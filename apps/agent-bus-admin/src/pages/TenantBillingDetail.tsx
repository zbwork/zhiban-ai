// F25 §4.3/§4.4（docs/features/F25-alert-center-and-admin-visibility.md）：
//   - TenantBillingDetailPage（平台 /tenants/:id）= 租户 360°：概况 / 使用与健康 / 订阅与配额 / 审计记录 四个顶级 Tab；
//     原计费详情（订阅与权益/钱包/订单/用量 + 覆写 Drawer）整体收编为「订阅与配额」Tab，能力不减。
//   - TenantBillingSubscriptionPage（租户 /billing/subscription，菜单「订阅与配额」）= 只读透明度四 Tab：
//     套餐与权益 / 配额水位 / 积分钱包 / 订单记录（支持 ?tab= 深链）。
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { ArrowRight, Gauge, Pencil, RefreshCw } from 'lucide-react'

import {
  Billing as BillingAPI,
  AuditCenter,
  Tenants,
  TenantInsightAPI,
  type AuditEvent,
  type BillingEntitlement,
  type BillingLedgerEntry,
  type BillingPaymentOrder,
  type BillingUsageAggregate,
  type Tenant,
  type TenantBillingOverview,
  type TenantInsight,
} from '../lib/api'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  Panel,
  Tabs,
  TrendChart,
} from '../components/ui'

// ============================================================================
// 平台侧：租户 360° 详情（/tenants/:id）
// ============================================================================

type TenantInsightTab = 'summary' | 'health' | 'billing' | 'audit'

const tenantInsightTabs: Array<{ value: TenantInsightTab; label: string }> = [
  { value: 'summary', label: '概况' },
  { value: 'health', label: '使用与健康' },
  { value: 'billing', label: '订阅与配额' },
  { value: 'audit', label: '审计记录' },
]

type TenantBillingTab = 'entitlements' | 'wallet' | 'orders' | 'usage'

const tenantBillingTabs: Array<{ value: TenantBillingTab; label: string }> = [
  { value: 'entitlements', label: '订阅与权益' },
  { value: 'wallet', label: '积分钱包' },
  { value: 'orders', label: '订单记录' },
  { value: 'usage', label: '用量报表' },
]

export function TenantBillingDetailPage() {
  const params = useParams()
  const tenantID = Number(params.id || 0)
  const [tenant, setTenant] = useState<Tenant | null>(null)
  const [insight, setInsight] = useState<TenantInsight | null>(null)
  const [overview, setOverview] = useState<TenantBillingOverview | null>(null)
  const [orders, setOrders] = useState<BillingPaymentOrder[]>([])
  const [usage, setUsage] = useState<BillingUsageAggregate[]>([])
  const [tab, setTab] = useState<TenantInsightTab>('summary')
  const [billingTab, setBillingTab] = useState<TenantBillingTab>('entitlements')
  const [editing, setEditing] = useState<BillingEntitlement | null>(null)
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    if (!tenantID) return
    setLoading(true)
    setErr('')
    try {
      const [tenantRes, insightRes, overviewRes, ordersRes, usageRes] = await Promise.all([
        Tenants.get(tenantID),
        TenantInsightAPI.get(tenantID),
        BillingAPI.getTenantOverview(tenantID),
        BillingAPI.listOrders({ tenant_id: String(tenantID), limit: 10, offset: 0 }),
        BillingAPI.listUsageAggregates({ tenant_id: String(tenantID), period: 'monthly', limit: 10, offset: 0 }),
      ])
      setTenant(tenantRes)
      setInsight(insightRes)
      setOverview(overviewRes)
      setOrders(ordersRes.items)
      setUsage(usageRes.items)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [tenantID])

  useEffect(() => scheduleTenantBillingLoad(load), [load])

  const entitlements = useMemo(() => {
    const items = [...(overview?.entitlements ?? [])]
    return items.sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0))
  }, [overview])

  return (
    <section>
      <PageHeader
        title={tenant ? tenant.Name : `租户 #${tenantID}`}
        subtitle="租户 360°：概况、使用健康、订阅配额与审计记录；详情只做摘要与下钻，不承载完整管理页。"
      />

      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <Tabs value={tab} items={tenantInsightTabs} onChange={setTab} />
        <Button onClick={load} disabled={loading}>
          <RefreshCw size={14} /> 刷新
        </Button>
      </div>

      {err && <InlineAlert>{err}</InlineAlert>}

      {tab === 'summary' && <InsightSummaryTab tenantID={tenantID} insight={insight} overview={overview} />}
      {tab === 'health' && <InsightHealthTab tenantID={tenantID} insight={insight} />}
      {tab === 'billing' && (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Tabs value={billingTab} items={tenantBillingTabs} onChange={setBillingTab} variant="underline" />
          </div>
          {billingTab === 'entitlements' && (
            <div className="space-y-4">
              <SubscriptionPanel overview={overview} />
              <EntitlementsTable items={entitlements} onEdit={setEditing} />
            </div>
          )}
          {billingTab === 'wallet' && <WalletPanel overview={overview} />}
          {billingTab === 'orders' && <OrdersPanel tenantID={tenantID} items={orders} />}
          {billingTab === 'usage' && <UsagePanel tenantID={tenantID} items={usage} />}
        </div>
      )}
      {tab === 'audit' && <InsightAuditTab tenantID={tenantID} />}

      {editing && (
        <OverrideDrawer
          tenantID={tenantID}
          entitlement={editing}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); void load() }}
        />
      )}
    </section>
  )
}

// 概况 Tab：成员/活跃/数字员工/套餐/积分/告警/异常，全部摘要 + 下钻。
function InsightSummaryTab({ tenantID, insight, overview }: {
  tenantID: number
  insight: TenantInsight | null
  overview: TenantBillingOverview | null
}) {
  if (!insight) return <Panel className="p-6 text-center text-[13px] text-[var(--color-text-sub)]">正在加载租户概况</Panel>
  const o = insight.overview
  const sub = overview?.subscription
  const metrics: Array<{ label: string; value: string; hint?: string; warn?: boolean }> = [
    { label: '成员总数', value: String(o.members), hint: `7 日活跃 ${o.active_members_7d} · 30 日活跃 ${insight.active_members_30d}` },
    { label: '数字员工', value: String(o.digital_employees), hint: `已发布 ${o.published}` },
    { label: '当前套餐', value: sub?.plan_name || o.billing?.plan_name || '未开通', hint: sub ? subscriptionStatusLabel(sub.status) : '' },
    {
      label: '积分余额',
      value: overview?.wallet ? overview.wallet.balance.toLocaleString() : '—',
      hint: overview?.wallet?.frozen ? (overview.wallet.balance_source === 'beebridge' ? '余额不足' : '钱包已冻结') : (o.billing ? `本月消耗 ${o.billing.month_credits_used.toLocaleString()}` : ''),
      warn: !!overview?.wallet?.frozen,
    },
    { label: '未恢复告警', value: String(insight.open_alerts), warn: insight.open_alerts > 0 },
    { label: '异常 Runtime', value: String(o.health.instances_abnormal), hint: `实例就绪 ${o.health.instances_ready}/${o.health.instances_total}`, warn: o.health.instances_abnormal > 0 },
    { label: '异常定时任务', value: String(o.todos.cron_errors), warn: o.todos.cron_errors > 0 },
    { label: '今日消息', value: String(o.messages_today), hint: `今日会话 ${o.conversations_today}` },
  ]
  return (
    <div className="space-y-4">
      <Panel className="p-4">
        <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-4">
          {metrics.map((m) => (
            <Metric key={m.label} label={m.label} value={m.value} hint={m.hint} warn={m.warn} />
          ))}
        </div>
      </Panel>
      <Panel className="p-4">
        <div className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">下钻入口</div>
        <div className="grid gap-1 sm:grid-cols-2 md:grid-cols-4">
          <DrillLink to={`/alerts?status=firing&tenant_id=${tenantID}`} label="查看该租户告警" />
          <DrillLink to={`/observability/agent-runs?tenant_id=${tenantID}`} label="查看运行记录" />
          <DrillLink to={`/observability/call-logs?tenant_id=${tenantID}`} label="查看调用日志" />
          <DrillLink to={`/billing/usage?tenant_id=${tenantID}`} label="查看用量统计" />
        </div>
      </Panel>
    </div>
  )
}

// 使用与健康 Tab：近 14 天趋势 + run 统计 + 异常项。
function InsightHealthTab({ tenantID, insight }: { tenantID: number; insight: TenantInsight | null }) {
  if (!insight) return <Panel className="p-6 text-center text-[13px] text-[var(--color-text-sub)]">正在加载使用与健康数据</Panel>
  const o = insight.overview
  const rs = insight.run_stats
  const trendPoints = o.trend.map((p) => ({
    label: p.date,
    title: `${p.date} · 成员消息 ${p.user_messages} · 员工回复 ${p.agent_messages} · 活跃成员 ${p.active_accounts}`,
    values: { user: p.user_messages, agent: p.agent_messages },
  }))
  return (
    <div className="space-y-4">
      <Panel className="p-4">
        <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-4">
          <Metric label="近 14 天运行" value={String(rs.runs_14d)} hint={`失败 ${rs.failed_14d}`} warn={rs.failed_14d > 0} />
          <Metric label="运行成功率" value={rs.success_rate != null ? `${rs.success_rate.toFixed(1)}%` : '—'} warn={rs.success_rate != null && rs.success_rate < 95} />
          <Metric label="P95 耗时" value={rs.p95_duration_ms != null ? `${(rs.p95_duration_ms / 1000).toFixed(1)}s` : '—'} warn={(rs.p95_duration_ms ?? 0) >= 60000} />
          <Metric label="24h 调用" value={String(o.health.calls_24h)} hint={`失败 ${o.health.calls_failed_24h}`} warn={o.health.calls_failed_24h > 0} />
        </div>
      </Panel>
      <Panel className="p-4">
        <div className="mb-3 flex items-center justify-between">
          <div className="text-[13px] font-semibold text-[var(--color-text)]">近 14 天使用趋势</div>
          <div className="flex gap-3 text-[13px]">
            <Link className="text-[var(--color-brand)] hover:underline" to={`/observability/agent-runs?tenant_id=${tenantID}`}>查看运行记录</Link>
            <Link className="text-[var(--color-brand)] hover:underline" to={`/observability/call-logs?tenant_id=${tenantID}`}>查看调用日志</Link>
          </div>
        </div>
        <TrendChart
          points={trendPoints}
          series={[
            { key: 'user', label: '成员消息', color: 'var(--color-icon-blue)' },
            { key: 'agent', label: '员工回复', color: 'var(--color-icon-purple)' },
          ]}
          height={200}
          emptyText="近 14 天还没有消息记录"
        />
      </Panel>
    </div>
  )
}

// 审计记录 Tab：最近高风险写操作摘要 + 全量入口。
function InsightAuditTab({ tenantID }: { tenantID: number }) {
  const [items, setItems] = useState<AuditEvent[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let cancelled = false
    AuditCenter.listPlatformEvents({ tenant_id: tenantID, limit: 20, offset: 0 })
      .then((resp) => { if (!cancelled) { setItems(resp.items || []); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tenantID])
  return (
    <div className="space-y-4">
      {err && <InlineAlert>{err}</InlineAlert>}
      <Panel className="p-4">
        <div className="mb-3 flex items-center justify-between">
          <div className="text-[13px] font-semibold text-[var(--color-text)]">最近审计事件 · 20 条</div>
          <Link className="text-[13px] text-[var(--color-brand)] hover:underline" to={`/audit?tenant_id=${tenantID}`}>查看全部审计 →</Link>
        </div>
        <DataTable
          headers={['时间', '操作人', '领域', '事件', '级别', '资源']}
          loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载审计事件</div> : undefined}
          empty={!loading && items.length === 0 ? <EmptyState title="暂无审计记录" description="该租户还没有产生管理操作审计。" /> : undefined}
        >
          {!loading && items.map((it) => (
            <tr key={it.id} className="group hover:bg-[var(--color-bg-sub)]">
              <Td>{dateTime(it.occurredAt)}</Td>
              <Td>{it.accountName || it.accountUsername || (it.accountId ? `#${it.accountId}` : '系统')}</Td>
              <Td>{it.domain}</Td>
              <Td strong>{it.eventKind}</Td>
              <Td>{it.severity}</Td>
              <Td mono>{it.resourceUuid ? `${it.resourceKind || ''} ${it.resourceUuid.slice(0, 12)}` : (it.resourceKind || '-')}</Td>
            </tr>
          ))}
        </DataTable>
      </Panel>
    </div>
  )
}

function DrillLink({ to, label }: { to: string; label: string }) {
  return (
    <Link
      to={to}
      className="group flex h-10 items-center justify-between rounded-lg px-3 text-[13px] text-[var(--color-text)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand)]"
    >
      <span>{label}</span>
      <ArrowRight size={14} className="text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />
    </Link>
  )
}

// ============================================================================
// 租户侧：订阅与配额（/billing/subscription，只读四 Tab，?tab= 深链）
// ============================================================================

type TenantSelfTab = 'plan' | 'quota' | 'wallet' | 'orders'

const tenantSelfTabs: Array<{ value: TenantSelfTab; label: string }> = [
  { value: 'plan', label: '套餐与权益' },
  { value: 'quota', label: '配额水位' },
  { value: 'wallet', label: '积分钱包' },
  { value: 'orders', label: '订单记录' },
]

function normalizeSelfTab(v: string | null): TenantSelfTab {
  return (['plan', 'quota', 'wallet', 'orders'] as const).includes(v as TenantSelfTab) ? (v as TenantSelfTab) : 'plan'
}

export function TenantBillingSubscriptionPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  // tab 直接从 URL 推导（?tab= 深链即时生效，无需同步 state）
  const tab = normalizeSelfTab(searchParams.get('tab'))
  const [overview, setOverview] = useState<TenantBillingOverview | null>(null)
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      const [subscription, entitlements, wallet] = await Promise.all([
        BillingAPI.getTenantSubscription(),
        BillingAPI.listTenantEntitlements(),
        BillingAPI.getTenantWallet().catch(() => null),
      ])
      setOverview({ subscription, entitlements: entitlements.items, wallet })
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => scheduleTenantBillingLoad(load), [load])

  const entitlements = [...(overview?.entitlements ?? [])].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0))
  const switchTab = (next: TenantSelfTab) => {
    setSearchParams(next === 'plan' ? {} : { tab: next }, { replace: true })
  }

  return (
    <section>
      <PageHeader
        title="订阅与配额"
        subtitle="查看当前套餐、权益配额、积分钱包与订单记录；套餐变更与积分购买请联系平台运营。"
      />
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <Tabs value={tab} items={tenantSelfTabs} onChange={switchTab} />
        <Button onClick={load} disabled={loading}>
          <RefreshCw size={14} /> 刷新
        </Button>
      </div>
      {err && <InlineAlert>{err}</InlineAlert>}

      {tab === 'plan' && (
        <div className="space-y-4">
          <SubscriptionPanel overview={overview} />
          <EntitlementsTable items={entitlements} />
        </div>
      )}
      {tab === 'quota' && <TenantQuotaTab items={entitlements} />}
      {tab === 'wallet' && <TenantWalletTab overview={overview} />}
      {tab === 'orders' && <TenantOrdersTab />}
    </section>
  )
}

// 配额水位 Tab：只保留 metered 权益的水位视角 + 用量下钻。
function TenantQuotaTab({ items }: { items: BillingEntitlement[] }) {
  const metered = items.filter((it) => it.feature_type === 'metered')
  return (
    <div className="space-y-4">
      <Panel className="p-4">
        <div className="mb-3 flex items-center justify-between">
          <div className="text-[13px] font-semibold text-[var(--color-text)]">配额水位（限制 / 已用 / 剩余）</div>
          <Link className="text-[13px] text-[var(--color-brand)] hover:underline" to="/billing/usage">查看用量统计 →</Link>
        </div>
        <DataTable
          headers={['配额项', '生效限额', '已使用', '剩余', '使用率']}
          empty={metered.length === 0 ? <EmptyState title="暂无配额项" description="当前套餐没有需要计量的配额。" /> : null}
        >
          {metered.map((item) => {
            const usage = entitlementUsage(item)
            const ratio = usage.limit != null && usage.limit > 0 ? usage.used / usage.limit : null
            const remainText = usage.limit == null
              ? '无限制'
              : (item.current_usage_bytes != null ? fmtBytes(Math.max(0, usage.limit - usage.used)) : Math.max(0, usage.limit - usage.used).toLocaleString())
            return (
              <tr key={item.feature_code} className="group hover:bg-[var(--color-bg-sub)]">
                <Td strong>{item.feature_name || featureLabel(item.feature_code)}</Td>
                <Td>{formatLimit(item.granted_value, item.granted_unit, item.granted_value_bytes)}</Td>
                <Td>{usage.text}</Td>
                <Td>{remainText}</Td>
                <Td><UsageBar ratio={ratio} /></Td>
              </tr>
            )
          })}
        </DataTable>
      </Panel>
    </div>
  )
}

// 积分钱包 Tab：余额卡 + 流水（后端分页）。
function TenantWalletTab({ overview }: { overview: TenantBillingOverview | null }) {
  const [items, setItems] = useState<BillingLedgerEntry[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let cancelled = false
    BillingAPI.listTenantLedger({ limit: pageSize, offset: (page - 1) * pageSize })
      .then((resp) => { if (!cancelled) { setItems(resp.items || []); setTotal(resp.total || 0); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [page, pageSize])

  return (
    <div className="space-y-4">
      <WalletPanel overview={overview} />
      {err && <InlineAlert>{err}</InlineAlert>}
      <Panel className="p-4">
        <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">{overview?.wallet?.balance_source === 'beebridge' ? '历史本地积分流水' : '积分流水'}</div>
        {overview?.wallet?.balance_source === 'beebridge' && <p className="mb-3 text-[13px] text-[var(--color-text-sub)]">以下保留切换前的本地账务记录；当前余额以模型账户为准，模型消费请查看用量明细。</p>}
        <DataTable
          headers={['时间', '类型', '变动量', '变动后余额', '来源单号']}
          loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载积分流水</div> : undefined}
          empty={!loading && items.length === 0 ? <EmptyState title="暂无积分流水" description={overview?.wallet?.balance_source === 'beebridge' ? '暂无切换前的本地账务记录。' : '积分发放与消耗后会在这里展示。'} /> : undefined}
        >
          {!loading && items.map((it) => (
            <tr key={it.id} className="group hover:bg-[var(--color-bg-sub)]">
              <Td>{dateTime(it.created_at)}</Td>
              <Td>{ledgerBizLabel(it.biz_type)}</Td>
              <Td strong className={it.direction === 'credit' ? 'text-[var(--color-success)]' : ''}>
                {it.direction === 'credit' ? '+' : '-'}{it.amount.toLocaleString()}
              </Td>
              <Td>{it.balance_after.toLocaleString()}</Td>
              <Td mono>{it.biz_no || '-'}</Td>
            </tr>
          ))}
        </DataTable>
        <Pagination
          total={total}
          page={page}
          pageSize={pageSize}
          onPageChange={(next) => { setLoading(true); setPage(next) }}
          onPageSizeChange={(next) => { setLoading(true); setPageSize(next); setPage(1) }}
        />
      </Panel>
    </div>
  )
}

// 订单记录 Tab：本租户订单（后端分页 + 详情 Drawer，无退款操作）。
function TenantOrdersTab() {
  const [items, setItems] = useState<BillingPaymentOrder[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [viewing, setViewing] = useState<BillingPaymentOrder | null>(null)
  useEffect(() => {
    let cancelled = false
    BillingAPI.listTenantOrders({ limit: pageSize, offset: (page - 1) * pageSize })
      .then((resp) => { if (!cancelled) { setItems(resp.items || []); setTotal(resp.total || 0); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [page, pageSize])

  return (
    <div className="space-y-4">
      {err && <InlineAlert>{err}</InlineAlert>}
      <Panel className="p-4">
        <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">订单记录</div>
        <DataTable
          headers={['订单号', '类型', '金额', '支付渠道', '状态', '创建时间', '操作']}
          stickyLastCol
          loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载订单</div> : undefined}
          empty={!loading && items.length === 0 ? <EmptyState title="暂无订单" description="本租户还没有产生订单。" /> : undefined}
        >
          {!loading && items.map((item) => (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <Td mono>{item.out_trade_no}</Td>
              <Td>{orderTypeLabel(item.order_type)}</Td>
              <Td>{(item.amount_cents / 100).toFixed(2)} {item.currency}</Td>
              <Td>{item.provider || '-'}</Td>
              <Td>{orderStatusLabel(item.status)}</Td>
              <Td>{dateTime(item.created_at)}</Td>
              <td className="sticky right-0 whitespace-nowrap bg-white px-4 py-2 group-hover:bg-[var(--color-bg-sub)]">
                <Button size="sm" variant="ghost" onClick={() => setViewing(item)}>详情</Button>
              </td>
            </tr>
          ))}
        </DataTable>
        <Pagination
          total={total}
          page={page}
          pageSize={pageSize}
          onPageChange={(next) => { setLoading(true); setPage(next) }}
          onPageSizeChange={(next) => { setLoading(true); setPageSize(next); setPage(1) }}
        />
      </Panel>
      {viewing && (
        <DrawerShell
          title={`订单 ${viewing.out_trade_no}`}
          subtitle={`${orderTypeLabel(viewing.order_type)} · ${orderStatusLabel(viewing.status)}`}
          width="sm"
          onClose={() => setViewing(null)}
          footer={<div className="flex justify-end"><Button variant="secondary" onClick={() => setViewing(null)}>关闭</Button></div>}
        >
          <div className="grid gap-2 sm:grid-cols-2">
            <Metric label="金额" value={`${(viewing.amount_cents / 100).toFixed(2)} ${viewing.currency}`} />
            <Metric label="支付渠道" value={viewing.provider || '-'} />
            <Metric label="状态" value={orderStatusLabel(viewing.status)} />
            <Metric label="创建时间" value={dateTime(viewing.created_at)} />
            {viewing.paid_at && <Metric label="支付时间" value={dateTime(viewing.paid_at)} />}
          </div>
        </DrawerShell>
      )}
    </div>
  )
}

// ============================================================================
// 共享区块（平台详情「订阅与配额」Tab 与租户页共用）
// ============================================================================

function SubscriptionPanel({ overview }: { overview: TenantBillingOverview | null }) {
  const sub = overview?.subscription
  return (
    <Panel className="p-4">
      <div className="grid gap-3 md:grid-cols-4">
        <Metric label="当前套餐" value={sub?.plan_name || '-'} hint={sub?.plan_code || ''} />
        <Metric label="订阅状态" value={subscriptionStatusLabel(sub?.status)} hint={sub?.in_grace_period ? '宽限期内' : ''} warn={!!sub?.in_grace_period} />
        <Metric label="当前周期" value={sub ? `${dateOnly(sub.current_period_start)} 至 ${dateOnly(sub.current_period_end)}` : '-'} />
        <Metric label="到期变更" value={sub?.pending_plan_name || '无'} hint={sub?.pending_effective_at ? dateOnly(sub.pending_effective_at) : ''} />
      </div>
    </Panel>
  )
}

function WalletPanel({ overview }: { overview: TenantBillingOverview | null }) {
  const wallet = overview?.wallet
  return (
    <Panel className="p-4">
      <div className="grid gap-3 md:grid-cols-4">
        <Metric label="积分余额" value={wallet ? wallet.balance.toLocaleString() : '—'} />
        <Metric label="可用积分" value={wallet ? wallet.available_credits.toLocaleString() : '—'} />
        {wallet?.balance_source === 'beebridge'
          ? <Metric label="余额来源" value="模型账户" hint={wallet.balance_observed_at ? `同步于 ${new Date(wallet.balance_observed_at).toLocaleString('zh-CN')}` : ''} />
          : <Metric label="已用透支" value={wallet ? wallet.overdraft_used.toLocaleString() : '—'} hint={wallet ? `透支上限 ${wallet.overdraft_limit.toLocaleString()}` : ''} /> }
        <Metric label="钱包状态" value={wallet ? (wallet.frozen ? '余额不足' : '正常') : '暂不可用'} warn={!!wallet?.frozen} />
      </div>
    </Panel>
  )
}

function EntitlementsTable({ items, onEdit }: { items: BillingEntitlement[]; onEdit?: (item: BillingEntitlement) => void }) {
  return (
    <DataTable
      headers={['权益', '类型', '套餐限额', '覆写值', '生效值', '已使用', '使用率', '操作']}
      empty={items.length === 0 ? <EmptyState title="暂无权益" description="当前租户还没有可展示的套餐权益。" /> : null}
      stickyLastCol
    >
      {items.map((item) => {
        const usage = entitlementUsage(item)
        const ratio = usage.limit != null && usage.limit > 0 ? usage.used / usage.limit : null
        return (
          <tr key={item.feature_code} className="group hover:bg-[var(--color-bg-sub)]">
            <Td strong>{item.feature_name || featureLabel(item.feature_code)}</Td>
            <Td>{featureTypeLabel(item.feature_type)}</Td>
            <Td>{formatLimit(item.plan_value, item.plan_unit, null)}</Td>
            <Td>{item.override_value == null ? '-' : formatLimit(item.override_value, item.override_unit, null)}</Td>
            <Td>{formatLimit(item.granted_value, item.granted_unit, item.granted_value_bytes)}</Td>
            <Td>{usage.text}</Td>
            <Td><UsageBar ratio={ratio} /></Td>
            <td className="sticky right-0 bg-white px-4 py-2 group-hover:bg-[var(--color-bg-sub)]">
              {onEdit ? (
                <Button size="sm" variant="secondary" onClick={() => onEdit(item)}>
                  <Pencil size={14} /> 覆写
                </Button>
              ) : '-'}
            </td>
          </tr>
        )
      })}
    </DataTable>
  )
}

function OrdersPanel({ tenantID, items }: { tenantID: number; items: BillingPaymentOrder[] }) {
  const nav = useNavigate()
  return (
    <Panel className="p-4">
      <div className="mb-3 flex items-center justify-between">
        <div className="text-[13px] font-semibold text-[var(--color-text)]">最近订单</div>
        <Button onClick={() => nav(`/billing/orders?tenant_id=${tenantID}`)}>查看全部</Button>
      </div>
      <DataTable headers={['订单号', '类型', '金额', '状态', '创建时间']} empty={items.length === 0 ? <EmptyState title="暂无订单" /> : null}>
        {items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td mono>{item.out_trade_no}</Td>
            <Td>{orderTypeLabel(item.order_type)}</Td>
            <Td>{(item.amount_cents / 100).toFixed(2)} {item.currency}</Td>
            <Td>{orderStatusLabel(item.status)}</Td>
            <Td>{dateTime(item.created_at)}</Td>
          </tr>
        ))}
      </DataTable>
    </Panel>
  )
}

function UsagePanel({ tenantID, items }: { tenantID: number; items: BillingUsageAggregate[] }) {
  const nav = useNavigate()
  return (
    <Panel className="p-4">
      <div className="mb-3 flex items-center justify-between">
        <div className="text-[13px] font-semibold text-[var(--color-text)]">最近用量</div>
        <Button onClick={() => nav(`/billing/usage?tenant_id=${tenantID}`)}>查看全部</Button>
      </div>
      <DataTable headers={['资源类型', '周期', '数量', '积分', '事件数']} empty={items.length === 0 ? <EmptyState title="暂无用量" /> : null}>
        {items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td>{item.resource_type}</Td>
            <Td>{dateOnly(item.period_start)}</Td>
            <Td>{item.total_amount.toLocaleString()}</Td>
            <Td>{item.total_credits.toLocaleString()}</Td>
            <Td>{item.event_count.toLocaleString()}</Td>
          </tr>
        ))}
      </DataTable>
    </Panel>
  )
}

function OverrideDrawer({ tenantID, entitlement, onClose, onSaved }: {
  tenantID: number
  entitlement: BillingEntitlement
  onClose: () => void
  onSaved: () => void
}) {
  const [value, setValue] = useState(entitlement.override_value != null ? String(entitlement.override_value) : '')
  const [unit, setUnit] = useState(entitlement.override_unit || entitlement.granted_unit || '')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      await BillingAPI.createOverride({
        tenant_id: tenantID,
        feature_code: entitlement.feature_code,
        override_value: value.trim() === '' ? null : Number(value),
        override_unit: unit || undefined,
        reason,
      })
      onSaved()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={`覆写权益 · ${entitlement.feature_name || featureLabel(entitlement.feature_code)}`}
      subtitle="新覆写会立即影响该租户的生效配额；历史超配按存量保留、新增拦截处理。"
      icon={<Gauge className="h-4 w-4" />}
      width="sm"
      onClose={onClose}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="primary" disabled={busy || !reason.trim()} onClick={submit}>保存覆写</Button>
        </div>
      )}
    >
      {err && <InlineAlert>{err}</InlineAlert>}
      <div className="space-y-4">
        <FormField label="新限额">
          <Input value={value} onChange={(e) => setValue(e.target.value.replace(/[^\d-]/g, ''))} placeholder="留空表示无限制" />
        </FormField>
        <FormField label="单位">
          <Input value={unit} onChange={(e) => setUnit(e.target.value)} placeholder="GB / MB / 个 / 人" />
        </FormField>
        <FormField label="原因">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="例如：商务定制、临时扩容" />
        </FormField>
      </div>
    </DrawerShell>
  )
}

function Metric({ label, value, hint = '', warn = false }: { label: string; value: string; hint?: string; warn?: boolean }) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white p-3">
      <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
      <div className={`mt-1 truncate text-[18px] font-semibold ${warn ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]'}`}>{value}</div>
      {hint && <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]">{hint}</div>}
    </div>
  )
}

function UsageBar({ ratio }: { ratio: number | null }) {
  if (ratio == null) return <span className="text-[var(--color-text-mute)]">-</span>
  const pct = Math.round(Math.max(0, ratio) * 100)
  const color = pct >= 100 ? 'var(--color-danger)' : pct >= 80 ? 'var(--color-warn)' : 'var(--color-brand)'
  return (
    <div className="flex min-w-[120px] items-center gap-2">
      <div className="h-2 flex-1 overflow-hidden rounded-full bg-[var(--color-bg-sub)]">
        <div className="h-full rounded-full" style={{ width: `${Math.min(100, pct)}%`, background: color }} />
      </div>
      <span className="w-10 text-right text-[12px] tabular-nums text-[var(--color-text-sub)]">{pct}%</span>
    </div>
  )
}

function entitlementUsage(item: BillingEntitlement) {
  const used = item.current_usage_bytes ?? item.current_usage ?? null
  const limit = item.granted_value_bytes ?? item.granted_value ?? null
  if (used == null) return { used: 0, limit, text: '-' }
  const formatter = item.current_usage_bytes != null ? fmtBytes : (n: number) => n.toLocaleString()
  return {
    used,
    limit,
    text: limit == null ? formatter(used) : `${formatter(used)} / ${formatter(limit)}`,
  }
}

function formatLimit(value?: number | null, unit?: string | null, bytes?: number | null) {
  if (bytes != null) return fmtBytes(bytes)
  if (value == null) return '无限制'
  return unit ? `${value.toLocaleString()} ${unit}` : value.toLocaleString()
}

function fmtBytes(value: number) {
  if (value < 0) return '无限制'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let size = value
  let index = 0
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024
    index++
  }
  return `${size >= 10 ? size.toFixed(0) : size.toFixed(1).replace(/\\.0$/, '')} ${units[index]}`
}

function featureLabel(code: string) {
  const labels: Record<string, string> = {
    member_limit: '团队成员',
    digital_employee_limit: '数字员工',
    automation_task_limit: '自动任务',
    knowledge_file_storage_limit: '知识库容量',
    drive_file_storage_limit: '云盘容量',
    digital_employee_av_call: '数字员工音视频通话',
    can_buy_credit_pack: '积分包购买',
  }
  return labels[code] || code
}

function featureTypeLabel(type: string) {
  if (type === 'boolean') return '开关'
  if (type === 'metered') return '额度'
  if (type === 'rate_limit') return '频率'
  return type || '-'
}

function subscriptionStatusLabel(status?: string) {
  const labels: Record<string, string> = {
    trialing: '试用',
    active: '生效中',
    past_due: '宽限期',
    canceled: '已取消',
    expired: '已过期',
  }
  return labels[status || ''] || status || '-'
}

function orderTypeLabel(type?: string) {
  const labels: Record<string, string> = {
    subscription: '套餐订阅',
    credit_pack: '积分包',
    upgrade: '套餐订阅',
  }
  return labels[type || ''] || type || '-'
}

function orderStatusLabel(status?: string) {
  const labels: Record<string, string> = {
    created: '待支付',
    paying: '支付中',
    paid: '已支付',
    closed: '已关闭',
    refunding: '退款中',
    refunded: '已退款',
  }
  return labels[status || ''] || status || '-'
}

function ledgerBizLabel(bizType: string) {
  const labels: Record<string, string> = {
    subscription_grant: '订阅发放',
    pack_purchase: '积分包购买',
    promotion_grant: '活动赠送',
    skill_consume: '技能调用',
    consume_marker: '消耗',
    expire: '积分过期',
    refund: '退款',
    refund_clawback: '退款扣回',
    llm_consume: '模型消费',
    llm_refund: '模型费用返还',
    rtc_consume: '音视频通话',
    overdraft_repay: '透支偿还',
  }
  return labels[bizType] || bizType
}

function dateOnly(value?: string) {
  if (!value) return '-'
  return value.slice(0, 10)
}

function dateTime(value?: string) {
  if (!value) return '-'
  return new Date(value).toLocaleString()
}

function scheduleTenantBillingLoad(load: () => Promise<void>) {
  const timer = window.setTimeout(() => { void load() }, 0)
  return () => window.clearTimeout(timer)
}

function Td({ children, strong = false, mono = false, className = '' }: {
  children: ReactNode
  strong?: boolean
  mono?: boolean
  className?: string
}) {
  return (
    <td className={`whitespace-nowrap px-4 py-2 text-[13px] ${strong ? 'font-medium text-[var(--color-text)]' : 'text-[var(--color-text-sub)]'} ${mono ? 'font-mono text-[12px]' : ''} ${className}`}>
      {children}
    </td>
  )
}
