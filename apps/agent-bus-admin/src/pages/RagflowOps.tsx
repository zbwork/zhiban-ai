// RagflowOps · /platform/ragflow-ops — 知识库监控运维 (F07 §5.1 v0.2)
//
// 定位: RAGFlow 服务健康 + 异常处置 (不承载容量运营视图):
//   1. 探活目标选择 — 只影响健康探活; 绑定/异步任务/统计均为全局数据
//   2. 健康度 — 服务状态(含探活耗时) / 租户绑定 / 异步任务 三组; 探活 FAIL 一票否决绿灯
//   3. 租户绑定 — 后端分页 + 筛选/搜索 + 详情抽屉; failed 行可「重新供给」(写 outbox 事件)
//   4. 异步任务队列 — kb_outbox_events 列表 + 详情; failed/死信可重试, 可丢弃
//
// 后端: /api/admin/v1/platform/ragflow-{bindings,health}, /platform/kb-outbox-events,
//       /platform/knowledge-bases-overview (api.ts RagflowOpsAPI)
// 权限: 查看 platform.kb_provider.read; 处置 platform.kb_provider.update
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import {
  Activity,
  AlertCircle,
  AlertTriangle,
  Check,
  CheckCircle2,
  Copy,
  Database,
  Eye,
  Inbox,
  RefreshCw,
  RotateCw,
  Trash2,
} from 'lucide-react'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DrawerShell,
  EmptyState,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  SearchInput,
  Select,
  Switch,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'
import {
  KBProviders,
  RagflowOpsAPI,
  type KBOutboxEvent,
  type KBProvider,
  type RagflowBinding,
  type RagflowHealth,
  type RagflowKBOverviewRow,
} from '../lib/api'
import { notifyInfo } from '../lib/toast'

// ===== 展示辅助 =====

/** PG text 时间 ('2026-07-06 12:33:44.123+08') → Date; 解析失败返 null。 */
function parsePgTime(s?: string): Date | null {
  if (!s) return null
  let iso = s.trim().replace(' ', 'T')
  // Safari 不认 '+08' 结尾, 补 ':00'
  if (/[+-]\d{2}$/.test(iso)) iso = `${iso}:00`
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? null : d
}

function fmtTime(s?: string): string {
  const d = parsePgTime(s)
  if (!d) return '-'
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

/** 相对时间: 刚刚 / N 分钟前 / N 小时前 / N 天前; 未来时间显示「约 N 分钟后」。 */
function timeAgo(s?: string): string {
  const d = parsePgTime(s)
  if (!d) return '-'
  const diffMs = Date.now() - d.getTime()
  const abs = Math.abs(diffMs)
  const min = Math.round(abs / 60_000)
  const label =
    abs < 30_000 ? '刚刚'
    : min < 60 ? `${Math.max(1, min)} 分钟`
    : min < 60 * 24 ? `${Math.round(min / 60)} 小时`
    : `${Math.round(min / 60 / 24)} 天`
  if (label === '刚刚') return label
  return diffMs >= 0 ? `${label}前` : `约 ${label}后`
}

const BINDING_STATUS: Record<string, { label: string; cls: string }> = {
  active: { label: '正常', cls: 'bg-[var(--color-success-bg)] text-[var(--color-success)]' },
  pending: { label: '供给中', cls: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]' },
  failed: { label: '失败', cls: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]' },
  deactivated: { label: '已停用', cls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]' },
  pending_cleanup: { label: '待清理', cls: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]' },
}

const OUTBOX_STATUS: Record<string, { label: string; cls: string }> = {
  pending: { label: '待执行', cls: 'bg-[var(--color-info-bg)] text-[var(--color-info)]' },
  running: { label: '执行中', cls: 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]' },
  done: { label: '已完成', cls: 'bg-[var(--color-success-bg)] text-[var(--color-success)]' },
  failed: { label: '失败重试中', cls: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]' },
  dlq: { label: '死信', cls: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]' },
  discarded: { label: '已丢弃', cls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]' },
}

const OUTBOX_OP_LABEL: Record<string, string> = {
  delete_dataset: '删除知识库',
  delete_document: '删除文档',
  tenant_cleanup_datasets: '清理租户知识库',
  tenant_cleanup_user: '清理租户账号',
  reconcile_provision: '重新供给',
}

function StatusBadge({ map, status }: { map: Record<string, { label: string; cls: string }>; status: string }) {
  const m = map[status] || { label: status, cls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]' }
  return (
    <span className={`inline-block whitespace-nowrap rounded px-2 py-0.5 text-[12px] font-medium ${m.cls}`} title={status}>
      {m.label}
    </span>
  )
}

/** 单行复制按钮: hover 显示, 点击复制 + 短暂打勾。 */
function CopyBtn({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      title={`复制${label}`}
      aria-label={`复制${label}`}
      className="grid h-6 w-6 shrink-0 place-items-center rounded text-[var(--color-text-mute)] transition hover:bg-[var(--color-line-soft)] hover:text-[var(--color-text)]"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text)
          setCopied(true)
          window.setTimeout(() => setCopied(false), 1200)
        } catch {
          notifyInfo('复制失败, 请手动选择文本')
        }
      }}
    >
      {copied ? <Check size={13} className="text-[var(--color-success)]" /> : <Copy size={13} />}
    </button>
  )
}

/** 详情抽屉里的字段行。 */
function FieldRow({ label, value, mono, copyText }: { label: string; value: ReactNode; mono?: boolean; copyText?: string }) {
  return (
    <div className="flex items-start gap-3 py-1.5">
      <div className="w-28 shrink-0 pt-0.5 text-[12.5px] text-[var(--color-text-sub)]">{label}</div>
      <div className={`min-w-0 flex-1 break-all text-[13px] text-[var(--color-text)] ${mono ? 'font-mono text-[12.5px]' : ''}`}>
        {value}
      </div>
      {copyText ? <CopyBtn text={copyText} label={label} /> : null}
    </div>
  )
}

const AUTO_REFRESH_KEY = 'agbus.ragflowops.autorefresh'
const AUTO_REFRESH_MS = 30_000
const PAGE_SIZE_DEFAULT = 10

export function RagflowOpsPage() {
  // ===== 探活目标 (provider) =====
  const [providers, setProviders] = useState<KBProvider[]>([])
  const [providerUUID, setProviderUUID] = useState('')

  // ===== 健康度 =====
  const [health, setHealth] = useState<RagflowHealth | null>(null)

  // ===== 租户绑定 =====
  const [bindings, setBindings] = useState<RagflowBinding[]>([])
  const [bindingTotal, setBindingTotal] = useState(0)
  const [bindingPage, setBindingPage] = useState(1)
  const [bindingPageSize, setBindingPageSize] = useState(PAGE_SIZE_DEFAULT)
  const [bindingStatus, setBindingStatus] = useState('')
  const [bindingQ, setBindingQ] = useState('')
  const [bindingDetail, setBindingDetail] = useState<RagflowBinding | null>(null)
  const [reconcileTarget, setReconcileTarget] = useState<RagflowBinding | null>(null)

  // ===== 异步任务 (outbox) =====
  const [events, setEvents] = useState<KBOutboxEvent[]>([])
  const [eventTotal, setEventTotal] = useState(0)
  const [eventPage, setEventPage] = useState(1)
  const [eventPageSize, setEventPageSize] = useState(PAGE_SIZE_DEFAULT)
  const [eventStatus, setEventStatus] = useState('')
  const [eventOp, setEventOp] = useState('')
  const [eventDetail, setEventDetail] = useState<KBOutboxEvent | null>(null)
  const [discardTarget, setDiscardTarget] = useState<KBOutboxEvent | null>(null)
  const [busyEventUUID, setBusyEventUUID] = useState('')

  // ===== 跨租户 KB 统计 (客户端分页的诊断汇总; 完整运营视图后续归「全部知识库」页) =====
  const [overview, setOverview] = useState<RagflowKBOverviewRow[]>([])
  const [overviewPage, setOverviewPage] = useState(1)
  const [overviewPageSize, setOverviewPageSize] = useState(PAGE_SIZE_DEFAULT)

  // ===== 页面级状态 =====
  const [initialLoading, setInitialLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [pageErr, setPageErr] = useState('')
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null)
  const [autoRefresh, setAutoRefresh] = useState(() => localStorage.getItem(AUTO_REFRESH_KEY) !== 'off')

  const selectedProvider = providers.find((p) => p.provider_uuid === providerUUID) || null
  const anyOverlayOpen = !!(bindingDetail || eventDetail || discardTarget || reconcileTarget)

  // ===== 数据加载 =====

  const loadHealth = useCallback(async (uuid: string) => {
    setHealth(await RagflowOpsAPI.health(uuid || undefined))
  }, [])

  const loadBindings = useCallback(async (page: number, size: number, status: string, q: string) => {
    const resp = await RagflowOpsAPI.listBindings({
      limit: size,
      offset: (page - 1) * size,
      status: status || undefined,
      q: q || undefined,
    })
    setBindings(resp.items || [])
    setBindingTotal(resp.total || 0)
  }, [])

  const loadEvents = useCallback(async (page: number, size: number, status: string, op: string) => {
    const resp = await RagflowOpsAPI.listOutboxEvents({
      limit: size,
      offset: (page - 1) * size,
      status: status || undefined,
      op: op || undefined,
    })
    setEvents(resp.items || [])
    setEventTotal(resp.total || 0)
  }, [])

  const loadOverview = useCallback(async () => {
    const resp = await RagflowOpsAPI.kbOverview()
    setOverview(resp.items || [])
  }, [])

  /** 全量刷新 (手动按钮 / 自动轮询)。保留旧数据渐进更新, 不整页闪白。 */
  const refreshAll = useCallback(
    async (uuid = providerUUID) => {
      setRefreshing(true)
      setPageErr('')
      try {
        const providerResp = await KBProviders.list()
        const ragflowProviders = (providerResp.items || []).filter((p) => p.provider_kind === 'ragflow')
        const nextUUID =
          uuid && ragflowProviders.some((p) => p.provider_uuid === uuid)
            ? uuid
            : (ragflowProviders.find((p) => p.is_default) || ragflowProviders[0])?.provider_uuid || ''
        setProviders(ragflowProviders)
        setProviderUUID(nextUUID)
        await Promise.all([
          loadHealth(nextUUID),
          loadBindings(bindingPage, bindingPageSize, bindingStatus, bindingQ),
          loadEvents(eventPage, eventPageSize, eventStatus, eventOp),
          loadOverview(),
        ])
        setLastUpdated(new Date())
      } catch (e) {
        setPageErr(e instanceof Error ? e.message : String(e))
      } finally {
        setRefreshing(false)
        setInitialLoading(false)
      }
    },
    [providerUUID, bindingPage, bindingPageSize, bindingStatus, bindingQ, eventPage, eventPageSize, eventStatus, eventOp, loadHealth, loadBindings, loadEvents, loadOverview],
  )

  // 首次加载 (setTimeout 回调里执行, setState 不落在 effect 同步体内)
  useEffect(() => {
    const t = window.setTimeout(() => void refreshAll(), 0)
    return () => window.clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // 自动刷新: 30s; 抽屉/弹框打开时暂停, 避免数据在用户眼皮下换行
  useEffect(() => {
    if (!autoRefresh || anyOverlayOpen) return
    const t = window.setInterval(() => void refreshAll(), AUTO_REFRESH_MS)
    return () => window.clearInterval(t)
  }, [autoRefresh, anyOverlayOpen, refreshAll])

  // 绑定筛选/搜索/分页变化 → 重新拉绑定列表 (搜索 300ms 防抖)
  const bindingQTimer = useRef<number>(0)
  useEffect(() => {
    window.clearTimeout(bindingQTimer.current)
    bindingQTimer.current = window.setTimeout(() => {
      loadBindings(bindingPage, bindingPageSize, bindingStatus, bindingQ).catch((e) =>
        setPageErr(e instanceof Error ? e.message : String(e)),
      )
    }, bindingQ ? 300 : 0)
    return () => window.clearTimeout(bindingQTimer.current)
  }, [bindingPage, bindingPageSize, bindingStatus, bindingQ, loadBindings])

  // 任务筛选/分页变化 → 重新拉任务列表 (同上, setState 在回调内)
  useEffect(() => {
    const t = window.setTimeout(() => {
      loadEvents(eventPage, eventPageSize, eventStatus, eventOp).catch((e) =>
        setPageErr(e instanceof Error ? e.message : String(e)),
      )
    }, 0)
    return () => window.clearTimeout(t)
  }, [eventPage, eventPageSize, eventStatus, eventOp, loadEvents])

  // ===== 处置动作 =====

  const doRetryEvent = async (ev: KBOutboxEvent) => {
    setBusyEventUUID(ev.uuid)
    try {
      const resp = await RagflowOpsAPI.retryOutboxEvent(ev.uuid)
      notifyInfo(resp.message || '已提交重试')
      setEventDetail(null)
      await Promise.all([loadEvents(eventPage, eventPageSize, eventStatus, eventOp), loadHealth(providerUUID)])
    } finally {
      setBusyEventUUID('')
    }
  }

  const doDiscardEvent = async (ev: KBOutboxEvent) => {
    const resp = await RagflowOpsAPI.discardOutboxEvent(ev.uuid)
    notifyInfo(resp.message || '已丢弃')
    setDiscardTarget(null)
    setEventDetail(null)
    await Promise.all([loadEvents(eventPage, eventPageSize, eventStatus, eventOp), loadHealth(providerUUID)])
  }

  const doReconcile = async (b: RagflowBinding) => {
    const resp = await RagflowOpsAPI.reconcileBinding(b.tenant_id)
    notifyInfo(resp.message || '重新供给任务已提交')
    setReconcileTarget(null)
    setBindingDetail(null)
    await Promise.all([
      loadBindings(bindingPage, bindingPageSize, bindingStatus, bindingQ),
      loadEvents(eventPage, eventPageSize, eventStatus, eventOp),
      loadHealth(providerUUID),
    ])
  }

  // ===== 健康度总览灯 =====
  // red: 未配置或任一探活 FAIL (探活失败一票否决); amber: 存在 failed 绑定 / 失败任务 / 死信; green: 其余
  const overallTone: 'red' | 'amber' | 'green' | null = health
    ? !health.config_present || !health.admin_ok || !health.api_ok
      ? 'red'
      : health.bindings_failed > 0 || health.outbox_failed > 0 || health.outbox_dlq > 0
        ? 'amber'
        : 'green'
    : null

  const canRetry = (ev: KBOutboxEvent) =>
    ev.status === 'failed' || ev.status === 'dlq' || (ev.status === 'running' && ev.lock_expired)
  const canDiscard = (ev: KBOutboxEvent) => ev.status === 'failed' || ev.status === 'dlq'

  const overviewPageItems = overview.slice((overviewPage - 1) * overviewPageSize, overviewPage * overviewPageSize)

  return (
    <div className="p-6">
      <PageHeader
        title="监控运维"
        subtitle="RAGFlow 知识库服务健康、租户绑定与异步任务处置。异常处理路径：健康度定位 → 列表筛选 → 详情处置。"
        actions={
          <div className="flex items-center gap-3">
            <span className="text-[12.5px] text-[var(--color-text-sub)]">
              {lastUpdated ? `最后更新 ${fmtTime(String(lastUpdated.toISOString()))}` : '尚未加载'}
            </span>
            <div className="flex items-center gap-1.5">
              <Switch
                checked={autoRefresh}
                ariaLabel="自动刷新"
                onChange={(v) => {
                  setAutoRefresh(v)
                  localStorage.setItem(AUTO_REFRESH_KEY, v ? 'on' : 'off')
                }}
              />
              <span className="text-[12.5px] text-[var(--color-text-sub)]">自动刷新 (30 秒)</span>
            </div>
            <Button variant="secondary" onClick={() => void refreshAll()} disabled={refreshing}>
              <RefreshCw size={14} className={refreshing ? 'animate-spin' : ''} />
              刷新
            </Button>
          </div>
        }
      />

      <div className="space-y-5">
        {/* 探活目标 */}
        <Panel className="p-4">
          <div className="grid grid-cols-1 items-end gap-3 sm:grid-cols-[minmax(260px,420px)_1fr]">
            <div>
              <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">RAGFlow 服务（探活目标）</div>
              <Select
                value={providerUUID}
                onChange={(e) => {
                  const uuid = e.target.value
                  setProviderUUID(uuid)
                  loadHealth(uuid).catch((err) => setPageErr(err instanceof Error ? err.message : String(err)))
                }}
                disabled={providers.length === 0}
              >
                {providers.length === 0 ? (
                  <option value="">暂无 RAGFlow 服务</option>
                ) : (
                  providers.map((p) => (
                    <option key={p.provider_uuid} value={p.provider_uuid}>
                      {p.name}
                      {p.is_default ? '（默认）' : ''}
                    </option>
                  ))
                )}
              </Select>
            </div>
            <div className="flex min-w-0 flex-wrap items-center gap-x-1 gap-y-0.5 text-[13px] text-[var(--color-text-sub)]">
              {selectedProvider ? (
                <>
                  <span className="inline-flex max-w-full items-center gap-1">
                    <span className="shrink-0">探活目标：</span>
                    <span className="truncate font-mono text-[12.5px]" title={selectedProvider.endpoint_url || ''}>
                      {selectedProvider.endpoint_url || '未配置服务地址'}
                    </span>
                    {selectedProvider.endpoint_url ? <CopyBtn text={selectedProvider.endpoint_url} label="服务地址" /> : null}
                  </span>
                  <span className="text-[12.5px] text-[var(--color-text-mute)]">下方绑定 / 异步任务 / 统计为全局数据，不随此选择变化</span>
                </>
              ) : (
                <span>请先在「知识库服务配置」中创建 RAGFlow 服务。</span>
              )}
            </div>
          </div>
        </Panel>

        {pageErr && (
          <InlineAlert tone="danger">
            数据加载失败：{pageErr}。可点击右上角「刷新」重试。
          </InlineAlert>
        )}

        {/* 健康度 */}
        {health && (
          <Panel className="p-5">
            <div className="mb-4 flex flex-wrap items-center gap-2">
              {overallTone === 'green' && <CheckCircle2 size={18} className="text-[var(--color-success)]" />}
              {overallTone === 'amber' && <AlertTriangle size={18} className="text-[var(--color-warn)]" />}
              {overallTone === 'red' && <AlertCircle size={18} className="text-[var(--color-danger)]" />}
              <h2 className="text-[15px] font-semibold text-[var(--color-text)]">健康度</h2>
              <span className="text-[13px] text-[var(--color-text-sub)]">
                {health.provider_name ? `${health.provider_name} · ` : ''}
                {health.message}
              </span>
              <span className="ml-auto text-[12px] text-[var(--color-text-mute)]" title={fmtTime(health.checked_at)}>
                检查于 {timeAgo(health.checked_at)}
              </span>
            </div>
            <div className="grid grid-cols-1 gap-x-8 gap-y-4 md:grid-cols-3">
              {/* 服务状态 */}
              <div>
                <div className="mb-2 text-[12px] font-medium uppercase tracking-wide text-[var(--color-text-mute)]">服务状态</div>
                <div className="space-y-1.5 text-[13px]">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">Provider 配置</span>
                    <span className={health.config_present ? 'font-medium text-[var(--color-success)]' : 'font-medium text-[var(--color-danger)]'}>
                      {health.config_present ? '已配置' : '未配置'}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">管理接口 (Admin API)</span>
                    <span className={health.admin_ok ? 'font-medium text-[var(--color-success)]' : 'font-medium text-[var(--color-danger)]'}>
                      {health.config_present ? (health.admin_ok ? `正常 · ${health.admin_latency_ms}ms` : '异常') : '-'}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">业务接口 (API)</span>
                    <span className={health.api_ok ? 'font-medium text-[var(--color-success)]' : 'font-medium text-[var(--color-danger)]'}>
                      {health.config_present ? (health.api_ok ? `正常 · ${health.api_latency_ms}ms` : '异常') : '-'}
                    </span>
                  </div>
                </div>
              </div>
              {/* 租户绑定 */}
              <div>
                <div className="mb-2 text-[12px] font-medium uppercase tracking-wide text-[var(--color-text-mute)]">租户绑定</div>
                <div className="space-y-1.5 text-[13px]">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">总数 / 正常</span>
                    <span className="font-medium tabular-nums text-[var(--color-text)]">
                      {health.bindings_total} / <span className="text-[var(--color-success)]">{health.bindings_active}</span>
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">供给中 / 已停用</span>
                    <span className="font-medium tabular-nums text-[var(--color-text)]">
                      {health.bindings_pending} / {health.bindings_deactivated}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">失败</span>
                    {health.bindings_failed > 0 ? (
                      <button
                        type="button"
                        className="font-medium tabular-nums text-[var(--color-danger)] underline decoration-dotted underline-offset-2"
                        title="筛选失败绑定"
                        onClick={() => {
                          setBindingStatus('failed')
                          setBindingPage(1)
                        }}
                      >
                        {health.bindings_failed} · 去处理
                      </button>
                    ) : (
                      <span className="font-medium tabular-nums text-[var(--color-text)]">0</span>
                    )}
                  </div>
                </div>
              </div>
              {/* 异步任务 */}
              <div>
                <div className="mb-2 text-[12px] font-medium uppercase tracking-wide text-[var(--color-text-mute)]">异步任务</div>
                <div className="space-y-1.5 text-[13px]">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">待执行</span>
                    <span className="font-medium tabular-nums text-[var(--color-text)]">{health.outbox_pending}</span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]">失败重试中</span>
                    <span className={`font-medium tabular-nums ${health.outbox_failed > 0 ? 'text-[var(--color-warn)]' : 'text-[var(--color-text)]'}`}>
                      {health.outbox_failed}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[var(--color-text-sub)]" title="重试 6 次仍失败的任务, 不再自动重试, 需人工处置">
                      死信（需人工介入）
                    </span>
                    {health.outbox_dlq > 0 ? (
                      <button
                        type="button"
                        className="font-medium tabular-nums text-[var(--color-danger)] underline decoration-dotted underline-offset-2"
                        title="筛选死信任务"
                        onClick={() => {
                          setEventStatus('dlq')
                          setEventPage(1)
                        }}
                      >
                        {health.outbox_dlq} · 去处理
                      </button>
                    ) : (
                      <span className="font-medium tabular-nums text-[var(--color-text)]">0</span>
                    )}
                  </div>
                </div>
              </div>
            </div>
          </Panel>
        )}

        {/* 租户绑定 */}
        <section>
          <div className="mb-2 flex items-center gap-2">
            <Database size={16} className="text-[var(--color-text-sub)]" />
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">租户绑定</h2>
          </div>
          <Toolbar
            search={<SearchInput value={bindingQ} onChange={(v) => { setBindingQ(v); setBindingPage(1) }} placeholder="搜索租户名 / 邮箱 / 租户 ID" />}
            filters={
              <div className="w-[150px]">
                <Select value={bindingStatus} onChange={(e) => { setBindingStatus(e.target.value); setBindingPage(1) }}>
                  <option value="">全部状态</option>
                  <option value="active">正常</option>
                  <option value="pending">供给中</option>
                  <option value="failed">失败</option>
                  <option value="deactivated">已停用</option>
                  <option value="pending_cleanup">待清理</option>
                </Select>
              </div>
            }
            summary={<>共 <b className="tabular-nums">{bindingTotal}</b> 条</>}
          />
          <DataTable
            stickyLastCol
            headers={['租户', 'RAGFlow 邮箱', '用户 ID', 'API Key', '状态', '最后使用', '错误信息', '操作']}
            loading={initialLoading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中…</div> : undefined}
            empty={
              !initialLoading && bindings.length === 0 ? (
                <EmptyState
                  icon={<Database size={24} />}
                  title={bindingQ || bindingStatus ? '没有匹配的绑定' : '暂无租户绑定'}
                  description={bindingQ || bindingStatus ? '调整搜索或筛选条件后重试。' : '租户首次创建知识库时自动供给 RAGFlow 账号并生成绑定。'}
                />
              ) : undefined
            }
          >
            {bindings.map((b) => (
              <tr key={b.tenant_id} className="group transition hover:bg-[var(--color-bg-sub)]">
                <td className="px-4 py-2.5">
                  <div className="whitespace-nowrap text-[13px] text-[var(--color-text)]">{b.tenant_name || '-'}</div>
                  <div className="text-[12px] text-[var(--color-text-mute)]">ID {b.tenant_id}</div>
                </td>
                <td className="px-4 py-2.5">
                  <div className="flex max-w-[260px] items-center gap-0.5">
                    <span className="truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={b.ragflow_email}>
                      {b.ragflow_email}
                    </span>
                    <CopyBtn text={b.ragflow_email} label="邮箱" />
                  </div>
                </td>
                <td className="px-4 py-2.5">
                  <div className="flex items-center gap-0.5">
                    <span className="font-mono text-[12px] text-[var(--color-text-sub)]" title={b.ragflow_user_id}>
                      {b.ragflow_user_id ? `${b.ragflow_user_id.slice(0, 12)}…` : '-'}
                    </span>
                    {b.ragflow_user_id ? <CopyBtn text={b.ragflow_user_id} label="用户 ID" /> : null}
                  </div>
                </td>
                <td className="px-4 py-2.5 whitespace-nowrap font-mono text-[12px] text-[var(--color-text-sub)]">
                  {b.api_key_prefix ? `${b.api_key_prefix}… (v${b.api_key_version})` : '-'}
                </td>
                <td className="px-4 py-2.5"><StatusBadge map={BINDING_STATUS} status={b.status} /></td>
                <td className="px-4 py-2.5 whitespace-nowrap text-[12.5px] text-[var(--color-text-sub)]" title={fmtTime(b.last_used_at)}>
                  {b.last_used_at ? timeAgo(b.last_used_at) : '-'}
                </td>
                <td className="px-4 py-2.5">
                  {b.error_msg ? (
                    <button
                      type="button"
                      className="block max-w-[220px] truncate text-left text-[12.5px] text-[var(--color-danger)] underline decoration-dotted underline-offset-2"
                      title="查看错误全文"
                      onClick={() => setBindingDetail(b)}
                    >
                      {b.error_msg}
                    </button>
                  ) : (
                    <span className="text-[12.5px] text-[var(--color-text-mute)]">-</span>
                  )}
                </td>
                <td className={`px-4 py-2.5 ${stickyRightTdCls}`}>
                  <div className="flex items-center gap-1">
                    <Button variant="ghost" size="sm" title="查看详情" aria-label="查看详情" onClick={() => setBindingDetail(b)}>
                      <Eye size={14} />
                    </Button>
                    {b.status === 'failed' && (
                      <Button variant="ghost" size="sm" title="重新供给" aria-label="重新供给" onClick={() => setReconcileTarget(b)}>
                        <RotateCw size={14} />
                      </Button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </DataTable>
          <Pagination
            total={bindingTotal}
            page={bindingPage}
            pageSize={bindingPageSize}
            onPageChange={setBindingPage}
            onPageSizeChange={(s) => { setBindingPageSize(s); setBindingPage(1) }}
          />
        </section>

        {/* 异步任务队列 */}
        <section>
          <div className="mb-2 flex items-center gap-2">
            <Inbox size={16} className="text-[var(--color-text-sub)]" />
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">异步任务队列</h2>
            <span className="text-[12.5px] text-[var(--color-text-mute)]">删除知识库、租户清理、重新供给等任务由后台执行器异步处理</span>
          </div>
          <Toolbar
            filters={
              <>
                <div className="w-[150px]">
                  <Select value={eventStatus} onChange={(e) => { setEventStatus(e.target.value); setEventPage(1) }}>
                    <option value="">全部状态</option>
                    <option value="pending">待执行</option>
                    <option value="running">执行中</option>
                    <option value="done">已完成</option>
                    <option value="failed">失败重试中</option>
                    <option value="dlq">死信</option>
                    <option value="discarded">已丢弃</option>
                  </Select>
                </div>
                <div className="w-[170px]">
                  <Select value={eventOp} onChange={(e) => { setEventOp(e.target.value); setEventPage(1) }}>
                    <option value="">全部类型</option>
                    <option value="delete_dataset">删除知识库</option>
                    <option value="delete_document">删除文档</option>
                    <option value="tenant_cleanup_datasets">清理租户知识库</option>
                    <option value="tenant_cleanup_user">清理租户账号</option>
                    <option value="reconcile_provision">重新供给</option>
                  </Select>
                </div>
              </>
            }
            summary={<>共 <b className="tabular-nums">{eventTotal}</b> 条</>}
          />
          <DataTable
            stickyLastCol
            headers={['发生时间', '租户', '任务类型', '状态', '重试次数', '下次重试', '错误信息', '操作']}
            loading={initialLoading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中…</div> : undefined}
            empty={
              !initialLoading && events.length === 0 ? (
                <EmptyState
                  icon={<Inbox size={24} />}
                  title={eventStatus || eventOp ? '没有匹配的任务' : '暂无异步任务'}
                  description={eventStatus || eventOp ? '调整筛选条件后重试。' : '删除知识库、租户清理等操作会在这里生成异步任务。'}
                />
              ) : undefined
            }
          >
            {events.map((ev) => (
              <tr key={ev.uuid} className="group transition hover:bg-[var(--color-bg-sub)]">
                <td className="px-4 py-2.5 whitespace-nowrap text-[12.5px] text-[var(--color-text-sub)]" title={fmtTime(ev.occurred_at)}>
                  {timeAgo(ev.occurred_at)}
                </td>
                <td className="px-4 py-2.5">
                  <div className="whitespace-nowrap text-[13px] text-[var(--color-text)]">{ev.scope_kind === 'platform' ? '平台知识库' : ev.tenant_name || '-'}</div>
                  <div className="text-[12px] text-[var(--color-text-mute)]">{ev.scope_kind === 'platform' ? `KB ID ${ev.kb_id ?? '-'}` : `租户 ID ${ev.tenant_id ?? '-'}`}</div>
                </td>
                <td className="px-4 py-2.5 whitespace-nowrap text-[13px] text-[var(--color-text)]">
                  {OUTBOX_OP_LABEL[ev.op] || ev.op}
                </td>
                <td className="px-4 py-2.5 whitespace-nowrap">
                  <StatusBadge map={OUTBOX_STATUS} status={ev.status} />
                  {ev.status === 'running' && ev.lock_expired && (
                    <span className="ml-1 text-[11px] text-[var(--color-warn)]" title="执行器锁已过期, 可能执行器已崩溃; 可手动重试">
                      锁已过期
                    </span>
                  )}
                </td>
                <td className="px-4 py-2.5 whitespace-nowrap tabular-nums text-[12.5px] text-[var(--color-text-sub)]">{ev.attempts} / 6</td>
                <td className="px-4 py-2.5 whitespace-nowrap text-[12.5px] text-[var(--color-text-sub)]" title={fmtTime(ev.next_retry_at)}>
                  {ev.status === 'pending' || ev.status === 'failed' ? timeAgo(ev.next_retry_at) : '-'}
                </td>
                <td className="px-4 py-2.5">
                  {ev.last_error ? (
                    <button
                      type="button"
                      className="block max-w-[220px] truncate text-left text-[12.5px] text-[var(--color-danger)] underline decoration-dotted underline-offset-2"
                      title="查看错误全文"
                      onClick={() => setEventDetail(ev)}
                    >
                      {ev.last_error}
                    </button>
                  ) : (
                    <span className="text-[12.5px] text-[var(--color-text-mute)]">-</span>
                  )}
                </td>
                <td className={`px-4 py-2.5 ${stickyRightTdCls}`}>
                  <div className="flex items-center gap-1">
                    <Button variant="ghost" size="sm" title="查看详情" aria-label="查看详情" onClick={() => setEventDetail(ev)}>
                      <Eye size={14} />
                    </Button>
                    {canRetry(ev) && (
                      <Button
                        variant="ghost"
                        size="sm"
                        title="立即重试"
                        aria-label="立即重试"
                        disabled={busyEventUUID === ev.uuid}
                        onClick={() => void doRetryEvent(ev)}
                      >
                        <RotateCw size={14} className={busyEventUUID === ev.uuid ? 'animate-spin' : ''} />
                      </Button>
                    )}
                    {canDiscard(ev) && (
                      <Button variant="ghost" size="sm" title="丢弃" aria-label="丢弃" onClick={() => setDiscardTarget(ev)}>
                        <Trash2 size={14} className="text-[var(--color-danger)]" />
                      </Button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </DataTable>
          <Pagination
            total={eventTotal}
            page={eventPage}
            pageSize={eventPageSize}
            onPageChange={setEventPage}
            onPageSizeChange={(s) => { setEventPageSize(s); setEventPage(1) }}
          />
        </section>

        {/* 跨租户 KB 统计 */}
        <section>
          <div className="mb-2 flex items-center gap-2">
            <Activity size={16} className="text-[var(--color-text-sub)]" />
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">跨租户知识库统计</h2>
            <span className="text-[12.5px] text-[var(--color-text-mute)]">按知识库总数排序 · 全局数据</span>
          </div>
          <DataTable
            headers={['租户', '知识库总数', '租户级', '个人', '文档总数']}
            loading={initialLoading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中…</div> : undefined}
            empty={
              !initialLoading && overview.length === 0 ? (
                <EmptyState icon={<Activity size={24} />} title="暂无知识库" description="任一租户创建知识库后, 这里会出现统计。" />
              ) : undefined
            }
          >
            {overviewPageItems.map((r) => (
              <tr key={r.tenant_id} className="transition hover:bg-[var(--color-bg-sub)]">
                <td className="px-4 py-2.5">
                  <div className="whitespace-nowrap text-[13px] text-[var(--color-text)]">{r.tenant_name || '-'}</div>
                  <div className="text-[12px] text-[var(--color-text-mute)]">ID {r.tenant_id}</div>
                </td>
                <td className="px-4 py-2.5 tabular-nums text-[13px] font-medium text-[var(--color-text)]">{r.kb_total}</td>
                <td className="px-4 py-2.5 tabular-nums text-[13px] text-[var(--color-text-sub)]">{r.kb_tenant_level}</td>
                <td className="px-4 py-2.5 tabular-nums text-[13px] text-[var(--color-text-sub)]">{r.kb_personal}</td>
                <td className="px-4 py-2.5 tabular-nums text-[13px] text-[var(--color-text-sub)]">{r.document_total}</td>
              </tr>
            ))}
          </DataTable>
          <Pagination
            total={overview.length}
            page={overviewPage}
            pageSize={overviewPageSize}
            onPageChange={setOverviewPage}
            onPageSizeChange={(s) => { setOverviewPageSize(s); setOverviewPage(1) }}
          />
        </section>
      </div>

      {/* 绑定详情抽屉 */}
      {bindingDetail && (
        <DrawerShell
          title={`租户绑定 · ${bindingDetail.tenant_name || bindingDetail.tenant_id}`}
          subtitle="RAGFlow 账号供给详情"
          icon={<Database size={16} />}
          width="sm"
          onClose={() => setBindingDetail(null)}
          footer={
            <div className="flex items-center justify-end gap-2">
              <Button variant="secondary" onClick={() => setBindingDetail(null)}>关闭</Button>
              {bindingDetail.status === 'failed' && (
                <Button variant="primary" onClick={() => setReconcileTarget(bindingDetail)}>
                  <RotateCw size={14} /> 重新供给
                </Button>
              )}
            </div>
          }
        >
          <div className="space-y-4">
            <div>
              <FieldRow label="租户" value={`${bindingDetail.tenant_name || '-'}（ID ${bindingDetail.tenant_id}）`} />
              <FieldRow label="状态" value={<StatusBadge map={BINDING_STATUS} status={bindingDetail.status} />} />
              <FieldRow label="RAGFlow 邮箱" value={bindingDetail.ragflow_email} mono copyText={bindingDetail.ragflow_email} />
              <FieldRow label="用户 ID" value={bindingDetail.ragflow_user_id || '-'} mono copyText={bindingDetail.ragflow_user_id || undefined} />
              <FieldRow
                label="API Key"
                value={bindingDetail.api_key_prefix ? `${bindingDetail.api_key_prefix}…（版本 v${bindingDetail.api_key_version}，仅展示前缀）` : '-'}
                mono
              />
            </div>
            {bindingDetail.error_msg && (
              <div>
                <div className="mb-1 text-[12.5px] text-[var(--color-text-sub)]">错误信息</div>
                <div className="whitespace-pre-wrap break-all rounded-md border border-[var(--color-line)] bg-[var(--color-danger-bg)] p-3 text-[12.5px] leading-relaxed text-[var(--color-danger)]">
                  {bindingDetail.error_msg}
                </div>
              </div>
            )}
            <div className="border-t border-[var(--color-line-soft)] pt-2">
              <FieldRow label="供给完成时间" value={fmtTime(bindingDetail.provisioned_at)} />
              <FieldRow label="最后使用时间" value={fmtTime(bindingDetail.last_used_at)} />
              <FieldRow label="停用时间" value={fmtTime(bindingDetail.deactivated_at)} />
              <FieldRow label="创建时间" value={fmtTime(bindingDetail.created_at)} />
            </div>
            {bindingDetail.status === 'failed' && (
              <InlineAlert tone="info">
                后台每分钟会自动重试失败的绑定；「重新供给」会立即提交一个异步任务，无需等待自动重试周期。
              </InlineAlert>
            )}
          </div>
        </DrawerShell>
      )}

      {/* 任务详情抽屉 */}
      {eventDetail && (
        <DrawerShell
          title={`异步任务 · ${OUTBOX_OP_LABEL[eventDetail.op] || eventDetail.op}`}
          subtitle={`任务编号 ${eventDetail.uuid}`}
          icon={<Inbox size={16} />}
          width="md"
          onClose={() => setEventDetail(null)}
          footer={
            <div className="flex items-center justify-end gap-2">
              <Button variant="secondary" onClick={() => setEventDetail(null)}>关闭</Button>
              {canDiscard(eventDetail) && (
                <Button variant="danger" onClick={() => setDiscardTarget(eventDetail)}>
                  <Trash2 size={14} /> 丢弃
                </Button>
              )}
              {canRetry(eventDetail) && (
                <Button variant="primary" disabled={busyEventUUID === eventDetail.uuid} onClick={() => void doRetryEvent(eventDetail)}>
                  <RotateCw size={14} className={busyEventUUID === eventDetail.uuid ? 'animate-spin' : ''} /> 立即重试
                </Button>
              )}
            </div>
          }
        >
          <div className="space-y-4">
            <div>
              <FieldRow label="作用域" value={eventDetail.scope_kind === 'platform' ? `平台知识库（KB ID ${eventDetail.kb_id ?? '-'}）` : `${eventDetail.tenant_name || '-'}（租户 ID ${eventDetail.tenant_id ?? '-'}）`} />
              <FieldRow label="任务类型" value={<>{OUTBOX_OP_LABEL[eventDetail.op] || eventDetail.op} <span className="font-mono text-[11.5px] text-[var(--color-text-mute)]">{eventDetail.op}</span></>} />
              <FieldRow
                label="状态"
                value={
                  <span className="inline-flex items-center gap-2">
                    <StatusBadge map={OUTBOX_STATUS} status={eventDetail.status} />
                    <span className="text-[12.5px] text-[var(--color-text-sub)] tabular-nums">已重试 {eventDetail.attempts} / 6 次</span>
                  </span>
                }
              />
              <FieldRow label="发生时间" value={fmtTime(eventDetail.occurred_at)} />
              <FieldRow label="下次重试" value={eventDetail.status === 'pending' || eventDetail.status === 'failed' ? fmtTime(eventDetail.next_retry_at) : '-'} />
              <FieldRow label="完成时间" value={fmtTime(eventDetail.completed_at)} />
            </div>
            {eventDetail.status === 'running' && (
              <div className="border-t border-[var(--color-line-soft)] pt-2">
                <FieldRow label="执行器" value={eventDetail.locked_by || '-'} mono />
                <FieldRow label="锁到期时间" value={fmtTime(eventDetail.locked_until)} />
                {eventDetail.lock_expired && (
                  <InlineAlert tone="warn">
                    执行器锁已过期但任务仍标记为执行中，可能执行器已崩溃。可点击「立即重试」重新排队。
                  </InlineAlert>
                )}
              </div>
            )}
            {eventDetail.last_error && (
              <div>
                <div className="mb-1 text-[12.5px] text-[var(--color-text-sub)]">最近错误</div>
                <div className="whitespace-pre-wrap break-all rounded-md border border-[var(--color-line)] bg-[var(--color-danger-bg)] p-3 text-[12.5px] leading-relaxed text-[var(--color-danger)]">
                  {eventDetail.last_error}
                </div>
              </div>
            )}
            <div>
              <div className="mb-1 text-[12.5px] text-[var(--color-text-sub)]">任务数据</div>
              <pre className="max-h-64 overflow-auto rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3 font-mono text-[12px] leading-relaxed text-[var(--color-text)]">
                {JSON.stringify(eventDetail.payload ?? {}, null, 2)}
              </pre>
            </div>
          </div>
        </DrawerShell>
      )}

      {/* 丢弃确认 */}
      {discardTarget && (
        <ConfirmDialog
          title="丢弃异步任务"
          tone="danger"
          confirmLabel="丢弃"
          busyLabel="丢弃中"
          description={
            <>
              将丢弃 <b>{discardTarget.scope_kind === 'platform' ? '平台知识库' : discardTarget.tenant_name || discardTarget.tenant_id}</b> 的
              「{OUTBOX_OP_LABEL[discardTarget.op] || discardTarget.op}」任务。
              丢弃后不再自动重试，任务记录保留可查；若该任务对应 RAGFlow 侧数据清理，需人工确认已无残留。
            </>
          }
          onClose={() => setDiscardTarget(null)}
          onConfirm={() => doDiscardEvent(discardTarget)}
        />
      )}

      {/* 重新供给确认 */}
      {reconcileTarget && (
        <ConfirmDialog
          title="重新供给 RAGFlow 账号"
          tone="info"
          confirmLabel="提交"
          busyLabel="提交中"
          description={
            <>
              将为租户 <b>{reconcileTarget.tenant_name || reconcileTarget.tenant_id}</b> 提交「重新供给」异步任务，
              后台执行器数秒内会重新创建 RAGFlow 账号并签发访问密钥。执行结果可在绑定状态与异步任务队列查看。
            </>
          }
          onClose={() => setReconcileTarget(null)}
          onConfirm={() => doReconcile(reconcileTarget)}
        />
      )}
    </div>
  )
}
