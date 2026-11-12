// 回复反馈（数据线第一批，契约 §2.9b）：创业助手站 AI 回复的 👍👎 与点踩
// 分类回看——质量信号源。口径与后续指标批次见 baigong spec
// 2026-08-14-baigong-p0-metrics-and-feedback-review.md。
import { useCallback, useEffect, useMemo, useState } from 'react'
import { RefreshCw } from 'lucide-react'

import {
  Button,
  DataTable,
  EmptyState,
  FormSection,
  InlineAlert,
  KpiCard,
  LineTrendChart,
  PageHeader,
  Pagination,
  Select,
  Toolbar,
  type TrendChartPoint,
} from '../components/ui'
import { WebLeads, type WebFeedbackItem, type WebFeedbackStats } from '../lib/api'

const DAY_OPTIONS = [
  { value: 7, label: '近 7 天' },
  { value: 30, label: '近 30 天' },
  { value: 90, label: '近 90 天' },
]

const VERDICT_OPTIONS = [
  { value: '', label: '全部评价' },
  { value: 'up', label: '有帮助' },
  { value: 'down', label: '没帮到' },
]

const fmtTime = (iso: string) => iso.slice(0, 16).replace('T', ' ')

export function StartupFeedbackPage() {
  const [days, setDays] = useState(30)
  const [stats, setStats] = useState<WebFeedbackStats | null>(null)
  const [error, setError] = useState('')
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    let cancelled = false
    WebLeads.feedbackStats(days)
      .then((res) => { if (!cancelled) { setStats(res); setError('') } })
      .catch((e: unknown) => {
        if (!cancelled) setError(e instanceof Error ? e.message : '反馈统计加载失败')
      })
    return () => { cancelled = true }
  }, [days, reloadKey])

  // 明细独立分页；评价筛选变化时页码重置为 1
  const [verdict, setVerdict] = useState('')
  const [items, setItems] = useState<WebFeedbackItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)

  useEffect(() => {
    let cancelled = false
    WebLeads.feedback({ verdict: verdict || undefined, limit: pageSize, offset: (page - 1) * pageSize })
      .then((res) => {
        if (cancelled) return
        setItems(res.items ?? [])
        setTotal(res.total ?? 0)
      })
      .catch(() => { if (!cancelled) setItems([]) })
    return () => { cancelled = true }
  }, [verdict, page, pageSize, reloadKey])

  const load = useCallback(() => setReloadKey((k) => k + 1), [])

  const goodRate = useMemo(() => {
    if (!stats) return '—'
    const sum = stats.up + stats.down
    return sum > 0 ? `${((stats.up / sum) * 100).toFixed(1)}%` : '—'
  }, [stats])

  const reasonRows = useMemo(() => {
    if (!stats?.reasons) return []
    return Object.entries(stats.reasons).sort((a, b) => b[1] - a[1])
  }, [stats])

  const reasonMax = useMemo(
    () => Math.max(1, ...reasonRows.map(([, n]) => n)),
    [reasonRows],
  )

  const trendPoints: TrendChartPoint[] = useMemo(() => {
    if (!stats?.daily) return []
    return stats.daily.map((d) => ({
      label: d.date.slice(5),
      title: d.date,
      values: { up: d.up, down: d.down },
    }))
  }, [stats])

  return (
    <div>
      <PageHeader
        title="回复反馈"
        subtitle="创业助手站每条 AI 回复下的「有帮助 / 没帮到」与点踩原因。这是回答质量的第一信号源：分类分布指向该修的方向，明细可回溯当轮问答摘录。"
      />

      <Toolbar
        filters={
          <div className="flex items-center gap-2">
            <div className="w-[140px]">
              <Select value={days} onChange={(e) => setDays(Number(e.target.value))}>
                {DAY_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </Select>
            </div>
            <div className="w-[140px]">
              <Select
                value={verdict}
                onChange={(e) => { setVerdict(e.target.value); setPage(1) }}
              >
                {VERDICT_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </Select>
            </div>
          </div>
        }
        summary={stats ? `统计区间 ${stats.days} 天` : undefined}
        actions={
          <Button variant="ghost" onClick={load}>
            <RefreshCw size={14} className="mr-1" />
            刷新
          </Button>
        }
      />

      {error && (
        <div className="mb-3">
          <InlineAlert tone="danger">{error}</InlineAlert>
        </div>
      )}

      {stats && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
            <KpiCard label="有帮助" value={stats.up.toLocaleString('zh-CN')} tone="success" />
            <KpiCard label="没帮到" value={stats.down.toLocaleString('zh-CN')} />
            <KpiCard label="好评率" value={goodRate} hint="有帮助 ÷ 总反馈" tone="success" />
            <KpiCard label="总反馈" value={(stats.up + stats.down).toLocaleString('zh-CN')} />
          </div>

          <FormSection
            title="点踩原因分布"
            description="四个分类来自点踩后的原因药丸，自由文字归入「其他」；分布指向优先要修的质量方向。"
          >
            {reasonRows.length === 0 ? (
              <EmptyState
                title="暂无点踩原因"
                description="用户点「没帮到」并选择原因后，会在这里按分类汇总。"
              />
            ) : (
              <div className="space-y-2">
                {reasonRows.map(([reason, count]) => (
                  <div key={reason} className="flex items-center gap-3">
                    <div className="w-[80px] shrink-0 text-[13px] text-[var(--color-text)]">{reason}</div>
                    <div className="h-7 flex-1 rounded bg-[var(--color-bg-sub)]">
                      <div
                        className="flex h-7 items-center rounded bg-[var(--color-brand-soft)] px-2"
                        style={{ width: `${Math.max(6, (count / reasonMax) * 100)}%` }}
                      >
                        <span className="text-[12.5px] font-medium tabular-nums text-[var(--color-brand)]">
                          {count}
                        </span>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </FormSection>

          <FormSection
            title="每日趋势"
            description="正负反馈的按日走势，用于观察版本发布与内容调整的即时反应。"
            className="mt-4"
          >
            <LineTrendChart
              points={trendPoints}
              series={[
                { key: 'up', label: '有帮助', color: 'var(--color-icon-green)' },
                { key: 'down', label: '没帮到', color: 'var(--color-icon-red)' },
              ]}
              emptyText="这个区间还没有反馈数据"
            />
          </FormSection>
        </>
      )}

      <FormSection
        title="反馈明细"
        description="按时间倒序；问答均为摘录（各 240 字内），完整对话按会话号回创业助手侧转写查看。"
        className="mt-4"
      >
        {items.length === 0 ? (
          <EmptyState
            title="暂无反馈"
            description="用户在创业助手站对回复点「有帮助 / 没帮到」后，会出现在这里。"
          />
        ) : (
          <>
            <DataTable headers={['时间', '评价', '原因', '用户问题', 'AI 回复摘录', '会话']}>
              {items.map((it) => (
                <tr key={it.id}>
                  <td className="whitespace-nowrap px-4 py-2.5 text-[var(--color-text-sub)]">
                    {fmtTime(it.created_at)}
                  </td>
                  <td className="whitespace-nowrap px-4 py-2.5">
                    <span
                      className={
                        it.verdict === 'up'
                          ? 'text-[var(--color-icon-green)]'
                          : 'text-[var(--color-icon-red)]'
                      }
                    >
                      {it.verdict === 'up' ? '有帮助' : '没帮到'}
                    </span>
                  </td>
                  <td className="whitespace-nowrap px-4 py-2.5 text-[var(--color-text-sub)]">
                    {it.reason || '—'}
                  </td>
                  <td className="max-w-[260px] px-4 py-2.5 text-[var(--color-text-sub)]">
                    <span className="line-clamp-2">{it.q_excerpt || '—'}</span>
                  </td>
                  <td className="max-w-[320px] px-4 py-2.5 text-[var(--color-text-sub)]">
                    <span className="line-clamp-2">{it.a_excerpt || '—'}</span>
                  </td>
                  <td className="whitespace-nowrap px-4 py-2.5 font-mono text-[12px] text-[var(--color-text-mute)]">
                    {it.session_id.slice(0, 8)}
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
          </>
        )}
      </FormSection>
    </div>
  )
}
