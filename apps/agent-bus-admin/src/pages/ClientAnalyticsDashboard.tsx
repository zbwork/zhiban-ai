import { Fragment, useEffect, useState, type ComponentType, type ReactNode } from 'react'
import {
  Activity,
  Building2,
  Bug,
  CalendarPlus,
  ChartNoAxesCombined,
  ChevronDown,
  ChevronRight,
  MonitorSmartphone,
  RefreshCw,
  Users,
} from 'lucide-react'
import {
  ClientAnalytics,
  type ClientAnalyticsDimension,
  type ClientAnalyticsErrorDetail,
  type ClientAnalyticsAffectedAccount,
  type ClientAnalyticsErrorGroup,
  type ClientAnalyticsErrorPoint,
  type ClientAnalyticsOverview,
  type ClientAnalyticsPoint,
} from '../lib/api'
import {
  Button,
  DataTable,
  EmptyState,
  HelpLabel,
  InlineAlert,
  LineTrendChart,
  PageHeader,
  Panel,
  Select,
  stickyLeftTdCls,
  Switch,
  type TrendChartPoint,
} from '../components/ui'

type RangeDays = 7 | 30 | 90

// 接口失败时的兜底空数据：让页面结构（卡片/图表/表格的"暂无数据"态）照常渲染，
// 不要因为一个接口挂了就整页只剩一条错误提示——之前 data 为 null 时直接不渲染
// 任何 section，用户看到的就是一片空白 + 一坨错误文字。
const EMPTY_OVERVIEW: ClientAnalyticsOverview = {
  generated_at: '',
  timezone: '',
  range_days: 0,
  dau: 0,
  wau: 0,
  mau: 0,
  stickiness_pct: 0,
  active_tenants_24h: 0,
  new_accounts_24h: 0,
  trend: [],
  platforms: [],
  versions: [],
  tenants: [],
  error_count: 0,
  error_users: 0,
  error_fingerprints: 0,
  error_trend: [],
  top_errors: [],
}

export default function ClientAnalyticsDashboardPage() {
  const [days, setDays] = useState<RangeDays>(30)
  const [showArchived, setShowArchived] = useState(false)
  const [data, setData] = useState<ClientAnalyticsOverview | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [reloadTick, setReloadTick] = useState(0)

  useEffect(() => {
    let active = true
    ClientAnalytics.overview(days, showArchived)
      .then((overview) => {
        if (!active) return
        setData(overview)
        setError('')
      })
      .catch((cause: unknown) => {
        if (!active) return
        setError((cause as Error).message || '客户端分析数据加载失败')
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => { active = false }
  }, [days, showArchived, reloadTick])

  const refresh = () => setReloadTick((value) => value + 1)

  return (
    <div className="space-y-4">
      <PageHeader
        className="mb-1"
        title="客户端分析"
        subtitle="查看知办AI 客户端活跃用户、平台版本与 Flutter 客户端错误。服务和网络错误不计入。"
        actions={(
          <>
            <div className="w-[132px]">
              <Select
                aria-label="统计范围"
                value={days}
                onChange={(event) => {
                  setLoading(true)
                  setDays(Number(event.target.value) as RangeDays)
                }}
              >
                <option value={7}>最近 7 天</option>
                <option value={30}>最近 30 天</option>
                <option value={90}>最近 90 天</option>
              </Select>
            </div>
            <Button
              variant="secondary"
              disabled={loading}
              onClick={() => {
                setLoading(true)
                refresh()
              }}
            >
              <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
              刷新
            </Button>
          </>
        )}
      />

      {error && (
        <InlineAlert tone="danger">
          {error}。下面各区块暂时显示为空，接口恢复后点"刷新"即可。
        </InlineAlert>
      )}

      {!data && loading ? (
        <Panel className="px-4 py-10 text-center text-[13px] text-[var(--color-text-mute)]">客户端分析数据加载中...</Panel>
      ) : (
        (() => {
          // 接口失败时 data 为 null，用兜底空数据渲染页面结构（各 section 自带
          // "暂无数据" empty state），而不是整页只剩顶部一条错误提示。
          const overview = data ?? EMPTY_OVERVIEW
          return (
            <>
              <MetricCards overview={overview} />
              <ActiveTrend points={overview.trend} days={days} />
              <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
                <DimensionPanel
                  title="平台分布"
                  description={`最近 ${days} 个自然日活跃账号数；同一账号使用多个平台时会进入多个分组。`}
                  items={overview.platforms}
                  label={platformLabel}
                />
                <DimensionPanel
                  title="应用版本分布"
                  description={`最近 ${days} 个自然日活跃账号数，最多展示 10 个版本。`}
                  items={overview.versions}
                />
              </div>
              <TenantRanking overview={overview} />
              <ClientErrorOverview
                overview={overview}
                showArchived={showArchived}
                onShowArchivedChange={setShowArchived}
                onChanged={refresh}
              />
              {data && (
                <div className="text-right text-[12px] text-[var(--color-text-mute)]">
                  数据更新时间：{formatDateTime(data.generated_at)} · 时区：{data.timezone}
                </div>
              )}
            </>
          )
        })()
      )}
    </div>
  )
}

function MetricCards({ overview }: { overview: ClientAnalyticsOverview }) {
  const cards: Array<{
    label: string
    value: ReactNode
    note: string
    hint: string
    icon: ComponentType<{ size?: number; className?: string }>
  }> = [
    {
      label: 'DAU',
      value: overview.dau,
      note: '滚动最近 24 小时',
      hint: '滚动最近 24 小时内、按账号（account_id）去重的活跃用户数；触发 app_active 事件即算活跃。',
      icon: Activity,
    },
    {
      label: 'WAU',
      value: overview.wau,
      note: '滚动最近 7 天',
      hint: '滚动最近 7 天，按账号去重的活跃用户数。',
      icon: Users,
    },
    {
      label: 'MAU',
      value: overview.mau,
      note: '滚动最近 30 天',
      hint: '滚动最近 30 天，按账号去重的活跃用户数。',
      icon: Users,
    },
    {
      label: 'DAU / MAU',
      value: `${formatPercent(overview.stickiness_pct)}%`,
      note: '用户活跃粘性',
      hint: 'DAU ÷ MAU × 100%，衡量月活用户里有多大比例每天都在使用；越高说明用户粘性越强。',
      icon: ChartNoAxesCombined,
    },
    {
      label: '活跃租户',
      value: overview.active_tenants_24h,
      note: '滚动最近 24 小时',
      hint: '滚动最近 24 小时内，至少有一个账号活跃过的租户数。',
      icon: Building2,
    },
    {
      label: '新增账号',
      value: overview.new_accounts_24h,
      note: '滚动最近 24 小时',
      hint: '滚动最近 24 小时内新注册的账号数。',
      icon: CalendarPlus,
    },
  ]
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
      {cards.map(({ label, value, note, hint, icon: Icon }) => (
        <div key={label} className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-4 shadow-sm">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <HelpLabel label={label} hint={hint} />
              <div className="mt-1 text-[24px] font-semibold tabular-nums text-[var(--color-text)]">{value}</div>
              <div className="mt-1 truncate text-[11px] text-[var(--color-text-mute)]" title={note}>{note}</div>
            </div>
            <div className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
              <Icon size={18} />
            </div>
          </div>
        </div>
      ))}
    </div>
  )
}

function ActiveTrend({ points, days }: { points: ClientAnalyticsPoint[]; days: number }) {
  const chartPoints: TrendChartPoint[] = points.map((p) => ({
    label: p.date.slice(5),
    values: { active_users: p.active_users },
  }))
  return (
    <Panel className="px-4 py-4">
      <SectionTitle title="日活趋势" description={`最近 ${days} 个自然日，每日按 account_id 去重；无事件日期补 0。`} />
      {points.some((point) => point.active_users > 0) ? (
        <LineTrendChart
          points={chartPoints}
          series={[{ key: 'active_users', label: '活跃用户', color: 'var(--color-brand)' }]}
        />
      ) : (
        <EmptyState
          icon={<ChartNoAxesCombined size={26} />}
          title="暂无活跃趋势"
          description="当前范围内尚未收到 app_active 事件。客户端开始上报后，这里会自动出现趋势。"
          className="min-h-[230px] py-8"
        />
      )}
    </Panel>
  )
}

function DimensionPanel({
  title,
  description,
  items,
  label = (value) => value,
}: {
  title: string
  description: string
  items: ClientAnalyticsDimension[]
  label?: (value: string) => string
}) {
  const max = Math.max(...items.map((item) => item.active_users), 1)
  return (
    <Panel className="px-4 py-4">
      <SectionTitle title={title} description={description} />
      {items.length === 0 ? (
        <div className="py-10 text-center text-[13px] text-[var(--color-text-mute)]">暂无分布数据</div>
      ) : (
        <div className="mt-4 space-y-3">
          {items.map((item) => (
            <div key={item.key}>
              <div className="mb-1.5 flex items-center justify-between gap-3 text-[13px]">
                <span className="truncate text-[var(--color-text-sub)]" title={label(item.key)}>{label(item.key)}</span>
                <span className="shrink-0 tabular-nums font-medium text-[var(--color-text)]">{item.active_users}</span>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-[var(--color-line-soft)]">
                <div
                  className="h-full rounded-full bg-[var(--color-brand)]"
                  style={{ width: `${Math.max(item.active_users / max * 100, 2)}%` }}
                />
              </div>
            </div>
          ))}
        </div>
      )}
    </Panel>
  )
}

function TenantRanking({ overview }: { overview: ClientAnalyticsOverview }) {
  return (
    <div>
      <SectionTitle
        title="租户活跃排行"
        description={`最近 ${overview.range_days} 个自然日按租户内 account_id 去重，最多展示 10 个租户。`}
      />
      <DataTable
        headers={['排名', '租户', '活跃用户', '最近活跃']}
        empty={overview.tenants.length === 0 ? (
          <EmptyState
            icon={<MonitorSmartphone size={26} />}
            title="暂无租户活跃数据"
            description="当前统计范围内还没有租户产生 app_active 事件。"
            className="min-h-[220px] py-8"
          />
        ) : undefined}
      >
        {overview.tenants.map((tenant, index) => (
          <tr key={tenant.tenant_id} className="hover:bg-[var(--color-bg-sub)]">
            <td className="px-4 py-3 tabular-nums text-[var(--color-text-mute)]">{index + 1}</td>
            <td className="px-4 py-3 font-medium text-[var(--color-text)]">{tenant.tenant_name}</td>
            <td className="px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{tenant.active_users}</td>
            <td className="px-4 py-3 text-[var(--color-text-sub)]">{formatDateTime(tenant.last_active_at)}</td>
          </tr>
        ))}
      </DataTable>
    </div>
  )
}

function ClientErrorOverview({
  overview,
  showArchived,
  onShowArchivedChange,
  onChanged,
}: {
  overview: ClientAnalyticsOverview
  showArchived: boolean
  onShowArchivedChange: (value: boolean) => void
  onChanged: () => void
}) {
  const cards = [
    {
      label: '客户端错误',
      value: overview.error_count,
      note: `最近 ${overview.range_days} 个自然日`,
      hint: `最近 ${overview.range_days} 个自然日，Flutter/Dart 客户端错误事件总次数，不含服务端和网络错误。`,
    },
    {
      label: '受影响用户',
      value: overview.error_users,
      note: '按账号去重',
      hint: '按账号（account_id）去重后，触发过至少一次客户端错误的用户数。',
    },
    {
      label: '错误类型',
      value: overview.error_fingerprints,
      note: '按错误指纹去重',
      hint: '按错误指纹（fingerprint，同一类错误的唯一签名）去重后的错误种类数。',
    },
  ]
  return (
    <div className="space-y-4">
      <SectionTitle
        title="Flutter 客户端错误"
        description={`最近 ${overview.range_days} 个自然日，仅统计 Flutter/Dart 客户端错误；不包含服务和网络错误。`}
      />
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        {cards.map((card) => (
          <div key={card.label} className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-4 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div>
                <HelpLabel label={card.label} hint={card.hint} />
                <div className="mt-1 text-[24px] font-semibold tabular-nums text-[var(--color-text)]">{card.value}</div>
                <div className="mt-1 text-[11px] text-[var(--color-text-mute)]">{card.note}</div>
              </div>
              <div className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-[var(--color-danger-bg)] text-[var(--color-danger)]">
                <Bug size={18} />
              </div>
            </div>
          </div>
        ))}
      </div>
      <ErrorTrend points={overview.error_trend} />
      <TopErrors
        items={overview.top_errors}
        showArchived={showArchived}
        onShowArchivedChange={onShowArchivedChange}
        onChanged={onChanged}
      />
    </div>
  )
}

function ErrorTrend({ points }: { points: ClientAnalyticsErrorPoint[] }) {
  const chartPoints: TrendChartPoint[] = points.map((p) => ({
    label: p.date.slice(5),
    title: `${p.affected_users} 位受影响用户`,
    values: { error_count: p.error_count },
  }))
  return (
    <Panel className="px-4 py-4">
      <SectionTitle title="错误趋势" description="每日错误次数；悬停数据点可查看当天受影响用户数。" />
      {points.some((point) => point.error_count > 0) ? (
        <LineTrendChart
          points={chartPoints}
          series={[{ key: 'error_count', label: '客户端错误', color: 'var(--color-danger)' }]}
        />
      ) : (
        <EmptyState
          icon={<Bug size={26} />}
          title="暂无客户端错误"
          description="当前范围内尚未收到 Flutter/Dart 客户端错误。"
          className="min-h-[220px] py-8"
        />
      )}
    </Panel>
  )
}

function TopErrors({
  items,
  showArchived,
  onShowArchivedChange,
  onChanged,
}: {
  items: ClientAnalyticsErrorGroup[]
  showArchived: boolean
  onShowArchivedChange: (value: boolean) => void
  onChanged: () => void
}) {
  const [expanded, setExpanded] = useState<string | null>(null)
  const [detail, setDetail] = useState<ClientAnalyticsErrorDetail | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')
  const [busyFingerprint, setBusyFingerprint] = useState<string | null>(null)

  const toggleExpand = (fingerprint: string) => {
    if (expanded === fingerprint) {
      setExpanded(null)
      return
    }
    setExpanded(fingerprint)
    setDetail(null)
    setDetailError('')
    setDetailLoading(true)
    ClientAnalytics.errorDetail(fingerprint)
      .then(setDetail)
      .catch((cause: unknown) => setDetailError((cause as Error).message || '加载完整堆栈失败'))
      .finally(() => setDetailLoading(false))
  }

  const toggleArchive = async (item: ClientAnalyticsErrorGroup) => {
    setBusyFingerprint(item.fingerprint)
    try {
      if (item.archived) {
        await ClientAnalytics.unarchiveError(item.fingerprint)
      } else {
        await ClientAnalytics.archiveError(item.fingerprint)
      }
      onChanged()
    } catch (cause) {
      window.alert((cause as Error).message || '操作失败')
    } finally {
      setBusyFingerprint(null)
    }
  }

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <SectionTitle title="高频错误" description="按错误指纹聚合，最多展示 10 条；错误信息和报错位置已脱敏；点击一行可展开完整脱敏堆栈。" />
        <label className="flex shrink-0 items-center gap-2 text-[13px] text-[var(--color-text-sub)]">
          <HelpLabel label="显示已归档" hint="「归档」是运营用来标记「已知/已处理，不用再关注」的软状态，不影响原始错误数据；默认列表只显示未归档的错误，打开开关后会一并显示已归档的。" />
          <Switch checked={showArchived} onChange={(value) => onShowArchivedChange(value)} />
        </label>
      </div>
      <DataTable
        stickyFirstCol
        headers={['', '错误类型', '错误信息', '报错位置', '错误指纹', '次数', '受影响用户', '平台', '应用版本', '状态', '最近发生', '操作']}
        empty={items.length === 0 ? (
          <EmptyState
            icon={<Bug size={26} />}
            title="暂无高频错误"
            description="当前统计范围内没有可聚合的客户端错误。"
            className="min-h-[220px] py-8"
          />
        ) : undefined}
      >
        {items.map((item) => (
          <Fragment key={item.fingerprint}>
            <tr
              className="group cursor-pointer hover:bg-[var(--color-bg-sub)]"
              onClick={() => toggleExpand(item.fingerprint)}
            >
              <td className={`${stickyLeftTdCls} px-2 py-3 text-[var(--color-text-mute)]`}>
                {expanded === item.fingerprint ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              </td>
              <td className="px-4 py-3 font-medium text-[var(--color-text)]">{item.error_type || '-'}</td>
              <td className="max-w-[320px] truncate px-4 py-3 text-[var(--color-text-sub)]" title={item.error_message}>{item.error_message || '-'}</td>
              <td className="min-w-[360px] max-w-[520px] whitespace-pre-line px-4 py-3 font-mono text-[12px] leading-5 text-[var(--color-text-sub)]" title={item.source_location}>{item.source_location || '-'}</td>
              <td className="px-4 py-3 font-mono text-[var(--color-text-sub)]" title={item.fingerprint}>{item.fingerprint.slice(0, 12)}</td>
              <td className="px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.occurrences}</td>
              <td className="px-4 py-3 tabular-nums text-[var(--color-text-sub)]">{item.affected_users}</td>
              <td className="px-4 py-3 text-[var(--color-text-sub)]">{item.platforms || '-'}</td>
              <td className="px-4 py-3 text-[var(--color-text-sub)]">{item.app_versions || '-'}</td>
              <td className="px-4 py-3">
                {item.archived ? (
                  <span className="rounded-full bg-[var(--color-bg-sub)] px-2 py-0.5 text-[11px] text-[var(--color-text-mute)]">已归档</span>
                ) : (
                  <span className="rounded-full bg-[var(--color-danger-bg)] px-2 py-0.5 text-[11px] text-[var(--color-danger)]">未处理</span>
                )}
              </td>
              <td className="px-4 py-3 whitespace-nowrap text-[var(--color-text-sub)]">{formatDateTime(item.last_seen_at)}</td>
              <td className="px-4 py-3">
                <Button
                  variant="secondary"
                  disabled={busyFingerprint === item.fingerprint}
                  onClick={(event) => {
                    event.stopPropagation()
                    void toggleArchive(item)
                  }}
                >
                  {item.archived ? '取消归档' : '归档'}
                </Button>
              </td>
            </tr>
            {expanded === item.fingerprint && (
              <tr>
                <td colSpan={12} className="bg-[var(--color-bg-sub)] px-4 py-4">
                  {detailLoading ? (
                    <div className="text-[13px] text-[var(--color-text-mute)]">加载完整堆栈中...</div>
                  ) : detailError ? (
                    <InlineAlert tone="danger">{detailError}</InlineAlert>
                  ) : detail ? (
                    <div className="space-y-3">
                      <div>
                        <div className="mb-1 text-[12px] font-semibold text-[var(--color-text-mute)]">受影响用户明细</div>
                        {(detail.affected_accounts ?? []).length === 0 ? (
                          <div className="text-[12px] text-[var(--color-text-mute)]">(空)</div>
                        ) : (
                          <div className="max-h-[240px] overflow-auto rounded-lg border border-[var(--color-line)] bg-white">
                            <table className="w-full text-[12px]">
                              <thead>
                                <tr className="border-b border-[var(--color-line)] text-left text-[var(--color-text-mute)]">
                                  <th className="px-3 py-2 font-medium">用户</th>
                                  <th className="px-3 py-2 font-medium">所属租户</th>
                                  <th className="px-3 py-2 font-medium">命中次数</th>
                                  <th className="px-3 py-2 font-medium">最近发生</th>
                                </tr>
                              </thead>
                              <tbody>
                                {(detail.affected_accounts ?? []).map((account: ClientAnalyticsAffectedAccount) => (
                                  <tr key={account.account_uuid} className="border-b border-[var(--color-line)] last:border-0">
                                    <td className="px-3 py-2 text-[var(--color-text)]">{account.display_name || account.account_uuid}</td>
                                    <td className="px-3 py-2 text-[var(--color-text-sub)]">{account.tenant_name || '-'}</td>
                                    <td className="px-3 py-2 tabular-nums text-[var(--color-text-sub)]">{account.occurrences}</td>
                                    <td className="px-3 py-2 whitespace-nowrap text-[var(--color-text-sub)]">{formatDateTime(account.last_seen_at)}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        )}
                      </div>
                      <div>
                        <div className="mb-1 text-[12px] font-semibold text-[var(--color-text-mute)]">完整堆栈（已脱敏）</div>
                        <pre className="max-h-[360px] overflow-auto whitespace-pre-wrap break-all rounded-lg border border-[var(--color-line)] bg-white p-3 font-mono text-[12px] leading-5 text-[var(--color-text-sub)]">
                          {detail.stacktrace || '(空)'}
                        </pre>
                      </div>
                      <div>
                        <div className="mb-1 text-[12px] font-semibold text-[var(--color-text-mute)]">完整 properties</div>
                        <pre className="max-h-[240px] overflow-auto whitespace-pre-wrap break-all rounded-lg border border-[var(--color-line)] bg-white p-3 font-mono text-[12px] leading-5 text-[var(--color-text-sub)]">
                          {JSON.stringify(detail.properties, null, 2)}
                        </pre>
                      </div>
                      <div className="text-[12px] text-[var(--color-text-mute)]">
                        首次发生：{formatDateTime(detail.first_seen_at)} · mechanism：{detail.mechanism || '-'} · severity：{detail.severity || '-'}
                      </div>
                    </div>
                  ) : null}
                </td>
              </tr>
            )}
          </Fragment>
        ))}
      </DataTable>
    </div>
  )
}

function SectionTitle({ title, description }: { title: string; description: string }) {
  return (
    <div className="mb-3">
      <div className="text-[16px] font-semibold text-[var(--color-text)]">{title}</div>
      <div className="mt-0.5 text-[12px] text-[var(--color-text-mute)]">{description}</div>
    </div>
  )
}

function platformLabel(value: string) {
  return ({ android: 'Android', ios: 'iOS', macos: 'macOS', windows: 'Windows' } as Record<string, string>)[value] || value
}

function formatDateTime(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '-' : date.toLocaleString('zh-CN', { hour12: false })
}

function formatPercent(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}
