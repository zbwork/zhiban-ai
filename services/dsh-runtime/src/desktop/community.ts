/** Community parent-pipe entrypoint: deliberately has no Bus/channel imports. */
import { createInterface } from 'node:readline';
import { realpathSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, realpath, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { DesktopBroker } from './broker.js';
import { DesktopEngine } from './engine.js';
import { CodexDesktopEngine, LocalEngineRouter } from './codex-engine.js';
import { fingerprint, LocalError, LocalLedger, type LocalTask } from './ledger.js';
import { LocalSupervisor } from './supervisor.js';
import { LocalWorkspaces } from './workspaces.js';
import { ArtifactStore } from './artifacts.js';
import { localTools } from './tools.js';
import { officeTools } from './office.js';
import { systemTool } from './system.js';
import { historyTool } from './history.js';
import { captureDeclaredDeliverables, verifyLocalDeliverables } from './deliverables.js';
import { desktopComponentCheck } from './diagnostics.js';
import { importCommunityAttachments } from './community-attachments.js';
import { readModelFailure } from './model-error.js';

const output = (value: unknown) => process.stdout.write(JSON.stringify(value) + '\n');
const modelRoute = z.object({
  baseURL: z.string().max(2048), apiKey: z.string().min(1).max(8192),
  headers: z.record(z.string(), z.string()).default({}),
  protocol: z.enum(['openai-compatible', 'anthropic-messages']),
}).strict();
type ModelRoute = z.infer<typeof modelRoute>;
export interface CommunityModelDiagnostic {
  request: string; protocol: string; attempt: number; status: number;
  code?: string; retryable: boolean; requestId?: string;
}

/** Backup of the authoritative registry; never guess aliases by ordinal. */
export function communityToolGuide(tools: Array<{ name: string; description: string; inputSchema: Record<string, unknown> }>): string {
  return '本轮可用工具以以下宿主实际注册目录为准。DSH 使用 mcp__local__ 前缀，例如 mcp__local__list_files；Codex 使用 local MCP 对应工具。参数遵守以下 schema。不使用 tool、tool_2 等占位名，不猜编号与工具对应关系。接口只显示占位定义时以此目录真实名称与参数为准，仍不能调用时说明接口异常，停止试探未知工具。只使用此目录与引擎实际提供的工具，不宣称具有未注册的搜索、浏览器或桌面控制能力。DSH 列目录只调用 mcp__local__list_files，path 为空；读取文件只调用 mcp__local__read_file。type=file 的路径不能传给目录工具。目录中每项 name 已是完整可调用名称，DSH 禁止去掉前缀。已获得未截断列表就回答，不为只问列表的任务继续读内容或枚举工具。工具错误按具体反馈修正，不重复试探。生成文件仍须交付声明与发布，写入和命令遵守当前访问权限，需批准时等待用户决定。本轮实际工具目录：' + JSON.stringify(tools.map(({ name, description, inputSchema }) => ({ name: 'mcp__local__' + name, description, parameters: inputSchema })));
}

/** The parent chooses the destination; workers cannot redirect credentials. */
export async function communityModel(route: ModelRoute, task: LocalTask, protocol: 'chat/completions' | 'messages' | 'responses', body: Record<string, unknown>, signal: AbortSignal, diagnose?: (event: CommunityModelDiagnostic) => Promise<void>): Promise<Response> {
  const url = new URL(route.baseURL);
  if (url.username || url.password || url.search || url.hash ||
    (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))) throw new LocalError('local.invalid_model_url');
  if (body['model'] !== task.model || (protocol === 'messages') !== (route.protocol === 'anthropic-messages')) throw new LocalError('local.model_protocol_mismatch');
  const base = route.baseURL.replace(/\/+$/, '');
  const apiBase = route.protocol === 'anthropic-messages' ? (base.endsWith('/v1') ? base : base + '/v1') : (url.pathname === '/' ? base + '/v1' : base);
  const headers = new Headers(route.headers);
  for (const name of ['authorization', 'x-api-key', 'host', 'cookie', 'content-length']) headers.delete(name);
  headers.set('content-type', 'application/json');
  if (route.protocol === 'anthropic-messages') { headers.set('x-api-key', route.apiKey); headers.set('anthropic-version', '2023-06-01'); }
  else headers.set('authorization', 'Bearer ' + route.apiKey);
  // Retry only an observed gateway rejection, never a delivered stream or tools.
  const serialized = JSON.stringify(body);
  const request = fingerprint(body);
  const record = async (response: Response, attempt: number, failure?: Awaited<ReturnType<typeof readModelFailure>>) => {
    const requestId = response.headers.get('x-request-id') ?? response.headers.get('request-id') ?? '';
    await diagnose?.({ request, protocol, attempt, status: response.status,
      ...(failure ? { code: failure.code } : {}), retryable: failure?.transientRequestRejection === true,
      ...(/^[a-zA-Z0-9_-]{1,128}$/.test(requestId) ? { requestId } : {}) }).catch(() => {});
  };
  const send = () => fetch(apiBase + '/' + protocol, { method: 'POST', headers, body: serialized, redirect: 'error', signal });
  let response = await send();
  if (response.ok) { await record(response, 1); return response; }
  let failure = await readModelFailure(response, signal, 'provider');
  await record(response, 1, failure);
  signal.throwIfAborted();
  if (url.origin === 'https://api.airick.cn' && protocol === 'chat/completions' && failure.transientRequestRejection) {
    await delay(250, undefined, { signal });
    response = await send();
    if (response.ok) { await record(response, 2); return response; }
    failure = await readModelFailure(response, signal, 'provider');
    await record(response, 2, failure);
  }
  return new Response(JSON.stringify({ message: failure.code }), { status: response.status, headers: { 'content-type': 'application/json', 'x-local-model-upstream-status': String(response.status) } });
}

export async function runCommunity(): Promise<void> {
  if (process.stdin.isTTY) throw new LocalError('local.parent_pipe_required');
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const routes = new Map<string, ModelRoute>();
  const diagnosticCounts = new Map<string, number>();
  let supervisor: LocalSupervisor | undefined;
  let broker: DesktopBroker | undefined;
  let ledger: LocalLedger | undefined;
  let workspaces: LocalWorkspaces | undefined;
  let communityStateRoot = '';
  let toolGuide = '';
  let closing = false;
  const session = randomUUID();
  // Explicit local namespaces, never a platform identity or authorization token.
  const identity = { tenant: 'community', account: 'device-local', loginSession: session, device: 'local-desktop' };
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    const deadline = setTimeout(() => process.exit(1), 8000);
    try { await supervisor?.stop(); routes.clear(); await broker?.close(); ledger?.close(); }
    finally { clearTimeout(deadline); process.exit(0); }
  };
  lines.once('close', () => { void shutdown(); });
  process.once('SIGTERM', () => { void shutdown(); });
  process.once('SIGINT', () => { void shutdown(); });
  const bootstrapTimeout = setTimeout(() => { void shutdown(); }, 15000);
  let queue = Promise.resolve();
  lines.on('line', line => {
    queue = queue.then(async () => {
      let requestID: unknown;
      try {
        if (line.length > 4_000_000 || closing) throw new LocalError('local.invalid_request');
        const input = JSON.parse(line) as Record<string, unknown>;
        requestID = input['id'];
        if (!supervisor) {
          const config = z.object({ type: z.literal('initialize'), privateRoot: z.string().max(4096), documentsRoot: z.string().max(4096) }).strict().parse(input);
          if (!isAbsolute(config.privateRoot) || !isAbsolute(config.documentsRoot)) throw new LocalError('local.invalid_bootstrap');
          const components = await desktopComponentCheck();
          if (!components.checks['node'] || !components.checks['engine'] || !components.checks['isolation']) throw new LocalError('local.isolation_unavailable');
          const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
          await mkdir(config.privateRoot, { recursive: true, mode: 0o700 });
          const stateRoot = await realpath(config.privateRoot);
          communityStateRoot = stateRoot;
          workspaces = new LocalWorkspaces({ stateRoot, documentsRoot: config.documentsRoot, identity });
          await workspaces.load();
          ledger = new LocalLedger(join(stateRoot, 'tasks.sqlite')); ledger.recover();
          const artifacts = new ArtifactStore(join(stateRoot, 'artifacts'));
          const tools = [systemTool(), historyTool()];
          broker = new DesktopBroker({
            supervisor: () => supervisor!, tools, workspaces,
            model: (task, protocol, body, signal) => {
              const route = routes.get(task.run);
              if (!route) throw new LocalError('local.model_unavailable');
              return communityModel(route, task, protocol, body, signal, async event => {
                const count = diagnosticCounts.get(task.run) ?? 0;
                if (count >= 64) return;
                diagnosticCounts.set(task.run, count + 1);
                const directory = join(stateRoot, 'model-diagnostics');
                await mkdir(directory, { recursive: true, mode: 0o700 });
                await appendFile(join(directory, task.run + '.jsonl'), JSON.stringify({ time: new Date().toISOString(), run: task.run, ...event }) + '\n', { mode: 0o600 });
              });
            },
          });
          const brokerURL = await broker.listen();
          const port = Number(new URL(brokerURL).port);
          tools.push(...localTools({ privateRoot: stateRoot, artifacts, brokerPort: port, runtimeReadRoots: [join(packageRoot, 'node_modules')], moduleRoot: join(packageRoot, 'node_modules') }),
            ...officeTools({ packageRoot, privateRoot: stateRoot, artifacts, brokerPort: port }));
          toolGuide = communityToolGuide(tools);
          const dsh = new DesktopEngine({ packageRoot, cacheRoot: join(stateRoot, 'engine'), brokerURL });
          const engine = new LocalEngineRouter(dsh, new CodexDesktopEngine({ packageRoot, cacheRoot: join(stateRoot, 'codex'), brokerURL }));
          supervisor = new LocalSupervisor({ identity, ledger, engine,
            validateLease: async task => !closing && task.loginSession === session && routes.has(task.run) && task.expiresAt > Date.now(),
            requireDeliveryDeclaration: true,
            verifyDeliverables: async run => {
              if (!run.controller.signal.aborted) await captureDeclaredDeliverables(run, file => tools.find(t => t.name === 'publish_artifact')!.call(run, { path: file.name, mime: file.mime }, run.controller.signal));
              await verifyLocalDeliverables(run, artifacts);
            },
            onEvent: event => {
              output({ type: 'event', ...event });
              if (['message.completed', 'message.failed', 'message.cancelled'].includes(event.frame.event)) {
                const task = ledger!.get(event.run)!.task;
                void Promise.all(supervisor!.get(event.run)!.artifacts.map(async meta => {
                  const snapshot = await artifacts.readForConversation({ tenant: task.tenant, account: task.account, conversation: task.conversation }, meta.local_artifact);
                  const outputRoot = join(stateRoot, 'outputs', event.run);
                  await mkdir(outputRoot, { recursive: true, mode: 0o700 });
                  const path = join(outputRoot, meta.name);
                  await writeFile(path, snapshot.bytes, { flag: 'wx', mode: 0o600 });
                  return { ...meta, path };
                }))
                  .then(files => output({ type: 'result', run: event.run, frame: event.frame, files }))
                  .catch(() => output({ type: 'result', run: event.run, frame: { event: 'message.failed', data: { error_message: '本地结果读取失败' } }, files: [] }));
                routes.delete(event.run);
                diagnosticCounts.delete(event.run);
              }
            },
            onApproval: approval => output({ type: 'approval', ...approval }),
          });
          clearTimeout(bootstrapTimeout);
          output({ type: 'ready', url: brokerURL, key: broker.appKey, engines: components.checks });
          return;
        }
        if (input['type'] === 'stop') { await shutdown(); return; }
        if (input['type'] !== 'submit') throw new LocalError('local.invalid_request');
        const request = z.object({ type: z.literal('submit'), id: z.string().uuid(), employee: z.string().uuid(), name: z.string().max(200), messageId: z.string().uuid(), engine: z.enum(['dsh', 'codex_app_server']), workspace: z.string().max(4096).optional(), mode: z.enum(['ask', 'assist', 'full']).default('assist'), confirmation: z.string().uuid().optional(), skillsDir: z.string().max(4096).optional(), model: z.string().min(1).max(1024), attachments: z.array(z.object({ name: z.string().min(1).max(255), path: z.string().max(4096), size: z.number().int().min(0).max(10 * 1024 * 1024), sha256: z.string().regex(/^[a-f0-9]{64}$/) }).strict()).max(5).default([]), message: z.string().min(1).max(150000), persona: z.string().max(200000), history: z.string().max(500000), route: modelRoute }).strict().parse(input);
        if (request.engine === 'codex_app_server' && request.route.protocol !== 'openai-compatible') throw new LocalError('local.model_protocol_mismatch');
        const task: LocalTask = { ...identity, run: request.id, employee: request.employee, conversation: request.employee, messageId: request.messageId, engine: request.engine, model: request.model, message: request.message, fence: 1, source: 'desktop', expiresAt: Date.now() + 900000 };
        const { selection } = await workspaces!.defaults(request.employee, request.employee, request.name);
        Object.assign(selection, await workspaces!.select({ ...selection, workspace: request.workspace ?? selection.workspace, mode: request.mode }, request.confirmation));
        let skillsDir: string | undefined;
        if (request.skillsDir) {
          const candidate = await realpath(request.skillsDir);
          // Flutter creates snapshots only below this employee's private runtime.
          const expected = join(communityStateRoot, 'skills');
          if (!isAbsolute(request.skillsDir) || candidate !== resolve(request.skillsDir) || dirname(candidate) !== expected) throw new LocalError('local.invalid_skills_path');
          skillsDir = candidate;
        }
        const attachmentGuide = await importCommunityAttachments(communityStateRoot, request.employee, selection.workspace, request.attachments);
        routes.set(task.run, request.route);
        try { await supervisor.accept(task, { ...selection, toolGuide, persona: request.persona + '\n\n' + toolGuide, prompt: [request.message, attachmentGuide].filter(Boolean).join('\n\n'), history: request.history, skillsDir, protocol: request.route.protocol }); }
        catch (error) { routes.delete(task.run); throw error; }
        output({ type: 'accepted', id: request.id, workspace: selection.workspace });
      } catch (error) { output({ type: 'error', id: requestID, code: error instanceof LocalError ? error.code : 'local.request_failed' }); }
    });
  });
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) void runCommunity().catch(() => { output({ type: 'error', code: 'local.helper_unavailable' }); process.exitCode = 1; });
