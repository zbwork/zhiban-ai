import { useCallback, useEffect, useMemo, useState } from 'react'
import { Check, Eye, RefreshCw, X } from 'lucide-react'

import {
  A2AApprovalsAdmin,
  type A2AApprovalItem,
  type A2AApprovalStatus,
} from '../lib/api'
import { notifyOk } from '../lib/toast'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DrawerShell,
  EmptyState,
  Input,
  InlineAlert,
  PageHeader,
  Pagination,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

type DecisionDialog =
  | { kind: 'approved'; mode: 'single'; item: A2AApprovalItem }
  | { kind: 'rejected'; mode: 'single'; item: A2AApprovalItem }
  | { kind: 'approved'; mode: 'batch'; items: A2AApprovalItem[] }
  | { kind: 'rejected'; mode: 'batch'; items: A2AApprovalItem[] }
  | null

const statusOptions: Array<{ value: '' | A2AApprovalStatus; label: string }> = [
  { value: '', label: '全部状态' },
  { value: 'pending', label: '待审批' },
  { value: 'approved', label: '已同意' },
  { value: 'rejected', label: '已拒绝' },
  { value: 'expired', label: '已过期' },
  { value: 'cancelled', label: '已取消' },
]
const A2A_APPROVALS_CHANGED_EVENT = 'a2a-approvals:changed'

const statusMeta: Record<A2AApprovalStatus, { label: string; className: string }> = {
  pending: {
    label: '待审批',
    className: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)] ring-[var(--color-warn)]/20',
  },
  approved: {
    label: '已同意',
    className: 'bg-[var(--color-success-bg)] text-[var(--color-success)] ring-[var(--color-success)]/20',
  },
  rejected: {
    label: '已拒绝',
    className: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)] ring-[var(--color-danger)]/20',
  },
  expired: {
    label: '已过期',
    className: 'bg-[var(--color-bg-sub)] text-[var(--color-text-sub)] ring-[var(--color-line)]',
  },
  cancelled: {
    label: '已取消',
    className: 'bg-[var(--color-bg-sub)] text-[var(--color-text-sub)] ring-[var(--color-line)]',
  },
}

export function A2AApprovalsPage() {
  const [items, setItems] = useState<A2AApprovalItem[]>([])
  const [total, setTotal] = useState(0)
  const [status, setStatus] = useState<'' | A2AApprovalStatus>('pending')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [dialog, setDialog] = useState<DecisionDialog>(null)
  const [rejectReason, setRejectReason] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set())
  const [detailItem, setDetailItem] = useState<A2AApprovalItem | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')

  const offset = useMemo(() => (page - 1) * pageSize, [page, pageSize])
  const pendingItems = useMemo(() => items.filter((item) => item.status === 'pending'), [items])
  const selectedPendingItems = useMemo(
    () => pendingItems.filter((item) => selectedIds.has(item.id)),
    [pendingItems, selectedIds],
  )
  const allPendingSelected = pendingItems.length > 0 && pendingItems.every((item) => selectedIds.has(item.id))

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const resp = await A2AApprovalsAdmin.list({ status, limit: pageSize, offset })
      setItems(resp.items || [])
      setTotal(resp.total || 0)
      setSelectedIds(new Set())
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [offset, pageSize, status])

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load()
    }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const openDecision = (kind: 'approved' | 'rejected', item: A2AApprovalItem) => {
    setRejectReason('')
    setDialog({ kind, mode: 'single', item })
  }

  const openBatchDecision = (kind: 'approved' | 'rejected') => {
    if (selectedPendingItems.length === 0) return
    setRejectReason('')
    setDialog({ kind, mode: 'batch', items: selectedPendingItems })
  }

  const openDetail = async (item: A2AApprovalItem) => {
    setDetailItem(item)
    setDetailLoading(true)
    setDetailError('')
    try {
      const detail = await A2AApprovalsAdmin.get(item.id)
      setDetailItem(detail)
    } catch (e) {
      setDetailError((e as Error).message)
    } finally {
      setDetailLoading(false)
    }
  }

  const closeDetail = () => {
    setDetailItem(null)
    setDetailError('')
  }

  const submitDecision = async () => {
    if (!dialog) return
    const targets = dialog.mode === 'single' ? [dialog.item] : dialog.items
    const reason = dialog.kind === 'rejected' ? rejectReason.trim() : undefined
    const failures: string[] = []
    for (const target of targets) {
      try {
        await A2AApprovalsAdmin.decide(target.id, {
          decision: dialog.kind,
          reason,
          form_result: {},
        })
      } catch (e) {
        failures.push(`${target.from_agent_name || target.from_agent_id || '发起方'} → ${target.to_agent_name || target.to_agent_id || '目标'}：${(e as Error).message}`)
      }
    }
    setDialog(null)
    await load()
    window.dispatchEvent(new CustomEvent(A2A_APPROVALS_CHANGED_EVENT))
    if (detailItem) {
      closeDetail()
    }
    if (failures.length > 0) {
      setError(`处理失败 ${failures.length} 条：${failures.slice(0, 2).join('；')}`)
      return
    }
    notifyOk(dialog.kind === 'approved' ? `已同意 ${targets.length} 条协作请求` : `已拒绝 ${targets.length} 条协作请求`)
  }

  const toggleOne = (item: A2AApprovalItem, checked: boolean) => {
    if (item.status !== 'pending') return
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (checked) next.add(item.id)
      else next.delete(item.id)
      return next
    })
  }

  const toggleAllPending = (checked: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      for (const item of pendingItems) {
        if (checked) next.add(item.id)
        else next.delete(item.id)
      }
      return next
    })
  }

  return (
    <div>
      <PageHeader
        title="协作审批"
        subtitle="处理数字员工之间需要人工确认的协作请求。"
      />

      <Toolbar
        filters={(
          <div className="w-[160px]">
            <Select
              value={status}
              onChange={(e) => {
                setStatus(e.target.value as '' | A2AApprovalStatus)
                setPage(1)
              }}
            >
              {statusOptions.map((opt) => (
                <option key={opt.value || 'all'} value={opt.value}>{opt.label}</option>
              ))}
            </Select>
          </div>
        )}
        summary={`共 ${total} 条`}
        actions={(
          <div className="flex items-center gap-2">
            {selectedPendingItems.length > 0 && (
              <>
                <span className="text-[12.5px] text-[var(--color-text-sub)]">已选 {selectedPendingItems.length} 条</span>
                <Button variant="secondary" size="sm" onClick={() => openBatchDecision('rejected')}>
                  <X size={14} />
                  批量拒绝
                </Button>
                <Button size="sm" onClick={() => openBatchDecision('approved')}>
                  <Check size={14} />
                  批量同意
                </Button>
              </>
            )}
            <Button variant="secondary" size="sm" onClick={() => void load()} disabled={loading}>
              <RefreshCw size={14} />
              刷新
            </Button>
          </div>
        )}
      />

      {error && <div className="mb-3"><InlineAlert>{error}</InlineAlert></div>}

      <DataTable
        stickyLastCol
        headers={[
          <input
            key="select"
            type="checkbox"
            className="h-4 w-4 rounded border-[var(--color-line)] accent-[var(--color-brand)]"
            checked={allPendingSelected}
            disabled={pendingItems.length === 0}
            aria-label="选择当前页待审批项"
            onChange={(e) => toggleAllPending(e.target.checked)}
          />,
          '状态',
          '发起数字员工',
          '被请求数字员工',
          '请求摘要',
          '创建时间',
          '过期时间',
          '操作',
        ]}
        loading={loading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-mute)]">加载中...</div> : null}
        empty={!loading && items.length === 0 ? <EmptyState title="暂无协作审批" description="当前筛选条件下没有需要处理的协作请求。" /> : null}
      >
        {items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <td className="whitespace-nowrap px-4 py-3">
              <input
                type="checkbox"
                className="h-4 w-4 rounded border-[var(--color-line)] accent-[var(--color-brand)] disabled:opacity-40"
                checked={selectedIds.has(item.id)}
                disabled={item.status !== 'pending'}
                aria-label={`选择 ${item.from_agent_name || '发起数字员工'} 请求 ${item.to_agent_name || '目标数字员工'} 的审批项`}
                onChange={(e) => toggleOne(item, e.target.checked)}
              />
            </td>
            <td className="whitespace-nowrap px-4 py-3">{renderStatus(item.status)}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text)]">{item.from_agent_name || item.from_agent_id || '-'}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text)]">{item.to_agent_name || item.to_agent_id || '-'}</td>
            <td className="max-w-[420px] px-4 py-3 text-[var(--color-text-sub)]">
              <span className="line-clamp-2">{requestSummary(item.request_payload)}</span>
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.expires_at)}</td>
            <td className={stickyRightTdCls}>
              <div className="flex justify-end gap-1">
                <Button size="sm" variant="ghost" onClick={() => void openDetail(item)}>
                  <Eye size={14} />
                  详情
                </Button>
                {item.status === 'pending' ? (
                  <>
                  <Button size="sm" variant="secondary" onClick={() => openDecision('rejected', item)}>
                    <X size={14} />
                    拒绝
                  </Button>
                  <Button size="sm" onClick={() => openDecision('approved', item)}>
                    <Check size={14} />
                    同意
                  </Button>
                  </>
                ) : null}
              </div>
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => {
          setPageSize(size)
          setPage(1)
        }}
      />

      {dialog && (
        <ConfirmDialog
          title={dialog.kind === 'approved' ? '同意协作请求' : '拒绝协作请求'}
          description={dialogDescription(dialog)}
          tone={dialog.kind === 'approved' ? 'info' : 'danger'}
          confirmLabel={dialog.kind === 'approved' ? '同意' : '拒绝'}
          busyLabel="提交中..."
          onClose={() => setDialog(null)}
          onConfirm={submitDecision}
        >
          {dialog.kind === 'rejected' && (
            <Input
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              placeholder="填写拒绝原因（选填）"
            />
          )}
        </ConfirmDialog>
      )}

      {detailItem && (
        <ApprovalDetailDrawer
          item={detailItem}
          loading={detailLoading}
          error={detailError}
          onClose={closeDetail}
          onApprove={() => openDecision('approved', detailItem)}
          onReject={() => openDecision('rejected', detailItem)}
        />
      )}
    </div>
  )
}

function renderStatus(status: A2AApprovalStatus) {
  const meta = statusMeta[status] || statusMeta.pending
  return (
    <span className={`inline-flex h-6 items-center rounded-full px-2.5 text-[12px] font-medium ring-1 ${meta.className}`}>
      {meta.label}
    </span>
  )
}

function requestSummary(payload: unknown) {
  if (!payload) return '-'
  if (typeof payload === 'string') return payload
  if (typeof payload === 'object') {
    const obj = payload as Record<string, unknown>
    const direct = obj.user_text || obj.input || obj.text || obj.query || obj.prompt
    if (typeof direct === 'string' && direct.trim()) return direct
  }
  try {
    return JSON.stringify(payload)
  } catch {
    return '-'
  }
}

function formatTime(value?: string) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString('zh-CN', { hour12: false })
}

function dialogDescription(dialog: Exclude<DecisionDialog, null>) {
  if (dialog.mode === 'batch') {
    return `将处理当前页选中的 ${dialog.items.length} 条待审批协作请求。`
  }
  return `${dialog.item.from_agent_name || '发起方'} 请求 ${dialog.item.to_agent_name || '目标数字员工'} 协助处理任务。`
}

function ApprovalDetailDrawer({
  item,
  loading,
  error,
  onClose,
  onApprove,
  onReject,
}: {
  item: A2AApprovalItem
  loading: boolean
  error: string
  onClose: () => void
  onApprove: () => void
  onReject: () => void
}) {
  return (
    <DrawerShell
      title="审批详情"
      subtitle="查看协作请求上下文，确认后可同意或拒绝。"
      onClose={onClose}
      width="md"
      footer={(
        <div className="flex items-center justify-between gap-3">
          <Button variant="secondary" onClick={onClose}>关闭</Button>
          {item.status === 'pending' && (
            <div className="flex items-center gap-2">
              <Button variant="secondary" onClick={onReject}>
                <X size={14} />
                拒绝
              </Button>
              <Button onClick={onApprove}>
                <Check size={14} />
                同意
              </Button>
            </div>
          )}
        </div>
      )}
    >
      <div className="space-y-4">
        {loading && <InlineAlert tone="info">正在加载审批详情...</InlineAlert>}
        {error && <InlineAlert>{error}</InlineAlert>}

        <section className="rounded-lg border border-[var(--color-line)] bg-white p-4">
          <div className="mb-3 flex items-center justify-between gap-3">
            <div className="text-[14px] font-semibold text-[var(--color-text)]">基本信息</div>
            {renderStatus(item.status)}
          </div>
          <div className="grid gap-3 text-[13px] sm:grid-cols-2">
            <DetailField label="发起数字员工" value={item.from_agent_name || item.from_agent_id || '-'} />
            <DetailField label="被请求数字员工" value={item.to_agent_name || item.to_agent_id || '-'} />
            <DetailField label="调用方式" value={item.invoke_kind || '-'} />
            <DetailField label="Edge ID" value={item.edge_id || '-'} mono />
            <DetailField label="创建时间" value={formatTime(item.created_at)} />
            <DetailField label="过期时间" value={formatTime(item.expires_at)} />
            <DetailField label="决策时间" value={formatTime(item.decided_at)} />
            <DetailField label="审批人账号" value={item.decided_by_account_id ? String(item.decided_by_account_id) : '-'} />
          </div>
        </section>

        <DetailJsonBlock title="请求摘要" value={item.request_payload} />
        <DetailJsonBlock title="表单结构" value={item.form_schema} />
        <DetailJsonBlock title="审批结果" value={item.form_result} />
        {item.reason && (
          <section className="rounded-lg border border-[var(--color-line)] bg-white p-4">
            <div className="mb-2 text-[14px] font-semibold text-[var(--color-text)]">拒绝原因</div>
            <div className="whitespace-pre-wrap text-[13px] leading-relaxed text-[var(--color-text-sub)]">{item.reason}</div>
          </section>
        )}
      </div>
    </DrawerShell>
  )
}

function DetailField({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0 rounded-md bg-[var(--color-bg-sub)] px-3 py-2">
      <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
      <div className={`mt-1 truncate text-[13px] text-[var(--color-text)] ${mono ? 'font-mono' : ''}`} title={value}>
        {value}
      </div>
    </div>
  )
}

function DetailJsonBlock({ title, value }: { title: string; value: unknown }) {
  return (
    <section className="rounded-lg border border-[var(--color-line)] bg-white p-4">
      <div className="mb-2 text-[14px] font-semibold text-[var(--color-text)]">{title}</div>
      <pre className="max-h-[240px] overflow-auto rounded-md bg-[var(--color-bg-sub)] p-3 text-[12px] leading-relaxed text-[var(--color-text-sub)]">
        {formatJson(value)}
      </pre>
    </section>
  )
}

function formatJson(value: unknown) {
  if (value == null) return '-'
  if (typeof value === 'string') return value || '-'
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}
