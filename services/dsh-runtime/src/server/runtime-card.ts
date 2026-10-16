import type { RuntimeConfig } from '../config.js';

/** 本 runtime 框架层支持的 block 类型上限（AgentCard.ui_components 只能取其子集）。 */
export const RUNTIME_UI_COMPONENTS = ['markdown', 'plain', 'error', 'code', 'tool_call', 'tool_result'] as const;

/**
 * RuntimeCard（ZAP-1.1 §1.2）。平台级 external_endpoint 接入：framework='zap'、vendor='zhiban/dsh'、
 * multi-agent、multi_tenant_isolation 必须为 true（§1.3 第 7 条；P2 补 bwrap 读隔离与探针后方可上生产）。
 */
export function buildRuntimeCard(config: RuntimeConfig): Record<string, unknown> {
  return {
    protocol_version: 'zap-1.1',
    schema_version: 'zap-1.1',
    framework: 'zap',
    vendor: 'zhiban/dsh',
    version: config.version,
    description: '知办通用运行时（dsh）：数字员工=一份配置；对话=每会话一个带内核沙箱的子进程，空闲回收。',
    supports_multi_agent: true,
    default_agent_key: 'main',
    max_agents: 0,
    agent_management: { supports_create: true, supports_update: true, supports_delete: true, supports_list: true },
    control_plane_capabilities: ['agent.read', 'agent.list', 'agent.create', 'agent.update', 'agent.delete'],
    runtime_ui_components: [...RUNTIME_UI_COMPONENTS],
    data_egress: 'platform-only',
    limits: { max_concurrent_sessions: config.maxProcesses },
    multi_tenant_isolation: true,
    multi_tenant_isolation_notes:
      'per-session process + kernel sandbox write boundary + Landlock read allow-list scoped to /data/tenants/<tenant>/<user>; cross-tenant read probe is a startup gate (ADR-0035 §6.1)',
    agent_instance_initialization: {
      version: 'zap-agent-instance-1',
      supports_initialize: true,
      returns_runtime_identity: true,
      supports_user_deactivate: true,
      supports_bulk: false,
      supports_async_callback: false,
    },
    tenant_synchronization: { version: 'zap-tenant-sync-1', supports_upsert: true },
    // ADR-0037 dsh 消费端：Bus 只向声明了本能力位的 runtime 下发 scope=agent（员工自带模型服务）的凭据；
    // 老版本收到会当账号级凭据存，所以这个位必须由新版本才声明。
    llm_credentials: { version: 'zap-llm-credentials-1', supports_agent_scope: true, sources: ['beebridge_gateway', 'byok'] },
    // §10.2：Bus 据此在会话前调 POST /identity/provision（聚合）；user upsert / resolve / status 三段式也实现（§10.5~10.7）
    identity_provisioning: {
      version: 'zap-identity-1',
      supports_provision: true,
      supports_tenant_upsert: true,
      supports_user_upsert: true,
      supports_resolve: true,
      supports_user_resolve: true,
      supports_user_deactivate: true,
      supports_bulk: false,
      supports_async_callback: false,
    },
    extensions: { conversation_model: { version: 1, per_turn: true, platform_binding: true } },
  };
}
