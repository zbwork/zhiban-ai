/**
 * LLM 网关归一化代理（回环）：agent 子进程把 DEEPSEEK_BASE_URL 指到这里, 由本层转发到真正的
 * 公司 AIGC 网关, 并在流式响应上做协议归一化 (见 normalize.ts 的两处不兼容说明)。
 *
 * 设计要点:
 *   - **凭据经纪 (P1-c)**: 子进程 env 里**只有会话级假 key**, 真的账号级凭据从不出 shim 进程。
 *     本层校验假 key 后, 在转发时换成真 key。理由: agent 能出网 ⇒ 只要真 key 进了它的 env,
 *     它就能把该账号的网关渠道 key 发出去; 桌面端 Phase 5 (dsh sidecar 跑在用户机器上) 更是绝对不能下发。
 *     兼容: 会话没有假 key 时 (老会话/未配 per-account 凭据) 保持原样透传调用方自带的 Authorization。
 *   - **不改语义**: 只删 tool_calls 增量帧里值为 null 的 id/name, 并在缺失时补 [DONE]; 其余字节透传。
 *   - **逐帧转发**: 不缓冲整条响应, 首字延迟与直连一致。
 *   - **回环 only + 会话校验**: 与桥接同口径, 避免变成一个开放的网关代理。
 *   - 上游地址取自该会话的账号级凭据 (per-account base_url), 因此按 session 定址而非全局配置。
 */
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

import { bearerMatches } from '../server/auth.js';
import { SseNormalizer } from './normalize.js';

export interface LlmGatewayDeps {
  /**
   * 解析该会话的转发目标与凭据；返回 undefined = 该会话不可用（404）。
   * - `upstream`：上游 base（形如 http://gw/v1），取自该会话的 per-account 凭据。
   * - `sessionKey`：下发给子进程的**会话级假 key**。给了就强制校验，并在转发时换成 `apiKey`。
   * - `apiKey`：真凭据，只在本进程内存里，**不得写日志**。
   */
  brokerFor(sessionId: string): { upstream: string; sessionKey?: string; apiKey?: string } | undefined;
  /**
   * by-key 入口（员工自带模型服务的 pi-ai 路由用；装配文件按员工缓存、多会话共用，baseURL 里放不了 session_id）：
   * 按子进程出示的会话假 key 反查会话；返回 undefined = 401。
   */
  brokerForKey?(presentedKey: string): { sessionId: string; upstream: string; sessionKey: string; apiKey?: string } | undefined;
  log: { warn(obj: Record<string, unknown>, msg: string): void };
  /** 上游请求超时（ms）；默认与单轮上限同量级。 */
  timeoutMs?: number;
}

const isLoopback = (ip: string): boolean => ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';

/** 逐字节转发的响应头白名单：内容类型与流控相关的原样带上，其余由 fastify 生成。 */
const FORWARD_RESPONSE_HEADERS = ['content-type', 'cache-control', 'x-request-id', 'x-deepseek-request-id'];

/** anthropic-messages 协议要求的请求头，原样透传（不带凭据）。 */
const FORWARD_REQUEST_HEADERS = ['anthropic-version', 'anthropic-beta'];

/** 子进程出示的凭据：OpenAI 系走 Authorization: Bearer，anthropic-messages 走 x-api-key。 */
function presentedKey(req: FastifyRequest): { value: string; header: 'authorization' | 'x-api-key' } | undefined {
  const auth = req.headers['authorization'];
  if (typeof auth === 'string' && auth.trim()) return { value: auth.replace(/^Bearer\s+/i, '').trim(), header: 'authorization' };
  const xk = req.headers['x-api-key'];
  if (typeof xk === 'string' && xk.trim()) return { value: xk.trim(), header: 'x-api-key' };
  return undefined;
}

type Broker = { upstream: string; sessionKey?: string; apiKey?: string };

/**
 * 挂代理路由：ANY /llmgw/v1/:session_id/* → <该会话的上游 base>/*
 * SDK 会在 baseURL 后拼 `/chat/completions`，故子进程侧的 DEEPSEEK_BASE_URL 形如
 * http://127.0.0.1:<port>/llmgw/v1/<session_id>
 */
export function registerLlmGatewayRoutes(app: FastifyInstance, deps: LlmGatewayDeps): void {
  // by-key 必须先注册，否则会被 /:session_id/* 当成 session_id="by-key"。
  app.all('/llmgw/v1/by-key/*', async (req: FastifyRequest, reply: FastifyReply) => {
    if (!isLoopback(req.ip)) return reply.status(403).send({ error: { code: 'llmgw.forbidden', message: 'loopback only' } });
    const rest = (req.params as Record<string, string>)['*'] ?? '';
    const presented = presentedKey(req);
    const broker = presented && deps.brokerForKey ? deps.brokerForKey(presented.value) : undefined;
    if (!broker?.upstream) {
      deps.log.warn({}, 'llm gateway proxy by-key: unknown session key');
      return reply.status(401).send({ error: { code: 'llmgw.unauthorized', message: 'invalid session key' } });
    }
    return forward(req, reply, broker.sessionId, rest, broker, deps);
  });

  app.all('/llmgw/v1/:session_id/*', async (req: FastifyRequest, reply: FastifyReply) => {
    if (!isLoopback(req.ip)) return reply.status(403).send({ error: { code: 'llmgw.forbidden', message: 'loopback only' } });
    const { session_id: sid } = req.params as { session_id: string };
    const rest = (req.params as Record<string, string>)['*'] ?? '';
    const broker = deps.brokerFor(sid);
    if (!broker?.upstream) return reply.status(404).send({ error: { code: 'llmgw.unknown_session', message: 'unknown session' } });
    return forward(req, reply, sid, rest, broker, deps);
  });
}

async function forward(req: FastifyRequest, reply: FastifyReply, sid: string, rest: string, broker: Broker, deps: LlmGatewayDeps): Promise<FastifyReply> {
  const { upstream } = broker;
  // 假 key 校验 + 换真 key。常量时间比较，复用 server/auth.ts 的同一实现。
  // 校验失败按 401 而非 403：调用方是我们自己 spawn 的子进程，凭据不对说明它拿的是过期/伪造的 key。
  // 换 key 时保持子进程用的那种头（OpenAI 系 Bearer / anthropic x-api-key）。
  const presented = presentedKey(req);
  let credHeaders: Record<string, string> = {};
  if (broker.sessionKey) {
    if (!presented || !bearerMatches(`Bearer ${presented.value}`, broker.sessionKey)) {
      deps.log.warn({ session_id: sid }, 'llm gateway proxy rejected a request with a bad session key');
      return reply.status(401).send({ error: { code: 'llmgw.unauthorized', message: 'invalid session key' } });
    }
    if (broker.apiKey) credHeaders = presented.header === 'x-api-key' ? { 'x-api-key': broker.apiKey } : { authorization: `Bearer ${broker.apiKey}` };
  } else if (presented) {
    credHeaders = presented.header === 'x-api-key' ? { 'x-api-key': presented.value } : { authorization: `Bearer ${presented.value}` };
  }
  const passthrough: Record<string, string> = {};
  for (const h of FORWARD_REQUEST_HEADERS) {
    const v = req.headers[h];
    if (typeof v === 'string' && v) passthrough[h] = v;
  }
  const url = upstream.replace(/\/+$/, '') + '/' + rest.replace(/^\/+/, '');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? 15 * 60_000);
  try {
    const upstreamRes = await fetch(url, {
      method: req.method,
      headers: {
        ...credHeaders,
        ...passthrough,
        'content-type': String(req.headers['content-type'] ?? 'application/json'),
        ...(req.headers['accept'] ? { accept: String(req.headers['accept']) } : {}),
      },
      body: req.method === 'GET' || req.method === 'HEAD' ? undefined : JSON.stringify(req.body ?? {}),
      signal: controller.signal,
    });

    reply.status(upstreamRes.status);
    for (const h of FORWARD_RESPONSE_HEADERS) {
      const v = upstreamRes.headers.get(h);
      if (v) void reply.header(h, v);
    }

    const isStream = (upstreamRes.headers.get('content-type') ?? '').includes('text/event-stream');
    if (!isStream || !upstreamRes.body) {
      // 非流式（含错误响应）: 原样透传, 不解析不改写 —— 错误信息要让上游原话到达 SDK。
      return reply.send(Buffer.from(await upstreamRes.arrayBuffer()));
    }

    const normalizer = new SseNormalizer();
    const decoder = new TextDecoder();
    const reader = upstreamRes.body.getReader();
    void reply.raw.writeHead(upstreamRes.status, Object.fromEntries(FORWARD_RESPONSE_HEADERS.flatMap((h) => {
      const v = upstreamRes.headers.get(h);
      return v ? [[h, v] as [string, string]] : [];
    })));
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const out = normalizer.push(decoder.decode(value, { stream: true }));
      if (out) reply.raw.write(out);
    }
    const tail = normalizer.flush();
    if (tail) reply.raw.write(tail);
    reply.raw.end();
    return reply;
  } catch (err) {
    // 只在这里记一行；不含 URL 查询串与任何头部，避免凭据入日志。
    deps.log.warn({ session_id: sid, detail: err instanceof Error ? err.message : String(err) }, 'llm gateway proxy failed');
    if (!reply.sent) return reply.status(502).send({ error: { code: 'llmgw.upstream_error', message: 'llm gateway unreachable' } });
    reply.raw.end();
    return reply;
  } finally {
    clearTimeout(timer);
  }
}
