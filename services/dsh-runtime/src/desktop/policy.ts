import { randomUUID } from 'node:crypto';
import { fingerprint, LocalError } from './ledger.js';

export type PermissionMode = 'ask' | 'assist' | 'full';
export type Operation = 'read' | 'write' | 'overwrite' | 'delete' | 'shell' | 'network' | 'browser' | 'desktop' | 'upload';
export interface ToolIntent { tool: string; operation: Operation; args: Record<string, unknown> }
export interface ApprovalRequest { id: string; run: string; revision: number; intent: ToolIntent; expiresAt: number }
interface Pending { request: ApprovalRequest; digest: string; resolve: (approved: boolean) => void; timer: NodeJS.Timeout }

/** Owned by the App control plane; workers can request but cannot resolve approvals. */
export class LocalPolicy {
  private currentMode: PermissionMode = 'assist';
  private revision = 1;
  private generation = new AbortController();
  private readonly taskGrants = new Set<string>();
  private readonly pending = new Map<string, Pending>();
  private fullConfirmation: { id: string; revision: number; expiresAt: number } | undefined;

  constructor(readonly run: string, private readonly onApproval: (request: ApprovalRequest) => void, private readonly approvalTimeoutMs = 120_000) {}

  get mode(): PermissionMode { return this.currentMode; }
  get version(): number { return this.revision; }
  get signal(): AbortSignal { return this.generation.signal; }
  pendingApproval(id: string): ApprovalRequest | undefined {
    const pending = this.pending.get(id);
    return pending ? structuredClone(pending.request) : undefined;
  }

  requestFull(): { id: string; revision: number; expiresAt: number } {
    return this.fullConfirmation = { id: randomUUID(), revision: this.revision, expiresAt: Date.now() + 60_000 };
  }

  /** Only authenticated App IPC calls this after displaying the local confirmation. */
  setMode(mode: PermissionMode, confirmation?: string): void {
    if (!['ask', 'assist', 'full'].includes(mode)) throw new LocalError('local.invalid_policy');
    if (mode === 'full') {
      const check = this.fullConfirmation;
      this.fullConfirmation = undefined;
      if (!check || check.id !== confirmation || check.revision !== this.revision || check.expiresAt < Date.now()) throw new LocalError('local.full_confirmation_required');
    }
    this.revoke();
    this.currentMode = mode;
    this.generation = new AbortController();
  }

  revoke(): void {
    this.revision += 1;
    this.generation.abort(new LocalError('local.permission_revoked'));
    this.fullConfirmation = undefined;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.resolve(false); }
    this.pending.clear();
    this.taskGrants.clear();
  }

  approve(id: string, revision: number, approved: boolean, scope: 'once' | 'task' = 'once'): void {
    const pending = this.pending.get(id);
    if (!pending || revision !== this.revision || revision !== pending.request.revision || pending.request.expiresAt < Date.now()) throw new LocalError('local.approval_stale');
    if (approved && scope === 'task' && pending.request.intent.operation !== 'upload') this.taskGrants.add(pending.digest);
    this.pending.delete(id);
    clearTimeout(pending.timer);
    pending.resolve(approved);
  }

  async execute<T>(intent: ToolIntent, execute: (signal: AbortSignal) => Promise<T>, signal?: AbortSignal): Promise<T> {
    const revision = this.revision;
    const generation = this.generation.signal;
    const combined = signal ? AbortSignal.any([generation, signal]) : generation;
    combined.throwIfAborted();
    // Full never implies file upload consent. Each upload intent includes immutable artifact IDs + hashes.
    const workspaceRead = intent.operation === 'read' && !(['search_files', 'view_local_image'].includes(intent.tool) && intent.args['scope'] === 'home');
    const automatic = intent.operation !== 'upload' && (this.taskGrants.has(fingerprint(intent)) || this.currentMode === 'full' || workspaceRead || (this.currentMode === 'assist' && intent.operation === 'write'));
    if (!automatic) {
      const frozen = structuredClone(intent);
      const digest = fingerprint(frozen);
      const request: ApprovalRequest = { id: randomUUID(), run: this.run, revision, intent: frozen, expiresAt: Date.now() + this.approvalTimeoutMs };
      const approved = await new Promise<boolean>((resolve) => {
        const settle = (value: boolean) => {
          clearTimeout(timer);
          combined.removeEventListener('abort', aborted);
          this.pending.delete(request.id);
          resolve(value);
        };
        const aborted = () => settle(false);
        const timer = setTimeout(() => settle(false), this.approvalTimeoutMs);
        timer.unref();
        this.pending.set(request.id, { request, digest, resolve: settle, timer });
        combined.addEventListener('abort', aborted, { once: true });
        if (combined.aborted) settle(false);
        else { try { this.onApproval(structuredClone(request)); } catch { settle(false); } }
      });
      if (!approved) throw new LocalError('local.approval_denied');
      if (digest !== fingerprint(intent)) throw new LocalError('local.approval_changed');
    }
    combined.throwIfAborted();
    if (revision !== this.revision) throw new LocalError('local.approval_stale');
    // Adapters must honor this signal and kill the full subprocess tree before resolving cancellation.
    return execute(combined);
  }
}
