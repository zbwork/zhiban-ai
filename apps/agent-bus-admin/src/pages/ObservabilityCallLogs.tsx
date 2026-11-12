import { useCallback, useEffect, useMemo, useState } from 'react'
import { useOutletContext, useSearchParams } from 'react-router-dom'
import {
  Activity,
  AlertTriangle,
  ArrowUpDown,
  CheckCircle2,
  Eye,
  X,
} from 'lucide-react'

import { ObservabilityCallLogs, type CallLogEntry, type CallLogListParams } from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  Input,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

type Filters = {
  // F25 评审返修：平台侧支持 ?tenant_id= 深链（租户 360° 下钻）
  tenantId: string
  method: string
  httpStatus: string
  operation: string
  agentId: string
  agentName: string
  runtimeEnvironmentId: string
  messageUuid: string
  errorsOnly: boolean
  q: string
  from: string
  to: string
}

type TimelineQuery = {
  key: string
  params: Pick<CallLogListParams, 'trace_id' | 'message_uuid' | 'stream_id'>
}

const DEFAULT_FILTERS: Filters = {
  tenantId: '',
  method: '',
  httpStatus: '',
  operation: '',
  agentId: '',
  agentName: '',
  runtimeEnvironmentId: '',
  messageUuid: '',
  errorsOnly: false,
  q: '',
  from: '',
  to: '',
}

const METHOD_OPTIONS = [
  ['', '全部方法'],
  ['GET', 'GET'],
  ['POST', 'POST'],
  ['PUT', 'PUT'],
  ['PATCH', 'PATCH'],
  ['DELETE', 'DELETE'],
]

function statusBadge(status?: number) {
  if (!status) return <span className="text-[var(--color-text-muted)]">—</span>
  if (status >= 200 && status < 300)
    return <span className="inline-flex items-center gap-1 text-green-700"><CheckCircle2 size={14} />{status}</span>
  if (status >= 400 && status < 500)
    return <span className="inline-flex items-center gap-1 text-amber-700"><AlertTriangle size={14} />{status}</span>
  if (status >= 500)
    return <span className="inline-flex items-center gap-1 text-red-700"><AlertTriangle size={14} />{status}</span>
  return <span>{status}</span>
}

function latencyLabel(ms: number) {
  if (ms < 100) return <span className="text-green-700">{ms}ms</span>
  if (ms < 1000) return <span className="text-amber-700">{ms}ms</span>
  return <span className="text-red-700">{(ms / 1000).toFixed(1)}s</span>
}

function fmtTime(iso: string) {
  try {
    const d = new Date(iso)
    return d.toLocaleString('zh-CN', { hour12: false })
  } catch {
    return iso
  }
}

function getAgentId(entry: CallLogEntry) {
  return entry.agentId ?? entry.digitalEmployeeId
}

function getAgentName(entry: CallLogEntry) {
  return entry.agentName || entry.digitalEmployeeName || ''
}

function getTimelineQuery(entry: CallLogEntry): TimelineQuery | null {
  if (entry.traceId) {
    return { key: `trace:${entry.traceId}`, params: { trace_id: entry.traceId } }
  }
  if (entry.messageUuid) {
    return { key: `message:${entry.messageUuid}`, params: { message_uuid: entry.messageUuid } }
  }
  if (entry.streamId) {
    return { key: `stream:${entry.streamId}`, params: { stream_id: entry.streamId } }
  }
  return null
}

function JsonViewer({ data, label }: { data: unknown; label: string }) {
  const [expanded, setExpanded] = useState(false)
  const text = typeof data === 'string' ? data : JSON.stringify(data, null, 2)
  const isEmpty = !text || text === '{}' || text === 'null'
  if (isEmpty) return <div className="text-xs text-[var(--color-text-muted)]">{label}: (empty)</div>
  return (
    <div className="mt-2">
      <button
        className="text-xs font-medium text-[var(--color-primary)] hover:underline"
        onClick={() => setExpanded(!expanded)}
      >
        {expanded ? `▾ ${label}` : `▸ ${label}`}
      </button>
      {expanded && (
        <pre className="mt-1 overflow-auto rounded border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-2 text-xs max-h-80">
          {text}
        </pre>
      )}
    </div>
  )
}

function CallLogDrawer({
  entry,
  isPlatform,
  onClose,
}: {
  entry: CallLogEntry
  isPlatform: boolean
  onClose: () => void
}) {
  const timelineQuery = useMemo(() => getTimelineQuery(entry), [entry])
  const [timeline, setTimeline] = useState<{ key: string; items: CallLogEntry[] }>({ key: '', items: [] })
  const [loadingTimelineKey, setLoadingTimelineKey] = useState('')
  const visibleTimeline = timelineQuery && timeline.key === timelineQuery.key ? timeline.items : []
  const loadingTimeline = timelineQuery?.key === loadingTimelineKey

  useEffect(() => {
    if (!timelineQuery) return
    const { key, params } = timelineQuery
    const timer = window.setTimeout(() => {
      setLoadingTimelineKey(key)
      ObservabilityCallLogs.getTimeline(params, isPlatform ? 'platform' : 'tenant')
        .then((r) => setTimeline({ key, items: r.items || [] }))
        .catch(() => setTimeline({ key, items: [] }))
        .finally(() => setLoadingTimelineKey((current) => current === key ? '' : current))
    }, 0)
    return () => window.clearTimeout(timer)
  }, [isPlatform, timelineQuery])

  return (
    <DrawerShell title="调用详情" onClose={onClose}>
      <div className="space-y-4 p-4 text-sm">
        <div className="grid grid-cols-2 gap-x-6 gap-y-2">
          <div><span className="text-[var(--color-text-sub)]">UUID</span><div className="font-mono text-xs">{entry.uuid}</div></div>
          <div><span className="text-[var(--color-text-sub)]">时间</span><div>{fmtTime(entry.createdAt)}</div></div>
          <div><span className="text-[var(--color-text-sub)]">目标服务</span><div>{entry.targetService}</div></div>
          {entry.operation && <div><span className="text-[var(--color-text-sub)]">操作</span><div>{entry.operation}</div></div>}
          <div><span className="text-[var(--color-text-sub)]">方向</span><div>{entry.direction}</div></div>
          <div><span className="text-[var(--color-text-sub)]">方法</span><div className="font-mono">{entry.method}</div></div>
          <div><span className="text-[var(--color-text-sub)]">路径</span><div className="font-mono text-xs break-all">{entry.path}</div></div>
          <div><span className="text-[var(--color-text-sub)]">状态码</span><div>{statusBadge(entry.httpStatus)}</div></div>
          <div><span className="text-[var(--color-text-sub)]">延迟</span><div>{latencyLabel(entry.latencyMs)}</div></div>
          {entry.traceId && <div><span className="text-[var(--color-text-sub)]">Trace ID</span><div className="font-mono text-xs">{entry.traceId}</div></div>}
          {entry.spanId && <div><span className="text-[var(--color-text-sub)]">Span ID</span><div className="font-mono text-xs">{entry.spanId}</div></div>}
          {entry.runtimeEnvironmentId && <div><span className="text-[var(--color-text-sub)]">运行环境 ID</span><div>{entry.runtimeEnvironmentId}</div></div>}
          {getAgentId(entry) && <div><span className="text-[var(--color-text-sub)]">Agent ID</span><div>{getAgentId(entry)}</div></div>}
          {getAgentName(entry) && <div><span className="text-[var(--color-text-sub)]">数字员工名称</span><div>{getAgentName(entry)}</div></div>}
          {entry.conversationUuid && <div><span className="text-[var(--color-text-sub)]">会话 UUID</span><div className="font-mono text-xs break-all">{entry.conversationUuid}</div></div>}
          {entry.messageUuid && <div><span className="text-[var(--color-text-sub)]">消息 UUID</span><div className="font-mono text-xs break-all">{entry.messageUuid}</div></div>}
          {entry.streamId && <div><span className="text-[var(--color-text-sub)]">Stream ID</span><div className="font-mono text-xs break-all">{entry.streamId}</div></div>}
          {entry.tenantId && <div><span className="text-[var(--color-text-sub)]">租户 ID</span><div>{entry.tenantId}</div></div>}
          {entry.accountId && <div><span className="text-[var(--color-text-sub)]">账号 ID</span><div>{entry.accountId}</div></div>}
        </div>
        {entry.bodyTruncated && (
          <div className="rounded bg-amber-50 px-2 py-1 text-xs text-amber-800">
            Body 已截断 (超过 64KB)
          </div>
        )}
        {entry.errorMessage && (
          <div className="rounded bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-800">
            {entry.errorMessage}
          </div>
        )}
        <JsonViewer data={entry.requestBodyJson} label="Request Body" />
        <JsonViewer data={entry.responseBodyJson} label="Response Body" />
        <JsonViewer data={entry.tags} label="Tags" />

        {timelineQuery && (
          <div className="mt-4 border-t border-[var(--color-line)] pt-4">
            <h3 className="text-sm font-medium mb-2 flex items-center gap-1">
              <ArrowUpDown size={14} /> 关联调用时间线
            </h3>
            {loadingTimeline ? (
              <div className="text-xs text-[var(--color-text-sub)]">加载中...</div>
            ) : visibleTimeline.length === 0 ? (
              <div className="text-xs text-[var(--color-text-sub)]">无关联调用记录</div>
            ) : (
              <div className="space-y-1">
                {visibleTimeline.map((t) => (
                  <div
                    key={t.id}
                    className={`flex items-center gap-2 rounded px-2 py-1 text-xs ${t.id === entry.id ? 'bg-[var(--color-primary-light)] font-medium' : 'hover:bg-[var(--color-bg-sub)]'}`}
                  >
                    <span className="w-36 shrink-0 text-[var(--color-text-sub)]">{fmtTime(t.createdAt)}</span>
                    <span className="w-12 shrink-0 font-mono">{t.method}</span>
                    <span className="flex-1 truncate font-mono">{t.path}</span>
                    {statusBadge(t.httpStatus)}
                    <span className="w-16 text-right">{latencyLabel(t.latencyMs)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </DrawerShell>
  )
}

const COL_COUNT = 11

export function ObservabilityCallLogsPage() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isPlatform = actScope?.kind === 'platform'
  const isTenant = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'

  const [searchParams] = useSearchParams()
  const [filters, setFilters] = useState<Filters>(() => ({
    ...DEFAULT_FILTERS,
    tenantId: (searchParams.get('tenant_id') ?? '').replace(/[^0-9]/g, ''),
  }))
  const [items, setItems] = useState<CallLogEntry[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(false)
  const [selected, setSelected] = useState<CallLogEntry | null>(null)

  const fetchData = useCallback(() => {
    if (!actScope) return
    setLoading(true)
    const params: CallLogListParams = {
      limit: pageSize,
      offset: (page - 1) * pageSize,
    }
    if (isPlatform && filters.tenantId) params.tenant_id = Number(filters.tenantId)
    if (filters.method) params.method = filters.method
    if (filters.httpStatus) params.http_status = Number(filters.httpStatus)
    if (filters.operation) params.operation = filters.operation
    if (filters.agentId) params.agent_id = Number(filters.agentId)
    if (filters.agentName) params.agent_name = filters.agentName
    if (filters.runtimeEnvironmentId) params.runtime_environment_id = Number(filters.runtimeEnvironmentId)
    if (filters.messageUuid) params.message_uuid = filters.messageUuid
    if (filters.errorsOnly) params.errors_only = '1'
    if (filters.from) params.from = filters.from
    if (filters.to) params.to = filters.to
    if (filters.q) params.q = filters.q

    const fn = isPlatform ? ObservabilityCallLogs.listPlatform : ObservabilityCallLogs.listTenant
    fn(params)
      .then((r) => {
        setItems(r.items || [])
        setTotal(r.total)
      })
      .catch(() => {
        setItems([])
        setTotal(0)
      })
      .finally(() => setLoading(false))
  }, [actScope, isPlatform, filters, page, pageSize])

  useEffect(() => {
    const timer = window.setTimeout(() => fetchData(), 0)
    return () => window.clearTimeout(timer)
  }, [fetchData])

  const resetFilters = () => {
    setFilters({ ...DEFAULT_FILTERS })
    setPage(1)
  }

  if (switchingScope || !actScope) return null
  if (!isPlatform && !isTenant) {
    return <EmptyState title="选择管理范围" description="请先在左上角选择平台或租户后查看调用日志。" />
  }

  const hasFilters = filters.method || filters.httpStatus || filters.operation || filters.agentId || filters.agentName || filters.runtimeEnvironmentId || filters.messageUuid || filters.errorsOnly || filters.q || filters.from || filters.to

  return (
    <>
      <PageHeader
        title="调用日志"
        subtitle={isPlatform ? '所有租户 Runtime 出站调用记录' : '本租户 Runtime 出站调用记录'}
      />

      <Toolbar
        search={
          <SearchInput
            value={filters.q}
            onChange={(v) => { setFilters((f) => ({ ...f, q: v })); setPage(1) }}
            placeholder="搜索路径 / 服务 / Trace"
          />
        }
        filters={
          <>
            <div className="w-[132px]">
              <Select
                value={filters.method}
                onChange={(e) => { setFilters((f) => ({ ...f, method: e.target.value })); setPage(1) }}
              >
                {METHOD_OPTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </Select>
            </div>
            <div className="w-[104px]">
              <Input
                placeholder="状态码"
                value={filters.httpStatus}
                onChange={(e) => { setFilters((f) => ({ ...f, httpStatus: e.target.value.replace(/\D/g, '') })); setPage(1) }}
              />
            </div>
            <div className="w-[160px]">
              <Input
                placeholder="操作"
                value={filters.operation}
                onChange={(e) => { setFilters((f) => ({ ...f, operation: e.target.value })); setPage(1) }}
              />
            </div>
            {isPlatform && (
              <div className="w-[100px]">
                <Input
                  placeholder="租户 ID"
                  value={filters.tenantId}
                  onChange={(e) => { setFilters((f) => ({ ...f, tenantId: e.target.value.replace(/\D/g, '') })); setPage(1) }}
                />
              </div>
            )}
            <div className="w-[112px]">
              <Input
                placeholder="Agent ID"
                value={filters.agentId}
                onChange={(e) => { setFilters((f) => ({ ...f, agentId: e.target.value.replace(/\D/g, '') })); setPage(1) }}
              />
            </div>
            <div className="w-[148px]">
              <Input
                placeholder="数字员工名称"
                value={filters.agentName}
                onChange={(e) => { setFilters((f) => ({ ...f, agentName: e.target.value })); setPage(1) }}
              />
            </div>
            <div className="w-[132px]">
              <Input
                placeholder="运行环境 ID"
                value={filters.runtimeEnvironmentId}
                onChange={(e) => { setFilters((f) => ({ ...f, runtimeEnvironmentId: e.target.value.replace(/\D/g, '') })); setPage(1) }}
              />
            </div>
            <div className="w-[220px]">
              <Input
                placeholder="消息 UUID"
                value={filters.messageUuid}
                onChange={(e) => { setFilters((f) => ({ ...f, messageUuid: e.target.value })); setPage(1) }}
              />
            </div>
            <label className="flex h-9 cursor-pointer items-center gap-1.5 whitespace-nowrap rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] px-3 text-[13px] text-[var(--color-text-sub)]">
              <input
                type="checkbox"
                checked={filters.errorsOnly}
                onChange={(e) => { setFilters((f) => ({ ...f, errorsOnly: e.target.checked })); setPage(1) }}
              />
              仅错误
            </label>
          </>
        }
        actions={
          hasFilters ? (
            <Button variant="ghost" size="sm" onClick={resetFilters}><X size={14} /> 清除</Button>
          ) : undefined
        }
        summary={<span className="text-[12px] text-[var(--color-text-sub)]">共 {total} 条</span>}
      />

      <DataTable
        headers={['时间', '目标', '操作类型', 'Agent ID', '数字员工名称', '方法', '路径', '状态', '延迟', '错误', '操作']}
        stickyLastCol
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<Activity size={24} />}
            title="暂无调用日志"
            description="当前筛选条件下没有 Runtime 调用记录。"
          />
        ) : null}
      >
          {loading && <tr><td colSpan={COL_COUNT} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</td></tr>}
          {!loading && items.map((item) => (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)] cursor-pointer" onClick={() => setSelected(item)}>
              <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{fmtTime(item.createdAt)}</td>
              <td className="px-4 py-3 whitespace-nowrap text-[12px]">{item.targetService}</td>
              <td className="px-4 py-3 max-w-[160px] truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={item.operation || ''}>{item.operation || ''}</td>
              <td className="px-4 py-3 whitespace-nowrap font-mono text-[12px] text-[var(--color-text-sub)]">{getAgentId(item) || '—'}</td>
              <td className="px-4 py-3 max-w-[140px] truncate text-[12px]" title={getAgentName(item)}>{getAgentName(item) || '—'}</td>
              <td className="px-4 py-3 whitespace-nowrap font-mono text-[12px]">{item.method}</td>
              <td className="px-4 py-3 max-w-[300px] truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={item.path}>{item.path}</td>
              <td className="px-4 py-3 whitespace-nowrap">{statusBadge(item.httpStatus)}</td>
              <td className="px-4 py-3 whitespace-nowrap tabular-nums text-[12px]">{latencyLabel(item.latencyMs)}</td>
              <td className="px-4 py-3 max-w-[140px] truncate text-[12px] text-red-700" title={item.errorMessage || ''}>{item.errorMessage || ''}</td>
              <td className={`px-4 py-3 whitespace-nowrap ${stickyRightTdCls}`}>
                <Button variant="ghost" size="sm" onClick={(e) => { e.stopPropagation(); setSelected(item) }} title="详情" aria-label="查看调用详情">
                  <Eye size={14} />
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
        <CallLogDrawer
          entry={selected}
          isPlatform={isPlatform}
          onClose={() => setSelected(null)}
        />
      )}
    </>
  )
}
