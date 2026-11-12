// 创业助手咨询单（原「Web 线索」，2026-08-05 更名；contracts/admin-startup-agent-api.md §2.9 / §2.10）。
// 独立 Web 入口（创业助手站）的匿名访客留资：顾问在此跟进联系，并维护回执里的
// 顾问二维码（换顾问只换图，Web 端即时生效）。
// 2026-08-06 拍板：留资只做联系标记、不再转化——注册/海外办理都由用户在
// Web 对话里自助发起（办理单在企业注册申请页的海外 Tab）；本页办理单 Tab 与
// 「转办理单」入口下线。
// 隐私：列表联系方式由服务端脱敏，明文只在详情（每次查看写审计）。
import { useCallback, useEffect, useMemo, useState } from 'react'
import { ClipboardList, Eye, QrCode, RefreshCw, UserPlus } from 'lucide-react'
import { useNavigate, useSearchParams } from 'react-router-dom'

import {
  Auth,
  WebLeads as WebLeadsApi,
  type WebContactCard,
  type WebLeadDetail,
  type WebLeadItem,
  type WebLeadStats,
} from '../lib/api'
import { notifyOk } from '../lib/toast'
import { CaseBadge as Badge, CaseField as Field, CaseTimelineItem } from '../components/caseTimeline'
import { CASE_TONE as TONE } from '../components/caseTone'
import { FileUploadPicker } from '../components/form/FileUploadPicker'
import {
  Button,
  DataTable,
  KpiCard,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'

const STAGE_FILTERS: { value: string; label: string }[] = [
  { value: '', label: '全部跟进态' },
  { value: 'new', label: '待联系' },
  { value: 'contacted', label: '已联系' },
  { value: 'converted', label: '已成单' },
  { value: 'invalid', label: '无效' },
]

function stageInfo(stage: string): { label: string; tone: string } {
  switch (stage) {
    case 'new': return { label: '待联系', tone: TONE.warn }
    case 'contacted': return { label: '已联系', tone: TONE.info }
    case 'converted': return { label: '已成单', tone: TONE.success }
    case 'invalid': return { label: '无效', tone: TONE.gray }
    default: return { label: stage || '未知', tone: TONE.gray }
  }
}

const FOLLOW_LABELS: Record<'contacted' | 'invalid', string> = {
  contacted: '标记已联系',
  invalid: '标记无效',
}

function fmtTime(v: string): string {
  if (!v) return '-'
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? v : d.toLocaleString('zh-CN', { hour12: false })
}

function eventLabel(type: string): string {
  switch (type) {
    case 'lead_submitted': return '用户提交留资'
    case 'lead_updated': return '用户更新留资'
    case 'lead_followed': return '顾问跟进'
    default: return type
  }
}

export function WebLeadsPage() {
  const [items, setItems] = useState<WebLeadItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [stage, setStage] = useState('')
  const [q, setQ] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [tick, setTick] = useState(0)
  const [canOperate, setCanOperate] = useState(false)
  const [qrOpen, setQrOpen] = useState(false)
  const [stats, setStats] = useState<WebLeadStats | null>(null)
  const [searchParams, setSearchParams] = useSearchParams()

  const leadID = searchParams.get('lead_id') ?? ''
  const tenantUUID = searchParams.get('tenant_uuid') ?? ''

  const resetPage = useCallback((fn: () => void) => {
    fn()
    setPage(1)
    setLoading(true)
  }, [])
  const refresh = useCallback(() => { setLoading(true); setTick((v) => v + 1) }, [])

  useEffect(() => {
    let cancelled = false
    Auth.permissions()
      .then((codes) => {
        if (!cancelled) setCanOperate((codes ?? []).includes('platform.startup_agent.operate'))
      })
      .catch(() => { if (!cancelled) setCanOperate(false) })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    let cancelled = false
    WebLeadsApi.stats(30)
      .then((res) => { if (!cancelled) setStats(res) })
      .catch(() => { if (!cancelled) setStats(null) })
    return () => { cancelled = true }
  }, [tick])

  useEffect(() => {
    let cancelled = false
    WebLeadsApi.list({
      stage: stage || undefined, q: q.trim() || undefined, page, page_size: pageSize,
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
  }, [stage, q, page, pageSize, tick])

  const openDetail = useCallback((item: WebLeadItem) => {
    const next = new URLSearchParams(searchParams)
    next.set('lead_id', item.id)
    next.set('tenant_uuid', item.tenant_uuid)
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  const closeDetail = useCallback(() => {
    const next = new URLSearchParams(searchParams)
    next.delete('lead_id')
    next.delete('tenant_uuid')
    setSearchParams(next)
  }, [searchParams, setSearchParams])

  return (
    <>
      <PageHeader
        title="创业助手咨询单"
        subtitle="独立 Web 站（创业助手）访客留下的联系方式，顾问在此电话/微信跟进并做标记；办理由用户在 Web 对话里自助发起，不从这里转化。"
        actions={
          <div className="flex items-center gap-2">
            {canOperate && (
              <Button variant="secondary" onClick={() => setQrOpen(true)}>
                <QrCode size={14} /> 顾问二维码
              </Button>
            )}
            <Button variant="secondary" onClick={refresh}>
              <RefreshCw size={14} /> 刷新
            </Button>
          </div>
        }
      />
      {stats && (
        <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard
            label="近 30 天访客"
            value={stats.visitors}
            hint={`今天 ${stats.visitors_today} 人 · 人均 ${stats.avg_turns} 轮`}
          />
          <KpiCard label="留下联系方式" value={stats.converted} tone="success" />
          <KpiCard
            label="留资转化率"
            value={`${stats.conversion_rate}%`}
            hint="留资会话 / 咨询会话"
          />
          <KpiCard
            label="待联系"
            value={stats.by_stage?.new ?? 0}
            tone="warn"
            hint={`已成单 ${stats.by_stage?.converted ?? 0}`}
          />
        </div>
      )}
      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => resetPage(() => setQ(v))}
            placeholder="搜索称呼 / 联系方式 / 城市"
          />
        }
        filters={
          <div className="w-[160px]">
            <Select value={stage} onChange={(e) => resetPage(() => setStage(e.target.value))}>
              {STAGE_FILTERS.map((f) => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </Select>
          </div>
        }
        summary={<>共 {total} 条</>}
      />
      {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['称呼', '联系方式', '城市', '想办的事', '跟进态', '留资时间', '操作']}
        loading={loading ? (
          <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载咨询</div>
        ) : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            title="暂无咨询"
            description="访客在独立 Web 站里留下联系方式后，咨询会出现在这里；同时会发一封咨询邮件给顾问。"
          />
        ) : undefined}
      >
        {items.map((item) => {
          const info = stageInfo(item.stage)
          return (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[140px] min-w-[140px] max-w-[140px] px-4 py-3 ${stickyLeftTdCls}`}>
                <span className="truncate">{item.name || '-'}</span>
              </td>
              <td className="min-w-[150px] whitespace-nowrap px-4 py-3">{item.contact || '-'}</td>
              <td className="min-w-[100px] whitespace-nowrap px-4 py-3">{item.city || '-'}</td>
              <td className="min-w-[130px] whitespace-nowrap px-4 py-3">{item.intent || '-'}</td>
              <td className="min-w-[100px] whitespace-nowrap px-4 py-3">
                <Badge className={info.tone}>{info.label}</Badge>
              </td>
              <td className="min-w-[160px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
                {fmtTime(item.created_at)}
              </td>
              <td className={`min-w-[104px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button variant="ghost" size="sm" onClick={() => openDetail(item)}>
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
      {leadID && tenantUUID && (
        <LeadDrawer
          leadID={leadID}
          tenantUUID={tenantUUID}
          canOperate={canOperate}
          onClose={closeDetail}
          onFollowed={refresh}
        />
      )}
      {qrOpen && <ContactCardDialog onClose={() => setQrOpen(false)} />}
    </>
  )
}

function LeadDrawer({ leadID, tenantUUID, canOperate, onClose, onFollowed }: {
  leadID: string
  tenantUUID: string
  canOperate: boolean
  onClose: () => void
  onFollowed: () => void
}) {
  const navigate = useNavigate()
  const [detail, setDetail] = useState<WebLeadDetail | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState('')
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let cancelled = false
    WebLeadsApi.get(leadID, tenantUUID)
      .then((res) => { if (!cancelled) { setDetail(res); setError('') } })
      .catch((e: Error) => { if (!cancelled) setError(e.message) })
    return () => { cancelled = true }
  }, [leadID, tenantUUID, reload])

  const follow = useCallback(async (stage: 'contacted' | 'invalid') => {
    setBusy(true)
    try {
      await WebLeadsApi.follow(leadID, tenantUUID, stage, note.trim() || undefined)
      notifyOk(`已${FOLLOW_LABELS[stage].replace('标记', '')}`)
      setNote('')
      setReload((v) => v + 1)
      onFollowed()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [leadID, tenantUUID, note, onFollowed])

  const info = stageInfo(detail?.stage ?? '')
  // 向导化：new → 主按钮「标记已联系」；其余只剩查看关联单/标记无效
  // （2026-08-06 起本页不再转化，办理由用户在对话里自助发起）。
  const primaryFollow: 'contacted' | null =
    detail?.stage === 'new' ? 'contacted' : null

  return (
    <DrawerShell
      title={detail?.name || '咨询详情'}
      subtitle={detail ? `留资于 ${fmtTime(detail.created_at)} · 来源 ${detail.source || 'web'}` : ''}
      icon={<UserPlus size={16} />}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex items-center justify-between gap-2">
          <div className="flex flex-wrap items-center gap-2">
            {canOperate && primaryFollow && (
              <Button variant="primary" size="sm" disabled={busy} onClick={() => void follow(primaryFollow)}>
                {FOLLOW_LABELS[primaryFollow]}
              </Button>
            )}
            {detail?.converted_case_id && (
              detail.converted_case_kind === 'company_reg' ? (
                <Button variant="secondary" size="sm"
                  onClick={() => navigate(`/startup-agent-cases?case_id=${detail.converted_case_id}&tenant_uuid=${tenantUUID}`)}>
                  <ClipboardList size={14} /> 查看注册申请
                </Button>
              ) : (
                // 存量转化单（含海外）：办理单详情在企业注册申请页的海外 Tab
                <Button variant="secondary" size="sm"
                  onClick={() => navigate(`/startup-agent-cases?view=overseas&case_id=${detail.converted_case_id}&case_tenant=${tenantUUID}`)}>
                  <ClipboardList size={14} /> 查看办理单
                </Button>
              )
            )}
            {canOperate && detail && detail.stage !== 'invalid' && detail.stage !== 'converted' && (
              <Button variant="secondary" size="sm" disabled={busy} onClick={() => void follow('invalid')}>
                {FOLLOW_LABELS.invalid}
              </Button>
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
          <FormSection title="联系信息">
            <div className="grid grid-cols-2 gap-4">
              <Field label="称呼" value={detail.name || '-'} />
              <Field label="联系方式" value={detail.contact || '-'} />
              <Field label="城市" value={detail.city || '-'} />
              <Field label="想办的事" value={detail.intent || '-'} />
              <div>
                <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">跟进态</div>
                <div className="mt-0.5"><Badge className={info.tone}>{info.label}</Badge></div>
              </div>
              <Field label="来源渠道" value={detail.agent ? `${detail.source} · ${detail.agent}` : detail.source || 'web'} />
              <Field label="咨询 ID" value={detail.id} />
            </div>
            {detail.note && (
              <div className="mt-3">
                <Field label="用户补充" value={detail.note} />
              </div>
            )}
          </FormSection>

          <FormSection
            title="会话摘录"
            description="留资前用户在网页里聊过的最近几轮，跟进前先看一眼。"
          >
            {detail.chat_digest ? (
              <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap rounded-[8px] bg-[var(--color-bg-sub)] p-3 text-[13px] leading-[1.7] text-[var(--color-text)]">
                {detail.chat_digest}
              </pre>
            ) : (
              <div className="text-[13px] text-[var(--color-text-sub)]">未记录会话内容。</div>
            )}
          </FormSection>

          {canOperate && (
            <FormSection title="跟进备注" description="选填，随下方跟进动作一起记入时间线；用户侧不可见。">
              <FormField label="备注">
                <Input
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder="例如：已电话联系，约周三详聊"
                  maxLength={500}
                />
              </FormField>
            </FormSection>
          )}

          <FormSection title="跟进记录">
            {detail.events.length === 0 ? (
              <div className="text-[13px] text-[var(--color-text-sub)]">暂无记录。</div>
            ) : (
              <div>
                {detail.events.map((ev, i) => {
                  const payload = (ev.payload ?? {}) as Record<string, string>
                  const parts = [payload.stage ? stageInfo(payload.stage).label : '', payload.note ?? '']
                  return (
                    <CaseTimelineItem
                      key={`${ev.event_type}-${ev.received_at}-${i}`}
                      kind={ev.event_type === 'lead_followed' ? 'op' : 'user'}
                      label={eventLabel(ev.event_type)}
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
    </DrawerShell>
  )
}

// 顾问二维码维护（契约 §2.10）：换顾问只换图，Web 回执即时生效。
function ContactCardDialog({ onClose }: { onClose: () => void }) {
  const [card, setCard] = useState<WebContactCard>({ image_data_uri: '', note: '' })
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    let cancelled = false
    WebLeadsApi.getContactCard()
      .then((res) => { if (!cancelled) setCard(res) })
      .catch((e: Error) => { if (!cancelled) setError(e.message) })
    return () => { cancelled = true }
  }, [])

  const onSelect = useCallback((f: File) => {
    setError('')
    if (f.size > 300 * 1024) {
      setError('图片需小于 300KB，请压缩后再上传。')
      return
    }
    const reader = new FileReader()
    reader.onload = () => {
      setFile(f)
      setCard((c) => ({ ...c, image_data_uri: String(reader.result ?? '') }))
    }
    reader.onerror = () => setError('图片读取失败，请重试。')
    reader.readAsDataURL(f)
  }, [])

  const save = useCallback(async () => {
    setBusy(true)
    try {
      await WebLeadsApi.putContactCard(card)
      notifyOk('已保存，Web 端回执即时生效')
      onClose()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [card, onClose])

  const preview = useMemo(() => card.image_data_uri.trim(), [card.image_data_uri])

  return (
    <DialogShell
      title="顾问二维码"
      subtitle="展示在 Web 留资回执里，引导用户直接加顾问企微；换顾问只需换图，无需重新部署。"
      onClose={onClose}
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="primary" disabled={busy} onClick={() => void save()}>保存</Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
        <FileUploadPicker
          title="上传二维码"
          description="支持 PNG / JPG / WebP，需小于 300KB。留空并保存 = 清除二维码，回执退回纯文字。"
          accept="image/png,image/jpeg,image/webp"
          file={file}
          busy={busy}
          onSelect={onSelect}
          onClear={() => { setFile(null); setCard((c) => ({ ...c, image_data_uri: '' })) }}
        />
        {preview && (
          <div className="flex items-center gap-3">
            <img
              src={preview}
              alt="顾问二维码预览"
              className="h-[120px] w-[120px] rounded-[8px] border border-[var(--color-line)] object-contain"
            />
            <div className="text-[13px] text-[var(--color-text-sub)]">当前生效的二维码</div>
          </div>
        )}
        <FormField label="备注" hint="仅后台可见，例如顾问姓名，方便交接时确认是谁的码。">
          <Input
            value={card.note}
            onChange={(e) => setCard((c) => ({ ...c, note: e.target.value }))}
            placeholder="例如：顾问小张"
            maxLength={200}
          />
        </FormField>
      </div>
    </DialogShell>
  )
}
