import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useOutletContext, useSearchParams } from 'react-router-dom'
import {
  AlertTriangle,
  Bot,
  CheckCircle2,
  Clock3,
  Database,
  Gauge,
  MessageSquareText,
  Network,
  Wrench,
  X,
} from 'lucide-react'

import {
  ObservabilityAgentRuns,
  type AgentRunChain,
  type AgentRunDetail,
  type AgentRunItem,
  type AgentRunListParams,
  type AgentRunStats,
} from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  Input,
  PageHeader,
  Pagination,
  Panel,
  SearchInput,
  SegmentedControl,
  Select,
  stickyRightTdCls,
  Tabs,
  Toolbar,
  TrendChart,
} from '../components/ui'

type RangeKey = 'today' | '7d' | 'month' | 'custom'

type Filters = {
  runtimeKind: string
  triggerSource: string
  status: string
  agentId: string
  accountId: string
  // F25 评审返修：平台侧支持 ?tenant_id= 深链（告警「去排查」/ 租户 360° 下钻）
  tenantId: string
  minDurationMs: string
  errorsOnly: boolean
  hasToolError: boolean
  q: string
}

const DEFAULT_FILTERS: Filters = {
  runtimeKind: '',
  triggerSource: '',
  status: '',
  agentId: '',
  accountId: '',
  tenantId: '',
  minDurationMs: '',
  errorsOnly: false,
  hasToolError: false,
  q: '',
}

const KNOWN_STATUS = new Set(['running', 'awaiting_user', 'completed', 'failed', 'cancelled'])

// F25 评审返修：告警中心「去排查」与租户 360° 下钻带的查询参数必须真正被消费
function filtersFromSearch(sp: URLSearchParams): Filters {
  const status = sp.get('status') ?? ''
  return {
    ...DEFAULT_FILTERS,
    status: KNOWN_STATUS.has(status) ? status : '',
    minDurationMs: (sp.get('min_duration_ms') ?? '').replace(/[^0-9]/g, ''),
    tenantId: (sp.get('tenant_id') ?? '').replace(/[^0-9]/g, ''),
    errorsOnly: sp.get('errors_only') === 'true',
  }
}

const RUNTIME_OPTIONS: [string, string][] = [
  ['', '全部运行时'],
  ['openclaw', 'OpenClaw'],
  ['hermes', 'Hermes'],
  ['dsh', '知办通用运行时（dsh）'],
  ['zap_external', '外部自定义'],
  ['builtin_llm', '内置模型'],
  ['unknown', '未知(补录)'],
]

const TRIGGER_OPTIONS: [string, string][] = [
  ['', '全部来源'],
  ['chat', '单聊'],
  ['room', '群聊'],
  ['a2a', 'Agent 互调'],
]

const STATUS_OPTIONS: [string, string][] = [
  ['', '全部状态'],
  ['completed', '成功'],
  ['failed', '失败'],
  ['cancelled', '已取消'],
  ['awaiting_user', '等待用户'],
]

const STATUS_LABEL: Record<string, string> = {
  completed: '成功',
  failed: '失败',
  cancelled: '已取消',
  awaiting_user: '等待用户',
  running: '进行中',
}

const RUNTIME_LABEL: Record<string, string> = {
  openclaw: 'OpenClaw',
  hermes: 'Hermes',
  dsh: '知办通用运行时（dsh）',
  zap_external: '外部自定义',
  builtin_llm: '内置模型',
  unknown: '未知(补录)',
}

const TRIGGER_LABEL: Record<string, string> = {
  chat: '单聊',
  room: '群聊',
  a2a: 'Agent 互调',
  debug: '调试',
  cron: '定时任务',
  rtc: '实时通话',
}

const STEP_KIND_LABEL: Record<string, string> = {
  thinking: '思考',
  tool_call: '工具调用',
  a2a_invoke: 'Agent 互调',
  kb_retrieval: '知识检索',
  hitl_wait: '等待用户',
  stage: '阶段',
}

function rangeToWindow(range: RangeKey, customFrom: string, customTo: string): { from?: string; to?: string } {
  const now = new Date()
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  switch (range) {
    case 'today':
      return { from: startOfDay.toISOString(), to: now.toISOString() }
    case '7d':
      return { from: new Date(now.getTime() - 7 * 24 * 3600 * 1000).toISOString(), to: now.toISOString() }
    case 'month':
      return { from: new Date(now.getFullYear(), now.getMonth(), 1).toISOString(), to: now.toISOString() }
    case 'custom': {
      const out: { from?: string; to?: string } = {}
      if (customFrom) out.from = new Date(customFrom).toISOString()
      if (customTo) out.to = new Date(customTo).toISOString()
      return out
    }
  }
}

function fmtTime(iso: string) {
  try {
    return new Date(iso).toLocaleString('zh-CN', { hour12: false })
  } catch {
    return iso
  }
}

function fmtMs(ms?: number | null) {
  if (ms == null) return '—'
  if (ms < 1000) return `${ms}ms`
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60_000).toFixed(1)}min`
}

function durationLabel(ms?: number) {
  if (ms == null) return <span className="text-[var(--color-text-muted)]">—</span>
  if (ms < 5000) return <span className="text-green-700">{fmtMs(ms)}</span>
  if (ms < 30_000) return <span className="text-amber-700">{fmtMs(ms)}</span>
  return <span className="text-red-700">{fmtMs(ms)}</span>
}

function statusBadge(status: string) {
  const label = STATUS_LABEL[status] || status
  if (status === 'completed')
    return <span className="inline-flex items-center gap-1 text-green-700"><CheckCircle2 size={14} />{label}</span>
  if (status === 'failed')
    return <span className="inline-flex items-center gap-1 text-red-700"><AlertTriangle size={14} />{label}</span>
  if (status === 'awaiting_user')
    return <span className="inline-flex items-center gap-1 text-amber-700">{label}</span>
  return <span className="text-[var(--color-text-sub)]">{label}</span>
}

function fmtTokens(n?: number) {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`
  return String(n)
}

type MetricTone = 'blue' | 'green' | 'purple' | 'orange'

const METRIC_TONE: Record<MetricTone, string> = {
  blue: 'bg-[var(--color-icon-blue-bg)] text-[var(--color-icon-blue)]',
  green: 'bg-[var(--color-icon-green-bg)] text-[var(--color-icon-green)]',
  purple: 'bg-[var(--color-icon-purple-bg)] text-[var(--color-icon-purple)]',
  orange: 'bg-[var(--color-icon-orange-bg)] text-[var(--color-icon-orange)]',
}

function MetricsStrip({ items }: {
  items: Array<{ icon: React.ReactNode; label: string; value: React.ReactNode; sub?: React.ReactNode; tone: MetricTone }>
}) {
  return (
    <Panel className="mb-3 overflow-hidden">
      <div className="grid gap-px bg-[var(--color-line)] sm:grid-cols-2 xl:grid-cols-4">
        {items.map((item) => (
          <div key={item.label} className="flex min-w-0 items-center gap-4 bg-white px-5 py-4">
            <div className={`grid h-11 w-11 shrink-0 place-items-center rounded-lg ${METRIC_TONE[item.tone]}`}>
              {item.icon}
            </div>
            <div className="min-w-0">
              <div className="text-[12px] text-[var(--color-text-sub)]">{item.label}</div>
              <div className="mt-0.5 text-[23px] font-semibold leading-tight tabular-nums text-[var(--color-text)]">{item.value}</div>
              {item.sub && <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]">{item.sub}</div>}
            </div>
          </div>
        ))}
      </div>
    </Panel>
  )
}

function RunHealthOverview({ totals, periodLabel }: {
  totals: AgentRunStats['totals']
  periodLabel: string
}) {
  const successRate = totals.successRate ?? 0
  const failedRate = totals.runs > 0 ? (totals.failed / totals.runs) * 100 : 0
  const radius = 44
  const circumference = 2 * Math.PI * radius
  const successArc = Math.max(0, Math.min(100, successRate)) / 100 * circumference

  if (totals.runs <= 0) {
    return <div className="grid min-h-[204px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">{periodLabel}暂无运行</div>
  }

  return (
    <div className="grid min-h-[204px] items-center gap-5 md:grid-cols-[132px_minmax(0,1fr)]">
      <div className="relative mx-auto h-[124px] w-[124px]">
        <svg viewBox="0 0 112 112" className="h-full w-full -rotate-90" aria-hidden="true">
          <circle cx="56" cy="56" r={radius} fill="none" stroke={totals.failed > 0 ? 'var(--color-danger)' : 'var(--color-line-soft)'} strokeWidth="10" />
          <circle
            cx="56"
            cy="56"
            r={radius}
            fill="none"
            stroke="var(--color-success)"
            strokeWidth="10"
            strokeLinecap="butt"
            strokeDasharray={`${successArc} ${circumference - successArc}`}
          />
        </svg>
        <div className="absolute inset-0 grid place-items-center text-center">
          <div>
            <div className="text-[11px] text-[var(--color-text-mute)]">成功率</div>
            <div className="mt-0.5 text-[25px] font-semibold leading-none tabular-nums text-[var(--color-text)]">{successRate.toFixed(1)}%</div>
          </div>
        </div>
      </div>
      <div className="min-w-0">
        <div className="grid grid-cols-3 divide-x divide-[var(--color-line)]">
          <div className="pr-4">
            <div className="flex items-center gap-1.5 text-[12px] text-[var(--color-text-sub)]"><span className="h-2 w-2 rounded-full bg-[var(--color-success)]" />成功</div>
            <div className="mt-1 text-[21px] font-semibold tabular-nums">{totals.completed}</div>
          </div>
          <div className="px-4">
            <div className="flex items-center gap-1.5 text-[12px] text-[var(--color-text-sub)]"><span className="h-2 w-2 rounded-full bg-[var(--color-danger)]" />失败</div>
            <div className="mt-1 text-[21px] font-semibold tabular-nums">{totals.failed}</div>
          </div>
          <div className="pl-4">
            <div className="text-[12px] text-[var(--color-text-sub)]">运行总数</div>
            <div className="mt-1 text-[21px] font-semibold tabular-nums">{totals.runs}</div>
          </div>
        </div>
        <div className="mt-5 flex h-2.5 overflow-hidden rounded-full bg-[var(--color-line-soft)]" title={`成功 ${totals.completed}，失败 ${totals.failed}`}>
          {totals.completed > 0 && <div className="h-full bg-[var(--color-success)]" style={{ width: `${successRate}%` }} />}
          {totals.failed > 0 && <div className="h-full bg-[var(--color-danger)]" style={{ width: `${failedRate}%` }} />}
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-[12px] text-[var(--color-text-sub)]">
          <span>成功 {totals.completed}（{successRate.toFixed(1)}%）</span>
          <span>失败 {totals.failed}（{failedRate.toFixed(1)}%）</span>
        </div>
      </div>
    </div>
  )
}

function SlowestTools({ tools }: { tools: AgentRunStats['slowest_tools'] }) {
  const maxDuration = Math.max(...tools.map((tool) => tool.avgDurationMs), 1)
  if (!tools.length) {
    return <div className="grid min-h-[204px] place-items-center text-xs text-[var(--color-text-sub)]">所选时间范围内暂无工具调用。</div>
  }
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-[24px_minmax(120px,1fr)_minmax(90px,1.5fr)_54px_64px] gap-3 text-[11px] text-[var(--color-text-mute)]">
        <span />
        <span>工具</span>
        <span />
        <span className="text-right">调用</span>
        <span className="text-right">平均耗时</span>
      </div>
      {tools.map((tool, index) => (
        <div key={tool.name} className="grid grid-cols-[24px_minmax(120px,1fr)_minmax(90px,1.5fr)_54px_64px] items-center gap-3 text-[12px]">
          <span className="grid h-6 w-6 place-items-center rounded-full bg-[var(--color-brand-soft)] font-semibold tabular-nums text-[var(--color-brand)]">{index + 1}</span>
          <span className="truncate font-mono text-[var(--color-text)]" title={tool.name}>{tool.name}</span>
          <span className="h-2 overflow-hidden rounded-full bg-[var(--color-line-soft)]">
            <span className="block h-full rounded-full bg-[var(--color-brand-line)]" style={{ width: `${Math.max((tool.avgDurationMs / maxDuration) * 100, 4)}%` }} />
          </span>
          <span className="text-right tabular-nums text-[var(--color-text-sub)]">{tool.calls} 次</span>
          <span className="text-right tabular-nums font-medium text-[var(--color-text)]">{fmtMs(tool.avgDurationMs)}</span>
        </div>
      ))}
    </div>
  )
}

function StepTimeline({ detail }: { detail: AgentRunDetail }) {
  const totalMs = Math.max(detail.run.durationMs || 1, 1)
  const runStart = new Date(detail.run.startedAt).getTime()
  if (!detail.steps.length) {
    return <div className="text-xs text-[var(--color-text-sub)]">本次运行没有记录到中间步骤（纯文本回答或运行时未透出过程事件）。</div>
  }
  return (
    <div className="relative">
      <div className="absolute bottom-4 left-[13px] top-4 w-px bg-[var(--color-line)]" />
      {detail.steps.map((st, index) => {
        const offset = Math.min(Math.max(((new Date(st.startedAt).getTime() - runStart) / totalMs) * 100, 0), 98)
        const width = Math.min(Math.max(((st.durationMs || 0) / totalMs) * 100, 2), 100 - offset)
        const isError = st.status === 'error'
        const statusLabel = isError ? '失败' : st.status === 'running' ? '进行中' : st.status === 'cancelled' ? '已取消' : '完成'
        return (
          <div key={st.seq} className={`relative flex gap-3 ${index === detail.steps.length - 1 ? '' : 'pb-3'}`}>
            <div className={`relative z-10 mt-3 grid h-7 w-7 shrink-0 place-items-center rounded-full border bg-white ${isError ? 'border-[var(--color-danger)] text-[var(--color-danger)]' : 'border-[var(--color-brand-line)] text-[var(--color-brand)]'}`}>
              {isError ? <AlertTriangle size={13} /> : st.stepKind === 'tool_call' ? <Wrench size={13} /> : st.stepKind === 'a2a_invoke' ? <Network size={13} /> : <CheckCircle2 size={13} />}
            </div>
            <div className="min-w-0 flex-1 rounded-lg border border-[var(--color-line)] bg-white px-3.5 py-3">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className="shrink-0 text-[13px] font-medium text-[var(--color-text)]">{st.seq}. {STEP_KIND_LABEL[st.stepKind] || st.stepKind}</span>
                    {st.name && <span className="truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={st.name}>{st.name}</span>}
                  </div>
                  <div className="mt-1 text-[11px] text-[var(--color-text-mute)]">
                    {fmtTime(st.startedAt)} · 耗时 {fmtMs(st.durationMs)}
                  </div>
                </div>
                <span className={`shrink-0 text-[12px] font-medium ${isError ? 'text-[var(--color-danger)]' : st.status === 'running' ? 'text-[var(--color-warn)]' : st.status === 'cancelled' ? 'text-[var(--color-text-mute)]' : 'text-[var(--color-success)]'}`}>
                  {statusLabel}
                </span>
              </div>
              <div className="relative mt-3 h-1.5 overflow-hidden rounded-full bg-[var(--color-bg-sub)]" title={`相对运行时序：${fmtMs(st.durationMs)}`}>
                <div
                  className={`absolute inset-y-0 rounded-full ${isError ? 'bg-[var(--color-danger)]' : 'bg-[var(--color-brand)]'}`}
                  style={{ left: `${offset}%`, width: `${width}%` }}
                />
              </div>
              {st.errorMessage && <div className="mt-2 text-[12px] leading-relaxed text-[var(--color-danger)]">{st.errorMessage}</div>}
            </div>
          </div>
        )
      })}
    </div>
  )
}

function ChainView({ scope, runUuid, contentAvailable }: {
  scope: 'platform' | 'tenant'
  runUuid: string
  contentAvailable: boolean
}) {
  const [chain, setChain] = useState<AgentRunChain | null>(null)
  const [showPayloads, setShowPayloads] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setLoading(true)
      setError('')
      ObservabilityAgentRuns.chain(scope, runUuid, showPayloads)
        .then(setChain)
        .catch((e: Error) => setError(e.message || '加载链路失败'))
        .finally(() => setLoading(false))
    }, 0)
    return () => window.clearTimeout(timer)
  }, [scope, runUuid, showPayloads])

  if (loading && !chain) return <div className="text-xs text-[var(--color-text-sub)]">链路加载中...</div>
  if (error) return <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">{error}</div>
  if (!chain) return null
  if (!chain.edges.length) {
    return <div className="text-xs text-[var(--color-text-sub)]">本次运行没有 Agent 互调。</div>
  }
  return (
    <div className="space-y-3">
      {contentAvailable && (
        <label className="flex cursor-pointer items-center gap-1.5 text-xs text-[var(--color-text-sub)]">
          <input type="checkbox" checked={showPayloads} onChange={(e) => setShowPayloads(e.target.checked)} />
          显示传参与返回（本操作将记录审计）
        </label>
      )}
      <div className="space-y-2">
        {chain.edges.map((e) => (
          <div key={e.edgeUuid} className="rounded border border-[var(--color-line)] p-2 text-xs" style={{ marginLeft: Math.min(e.depth, 6) * 16 }}>
            <div className="flex flex-wrap items-center gap-2">
              <Network size={13} className="text-purple-500" />
              <span className="font-medium">{e.fromAgentName}</span>
              <span className="text-[var(--color-text-muted)]">→</span>
              <span className="font-medium">{e.toAgentName}</span>
              <span className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5">{e.invokeKind || 'sync'}</span>
              {e.status === 'done'
                ? <span className="text-green-700">完成</span>
                : e.status.startsWith('dropped_')
                  ? <span className="text-red-700" title="被治理策略拦截">{e.status === 'dropped_loop' ? '防环拦截' : e.status === 'dropped_budget' ? '预算拦截' : '白名单拦截'}</span>
                  : e.status === 'failed'
                    ? <span className="text-red-700">失败</span>
                    : <span className="text-amber-700">{e.status}</span>}
              <span className="ml-auto tabular-nums text-[var(--color-text-sub)]">{fmtMs(e.latencyMs)}</span>
              {(e.tokensIn != null || e.tokensOut != null) && (
                <span className="tabular-nums text-[var(--color-text-sub)]">tokens {fmtTokens(e.tokensIn)} / {fmtTokens(e.tokensOut)}</span>
              )}
            </div>
            {e.errorMessage && <div className="mt-1 text-red-700">{e.errorMessage}</div>}
            {showPayloads && (
              <div className="mt-1.5 space-y-1">
                <pre className="max-h-40 overflow-auto rounded bg-[var(--color-bg-sub)] p-1.5">请求: {JSON.stringify(e.requestPayload ?? null, null, 2)}</pre>
                <pre className="max-h-40 overflow-auto rounded bg-[var(--color-bg-sub)] p-1.5">返回: {JSON.stringify(e.responsePayload ?? null, null, 2)}</pre>
              </div>
            )}
          </div>
        ))}
      </div>
      {chain.nodes.length > 1 && (
        <div className="text-[11px] text-[var(--color-text-muted)]">
          链上共 {chain.nodes.length} 个有运行记录的节点；被调 Agent 直连执行时以调用边呈现（含耗时/token）。
        </div>
      )}
      {chain.truncated && (
        <div className="text-[11px] text-amber-700">链路过大已截断，完整关系请到「Agent 互调」调用图查看。</div>
      )}
    </div>
  )
}

function RunDrawer({ item, scope, onClose, onOpenConversation }: {
  item: AgentRunItem
  scope: 'platform' | 'tenant'
  onClose: () => void
  onOpenConversation: (conversationUuid: string) => void
}) {
  const [detail, setDetail] = useState<AgentRunDetail | null>(null)
  const [tab, setTab] = useState<'timeline' | 'chain'>('timeline')
  const [error, setError] = useState('')

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setDetail(null)
      setError('')
      ObservabilityAgentRuns.detail(scope, item.uuid)
        .then(setDetail)
        .catch((e: Error) => setError(e.message || '加载详情失败'))
    }, 0)
    return () => window.clearTimeout(timer)
  }, [scope, item.uuid])

  return (
    <DrawerShell
      title="运行详情"
      subtitle={`${item.agentName} · ${fmtTime(item.startedAt)}`}
      onClose={onClose}
      width="sm"
      footer={<div className="flex justify-end"><Button variant="secondary" onClick={onClose}>关闭</Button></div>}
    >
      <div className="space-y-5 text-sm">
        {error && (
          <div className="rounded-md border border-red-200 bg-[var(--color-danger-bg)] px-3 py-2 text-xs text-[var(--color-danger)]">
            {error}
          </div>
        )}
        {!detail && !error && (
          <div className="rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-4 py-10 text-center text-[13px] text-[var(--color-text-sub)]">
            正在加载运行详情...
          </div>
        )}
        {detail && (
          <>
            <section className="rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="text-[17px] font-semibold text-[var(--color-text)]">{detail.run.agentName}</span>
                    {detail.run.agentVersion && <span className="text-xs text-[var(--color-text-mute)]">v{detail.run.agentVersion}</span>}
                    {detail.run.backfilled && (
                      <span className="rounded bg-[var(--color-warn-bg)] px-1.5 py-0.5 text-[11px] text-[var(--color-warn)]" title="实时采集缺失，由对账任务从消息记录补录（精度降级）">补录</span>
                    )}
                  </div>
                  <div className="mt-1 text-[12px] text-[var(--color-text-sub)]">
                    {TRIGGER_LABEL[detail.run.triggerSource] || detail.run.triggerSource}{detail.run.accountName ? ` · ${detail.run.accountName}` : ''}
                  </div>
                </div>
                <div className="rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px]">
                  {statusBadge(detail.run.status)}
                </div>
              </div>
            </section>

            <section>
              <h3 className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">基本信息</h3>
              <div className="grid grid-cols-2 overflow-hidden rounded-lg border border-[var(--color-line)] bg-white">
                {[
                  ['运行时', <>{RUNTIME_LABEL[detail.run.runtimeKind] || detail.run.runtimeKind}{detail.run.model ? <span className="ml-1 font-mono text-xs">{detail.run.model}</span> : null}</>],
                  ['开始时间', fmtTime(detail.run.startedAt)],
                  ['总耗时', <>{durationLabel(detail.run.durationMs)}{detail.run.hitlWaitMs ? <span className="ml-1 text-xs text-[var(--color-text-mute)]">另有等待用户 {fmtMs(detail.run.hitlWaitMs)}</span> : null}</>],
                  ['首输出', fmtMs(detail.run.firstOutputMs)],
                ].map(([label, value]) => (
                  <div key={label as string} className="border-b border-r border-[var(--color-line-soft)] px-4 py-3 even:border-r-0 [&:nth-last-child(-n+2)]:border-b-0">
                    <div className="text-[11px] text-[var(--color-text-mute)]">{label}</div>
                    <div className="mt-1 text-[13px] text-[var(--color-text)]">{value}</div>
                  </div>
                ))}
              </div>
            </section>

            <section>
              <h3 className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">运行概览</h3>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                {[
                  ['思考时长', fmtMs(detail.run.thinkingMs)],
                  ['工具调用', `${detail.run.toolCallCount} 次`],
                  ['工具失败', `${detail.run.toolErrorCount} 次`],
                  ['Agent 互调', `${detail.run.a2aEdgeCount} 次`],
                ].map(([label, value]) => (
                  <div key={label} className="rounded-lg border border-[var(--color-line)] bg-white px-3 py-3">
                    <div className="text-[11px] text-[var(--color-text-mute)]">{label}</div>
                    <div className={`mt-1 text-[16px] font-semibold tabular-nums ${label === '工具失败' && detail.run.toolErrorCount > 0 ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]'}`}>{value}</div>
                  </div>
                ))}
              </div>
            </section>

            <section>
              <h3 className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">Token 消耗</h3>
              <div className="grid grid-cols-2 gap-3 rounded-lg border border-[var(--color-line)] bg-white p-4 text-xs">
                <div>
                  <div className="text-[var(--color-text-mute)]">运行时上报</div>
                  <div className="mt-1.5 tabular-nums text-[var(--color-text)]">
                    {detail.run.totalTokens != null
                      ? <>共 {fmtTokens(detail.run.totalTokens)}（入 {fmtTokens(detail.inputTokens)} / 出 {fmtTokens(detail.outputTokens)}）</>
                      : '— 运行时未上报'}
                  </div>
                </div>
                <div>
                  <div className="text-[var(--color-text-mute)]">计费口径</div>
                  <div className="mt-1.5 tabular-nums text-[var(--color-text)]">
                    {detail.billingUsage
                      ? <>共 {fmtTokens(detail.billingUsage.totalTokens)} · {detail.billingUsage.credits} 积分{detail.billingUsage.matchedLevel === 'agent_day' && <span className="ml-1 text-[var(--color-text-mute)]" title="计费事件未携带消息级归因，展示该数字员工当日汇总">（当日汇总）</span>}</>
                      : '—'}
                  </div>
                </div>
              </div>
            </section>

            {detail.errorMessage && (
              <div className="rounded-md border border-red-200 bg-[var(--color-danger-bg)] px-3 py-2 text-xs text-[var(--color-danger)]">
                <span className="font-mono">{detail.run.errorCode}</span> {detail.errorMessage}
              </div>
            )}

            <section>
              <Tabs
                variant="underline"
                value={tab}
                onChange={setTab}
                items={[
                  { value: 'timeline', label: '步骤时间线' },
                  ...(detail.run.a2aEdgeCount > 0 || detail.links.rootA2aEdgeUuid
                    ? [{ value: 'chain' as const, label: 'Agent 互调链路' }]
                    : []),
                ]}
              />
              <div className="mt-4">
                {tab === 'timeline' && <StepTimeline detail={detail} />}
                {tab === 'chain' && (
                  <ChainView scope={scope} runUuid={detail.run.uuid} contentAvailable={detail.links.contentAvailable} />
                )}
              </div>
            </section>

            <div className="flex flex-wrap items-center gap-2 border-t border-[var(--color-line)] pt-4">
              <Button
                variant="secondary"
                size="sm"
                disabled={!detail.links.contentAvailable}
                title={detail.links.contentAvailable ? '在会话检索中查看完整对话内容' : '需要「会话内容查看」权限'}
                onClick={() => detail.links.conversationUuid && onOpenConversation(detail.links.conversationUuid)}
              >
                <MessageSquareText size={14} /> 查看会话内容
              </Button>
              {detail.links.traceId && (
                <span className="font-mono text-[11px] text-[var(--color-text-mute)]" title="可在调用日志页按 Trace 检索 HTTP 层明细">
                  trace: {detail.links.traceId}
                </span>
              )}
            </div>
          </>
        )}
      </div>
    </DrawerShell>
  )
}

const COL_COUNT = 12

export function ObservabilityAgentRunsPage() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isPlatform = actScope?.kind === 'platform'
  const isTenant = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const scope: 'platform' | 'tenant' = isPlatform ? 'platform' : 'tenant'

  const [searchParams] = useSearchParams()
  const [range, setRange] = useState<RangeKey>('today')
  const [customFrom, setCustomFrom] = useState('')
  const [customTo, setCustomTo] = useState('')
  const [filters, setFilters] = useState<Filters>(() => filtersFromSearch(searchParams))
  const [items, setItems] = useState<AgentRunItem[]>([])
  const [total, setTotal] = useState(0)
  const [stats, setStats] = useState<AgentRunStats | null>(null)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(false)
  const [selected, setSelected] = useState<AgentRunItem | null>(null)
  const navigate = useNavigate()

  // 每次请求现算窗口 (review C11: useMemo 会把 today/近7天 的 now 冻结在首次渲染)
  const listSeq = useRef(0)
  const statsSeq = useRef(0)

  const fetchData = useCallback(() => {
    if (!actScope) return
    setLoading(true)
    const seq = ++listSeq.current
    const params: AgentRunListParams = {
      limit: pageSize,
      offset: (page - 1) * pageSize,
      ...rangeToWindow(range, customFrom, customTo),
    }
    if (filters.runtimeKind) params.runtime_kind = filters.runtimeKind
    if (filters.triggerSource) params.trigger_source = filters.triggerSource
    if (filters.status) params.status = filters.status
    if (filters.agentId) params.digital_employee_id = Number(filters.agentId)
    if (filters.accountId) params.account_id = Number(filters.accountId)
    if (filters.minDurationMs) params.min_duration_ms = Number(filters.minDurationMs)
    if (isPlatform && filters.tenantId) params.tenant_id = Number(filters.tenantId)
    if (filters.errorsOnly) params.errors_only = 'true'
    if (filters.hasToolError) params.has_tool_error = 'true'
    if (filters.q) params.q = filters.q

    ObservabilityAgentRuns.list(scope, params)
      .then((r) => {
        if (seq !== listSeq.current) return // 乱序守卫 (review C12)
        setItems(r.items || [])
        setTotal(r.total)
      })
      .catch(() => {
        if (seq !== listSeq.current) return
        setItems([])
        setTotal(0)
      })
      .finally(() => { if (seq === listSeq.current) setLoading(false) })
  }, [actScope, scope, isPlatform, filters, page, pageSize, range, customFrom, customTo])

  useEffect(() => {
    const timer = window.setTimeout(() => fetchData(), 0)
    return () => window.clearTimeout(timer)
  }, [fetchData])

  // stats 只随时间窗/scope 变化, 与翻页/筛选解耦 (review C12: 它是页面最重的聚合查询)
  useEffect(() => {
    if (!actScope) return
    const seq = ++statsSeq.current
    const timer = window.setTimeout(() => {
      ObservabilityAgentRuns.stats(scope, { ...rangeToWindow(range, customFrom, customTo), group_by: 'day' })
        .then((r) => { if (seq === statsSeq.current) setStats(r) })
        .catch(() => { if (seq === statsSeq.current) setStats(null) })
    }, 0)
    return () => window.clearTimeout(timer)
  }, [actScope, scope, range, customFrom, customTo])

  const openConversation = (conversationUuid: string) => {
    navigate(`/observability/conversations?uuid=${encodeURIComponent(conversationUuid)}`)
  }

  if (switchingScope || !actScope) return null
  if (!isPlatform && !isTenant) {
    return <EmptyState title="选择管理范围" description="请先在左上角选择平台或租户后查看运行监测。" />
  }

  const totals = stats?.totals
  const periodLabel = range === 'today' ? '今日' : range === '7d' ? '近7天' : range === 'month' ? '本月' : '所选范围'
  const trendPoints = (stats?.buckets || []).map((b) => ({
    label: b.key,
    title: `${b.key} 成功 ${b.completed} / 失败 ${b.failed}`,
    values: { completed: b.completed, failed: b.failed },
  }))

  const hasFilters = filters.runtimeKind || filters.triggerSource || filters.status || filters.agentId || filters.accountId || filters.tenantId || filters.minDurationMs || filters.errorsOnly || filters.hasToolError || filters.q

  return (
    <>
      <PageHeader
        title="Agent 运行监测"
        subtitle={isPlatform ? '全部租户数字员工的每次执行：耗时、思考、工具、Token' : '本租户数字员工的每次执行：耗时、思考、工具、Token'}
      />

      <div className="mb-3 flex items-center gap-3">
        <SegmentedControl
          value={range}
          onChange={(v) => { setRange(v); setPage(1) }}
          options={[
            { value: 'today', label: '今日' },
            { value: '7d', label: '近7天' },
            { value: 'month', label: '本月' },
            { value: 'custom', label: '自定义' },
          ]}
        />
        {range === 'custom' && (
          <div className="flex items-center gap-2">
            <Input type="datetime-local" value={customFrom} onChange={(e) => { setCustomFrom(e.target.value); setPage(1) }} className="w-[190px]" />
            <span className="text-[var(--color-text-muted)]">—</span>
            <Input type="datetime-local" value={customTo} onChange={(e) => { setCustomTo(e.target.value); setPage(1) }} className="w-[190px]" />
          </div>
        )}
      </div>

      <MetricsStrip
        items={[
          {
            icon: <Gauge size={22} />,
            label: '运行数',
            value: totals ? totals.runs : '—',
            sub: totals ? <>成功 <span className="text-[var(--color-success)]">{totals.completed}</span> · 失败 <span className="text-[var(--color-danger)]">{totals.failed}</span></> : undefined,
            tone: 'blue',
          },
          {
            icon: <Clock3 size={22} />,
            label: 'P95 耗时',
            value: totals ? fmtMs(totals.p95DurationMs) : '—',
            sub: totals ? <>P50 {fmtMs(totals.p50DurationMs)}</> : undefined,
            tone: 'green',
          },
          {
            icon: <Bot size={22} />,
            label: '平均思考时长',
            value: totals ? fmtMs(totals.avgThinkingMs) : '—',
            sub: totals?.thinkingCoverage != null ? <>覆盖率 {(totals.thinkingCoverage * 100).toFixed(0)}%</> : undefined,
            tone: 'purple',
          },
          {
            icon: <Database size={22} />,
            label: 'Token 消耗',
            value: totals ? fmtTokens(totals.totalTokens) : '—',
            sub: totals?.tokenCoverage != null ? <>上报覆盖率 {(totals.tokenCoverage * 100).toFixed(0)}%</> : undefined,
            tone: 'orange',
          },
        ]}
      />

      <Panel className="mb-4 overflow-hidden">
        <div className="grid lg:grid-cols-[minmax(0,1.05fr)_minmax(420px,0.95fr)]">
          <section className="p-5 lg:border-r lg:border-[var(--color-line)]">
            <div className="mb-3 text-[14px] font-semibold text-[var(--color-text)]">{trendPoints.length <= 1 ? '运行健康度' : '运行趋势'}</div>
            {trendPoints.length <= 1 && totals ? (
              <RunHealthOverview totals={totals} periodLabel={periodLabel} />
            ) : (
              <TrendChart
                points={trendPoints}
                series={[
                  { key: 'completed', label: '成功', color: 'var(--color-icon-green)' },
                  { key: 'failed', label: '失败', color: 'var(--color-icon-red)' },
                ]}
                height={180}
                emptyText="所选时间范围内暂无运行"
              />
            )}
          </section>
          <section className="border-t border-[var(--color-line)] p-5 lg:border-t-0">
            <div className="mb-4 text-[14px] font-semibold text-[var(--color-text)]">最慢工具 Top5</div>
            <SlowestTools tools={stats?.slowest_tools || []} />
          </section>
        </div>
      </Panel>

      <Toolbar
        search={
          <SearchInput
            value={filters.q}
            onChange={(v) => { setFilters((f) => ({ ...f, q: v })); setPage(1) }}
            placeholder="搜索数字员工名称"
          />
        }
        filters={
          <>
            <div className="w-[132px]">
              <Select value={filters.runtimeKind} onChange={(e) => { setFilters((f) => ({ ...f, runtimeKind: e.target.value })); setPage(1) }}>
                {RUNTIME_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </Select>
            </div>
            <div className="w-[120px]">
              <Select value={filters.triggerSource} onChange={(e) => { setFilters((f) => ({ ...f, triggerSource: e.target.value })); setPage(1) }}>
                {TRIGGER_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </Select>
            </div>
            <div className="w-[120px]">
              <Select value={filters.status} onChange={(e) => { setFilters((f) => ({ ...f, status: e.target.value })); setPage(1) }}>
                {STATUS_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </Select>
            </div>
            {isPlatform && (
              <div className="w-[100px]">
                <Input placeholder="租户 ID" value={filters.tenantId}
                  onChange={(e) => { setFilters((f) => ({ ...f, tenantId: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
              </div>
            )}
            <div className="w-[120px]">
              <Input placeholder="数字员工 ID" value={filters.agentId}
                onChange={(e) => { setFilters((f) => ({ ...f, agentId: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
            </div>
            <div className="w-[110px]">
              <Input placeholder="成员 ID" value={filters.accountId}
                onChange={(e) => { setFilters((f) => ({ ...f, accountId: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
            </div>
            <div className="w-[130px]">
              <Input placeholder="耗时 ≥ (ms)" value={filters.minDurationMs}
                onChange={(e) => { setFilters((f) => ({ ...f, minDurationMs: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
            </div>
            <label className="flex h-9 cursor-pointer items-center gap-1.5 whitespace-nowrap rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] px-3 text-[13px] text-[var(--color-text-sub)]">
              <input type="checkbox" checked={filters.errorsOnly}
                onChange={(e) => { setFilters((f) => ({ ...f, errorsOnly: e.target.checked })); setPage(1) }} />
              仅失败
            </label>
            <label className="flex h-9 cursor-pointer items-center gap-1.5 whitespace-nowrap rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] px-3 text-[13px] text-[var(--color-text-sub)]">
              <input type="checkbox" checked={filters.hasToolError}
                onChange={(e) => { setFilters((f) => ({ ...f, hasToolError: e.target.checked })); setPage(1) }} />
              有工具失败
            </label>
          </>
        }
        actions={hasFilters ? (
          <Button variant="ghost" size="sm" onClick={() => { setFilters({ ...DEFAULT_FILTERS }); setPage(1) }}><X size={14} /> 清除</Button>
        ) : undefined}
        summary={<span className="text-[12px] text-[var(--color-text-sub)]">共 {total} 条</span>}
      />

      <DataTable
        headers={['时间', ...(isPlatform ? ['租户'] : []), '数字员工', '触发', '运行时', '状态', '耗时', '思考', '工具', '互调', 'Token', '操作']}
        stickyLastCol
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<Gauge size={24} />}
            title="暂无运行记录"
            description="当前筛选条件下没有 Agent 运行。数字员工产生对话后，这里会出现每次执行的轨迹。"
          />
        ) : null}
      >
        {loading && <tr><td colSpan={COL_COUNT + (isPlatform ? 1 : 0)} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</td></tr>}
        {!loading && items.map((item) => (
          <tr key={item.uuid} className="group cursor-pointer hover:bg-[var(--color-bg-sub)]" onClick={() => setSelected(item)}>
            <td className="whitespace-nowrap px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{fmtTime(item.startedAt)}</td>
            {isPlatform && <td className="max-w-[120px] truncate px-4 py-3 text-[12px]" title={item.tenantName}>{item.tenantName || item.tenantId}</td>}
            <td className="max-w-[160px] truncate px-4 py-3 text-[12px]" title={item.agentName}>
              {item.agentName}
              {item.backfilled && <span className="ml-1 rounded bg-amber-50 px-1 text-[10px] text-amber-800" title="对账补录（精度降级）">补</span>}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[12px]">{TRIGGER_LABEL[item.triggerSource] || item.triggerSource}{item.accountName ? ` · ${item.accountName}` : ''}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[12px]">{RUNTIME_LABEL[item.runtimeKind] || item.runtimeKind}</td>
            <td className="whitespace-nowrap px-4 py-3">{statusBadge(item.status)}</td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">{durationLabel(item.durationMs)}</td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">{fmtMs(item.thinkingMs)}</td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">
              {item.toolCallCount}{item.toolErrorCount > 0 && <span className="ml-0.5 text-red-700">({item.toolErrorCount} 失败)</span>}
            </td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">{item.a2aEdgeCount || '—'}</td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">{fmtTokens(item.totalTokens)}</td>
            <td className={`whitespace-nowrap px-4 py-2 ${stickyRightTdCls}`}>
              <Button className="text-[var(--color-brand)]" variant="ghost" size="sm" onClick={(e) => { e.stopPropagation(); setSelected(item) }} title="查看运行详情">
                详情
              </Button>
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {selected && (
        <RunDrawer
          item={selected}
          scope={scope}
          onClose={() => setSelected(null)}
          onOpenConversation={openConversation}
        />
      )}
    </>
  )
}
