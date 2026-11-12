import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Bot, Save } from 'lucide-react'
import {
  Button,
  ConfirmDialog,
  EmptyState,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  PrimaryButton,
  Toolbar,
} from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { AgentCard } from '../components/agent/AgentCard'
import {
  AgentA2ACardSection,
  type AgentA2ACardSectionHandle,
  AgentAbilitiesSection,
  AgentBasicSection,
  AgentRuntimeSection,
} from '../components/agent/AgentEditorSections'
import { AgentEditorShell, type AgentEditorStep } from '../components/agent/AgentEditorShell'
import {
  cloudAgentTemplateCreationEnabled,
  emptyAgentDraft,
  fromAgent,
  isRuntimeBindableForAgent,
  isSupportBuiltinDraft,
  normalizeAgentModelOptions,
  toAgentPayload,
  type AgentDraft,
  type AgentModelSelectOption,
} from '../components/agent/AgentEditorModel'
import {
  AgentModelOptions,
  AdminPlatformPresetA2ACard,
  PlatformAppCategories,
  PlatformApps,
  PlatformKB,
  PlatformPresetKBBindings,
  PlatformPresetAgentsAdmin,
  PlatformSkills,
  RuntimeHosting,
  type AgentBinding,
  type AgentFull,
  type App,
  type AppCategory,
  type HostingConfigListItem,
  type RuntimeEnv,
  type SkillCategory,
  type TenantKBItem,
  type TenantSkill,
} from '../lib/api'
import { notifyOk } from '../lib/toast'

// 发布不是步骤：发布为最后一步动作。support_builtin 内置执行器不展示运行配置步骤。
type EditorTab = 'basic' | 'runtime' | 'abilities' | 'collaboration'

export function PlatformPresetAgents() {
  const nav = useNavigate()
  const confirmAction = useConfirmDialog()
  const [items, setItems] = useState<AgentFull[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [runtimeMap, setRuntimeMap] = useState<Map<number, RuntimeEnv>>(() => new Map())

  const reload = useCallback(() => {
    setLoading(true)
    setErr('')
    PlatformPresetAgentsAdmin.list(pageSize, (page - 1) * pageSize)
      .then((r) => {
        setItems(r.items || [])
        setTotal(r.total || 0)
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [page, pageSize])

  // eslint-disable-next-line react-hooks/set-state-in-effect -- 列表页按分页/筛选条件拉取后端数据。
  useEffect(() => { reload() }, [reload])

  useEffect(() => {
    let cancelled = false
    loadTemplateRuntimeConfigs()
      .then((r) => {
        if (cancelled) return
        const runtimes = (r.items || []).map(hostingConfigToRuntimeEnv)
        setRuntimeMap(new Map(runtimes.map((it) => [it.ID, it])))
      })
      .catch(() => {})
    return () => { cancelled = true }
  }, [])

  const deleteAgent = useCallback(async (agent: AgentFull) => {
    const ok = await confirmAction.confirm({
      title: '删除数字员工模版',
      description: <>确认删除「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？删除后将从平台模版列表移除。</>,
      confirmLabel: '删除',
      tone: 'danger',
    })
    if (!ok) return
    try {
      await PlatformPresetAgentsAdmin.remove(agent.UUID)
      if (items.length === 1 && page > 1) setPage(page - 1)
      else reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, items.length, page, reload])

  const publishAgent = useCallback(async (agent: AgentFull) => {
    const isRepublish = agent.Status === 'archived'
    const ok = await confirmAction.confirm({
      title: isRepublish ? '上架数字员工模版' : '发布数字员工模版',
      description: isRepublish
        ? <>确认上架「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？上架后租户侧将重新可见并可使用该平台模版。</>
        : <>确认发布「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？发布后租户侧将可见并可使用该平台模版。</>,
      confirmLabel: isRepublish ? '上架' : '发布',
      tone: 'info',
    })
    if (!ok) return
    try {
      await PlatformPresetAgentsAdmin.publish(agent.UUID)
      notifyOk(`「${agent.Name}」已${isRepublish ? '上架' : '发布'}。`)
      reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, reload])

  const unpublishAgent = useCallback(async (agent: AgentFull) => {
    const ok = await confirmAction.confirm({
      title: '下架数字员工模版',
      description: <>确认下架「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？下架后租户侧将不再直接使用该平台模版，已创建的租户数字员工不会自动删除。</>,
      confirmLabel: '下架',
      tone: 'warn',
    })
    if (!ok) return
    try {
      await PlatformPresetAgentsAdmin.unpublish(agent.UUID)
      notifyOk(`「${agent.Name}」已下架。`)
      reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, reload])

  // doc-15：平台侧**只**空白新建模板，**不再有「从模板创建」**（「从模板创建」只在租户侧、读平台已发布模板）。

  return (
    <Panel className="p-6 md:p-8">
      {confirmAction.dialog}
      <PageHeader
        title="数字员工模版"
        subtitle="管理平台数字员工；发布后由各租户实时只读使用，也可作为创建独立租户员工的模板。"
        className="mb-4"
      />

      {err && <div className="mb-3"><InlineAlert tone="danger">{err}</InlineAlert></div>}

      <Toolbar
        className="mb-5"
        actions={(
          <PrimaryButton onClick={() => nav('/preset-agents/new')}>新建数字员工模版</PrimaryButton>
        )}
      />

      {loading ? (
        <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div>
      ) : items.length > 0 ? (
        <div className="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3">
          {items.map((agent) => (
            <AgentCard
              key={agent.ID}
              agent={agent}
              runtimeEnv={agent.RuntimeEnvironmentID ? runtimeMap.get(agent.RuntimeEnvironmentID) : null}
              onEdit={() => nav(`/preset-agents/${agent.UUID}`)}
              onPublish={() => publishAgent(agent)}
              onUnpublish={() => unpublishAgent(agent)}
              onDelete={() => deleteAgent(agent)}
              allowArchivedPublish
            />
          ))}
        </div>
      ) : (
        <EmptyState
          icon={<Bot size={26} />}
          title="暂无数字员工模版"
          description={cloudAgentTemplateCreationEnabled
            ? '点击右上角「新建数字员工模版」创建本地或云端模板；发布后将作为平台创建的数字员工供租户使用。'
            : '点击右上角「新建数字员工模版」创建用户电脑运行的模板；云端创建暂未开放。'}
        />
      )}

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />
    </Panel>
  )
}

export function PlatformPresetAgentDetail() {
  const { uuid } = useParams()
  const nav = useNavigate()
  const collaborationCardRef = useRef<AgentA2ACardSectionHandle>(null)
  // doc-15：平台编辑/新建页**只**空白创建/编辑模板，不提供「从示例填充」或「从模板创建」。
  const isCreate = !uuid || uuid === 'new'
  const [tab, setTab] = useState<EditorTab>('basic')
  const [agent, setAgent] = useState<AgentFull | null>(null)
  const [draft, setDraft] = useState<AgentDraft>(() => ({
    ...emptyAgentDraft(),
    ...(isCreate && !cloudAgentTemplateCreationEnabled ? { ExecutionLocus: 'local', LocalEngine: 'dsh' } as const : {}),
  }))
  const [runtimes, setRuntimes] = useState<RuntimeEnv[]>([])
  const [skills, setSkills] = useState<TenantSkill[]>([])
  const [skillCategories, setSkillCategories] = useState<SkillCategory[]>([])
  const [apps, setApps] = useState<App[]>([])
  const [appCategories, setAppCategories] = useState<AppCategory[]>([])
  const [kbs, setKbs] = useState<TenantKBItem[]>([])
  const [modelOptions, setModelOptions] = useState<AgentModelSelectOption[]>(() => normalizeAgentModelOptions())
  const [skillUuids, setSkillUuids] = useState<string[]>([])
  const [appUuids, setAppUuids] = useState<string[]>([])
  const [kbUuids, setKbUuids] = useState<string[]>([])
  const [loading, setLoading] = useState(!isCreate)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')
  const [notice, setNotice] = useState('')
  const [confirmAction, setConfirmAction] = useState<'publish' | null>(null)

  useEffect(() => {
    let cancelled = false
    Promise.all([
      AgentModelOptions.platform().catch(() => ({ items: [] })),
      loadTemplateRuntimeConfigs(),
      PlatformSkills.list({ status: 'active', limit: 200, offset: 0 }),
      PlatformApps.list({ status: 'active', limit: 200, offset: 0 }),
      PlatformSkills.listCategories({ status: 'active', limit: 200, offset: 0 }),
      PlatformAppCategories.list({ limit: 200, offset: 0 }),
      PlatformKB.list({ status: 'active', limit: 200, offset: 0 }),
    ]).then(([modelRes, runtimeRes, skillRes, appRes, skillCategoryRes, appCategoryRes, kbRes]) => {
      if (cancelled) return
      setModelOptions(normalizeAgentModelOptions(modelRes.items || []))
      setRuntimes((runtimeRes.items || []).map(hostingConfigToRuntimeEnv))
      setSkills((skillRes.items || []) as TenantSkill[])
      setApps((appRes.items || []).filter(isAgentUsableApp))
      setSkillCategories(skillCategoryRes.items || [])
      setAppCategories(appCategoryRes.items || [])
      setKbs((kbRes.items || []).filter((kb) => kb.provision_status === 'active'))
    }).catch((e: Error) => {
      if (!cancelled) {
        setModelOptions(normalizeAgentModelOptions())
        setErr(e.message)
      }
    })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    if (isCreate || !uuid) {
      return
    }
    Promise.all([
      PlatformPresetAgentsAdmin.get(uuid),
      PlatformPresetKBBindings.list(uuid),
    ])
      .then(([res, kbRes]) => {
        setAgent(res.agent)
        setDraft(fromAgent(res.agent))
        setPlatformBindings(res.bindings || [], setSkillUuids, setAppUuids)
        setKbUuids((kbRes.items || []).map((item) => item.kb_uuid))
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [isCreate, uuid])

  const runtimeOptions = useMemo(() => {
    const platform = runtimes.filter((r) => isRuntimeBindableForAgent(r) && r.OpenToTenants)
    return { platform, tenant: [], all: runtimes }
  }, [runtimes])
  const selectedRuntime = useMemo(
    () => runtimeOptions.all.find((r) => r.ID === draft.RuntimeEnvironmentID) || null,
    [draft.RuntimeEnvironmentID, runtimeOptions.all],
  )
  const isSupportBuiltin = isSupportBuiltinDraft(draft, agent)

  const locked = false
  const patch = (p: Partial<AgentDraft>) => setDraft((d) => ({ ...d, ...p }))

  const steps = useMemo<Array<AgentEditorStep<EditorTab>>>(() => {
    const base: Array<AgentEditorStep<EditorTab>> = [
      { value: 'basic', label: '基础信息', description: '填写数字员工的基础资料' },
      { value: 'abilities', label: '能力装配', description: '选择并装配所需能力' },
    ]
    const ordered: Array<AgentEditorStep<EditorTab>> = isSupportBuiltin ? base : [
      base[0],
      { value: 'runtime', label: '运行配置', description: '配置运行相关的参数与环境' },
      base[1],
    ]
    if (!isCreate) {
      ordered.push({ value: 'collaboration', label: '协作说明', description: '配置租户复制后的默认协作说明' })
    }
    return ordered
  }, [isCreate, isSupportBuiltin])
  const activeTab: EditorTab = (isSupportBuiltin && tab === 'runtime') || (isCreate && tab === 'collaboration') ? 'basic' : tab

  const save = async ({ publish = false }: { publish?: boolean } = {}) => {
    if (isCreate && !cloudAgentTemplateCreationEnabled && draft.ExecutionLocus !== 'local') {
      setErr('云端模板创建暂未开放，请使用用户电脑运行。')
      setTab('runtime')
      return
    }
    if (!draft.Name.trim()) {
      setErr('请填写模版名称')
      setTab('basic')
      return
    }
    if (!isSupportBuiltin && draft.ExecutionLocus !== 'local' && !draft.RuntimeEnvironmentID) {
      setErr('请选择运行环境')
      setTab('runtime')
      return
    }
    if (!isSupportBuiltin && draft.ExecutionLocus !== 'local' && draft.RuntimeEnvironmentID && !selectedRuntime) {
      setErr('当前绑定的运行环境不满足绑定条件，请确认已启用、对租户开放且连通性测试通过后重新选择。')
      setTab('runtime')
      return
    }
    setSaving(true)
    setErr('')
    setNotice('')
    try {
      const normalizedDraft = isSupportBuiltin
        ? { ...draft, RuntimeEnvironmentID: null }
        : draft
      const payload = {
        ...toAgentPayload(normalizedDraft, agent),
        Source: 'platform' as const,
        Visibility: 'platform',
        Status: agent?.Status || 'draft',
        SupportsGroupChat: normalizedDraft.AllowInviteToGroup,
        skill_uuids: skillUuids,
        app_uuids: appUuids,
      }
      let saved = isCreate
        ? await PlatformPresetAgentsAdmin.create(payload)
        : await PlatformPresetAgentsAdmin.update(agent!.UUID, payload)
      try {
        let expectedUpdatedAt = saved.UpdatedAt
        if (!expectedUpdatedAt) {
          const refreshed = await PlatformPresetAgentsAdmin.get(saved.UUID)
          expectedUpdatedAt = refreshed.agent.UpdatedAt
        }
        if (!expectedUpdatedAt) throw new Error('模板更新时间缺失，请刷新后重试。')
        const bindingResult = await PlatformPresetKBBindings.replace(saved.UUID, kbUuids, expectedUpdatedAt)
        saved.UpdatedAt = bindingResult.agent_updated_at
      } catch (e) {
        // 主记录已保存时立即切换到编辑态，避免用户重试后重复创建模板。
        setAgent(saved)
        setDraft(fromAgent(saved))
        if (isCreate) nav(`/preset-agents/${saved.UUID}`, { replace: true })
        throw new Error(`模板已保存，但知识库关联失败：${(e as Error).message}`, { cause: e })
      }
      if (!isCreate && activeTab === 'collaboration') {
        if (!collaborationCardRef.current) {
          throw new Error('协作说明仍在加载，请稍后再保存。')
        }
        await collaborationCardRef.current.save()
      }
      const publishAfterSave = publish || (!isCreate && agent?.Status === 'published')
      if (publishAfterSave) {
        try {
          await PlatformPresetAgentsAdmin.publish(saved.UUID)
          if (!publish) {
            const refreshed = await PlatformPresetAgentsAdmin.get(saved.UUID)
            saved = refreshed.agent
          }
        } catch (e) {
          // 发布失败：保留已保存配置，进入编辑态并给出清晰错误，不丢配置。
          setAgent(saved)
          setDraft(fromAgent(saved))
          setErr(`模板已保存，但生成新发布版本失败：${(e as Error).message}`)
          if (isCreate) nav(`/preset-agents/${saved.UUID}`, { replace: true })
          return
        }
      }
      setAgent(saved)
      setDraft(fromAgent(saved))
      setNotice(publish
        ? '已保存并发布'
        : isCreate
          ? '模版草稿已创建'
          : publishAfterSave
            ? '模板更新已保存并生成新发布版本。平台创建的数字员工将在后续任务中使用最新配置；租户主动从模板创建的独立副本不会自动变更。'
            : '模板更新已保存。租户主动从模板创建的独立副本不会自动变更。')
      if (publish) {
        nav('/preset-agents', { replace: true })
        return
      }
      if (isCreate) nav(`/preset-agents/${saved.UUID}`, { replace: true })
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const refreshAgent = async () => {
    if (!uuid || uuid === 'new') return
    const res = await PlatformPresetAgentsAdmin.get(uuid)
    const kbRes = await PlatformPresetKBBindings.list(uuid)
    setAgent(res.agent)
    setDraft(fromAgent(res.agent))
    setPlatformBindings(res.bindings || [], setSkillUuids, setAppUuids)
    setKbUuids((kbRes.items || []).map((item) => item.kb_uuid))
  }

  if (loading) return <div className="text-[13px] text-[var(--color-text-mute)]">加载中...</div>

  return (
    <AgentEditorShell
      title={isCreate ? '新建数字员工模版' : '编辑数字员工模版'}
      subtitle={isCreate
        ? '按步骤填写资料、选择运行位置与引擎、装配能力；完成后可保存草稿或发布。'
        : isSupportBuiltin
          ? '维护平台模版的基础信息与能力装配；该模板由平台内置客服执行器处理，不需要运行环境。'
          : '维护平台模版的基础信息、运行配置与能力；下架请回到列表卡片菜单操作。'}
      tab={activeTab}
      steps={steps}
      onTabChange={setTab}
      notice={notice}
      error={err}
      backAction={{ label: '返回数字员工模版列表', onClick: () => nav('/preset-agents') }}
      finalActions={isCreate ? (
        <>
          <Button variant="secondary" onClick={() => save()} disabled={saving}>
            <Save size={14} /> {saving ? '保存中...' : '保存草稿'}
          </Button>
          <Button onClick={() => save({ publish: true })} disabled={saving}>
            {saving ? '处理中...' : '保存并发布'}
          </Button>
        </>
      ) : (
        <>
          <Button variant="secondary" onClick={() => save()} disabled={saving}>
            <Save size={14} /> {saving ? '保存中...' : '保存'}
          </Button>
          {agent?.Status === 'draft' && (
            <Button
              onClick={() => setConfirmAction('publish')}
              disabled={saving || !(agent?.Status === 'draft' && (isSupportBuiltin || agent?.execution_locus === 'local' || !!agent?.RuntimeEnvironmentID))}
            >
              发布
            </Button>
          )}
        </>
      )}
    >
      {activeTab === 'basic' && (
        <AgentBasicSection
          draft={draft}
          patch={patch}
          locked={locked}
          showOrgControls={false}
          agentUuid={agent?.UUID}
          uploadScope="platform"
          modelOptions={modelOptions}
          runtimeFramework={runtimeOptions.all.find((r) => r.ID === draft.RuntimeEnvironmentID)?.Framework}
        />
      )}
      {activeTab === 'runtime' && (
        <AgentRuntimeSection
          draft={draft}
          patch={patch}
          locked={locked}
          runtimeOptions={runtimeOptions}
          context="platformPreset"
          allowCreateRuntime={false}
          required
          allowTemplateCloudToLocal={!isCreate}
          description={cloudAgentTemplateCreationEnabled
            ? '选择用户电脑或云端，并配置相应引擎。云端环境须已启用、对租户开放且测试和审核通过。'
            : draft.ExecutionLocus === 'local'
              ? '使用用户电脑运行，选择本地引擎。模板切换不改变已经分发到租户的云端员工。'
              : '已有云端模板可切换为用户电脑运行；保存后只影响未来创建，不改变已分发的租户云端员工。'}
          emptyMessage="暂无可用于数字员工模版的平台运行环境。请先在「平台托管配置」启用、设为对租户开放，并完成连通性测试。"
          emptyAction={{ label: '前往平台托管配置', onClick: () => nav('/runtime-hosting') }}
        />
      )}
      {activeTab === 'abilities' && (
        <AgentAbilitiesSection
          skillsOpts={skills}
          skillCategories={skillCategories}
          skillUuids={skillUuids}
          setSkillUuids={setSkillUuids}
          appsOpts={apps}
          appCategories={appCategories}
          appUuids={appUuids}
          setAppUuids={setAppUuids}
          kbsOpts={kbs}
          kbUuids={kbUuids}
          setKbUuids={setKbUuids}
          knowledgeBaseHint="只展示平台已就绪的知识库；租户从模板创建数字员工时会继承这些绑定。"
        />
      )}
      {activeTab === 'collaboration' && agent?.UUID && (
        <AgentA2ACardSection
          ref={collaborationCardRef}
          agentUuid={agent.UUID}
          api={AdminPlatformPresetA2ACard}
          loadingLabel="模板协作说明加载中..."
          errorPrefix="模板协作说明保存失败，页面已刷新为服务端当前说明"
        />
      )}
      {confirmAction && agent && (
        <ConfirmDialog
          title="发布数字员工模版"
          description={`确认发布「${agent.Name}」？发布后将作为平台创建的数字员工供所有租户只读使用；每次执行读取当前发布版本及最新能力绑定。`}
          confirmLabel="发布"
          tone="info"
          onClose={() => setConfirmAction(null)}
          onConfirm={async () => {
            await PlatformPresetAgentsAdmin.publish(agent.UUID)
            setConfirmAction(null)
            await refreshAgent()
          }}
        />
      )}
    </AgentEditorShell>
  )
}

function isAgentUsableApp(app: App) {
  return app.usageScope !== 'end_user'
}

function setPlatformBindings(
  bindings: AgentBinding[],
  setSkillUuids: (items: string[]) => void,
  setAppUuids: (items: string[]) => void,
) {
  setSkillUuids(uniqueBindingUuids(bindings, 'composer_skill'))
  setAppUuids(uniqueBindingUuids(bindings, 'app'))
}

function uniqueBindingUuids(bindings: AgentBinding[], capabilityKind: string) {
  return [...new Set(
    bindings
      .filter((binding) => binding.CapabilityKind === capabilityKind)
      .map((binding) => binding.CapabilityUUID)
      .filter(Boolean),
  )]
}

// 平台托管配置列表项不携带 supports_multi_agent / default_agent_key / runtime_card
// （API 字段缺口，见 docs/plans/08 C3）。在拿到精确信号前，按 framework 做**保守推导**：
// 已知支持多智能体的 framework 不被当成 single，避免多智能体 Agent Key 的 UI / 校验失效。
// 注：ADR-0025 §2.4 主要以 ZAP 描述 multi-agent；openclaw/hermes 是否多智能体待产品确认（见 doc-08）。
const MULTI_AGENT_FRAMEWORKS = new Set(['zap', 'dsh', 'openclaw', 'hermes'])
function frameworkSupportsMultiAgent(framework?: string): boolean {
  return framework ? MULTI_AGENT_FRAMEWORKS.has(framework) : false
}

function hostingConfigToRuntimeEnv(item: HostingConfigListItem): RuntimeEnv {
  return {
    ID: item.runtime_environment_id,
    UUID: item.runtime_uuid,
    Code: item.runtime_code,
    Name: item.runtime_name,
    Description: '',
    Framework: item.runtime_framework,
    AdapterKind: '',
    Scope: 'platform',
    ImageRepository: item.image_repository || '',
    ImageTag: item.image_tag || '',
    Endpoints: {},
    PrimaryEndpoint: item.primary_endpoint,
    DataEgress: item.data_egress || '',
    EgressAuditStatus: item.egress_audit_status || '',
    Status: item.enabled ? 'active' : 'disabled',
    ProtocolVersion: '',
    ZAPSchemaVersion: '',
    // 缺口降级：framework 推导;DefaultAgentKey/MaxAgents/RuntimeCard 列表 API 不提供，留空。
    SupportsMultiAgent: frameworkSupportsMultiAgent(item.runtime_framework),
    DefaultAgentKey: '',
    MaxAgents: 0,
    RuntimeCard: {},
    APIKeySecretRef: item.api_key_secret_ref || '',
    HostingKind: item.hosting_kind,
    IsPlatformDefault: item.is_platform_default,
    Metadata: {},
    CreatedAt: '',
    UpdatedAt: '',
    BoundAgents: item.active_instance_count || 0,
    IsDefaultForCaller: false,
    EnablementUUID: '',
    LastProbeStatus: item.last_probe_status || '',
    OpenToTenants: item.open_to_tenants,
  }
}

async function loadTemplateRuntimeConfigs() {
  const items: HostingConfigListItem[] = []
  let total: number
  do {
    const page = await RuntimeHosting.listConfigs(100, items.length)
    items.push(...(page.items || []))
    total = page.total || 0
    if (!page.items?.length) break
  } while (items.length < total)
  return { items, total }
}
