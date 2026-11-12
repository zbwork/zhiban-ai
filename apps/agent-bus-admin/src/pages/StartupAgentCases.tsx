// 企业注册申请（F24 创业助手运营台, contracts/admin-startup-agent-api.md）。
// 列表 + 详情抽屉 + 按阶段录事件弹窗；数据经 admin Go 代理自 baigong /internal/ops/*。
// event_key 在弹窗打开时生成一次，重试/双击复用（幂等；duplicate_event = 已处理过，非错误）。
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { AlertTriangle, Eye, EyeOff, ImageIcon, RefreshCw, Zap } from 'lucide-react'
import { useNavigate, useSearchParams } from 'react-router-dom'

import {
  Auth,
  StartupAgentCases,
  WebCases as WebCasesApi,
  type StartupAgentCaseDetail,
  type StartupAgentCaseEvent,
  type StartupAgentCaseItem,
  type StartupAgentCasePII,
  type StartupAgentStats,
  type WebCasePayment,
} from '../lib/api'
import { SetPaymentDialog, WebCasesSection } from '../components/webServiceCases'
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
  ConfirmDialog,
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
  SegmentedControl,
  Select,
  Tabs,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'

// ---- stage → 展示映射（契约 §4） ----

type StageInfo = { label: string; tone: string }

function stageInfo(item: { status: string; stage: string }): StageInfo {
  if (item.status === 'cancelled') return { label: '已取消', tone: TONE.gray }
  if (item.status === 'failed') {
    return item.stage === 'rejected'
      ? { label: '已驳回', tone: TONE.danger }
      : { label: '异常终止', tone: TONE.danger }
  }
  const [main, sub] = item.stage.split(':', 2)
  switch (main) {
    case 'draft': return { label: '草稿（收集中）', tone: TONE.gray }
    case 'submitted':
      if (sub === 'awaiting_materials') return { label: '已受理·待补材料', tone: TONE.warn }
      return { label: '已受理·待收款', tone: TONE.warn }
    case 'naming':
      if (sub === 'awaiting_new_names') return { label: '核名驳回·待补字号', tone: TONE.danger }
      if (sub === 'awaiting_materials') return { label: '核名中·待补材料', tone: TONE.warn }
      return { label: '核名中', tone: TONE.info }
    case 'filed':
      if (sub === 'awaiting_materials') return { label: '已报送·待补材料', tone: TONE.warn }
      return { label: '已报送工商', tone: TONE.info }
    case 'licensed':
      if (sub === 'awaiting_shipping') return { label: '已出照·待收件信息', tone: TONE.warn }
      return { label: '已出照', tone: TONE.success }
    case 'done': return { label: '已完成', tone: TONE.success }
    default: return { label: item.stage || item.status, tone: TONE.gray }
  }
}

// 收款列从 stage 推断：payment_recorded（微信支付回调，2026-07-24 收款线上化）
// 是唯一 submitted→naming 迁移（契约 §4）。
function paymentInfo(item: { status: string; stage: string; final_price?: number; refund_pending?: boolean }): StageInfo | null {
  if (item.refund_pending) return { label: '待退款', tone: TONE.danger }
  if (item.status === 'cancelled' || item.status === 'failed') return null
  const main = item.stage.split(':', 1)[0]
  if (main === 'draft') return null
  if (main === 'submitted') {
    return (item.final_price ?? 0) > 0
      ? { label: '待用户支付', tone: TONE.warn }
      : { label: '未收款', tone: TONE.warn }
  }
  return { label: '已收款', tone: TONE.success }
}

const STAGE_FILTERS = [
  { value: '', label: '全部阶段' },
  { value: 'draft', label: '草稿' },
  { value: 'submitted', label: '已受理' },
  { value: 'naming', label: '核名中' },
  { value: 'filed', label: '已报送' },
  { value: 'licensed', label: '已出照' },
  { value: 'done', label: '已完成' },
]

const STATUS_FILTERS = [
  { value: 'all', label: '全部状态' },
  { value: 'active', label: '进行中' },
  { value: 'completed', label: '已完成' },
  { value: 'cancelled', label: '已取消' },
  { value: 'failed', label: '已驳回' },
]

const PAID_FILTERS = [
  { value: '', label: '全部收款' },
  { value: 'unpaid', label: '未收款' },
  { value: 'paid', label: '已收款' },
]

// 注册城市枚举与用户端第 1 步 schema 一致（F24 §2.2）。
const CITY_FILTERS = ['', '杭州', '上海', '深圳', '北京', '成都']

// 超时口径（契约 §2.1）：进行中且 eta 已过今天。
function isOverdue(item: { status: string; eta: string }): boolean {
  if (item.status !== 'active' || !item.eta) return false
  return item.eta < new Date().toISOString().slice(0, 10)
}

function relatedBookkeepingStatus(status: string, stage: string): string {
  if (status === 'completed') return '已关闭·期满'
  if (status === 'cancelled') return '已关闭·流失'
  if (status === 'failed') return '异常终止'
  switch (stage) {
    case 'pending_reg': return '待注册'
    case 'to_contact': return '待联系'
    case 'talking': return '沟通中'
    case 'talking:quoted': return '已报价'
    case 'signed': return '已签约'
    case 'serving': return '服务中'
    default: return stage || status
  }
}

function bookkeepingCreationMessage(data: Record<string, unknown>): string {
  const raw = data.bookkeeping_creation
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return ''
  const status = String((raw as Record<string, unknown>).status || '')
  if (status === 'pending') return '代理记账工单创建中，系统会按计划自动重试。'
  if (status === 'conflict') return '检测到已有进行中的代理记账服务，需要顾问确认后处理。'
  if (status === 'failed') return '代理记账工单创建失败，已停止自动重试，请人工处理。'
  if (status === 'created') return '关联代账工单未找到，请核对关系数据。'
  return ''
}

// ---- 事件 ----

type ActionKind =
  | 'quote_final' | 'naming_result' | 'materials_requested'
  | 'license_uploaded' | 'expedite_ack' | 'case_closed' | 'case_cancelled'
  | 'case_rejected' | 'note_added' | 'handoff_resend'

const EVENT_LABELS: Record<string, string> = {
  quote_final: '录服务费',
  payment_recorded: '收款·开始办理',
  naming_result: '录入核名结果',
  materials_requested: '请求补材料',
  license_uploaded: '录入执照',
  expedite_ack: '加急回执',
  case_closed: '办结关单',
  case_cancelled: '取消申请',
  case_rejected: '驳回申请',
  note_added: '内部备注',
  handoff_resend: '重发交接资料包',
  // 会话侧/系统事件（时间线展示，不是运营操作）
  submit: '提交申请',
  new_names: '补充新字号',
  materials_submitted: '补交材料',
  expedite_requested: '用户催办',
  cancel: '用户取消',
  shipping_info: '提交收件信息',
  handoff_sent: '交接资料包已发送',
  handoff_failed: '交接发送失败',
  refund_completed: '退款已原路退回',
}

// 当前阶段的主线下一步（2026-07-22 向导化）：详情引导条 + 唯一 primary 按钮，
// 其余操作收进「更多操作」——操作员照提示点一个按钮即可，降低培训成本。
function nextStepInfo(item: { status: string; stage: string; final_price?: number }):
    { title: string; desc: string; action?: ActionKind } | null {
  if (item.status !== 'active') return null
  const [main, sub] = item.stage.split(':', 2)
  switch (main) {
    case 'draft':
      return { title: '等待用户提交申请', desc: '用户还在会话里填写申请信息，暂无需操作。' }
    case 'submitted':
      if (sub === 'awaiting_materials')
        return { title: '等待用户补材料', desc: '已通知用户重新上传，补交后回到待支付；服务费未录时先录服务费推送支付。' }
      if ((item.final_price ?? 0) > 0)
        return { title: '等待用户在线支付', desc: '服务费已推送用户，微信支付完成后自动开始办理并把交接资料包发送给金蝶；改价可重新录服务费。' }
      return { title: '下一步：录服务费', desc: '录入与用户确认的服务费，系统实时推送用户并附微信支付入口；支付完成自动开始办理。材料有问题（如身份证模糊）可先请求补材料。', action: 'quote_final' }
    case 'naming':
      if (sub === 'awaiting_new_names')
        return { title: '等待用户补新字号', desc: '核名驳回已通知用户补新字号，提交后自动同步金蝶重新核名。' }
      if (sub === 'awaiting_materials')
        return { title: '等待用户补材料', desc: '用户补交后自动同步金蝶；金蝶核名有结果后录入。' }
      return { title: '下一步：录入核名结果', desc: '金蝶核名有结果后在这里录入：通过自动报送工商，驳回自动向用户收新字号。', action: 'naming_result' }
    case 'filed':
      if (sub === 'awaiting_materials')
        return { title: '等待用户补材料', desc: '用户补交后自动同步金蝶；执照下来后录入执照信息。' }
      return { title: '下一步：录入执照信息', desc: '金蝶传回执照后录入信用代码与成立日期，系统自动建企业档案并向用户收快递地址。', action: 'license_uploaded' }
    case 'licensed':
      if (sub === 'awaiting_shipping')
        return { title: '等待用户填收件地址', desc: '用户提交后新版资料包自动发金蝶安排寄送；执照与印章交付完成后办结。', action: 'case_closed' }
      return { title: '下一步：办结关单', desc: '执照与印章交付完成后办结：自动向用户发开户/税务指引，并激活顺带代账单。', action: 'case_closed' }
    default:
      return null
  }
}

// 阶段 → 可用操作（契约 §4）。驳回仅限受理/核名阶段（2026-07-21 收紧：
// 材料已报送工商后"驳回"语义不成立，终止走取消/办结）；naming 起（收款后）
// 可重发交接资料包（拍板 5·2026-07-17）。
function availableActions(item: { status: string; stage: string }): ActionKind[] {
  if (item.status !== 'active') return []
  const [main, sub] = item.stage.split(':', 2)
  const tail: ActionKind[] = ['handoff_resend', 'note_added', 'case_cancelled']
  switch (main) {
    case 'draft': return ['case_cancelled']
    case 'submitted':
      // 提交初审可打回（2026-07-24 补缺口：身份证等材料问题此前只能整单驳回）；
      // 待补材料期间不可重复请求（与核名阶段同口径），收款照常可登记。
      if (sub === 'awaiting_materials') return ['quote_final', 'note_added', 'case_rejected', 'case_cancelled']
      return ['quote_final', 'materials_requested', 'note_added', 'case_rejected', 'case_cancelled']
    case 'naming':
      if (sub === 'awaiting_materials') return ['expedite_ack', ...tail, 'case_rejected']
      if (sub === 'awaiting_new_names') return ['materials_requested', 'expedite_ack', ...tail, 'case_rejected']
      return ['naming_result', 'materials_requested', 'expedite_ack', ...tail, 'case_rejected']
    case 'filed':
      if (sub === 'awaiting_materials') return ['expedite_ack', ...tail]
      return ['license_uploaded', 'materials_requested', 'expedite_ack', ...tail]
    case 'licensed': return ['case_closed', 'handoff_resend', 'note_added']
    default: return []
  }
}

// ---- 申请信息（data.draft 扁平 slot 快照，排版按原型：两列 label/value） ----

// PII 脱敏（契约 §2.2：保留首 4 尾 4；明文经 §2.4 端点按权限拉取）。
function maskPII(v: string) {
  if (v.length <= 8) return v.replace(/./g, '*')
  return `${v.slice(0, 4)}${'*'.repeat(v.length - 8)}${v.slice(-4)}`
}

// 通用取值：数组顿号连接，空值回空串（Field 为空即不渲染该行）。
function text(raw: unknown): string {
  if (raw === undefined || raw === null || raw === '') return ''
  return Array.isArray(raw) ? raw.map((v) => String(v)).join('、') : String(raw)
}

// 候选字号合一行（原型「公司名称（候选字号）」展示方式）。
function brandLine(draft: Record<string, unknown>): string {
  const parts: string[] = []
  if (text(draft.brand_1)) parts.push(`${text(draft.brand_1)}（首选）`)
  if (text(draft.brand_2)) parts.push(`${text(draft.brand_2)}（备选）`)
  if (text(draft.brand_3)) parts.push(`${text(draft.brand_3)}（备选）`)
  if (text(draft.brand_4)) parts.push(`${text(draft.brand_4)}（备选）`)
  return parts.join('、')
}

// 四期材料并集的分组展示：任职人员三角色 / 股东两席（有值才渲染该组）。
const OFFICER_ROLES: Array<[string, string]> = [
  ['director', '执行董事'],
  ['manager', '经理'],
  ['finance', '财务负责人'],
]
const SHAREHOLDER_SEATS: Array<[string, string]> = [
  ['sh2', '股东二'],
  ['sh3', '股东三'],
]
// 已挪进人员卡的证件材料键（底部「其他材料」只展示这之外的，如场地证明）。
const CLAIMED_FILE_KEYS = new Set<string>([
  'id_front', 'id_back', 'sup_id_front', 'sup_id_back',
  ...OFFICER_ROLES.flatMap(([p]) => [`${p}_id_front`, `${p}_id_back`]),
  ...SHAREHOLDER_SEATS.flatMap(([p]) =>
    [`${p}_id_front`, `${p}_id_back`, `${p}_license`, `${p}_license_sealed`]),
])

// 申请材料（file slot → 缩略卡；文件体预览随企业档案波次的文件通道再接）。
const MATERIAL_FIELDS: Array<{ key: string; label: string }> = [
  { key: 'id_front', label: '身份证 · 人像面' },
  { key: 'id_back', label: '身份证 · 国徽面' },
  { key: 'sup_id_front', label: '监事身份证 · 人像面' },
  { key: 'sup_id_back', label: '监事身份证 · 国徽面' },
  { key: 'address_proof', label: '场地证明' },
]

// Web 自助注册单（四期）的材料是动态并集（任职人员/股东追加步按需出现），
// 按「角色前缀 + 证件后缀」从 draft 推导标签；值为 baigong 本地 file_id 字符串。
const WEB_FILE_SUFFIXES: Array<[string, string]> = [
  ['id_front', '身份证 · 人像面'],
  ['id_back', '身份证 · 国徽面'],
  ['license_sealed', '执照复印件盖章照片'],
  ['license', '营业执照副本'],
  ['address_proof', '场地证明'],
]
const WEB_ROLE_PREFIXES: Array<[string, string]> = [
  ['sup_', '监事'],
  ['director_', '执行董事'],
  ['manager_', '经理'],
  ['finance_', '财务负责人'],
  ['sh2_', '股东二 · '],
  ['sh3_', '股东三 · '],
]
function materialFields(source: string, draft: Record<string, unknown>): Array<{ key: string; label: string }> {
  if (source !== 'web') return MATERIAL_FIELDS
  const out: Array<{ key: string; label: string }> = []
  for (const key of Object.keys(draft)) {
    if (!draft[key]) continue
    const suf = WEB_FILE_SUFFIXES.find(([s]) => key === s || key.endsWith('_' + s))
    if (!suf) continue
    if (key === suf[0]) {
      out.push({ key, label: suf[0].startsWith('id_') ? `法人${suf[1]}` : suf[1] })
      continue
    }
    const role = WEB_ROLE_PREFIXES.find(([p]) => key.startsWith(p))
    out.push({ key, label: `${role ? role[1] : ''}${suf[1]}` })
  }
  return out
}

function formatTime(v?: string) {
  if (!v) return '-'
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString('zh-CN', { hour12: false })
}

// ---- 页面 ----

export function StartupAgentCasesPage() {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const detailCaseID = searchParams.get('case_id') || ''
  const detailTenantUUID = searchParams.get('tenant_uuid') || ''
  // 海内外 Tab（2026-08-06 拍板）：内地=company_reg 注册申请；海外=web_service
  // 办理单（用户在 Web 对话里自助发起，按 service_type 过滤）
  const view: 'domestic' | 'overseas' =
    searchParams.get('view') === 'overseas' ? 'overseas' : 'domestic'
  const setView = useCallback((v: 'domestic' | 'overseas') => {
    const next = new URLSearchParams(searchParams)
    if (v === 'overseas') next.set('view', 'overseas')
    else next.delete('view')
    next.delete('case_id')
    next.delete('tenant_uuid')
    next.delete('case_tenant')
    setSearchParams(next)
  }, [searchParams, setSearchParams])
  const [canOperate, setCanOperate] = useState(false)
  const [items, setItems] = useState<StartupAgentCaseItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [stage, setStage] = useState('')
  const [status, setStatus] = useState('all')
  const [keyword, setKeyword] = useState('')
  const [city, setCity] = useState('')
  const [paidFilter, setPaidFilter] = useState<'' | 'paid' | 'unpaid'>('')
  const [createdFrom, setCreatedFrom] = useState('')
  const [createdTo, setCreatedTo] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const viewing = detailCaseID && detailTenantUUID
    ? { id: detailCaseID, tenant_uuid: detailTenantUUID }
    : null
  const [stats, setStats] = useState<StartupAgentStats | null>(null)
  // PII 明文按钮按权限码渲染（platform.startup_agent.pii_read，契约 §2.4）；
  // 拉取失败按无权限处理（后端仍有强制门）。
  const [canViewPII, setCanViewPII] = useState(false)

  useEffect(() => {
    let cancelled = false
    Auth.permissions()
      .then((codes) => {
        if (cancelled) return
        setCanViewPII((codes ?? []).includes('platform.startup_agent.pii_read'))
        setCanOperate((codes ?? []).includes('platform.startup_agent.operate'))
      })
      .catch(() => {
        if (cancelled) return
        setCanViewPII(false)
        setCanOperate(false)
      })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    let cancelled = false
    StartupAgentCases.list({
      stage: stage || undefined,
      status,
      q: keyword || undefined,
      city: city || undefined,
      paid: paidFilter || undefined,
      created_from: createdFrom || undefined,
      created_to: createdTo || undefined,
      page,
      page_size: pageSize,
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
  }, [stage, status, keyword, city, paidFilter, createdFrom, createdTo, page, pageSize, tick])

  // 统计卡与筛选无关，只随刷新重取；失败静默（卡片降级为占位，不挡列表）。
  useEffect(() => {
    let cancelled = false
    StartupAgentCases.stats()
      .then((s) => { if (!cancelled) setStats(s) })
      .catch(() => { if (!cancelled) setStats(null) })
    return () => { cancelled = true }
  }, [tick])

  const summary = useMemo(() => `共 ${total} 条申请`, [total])
  const resetPage = (fn: () => void) => {
    setLoading(true)
    setPage(1)
    fn()
  }
  const refresh = useCallback(() => {
    setLoading(true)
    setTick((v) => v + 1)
  }, [])

  const openViewing = useCallback((item: Pick<StartupAgentCaseItem, 'id' | 'tenant_uuid'>) => {
    const next = new URLSearchParams(searchParams)
    next.set('case_id', item.id)
    next.set('tenant_uuid', item.tenant_uuid)
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  const closeViewing = useCallback(() => {
    const next = new URLSearchParams(searchParams)
    next.delete('case_id')
    next.delete('tenant_uuid')
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  return (
    <div>
      <PageHeader
        title="企业注册申请"
        subtitle="创业助手收集的注册服务单：内地为自助注册申请（收款/核名/出照/办结），海外为按法域收资料的办理单，操作会实时推送给用户。"
      />

      <Tabs
        className="mb-4"
        value={view}
        onChange={setView}
        items={[
          { value: 'domestic', label: '内地注册' },
          { value: 'overseas', label: '海外注册' },
        ]}
      />

      {view === 'overseas' && (
        <WebCasesSection canOperate={canOperate} canViewPII={canViewPII}
          tick={tick} serviceType="海外主体注册" />
      )}

      {view === 'domestic' && (<>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
        <KpiCard label="本月新增" value={stats ? stats.new_this_month : '—'} />
        <KpiCard label="进行中" value={stats ? stats.active : '—'} tone="warn" />
        <KpiCard label="本月办结" value={stats ? stats.done_this_month : '—'} tone="success" />
        <KpiCard
          label="平均办结天数"
          value={stats ? stats.avg_done_days : '—'}
          hint="已办结事项 创建→办结 平均耗时"
        />
      </div>

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索注册单号 / 关联代账单号（DZ） / 申请人 / 字号"
          />
        }
        filters={
          <div className="flex flex-wrap items-center gap-2">
            <div className="w-[132px]">
              <Select value={stage} onChange={(e) => resetPage(() => setStage(e.target.value))}>
                {STAGE_FILTERS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
            <div className="w-[116px]">
              <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
                {STATUS_FILTERS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
            <div className="w-[112px]">
              <Select value={paidFilter} onChange={(e) => resetPage(() => setPaidFilter(e.target.value as '' | 'paid' | 'unpaid'))}>
                {PAID_FILTERS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
            <div className="w-[104px]">
              <Select value={city} onChange={(e) => resetPage(() => setCity(e.target.value))}>
                {CITY_FILTERS.map((c) => <option key={c} value={c}>{c || '全部城市'}</option>)}
              </Select>
            </div>
            <div className="flex items-center gap-1">
              <div className="w-[136px]">
                <Input
                  type="date"
                  value={createdFrom}
                  max={createdTo || undefined}
                  onChange={(e) => resetPage(() => setCreatedFrom(e.target.value))}
                  aria-label="创建时间起"
                />
              </div>
              <span className="text-[12px] text-[var(--color-text-mute)]">至</span>
              <div className="w-[136px]">
                <Input
                  type="date"
                  value={createdTo}
                  min={createdFrom || undefined}
                  onChange={(e) => resetPage(() => setCreatedTo(e.target.value))}
                  aria-label="创建时间止"
                />
              </div>
            </div>
          </div>
        }
        summary={summary}
        actions={
          <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新注册申请列表">
            <RefreshCw size={14} />
          </Button>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['单号', '租户', '申请人', '拟用字号', '城市', '关联服务', '阶段', '收款', '创建时间', '预计完成', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载注册申请</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState title="暂无注册申请" description="用户在创业助手里确认提交注册服务单后，会出现在这里。" />
        ) : undefined}
      >
        {!loading && items.map((item) => {
          const st = stageInfo(item)
          const pay = paymentInfo(item)
          const overdue = isOverdue(item)
          return (
            <tr
              key={item.id}
              className={`group hover:bg-[var(--color-bg-sub)] ${overdue ? 'bg-[var(--color-danger-bg)]/40' : ''}`}
            >
              <td className={`w-[196px] min-w-[196px] max-w-[196px] px-4 py-3 ${stickyLeftTdCls}`}>
                <div className="flex items-center gap-1.5">
                  <span className="truncate font-medium text-[var(--color-brand)]">{item.business_no || item.id.slice(0, 8)}</span>
                  {item.source === 'web' && (
                    <Badge className={TONE.info} title="Web 自助注册单：录费用与收款走 Web 端在线支付">Web</Badge>
                  )}
                  {item.expedite_pending && (
                    <Badge className={TONE.warn} title="用户已催办，等待加急回执">
                      <Zap size={11} className="mr-0.5" />催办
                    </Badge>
                  )}
                  {item.handoff_pending && (
                    <Badge className={TONE.danger} title="已收款但交接资料包未成功送出，请在详情中重发或下载后手动发送">
                      <AlertTriangle size={11} className="mr-0.5" />交接未送出
                    </Badge>
                  )}
                </div>
              </td>
              <td className="min-w-[180px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.tenant_name}>
                <div className="max-w-[220px] truncate">{item.tenant_name}</div>
              </td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3 text-[var(--color-text)]">
                {item.applicant || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[120px] whitespace-nowrap px-4 py-3 text-[var(--color-text)]" title={item.brand}>
                <div className="max-w-[160px] truncate">{item.brand || <span className="text-[var(--color-text-mute)]">—</span>}</div>
              </td>
              <td className="min-w-[88px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
                {item.city || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[200px] whitespace-nowrap px-4 py-3">
                {item.related_case_id ? (
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      className="font-medium text-[var(--color-brand)] hover:underline"
                      onClick={() => navigate(`/bookkeeping-tickets?case_id=${encodeURIComponent(item.related_case_id)}&tenant_uuid=${encodeURIComponent(item.tenant_uuid)}`)}
                    >
                      代账 · {item.related_business_no || '查看工单'}
                    </button>
                    <Badge className={TONE.gray}>
                      {relatedBookkeepingStatus(item.related_status, item.related_stage)}
                    </Badge>
                  </div>
                ) : <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[148px] whitespace-nowrap px-4 py-3">
                <div className="flex items-center gap-1.5">
                  <Badge className={st.tone}>{st.label}</Badge>
                  {overdue && <Badge className={TONE.danger} title={`预计完成 ${item.eta} 已过`}>超时</Badge>}
                </div>
              </td>
              <td className="min-w-[112px] whitespace-nowrap px-4 py-3">
                {pay ? (
                  <Badge className={pay.tone}>
                    {pay.label === '已收款' && item.fee_amount > 0 ? `已收款 ¥${item.fee_amount}` : pay.label}
                  </Badge>
                ) : <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[172px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
              <td className={`min-w-[112px] whitespace-nowrap px-4 py-3 ${overdue ? 'font-medium text-[var(--color-danger)]' : 'text-[var(--color-text-sub)]'}`}>
                {item.eta || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className={`min-w-[104px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => openViewing(item)}
                  title="查看详情"
                  aria-label={`查看注册申请 ${item.business_no}`}
                >
                  <Eye size={14} />
                  详情
                </Button>
              </td>
            </tr>
          )
        })}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => {
          setLoading(true)
          setPage(next)
        }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {viewing && (
        <CaseDrawer
          caseID={viewing.id}
          tenantUUID={viewing.tenant_uuid}
          canViewPII={canViewPII}
          onClose={closeViewing}
          onChanged={refresh}
          onOpenRelated={(relatedCaseID, relatedTenantUUID) => navigate(`/bookkeeping-tickets?case_id=${encodeURIComponent(relatedCaseID)}&tenant_uuid=${encodeURIComponent(relatedTenantUUID)}`)}
        />
      )}
      </>)}
    </div>
  )
}

// ---- 详情抽屉 ----

function CaseDrawer({
  caseID,
  tenantUUID,
  canViewPII,
  onClose,
  onChanged,
  onOpenRelated,
}: {
  caseID: string
  tenantUUID: string
  canViewPII: boolean
  onClose: () => void
  onChanged: () => void
  onOpenRelated: (caseID: string, tenantUUID: string) => void
}) {
  const [detail, setDetail] = useState<StartupAgentCaseDetail | null>(null)
  const [err, setErr] = useState('')
  // 弹窗打开时生成一次 event_key，重试复用（幂等，契约 §2.3）。
  const [action, setAction] = useState<{ kind: ActionKind; eventKey: string } | null>(null)
  const [refunding, setRefunding] = useState(false)
  // PII 明文：点击拉取后仅本抽屉会话内展示（每次拉取后端落查看审计）。
  const [pii, setPII] = useState<StartupAgentCasePII | null>(null)
  const [piiBusy, setPIIBusy] = useState(false)
  // 交接资料包下载（契约 §2.5a）：邮件故障人工兜底；权限同 pii_read，每次下载落审计。
  const [pkgBusy, setPkgBusy] = useState(false)
  // 四期 Web 自助注册单：submitted 阶段开价走 Web 支付（data.payment），
  // 不用 quote_final（那是 App 支付通道，Web 用户收不到）。
  const [webPricing, setWebPricing] = useState(false)

  const downloadPackage = async () => {
    setPkgBusy(true)
    try {
      const { blob, filename } = await StartupAgentCases.downloadPackage(caseID, tenantUUID)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.click()
      URL.revokeObjectURL(url)
      setErr('')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setPkgBusy(false)
    }
  }

  const togglePII = async () => {
    if (pii) { setPII(null); return }
    setPIIBusy(true)
    try {
      const resp = await StartupAgentCases.getPII(caseID, tenantUUID)
      setPII(resp.pii)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setPIIBusy(false)
    }
  }

  // 材料预览（契约 §2.5）：先开空窗再回填 URL——await 之后 window.open 会被拦截。
  // Web 自助注册单的附件在 baigong 本地存储（归属三重门）：走 previewFile
  // blob 预览——图片/PDF 点开即看（2026-08-07 修"点了直接下载"），另存走
  // 「下载资料包」；弹窗被拦截时退回下载。
  const openFile = async (fileUUID: string) => {
    if (detail?.source === 'web') {
      try {
        await WebCasesApi.previewFile(caseID, tenantUUID, fileUUID)
      } catch (e) {
        setErr((e as Error).message)
      }
      return
    }
    const win = window.open('', '_blank', 'noopener=false')
    try {
      const resp = await StartupAgentCases.getFileURL(caseID, tenantUUID, fileUUID)
      if (win) win.location.replace(resp.url)
    } catch (e) {
      win?.close()
      setErr((e as Error).message)
    }
  }

  const reload = useCallback(() => {
    StartupAgentCases.get(caseID, tenantUUID)
      .then((d) => { setDetail(d); setErr('') })
      .catch((e: Error) => setErr(e.message))
  }, [caseID, tenantUUID])

  useEffect(() => { reload() }, [reload])

  const openAction = (kind: ActionKind) =>
    setAction({ kind, eventKey: randomUUID() })

  const submitEvent = async (type: ActionKind, payload: Record<string, unknown>) => {
    if (!action) return
    const outcome = await StartupAgentCases.ingestEvent(caseID, {
      tenant_uuid: tenantUUID,
      type,
      event_key: action.eventKey,
      payload,
    })
    if (outcome.refund_error) {
      notifyOk(`操作已生效，但自动退款失败：${outcome.refund_error}；请在详情「发起退款」重试`)
    } else if (outcome.refund_triggered) {
      notifyOk('操作已生效，已自动发起微信原路退款')
    } else if (outcome.reason === 'duplicate_event') {
      notifyOk('该操作此前已处理，未重复推进')
    } else if (type === 'note_added') {
      notifyOk('内部备注已保存（不通知用户）')
    } else if (type === 'handoff_resend') {
      notifyOk('已触发重发，发送结果以时间线「交接资料包已发送」记录为准')
    } else {
      notifyOk(`已${EVENT_LABELS[type]}，用户将收到进度通知`)
    }
    setAction(null)
    reload()
    onChanged()
  }

  const st = detail ? stageInfo(detail) : null
  const draft = (detail?.data?.draft ?? {}) as Record<string, unknown>
  const materials = detail ? materialFields(detail.source, draft) : []
  // 证件随人分块（2026-08-06 反馈）：人员卡内直出该人的证件缩略图；
  // 底部只剩没有归属人的材料（场地证明等）。
  const looseMaterials = materials.filter((m) => !CLAIMED_FILE_KEYS.has(m.key))
  const fileThumbs = (key: string, label: string): ReactNode[] => {
    const raw = draft[key]
    const items = (Array.isArray(raw) ? raw : raw ? [raw] : []) as Array<Record<string, unknown> | string>
    return items.map((it, idx) => {
      // 引用键双收:契约规范 file_uuid,App 实际上报 file_id(2026-07-21 实锤)；
      // Web 自助注册单的值是 baigong 本地 file_id 字符串。
      const uuid = typeof it === 'object' && it !== null
        ? String(it.file_uuid ?? it.file_id ?? '')
        : typeof it === 'string' ? it : ''
      const thumbLabel = items.length > 1 ? `${label} ${idx + 1}` : label
      const clickable = canViewPII && !!uuid
      return (
        <button
          key={`${key}-${idx}`}
          type="button"
          disabled={!clickable}
          onClick={() => clickable && openFile(uuid)}
          title={clickable ? String((typeof it === 'object' && it !== null ? it.name : undefined) ?? thumbLabel) : '查看需要 PII 明文权限'}
          className={`inline-flex h-8 items-center gap-1.5 rounded-md border bg-[var(--color-bg-sub)] px-2.5 text-[12px] text-[var(--color-text-sub)] transition ${
            clickable
              ? 'cursor-pointer border-[var(--color-line)] hover:border-[var(--color-brand)] hover:text-[var(--color-brand)]'
              : 'cursor-not-allowed border-[var(--color-line)] opacity-70'
          }`}
        >
          <ImageIcon size={13} className="shrink-0" />
          <span className="max-w-[180px] truncate">{thumbLabel}</span>
        </button>
      )
    })
  }
  // 四期 Web 自助注册单：开价/收款走 data.payment + Web 端在线支付；
  // quote_final 与补材料请求都是 App 通道语义，对 web 来源隐藏。
  const webPay = detail?.source === 'web'
    ? ((detail.data?.payment ?? null) as WebCasePayment | null)
    : null
  const isWebQuote = !!detail && detail.source === 'web' && detail.status === 'active'
    && detail.stage.split(':', 1)[0] === 'submitted'
  const actions = detail
    ? availableActions(detail).filter((k) =>
        detail.source !== 'web' || (k !== 'quote_final' && k !== 'materials_requested'))
    : []
  // 向导化（2026-07-22）：主线下一步独占 primary，其余收进「更多操作」
  const next = detail
    ? (isWebQuote
        ? (webPay && webPay.status === 'pending'
            ? { title: '等待用户在线支付',
                desc: `已录费用 ¥${(webPay.amount_cents / 100).toFixed(2)}，用户在 Web 端支付后自动开始核名；要调整金额可重新录费用。` }
            : { title: '下一步：录费用',
                desc: 'Web 自助注册单：录入服务费后会立即通知用户并给出在线支付入口；支付完成自动开始核名。', action: undefined })
        : nextStepInfo(detail))
    : null
  const mainAction = !isWebQuote && next?.action && actions.includes(next.action) ? next.action : undefined
  const menuActions = actions.filter((k) => k !== mainAction)
  const payBadgeSrc = detail && webPay && webPay.status === 'pending'
    ? { ...detail, final_price: webPay.amount_cents / 100 }
    : detail
  const paid = payBadgeSrc ? paymentInfo(payBadgeSrc)?.label === '已收款' : false

  return (
    <DrawerShell
      title={detail?.business_no || '注册申请详情'}
      subtitle={detail ? `租户 ${detail.tenant_name} · 创建于 ${formatTime(detail.created_at)}` : undefined}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex items-center justify-between gap-2">
          <div className="flex flex-wrap items-center gap-2">
            {isWebQuote && (
              <Button variant="primary" size="sm" onClick={() => setWebPricing(true)}>
                {webPay && webPay.status === 'pending' ? '重新录费用' : '录费用'}
              </Button>
            )}
            {mainAction && (
              <Button variant="primary" size="sm" onClick={() => openAction(mainAction)}>
                {EVENT_LABELS[mainAction]}
              </Button>
            )}
            <ActionMenu
              items={[
                ...menuActions.map((kind) => ({
                  key: kind,
                  label: EVENT_LABELS[kind],
                  danger: kind === 'case_cancelled' || kind === 'case_rejected',
                  onSelect: () => openAction(kind),
                })),
                ...(detail && canViewPII
                  ? [{ key: 'pkg', label: pkgBusy ? '资料包打包中…' : '下载资料包', onSelect: downloadPackage }]
                  : []),
              ]}
            />
            {detail && actions.length === 0 && !canViewPII && (
              <span className="text-[12px] text-[var(--color-text-mute)]">当前状态无可执行操作</span>
            )}
          </div>
          <Button variant="secondary" onClick={onClose}>关闭</Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        {!detail && !err && (
          <div className="px-2 py-8 text-center text-[var(--color-text-sub)]">正在加载申请详情</div>
        )}

        {detail && st && (
          <>
            <div className="flex items-center gap-2">
              <Badge className={st.tone}>{st.label}</Badge>
              {detail.source === 'web' && (
                <Badge className={TONE.info} title="Web 自助注册单：用户在 Web 端填资料并在线支付">Web 自助</Badge>
              )}
              {payBadgeSrc && paymentInfo(payBadgeSrc) && (
                <Badge className={paymentInfo(payBadgeSrc)!.tone}>{paymentInfo(payBadgeSrc)!.label}</Badge>
              )}
              {detail.expedite_pending && (
                <Badge className={TONE.warn} title="用户已催办，等待加急回执"><Zap size={11} className="mr-0.5" />催办中</Badge>
              )}
              {detail.handoff_pending && (
                <Badge className={TONE.danger}><AlertTriangle size={11} className="mr-0.5" />交接未送出</Badge>
              )}
              {isOverdue(detail) && <Badge className={TONE.danger}>超时</Badge>}
            </div>

            {next && (
              <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-info-bg)] px-3 py-2 text-[13px] leading-6">
                <span className="font-medium text-[var(--color-text)]">{next.title}</span>
                <span className="ml-2 text-[var(--color-text-sub)]">{next.desc}</span>
              </div>
            )}

            {detail.handoff_pending && (
              <InlineAlert tone="warn">
                交接资料包未送出：系统未能把资料包发送到金蝶对接人邮箱（原因见时间线「交接发送失败」）。
                请点击下方「重发交接资料包」，或「下载资料包」后手动发送。
              </InlineAlert>
            )}

            <FormSection
              title="申请信息"
              description="来自用户在创业助手中的表单提交；身份证号、手机号默认脱敏展示。"
            >
              {Object.keys(draft).length === 0 ? (
                <div className="text-[13px] text-[var(--color-text-mute)]">草稿尚未填写任何字段。</div>
              ) : (
                <>
                  <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
                    <Field span label="公司名称（候选字号）" value={brandLine(draft)} />
                    <Field label="注册城市" value={text(draft.city)} />
                    <Field label="行业" value={text(draft.industry)} />
                    <Field label="经营期限" value={text(draft.operating_term)} />
                    <Field label="注册资本（万元）" value={text(draft.registered_capital)} />
                    <Field span label="经营范围"
                      value={[text(draft.business_scope), text(draft.scope_note)].filter(Boolean).join('；')} />
                    <Field label="地址方案" value={text(draft.address_mode)} />
                    <Field label="自有地址" value={text(draft.address_detail)} />
                    <Field span label="执照/印章收件信息"
                      value={[text(draft.ship_name), text(draft.ship_mobile), text(draft.ship_address)]
                        .filter(Boolean).join(' · ')} />
                  </div>

                  <div className="mt-4">
                    <div className="mb-1.5 text-[12px] font-medium text-[var(--color-text-sub)]">人员信息</div>
                    <div className="grid items-start gap-3 xl:grid-cols-2">
                      <PersonCard title={`法定代表人${text(draft.rep_name) ? ` · ${text(draft.rep_name)}` : ''}`}
                        files={[...fileThumbs('id_front', '身份证 · 人像面'),
                                ...fileThumbs('id_back', '身份证 · 国徽面')]}>
                        <PIIField label="身份证号" masked={maskPII(text(draft.rep_id_number))} plain={pii?.rep_id_number}
                          canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                        <PIIField label="手机号" masked={maskPII(text(draft.rep_mobile))} plain={pii?.rep_mobile}
                          canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                        <CardField label="邮箱" value={text(draft.rep_email)} />
                      </PersonCard>
                      {(text(draft.sup_name) || text(draft.sup_mode)) && (
                        <PersonCard title={`监事${text(draft.sup_name) ? ` · ${text(draft.sup_name)}` : ''}`}
                          note={text(draft.sup_mode)}
                          files={[...fileThumbs('sup_id_front', '身份证 · 人像面'),
                                  ...fileThumbs('sup_id_back', '身份证 · 国徽面')]}>
                          <PIIField label="身份证号" masked={maskPII(text(draft.sup_id_number))} plain={pii?.sup_id_number}
                            canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                          <PIIField label="手机号" masked={maskPII(text(draft.sup_mobile))} plain={pii?.sup_mobile}
                            canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                        </PersonCard>
                      )}
                      {OFFICER_ROLES.map(([p, roleLabel]) => text(draft[`${p}_mode`]) ? (
                        text(draft[`${p}_mode`]) === '另行指定' ? (
                          <PersonCard key={p} note="另行指定"
                            title={`${roleLabel}${text(draft[`${p}_name`]) ? ` · ${text(draft[`${p}_name`])}` : ''}`}
                            files={[...fileThumbs(`${p}_id_front`, '身份证 · 人像面'),
                                    ...fileThumbs(`${p}_id_back`, '身份证 · 国徽面')]}>
                            <PIIField label="身份证号" masked={maskPII(text(draft[`${p}_id_number`]))}
                              plain={pii?.[`${p}_id_number`]} canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                            <PIIField label="手机号" masked={maskPII(text(draft[`${p}_mobile`]))}
                              plain={pii?.[`${p}_mobile`]} canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                          </PersonCard>
                        ) : (
                          <PersonCard key={p} title={roleLabel} note="同法定代表人" />
                        )
                      ) : null)}
                    </div>
                  </div>

                  {!!text(draft.shareholder_mode) && (
                    <div className="mt-4">
                      <div className="mb-1.5 text-[12px] font-medium text-[var(--color-text-sub)]">
                        股东与出资 · {text(draft.shareholder_mode)}
                      </div>
                      <div className="grid items-start gap-3 xl:grid-cols-2">
                        {!!text(draft.rep_share_ratio) && (
                          <PersonCard note={`出资 ${text(draft.rep_share_ratio)}%`}
                            title={`法定代表人${text(draft.rep_name) ? ` · ${text(draft.rep_name)}` : ''}`} />
                        )}
                        {SHAREHOLDER_SEATS.map(([p, seatLabel]) => text(draft[`${p}_type`]) ? (
                          <PersonCard key={p}
                            title={`${seatLabel}${(() => { const n = text(draft[`${p}_company_name`]) || text(draft[`${p}_name`]); return n ? ` · ${n}` : '' })()}`}
                            note={[text(draft[`${p}_type`]),
                                   text(draft[`${p}_share_ratio`]) && `出资 ${text(draft[`${p}_share_ratio`])}%`]
                              .filter(Boolean).join(' · ')}
                            files={text(draft[`${p}_type`]) === '企业股东'
                              ? [...fileThumbs(`${p}_license`, '营业执照副本'),
                                 ...fileThumbs(`${p}_license_sealed`, '执照盖章件')]
                              : [...fileThumbs(`${p}_id_front`, '身份证 · 人像面'),
                                 ...fileThumbs(`${p}_id_back`, '身份证 · 国徽面')]}>
                            {text(draft[`${p}_type`]) !== '企业股东' && (
                              <>
                                <PIIField label="身份证号" masked={maskPII(text(draft[`${p}_id_number`]))}
                                  plain={pii?.[`${p}_id_number`]} canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                                <PIIField label="手机号" masked={maskPII(text(draft[`${p}_mobile`]))}
                                  plain={pii?.[`${p}_mobile`]} canView={canViewPII} busy={piiBusy} onToggle={togglePII} />
                              </>
                            )}
                          </PersonCard>
                        ) : null)}
                      </div>
                    </div>
                  )}

                  {!!text(draft.bookkeeping) && (
                    <div className="mt-4">
                      <div className="mb-1.5 text-[12px] font-medium text-[var(--color-text-sub)]">
                        代理记账{text(draft.bookkeeping) === '需要' ? '（报价与工单进度见下方关联记录）' : ''}
                      </div>
                      <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
                        <Field label="是否需要" value={text(draft.bookkeeping)} />
                        <Field label="纳税人类型" value={text(draft.taxpayer_type)} />
                        <Field label="公司人数" value={text(draft.headcount)} />
                        <Field label="需缴社保人数" value={text(draft.insured_count)} />
                        <Field label="月开票金额" value={text(draft.monthly_invoice)} />
                        <Field label="月票据张数" value={text(draft.monthly_receipts)} />
                        <Field label="行业（记账口径）" value={text(draft.bk_industry)} />
                        <Field label="期望开始月份" value={text(draft.start_month)} />
                      </div>
                    </div>
                  )}

                  {looseMaterials.some((m) => draft[m.key]) && (
                    <div className="mt-4">
                      <div className="mb-1.5 text-[12px] text-[var(--color-text-mute)]">
                        其他材料{canViewPII ? '（点击查看，每次查看记审计）' : '（查看需要 PII 权限）'}
                      </div>
                      <div className="flex flex-wrap gap-2">
                        {looseMaterials.flatMap((m) => fileThumbs(m.key, m.label))}
                      </div>
                    </div>
                  )}
                  {/* 服务费合计条（原型：金额 + 收款态内嵌申请信息卡底部；金额来自登记收款事件快照） */}
                  <div className="mt-4 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3.5 py-2.5">
                    <span className="text-[13px] text-[var(--color-text-sub)]">服务费合计</span>
                    <span className="text-[15px] font-semibold tabular-nums text-[var(--color-text)]">
                      {detail.fee_amount > 0 ? `¥${detail.fee_amount}` : '未登记'}
                    </span>
                    {paymentInfo(detail) && (
                      <Badge className={paymentInfo(detail)!.tone}>{paymentInfo(detail)!.label}</Badge>
                    )}
                    <div className="flex-1" />
                    {detail.eta && (
                      <span className={`text-[12px] ${isOverdue(detail) ? 'font-medium text-[var(--color-danger)]' : 'text-[var(--color-text-mute)]'}`}>
                        预计完成 {detail.eta}
                      </span>
                    )}
                    {actions.includes('quote_final') && (
                      <Button size="sm" onClick={() => openAction('quote_final')}>录服务费</Button>
                    )}
                    {detail.refund_pending && (
                      <Button size="sm" variant="danger" onClick={() => setRefunding(true)}>发起退款</Button>
                    )}
                  </div>
                </>
              )}
            </FormSection>

            <RelatedCaseCard
              heading="关联服务"
              businessNo={detail.related_business_no
                ? `代理记账 · ${detail.related_business_no}`
                : ''}
              title={detail.related_case_id ? '来源：注册顺带' : undefined}
              statusLabel={relatedBookkeepingStatus(detail.related_status, detail.related_stage)}
              onOpen={detail.related_case_id
                ? () => onOpenRelated(detail.related_case_id, detail.tenant_uuid)
                : undefined}
              error={!detail.related_case_id ? bookkeepingCreationMessage(detail.data) : ''}
            />

            <FormSection title="办理时间线" description="用户动作与顾问录入的进度事件，均带操作人审计。">
              {(detail.events ?? []).length === 0 ? (
                <div className="text-[13px] text-[var(--color-text-mute)]">暂无操作记录。</div>
              ) : (
                <div>
                  {(detail.events ?? []).map((ev, i, arr) => (
                    <CaseTimelineItem
                      key={`${ev.received_at}-${i}`}
                      kind={timelineKind(ev)}
                      label={EVENT_LABELS[ev.event_type] || ev.event_type}
                      summary={eventSummary(ev)}
                      time={formatTime(ev.received_at)}
                      operator={typeof ev.payload?.operator === 'string' ? ev.payload.operator : ''}
                      last={i === arr.length - 1}
                    />
                  ))}
                </div>
              )}
            </FormSection>
          </>
        )}
      </div>

      {action && detail && (
        <EventDialog
          kind={action.kind}
          paid={paid}
          businessNo={detail.business_no}
          approvedName={String(detail.data?.approved_name ?? '')}
          onClose={() => setAction(null)}
          onSubmit={(payload) => submitEvent(action.kind, payload)}
        />
      )}
      {refunding && detail && (
        <CaseRefundDialog
          caseId={detail.id}
          tenantUuid={detail.tenant_uuid}
          maxYuan={detail.fee_amount || 0}
          onClose={() => setRefunding(false)}
          onDone={() => { setRefunding(false); reload(); onChanged() }}
        />
      )}
      {webPricing && detail && (
        <SetPaymentDialog
          caseID={caseID}
          tenantUUID={tenantUUID}
          current={webPay && webPay.status === 'pending' ? webPay : null}
          onClose={() => setWebPricing(false)}
          onSaved={() => { setWebPricing(false); reload(); onChanged() }}
        />
      )}
    </DrawerShell>
  )
}

// 时间线语义（契约 §4）：会推送用户的顾问事件标「已推送用户」，
// 内部备注只留档不打扰用户，用户催办来自会话侧，其余为用户会话动作。
const NOTIFYING_EVENTS = new Set([
  'quote_final', 'payment_recorded', 'refund_completed', 'naming_result', 'materials_requested', 'license_uploaded',
  'expedite_ack', 'case_closed', 'case_cancelled', 'case_rejected',
])

function timelineKind(ev: StartupAgentCaseEvent): CaseTimelineKind {
  if (ev.event_type === 'note_added') return 'note'
  if (ev.event_type === 'expedite_requested') return 'urge'
  // 交接资料包（契约 §4）：重发=顾问动作、已发送=系统事实，均不推送用户；
  // 发送失败=需处理的系统事实（2026-07-21）。
  if (ev.event_type === 'handoff_failed') return 'fail'
  if (ev.event_type === 'handoff_resend' || ev.event_type === 'handoff_sent') return 'op'
  if (NOTIFYING_EVENTS.has(ev.event_type)) return 'push'
  return 'user' // 提交申请/补交材料/补充新字号等用户会话动作
}

function eventSummary(ev: StartupAgentCaseEvent): string {
  const p = ev.payload || {}
  switch (ev.event_type) {
    case 'quote_final': return p.amount ? `¥${p.amount}` : ''
    case 'refund_completed': return p.amount ? `¥${p.amount} 已原路退回` : ''
    case 'payment_recorded': return p.amount ? `${p.channel === 'wechat' ? '微信支付 · ' : ''}金额 ¥${p.amount}${p.note ? ` · ${p.note}` : ''}` : ''
    case 'naming_result': return p.passed ? `通过 · ${p.approved_name ?? ''}` : `驳回 · ${p.reject_reason ?? ''}`
    case 'materials_requested': return `${Array.isArray(p.items) ? p.items.join('、') : ''}${p.reason ? `（${p.reason}）` : ''}`
    case 'license_uploaded': return `${p.company_name ?? ''} · ${p.credit_code ?? ''}${p.established_date ? ` · 成立 ${p.established_date}` : ''}`
    case 'case_cancelled': return p.refund ? '费用原路退回' : ''
    case 'case_rejected': return `${p.reason_category ? `${p.reason_category} · ` : ''}${p.reason ?? ''}`
    case 'note_added': return typeof p.text === 'string' ? p.text : ''
    case 'shipping_info': {
      const f = (p.fields || {}) as Record<string, unknown>
      return [f.ship_name, f.ship_mobile, f.ship_address].filter(Boolean).join(' · ')
    }
    case 'handoff_sent': return `v${p.version ?? '?'}${p.reason ? `（${p.reason}）` : ''}`
    case 'handoff_failed': return `v${p.version ?? '?'}${p.reason ? ` · ${p.reason}` : ''}`
    case 'handoff_resend': return '重发最新全量资料包到金蝶对接人邮箱'
    default: return ''
  }
}

// ---- 录事件弹窗 ----

function EventDialog({
  kind,
  paid,
  businessNo,
  approvedName = '',
  onClose,
  onSubmit,
}: {
  kind: ActionKind
  paid: boolean
  businessNo: string
  approvedName?: string
  onClose: () => void
  onSubmit: (payload: Record<string, unknown>) => Promise<void>
}) {
  if (kind === 'expedite_ack') {
    return (
      <ConfirmDialog
        title="发送加急回执"
        tone="info"
        description={`将向用户发送「已加急 ⚡ 顾问会在 24 小时内更新进度」（${businessNo}），不改变办理阶段。`}
        confirmLabel="发送"
        onClose={onClose}
        onConfirm={() => onSubmit({})}
      />
    )
  }
  if (kind === 'handoff_resend') {
    return (
      <ConfirmDialog
        title="重发交接资料包"
        tone="info"
        description={`将把 ${businessNo} 当前的全量资料（确认单汇总 + 全部附件）以新版本号重发到金蝶对接人邮箱。不改变办理阶段、不通知用户。`}
        confirmLabel="重发"
        onClose={onClose}
        onConfirm={() => onSubmit({})}
      />
    )
  }
  if (kind === 'case_closed') {
    return (
      <ConfirmDialog
        title="办结关单"
        tone="info"
        description={`确认 ${businessNo} 已完成交付。关单后向用户发送收尾引导（银行开户 / 税务报到 / 刻章），申请进入「已完成」。`}
        confirmLabel="确认关单"
        onClose={onClose}
        onConfirm={() => onSubmit({})}
      />
    )
  }
  if (kind === 'case_cancelled') {
    return (
      <ConfirmDialog
        title="取消申请"
        description={
          paid
            ? `取消 ${businessNo} 后申请终止，已收服务费将按「原路退回」口径通知用户。此操作不可撤销。`
            : `取消 ${businessNo} 后申请终止，此操作不可撤销。`
        }
        confirmLabel="确认取消申请"
        onClose={onClose}
        onConfirm={() => onSubmit({ refund: paid })}
      />
    )
  }
  if (kind === 'quote_final') return <QuoteFinalDialog onClose={onClose} onSubmit={onSubmit} />
  if (kind === 'naming_result') return <NamingDialog onClose={onClose} onSubmit={onSubmit} />
  if (kind === 'materials_requested') return <MaterialsDialog onClose={onClose} onSubmit={onSubmit} />
  if (kind === 'case_rejected') return <RejectDialog businessNo={businessNo} onClose={onClose} onSubmit={onSubmit} />
  if (kind === 'note_added') return <NoteDialog onClose={onClose} onSubmit={onSubmit} />
  return <LicenseDialog approvedName={approvedName} onClose={onClose} onSubmit={onSubmit} />
}

type FormDialogProps = {
  onClose: () => void
  onSubmit: (payload: Record<string, unknown>) => Promise<void>
}

function useSubmit(onSubmit: (payload: Record<string, unknown>) => Promise<void>) {
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const run = async (payload: Record<string, unknown>) => {
    setBusy(true)
    setErr('')
    try {
      await onSubmit(payload)
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }
  return { busy, err, run }
}

function dialogFooter(busy: boolean, disabled: boolean, label: string, onClose: () => void, submit: () => void) {
  return (
    <div className="flex justify-end gap-2">
      <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
      <Button onClick={submit} disabled={busy || disabled}>{busy ? '提交中...' : label}</Button>
    </div>
  )
}

function QuoteFinalDialog({ onClose, onSubmit }: FormDialogProps) {
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const value = Number(amount)
  const invalid = !amount || Number.isNaN(value) || value <= 0
  const submit = () => run({ amount: value, ...(note.trim() ? { note: note.trim() } : {}) })
  return (
    <DialogShell
      title="录服务费"
      subtitle="确认后实时推送用户并附微信支付入口；用户支付完成自动开始核名，并把交接资料包（确认单 + 全部附件）发送到金蝶对接人邮箱，操作写入审计。"
      onClose={onClose}
      size="sm"
      footer={dialogFooter(busy, invalid, '确认并推送', onClose, submit)}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="服务费金额（元）">
          <Input
            type="number"
            min={0}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="如 1888"
          />
        </FormField>
        <FormField label="凭据说明（选填）" hint="转账凭证号、收款备注等，随事件留档">
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="微信转账 · 凭证号 42000..." />
        </FormField>
      </div>
    </DialogShell>
  )
}

function NamingDialog({ onClose, onSubmit }: FormDialogProps) {
  const [passed, setPassed] = useState<'pass' | 'reject'>('pass')
  const [approvedName, setApprovedName] = useState('')
  const [rejectReason, setRejectReason] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const invalid = passed === 'pass' ? !approvedName.trim() : !rejectReason.trim()
  const submit = () => run(passed === 'pass'
    ? { passed: true, approved_name: approvedName.trim() }
    : { passed: false, reject_reason: rejectReason.trim() })
  return (
    <DialogShell
      title="录入核名结果"
      subtitle="通过 → 报送工商；驳回 → 用户只需在会话里补 2-3 个新字号，其余信息不重填。"
      onClose={onClose}
      size="sm"
      footer={dialogFooter(busy, invalid, '确认并通知用户', onClose, submit)}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <SegmentedControl
          value={passed}
          onChange={setPassed}
          options={[{ value: 'pass', label: '核名通过' }, { value: 'reject', label: '核名驳回' }]}
        />
        {passed === 'pass' ? (
          <FormField label="核准的企业全称" hint="含行政区划与行业表述，如：杭州知未网络科技有限公司">
            <Input value={approvedName} onChange={(e) => setApprovedName(e.target.value)} placeholder="杭州知未网络科技有限公司" />
          </FormField>
        ) : (
          <FormField label="驳回原因" hint="将原文推送给用户">
            <Input value={rejectReason} onChange={(e) => setRejectReason(e.target.value)} placeholder="与已注册企业重名" />
          </FormField>
        )}
      </div>
    </DialogShell>
  )
}

// 措辞须与 baigong graph._MATERIAL_FIELD_MAP 的键逐字一致——勾选项原文作为
// items 推送，runtime 按中文名映射补传卡的 file slot，改词会落进通用 material_N 槽。
const MATERIAL_PRESETS = [
  '身份证人像面',
  '身份证国徽面',
  '监事身份证人像面',
  '监事身份证国徽面',
  '地址产权证明',
]

function MaterialsDialog({ onClose, onSubmit }: FormDialogProps) {
  const [checked, setChecked] = useState<Set<string>>(new Set())
  const [custom, setCustom] = useState('')
  const [reason, setReason] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const items = [...checked, ...(custom.trim() ? [custom.trim()] : [])]
  const invalid = items.length === 0 || !reason.trim()
  const toggle = (name: string) =>
    setChecked((prev) => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  const submit = () => run({ items, reason: reason.trim() })
  return (
    <DialogShell
      title="请求补材料"
      subtitle="办理阶段保持不变，用户补齐后自动继续；请求会推送给用户。"
      onClose={onClose}
      size="sm"
      footer={dialogFooter(busy, invalid, '发送补材料请求', onClose, submit)}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <div className="space-y-2">
          {MATERIAL_PRESETS.map((name) => (
            <label key={name} className="flex cursor-pointer items-center gap-2 rounded-md border border-[var(--color-line-soft)] px-3 py-2 text-[13px] text-[var(--color-text)]">
              <input type="checkbox" checked={checked.has(name)} onChange={() => toggle(name)} />
              {name}
            </label>
          ))}
        </div>
        <FormField label="其他材料（选填）">
          <Input value={custom} onChange={(e) => setCustom(e.target.value)} placeholder="如：租赁合同复印件" />
        </FormField>
        <FormField label="给用户的原因" hint="如：照片模糊，请重拍">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="照片模糊，请重拍" />
        </FormField>
      </div>
    </DialogShell>
  )
}

const REJECT_CATEGORIES = ['行业禁入', '材料造假嫌疑', '资料不齐且无法联系', '其他']

function RejectDialog({ businessNo, onClose, onSubmit }: FormDialogProps & { businessNo: string }) {
  const [category, setCategory] = useState(REJECT_CATEGORIES[0])
  const [reason, setReason] = useState('')
  const [notifyText, setNotifyText] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const invalid = !reason.trim()
  const submit = () => run({
    reason_category: category,
    reason: reason.trim(),
    ...(notifyText.trim() ? { notify_text: notifyText.trim() } : {}),
  })
  return (
    <DialogShell
      title="驳回申请"
      subtitle={`驳回 ${businessNo} 后申请终止且不可撤销；已收费用按「原路退回」口径通知用户。`}
      onClose={onClose}
      size="sm"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button variant="danger" onClick={submit} disabled={busy || invalid}>{busy ? '提交中...' : '确认驳回'}</Button>
        </div>
      }
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="驳回原因分类">
          <Select value={category} onChange={(e) => setCategory(e.target.value)}>
            {REJECT_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </Select>
        </FormField>
        <FormField label="具体说明" hint="必填，写入审计并用于用户通知">
          <textarea
            value={reason}
            rows={3}
            onChange={(e) => setReason(e.target.value)}
            placeholder="如：所选经营范围包含禁入行业"
            className={textareaCls}
          />
        </FormField>
        <FormField label="发送给用户的通知（选填）" hint="不填时使用默认模板：驳回原因 + 费用原路退回">
          <textarea
            value={notifyText}
            rows={3}
            onChange={(e) => setNotifyText(e.target.value)}
            placeholder="很抱歉，您的注册申请未通过审核：……已支付费用将原路退回。"
            className={textareaCls}
          />
        </FormField>
      </div>
    </DialogShell>
  )
}

function NoteDialog({ onClose, onSubmit }: FormDialogProps) {
  const [text, setText] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const invalid = !text.trim()
  const submit = () => run({ text: text.trim() })
  return (
    <DialogShell
      title="添加内部备注"
      subtitle="只进操作时间线留档（带操作人），不会通知用户、不改变办理阶段。"
      onClose={onClose}
      size="sm"
      footer={dialogFooter(busy, invalid, '保存备注', onClose, submit)}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="备注内容">
          <textarea
            value={text}
            rows={4}
            onChange={(e) => setText(e.target.value)}
            placeholder="如：已电话与申请人确认字号顺序，优先使用备选一"
            className={textareaCls}
          />
        </FormField>
      </div>
    </DialogShell>
  )
}

const textareaCls = 'w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]'

function LicenseDialog({ approvedName = '', onClose, onSubmit }: FormDialogProps & { approvedName?: string }) {
  // 企业名称预填核名核准的全称（2026-07-21）：核名已定，重敲易错；工商极少调整，可改。
  const [companyName, setCompanyName] = useState(approvedName)
  const [creditCode, setCreditCode] = useState('')
  const [establishedDate, setEstablishedDate] = useState('')
  const [registeredAddress, setRegisteredAddress] = useState('')
  const { busy, err, run } = useSubmit(onSubmit)
  const invalid = !companyName.trim() || !creditCode.trim() || !establishedDate
  const submit = () => run({
    company_name: companyName.trim(),
    credit_code: creditCode.trim(),
    established_date: establishedDate,
    ...(registeredAddress.trim() ? { registered_address: registeredAddress.trim() } : {}),
  })
  return (
    <DialogShell
      title="录入执照信息"
      subtitle="确认后申请进入「已出照」，向用户推送执照信息并自动完善企业档案；执照电子档随邮件/邮寄交付（文件上传后置）。"
      onClose={onClose}
      size="sm"
      footer={dialogFooter(busy, invalid, '确认录入并通知用户', onClose, submit)}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="企业名称" hint={approvedName ? '已按核名核准的全称带入，与执照不一致时再修改' : undefined}>
          <Input value={companyName} onChange={(e) => setCompanyName(e.target.value)} placeholder="杭州知未网络科技有限公司" />
        </FormField>
        <FormField label="统一社会信用代码">
          <Input value={creditCode} onChange={(e) => setCreditCode(e.target.value)} placeholder="91330106MA2XXXXX0K" />
        </FormField>
        <FormField label="成立日期" hint="以执照上的成立日期为准，代账建账与报税起算依赖此日期">
          <Input type="date" value={establishedDate} onChange={(e) => setEstablishedDate(e.target.value)} />
        </FormField>
        <FormField label="注册地址（选填）" hint="执照上的住所；填了将更新企业档案，不填保留申请时的地址">
          <Input value={registeredAddress} onChange={(e) => setRegisteredAddress(e.target.value)} placeholder="杭州市西湖区XX路XX号XX室" />
        </FormField>
      </div>
    </DialogShell>
  )
}

// ---- 小件 ----

// 人员小卡（2026-08-06 反馈）：证件/手机号随人分块，不再混进大网格——
// 标题=角色·姓名，note=安排（同法定代表人/另行指定/出资比例等）。
// 卡内字段用横向 label-value 行（label 定宽对齐），证件 chip 用细线与字段分隔。
function PersonCard({ title, note, children, files }: {
  title: string
  note?: string
  children?: ReactNode
  files?: ReactNode[]
}) {
  return (
    <div className="rounded-md border border-[var(--color-line)] px-3 py-2.5">
      <div className="flex items-baseline gap-2">
        <span className="text-[13px] font-medium text-[var(--color-text)]">{title}</span>
        {note && <span className="text-[12px] text-[var(--color-text-mute)]">{note}</span>}
      </div>
      {children && <div className="mt-1.5 space-y-1">{children}</div>}
      {files && files.length > 0 && (
        <div className={`flex flex-wrap gap-1.5 ${children ? 'mt-2.5 border-t border-[var(--color-line-soft)] pt-2.5' : 'mt-2'}`}>
          {files}
        </div>
      )}
    </div>
  )
}

// 卡内明文信息行（如邮箱）：与 PIIField 同一 label 定宽，保证卡内纵向对齐。
function CardField({ label, value }: { label: string; value: string }) {
  if (!value) return null
  return (
    <div className="flex items-start gap-3">
      <span className="w-14 shrink-0 text-[12px] leading-6 text-[var(--color-text-mute)]">{label}</span>
      <span className="min-w-0 break-words text-[13px] leading-6 text-[var(--color-text)]">{value}</span>
    </div>
  )
}

// PII 行：脱敏值 + 小眼睛切换明文（与 SecretValueField 的眼睛惯例一致；
// 一次拉取全部字段并落查看审计，任一眼睛开关即全局显隐）。
function PIIField({ label, masked, plain, canView, busy, onToggle }: {
  label: string
  masked: string
  plain?: string
  canView: boolean
  busy: boolean
  onToggle: () => void
}) {
  if (!masked) return null
  return (
    <div className="flex items-start gap-3">
      <span className="w-14 shrink-0 text-[12px] leading-6 text-[var(--color-text-mute)]">{label}</span>
      <span className="flex min-w-0 items-center gap-1.5 text-[13px] leading-6 text-[var(--color-text)]">
        <span className="truncate font-mono tabular-nums">{plain || masked}</span>
        {canView && (
          <button
            type="button"
            onClick={onToggle}
            disabled={busy}
            title={plain ? '隐藏明文' : '查看明文（每次查看写入审计）'}
            aria-label={plain ? `隐藏${label}明文` : `查看${label}明文`}
            className="shrink-0 text-[var(--color-text-mute)] transition hover:text-[var(--color-brand)] disabled:cursor-not-allowed disabled:opacity-50"
          >
            {plain ? <EyeOff size={14} /> : <Eye size={14} />}
          </button>
        )}
      </span>
    </div>
  )
}
