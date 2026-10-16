import { ResultRecovery } from './result-recovery.js';
import { captureDeclaredDeliverables, verifyLocalDeliverables } from './deliverables.js';
/** Desktop helper entrypoint. Parent pipe is the only bootstrap/credential channel. */
import { mkdir, realpath } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { archiveLocalOutputs } from './archive.js';
import { officeTools } from './office.js';
import { imageTools } from './image.js';
import { webSearchTool } from './web-search.js';
import { historyTool } from './history.js';
import { LocalBrowser } from './browser.js';
import { DesktopContext } from './context.js';
import { DesktopBroker } from './broker.js';
import { DesktopChannel, registerDesktop } from './channel.js';
import { ArtifactStore } from './artifacts.js';
import { DesktopEngine } from './engine.js';
import { CODEX_VERSION, CodexDesktopEngine, LocalEngineRouter } from './codex-engine.js';
import { fingerprint, LocalError, LocalLedger } from './ledger.js';
import { LocalSupervisor } from './supervisor.js';
import { localTools } from './tools.js';
import { desktopComponentCheck } from './diagnostics.js';
import { desktopLoginIdentity } from './bootstrap-identity.js';
import { LocalWorkspaces } from './workspaces.js';
import { systemTool } from './system.js';
import { searchTool } from './search.js';
import { visionTool } from './vision.js';
import { mediaTool } from './media.js';
import { ParentComputer } from './computer.js';

const output = (value: unknown) => { process.stdout.write(`${JSON.stringify(value)}\n`); };
const bootstrap = z.object({ type: z.literal('initialize'), baseURL: z.string().max(2048), accessToken: z.string().min(1).max(16000), installationId: z.string().uuid(),
  loginSession: z.string().uuid(), account: z.string().uuid(), tenant: z.string().min(1).max(64), privateRoot: z.string().max(4096), documentsRoot: z.string().max(4096),
}).strict();

async function run(): Promise<void> {
  if (process.argv.includes('--self-check')) { output(await desktopComponentCheck()); return; }
  if (process.platform !== 'darwin' && process.platform !== 'win32') throw new LocalError('local.platform_unsupported');
  if (process.stdin.isTTY) throw new LocalError('local.parent_pipe_required');
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const computer = new ParentComputer(output);
  let broker: DesktopBroker | undefined;
  let supervisor: LocalSupervisor | undefined;
  let channel: DesktopChannel | undefined;
  let ledger: LocalLedger | undefined;
  let accessToken = '';
  let resultRecovery: ResultRecovery | undefined;
  let resultTimer: NodeJS.Timeout | undefined;
  let resultAbort = new AbortController();
  let resultWork = Promise.resolve();
  const recoverResults = () => {
    const signal = resultAbort.signal;
    resultWork = resultWork.then(() => signal.aborted ? undefined : resultRecovery?.drain(signal)).catch(() => {
      if (signal.aborted) return;
      output({type: 'error', code: 'local.result_recovery_failed'}); void shutdown();
    });
  };
  let closing = false;
  let started = false;
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    computer.close();
    accessToken = '';
    resultAbort.abort();
    if (resultTimer) clearInterval(resultTimer);
    // Graceful tree cleanup gets a bounded window; App also supervises helper exit.
    const deadline = setTimeout(() => process.exit(1), 8000);
    try { await channel?.close(); await supervisor?.stop(); await broker?.close(); await resultWork; ledger?.close(); }
    finally { clearTimeout(deadline); process.exit(0); }
  };
  process.once('SIGTERM', () => { void shutdown(); });
  process.once('SIGINT', () => { void shutdown(); });
  lines.once('close', () => { void shutdown(); });
  const startTimeout = setTimeout(() => { output({ type: 'error', code: 'local.bootstrap_timeout' }); void shutdown(); }, 15_000);
  let queue = Promise.resolve();
  lines.on('line', (line) => {
    queue = queue.then(async () => {
      if (line.length > 2_100_000) throw new LocalError('local.invalid_bootstrap');
      const input = JSON.parse(line) as Record<string, unknown>;
      if (input['type'] === 'computer_result' && started && !closing) { computer.accept(input); return; }
      if (line.length > 32_000) throw new LocalError('local.invalid_bootstrap');
      if (input['type'] === 'stop') { await shutdown(); return; }
      if (input['type'] === 'token' && started) {
        const token = z.object({ type: z.literal('token'), accessToken: z.string().min(1).max(16000) }).strict().parse(input);
        // Parent must restart the helper for any identity/scope change.
        accessToken = token.accessToken; return;
      }
      if (started || closing) throw new LocalError('local.already_initialized');
      started = true; clearTimeout(startTimeout);
      const config = bootstrap.parse(input);
      if (!isAbsolute(config.privateRoot) || !isAbsolute(config.documentsRoot)) throw new LocalError('local.invalid_bootstrap');
      accessToken = config.accessToken;
      const login = desktopLoginIdentity(accessToken);
      if (login.account !== config.account || login.tenant !== config.tenant || login.loginSession !== config.loginSession) throw new LocalError('local.identity_mismatch');
      // Clear raw credential strings in the parsed control message as soon as possible.
      config.accessToken = ''; input['accessToken'] = '';
      const platform = process.platform as 'darwin' | 'win32';
      // Target-machine probes, not a platform name, decide whether execution is available.
      const components = await desktopComponentCheck();
      if (!components.checks['node'] || !components.checks['engine'] || !components.checks['isolation']) throw new LocalError('local.isolation_unavailable');
      const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
      const engines: Record<string,string> = { dsh: '0.1.0-rc.8', ...(components.checks['codex'] ? { codex_app_server: CODEX_VERSION } : {}) };
      const device = await registerDesktop(config.baseURL, accessToken, platform, config.installationId, engines);
      if (device.account_id !== config.account || (!config.tenant.startsWith('id:') && device.tenant_id !== config.tenant)) throw new LocalError('local.identity_mismatch');
      const identity = { tenant: device.tenant_id, account: device.account_id, loginSession: config.loginSession, device: device.device_id };
      const stateRoot = join(config.privateRoot, fingerprint({ tenant: identity.tenant, account: identity.account }));
      await mkdir(stateRoot, { recursive: true, mode: 0o700 });
      const canonicalState = await realpath(stateRoot);
      const workspaces = new LocalWorkspaces({ stateRoot: canonicalState, documentsRoot: config.documentsRoot, identity });
      await workspaces.load();
      ledger = new LocalLedger(join(canonicalState, 'tasks.sqlite'));
      ledger.recover();
      const artifacts = new ArtifactStore(join(canonicalState, 'artifacts'));
      const browser = new LocalBrowser({ root: join(canonicalState, 'browser') });
      const tools: ReturnType<typeof localTools> = [systemTool(), ...computer.tools(), browser.tool(), browser.actionsTool()];
      broker = new DesktopBroker({ saveImageAttachment: (task, input, signal) => dsh.saveImageAttachment(task, input, signal), decideApproval: (...args) => channel!.decideApproval(...args), supervisor: () => supervisor!, workspaces, tools, originalArtifact: (conversation, ref) => artifacts.originalForConversation({ tenant: identity.tenant, account: identity.account, conversation }, ref), readArtifact: (conversation, ref) => artifacts.readForConversation({ tenant: identity.tenant, account: identity.account, conversation }, ref), model: (task, protocol, body, signal) => channel!.model(task, protocol, body, signal) });
      const brokerURL = await broker.listen();
      tools.push(webSearchTool({ search: (task, body, signal) => channel!.search(task, body, signal) }));
      tools.push(visionTool({ privateRoot: config.privateRoot, brokerPort: Number(new URL(brokerURL).port) }), searchTool({ privateRoot: config.privateRoot, brokerPort: Number(new URL(brokerURL).port) }));
      const mediaRenderer = process.platform === 'darwin' && existsSync(join(packageRoot, 'assets/bridge/local-media')) ? join(packageRoot, 'assets/bridge/local-media') : undefined;
      if (mediaRenderer) tools.push(mediaTool({ executable: mediaRenderer, privateRoot: config.privateRoot, brokerPort: Number(new URL(brokerURL).port) }));
      tools.push(...localTools({ privateRoot: config.privateRoot, artifacts, brokerPort: Number(new URL(brokerURL).port), runtimeReadRoots: [join(packageRoot, 'node_modules')], moduleRoot: join(packageRoot, 'node_modules') }));
      tools.push(historyTool(), ...officeTools({ packageRoot, privateRoot: config.privateRoot, artifacts, brokerPort: Number(new URL(brokerURL).port) }));
      tools.push(...imageTools({
        privateRoot: config.privateRoot,
        artifacts,
        brokerPort: Number(new URL(brokerURL).port),
        ledger,
        generate: (task, body, signal) => channel!.image(task, body, signal),
      }));
      if (new Set(tools.map((tool) => tool.name)).size !== tools.length) {
        throw new LocalError('local.duplicate_tool');
      }
      const context = new DesktopContext({ allowHttpStorage: () => channel?.allowHttpStorage ?? false, privateRoot: config.privateRoot, skillsRoot: join(canonicalState, 'skills'), brokerPort: Number(new URL(brokerURL).port) });
      const dsh: DesktopEngine = new DesktopEngine({ packageRoot, cacheRoot: join(canonicalState, 'engine'), brokerURL });
      const engine = new LocalEngineRouter(dsh, new CodexDesktopEngine({ packageRoot, cacheRoot: join(canonicalState, 'codex'), brokerURL }));
      supervisor = new LocalSupervisor({ identity, ledger, engine, validateLease: (task) => channel!.validateLease(task), confirmAccepted: (task) => channel!.confirmAccepted(task),
        requireDeliveryDeclaration: true, verifyDeliverables: async (run) => {
          if (!run.controller.signal.aborted && await channel!.validateLease(run.task).catch(() => false)) {
            const publish = tools.find((tool) => tool.name === 'publish_artifact')!;
            await captureDeclaredDeliverables(run, (file) => publish.call(run, { path: file.name, mime: file.mime }, run.controller.signal));
          }
          await verifyLocalDeliverables(run, artifacts);
        },
        archiveDeliverables: (run) => archiveLocalOutputs(run, artifacts, {
          allowHttpStorage: channel!.allowHttpStorage,
          sign: async (body, signal) => z.object({ upload_url: z.string().optional(), upload_headers: z.record(z.string(), z.string()).optional(), uploaded: z.boolean().optional() }).parse(await channel!.output(run.task, 'sign', body, signal)),
          confirm: async (body, signal) => z.object({ id: z.string().uuid() }).parse(await channel!.output(run.task, 'confirm', body, signal)),
        }),
        prepareContext: (run) => context.prepare(run), releaseContext: async (run) => { await browser.close(run.task.run); await context.release(run); },
        onEvent: (event) => { channel!.onEvent(event); output({ type: 'run', run: event.run, conversation: ledger!.get(event.run)?.task.conversation, event: event.frame.event }); },
        onApproval: (approval) => { output({ type: 'approval', context: supervisor?.get(approval.run)?.config.contextID, ...approval }); void channel!.coordinateApproval(approval).catch(() => {}); },
        onFatalError: (code) => { output({ type: 'error', code }); queueMicrotask(() => { void shutdown(); }); },
      });
      channel = new DesktopChannel({ baseURL: config.baseURL, identity, installationId: config.installationId, platform, engines, accessToken: async () => accessToken,
        ledger, supervisor: () => supervisor!,
        configure: async (task, payload) => {
          const contextID = z.string().uuid().parse(payload['local_context_id']);
          const { selection } = await workspaces.defaults(task.employee, contextID, z.string().max(200).parse(payload['employee_name'] ?? '数字员工'));
          return { modelRecovery: z.array(z.object({ slot: z.number().int().min(1).max(2), label: z.string().max(512) })).parse(payload['model_recovery'] ?? []), contextID, ...selection, persona: payload.persona, history: payload.history, protocol: payload.model_protocol, context: { blocks: payload['blocks'], skills: payload['skills'], knowledge: payload['knowledge_context'], metadata: z.record(z.string(), z.unknown()).parse(payload['metadata'] ?? {}) } };
        },
        onStatus: (status) => {
          if (resultTimer) { clearInterval(resultTimer); resultTimer = undefined; }
          if (status === 'online') {
            resultAbort.abort();
            resultAbort = new AbortController();
            output({ type: 'ready', version: 1, engines, device: identity.device, url: brokerURL, key: broker!.appKey });
            recoverResults(); resultTimer = setInterval(recoverResults, 3000); resultTimer.unref();
          } else {
            if (status === 'offline') resultAbort.abort();
            output({ type: 'status', status });
          }
        }, onDisconnected: () => { void shutdown(); },
      });
      resultRecovery = new ResultRecovery({ identity, ledger, artifacts,
        save: async (task, metas, signal) => z.object({can_archive: z.boolean()}).parse(await channel!.recoverResult(task, 'results', {
          blocks: metas.map((meta) => ({type: meta.mime.startsWith('image/') ? 'image' : 'file', ...meta})),
        }, signal)).can_archive,
        transport: (task) => ({
          allowHttpStorage: channel!.allowHttpStorage,
          sign: async (body, signal) => z.object({upload_url: z.string().optional(), upload_headers: z.record(z.string(), z.string()).optional(), uploaded: z.boolean().optional()}).parse(await channel!.recoverResult(task, 'archive/sign', body, signal)),
          confirm: async (body, signal) => z.object({id: z.string().uuid()}).parse(await channel!.recoverResult(task, 'archive/confirm', body, signal)),
        }),
        onSaved: (task) => output({type: 'results_saved', conversation: task.conversation}),
      });
      await channel.connect();
    }).catch((error: unknown) => { output({ type: 'error', code: error instanceof LocalError ? error.code : 'local.helper_unavailable' }); void shutdown(); });
  });
}

void run().catch((error: unknown) => {
  output({ type: 'error', code: error instanceof LocalError ? error.code : 'local.helper_unavailable' });
  process.exitCode = 1;
});
