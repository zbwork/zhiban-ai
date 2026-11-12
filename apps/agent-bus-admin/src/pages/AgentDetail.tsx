import { useEffect, useMemo, useRef, useState } from 'react'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { Save, Sparkles } from 'lucide-react'
import {
  AgentApps,
  AgentKBBindings,
  AgentModelOptions,
  AgentsAdmin,
  AppCategories,
  Apps,
  Departments,
  Positions,
  TenantKB,
  TenantOwnSkills,
  TenantAgentTemplates,
  TenantRuntimeEnvs,
  TenantSkills,
  type AgentFull,
  type AgentKBBinding,
  type TenantAgentTemplate,
  type App,
  type AppCategory,
  type Department,
  type Position,
  type SkillCategory,
  type TenantKBItem,
  type TenantRuntimeEnvList,
  type TenantSkill,
} from '../lib/api'
import type { PositionsFieldValue } from '../components/PositionsField'
import { Button, ConfirmDialog } from '../components/ui'
import {
  AgentAbilitiesSection,
  AgentBasicSection,
  AgentCollaborationSection,
  AgentRuntimeSection,
  type AgentCollaborationSectionHandle,
} from '../components/agent/AgentEditorSections'
import { AgentEditorShell, type AgentEditorStep } from '../components/agent/AgentEditorShell'
import {
  byokInfoFromAgent,
  emptyAgentDraft,
  fromAgent,
  isSupportBuiltinDraft,
  normalizeAgentModelOptions,
  toAgentPayload,
  type AgentDraft,
  type AgentModelSelectOption,
} from '../components/agent/AgentEditorModel'
import { TenantAgentTemplatePicker } from '../components/agent/TenantAgentTemplatePicker'
import { notifyOk } from '../lib/toast'

// 发布不是步骤：发布为最后一步动作。support_builtin 内置执行器不展示运行配置步骤。
type Tab = 'basic' | 'runtime' | 'abilities' | 'collaboration'

export function AgentDetail() {
  const { uuid } = useParams()
  const location = useLocation()
  const templateUuid = (location.state as { templateUuid?: string } | null)?.templateUuid
  return <AgentDetailEditor key={uuid || '__new__'} uuid={uuid} templateUuid={templateUuid} />
}

function AgentDetailEditor({ uuid, templateUuid }: { uuid?: string; templateUuid?: string }) {
  const nav = useNavigate()
  const isCreate = !uuid
  const appliedExampleRef = useRef(false)
  const collaborationRef = useRef<AgentCollaborationSectionHandle>(null)
  const [tab, setTab] = useState<Tab>('basic')
  const [agent, setAgent] = useState<AgentFull | null>(null)
  const [draft, setDraft] = useState<AgentDraft>(() => emptyAgentDraft())
  const [positions, setPositions] = useState<Position[]>([])
  const [departments, setDepartments] = useState<Department[]>([])
  const [posValue, setPosValue] = useState<PositionsFieldValue>({ positionIds: [], primaryPositionId: null })
  const [runtimeData, setRuntimeData] = useState<TenantRuntimeEnvList | null>(null)
  const [skillsOpts, setSkillsOpts] = useState<TenantSkill[]>([])
  const [skillCategories, setSkillCategories] = useState<SkillCategory[]>([])
  const [appsOpts, setAppsOpts] = useState<App[]>([])
  const [appCategories, setAppCategories] = useState<AppCategory[]>([])
  const [kbsOpts, setKbsOpts] = useState<TenantKBItem[]>([])
  const [modelOptions, setModelOptions] = useState<AgentModelSelectOption[]>(() => normalizeAgentModelOptions())
  const [skillUuids, setSkillUuids] = useState<string[]>([])
  const [appUuids, setAppUuids] = useState<string[]>([])
  const [kbUuids, setKbUuids] = useState<string[]>([])
  const [lockedKBBindings, setLockedKBBindings] = useState<Array<Pick<AgentKBBinding, 'kb_uuid' | 'kb_name'> & Partial<Pick<AgentKBBinding, 'kb_status'>>>>([])
  const [err, setErr] = useState('')
  const [notice, setNotice] = useState('')
  const [loading, setLoading] = useState(!isCreate)
  const [saving, setSaving] = useState(false)
  const [showExamples, setShowExamples] = useState(false)
  const [showSaveConfirm, setShowSaveConfirm] = useState(false)
  const [confirmAction, setConfirmAction] = useState<'publish' | null>(null)

  useEffect(() => {
    if (!uuid) return
    AgentsAdmin.get(uuid)
      .then((res) => {
        setAgent(res.agent)
        setDraft(fromAgent(res.agent))
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [isCreate, uuid])

  useEffect(() => {
    AgentModelOptions.tenant()
      .then((r) => setModelOptions(normalizeAgentModelOptions(r.items || [])))
      .catch(() => setModelOptions(normalizeAgentModelOptions()))
    Departments.list().then((r) => setDepartments(r.items || [])).catch(() => {})
    Positions.list('', 200, 0).then((r) => setPositions(r.items || [])).catch(() => {})
    TenantRuntimeEnvs.list(200, 0).then(setRuntimeData).catch((e: Error) => setErr(e.message))
    TenantSkills.list({ status: 'active', limit: 200 })
      .then((r) => setSkillsOpts((r.items || []).filter((s) => !s.tenant_disabled)))
      .catch(() => {})
    TenantOwnSkills.listCategories({ status: 'active', limit: 200 })
      .then((r) => setSkillCategories(r.items || []))
      .catch(() => {})
    Apps.list({ status: 'active', limit: 200 })
      .then((r) => setAppsOpts((r.items || []).filter(isAgentUsableApp)))
      .catch(() => {})
    AppCategories.list({ limit: 200, offset: 0 })
      .then((r) => setAppCategories(r.items || []))
      .catch(() => {})
    TenantKB.list()
      .then((r) => setKbsOpts((r.items || []).filter(isUsableKB)))
      .catch(() => {})
  }, [])

  useEffect(() => {
    if (!agent?.ID) return
    Positions.listForAgent(agent.ID)
      .then((r) => {
        const items = r.items || []
        setPosValue({
          positionIds: items.map((it) => it.positionId),
          primaryPositionId: items.find((it) => it.isPrimary)?.positionId ?? null,
        })
      })
      .catch(() => {})
  }, [agent?.ID])

  useEffect(() => {
    if (!uuid) return
    AgentApps.list(uuid).then((r) => setAppUuids((r.items || []).map((a) => a.uuid))).catch(() => {})
    TenantSkills.listAgentSkills(uuid)
      .then((r) => {
        const values = (r.items || []).map((it) => it.skill_uuid)
        setSkillUuids(values)
      })
      .catch(() => {})
    AgentKBBindings.list(uuid).then((r) => {
      const items = r.items || []
      setKbUuids(items.filter((it) => it.editable).map((it) => it.kb_uuid))
      setLockedKBBindings(items.filter((it) => !it.editable))
    }).catch(() => {})
  }, [uuid])

  const runtimeOptions = useMemo(() => {
    const platform = runtimeData?.platform_enabled || []
    const tenant = runtimeData?.tenant_custom || []
    return { platform, tenant, all: [...platform, ...tenant] }
  }, [runtimeData])

  const locked = false
  const defaultAgentModel = modelOptions.find((item) => item.default)?.value || modelOptions[0]?.value || 'openai/gpt-5.4'
  const shouldConfirmSave = !isCreate && (agent?.Status === 'published' || agent?.Status === 'grayed')
  const isSupportBuiltin = isSupportBuiltinDraft(draft, agent)
  const patch = (p: Partial<AgentDraft>) => setDraft((d) => ({ ...d, ...p }))

  const steps = useMemo<Array<AgentEditorStep<Tab>>>(() => {
    const base: Array<AgentEditorStep<Tab>> = [
      { value: 'basic', label: '基础信息', description: '填写数字员工的基础资料' },
      { value: 'abilities', label: '能力装配', description: '选择并装配所需能力' },
    ]
    const withRuntime: Array<AgentEditorStep<Tab>> = isSupportBuiltin ? base : [
      base[0],
      { value: 'runtime', label: '运行配置', description: '配置运行相关的参数与环境' },
      base[1],
    ]
    if (!isCreate) {
      return [
        ...withRuntime,
        { value: 'collaboration', label: '协作设置', description: '让它与其他数字员工互相协助' },
      ]
    }
    return withRuntime
  }, [isCreate, isSupportBuiltin])
  const activeTab: Tab = (isSupportBuiltin && tab === 'runtime') || (isCreate && tab === 'collaboration') ? 'basic' : tab

  // doc-15 P6：用平台已发布模板（API DTO）预填当前草稿。
  // Phase 2 (2026-06-08)：普通主路径不再支持高级编排模板：① TenantAgentTemplatePicker 已固定请求
  // kind='single'，UI 不会暴露高级编排模板；② 防御性兜底 —— 若后端/直链异常返回高级编排模板，
  // 这里直接拒绝预填并提示，**不**降级为 single + 写 TemplateSourceUUID（避免 template_source_uuid
  // 幂等/统计/后续升级语义指向一个本租户实际并未拥有结构的模板）。
  const applyTemplate = (t: TenantAgentTemplate) => {
    setShowExamples(false)
    setErr('')
    setNotice('')
    if (t.agent_kind === 'orchestrator') {
      setErr('该模板属于高级编排模板，普通新建入口暂不支持使用。')
      setTab('basic')
      return
    }
    // 能力装配同步预填（技能 / 应用）。技能/应用绑定与基础信息一起带过来，用户可继续在「能力装配」里增删。
    setSkillUuids(t.skill_uuids || [])
    setAppUuids(t.app_uuids || [])
    setLockedKBBindings((t.knowledge_bases || []).map((kb) => ({ kb_uuid: kb.uuid, kb_name: kb.name })))
    const base: Partial<AgentDraft> = {
      Name: t.name,
      Intro: t.intro,
      PositionLabel: t.position_label,
      Description: t.description,
      TagsText: (t.tags || []).join(', '),
      AvatarURL: t.avatar_url,
      AvatarPreviewURL: t.avatar_preview_url || t.avatar_url,
      WelcomeMsg: t.welcome_msg || '',
      SystemPrompt: t.system_prompt || '',
      RuntimeEnvironmentID: t.runtime_environment_id || null,
      ExecutionLocus: t.execution_locus === 'local' ? 'local' : 'cloud',
      LocalEngine: t.execution_locus === 'local' ? t.local_engine || 'dsh' : '',
      AgentKey: '',
      ModelPrimary: t.model_primary || defaultAgentModel,
      AgentKind: 'single',
      TemplateSourceUUID: t.uuid,
      TemplateSourceUpdatedAt: t.updated_at || '',
    }
    patch({ ...base, OrchestrationStrategy: 'manager', ChildAgentUuids: [] })
    setTab('basic')
  }

  useEffect(() => {
    if (!isCreate || appliedExampleRef.current || !templateUuid) return
    appliedExampleRef.current = true
    let cancelled = false
    // doc-15 P6：精确取该模板（不再 list 后 find），fail-closed 由后端 GET 保证。
    TenantAgentTemplates.get(templateUuid)
      .then((t) => {
        if (cancelled) return
        applyTemplate(t)
      })
      .catch((e: Error) => {
        if (cancelled) return
        // 模板不存在 / 已下架（404）→ 友好提示并允许空白新建；其它错误展示后端 message。
        setErr(/404/.test(e.message) ? '未找到该平台模板（可能已下架）。可改为空白新建。' : e.message)
      })
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 按 templateUuid 预填一次，由 appliedExampleRef 守卫。
  }, [isCreate, templateUuid])

  const save = async ({ publish = false }: { publish?: boolean } = {}) => {
    if (!draft.Name.trim()) {
      setErr('请填写名称')
      setTab('basic')
      return
    }
    if (draft.Visibility === 'workspace' && !draft.WorkspaceID) {
      setErr('可见范围为指定部门时必须选择部门')
      setTab('basic')
      return
    }
    if (publish && !isSupportBuiltin && draft.ExecutionLocus !== 'local' && !draft.RuntimeEnvironmentID) {
      setErr('发布前需要绑定可用运行环境')
      setTab('runtime')
      return
    }
    const selectedRt = runtimeOptions.all.find((r) => r.ID === draft.RuntimeEnvironmentID)
    if (!isSupportBuiltin && draft.RuntimeEnvironmentID && !selectedRt) {
      setErr('当前绑定的运行环境不满足绑定条件，请确认已启用且连通性测试通过后重新选择。')
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
      const payload = toAgentPayload(normalizedDraft, agent)
      const savePayload = {
        ...payload,
        position_ids: posValue.positionIds,
        primary_position_id: posValue.primaryPositionId ?? null,
        skill_uuids: skillUuids,
        app_uuids: appUuids,
        kb_uuids: kbUuids,
      }
      let saved = agent
      if (isCreate) {
        saved = await AgentsAdmin.create(savePayload)
      } else if (agent) {
        saved = await AgentsAdmin.update(agent.UUID, savePayload)
      }
      if (!saved) return
      if (publish) {
        try {
          await AgentsAdmin.publish(saved.UUID)
        } catch (e) {
          // 发布失败：保留已创建草稿，进入编辑态并给出清晰错误，不丢配置。
          setAgent(saved)
          setDraft(fromAgent(saved))
          setErr(`草稿已保存，但发布失败：${(e as Error).message}`)
          if (isCreate) nav(`/agents/${saved.UUID}`, { replace: true })
          return
        }
      }
      if (!isCreate && activeTab === 'collaboration' && collaborationRef.current) {
        await collaborationRef.current.save()
      }
      notifyOk(publish ? '已保存并发布。' : isCreate ? '草稿已创建。' : '已保存。')
      nav('/agents', { replace: true, state: { refreshAt: Date.now() } })
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const requestSave = async ({ publish = false }: { publish?: boolean } = {}) => {
    if (!publish && shouldConfirmSave) {
      setShowSaveConfirm(true)
      return
    }
    await save({ publish })
  }

  const refreshAgent = async () => {
    if (!uuid) return
    const res = await AgentsAdmin.get(uuid)
    setAgent(res.agent)
    setDraft(fromAgent(res.agent))
  }

  if (loading) return <div className="text-[13px] text-[var(--color-text-mute)]">加载中...</div>

  const pageSubtitle = isCreate
    ? '按步骤填写资料、绑定运行环境与能力；完成配置后可保存草稿或直接发布。'
    : isSupportBuiltin
      ? '维护基础信息与能力装配；该数字员工由平台内置客服执行器处理，不需要运行环境。'
      : '维护基础信息、运行环境与能力装配；下架请回到列表卡片菜单操作。'

  return (
    <AgentEditorShell
      title={isCreate ? '新建数字员工' : '编辑数字员工'}
      subtitle={pageSubtitle}
      tab={activeTab}
      steps={steps}
      onTabChange={setTab}
      notice={notice}
      error={err}
      backAction={{ label: '返回数字员工列表', onClick: () => nav('/agents') }}
      actions={isCreate ? (
        <Button variant="secondary" onClick={() => setShowExamples(true)} disabled={saving}>
          <Sparkles size={14} /> 从模板创建
        </Button>
      ) : undefined}
      finalActions={isCreate ? (
        <>
          <Button variant="secondary" onClick={() => requestSave()} disabled={saving}>
            <Save size={14} /> {saving ? '保存中...' : '保存草稿'}
          </Button>
          <Button onClick={() => requestSave({ publish: true })} disabled={saving}>
            {saving ? '处理中...' : '保存并发布'}
          </Button>
        </>
      ) : (
        <>
          <Button variant="secondary" onClick={() => requestSave()} disabled={saving}>
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
          positions={positions}
          posValue={posValue}
          onPosChange={setPosValue}
          departments={departments}
          agentUuid={agent?.UUID}
          modelOptions={modelOptions}
          runtimeFramework={runtimeOptions.all.find((r) => r.ID === draft.RuntimeEnvironmentID)?.Framework}
          byokInfo={byokInfoFromAgent(agent)}
        />
      )}
      {activeTab === 'runtime' && (
        <AgentRuntimeSection
          draft={draft}
          patch={patch}
          locked={locked}
          runtimeOptions={runtimeOptions}
          context="tenantAgent"
        />
      )}
      {activeTab === 'abilities' && (
        <AgentAbilitiesSection
          skillsOpts={skillsOpts}
          skillCategories={skillCategories}
          skillUuids={skillUuids}
          setSkillUuids={setSkillUuids}
          appsOpts={appsOpts}
          appCategories={appCategories}
          appUuids={appUuids}
          setAppUuids={setAppUuids}
          kbsOpts={kbsOpts}
          kbUuids={kbUuids}
          setKbUuids={setKbUuids}
          lockedKBBindings={lockedKBBindings}
        />
      )}
      {activeTab === 'collaboration' && agent?.UUID && (
        <AgentCollaborationSection ref={collaborationRef} agentUuid={agent.UUID} />
      )}
      {showExamples && (
        <TenantAgentTemplatePicker onClose={() => setShowExamples(false)} onPick={applyTemplate} />
      )}
      {showSaveConfirm && (
        <ConfirmDialog
          title="确认保存并下发更新？"
          description="保存后，系统会生成新的数字员工配置，并向当前租户下已启动的用户运行实例下发更新任务。在线用户或下次使用该数字员工时，右下角任务面板会显示更新进度。更新完成后，新会话将使用最新配置；历史会话内容不会被修改。"
          confirmLabel="保存并下发"
          tone="info"
          onClose={() => setShowSaveConfirm(false)}
          onConfirm={async () => {
            await save()
            setShowSaveConfirm(false)
          }}
        />
      )}
      {confirmAction && agent && (
        <ConfirmDialog
          title={confirmTitle(confirmAction)}
          description={confirmDescription(confirmAction, agent.Name)}
          confirmLabel="发布"
          tone="info"
          onClose={() => setConfirmAction(null)}
          onConfirm={async () => {
            await AgentsAdmin.publish(agent.UUID)
            setConfirmAction(null)
            await refreshAgent()
          }}
        />
      )}
    </AgentEditorShell>
  )
}

function isUsableKB(k: TenantKBItem) {
  return k.space_kind === 'tenant' &&
    k.visibility === 'tenant' &&
    (k.provision_status || 'active') === 'active' &&
    (k.status || 'active') === 'active'
}

function isAgentUsableApp(app: App) {
  return app.usageScope !== 'end_user'
}

function confirmTitle(action: 'publish') {
  void action
  return '发布数字员工'
}

function confirmDescription(action: 'publish', name: string) {
  void action
  return `确认发布「${name}」？发布后客户端将可见并可使用。`
}
