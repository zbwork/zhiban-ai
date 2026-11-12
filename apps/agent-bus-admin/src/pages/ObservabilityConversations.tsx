import { useCallback, useEffect, useRef, useState } from 'react'
import { useOutletContext, useSearchParams } from 'react-router-dom'
import { Bot, MessageSquareText, ShieldAlert, User, Wrench, X } from 'lucide-react'

import {
  ObservabilityConversations,
  type ObsConversationItem,
  type ObsMessageItem,
} from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  SearchInput,
  stickyRightTdCls,
  Toolbar,
} from '../components/ui'

function fmtTime(iso?: string) {
  if (!iso) return '—'
  try {
    return new Date(iso).toLocaleString('zh-CN', { hour12: false })
  } catch {
    return iso
  }
}

type Block = { type?: string; text?: string; tool?: string; tool_call_id?: string; status?: string; [k: string]: unknown }

// 只读回放的 EMP block 渲染：文本类直接展示，工具/结构化块折叠为 JSON。
function BlockView({ block }: { block: Block }) {
  const [open, setOpen] = useState(false)
  const t = block.type || 'markdown'
  if ((t === 'markdown' || t === 'text' || t === 'plain') && typeof block.text === 'string') {
    return <div className="whitespace-pre-wrap break-words text-[13px] leading-relaxed">{block.text}</div>
  }
  if (t === 'tool_call' || t === 'tool_result') {
    return (
      <div className="rounded border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-2 py-1 text-xs">
        <button className="inline-flex items-center gap-1 font-medium text-[var(--color-text-sub)]" onClick={() => setOpen(!open)}>
          <Wrench size={12} />
          {t === 'tool_call' ? '工具调用' : '工具结果'}
          {typeof block.tool === 'string' && block.tool ? <span className="font-mono">{block.tool}</span> : null}
          <span className="text-[var(--color-text-muted)]">{open ? '收起' : '展开'}</span>
        </button>
        {open && (
          <pre className="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-all">{JSON.stringify(block, null, 2)}</pre>
        )}
      </div>
    )
  }
  return (
    <div className="rounded border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-2 py-1 text-xs">
      <button className="font-medium text-[var(--color-text-sub)]" onClick={() => setOpen(!open)}>
        {t} 块 {open ? '收起' : '展开'}
      </button>
      {open && <pre className="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-all">{JSON.stringify(block, null, 2)}</pre>}
    </div>
  )
}

function ConversationDrawer({ scope, conversation, onClose }: {
  scope: 'platform' | 'tenant'
  conversation: ObsConversationItem
  onClose: () => void
}) {
  const [items, setItems] = useState<ObsMessageItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const pageSize = 50
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setLoading(true)
      setError('')
      ObservabilityConversations.messages(scope, conversation.uuid, { limit: pageSize, offset: (page - 1) * pageSize })
        .then((r) => {
          setItems(r.items || [])
          setTotal(r.total)
        })
        .catch((e: Error) => setError(e.message || '加载消息失败'))
        .finally(() => setLoading(false))
    }, 0)
    return () => window.clearTimeout(timer)
  }, [scope, conversation.uuid, page])

  return (
    <DrawerShell
      title="会话详情"
      subtitle={conversation.title || '(无标题会话)'}
      onClose={onClose}
      width="sm"
      footer={<div className="flex justify-end"><Button variant="secondary" onClick={onClose}>关闭</Button></div>}
    >
      <div className="space-y-5">
        <InlineAlert tone="warn">
          <span className="mr-1 inline-flex align-text-bottom"><ShieldAlert size={14} /></span>
          本次会话内容查看已记录审计日志，请仅用于问题排查与合规审查。
        </InlineAlert>

        <section>
          <h3 className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">会话概览</h3>
          <div className="grid grid-cols-2 overflow-hidden rounded-lg border border-[var(--color-line)] bg-white">
            {[
              ['最后活跃', fmtTime(conversation.lastMessageAt || conversation.createdAt)],
              ['消息数量', `${conversation.messageCount} 条`],
              ['成员', conversation.accountName || `成员 ${conversation.accountId}`],
              ['数字员工', conversation.agentName || '—'],
            ].map(([label, value]) => (
              <div key={label} className="border-b border-r border-[var(--color-line-soft)] px-4 py-3 even:border-r-0 [&:nth-last-child(-n+2)]:border-b-0">
                <div className="text-[11px] text-[var(--color-text-mute)]">{label}</div>
                <div className="mt-1 truncate text-[13px] font-medium text-[var(--color-text)]" title={value}>{value}</div>
              </div>
            ))}
          </div>
        </section>

        <section>
          <div className="mb-2 flex items-center justify-between gap-3">
            <h3 className="text-[13px] font-semibold text-[var(--color-text)]">会话内容</h3>
            <span className="text-[11px] text-[var(--color-text-mute)]">按时间顺序展示</span>
          </div>
          <div className="space-y-3 rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-4">
            {loading && (
              <div className="py-10 text-center text-xs text-[var(--color-text-sub)]">正在加载会话内容...</div>
            )}
            {error && (
              <div className="rounded-md border border-red-200 bg-[var(--color-danger-bg)] px-3 py-2 text-xs text-[var(--color-danger)]">{error}</div>
            )}
            {!loading && !error && !items.length && (
              <div className="py-10 text-center text-xs text-[var(--color-text-sub)]">该会话暂无消息。</div>
            )}
            {!loading && items.map((m) => {
              const isUser = m.role === 'user'
              const blocks: Block[] = Array.isArray(m.blocks) ? (m.blocks as Block[]) : []
              return (
                <div key={m.uuid} className="flex gap-2">
                  <div className={`mt-0.5 grid h-6 w-6 shrink-0 place-items-center rounded-full ${isUser ? 'bg-[var(--color-bg-sub)] text-[var(--color-text-sub)]' : 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]'}`}>
                    {isUser ? <User size={13} /> : <Bot size={13} />}
                  </div>
                  <div className={`min-w-0 flex-1 rounded-lg border border-[var(--color-line)] p-3 ${isUser ? 'bg-white' : 'bg-[var(--color-brand-soft)]'}`}>
                    <div className="mb-1 flex items-center gap-2 text-[11px] text-[var(--color-text-muted)]">
                      <span>{isUser ? '成员' : m.role === 'agent' ? '数字员工' : m.role}</span>
                      <span>{fmtTime(m.createdAt)}</span>
                      {m.status === 'failed' && <span className="text-red-700">失败{m.errorCode ? ` · ${m.errorCode}` : ''}</span>}
                      {m.status === 'cancelled' && <span>已取消</span>}
                      {m.status === 'awaiting_user' && <span className="text-amber-700">等待用户</span>}
                    </div>
                    <div className="space-y-1.5">
                      {blocks.length
                        ? blocks.map((b, i) => <BlockView key={i} block={b} />)
                        : <div className="text-xs text-[var(--color-text-muted)]">(无内容)</div>}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </section>
        {total > pageSize && (
          <Pagination total={total} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={() => {}} />
        )}
      </div>
    </DrawerShell>
  )
}

type Filters = { accountId: string; agentId: string; q: string }
const DEFAULT_FILTERS: Filters = { accountId: '', agentId: '', q: '' }

export function ObservabilityConversationsPage() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isPlatform = actScope?.kind === 'platform'
  const isTenant = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const scope: 'platform' | 'tenant' = isPlatform ? 'platform' : 'tenant'
  const [searchParams, setSearchParams] = useSearchParams()

  const [filters, setFilters] = useState<Filters>({ ...DEFAULT_FILTERS })
  const [items, setItems] = useState<ObsConversationItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(false)
  const [selected, setSelected] = useState<ObsConversationItem | null>(null)

  // deep-link 只应用一次 (review C14: 否则每次 refetch 都会把选中项弹回 deep-link 会话)
  const deepLinkRef = useRef(searchParams.get('uuid') || '')

  const fetchData = useCallback(() => {
    if (!actScope) return
    setLoading(true)
    const params: Parameters<typeof ObservabilityConversations.list>[1] = {
      limit: pageSize,
      offset: (page - 1) * pageSize,
    }
    if (filters.accountId) params.account_id = Number(filters.accountId)
    if (filters.agentId) params.digital_employee_id = Number(filters.agentId)
    if (filters.q) params.q = filters.q
    ObservabilityConversations.list(scope, params)
      .then((r) => {
        setItems(r.items || [])
        setTotal(r.total)
        if (deepLinkRef.current) {
          const hit = (r.items || []).find((c) => c.uuid === deepLinkRef.current)
          deepLinkRef.current = '' // 应用一次即失效; 目标不在本页时静默放弃 (已知限制)
          if (hit) setSelected(hit)
        }
      })
      .catch(() => {
        setItems([])
        setTotal(0)
      })
      .finally(() => setLoading(false))
  }, [actScope, scope, filters, page, pageSize])

  useEffect(() => {
    const timer = window.setTimeout(() => fetchData(), 0)
    return () => window.clearTimeout(timer)
  }, [fetchData])

  if (switchingScope || !actScope) return null
  if (!isPlatform && !isTenant) {
    return <EmptyState title="选择管理范围" description="请先在左上角选择平台或租户后查看会话内容。" />
  }

  const hasFilters = filters.accountId || filters.agentId || filters.q

  return (
    <>
      <PageHeader
        title="会话检索"
        subtitle={isPlatform ? '跨租户检索并查看 Agent 会话完整内容（用于问题定位与优化）' : '检索并查看本租户 Agent 会话完整内容（用于问题定位与优化）'}
      />

      <div className="mb-3">
        <InlineAlert tone="warn">
          <span className="mr-1 inline-flex align-text-bottom"><ShieldAlert size={14} /></span>
          本页展示成员与数字员工的完整对话内容，仅限问题排查与合规审查使用；<span className="font-medium">每次检索与查看都会记录审计日志</span>。
        </InlineAlert>
      </div>

      <Toolbar
        search={
          <SearchInput
            value={filters.q}
            onChange={(v) => { setFilters((f) => ({ ...f, q: v })); setPage(1) }}
            placeholder="搜索会话标题"
          />
        }
        filters={
          <>
            <div className="w-[120px]">
              <Input placeholder="成员 ID" value={filters.accountId}
                onChange={(e) => { setFilters((f) => ({ ...f, accountId: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
            </div>
            <div className="w-[130px]">
              <Input placeholder="数字员工 ID" value={filters.agentId}
                onChange={(e) => { setFilters((f) => ({ ...f, agentId: e.target.value.replace(/\D/g, '') })); setPage(1) }} />
            </div>
          </>
        }
        actions={hasFilters ? (
          <Button variant="ghost" size="sm" onClick={() => { setFilters({ ...DEFAULT_FILTERS }); setPage(1); setSearchParams({}) }}>
            <X size={14} /> 清除
          </Button>
        ) : undefined}
        summary={<span className="text-[12px] text-[var(--color-text-sub)]">共 {total} 条</span>}
      />

      <div className="min-w-0">
        <DataTable
          headers={['最后活跃', ...(isPlatform ? ['租户'] : []), '标题', '成员', '数字员工', '消息数', '操作']}
          stickyLastCol
          empty={!loading && !items.length ? (
            <EmptyState
              icon={<MessageSquareText size={24} />}
              title="暂无会话"
              description="当前筛选条件下没有会话记录。"
            />
          ) : null}
        >
          {loading && <tr><td colSpan={7 + (isPlatform ? 1 : 0)} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</td></tr>}
          {!loading && items.map((c) => (
            <tr
              key={c.uuid}
              className={`group cursor-pointer hover:bg-[var(--color-bg-sub)] ${selected?.uuid === c.uuid ? 'bg-[var(--color-brand-soft)]' : ''}`}
              onClick={() => setSelected(c)}
            >
              <td className="whitespace-nowrap px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{fmtTime(c.lastMessageAt || c.createdAt)}</td>
              {isPlatform && <td className="max-w-[110px] truncate px-4 py-3 text-[12px]" title={c.tenantName}>{c.tenantName || c.tenantId}</td>}
              <td className="max-w-[220px] truncate px-4 py-3 text-[13px]" title={c.title}>{c.title || '(无标题)'}</td>
              <td className="whitespace-nowrap px-4 py-3 text-[12px]">{c.accountName || c.accountId}</td>
              <td className="max-w-[140px] truncate px-4 py-3 text-[12px]" title={c.agentName}>{c.agentName || '—'}</td>
              <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[12px]">{c.messageCount}</td>
              <td className={`whitespace-nowrap px-4 py-2 ${stickyRightTdCls}`}>
                <Button className="text-[var(--color-brand)]" variant="ghost" size="sm" onClick={(e) => { e.stopPropagation(); setSelected(c) }} title="查看会话详情">
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
      </div>

      {selected && (
        <ConversationDrawer key={selected.uuid} scope={scope} conversation={selected} onClose={() => { setSelected(null); setSearchParams({}) }} />
      )}
    </>
  )
}
