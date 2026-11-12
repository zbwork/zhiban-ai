// M8 Phase B sprint · KB 详情页 (概览 / 调优 recall-test / 引用统计 / 审计)
// 路径: /kb/:uuid?tab=docs|tune|stats|audit
//
// 权限: tenant.kb.read / tenant.kb.recall / tenant.kb.update / tenant.kb.read_audit; 后端最终把关.

import { useEffect, useState, type ReactNode } from 'react'
import { useParams, useSearchParams, Link } from 'react-router-dom'
import { Button, Input, FormField, Tabs, InlineAlert } from '../components/ui'
import {
  ManagedKB,
  TenantKB,
  type KBRecallTestResp,
  type KBRecallLogItem,
  type KBReferenceStats,
  type TenantKBItem,
  type ManagedKBScope,
} from '../lib/api'
import { ArrowLeft, BookOpen, FileText, Gauge, ShieldCheck, UserRound } from 'lucide-react'
import { KBContentPanel } from '../components/kb/KBContentPanel'

type TabKey = 'overview' | 'docs' | 'tune' | 'stats' | 'audit'

export function KBDetailPage() {
  return <ManagedKBDetailPage scope="tenant" />
}

export function PlatformKBDetailPage() {
  return <ManagedKBDetailPage scope="platform" />
}

function ManagedKBDetailPage({ scope }: { scope: ManagedKBScope }) {
  const { uuid = '' } = useParams()
  const [search, setSearch] = useSearchParams()
  const initTab = (search.get('tab') as TabKey) || 'overview'
  const [tab, setTab] = useState<TabKey>(initTab)
  const [kb, setKb] = useState<TenantKBItem | null>(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    ManagedKB.get(scope, uuid)
	  .then(setKb)
	  .catch((e: Error) => setErr(e.message))
  }, [scope, uuid])

  const switchTab = (k: TabKey) => {
    setTab(k)
    const sp = new URLSearchParams(search)
    sp.set('tab', k)
    setSearch(sp, { replace: true })
  }

  return (
    <div className="mx-auto max-w-[1320px]">
      <div className="mb-5 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <Link to={scope === 'platform' ? '/platform-kb' : '/kb'} className="mb-2 inline-flex">
            <Button size="sm" variant="ghost"><ArrowLeft size={14} /> 返回</Button>
          </Link>
          <h1 className="truncate text-[28px] font-semibold tracking-tight">{kb?.name || '知识库详情'}</h1>
          <p className="mt-1 text-sm text-[var(--color-text-sub)]">
            {scope === 'platform' ? '维护平台知识库目录和文件；已就绪内容可装配给平台数字员工模版。' : '维护目录和文件，并执行召回调优、引用统计和审计排查。'}
          </p>
        </div>
      </div>
      {err && <InlineAlert>{err}</InlineAlert>}

      <Tabs<TabKey>
        value={tab}
        onChange={switchTab}
        className="w-full overflow-x-auto"
        items={[
          { value: 'overview', label: '概览' },
          { value: 'docs', label: '文档' },
          { value: 'tune' as const, label: '调优' },
          ...(scope === 'tenant' ? [
            { value: 'stats' as const, label: '引用统计' },
            { value: 'audit' as const, label: '审计' },
          ] : []),
        ]}
      />

      <div className="mt-6">
        {tab === 'overview' && <Overview kb={kb} />}
        {tab === 'docs' && <KBContentPanel scope={scope} kbUuid={uuid} kbName={kb?.name || '知识库根目录'} />}
        {tab === 'tune' && <TunePanel scope={scope} uuid={uuid} />}
        {scope === 'tenant' && tab === 'stats' && <StatsPanel uuid={uuid} />}
        {scope === 'tenant' && tab === 'audit' && <AuditPanel uuid={uuid} />}
      </div>
    </div>
  )
}

function Overview({ kb }: { kb: TenantKBItem | null }) {
  if (!kb) return <div className="text-[var(--color-ink-mute)]">加载中…</div>
  const owner = ownerSummary(kb)
  const rows = [
    ['UUID', kb.uuid],
    ['归属', `${owner.label}${owner.meta ? ` / ${owner.meta}` : ''}`],
    ['服务', kb.provider_kind || '—'],
    ['RAGFlow Dataset', kb.ragflow_dataset_id || '—'],
    ['Provision', kb.provision_status || '—'],
    ['创建时间', formatDate(kb.created_at)],
  ]
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 gap-3 md:grid-cols-4">
        <OverviewMetric icon={<ShieldCheck size={16} />} label="状态" value={kb.status || '—'} />
        <OverviewMetric icon={<UserRound size={16} />} label="归属" value={owner.label} />
        <OverviewMetric icon={<FileText size={16} />} label="文档数" value={kb.total_documents ?? '—'} />
        <OverviewMetric icon={<BookOpen size={16} />} label="可见性" value={kb.visibility || '—'} />
      </div>
      <section className="rounded-lg border border-[var(--color-line)] bg-white p-5 shadow-[0_1px_0_rgba(23,23,23,0.02)]">
        <div className="mb-4 flex items-center gap-2 text-[15px] font-semibold text-[var(--color-text)]">
          <Gauge size={16} /> 基础信息
        </div>
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          {rows.map(([label, value]) => (
            <div key={label} className="min-w-0 rounded-md bg-[var(--color-bg-sub)] px-3 py-2">
              <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
              <div className="mt-1 truncate font-mono text-[13px] text-[var(--color-text)]" title={String(value)}>{value}</div>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}

function ownerSummary(kb: TenantKBItem) {
  if (kb.space_kind === 'platform') return { label: '平台内置', meta: '数字员工专用' }
  const isUserOwned = kb.space_kind === 'personal' || kb.visibility === 'private'
  if (!isUserOwned) return { label: '租户共享', meta: '租户级' }
  const id = kb.owner_account_id || kb.creator_id
  return { label: '用户私有', meta: id ? `用户ID #${id}` : '用户ID -' }
}

function OverviewMetric({
  icon,
  label,
  value,
}: {
  icon: ReactNode
  label: string
  value: number | string
}) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-3">
      <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-mute)]">
        {icon}
        {label}
      </div>
      <div className="mt-2 truncate text-[20px] font-semibold text-[var(--color-text)]">{value}</div>
    </div>
  )
}

function formatDate(value?: string) {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

function TunePanel({ scope, uuid }: { scope: ManagedKBScope; uuid: string }) {
  const [query, setQuery] = useState('')
  const [topK, setTopK] = useState(5)
  const [threshold, setThreshold] = useState(0.4)
  const [resp, setResp] = useState<KBRecallTestResp | null>(null)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  const run = async () => {
    setErr(''); setLoading(true)
    try {
      const r = await ManagedKB.recallTest(scope, uuid, { query, top_k: topK, threshold })
      setResp(r)
    } catch (e) { setErr((e as Error).message) }
    finally { setLoading(false) }
  }

  return (
    <div className="grid grid-cols-1 gap-4 xl:grid-cols-[420px_minmax(0,1fr)]">
      <div className="min-w-0 rounded-lg border border-[var(--color-line)] bg-white p-5 shadow-[0_1px_0_rgba(23,23,23,0.02)]">
        <div className="mb-4 text-[15px] font-semibold text-[var(--color-text)]">召回试问</div>
        <FormField label="试问 query">
          <textarea
            className="h-28 w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-sm outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="输入要测试的检索问题"
          />
        </FormField>
        <FormField label={`top_k = ${topK}`}>
          <input type="range" min={1} max={20} value={topK} onChange={(e) => setTopK(Number(e.target.value))} className="w-full" />
        </FormField>
        <FormField label={`threshold = ${threshold.toFixed(2)}`}>
          <input type="range" min={0} max={1} step={0.05} value={threshold} onChange={(e) => setThreshold(Number(e.target.value))} className="w-full" />
        </FormField>
        <Button onClick={run} disabled={!query.trim() || loading}>{loading ? '召回中…' : '召回试问'}</Button>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>

      <div className="min-w-0 rounded-lg border border-[var(--color-line)] bg-white p-5 shadow-[0_1px_0_rgba(23,23,23,0.02)]">
        <div className="mb-2 text-[15px] font-semibold text-[var(--color-text)]">召回结果</div>
        {!resp && <div className="text-[13px] text-[var(--color-text-mute)]">点击“召回试问”后显示命中片段。</div>}
        {resp && (
          <div className="space-y-3">
            <div className="text-xs text-[var(--color-text-sub)]">命中 {resp.chunks.length} 条</div>
            {resp.chunks.map((c, i) => (
              <div key={c.uuid || i} className="rounded-md border border-[var(--color-line)] p-3">
                <div className="flex justify-between text-xs text-[var(--color-ink-sub)] mb-1">
                  <span>rank #{i + 1} · doc={c.document_id ?? '—'} · chunk={c.chunk_index ?? '—'}</span>
                  <span className="font-mono">score={c.score.toFixed(3)}</span>
                </div>
                <pre className="text-xs whitespace-pre-wrap text-[var(--color-ink)] max-h-32 overflow-y-auto">{c.content}</pre>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function StatsPanel({ uuid }: { uuid: string }) {
  const [stats, setStats] = useState<KBReferenceStats | null>(null)
  const [days, setDays] = useState(30)
  const [err, setErr] = useState('')
  useEffect(() => {
    TenantKB.referenceStats(uuid, days)
      .then(setStats)
      .catch((e: Error) => setErr(e.message))
  }, [uuid, days])

  return (
    <div>
      <div className="flex gap-3 items-center mb-4">
        <span className="text-sm">窗口:</span>
        {[7, 30, 90].map((d) => (
          <Button key={d} size="sm" variant={d === days ? 'primary' : 'ghost'} onClick={() => setDays(d)}>{d}d</Button>
        ))}
      </div>
      {err && <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] rounded-md p-3 mb-4">{err}</div>}
      {!stats && <div className="text-[var(--color-ink-mute)]">加载中…</div>}
      {stats && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <StatCard label="总召回" value={stats.total} />
          <StatCard label="命中" value={stats.hit} />
          <StatCard label="错误" value={stats.err} />
          <StatCard label="avg 延迟 (ms)" value={Math.round(stats.avg_latency_ms)} />
          <StatCard label="agent 召回" value={stats.agent_count} />
          <StatCard label="user 召回" value={stats.user_count} />
        </div>
      )}
    </div>
  )
}

function StatCard({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="bg-white rounded-lg card-shadow p-5">
      <div className="text-xs text-[var(--color-ink-sub)]">{label}</div>
      <div className="text-2xl font-semibold mt-1">{value}</div>
    </div>
  )
}

function AuditPanel({ uuid }: { uuid: string }) {
  const [items, setItems] = useState<KBRecallLogItem[]>([])
  const [limit, setLimit] = useState(100)
  const [err, setErr] = useState('')
  useEffect(() => {
    TenantKB.recallLogs(uuid, limit)
      .then((r) => setItems(r.items || []))
      .catch((e: Error) => setErr(e.message))
  }, [uuid, limit])

  return (
    <div>
      <div className="flex gap-2 items-center mb-3">
        <span className="text-sm">最近</span>
        <Input value={String(limit)} onChange={(e) => setLimit(Number(e.target.value) || 100)} className="w-24" />
        <span className="text-sm">条</span>
      </div>
      {err && <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] rounded-md p-3 mb-4">{err}</div>}
      <div className="bg-white rounded-lg card-shadow overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
            <tr>
              <th className="px-3 py-2 font-medium">时间</th>
              <th className="px-3 py-2 font-medium">caller</th>
              <th className="px-3 py-2 font-medium">query</th>
              <th className="px-3 py-2 font-medium">top_k/阈值</th>
              <th className="px-3 py-2 font-medium">命中</th>
              <th className="px-3 py-2 font-medium">top score</th>
              <th className="px-3 py-2 font-medium">耗时</th>
              <th className="px-3 py-2 font-medium">错误</th>
            </tr>
          </thead>
          <tbody>
            {items.map((l, i) => (
              <tr key={i} className="border-t border-[var(--color-line)]">
                <td className="px-3 py-2 text-xs">{l.occurred_at}</td>
                <td className="px-3 py-2 text-xs">{l.caller_kind}{l.account_id ? `#${l.account_id}` : ''}{l.agent_id ? `agent#${l.agent_id}` : ''}</td>
                <td className="px-3 py-2 text-xs max-w-xs truncate" title={l.query_text}>{l.query_text}</td>
                <td className="px-3 py-2 text-xs">{l.top_k} / {l.threshold.toFixed(2)}</td>
                <td className="px-3 py-2 text-xs">{l.chunk_hits}</td>
                <td className="px-3 py-2 text-xs font-mono">{l.score_top.toFixed(3)}</td>
                <td className="px-3 py-2 text-xs">{l.latency_ms} ms</td>
                <td className="px-3 py-2 text-xs text-[var(--color-danger)]">{l.error_code || '—'}</td>
              </tr>
            ))}
            {!items.length && (
              <tr><td colSpan={8} className="px-3 py-8 text-center text-[var(--color-ink-mute)]">无召回历史</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
