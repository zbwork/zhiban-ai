// 平台托管配置 · 配置列表为主视图 (4 层模型 §2.3 L2)
//
// 视觉设计要点 (refined editorial admin):
//   - 顶部 header 带细微 hairline + 「新增配置」主行动按钮在右
//   - 一行 stat 卡片: 总配置 / 已启用 / 对租户开放 / 活跃实例
//   - 主体: 单表 = 一行一个 hosting_config; 列里聚合所需信息;
//          行操作: 编辑 / 监控 / 删除
//   - 编辑 / 监控走 slide-over drawer (不再用左右分栏的双视图)
//   - 全局 SRE "实例视图" 收敛到 header 次级按钮, 不再是主入口
//
// 行为契约:
//   - DELETE 仅删 hosting_config 行; runtime_environment 行不动 (后端拒绝条件: 有 active instance)
//   - 编辑保存 / Probe / Ensure 走原有 RuntimeHosting.* API (HostingConfigPanel 复用)
//   - 监控按钮当前先以"该 runtime 实例列表 + Refresh" 形态最小实现 (用户预期"按钮预留", 我们给了真实数据)
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import clsx from 'clsx'
import {
  Runtimes,
  RuntimeHosting,
  PlatformTypes as PlatformTypesAPI,
  type RuntimeEnv,
  type Runtime,
  type HostingConfig,
  type HostingConfigListItem,
  type HostingProbeResult,
  type RuntimeInstance,
  type PlatformType,
  type CreateAgentSdkCredentialResult,
} from '../lib/api'
import {
  Activity, AlertTriangle, Boxes, Check, CheckCircle2, Copy, Cpu,
  Eye, Plug, Plus, RefreshCw,
  Save, Server, X, ShieldCheck, Trash2,
} from 'lucide-react'
import { Button, HelpLabel, PageHeader, Pagination, PrimaryButton, Toolbar } from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { notifyError, notifyOk } from '../lib/toast'
import { randomUUID } from '../lib/uuid'

// 统一用 admin web 全局 token (与 TenantList / KBProviders 一致), 不再自起一套色板。
// var(--color-text) = #171717  /  var(--color-text-sub) = #4d4d4d  /  var(--color-text-mute) = #808080
// var(--color-line) = #dbe6f5 (蓝调中性灰)  /  var(--color-line-soft) = #eef5ff  /  var(--color-bg-sub) = #f8fbff
const TOKEN = {
  ring: 'ring-1 ring-[var(--color-line)]',
  ringHover: 'hover:ring-[var(--color-line)]',
  brand: 'bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)]',
  brandSoft: 'bg-[var(--color-line-soft)]',
  danger: 'text-rose-700 bg-rose-50 ring-1 ring-rose-200',
  emerald: 'text-emerald-700 bg-emerald-50 ring-1 ring-emerald-200',
  amber: 'text-amber-700 bg-amber-50 ring-1 ring-amber-200',
  slate: 'text-slate-600 bg-slate-100 ring-1 ring-slate-200',
}
const BULK_DELETE_CONCURRENCY = 5

// 共享 helpers 抽到 lib/hostingConfig.ts (满足 react-refresh/only-export-components)
import { EMPTY_CFG, fieldErrorsForHostingConfigValidation, hostingKindLabel, validateHostingConfig, cfgWithKindDefaults, normalizeRuntimeRootEndpoint, isZapWire, type HostingKind } from '../lib/hostingConfig'
// ADR-0025 §2.5: hosting_kind 分支字段 (clawmanager / k8s_native / external_endpoint) 统一渲染。
import { RuntimeHostingForm } from '../components/runtime-hosting/RuntimeHostingForm'
import { mergeRuntimeDisplayCaps } from '../components/runtime-hosting/capabilities'
import { CredentialCreatedDialog, RuntimeCredentialPanel } from './AgentSdkCredentials'

// ConfigRow 是表格中的一行: 后端 ListConfigs 返回的列表项 + 一个 synth 的最小 env 给抽屉里复用旧组件。
// 注意: 本页不再对每个 runtime 单独 getConfig / instances ——所有数据来自一次 batch 调用。
// 没有 hosting_config 的历史 runtime 自然不在结果集里 (INNER JOIN), 也就根本不会出现"404"行。
type ConfigRow = {
  env: RuntimeEnv            // synth: 只填渲染抽屉/HostingConfigPanel 需要的字段
  cfg: HostingConfig         // 列表 API 已保证 hosting_config 必定存在
  activeInstances: number
  failedInstances: number
}

// listItemToRow 把后端 batch 项转成内部 ConfigRow。
// synth env 只供 UI 渲染 (Name / Code / Framework / UUID / ID / Scope) + 编辑抽屉里
// HostingConfigPanel 用到的字段; 其它字段保留默认值, 不参与持久化。
function listItemToRow(it: HostingConfigListItem): ConfigRow {
  const { runtime_uuid, runtime_code, runtime_name, runtime_framework, is_platform_default,
    active_instance_count, failed_instance_count, ...cfg } = it
  const env: RuntimeEnv = {
    ID: cfg.runtime_environment_id,
    UUID: runtime_uuid,
    Code: runtime_code,
    Name: runtime_name,
    Framework: runtime_framework,
    Scope: 'platform',
    IsPlatformDefault: is_platform_default,
  } as unknown as RuntimeEnv
  return { env, cfg: cfg as HostingConfig, activeInstances: active_instance_count, failedInstances: failed_instance_count }
}

// ===========================================================================
// 主组件
// ===========================================================================

export function RuntimeHostingPage() {
  const confirmDelete = useConfirmDialog()
  const [searchParams, setSearchParams] = useSearchParams()
  const [rows, setRows] = useState<ConfigRow[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [healthCheckingUUID, setHealthCheckingUUID] = useState('')

  // 抽屉状态 (URL ↔ state 双向同步, 方便直接拷贝链接)
  const editingUUID = searchParams.get('edit') || ''
  const monitoringUUID = searchParams.get('monitor') || ''
  const credentialsUUID = searchParams.get('credentials') || ''
  const createOpen = searchParams.get('new') === '1'

  const setQuery = useCallback((patch: Record<string, string | null>) => {
    const next = new URLSearchParams(searchParams)
    Object.entries(patch).forEach(([k, v]) => {
      if (v === null || v === '') next.delete(k)
      else next.set(k, v)
    })
    setSearchParams(next, { replace: true })
  }, [searchParams, setSearchParams])

  const [reloadTick, setReloadTick] = useState(0)
  // 把 loading 切换 (会触发 cascading rerender) 放在 reload 触发点, 避免在 useEffect 内 setState
  // 命中 react-hooks/set-state-in-effect lint。初始 loading 由 useState 设 true 兜底。
  const reload = useCallback(() => { setLoading(true); setReloadTick((t) => t + 1) }, [])
  const runHealthCheck = useCallback(async (row: ConfigRow) => {
    const name = row.env.Name || row.env.Code
    setHealthCheckingUUID(row.env.UUID)
    try {
      const r = await RuntimeHosting.probe(row.env.UUID)
      setRows((rs) => rs.map((it) => it.env.UUID === row.env.UUID
        ? {
            ...it,
            cfg: {
              ...it.cfg,
              last_probe_status: r.status,
              last_probe_message: r.message,
              last_probe_latency_ms: r.latency_ms,
              last_probed_at: new Date().toISOString(),
            },
          }
        : it))
      if (r.status === 'ok') {
        notifyOk(`「${name}」健康检查通过`)
      } else {
        notifyError(`「${name}」健康检查失败`)
      }
    } catch {
      notifyError(`「${name}」健康检查失败`)
    } finally {
      setHealthCheckingUUID('')
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    // 单次 batch 调用; 后端 INNER JOIN 保证只返回真实存在 hosting_config 的行,
    // 没有 hosting_config 的历史 runtime 不会进列表 ——不再有 N 个 404。
    RuntimeHosting.listConfigs(pageSize, (page - 1) * pageSize)
      .then((r) => {
        if (cancelled) return
        setRows((r.items || []).map(listItemToRow))
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [page, pageSize, reloadTick])

  // 聚合统计 (实例数来自后端聚合, 前端不再各自统计)
  const stats = useMemo(() => {
    const enabled = rows.filter((r) => r.cfg.enabled).length
    const open = rows.filter((r) => r.cfg.open_to_tenants).length
    const activeInst = rows.reduce((s, r) => s + r.activeInstances, 0)
    return { total, enabled, open, activeInst }
  }, [rows, total])

  // 当前选中行 (drawer 数据源)
  const editingRow = useMemo(() => rows.find((r) => r.env.UUID === editingUUID) || null, [rows, editingUUID])
  const monitoringRow = useMemo(() => rows.find((r) => r.env.UUID === monitoringUUID) || null, [rows, monitoringUUID])
  const credentialsRow = useMemo(() => rows.find((r) => r.env.UUID === credentialsUUID) || null, [rows, credentialsUUID])

  return (
    <div>
      {/* ========== Header ========== */}
      <PageHeader
        title="平台托管配置"
        subtitle="管理平台提供给租户使用的托管环境。配置服务地址、资源参数和访问凭证，连通性测试通过后即可启用并开放给租户。"
      />

      {err && (
        <div className={clsx('text-[12.5px] p-3 rounded-md mb-5 flex items-start gap-2', TOKEN.danger)}>
          <AlertTriangle size={14} className="mt-0.5 shrink-0" />
          <span>{err}</span>
        </div>
      )}

      {/* ========== Stat row ========== */}
      <section className="grid grid-cols-4 gap-3 mb-6">
        <StatCard
          label="托管配置总数"
          value={stats.total}
          icon={Boxes}
          hint="包含未启用 / 未对租户开放"
        />
        <StatCard
          label="已启用"
          value={stats.enabled}
          icon={CheckCircle2}
          tone="emerald"
          hint="可用于创建环境"
        />
        <StatCard
          label="对租户开放"
          value={stats.open}
          icon={ShieldCheck}
          tone="brand"
          hint="租户可选择"
        />
        <StatCard
          label="活跃实例"
          value={stats.activeInst}
          icon={Activity}
          tone={stats.activeInst > 0 ? 'amber' : 'slate'}
          hint="当前运行中的实例"
        />
      </section>

      {/* ========== Toolbar (新建 / 刷新 + 计数) ========== */}
      <Toolbar
        summary={<>共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 条托管配置</>}
        actions={
          <>
            <Button variant="ghost" size="sm" onClick={reload}>
              <RefreshCw size={13} /> 刷新
            </Button>
            <PrimaryButton onClick={() => setQuery({ new: '1' })}>新建托管配置</PrimaryButton>
          </>
        }
      />

      {/* ========== Table ========== */}
      <ConfigTable
        rows={rows}
        loading={loading}
        healthCheckingUUID={healthCheckingUUID}
        onEdit={(uuid) => setQuery({ edit: uuid })}
        onCredentials={(uuid) => setQuery({ credentials: uuid })}
        onMonitor={(uuid) => setQuery({ monitor: uuid })}
        onHealthCheck={runHealthCheck}
        onToggle={async (row, field, next) => {
          // 乐观更新 + 失败回滚: PUT hosting-config 整份回去, 仅翻转一位。
          // 后端 guard: 仅 last_probe_status='ok' 才允许 enabled / open_to_tenants 设 true,
          // 否则返 409 "must pass connectivity probe before enabled/open_to_tenants=true",
          if (next && (row.cfg.last_probe_status || '') !== 'ok') {
            notifyError(field === 'enabled'
              ? '请先完成健康检查，通过后再开启。'
              : '请先完成健康检查，通过后再对租户开放。')
            return
          }
          if (field === 'open_to_tenants' && next && !row.cfg.enabled) {
            notifyError('请先开启该托管配置，再对租户开放。')
            return
          }
          const prev = row.cfg[field]
          setRows((rs) => rs.map((r) => r.env.UUID === row.env.UUID
            ? { ...r, cfg: { ...r.cfg, [field]: next } } : r))
          setErr('')
          try {
            await RuntimeHosting.upsertConfig(row.env.UUID, { ...row.cfg, [field]: next })
          } catch (e) {
            // 回滚
            setRows((rs) => rs.map((r) => r.env.UUID === row.env.UUID
              ? { ...r, cfg: { ...r.cfg, [field]: prev } } : r))
            notifyError((e as Error).message)
          }
        }}
        onDelete={async (row) => {
          const ok = await confirmDelete.confirm({
            title: '删除托管配置',
            description: <>确认删除「<span className="font-medium text-[var(--color-text)]">{row.env.Name || row.env.Code}</span>」的托管配置吗？如仍存在运行中的实例，系统会拒绝删除。</>,
            confirmLabel: '删除',
          })
          if (!ok) return
          try {
            await RuntimeHosting.deleteConfig(row.env.UUID)
            reload()
          } catch (e) {
            const msg = (e as Error).message
            // 404: 实际上没 hosting_config (并发删除 / 已被别人删了), 当作成功 + reload 列表。
            if (/not[_\s]?found|404/i.test(msg)) { reload(); return }
            setErr(msg)
          }
        }}
        onCreateNew={() => setQuery({ new: '1' })}
      />
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />
      {confirmDelete.dialog}

      {/* ========== 编辑 Drawer ========== */}
      {editingRow && (
        <SlideOver
          title={`编辑 · ${editingRow.env.Name || editingRow.env.Code}`}
          subtitle={`${frameworkLabel(editingRow.env.Framework)} · ${hostingKindLabel(editingRow.cfg.hosting_kind)}`}
          onClose={() => setQuery({ edit: null })}
        >
          <HostingConfigPanel
            key={editingRow.env.UUID}
            env={editingRow.env}
            initialCfg={editingRow.cfg}
            initialMissing={false}
            onChanged={reload}
            onSaved={() => { reload(); setQuery({ edit: null }) }}
          />
        </SlideOver>
      )}

      {/* ========== 监控 Drawer ========== */}
      {monitoringRow && (
        <SlideOver
          title={`监控 · ${monitoringRow.env.Name || monitoringRow.env.Code}`}
          subtitle="查看该托管环境下的实例运行状态"
          onClose={() => setQuery({ monitor: null })}
          width="wide"
        >
          <RuntimeMonitorPanel env={monitoringRow.env} onChanged={reload} />
        </SlideOver>
      )}

      {/* ========== 凭证 Drawer ========== */}
      {credentialsRow && (
        <SlideOver
          title={`凭证 · ${credentialsRow.env.Name || credentialsRow.env.Code}`}
          subtitle="管理该平台托管 Runtime 用于换发短期 st_ 的长期凭证"
          onClose={() => setQuery({ credentials: null })}
          width="wide"
        >
          <RuntimeCredentialPanel runtime={credentialsRow.env} />
        </SlideOver>
      )}

      {/* ========== 新增配置 Drawer ========== */}
      {createOpen && (
        <SlideOver
          title="新增平台托管配置"
          subtitle="配置平台类型、部署方式和资源参数"
          onClose={() => setQuery({ new: null })}
        >
          <CreateHostingConfigPanel
            onClose={() => setQuery({ new: null })}
            onCreated={() => {
              setQuery({ new: null })
              reload()
            }}
          />
        </SlideOver>
      )}

    </div>
  )
}

// ===========================================================================
// 子组件: StatCard
// ===========================================================================

function StatCard({
  label, value, icon: Icon, hint, tone = 'plain',
}: {
  label: string; value: number; icon: React.ComponentType<{ size?: number; className?: string }>;
  hint?: string;
  tone?: 'plain' | 'emerald' | 'amber' | 'rose' | 'slate' | 'brand'
}) {
  const accentBg: Record<string, string> = {
    plain: 'bg-white',
    brand: 'bg-white',
    emerald: 'bg-white',
    amber: 'bg-white',
    rose: 'bg-white',
    slate: 'bg-white',
  }
  const accentText: Record<string, string> = {
    plain: 'text-[var(--color-text)]',
    brand: 'text-[var(--color-text)]',
    emerald: 'text-emerald-700',
    amber: 'text-amber-700',
    rose: 'text-rose-700',
    slate: 'text-slate-500',
  }
  const iconBg: Record<string, string> = {
    plain: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
    brand: 'bg-[var(--color-brand)] text-white',
    emerald: 'bg-emerald-50 text-emerald-700 ring-1 ring-emerald-100',
    amber: 'bg-amber-50 text-amber-700 ring-1 ring-amber-100',
    rose: 'bg-rose-50 text-rose-700 ring-1 ring-rose-100',
    slate: 'bg-slate-100 text-slate-600',
  }
  return (
    <div className={clsx('relative rounded-lg p-4 transition', TOKEN.ring, TOKEN.ringHover, accentBg[tone])}>
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-[10.5px] uppercase tracking-[0.16em] text-[var(--color-text-mute)]">{label}</div>
          <div className={clsx('mt-1.5 text-[28px] font-semibold leading-none tabular-nums', accentText[tone])}>
            {value}
          </div>
          {hint && (
            <div className="mt-2 text-[11px] text-[var(--color-text-mute)]">{hint}</div>
          )}
        </div>
        <div className={clsx('w-9 h-9 rounded-md flex items-center justify-center', iconBg[tone])}>
          <Icon size={16} />
        </div>
      </div>
    </div>
  )
}

// ===========================================================================
// 子组件: ConfigTable (主列表)
// ===========================================================================

function ConfigTable({
  rows, loading, healthCheckingUUID, onHealthCheck, onEdit, onCredentials, onMonitor, onToggle, onDelete, onCreateNew,
}: {
  rows: ConfigRow[]; loading: boolean;
  healthCheckingUUID: string;
  onHealthCheck: (row: ConfigRow) => void;
  onEdit: (uuid: string) => void;
  onCredentials: (uuid: string) => void;
  onMonitor: (uuid: string) => void;
  onToggle: (row: ConfigRow, field: 'enabled' | 'open_to_tenants', next: boolean) => void;
  onDelete: (row: ConfigRow) => void;
  onCreateNew: () => void;
}) {
  return (
    <section className="overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[0_1px_0_rgba(23,23,23,0.02)]">
      <div className="grid grid-cols-[minmax(220px,2fr)_minmax(120px,0.9fr)_minmax(140px,1fr)_110px_110px_80px_330px] border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
        <Col>配置名称</Col>
        <Col>平台类型</Col>
        <Col>部署方式</Col>
        <Col>是否启用</Col>
        <Col>对租户开放</Col>
        <Col className="tabular-nums">实例</Col>
        <Col>操作</Col>
      </div>

      {loading && (
        <div className="px-5 py-12 text-center text-[var(--color-text-mute)] text-[13px] flex items-center justify-center gap-2">
          <RefreshCw size={14} className="animate-spin" /> 加载托管配置…
        </div>
      )}

      {!loading && rows.length === 0 && (
        <EmptyState onCreateNew={onCreateNew} />
      )}

      {!loading && rows.map((row) => (
        <ConfigRowItem
          key={row.env.UUID}
          row={row}
          healthChecking={healthCheckingUUID === row.env.UUID}
          onHealthCheck={() => onHealthCheck(row)}
          onEdit={() => onEdit(row.env.UUID)}
          onCredentials={() => onCredentials(row.env.UUID)}
          onMonitor={() => onMonitor(row.env.UUID)}
          onToggle={(field, next) => onToggle(row, field, next)}
          onDelete={() => onDelete(row)}
        />
      ))}
    </section>
  )
}

function Col({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={clsx('px-4 py-3', className)}>{children}</div>
}

function ConfigRowItem({
  row, healthChecking, onHealthCheck, onEdit, onCredentials, onMonitor, onToggle, onDelete,
}: {
  row: ConfigRow;
  healthChecking: boolean;
  onHealthCheck: () => void;
  onEdit: () => void;
  onCredentials: () => void;
  onMonitor: () => void;
  onToggle: (field: 'enabled' | 'open_to_tenants', next: boolean) => void;
  onDelete: () => void;
}) {
  const { env, cfg, activeInstances: activeInst, failedInstances: failedInst } = row
  const probeOk = (cfg.last_probe_status || '') === 'ok'
  const enabledSwitchTitle = cfg.enabled ? '点击停用' : probeOk ? '点击启用' : '需先完成健康检查'
  const openSwitchTitle = cfg.open_to_tenants
    ? '点击关闭对租户开放'
    : !probeOk
      ? '需先完成健康检查'
      : cfg.enabled
        ? '点击对租户开放'
        : '请先开启该托管配置'

  return (
    <div className="grid grid-cols-[minmax(220px,2fr)_minmax(120px,0.9fr)_minmax(140px,1fr)_110px_110px_80px_330px] items-center text-[13px] border-b border-[var(--color-line-soft)] last:border-b-0 hover:bg-[var(--color-bg-sub)] transition">
      {/* 配置 / Runtime */}
      <div className="px-4 py-4 min-w-0">
        <div className="flex items-center gap-2 min-w-0">
          <FrameworkIcon framework={env.Framework} />
          <div className="min-w-0">
            <div className="font-medium text-[var(--color-text)] truncate">{env.Name || env.Code}</div>
            <div className="text-[11px] font-mono text-[var(--color-text-mute)] truncate">{env.Code}</div>
          </div>
          {env.IsPlatformDefault && (
            <span className="ml-1 text-[9.5px] px-1.5 py-0.5 rounded-sm bg-amber-50 text-amber-700 ring-1 ring-amber-100 uppercase tracking-wider">默认</span>
          )}
        </div>
      </div>

      {/* 平台类型 */}
      <div className="px-4 py-4 min-w-0">
        <span
          title={frameworkLabel(env.Framework)}
          className="inline-flex max-w-full items-center truncate rounded px-2 py-0.5 text-[11.5px] text-[var(--color-brand)] bg-[var(--color-brand-soft)] ring-1 ring-[var(--color-brand-line)]"
        >
          {frameworkLabel(env.Framework)}
        </span>
      </div>

      {/* 部署方式 */}
      <div className="px-4 py-4">
        <HostingKindBadge kind={cfg.hosting_kind} />
      </div>

      {/* 启用 (内联开关) */}
      <div className="px-4 py-4">
        <RowSwitch
          on={cfg.enabled}
          probeOk={probeOk}
          title={enabledSwitchTitle}
          onChange={(next) => onToggle('enabled', next)}
        />
      </div>

      {/* 对租户开放 (内联开关) */}
      <div className="px-4 py-4">
        <RowSwitch
          on={cfg.open_to_tenants}
          probeOk={probeOk}
          title={openSwitchTitle}
          onChange={(next) => onToggle('open_to_tenants', next)}
        />
      </div>

      {/* 实例 */}
      <div className="px-4 py-4 tabular-nums">
        <div className="text-[14px] font-semibold text-[var(--color-text)]">{activeInst}</div>
        {failedInst > 0 && (
          <div className="text-[10px] text-rose-700 mt-0.5">含 {failedInst} 失败</div>
        )}
      </div>

      {/* 操作 — 文字按钮, 与全站 RowActions 风格一致 (品牌蓝/危险红)。 */}
      <div className="-ml-3 px-4 py-3 flex items-center gap-1">
        <RowAction label={healthChecking ? '检查中' : '健康检查'} onClick={onHealthCheck} disabled={healthChecking} />
        <RowAction label="凭证" onClick={onCredentials} />
        <RowAction label="编辑" onClick={onEdit} />
        <RowAction label="监控" onClick={onMonitor} />
        <RowAction label="删除" tone="danger" onClick={onDelete} />
      </div>
    </div>
  )
}

function RowAction({
  label, tone = 'brand', disabled = false, onClick,
}: { label: string; tone?: 'brand' | 'danger'; disabled?: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      title={label}
      disabled={disabled}
      onClick={onClick}
      className={clsx(
        'inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium transition disabled:cursor-not-allowed disabled:opacity-50',
        tone === 'brand' && 'text-[var(--color-brand)] hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]',
        tone === 'danger' && 'text-[var(--color-danger)] hover:bg-red-50 hover:text-[var(--color-danger)]',
      )}
    >
      {label}
    </button>
  )
}

function FrameworkIcon({ framework }: { framework: string }) {
  // ADR-0035: dsh 与 zap 都走外部 endpoint 协议, 图标复用 Plug。
  const map: Record<string, React.ComponentType<{ size?: number; className?: string }>> = {
    openclaw: Cpu, hermes: Server, zap: Plug, dsh: Plug,
  }
  const Icon = map[framework] || Server
  return (
    <div className="w-8 h-8 rounded-md bg-[var(--color-line-soft)] flex items-center justify-center shrink-0 ring-1 ring-[var(--color-line)]">
      <Icon size={14} className="text-[var(--color-text-sub)]" />
    </div>
  )
}

function frameworkLabel(f: string) {
  if (f === 'openclaw') return 'OpenClaw'
  if (f === 'hermes') return 'Hermes'
  if (f === 'zap') return '自定义智能体平台'
  if (f === 'dsh') return '知办通用运行时（dsh）'
  return f || '—'
}

function platformTypeLabel(t: PlatformType) {
  if (t.code === 'zap') return '自定义智能体平台（ZAP 协议）'
  if (t.code === 'dsh') return '知办通用运行时（dsh）'
  if (t.code === 'openclaw') return 'OpenClaw'
  if (t.code === 'hermes') return 'Hermes'
  return t.display_name || t.code
}

function supportedHostingKinds(types: PlatformType[], framework: string, current?: HostingKind): HostingKind[] {
  const fromRegistry = types.find((t) => t.code === framework)?.hosting_kinds as HostingKind[] | undefined
  if (fromRegistry?.length) return fromRegistry
  if (isZapWire(framework)) return ['external_endpoint']
  if (current && current !== 'external_endpoint') return [current]
  return ['clawmanager', 'k8s_native']
}

function HostingKindBadge({ kind }: { kind?: 'clawmanager' | 'k8s_native' | 'external_endpoint' }) {
  if (!kind) return <span className="text-[12px] text-[var(--color-text-mute)]">—</span>
  const labelMap: Record<string, string> = {
    clawmanager: '工作负载服务',
    k8s_native: 'Kubernetes 集群',
    external_endpoint: '外部服务接入',
  }
  return (
    <span className="inline-flex items-center gap-1.5 text-[11.5px] text-[var(--color-text-sub)] bg-[var(--color-line-soft)] ring-1 ring-[var(--color-line)] px-2 py-0.5 rounded">
      {labelMap[kind] || kind}
    </span>
  )
}

// RowSwitch 列表内联开关: off→on 前若 Probe 未通过, 页面层 onToggle 会拦截并用 toast 提示;
// 后端也会兜底 409 拒绝。视觉上禁用态用淡化区分。
function RowSwitch({
  on, probeOk, onChange, title,
}: {
  on: boolean; probeOk: boolean;
  onChange: (next: boolean) => void;
  title?: string;
}) {
  const turningOnBlocked = !on && !probeOk
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      title={title}
      onClick={() => onChange(!on)}
      className={clsx(
        'relative inline-flex items-center h-5 w-9 rounded-full transition-colors',
        'focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-text)]/30',
        on ? 'bg-emerald-500' : turningOnBlocked ? 'bg-slate-200' : 'bg-slate-300',
        turningOnBlocked && 'opacity-70 cursor-help',
      )}
    >
      <span
        className={clsx(
          'inline-block h-4 w-4 rounded-full bg-white shadow-sm transition-transform',
          on ? 'translate-x-[18px]' : 'translate-x-[2px]',
        )}
      />
    </button>
  )
}

function EmptyState({ onCreateNew }: { onCreateNew: () => void }) {
  return (
    <div className="px-5 py-16 text-center">
      <div className="w-14 h-14 mx-auto rounded-xl bg-[var(--color-line-soft)] ring-1 ring-[var(--color-line)] flex items-center justify-center mb-4">
        <Boxes size={22} className="text-[var(--color-text-sub)]" />
      </div>
      <div className="text-[15px] font-medium text-[var(--color-text)]">尚无任何托管配置</div>
      <p className="mt-2 text-[12.5px] text-[var(--color-text-sub)] max-w-md mx-auto leading-relaxed">
        新部署或第一次进入本页时，这里是空的。点击「新增配置」选择平台类型和部署方式，填好服务地址与访问凭证，连通性测试通过后即可启用。
      </p>
      <Button onClick={onCreateNew}>
        <Plus size={15} /> 新增首个配置
      </Button>
    </div>
  )
}

// ===========================================================================
// SlideOver (slide-over drawer)
// ===========================================================================

function SlideOver({
  title, subtitle, onClose, children, width = 'normal',
}: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: React.ReactNode;
  width?: 'normal' | 'wide';
}) {
  const w = width === 'wide' ? 'max-w-[1120px]' : 'max-w-[760px]'
  return (
    <div className="fixed inset-0 z-40 flex" onClick={onClose}>
      <div className="flex-1 bg-black/20 backdrop-blur-[1px] transition" />
      <div
        className={clsx('w-full bg-white shadow-2xl overflow-hidden flex flex-col', w)}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="px-6 py-4 border-b border-[var(--color-line)] flex items-start justify-between gap-3 shrink-0">
          <div className="min-w-0">
            <div className="text-[18px] font-semibold tracking-tight text-[var(--color-text)] truncate">{title}</div>
            {subtitle && <div className="mt-0.5 text-[12px] text-[var(--color-text-sub)] truncate">{subtitle}</div>}
          </div>
          <button
            onClick={onClose}
            className="w-8 h-8 rounded-md flex items-center justify-center text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)]"
            title="关闭"
          ><X size={16} /></button>
        </header>
        <div className="flex-1 overflow-auto px-6 py-5">
          {children}
        </div>
      </div>
    </div>
  )
}

// ===========================================================================
// HostingConfigPanel (编辑表单本体, 复用在编辑 drawer 内)
// ===========================================================================

function HostingConfigPanel({
  env, initialCfg, initialMissing, onChanged, onSaved,
}: {
  env: RuntimeEnv;
  initialCfg: HostingConfig | null;
  initialMissing: boolean;
  onChanged: () => void;
  onSaved?: () => void;
}) {
  const [cfg, setCfg] = useState<HostingConfig>(initialCfg || { ...EMPTY_CFG, runtime_environment_id: env.ID })
  const [types, setTypes] = useState<PlatformType[]>([])
  const [name, setName] = useState(env.Name || '')
  const [framework, setFramework] = useState<string>(initialCfg?.framework || env.Framework || 'openclaw')
  const [hostingKind, setHostingKind] = useState<HostingKind>((initialCfg?.hosting_kind || 'clawmanager') as HostingKind)
  // ADR-0025: edit drawer 也要支持 external_endpoint; 凭证类型默认按现有 ref 前缀回填。
  const initRefKind: 'vault' | 'env' = (initialCfg?.api_key_secret_ref || '').toLowerCase().startsWith('env://') ? 'env' : 'vault'
  const [credRefKind, setCredRefKind] = useState<'vault' | 'env'>(initRefKind)
  const [missing, setMissing] = useState(initialMissing)
  // ADR-0021: 「高级环境参数」textarea 已删, 但保留 envJSON 序列化以向后兼容现有 workload_env jsonb 字段。
  const envJSON = JSON.stringify((initialCfg?.workload_env) || {}, null, 2)
  const [err, setErr] = useState('')
  const [ok, setOk] = useState('')
  const [saving, setSaving] = useState(false)
  const [probing, setProbing] = useState(false)
  // S5e: 最近一次 probe 探测出的对方支持能力 (仅 ZAP/custom runtime_card 声明时非空)。
  const [probeCaps, setProbeCaps] = useState<{ done: boolean; supportedCaps?: Record<string, boolean> } | undefined>(undefined)

  useEffect(() => {
    PlatformTypesAPI.list().then((r) => setTypes(r.items)).catch((e: Error) => setErr(e.message))
  }, [])

  const supportedKinds = supportedHostingKinds(types, framework, hostingKind)

  const patch = (p: Partial<HostingConfig>) => {
    const probeSensitiveKeys: Array<keyof HostingConfig> = [
      'hosting_kind',
      'framework',
      'primary_endpoint',
      'api_key_secret_ref',
      'workload_api_base_url',
      'workload_api_token_secret_ref',
      'k8s_api_server_url',
      'k8s_token_secret_ref',
      'k8s_insecure_skip_verify',
    ]
    const touchesProbeSensitiveField = probeSensitiveKeys.some((key) => Object.prototype.hasOwnProperty.call(p, key))
    if (touchesProbeSensitiveField) {
      setErr('')
      setOk('')
    }
    setCfg((c) => {
      const probeSensitiveChanged = probeSensitiveKeys.some((key) => (
        Object.prototype.hasOwnProperty.call(p, key) && p[key] !== c[key]
      ))
      if (!probeSensitiveChanged) return { ...c, ...p }
      return {
        ...c,
        ...p,
        last_probed_at: null,
        last_probe_status: '',
        last_probe_message: '',
        last_probe_latency_ms: 0,
        multi_tenant_isolation: undefined,
      }
    })
  }

  // ADR-0035: external_endpoint 允许 zap / dsh 两种 framework (走 ZAP 协议),
  // 切 kind/framework 时仅在当前 framework 不是 zap-wire 才默认回落 'zap'。
  const coerceFrameworkForKind = (kind: HostingKind, fw: string): string =>
    kind === 'external_endpoint' ? (isZapWire(fw) ? fw : 'zap') : fw

  const changeHostingKind = (next: HostingKind) => {
    setErr('')
    setOk('')
    setHostingKind(next)
    setCfg((c) => ({
      ...cfgWithKindDefaults({ ...c, hosting_kind: next }, next, coerceFrameworkForKind(next, framework)),
      hosting_kind: next,
      framework: coerceFrameworkForKind(next, framework),
      runtime_environment_id: env.ID,
      last_probed_at: null,
      last_probe_status: '',
      last_probe_message: '',
      last_probe_latency_ms: 0,
      multi_tenant_isolation: undefined,
    }))
  }

  const changeFramework = (next: string) => {
    const kinds = supportedHostingKinds(types, next, hostingKind)
    const nextKind = kinds.includes(hostingKind) ? hostingKind : kinds[0]
    setFramework(next)
    setErr('')
    setOk('')
    setHostingKind(nextKind)
    setCfg((c) => ({
      ...cfgWithKindDefaults({ ...c, hosting_kind: nextKind }, nextKind, next),
      hosting_kind: nextKind,
      framework: coerceFrameworkForKind(nextKind, next),
      runtime_environment_id: env.ID,
      last_probed_at: null,
      last_probe_status: '',
      last_probe_message: '',
      last_probe_latency_ms: 0,
      multi_tenant_isolation: undefined,
    }))
  }

  function currentDraftConfig(parsedEnv: Record<string, string> = {}): HostingConfig {
    const normalized = cfgWithKindDefaults(
      { ...cfg, hosting_kind: hostingKind, framework, workload_env: parsedEnv },
      hostingKind,
      coerceFrameworkForKind(hostingKind, framework),
    )
    return {
      ...normalized,
      runtime_environment_id: env.ID,
      hosting_kind: hostingKind,
      framework: coerceFrameworkForKind(hostingKind, framework),
      scope: 'platform',
      workload_env: hostingKind === 'external_endpoint' ? {} : parsedEnv,
    }
  }

  const fieldErrors = fieldErrorsForHostingConfigValidation(currentDraftConfig(), err)

  async function save() {
    setSaving(true); setErr(''); setOk('')
    try {
      if (!name.trim()) {
        setErr('请填写显示名')
        return
      }
      let parsed: Record<string, string> = {}
      if (envJSON.trim()) parsed = JSON.parse(envJSON) as Record<string, string>
      const draft = currentDraftConfig(parsed)
      const validation = validateHostingConfig(draft)
      if (validation) {
        setErr(validation)
        return
      }
      if (name.trim() !== env.Name || framework !== env.Framework) {
        await Runtimes.update(env.ID, {
          Name: name.trim(),
          Framework: framework,
          // ADR-0035: zap 与 dsh 均走外部 endpoint 协议, AdapterKind='external'。
          AdapterKind: isZapWire(framework) ? 'external' : 'builtin',
        } as Partial<Runtime>)
      }
      await RuntimeHosting.upsertConfig(env.UUID, draft)
      setMissing(false)
      // 保存成功: 优先走 onSaved (会关抽屉 + 刷列表); 兜底 onChanged + 短暂 toast。
      if (onSaved) {
        notifyOk('保存成功')
        onSaved()
        return
      }
      setOk('已保存')
      onChanged()
      setTimeout(() => setOk(''), 2200)
    } catch (e) { setErr((e as Error).message) }
    finally { setSaving(false) }
  }

  // probe 用当前抽屉里的表单内容做 dry-run 探针 (probeDraft), 而不是读 DB 已保存的旧配置;
  // 这样运维改完字段不必先「保存」就能验证连通性。仅当探针通过且最终用户点了「保存配置」,
  // last_probe_* 才会被同时更新到 DB。
  async function probe() {
    setProbing(true); setErr(''); setOk('')
    try {
      let parsed: Record<string, string> = {}
      if (envJSON.trim()) parsed = JSON.parse(envJSON) as Record<string, string>
      const draft = currentDraftConfig(parsed)
      const validation = validateHostingConfig(draft)
      if (validation) {
        setErr(validation)
        return
      }
      const r = await RuntimeHosting.probeDraft(draft)
      if (hostingKind === 'external_endpoint') {
        setCfg((c) => ({ ...c, control_plane_capabilities: r.supported_control_plane_capabilities || {} }))
      }
      // 不论 ok / failed, 都把这次探针结果"投影"到本地 cfg 的 last_probe_* 字段, 让 footer
      // FooterStatus 能立刻显示最新一次结果; 真正落 DB 仍由 save 触发。
      setCfg((c) => ({
        ...c,
        last_probe_status: r.status,
        last_probe_message: r.message,
        last_probe_latency_ms: r.latency_ms,
        last_probed_at: new Date().toISOString(),
      }))
      // 记录对方 runtime_card 声明能力, 供「接口能力」section 展示。
      // agent.instance_initialize 仅展示, 不写入 control_plane_capabilities。
      setProbeCaps({
        done: true,
        supportedCaps: mergeRuntimeDisplayCaps(
          r.supported_control_plane_capabilities,
          r.agent_instance_initialize_supported,
        ),
      })
      if (r.status !== 'ok') {
        setErr(`连通性测试失败（${hostingKindLabel(r.hosting_kind)}，${r.latency_ms}ms）：${r.message}`)
      }
    } catch (e) { setErr((e as Error).message) }
    finally { setProbing(false) }
  }

  return (
    <div className="space-y-5">
      {missing && (
        <div>
          <span className="text-[11.5px] text-amber-700 bg-amber-50 ring-1 ring-amber-100 px-2 py-0.5 rounded">尚未配置 · 保存后即创建</span>
        </div>
      )}

      <HostingBasicSection
        mode="edit"
        name={name}
        framework={framework}
        hostingKind={hostingKind}
        types={types}
        supportedKinds={supportedKinds}
        onNameChange={setName}
        onFrameworkChange={changeFramework}
        onHostingKindChange={changeHostingKind}
      />

      {/* ADR-0025: hosting_kind 分支字段统一走共享组件 RuntimeHostingForm。 */}
      <RuntimeHostingForm
        scope="platform"
        hostingKind={hostingKind}
        framework={framework}
        cfg={{ ...cfg, hosting_kind: hostingKind, framework: coerceFrameworkForKind(hostingKind, framework) }}
        onPatch={patch}
        credRefKind={credRefKind}
        setCredRefKind={setCredRefKind}
        fieldErrors={fieldErrors}
        probe={probeCaps}
      />

      <div className="sticky bottom-[-20px] -mx-6 px-6 py-3 bg-white border-t border-[var(--color-line)] flex items-center gap-2 z-10">
        <button
          onClick={save}
          disabled={saving}
          className={clsx('shrink-0 whitespace-nowrap px-3.5 py-2 rounded-md text-[13px] inline-flex items-center gap-1.5 disabled:opacity-50', TOKEN.brand)}
        ><Save size={14} /> {saving ? '保存中…' : '保存配置'}</button>
        <button
          onClick={probe}
          disabled={probing || missing}
          className="shrink-0 whitespace-nowrap px-3 py-2 rounded-md text-[13px] ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] disabled:opacity-50 inline-flex items-center gap-1.5"
        ><Activity size={14} /> {probing ? '测试中…' : '测试连通性'}</button>

        <FooterStatus
          err={err}
          ok={ok}
          probing={probing}
          saving={saving}
          lastStatus={cfg.last_probe_status}
          lastAt={cfg.last_probed_at ?? undefined}
          lastMessage={cfg.last_probe_message}
          lastLatencyMs={cfg.last_probe_latency_ms}
        />
      </div>
    </div>
  )
}

// FooterStatus 把"保存中/测试中/错误/刚成功/历史最近测试"折叠到右侧一个紧凑状态条;
// 同一时刻只展示当前最有信息量的一种, 避免出现两行状态、两份相同文本的拥挤感。
function FooterStatus({
  err, ok, saving, probing, lastStatus, lastAt, lastMessage, lastLatencyMs,
}: {
  err: string; ok: string; saving: boolean; probing: boolean;
  lastStatus?: string; lastAt?: string; lastMessage?: string; lastLatencyMs?: number;
}) {
  type Tone = 'emerald' | 'rose' | 'slate' | 'amber'
  let tone: Tone
  let dotPulse = false
  let leadingLabel: string
  let body = ''
  let timeText = ''
  let title = ''

  if (err) {
    tone = 'rose'; leadingLabel = '错误：'; body = err; title = err
  } else if (saving) {
    tone = 'slate'; dotPulse = true; leadingLabel = '保存中…'
  } else if (probing) {
    tone = 'amber'; dotPulse = true; leadingLabel = '测试中…'
  } else if (ok === '已保存') {
    tone = 'emerald'; leadingLabel = '已保存'
  } else if (lastMessage) {
    const isOk = lastStatus === 'ok'
    tone = isOk ? 'emerald' : 'rose'
    const latency = Number.isFinite(lastLatencyMs) && (lastLatencyMs as number) >= 0
      ? `（${lastLatencyMs}ms）`
      : ''
    const verb = isOk ? '测试通过' : '测试失败'
    leadingLabel = `${verb}${latency}：`
    body = isOk ? summarizeProbeSuccess(lastMessage) : lastMessage
    title = isOk ? body : lastMessage
    if (lastAt) timeText = formatRelativeTime(lastAt)
  } else {
    return (
      <span className="ml-auto shrink-0 text-[11px] text-[var(--color-text-mute)]">
        尚未测试连通性
      </span>
    )
  }

  const dotColor: Record<Tone, string> = {
    emerald: 'bg-emerald-500',
    rose: 'bg-rose-500',
    amber: 'bg-amber-500',
    slate: 'bg-slate-400',
  }
  const labelColor: Record<Tone, string> = {
    emerald: 'text-emerald-700',
    rose: 'text-rose-700',
    amber: 'text-amber-700',
    slate: 'text-[var(--color-text-sub)]',
  }

  // copyable: 完整可复制的文本 (label + body), 给 Copy 按钮用; 不含状态点等装饰性内容。
  const copyable = body ? `${leadingLabel}${body}` : leadingLabel

  return (
    <div
      role="status"
      title={title}
      className="ml-auto shrink min-w-0 max-w-[520px] inline-flex items-center gap-2 text-[12px]"
    >
      <span className={clsx('relative inline-flex w-1.5 h-1.5 rounded-full shrink-0', dotColor[tone])}>
        {dotPulse && (
          <span className={clsx('absolute inset-0 rounded-full animate-ping opacity-60', dotColor[tone])} />
        )}
      </span>
      <span className={clsx('shrink-0 font-medium', labelColor[tone])}>{leadingLabel}</span>
      {body && (
        <span className="truncate text-[var(--color-text-sub)]">{body}</span>
      )}
      {timeText && (
        <span className="shrink-0 text-[var(--color-text-mute)] tabular-nums">· {timeText}</span>
      )}
      {body && <CopyButton text={copyable} />}
    </div>
  )
}

function summarizeProbeSuccess(message: string): string {
  const text = (message || '').trim()
  if (!text) return ''
  // ZAP external 成功信息会拼接 runtime_card 的 isolation notes; 成功态只展示核心可达性,
  // 失败态才展示完整错误。避免 footer / 原生 title tooltip 被长说明撑满。
  const isolationIdx = text.search(/[;；]\s*隔离声明/)
  if (isolationIdx > 0) return text.slice(0, isolationIdx).trim()
  const firstLine = text.split(/\r?\n/)[0]?.trim() || text
  return firstLine.length > 90 ? `${firstLine.slice(0, 90)}...` : firstLine
}

// CopyButton 把完整错误/消息一键塞进剪贴板; 失败时降级到 document.execCommand('copy')
// (老 Safari / 非 https 场景仍可工作)。复制后 1.5s 内 icon 切到 ✓ 表示成功。
function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  const onCopy = async () => {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
      } else {
        const ta = document.createElement('textarea')
        ta.value = text
        ta.style.position = 'fixed'
        ta.style.opacity = '0'
        document.body.appendChild(ta)
        ta.select()
        document.execCommand('copy')
        document.body.removeChild(ta)
      }
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      notifyError('复制失败，请手动选中文本')
    }
  }
  return (
    <button
      type="button"
      onClick={onCopy}
      title={copied ? '已复制' : '复制完整错误'}
      aria-label="复制完整错误"
      className={clsx(
        'shrink-0 inline-flex items-center justify-center w-6 h-6 rounded',
        'text-[var(--color-text-mute)] hover:text-[var(--color-text)] hover:bg-[var(--color-line-soft)]',
        'transition focus:outline-none focus-visible:ring-1 focus-visible:ring-[var(--color-text)]/30',
        copied && 'text-emerald-600 hover:text-emerald-700',
      )}
    >
      {copied ? <Check size={12} /> : <Copy size={12} />}
    </button>
  )
}

function formatRelativeTime(iso: string): string {
  const t = new Date(iso).getTime()
  if (!Number.isFinite(t)) return ''
  const diff = Date.now() - t
  const sec = Math.round(diff / 1000)
  if (sec < 5) return '刚刚'
  if (sec < 60) return `${sec} 秒前`
  const min = Math.round(sec / 60)
  if (min < 60) return `${min} 分钟前`
  const hr = Math.round(min / 60)
  if (hr < 24) return `${hr} 小时前`
  const day = Math.round(hr / 24)
  if (day < 7) return `${day} 天前`
  return new Date(iso).toLocaleDateString()
}

function Section({ title, desc, children }: { title: string; desc?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg ring-1 ring-[var(--color-line)] bg-white p-4">
      <div className="text-[14px] font-semibold text-[var(--color-text)] mb-2">{title}</div>
      {desc && <p className="text-[11.5px] text-[var(--color-text-sub)] mb-2 leading-relaxed">{desc}</p>}
      {children}
    </section>
  )
}
function Grid2({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 md:grid-cols-2 gap-3">{children}</div>
}
function Field({ label, help, value, onChange, placeholder, mono, disabled }: {
  label: string
  help?: string
  value: string
  onChange: (v: string) => void
  placeholder?: string
  mono?: boolean
  disabled?: boolean
}) {
  return (
    <div>
      <HelpLabel label={label} hint={help} />
      <input
        value={value}
        placeholder={placeholder}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        className={clsx(
          'w-full h-10 px-3 text-[13px] rounded-md ring-1 ring-[var(--color-line)] focus:ring-2 focus:ring-[var(--color-text)]/20 focus:outline-none bg-white',
          mono && 'font-mono text-[12px]',
          disabled && 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)] cursor-not-allowed',
        )}
      />
    </div>
  )
}
function SelectField({ label, value, onChange, children }: { label: string; value: string; onChange: (v: string) => void; children: React.ReactNode }) {
  return (
    <div>
      <label className="text-[13px] font-medium text-[var(--color-text)] mb-1.5 block">{label}</label>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-full h-10 px-3 text-[13px] rounded-md ring-1 ring-[var(--color-line)] focus:ring-2 focus:ring-[var(--color-text)]/20 focus:outline-none bg-white"
      >
        {children}
      </select>
    </div>
  )
}
// NumberField 已移到 components/runtime-hosting/RuntimeHostingForm.tsx (本页 hosting_kind
// 分支字段统一改走 RuntimeHostingForm 后, 局部 NumberField 不再被引用)。

function HostingBasicSection({
  mode, name, framework, hostingKind, types, supportedKinds,
  onNameChange, onFrameworkChange, onHostingKindChange,
}: {
  mode: 'create' | 'edit'
  name: string
  framework: string
  hostingKind: HostingKind
  types: PlatformType[]
  supportedKinds: HostingKind[]
  onNameChange: (v: string) => void
  onFrameworkChange: (v: string) => void
  onHostingKindChange: (v: HostingKind) => void
}) {
  return (
    <Section
      title="基础信息"
      desc={mode === 'create'
        ? '创建后默认不启用、不开放；连通性测试通过后再开启。'
        : '编辑内容与新增配置保持一致。'}
    >
      <Grid2>
        <Field label="显示名 *" value={name} onChange={onNameChange} placeholder="OpenClaw 平台托管 v2" />
        <SelectField label="平台类型" value={framework} onChange={onFrameworkChange}>
          {types.map((t) => (
            <option key={t.code} value={t.code}>{platformTypeLabel(t)}</option>
          ))}
          {types.length === 0 && (
            <option value={framework}>{frameworkLabel(framework)}</option>
          )}
        </SelectField>
        <SelectField label="部署方式" value={hostingKind} onChange={(v) => onHostingKindChange(v as HostingKind)}>
          {supportedKinds.map((k) => (
            <option key={k} value={k}>{hostingKindLabel(k)}</option>
          ))}
        </SelectField>
      </Grid2>
    </Section>
  )
}

// ===========================================================================
// RuntimeMonitorPanel (监控 drawer 内容)
// ===========================================================================

function RuntimeMonitorPanel({ env, onChanged }: { env: RuntimeEnv; onChanged: () => void }) {
  const confirmAction = useConfirmDialog()
  const [items, setItems] = useState<RuntimeInstance[] | null>(null)
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState('')
  const [selectedIDs, setSelectedIDs] = useState<Set<string>>(() => new Set())
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    Runtimes.instances(env.ID)
      .then((r) => {
        if (!cancelled) {
          setItems(r.items || [])
          setSelectedIDs(new Set())
          setErr('')
        }
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
    return () => { cancelled = true }
  }, [env.ID, tick])

  const stats = useMemo(() => {
    const c = { ready: 0, starting: 0, pending: 0, failed: 0, stopped: 0 } as Record<string, number>
    items?.forEach((it) => { c[it.Status] = (c[it.Status] || 0) + 1 })
    return c
  }, [items])
  const errorItems = useMemo(
    () => (items || []).filter((it) => it.Status === 'failed' && it.ErrorMessage),
    [items],
  )
  const selectedItems = useMemo(
    () => (items || []).filter((it) => selectedIDs.has(it.UUID)),
    [items, selectedIDs],
  )
  const allSelected = !!items?.length && selectedIDs.size === items.length
  const someSelected = selectedIDs.size > 0

  function toggleSelect(uuid: string, checked: boolean) {
    setSelectedIDs((prev) => {
      const next = new Set(prev)
      if (checked) next.add(uuid)
      else next.delete(uuid)
      return next
    })
  }

  function toggleSelectAll(checked: boolean) {
    setSelectedIDs(checked ? new Set((items || []).map((it) => it.UUID)) : new Set())
  }

  async function restart(it: RuntimeInstance) {
    const workload = it.K8sDeployment || it.K8sService
    if (!workload) { setErr('该实例缺少工作负载名称'); return }
    const ok = await confirmAction.confirm({
      title: '重启工作负载',
      description: <>确认重启工作负载「<span className="font-medium text-[var(--color-text)]">{workload}</span>」吗？系统会对对应 K8S Deployment 执行滚动重启，访问地址会短暂重新收敛。</>,
      confirmLabel: '重启',
      tone: 'info',
    })
    if (!ok) return
    setBusy(it.UUID); setErr('')
    try { await RuntimeHosting.restartWorkload(env.UUID, workload, it.WorkloadInstanceID); setTick((t) => t + 1); onChanged() }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy('') }
  }
  async function del(it: RuntimeInstance) {
    const workload = it.K8sDeployment || it.K8sService
    if (!workload) { setErr('该实例缺少工作负载名称'); return }
    const ok = await confirmAction.confirm({
      title: '删除工作负载',
      description: <>确认删除工作负载「<span className="font-medium text-[var(--color-text)]">{workload}</span>」吗？OpenClaw 会先清理 Pod 内 /data/.openclaw，再删除对应 K8S Deployment。</>,
      confirmLabel: '删除',
      tone: 'danger',
    })
    if (!ok) return
    setBusy(it.UUID); setErr('')
    try { await RuntimeHosting.deleteWorkload(env.UUID, workload, it.WorkloadInstanceID); setTick((t) => t + 1); onChanged() }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy('') }
  }
  async function deleteSelected() {
    if (selectedItems.length === 0) return
    const ok = await confirmAction.confirm({
      title: '批量删除工作负载',
      description: <>确认删除已选中的 <span className="font-medium text-[var(--color-text)]">{selectedItems.length}</span> 个工作负载吗？系统会逐个复用单实例删除流程，OpenClaw 实例会先清理 Pod 内 /data/.openclaw。</>,
      confirmLabel: '批量删除',
      tone: 'danger',
    })
    if (!ok) return
    setBusy('bulk'); setErr('')
    const deleteOne = async (it: RuntimeInstance) => {
      const workload = it.K8sDeployment || it.K8sService
      if (!workload) return { ok: false, error: `${it.UUID.slice(0, 8)} 缺少工作负载名称` }
      try {
        await RuntimeHosting.deleteWorkload(env.UUID, workload, it.WorkloadInstanceID)
        return { ok: true, error: '' }
      } catch (e) {
        return { ok: false, error: `${workload}: ${(e as Error).message}` }
      }
    }
    const results: Array<{ ok: boolean; error: string }> = []
    for (let i = 0; i < selectedItems.length; i += BULK_DELETE_CONCURRENCY) {
      const batch = selectedItems.slice(i, i + BULK_DELETE_CONCURRENCY)
      results.push(...await Promise.all(batch.map(deleteOne)))
    }
    const failures = results.filter((r) => !r.ok).map((r) => r.error)
    const success = results.length - failures.length
    setSelectedIDs(new Set())
    setTick((t) => t + 1)
    onChanged()
    setBusy('')
    if (failures.length > 0) {
      const detail = failures.slice(0, 3).join('；')
      const more = failures.length > 3 ? `；另有 ${failures.length - 3} 个失败` : ''
      setErr(`批量删除完成：成功 ${success} 个，失败 ${failures.length} 个。${detail}${more}`)
      notifyError('部分工作负载删除失败')
    } else {
      notifyOk(`已提交删除 ${success} 个工作负载`)
    }
  }

  return (
    <div className="space-y-5">
      {confirmAction.dialog}
      <div className="grid grid-cols-5 gap-2">
        <MiniStat label="运行中" value={stats.ready || 0} tone="emerald" />
        <MiniStat label="启动中" value={stats.starting || 0} tone="amber" />
        <MiniStat label="排队中" value={stats.pending || 0} tone="slate" />
        <MiniStat label="失败" value={stats.failed || 0} tone="rose" />
        <MiniStat label="已停止" value={stats.stopped || 0} tone="slate" />
      </div>

      {err && <div className={clsx('text-[12px] p-2 rounded', TOKEN.danger)}>{err}</div>}

      <div className="flex items-center justify-between">
        <div className="text-[11px] text-[var(--color-text-mute)]">
          共 {items?.length || 0} 个实例
          {someSelected && <span className="ml-2 text-[var(--color-text-sub)]">已选 {selectedIDs.size} 个</span>}
        </div>
        <div className="flex items-center gap-2">
          {someSelected && (
            <Button variant="danger" size="sm" onClick={deleteSelected} disabled={busy !== ''}>
              <Trash2 size={13} /> 批量删除
            </Button>
          )}
          <button
            onClick={() => setTick((t) => t + 1)}
            disabled={busy !== ''}
            className="text-[12px] px-2 py-1 rounded ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] disabled:cursor-not-allowed disabled:opacity-60 inline-flex items-center gap-1"
          ><RefreshCw size={11} /> 刷新</button>
        </div>
      </div>

      <div className={clsx('rounded-md overflow-x-auto', TOKEN.ring)}>
        <div className="min-w-[1380px]">
          <div className="grid grid-cols-[44px_1.5fr_0.9fr_0.9fr_0.9fr_0.9fr_1fr_1.15fr_0.7fr_0.85fr] text-[10.5px] uppercase tracking-[0.14em] text-[var(--color-text-mute)] bg-[var(--color-bg-sub)] border-b border-[var(--color-line)]">
            <div className="px-4 py-2.5">
              <input
                type="checkbox"
                aria-label="全选当前实例"
                checked={allSelected}
                aria-checked={allSelected ? true : someSelected ? 'mixed' : false}
                disabled={!items?.length || busy !== ''}
                onChange={(e) => toggleSelectAll(e.target.checked)}
                className="h-4 w-4 rounded border-[var(--color-line)] text-[var(--color-brand)] focus:ring-[var(--color-brand)]/25 disabled:cursor-not-allowed"
              />
            </div>
            <Col>工作负载</Col>
            <Col>租户名称</Col>
            <Col>用户名称</Col>
            <Col>手机号</Col>
            <Col>镜像版本</Col>
            <Col>命名空间</Col>
            <Col>访问地址</Col>
            <Col>状态</Col>
            <Col>操作</Col>
          </div>
        {items === null && <div className="py-8 text-center text-[var(--color-text-mute)] text-[12.5px]">加载中…</div>}
        {items && items.length === 0 && (
          <div className="py-8 text-center text-[var(--color-text-mute)] text-[12.5px]">
            当前托管环境尚无工作负载实例。可在「编辑配置」里部署首个实例。
          </div>
        )}
        {items?.map((it) => (
          <div key={it.UUID} className="grid grid-cols-[44px_1.5fr_0.9fr_0.9fr_0.9fr_0.9fr_1fr_1.15fr_0.7fr_0.85fr] items-center text-[12.5px] border-b border-[var(--color-line-soft)] last:border-b-0 hover:bg-[var(--color-bg-sub)]">
            <div className="px-4 py-2.5">
              <input
                type="checkbox"
                aria-label={`选择工作负载 ${it.K8sDeployment || it.K8sService || it.UUID}`}
                checked={selectedIDs.has(it.UUID)}
                disabled={busy !== ''}
                onChange={(e) => toggleSelect(it.UUID, e.target.checked)}
                className="h-4 w-4 rounded border-[var(--color-line)] text-[var(--color-brand)] focus:ring-[var(--color-brand)]/25 disabled:cursor-not-allowed"
              />
            </div>
            <div className="px-4 py-2.5 font-mono text-[11px] truncate">{it.K8sDeployment || it.K8sService || '—'}</div>
            <div className="px-4 py-2.5 text-[11px] text-[var(--color-text-sub)] truncate">{it.TenantName || '—'}</div>
            <div className="px-4 py-2.5 text-[11px] text-[var(--color-text-sub)] truncate">{it.AccountName || '—'}</div>
            <div className="px-4 py-2.5 font-mono text-[11px] text-[var(--color-text-sub)] truncate">{it.AccountPhone || '—'}</div>
            <div
              className="px-4 py-2.5 font-mono text-[11px] text-[var(--color-text-sub)] truncate"
              title={it.ImageVersion || it.TargetImageVersion || ''}
            >
              {imageVersionLabel(it.ImageVersion || it.TargetImageVersion)}
            </div>
            <div className="px-4 py-2.5 font-mono text-[11px] text-[var(--color-text-sub)]">{it.K8sNamespace || '—'}</div>
            <div className="px-4 py-2.5 font-mono text-[11px] text-[var(--color-text-sub)] truncate">{it.EndpointURL || '—'}</div>
            <div className="px-4 py-2.5"><InstStatus status={it.Status} /></div>
            <div className="-ml-3 px-4 py-2 flex items-center gap-1">
              <RowAction label="重启" onClick={() => restart(it)} disabled={busy !== ''} />
              <RowAction label="删除" tone="danger" onClick={() => del(it)} disabled={busy !== ''} />
              <span className="hidden">{busy === it.UUID ? 'busy' : ''}</span>
            </div>
          </div>
        ))}
        </div>
      </div>

      {errorItems.length > 0 && (
        <div className="space-y-1.5">
          <div className="text-[10.5px] uppercase tracking-[0.14em] text-[var(--color-text-mute)]">错误详情</div>
          {errorItems.map((it) => (
            <div key={'err-' + it.UUID} className={clsx('text-[11.5px] p-2 rounded flex items-start gap-1.5', TOKEN.danger)}>
              <AlertTriangle size={11} className="mt-0.5 shrink-0" />
              <span><span className="font-mono">{it.K8sDeployment || it.UUID.slice(0, 8)}</span>: {it.ErrorMessage}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function MiniStat({ label, value, tone }: { label: string; value: number; tone: 'emerald' | 'amber' | 'rose' | 'slate' }) {
  const m = { emerald: 'text-emerald-700', amber: 'text-amber-700', rose: 'text-rose-700', slate: 'text-slate-600' }[tone]
  return (
    <div className={clsx('rounded-md px-3 py-2 ring-1 ring-[var(--color-line)] bg-white')}>
      <div className="text-[10px] uppercase tracking-[0.14em] text-[var(--color-text-mute)]">{label}</div>
      <div className={clsx('mt-0.5 text-[18px] font-semibold tabular-nums leading-none', m)}>{value}</div>
    </div>
  )
}
function InstStatus({ status }: { status: string }) {
  const m: Record<string, string> = {
    pending: 'bg-slate-100 text-slate-600 ring-slate-200',
    starting: 'bg-amber-50 text-amber-700 ring-amber-200',
    ready: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
    failed: 'bg-rose-50 text-rose-700 ring-rose-200',
    stopped: 'bg-slate-100 text-slate-500 ring-slate-200',
    deleted: 'bg-slate-100 text-slate-500 ring-slate-200',
  }
  const labelMap: Record<string, string> = {
    pending: '排队中', starting: '启动中', ready: '运行中', failed: '失败', stopped: '已停止', deleted: '已删除',
  }
  return (
    <span className={clsx('text-[10.5px] px-2 py-0.5 rounded ring-1 inline-flex items-center gap-1', m[status] || m.pending)}>
      {labelMap[status] || status}
    </span>
  )
}

function imageVersionLabel(imageVersion?: string) {
  if (!imageVersion) return '—'
  const digestIndex = imageVersion.indexOf('@sha256:')
  if (digestIndex >= 0) return imageVersion.slice(digestIndex + 1)
  const tagIndex = imageVersion.lastIndexOf(':')
  return tagIndex >= 0 ? imageVersion.slice(tagIndex + 1) : imageVersion
}

function internalRuntimeCompatCode() {
  return `runtime-${randomUUID()}`
}

// ===========================================================================
// CreateHostingConfigPanel (新建抽屉; 一次填完基础信息 + hosting_config)
// ===========================================================================

function CreateHostingConfigPanel({
  onClose, onCreated,
}: {
  onClose: () => void
  onCreated: () => void
}) {
  const [types, setTypes] = useState<PlatformType[]>([])
  const [framework, setFramework] = useState<string>('openclaw')
  const [hostingKind, setHostingKind] = useState<HostingKind>('clawmanager')
  const [name, setName] = useState('')
  const [cfg, setCfg] = useState<HostingConfig>({ ...EMPTY_CFG })
  // ADR-0021: 新建抽屉「高级环境参数」textarea 已删; workload_env 创建时为空, 不需要状态。
  const envJSON = '{}'
  // 兼容旧 RuntimeHostingForm props；当前表单不展示额外的凭证方案选择，访问凭证由 SecretValueField 内部包装。
  const [credRefKind, setCredRefKind] = useState<'vault' | 'env'>('vault')
  const [busy, setBusy] = useState(false)
  const [probing, setProbing] = useState(false)
  const [probeResult, setProbeResult] = useState<HostingProbeResult | null>(null)
  const [defaultCredential, setDefaultCredential] = useState<CreateAgentSdkCredentialResult | null>(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    PlatformTypesAPI.list().then((r) => setTypes(r.items)).catch((e: Error) => setErr(e.message))
  }, [])

  const patch = (p: Partial<HostingConfig>) => {
    setErr('')
    setProbeResult(null)
    setCfg((c) => ({ ...c, ...p }))
  }
  const supportedKinds = supportedHostingKinds(types, framework, hostingKind)
  const isExternal = hostingKind === 'external_endpoint'
  const [lastFramework, setLastFramework] = useState(framework)
  if (framework !== lastFramework) {
    setLastFramework(framework)
    setProbeResult(null)
    if (!supportedKinds.includes(hostingKind) && supportedKinds.length > 0) setHostingKind(supportedKinds[0])
  }

  function currentDraftConfig(parsedEnv: Record<string, string> = {}): HostingConfig {
    if (hostingKind === 'external_endpoint') {
      // ADR-0025 §2.5: external_endpoint 不渲染 image/k8s/资源/运行时参数; cfgWithKindDefaults 会清回默认值。
      // ADR-0035: framework 可为 zap 或 dsh, 均走 ZAP 协议; 其它值默认回落 'zap'。
      const externalFw = isZapWire(framework) ? framework : 'zap'
      return {
        ...cfgWithKindDefaults(cfg, 'external_endpoint', externalFw),
        runtime_environment_id: 0,
        hosting_kind: 'external_endpoint',
        framework: externalFw,
        scope: 'platform',
        enabled: false,
        open_to_tenants: false,
        workload_env: {},
        primary_endpoint: normalizeRuntimeRootEndpoint(cfg.primary_endpoint || ''),
        api_key_secret_ref: cfg.api_key_secret_ref || '',
      }
    }
    return {
      ...cfgWithKindDefaults(cfg, hostingKind, framework),
      runtime_environment_id: 0,
      hosting_kind: hostingKind,
      enabled: false,
      open_to_tenants: false,
      workload_env: parsedEnv,
    }
  }

  const fieldErrors = fieldErrorsForHostingConfigValidation(currentDraftConfig(), err)

  async function probeDraft() {
    setProbing(true); setErr(''); setProbeResult(null)
    try {
      let parsedEnv: Record<string, string> = {}
      if (envJSON.trim()) parsedEnv = JSON.parse(envJSON) as Record<string, string>
      const draft = currentDraftConfig(parsedEnv)
      const validation = validateHostingConfig(draft)
      if (validation) {
        setErr(validation)
        return
      }
      const r = await RuntimeHosting.probeDraft(draft)
      if (hostingKind === 'external_endpoint') {
        setCfg((c) => ({ ...c, control_plane_capabilities: r.supported_control_plane_capabilities || {} }))
      }
      setProbeResult(r)
      if (r.status !== 'ok') {
        setErr(`健康检查失败（${hostingKindLabel(r.hosting_kind)}，${r.latency_ms}ms）：${r.message}`)
      }
    } catch (e) { setErr((e as Error).message) }
    finally { setProbing(false) }
  }

  async function submit() {
    if (busy) return
    if (!name.trim()) { setErr('请填写显示名。'); return }
    if (probeResult?.status !== 'ok') { setErr('请先完成健康检查，通过后再创建配置。'); return }
    setBusy(true); setErr('')
    try {
      let parsedEnv: Record<string, string> = {}
      if (envJSON.trim()) parsedEnv = JSON.parse(envJSON) as Record<string, string>
      const draft = currentDraftConfig(parsedEnv)
      const validation = validateHostingConfig(draft)
      if (validation) {
        setErr(validation)
        return
      }
      const rt = await Runtimes.create({
        Name: name.trim(),
        Code: internalRuntimeCompatCode(),
        Framework: framework,
        Scope: 'platform',
        // ADR-0035: zap 与 dsh 均走外部 endpoint 协议, AdapterKind='external'。
        AdapterKind: isZapWire(framework) ? 'external' : 'builtin',
        Status: 'active',
        Endpoints: {},
      } as Partial<Runtime>)
      const nextCfg: HostingConfig = {
        ...currentDraftConfig(parsedEnv),
        runtime_environment_id: rt.ID,
        auto_issue_default_credential: true,
      }
      const res = await RuntimeHosting.upsertConfig(rt.UUID, nextCfg)
      if (res.defaultCredential) {
        setDefaultCredential(res.defaultCredential)
        return
      }
      onCreated()
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="space-y-5">
      {err && <div className={clsx('text-[12px] p-2 rounded', TOKEN.danger)}>{err}</div>}

      <HostingBasicSection
        mode="create"
        name={name}
        framework={framework}
        hostingKind={hostingKind}
        types={types}
        supportedKinds={supportedKinds}
        onNameChange={setName}
        onFrameworkChange={(v) => { setFramework(v); setProbeResult(null) }}
        onHostingKindChange={(v) => { setHostingKind(v); setProbeResult(null) }}
      />

      {/* ADR-0025: hosting_kind 分支字段统一走共享组件 RuntimeHostingForm。 */}
      <RuntimeHostingForm
        scope="platform"
        hostingKind={hostingKind}
        framework={framework}
        cfg={cfg}
        onPatch={patch}
        credRefKind={credRefKind}
        setCredRefKind={setCredRefKind}
        fieldErrors={fieldErrors}
        probe={{
          done: !!probeResult,
          supportedCaps: mergeRuntimeDisplayCaps(
            probeResult?.supported_control_plane_capabilities,
            probeResult?.agent_instance_initialize_supported,
          ),
        }}
      />
      {probeResult?.status === 'ok' && (
        <div className={clsx('rounded-md p-3 text-[12px]', TOKEN.emerald)}>
          <div className="flex items-center gap-2 font-medium">
            <CheckCircle2 size={14} /> 健康检查通过 · 可创建
            {isExternal && (
              <span className="ml-2 inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-emerald-100 ring-1 ring-emerald-200 text-emerald-800 text-[11px]">
                <ShieldCheck size={12} /> multi_tenant_isolation = true
              </span>
            )}
          </div>
          <div className="mt-1 break-all">
            {probeResult.message || '底层服务可访问，凭证有效。'}
            {probeResult.latency_ms ? <span className="ml-2 font-mono">{probeResult.latency_ms}ms</span> : null}
          </div>
        </div>
      )}
      {err && <div className={clsx('text-[12px] p-2 rounded', TOKEN.danger)}>{err}</div>}

      {defaultCredential && (
        <CredentialCreatedDialog
          mode="platform"
          credential={defaultCredential}
          onClose={() => {
            setDefaultCredential(null)
            onCreated()
          }}
        />
      )}

      <div className="sticky bottom-[-20px] -mx-6 px-6 py-3 bg-white border-t border-[var(--color-line)] flex items-center justify-end gap-2 z-10">
        <button onClick={onClose} className="px-3.5 py-2 rounded-md text-[13px] ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)]">取消</button>
        <button onClick={probeDraft} disabled={probing}
          className="px-3 py-2 rounded-md text-[13px] ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] disabled:opacity-50 inline-flex items-center gap-1.5">
          <Activity size={14} /> {probing ? '检查中…' : '测试连通性'}
        </button>
        <button onClick={submit} disabled={busy || probeResult?.status !== 'ok'}
          className={clsx('px-3.5 py-2 rounded-md text-[13px] disabled:opacity-50 inline-flex items-center gap-1.5', TOKEN.brand)}>
          <Plus size={14} /> {busy ? '创建中…' : '创建配置'}
        </button>
      </div>
    </div>
  )
}

// 防 lint 未引用; Eye / Server 仅在某些分支用到。
void Eye
void Server
