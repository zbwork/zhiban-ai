import { coordinateApproval } from './remote-approval.js';
import { webSearchResponse } from './web-search.js';
import { fingerprint } from './ledger.js';
import type { ApprovalRequest } from './policy.js';
import { recoverModelRequest } from './model-recovery.js';
import { WebSocket } from 'ws';
import { z } from 'zod';
import { LocalError, sameIdentity, type LocalEvent, type LocalIdentity, type LocalLedger, type LocalTask } from './ledger.js';
import type { ActiveLocalRun, LeaseState, LocalRunConfig, LocalSupervisor } from './supervisor.js';

const id = z.string().regex(/^[a-zA-Z0-9_-]{1,128}$/);
const deviceSchema = z.object({ device_id: id, tenant_id: id, account_id: id, generation: z.number().int().nonnegative(), connect_token: z.string().min(1).max(4096), connect_expires_at: z.string().datetime({ offset: true }) });
export type RegisteredDevice = z.infer<typeof deviceSchema>;
const deliverySchema = z.object({
  run_id: id, device_id: id, tenant_id: id, account_id: id, login_session_id: id, agent_id: id,
  conversation_id: id, message_id: id, fencing_token: z.number().int().positive(), expires_at: z.string().datetime({ offset: true }),
  local_engine: z.enum(['dsh', 'codex_app_server']).default('dsh'),
  model: z.string().min(1).max(1024), status: z.enum(['dispatched', 'accepted']), last_seq: z.number().int().nonnegative(),
  payload: z.object({ text: z.string().min(1).max(100_000), persona: z.string(), history: z.string(), model_protocol: z.enum(['openai-compatible', 'anthropic-messages']) }).passthrough(),
});

export interface ChannelOptions {
  /** App configuration, never an engine/tool parameter. Must include /api/agent-bus/v1. */
  baseURL: string;
  identity: LocalIdentity;
  installationId: string;
  platform: 'darwin' | 'win32';
  engines?: Record<string, string>;
  /** App-owned login token. Connection tickets and login credentials remain in memory. */
  accessToken(): Promise<string>;
  ledger: LocalLedger;
  supervisor(): LocalSupervisor;
  /** Resolve only an App-authorized local workspace; paths never travel to Bus. */
  configure(task: LocalTask, payload: z.infer<typeof deliverySchema>['payload']): Promise<LocalRunConfig>;
  onStatus(status: 'connecting' | 'online' | 'offline'): void;
  /** App restarts the helper after refreshing registration/token; no hidden offline work queue. */
  onDisconnected(): void;
}

function apiBase(raw: string): URL {
  const url = new URL(raw.endsWith('/') ? raw : `${raw}/`);
  const local = url.protocol === 'http:' && url.hostname === '127.0.0.1';
  if ((!local && url.protocol !== 'https:') || url.username || url.password || url.search || url.hash || !url.pathname.endsWith('/api/agent-bus/v1/')) throw new LocalError('local.invalid_bus_url');
  return url;
}

async function jsonRequest(base: URL, path: string, token: string, body: unknown): Promise<unknown> {
  const response = await fetch(new URL(path, base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(5000) });
  if (!response.ok) {
    await response.body?.cancel();
    throw new LocalError(response.status === 401 || response.status === 403 ? 'local.unauthorized' : 'local.bus_unavailable');
  }
  const envelope = z.object({ success: z.literal(true), data: z.unknown() }).parse(await response.json());
  return envelope.data;
}

export async function registerDesktop(baseURL: string, token: string, platform: 'darwin' | 'win32', installationId: string, engines: Record<string, string> = { dsh: '0.1.0-rc.8' }): Promise<RegisteredDevice> {
  return deviceSchema.parse(await jsonRequest(apiBase(baseURL), 'local-runtime/devices', token, { platform, installation_id: installationId, protocol_version: 2, engines }));
}

/** Uses the same durable run/message identifiers across reconnects; credentials exist only in memory. */
export class DesktopChannel {
  private readonly base: URL;
  private socket: WebSocket | undefined;
  private connected = false;
  private stopped = false;
  private readonly capabilities = new Map<string, string>();
  private readonly acknowledgements = new Map<string, { resolve(): void; reject(): void }>();
  private readonly accepted = new Set<string>();
  private readonly sent = new Map<string, number>();
  private timer: NodeJS.Timeout | undefined;
  private reconnectTimer: NodeJS.Timeout | undefined;
  private attempt = 0;
  private lastHeartbeat = 0;
  private generation = 0;

  constructor(private readonly opts: ChannelOptions) { this.base = apiBase(opts.baseURL); }

  async connect(): Promise<void> {
    if (this.socket || this.stopped) throw new LocalError('local.channel_state');
    this.opts.onStatus('connecting');
    const token = await this.opts.accessToken();
    const device = await registerDesktop(this.opts.baseURL, token, this.opts.platform, this.opts.installationId, this.opts.engines);
    if (device.device_id !== this.opts.identity.device || device.tenant_id !== this.opts.identity.tenant || device.account_id !== this.opts.identity.account) throw new LocalError('local.identity_mismatch');
    const url = new URL('local-runtime/channel', this.base);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    const socket = new WebSocket(url, { followRedirects: false, perMessageDeflate: false, maxPayload: 1024 * 1024, handshakeTimeout: 5000, headers: {
      authorization: `Bearer ${token}`, 'X-Local-Device': device.device_id, 'X-Local-Generation': String(device.generation),
      'X-Local-Connect-Token': device.connect_token,
    } });
    this.socket = socket;
    let handshakeError: LocalError | undefined;
    socket.once('unexpected-response', (_request, response) => {
      handshakeError = new LocalError(response.statusCode === 401 || response.statusCode === 403 ? 'local.unauthorized' : 'local.channel_unavailable');
      // With a listener ws leaves the response to us. Close it without exposing its body.
      response.destroy(); socket.terminate();
    });
    let queue = Promise.resolve();
    socket.on('message', (data, binary) => {
      if (binary) { socket.terminate(); return; }
      // Ordered processing; asynchronous lease checks must not reorder task acceptance and event ACKs.
      queue = queue.then(() => this.receive(JSON.parse(data.toString()) as unknown)).catch(() => socket.terminate());
    });
    socket.on('error', () => { /* close handles lifecycle; do not log credentials, URL or payload */ });
    socket.once('close', () => {
      this.connected = false;
      this.socket = undefined;
      if (this.timer) clearInterval(this.timer);
      // Capabilities are per-connection: dropping them makes validateLease report 'offline', which
      // gates every model/tool call until we are authoritative again.
      this.capabilities.clear(); this.accepted.clear(); this.sent.clear();
      for (const ack of this.acknowledgements.values()) ack.reject();
      this.acknowledgements.clear();
      this.opts.onStatus('offline');
      // Q4: a transient drop must not destroy engine state a reconnect can still deliver. The run
      // stays alive but fully gated; task.expiresAt remains the backstop.
      if (!this.stopped && !this.disconnectIfTerminal(handshakeError)) this.scheduleReconnect();
    });
    await new Promise<void>((resolve, reject) => {
      const opened = () => { socket.off('error', failed); resolve(); };
      const failed = () => { socket.off('open', opened); reject(handshakeError ?? new LocalError('local.channel_unavailable')); };
      socket.once('open', opened); socket.once('error', failed);
    });
  }

  /** 1s→30s exponential backoff with jitter, so a fleet does not reconnect in lockstep. */
  static backoffMs(attempt: number, random = Math.random): number {
    const base = Math.min(30_000, 1000 * 2 ** Math.max(0, attempt - 1));
    return Math.round(base * (0.8 + random() * 0.4));
  }

  /** Only an identity/authorization refusal is terminal; transport faults keep retrying. */
  private static terminal(error: unknown): boolean {
    return error instanceof LocalError && ['local.identity_mismatch', 'local.device_revoked', 'local.unauthorized'].includes(error.code);
  }

  private disconnectIfTerminal(error: unknown): boolean {
    if (!DesktopChannel.terminal(error)) return false;
    if (!this.stopped) {
      this.stopped = true;
      if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
      this.opts.onDisconnected();
    }
    return true;
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    this.attempt += 1;
    this.opts.onStatus('connecting');
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (this.stopped) return;
      void this.connect().catch((error: unknown) => {
        if (this.stopped) return;
        // A revoked session must tear the helper down instead of reconnecting forever.
        if (this.disconnectIfTerminal(error)) return;
        this.scheduleReconnect();
      });
    }, DesktopChannel.backoffMs(this.attempt));
    this.reconnectTimer.unref();
  }

  private send(value: unknown): void {
    if (!this.connected || !this.socket || this.socket.readyState !== WebSocket.OPEN) throw new LocalError('local.channel_offline');
    if (this.socket.bufferedAmount > 4 * 1024 * 1024) { this.socket.terminate(); throw new LocalError('local.channel_backpressure'); }
    this.socket.send(JSON.stringify(value));
  }

  private flush(runID: string): void {
    if (!this.accepted.has(runID)) return;
    const stored = this.opts.ledger.get(runID);
    if (!stored) throw new LocalError('local.run_not_found');
    for (const event of this.opts.ledger.replay(runID, stored.task.fence, Math.max(stored.ack, this.sent.get(runID) ?? 0))) {
      if (event.seq > stored.ack + 4) break; // Keep heartbeat/control frames ahead of an unbounded token backlog.
      this.send({ type: 'event', run_id: event.run, fencing_token: event.fence, seq: event.seq, event: event.frame.event, data: event.frame.data });
      this.sent.set(runID, event.seq);
    }
  }

  onEvent(event: LocalEvent): void { if (this.connected && this.accepted.has(event.run)) this.flush(event.run); }

  async confirmAccepted(task: LocalTask): Promise<void> {
    if (!this.connected) throw new LocalError('local.channel_offline');
    await new Promise<void>((resolve, reject) => {
      const settle = (ok: boolean) => {
        clearTimeout(timer); this.acknowledgements.delete(task.run);
        if (ok) resolve(); else reject(new LocalError('local.acceptance_unconfirmed'));
      };
      const timer = setTimeout(() => settle(false), 5000);
      this.acknowledgements.set(task.run, { resolve: () => settle(true), reject: () => settle(false) });
      try { this.send({ type: 'task.accepted', run_id: task.run, fencing_token: task.fence }); } catch { settle(false); }
    });
  }

  private async receive(raw: unknown): Promise<void> {
    const message = z.record(z.string(), z.unknown()).parse(raw);
    const type = message['type'];
    if (type === 'hello') {
      if (this.connected || message['device_id'] !== this.opts.identity.device || message['version'] !== 1) throw new LocalError('local.channel_identity');
      this.generation = z.number().int().positive().parse(message['generation']);
      this.connected = true; this.attempt = 0; this.lastHeartbeat = Date.now(); this.opts.onStatus('online');
      this.send({ type: 'heartbeat' });
      for (const stored of this.opts.ledger.unacknowledged(this.opts.identity)) this.send({ type: 'task.resume', run_id: stored.task.run, fencing_token: stored.task.fence });
      this.timer = setInterval(() => {
        if (Date.now() - this.lastHeartbeat > 12_000) { this.socket?.terminate(); return; }
        try { this.send({ type: 'heartbeat' }); } catch { this.socket?.terminate(); }
      }, 4000);
      return;
    }
    if (!this.connected) throw new LocalError('local.channel_not_ready');
    if (type === 'heartbeat.ack') { this.lastHeartbeat = Date.now(); return; }
    if (type === 'task.dispatch') {
      const value = deliverySchema.parse(message['task']);
      const capability = z.string().startsWith('lrt_').max(2048).parse(message['capability']);
      const task: LocalTask = { run: value.run_id, messageId: value.message_id, tenant: value.tenant_id, account: value.account_id, loginSession: value.login_session_id, device: value.device_id,
        engine: value.local_engine, employee: value.agent_id, conversation: value.conversation_id, fence: value.fencing_token, expiresAt: Date.parse(value.expires_at), source: z.enum(['desktop', 'mobile']).parse(value.payload['task_source'] ?? 'desktop'), message: value.payload.text, model: value.model };
      if (!sameIdentity(task, this.opts.identity)) throw new LocalError('local.identity_mismatch');
      this.capabilities.set(task.run, capability);
      const config = await this.opts.configure(task, value.payload);
      const result = await this.opts.supervisor().accept(task, config);
      if (!result.fresh) this.send({ type: 'task.accepted', run_id: task.run, fencing_token: task.fence });
      return;
    }
    const runID = id.parse(message['run_id']);
    const stored = this.opts.ledger.get(runID);
    if (!stored || !sameIdentity(stored.task, this.opts.identity)) throw new LocalError('local.run_not_found');
    if (type === 'task.rejected' || type === 'event.rejected') { this.accepted.delete(runID); this.capabilities.delete(runID); this.acknowledgements.get(runID)?.reject(); await this.opts.supervisor().cancel(runID, stored.task.fence); return; }
    const fence = z.number().int().positive().parse(message['fencing_token']);
    if (stored.task.fence !== fence) throw new LocalError('local.fence_mismatch');
    if (type === 'task.accepted_ack') {
      this.accepted.add(runID); this.acknowledgements.get(runID)?.resolve(); this.flush(runID);
    } else if (type === 'event.ack') {
      this.opts.ledger.acknowledge(runID, fence, z.number().int().nonnegative().parse(message['seq']));
      this.flush(runID);
    } else if (type === 'task.cancel') {
      this.acknowledgements.get(runID)?.reject();
      await this.opts.supervisor().cancel(runID, fence);
      this.capabilities.delete(runID); this.accepted.delete(runID);
    } else if (type === 'task.state') {
      this.opts.ledger.acknowledge(runID, fence, z.number().int().nonnegative().parse(message['seq']));
      if (message['status'] === 'accepted' || message['status'] === 'dispatched') {
        this.send({ type: 'task.accepted', run_id: runID, fencing_token: fence });
      } else {
        await this.opts.supervisor().cancel(runID, fence);
        this.capabilities.delete(runID); this.accepted.delete(runID);
      }
    } else throw new LocalError('local.channel_event_invalid');
  }

  async coordinateApproval(request: ApprovalRequest): Promise<void> {
    const run = this.opts.supervisor().get(request.run);
    if (!run) throw new LocalError('local.run_not_found');
    const signal = AbortSignal.any([run.controller.signal, run.policy.signal]);
    await coordinateApproval({ request, policy: run.policy, fence: run.task.fence, expiresAt: run.task.expiresAt, signal,
      send: async (method, suffix, body) => {
        const capability = this.capabilities.get(request.run);
        if (!this.connected || !capability) throw new LocalError('local.channel_offline');
        const response = await fetch(new URL(`local-runtime/runs/${request.run}/approvals${suffix}`, this.base), {
          method, redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(run.task.fence), 'content-type': 'application/json' },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(4000),
        });
        if (!response.ok) throw new LocalError('local.approval_sync_failed');
        return z.object({ success: z.literal(true), data: z.unknown() }).parse(await response.json()).data;
      },
    });
  }

  async decideApproval(run: ActiveLocalRun, id: string, revision: number, approved: boolean, scope: 'once' | 'task'): Promise<void> {
    const pending = run.policy.pendingApproval(id);
    if (!pending || pending.revision !== revision) throw new LocalError('local.approval_stale');
    await jsonRequest(this.base, `local-runtime/approvals/${id}`, await this.opts.accessToken(), {
      revision, intent_hash: fingerprint(pending.intent), approved, scope,
    });
    // The common polling path, never this IPC request, applies the winning server decision.
  }

  async validateLease(task: LocalTask): Promise<LeaseState> {
    // Identity mismatch is a hard revocation; being unreachable is not.
    if (!sameIdentity(task, this.opts.identity)) return false;
    const capability = this.capabilities.get(task.run);
    if (!this.connected || !capability) return 'offline';
    try {
      const response = await fetch(new URL(`local-runtime/runs/${task.run}/authorize`, this.base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(task.fence) }, signal: AbortSignal.timeout(12_000) });
      await response.body?.cancel();
      // Only an explicit server refusal revokes; transport/5xx faults stay 'offline' so a reconnect
      // can still finish the run (Q4). Execution remains refused either way.
      if ([401, 403, 404, 409, 410].includes(response.status)) return false;
      if (!response.ok) return 'offline';
      return this.connected ? true : 'offline';
    } catch { return 'offline'; }
  }

  async model(task: LocalTask, protocol: 'chat/completions' | 'messages' | 'responses', body: Record<string, unknown>, signal: AbortSignal): Promise<Response> {
    const capability = this.capabilities.get(task.run);
    if (!this.connected || !capability || !sameIdentity(task, this.opts.identity)) throw new LocalError('local.lease_invalid');
    const run = this.opts.supervisor().get(task.run);
    if (!run) throw new LocalError('local.lease_invalid');
    return recoverModelRequest({ state: run.recovery, candidates: protocol === 'responses' ? [] : run.config.modelRecovery ?? [], body, signal,
      progress: (text) => this.opts.supervisor().modelProgress(task, text),
      request: async (slot, requestSignal) => {
        if (!this.connected || this.capabilities.get(task.run) !== capability) throw new LocalError('local.lease_invalid');
        return fetch(new URL(`local-runtime/runs/${task.run}/model/${protocol}`, this.base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(task.fence), 'X-Local-Model-Slot': String(slot), 'content-type': 'application/json' }, body: JSON.stringify(body), signal: requestSignal });
      },
    });
  }

  async image(task: LocalTask, body: Record<string, unknown>, signal: AbortSignal): Promise<Buffer> {
    const capability = this.capabilities.get(task.run);
    if (!this.connected || !capability || !sameIdentity(task, this.opts.identity)) throw new LocalError('local.lease_invalid');
    // No model fallback/recovery loop for a paid media submission.
    const response = await fetch(new URL(`local-runtime/runs/${task.run}/images`, this.base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(task.fence), 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.any([signal, AbortSignal.timeout(330_000)]) });
    if (!response.ok) {
      const raw = await response.json().catch(() => null) as { error?: { code?: string } } | null;
      const allowed = ['local.lease_invalid', 'local.image_invalid', 'local.image_credit_unavailable', 'local.image_unavailable', 'local.image_rejected', 'local.media_conflict', 'local.media_reconcile_required'];
      throw new LocalError(allowed.includes(raw?.error?.code ?? '') ? raw!.error!.code! : 'local.image_unavailable');
    }
    if (response.headers.get('content-type') !== 'image/png' || !response.body) { await response.body?.cancel(); throw new LocalError('local.image_invalid'); }
    const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
    try {
      for (;;) {
        const part = await reader.read(); if (part.done) break;
        size += part.value.length; if (size > 12 * 1024 * 1024) throw new LocalError('local.image_invalid');
        chunks.push(part.value);
      }
    } finally { await reader.cancel(); }
    signal.throwIfAborted();
    return Buffer.concat(chunks);
  }

  async search(task: LocalTask, body: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    const capability = this.capabilities.get(task.run);
    if (!this.connected || !capability || !sameIdentity(task, this.opts.identity)) throw new LocalError('local.lease_invalid');
    const timeout = AbortSignal.timeout(25_000);
    const combined = AbortSignal.any([signal, timeout]);
    try {
      const response = await fetch(new URL(`local-runtime/runs/${task.run}/search`, this.base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(task.fence), 'content-type': 'application/json' }, body: JSON.stringify(body), signal: combined });
      if (!response.body) throw new LocalError('local.web_search_unavailable');
      const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
      try {
        for (;;) {
          const part = await reader.read(); if (part.done) break;
          size += part.value.length; if (size > 256 * 1024) throw new LocalError('local.web_search_unavailable');
          chunks.push(part.value);
        }
      } finally { await reader.cancel(); }
      combined.throwIfAborted();
      if (!this.connected || this.capabilities.get(task.run) !== capability) throw new LocalError('local.lease_invalid');
      const raw: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!response.ok) {
        const error = z.object({ error: z.object({ code: z.enum(['local.lease_invalid', 'local.web_search_invalid', 'local.web_search_unavailable', 'local.web_search_limited', 'local.web_search_timeout']) }) }).safeParse(raw);
        throw new LocalError(error.success ? error.data.error.code : 'local.web_search_unavailable');
      }
      const parsed = webSearchResponse.safeParse(raw);
      if (!parsed.success) throw new LocalError('local.web_search_unavailable');
      return parsed.data;
    } catch (error) {
      signal.throwIfAborted();
      if (timeout.aborted) throw new LocalError('local.web_search_timeout');
      if (error instanceof LocalError) throw error;
      throw new LocalError('local.web_search_unavailable');
    }
  }

  get allowHttpStorage(): boolean { return this.base.protocol === 'http:' && this.base.hostname === '127.0.0.1'; }

  async output(task: LocalTask, operation: 'sign' | 'confirm', body: unknown, signal: AbortSignal): Promise<unknown> {
    const capability = this.capabilities.get(task.run);
    if (!this.connected || !capability || !sameIdentity(task, this.opts.identity)) throw new LocalError('local.lease_invalid');
    const response = await fetch(new URL(`local-runtime/runs/${task.run}/files/${operation}`, this.base), { method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${capability}`, 'X-Local-Fence': String(task.fence), 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)]) });
    if (!response.ok) { await response.body?.cancel(); throw new LocalError('local.archive_failed'); }
    return z.object({ success: z.literal(true), data: z.unknown() }).parse(await response.json()).data;
  }

  async recoverResult(task: LocalTask, suffix: string, body: unknown, signal: AbortSignal): Promise<unknown> {
    if (!this.connected || !sameIdentity(task, this.opts.identity)) throw new LocalError('local.lease_invalid');
    const response = await fetch(new URL(`local-runtime/runs/${task.run}/${suffix}`, this.base), {
      method: 'POST', redirect: 'error', headers: {
        authorization: `Bearer ${await this.opts.accessToken()}`, 'content-type': 'application/json',
        'X-Local-Device': task.device, 'X-Local-Fence': String(task.fence), 'X-Local-Generation': String(this.generation),
      }, body: JSON.stringify(body), signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)]),
    });
    if (!response.ok) { await response.body?.cancel(); throw new LocalError('local.result_recovery_failed'); }
    return z.object({success: z.literal(true), data: z.unknown()}).parse(await response.json()).data;
  }

  async close(): Promise<void> {
    this.stopped = true; this.connected = false;
    if (this.timer) clearInterval(this.timer);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.socket?.terminate();
    await this.opts.supervisor().stop();
    this.capabilities.clear();
  }
}
