// F25 告警中心 /alerts（platform / tenant 双 scope 复用，按 actScope 切数据源）。
// 设计权威 docs/features/F25-alert-center-and-admin-visibility.md §8.1。
import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useNavigate, useOutletContext, useSearchParams } from 'react-router-dom'
import { Check, Eye, RefreshCw, Route as RouteIcon } from 'lucide-react'

import { Alerts, type AlertItem, type AlertScope, type AlertSeverity, type AlertStatus } from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  InlineAlert,
  PageHeader,
  Pagination,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

export const ALERTS_CHANGED_EVENT = 'alerts:changed'

const STATUS_LABEL: Record<AlertStatus, string> = {
  firing: '待处理',
  acknowledged: '已确认',
  resolved: '已恢复',
}

const SEVERITY_LABEL: Record<AlertSeverity, string> = {
  warning: '警告',
  critical: '严重',
}

const SOURCE_LABEL: Record<string, string> = {
  agent_run: 'Agent 运行',
  runtime: '运行实例',
  kb_provider: '知识库服务',
  cron: '定时任务',
  drive_worker: '云盘任务',
  outbox: '事件总线',
  billing: '计费',
  im: 'IM 连接',
}

const statusTone: Record<AlertStatus, string> = {
  firing: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
  acknowledged: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  resolved: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
}

const severityTone: Record<AlertSeverity, string> = {
  warning: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  critical: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
}

// alert_type → 去排查跳转（F25 §3 表）；带 scope 差异的路由在函数内判断。
// 评审返修：平台侧对租户归属告警附加 tenant_id 深链参数，目标页已消费（运行监测/调用日志）。
function investigateRoute(item: AlertItem, scope: AlertScope): string | null {
  const tenantSuffix = scope === 'platform' && item.tenantId ? `&tenant_id=${item.tenantId}` : ''
  switch (item.alertType) {
    case 'agent_run_failure_rate':
      return `/observability/agent-runs?status=failed${tenantSuffix}`
    case 'agent_run_p95_slow':
      return `/observability/agent-runs?min_duration_ms=60000${tenantSuffix}`
    case 'runtime_unhealthy':
      return scope === 'platform' ? '/runtime-hosting' : '/runtime-environments'
    case 'kb_provider_unhealthy':
    case 'kb_outbox_backlog':
      return '/ragflow-ops'
    case 'cron_consecutive_failures':
      // 平台任务列表消费 only_consecutive_failure=1 直接落到连续失败筛选；
      // 租户侧带 ?job=<uuid> 直接打开该任务详情（含最近运行记录）
      return scope === 'platform'
        ? '/cron-jobs?only_consecutive_failure=1'
        : item.resourceUuid
          ? `/cron?job=${encodeURIComponent(item.resourceUuid)}`
          : '/cron'
    case 'drive_worker_backlog':
      return '/drive/workers'
    case 'wallet_frozen':
    case 'credit_low':
      return scope === 'tenant' ? '/billing/subscription?tab=wallet' : null
    case 'quota_threshold':
      return scope === 'tenant' ? '/billing/subscription?tab=quota' : null
    case 'subscription_expiring':
      return scope === 'tenant' ? '/billing/subscription' : null
    case 'order_unfulfilled':
      return scope === 'platform' ? '/billing/orders' : null
    case 'im_reconnect_storm':
      return scope === 'platform' && item.resourceUuid
        ? `/wukongim?tab=anomalies&connection=${encodeURIComponent(item.resourceUuid)}${tenantSuffix}`
        : null
    default:
      return null
  }
}

export function AlertCenterPage() {
  const ctx = useOutletContext<LayoutOutletContext>()
  const nav = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const scopeKind = ctx?.actScope?.kind
  const scope: AlertScope = scopeKind === 'platform' ? 'platform' : 'tenant'

  const [items, setItems] = useState<AlertItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [status, setStatus] = useState(searchParams.get('status') ?? 'firing')
  const [severity, setSeverity] = useState('')
  const [sourceKind, setSourceKind] = useState('')
  // 平台侧支持从租户 360° 带 ?tenant_id= 深链进入
  const [tenantID, setTenantID] = useState(searchParams.get('tenant_id')?.replace(/[^0-9]/g, '') ?? '')
  // 平台侧默认排除租户经营类告警（配额/积分不足/订阅到期，行动方是租户）；勾选后可见
  const [includeTenantOps, setIncludeTenantOps] = useState(searchParams.get('include_tenant_ops') === 'true')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [viewing, setViewing] = useState<AlertItem | null>(null)
  const [resolving, setResolving] = useState<AlertItem | null>(null)

  useEffect(() => {
    if (!scopeKind) return
    let cancelled = false
    Alerts.list(scope, {
      status: status || undefined,
      severity: severity || undefined,
      source_kind: sourceKind || undefined,
      tenant_id: scope === 'platform' && tenantID ? Number(tenantID) : undefined,
      include_tenant_ops: scope === 'platform' && includeTenantOps ? true : undefined,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    }).then((resp) => {
      if (cancelled) return
      setItems(resp.items || [])
      setTotal(resp.total || 0)
      setErr('')
    }).catch((e: Error) => {
      if (!cancelled) setErr(e.message)
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })
    return () => { cancelled = true }
  }, [scope, scopeKind, status, severity, sourceKind, tenantID, includeTenantOps, page, pageSize, tick])

  const summary = useMemo(() => `共 ${total} 条告警`, [total])
  const resetPage = (fn: () => void) => {
    setLoading(true)
    setPage(1)
    fn()
  }
  const refresh = () => {
    setLoading(true)
    setTick((v) => v + 1)
    window.dispatchEvent(new Event(ALERTS_CHANGED_EVENT))
  }

  const acknowledge = async (item: AlertItem) => {
    try {
      await Alerts.acknowledge(scope, item.uuid)
      refresh()
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  if (!scopeKind) return null

  return (
    <div>
      <PageHeader
        title="告警中心"
        subtitle={scope === 'platform'
          ? '按内置规则持续评估全平台健康信号：去重、持续阈值、自动恢复；确认与人工恢复会写入审计。'
          : '本租户的运行、任务与计费告警：确认表示有人跟进，异常消除后自动恢复。'}
      />

      <Toolbar
        filters={
          <div className="flex items-center gap-2">
            <div className="w-[120px]">
              <Select value={status} onChange={(e) => resetPage(() => {
                setStatus(e.target.value)
                setSearchParams(e.target.value ? { status: e.target.value } : {}, { replace: true })
              })}>
                <option value="">全部状态</option>
                <option value="firing">{STATUS_LABEL.firing}</option>
                <option value="acknowledged">{STATUS_LABEL.acknowledged}</option>
                <option value="resolved">{STATUS_LABEL.resolved}</option>
              </Select>
            </div>
            <div className="w-[110px]">
              <Select value={severity} onChange={(e) => resetPage(() => setSeverity(e.target.value))}>
                <option value="">全部级别</option>
                <option value="critical">{SEVERITY_LABEL.critical}</option>
                <option value="warning">{SEVERITY_LABEL.warning}</option>
              </Select>
            </div>
            <div className="w-[130px]">
              <Select value={sourceKind} onChange={(e) => resetPage(() => setSourceKind(e.target.value))}>
                <option value="">全部来源</option>
                {Object.entries(SOURCE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </Select>
            </div>
            {scope === 'platform' && (
              <>
                <input
                  value={tenantID}
                  onChange={(e) => resetPage(() => setTenantID(e.target.value.replace(/[^0-9]/g, '')))}
                  placeholder="租户 ID"
                  className="h-9 w-[100px] rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 text-[13px] outline-none transition focus:border-[var(--color-brand)]"
                />
                <label className="flex h-9 cursor-pointer select-none items-center gap-1.5 whitespace-nowrap text-[13px] text-[var(--color-text-sub)]" title="配额到阈值 / 积分不足 / 订阅到期：行动方是租户管理员，默认不进平台待处理">
                  <input
                    type="checkbox"
                    checked={includeTenantOps}
                    onChange={(e) => resetPage(() => setIncludeTenantOps(e.target.checked))}
                  />
                  含租户经营类
                </label>
              </>
            )}
          </div>
        }
        summary={summary}
        actions={
          <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新告警列表">
            <RefreshCw size={14} />
          </Button>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        stickyLastCol
        headers={scope === 'platform'
          ? ['最近触发', '级别', '标题', '来源', '租户', '次数', '状态', '操作']
          : ['最近触发', '级别', '标题', '来源', '次数', '状态', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载告警</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            title={status === 'firing' ? '暂无待处理告警' : '暂无告警'}
            description={status === 'firing' ? '所有监控信号正常，一切安好。' : '当前筛选条件下没有告警记录。'}
          />
        ) : undefined}
      >
        {!loading && items.map((item) => {
          const route = investigateRoute(item, scope)
          return (
            <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
              <td className="min-w-[150px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.lastTriggeredAt)}</td>
              <td className="min-w-[80px] whitespace-nowrap px-4 py-3">
                <Badge className={severityTone[item.severity]}>{SEVERITY_LABEL[item.severity] || item.severity}</Badge>
              </td>
              <td className="min-w-[260px] px-4 py-3" title={item.summary}>
                <div className="max-w-[360px] truncate font-medium text-[var(--color-text)]">{item.title}</div>
                <div className="mt-0.5 max-w-[360px] truncate text-[12px] text-[var(--color-text-sub)]">{item.summary}</div>
              </td>
              <td className="min-w-[100px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{SOURCE_LABEL[item.sourceKind] || item.sourceKind}</td>
              {scope === 'platform' && (
                <td className="min-w-[120px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.tenantName || ''}>
                  <div className="max-w-[140px] truncate">{item.tenantName || (item.tenantId ? `#${item.tenantId}` : '平台')}</div>
                </td>
              )}
              <td className="min-w-[64px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{item.occurrenceCount}</td>
              <td className="min-w-[88px] whitespace-nowrap px-4 py-3">
                <Badge className={statusTone[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
              </td>
              <td className={`min-w-[200px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <div className="flex items-center gap-1">
                  <Button variant="ghost" size="sm" onClick={() => setViewing(item)} title="详情" aria-label="查看告警详情">
                    <Eye size={14} />
                    详情
                  </Button>
                  {item.status === 'firing' && (
                    <Button variant="ghost" size="sm" onClick={() => acknowledge(item)} title="确认（表示有人跟进）" aria-label="确认告警">
                      <Check size={14} />
                      确认
                    </Button>
                  )}
                  {item.status !== 'resolved' && route && (
                    <Button variant="ghost" size="sm" onClick={() => nav(route)} title="去排查" aria-label="去排查">
                      <RouteIcon size={14} />
                      去排查
                    </Button>
                  )}
                </div>
              </td>
            </tr>
          )
        })}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => { setLoading(true); setPage(next) }}
        onPageSizeChange={(next) => { setLoading(true); setPageSize(next); setPage(1) }}
      />

      {viewing && (
        <AlertDetailDrawer
          item={viewing}
          scope={scope}
          onClose={() => setViewing(null)}
          onAcknowledge={async () => { await acknowledge(viewing); setViewing(null) }}
          onResolve={() => { setResolving(viewing); setViewing(null) }}
          onInvestigate={(route) => nav(route)}
        />
      )}

      {resolving && (
        <ResolveConfirm
          item={resolving}
          scope={scope}
          onClose={() => setResolving(null)}
          onDone={() => { setResolving(null); refresh() }}
        />
      )}
    </div>
  )
}

function AlertDetailDrawer({
  item, scope, onClose, onAcknowledge, onResolve, onInvestigate,
}: {
  item: AlertItem
  scope: AlertScope
  onClose: () => void
  onAcknowledge: () => void
  onResolve: () => void
  onInvestigate: (route: string) => void
}) {
  const route = investigateRoute(item, scope)
  const contextEntries = Object.entries(item.context || {})
  return (
    <DrawerShell
      title={item.title}
      subtitle={`${SOURCE_LABEL[item.sourceKind] || item.sourceKind} · ${item.alertType}`}
      onClose={onClose}
      width="md"
      footer={
        <div className="flex w-full items-center justify-between gap-2">
          <div>
            {item.status !== 'resolved' && route && (
              <Button variant="secondary" onClick={() => onInvestigate(route)}>
                <RouteIcon size={14} />
                去排查
              </Button>
            )}
            {item.status === 'resolved' && route && (
              <Button variant="secondary" onClick={() => onInvestigate(route)}>查看相关记录</Button>
            )}
          </div>
          <div className="flex gap-2">
            {item.status === 'firing' && <Button variant="secondary" onClick={onAcknowledge}>确认</Button>}
            {item.status !== 'resolved' && <Button variant="danger" onClick={onResolve}>标记恢复</Button>}
            <Button variant="secondary" onClick={onClose}>关闭</Button>
          </div>
        </div>
      }
    >
      <div className="space-y-4">
        <div className="flex items-center gap-2">
          <Badge className={severityTone[item.severity]}>{SEVERITY_LABEL[item.severity]}</Badge>
          <Badge className={statusTone[item.status]}>{STATUS_LABEL[item.status]}</Badge>
          <span className="text-[12px] text-[var(--color-text-mute)]">累计命中 {item.occurrenceCount} 次</span>
        </div>

        <div className="rounded-md border border-[var(--color-line-soft)] bg-white px-3 py-3 text-[13px] leading-6 text-[var(--color-text)]">
          {item.summary}
        </div>

        <div className="grid gap-2 sm:grid-cols-2">
          <MetaTile label="首次触发" value={formatTime(item.firstTriggeredAt)} />
          <MetaTile label="最近触发" value={formatTime(item.lastTriggeredAt)} />
          {scope === 'platform' && <MetaTile label="租户" value={item.tenantName || (item.tenantId ? `#${item.tenantId}` : '平台级')} />}
          <MetaTile label="关联资源" value={item.resourceUuid ? `${item.resourceKind} · ${item.resourceUuid}` : (item.resourceKind || '-')} />
          {item.acknowledgedAt && <MetaTile label="确认时间" value={formatTime(item.acknowledgedAt)} />}
          {item.resolvedAt && (
            <MetaTile label="恢复方式" value={`${item.resolvedBy ? '人工标记' : '自动恢复'} · ${formatTime(item.resolvedAt)}`} />
          )}
        </div>

        {contextEntries.length > 0 && (
          <div>
            <div className="mb-1 text-[12px] font-medium text-[var(--color-text-sub)]">观测上下文</div>
            <div className="grid gap-2 sm:grid-cols-2">
              {contextEntries.map(([k, v]) => (
                <MetaTile key={k} label={k} value={formatContextValue(v)} />
              ))}
            </div>
          </div>
        )}
      </div>
    </DrawerShell>
  )
}

function ResolveConfirm({
  item, scope, onClose, onDone,
}: {
  item: AlertItem
  scope: AlertScope
  onClose: () => void
  onDone: () => void
}) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  return (
    <ConfirmDialog
      title="标记告警恢复"
      description={`「${item.title}」将被标记为已恢复。若底层异常仍存在，评估器会重新产生一条新告警；本次操作将写入审计。`}
      confirmLabel={busy ? '提交中' : '标记恢复'}
      confirmDisabled={busy || reason.trim().length < 2}
      onClose={onClose}
      onConfirm={async () => {
        setBusy(true)
        setErr('')
        try {
          await Alerts.resolve(scope, item.uuid, reason.trim())
          onDone()
        } catch (e) {
          setErr((e as Error).message)
          setBusy(false)
        }
      }}
    >
      <div className="space-y-2">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="恢复原因（必填，写入审计）">
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            maxLength={200}
            placeholder="例如：已重启运行实例 / 已人工补发订单"
            className="h-9 w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 text-[13px] outline-none transition focus:border-[var(--color-brand)]"
          />
        </FormField>
      </div>
    </ConfirmDialog>
  )
}

function MetaTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2">
      <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">{label}</div>
      <div className="mt-0.5 min-w-0 truncate text-[13px] font-medium text-[var(--color-text)]" title={value}>{value}</div>
    </div>
  )
}

function Badge({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-[12px] font-medium ${className}`}>
      {children}
    </span>
  )
}

function formatContextValue(v: unknown): string {
  if (v === null || v === undefined) return '-'
  if (typeof v === 'number') {
    return Number.isInteger(v) ? String(v) : v.toFixed(2)
  }
  if (typeof v === 'object') return JSON.stringify(v)
  return String(v)
}

function formatTime(v?: string | null) {
  if (!v) return '-'
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString('zh-CN', { hour12: false })
}
