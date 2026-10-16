/**
 * identity / instances 实现（方案 §C identity/）：收身份、回 ok + runtime_identity；
 * 并保存 Bus 随 /instances 下发的 per-account LLM 凭据（ADR-0021 account_llm_credentials）。
 *
 * 本 runtime 的“本地身份” = 平台稳定 UUID 原样（不做二次映射），agent_instance_id = tenant/user/agent 三元组。
 * 凭据按 **(租户, 账号)** 存（计费归属是账号级，不是员工级），供 spawn 时注入进程 env → 该账号的
 * 模型调用走自己的网关 key。**凭据只在内存、绝不日志/绝不回显**（安全口径同 Bus chat.go）。
 * `scope=agent`（员工自带模型服务，ADR-0037 dsh 消费端）的凭据按 **(租户, 账号, 员工)** 实例存，绝不写进账号级。
 */
export interface RuntimeIdentity {
  tenant_id: string;
  user_id: string;
  agent_instance_id?: string;
  mapping_status: 'matched';
}

/** per-account 模型网关凭据（不落盘、不日志）。 */
export interface AccountLLMCredentials {
  base_url?: string;
  api_key: string;
  model?: string;
  source?: string;
  scope?: string;
}

export type UserStatus = 'active' | 'suspended' | 'deactivated';

/** §10.5 平台用户身份事实（只存展示/联系/主体字段，本地 user_id = 平台 user_id 原样） */
export interface UserRecord {
  tenant_id: string;
  user_id: string;
  status: UserStatus;
  profile: Record<string, unknown>;
  identity: Record<string, unknown>;
  updated_at: number;
}

export interface InstanceRecord {
  tenant_id: string;
  user_id: string;
  agent_key: string;
  agent_id: string;
  external_environment_id?: string;
  has_llm_credentials: boolean;
  initialized_at: number;
}

function str(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

export function agentInstanceId(tenantId: string, userId: string, agentRef: string): string {
  return `${tenantId}/${userId}/${agentRef || '-'}`;
}

/** 凭据/身份索引键：账号级（租户+账号），与 account_llm_credentials 粒度一致。 */
function acctKey(tenantId: string, userId: string): string {
  return `${tenantId}\u0000${userId}`;
}

export class IdentityRegistry {
  private readonly instances = new Map<string, InstanceRecord>();
  private readonly tenants = new Map<string, Record<string, unknown>>();
  private readonly creds = new Map<string, AccountLLMCredentials>();
  /** scope=agent（员工自带模型服务, ADR-0037 dsh 消费端）：按员工实例存，绝不写进账号级 map */
  private readonly agentCreds = new Map<string, AccountLLMCredentials>();
  private readonly users = new Map<string, UserRecord>();

  /** POST /zap/v1/instances（= 旧 /identity/provision）。返回 null 表示缺必填身份字段。 */
  initialize(raw: Record<string, unknown>): { identity: RuntimeIdentity; record: InstanceRecord } | null {
    const tenant = (raw['tenant'] ?? {}) as Record<string, unknown>;
    const user = (raw['user'] ?? {}) as Record<string, unknown>;
    const agent = (raw['agent'] ?? {}) as Record<string, unknown>;
    const tenantId = str(tenant['tenant_id']) || str(raw['tenant_id']);
    const userId = str(user['user_id']) || str(raw['user_id']);
    if (!tenantId || !userId) return null;
    const agentKey = str(agent['agent_key']);
    const agentId = str(agent['agent_id']);
    const metadata = (raw['metadata'] ?? {}) as Record<string, unknown>;
    const env = (metadata['runtime_environment'] ?? {}) as Record<string, unknown>;
    const parsedCreds = parseCredentials(raw['llm']);
    const agentRef = agentKey || agentId;
    const instanceId = agentInstanceId(tenantId, userId, agentRef);
    if (parsedCreds?.scope === 'agent') {
      // 员工自带模型服务的 key 只归这个员工实例；没有员工引用就丢弃，绝不落到账号级
      if (agentRef) this.agentCreds.set(instanceId, parsedCreds);
    } else if (parsedCreds) {
      this.creds.set(acctKey(tenantId, userId), parsedCreds);
    }
    const record: InstanceRecord = {
      tenant_id: tenantId,
      user_id: userId,
      agent_key: agentKey,
      agent_id: agentId,
      ...(str(env['external_id']) ? { external_environment_id: str(env['external_id']) } : {}),
      has_llm_credentials: this.credentialsFor(tenantId, userId, agentRef) !== undefined,
      initialized_at: Date.now(),
    };
    this.instances.set(instanceId, record);
    return { identity: { tenant_id: tenantId, user_id: userId, agent_instance_id: instanceId, mapping_status: 'matched' }, record };
  }

  /** spawn / 代理前查凭据：先员工实例（scope=agent），再账号级；都无则 undefined（回落服务级 env）。 */
  credentialsFor(tenantId: string, userId: string, agentRef?: string): AccountLLMCredentials | undefined {
    if (agentRef) {
      const own = this.agentCreds.get(agentInstanceId(tenantId, userId, agentRef));
      if (own) return own;
    }
    return this.creds.get(acctKey(tenantId, userId));
  }

  upsertTenant(tenantId: string, payload: Record<string, unknown>): void {
    this.tenants.set(tenantId, payload);
  }

  hasTenant(tenantId: string): boolean {
    return this.tenants.has(tenantId);
  }

  /** §10.5 PUT /identity/users/{id}：平台身份事实落本地映射（本地 user_id = 平台 user_id，不按姓名/邮箱猜）。 */
  upsertUser(tenantId: string, userId: string, payload: Record<string, unknown>): { identity: RuntimeIdentity; created: boolean } {
    const key = acctKey(tenantId, userId);
    const prev = this.users.get(key);
    const user = (payload['user'] ?? {}) as Record<string, unknown>;
    const rec: UserRecord = {
      tenant_id: tenantId,
      user_id: userId,
      status: prev?.status ?? 'active',
      profile: { ...(prev?.profile ?? {}), ...user },
      identity: { ...(prev?.identity ?? {}), ...((payload['identity'] ?? {}) as Record<string, unknown>) },
      updated_at: Date.now(),
    };
    this.users.set(key, rec);
    return { identity: { tenant_id: tenantId, user_id: userId, mapping_status: 'matched' }, created: !prev };
  }

  /** §10.6 resolve：平台 user_id 即本地 user_id；没 user_id 时按 provider_subject / email 在已登记用户里唯一匹配。 */
  resolveUser(tenantId: string, q: Record<string, unknown>): { identity: RuntimeIdentity } | 'not_found' | 'conflict' {
    const userId = str(q['user_id']);
    if (userId) return { identity: { tenant_id: tenantId, user_id: userId, mapping_status: 'matched' } };
    const subject = str(q['provider_subject']);
    const subjects = (q['provider_subjects'] ?? {}) as Record<string, unknown>;
    const email = str(q['email']).toLowerCase();
    const matches = [...this.users.values()].filter((u) => {
      if (u.tenant_id !== tenantId) return false;
      const ident = u.identity;
      const identSubjects = (ident['provider_subjects'] ?? {}) as Record<string, unknown>;
      if (subject && (str(ident['provider_subject']) === subject || Object.values(identSubjects).some((v) => str(v) === subject))) return true;
      for (const [k, v] of Object.entries(subjects)) if (str(v) && str(identSubjects[k]) === str(v)) return true;
      if (email && u.profile['email_verified'] === true && str(u.profile['email']).toLowerCase() === email) return true;
      return false;
    });
    if (matches.length === 1) return { identity: { tenant_id: tenantId, user_id: matches[0]!.user_id, mapping_status: 'matched' } };
    return matches.length === 0 ? 'not_found' : 'conflict';
  }

  /** §10.7 status patch：suspended / deactivated 的用户不再开新会话。 */
  setUserStatus(tenantId: string, userId: string, status: UserStatus): UserRecord | undefined {
    const key = acctKey(tenantId, userId);
    const prev = this.users.get(key);
    if (!prev) return undefined;
    prev.status = status;
    prev.updated_at = Date.now();
    return prev;
  }

  userStatus(tenantId: string, userId: string): UserStatus {
    return this.users.get(acctKey(tenantId, userId))?.status ?? 'active';
  }

  userCount(): number {
    return this.users.size;
  }

  instanceCount(): number {
    return this.instances.size;
  }

  credentialCount(): number {
    return this.creds.size + this.agentCreds.size;
  }
}

function parseCredentials(raw: unknown): AccountLLMCredentials | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined;
  const r = raw as Record<string, unknown>;
  const apiKey = str(r['api_key']);
  if (!apiKey) return undefined;
  return {
    api_key: apiKey,
    ...(str(r['base_url']) ? { base_url: str(r['base_url']) } : {}),
    ...(str(r['model']) ? { model: str(r['model']) } : {}),
    ...(str(r['source']) ? { source: str(r['source']) } : {}),
    ...(str(r['scope']) ? { scope: str(r['scope']) } : {}),
  };
}
