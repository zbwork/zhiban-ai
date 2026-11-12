import { useEffect, useMemo, useState, type ComponentType, type ReactNode } from 'react'
import { DownloadCloud, Eye, Percent, Share2, UserRoundCheck, UsersRound } from 'lucide-react'

import {
  ShareGrowth,
  type DownloadChannelStatus,
  type ShareGrowthItem,
  type ShareGrowthStats,
} from '../lib/api'
import { DateRangeField } from '../components/DateRangeField'
import {
  DataTable,
  EmptyState,
  HelpLabel,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  SearchInput,
  Select,
  StackedTrendChart,
  Toolbar,
  type TrendChartPoint,
} from '../components/ui'

const STATUS_LABEL: Record<DownloadChannelStatus, string> = {
  active: '启用中',
  archived: '已归档',
}

const STATUS_TONE: Record<DownloadChannelStatus, string> = {
  active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  archived: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
}

const PLATFORM_LABEL: Record<string, string> = {
  macos: 'macOS',
  windows: 'Windows',
  ios: 'iOS',
  android: 'Android',
  mobile: '移动端',
  unknown: '未知平台',
}

export function ShareGrowthPage() {
  const [items, setItems] = useState<ShareGrowthItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [keyword, setKeyword] = useState('')
  const [status, setStatus] = useState('')
  const [rangeStart, setRangeStart] = useState('')
  const [rangeEnd, setRangeEnd] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [stats, setStats] = useState<ShareGrowthStats | null>(null)
  const [statsLoading, setStatsLoading] = useState(true)
  const [statsError, setStatsError] = useState('')

  const rangeParams = useMemo(() => ({
    start: rangeStart ? toRangeBoundary(rangeStart, false) : undefined,
    end: rangeEnd ? toRangeBoundary(rangeEnd, true) : undefined,
  }), [rangeStart, rangeEnd])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    ShareGrowth.list({
      q: keyword || undefined,
      status: status || undefined,
      ...rangeParams,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    }).then((resp) => {
      if (cancelled) return
      setItems(resp.items || [])
      setTotal(resp.total || 0)
      setError('')
    }).catch((e: Error) => {
      if (!cancelled) setError(e.message)
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })
    return () => { cancelled = true }
  }, [keyword, status, rangeParams, page, pageSize])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStatsLoading(true)
    ShareGrowth.stats({
      q: keyword || undefined,
      status: status || undefined,
      ...rangeParams,
    }).then((resp) => {
      if (cancelled) return
      setStats(resp)
      setStatsError('')
    }).catch((e: Error) => {
      if (!cancelled) setStatsError(e.message)
    }).finally(() => {
      if (!cancelled) setStatsLoading(false)
    })
    return () => { cancelled = true }
  }, [keyword, status, rangeParams])

  const resetPage = (fn: () => void) => { setPage(1); fn() }

  return (
    <div>
      <PageHeader
        title="用户分享增长"
        subtitle="查看用户专属邀请码带来的官网访问与下载点击，定位活跃分享者；注册、激活等指标将在归因链路打通后补充。"
      />

      {statsError ? <InlineAlert>{statsError}</InlineAlert> : (
        <ShareGrowthOverview stats={stats} loading={statsLoading} />
      )}

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(value) => resetPage(() => setKeyword(value))}
            placeholder="搜索邀请码 / 分享者 / 手机号"
          />
        }
        filters={
          <>
            <div className="w-[132px]">
              <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
                <option value="">全部状态</option>
                {Object.entries(STATUS_LABEL).map(([value, label]) => (
                  <option key={value} value={value}>{label}</option>
                ))}
              </Select>
            </div>
            <DateRangeField
              start={rangeStart}
              end={rangeEnd}
              onChange={(start, end) => resetPage(() => { setRangeStart(start); setRangeEnd(end) })}
            />
          </>
        }
        summary={`共 ${total} 位已开通分享者`}
      />

      {error && <InlineAlert>{error}</InlineAlert>}

      <DataTable
        headers={['分享者', '手机号', '邀请码', '状态', '访问', '下载点击', '点击率', '首次归因', '最近归因', '开通时间']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载用户分享数据</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<Share2 size={22} />}
            title="暂无用户分享数据"
            description="用户在客户端首次打开“分享给朋友”后会生成专属邀请码；朋友通过邀请链接访问官网后，这里会出现归因数据。"
          />
        ) : undefined}
      >
        {!loading && items.map((item) => {
          const rate = item.visit_count > 0 ? `${((item.download_count / item.visit_count) * 100).toFixed(1)}%` : '—'
          return (
            <tr key={item.owner_account_uuid} className="hover:bg-[var(--color-bg-sub)]">
              <td className="max-w-[220px] px-4 py-3">
                <div className="truncate font-medium text-[var(--color-text)]" title={item.owner_display_name || item.owner_account_uuid}>
                  {item.owner_display_name || '未设置昵称'}
                </div>
                <div className="mt-0.5 truncate font-mono text-[11px] text-[var(--color-text-mute)]" title={item.owner_account_uuid}>
                  {item.owner_account_uuid}
                </div>
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{item.owner_phone_masked || '—'}</td>
              <td className="whitespace-nowrap px-4 py-3 font-mono font-medium text-[var(--color-text)]">{item.invite_code}</td>
              <td className="whitespace-nowrap px-4 py-3"><StatusBadge status={item.status} /></td>
              <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.visit_count}</td>
              <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.download_count}</td>
              <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{rate}</td>
              <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.first_event_at)}</td>
              <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.last_event_at)}</td>
              <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
            </tr>
          )
        })}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(next) => { setPageSize(next); setPage(1) }}
      />
    </div>
  )
}

function ShareGrowthOverview({ stats, loading }: { stats: ShareGrowthStats | null; loading: boolean }) {
  const conversion = stats && stats.total_visits > 0
    ? `${((stats.total_downloads / stats.total_visits) * 100).toFixed(1)}%`
    : '—'
  const cards: Array<{
    label: string
    value: ReactNode
    note: string
    hint: string
    icon: ComponentType<{ size?: number; className?: string }>
  }> = [
    {
      label: '邀请码总数', value: stats?.total_codes ?? '—', note: '当前存量', icon: UsersRound,
      hint: '满足当前关键词和状态筛选的用户专属邀请码总数；该存量指标不受事件时间范围影响。',
    },
    {
      label: '活跃分享者', value: stats?.active_sharers ?? '—', note: '范围内至少 1 次访问', icon: UserRoundCheck,
      hint: '当前时间范围内，至少带来 1 次官网访问事件的去重邀请码数。',
    },
    {
      label: '访问事件', value: stats?.total_visits ?? '—', note: '原始事件，不去重', icon: Eye,
      hint: '邀请链接带来的 visit 原始事件数；官网按同一浏览器会话做基础去重，但这里不是独立访客数。',
    },
    {
      label: '下载点击', value: stats?.total_downloads ?? '—', note: '原始点击事件', icon: DownloadCloud,
      hint: '带有个人邀请码归因的 download_click 事件数，不等同于成功安装或注册。',
    },
    {
      label: '下载点击率', value: conversion, note: '下载点击 ÷ 访问事件', icon: Percent,
      hint: '下载点击事件数 ÷ 访问事件数 × 100%；不关联同一访客的访问到下载路径，只作为粗运营参考。',
    },
  ]
  const trendPoints: TrendChartPoint[] = (stats?.trend ?? []).map((point) => ({
    label: point.date.slice(5),
    title: `${point.date} · 访问 ${point.visit_count} · 下载点击 ${point.download_count}`,
    values: { visit: point.visit_count, download: point.download_count },
  }))

  return (
    <div className="mb-4 space-y-3">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-5">
        {cards.map(({ label, value, note, hint, icon: Icon }) => (
          <div key={label} className="rounded-lg border border-[var(--color-line)] bg-[var(--color-surface)] px-4 py-3">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <HelpLabel label={label} hint={hint} />
                <div className="mt-1.5 text-[22px] font-semibold leading-none tabular-nums text-[var(--color-text)]">
                  {loading ? '...' : value}
                </div>
                <div className="mt-1.5 truncate text-[11px] text-[var(--color-text-mute)]" title={note}>{note}</div>
              </div>
              <div className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
                <Icon size={16} />
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="grid gap-3 xl:grid-cols-[minmax(0,2fr)_minmax(280px,1fr)]">
        <Panel className="px-4 py-4">
          <div className="mb-1 text-[13px] font-medium text-[var(--color-text)]">访问 / 下载点击趋势</div>
          <div className="mb-2 text-[12px] text-[var(--color-text-sub)]">按当前筛选与时间范围逐日聚合。</div>
          {loading ? (
            <div className="grid h-[160px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">加载中...</div>
          ) : (
            <StackedTrendChart
              points={trendPoints}
              series={[
                { key: 'visit', label: '访问', color: 'var(--color-brand)' },
                { key: 'download', label: '下载点击', color: 'var(--color-success)' },
              ]}
              emptyText="当前范围内暂无访问或下载点击"
            />
          )}
        </Panel>
        <PlatformDistribution stats={stats} loading={loading} />
      </div>
    </div>
  )
}

function PlatformDistribution({ stats, loading }: { stats: ShareGrowthStats | null; loading: boolean }) {
  const rows = stats?.platforms ?? []
  const max = Math.max(...rows.map((row) => row.download_count), 1)
  return (
    <Panel className="px-4 py-4">
      <div className="mb-1 text-[13px] font-medium text-[var(--color-text)]">下载平台分布</div>
      <div className="mb-4 text-[12px] text-[var(--color-text-sub)]">按下载点击事件的平台字段聚合。</div>
      {loading ? (
        <div className="grid h-[160px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">加载中...</div>
      ) : rows.length === 0 ? (
        <div className="grid h-[160px] place-items-center text-center text-[12.5px] text-[var(--color-text-mute)]">当前范围内暂无下载点击</div>
      ) : (
        <div className="space-y-3">
          {rows.map((row) => (
            <div key={row.platform}>
              <div className="mb-1 flex items-center justify-between gap-3 text-[12px]">
                <span className="text-[var(--color-text-sub)]">{PLATFORM_LABEL[row.platform] || row.platform}</span>
                <span className="tabular-nums text-[var(--color-text)]">{row.download_count}</span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-[var(--color-line-soft)]">
                <div
                  className="h-full rounded-full bg-[var(--color-brand)]"
                  style={{ width: `${Math.max((row.download_count / max) * 100, 3)}%` }}
                />
              </div>
            </div>
          ))}
        </div>
      )}
    </Panel>
  )
}

function StatusBadge({ status }: { status: DownloadChannelStatus }) {
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-[12px] font-medium ${STATUS_TONE[status]}`}>
      {STATUS_LABEL[status] || status}
    </span>
  )
}

function formatTime(value?: string) {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString('zh-CN', { hour12: false })
}

function toRangeBoundary(value: string, endOfDay: boolean) {
  const date = new Date(`${value}T${endOfDay ? '23:59:59.999' : '00:00:00.000'}`)
  return Number.isNaN(date.getTime()) ? value : date.toISOString()
}
