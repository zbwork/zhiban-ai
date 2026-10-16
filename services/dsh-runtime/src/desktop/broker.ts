import { observeModelResponse } from './model-response.js';
import { normalizeResponsesTools } from './responses-tools.js';
import { modelFailure, readModelFailure } from './model-error.js';
import { randomBytes } from 'node:crypto';
import type { SaveImageAttachment } from '@deepseek-ai/dsh-attachment';
import { readFileSync } from 'node:fs';
import { Readable } from 'node:stream';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { CallToolRequestSchema, ListToolsRequestSchema, type CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import Fastify, { type FastifyInstance } from 'fastify';
import { z } from 'zod';
import { bearerMatches } from '../server/auth.js';
import { fingerprint, LocalError, type LocalTask } from './ledger.js';
import type { ActiveLocalRun, LocalSupervisor } from './supervisor.js';
import type { Operation } from './policy.js';
import type { LocalWorkspaces } from './workspaces.js';
import type { ArtifactRef, ArtifactMeta } from './artifacts.js';

const toolErrors = JSON.parse(readFileSync(new URL('../../assets/bridge/local-tool-errors.json', import.meta.url), 'utf8')) as Record<string, string>;

/** Report schema constraints, never user-controlled values or dynamic record keys. */
export function toolArgumentIssues(error: z.ZodError, schema: Record<string, unknown>): string {
  const properties = schema['properties'] as Record<string, unknown> | undefined;
  return error.issues.slice(0, 6).map(issue => {
    const key = issue.path[0];
    const field = typeof key === 'string' && properties && Object.hasOwn(properties, key) ? key : 'arguments';
    if (issue.code === 'too_big' || issue.code === 'too_small') {
      const bound = issue.code === 'too_big' ? issue.maximum : issue.minimum;
      return `${field}: ${issue.code}${typeof bound === 'number' ? ` (${issue.code === 'too_big' ? 'maximum' : 'minimum'}=${bound})` : ''}`;
    }
    return `${field}: ${issue.code}`;
  }).join('; ');
}
const stableJson = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${stableJson((value as Record<string, unknown>)[key])}`).join(',')}}`;
  return JSON.stringify(value);
};

export interface DesktopTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  schema: z.ZodType<Record<string, unknown>>;
  operation: Operation;
  isError?(result: unknown): boolean;
  content?(result: unknown): CallToolResult['content'];
  call(run: ActiveLocalRun, args: Record<string, unknown>, signal: AbortSignal): Promise<unknown>;
}

export interface BrokerOptions {
  saveImageAttachment?(task: LocalTask, input: SaveImageAttachment, signal: AbortSignal): Promise<unknown>;
  decideApproval?(run: ActiveLocalRun, id: string, revision: number, approved: boolean, scope: 'once' | 'task'): Promise<void>;
  supervisor(): LocalSupervisor;
  tools: DesktopTool[];
  workspaces?: LocalWorkspaces;
  originalArtifact?(conversation: string, ref: ArtifactRef): Promise<string>;
  readArtifact?(conversation: string, ref: ArtifactRef): Promise<{ meta: ArtifactMeta; bytes: Buffer }>;
  /** Implemented by the Bus client. URL/credentials/source are not caller controlled. */
  model(task: LocalTask, protocol: 'chat/completions' | 'messages' | 'responses', body: Record<string, unknown>, signal: AbortSignal): Promise<Response>;
}

/** Random loopback port; separate App and worker credentials. No browser origins or arbitrary proxy URLs. */
export class DesktopBroker {
  readonly appKey = randomBytes(32).toString('base64url');
  private readonly app: FastifyInstance;
  private readonly imageBudgets = new WeakMap<ActiveLocalRun, { count: number; bytes: number }>();
  private readonly repeatedCalls = new Map<string, { key: string; count: number }>();
  private readonly toolFailures = new WeakMap<ActiveLocalRun, { key: string; count: number }>();

  constructor(private readonly opts: BrokerOptions) {
    this.app = Fastify({ logger: false, bodyLimit: 8 * 1024 * 1024 });
    const names = new Set(opts.tools.map((tool) => tool.name));
    if (names.size !== opts.tools.length) throw new LocalError('local.duplicate_tool');
    this.app.addHook('onRequest', async (req, reply) => {
      if (req.ip !== '127.0.0.1' || req.headers.origin !== undefined || !/^127\.0\.0\.1:\d+$/.test(req.headers.host ?? '')) return reply.code(403).send({ error: 'local.loopback_only' });
    });
    this.app.setErrorHandler((err, _req, reply) => {
      const code = err instanceof LocalError ? err.code : 'local.request_failed';
      return reply.code(err instanceof z.ZodError ? 400 : err instanceof LocalError ? 403 : 500).send({ error: { code, message: '本机操作未完成，请检查授权和设备状态。' } });
    });
    const authorize = async (header: string | undefined): Promise<ActiveLocalRun> => {
      if (!header?.startsWith('Bearer ')) throw new LocalError('local.unauthorized');
      return opts.supervisor().authorize(header.slice(7));
    };
    this.app.post('/worker/attachments/image', async (req) => {
      const run = await authorize(req.headers.authorization);
      if (!opts.saveImageAttachment) throw new LocalError('local.tool_unavailable');
      const input = z.object({ mediaType: z.enum(['image/png', 'image/jpeg', 'image/webp', 'image/gif']),
        data: z.string().max(2_000_000).regex(/^[A-Za-z0-9+/]+=*$/), name: z.string().max(200).optional(),
      }).strict().parse(req.body);
      const data = Buffer.from(input.data, 'base64');
      if (data.toString('base64') !== input.data || data.length > 1_500_000) throw new LocalError('local.invalid_attachment');
      const budget = this.imageBudgets.get(run) ?? { count: 0, bytes: 0 };
      if (++budget.count > 50 || (budget.bytes += data.length) > 32 * 1024 * 1024) throw new LocalError('local.attachment_limit');
      this.imageBudgets.set(run, budget);
      return opts.saveImageAttachment(run.task, { ...input, data }, run.controller.signal);
    });
    const listTools = () => ({ tools: opts.tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
    this.app.post('/worker/tools/list', async (req) => {
      await authorize(req.headers.authorization);
      return listTools();
    });
    const executeTool = async (run: ActiveLocalRun, body: unknown): Promise<CallToolResult> => {
      const input = z.object({ name: z.string(), arguments: z.record(z.string(), z.unknown()) }).strict().parse(body);
      const tool = opts.tools.find((entry) => entry.name === input.name);
      if (!tool) throw new LocalError('local.tool_unavailable');
      const parsed = tool.schema.safeParse(input.arguments);
      if (!parsed.success) return { content: [{ type: 'text', text: tool.name === 'office_create'
        ? 'local.invalid_tool_arguments: Office 参数无效，尚未进入审批，未写入文件。生成 Word 必须传 kind="docx"、相对文件名 path、标题 title 和正文段落数组 paragraphs；请补齐参数后重新调用。'
        : `local.invalid_tool_arguments: ${toolArgumentIssues(parsed.error, tool.inputSchema)}。尚未进入审批或执行，请修正这些字段后重试。` }], isError: true };
      const args = parsed.data;
      if (['write', 'overwrite', 'shell'].includes(tool.operation)) run.attemptedFileDelivery = true;
      if (tool.name === 'office_create') run.attemptedOfficeCreation = true;
      if (input.name === 'list_files') {
        const callKey = `${input.name}:${stableJson(args)}`;
        const previous = this.repeatedCalls.get(run.task.run);
        const count = previous?.key === callKey ? previous.count + 1 : 1;
        this.repeatedCalls.set(run.task.run, { key: callKey, count });
        if (count >= 6) return { isError: true, content: [{ type: 'text', text: 'local.repeated_tool_call: 相同文件列表查询已连续调用多次且没有新信息。请停止重复探测，改用不同路径或继续执行下一步。' }] };
      }
      const result = await run.policy.execute({ tool: tool.name, operation: tool.operation, args }, (signal) => tool.call(run, args, signal), run.controller.signal);
      return { content: tool.content?.(result) ?? [{ type: 'text', text: JSON.stringify(result) }], isError: tool.isError?.(result) ?? false };
    };
    const callTool = async (run: ActiveLocalRun, body: unknown): Promise<CallToolResult> => {
      const key = fingerprint(body);
      const recordFailure = () => {
        if (run.controller.signal.aborted) return;
        const previous = this.toolFailures.get(run);
        const count = previous?.key === key ? previous.count + 1 : 1;
        this.toolFailures.set(run, { key, count });
        if (count >= 3) run.controller.abort(new LocalError('local.repeated_tool_failure'));
      };
      try {
        const result = await executeTool(run, body);
        if (result.isError) recordFailure(); else this.toolFailures.delete(run);
        return result;
      } catch (error) { recordFailure(); throw error; }
    };
    this.app.post('/worker/tools/call', async (req) => callTool(await authorize(req.headers.authorization), req.body));
    this.app.route({ method: ['POST', 'GET', 'DELETE'], url: '/worker/mcp', handler: async (req, reply) => {
      let run: ActiveLocalRun;
      try { run = await authorize(req.headers.authorization); }
      catch (error) {
        if (!req.headers.authorization?.startsWith('Bearer ')) throw error;
        const code = error instanceof LocalError && Object.hasOwn(toolErrors, error.code) ? toolErrors[error.code] : '本机工具授权已失效，请重新连接设备后重试。';
        return reply.code(403).send({ jsonrpc: '2.0', id: (req.body as Record<string, unknown> | undefined)?.id ?? null, error: { code: -32001, message: code } });
      }
      // Stateless official MCP transport: every request revalidates the run capability.
      // The AppContainer reaches this same broker through its fixed-port named pipe.
      if (req.method !== 'POST') return reply.code(405).header('allow', 'POST').send();
      const server = new Server({ name: 'zhiban-local', version: '1.0.0' }, { capabilities: { tools: {} } });
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      server.setRequestHandler(ListToolsRequestSchema, async () => listTools());
      server.setRequestHandler(CallToolRequestSchema, async (request) => {
        try { return await callTool(run, { name: request.params.name, arguments: request.params.arguments ?? {} }); }
        catch (error) {
          const message = error instanceof LocalError && Object.hasOwn(toolErrors, error.code) ? toolErrors[error.code] : undefined;
          return { isError: true, content: [{ type: 'text', text: message ?? '本机工具调用未完成，原因未确认；不能据此断言用户拒绝批准或文件已生成。' }] };
        }
      });
      await server.connect(transport);
      reply.hijack();
      // handleRequest can return before a long-running tool produces its response.
      reply.raw.once('close', () => { void server.close().catch(() => {}); });
      await transport.handleRequest(req.raw, reply.raw, req.body);
    } });
    for (const [path, protocol] of [['responses', 'responses'], ['chat/completions', 'chat/completions'], ['messages', 'messages'], ['v1/messages', 'messages']] as const) {
      this.app.post(`/llmgw/v1/by-key/${path}`, async (req, reply) => {
        const presented = req.headers.authorization ?? (typeof req.headers['x-api-key'] === 'string' ? `Bearer ${req.headers['x-api-key']}` : undefined);
        const run = await authorize(presented);
        if (protocol === 'responses' && run.task.engine !== 'codex_app_server') throw new LocalError('local.model_protocol_mismatch');
        if ((protocol === 'messages') !== (run.config.protocol === 'anthropic-messages')) throw new LocalError('local.model_protocol_mismatch');
        const body = z.record(z.string(), z.unknown()).parse(req.body);
        if (body['model'] !== run.task.model) throw new LocalError('local.model_mismatch');
        const controller = new AbortController();
        const disconnected = () => controller.abort();
        reply.raw.once('close', disconnected);
        const signal = AbortSignal.any([run.controller.signal, controller.signal]);
        const sequence = run.modelRequestSequence = (run.modelRequestSequence ?? 0) + 1;
        run.modelFailure = undefined;
        run.modelResponseFailed = false;
        try {
          const upstream = await opts.model(run.task, protocol, body, signal);
          const response = protocol === 'responses' && upstream.ok ? normalizeResponsesTools(upstream, body['tools']) : upstream;
          if (!response.ok || !response.body) {
            const failure = await readModelFailure(response, signal);
            if (run.modelRequestSequence === sequence && !signal.aborted) {
              run.modelFailure = failure;
              run.modelResponseFailed = false;
            }
            reply.raw.off('close', disconnected);
            return reply.code(response.status >= 400 ? response.status : 502).send({ error: failure });
          }
          reply.code(response.status).header('content-type', response.headers.get('content-type') ?? 'application/json');
          const stream = Readable.from(observeModelResponse(response, protocol, signal, (failure) => {
            if (run.modelRequestSequence !== sequence || signal.aborted) return;
            run.modelFailure = failure;
            run.modelResponseFailed = failure !== undefined;
          }), { signal });
          stream.once('close', () => reply.raw.off('close', disconnected));
          return reply.send(stream);
        } catch {
          reply.raw.off('close', disconnected);
          const failure = modelFailure('model.connection_failed');
          if (run.modelRequestSequence === sequence && !signal.aborted) {
            run.modelFailure = failure;
            run.modelResponseFailed = false;
          }
          return reply.code(502).send({ error: failure });
        }
      });
    }
    this.app.addHook('preHandler', async (req, reply) => {
      if (req.url.startsWith('/app/') && !bearerMatches(req.headers.authorization, this.appKey)) return reply.code(401).send({ error: 'local.unauthorized' });
    });
    this.app.post('/app/artifacts/read', async (req, reply) => {
      const input = z.object({ conversation: z.string().uuid(), artifact_id: z.string().uuid(), device_id: z.string().uuid(), sha256: z.string().regex(/^[0-9a-f]{64}$/) }).strict().parse(req.body);
      if (!opts.readArtifact) throw new LocalError('local.artifact_unavailable');
      const { conversation, ...ref } = input;
      const result = await opts.readArtifact(conversation, ref);
      return reply.header('content-type', 'application/octet-stream').header('cache-control', 'no-store').send(result.bytes);
    });
    this.app.post('/app/artifacts/original', async (req) => {
      const { conversation, ...ref } = z.object({ conversation: z.string().uuid(), artifact_id: z.string().uuid(), device_id: z.string().uuid(), sha256: z.string().regex(/^[0-9a-f]{64}$/) }).strict().parse(req.body);
      if (!opts.originalArtifact) throw new LocalError('local.artifact_unavailable');
      return { path: await opts.originalArtifact(conversation, ref) };
    });
    this.app.post('/app/workspaces/create', async (req) => {
      const input = z.object({ parent: z.string(), name: z.string() }).strict().parse(req.body);
      if (!opts.workspaces) throw new LocalError('local.workspace_unavailable');
      return { workspace: await opts.workspaces.create(input.parent, input.name) };
    });
    this.app.post('/app/workspaces/default', async (req) => {
      const input = z.object({ employee: z.string(), conversation: z.string(), name: z.string().max(200) }).strict().parse(req.body);
      if (!opts.workspaces) throw new LocalError('local.workspace_unavailable');
      return opts.workspaces.defaults(input.employee, input.conversation, input.name);
    });
    this.app.post('/app/workspaces/full-confirmation', async (req) => {
      const input = z.object({ conversation: z.string().max(128) }).strict().parse(req.body);
      if (!opts.workspaces) throw new LocalError('local.workspace_unavailable');
      return opts.workspaces.confirmFull(input.conversation);
    });
    this.app.post('/app/workspaces/select', async (req) => {
      const input = z.object({ employee: z.string(), conversation: z.string(), workspace: z.string(), mode: z.enum(['ask', 'assist', 'full']), confirmation: z.string().optional() }).strict().parse(req.body);
      if (!opts.workspaces) throw new LocalError('local.workspace_unavailable');
      const { confirmation, ...choice } = input;
      const selected = await opts.workspaces.select(choice, confirmation);
      // Revocation takes effect on running tools immediately; workspace/model still change next turn.
      if (selected.mode !== 'full') for (const run of opts.supervisor().runs()) {
        if (run.config.contextID === selected.conversation || run.task.conversation === selected.conversation) run.policy.setMode(selected.mode);
      }
      return selected;
    });
    this.app.post('/app/runs/:run/full-confirmation', async (req) => {
      const { run } = z.object({ run: z.string() }).parse(req.params);
      const active = opts.supervisor().get(run);
      if (!active) throw new LocalError('local.run_not_found');
      return { ...active.policy.requestFull(), message: '允许该任务访问更广的本机文件、执行命令及联网操作。上传产物仍需单独确认。' };
    });
    this.app.post('/app/runs/:run/policy', async (req) => {
      const { run } = z.object({ run: z.string() }).parse(req.params);
      const input = z.object({ mode: z.enum(['ask', 'assist', 'full']), confirmation: z.string().optional() }).strict().parse(req.body);
      const active = opts.supervisor().get(run);
      if (!active) throw new LocalError('local.run_not_found');
      active.policy.setMode(input.mode, input.confirmation);
      return { mode: active.policy.mode, revision: active.policy.version };
    });
    this.app.post('/app/runs/:run/approvals/:id', async (req) => {
      const { run, id } = z.object({ run: z.string(), id: z.string() }).parse(req.params);
      const input = z.object({ revision: z.number().int().positive(), approved: z.boolean(), scope: z.enum(['once', 'task']).default('once') }).strict().parse(req.body);
      const active = opts.supervisor().get(run);
      if (!active) throw new LocalError('local.run_not_found');
      if (opts.decideApproval) await opts.decideApproval(active, id, input.revision, input.approved, input.scope);
      else active.policy.approve(id, input.revision, input.approved, input.scope);
      return { ok: true };
    });
    this.app.post('/app/runs/:run/cancel', async (req) => {
      const { run } = z.object({ run: z.string() }).parse(req.params);
      const { fence } = z.object({ fence: z.number().int().positive() }).strict().parse(req.body);
      await opts.supervisor().cancel(run, fence);
      return { ok: true };
    });
    // Q5: a workspace whose stop could not be verified stays locked until the user says to continue.
    this.app.post('/app/workspaces/stop-locks', async () => ({ locks: opts.supervisor().stopLockList() }));
    this.app.post('/app/workspaces/clear-stop-lock', async (req) => {
      const { workspace } = z.object({ workspace: z.string().min(1).max(4096) }).strict().parse(req.body);
      opts.supervisor().clearStopLock(workspace);
      return { ok: true };
    });
  }

  async listen(): Promise<string> { return this.app.listen({ host: '127.0.0.1', port: 0 }); }
  async close(): Promise<void> { await this.app.close(); }
}
