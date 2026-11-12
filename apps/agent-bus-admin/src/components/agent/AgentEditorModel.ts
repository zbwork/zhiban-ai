import {
  type AgentFull,
  type AgentModelOption,
  type RuntimeEnv,
} from '../../lib/api'

export type AgentEditorVisibility = 'private' | 'workspace' | 'tenant'

// 暂停后台模板云端新建/位置切换；保留已有云端模板和运行实现。
export const cloudAgentTemplateCreationEnabled = import.meta.env.VITE_CLOUD_AGENT_TEMPLATE_CREATION_ENABLED === 'true'

// 历史数据形态：普通 Admin UI 不再展示类型切换，创建默认写 single；orchestrator 仅用于读取/保留存量 metadata。
export type AgentKind = 'single' | 'orchestrator'

// 历史编排 metadata 的策略值；普通 Admin UI 不再提供维护入口。
export type OrchestrationStrategy = 'manager' | 'sequential' | 'parallel'

export type AgentDraft = {
  ExecutionLocus: 'cloud' | 'local'
  LocalEngine: 'dsh' | 'codex_app_server' | ''
  Name: string
  AvatarURL: string
  AvatarPreviewURL: string
  Intro: string
  PositionLabel: string
  Description: string
  WelcomeMsg: string
  /** 人设（系统提示词），存 metadata.system_prompt；目前只有知办通用运行时（dsh/ZAP）消费。 */
  SystemPrompt: string
  TagsText: string
  ModelPrimary: string
  Visibility: AgentEditorVisibility
  WorkspaceID: number | ''
  RuntimeEnvironmentID: number | null
  AgentKey: string
  ContactEnabled: boolean
  AllowInviteToGroup: boolean
  AgentKind: AgentKind
  ChildAgentUuids: string[]
  OrchestrationStrategy: OrchestrationStrategy
  // 从平台模板「从模板创建」预填时记录来源模板 uuid；服务端据此复核版本并复制受管能力。
  // 空 = 非模板创建（空白新建）。
  TemplateSourceUUID: string
  TemplateSourceUpdatedAt: string
  // 工具权限（仅 dsh 运行时生效）：null = 跟随平台安全默认（命令执行关闭、其余开启）；
  // 非 null = 自定义白名单（只启用勾选的组）。保存时 null 序列化为空数组。
  ToolAllow: string[] | null
}

export type AgentModelSelectOption = {
  value: string
  label: string
  default?: boolean
}

export const DEFAULT_AGENT_MODEL = 'openai/gpt-5.4'

export const DEFAULT_AGENT_MODEL_OPTIONS: AgentModelSelectOption[] = [
  { value: 'openai/gpt-5.4', label: 'openai/gpt-5.4', default: true },
  { value: 'openai/gpt-5.4-mini', label: 'openai/gpt-5.4-mini' },
]

// 工具组（与 dsh-runtime tool-gate 的逻辑组、后端 normalizeToolConfig 值域一致）。
export const TOOL_GROUP_OPTIONS: { value: string; label: string; desc: string }[] = [
  { value: 'bash', label: '命令执行', desc: '运行脚本与命令行；脚本类技能（如网页抓取、文档生成）依赖它' },
  { value: 'fs', label: '文件读写', desc: '在工作区读写文件、处理附件与产出文件' },
  { value: 'skill', label: '技能加载', desc: '加载已绑定的技能包' },
  { value: 'platform', label: '平台工具', desc: '知识库检索、记忆、同事协作（A2A）等平台能力' },
]

// 「自定义」模式的初始勾选 = 平台安全默认的等效集合（命令执行关闭），避免切换瞬间静默放开命令执行。
export const CUSTOM_TOOL_ALLOW_INITIAL = ['fs', 'skill', 'platform']

/** 是否使用 DSH 工具权限分组。 */
export function isDshFramework(framework?: string | null): boolean {
  return (framework || '').trim().toLowerCase() === 'dsh'
}

/** 模型目录由服务端按成员服务返回，不能按引擎名称猜测模型兼容性。 */
export function modelOptionsForFramework(options: AgentModelSelectOption[], _framework?: string | null): AgentModelSelectOption[] {
  void _framework
  return options
}
export function defaultModelForFramework(_framework?: string | null): string {
  void _framework
  return DEFAULT_AGENT_MODEL
}

// ADR-0037 BYOK 只读展示信息，从 AgentFull.ModelServiceConfigJSON 解出来。
export type AgentByokInfo = {
  endpointType: string
  baseUrl: string
  modelId: string
  apiKeyPrefix: string
}

// 非 BYOK（ModelSource 为空或 'platform_whitelist'）返回 null，调用方据此判断走哪条 UI。
export function byokInfoFromAgent(agent: AgentFull | null | undefined): AgentByokInfo | null {
  if (!agent || agent.ModelSource !== 'byok') return null
  let endpointType = ''
  let baseUrl = ''
  let modelId = ''
  try {
    const parsed = agent.ModelServiceConfigJSON ? JSON.parse(agent.ModelServiceConfigJSON) : null
    if (parsed && typeof parsed === 'object') {
      endpointType = typeof parsed.endpoint_type === 'string' ? parsed.endpoint_type : ''
      baseUrl = typeof parsed.base_url === 'string' ? parsed.base_url : ''
      modelId = typeof parsed.model_id === 'string' ? parsed.model_id : ''
    }
  } catch {
    // 解析失败不阻塞页面渲染，只是这几个字段留空。
  }
  return { endpointType, baseUrl, modelId, apiKeyPrefix: agent.ModelServiceAPIKeyPrefix || '' }
}

export function isRuntimeBindableForAgent(runtime: RuntimeEnv): boolean {
  return runtime.Status === 'active' && runtime.LastProbeStatus === 'ok' && runtime.EgressAuditStatus === 'approved'
}

export function normalizeAgentModelOptions(items: AgentModelOption[] = []): AgentModelSelectOption[] {
  const out: AgentModelSelectOption[] = []
  const seen = new Set<string>()
  for (const item of items) {
    const value = (item.id || '').trim()
    if (!value || seen.has(value)) continue
    seen.add(value)
    out.push({ value, label: item.label || value, default: item.default === true })
  }
  return out.length > 0 ? out : DEFAULT_AGENT_MODEL_OPTIONS
}

export function withCurrentAgentModelOption(
  options: AgentModelSelectOption[],
  current: string,
): AgentModelSelectOption[] {
  const value = current.trim()
  if (!value || options.some((item) => item.value === value)) return options
  return [{ value, label: `${value}（历史值）` }, ...options]
}

export function emptyAgentDraft(): AgentDraft {
  return {
    ExecutionLocus: 'cloud',
    LocalEngine: '',
    Name: '',
    AvatarURL: '',
    AvatarPreviewURL: '',
    Intro: '',
    PositionLabel: '',
    Description: '',
    WelcomeMsg: '',
    SystemPrompt: '',
    TagsText: '',
    ModelPrimary: DEFAULT_AGENT_MODEL,
    Visibility: 'tenant',
    WorkspaceID: '',
    RuntimeEnvironmentID: null,
    AgentKey: '',
    ContactEnabled: true,
    AllowInviteToGroup: true,
    AgentKind: 'single',
    ChildAgentUuids: [],
    OrchestrationStrategy: 'manager',
    TemplateSourceUUID: '',
    TemplateSourceUpdatedAt: '',
    ToolAllow: null,
  }
}

export function fromAgent(agent: AgentFull): AgentDraft {
  return {
    ExecutionLocus: agent.execution_locus || 'cloud',
    LocalEngine: agent.execution_locus === 'local' ? agent.local_engine || 'dsh' : '',
    Name: agent.Name || '',
    AvatarURL: agent.AvatarURL || '',
    AvatarPreviewURL: agent.AvatarPreviewURL || (agent.AvatarURL && !agent.AvatarURL.startsWith('oss://') ? agent.AvatarURL : ''),
    Intro: agent.Intro || '',
    PositionLabel: agent.PositionLabel || '',
    Description: agent.Description || '',
    WelcomeMsg: agent.WelcomeMsg || '',
    SystemPrompt: metadataString(agent.Metadata, 'system_prompt'),
    TagsText: displayTagsFromAgent(agent).join(', '),
    ModelPrimary: agent.ModelPrimary || DEFAULT_AGENT_MODEL,
    Visibility: visibilityValue(agent.Visibility),
    WorkspaceID: agent.WorkspaceID || '',
    RuntimeEnvironmentID: agent.RuntimeEnvironmentID || null,
    AgentKey: metadataString(agent.Metadata, 'agent_key'),
    ContactEnabled: agent.ContactEnabled !== false,
    AllowInviteToGroup: !!agent.AllowInviteToGroup,
    AgentKind: metadataAgentKind(agent.Metadata),
    ChildAgentUuids: metadataChildUuids(agent.Metadata),
    OrchestrationStrategy: metadataStrategy(agent.Metadata),
    TemplateSourceUUID: metadataString(agent.Metadata, 'template_source_uuid'),
    TemplateSourceUpdatedAt: metadataString(agent.Metadata, 'template_source_updated_at'),
    // 空数组与 null 都视为「平台默认」（后端 allow 空 = 默认语义）。
    ToolAllow: agent.ToolAllow && agent.ToolAllow.length > 0 ? [...agent.ToolAllow] : null,
  }
}

export function isSupportBuiltinAgent(agent: AgentFull | null | undefined): boolean {
  if (!agent?.Metadata) return false
  return metadataString(agent.Metadata, 'runtime_kind') === 'support_builtin' ||
    metadataString(agent.Metadata, 'agent_key') === 'zhiban-support'
}

export function isSupportBuiltinDraft(draft: AgentDraft, existing?: AgentFull | null): boolean {
  return draft.AgentKey.trim() === 'zhiban-support' || isSupportBuiltinAgent(existing)
}

export function toAgentPayload(draft: AgentDraft, existing: AgentFull | null): Partial<AgentFull> {
  const tags = splitText(draft.TagsText)
  const metadata: Record<string, unknown> = { ...(existing?.Metadata || {}) }
  if (draft.AgentKey.trim()) metadata.agent_key = draft.AgentKey.trim()
  else delete metadata.agent_key
  // 保留历史 metadata 读写语义；普通 Admin UI 当前不再提供类型与编排配置入口。
  metadata.agent_kind = draft.AgentKind
  if (draft.AgentKind === 'orchestrator') {
    metadata.orchestration = {
      child_agent_uuids: draft.ChildAgentUuids,
      strategy: draft.OrchestrationStrategy,
    }
  } else {
    // 单体：清掉编排子配置，避免脏数据影响。
    delete metadata.orchestration
  }
  // doc-15：副本溯源（保留既有；从模板预填时由 draft 带入）。空则不动 existing 值。
  if (draft.TemplateSourceUUID.trim()) metadata.template_source_uuid = draft.TemplateSourceUUID.trim()
  if (draft.TemplateSourceUpdatedAt.trim()) metadata.template_source_updated_at = draft.TemplateSourceUpdatedAt.trim()
  // 人设：非空写 metadata.system_prompt（ZAP/dsh 注册随卡片下发）；清空则删键，让 Bus 用结构化字段渲染兜底人设。
  if (draft.SystemPrompt.trim()) metadata.system_prompt = draft.SystemPrompt.trim()
  else delete metadata.system_prompt
  return {
    ...(existing || {}),
    Name: draft.Name.trim(),
    AvatarURL: draft.AvatarURL,
    Intro: draft.Intro,
    PositionLabel: draft.PositionLabel,
    Description: draft.Description,
    WelcomeMsg: draft.WelcomeMsg,
    Tags: tags,
    Badges: tags,
    ModelPrimary: draft.ModelPrimary,
    Visibility: draft.Visibility,
    WorkspaceID: draft.Visibility === 'workspace' ? Number(draft.WorkspaceID) : null,
    execution_locus: draft.ExecutionLocus,
    local_engine: draft.ExecutionLocus === 'local' ? draft.LocalEngine || 'dsh' : '',
    RuntimeEnvironmentID: draft.ExecutionLocus === 'local' ? null : draft.RuntimeEnvironmentID,
    Metadata: metadata,
    Source: existing?.Source || 'enterprise',
    ContactEnabled: draft.ContactEnabled,
    AllowInviteToGroup: draft.AllowInviteToGroup,
    Status: existing?.Status || 'draft',
    SupportsGroupChat: draft.AllowInviteToGroup,
    Temperature: existing?.Temperature || 0.7,
    ContextWindow: existing?.ContextWindow || 32768,
    // null（平台默认）序列化为空数组 = 后端「清空/默认」语义；自定义则原样提交白名单。
    ToolAllow: draft.ToolAllow === null ? [] : draft.ToolAllow,
  }
}

export function splitText(text: string) {
  return text.split(',').map((s) => s.trim()).filter(Boolean)
}

function displayTagsFromAgent(agent: AgentFull) {
  const tags = agent.Tags || []
  if (tags.length > 0) return tags
  return agent.Badges || []
}

function visibilityValue(v: string): AgentEditorVisibility {
  return v === 'private' || v === 'workspace' || v === 'tenant' ? v : 'tenant'
}

function metadataString(metadata: Record<string, unknown> | null | undefined, key: string) {
  const value = metadata?.[key]
  return typeof value === 'string' ? value : ''
}

function metadataAgentKind(metadata: Record<string, unknown> | null | undefined): AgentKind {
  return metadata?.agent_kind === 'orchestrator' ? 'orchestrator' : 'single'
}

function orchestrationObj(metadata: Record<string, unknown> | null | undefined): Record<string, unknown> | null {
  const o = metadata?.orchestration
  return o && typeof o === 'object' ? (o as Record<string, unknown>) : null
}

function metadataChildUuids(metadata: Record<string, unknown> | null | undefined): string[] {
  const arr = orchestrationObj(metadata)?.child_agent_uuids
  return Array.isArray(arr) ? arr.filter((x): x is string => typeof x === 'string') : []
}

function metadataStrategy(metadata: Record<string, unknown> | null | undefined): OrchestrationStrategy {
  const s = orchestrationObj(metadata)?.strategy
  return s === 'sequential' || s === 'parallel' ? s : 'manager'
}
