import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { Edit3, ExternalLink, Eye, RefreshCw } from 'lucide-react'

import {
  MarketingLeads,
  SysUsers,
  type MarketingLeadItem,
  type MarketingLeadStatus,
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

const STATUS_LABEL: Record<MarketingLeadStatus, string> = {
  new: '待联系',
  contacted: '已联系',
  qualified: '有效线索',
  closed: '已关闭',
  spam: '垃圾线索',
}

const STATUS_OPTIONS: Array<{ value: '' | MarketingLeadStatus; label: string }> = [
  { value: '', label: '全部状态' },
  { value: 'new', label: STATUS_LABEL.new },
  { value: 'contacted', label: STATUS_LABEL.contacted },
  { value: 'qualified', label: STATUS_LABEL.qualified },
  { value: 'closed', label: STATUS_LABEL.closed },
  { value: 'spam', label: STATUS_LABEL.spam },
]

const badgeTone: Record<MarketingLeadStatus, string> = {
  new: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  contacted: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  qualified: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  closed: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
  spam: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
}

const readonlyStatuses = new Set<MarketingLeadStatus>(['closed', 'spam'])

export function MarketingLeadsPage() {
  const [items, setItems] = useState<MarketingLeadItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [keyword, setKeyword] = useState('')
  const [status, setStatus] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [editing, setEditing] = useState<MarketingLeadItem | null>(null)

  useEffect(() => {
    let cancelled = false
    MarketingLeads.list({
      q: keyword || undefined,
      status: status || undefined,
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
  }, [keyword, status, page, pageSize, tick])

  const summary = useMemo(() => `共 ${total} 条线索`, [total])
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
        title="官网线索"
        subtitle="查看官网业务咨询表单提交的联系人、公司和咨询需求，按状态持续跟进。"
      />

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索联系人 / 手机 / 公司 / 需求"
          />
        }
        filters={
          <div className="w-[140px]">
            <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
              {STATUS_OPTIONS.map((it) => <option key={it.value} value={it.value}>{it.label}</option>)}
            </Select>
          </div>
        }
        summary={summary}
        actions={
          <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新官网线索">
            <RefreshCw size={14} />
          </Button>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['联系人', '手机号', '公司', '咨询问题', '状态', '跟进人', '来源页面', '提交时间', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载官网线索</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState title="暂无官网线索" description="官网访客提交业务咨询后，会出现在这里。" />
        ) : undefined}
      >
        {!loading && items.map((item) => {
          const isReadonly = readonlyStatuses.has(item.status)
          const actionLabel = isReadonly ? '查看' : '跟进'
          const ActionIcon = isReadonly ? Eye : Edit3
          return (
            <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[160px] min-w-[160px] max-w-[160px] px-4 py-3 ${stickyLeftTdCls}`}>
                <div className="truncate font-medium text-[var(--color-text)]">{item.contact_name}</div>
                <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]">{item.source || 'zhiban-www'}</div>
              </td>
              <td className="min-w-[140px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
                {item.phone_masked || item.phone || '-'}
              </td>
              <td className="min-w-[200px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.company}>
                <div className="max-w-[220px] truncate">{item.company}</div>
              </td>
              <td className="min-w-[300px] px-4 py-3 text-[var(--color-text-sub)]" title={item.message || '-'}>
                <div className="max-w-[340px] truncate">{item.message || '-'}</div>
              </td>
              <td className="min-w-[116px] whitespace-nowrap px-4 py-3">
                <Badge className={badgeTone[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
              </td>
              <td className="min-w-[144px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.assigned_to_name || '未指派'}>
                <div className="max-w-[144px] truncate">{item.assigned_to_name || '未指派'}</div>
              </td>
              <td className="min-w-[220px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.page_url || '-'}>
                <div className="max-w-[220px] truncate">{item.page_url || '-'}</div>
              </td>
              <td className="min-w-[180px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
              <td className={`min-w-[112px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setEditing(item)}
                  title={actionLabel}
                  aria-label={`${actionLabel}官网线索`}
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
        <MarketingLeadDrawer
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

function MarketingLeadDrawer({
  item,
  onClose,
  onSaved,
}: {
  item: MarketingLeadItem
  onClose: () => void
  onSaved: (item: MarketingLeadItem) => void
}) {
  const [status, setStatus] = useState<MarketingLeadStatus>(item.status)
  const [assignedTo, setAssignedTo] = useState(item.assigned_to ? String(item.assigned_to) : '')
  const [sysUsers, setSysUsers] = useState<SysUser[]>([])
  const [remark, setRemark] = useState(item.remark || '')
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')

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
      const resp = await MarketingLeads.update(item.uuid, {
        status,
        assigned_to: assignedTo ? Number(assignedTo) : null,
        remark,
      })
      onSaved(resp.item)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      title="跟进官网线索"
      subtitle={`${item.contact_name} · ${item.company}`}
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

        <FormSection title="联系人信息" description="手机号来自官网短信验证码校验后的提交记录，列表默认脱敏展示。">
          <div className="grid gap-2 sm:grid-cols-2">
            <InfoTile label="联系人" value={item.contact_name} />
            <InfoTile label="联系电话" value={item.phone || item.phone_masked || '-'} />
            <InfoTile label="公司名称" value={item.company} />
            <InfoTile label="提交时间" value={formatTime(item.created_at)} />
          </div>
          <LeadTextBlock title="咨询问题" text={item.message || '-'} />
          {item.page_url && (
            <a
              href={item.page_url}
              target="_blank"
              rel="noreferrer"
              className="mt-3 inline-flex items-center gap-1 text-[13px] font-medium text-[var(--color-brand)]"
            >
              打开来源页面
              <ExternalLink size={13} />
            </a>
          )}
        </FormSection>

        <FormSection title="跟进状态">
          <div className="grid gap-3 sm:grid-cols-2">
            <FormField label="状态">
              <Select value={status} onChange={(e) => setStatus(e.target.value as MarketingLeadStatus)}>
                {STATUS_OPTIONS.filter((it) => it.value).map((it) => (
                  <option key={it.value} value={it.value}>{it.label}</option>
                ))}
              </Select>
            </FormField>
            <FormField label="跟进人">
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
          <div className="mt-3">
            <FormField label="内部备注">
              <textarea
                value={remark}
                rows={5}
                maxLength={1000}
                onChange={(e) => setRemark(e.target.value)}
                className={textareaCls}
                placeholder="记录沟通结果、商机判断、下一步动作"
              />
            </FormField>
            <div className="mt-1 text-right text-[12px] text-[var(--color-text-mute)]">{remark.length}/1000</div>
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
      <div className="mt-0.5 min-w-0 truncate text-[13px] font-medium text-[var(--color-text)]">{value || '-'}</div>
    </div>
  )
}

function LeadTextBlock({ title, text }: { title: string; text: string }) {
  return (
    <div className="mt-3 rounded-md border border-[var(--color-line-soft)] bg-white px-3 py-3">
      <div className="text-[12px] font-medium text-[var(--color-text-sub)]">{title}</div>
      <div className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[var(--color-text)]">{text}</div>
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

const textareaCls = [
  'min-h-[112px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-6 text-[var(--color-text)]',
  'outline-none transition focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]',
].join(' ')

function formatTime(v?: string) {
  if (!v) return '-'
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  return d.toLocaleString('zh-CN', { hour12: false })
}
