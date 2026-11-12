// 办理单（web_service）共享视图：列表 + 详情抽屉 + 开价弹框。
// 2026-08-06 拍板：留资只做联系标记不再转化，办理一律在 Web 对话里自助发起；
// 海外主体注册单并入「企业注册申请」页的海外 Tab（本组件按 serviceType 过滤），
// 原「创业助手咨询单」页的办理单 Tab 下线。契约 §2.11。
import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { ClipboardList, Eye, Image as ImageIcon } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'

import {
  StartupAgentCases as StartupAgentCasesApi,
  WebCases as WebCasesApi,
  type WebCaseDetail,
  type WebCaseItem,
  type WebCasePayment,
  type WebCaseStage,
} from '../lib/api'
import { notifyOk } from '../lib/toast'
import { CaseBadge as Badge, CaseField as Field, CaseTimelineItem } from './caseTimeline'
import { CASE_TONE as TONE } from './caseTone'
import {
  ActionMenu,
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from './ui'

// 办理资料字段中文名（与 baigong materials/overseas_materials 的 SlotSpec label 对齐；
// 未登记的 key 原样显示，后端加字段不阻塞前端）
const MATERIAL_LABELS: Record<string, string> = {
  contact_name: '联系人姓名', id_front: '证件照·正面', id_back: '证件照·反面', extra_note: '补充说明',
  ov_jurisdiction: '注册地', ov_holding: '控股方式', ov_purpose: '主要用途',
  ov_target_region: '目标法域', ov_other_note: '补充说明',
  ov_name_1: '公司名称·首选', ov_name_2: '公司名称·备选', ov_capital: '注册资本', ov_business: '业务描述',
  ov_sh_mode: '股东构成', ov_rep_name: '申请人姓名', ov_rep_id: '申请人身份证照',
  ov_rep_passport: '申请人护照照', ov_rep_selfie: '申请人手持证件照', ov_rep_ratio: '申请人持股比例',
  ov_sh2_name: '股东2姓名', ov_sh2_ratio: '股东2持股比例', ov_sh2_id: '股东2身份证照',
  ov_sh2_passport: '股东2护照照', ov_sh2_selfie: '股东2手持证件照',
  ov_sh3_name: '股东3姓名', ov_sh3_ratio: '股东3持股比例', ov_sh3_id: '股东3身份证照',
  ov_sh3_passport: '股东3护照照', ov_sh3_selfie: '股东3手持证件照',
  ov_corp_name: '法人股东名称', ov_corp_cert: '法人股东注册证书', ov_corp_sh_doc: '法人股东·股东文件',
  ov_corp_dir_doc: '法人股东·董事文件', ov_corp_chart: '股权架构图', ov_ubo_id: '最终受益人证件照',
  ov_corp_note: '架构补充说明',
  ov_dir_mode: '董事人选', ov_dir_name: '董事姓名', ov_dir_id: '董事身份证照',
  ov_dir_passport: '董事护照照', ov_dir_selfie: '董事手持证件照',
  ov_rep_addr_proof: '申请人地址证明', ov_addr_proof_2: '其他股东/董事地址证明',
  ship_name: '收件人', ship_mobile: '收件电话', ship_address: '收件地址',
}
const materialLabel = (k: string) => MATERIAL_LABELS[k] ?? k

const CASE_STAGE_FILTERS: { value: string; label: string }[] = [
  { value: '', label: '全部阶段' },
  { value: 'received', label: '已接单' },
  { value: 'materials', label: '资料准备' },
  { value: 'processing', label: '办理中' },
  { value: 'done', label: '已办结' },
  { value: 'cancelled', label: '已终止' },
]

function caseStageInfo(stage: string): { label: string; tone: string } {
  switch (stage) {
    case 'received': return { label: '已接单', tone: TONE.info }
    case 'materials': return { label: '资料准备', tone: TONE.warn }
    case 'processing': return { label: '办理中', tone: TONE.info }
    case 'done': return { label: '已办结', tone: TONE.success }
    case 'cancelled': return { label: '已终止', tone: TONE.gray }
    default: return { label: stage || '未知', tone: TONE.gray }
  }
}

// 向导化流程（design std §4.x）：每个阶段只有一个"下一步"，顾问照提示点。
// 2026-08-07 拍板（与内地一致）：用户交资料 → 顾问核对后**录费用** → 用户
// 在线支付 → **支付成功自动进入办理**（录费用即隐含资料核可，不再有
// "资料无误，开始办理"的手动步）→ 办结。
const CASE_FLOW: Partial<Record<WebCaseStage, { next: WebCaseStage; btn: string }>> = {
  received: { next: 'materials', btn: '开始收资料' },   // 存量转化单兜底
  processing: { next: 'done', btn: '办结' },
}

function caseGuide(detail: WebCaseDetail): string {
  const pay = detail.payment
  switch (detail.stage) {
    case 'received':
    case 'materials':
      if (pay?.status === 'pending') {
        return `已录费用 ¥${(pay.amount_cents / 100).toFixed(2)}，等待用户支付；支付成功自动进入办理。`
      }
      return detail.materials_done
        ? '用户已提交资料 ✓ 到下方办理资料区核对，没问题就点录费用——用户在线支付后自动进入办理。'
        : '等待用户在 Web 对话里提交资料；资料齐了核对无误就录费用。'
    case 'processing': {
      // 海外主线（2026-08-07 里程碑对齐内地）：核名 → 录证书 → 收件 → 办结
      if (detail.service_type === '海外主体注册') {
        const ev = new Set(detail.events.map((e) => e.event_type))
        if (!ev.has('naming_passed')) return '费用已到账、办理中。名称核准下来后点核名通过，用户会收到庆祝通知。'
        if (!ev.has('license_issued')) return '核名已通过 ✓ 拿到注册证书后点录入证书——用户会收到证书通知并填写收件信息。'
        if (!ev.has('shipping_info')) return '证书已录 ✓ 等用户填写收件信息（聊天里已弹收件卡）；文件寄出后点办结。'
        return '收件信息已收到 ✓（见下方办理资料区）证书原件与印章寄出并确认后点办结。'
      }
      return '费用已到账、办理中。全部完成后点办结，用户端会自动收到通知。'
    }
    case 'done':
      return '本单已办结。如需继续推进，可在更多操作里恢复到办理中。'
    default:
      return '本单已终止办理。如需继续推进，可在更多操作里恢复到办理中。'
  }
}

function fmtTime(v: string): string {
  if (!v) return '-'
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? v : d.toLocaleString('zh-CN', { hour12: false })
}

function caseEventLabel(type: string): string {
  switch (type) {
    case 'created': return '建单'
    case 'progress': return '进度更新'
    case 'materials_submitted': return '用户提交资料'
    case 'payment_recorded': return '用户完成支付'
    case 'naming_passed': return '核名通过'
    case 'license_issued': return '录入注册证书'
    case 'shipping_info': return '用户提交收件信息'
    default: return type
  }
}

export function WebCasesSection({ canOperate, canViewPII = false, tick, serviceType }: {
  canOperate: boolean
  // 资料包下载走 pii_read 门（含证件影像，与内地注册申请同权限码）
  canViewPII?: boolean
  tick: number
  // 传入即按服务类型过滤（如「海外主体注册」）；空 = 全部办理单
  serviceType?: string
}) {
  const [items, setItems] = useState<WebCaseItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [stage, setStage] = useState('')
  const [q, setQ] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [reload, setReload] = useState(0)
  const [searchParams, setSearchParams] = useSearchParams()

  const caseID = searchParams.get('case_id') ?? ''
  const caseTenant = searchParams.get('case_tenant') ?? ''

  const resetPage = useCallback((fn: () => void) => {
    fn()
    setPage(1)
    setLoading(true)
  }, [])

  useEffect(() => {
    let cancelled = false
    WebCasesApi.list({
      stage: stage || undefined, q: q.trim() || undefined,
      service_type: serviceType || undefined,
      page, page_size: pageSize,
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
  }, [stage, q, page, pageSize, tick, reload, serviceType])

  const openCase = useCallback((item: WebCaseItem) => {
    const next = new URLSearchParams(searchParams)
    next.set('case_id', item.id)
    next.set('case_tenant', item.tenant_uuid)
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  const closeCase = useCallback(() => {
    const next = new URLSearchParams(searchParams)
    next.delete('case_id')
    next.delete('case_tenant')
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  return (
    <>
      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => resetPage(() => setQ(v))}
            placeholder="搜索单号 / 标题 / 手机号"
          />
        }
        filters={
          <div className="w-[140px]">
            <Select value={stage} onChange={(e) => resetPage(() => setStage(e.target.value))}>
              {CASE_STAGE_FILTERS.map((f) => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </Select>
          </div>
        }
        summary={<>共 {total} 单</>}
      />
      {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['标题', '单号', '服务类型', '手机号', '阶段', '更新时间', '操作']}
        loading={loading ? (
          <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载办理单</div>
        ) : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            title={serviceType ? `暂无${serviceType}单` : '暂无办理单'}
            description="用户在 Web 对话里发起办理并开始填资料后，单子会出现在这里。"
          />
        ) : undefined}
      >
        {items.map((item) => {
          const info = caseStageInfo(item.stage)
          return (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[220px] min-w-[220px] max-w-[220px] px-4 py-3 ${stickyLeftTdCls}`}>
                <span className="block truncate" title={item.title}>{item.title || '-'}</span>
              </td>
              <td className="min-w-[130px] whitespace-nowrap px-4 py-3 font-mono text-[13px] text-[var(--color-text-sub)]">
                {item.case_no || '-'}
              </td>
              <td className="min-w-[110px] whitespace-nowrap px-4 py-3">{item.service_type || '-'}</td>
              <td className="min-w-[130px] whitespace-nowrap px-4 py-3">{item.phone || '-'}</td>
              <td className="min-w-[100px] whitespace-nowrap px-4 py-3">
                <Badge className={info.tone}>{info.label}</Badge>
              </td>
              <td className="min-w-[160px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
                {fmtTime(item.updated_at)}
              </td>
              <td className={`min-w-[104px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button variant="ghost" size="sm" onClick={() => openCase(item)}>
                  <Eye size={14} /> 详情
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
        onPageChange={setPage}
        onPageSizeChange={(s) => { setPageSize(s); setPage(1) }}
      />
      {caseID && caseTenant && (
        <WebCaseDrawer
          caseID={caseID}
          tenantUUID={caseTenant}
          canOperate={canOperate}
          canViewPII={canViewPII}
          onClose={closeCase}
          onChanged={() => setReload((v) => v + 1)}
        />
      )}
    </>
  )
}

// ---------------------------------------------------------------- 资料模块化展示
// 与内地注册申请详情同款排版（PersonCard/label 定宽行/32px 附件 chip）；
// 组件为本文件私有轻量副本——内地页的同名组件与其 PII 逻辑耦合，不跨页复用。

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

function CardField({ label, value }: { label: string; value: string }) {
  if (!value) return null
  return (
    <div className="flex items-start gap-3">
      <span className="w-14 shrink-0 text-[12px] leading-6 text-[var(--color-text-mute)]">{label}</span>
      <span className="min-w-0 break-words text-[13px] leading-6 text-[var(--color-text)]">{value}</span>
    </div>
  )
}

const OVERSEAS_FILE_RE = /^[0-9a-f]{32}\.(jpg|png|pdf|xlsx)$/

function OverseasMaterials({ draft, onFile }: {
  draft: Record<string, unknown>
  onFile: (fileID: string) => void
}) {
  const v = (k: string) => {
    const raw = draft[k]
    if (raw == null) return ''
    return Array.isArray(raw) ? raw.join('、') : String(raw)
  }
  const chip = (k: string, label: string): ReactNode[] => {
    const id = v(k)
    if (!id || !OVERSEAS_FILE_RE.test(id)) return []
    return [(
      <button
        key={k}
        type="button"
        onClick={() => onFile(id)}
        title={`下载 ${label}`}
        className="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-2.5 text-[12px] text-[var(--color-text-sub)] transition hover:border-[var(--color-brand)] hover:text-[var(--color-brand)]"
      >
        <ImageIcon size={13} className="shrink-0" />
        <span className="max-w-[180px] truncate">{label}</span>
      </button>
    )]
  }
  const shMode = v('ov_sh_mode')
  const hasCorp = !!(v('ov_corp_name') || v('ov_corp_cert'))
  const hasSh2 = !!(v('ov_sh2_name') || v('ov_sh2_id'))
  const hasSh3 = !!(v('ov_sh3_name') || v('ov_sh3_id'))
  const dirExtra = v('ov_dir_mode') === '另指定董事'
  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-2 gap-3">
        <Field label="注册地" value={v('ov_jurisdiction') || '-'} />
        <Field label="控股方式" value={v('ov_holding') || '-'} />
        <Field label="主要用途" value={v('ov_purpose') || '-'} />
        {v('ov_target_region') && <Field label="目标法域" value={v('ov_target_region')} />}
        {v('ov_other_note') && <Field label="补充说明" value={v('ov_other_note')} />}
      </div>
      {(v('ov_name_1') || v('ov_business')) && (
        <PersonCard title="公司信息">
          <CardField label="名称首选" value={v('ov_name_1')} />
          <CardField label="名称备选" value={v('ov_name_2')} />
          <CardField label="注册资本" value={v('ov_capital')} />
          <CardField label="业务描述" value={v('ov_business')} />
        </PersonCard>
      )}
      <div className="grid grid-cols-1 gap-2 md:grid-cols-2 md:items-start">
        {(v('ov_rep_name') || v('ov_rep_id')) && (
          <PersonCard
            title={`申请人${v('ov_rep_name') ? ` · ${v('ov_rep_name')}` : ''}`}
            note={shMode || undefined}
            files={[...chip('ov_rep_id', '身份证照'),
                    ...chip('ov_rep_passport', '护照照'),
                    ...chip('ov_rep_selfie', '手持证件照')]}
          >
            {v('ov_rep_ratio') && <CardField label="持股比例" value={`${v('ov_rep_ratio')}%`} />}
          </PersonCard>
        )}
        {hasSh2 && (
          <PersonCard
            title={`股东 2${v('ov_sh2_name') ? ` · ${v('ov_sh2_name')}` : ''}`}
            files={[...chip('ov_sh2_id', '身份证照'),
                    ...chip('ov_sh2_passport', '护照照'),
                    ...chip('ov_sh2_selfie', '手持证件照')]}
          >
            {v('ov_sh2_ratio') && <CardField label="持股比例" value={`${v('ov_sh2_ratio')}%`} />}
          </PersonCard>
        )}
        {hasSh3 && (
          <PersonCard
            title={`股东 3${v('ov_sh3_name') ? ` · ${v('ov_sh3_name')}` : ''}`}
            files={[...chip('ov_sh3_id', '身份证照'),
                    ...chip('ov_sh3_passport', '护照照'),
                    ...chip('ov_sh3_selfie', '手持证件照')]}
          >
            {v('ov_sh3_ratio') && <CardField label="持股比例" value={`${v('ov_sh3_ratio')}%`} />}
          </PersonCard>
        )}
        {hasCorp && (
          <PersonCard
            title={`法人股东${v('ov_corp_name') ? ` · ${v('ov_corp_name')}` : ''}`}
            files={[...chip('ov_corp_cert', '注册证书'),
                    ...chip('ov_corp_sh_doc', '股东文件'),
                    ...chip('ov_corp_dir_doc', '董事文件'),
                    ...chip('ov_corp_chart', '股权架构图'),
                    ...chip('ov_ubo_id', '受益人证件照')]}
          >
            {v('ov_corp_note') && <CardField label="补充说明" value={v('ov_corp_note')} />}
          </PersonCard>
        )}
        {(v('ov_dir_mode') || dirExtra) && (
          <PersonCard
            title={dirExtra
              ? `董事${v('ov_dir_name') ? ` · ${v('ov_dir_name')}` : ''}`
              : '董事'}
            note={dirExtra ? undefined : (v('ov_dir_mode') || undefined)}
            files={dirExtra
              ? [...chip('ov_dir_id', '身份证照'),
                 ...chip('ov_dir_passport', '护照照'),
                 ...chip('ov_dir_selfie', '手持证件照')]
              : undefined}
          />
        )}
        {(v('ov_rep_addr_proof') || v('ov_addr_proof_2')) && (
          <PersonCard
            title="地址证明"
            note="近 3 个月账单（香港要求）"
            files={[...chip('ov_rep_addr_proof', '申请人地址证明'),
                    ...chip('ov_addr_proof_2', '其他股东/董事地址证明')]}
          />
        )}
        {(v('ship_name') || v('ship_address')) && (
          <PersonCard title="收件信息" note="证书原件与印章寄送">
            <CardField label="收件人" value={v('ship_name')} />
            <CardField label="电话" value={v('ship_mobile')} />
            <CardField label="地址" value={v('ship_address')} />
          </PersonCard>
        )}
      </div>
    </div>
  )
}

function WebCaseDrawer({ caseID, tenantUUID, canOperate, canViewPII, onClose, onChanged }: {
  caseID: string
  tenantUUID: string
  canOperate: boolean
  canViewPII: boolean
  onClose: () => void
  onChanged: () => void
}) {
  const [detail, setDetail] = useState<WebCaseDetail | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [reload, setReload] = useState(0)
  const [payOpen, setPayOpen] = useState(false)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [pkgBusy, setPkgBusy] = useState(false)
  const [namingOpen, setNamingOpen] = useState(false)
  const [licenseOpen, setLicenseOpen] = useState(false)

  // 资料打包下载（2026-08-07 对齐内地）：同一 /cases/{id}/package 端点，
  // pii_read 门控 + 下载审计在 admin 后端
  const downloadPackage = async () => {
    setPkgBusy(true)
    try {
      const { blob, filename } = await StartupAgentCasesApi.downloadPackage(caseID, tenantUUID)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.click()
      URL.revokeObjectURL(url)
      setError('')
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setPkgBusy(false)
    }
  }

  useEffect(() => {
    let cancelled = false
    WebCasesApi.get(caseID, tenantUUID)
      .then((res) => {
        if (cancelled) return
        setDetail(res)
        setError('')
      })
      .catch((e: Error) => { if (!cancelled) setError(e.message) })
    return () => { cancelled = true }
  }, [caseID, tenantUUID, reload])

  const push = useCallback(async (stage: WebCaseStage, t?: string,
                                  ok = '进度已更新，用户端会收到通知') => {
    setBusy(true)
    try {
      await WebCasesApi.progress(caseID, tenantUUID, {
        stage, title: (t ?? '').trim() || undefined,
      })
      notifyOk(ok)
      setReload((v) => v + 1)
      onChanged()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [caseID, tenantUUID, onChanged])

  const info = caseStageInfo(detail?.stage ?? '')
  const terminal = detail?.stage === 'done' || detail?.stage === 'cancelled'
  const flow = detail ? CASE_FLOW[detail.stage] : undefined
  // 用户已交资料且未录费用：主动作是录费用（录了费用=资料核可，
  // 用户支付后自动进入办理）
  const needPricing = !!detail && !detail.payment
    && (detail.stage === 'materials' || detail.stage === 'received')
    && detail.materials_done
  // 海外办理中主线（2026-08-07）：核名 → 录证书 → 办结依序做主按钮
  const isOverseas = detail?.service_type === '海外主体注册'
  const evTypes = new Set((detail?.events ?? []).map((ev) => ev.event_type))
  const overseasStep: 'naming' | 'license' | null =
    isOverseas && detail?.stage === 'processing'
      ? (!evTypes.has('naming_passed') ? 'naming'
        : !evTypes.has('license_issued') ? 'license' : null)
      : null

  return (
    <DrawerShell
      title={detail?.title || '办理单详情'}
      subtitle={detail ? `单号 ${detail.case_no || '-'} · 建单于 ${fmtTime(detail.created_at)} · ${detail.service_type}` : ''}
      icon={<ClipboardList size={16} />}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            {canOperate && needPricing && (
              <Button variant="primary" size="sm" disabled={busy}
                onClick={() => setPayOpen(true)}>
                录费用
              </Button>
            )}
            {canOperate && !needPricing && overseasStep === 'naming' && (
              <Button variant="primary" size="sm" disabled={busy}
                onClick={() => setNamingOpen(true)}>
                核名通过
              </Button>
            )}
            {canOperate && !needPricing && overseasStep === 'license' && (
              <Button variant="primary" size="sm" disabled={busy}
                onClick={() => setLicenseOpen(true)}>
                录入证书
              </Button>
            )}
            {canOperate && !needPricing && !overseasStep && flow && (
              <Button variant="primary" size="sm" disabled={busy}
                onClick={() => void push(flow.next)}>
                {flow.btn}
              </Button>
            )}
            {canOperate && detail && (
              <ActionMenu items={[
                // 海外里程碑兜底入口（主按钮按序推荐；重录/补录走这里）
                ...(isOverseas && !terminal ? [
                  { key: 'naming', label: '核名通过', onSelect: () => setNamingOpen(true) },
                  { key: 'license', label: '录入注册证书', onSelect: () => setLicenseOpen(true) },
                ] : []),
                ...(terminal ? [{
                  key: 'resume', label: '恢复到办理中',
                  onSelect: () => void push('processing', '已恢复办理', '已恢复办理'),
                }] : [{
                  key: 'cancel', label: '终止办理', danger: true,
                  onSelect: () => setCancelOpen(true),
                }]),
                ...(canViewPII && Object.keys(detail.materials_draft ?? {}).length > 0
                  ? [{ key: 'pkg', label: pkgBusy ? '资料包打包中…' : '下载资料包',
                       onSelect: () => void downloadPackage() }]
                  : []),
              ]} />
            )}
          </div>
          <Button variant="secondary" onClick={onClose}>关闭</Button>
        </div>
      }
    >
      {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
      {detail == null ? (
        <div className="px-1 py-6 text-[var(--color-text-sub)]">正在加载…</div>
      ) : (
        <div className="flex flex-col gap-5">
          {/* 向导化引导条：告诉顾问"现在该做什么"（design std §4.x） */}
          <InlineAlert tone={detail.stage === 'done' ? 'success' : 'info'}>
            {caseGuide(detail)}
          </InlineAlert>
          <FormSection title="单据信息">
            <div className="grid grid-cols-2 gap-4">
              <Field label="服务类型" value={detail.service_type || '-'} />
              <Field label="用户手机号" value={detail.phone || '-'} />
              <div>
                <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">当前阶段</div>
                <div className="mt-0.5"><Badge className={info.tone}>{info.label}</Badge></div>
              </div>
              <Field label="最近更新" value={fmtTime(detail.updated_at)} />
            </div>
            {detail.note && (
              <div className="mt-3">
                <Field label="内部备注" value={detail.note} />
              </div>
            )}
          </FormSection>

          <FormSection
            title="收款"
            description="顾问核对资料后录费用；用户在 Web 端「办理进度」里在线支付，支付成功自动进入办理。"
          >
            <div className="flex items-center justify-between gap-3">
              {detail.payment == null ? (
                <div className="text-[13px] text-[var(--color-text-sub)]">尚未录费用。</div>
              ) : (
                <div className="flex items-center gap-2 text-[14px]">
                  <span className="font-semibold">¥{(detail.payment.amount_cents / 100).toFixed(2)}</span>
                  <span className="text-[var(--color-text-sub)]">{detail.payment.desc}</span>
                  <Badge className={detail.payment.status === 'paid' ? TONE.success : TONE.warn}>
                    {detail.payment.status === 'paid' ? '已支付' : '待支付'}
                  </Badge>
                </div>
              )}
              {canOperate && detail.payment?.status !== 'paid' && (
                <Button variant="secondary" size="sm" onClick={() => setPayOpen(true)}>
                  {detail.payment == null ? '录费用' : '改费用'}
                </Button>
              )}
            </div>
          </FormSection>

          <FormSection
            title="办理资料"
            description={detail.materials_done
              ? '用户已提交完成；附件可下载核对。'
              : '用户在 Web 对话里按法域逐步填写，填齐自动同步到这里。'}
          >
            {Object.keys(detail.materials_draft ?? {}).length === 0 ? (
              <div className="text-[13px] text-[var(--color-text-sub)]">用户尚未填写。</div>
            ) : detail.service_type === '海外主体注册' ? (
              // 海外注册：与内地注册申请同款人员模块化排版（2026-08-07）
              <OverseasMaterials
                draft={detail.materials_draft as Record<string, unknown>}
                onFile={(id) => void WebCasesApi.previewFile(caseID, tenantUUID, id)}
              />
            ) : (
              <div className="grid grid-cols-2 gap-3">
                {Object.entries(detail.materials_draft).map(([k, v]) => {
                  const val = Array.isArray(v) ? v.join('、') : String(v ?? '')
                  const isFile = OVERSEAS_FILE_RE.test(val)
                  return isFile ? (
                    <div key={k}>
                      <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">{materialLabel(k)}</div>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => void WebCasesApi.previewFile(caseID, tenantUUID, val)}
                      >
                        查看附件
                      </Button>
                    </div>
                  ) : (
                    <Field key={k} label={materialLabel(k)} value={val || '-'} />
                  )
                })}
              </div>
            )}
          </FormSection>

          <FormSection title="进度时间线">
            {detail.events.length === 0 ? (
              <div className="text-[13px] text-[var(--color-text-sub)]">暂无记录。</div>
            ) : (
              <div>
                {detail.events.map((ev, i) => {
                  const payload = (ev.payload ?? {}) as Record<string, string>
                  const parts = [
                    payload.stage ? caseStageInfo(payload.stage).label : '',
                    payload.title ?? '',
                    payload.note ? `内部：${payload.note}` : '',
                  ]
                  return (
                    <CaseTimelineItem
                      key={`${ev.event_type}-${ev.received_at}-${i}`}
                      kind={ev.event_type === 'materials_submitted'
                        || ev.event_type === 'payment_recorded' ? 'user' : 'op'}
                      label={caseEventLabel(ev.event_type)}
                      summary={parts.filter(Boolean).join(' · ')}
                      time={fmtTime(ev.received_at)}
                      operator={payload.operator}
                      last={i === detail.events.length - 1}
                    />
                  )
                })}
              </div>
            )}
          </FormSection>
        </div>
      )}
      {payOpen && detail && (
        <SetPaymentDialog
          caseID={caseID}
          tenantUUID={tenantUUID}
          current={detail.payment}
          onClose={() => setPayOpen(false)}
          onSaved={() => { setPayOpen(false); setReload((v) => v + 1); onChanged() }}
        />
      )}
      {namingOpen && detail && (
        <NamingDialog
          caseID={caseID}
          tenantUUID={tenantUUID}
          defaultName={detail.approved_name
            || String((detail.materials_draft ?? {}).ov_name_1 ?? '')}
          onClose={() => setNamingOpen(false)}
          onSaved={() => { setNamingOpen(false); setReload((v) => v + 1); onChanged() }}
        />
      )}
      {licenseOpen && detail && (
        <LicenseDialog
          caseID={caseID}
          tenantUUID={tenantUUID}
          defaultName={detail.approved_name
            || String((detail.materials_draft ?? {}).ov_name_1 ?? '')}
          onClose={() => setLicenseOpen(false)}
          onSaved={() => { setLicenseOpen(false); setReload((v) => v + 1); onChanged() }}
        />
      )}
      {cancelOpen && detail && (
        <ConfirmDialog
          title="终止办理？"
          description="用户端会显示「本单已终止办理」；已收款项不受影响。之后可在「更多操作」里恢复。"
          confirmLabel="终止办理"
          onClose={() => setCancelOpen(false)}
          onConfirm={async () => {
            await push('cancelled', '', '已终止办理')
            setCancelOpen(false)
          }}
        />
      )}
    </DrawerShell>
  )
}

// 核名通过（2026-08-07 海外里程碑）：留痕 + 用户会话庆祝话术。
function NamingDialog({ caseID, tenantUUID, defaultName, onClose, onSaved }: {
  caseID: string
  tenantUUID: string
  defaultName: string
  onClose: () => void
  onSaved: () => void
}) {
  const [name, setName] = useState(defaultName)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = useCallback(async () => {
    if (!name.trim()) {
      setError('填核准通过的名称')
      return
    }
    setBusy(true)
    try {
      await WebCasesApi.naming(caseID, tenantUUID, name.trim())
      notifyOk('已同步核名结果，用户会收到通知')
      onSaved()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [name, caseID, tenantUUID, onSaved])

  return (
    <DialogShell
      title="核名通过"
      subtitle="记录核准名称并推送庆祝通知给用户；名称默认取资料里的首选字号，可修改。"
      onClose={onClose}
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="primary" disabled={busy} onClick={() => void submit()}>确认核名通过</Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
        <FormField label="核准名称">
          <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={100} placeholder="例如：云图国际有限公司" />
        </FormField>
      </div>
    </DialogShell>
  )
}

// 录入注册证书（2026-08-07 海外里程碑）：档案字段 + 待收件子态 + 证书话术
// （举证书人物形象）+ 用户端收件表单卡。
function LicenseDialog({ caseID, tenantUUID, defaultName, onClose, onSaved }: {
  caseID: string
  tenantUUID: string
  defaultName: string
  onClose: () => void
  onSaved: () => void
}) {
  const [name, setName] = useState(defaultName)
  const [regNo, setRegNo] = useState('')
  const [date, setDate] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = useCallback(async () => {
    if (!regNo.trim()) {
      setError('填注册证书上的注册编号')
      return
    }
    setBusy(true)
    try {
      await WebCasesApi.license(caseID, tenantUUID, {
        company_name: name.trim() || undefined,
        reg_no: regNo.trim(),
        established_date: date.trim() || undefined,
      })
      notifyOk('证书已录入，用户会收到通知并填写收件信息')
      onSaved()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [name, regNo, date, caseID, tenantUUID, onSaved])

  return (
    <DialogShell
      title="录入注册证书"
      subtitle="录入后用户会收到证书通知并填写收件信息（证书原件与印章快递寄送）。"
      onClose={onClose}
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="primary" disabled={busy} onClick={() => void submit()}>确认录入</Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
        <FormField label="公司名称" hint="空则沿用核名通过的名称。">
          <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={100} />
        </FormField>
        <FormField label="注册编号">
          <Input value={regNo} onChange={(e) => setRegNo(e.target.value)} maxLength={64} placeholder="证书上的公司编号 / UEN" />
        </FormField>
        <FormField label="成立日期" hint="选填。">
          <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </FormField>
      </div>
    </DialogShell>
  )
}

// 录费用（契约 §2.11b）：金额按元输入、提交转分；pending 可改，已支付
// 后端 409。2026-08-07 拍板：内地/海外统一"录费用"措辞——录费用即资料
// 核可，用户支付成功后自动进入下一阶段（内地开始核名/办理单开始办理）。
export function SetPaymentDialog({ caseID, tenantUUID, current, verb = '录费用', onClose, onSaved }: {
  caseID: string
  tenantUUID: string
  current: WebCasePayment | null
  verb?: string
  onClose: () => void
  onSaved: () => void
}) {
  const [yuan, setYuan] = useState(current ? (current.amount_cents / 100).toFixed(2) : '')
  const [desc, setDesc] = useState(current?.desc ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = useCallback(async () => {
    const amount = Math.round(Number(yuan) * 100)
    if (!Number.isFinite(amount) || amount <= 0) {
      setError('金额需为正数（元）')
      return
    }
    if (!desc.trim()) {
      setError('填一句服务说明，用户支付时会看到')
      return
    }
    setBusy(true)
    try {
      await WebCasesApi.setPayment(caseID, tenantUUID, {
        amount_cents: amount, desc: desc.trim(),
      })
      notifyOk('已录费用，用户在 Web 端即可支付')
      onSaved()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [yuan, desc, caseID, tenantUUID, onSaved])

  return (
    <DialogShell
      title={current ? `重新${verb}` : verb}
      subtitle="用户在 Web 端「办理进度」里看到金额与说明并在线支付；支付成功前可随时修改。"
      onClose={onClose}
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="primary" disabled={busy} onClick={() => void submit()}>确认{verb}</Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
        <FormField label="金额（元）">
          <Input value={yuan} onChange={(e) => setYuan(e.target.value)} placeholder="例如：688.00" inputMode="decimal" />
        </FormField>
        <FormField label="服务说明" hint="用户支付页可见，例如「注册全包服务费」。">
          <Input value={desc} onChange={(e) => setDesc(e.target.value)} placeholder="必填" maxLength={200} />
        </FormField>
      </div>
    </DialogShell>
  )
}
