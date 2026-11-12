// F09-B4-02: Orchestration 列表 (tenant scope).
//
// 路径 /rooms/orchestrations. 列出 agent_orchestrations 按 status/master/time/room 过滤;
// 行点 "查看" → /rooms/orchestrations/{uuid} 详情页 (Orchestrationdetail.tsx).
//
// ui.tsx primitives 复用; 无新 3rd-party 依赖.

import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { AdminOrchestrations, type AdminOrchestrationSummary } from '../lib/api'
import {
  DataTable,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  RowActions,
  Select,
} from '../components/ui'

const STATUS_OPTIONS = [
  { value: '', label: '全部状态' },
  { value: 'pending', label: 'pending' },
  { value: 'running', label: 'running' },
  { value: 'done', label: 'done' },
  { value: 'failed', label: 'failed' },
  { value: 'cancelled', label: 'cancelled' },
  { value: 'timed_out', label: 'timed_out' },
  { value: 'budget_exhausted', label: 'budget_exhausted' },
]

const WINDOWS = [
  { label: '近 24 小时', hours: 24 },
  { label: '近 7 天', hours: 24 * 7 },
  { label: '近 30 天', hours: 24 * 30 },
]

function defaultFrom(hours: number): string {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString()
}

export default function Orchestrations() {
  const [windowHours, setWindowHours] = useState(7 * 24)
  const [status, setStatus] = useState('')
  const [page, setPage] = useState(1)
  const pageSize = 20

  const [items, setItems] = useState<AdminOrchestrationSummary[]>([])
  const [total, setTotal] = useState(0)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    let mounted = true
    AdminOrchestrations.list({
      status: status || undefined,
      from: defaultFrom(windowHours),
      page,
      page_size: pageSize,
    })
      .then((res) => {
        if (!mounted) return
        setItems(res.items || [])
        setTotal(res.total)
        setLoading(false)
        setErr('')
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr((e as Error).message || '加载失败')
        setLoading(false)
      })
    return () => { mounted = false }
  }, [status, windowHours, page])

  return (
    <div className="p-6 space-y-4 max-w-7xl">
      <PageHeader title="协作编排" subtitle="主-子 Agent orchestration 记录、状态、预算消耗。" />

      <Panel>
        <FormSection title="过滤" description={`命中 ${total} 条`}>
          <div className="flex flex-wrap items-center gap-3">
            <div className="flex gap-2">
              {WINDOWS.map((w) => (
                <button
                  key={w.hours}
                  onClick={() => { setWindowHours(w.hours); setPage(1) }}
                  className={`h-8 px-3 rounded text-xs border ${
                    windowHours === w.hours
                      ? 'border-[var(--color-brand)] bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
                      : 'border-[var(--color-line)] bg-[var(--color-surface)] text-[var(--color-text-sub)]'
                  }`}
                >
                  {w.label}
                </button>
              ))}
            </div>
            <FormField label="状态">
              <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
                {STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </Select>
            </FormField>
          </div>
        </FormSection>
      </Panel>

      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <DataTable
        headers={['时间', '主 Agent', '状态', '计划摘要', '预算 (token)', '已用 (in/out)', '调用边', '最大 depth', '操作']}
      >
        {loading && items.length === 0 ? null : items.length === 0 ? (
          <tr>
            <td colSpan={9} className="px-3 py-8">
              <EmptyState title="窗内无 orchestration 记录" description="尝试加宽时间窗或修改状态过滤。" />
            </td>
          </tr>
        ) : items.map((o) => (
          <tr key={o.uuid} className="border-t border-[var(--color-line-soft)]">
            <td className="px-3 py-2 text-xs text-[var(--color-text-sub)]">{new Date(o.created_at).toLocaleString('zh-CN', { hour12: false })}</td>
            <td className="px-3 py-2">{o.master_agent_name || `#${o.master_agent_id}`}</td>
            <td className="px-3 py-2"><StatusBadge status={o.status} /></td>
            <td className="px-3 py-2 max-w-md truncate text-xs text-[var(--color-text-sub)]" title={o.plan_summary || ''}>
              {o.plan_summary || <span className="italic text-[var(--color-text-mute)]">(无摘要)</span>}
            </td>
            <td className="px-3 py-2 text-right tabular-nums">{o.token_budget}</td>
            <td className="px-3 py-2 text-right tabular-nums text-xs text-[var(--color-text-sub)]">{o.tokens_in_total}/{o.tokens_out_total}</td>
            <td className="px-3 py-2 text-right tabular-nums">{o.edges_count}</td>
            <td className="px-3 py-2 text-right tabular-nums">{o.max_depth_reached}</td>
            <td className="px-3 py-2 sticky right-0 bg-[var(--color-surface)]">
              <RowActions
                extras={
                  <Link to={`/rooms/orchestrations/${o.uuid}`} className="text-[var(--color-brand)] hover:underline">查看</Link>
                }
              />
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination page={page} pageSize={pageSize} total={total} onPageChange={setPage} onPageSizeChange={() => { /* fixed */ }} />
    </div>
  )
}

function StatusBadge({ status }: { status: string }) {
  const tone =
    status === 'done' ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
    : status === 'failed' || status === 'cancelled' || status === 'timed_out' || status === 'budget_exhausted' ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
    : status === 'running' || status === 'pending' ? 'bg-[var(--color-info-bg)] text-[var(--color-info)]'
    : 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]'
  return <span className={`inline-flex px-2 py-0.5 rounded text-xs ${tone}`}>{status}</span>
}
