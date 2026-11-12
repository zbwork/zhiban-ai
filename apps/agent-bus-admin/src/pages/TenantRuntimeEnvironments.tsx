// 租户视角 · 智能体托管环境 (4 层模型 L3)
//
// 一页讲清:
//   - 顶部一行 chip = L1 Agent 平台类型 (只读, 与平台一致)
//   - 列表两段:
//       * 「我已启用的环境」: platform_enabled + tenant_custom 混合; 用 内联开关启停 / 编辑 / 删除
//       * 「平台开放可启用环境」: platform_available 只读卡 + 开关 (off→on = enable)
//   - 卡片上展示后端 join 出来的: 托管机制 (clawmanager / k8s_native) / 探活 / 对租户开放 角标
//
// 视觉与平台托管页 (RuntimeHosting.tsx v5) 对齐:
//   - 细 ring + 浅蓝 line-soft 悬停 + emerald 内联开关
//   - 不再用旧的圆角填充卡 (`--color-fill-bg`)
import { useCallback, useEffect, useMemo, useState } from 'react'
import clsx from 'clsx'
import {
  TenantRuntimeEnvs,
  PlatformTypes as PlatformTypesAPI,
  type TenantRuntimeEnvList,
  type RuntimeEnv,
  type ProbeResult,
  type CreateCustomEnvInput,
  type HostingConfig,
  type HostingProbeResult,
  type PlatformType,
} from '../lib/api'
import { EMPTY_CFG, cfgWithKindDefaults, fieldErrorsForHostingConfigValidation, validateHostingConfig, hostingKindLabel } from '../lib/hostingConfig'
import { RuntimeHostingForm } from '../components/runtime-hosting/RuntimeHostingForm'
import { controlPlaneCapsFromRuntimeCard, mergeRuntimeDisplayCaps } from '../components/runtime-hosting/capabilities'
import {
  Activity, AlertTriangle, CheckCircle2, Cpu, Plug, Plus,
  RefreshCw, Server, ShieldCheck,
} from 'lucide-react'
import { Button, DrawerShell, EmptyState, FormSection, HelpLabel, InlineAlert, Input, PageHeader, Pagination, PrimaryButton, Select, Toolbar } from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { secretRefToDisplay } from '../components/form/secretValue'

export function TenantRuntimeEnvironments() {
  const confirmAction = useConfirmDialog()
  const initialOpen = useMemo(() => {
    if (typeof window === 'undefined') return false
    return new URL(window.location.href).searchParams.get('openAddDialog') === '1'
  }, [])
  const [data, setData] = useState<TenantRuntimeEnvList | null>(null)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [total, setTotal] = useState(0)
  const [openAdd, setOpenAdd] = useState(initialOpen)
  const [editing, setEditing] = useState<RuntimeEnv | null>(null)

  const reload = useCallback(() => {
    setLoading(true)
    TenantRuntimeEnvs.list(pageSize, (page - 1) * pageSize)
      .then((d) => { setData(d); setTotal(d.total || 0); setErr('') })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [page, pageSize])

  // eslint-disable-next-line react-hooks/set-state-in-effect -- 列表初次加载/翻页触发，跟外部数据源同步是 useEffect 合理用法
  useEffect(() => { reload() }, [reload])

  const enable = useCallback(async (uuid: string, asDefault = false) => {
    try { await TenantRuntimeEnvs.enable(uuid, asDefault); reload() }
    catch (e) { setErr((e as Error).message) }
  }, [reload])
  const disable = useCallback(async (enUUID: string) => {
    const ok = await confirmAction.confirm({
      title: '撤销启用环境',
      description: '撤销启用后，该环境将不再可被新的数字员工绑定；若已被数字员工使用，系统会拒绝操作。',
      confirmLabel: '撤销启用',
      tone: 'warn',
    })
    if (!ok) return
    try { await TenantRuntimeEnvs.disable(enUUID); reload() }
    catch (e) { setErr((e as Error).message) }
  }, [confirmAction, reload])
  const deleteCustom = useCallback(async (uuid: string) => {
    const ok = await confirmAction.confirm({
      title: '删除自建环境',
      description: '删除后该自建环境不可再被数字员工绑定；若仍被数字员工使用，系统会拒绝删除。',
      confirmLabel: '删除',
    })
    if (!ok) return
    try { await TenantRuntimeEnvs.deleteCustom(uuid); reload() }
    catch (e) { setErr((e as Error).message) }
  }, [confirmAction, reload])

  // Flat 行: platform_enabled + tenant_custom + platform_available; 每行带 section 决定开关 / 操作。
  const rows = useMemo<Array<{ env: RuntimeEnv; section: Section }>>(() => {
    if (!data) return []
    return [
      ...data.platform_enabled.map((env) => ({ env, section: 'enabled-platform' as Section })),
      ...data.tenant_custom.map((env) => ({ env, section: 'custom' as Section })),
      ...data.platform_available.map((env) => ({ env, section: 'available' as Section })),
    ]
  }, [data])

  return (
    <div>
      {confirmAction.dialog}
      {/* ========== Header (与平台托管页对齐) ========== */}
      <PageHeader
        title="智能体托管环境"
        subtitle="管理可供数字员工使用的运行环境。你可以启用平台提供的环境，也可以新增外部智能体接入；连通性测试通过后即可绑定数字员工。"
      />

      {err && (
        <div className="text-[12.5px] p-3 rounded-md mb-4 flex items-start gap-2 text-rose-700 bg-rose-50 ring-1 ring-rose-200">
          <AlertTriangle size={14} className="mt-0.5 shrink-0" />
          <span>{err}</span>
        </div>
      )}

      {/* ========== Toolbar (按钮上移至表格上方) ========== */}
      <Toolbar
        summary={
          <>
            共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 条环境
            {data && (
              <span className="ml-2 text-[var(--color-text-mute)]">
                （平台可用 {data.platform_enabled.length} · 自建 {data.tenant_custom.length} · 待启用 {data.platform_available.length}）
              </span>
            )}
          </>
        }
        actions={
          <>
            <Button variant="ghost" size="sm" onClick={reload}>
              <RefreshCw size={13} /> 刷新
            </Button>
            <PrimaryButton onClick={() => setOpenAdd(true)}>新建托管</PrimaryButton>
          </>
        }
      />

      {/* ========== Table (单表 = 一行一个环境) ========== */}
      <EnvTable
        rows={rows}
        loading={loading}
        onEnable={(r) => enable(r.env.UUID, false)}
        onDisable={(r) => disable(r.env.EnablementUUID)}
        onEdit={(r) => setEditing(r.env)}
        onDelete={(r) => deleteCustom(r.env.UUID)}
        onAdd={() => setOpenAdd(true)}
      />
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {(openAdd || editing) && (
        <CustomEnvDialog
          editing={editing}
          onClose={() => { setOpenAdd(false); setEditing(null) }}
          onSaved={() => { setOpenAdd(false); setEditing(null); reload() }}
        />
      )}
    </div>
  )
}

type Section = 'enabled-platform' | 'available' | 'custom'

// ============================================================================
// EnvTable: 单表 = 一行一个环境 (与平台托管页 v5 一致的版式)
// ============================================================================

const COLS = 'grid grid-cols-[minmax(240px,2fr)_120px_minmax(160px,1.2fr)_120px_120px_130px_160px]'

function EnvTable({
  rows, loading, onEnable, onDisable, onEdit, onDelete, onAdd,
}: {
  rows: Array<{ env: RuntimeEnv; section: Section }>
  loading: boolean
  onEnable: (r: { env: RuntimeEnv; section: Section }) => void
  onDisable: (r: { env: RuntimeEnv; section: Section }) => void
  onEdit: (r: { env: RuntimeEnv; section: Section }) => void
  onDelete: (r: { env: RuntimeEnv; section: Section }) => void
  onAdd: () => void
}) {
  return (
    <section className="overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[0_1px_0_rgba(23,23,23,0.02)]">
      <div className={clsx(COLS, 'border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]')}>
        <Col>配置名称</Col>
        <Col>来源</Col>
        <Col>接入方式</Col>
        <Col>连通性</Col>
        <Col>是否启用</Col>
        <Col className="tabular-nums whitespace-nowrap">数字员工数量</Col>
        <Col>操作</Col>
      </div>

      {loading && (
        <div className="px-5 py-12 text-center text-[var(--color-text-mute)] text-[13px] flex items-center justify-center gap-2">
          <RefreshCw size={14} className="animate-spin" /> 加载环境列表…
        </div>
      )}

      {!loading && rows.length === 0 && (
        <EmptyState
          icon={<Server size={22} />}
          title="尚无可用环境"
          description="当前还没有可用环境。你可以新增外部智能体接入，测试连通后用于创建数字员工。"
          action={<Button onClick={onAdd}><Plus size={15} /> 新增托管</Button>}
        />
      )}

      {!loading && rows.map((r) => (
        <EnvRow
          key={r.env.UUID + ':' + r.section}
          env={r.env}
          section={r.section}
          onToggle={() => {
            if (r.section === 'available') return onEnable(r)
            if (r.section === 'enabled-platform') return onDisable(r)
            return onDelete(r) // custom 行: off=删除 (deleteCustom 内部有 confirm)
          }}
          onEdit={() => onEdit(r)}
        />
      ))}
    </section>
  )
}

function Col({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={clsx('px-4 py-3', className)}>{children}</div>
}

function EnvRow({
  env, section, onToggle, onEdit,
}: {
  env: RuntimeEnv
  section: Section
  onToggle: () => void
  onEdit: () => void
}) {
  const Icon: React.ComponentType<{ size?: number; className?: string }> =
    env.Framework === 'openclaw' ? Cpu
      : env.Framework === 'hermes' ? Server
      : (env.Framework === 'zap' || env.Framework === 'dsh') ? Plug
      : Server
  const isPlatformEnabled = section === 'enabled-platform'
  const isCustom = section === 'custom'
  const switchOn = isPlatformEnabled || isCustom // custom 视为已启用 (它的存在=启用); available off

  return (
    <div className={clsx(COLS, 'items-center text-[13px] border-b border-[var(--color-line-soft)] last:border-b-0 hover:bg-[var(--color-bg-sub)] transition')}>
      {/* 配置名称 */}
      <div className="px-4 py-4 min-w-0">
        <div className="flex items-center gap-2 min-w-0">
          <div className="w-8 h-8 rounded-md bg-[var(--color-line-soft)] ring-1 ring-[var(--color-line)] flex items-center justify-center shrink-0">
            <Icon size={14} className="text-[var(--color-text-sub)]" />
          </div>
          <div className="min-w-0">
            <div className="font-medium text-[var(--color-text)] truncate flex items-center gap-1.5">
              {env.Name || env.UUID}
            </div>
          </div>
        </div>
      </div>

      {/* 来源 */}
      <div className="px-4 py-4">
        <ScopeBadge scope={env.Scope} />
      </div>

      {/* 接入方式只展示 L2 hosting_kind 语义，不混入 L1 平台类型。 */}
      <div className="px-4 py-4">
        <div className="flex flex-wrap items-center gap-1.5">
          <Chip label={runtimeAccessModeLabel(env)} />
          {env.Scope === 'platform' && env.OpenToTenants && (
            <span className="inline-flex items-center gap-1 text-[10.5px] px-1.5 py-0.5 rounded bg-sky-50 text-sky-700 ring-1 ring-sky-100">
              <ShieldCheck size={10} /> 对租户开放
            </span>
          )}
        </div>
      </div>

      {/* 连通性 */}
      <div className="px-4 py-4">
        <ProbeBadge status={env.LastProbeStatus} />
      </div>

      {/* 启用: platform / custom 行统一用内联开关。
            - platform: off=enable / on=disable (走 enablement)
            - custom: 自建环境恒为"启用"状态; 关掉开关即删除 (deleteCustom, 有 confirm 兜底) */}
      <div className="px-4 py-4">
        <RowSwitch
          on={switchOn}
          title={isCustom
            ? '关闭后将删除该自建环境'
            : (switchOn ? '点击撤销启用' : '点击启用')}
          onChange={onToggle}
        />
      </div>

      {/* 数字员工数量 = 当前绑定本环境的 digital_employees 行数 (deleted_at IS NULL);
            后端在 fillBoundAgents 中聚合; >0 时 disable/delete 会被后端拒绝。 */}
      <div className="px-4 py-4 tabular-nums" title="当前绑定该环境的数字员工数；> 0 时不可停用 / 删除">
        <span className="text-[14px] font-semibold text-[var(--color-text)]">{env.BoundAgents}</span>
      </div>

      {/* 操作 — 文字按钮, 与全站 RowActions 风格一致 (品牌蓝/危险红)。 */}
      <div className="-ml-3 px-4 py-3 flex items-center gap-1">
        {/* custom 行: 删除走"启用"开关 (off=删除), 测试入口复用编辑抽屉。 */}
        {isCustom && (
          <>
            <RowAction tone="brand" label="测试" onClick={onEdit} />
            <RowAction tone="brand" label="编辑" onClick={onEdit} />
          </>
        )}
      </div>
    </div>
  )
}

function RowAction({
  label, tone = 'brand', onClick,
}: { label: string; tone?: 'brand' | 'danger'; onClick: () => void }) {
  return (
    <button
      type="button"
      title={label}
      onClick={onClick}
      className={clsx(
        'inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium transition',
        tone === 'brand' && 'text-[var(--color-brand)] hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]',
        tone === 'danger' && 'text-[var(--color-danger)] hover:bg-red-50 hover:text-[var(--color-danger)]',
      )}
    >
      {label}
    </button>
  )
}

function ScopeBadge({ scope }: { scope: string }) {
  if (scope === 'platform')
    return <span className="text-[10.5px] px-1.5 py-0.5 rounded bg-violet-50 text-violet-700 ring-1 ring-violet-100">平台</span>
  if (scope === 'tenant')
    return <span className="text-[10.5px] px-1.5 py-0.5 rounded bg-sky-50 text-sky-700 ring-1 ring-sky-100">租户自建</span>
  return <span className="text-[10.5px] px-1.5 py-0.5 rounded bg-slate-100 text-slate-600 ring-1 ring-slate-200">{scope}</span>
}

function Chip({ label }: { label: string }) {
  return (
    <span className="inline-flex items-center text-[10.5px] text-[var(--color-text-sub)] bg-[var(--color-line-soft)] ring-1 ring-[var(--color-line)] px-1.5 py-0.5 rounded">
      {label}
    </span>
  )
}

function ProbeBadge({ status }: { status?: string }) {
  if (!status) {
    return <span className="text-[10.5px] px-1.5 py-0.5 rounded bg-slate-100 text-slate-600 ring-1 ring-slate-200">未测试</span>
  }
  if (status === 'ok') {
    return (
      <span className="inline-flex items-center gap-1 text-[10.5px] px-1.5 py-0.5 rounded bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200">
        <CheckCircle2 size={10} /> 连通正常
      </span>
    )
  }
  return (
    <span className="inline-flex items-center gap-1 text-[10.5px] px-1.5 py-0.5 rounded bg-rose-50 text-rose-700 ring-1 ring-rose-200">
      <AlertTriangle size={10} /> 连通失败
    </span>
  )
}

function runtimeAccessModeLabel(env: RuntimeEnv) {
  if (env.HostingKind === 'clawmanager' || env.HostingKind === 'k8s_native' || env.HostingKind === 'external_endpoint') {
    return hostingKindLabel(env.HostingKind)
  }
  if (env.Framework === 'zap' || env.Framework === 'dsh') return hostingKindLabel('external_endpoint')
  if (env.Framework === 'openclaw' || env.Framework === 'hermes') return hostingKindLabel('clawmanager')
  return '托管服务'
}

function runtimeMetadata(editing: RuntimeEnv | null, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...(editing?.Metadata || {}), ...extra }
}

function RowSwitch({ on, onChange, title }: { on: boolean; onChange: () => void; title?: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      title={title}
      onClick={onChange}
      className={clsx(
        'relative inline-flex items-center h-5 w-9 rounded-full transition-colors shrink-0',
        'focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-text)]/30',
        on ? 'bg-emerald-500' : 'bg-slate-300',
      )}
    >
      <span className={clsx(
        'inline-block h-4 w-4 rounded-full bg-white shadow-sm transition-transform',
        on ? 'translate-x-[18px]' : 'translate-x-[2px]',
      )} />
    </button>
  )
}

// ============================================================================
// 添加 / 编辑自定义环境 (drawer 样式; 复用原 probe + create 链路)
// ============================================================================

function CustomEnvDialog({ editing, onClose, onSaved }: {
  editing: RuntimeEnv | null
  onClose: () => void
  onSaved: () => void
}) {
  // L1 平台类型 (开 + L2 hosting_kind 候选; 由后端 runtimetype 注册中心给) — ADR-0022 起 zap 也归到这里
  const [platformTypes, setPlatformTypes] = useState<PlatformType[]>([])
  const [name, setName] = useState(editing?.Name || '')
  const [framework, setFramework] = useState(editing?.Framework || 'zap')
  // ADR-0022: 租户也可选 clawmanager / k8s_native (公网可达 K8s/PaaS), 不再仅限 external_endpoint
  const initialKind: 'external_endpoint' | 'clawmanager' | 'k8s_native' =
    (editing?.HostingKind as 'external_endpoint' | 'clawmanager' | 'k8s_native' | undefined) ||
    (editing?.Framework === 'zap' || editing?.Framework === 'dsh' || !editing ? 'external_endpoint' : 'clawmanager')
  const [hostingKind, setHostingKind] = useState<'external_endpoint' | 'clawmanager' | 'k8s_native'>(initialKind)

  // ZAP external_endpoint 字段 (旧版 fields, 当 framework=zap 时使用)
  const [baseURL, setBaseURL] = useState(editing?.PrimaryEndpoint || ((editing?.Endpoints?.['base'] as string) || ''))
  const [credentialRef, setCredentialRef] = useState(editing?.APIKeySecretRef || '')
  const [probeResult, setProbeResult] = useState<ProbeResult | null>(null)

  // K8s/PaaS hosting_kind 字段 (clawmanager / k8s_native)
  const [cfg, setCfg] = useState<HostingConfig>({
    ...EMPTY_CFG,
    external_environment_id: editing?.ExternalEnvironmentID || '',
  })
  const [hostingProbeResult, setHostingProbeResult] = useState<HostingProbeResult | null>(null)
  const patchCfg = (p: Partial<HostingConfig>) => {
    setHostingProbeResult(null)
    setCfg((c) => ({ ...c, ...p }))
  }

  const [probing, setProbing] = useState(false)
  const [err, setErr] = useState('')
  const [saving, setSaving] = useState(false)

  // L1 列表初始化
  useEffect(() => {
    PlatformTypesAPI.list().then((r) => setPlatformTypes(r.items)).catch((e: Error) => setErr(e.message))
  }, [])

  // framework 改变时重置 hosting_kind 到该 framework 第一个候选 (zap → external_endpoint; openclaw/hermes → clawmanager)
  const supportedKinds = useMemo(
    () => (platformTypes.find((t) => t.code === framework)?.hosting_kinds || []) as Array<'external_endpoint' | 'clawmanager' | 'k8s_native'>,
    [platformTypes, framework],
  )
  useEffect(() => {
    if (supportedKinds.length === 0) return
    if (!supportedKinds.includes(hostingKind)) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- framework 切换时把 hosting_kind 同步回当前 framework 的合法子集；platformTypes 异步加载完成后必须兜底回到合法选项
      setHostingKind(supportedKinds[0])
      setProbeResult(null)
      setHostingProbeResult(null)
    }
  }, [supportedKinds, hostingKind])

  const isExternal = hostingKind === 'external_endpoint'
  const runtimeCardForCapability = (hostingProbeResult?.runtime_card || editing?.Metadata?.runtime_card) as Record<string, unknown> | undefined
  const liveCapabilityCaps = hostingProbeResult
    ? mergeRuntimeDisplayCaps(
        hostingProbeResult.supported_control_plane_capabilities,
        hostingProbeResult.agent_instance_initialize_supported,
      )
    : undefined
  const capabilityProbe = isExternal
    ? {
        done: Boolean(hostingProbeResult || editing?.Metadata?.runtime_card),
        supportedCaps: liveCapabilityCaps || controlPlaneCapsFromRuntimeCard(runtimeCardForCapability),
      }
    : undefined
  const fieldErrors = fieldErrorsForHostingConfigValidation(
    isExternal ? currentExternalDraftCfg() : currentDraftCfg(),
    err
  )

  function currentExternalDraftCfg(): HostingConfig {
    return {
      ...cfgWithKindDefaults(
        {
          ...cfg,
          hosting_kind: 'external_endpoint',
          framework,
          scope: 'tenant',
          primary_endpoint: baseURL,
          api_key_secret_ref: credentialRef,
        },
        'external_endpoint',
        framework || 'zap',
      ),
      runtime_environment_id: 0,
      hosting_kind: 'external_endpoint',
      framework: framework || 'zap',
      scope: 'tenant',
      enabled: false,
      open_to_tenants: false,
      workload_env: {},
    }
  }

  function currentDraftCfg(): HostingConfig {
    return {
      ...cfgWithKindDefaults(cfg, hostingKind === 'k8s_native' ? 'k8s_native' : 'clawmanager', framework),
      runtime_environment_id: 0,
      hosting_kind: hostingKind === 'k8s_native' ? 'k8s_native' : 'clawmanager',
      enabled: false,
      open_to_tenants: false,
      workload_env: {},
    }
  }

  const probe = async () => {
    if (isExternal) {
      const draft = currentExternalDraftCfg()
      const validation = validateHostingConfig(draft)
      if (validation) {
        setErr(validation)
        return
      }
      const secretRef = draft.api_key_secret_ref || ''
      const credential = secretRefToDisplay(secretRef).display
      setProbing(true); setErr(''); setProbeResult(null); setHostingProbeResult(null)
      try {
        const hostingRes = await TenantRuntimeEnvs.probeHosting(draft)
        setHostingProbeResult(hostingRes)
        if (hostingRes.status !== 'ok') {
          setErr(`连通性测试失败（${hostingKindLabel(hostingRes.hosting_kind)}，${hostingRes.latency_ms}ms）：${hostingRes.message}`)
          return
        }
        // 保存租户自建 external_endpoint 仍使用后端 probe token 闭环；页面展示统一采用 hosting probe。
        const tokenRes = await TenantRuntimeEnvs.probe({
          framework,
          endpoints: { base: draft.primary_endpoint || '' },
          auth: { kind: 'bearer', secret: credential, secret_ref: secretRef.trim() },
        })
        setProbeResult(tokenRes)
        if (!tokenRes.ok) setErr(`[${tokenRes.error_code}] ${tokenRes.error_message}`)
      } catch (e) { setErr((e as Error).message) }
      finally { setProbing(false) }
      return
    }
    // ADR-0022: clawmanager / k8s_native 走 hosting probe (复用平台 ProbeDraft 不落库)
    setProbing(true); setErr(''); setHostingProbeResult(null)
    try {
      const draft = currentDraftCfg()
      const validation = validateHostingConfig(draft)
      if (validation) { setErr(validation); return }
      const r = await TenantRuntimeEnvs.probeHosting(draft)
      setHostingProbeResult(r)
      if (r.status !== 'ok') {
        setErr(`健康检查失败（${hostingKindLabel(r.hosting_kind)}，${r.latency_ms}ms）：${r.message}`)
      }
    } catch (e) { setErr((e as Error).message) }
    finally { setProbing(false) }
  }

  const probeOk = hostingProbeResult?.status === 'ok'

  const save = async () => {
    if (!name.trim()) { setErr('请填写显示名。'); return }
    const validation = validateHostingConfig(isExternal ? currentExternalDraftCfg() : currentDraftCfg())
    if (validation) { setErr(validation); return }
    if (!probeOk) { setErr('请先完成连通性测试。'); return }
    setSaving(true); setErr('')
    try {
      let payload: CreateCustomEnvInput
      if (isExternal) {
        if (!probeResult?.probe_token) { setErr('请重新测试连通性以获取保存校验令牌。'); setSaving(false); return }
        const draft = currentExternalDraftCfg()
        const secretRef = draft.api_key_secret_ref || ''
        payload = {
          name: name.trim(),
          framework,
          hosting_kind: 'external_endpoint',
          primary_endpoint: draft.primary_endpoint || '',
          api_key_secret_ref: secretRef.trim(),
          external_environment_id: draft.external_environment_id?.trim() || undefined,
          probe_token: probeResult?.probe_token || '',
          metadata: runtimeMetadata(editing, {
            supports_multi_agent: Boolean((hostingProbeResult?.runtime_card as { supports_multi_agent?: boolean } | undefined)?.supports_multi_agent),
            default_agent_key: String((hostingProbeResult?.runtime_card as { default_agent_key?: string } | undefined)?.default_agent_key || ''),
            max_agents: Number((hostingProbeResult?.runtime_card as { max_agents?: number } | undefined)?.max_agents || 0),
            protocol_version: String((hostingProbeResult?.runtime_card as { protocol_version?: string } | undefined)?.protocol_version || ''),
            runtime_card: hostingProbeResult?.runtime_card || {},
          }),
        }
      } else {
        // ADR-0022: 租户自带 K8s/PaaS 托管 — 后端不需要 probe_token, schema 落库即可。
        const draft = currentDraftCfg()
        payload = {
          name: name.trim(),
          framework,
          hosting_kind: hostingKind,
          workload_api_base_url: draft.workload_api_base_url || undefined,
          workload_api_token_secret_ref: draft.workload_api_token_secret_ref || undefined,
          k8s_api_server_url: draft.k8s_api_server_url || undefined,
          k8s_token_secret_ref: draft.k8s_token_secret_ref || undefined,
          k8s_namespace: draft.k8s_namespace || undefined,
          k8s_insecure_skip_verify: draft.k8s_insecure_skip_verify || undefined,
          image_repository: draft.image_repository,
          image_tag: draft.image_tag,
          gateway_port: draft.gateway_port,
          mount_path: draft.mount_path,
          storage_class: draft.storage_class || undefined,
          default_cpu_cores: draft.default_cpu_cores,
          default_memory_gb: draft.default_memory_gb,
          default_disk_gb: draft.default_disk_gb,
          llm_default_model: draft.llm_default_model || undefined,
          http_proxy: draft.http_proxy || undefined,
          https_proxy: draft.https_proxy || undefined,
          no_proxy: draft.no_proxy || undefined,
          metadata: runtimeMetadata(editing),
        }
      }
      if (editing) await TenantRuntimeEnvs.patchCustom(editing.UUID, payload)
      else await TenantRuntimeEnvs.createCustom(payload)
      onSaved()
    } catch (e) { setErr((e as Error).message); setSaving(false) }
  }

  return (
    <DrawerShell
      title={editing ? '编辑托管' : '新增托管'}
      subtitle={isExternal
        ? '选择接入方式，填写服务地址并测试连通；测试通过后即可保存。'
        : '租户自带 K8s/PaaS 资源（公网可达），平台帮你拉起 Agent Pod。'}
      icon={<Plug size={18} />}
      onClose={onClose}
      footer={(
        <div className="flex min-w-0 items-center gap-2">
          <Button onClick={save} disabled={saving}>
            {saving ? '保存中…' : (editing ? '保存配置' : '保存并启用')}
          </Button>
          <Button variant="secondary" onClick={probe} disabled={probing}>
            <Activity size={13} /> {probing ? (isExternal ? '测试中…' : '检查中…') : '测试连通性'}
          </Button>
          <div className="min-w-0 flex-1">
            <TenantProbeFooterStatus
              probing={probing}
              err={err}
              hostingResult={hostingProbeResult}
            />
          </div>
          <Button variant="secondary" onClick={onClose}>取消</Button>
        </div>
      )}
    >
        <div className="space-y-5 text-[13px]">
          {err && <InlineAlert>{err}</InlineAlert>}

          <FormSection title="基础信息">
            <div className="space-y-3">
              <Field label="平台类型 *" help="ZAP 协议适合外部已经跑起来的 Agent 服务；OpenClaw / Hermes 让平台用你提供的 K8s/PaaS 资源拉起 Pod。">
                <Select value={framework} onChange={(e) => { setFramework(e.target.value); setProbeResult(null); setHostingProbeResult(null) }}>
                  <option value="zap">自定义智能体平台（ZAP 协议）</option>
                  <option value="dsh">知办通用运行时（dsh）</option>
                  <option value="openclaw">OpenClaw 智能体接入</option>
                  <option value="hermes">Hermes 智能体接入</option>
                </Select>
              </Field>
              {supportedKinds.length > 1 && (
                <Field label="部署方式 *" help="该平台类型支持的托管机制。">
                  <Select value={hostingKind} onChange={(e) => { setHostingKind(e.target.value as typeof hostingKind); setHostingProbeResult(null) }}>
                    {supportedKinds.map((k) => (
                      <option key={k} value={k}>{hostingKindLabel(k)}</option>
                    ))}
                  </Select>
                </Field>
              )}
              <Field label="显示名 *">
                <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="例如 客服助手" />
              </Field>
            </div>
          </FormSection>

          {/*
            ADR-0025 §2.5 + Codex Phase A 复盘 #4: 租户托管表单也走共享 RuntimeHostingForm,
            与平台页用同一份字段规则 (clawmanager / k8s_native / external_endpoint)。

            注意: 租户 external_endpoint 历史用 baseURL / credentialRef 作为独立 state。
            此处通过 onPatch 拦截 primary_endpoint / api_key_secret_ref, 同步到原有 state；
            页面测试与平台 external 统一走 hosting probe, 额外保留 probe_token 仅用于保存闭环。
          */}
          <RuntimeHostingForm
            scope="tenant"
            hostingKind={hostingKind}
            framework={framework}
            cfg={{
              ...cfg,
              primary_endpoint: baseURL,
              api_key_secret_ref: credentialRef,
            }}
            onPatch={(p) => {
              if (Object.prototype.hasOwnProperty.call(p, 'primary_endpoint')) {
                setErr('')
                setBaseURL(p.primary_endpoint || '')
                setProbeResult(null)
                return
              }
              if (Object.prototype.hasOwnProperty.call(p, 'api_key_secret_ref')) {
                setErr('')
                setCredentialRef(p.api_key_secret_ref || '')
                setProbeResult(null)
                return
              }
              setErr('')
              patchCfg(p)
            }}
            credRefKind="env"
            setCredRefKind={() => { /* tenant external 用 SecretValueField, 不读 credRefKind */ }}
            fieldErrors={fieldErrors}
            probe={capabilityProbe}
          />

        </div>
    </DrawerShell>
  )
}

function TenantProbeFooterStatus({
  probing,
  err,
  hostingResult,
}: {
  probing: boolean
  err: string
  hostingResult: HostingProbeResult | null
}) {
  if (probing) {
    return <span className="text-[12px] text-[var(--color-text-sub)]">正在测试连通性…</span>
  }
  if (err) {
    return <span className="block truncate text-[12px] text-[var(--color-danger)]">{err}</span>
  }
  if (hostingResult?.status === 'ok') {
    return (
      <span className="block truncate text-[12px] text-emerald-700">
        <CheckCircle2 size={11} className="mr-1 inline" /> 测试通过（{hostingResult.latency_ms}ms）：{hostingResult.message || '底层服务可访问，凭证有效。'}
      </span>
    )
  }
  return <span className="text-[12px] text-[var(--color-text-mute)]">测试通过后才能保存。</span>
}

function Field({ label, help, children }: { label: string; help?: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <HelpLabel label={label} hint={help} />
      {children}
    </label>
  )
}
