// 代理记账工单（F24 v2-W2, contracts/admin-startup-agent-api.md §4b）。
// 跟进代账线索的评估、报价、签约与服务回传；数据经 admin Go 代理自 baigong ops。
// event_key 在弹窗打开时生成一次，重试/双击复用（幂等；duplicate_event=已处理过）。
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Eye, NotebookPen, RefreshCw } from 'lucide-react'
import { useNavigate, useSearchParams } from 'react-router-dom'

import {
  StartupAgentCases,
  type StartupAgentCaseDetail,
  type StartupAgentCaseEvent,
  type StartupAgentCaseItem,
  type StartupAgentStats,
} from '../lib/api'
import { randomUUID } from '../lib/uuid'
import { notifyOk } from '../lib/toast'
import {
  CaseBadge as Badge,
  CaseField as Field,
  CaseTimelineItem,
  type CaseTimelineKind,
} from '../components/caseTimeline'
import { CASE_TONE as TONE } from '../components/caseTone'
import { CaseRefundDialog } from '../components/CaseRefundDialog'
import { RelatedCaseCard } from '../components/RelatedCaseCard'
import {
  Button,
  ActionMenu,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  KpiCard,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'

// stage → 展示映射（契约 §4b）。
function stageInfo(item: { status: string; stage: string }): { label: string; tone: string } {
  if (item.status === 'cancelled') return { label: '已关闭（流失）', tone: TONE.gray }
  if (item.status === 'completed') return { label: '已关闭（服务期满）', tone: TONE.success }
  if (item.status === 'failed') return { label: '异常终止', tone: TONE.danger }
  switch (item.stage) {
    case 'pending_reg': return { label: '待注册（挂起）', tone: TONE.gray }
    case 'to_contact': return { label: '待联系', tone: TONE.warn }
    case 'talking': return { label: '沟通中', tone: TONE.info }
    case 'talking:quoted': return { label: '已报价', tone: TONE.info }
    case 'signed': return { label: '已签约', tone: TONE.success }
    case 'signed:awaiting_setup': return { label: '已签约·待建账材料', tone: TONE.warn }
    case 'serving': return { label: '服务中', tone: TONE.success }
    default: return { label: item.stage || item.status, tone: TONE.gray }
  }
}

const STAGE_FILTERS = [
  { value: '', label: '全部阶段' },
  { value: 'pending_reg', label: '待注册' },
  { value: 'to_contact', label: '待联系' },
  { value: 'talking', label: '沟通中/已报价' },
  { value: 'signed', label: '已签约' },
  { value: 'serving', label: '服务中' },
]

const STATUS_FILTERS = [
  { value: 'all', label: '全部状态' },
  { value: 'active', label: '进行中' },
  { value: 'completed', label: '已关闭·期满' },
  { value: 'cancelled', label: '已关闭·流失' },
]

// 阶段 → 可用操作（契约 §4b）；pending_reg 只能备注不能推进。
// 收款线上化（2026-07-24）：认领联系 / 登记收款动作下线——录最终价即认领
//（操作人落审计），收款由用户在知办 App 内微信支付、Bus 回调自动推进签约。
type ActionKind = 'quote_final' | 'month_reported'
  | 'request_setup_materials' | 'setup_confirmed' | 'close' | 'note_added'

const ACTION_LABELS: Record<ActionKind, string> = {
  quote_final: '录最终月费',
  month_reported: '登记异常月报',
  request_setup_materials: '请求建账材料',
  setup_confirmed: '建账完成',
  close: '关闭工单',
  note_added: '内部备注',
}

// 当前阶段的主线下一步（2026-07-22 向导化）：详情引导条 + 唯一 primary 按钮，
// 其余操作收进「更多操作」。月报口径（2026-07-22）：未登记月份视为正常申报。
function nextStepInfo(item: {
  status: string
  stage: string
  termination_pending?: boolean
}): { title: string; desc: string; action?: ActionKind } | null {
  if (item.status !== 'active') return null
  if (item.termination_pending)
    return { title: '下一步：处理终止申请', desc: '用户已申请终止服务，核对账期、退款与资料交接后关闭工单。', action: 'close' }
  switch (item.stage) {
    case 'pending_reg':
      return { title: '等待注册办结', desc: '顺带代账单在注册办结后自动激活为待联系，暂无需操作。' }
    case 'to_contact':
      return { title: '下一步：录最终月费', desc: '录价即认领：与用户确认记账方案后录入最终月费，系统实时推送月费和 12 个月年付总额并附微信支付入口。', action: 'quote_final' }
    case 'talking':
      return { title: '下一步：录最终月费', desc: '与用户确认记账方案后录入最终月费，系统实时推送月费和 12 个月年付总额并附微信支付入口。', action: 'quote_final' }
    case 'talking:quoted':
      return { title: '等待用户在线支付', desc: '月费和 12 个月年付总额已推送用户，微信支付完成后自动签约并开始收建账材料；改价可重新录最终月费。' }
    case 'signed:awaiting_setup':
      return { title: '等待用户提交建账材料', desc: '用户交卷后资料包自动转交金蝶；长时间未交可在「更多操作」重新请求。' }
    case 'signed':
      return { title: '下一步：确认建账完成', desc: '金蝶核对材料并完成建账后确认，服务正式开始按月记账。', action: 'setup_confirmed' }
    case 'serving':
      return { title: '服务进行中', desc: '未登记的月份默认视为正常申报；仅当某月申报异常或需用户配合时「登记异常月报」，期满或流失时关闭工单。' }
    default:
      return null
  }
}

function actionsFor(item: {
  status: string
  stage: string
  termination_pending?: boolean
}): ActionKind[] {
  if (item.status !== 'active') return []
  switch (item.stage) {
    case 'pending_reg': return ['note_added']
    case 'to_contact': return ['quote_final', 'close', 'note_added']
    case 'talking':
    case 'talking:quoted': return ['quote_final', 'close', 'note_added']
    case 'signed': {
      // 已签约后不可直接流失关单（2026-07-21 收紧）：用户申请终止、顾问完成
      // 结算/退款/交接后才关；期满关单在 serving 阶段操作。
      const base: ActionKind[] = ['setup_confirmed', 'request_setup_materials', 'month_reported', 'note_added']
      return item.termination_pending ? [...base, 'close'] : base
    }
    case 'signed:awaiting_setup': {
      // 待建账材料阶段不露「建账完成」（材料还没交，服务商无从建账）。
      const base: ActionKind[] = ['request_setup_materials', 'month_reported', 'note_added']
      return item.termination_pending ? [...base, 'close'] : base
    }
    case 'serving': return ['month_reported', 'close', 'note_added']
    default: return ['note_added']
  }
}

// 系统报价（查表区间）与最终价分列展示（原型列布局）。
function systemQuoteText(item: { quote_low: number; quote_high: number }): string {
  if (item.quote_high > 0) return `¥${item.quote_low}–${item.quote_high}/月`
  return ''
}

function annualPaymentYuan(monthlyYuan: string): string {
  const value = Number(monthlyYuan)
  if (!Number.isFinite(value) || value <= 0) return ''
  const annualCents = Math.round(value * 100) * 12
  return (annualCents / 100).toFixed(2)
}

// 来源徽标（原型：API/注册顺带=蓝、直接咨询=灰）。
function sourceInfo(source: string): { label: string; tone: string } | null {
  if (!source) return null
  return source === '注册顺带'
    ? { label: source, tone: TONE.info }
    : { label: source, tone: TONE.gray }
}

function fmtTime(iso: string): string {
  return iso ? iso.slice(0, 16).replace('T', ' ') : '—'
}

function relatedRegistrationStatus(status: string, stage: string): string {
  if (status === 'completed') return '已完成'
  if (status === 'cancelled') return '已取消'
  if (status === 'failed') return stage === 'rejected' ? '已驳回' : '异常终止'
  switch (stage.split(':', 1)[0]) {
    case 'draft': return '草稿'
    case 'submitted': return '已受理'
    case 'naming': return '核名中'
    case 'filed': return '已报送'
    case 'licensed': return '已出照'
    case 'done': return '已完成'
    default: return stage || status
  }
}

// 时间线节点语义（契约 §4b）：报价/收款/激活/关闭会推送用户；
// 认领联系、月度回传是顾问操作不打扰用户；备注只留档。
function timelineKind(ev: StartupAgentCaseEvent): CaseTimelineKind {
  switch (ev.event_type) {
    case 'quote_final':
    case 'payment_recorded':
    case 'refund_completed':
    case 'activated':
    case 'close':
      return 'push'
    case 'note_added':
      return 'note'
    case 'contacted':
    case 'month_reported':
    case 'setup_package_sent':
    case 'setup_package_failed':
    case 'lead_mail_failed':
      return 'op'
    case 'request_setup_materials':
    case 'setup_confirmed':
      return 'push'
    case 'termination_requested':
    case 'setup_materials_submitted':
      return 'user'
    default:
      return 'user' // submit / eval 等用户会话动作
  }
}

function timelineSummary(ev: StartupAgentCaseEvent): string {
  const p = ev.payload || {}
  switch (ev.event_type) {
    case 'created_from_registration':
      return `系统创建顺带代账工单 · 关联 ${String(p.registration_business_no || '注册申请')}`
    case 'quote_final': return p.amount ? `¥${p.amount}/月` : ''
    case 'payment_recorded': return p.amount ? `${p.channel === 'wechat' ? '微信支付 · ' : ''}金额 ¥${p.amount}` : ''
    case 'refund_completed': return p.amount ? `¥${p.amount} 已原路退回` : ''
    case 'month_reported': return `${p.month ?? ''}${p.ok === false ? ` 异常${typeof p.note === 'string' && p.note ? ' · ' + p.note : ''}` : ' 已申报'}`
    case 'close': return `${p.outcome === 'completed' ? '服务期满' : '流失'}${p.reason ? ` · ${p.reason}` : ''}`
    case 'note_added': return typeof p.text === 'string' ? p.text : ''
    case 'bank_account_submitted': return [p.bank_name, p.bank_account].filter(Boolean).join(' · ')
    case 'lead_mail_failed': return [p.kind, p.reason].filter(Boolean).join(' · ')
    default: return ''
  }
}

const TIMELINE_LABELS: Record<string, string> = {
  created_from_registration: '用户提交注册申请',
  submit: '提交评估',
  activated: '注册办结·工单激活',
  contacted: '认领联系',
  quote_final: '录最终价',
  payment_recorded: '收款·签约',
  refund_completed: '退款已原路退回',
  month_reported: '月报登记',
  termination_requested: '用户提交终止服务申请',
  request_setup_materials: '请求建账材料',
  setup_confirmed: '建账完成·服务开始',
  setup_materials_submitted: '用户提交建账材料',
  setup_package_sent: '建账资料包已转交服务商',
  setup_package_failed: '建账资料包转交失败',
  lead_mail_failed: '同步邮件发送失败',
  bank_account_submitted: '登记开户信息',
  close: '关闭工单',
  note_added: '内部备注',
}

// ---- 页面 ----

export function BookkeepingTicketsPage() {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const detailCaseID = searchParams.get('case_id') || ''
  const detailTenantUUID = searchParams.get('tenant_uuid') || ''
  const [items, setItems] = useState<StartupAgentCaseItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [stage, setStage] = useState('')
  const [status, setStatus] = useState('all')
  const [q, setQ] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [stats, setStats] = useState<StartupAgentStats | null>(null)
  const [detail, setDetail] = useState<StartupAgentCaseDetail | null>(null)
  const visibleDetail = detail?.id === detailCaseID && detail.tenant_uuid === detailTenantUUID
    ? detail
    : null
  const [action, setAction] = useState<{ kind: ActionKind; item: StartupAgentCaseItem } | null>(null)

  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    StartupAgentCases.list({
      kind: 'bookkeeping', stage: stage || undefined, status,
      q: q.trim() || undefined, page, page_size: pageSize,
    }).then((res) => {
      if (cancelled) return
      setItems(res.items ?? [])
      setTotal(res.total ?? 0)
      setError('')
    }).catch((e: Error) => {
      if (!cancelled) setError(e.message)
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })
    return () => { cancelled = true }
  }, [stage, status, q, page, pageSize, tick])

  // 统计卡与筛选无关，只随刷新重取；失败静默降级不挡列表。
  useEffect(() => {
    let cancelled = false
    StartupAgentCases.stats('bookkeeping')
      .then((s) => { if (!cancelled) setStats(s) })
      .catch(() => { if (!cancelled) setStats(null) })
    return () => { cancelled = true }
  }, [tick])

  useEffect(() => {
    if (!detailCaseID || !detailTenantUUID) return
    let cancelled = false
    StartupAgentCases.get(detailCaseID, detailTenantUUID)
      .then((value) => {
        if (!cancelled) {
          setDetail(value)
          setError('')
        }
      })
      .catch((e: Error) => {
        if (!cancelled) {
          setDetail(null)
          setError(`代账工单详情加载失败：${e.message}`)
        }
      })
    return () => { cancelled = true }
  }, [detailCaseID, detailTenantUUID])

  const refresh = useCallback(() => {
    setLoading(true)
    setTick((v) => v + 1)
  }, [])
  const resetPage = (fn: () => void) => {
    setLoading(true)
    setPage(1)
    fn()
  }

  const openDetail = useCallback((item: StartupAgentCaseItem) => {
    const next = new URLSearchParams(searchParams)
    next.set('case_id', item.id)
    next.set('tenant_uuid', item.tenant_uuid)
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  const closeDetail = useCallback(() => {
    setDetail(null)
    const next = new URLSearchParams(searchParams)
    next.delete('case_id')
    next.delete('tenant_uuid')
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  const afterEvent = useCallback(() => {
    setAction(null)
    closeDetail()
    refresh()
  }, [closeDetail, refresh])

  return (
    <div>
      <PageHeader
        title="代理记账工单"
        subtitle="跟进代账线索的评估、报价、签约与服务回传。来源「注册顺带」的工单在注册办结后自动激活；报价/收款操作会实时推送给用户。"
        actions={<Button variant="secondary" onClick={refresh}><RefreshCw size={14} /> 刷新</Button>}
      />
      {stats && (
        <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="本月新增" value={stats.new_this_month} />
          <KpiCard label="本月关闭" value={stats.done_this_month} />
          <KpiCard label="服务中" value={stats.serving} tone="success" />
          <KpiCard label="平均结案天数" value={stats.avg_done_days} />
        </div>
      )}
      <Toolbar
        search={<SearchInput value={q} onChange={(v) => resetPage(() => setQ(v))} placeholder="搜索工单号 / 关联注册单号（EA） / 申请人" />}
        filters={
          <>
            <div className="w-[160px]">
              <Select value={stage} onChange={(e) => resetPage(() => setStage(e.target.value))}>
                {STAGE_FILTERS.map((f) => <option key={f.value} value={f.value}>{f.label}</option>)}
              </Select>
            </div>
            <div className="w-[160px]">
              <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
                {STATUS_FILTERS.map((f) => <option key={f.value} value={f.value}>{f.label}</option>)}
              </Select>
            </div>
          </>
        }
        summary={<>共 {total} 条</>}
      />
      {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['工单号', '租户', '来源', '办理企业', '关联注册单', '纳税人类型', '参保人数', '票量档', '系统报价', '最终月费', '收款', '状态', '创建时间', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载工单</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState title="暂无代账工单" description="用户在创业助手里完成代账评估后，工单会出现在这里；注册顺带的工单随注册单同步建立。" />
        ) : undefined}
      >
        {items.map((item) => {
          const st = stageInfo(item)
          const src = sourceInfo(item.source)
          return (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[168px] min-w-[168px] max-w-[168px] px-4 py-3 ${stickyLeftTdCls}`}>
                <div className="truncate font-medium text-[var(--color-brand)]">{item.business_no || item.id.slice(0, 8)}</div>
              </td>
              <td className="min-w-[160px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.tenant_name}>
                <div className="max-w-[200px] truncate">{item.tenant_name}</div>
              </td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3">
                {src ? <Badge className={src.tone}>{src.label}</Badge> : <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[160px] whitespace-nowrap px-4 py-3" title={item.company_name || undefined}>
                {item.company_name
                  ? <div className="max-w-[200px] truncate text-[var(--color-text)]">{item.company_name}</div>
                  : item.company_profile_id
                    ? <span className="text-[var(--color-text-mute)]">待补全企业</span>
                    : <span className="text-[var(--color-text-mute)]">未关联企业</span>}
              </td>
              <td className="min-w-[152px] whitespace-nowrap px-4 py-3">
                {item.related_case_id ? (
                  <button
                    type="button"
                    className="font-medium text-[var(--color-brand)] hover:underline"
                    onClick={() => navigate(`/startup-agent-cases?case_id=${encodeURIComponent(item.related_case_id)}&tenant_uuid=${encodeURIComponent(item.tenant_uuid)}`)}
                  >
                    {item.related_business_no || '查看注册申请'}
                  </button>
                ) : item.source === '注册顺带' ? (
                  <span className="text-[12px] text-[var(--color-danger)]">历史关联缺失</span>
                ) : <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[104px] whitespace-nowrap px-4 py-3 text-[var(--color-text)]">
                {item.taxpayer_type || <span className="text-[var(--color-text-mute)]">待确认</span>}
              </td>
              <td className="min-w-[80px] whitespace-nowrap px-4 py-3 text-[var(--color-text)]">
                {item.insured_count || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3 text-[var(--color-text)]">
                {item.receipts_band || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[112px] whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text)]">
                {systemQuoteText(item) || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3 tabular-nums">
                {item.final_price > 0
                  ? <span className="font-medium text-[var(--color-text)]">¥{item.final_price}/月</span>
                  : <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[104px] whitespace-nowrap px-4 py-3">
                {item.fee_amount > 0
                  ? <Badge className={TONE.success}>实际已收 ¥{item.fee_amount}</Badge>
                  : item.stage === 'talking:quoted'
                    ? <Badge className={TONE.warn}>待用户支付</Badge>
                    : <Badge className={TONE.warn}>未收款</Badge>}
              </td>
              <td className="min-w-[128px] whitespace-nowrap px-4 py-3">
                <div className="flex flex-wrap items-center gap-1">
                  <Badge className={st.tone}>{st.label}</Badge>
                  {item.status === 'active' && item.termination_pending && (
                    <Badge className={TONE.warn}>终止申请待处理</Badge>
                  )}
                  {item.refund_pending && (
                    <Badge className={TONE.danger}>待退款</Badge>
                  )}
                  {item.renewal_due && (
                    <Badge className={TONE.warn}>续费将至</Badge>
                  )}
                </div>
              </td>
              <td className="min-w-[148px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{fmtTime(item.created_at)}</td>
              <td className={`min-w-[104px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => openDetail(item)}
                  title="查看详情"
                  aria-label={`查看代账工单 ${item.business_no}`}
                >
                  <Eye size={14} />
                  详情
                </Button>
              </td>
            </tr>
          )
        })}
      </DataTable>
      <Pagination total={total} page={page} pageSize={pageSize}
                  onPageChange={setPage} onPageSizeChange={(s) => { setPageSize(s); setPage(1) }} />
      {visibleDetail && (
        <TicketDrawer
          detail={visibleDetail}
          onClose={closeDetail}
          onOpenRelated={() => navigate(`/startup-agent-cases?case_id=${encodeURIComponent(visibleDetail.related_case_id)}&tenant_uuid=${encodeURIComponent(visibleDetail.tenant_uuid)}`)}
          onAction={(kind) => setAction({ kind, item: visibleDetail })}
          onRefunded={afterEvent}
        />
      )}
      {action && (
        <EventDialog kind={action.kind} item={action.item} onClose={() => setAction(null)} onDone={afterEvent} />
      )}
    </div>
  )
}

// ---- 详情抽屉（排版对齐设计原型：评估问卷两列 + 系统报价大字条 +
//      签约信息 + 账期行式列表 + 图标节点时间线；视觉走系统 token）----

const text = (v: unknown): string =>
  v === undefined || v === null || v === '' ? '' : String(v)

function TicketDrawer({ detail, onClose, onAction, onOpenRelated, onRefunded }: {
  detail: StartupAgentCaseDetail
  onClose: () => void
  onAction: (kind: ActionKind) => void
  onOpenRelated: () => void
  onRefunded: () => void
}) {
  const [refunding, setRefunding] = useState(false)
  const st = stageInfo(detail)
  const evalData = (detail.data?.eval ?? {}) as Record<string, unknown>
  const periods = (detail.data?.periods ?? []) as { month: string; ok: boolean }[]
  const actions = actionsFor(detail)
  // 向导化（2026-07-22）：主线下一步独占 primary，其余收进「更多操作」
  const next = nextStepInfo(detail)
  const mainAction = next?.action && actions.includes(next.action) ? next.action : undefined
  const menuActions = actions.filter((k) => k !== mainAction)
  const hasEval = ['taxpayer_type', 'headcount', 'insured_count', 'monthly_invoice',
    'monthly_receipts', 'bk_industry', 'messy_books', 'start_month']
    .some((k) => text(evalData[k]))
  const signed = detail.stage.startsWith('signed') || detail.stage === 'serving' || detail.status === 'completed'
  const setupSubmitted = Boolean(detail.data?.setup_submitted)
  const setupHistory = String(detail.data?.setup_ledger_history ?? '')
  const setupFileCount = (['setup_tax_registration', 'setup_journal_ledger'] as const)
    .reduce((n, k) => n + (Array.isArray(detail.data?.[k]) ? (detail.data[k] as unknown[]).length : 0), 0)
  const downloadSetupPackage = async () => {
    try {
      const { blob, filename } = await StartupAgentCases.downloadPackage(detail.id, detail.tenant_uuid)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      notifyOk('资料包下载失败，请稍后重试')
    }
  }
  return (
    <DrawerShell
      title={detail.business_no || detail.id.slice(0, 8)}
      subtitle={`租户 ${detail.tenant_name} · 创建于 ${fmtTime(detail.created_at)}`}
      icon={<NotebookPen size={16} />}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex items-center justify-between gap-2">
          <div className="flex flex-wrap items-center gap-2">
            {mainAction && (
              <Button variant={mainAction === 'close' ? 'danger' : 'primary'} size="sm" onClick={() => onAction(mainAction)}>
                {ACTION_LABELS[mainAction]}
              </Button>
            )}
            <ActionMenu
              items={menuActions.map((kind) => ({
                key: kind,
                label: ACTION_LABELS[kind],
                danger: kind === 'close',
                onSelect: () => onAction(kind),
              }))}
            />
            {actions.length === 0 && (
              <span className="text-[12px] text-[var(--color-text-mute)]">当前状态无可执行操作</span>
            )}
          </div>
          <Button variant="secondary" onClick={onClose}>关闭</Button>
        </div>
      }
    >
      <div className="space-y-4">
        <div className="flex items-center gap-2">
          <Badge className={st.tone}>{st.label}</Badge>
          {detail.status === 'active' && detail.termination_pending && (
            <Badge className={TONE.warn}>终止申请待处理</Badge>
          )}
          {sourceInfo(detail.source) && (
            <Badge className={sourceInfo(detail.source)!.tone}>{sourceInfo(detail.source)!.label}</Badge>
          )}
          {detail.fee_amount > 0
            ? <Badge className={TONE.success}>实际已收 ¥{detail.fee_amount}</Badge>
            : <Badge className={TONE.warn}>未收款</Badge>}
          {detail.refund_pending && (
            <Badge className={TONE.danger}>待退款</Badge>
          )}
          {(detail.refund_pending
            || (detail.fee_amount > 0 && detail.status === 'active' && detail.termination_pending)) && (
            <Button size="sm" variant="danger" onClick={() => setRefunding(true)}>发起退款</Button>
          )}
        </div>

        {next && (
          <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-info-bg)] px-3 py-2 text-[13px] leading-6">
            <span className="font-medium text-[var(--color-text)]">{next.title}</span>
            <span className="ml-2 text-[var(--color-text-sub)]">{next.desc}</span>
          </div>
        )}

        {detail.status === 'active' && detail.termination_pending && (
          <InlineAlert tone="warn">
            用户已提交终止代理记账服务申请，请顾问核对账期、退款和资料交接后关闭工单。
          </InlineAlert>
        )}

        <RelatedCaseCard
          heading="关联注册申请"
          businessNo={detail.related_business_no}
          title={detail.related_title}
          statusLabel={relatedRegistrationStatus(detail.related_status, detail.related_stage)}
          onOpen={detail.related_case_id ? onOpenRelated : undefined}
          missing={detail.source === '注册顺带' && !detail.related_case_id}
        />

        {detail.stage === 'pending_reg' && (
          <InlineAlert tone="info">
            注册顺带工单：关联注册申请尚未办结，工单挂起中，注册完成后自动激活并通知用户。
          </InlineAlert>
        )}

        <FormSection title="办理企业" description="工单显式关联的企业档案；历史工单可能未关联，不按账号推测。">
          <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
            <Field label="企业名称"
                   value={detail.company_name
                     || (detail.company_profile_id ? '待补全企业' : '未关联企业')} />
            <Field label="对公账户"
                   value={[text(detail.data?.bank_name), text(detail.data?.bank_account)]
                     .filter(Boolean).join(' · ')} />
          </div>
        </FormSection>

        <FormSection title="评估问卷" description="来自用户在创业助手中的代账评估表单。">
          {hasEval ? (
            <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
              <Field label="纳税人类型" value={text(evalData.taxpayer_type)} />
              <Field label="公司人数" value={text(evalData.headcount)} />
              <Field label="需缴社保人数" value={text(evalData.insured_count)} />
              <Field label="月开票金额" value={text(evalData.monthly_invoice)} />
              <Field label="月票据张数" value={text(evalData.monthly_receipts)} />
              <Field label="所属行业" value={text(evalData.bk_industry)} />
              <Field label="历史乱账" value={text(evalData.messy_books)} />
              <Field label="期望开始月份" value={text(evalData.start_month)} />
            </div>
          ) : (
            <div className="text-[13px] text-[var(--color-text-mute)]">用户未填写评估信息，需顾问电话确认。</div>
          )}
        </FormSection>

        {/* 系统报价大字条（原型）：查表区间为主；已录最终价时最终价为主、区间降为依据 */}
        {(detail.quote_high > 0 || detail.final_price > 0) && (
          <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded-md border border-[var(--color-info-bg)] bg-[var(--color-info-bg)]/50 px-4 py-3">
            <span className="text-[13px] text-[var(--color-text-sub)]">
              {detail.final_price > 0 ? '最终月费' : '系统报价'}
            </span>
            <span className="text-[20px] font-semibold tabular-nums text-[var(--color-info)]">
              {detail.final_price > 0 ? `¥${detail.final_price}` : `¥${detail.quote_low}–${detail.quote_high}`}
            </span>
            <span className="text-[13px] text-[var(--color-text-sub)]">/ 月</span>
            {detail.final_price > 0 && detail.quote_high > 0 && (
              <span className="text-[12px] text-[var(--color-text-mute)]">
                系统报价区间 ¥{detail.quote_low}–{detail.quote_high} / 月
              </span>
            )}
            {detail.final_price === 0 && (
              <span className="text-[12px] text-[var(--color-text-mute)]">依据代账定价矩阵自动查表</span>
            )}
          </div>
        )}

        {signed && (
          <FormSection title="签约信息">
            <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
              <Field label="最终月费" value={detail.final_price > 0 ? `¥${detail.final_price} / 月` : ''} />
              <Field label="实际已收服务费" value={detail.fee_amount > 0 ? `¥${detail.fee_amount}` : ''} />
              <Field label="来源" value={detail.source} />
              <Field label="期望开始月份" value={text(evalData.start_month)} />
            </div>
          </FormSection>
        )}

        {signed && detail.source !== '注册顺带' && (
          <FormSection
            title="建账材料（税种认定 + 序时账）"
            description="服务商建账前置材料；用户在会话内上传，提交后自动邮件转交。"
            actions={setupSubmitted ? (
              <Button variant="secondary" size="sm" onClick={() => void downloadSetupPackage()}>
                下载建账资料包
              </Button>
            ) : undefined}
          >
            <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
              <Field
                label="材料状态"
                value={setupSubmitted
                  ? `已提交（附件 ${setupFileCount} 份）`
                  : detail.stage === 'signed:awaiting_setup' ? '待用户提交' : '未请求'}
              />
              <Field label="历史账情况" value={setupHistory} />
              {text(detail.data?.setup_validation_note) && (
                <Field label="校验备注" value={text(detail.data?.setup_validation_note)} />
              )}
            </div>
          </FormSection>
        )}

        {(signed || periods.length > 0) && (
          <FormSection
            title="异常账期"
            description="未登记的月份默认视为正常申报；仅申报异常或需用户配合的月份在此登记，用户查进度可见。"
            actions={actions.includes('month_reported') ? (
              <Button variant="secondary" size="sm" onClick={() => onAction('month_reported')}>
                登记异常月报
              </Button>
            ) : undefined}
          >
            {detail.renewal_due && (
              <InlineAlert tone="warn">
                已服务约 {detail.months_served} 个月，服务将满一年——建议联系用户确认续费或期满关单。
              </InlineAlert>
            )}
            {periods.length === 0 ? (
              <div className="text-[13px] text-[var(--color-text-mute)]">暂无异常记录（未登记月份视为正常申报）。</div>
            ) : (
              <div className="space-y-2">
                {periods.map((p) => (
                  <div
                    key={p.month}
                    className="flex items-center justify-between rounded-md border border-[var(--color-line-soft)] px-3 py-2"
                  >
                    <span className="text-[13px] text-[var(--color-text)]">{p.month} 账期</span>
                    <Badge className={p.ok ? TONE.success : TONE.warn}>{p.ok ? '已申报' : '异常待处理'}</Badge>
                  </div>
                ))}
              </div>
            )}
          </FormSection>
        )}

        <FormSection title="办理时间线" description="用户动作与顾问录入的进度事件，均带操作人审计。">
          {detail.events.length === 0 ? (
            <div className="text-[13px] text-[var(--color-text-mute)]">暂无操作记录。</div>
          ) : (
            <div>
              {detail.events.map((ev, i, arr) => (
                <CaseTimelineItem
                  key={`${ev.received_at}-${i}`}
                  kind={timelineKind(ev)}
                  label={TIMELINE_LABELS[ev.event_type] ?? ev.event_type}
                  summary={timelineSummary(ev)}
                  time={fmtTime(ev.received_at)}
                  operator={typeof ev.payload?.operator === 'string' ? ev.payload.operator : ''}
                  last={i === arr.length - 1}
                />
              ))}
            </div>
          )}
        </FormSection>
      </div>
      {refunding && (
        <CaseRefundDialog
          caseId={detail.id}
          tenantUuid={detail.tenant_uuid}
          maxYuan={detail.fee_amount || 0}
          onClose={() => setRefunding(false)}
          onDone={() => { setRefunding(false); onRefunded() }}
        />
      )}
    </DrawerShell>
  )
}

// ---- 录事件弹窗 ----

function EventDialog({ kind, item, onClose, onDone }: {
  kind: ActionKind
  item: StartupAgentCaseItem
  onClose: () => void
  onDone: () => void
}) {
  // 幂等键：弹窗打开时生成一次，提交重试复用（契约 §2.3）。
  const eventKey = useMemo(() => randomUUID(), [])
  const [amount, setAmount] = useState('')
  const [month, setMonth] = useState('')
  const [outcome, setOutcome] = useState<'completed' | 'cancelled'>('cancelled')
  const [reason, setReason] = useState('')
  const [text, setText] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const annualPayment = annualPaymentYuan(amount)

  const submit = async () => {
    const payload: Record<string, unknown> = {}
    if (kind === 'quote_final') {
      const v = Number(amount)
      if (!Number.isFinite(v) || v <= 0) { setError('请输入正确的金额'); return }
      payload.amount = v
    }
    if (kind === 'month_reported') {
      if (!/^\d{4}-\d{2}$/.test(month)) { setError('月份格式 YYYY-MM'); return }
      payload.month = month
      payload.ok = false  // 月报口径（2026-07-22）：只登记异常，未登记月份视为正常
      if (text.trim()) payload.note = text.trim()
    }
    if (kind === 'close') {
      if (!reason.trim()) { setError('关闭原因必填'); return }
      payload.outcome = outcome
      payload.reason = reason.trim()
    }
    if (kind === 'note_added') {
      if (!text.trim()) { setError('备注内容必填'); return }
      payload.text = text.trim()
    }
    setSubmitting(true)
    setError('')
    try {
      const res = await StartupAgentCases.ingestEvent(item.id, {
        tenant_uuid: item.tenant_uuid, type: kind, event_key: eventKey, payload,
      })
      notifyOk(res.reason === 'duplicate_event' ? '该操作已处理过' : '已提交')
      onDone()
    } catch (e) {
      setError(e instanceof Error ? e.message : '提交失败')
      setSubmitting(false)
    }
  }

  return (
    <DialogShell
      title={ACTION_LABELS[kind]}
      subtitle={`工单 ${item.business_no || item.id.slice(0, 8)} · ${item.tenant_name}`}
      onClose={onClose}
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant={kind === 'close' ? 'danger' : 'primary'} disabled={submitting} onClick={() => void submit()}>
            {submitting ? '提交中…' : '确认提交'}
          </Button>
        </div>
      }
    >
      <div className="space-y-3">
        {kind === 'request_setup_materials' && (
          <p className="text-[13px] text-[var(--color-text-sub)]">
            向用户推送建账材料请求（税种认定信息 + 序时账），工单进入「待建账材料」；用户回到会话即可上传。已在待建账材料阶段时用于重发提醒。
          </p>
        )}
        {kind === 'setup_confirmed' && (
          <p className="text-[13px] text-[var(--color-text-sub)]">
            确认服务商已完成建账，工单进入「服务中」，并推送用户「账套已建好，服务正式开始」。
          </p>
        )}
        {kind === 'quote_final' && (
          <>
            <FormField label="与用户确认的月费（元/月）"
                       hint={item.quote_high > 0
                         ? `系统报价区间 ¥${item.quote_low}–${item.quote_high} / 月；录价即认领，确认后实时推送用户并附微信支付入口`
                         : '录价即认领，确认后实时推送用户并附微信支付入口'}>
              <Input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="如 260" inputMode="decimal" />
            </FormField>
            {annualPayment && (
              <InlineAlert tone="info">
                用户将按年一次性支付 ¥{annualPayment}（12个月）。实际订单金额由服务端计算。
              </InlineAlert>
            )}
          </>
        )}
        {kind === 'month_reported' && (
          <>
            <FormField label="异常月份" hint="未登记的月份默认视为正常申报，仅异常月需要登记">
              <Input value={month} onChange={(e) => setMonth(e.target.value)} placeholder="2026-07" />
            </FormField>
            <FormField label="异常说明（选填）" hint="如：缺进项发票待用户补充；会随时间线展示">
              <Input value={text} onChange={(e) => setText(e.target.value)} placeholder="缺 6 月银行回单，待用户补充" />
            </FormField>
          </>
        )}
        {kind === 'close' && (
          <>
            <FormField label="关闭类型" as="div">
              <Select value={outcome} onChange={(e) => setOutcome(e.target.value as 'completed' | 'cancelled')}>
                <option value="cancelled">流失关闭（用户不再需要）</option>
                <option value="completed">服务期满正常关闭</option>
              </Select>
            </FormField>
            <FormField label="关闭原因（必填）">
              <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="如：用户已自行聘请会计" />
            </FormField>
          </>
        )}
        {kind === 'note_added' && (
          <FormField label="备注内容（仅内部时间线可见，不推送用户）">
            <Input value={text} onChange={(e) => setText(e.target.value)} placeholder="如：用户希望 8 月再启动" />
          </FormField>
        )}
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
      </div>
    </DialogShell>
  )
}
