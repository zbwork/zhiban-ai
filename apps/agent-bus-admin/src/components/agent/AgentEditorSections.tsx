import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react'
import { Bot, Camera, CheckCircle2, HelpCircle, ImagePlus, Upload, X } from 'lucide-react'
import { AgentExecutionFields } from '../form/AgentExecutionFields'
import { PositionsField, type PositionsFieldValue } from '../PositionsField'
import { SearchableMultiSelect } from '../form/SearchableMultiSelect'
import { Button, FormField, FormSection, InlineAlert, Input, SegmentedControl, Select, Switch } from '../ui'
import {
  AdminAgentA2ACard,
  AdminAgentA2AInvokeCapability,
  AdminAgentCallable,
  AgentsAdmin,
  type App,
  type AppCategory,
  type AdminAgentA2ACard as AdminAgentA2ACardDTO,
  type AdminAgentCallable as AdminAgentCallableDTO,
  type AgentFull,
  type AgentKBBinding,
  type Department,
  type Position,
  type RuntimeEnv,
  type SkillCategory,
  type TenantKBItem,
  type TenantSkill,
} from '../../lib/api'
import {
  CUSTOM_TOOL_ALLOW_INITIAL,
  DEFAULT_AGENT_MODEL_OPTIONS,
  TOOL_GROUP_OPTIONS,
  type AgentByokInfo,
  type AgentDraft,
  type AgentEditorVisibility,
  type AgentModelSelectOption,
  isDshFramework,
  isRuntimeBindableForAgent,
  modelOptionsForFramework,
  withCurrentAgentModelOption,
} from './AgentEditorModel'

const AGENT_AVATAR_MAX_BYTES = 5 * 1024 * 1024

export function AgentBasicSection({
  draft,
  patch,
  locked,
  positions = [],
  posValue,
  onPosChange,
  departments = [],
  agentUuid,
  uploadScope = 'tenant',
  showOrgControls = true,
  modelOptions = DEFAULT_AGENT_MODEL_OPTIONS,
  runtimeFramework,
  byokInfo,
}: {
  draft: AgentDraft
  patch: (p: Partial<AgentDraft>) => void
  locked: boolean
  positions?: Position[]
  posValue?: PositionsFieldValue
  onPosChange?: (v: PositionsFieldValue) => void
  departments?: Department[]
  agentUuid?: string
  uploadScope?: 'tenant' | 'platform'
  showOrgControls?: boolean
  modelOptions?: AgentModelSelectOption[]
  /** 绑定运行时的 framework；模型候选由服务端目录提供。 */
  runtimeFramework?: string
  // ADR-0037 BYOK：model_source='byok' 时主模型不可在后台编辑（密钥只有创建者本人能改），
  // 只读展示当前实际使用的模型服务信息。undefined/null = 非 BYOK，走原有可编辑 Select。
  byokInfo?: AgentByokInfo | null
}) {
  const isWorkspaceVisibility = draft.Visibility === 'workspace'
  const departmentPlaceholder = departments.length > 0 ? '请选择部门' : '暂无部门，请先创建部门'
  const visibleModelOptions = withCurrentAgentModelOption(
    modelOptionsForFramework(modelOptions, runtimeFramework),
    draft.ModelPrimary,
  )

  return (
    <div className="space-y-4">
      {/* 普通主路径不再露出协作配置；创建默认按单体数字员工保存。 */}
      <FormSection title="基础信息" description="客户端和后台都会使用这组信息识别数字员工。" className="border-0 bg-transparent p-0">
        <div className="grid grid-cols-1 gap-x-6 gap-y-4 md:grid-cols-2">
          <div className="md:col-span-2">
            <AgentAvatarUploader draft={draft} patch={patch} agentUuid={agentUuid} uploadScope={uploadScope} disabled={locked} />
          </div>
          <FormField label="名称 *">
            <Input value={draft.Name} onChange={(e) => patch({ Name: e.target.value })} disabled={locked} placeholder="例如：代码审计专家" />
          </FormField>
          {draft.ExecutionLocus === 'local' && uploadScope === 'platform' ? (
            <FormField label="模型服务"><p className="text-[13px] text-[var(--color-text-sub)]">由使用者在客户端配置</p></FormField>
          ) : byokInfo ? (
            <FormField
              label="主模型"
              hint="该数字员工使用创建者自己配置的模型服务（BYOK），密钥只有创建者本人能在客户端修改，后台只读展示。"
            >
              <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-line-soft)] px-3 py-2 text-[13px] text-[var(--color-text)]">
                <div className="font-medium">我的模型服务 · {byokInfo.modelId || '未配置'}</div>
                <div className="mt-1 truncate text-[12px] text-[var(--color-text-mute)]">
                  {[byokInfo.endpointType, byokInfo.baseUrl, byokInfo.apiKeyPrefix && `Key ${byokInfo.apiKeyPrefix}***`]
                    .filter(Boolean)
                    .join(' · ') || '未配置端点信息'}
                </div>
              </div>
            </FormField>
          ) : (
            <FormField label="主模型">
              <Select value={draft.ModelPrimary} onChange={(e) => patch({ ModelPrimary: e.target.value })} disabled={locked}>
                {visibleModelOptions.map((item) => (
                  <option key={item.value} value={item.value}>{item.label}</option>
                ))}
              </Select>
            </FormField>
          )}
          <div className="md:col-span-2">
            <FormField label="主要职责" hint="展示在数字员工列表、通讯录和客户端卡片上，建议用一句话说明职责。">
              <textarea
                value={draft.Intro}
                onChange={(e) => patch({ Intro: e.target.value })}
                rows={3}
                disabled={locked}
                className={textareaCls}
                placeholder="例如：负责代码审计、风险说明和修复建议，适合研发团队日常使用。"
              />
            </FormField>
          </div>
          <FormField label="标签" hint="展示在列表、通讯录和客户端卡片上的短标签，多个用逗号分隔。">
            <Input value={draft.TagsText} onChange={(e) => patch({ TagsText: e.target.value })} disabled={locked} placeholder="研发, 审计" />
          </FormField>
          <div className="md:col-span-2">
            <FormField label="内部说明" hint="仅用于后台维护，记录能力边界、适用场景和运维备注。">
              <textarea
                value={draft.Description}
                onChange={(e) => patch({ Description: e.target.value })}
                rows={4}
                disabled={locked}
                className={textareaCls}
                placeholder="补充能力范围、适用场景、限制和维护说明。"
              />
            </FormField>
          </div>
          <div className="md:col-span-2">
            <FormField label="欢迎语">
              <textarea
                value={draft.WelcomeMsg}
                onChange={(e) => patch({ WelcomeMsg: e.target.value })}
                rows={3}
                disabled={locked}
                className={textareaCls}
                placeholder="客户端打开会话时展示。"
              />
            </FormField>
          </div>
          <div className="md:col-span-2">
            <FormField
              label="人设（系统提示词）"
              hint={
                isDshFramework(runtimeFramework)
                  ? '随数字员工注册下发给知办通用运行时。留空时按名称、职位、主要职责、欢迎语自动生成一份基础人设。'
                  : '仅知办通用运行时（dsh）使用；OpenClaw / Hermes 运行时按名称、职位、主要职责自动生成身份文件，不读取此字段。'
              }
            >
              <textarea
                value={draft.SystemPrompt}
                onChange={(e) => patch({ SystemPrompt: e.target.value })}
                rows={6}
                disabled={locked}
                className={textareaCls}
                placeholder="例如：你是合同审查助理，回答简洁，遇到法律风险先列出风险点再给建议；不确定的条款明确说明需要人工复核。"
              />
            </FormField>
          </div>
        </div>
      </FormSection>

      <FormSection title="通讯录与范围" description="控制数字员工在客户端通讯录、部门范围和群聊邀请中的表现。" className="border-0 border-t border-[var(--color-line-soft)] bg-transparent px-0 pb-0 pt-5">
        {showOrgControls && posValue && onPosChange && (
          <div className="grid grid-cols-1 gap-x-6 gap-y-4 md:grid-cols-2">
            <FormField label="职位（通讯录主显示）">
              <PositionsField value={posValue} onChange={onPosChange} positions={positions} />
            </FormField>
            <FormField label="可见范围" hint="控制谁能看到这个数字员工；所在部门可单独设置。">
              <Select
                value={draft.Visibility}
                onChange={(e) => patch({ Visibility: e.target.value as AgentEditorVisibility })}
                disabled={locked}
              >
                <option value="tenant">全租户</option>
                <option value="workspace">指定部门</option>
                <option value="private">仅创建者</option>
              </Select>
            </FormField>
            <FormField
              label={isWorkspaceVisibility ? '所在部门 *' : '所在部门'}
              hint={isWorkspaceVisibility ? '指定部门可见时，此部门同时作为可见范围，必须选择。' : '数字员工在通讯录里的归属部门；不影响「全租户」可见。'}
            >
              <Select
                value={draft.WorkspaceID}
                onChange={(e) => patch({ WorkspaceID: e.target.value ? Number(e.target.value) : '' })}
                disabled={locked || departments.length === 0}
              >
                <option value="">{departmentPlaceholder}</option>
                {departments.map((d) => (
                  <option key={d.id} value={d.id}>{d.name}</option>
                ))}
              </Select>
            </FormField>
          </div>
        )}
        <div className="mt-4 flex flex-wrap gap-2">
          <ToggleChip checked={draft.ContactEnabled} onChange={(v) => patch({ ContactEnabled: v })} label="进入客户端通讯录" />
          <ToggleChip checked={draft.AllowInviteToGroup} onChange={(v) => patch({ AllowInviteToGroup: v })} label="允许被拉入群聊" />
        </div>
      </FormSection>
    </div>
  )
}

export type AgentEditorContext = 'platformPreset' | 'tenantAgent'

export function AgentRuntimeSection({
  draft,
  patch,
  locked,
  runtimeOptions,
  context = 'tenantAgent',
  allowCreateRuntime = true,
  required = false,
  description = '发布前必须绑定已启用且连通性测试通过的运行环境；草稿可以先暂不绑定。',
  emptyMessage = '暂无可用运行环境。请先在「智能体托管环境」启用平台环境、新增外部智能体接入，或完成连通性测试。',
  emptyAction,
  allowTemplateCloudToLocal = false,
}: {
  draft: AgentDraft
  patch: (p: Partial<AgentDraft>) => void
  locked: boolean
  runtimeOptions: { platform: RuntimeEnv[]; tenant: RuntimeEnv[]; all: RuntimeEnv[] }
  allowCreateRuntime?: boolean
  required?: boolean
  context?: AgentEditorContext
  description?: string
  emptyMessage?: string
  emptyAction?: { label: string; onClick: () => void }
  allowTemplateCloudToLocal?: boolean
}) {
  const currentRuntime = runtimeOptions.all.find((r) => r.ID === draft.RuntimeEnvironmentID) || null
  const visibleRuntimeOptions = {
    platform: runtimeOptions.platform.filter(isRuntimeBindableForAgent),
    tenant: runtimeOptions.tenant.filter(isRuntimeBindableForAgent),
    all: [
      ...runtimeOptions.platform.filter(isRuntimeBindableForAgent),
      ...runtimeOptions.tenant.filter(isRuntimeBindableForAgent),
    ],
  }
  const currentRuntimeIsSelectable = !!currentRuntime && isRuntimeSelectableForAgent(currentRuntime, context)

  // 当前选中的运行环境。即使当前绑定环境暂时不可选，也必须显示出来，避免误导成“未绑定”。
  const selected = currentRuntime || null

  return (
    <FormSection title="运行配置" description={description} className="border-0 bg-transparent p-0">
      <div className="max-w-3xl space-y-4">
        <AgentExecutionFields draft={draft} onChange={patch} disabled={locked}
          template={context === 'platformPreset'} runtimes={runtimeOptions.all}
          required={required} allowCreateRuntime={allowCreateRuntime}
          allowTemplateCloudToLocal={allowTemplateCloudToLocal} />

        {/* Agent Key 系统托管：不在 UI 填写，由后端据运行环境自动生成 / 补默认。 */}
        {selected && currentRuntimeIsSelectable && (
          <div className="flex items-start gap-2 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] leading-relaxed text-[var(--color-text-mute)]">
            <CheckCircle2 size={14} className="mt-0.5 shrink-0 text-[var(--color-text-mute)]" />
            <span>Agent Key 由后台自动生成，用于运行端识别，无需手动填写。</span>
          </div>
        )}
        {selected && !currentRuntimeIsSelectable && (
          <InlineAlert tone="warn">
            当前数字员工已绑定「{runtimeLabel(selected)}」，但该运行环境暂未通过可选条件：{runtimeUnavailableReason(selected, context)}。保存其它配置不会自动解绑；如需重新发布或切换运行环境，请先处理上述问题。
          </InlineAlert>
        )}

        {/* 工具权限：仅 dsh（知办通用运行时）装配层生效。平台安全默认关闭命令执行；
            脚本类技能（网页抓取、文档生成等）需要切「自定义」并勾选命令执行。 */}
        {selected && isDshFramework(selected.Framework) && (
          <FormField
            label="工具权限"
            hint="平台安全默认：命令执行关闭、其余开启。脚本类技能（如网页抓取、文档生成）依赖命令执行，需要时切换为自定义并勾选。"
          >
            <div className="space-y-2">
              <SegmentedControl
                size="sm"
                options={[
                  { value: 'default', label: '平台默认' },
                  { value: 'custom', label: '自定义' },
                ]}
                value={draft.ToolAllow === null ? 'default' : 'custom'}
                onChange={(v) => {
                  if (locked) return
                  patch({ ToolAllow: v === 'default' ? null : [...CUSTOM_TOOL_ALLOW_INITIAL] })
                }}
              />
              {draft.ToolAllow !== null && (
                <div className="grid grid-cols-1 gap-2 md:grid-cols-2">
                  {TOOL_GROUP_OPTIONS.map((opt) => {
                    const checked = draft.ToolAllow!.includes(opt.value)
                    const lastOne = checked && draft.ToolAllow!.length === 1
                    return (
                      <label
                        key={opt.value}
                        className="flex cursor-pointer items-start gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px] hover:bg-[var(--color-bg-sub)]"
                      >
                        <input
                          type="checkbox"
                          className="mt-0.5 accent-[var(--color-brand)]"
                          checked={checked}
                          disabled={locked || lastOne}
                          title={lastOne ? '至少保留一个工具组；全部关闭请切回「平台默认」' : undefined}
                          onChange={(e) =>
                            patch({
                              ToolAllow: e.target.checked
                                ? [...draft.ToolAllow!, opt.value]
                                : draft.ToolAllow!.filter((x) => x !== opt.value),
                            })
                          }
                        />
                        <span className="min-w-0">
                          <span className="block font-medium text-[var(--color-text)]">{opt.label}</span>
                          <span className="block text-[11px] leading-relaxed text-[var(--color-text-sub)]">{opt.desc}</span>
                        </span>
                      </label>
                    )
                  })}
                </div>
              )}
            </div>
          </FormField>
        )}

        {draft.ExecutionLocus !== 'local' && visibleRuntimeOptions.all.length === 0 && (
          <InlineAlert tone="warn">
            <div className="space-y-2">
              <div>{emptyMessage}</div>
              {emptyAction && (
                <Button variant="secondary" size="sm" onClick={emptyAction.onClick}>
                  {emptyAction.label}
                </Button>
              )}
            </div>
          </InlineAlert>
        )}
        <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-sub)]">
          <CheckCircle2 size={14} className="text-[var(--color-success)]" />
          <span>{draft.ExecutionLocus === 'local' ? '本地模板仅保存运行配置，不绑定用户设备、工作目录或运行权限。' : '创建后由平台统一托管和发布；容量与状态由后端在保存 / 发布时再次校验。'}</span>
        </div>
      </div>
    </FormSection>
  )
}

export function AgentAbilitiesSection({
  skillsOpts,
  skillCategories,
  skillUuids,
  setSkillUuids,
  appsOpts,
  appCategories,
  appUuids,
  setAppUuids,
  kbsOpts,
  kbUuids,
  setKbUuids,
  lockedKBBindings = [],
  disableKnowledgeBase = false,
  knowledgeBaseHint = '只展示已就绪的租户级知识库。',
}: {
  skillsOpts: TenantSkill[]
  skillCategories: SkillCategory[]
  skillUuids: string[]
  setSkillUuids: (v: string[]) => void
  appsOpts: App[]
  appCategories: AppCategory[]
  appUuids: string[]
  setAppUuids: (v: string[]) => void
  kbsOpts: TenantKBItem[]
  kbUuids: string[]
  setKbUuids: (v: string[]) => void
  lockedKBBindings?: Array<Pick<AgentKBBinding, 'kb_uuid' | 'kb_name'> & Partial<Pick<AgentKBBinding, 'kb_status'>>>
  disableKnowledgeBase?: boolean
  knowledgeBaseHint?: string
}) {
  return (
    <FormSection title="能力装配" description="技能、应用和知识库统一在这里选择；保存后写入当前数字员工草稿。" className="border-0 bg-transparent p-0">
      <div className="space-y-5">
        <FormField as="div" label="技能" hint="支持按技能名称、编码和分类筛选。">
          <SearchableMultiSelect
            options={skillsOpts.map((s) => ({
              value: s.uuid,
              label: s.name,
              hint: s.code,
              description: s.description,
              iconUrl: s.icon_url,
              iconText: s.name.slice(0, 1),
              categoryKey: s.category_id ? String(s.category_id) : undefined,
            }))}
            value={skillUuids}
            onChange={setSkillUuids}
            categoryOptions={skillCategories.map((c) => ({ value: String(c.id), label: c.name }))}
            categoryLabel="技能分类"
            categoryPlaceholder="全部技能分类"
            placeholder="点击挑选技能..."
            emptyHint="暂无可用技能"
          />
        </FormField>
        <FormField as="div" label="应用" hint="支持按应用名称、编码和分类筛选。">
          <SearchableMultiSelect
            options={appsOpts.map((a) => ({
              value: a.uuid,
              label: a.name,
              hint: a.code,
              description: a.description,
              iconUrl: a.iconUrl,
              iconText: a.name.slice(0, 1),
              categoryKey: a.categoryUuid,
            }))}
            value={appUuids}
            onChange={setAppUuids}
            categoryOptions={appCategories.map((c) => ({ value: c.uuid, label: c.name }))}
            categoryLabel="应用分类"
            categoryPlaceholder="全部应用分类"
            placeholder="点击挑选应用..."
            emptyHint="暂无可用应用"
          />
        </FormField>
        {disableKnowledgeBase ? (
          <DisabledPool title="知识库" />
        ) : (
          <FormField as="div" label="知识库" hint={knowledgeBaseHint}>
            <SearchableMultiSelect
              options={[
                ...lockedKBBindings.map((k) => ({
                  value: k.kb_uuid,
                  label: k.kb_name,
                  hint: !k.kb_status || k.kb_status === 'active' ? '平台提供' : `平台提供 · ${k.kb_status}`,
                  description: '由平台模板维护，租户管理员不可移除。',
                  iconText: '知',
                  locked: true,
                })),
                ...kbsOpts.map((k) => ({
                value: k.uuid,
                label: k.name,
                hint: kbKindLabel(k.space_kind),
                description: k.description,
                iconText: '知',
                })),
              ]}
              value={[...lockedKBBindings.map((k) => k.kb_uuid), ...kbUuids]}
              onChange={(next) => setKbUuids(next.filter((uuid) => !lockedKBBindings.some((k) => k.kb_uuid === uuid)))}
              placeholder="点击挑选知识库..."
              emptyHint="暂无可用知识库"
            />
          </FormField>
        )}
        <DisabledPool title="MCP" />
      </div>
    </FormSection>
  )
}

const defaultCallableConfig: AdminAgentCallableDTO = { mode: 'all', agent_ids: [] }

function CollaborationSectionHeader({
  title,
  titleHint,
  description,
}: {
  title: string
  titleHint?: string
  description?: string
}) {
  return (
    <div className="mb-3">
      <div className="flex items-center gap-1.5 text-[14px] font-semibold text-[var(--color-text)]">
        <span>{title}</span>
        {titleHint && (
          <span className="group relative inline-flex cursor-help">
            <span
              tabIndex={0}
              aria-label={titleHint}
              className="inline-flex h-4 w-4 items-center justify-center rounded-full text-[var(--color-text-mute)] transition hover:text-[var(--color-text)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25"
            >
              <HelpCircle size={13} />
            </span>
            <span
              role="tooltip"
              className="pointer-events-none absolute left-full top-1/2 z-[80] ml-2 hidden w-[300px] -translate-y-1/2 whitespace-normal rounded-md bg-[var(--color-text)] px-2.5 py-2 text-left text-[12px] font-normal leading-relaxed text-white shadow-lg group-hover:block group-focus-within:block"
            >
              {titleHint}
            </span>
          </span>
        )}
      </div>
      {description && <p className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">{description}</p>}
    </div>
  )
}

export type AgentCollaborationSectionHandle = {
  save: () => Promise<void>
}

export type AgentA2ACardSectionHandle = {
  save: () => Promise<void>
}

type AgentA2ACardAPI = {
  get: (agentUuid: string) => Promise<AdminAgentA2ACardDTO>
  update: (agentUuid: string, body: AdminAgentA2ACardDTO) => Promise<AdminAgentA2ACardDTO>
}

export const AgentA2ACardSection = forwardRef<AgentA2ACardSectionHandle, {
  agentUuid: string
  api?: AgentA2ACardAPI
  loadingLabel?: string
  errorPrefix?: string
}>(function AgentA2ACardSection({
  agentUuid,
  api = AdminAgentA2ACard,
  loadingLabel = '协作说明加载中...',
  errorPrefix = '协作说明保存失败，页面已刷新为服务端当前说明',
}, ref) {
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [summary, setSummary] = useState('')
  const [whenToUseText, setWhenToUseText] = useState('')
  const [whenNotToUseText, setWhenNotToUseText] = useState('')
  const [examplesText, setExamplesText] = useState('[]')
  const [inputSchemaText, setInputSchemaText] = useState('{}')
  const [outputSchemaText, setOutputSchemaText] = useState('{}')
  const [supportedModes, setSupportedModes] = useState<string[]>(['sync', 'async'])
  const [riskLevel, setRiskLevel] = useState<'low' | 'medium' | 'high'>('low')
  const [requiresApproval, setRequiresApproval] = useState(false)
  const [cardVersion, setCardVersion] = useState(0)

  const applyCard = useCallback((card: AdminAgentA2ACardDTO) => {
    setSummary(card.summary || '')
    setWhenToUseText((card.when_to_use || []).join('\n'))
    setWhenNotToUseText((card.when_not_to_use || []).join('\n'))
    setExamplesText(JSON.stringify(card.examples || [], null, 2))
    setInputSchemaText(JSON.stringify(card.input_schema || {}, null, 2))
    setOutputSchemaText(JSON.stringify(card.output_schema || {}, null, 2))
    setSupportedModes(card.supported_modes?.length ? card.supported_modes : ['sync', 'async'])
    setRiskLevel(card.risk_level || 'low')
    setRequiresApproval(!!card.requires_approval)
    setCardVersion(card.card_version || 0)
  }, [])

  const reloadCard = useCallback(async () => {
    const card = await api.get(agentUuid)
    applyCard(card)
  }, [agentUuid, api, applyCard])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- agentUuid/API 变化时重新进入加载态, 避免展示上一条说明。
    setLoading(true)
    setErr('')
    api.get(agentUuid)
      .then((card) => {
        if (!cancelled) applyCard(card)
      })
      .catch((e: Error) => {
        if (!cancelled) setErr(e.message)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => { cancelled = true }
  }, [agentUuid, api, applyCard])

  const saveCard = useCallback(async () => {
    if (loading) {
      throw new Error('协作说明仍在加载，请稍后再保存。')
    }
    setErr('')
    try {
      const inputSchema = parseObjectJSON(inputSchemaText, '输入格式')
      const outputSchema = parseObjectJSON(outputSchemaText, '输出格式')
      const examples = parseExamplesJSON(examplesText)
      const card: AdminAgentA2ACardDTO = {
        schema_version: 'a2a-card-1',
        summary: summary.trim(),
        when_to_use: splitLines(whenToUseText),
        when_not_to_use: splitLines(whenNotToUseText),
        examples,
        input_schema: inputSchema,
        output_schema: outputSchema,
        supported_modes: supportedModes,
        risk_level: riskLevel,
        requires_approval: requiresApproval,
        card_version: cardVersion,
      }
      const nextCard = await api.update(agentUuid, card)
      applyCard(nextCard)
    } catch (e) {
      const message = (e as Error).message
      await reloadCard().catch(() => {})
      setErr(`${errorPrefix}：${message}`)
      throw new Error(message, { cause: e })
    }
  }, [
    agentUuid,
    api,
    loading,
    inputSchemaText,
    outputSchemaText,
    examplesText,
    summary,
    whenToUseText,
    whenNotToUseText,
    supportedModes,
    riskLevel,
    requiresApproval,
    cardVersion,
    applyCard,
    reloadCard,
    errorPrefix,
  ])

  useImperativeHandle(ref, () => ({ save: saveCard }), [saveCard])

  if (loading) {
    return <div className="text-[13px] text-[var(--color-text-mute)]">{loadingLabel}</div>
  }

  return (
    <div className="space-y-6">
      {err && <InlineAlert>{err}</InlineAlert>}
      <section>
        <CollaborationSectionHeader
          title="协作说明"
          description="用一段说明和必要边界，帮助其他数字员工判断是否请求它协助。"
        />
        <textarea
          value={summary}
          onChange={(e) => setSummary(e.target.value)}
          rows={3}
          aria-label="协作说明"
          className={textareaCls}
          placeholder="例如：查询客户跟进记录，汇总销售进展并给出下一步建议。"
        />
      </section>

      <section className="border-t border-[var(--color-line-soft)] pt-5">
        <CollaborationSectionHeader
          title="使用边界（选填）"
          titleHint="说明不要交给它处理的事项；没有特殊限制可以留空。"
        />
        <textarea
          value={whenNotToUseText}
          onChange={(e) => setWhenNotToUseText(e.target.value)}
          rows={4}
          aria-label="使用边界"
          className={textareaCls}
          placeholder="例如：不处理审批、价格确认、跨租户数据或不可逆操作。"
        />
        <div className="mt-4">
          <details className="rounded-md border border-[var(--color-line)] bg-white p-4">
            <summary className="cursor-pointer text-[13px] font-medium text-[var(--color-text)]">开发者高级设置（选填）</summary>
            <div className="mt-4 grid grid-cols-1 gap-x-6 gap-y-4 md:grid-cols-2">
              <div className="md:col-span-2">
                <FormField label="典型使用场景" hint="选填。需要更精细地指导其他数字员工选择协作对象时再填写，每行一个场景。">
                  <textarea
                    value={whenToUseText}
                    onChange={(e) => setWhenToUseText(e.target.value)}
                    rows={4}
                    className={textareaCls}
                    placeholder={'例如：需要查询客户最近跟进记录\n例如：需要汇总某个销售机会的当前进展'}
                  />
                </FormField>
              </div>
              <FormField label="输入格式" hint="选填；不了解可以保持空对象 {}。">
                <textarea value={inputSchemaText} onChange={(e) => setInputSchemaText(e.target.value)} rows={6} className={`${textareaCls} font-mono`} />
              </FormField>
              <FormField label="输出格式" hint="选填；不了解可以保持空对象 {}。">
                <textarea value={outputSchemaText} onChange={(e) => setOutputSchemaText(e.target.value)} rows={6} className={`${textareaCls} font-mono`} />
              </FormField>
              <div className="md:col-span-2">
                <FormField label="示例" hint="选填。用于给其他数字员工参考，不影响权限。">
                  <textarea value={examplesText} onChange={(e) => setExamplesText(e.target.value)} rows={8} className={`${textareaCls} font-mono`} />
                </FormField>
                <div className="mt-2">
                  <Button type="button" variant="secondary" size="sm" onClick={() => setExamplesText(`[
  {
    "input": "请查询客户「北京明远科技」最近 30 天的跟进记录，并给出下一步建议",
    "expect": "返回客户跟进摘要、关键风险、待办事项和建议动作"
  }
]`)}>
                    插入示例
                  </Button>
                </div>
              </div>
            </div>
          </details>
        </div>
        <div className="mt-5 flex items-center justify-between border-t border-[var(--color-line-soft)] pt-4">
          <div className="text-[12px] text-[var(--color-text-mute)]">说明版本：{cardVersion}</div>
          <div className="text-[12px] text-[var(--color-text-mute)]">高级字段未填写时可保持默认，不影响基础协作权限。</div>
        </div>
      </section>
    </div>
  )
})

export const AgentCollaborationSection = forwardRef<AgentCollaborationSectionHandle, { agentUuid: string }>(function AgentCollaborationSection({ agentUuid }, ref) {
  const cardRef = useRef<AgentA2ACardSectionHandle>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [agentOptions, setAgentOptions] = useState<AgentFull[]>([])
  const [invokeEnabled, setInvokeEnabled] = useState(true)
  const [callable, setCallable] = useState<AdminAgentCallableDTO>(defaultCallableConfig)

  useEffect(() => {
    let cancelled = false
    Promise.all([
      AdminAgentA2AInvokeCapability.get(agentUuid),
      AdminAgentCallable.get(agentUuid),
      loadWhitelistAgents(agentUuid),
    ])
      .then(([cap, callableCfg, agents]) => {
        if (cancelled) return
        setInvokeEnabled(!!cap.enabled)
        setCallable({
          mode: callableCfg.mode || defaultCallableConfig.mode,
          agent_ids: callableCfg.agent_ids || [],
        })
        setAgentOptions(agents)
      })
      .catch((e: Error) => {
        if (!cancelled) setErr(e.message)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => { cancelled = true }
  }, [agentUuid])

  const saveCollaboration = useCallback(async () => {
    if (loading) {
      throw new Error('协作配置仍在加载，请稍后再保存。')
    }
    setErr('')
    try {
      const callableBody: AdminAgentCallableDTO = {
        mode: callable.mode,
        agent_ids: callable.mode === 'explicit' ? callable.agent_ids : [],
      }
      if (callableBody.mode === 'explicit' && callableBody.agent_ids.length === 0) {
        throw new Error('显式白名单至少选择一个可调用方。')
      }
      await AdminAgentA2AInvokeCapability.update(agentUuid, { enabled: invokeEnabled })
      await AdminAgentCallable.update(agentUuid, callableBody)
      if (!cardRef.current) {
        throw new Error('协作说明仍在加载，请稍后再保存。')
      }
      await cardRef.current.save()
    } catch (e) {
      const message = (e as Error).message
      await refetchCollaborationState(agentUuid, setInvokeEnabled, setCallable, setAgentOptions).catch(() => {})
      setErr(`协作设置保存失败，页面已刷新为服务端当前配置：${message}`)
      throw new Error(message, { cause: e })
    }
  }, [
    agentUuid,
    loading,
    invokeEnabled,
    callable,
  ])

  useImperativeHandle(ref, () => ({ save: saveCollaboration }), [saveCollaboration])

  if (loading) {
    return <div className="text-[13px] text-[var(--color-text-mute)]">协作配置加载中...</div>
  }

  return (
    <div className="space-y-6">
      {err && <InlineAlert>{err}</InlineAlert>}

      <section>
        <CollaborationSectionHeader
          title="协作权限"
          description="设置它能不能请求别人，以及哪些数字员工可以请求它。"
        />
        <div className="grid grid-cols-1 gap-4 rounded-md border border-[var(--color-line)] bg-white px-3 py-4 md:grid-cols-[1fr_1.4fr] md:items-center md:gap-6">
          <div className="flex min-h-10 items-center justify-between gap-4 md:border-r md:border-[var(--color-line)] md:pr-6">
            <div className="flex items-center gap-1.5 text-[13px] font-medium text-[var(--color-text)]">
              <span>允许请求协助</span>
              <span className="group relative inline-flex cursor-help">
                <span
                  tabIndex={0}
                  aria-label="开启后，它可以在处理任务时请求其他已授权数字员工协助。"
                  className="inline-flex h-4 w-4 items-center justify-center rounded-full text-[var(--color-text-mute)] transition hover:text-[var(--color-text)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25"
                >
                  <HelpCircle size={13} />
                </span>
                <span
                  role="tooltip"
                  className="pointer-events-none absolute left-full top-1/2 z-[80] ml-2 hidden w-[260px] -translate-y-1/2 whitespace-normal rounded-md bg-[var(--color-text)] px-2.5 py-2 text-left text-[12px] font-normal leading-relaxed text-white shadow-lg group-hover:block group-focus-within:block"
                >
                  开启后，它可以在处理任务时请求其他已授权数字员工协助。
                </span>
              </span>
            </div>
            <Switch checked={invokeEnabled} onChange={setInvokeEnabled} ariaLabel="允许请求协助" />
          </div>
          <div className="grid grid-cols-1 gap-3 md:grid-cols-[auto_1fr] md:items-center">
            <div className="whitespace-nowrap text-[13px] font-medium text-[var(--color-text)]">谁可以请求它</div>
            <Select
              value={callable.mode}
              onChange={(e) => setCallable({ mode: e.target.value as AdminAgentCallableDTO['mode'], agent_ids: [] })}
            >
              <option value="none">暂不允许</option>
              <option value="all">允许本租户全部数字员工</option>
              <option value="workspace">允许同部门数字员工</option>
              <option value="explicit">仅允许指定数字员工</option>
            </Select>
          </div>
          {callable.mode === 'explicit' && (
            <div className="md:col-span-2">
              <FormField as="div" label="指定数字员工">
                <SearchableMultiSelect
                  options={agentOptions.map((a) => ({
                    value: a.UUID,
                    label: a.Name,
                    hint: a.Status,
                    description: a.Intro || a.Description,
                    iconUrl: a.AvatarURL,
                    iconText: (a.Name || 'A').slice(0, 1),
                  }))}
                  value={callable.agent_ids}
                  onChange={(agent_ids) => setCallable((prev) => ({ ...prev, agent_ids }))}
                  placeholder="选择可以请求它的数字员工..."
                  emptyHint="暂无可选数字员工"
                />
              </FormField>
            </div>
          )}
        </div>
      </section>

      <div className="border-t border-[var(--color-line-soft)] pt-5">
        <AgentA2ACardSection ref={cardRef} agentUuid={agentUuid} />
      </div>
    </div>
  )
})

async function loadWhitelistAgents(excludeAgentUuid: string) {
  const limit = 100
  const max = 1000
  const out: AgentFull[] = []
  for (let offset = 0; offset < max; offset += limit) {
    const page = await AgentsAdmin.list(limit, offset)
    const items = page.items || []
    out.push(...items.filter((a) => a.UUID !== excludeAgentUuid))
    if (items.length < limit || offset + limit >= page.total) {
      break
    }
  }
  return out
}

async function refetchCollaborationState(
  agentUuid: string,
  setInvokeEnabled: (enabled: boolean) => void,
  setCallable: (callable: AdminAgentCallableDTO) => void,
  setAgentOptions: (agents: AgentFull[]) => void,
) {
  const [cap, callableCfg, agents] = await Promise.all([
    AdminAgentA2AInvokeCapability.get(agentUuid),
    AdminAgentCallable.get(agentUuid),
    loadWhitelistAgents(agentUuid),
  ])
  setInvokeEnabled(!!cap.enabled)
  setCallable({
    mode: callableCfg.mode || defaultCallableConfig.mode,
    agent_ids: callableCfg.agent_ids || [],
  })
  setAgentOptions(agents)
}

function AgentAvatarUploader({
  draft,
  patch,
  agentUuid,
  uploadScope,
  disabled,
}: {
  draft: AgentDraft
  patch: (p: Partial<AgentDraft>) => void
  agentUuid?: string
  uploadScope: 'tenant' | 'platform'
  disabled?: boolean
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const avatarSrc = draft.AvatarPreviewURL || ''
  const [failedSrc, setFailedSrc] = useState('')
  const showImage = avatarSrc !== '' && failedSrc !== avatarSrc

  const onFile = async (file?: File) => {
    if (!file) return
    if (file.size > AGENT_AVATAR_MAX_BYTES) {
      setErr('头像文件不能超过 5MB')
      return
    }
    setBusy(true)
    setErr('')
    try {
      const out = await AgentsAdmin.uploadAvatar(file, agentUuid, uploadScope)
      patch({ AvatarURL: out.storage_uri, AvatarPreviewURL: out.signed_url || URL.createObjectURL(file) })
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <FormField label="头像" as="div">
        <div className="flex flex-wrap items-center gap-3">
          <div className="grid h-20 w-20 shrink-0 place-items-center overflow-hidden rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]">
            {showImage ? (
              <img src={avatarSrc} alt={`${draft.Name || '数字员工'}头像`} className="h-full w-full object-cover" onError={() => setFailedSrc(avatarSrc)} />
            ) : (
              <Bot size={26} />
            )}
          </div>
          <input
            ref={inputRef}
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp"
            className="hidden"
            onChange={(e) => onFile(e.target.files?.[0])}
          />
          <div className="min-w-0 space-y-2">
            <div className="flex flex-wrap gap-2">
              <Button type="button" variant="secondary" size="sm" disabled={disabled || busy} onClick={() => inputRef.current?.click()}>
                {draft.AvatarURL ? <Camera size={13} /> : <ImagePlus size={13} />}
                {busy ? '上传中...' : draft.AvatarURL ? '更换头像' : '上传头像'}
              </Button>
              {draft.AvatarURL && (
                <Button type="button" variant="ghost" size="sm" disabled={disabled || busy} onClick={() => patch({ AvatarURL: '', AvatarPreviewURL: '' })}>
                  <X size={13} /> 移除
                </Button>
              )}
            </div>
            <div className="flex items-center gap-1.5 text-[11px] text-[var(--color-text-mute)]">
              <Upload size={12} />
              <span>支持 PNG / JPG / WebP / GIF，最大 5MB，建议 1MB 以内。</span>
            </div>
            {err && <InlineAlert>{err}</InlineAlert>}
          </div>
        </div>
      </FormField>
    </div>
  )
}

function ToggleChip({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button
      type="button"
      onClick={() => onChange(!checked)}
      className={`inline-flex h-8 items-center gap-2 rounded-md border px-3 text-[12px] transition ${
        checked
          ? 'border-emerald-200 bg-[var(--color-success-bg)] text-[var(--color-success)]'
          : 'border-[var(--color-line)] bg-white text-[var(--color-text-sub)] hover:bg-[var(--color-bg-sub)]'
      }`}
    >
      <span className={`h-2 w-2 rounded-full ${checked ? 'bg-[var(--color-success)]' : 'bg-[var(--color-text-mute)]'}`} />
      {label}
    </button>
  )
}

function DisabledPool({ title }: { title: string }) {
  return (
    <div className="rounded-lg border border-dashed border-[var(--color-line)] bg-[var(--color-bg-sub)] p-4">
      <div className="text-[13px] font-medium text-[var(--color-text)]">{title}</div>
      <div className="mt-2 text-[12px] leading-relaxed text-[var(--color-text-mute)]">暂未接入可选数据，先保留装配位置。</div>
    </div>
  )
}

function runtimeLabel(r: RuntimeEnv) {
  return r.Name || r.Code || '未命名运行环境'
}

function runtimeUnavailableReason(r: RuntimeEnv, context: AgentEditorContext) {
  const reasons: string[] = []
  if (context === 'platformPreset') {
    if (r.Scope !== 'platform') reasons.push('不是平台运行环境')
    if (!r.OpenToTenants) reasons.push('尚未对租户开放')
  } else if (r.Scope === 'platform' && !r.EnablementUUID) reasons.push('尚未对本租户启用')
  if (r.Status !== 'active') reasons.push('未启用')
  if (r.LastProbeStatus !== 'ok') reasons.push('连通性未通过')
  if (r.EgressAuditStatus !== 'approved') reasons.push('出境审核未通过')
  return reasons.length > 0 ? reasons.join('、') : '状态待确认'
}

function isRuntimeSelectableForAgent(r: RuntimeEnv, context: AgentEditorContext) {
  if (context === 'platformPreset') return r.Scope === 'platform' && !!r.OpenToTenants && isRuntimeBindableForAgent(r)
  if (r.Scope === 'platform' && !r.EnablementUUID) return false
  return isRuntimeBindableForAgent(r)
}

function kbKindLabel(kind?: string) {
  if (kind === 'personal') return '个人'
  if (kind === 'tenant') return '租户'
  return kind || '-'
}

function splitLines(value: string) {
  return value.split('\n').map((it) => it.trim()).filter(Boolean)
}

function parseObjectJSON(value: string, label: string): Record<string, unknown> {
  const parsed = JSON.parse(value || '{}')
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
    throw new Error(`${label} 必须是 JSON object。`)
  }
  return parsed as Record<string, unknown>
}

function parseExamplesJSON(value: string) {
  const parsed = JSON.parse(value || '[]')
  if (!Array.isArray(parsed)) {
    throw new Error('示例必须是 JSON array。')
  }
  return parsed.map((item, idx) => {
    if (!item || typeof item !== 'object' || typeof item.input !== 'string') {
      throw new Error(`示例第 ${idx + 1} 项必须包含 input 字符串。`)
    }
    return {
      input: item.input,
      expect: typeof item.expect === 'string' ? item.expect : undefined,
    }
  })
}

const textareaCls = 'min-h-[96px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-relaxed text-[var(--color-text)] outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]'
