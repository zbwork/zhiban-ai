import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { Copy, Edit3, ExternalLink, Eye, ImageIcon, RefreshCw } from 'lucide-react'

import {
  auth,
  SysUsers,
  SupportFeedback,
  type SupportFeedbackAttachmentURL,
  type SupportFeedbackCategory,
  type SupportFeedbackItem,
  type SupportFeedbackPriority,
  type SupportFeedbackStatus,
  type SysUser,
} from '../lib/api'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'
import { notifyError, notifyOk } from '../lib/toast'

const STATUS_LABEL: Record<SupportFeedbackStatus, string> = {
  open: '待处理',
  triaged: '已分诊',
  in_progress: '处理中',
  resolved: '已处理',
  closed: '已关闭',
}

const CATEGORY_LABEL: Record<SupportFeedbackCategory, string> = {
  usage_question: '使用咨询',
  bug: '疑似 bug',
  product_suggestion: '产品建议',
  account_access: '账号权限',
  performance: '性能问题',
  other: '其他',
}

const PRIORITY_LABEL: Record<SupportFeedbackPriority, string> = {
  low: '低',
  normal: '普通',
  high: '高',
  urgent: '紧急',
}

const STATUS_OPTIONS: Array<{ value: '' | SupportFeedbackStatus; label: string }> = [
  { value: '', label: '全部状态' },
  { value: 'open', label: STATUS_LABEL.open },
  { value: 'triaged', label: STATUS_LABEL.triaged },
  { value: 'in_progress', label: STATUS_LABEL.in_progress },
  { value: 'resolved', label: STATUS_LABEL.resolved },
  { value: 'closed', label: STATUS_LABEL.closed },
]

const CATEGORY_OPTIONS: Array<{ value: '' | SupportFeedbackCategory; label: string }> = [
  { value: '', label: '全部分类' },
  { value: 'usage_question', label: CATEGORY_LABEL.usage_question },
  { value: 'bug', label: CATEGORY_LABEL.bug },
  { value: 'product_suggestion', label: CATEGORY_LABEL.product_suggestion },
  { value: 'account_access', label: CATEGORY_LABEL.account_access },
  { value: 'performance', label: CATEGORY_LABEL.performance },
  { value: 'other', label: CATEGORY_LABEL.other },
]

const PRIORITY_OPTIONS: Array<{ value: '' | SupportFeedbackPriority; label: string }> = [
  { value: '', label: '全部优先级' },
  { value: 'urgent', label: PRIORITY_LABEL.urgent },
  { value: 'high', label: PRIORITY_LABEL.high },
  { value: 'normal', label: PRIORITY_LABEL.normal },
  { value: 'low', label: PRIORITY_LABEL.low },
]

const badgeTone: Record<string, string> = {
  open: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  triaged: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  in_progress: 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]',
  resolved: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  closed: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
  urgent: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
  high: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  normal: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
  low: 'bg-[var(--color-line-soft)] text-[var(--color-text-mute)]',
}

const readonlyFeedbackStatuses = new Set<SupportFeedbackStatus>(['resolved', 'closed'])
const DEFAULT_STATUS_FILTER: SupportFeedbackStatus = 'open'

export function SupportFeedbackPage() {
  const [items, setItems] = useState<SupportFeedbackItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [keyword, setKeyword] = useState('')
  const [status, setStatus] = useState<'' | SupportFeedbackStatus>(DEFAULT_STATUS_FILTER)
  const [category, setCategory] = useState('')
  const [priority, setPriority] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [editing, setEditing] = useState<SupportFeedbackItem | null>(null)

  useEffect(() => {
    let cancelled = false
    SupportFeedback.list({
      q: keyword || undefined,
      status: status || undefined,
      category: category || undefined,
      priority: priority || undefined,
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
  }, [keyword, status, category, priority, page, pageSize, tick])

  const summary = useMemo(() => `共 ${total} 条反馈`, [total])
  const resetPage = (fn: () => void) => {
    setLoading(true)
    setPage(1)
    fn()
  }
  const refresh = () => {
    setLoading(true)
    setTick((v) => v + 1)
  }

  return (
    <div>
      <PageHeader
        title="问题反馈"
        subtitle="查看知办客服收集的软件使用问题、疑似 bug 和产品建议，按状态持续跟进。"
      />

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索标题 / 描述"
          />
        }
        filters={
          <>
            <div className="w-[140px]">
              <Select
                value={status}
                onChange={(e) => resetPage(() => setStatus(e.target.value as '' | SupportFeedbackStatus))}
              >
                {STATUS_OPTIONS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
            <div className="w-[150px]">
              <Select value={category} onChange={(e) => resetPage(() => setCategory(e.target.value))}>
                {CATEGORY_OPTIONS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
            <div className="w-[140px]">
              <Select value={priority} onChange={(e) => resetPage(() => setPriority(e.target.value))}>
                {PRIORITY_OPTIONS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
              </Select>
            </div>
          </>
        }
        summary={summary}
        actions={
          <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新问题反馈">
            <RefreshCw size={14} />
          </Button>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['问题', '租户', '用户', '分类', '优先级', '状态', '处理人', '来源', '创建时间', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载问题反馈</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState title="暂无问题反馈" description="用户通过知办客服反馈后，会出现在这里。" />
        ) : undefined}
      >
        {!loading && items.map((item) => {
          const isReadonly = readonlyFeedbackStatuses.has(item.status)
          const actionLabel = isReadonly ? '查看' : '处理'
          const ActionIcon = isReadonly ? Eye : Edit3
          const feedbackText = item.description || item.title || '-'
          return (
            <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[420px] min-w-[420px] max-w-[420px] px-4 py-3 ${stickyLeftTdCls}`} title={feedbackText}>
                <div className="truncate font-medium text-[var(--color-text)]">{feedbackText}</div>
              </td>
              <td className="min-w-[180px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={String(item.tenant_name || item.tenant_id)}>
                <div className="max-w-[180px] truncate">{item.tenant_name || item.tenant_id}</div>
              </td>
              <td className="min-w-[180px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.account_name || '-'}>
                <div className="max-w-[180px] truncate">{item.account_name || '-'}</div>
              </td>
              <td className="min-w-[128px] whitespace-nowrap px-4 py-3">{CATEGORY_LABEL[item.category] || item.category}</td>
              <td className="min-w-[116px] whitespace-nowrap px-4 py-3">
                <Badge className={badgeTone[item.priority]}>{PRIORITY_LABEL[item.priority] || item.priority}</Badge>
              </td>
              <td className="min-w-[116px] whitespace-nowrap px-4 py-3">
                <Badge className={badgeTone[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
              </td>
              <td className="min-w-[144px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.assigned_to_name || '未指派'}>
                <div className="max-w-[144px] truncate">{item.assigned_to_name || '未指派'}</div>
              </td>
              <td className="min-w-[128px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{item.agent_name || '知办客服'}</td>
              <td className="min-w-[180px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
              <td className={`min-w-[112px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setEditing(item)}
                  title={actionLabel}
                  aria-label={`${actionLabel}问题反馈`}
                >
                  <ActionIcon size={14} />
                  {actionLabel}
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

      {editing && (
        <SupportFeedbackDrawer
          item={editing}
          onClose={() => setEditing(null)}
          onSaved={(next) => {
            setEditing(null)
            setItems((prev) => prev.map((it) => it.uuid === next.uuid ? next : it))
            refresh()
          }}
        />
      )}
    </div>
  )
}

function SupportFeedbackDrawer({
  item,
  onClose,
  onSaved,
}: {
  item: SupportFeedbackItem
  onClose: () => void
  onSaved: (item: SupportFeedbackItem) => void
}) {
  const [status, setStatus] = useState<SupportFeedbackStatus>(item.status)
  const [priority, setPriority] = useState<SupportFeedbackPriority>(item.priority)
  const [assignedTo, setAssignedTo] = useState(item.assigned_to ? String(item.assigned_to) : '')
  const [sysUsers, setSysUsers] = useState<SysUser[]>([])
  const [handlerNote, setHandlerNote] = useState(item.handler_note || '')
  const [saving, setSaving] = useState(false)
  const [copying, setCopying] = useState(false)
  const [err, setErr] = useState('')
  const feedbackContext = getFeedbackContext(item)
  const localCodingReport = getLocalCodingReport(item)

  useEffect(() => {
    let cancelled = false
    SysUsers.list('', 200, 0).then((resp) => {
      if (cancelled) return
      setSysUsers(resp.items || [])
    }).catch((e: Error) => {
      if (!cancelled) setErr(e.message)
    })
    return () => { cancelled = true }
  }, [])

  const submit = async () => {
    setSaving(true)
    setErr('')
    try {
      const resp = await SupportFeedback.update(item.uuid, {
        status,
        priority,
        assigned_to: assignedTo ? Number(assignedTo) : null,
        handler_note: handlerNote,
      })
      onSaved(resp.item)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const copyForCodex = async () => {
    setCopying(true)
    setErr('')
    try {
      const result = await copySupportFeedbackForCodex(item)
      notifyOk(result.imageCount > 0
        ? `已复制问题文本和 ${result.imageCount} 张图片`
        : '已复制问题文本和附件链接')
      if (result.imageFailures > 0) {
        notifyError(`${result.imageFailures} 个图片附件未能写入剪贴板，已保留短时链接`, 3500)
      }
    } catch (e) {
      const message = (e as Error).message || '复制失败'
      setErr(message)
      notifyError(message)
    } finally {
      setCopying(false)
    }
  }

  return (
    <DrawerShell
      title="处理问题反馈"
      subtitle={item.title}
      onClose={onClose}
      width="md"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button onClick={submit} disabled={saving}>{saving ? '保存中' : '保存'}</Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}

        <div className="flex items-center justify-between gap-3 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2">
          <div className="min-w-0 text-[12px] leading-relaxed text-[var(--color-text-sub)]">
            一键复制反馈文本和附件，便于粘贴到 Codex 排查。
          </div>
          <Button variant="secondary" size="sm" onClick={copyForCodex} disabled={copying}>
            <Copy size={14} />
            {copying ? '复制中' : '复制给 Codex'}
          </Button>
        </div>

        <FormSection title="反馈内容">
          <div className="space-y-4">
            <div className="grid gap-2 sm:grid-cols-2">
              <InfoTile label="租户" value={item.tenant_name || String(item.tenant_id)} />
              <InfoTile label="用户" value={item.account_name || '-'} />
              <InfoTile label="来源" value={item.agent_name || '知办客服'} />
              <InfoTile label="页面" value={item.page_url || '-'} />
            </div>
            <FeedbackTextBlock title="用户反馈" text={item.description || '-'} />
            {feedbackContext.excerpt && (
              <FeedbackContextBlock
                text={feedbackContext.excerpt}
                description={contextRangeLabel(feedbackContext.range)}
              />
            )}
          </div>
        </FormSection>

        {localCodingReport && (
          <FormSection
            title="本地开发工具现场"
            titleHint="用户在知办「本地开发工具」页面点「发送给支持」时自动带上的本机状态，不含配置内容与令牌。"
          >
            <LocalCodingReportBlock report={localCodingReport} />
          </FormSection>
        )}

        {item.attachments && item.attachments.length > 0 && (
          <FormSection title="附件清单">
            <div className="space-y-2">
              {item.attachments.map((attachment, index) => (
                <AttachmentRow
                  key={attachmentKey(attachment, index)}
                  feedbackUuid={item.uuid}
                  attachment={attachment}
                />
              ))}
            </div>
            <div className="mt-2 text-[12px] text-[var(--color-text-mute)]">
              图片附件通过后台校验后签发短时预览链接；非图片附件保留引用信息。
            </div>
          </FormSection>
        )}

        <FormSection title="处理状态">
          <div className="grid gap-3 sm:grid-cols-2">
            <FormField label="状态">
              <Select value={status} onChange={(e) => setStatus(e.target.value as SupportFeedbackStatus)}>
                {STATUS_OPTIONS.filter((it) => it.value).map((it) => (
                  <option key={it.value} value={it.value}>{it.label}</option>
                ))}
              </Select>
            </FormField>
            <FormField label="处理人">
              <Select value={assignedTo} onChange={(e) => setAssignedTo(e.target.value)}>
                <option value="">未指派</option>
                {assignedTo && !sysUsers.some((user) => String(user.account_id) === assignedTo) && (
                  <option value={assignedTo}>{item.assigned_to_name || `账号 ${assignedTo}`}</option>
                )}
                {sysUsers.map((user) => (
                  <option key={user.id} value={user.account_id} disabled={user.status !== 'active'}>
                    {sysUserLabel(user)}
                  </option>
                ))}
              </Select>
            </FormField>
          </div>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <FormField label="优先级">
              <Select value={priority} onChange={(e) => setPriority(e.target.value as SupportFeedbackPriority)}>
                {PRIORITY_OPTIONS.filter((it) => it.value).map((it) => (
                  <option key={it.value} value={it.value}>{it.label}</option>
                ))}
              </Select>
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="处理备注">
              <textarea
                value={handlerNote}
                rows={5}
                onChange={(e) => setHandlerNote(e.target.value)}
                className={textareaCls}
                placeholder="记录排查结论、转交对象或用户沟通结果"
              />
            </FormField>
          </div>
        </FormSection>
      </div>
    </DrawerShell>
  )
}

function sysUserLabel(user: SysUser) {
  const identity = user.email || user.username || user.phone
  const suffix = user.status === 'active' ? '' : `（${user.status}）`
  return `${user.display_name || identity || `账号 ${user.account_id}`}${identity && user.display_name ? ` / ${identity}` : ''}${suffix}`
}

function InfoTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2">
      <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">{label}</div>
      <div className="mt-0.5 min-w-0 truncate text-[13px] font-medium text-[var(--color-text)]">{value}</div>
    </div>
  )
}

function FeedbackTextBlock({
  title,
  text,
  description,
  muted,
}: {
  title: string
  text: string
  description?: string
  muted?: boolean
}) {
  return (
    <div className="rounded-md border border-[var(--color-line-soft)] bg-white">
      <div className="flex items-center justify-between gap-3 border-b border-[var(--color-line-soft)] px-3 py-2">
        <div className="text-[13px] font-semibold text-[var(--color-text)]">{title}</div>
        {description && <div className="truncate text-[12px] text-[var(--color-text-mute)]">{description}</div>}
      </div>
      <div className={`max-h-[220px] overflow-auto whitespace-pre-wrap px-3 py-3 text-[13px] leading-6 ${muted ? 'bg-[var(--color-bg-sub)] text-[var(--color-text-sub)]' : 'text-[var(--color-text)]'}`}>
        {text}
      </div>
    </div>
  )
}

type ContextRole = 'user' | 'agent' | 'system'

type ContextMessage = {
  role: ContextRole
  text: string
}

function FeedbackContextBlock({ text, description }: { text: string; description?: string }) {
  const messages = parseContextMessages(text)
  return (
    <div className="rounded-md border border-[var(--color-line-soft)] bg-white">
      <div className="flex items-center justify-between gap-3 border-b border-[var(--color-line-soft)] px-3 py-2">
        <div className="text-[13px] font-semibold text-[var(--color-text)]">相关上下文</div>
        {description && <div className="truncate text-[12px] text-[var(--color-text-mute)]">{description}</div>}
      </div>
      <div className="max-h-[300px] space-y-3 overflow-auto bg-[var(--color-bg-sub)] px-3 py-3">
        {messages.map((message, index) => (
          <ContextMessageBubble key={`${message.role}-${index}`} message={message} />
        ))}
      </div>
    </div>
  )
}

function ContextMessageBubble({ message }: { message: ContextMessage }) {
  if (message.role === 'system') {
    return (
      <div className="rounded-md border border-[var(--color-line-soft)] bg-white px-3 py-2 text-[12px] leading-6 text-[var(--color-text-sub)]">
        {message.text}
      </div>
    )
  }
  const isAgent = message.role === 'agent'
  return (
    <div className={`flex ${isAgent ? 'justify-start' : 'justify-end'}`}>
      <div className={`max-w-[86%] rounded-md border px-3 py-2 ${isAgent ? 'border-[var(--color-line-soft)] bg-white' : 'border-[var(--color-brand-line)] bg-[var(--color-brand-soft)]'}`}>
        <div className={`mb-1 text-[12px] font-medium ${isAgent ? 'text-[var(--color-brand)]' : 'text-[var(--color-text-sub)]'}`}>
          {isAgent ? 'Agent' : '用户'}
        </div>
        <div className="whitespace-pre-wrap break-words text-[13px] leading-6 text-[var(--color-text)]">
          {message.text}
        </div>
      </div>
    </div>
  )
}

function Badge({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] ${className || ''}`}>
      {children}
    </span>
  )
}

type NormalizedAttachment = {
  type: string
  file_uuid: string
  name: string
  mime: string
  size: number
  url: string
}

type CopyAttachment = NormalizedAttachment & {
  signed_url: string
  content_url: string
}

type FeedbackContext = {
  excerpt: string
  range: Record<string, unknown> | null
}

// ── 本地开发工具现场（知办 App「本地开发工具」页面「发送给支持」）──
// 结构见 docs/contracts/local-coding-tools-contract.md「诊断一键上报」：
// client_info.kind = local_coding_tools，targets[] 是该厂商两个形态的安装与配置状态，
// failure 是最近一次失败记录（含中转站原话）。只渲染已知字段，未知字段忽略。

type LocalCodingTargetReport = {
  target: string
  uiState: string
  installedVersion: string
  installSource: string
  availableVersion: string
  minimumVersion: string
  detectErrorCode: string
  currentService: string
  switched: boolean
  drifted: boolean
  verificationLevel: string
  lastVerifiedAt: string
  upgradeAvailable: boolean
  configErrorCode: string
}

type LocalCodingFailure = {
  stage: string
  kind: string
  errorCode: string
  errorDetail: string
  occurredAt: string
  suggestions: string[]
}

type LocalCodingReport = {
  vendor: string
  reportedTarget: string
  appVersion: string
  platform: string
  platformVersion: string
  environment: string
  bridgeVersion: string
  proxyNeedsFix: boolean
  authorizationConnected: boolean
  reportedAt: string
  targets: LocalCodingTargetReport[]
  failure: LocalCodingFailure | null
}

const LOCAL_CODING_VENDOR_LABEL: Record<string, string> = { codex: 'Codex', claude: 'Claude' }
const LOCAL_CODING_TARGET_LABEL: Record<string, string> = {
  codex_cli: 'Codex 命令行',
  codex_desktop: 'Codex 桌面端',
  claude_cli: 'Claude Code 命令行',
  claude_desktop: 'Claude 桌面端',
}
const LOCAL_CODING_UI_STATE_LABEL: Record<string, string> = {
  notInstalled: '未安装',
  installedUnmanaged: '已安装',
  configuredUnverified: '已安装',
  ready: '已安装',
  repairable: '安装已损坏',
  unsupported: '暂不支持',
}
const LOCAL_CODING_SERVICE_LABEL: Record<string, string> = {
  zhiban: '知办模型 API',
  official: '官方服务',
  unknown: '未知',
}
const LOCAL_CODING_SOURCE_LABEL: Record<string, string> = {
  official: '官方位置',
  npm: 'npm',
  homebrew: 'Homebrew',
  unknown: '未知',
}
const LOCAL_CODING_PLATFORM_LABEL: Record<string, string> = { macos: 'macOS', windows: 'Windows' }

function localCodingLabel(map: Record<string, string>, value: string) {
  return value ? map[value] || value : '-'
}

function booleanValue(value: unknown) {
  return value === true
}

function getLocalCodingReport(item: SupportFeedbackItem): LocalCodingReport | null {
  const info = item.client_info
  if (!info || typeof info !== 'object') return null
  const raw = info as Record<string, unknown>
  if (raw.kind !== 'local_coding_tools') return null
  const targets = Array.isArray(raw.targets) ? raw.targets : []
  const failureRaw = raw.failure && typeof raw.failure === 'object' ? (raw.failure as Record<string, unknown>) : null
  return {
    vendor: stringValue(raw.vendor),
    reportedTarget: stringValue(raw.reported_target),
    appVersion: stringValue(raw.app_version),
    platform: stringValue(raw.platform),
    platformVersion: stringValue(raw.platform_version),
    environment: stringValue(raw.environment),
    bridgeVersion: stringValue(raw.bridge_version),
    proxyNeedsFix: booleanValue(raw.proxy_needs_fix),
    authorizationConnected: booleanValue(raw.authorization_connected),
    reportedAt: stringValue(raw.reported_at),
    targets: targets.map((entry) => {
      const t = (entry && typeof entry === 'object' ? entry : {}) as Record<string, unknown>
      return {
        target: stringValue(t.target),
        uiState: stringValue(t.ui_state),
        installedVersion: stringValue(t.installed_version),
        installSource: stringValue(t.install_source),
        availableVersion: stringValue(t.available_version),
        minimumVersion: stringValue(t.minimum_version),
        detectErrorCode: stringValue(t.detect_error_code),
        currentService: stringValue(t.current_service),
        switched: booleanValue(t.switched),
        drifted: booleanValue(t.drifted),
        verificationLevel: stringValue(t.verification_level),
        lastVerifiedAt: stringValue(t.last_verified_at),
        upgradeAvailable: booleanValue(t.upgrade_available),
        configErrorCode: stringValue(t.config_error_code),
      }
    }),
    failure: failureRaw
      ? {
          stage: stringValue(failureRaw.stage),
          kind: stringValue(failureRaw.kind),
          errorCode: stringValue(failureRaw.error_code),
          errorDetail: stringValue(failureRaw.error_detail),
          occurredAt: stringValue(failureRaw.occurred_at),
          suggestions: Array.isArray(failureRaw.suggestions)
            ? failureRaw.suggestions.filter((s): s is string => typeof s === 'string')
            : [],
        }
      : null,
  }
}

function localCodingSwitchLabel(target: LocalCodingTargetReport) {
  if (!target.switched) return '未切换'
  if (target.drifted) return '已切换 · 配置已改动'
  if (target.upgradeAvailable) return '已切换 · 待按新版本重写'
  return '已切换'
}

function localCodingFailureText(failure: LocalCodingFailure) {
  const lines = [
    `阶段: ${failure.stage || '-'} · 类型: ${failure.kind || '-'}`,
    `错误码: ${failure.errorCode || '-'}`,
  ]
  if (failure.errorDetail) lines.push(`中转站返回: ${failure.errorDetail}`)
  if (failure.suggestions.length > 0) lines.push(`建议: ${failure.suggestions.join('；')}`)
  return lines.join('\n')
}

/// 复制给 Codex 时的纯文本版本，与抽屉里显示的信息一致。
function localCodingReportLines(report: LocalCodingReport) {
  const lines = [
    `工具: ${localCodingLabel(LOCAL_CODING_VENDOR_LABEL, report.vendor)} · ${localCodingLabel(LOCAL_CODING_TARGET_LABEL, report.reportedTarget)}`,
    `知办版本: ${report.appVersion || '-'} · 系统: ${localCodingLabel(LOCAL_CODING_PLATFORM_LABEL, report.platform)} ${report.platformVersion}`.trim(),
    `环境: ${report.environment || '-'} · 连接组件: ${report.bridgeVersion || '-'} · 设备授权: ${report.authorizationConnected ? '已连接' : '未连接'} · 系统代理: ${report.proxyNeedsFix ? '需设例外' : '正常'}`,
  ]
  if (report.failure) {
    lines.push('失败记录:', localCodingFailureText(report.failure))
  } else {
    lines.push('失败记录: 无')
  }
  report.targets.forEach((target) => {
    lines.push(
      [
        localCodingLabel(LOCAL_CODING_TARGET_LABEL, target.target),
        localCodingLabel(LOCAL_CODING_UI_STATE_LABEL, target.uiState),
        target.installedVersion ? `版本=${target.installedVersion}` : '',
        target.availableVersion ? `可升级到=${target.availableVersion}` : '',
        target.installSource ? `来源=${localCodingLabel(LOCAL_CODING_SOURCE_LABEL, target.installSource)}` : '',
        `服务=${localCodingLabel(LOCAL_CODING_SERVICE_LABEL, target.currentService)}`,
        localCodingSwitchLabel(target),
        target.verificationLevel ? `验证=${target.verificationLevel}` : '',
        target.configErrorCode || target.detectErrorCode ? `错误码=${target.configErrorCode || target.detectErrorCode}` : '',
      ]
        .filter(Boolean)
        .join(' | '),
    )
  })
  return lines
}

function LocalCodingReportBlock({ report }: { report: LocalCodingReport }) {
  const failure = report.failure
  return (
    <div className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-2">
        <InfoTile
          label="工具"
          value={`${localCodingLabel(LOCAL_CODING_VENDOR_LABEL, report.vendor)} · ${localCodingLabel(LOCAL_CODING_TARGET_LABEL, report.reportedTarget)}`}
        />
        <InfoTile label="知办版本" value={report.appVersion || '-'} />
        <InfoTile
          label="系统"
          value={`${localCodingLabel(LOCAL_CODING_PLATFORM_LABEL, report.platform)} ${report.platformVersion}`.trim()}
        />
        <InfoTile label="环境" value={report.environment || '-'} />
        <InfoTile label="连接组件版本" value={report.bridgeVersion || '-'} />
        <InfoTile label="设备授权" value={report.authorizationConnected ? '已连接' : '未连接'} />
        <InfoTile label="系统代理" value={report.proxyNeedsFix ? '会拦截知办中转站，需设例外' : '正常'} />
        <InfoTile label="上报时间" value={report.reportedAt ? formatTime(report.reportedAt) : '-'} />
      </div>
      {failure ? (
        <FeedbackTextBlock
          title="失败记录"
          description={failure.occurredAt ? formatTime(failure.occurredAt) : undefined}
          text={localCodingFailureText(failure)}
        />
      ) : (
        <FeedbackTextBlock title="失败记录" text="上报时没有失败记录" muted />
      )}
      <DataTable
        stickyFirstCol
        headers={['形态', '软件状态', '版本', '可升级到', '来源', '当前服务', '切换记录', '验证级别', '错误码']}
        empty={report.targets.length === 0 ? (
          <div className="px-4 py-6 text-center text-[13px] text-[var(--color-text-sub)]">上报里没有形态状态</div>
        ) : undefined}
      >
        {report.targets.map((target) => (
          <tr key={target.target || target.installedVersion} className="group hover:bg-[var(--color-bg-sub)]">
            <td className={`px-4 py-2 whitespace-nowrap ${stickyLeftTdCls}`}>
              {localCodingLabel(LOCAL_CODING_TARGET_LABEL, target.target)}
            </td>
            <td className="px-4 py-2 whitespace-nowrap">{localCodingLabel(LOCAL_CODING_UI_STATE_LABEL, target.uiState)}</td>
            <td className="px-4 py-2 whitespace-nowrap">{target.installedVersion || '-'}</td>
            <td className="px-4 py-2 whitespace-nowrap">{target.availableVersion || '-'}</td>
            <td className="px-4 py-2 whitespace-nowrap">{localCodingLabel(LOCAL_CODING_SOURCE_LABEL, target.installSource)}</td>
            <td className="px-4 py-2 whitespace-nowrap">{localCodingLabel(LOCAL_CODING_SERVICE_LABEL, target.currentService)}</td>
            <td className="px-4 py-2 whitespace-nowrap">{localCodingSwitchLabel(target)}</td>
            <td className="px-4 py-2 whitespace-nowrap">{target.verificationLevel || '-'}</td>
            <td className="px-4 py-2 whitespace-nowrap font-mono text-[12px]">
              {target.configErrorCode || target.detectErrorCode || '-'}
            </td>
          </tr>
        ))}
      </DataTable>
    </div>
  )
}

function getFeedbackContext(item: SupportFeedbackItem): FeedbackContext {
  const info = item.client_info
  if (!info || typeof info !== 'object') {
    return { excerpt: '', range: null }
  }
  const raw = info as Record<string, unknown>
  const range = raw.context_range && typeof raw.context_range === 'object'
    ? raw.context_range as Record<string, unknown>
    : null
  return {
    excerpt: stringValue(raw.context_excerpt),
    range,
  }
}

function contextRangeLabel(range: Record<string, unknown> | null) {
  if (!range) return ''
  const from = numberValue(range.from_message_id)
  const to = numberValue(range.to_message_id)
  const previous = stringValue(range.previous_feedback_uuid)
  const parts: string[] = []
  if (from > 0 && to > 0) {
    parts.push(`消息 ${from}-${to}`)
  }
  if (previous) {
    parts.push('上次反馈之后')
  }
  return parts.join(' · ')
}

function parseContextMessages(text: string): ContextMessage[] {
  const messages: ContextMessage[] = []
  let current: ContextMessage | null = null
  const flush = () => {
    if (current && current.text.trim()) {
      messages.push({ ...current, text: current.text.trim() })
    }
    current = null
  }

  text.split(/\r?\n/).forEach((rawLine) => {
    const line = rawLine.trimEnd()
    const roleLine = parseContextRoleLine(line)
    if (roleLine) {
      flush()
      current = { role: roleLine.role, text: roleLine.text }
      return
    }
    if (!line.trim() && !current) return
    if (!current) {
      current = { role: 'system', text: line }
      return
    }
    current.text = current.text ? `${current.text}\n${line}` : line
  })
  flush()

  return messages.length > 0 ? messages : [{ role: 'system', text }]
}

function parseContextRoleLine(line: string): { role: ContextRole; text: string } | null {
  const bracketMatch = line.match(/^\s*\[(user|human|agent|assistant|system)\]\s*(.*)$/i)
  if (bracketMatch) {
    return { role: mapContextRole(bracketMatch[1]), text: bracketMatch[2] || '-' }
  }
  const colonMatch = line.match(/^\s*(用户|user|human|agent|assistant|助手|客服|知办客服|系统|system)\s*[：:]\s*(.*)$/i)
  if (colonMatch) {
    return { role: mapContextRole(colonMatch[1]), text: colonMatch[2] || '-' }
  }
  return null
}

function mapContextRole(value: string): ContextRole {
  const normalized = value.toLowerCase()
  if (normalized === 'user' || normalized === 'human' || value === '用户') return 'user'
  if (normalized === 'system' || value === '系统') return 'system'
  return 'agent'
}

function AttachmentRow({ feedbackUuid, attachment }: { feedbackUuid: string; attachment: unknown }) {
  const item = normalizeAttachment(attachment)
  const isImage = item.type === 'image' || item.mime.toLowerCase().startsWith('image/')
  const shouldPreview = isImage && Boolean(item.file_uuid)
  const [preview, setPreview] = useState<SupportFeedbackAttachmentURL | null>(null)
  const [loading, setLoading] = useState(shouldPreview)
  const [err, setErr] = useState('')
  const [imageBroken, setImageBroken] = useState(false)

  useEffect(() => {
    let mounted = true
    if (!shouldPreview) {
      return () => {
        mounted = false
      }
    }
    SupportFeedback.previewAttachment(feedbackUuid, item.file_uuid)
      .then((resp) => {
        if (!mounted) return
        setPreview(resp)
      })
      .catch((error) => {
        if (!mounted) return
        setErr(error instanceof Error ? error.message : '图片预览地址获取失败')
      })
      .finally(() => {
        if (!mounted) return
        setLoading(false)
      })
    return () => {
      mounted = false
    }
  }, [feedbackUuid, shouldPreview, item.file_uuid])

  return (
    <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2">
      <div className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          {isImage && <ImageIcon size={16} className="shrink-0 text-[var(--color-brand)]" />}
          <div className="min-w-0 truncate text-[13px] font-medium text-[var(--color-text)]">
            {item.name || item.file_uuid || '未命名附件'}
          </div>
        </div>
        <Badge className="bg-[var(--color-line-soft)] text-[var(--color-text-sub)]">
          {item.type || 'file'}
        </Badge>
      </div>
      <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-[var(--color-text-mute)]">
        {item.mime && <span>{item.mime}</span>}
        {item.size > 0 && <span>{formatBytes(item.size)}</span>}
        {item.file_uuid && <span className="font-mono">{item.file_uuid}</span>}
      </div>
      {isImage && (
        <div className="mt-3 overflow-hidden rounded-md border border-[var(--color-line-soft)] bg-white">
          {preview?.url && !imageBroken ? (
            <>
              <div className="flex max-h-[260px] items-center justify-center bg-[var(--color-bg-sub)]">
                <img
                  src={preview.url}
                  alt={item.name || '反馈图片'}
                  className="max-h-[260px] w-full object-contain"
                  onError={() => setImageBroken(true)}
                />
              </div>
              <div className="flex items-center justify-end border-t border-[var(--color-line-soft)] bg-white px-3 py-2">
                <a
                  href={preview.url}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex h-8 items-center gap-1.5 rounded-md px-2 text-[12px] font-medium text-[var(--color-brand)] hover:bg-[var(--color-brand-soft)]"
                >
                  <ExternalLink size={14} />
                  打开原图
                </a>
              </div>
            </>
          ) : (
            <div className="flex min-h-[120px] items-center justify-center px-3 py-4 text-[12px] text-[var(--color-text-mute)]">
              {loading ? '正在加载图片预览' : err || (imageBroken ? '图片源暂不可用，请确认原始附件对象仍存在' : '暂无图片预览')}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function normalizeAttachment(value: unknown): NormalizedAttachment {
  if (!value || typeof value !== 'object') {
    return { type: '', file_uuid: '', name: '', mime: '', size: 0, url: '' }
  }
  const raw = value as Record<string, unknown>
  return {
    type: stringValue(raw.type),
    file_uuid: stringValue(raw.file_uuid || raw.fileUuid || raw.drive_file_uuid || raw.driveFileUuid),
    name: stringValue(raw.name || raw.file_name || raw.fileName),
    mime: stringValue(raw.mime || raw.mime_type || raw.mimeType),
    size: numberValue(raw.size || raw.file_size || raw.fileSize || raw.size_bytes || raw.sizeBytes),
    url: stringValue(raw.url || raw.preview_url || raw.previewUrl || raw.download_url || raw.downloadUrl),
  }
}

function attachmentKey(value: unknown, index: number) {
  const item = normalizeAttachment(value)
  return item.file_uuid || `${item.name}-${index}`
}

function stringValue(value: unknown) {
  return typeof value === 'string' ? value : ''
}

function numberValue(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}

function formatTime(value: string) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString('zh-CN', { hour12: false })
}

async function copySupportFeedbackForCodex(item: SupportFeedbackItem): Promise<{ imageCount: number; imageFailures: number }> {
  const attachments = await resolveCopyAttachments(item)
  const text = buildCodexFeedbackText(item, attachments)
  const images = await loadClipboardImages(attachments)

  if (images.length > 0 && navigator.clipboard?.write && typeof ClipboardItem !== 'undefined') {
    try {
      const textItem = new ClipboardItem({
        'text/plain': new Blob([text], { type: 'text/plain' }),
      })
      const imageItems = images.map((image) => new ClipboardItem({
        [image.blob.type || 'image/png']: image.blob,
      }))
      await navigator.clipboard.write([textItem, ...imageItems])
      return { imageCount: images.length, imageFailures: imageAttachmentCount(attachments) - images.length }
    } catch {
      await writeClipboardText(text)
      return { imageCount: 0, imageFailures: imageAttachmentCount(attachments) }
    }
  }

  await writeClipboardText(text)
  return { imageCount: 0, imageFailures: imageAttachmentCount(attachments) }
}

async function resolveCopyAttachments(item: SupportFeedbackItem): Promise<CopyAttachment[]> {
  const raw = item.attachments || []
  const normalized = raw.map((attachment) => normalizeAttachment(attachment))
  return Promise.all(normalized.map(async (attachment) => {
    if (!attachment.file_uuid) {
      return { ...attachment, signed_url: attachment.url, content_url: '' }
    }
    const isImage = isImageAttachment(attachment)
    const contentURL = SupportFeedback.attachmentContentURL(item.uuid, attachment.file_uuid)
    try {
      const signed = isImage
        ? await SupportFeedback.previewAttachment(item.uuid, attachment.file_uuid)
        : await SupportFeedback.downloadAttachment(item.uuid, attachment.file_uuid)
      return { ...attachment, signed_url: signed.url || attachment.url, content_url: contentURL }
    } catch {
      return { ...attachment, signed_url: attachment.url, content_url: contentURL }
    }
  }))
}

function buildCodexFeedbackText(item: SupportFeedbackItem, attachments: CopyAttachment[]) {
  const feedbackContext = getFeedbackContext(item)
  const lines = [
    '【知办AI 问题反馈】',
    `标题: ${item.title || '-'}`,
    `租户: ${item.tenant_name || item.tenant_id || '-'}`,
    `用户: ${item.account_name || item.account_id || '-'}`,
    `来源: ${item.agent_name || '知办客服'}`,
    `分类: ${CATEGORY_LABEL[item.category] || item.category || '-'}`,
    `优先级: ${PRIORITY_LABEL[item.priority] || item.priority || '-'}`,
    `状态: ${STATUS_LABEL[item.status] || item.status || '-'}`,
    `页面: ${item.page_url || '-'}`,
    `创建时间: ${formatTime(item.created_at)}`,
    '',
    '用户反馈:',
    item.description || '-',
  ]

  if (feedbackContext.excerpt) {
    lines.push('', '相关上下文:', feedbackContext.excerpt)
  }

  const localCodingReport = getLocalCodingReport(item)
  if (localCodingReport) {
    lines.push('', '本地开发工具现场:', ...localCodingReportLines(localCodingReport))
  }

  if (attachments.length > 0) {
    lines.push('', '附件:')
    attachments.forEach((attachment, index) => {
      const parts = [
        `${index + 1}. ${attachment.name || attachment.file_uuid || '未命名附件'}`,
        attachment.type ? `类型=${attachment.type}` : '',
        attachment.mime ? `MIME=${attachment.mime}` : '',
        attachment.size > 0 ? `大小=${formatBytes(attachment.size)}` : '',
        attachment.file_uuid ? `file_uuid=${attachment.file_uuid}` : '',
      ].filter(Boolean)
      lines.push(parts.join(' | '))
      if (attachment.signed_url) {
        lines.push(`   访问链接: ${attachment.signed_url}`)
      }
    })
  } else {
    lines.push('', '附件: 无')
  }

  lines.push('', '请根据以上反馈和附件截图分析问题，并给出修复建议或代码改动。')
  return lines.join('\n')
}

async function loadClipboardImages(attachments: CopyAttachment[]) {
  const images: Array<{ attachment: CopyAttachment; blob: Blob }> = []
  for (const attachment of attachments) {
    if (!isImageAttachment(attachment)) continue
    try {
      const blob = await fetchClipboardImageBlob(attachment)
      if (!blob.type.startsWith('image/')) continue
      images.push({ attachment, blob })
    } catch {
      // 文本里已经带短时链接；图片二进制复制失败不阻断整体复制。
    }
  }
  return images
}

async function fetchClipboardImageBlob(attachment: CopyAttachment) {
  const headers: Record<string, string> = {}
  const token = auth.token()
  if (token) headers.Authorization = `Bearer ${token}`

  if (attachment.content_url) {
    const resp = await fetch(attachment.content_url, { headers })
    if (resp.ok) return resp.blob()
  }
  if (!attachment.signed_url) {
    throw new Error('attachment url missing')
  }
  const resp = await fetch(attachment.signed_url)
  if (!resp.ok) {
    throw new Error(`attachment fetch failed: ${resp.status}`)
  }
  return resp.blob()
}

function imageAttachmentCount(attachments: CopyAttachment[]) {
  return attachments.filter((attachment) => isImageAttachment(attachment)).length
}

function isImageAttachment(attachment: NormalizedAttachment) {
  return attachment.type === 'image' || attachment.mime.toLowerCase().startsWith('image/')
}

async function writeClipboardText(text: string) {
  if (!navigator.clipboard?.writeText) {
    throw new Error('当前浏览器不支持写入剪贴板')
  }
  await navigator.clipboard.writeText(text)
}

const textareaCls = 'min-h-[120px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-relaxed text-[var(--color-text)] outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]'
