/**
 * 北侧错误码表——**只允许 zap.* 词表**（CLAUDE.md 边界 1）。
 * message 面向 Bus 运维排障，禁止出现南侧实现细节（进程名、插件名、wire 方法名）。
 * 线上形状与 Bus `zapErrorResponse` 对齐：{ ok:false, error:{ code, message } }。
 */
export const ZapErrorCode = {
  unauthorized: 'zap.unauthorized',
  notFound: 'zap.not_found',
  invalidRequest: 'zap.invalid_request',
  agentKeyExists: 'zap.agent_key_exists',
  agentKeyNotFound: 'zap.agent_key_not_found',
  agentContextMismatch: 'zap.agent_context_mismatch',
  contextMissing: 'zap.context_missing',
  tenantMismatch: 'zap.tenant_mismatch',
  accountMismatch: 'zap.account_mismatch',
  sessionNotFound: 'zap.session_not_found',
  sessionCancelled: 'zap.session_cancelled',
  sessionBusy: 'zap.session_busy',
  emptyUserMessage: 'zap.empty_user_message',
  capacityExhausted: 'zap.capacity_exhausted',
  /** SSE message.failed：会话进程拉起/握手失败 */
  runtimeStartFailed: 'zap.runtime_start_failed',
  /** SSE message.failed：会话进程运行中异常退出 / 上游模型失败 */
  upstreamFailure: 'zap.upstream_failure',
  /** SSE message.failed：单轮超时 */
  turnTimeout: 'zap.turn_timeout',
  /** 本 runtime 扩展：会话进程树超过内存 / CPU 上限被看门狗终止 */
  resourceLimitExceeded: 'zap.resource_limit_exceeded',
  /** 本 runtime 扩展：用户工作区 / 租户合计超出磁盘配额（spawn 前拒绝或本轮终止） */
  workspaceQuotaExceeded: 'zap.workspace_quota_exceeded',
  /** 本 runtime 扩展：数据卷剩余空间低于下限，拒开新轮（运维告警项） */
  diskFull: 'zap.disk_full',
  /** SSE message.failed：`DSH_RUNTIME_REQUIRE_ACCOUNT_LLM_KEY=1` 且该 (租户,账号) 未由 /instances 下发 llm 凭据（fail-closed，不 spawn，不用服务级 fallback） */
  llmCredentialMissing: 'zap.llm_credential_missing',
  /** 本 runtime 扩展（ADR-0037 dsh 消费端）：byok 员工没有由 /instances 下发员工级凭据（fail-closed，不 spawn，不回落账号/服务级） */
  modelServiceCredentialsMissing: 'zap.model_service_credentials_missing',
  /** 本 runtime 扩展：登记的 model_service.endpoint_type 不在支持列表（openai-compatible / anthropic-messages） */
  modelServiceEndpointUnsupported: 'zap.model_service_endpoint_unsupported',
  internal: 'zap.internal_error',
  /** §10.9 identity */
  identityTenantNotFound: 'zap.identity_tenant_not_found',
  identityUserNotFound: 'zap.identity_user_not_found',
  identityMappingConflict: 'zap.identity_mapping_conflict',
  identityProfileInvalid: 'zap.identity_profile_invalid',
  /** 本 runtime 扩展：用户已被 §10.7 置为 suspended/deactivated，拒绝开新会话 */
  userInactive: 'zap.user_inactive',
  /** §11.5 skills carrier */
  patchSeqOutdated: 'zap.patch_seq_outdated',
  patchGap: 'zap.patch_gap',
  patchInvalid: 'zap.patch_invalid',
} as const;

export type ZapErrorCodeValue = (typeof ZapErrorCode)[keyof typeof ZapErrorCode];

export interface ZapErrorBody {
  ok: false;
  error: { code: string; message: string; [extra: string]: unknown };
}

export class ZapError extends Error {
  readonly code: ZapErrorCodeValue;
  readonly httpStatus: number;
  /** 附加字段（如 §11.2.A 的 current_seq / expected_seq / received_seq / errors），放在 error 对象里：Bus parseErr 两种形态都收 */
  readonly extra: Record<string, unknown>;
  constructor(code: ZapErrorCodeValue, httpStatus: number, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.name = 'ZapError';
    this.code = code;
    this.httpStatus = httpStatus;
    this.extra = extra;
  }

  toBody(): ZapErrorBody {
    return { ok: false, error: { ...this.extra, code: this.code, message: this.message } };
  }
}

export const zapErrors = {
  unauthorized: () => new ZapError(ZapErrorCode.unauthorized, 401, 'invalid or missing bearer token'),
  notFound: () => new ZapError(ZapErrorCode.notFound, 404, 'route not found'),
  invalidRequest: (msg: string) => new ZapError(ZapErrorCode.invalidRequest, 400, msg),
  agentKeyExists: (key: string) => new ZapError(ZapErrorCode.agentKeyExists, 409, `agent_key ${key} already exists`),
  agentKeyNotFound: (key: string) => new ZapError(ZapErrorCode.agentKeyNotFound, 404, `agent_key ${key} is not registered`),
  agentContextMismatch: () =>
    new ZapError(ZapErrorCode.agentContextMismatch, 422, 'agent.agent_key must equal agent_key (fail-closed)'),
  contextMissing: (msg: string) => new ZapError(ZapErrorCode.contextMissing, 400, msg),
  tenantMismatch: () =>
    new ZapError(ZapErrorCode.tenantMismatch, 400, 'conversation_context_hint.tenant_id must equal user.tenant_id (fail-closed)'),
  accountMismatch: () =>
    new ZapError(ZapErrorCode.accountMismatch, 400, 'conversation_context_hint.user_id must equal user.user_id (fail-closed)'),
  sessionNotFound: (id: string) => new ZapError(ZapErrorCode.sessionNotFound, 404, `session ${id} not found or expired`),
  sessionCancelled: (id: string) => new ZapError(ZapErrorCode.sessionCancelled, 409, `session ${id} has been cancelled`),
  sessionBusy: (id: string) => new ZapError(ZapErrorCode.sessionBusy, 409, `session ${id} already has a message in flight`),
  emptyUserMessage: () =>
    new ZapError(ZapErrorCode.emptyUserMessage, 400, 'request must include `text` or at least one text block'),
  capacityExhausted: () => new ZapError(ZapErrorCode.capacityExhausted, 503, 'runtime is at capacity, retry later'),
  identityUserNotFound: (id: string) => new ZapError(ZapErrorCode.identityUserNotFound, 404, `user ${id} is not provisioned`),
  identityMappingConflict: () => new ZapError(ZapErrorCode.identityMappingConflict, 409, 'identity facts match more than one local user'),
  identityProfileInvalid: (msg: string) => new ZapError(ZapErrorCode.identityProfileInvalid, 422, msg),
  userInactive: (status: string) => new ZapError(ZapErrorCode.userInactive, 403, `user is ${status}; new sessions are refused`),
  /** skills 端点上的"会话不存在"按 §11.2.A 用 412（Bus 据此重开 session） */
  skillsSessionNotFound: (id: string) => new ZapError(ZapErrorCode.sessionNotFound, 412, `session ${id} not found or expired`),
  patchSeqOutdated: (current: number) => new ZapError(ZapErrorCode.patchSeqOutdated, 409, 'patch_seq already superseded', { current_seq: current }),
  patchGap: (current: number, expected: number, received: number) =>
    new ZapError(ZapErrorCode.patchGap, 410, 'patch_seq gap, resync required', { current_seq: current, expected_seq: expected, received_seq: received }),
  patchInvalid: (errors: string[]) => new ZapError(ZapErrorCode.patchInvalid, 422, 'skills payload invalid', { errors }),
  internal: () => new ZapError(ZapErrorCode['internal'], 500, 'internal runtime error'),
};
