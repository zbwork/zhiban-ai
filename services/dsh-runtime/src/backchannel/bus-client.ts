/**
 * Bus 反向通道客户端（ZAP-1.0 §6 / ADR-0030）：
 * - `st_` 由本 runtime 用 runtime_access 凭据换发（`POST /api/external/v1/oauth/token`，grant_type=runtime_access，
 *   绑定 tenant + agent (+ account)），按作用域缓存到过期前 60s；Bus 不在开会话时下发，SDK 同款。
 * - 调 `/zap/v1/internal/*`，拆 Bus 标准信封 `{success, code, message, data}`。
 * - 凭据与 token 只存在于 shim 进程内；不进日志、不进 SSE、不下传 agent 进程。
 */

export interface BusClientOptions {
  baseUrl: string;
  clientId: string;
  clientSecret: string;
  /** 换发 TTL 请求值（秒）；Bus 可能夹紧 */
  ttlSeconds?: number;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  logger: { warn(obj: Record<string, unknown>, msg: string): void; info(obj: Record<string, unknown>, msg: string): void };
}

export interface TokenScope {
  tenant_id: string;
  agent_id: string;
  account_id?: string;
}

export class BusError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly httpStatus: number,
  ) {
    super(message);
    this.name = 'BusError';
  }
}

interface CachedToken {
  token: string;
  expiresAt: number;
}

const REFRESH_SKEW_MS = 60_000;

export class BusClient {
  private readonly tokens = new Map<string, CachedToken>();
  private readonly inflight = new Map<string, Promise<string>>();

  constructor(private readonly opts: BusClientOptions) {}

  get baseUrl(): string {
    return this.opts.baseUrl.replace(/\/+$/, '');
  }

  /** 取/换发该作用域的 st_（缓存命中直接返回；同作用域并发只换发一次）。 */
  async token(scope: TokenScope, now = Date.now()): Promise<string> {
    const key = `${scope.tenant_id}|${scope.agent_id}|${scope.account_id ?? ''}`;
    const cached = this.tokens.get(key);
    if (cached && cached.expiresAt - REFRESH_SKEW_MS > now) return cached.token;
    const pending = this.inflight.get(key);
    if (pending) return pending;
    const task = this.exchange(scope, key).finally(() => this.inflight.delete(key));
    this.inflight.set(key, task);
    return task;
  }

  private async exchange(scope: TokenScope, key: string): Promise<string> {
    const body: Record<string, unknown> = {
      grant_type: 'runtime_access',
      client_id: this.opts.clientId,
      client_secret: this.opts.clientSecret,
      tenant_id: scope.tenant_id,
      agent_id: scope.agent_id,
      ...(scope.account_id ? { account_id: scope.account_id } : {}),
      ...(this.opts.ttlSeconds ? { ttl_seconds: this.opts.ttlSeconds } : {}),
    };
    const res = await this.post('/api/external/v1/oauth/token', body);
    const data = unwrap(res.status, res.json);
    const token = typeof data['access_token'] === 'string' ? data['access_token'] : '';
    const expiresIn = Number(data['expires_in'] ?? 0);
    if (!token) throw new BusError('runtime_access.no_token', 'oauth/token returned no access_token', res.status);
    this.tokens.set(key, { token, expiresAt: Date.now() + Math.max(60, expiresIn || 3600) * 1000 });
    this.opts.logger.info({ tenant_id: scope.tenant_id, agent_id: scope.agent_id, expires_in: expiresIn }, 'runtime_access token exchanged');
    return token;
  }

  /** 调一个 backchannel 端点；401 时清缓存重试一次（token 被 Bus 侧吊销/过期）。 */
  async call(scope: TokenScope, path: string, body: Record<string, unknown>, method: 'POST' | 'GET' = 'POST'): Promise<unknown> {
    let token = await this.token(scope);
    let res = await this.post(path, body, token, method);
    if (res.status === 401) {
      this.tokens.delete(`${scope.tenant_id}|${scope.agent_id}|${scope.account_id ?? ''}`);
      token = await this.token(scope);
      res = await this.post(path, body, token, method);
    }
    return unwrap(res.status, res.json);
  }

  private async post(path: string, body: Record<string, unknown>, bearer?: string, method: 'POST' | 'GET' = 'POST'): Promise<{ status: number; json: unknown }> {
    const fetchImpl = this.opts.fetchImpl ?? fetch;
    const url = `${this.baseUrl}${path}`;
    const res = await fetchImpl(url, {
      method,
      headers: { 'content-type': 'application/json', accept: 'application/json', ...(bearer ? { authorization: `Bearer ${bearer}` } : {}) },
      ...(method === 'POST' ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(this.opts.timeoutMs ?? 30_000),
    });
    const text = await res.text();
    let json: unknown = {};
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { success: false, code: 'bad_json', message: text.slice(0, 200) };
    }
    return { status: res.status, json };
  }
}

/** Bus 信封：成功 `{success:true, data}`；失败 `{success:false, code, message}`（或 zap.* 错误 envelope `{error:{code,message}}`）。 */
export function unwrap(status: number, json: unknown): Record<string, unknown> {
  const o = (typeof json === 'object' && json !== null ? json : {}) as Record<string, unknown>;
  if (status >= 200 && status < 300 && o['success'] !== false) {
    if ('data' in o && typeof o['data'] === 'object' && o['data'] !== null) return o['data'] as Record<string, unknown>;
    if ('data' in o) return { value: o['data'] };
    return o;
  }
  const err = (typeof o['error'] === 'object' && o['error'] !== null ? o['error'] : o) as Record<string, unknown>;
  const code = typeof err['code'] === 'string' ? err['code'] : `http_${status}`;
  const message = typeof err['message'] === 'string' ? err['message'] : `bus call failed (${status})`;
  throw new BusError(code, message, status);
}
