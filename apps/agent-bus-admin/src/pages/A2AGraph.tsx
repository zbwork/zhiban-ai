// F09-B4-01 / B4-04: A2A 调用治理.
//
// 路径 /rooms/a2a (tenant scope). 列出 a2a_call_edges 按时间窗 + agent/room/orch/status 过滤;
// 行 RowActions 「查看」打开 DrawerShell 详情, 含 redacted payload (admin 无权解 redact).
// 顶部一个轻量 SVG mini chart 显示按 from agent 的出度分布 (辅助; 节点 ≥ 12 退化为列表条).
//
// 与 admin-web-design-standard §4 一致: ui.tsx primitives (PageHeader / Toolbar / Select / FormField /
// DataTable / Pagination / DrawerShell / EmptyState / InlineAlert / RowActions).
//
// 不引入 force-graph 之类 3rd-party 依赖 (用户拍板).

import { useEffect, useMemo, useState } from 'react'
import {
  AdminA2A,
  type AdminA2AEdgeSummary,
  type AdminA2AEdgeDetail,
  type AdminA2AAgentNode,
} from '../lib/api'
import {
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  RowActions,
  SearchInput,
  Select,
} from '../components/ui'

function defaultFrom(hours = 24): string {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString()
}

const STATUS_OPTIONS = [
  { value: '', label: '全部状态' },
  { value: 'pending', label: 'pending' },
  { value: 'running', label: 'running' },
  { value: 'done', label: 'done' },
  { value: 'failed', label: 'failed' },
  { value: 'cancelled', label: 'cancelled' },
  { value: 'dropped_loop', label: 'dropped_loop' },
  { value: 'dropped_budget', label: 'dropped_budget' },
  { value: 'dropped_whitelist', label: 'dropped_whitelist' },
]

const WINDOW_PRESETS = [
  { label: '近 1 小时', hours: 1 },
  { label: '近 24 小时', hours: 24 },
  { label: '近 7 天', hours: 24 * 7 },
  { label: '近 30 天', hours: 24 * 30 },
]

export default function A2AGraph() {
  const [windowHours, setWindowHours] = useState(24)
  const [from, setFrom] = useState<string>(() => defaultFrom(24))
  const [status, setStatus] = useState('')
  const [agentFilter, setAgentFilter] = useState('')
  const [page, setPage] = useState(1)
  const pageSize = 20

  const [items, setItems] = useState<AdminA2AEdgeSummary[]>([])
  const [total, setTotal] = useState(0)
  const [agentNodes, setAgentNodes] = useState<AdminA2AAgentNode[]>([])
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  const [openDetail, setOpenDetail] = useState<AdminA2AEdgeDetail | null>(null)

  useEffect(() => {
    let mounted = true
    const fromAgent = agentFilter.trim() || undefined
    Promise.all([
      AdminA2A.list({
        from,
        to: undefined,
        status: status || undefined,
        from_agent_id: fromAgent,
        page,
        page_size: pageSize,
      }),
      AdminA2A.agentNodes({ from }),
    ])
      .then(([listRes, nodesRes]) => {
        if (!mounted) return
        setItems(listRes.items || [])
        setTotal(listRes.total)
        setAgentNodes(nodesRes.items || [])
        setLoading(false)
        setErr('')
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr((e as Error).message || '加载失败')
        setLoading(false)
      })
    return () => { mounted = false }
  }, [from, status, agentFilter, page])

  function applyWindow(hours: number) {
    setWindowHours(hours)
    setFrom(defaultFrom(hours))
    setPage(1)
  }

  async function openEdge(e: AdminA2AEdgeSummary) {
    try {
      const detail = await AdminA2A.get(e.id, e.created_at)
      setOpenDetail(detail)
    } catch (err: unknown) {
      setErr((err as Error).message || '加载详情失败')
    }
  }

  const totalEdges = items.length

  return (
    <div className="p-6 space-y-4 max-w-7xl">
      <PageHeader
        title="A2A 调用治理"
        subtitle="本租户 Agent-to-Agent 调用边、出入度、payload (已 redact)。"
      />

      <Panel>
        <FormSection title="过滤" description={`时间窗: ${WINDOW_PRESETS.find((p) => p.hours === windowHours)?.label ?? '自定义'} · 命中 ${total} 条`}>
          <div className="flex flex-wrap items-center gap-3">
            <div className="flex flex-wrap gap-2">
              {WINDOW_PRESETS.map((p) => (
                <button
                  key={p.hours}
                  onClick={() => applyWindow(p.hours)}
                  className={`h-8 px-3 rounded text-xs border ${
                    windowHours === p.hours
                      ? 'border-[var(--color-brand)] bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
                      : 'border-[var(--color-line)] bg-[var(--color-surface)] text-[var(--color-text-sub)]'
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>
            <FormField label="状态">
              <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
                {STATUS_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </Select>
            </FormField>
            <SearchInput
              value={agentFilter}
              onChange={(v) => { setAgentFilter(v); setPage(1) }}
              placeholder="发起数字员工 ID..."
            />
          </div>
        </FormSection>
      </Panel>

      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      {/* Mini bar chart: 出度 top 8; 节点 ≥ 12 退化为说明文字 (admin-web-design-standard §4 + 用户拍板). */}
      {agentNodes.length > 0 && (
        <Panel>
          <FormSection title="Agent 出/入度概览" description={`时间窗内涉及 ${agentNodes.length} 个 Agent (前 8 个按总度排序)`}>
            <MiniDegreeChart nodes={agentNodes.slice(0, 8)} />
          </FormSection>
        </Panel>
      )}

      <DataTable
        headers={['时间', 'From Agent', 'To Agent', '调用', 'Depth', '状态', 'Tokens (in/out)', '耗时 (ms)', '操作']}
      >
        {loading && totalEdges === 0 ? null : totalEdges === 0 ? (
          <tr>
            <td colSpan={9} className="px-3 py-8">
              <EmptyState title="时间窗内无 A2A 调用" description="尝试加宽时间窗或检查 from_agent_id 过滤。" />
            </td>
          </tr>
        ) : (
          items.map((e) => (
            <tr key={`${e.id}-${e.created_at}`} className="border-t border-[var(--color-line-soft)]">
              <td className="px-3 py-2 text-xs text-[var(--color-text-sub)]">{formatTime(e.created_at)}</td>
              <td className="px-3 py-2">{e.from_agent_name || e.from_agent_id}</td>
              <td className="px-3 py-2">{e.to_agent_name || e.to_agent_id}</td>
              <td className="px-3 py-2">{e.invoke_kind}</td>
              <td className="px-3 py-2 text-right">{e.depth}</td>
              <td className="px-3 py-2"><StatusBadge status={e.status} /></td>
              <td className="px-3 py-2 text-right text-xs text-[var(--color-text-sub)]">
                {e.tokens_in}/{e.tokens_out}
              </td>
              <td className="px-3 py-2 text-right text-xs text-[var(--color-text-sub)]">
                {e.latency_ms ?? '-'}
              </td>
              <td className="px-3 py-2 sticky right-0 bg-[var(--color-surface)]">
                <RowActions
                  extras={
                    <button onClick={() => void openEdge(e)} className="text-[var(--color-brand)] hover:underline">查看</button>
                  }
                />
              </td>
            </tr>
          ))
        )}
      </DataTable>

      <Pagination page={page} pageSize={pageSize} total={total} onPageChange={setPage} onPageSizeChange={() => { /* fixed page_size in PR8; admin 不切换 */ }} />

      {openDetail && <EdgeDetailDrawer edge={openDetail} onClose={() => setOpenDetail(null)} />}
    </div>
  )
}

// ----- mini chart -----

function MiniDegreeChart({ nodes }: { nodes: AdminA2AAgentNode[] }) {
  const max = useMemo(() => Math.max(1, ...nodes.map((n) => n.out_degree + n.in_degree)), [nodes])
  return (
    <div className="space-y-1.5">
      {nodes.map((n) => {
        const total = n.out_degree + n.in_degree
        const widthPct = Math.round((total / max) * 100)
        const failPct = n.out_degree > 0 ? Math.round((n.failed_out / n.out_degree) * 100) : 0
        return (
          <div key={n.agent_id} className="flex items-center gap-3 text-xs">
            <div className="w-40 truncate text-[var(--color-text-sub)]" title={n.agent_id}>
              {n.agent_name || n.agent_id}
            </div>
            <div className="flex-1 h-3 rounded bg-[var(--color-bg-sub)] overflow-hidden relative">
              <div
                className="absolute inset-y-0 left-0 bg-[var(--color-brand)] opacity-80"
                style={{ width: `${widthPct}%` }}
              />
            </div>
            <div className="w-44 tabular-nums text-[var(--color-text-mute)]">
              出 {n.out_degree} · 入 {n.in_degree}
              {failPct > 0 && <span className="ml-1 text-[var(--color-danger)]">·失败 {failPct}%</span>}
            </div>
          </div>
        )
      })}
    </div>
  )
}

// ----- detail drawer -----

function EdgeDetailDrawer({ edge, onClose }: { edge: AdminA2AEdgeDetail; onClose: () => void }) {
  const reqText = useMemo(() => safeJSONString(edge.request_payload), [edge.request_payload])
  const respText = useMemo(() => safeJSONString(edge.response_payload), [edge.response_payload])
  return (
    <DrawerShell onClose={onClose} title={`A2A edge · ${edge.id.slice(0, 8)}`} variant="polished">
      <div className="space-y-4">
        <FormSection title="基础">
          <KVRow k="Edge ID" v={edge.id} mono />
          <KVRow k="创建时间" v={formatTime(edge.created_at)} />
          <KVRow k="状态" v={<StatusBadge status={edge.status} />} />
          <KVRow k="调用形态" v={edge.invoke_kind} />
          <KVRow k="From Agent" v={`${edge.from_agent_name || '?'} (${edge.from_agent_id})`} />
          <KVRow k="To Agent" v={`${edge.to_agent_name || '?'} (${edge.to_agent_id})`} />
          <KVRow k="Depth" v={String(edge.depth)} />
          <KVRow k="idem_key" v={edge.idem_key} mono />
          {edge.parent_edge_id && <KVRow k="父 edge" v={edge.parent_edge_id} mono />}
          {edge.orchestration_id && <KVRow k="Orchestration" v={edge.orchestration_id} mono />}
          {edge.room_id && <KVRow k="Room" v={edge.room_id} mono />}
        </FormSection>

        <FormSection title="计量">
          <KVRow k="Tokens in/out" v={`${edge.tokens_in} / ${edge.tokens_out}`} />
          {typeof edge.latency_ms === 'number' && <KVRow k="耗时 (ms)" v={String(edge.latency_ms)} />}
          {edge.started_at && <KVRow k="started_at" v={formatTime(edge.started_at)} />}
          {edge.completed_at && <KVRow k="completed_at" v={formatTime(edge.completed_at)} />}
          {edge.error_message && <KVRow k="错误" v={<span className="text-[var(--color-danger)]">{edge.error_message}</span>} />}
        </FormSection>

        <FormSection
          title="请求 Payload (已 redact)"
          description="PII 字段被替换为 [REDACTED:*]; admin 无权解 redact (F09 §4.7.4)。"
        >
          <pre className="bg-[var(--color-bg-sub)] border border-[var(--color-line-soft)] rounded p-3 text-xs font-mono overflow-x-auto whitespace-pre-wrap max-h-72">
            {highlightRedacted(reqText)}
          </pre>
        </FormSection>

        <FormSection title="响应 Payload (已 redact)">
          <pre className="bg-[var(--color-bg-sub)] border border-[var(--color-line-soft)] rounded p-3 text-xs font-mono overflow-x-auto whitespace-pre-wrap max-h-72">
            {highlightRedacted(respText)}
          </pre>
        </FormSection>
      </div>
    </DrawerShell>
  )
}

// ----- helpers -----

function KVRow({ k, v, mono }: { k: string; v: React.ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline gap-3 text-sm py-0.5">
      <div className="w-32 shrink-0 text-[var(--color-text-mute)]">{k}</div>
      <div className={`flex-1 ${mono ? 'font-mono text-xs break-all' : ''}`}>{v}</div>
    </div>
  )
}

function StatusBadge({ status }: { status: string }) {
  const tone =
    status === 'done' ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
    : status === 'failed' || status.startsWith('dropped_') ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
    : status === 'running' || status === 'pending' ? 'bg-[var(--color-info-bg)] text-[var(--color-info)]'
    : 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]'
  return <span className={`inline-flex px-2 py-0.5 rounded text-xs ${tone}`}>{status}</span>
}

function formatTime(iso?: string): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('zh-CN', { hour12: false })
}

function safeJSONString(v: unknown): string {
  if (v == null) return '(空)'
  if (typeof v === 'string') return v
  try {
    return JSON.stringify(v, null, 2)
  } catch {
    return String(v)
  }
}

// highlight [REDACTED:*] markers — 让 admin 一眼看出哪些字段被 redact 了.
function highlightRedacted(s: string): React.ReactNode {
  const parts: React.ReactNode[] = []
  const re = /\[REDACTED:[a-zA-Z_-]+\]/g
  let lastIdx = 0
  let match: RegExpExecArray | null
  let key = 0
  while ((match = re.exec(s)) !== null) {
    if (match.index > lastIdx) parts.push(s.slice(lastIdx, match.index))
    parts.push(
      <span key={key++} className="bg-[var(--color-warn-bg)] text-[var(--color-warn)] px-1 rounded">
        {match[0]}
      </span>,
    )
    lastIdx = match.index + match[0].length
  }
  if (lastIdx < s.length) parts.push(s.slice(lastIdx))
  return parts
}
