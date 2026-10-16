/**
 * 会话工具桥：agent 进程里的 MCP 小服务（assets/bridge/zhiban-mcp.mjs）→ 本 runtime 回环口 → Bus 反向通道。
 *
 * 安全面：
 * - 只接受回环地址（127.0.0.1 / ::1）+ 每会话随机 `X-Bridge-Key`；key 只能"以本会话身份调这几个工具"，
 *   与模型自己调工具等价——真正的凭据（runtime_access / st_）只在 shim 进程里（bus-client.ts）。
 * - 工具参数白名单映射到 Bus 端点；身份（tenant/agent/account）来自会话记录，不接受调用方传入。
 * - 返回给模型的是 Bus `data`；错误统一 `{ error: { code, message } }`，不含 endpoint/token。
 */
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { SessionRecord } from '../sessions/session-store.js';
import { BusError, type BusClient, type TokenScope } from './bus-client.js';

export interface ImageGenCredentials {
  base_url: string;
  api_key: string;
}

export interface BridgeDeps {
  bus: BusClient;
  sessions: { get(sessionId: string): SessionRecord | undefined };
  log: { warn(obj: Record<string, unknown>, msg: string): void; info(obj: Record<string, unknown>, msg: string): void };
  /** A2A invoke 轮询上限（ms） */
  a2aWaitMs?: number;
  /** 图片生成：该会话可用的网关凭据（per-account 优先，否则服务级）；无 = 工具不可用 */
  imageCredentials?: (rec: SessionRecord) => ImageGenCredentials | undefined;
  /** 图片落盘目标（会话工作区 outbox/images） */
  workspaceFor?: (rec: SessionRecord) => string;
  imageModel?: string;
  imageTimeoutMs?: number;
  /** memory_write 同步等待窗口（ms），缺省 MEMORY_WRITE_WAIT_MS；测试用来收窄 */
  memoryWriteWaitMs?: number;
  fetchImpl?: typeof fetch;
}

export const BRIDGE_TOOLS = ['kb_search', 'memory_recall', 'memory_write', 'a2a_discover', 'a2a_invoke', 'a2a_get_edge', 'a2a_cancel_edge', 'image_generate'] as const;

/** 平移 OpenClaw aigc-llm-image：seedream 4.5/5.0 要求像素下限，不够就抬到 2048x2048。 */
const MIN_PIXELS_BY_MODEL: Record<string, number> = { 'doubao-seedream-5-0-260128': 3_686_400, 'doubao-seedream-4-5-251128': 3_686_400 };
export function adjustImageSize(model: string, size: string | undefined): string {
  const s = size && /^\d{3,4}x\d{3,4}$/.test(size) ? size : '1024x1024';
  const min = MIN_PIXELS_BY_MODEL[model];
  if (!min) return s;
  const [w, h] = s.split('x').map((n) => Number(n));
  return (w ?? 0) * (h ?? 0) >= min ? s : '2048x2048';
}
export type BridgeTool = (typeof BRIDGE_TOOLS)[number];

export function newBridgeKey(): string {
  return randomBytes(24).toString('base64url');
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');
const int = (v: unknown): number | undefined => (Number.isInteger(Number(v)) && Number(v) > 0 ? Number(v) : undefined);
const strList = (v: unknown): string[] => (Array.isArray(v) ? v.map(str).filter((s) => s) : []);
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const errBrief = (e: unknown): string => (e instanceof BusError ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e));

/** memory_write 同步等待上限；超过则转后台并回 accepted（见 runBridgeTool 的注释）。 */
export const MEMORY_WRITE_WAIT_MS = 1500;

/**
 * 平台记忆作用域的**真实取值**（Bus `internal/service/memory/scope.go` 的 ScopeKind）。
 * 两条记忆路由都把字符串原样转成 ScopeKind，不做短名映射——此前本桥白名单写的
 * `user/agent/group` 在平台上根本不存在，传了等于给个非法 scope（2026-08-25 实测召回恒空）。
 */
export const MEMORY_SCOPES = ['user_long_term', 'agent_private', 'session', 'group_shared'];
/** 容忍模型/旧 MCP schema 用的短名，映射到真实取值。 */
const MEMORY_SCOPE_ALIASES: Record<string, string> = { user: 'user_long_term', agent: 'agent_private', group: 'group_shared' };

function scopeOf(rec: SessionRecord): TokenScope {
  return {
    tenant_id: rec.tenant_id,
    agent_id: rec.agent_id,
    ...(rec.session_kind !== 'a2a' && rec.user_id && rec.user_id !== 'a2a' ? { account_id: rec.user_id } : {}),
  };
}

/**
 * external 记忆路由要求的五维 ctx（tenant 由 token 取，其余本侧显式传）。
 * session_id 用 ZAP 会话 id：记忆的 session 维度与我们的会话一一对应，跨会话召回靠 user/agent 维度。
 */
function memoryCtxBody(rec: SessionRecord): { user_id: string; agent_id: string; session_id: string } {
  return { user_id: rec.user_id, agent_id: rec.agent_id ?? '', session_id: rec.session_id };
}

const isLoopback = (ip: string): boolean => ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';

/** 执行一个桥工具（纯映射，便于测试）。 */
export async function runBridgeTool(deps: BridgeDeps, rec: SessionRecord, tool: BridgeTool, args: Obj): Promise<unknown> {
  const scope = scopeOf(rec);
  switch (tool) {
    case 'kb_search': {
      const query = str(args['query']);
      if (!query) throw new BusError('invalid_params', 'query required', 400);
      // 走 external 的 agent 绑定检索路由（按 st_ 的 agent 绑定预校验，不要求 conversation 绑定）；
      // /zap/v1/internal/tools/zhiban.kb.search 要求 st_ 绑定 conversation，runtime_access 换的 token 没有（本机联调实锤 403）。
      // 该路由 DisallowUnknownFields：只收 agent_id + query（top_k/continuation_token 传了直接 400）。
      return deps.bus.call(scope, '/api/external/v1/knowledge/retrieve', { agent_id: rec.agent_id, query });
    }
    case 'memory_recall': {
      const query = str(args['query']);
      if (!query) throw new BusError('invalid_params', 'query required', 400);
      const scopes = strList(args['scopes'])
        .map((s) => MEMORY_SCOPE_ALIASES[s] ?? s)
        .filter((s) => MEMORY_SCOPES.includes(s));
      // 与 kb_search 同理走 external 路由: /zap/v1/internal/tools/zhiban.memory.* 要求 st_ 绑定 conversation,
      // 而 runtime_access 换的 token 没有该绑定 → 401 memory session context incomplete (2026-08-25 实锤)。
      // external 路由按 memory.read/write scope 授权(反向通道凭据已含), 五维 ctx 由本侧显式传, 不需要 conversation。
      return deps.bus.call(scope, '/api/external/v1/memories/recall', {
        ...memoryCtxBody(rec),
        query,
        ...(scopes.length > 0 ? { scopes } : {}),
        ...(int(args['limit']) ? { limit: int(args['limit']) } : {}),
      });
    }
    case 'memory_write': {
      const content = str(args['content']);
      if (!content) throw new BusError('invalid_params', 'content required', 400);
      // 同 memory_recall: 走 external 路由避开 conversation 绑定要求。external 侧只收 content(无 role 字段),
      // 角色语义由记忆中台按内容处理。
      //
      // 写入是"短等窗口 + 超窗转后台"(见 MEMORY_WRITE_WAIT_MS)：记忆中台摄取是同步 LLM 抽取，
      // 实测 329ms~8.2s 剧烈抖动、偶发超时返 500 **但数据已落库**（2026-08-25 测试环境实测）。
      // 同步等到底会把一轮对话卡住 8 秒，且假失败会诱发模型重写 → 重复记忆。
      // 参数/权限类错误(4xx)几十毫秒内就返回，落在窗口内照常抛给模型。
      // 内部 ZAP 路由(internal_tools.go)对同一工具干脆整个异步只记日志，这里取其折中。
      const write = deps.bus
        .call(scope, '/api/external/v1/memories/events', { ...memoryCtxBody(rec), content })
        .then((v) => ({ ok: true as const, value: v }))
        .catch((e: unknown) => ({ ok: false as const, error: e }));
      const raced = await Promise.race([write, sleep(deps.memoryWriteWaitMs ?? MEMORY_WRITE_WAIT_MS).then(() => undefined)]);
      if (raced === undefined) {
        // 超窗：后台继续，失败只进日志（不骗模型说失败——它多半会成功）
        void write.then((r) => {
          if (!r.ok) deps.log.warn({ session_id: rec.session_id, err: errBrief(r.error) }, 'bridge memory_write failed after handoff');
        });
        return { accepted: true, pending: true };
      }
      if (!raced.ok) throw raced.error;
      return raced.value;
    }
    case 'a2a_discover': {
      const tags = strList(args['tags']);
      const mode = str(args['mode']);
      return deps.bus.call(scope, '/zap/v1/internal/a2a/discover', {
        ...(str(args['query']) ? { query: str(args['query']) } : {}),
        ...(tags.length > 0 ? { tags } : {}),
        ...(mode === 'sync' || mode === 'async' ? { mode } : {}),
        ...(int(args['limit']) ? { limit: Math.min(50, int(args['limit']) as number) } : {}),
        ...(str(args['cursor']) ? { cursor: str(args['cursor']) } : {}),
      });
    }
    case 'a2a_invoke': {
      const to = str(args['to_agent_id']);
      const userText = str(args['user_text']);
      if (!to || !userText) throw new BusError('invalid_params', 'to_agent_id and user_text required', 400);
      const ack = obj(
        await deps.bus.call(scope, '/zap/v1/internal/a2a/invoke', {
          to_agent_id: to,
          request_payload: { user_text: userText },
          ...(str(args['idempotency_key']) ? { idempotency_key: str(args['idempotency_key']) } : {}),
        }),
      );
      const edgeId = str(ack['edge_id']);
      const createdAt = str(ack['edge_created_at']);
      if (!edgeId || isTerminal(str(ack['status']))) return ack;
      // 轮询到终态（sync 60s 上限，§12.2）；未终态按进行中返回，模型可稍后再查
      const deadline = Date.now() + (deps.a2aWaitMs ?? 60_000);
      let edge: Obj = ack;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 1500));
        edge = obj(await deps.bus.call(scope, `/zap/v1/internal/a2a/edges/${encodeURIComponent(edgeId)}?created_at=${encodeURIComponent(createdAt)}`, {}, 'GET'));
        if (isTerminal(str(edge['status']))) break;
      }
      return { edge_id: edgeId, status: edge['status'] ?? 'pending', response_payload: edge['response_payload'] ?? null, tokens_out: edge['tokens_out'] ?? null };
    }
    case 'a2a_get_edge': {
      const edgeId = str(args['edge_id']);
      if (!edgeId) throw new BusError('invalid_params', 'edge_id required', 400);
      // 查询之前 a2a_invoke 派出去的任务当前状态/结果（进行中 → 稍后可再查）
      return deps.bus.call(scope, `/zap/v1/internal/a2a/edges/${encodeURIComponent(edgeId)}`, {}, 'GET');
    }
    case 'a2a_cancel_edge': {
      const edgeId = str(args['edge_id']);
      if (!edgeId) throw new BusError('invalid_params', 'edge_id required', 400);
      const reason = str(args['reason']);
      return deps.bus.call(scope, `/zap/v1/internal/a2a/edges/${encodeURIComponent(edgeId)}/cancel`, reason ? { reason } : {});
    }
    case 'image_generate': {
      const prompt = str(args['prompt']);
      if (!prompt) throw new BusError('invalid_params', 'prompt required', 400);
      const creds = deps.imageCredentials?.(rec);
      const workspace = deps.workspaceFor?.(rec);
      if (!creds || !workspace) throw new BusError('image.unavailable', 'image generation is not configured for this session', 503);
      const model = str(args['model']) || deps.imageModel || 'doubao-seedream-4-0-250828';
      const size = adjustImageSize(model, str(args['size']) || undefined);
      const n = Math.min(4, int(args['n']) ?? 1);
      const fetchImpl = deps.fetchImpl ?? fetch;
      const res = await fetchImpl(`${creds.base_url.replace(/\/+$/, '')}/images/generations`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${creds.api_key}` },
        body: JSON.stringify({ model, prompt, size, n, response_format: 'b64_json' }),
        signal: AbortSignal.timeout(deps.imageTimeoutMs ?? 360_000),
      });
      const text = await res.text();
      if (!res.ok) throw new BusError('image.upstream_error', `image gateway HTTP ${res.status}: ${text.slice(0, 160)}`, 502);
      let data: unknown[] = [];
      try {
        data = ((JSON.parse(text) as { data?: unknown[] }).data ?? []) as unknown[];
      } catch {
        throw new BusError('image.bad_response', 'image gateway returned invalid JSON', 502);
      }
      const dir = join(workspace, 'outbox', 'images');
      await mkdir(dir, { recursive: true });
      const stamp = Date.now().toString(36);
      const files: string[] = [];
      for (const [i, item] of data.entries()) {
        const o = obj(item);
        const b64 = str(o['b64_json']);
        if (!b64) continue;
        const name = `img-${stamp}-${i + 1}.png`;
        await writeFile(join(dir, name), Buffer.from(b64, 'base64'));
        files.push(join('outbox', 'images', name));
      }
      if (files.length === 0) throw new BusError('image.empty', 'image gateway returned no image data', 502);
      return { model, size, files, note: '图片已写入工作目录 outbox/images/，本轮结束会自动作为附件发给用户；回复里用 ![](<outbox/images/…>) 引用即可。' };
    }
    default:
      throw new BusError('unknown_tool', `unknown tool ${String(tool)}`, 404);
  }
}

function isTerminal(status: string): boolean {
  // Bus a2a_call_edges 终态实测为 done；其余按 ADR-0030/§12 词表
  return ['done', 'completed', 'failed', 'cancelled', 'rejected', 'timeout', 'dropped_loop', 'dropped_budget', 'dropped_whitelist'].some((s) => status.startsWith(s));
}

/** 挂回环桥路由：POST /bridge/v1/:session_id/:tool（X-Bridge-Key）。 */
export function registerBridgeRoutes(app: FastifyInstance, deps: BridgeDeps): void {
  app.post('/bridge/v1/:session_id/:tool', async (req: FastifyRequest, reply: FastifyReply) => {
    if (!isLoopback(req.ip)) return reply.status(403).send({ error: { code: 'bridge.forbidden', message: 'loopback only' } });
    const { session_id: sid, tool } = req.params as { session_id: string; tool: string };
    const key = str(req.headers['x-bridge-key']);
    const rec = deps.sessions.get(sid);
    if (!rec || !rec.bridgeKey || !key || key !== rec.bridgeKey) return reply.status(401).send({ error: { code: 'bridge.unauthorized', message: 'invalid bridge key' } });
    if (!(BRIDGE_TOOLS as readonly string[]).includes(tool)) return reply.status(404).send({ error: { code: 'bridge.unknown_tool', message: `unknown tool ${tool}` } });
    try {
      const result = await runBridgeTool(deps, rec, tool as BridgeTool, obj(req.body));
      deps.log.info({ session_id: sid, tool }, 'bridge tool call ok');
      return { result };
    } catch (err) {
      if (err instanceof BusError) {
        deps.log.warn({ session_id: sid, tool, code: err.code, status: err.httpStatus, detail: err.message.slice(0, 200) }, 'bridge tool call failed');
        return reply.status(err.httpStatus >= 400 && err.httpStatus < 600 ? err.httpStatus : 502).send({ error: { code: err.code, message: err.message } });
      }
      deps.log.warn({ session_id: sid, tool, detail: err instanceof Error ? err.message : String(err) }, 'bridge tool call errored');
      return reply.status(502).send({ error: { code: 'bridge.upstream_error', message: 'platform tool unavailable' } });
    }
  });
}
