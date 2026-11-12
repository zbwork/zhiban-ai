import { useEffect, useMemo, useState, type ComponentType, type ReactNode } from 'react'
import { Copy, DownloadCloud, Edit3, Eye, Link2, Percent, Trash2 } from 'lucide-react'

import {
  DownloadChannels,
  type DownloadChannelInput,
  type DownloadChannelItem,
  type DownloadChannelStats,
  type DownloadChannelStatus,
} from '../lib/api'
import { copyToClipboard } from '../lib/clipboard'
import { notifyError, notifyOk } from '../lib/toast'
import { DateRangeField } from '../components/DateRangeField'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  HelpLabel,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  Panel,
  SearchInput,
  Select,
  StackedTrendChart,
  stickyRightTdCls,
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

const EMPTY_INPUT: DownloadChannelInput = { code: '', name: '', description: '', status: 'active' }

const ZHIBAN_WWW_SITE_URL = 'https://www.zbwork.cn'

function channelLink(code: string) {
  return `${ZHIBAN_WWW_SITE_URL}/?ref=${encodeURIComponent(code)}`
}

function toInput(item: DownloadChannelItem): DownloadChannelInput {
  return { code: item.code, name: item.name, description: item.description, status: item.status }
}

export function DownloadChannelsPage() {
  const [items, setItems] = useState<DownloadChannelItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [keyword, setKeyword] = useState('')
  const [status, setStatus] = useState('')
  const [rangeStart, setRangeStart] = useState('')
  const [rangeEnd, setRangeEnd] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<DownloadChannelItem | null>(null)
  const [deleting, setDeleting] = useState<DownloadChannelItem | null>(null)
  const [stats, setStats] = useState<DownloadChannelStats | null>(null)
  const [statsLoading, setStatsLoading] = useState(true)
  const [statsErr, setStatsErr] = useState('')

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DownloadChannels.list({
      q: keyword || undefined,
      status: status || undefined,
      start: rangeStart || undefined,
      end: rangeEnd || undefined,
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
  }, [keyword, status, rangeStart, rangeEnd, page, pageSize, tick])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStatsLoading(true)
    DownloadChannels.stats({
      q: keyword || undefined,
      status: status || undefined,
      start: rangeStart || undefined,
      end: rangeEnd || undefined,
    }).then((resp) => {
      if (cancelled) return
      setStats(resp)
      setStatsErr('')
    }).catch((e: Error) => {
      if (!cancelled) setStatsErr(e.message)
    }).finally(() => {
      if (!cancelled) setStatsLoading(false)
    })
    return () => { cancelled = true }
  }, [keyword, status, rangeStart, rangeEnd, tick])

  const summary = useMemo(() => `共 ${total} 个渠道`, [total])
  const resetPage = (fn: () => void) => { setPage(1); fn() }
  const refresh = () => setTick((v) => v + 1)

  return (
    <div>
      <PageHeader
        title="下载渠道"
        subtitle="管理投放/推广渠道，追踪各渠道带来的官网访问量与 App 下载量，支持自定义时间范围查看。"
      />

      <ChannelStatsPanel stats={stats} loading={statsLoading} error={statsErr} />

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索渠道代码 / 名称"
          />
        }
        filters={
          <>
            <div className="w-[132px]">
              <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
                <option value="">全部状态</option>
                {Object.entries(STATUS_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
            <DateRangeField
              start={rangeStart}
              end={rangeEnd}
              onChange={(s, e) => resetPage(() => { setRangeStart(s); setRangeEnd(e) })}
            />
          </>
        }
        summary={summary}
        actions={
          <Button onClick={() => setCreating(true)}>
            <Link2 size={14} />
            新建渠道
          </Button>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        headers={['渠道代码', '渠道链接', '名称', '状态', '访问数', '下载数', '创建时间', '操作']}
        stickyLastCol
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载下载渠道</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<Link2 size={20} />}
            title="暂无下载渠道"
            description="新建渠道后，把渠道代码作为官网链接的 ?ref= 参数投放，即可开始统计访问与下载。"
          />
        ) : undefined}
      >
        {!loading && items.map((item) => (
          <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
            <td className="whitespace-nowrap px-4 py-3 font-mono text-[var(--color-text)]">{item.code}</td>
            <td className="max-w-[240px] px-4 py-3">
              {item.code === 'default' ? (
                <span className="text-[var(--color-text-mute)]">-</span>
              ) : (
                <div className="flex items-center gap-1.5">
                  <span className="truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={channelLink(item.code)}>
                    {channelLink(item.code)}
                  </span>
                  <button
                    type="button"
                    onClick={async () => {
                      const ok = await copyToClipboard(channelLink(item.code))
                      if (ok) notifyOk('渠道链接已复制')
                      else notifyError('复制失败，请手动选中链接复制')
                    }}
                    title="复制渠道链接"
                    className="grid h-6 w-6 shrink-0 place-items-center rounded text-[var(--color-text-mute)] hover:bg-[var(--color-bg-sub)] hover:text-[var(--color-text)]"
                  >
                    <Copy size={13} />
                  </button>
                </div>
              )}
            </td>
            <td className="max-w-[220px] px-4 py-3">
              <div className="truncate text-[var(--color-text)]" title={item.name}>{item.name}</div>
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              <Badge className={STATUS_TONE[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
            </td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.visit_count}</td>
            <td className="whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.download_count}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.created_at)}</td>
            <td className={`whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
              <div className="flex items-center gap-1">
                <Button variant="ghost" size="sm" onClick={() => setEditing(item)} title="编辑" aria-label="编辑下载渠道">
                  <Edit3 size={14} />
                </Button>
                <Button variant="ghost" size="sm" onClick={() => setDeleting(item)} title="删除" aria-label="删除下载渠道">
                  <Trash2 size={14} />
                </Button>
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
        onPageSizeChange={(next) => { setPageSize(next); setPage(1) }}
      />

      {creating && (
        <ChannelDrawer
          initial={EMPTY_INPUT}
          title="新建渠道"
          codeEditable
          onClose={() => setCreating(false)}
          onSave={async (input) => {
            const resp = await DownloadChannels.create(input)
            setCreating(false)
            notifyOk('渠道已创建')
            refresh()
            return resp.item
          }}
        />
      )}

      {editing && (
        <ChannelDrawer
          initial={toInput(editing)}
          title="编辑渠道"
          codeEditable={false}
          onClose={() => setEditing(null)}
          onSave={async (input) => {
            const resp = await DownloadChannels.patch(editing.uuid, input)
            setEditing(null)
            notifyOk('已保存')
            refresh()
            return resp.item
          }}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title="删除下载渠道"
          description={`确定删除渠道「${deleting.name}」吗？该渠道已产生的访问/下载历史数据不受影响，但删除后无法通过该渠道代码再次归因。`}
          confirmLabel="删除"
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await DownloadChannels.delete(deleting.uuid)
            setDeleting(null)
            notifyOk('已删除')
            refresh()
          }}
        />
      )}
    </div>
  )
}

function ChannelStatsPanel({
  stats,
  loading,
  error,
}: {
  stats: DownloadChannelStats | null
  loading: boolean
  error: string
}) {
  const conversionPct = stats && stats.total_visits > 0
    ? ((stats.total_downloads / stats.total_visits) * 100).toFixed(1)
    : '-'

  const cards: Array<{ label: string; hint?: string; value: ReactNode; icon: ComponentType<{ size?: number; className?: string }> }> = [
    { label: '总访问数', value: stats?.total_visits ?? '-', icon: Eye },
    { label: '总下载数', value: stats?.total_downloads ?? '-', icon: DownloadCloud },
    {
      label: '下载转化率',
      hint: '计算方式：总下载数 ÷ 总访问数 × 100%，按当前筛选条件（关键词/状态/时间范围）跨渠道汇总；不做访客去重，也不关联同一访客的访问→下载路径，仅供粗略参考投放效果。',
      value: conversionPct === '-' ? '-' : `${conversionPct}%`,
      icon: Percent,
    },
  ]

  const points: TrendChartPoint[] = (stats?.trend ?? []).map((p) => ({
    label: p.date.slice(5),
    title: `${p.date} · 访问 ${p.visit_count} · 下载 ${p.download_count}`,
    values: { visit: p.visit_count, download: p.download_count },
  }))

  if (error) {
    return <InlineAlert>{error}</InlineAlert>
  }

  return (
    <div className="mb-4 space-y-3">
      <div className="grid grid-cols-3 gap-3">
        {cards.map(({ label, hint, value, icon: Icon }) => (
          <div key={label} className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                {hint ? (
                  <HelpLabel label={label} hint={hint} />
                ) : (
                  <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
                )}
                <div className="mt-1 text-[24px] font-semibold tabular-nums text-[var(--color-text)]">
                  {loading ? '...' : value}
                </div>
              </div>
              <div className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
                <Icon size={18} />
              </div>
            </div>
          </div>
        ))}
      </div>
      <Panel className="px-4 py-4">
        <div className="mb-1 text-[13px] font-medium text-[var(--color-text)]">访问 / 下载趋势</div>
        <div className="mb-2 text-[12px] text-[var(--color-text-sub)]">按当前筛选条件（关键词/状态/时间范围）聚合，按天展示。</div>
        {loading ? (
          <div className="grid h-[160px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">加载中...</div>
        ) : (
          <StackedTrendChart
            points={points}
            series={[
              { key: 'visit', label: '访问', color: 'var(--color-brand)' },
              { key: 'download', label: '下载', color: 'var(--color-success)' },
            ]}
            emptyText="当前范围内暂无访问/下载数据"
          />
        )}
      </Panel>
      <Panel className="px-4 py-4">
        <div className="mb-1 text-[13px] font-medium text-[var(--color-text)]">下载平台占比</div>
        <div className="mb-2 text-[12px] text-[var(--color-text-sub)]">按当前筛选条件（关键词/状态/时间范围）聚合各平台下载次数占比。</div>
        {loading ? (
          <div className="grid h-[100px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">加载中...</div>
        ) : (
          <PlatformBreakdown points={stats?.platforms ?? []} />
        )}
      </Panel>
    </div>
  )
}

const PLATFORM_LABEL: Record<string, string> = {
  macos: 'macOS',
  windows: 'Windows',
  ios: 'iOS',
  android: 'Android',
  unknown: '未知',
}

function PlatformBreakdown({ points }: { points: DownloadChannelStats['platforms'] }) {
  const total = points.reduce((sum, p) => sum + p.download_count, 0)
  if (points.length === 0 || total === 0) {
    return <div className="py-8 text-center text-[13px] text-[var(--color-text-mute)]">当前范围内暂无下载数据</div>
  }
  return (
    <div className="space-y-3">
      {points.map((p) => {
        const pct = (p.download_count / total) * 100
        return (
          <div key={p.platform}>
            <div className="mb-1.5 flex items-center justify-between gap-3 text-[13px]">
              <span className="text-[var(--color-text-sub)]">{PLATFORM_LABEL[p.platform] ?? p.platform}</span>
              <span className="shrink-0 tabular-nums text-[var(--color-text)]">
                {p.download_count} <span className="text-[var(--color-text-mute)]">· {pct.toFixed(1)}%</span>
              </span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-[var(--color-line-soft)]">
              <div
                className="h-full rounded-full bg-[var(--color-brand)]"
                style={{ width: `${Math.max(pct, 2)}%` }}
              />
            </div>
          </div>
        )
      })}
    </div>
  )
}

function ChannelDrawer({
  initial,
  title,
  codeEditable,
  onClose,
  onSave,
}: {
  initial: DownloadChannelInput
  title: string
  codeEditable: boolean
  onClose: () => void
  onSave: (input: DownloadChannelInput) => Promise<DownloadChannelItem>
}) {
  const [form, setForm] = useState<DownloadChannelInput>(initial)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')

  const set = <K extends keyof DownloadChannelInput>(key: K, value: DownloadChannelInput[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }))

  const doSave = async () => {
    setSaving(true)
    setErr('')
    try {
      await onSave(form)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      title={title}
      icon={<Link2 size={18} />}
      onClose={onClose}
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={saving}>关闭</Button>
          <Button onClick={doSave} disabled={saving}>{saving ? '保存中...' : '保存'}</Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}

        <FormSection title="渠道信息">
          <div className="grid gap-4 md:grid-cols-2">
            <FormField
              label="渠道代码"
              hint={codeEditable ? 'URL-safe，作为官网链接 ?ref= 取值，如 baidu-sem' : '创建后不可修改，避免已投放的链接失效'}
            >
              <Input
                value={form.code}
                onChange={(e) => set('code', e.target.value)}
                placeholder="如 baidu-sem"
                readOnly={!codeEditable}
                disabled={!codeEditable}
              />
            </FormField>
            <FormField label="状态">
              <Select value={form.status} onChange={(e) => set('status', e.target.value as DownloadChannelStatus)}>
                {Object.entries(STATUS_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="渠道名称">
              <Input value={form.name} onChange={(e) => set('name', e.target.value)} placeholder="如 百度SEM" />
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="备注">
              <Input value={form.description || ''} onChange={(e) => set('description', e.target.value)} placeholder="可选" />
            </FormField>
          </div>
        </FormSection>
      </div>
    </DrawerShell>
  )
}

function Badge({ children, className }: { children: ReactNode; className: string }) {
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-[12px] font-medium ${className}`}>
      {children}
    </span>
  )
}

function formatTime(value?: string) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString('zh-CN', { hour12: false })
}
