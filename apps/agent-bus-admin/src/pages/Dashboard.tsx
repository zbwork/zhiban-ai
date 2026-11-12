import { useEffect, useState } from 'react'
import { Link, useOutletContext } from 'react-router-dom'
import { Stats, type PlatformOverview, type TenantOverview, type TenantTodos, type ScopeOption } from '../lib/api'
import {
  Activity, AlertTriangle, ArrowRight, BellRing, BookOpen, Bot, Building, Calendar, CheckCircle2,
  CheckSquare, Circle, Coins, Cpu, MessageSquare, ServerCog, Timer, Users,
} from 'lucide-react'
import { EmptyState, TrendChart } from '../components/ui'

export function Dashboard({ scope }: { scope: 'platform' | 'tenant' }) {
  return scope === 'platform' ? <PlatformDashboard /> : <TenantDashboard />
}

export function ScopedDashboard() {
  const { actScope, switchingScope } = useOutletContext<{ actScope: ScopeOption | null; switchingScope?: boolean }>()
  if (switchingScope) return <Loading />
  return <Dashboard scope={actScope?.kind === 'tenant' ? 'tenant' : 'platform'} />
}

function PlatformDashboard() {
  const [o, setO] = useState<PlatformOverview | null>(null)
  const [err, setErr] = useState('')
  useEffect(() => {
    Stats.platformOverview().then(setO).catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <Err msg={err} />
  if (!o) return <Loading />

  const h = o.health
  const runsBad = h.success_rate != null && h.success_rate < 95
  const cards = [
    { icon: Building, label: '租户', value: o.tenants, hint: `活跃 ${o.active_tenants}`, color: 'text-blue-700 bg-blue-50' },
    { icon: Users, label: '账号', value: o.accounts, hint: '当前生效成员', color: 'text-emerald-700 bg-emerald-50' },
    { icon: Bot, label: '数字员工', value: o.digital_employees, color: 'text-blue-700 bg-blue-50' },
    { icon: Cpu, label: '运行环境', value: o.runtimes, hint: '平台托管与外部接入', color: 'text-purple-700 bg-purple-50' },
    { icon: Calendar, label: '今日会话', value: o.conversations_today, hint: `消息 ${o.messages_today}`, color: 'text-amber-700 bg-amber-50' },
    {
      icon: Activity, label: '今日 Agent 运行',
      value: h.runs_today,
      hint: h.runs_today > 0
        ? `成功率 ${h.success_rate?.toFixed(1) ?? '—'}% · 失败 ${h.runs_failed_today}`
        : '今天还没有运行记录',
      color: runsBad ? 'text-red-700 bg-red-50' : 'text-emerald-700 bg-emerald-50',
      to: '/observability/agent-runs',
    },
  ]

  // 平台健康：每项直接回答「有没有问题、去哪处理」，全 0 即绿。
  const healthItems: Array<{
    label: string
    to: string
    icon: React.ComponentType<{ size?: number; className?: string }>
    count?: number
    text?: string
    warn?: boolean
  }> = [
    { label: 'Agent 运行失败 · 今日', count: h.runs_failed_today, to: '/observability/agent-runs?status=failed', icon: Activity },
    { label: 'P95 运行耗时 · 今日', text: h.p95_duration_ms != null ? `${(h.p95_duration_ms / 1000).toFixed(1)}s` : '—', warn: (h.p95_duration_ms ?? 0) >= 60000, to: '/observability/agent-runs', icon: Timer },
    { label: '异常运行实例', count: h.instances_abnormal, to: '/runtime-hosting', icon: ServerCog },
    { label: '异常知识库服务', count: h.providers_abnormal, to: '/ragflow-ops', icon: BookOpen },
    { label: '连续失败定时任务', count: h.cron_error_jobs, to: '/cron-jobs', icon: Timer },
    { label: '云盘任务异常', count: h.drive_worker_backlog, to: '/drive/workers', icon: ServerCog },
    { label: '事件总线积压 / 死信', count: h.outbox_backlog, to: '/alerts?status=firing', icon: AlertTriangle },
  ]
  const abnormalCount = healthItems.filter((it) => (it.count ?? 0) > 0 || it.warn).length

  return (
    <div>
      <Header title="平台总览" subtitle="先回答今天平台健不健康、影响了几个租户，再决定去哪里处理。" />
      <StatGrid cards={cards} />

      <div className="mt-6 grid grid-cols-1 gap-5 lg:grid-cols-3">
        <Tile
          className="lg:col-span-2"
          title="平台健康"
          rightLink={{ to: '/alerts?status=firing', label: `受影响租户 ${h.affected_tenants} 个 →` }}
        >
          {abnormalCount === 0 ? (
            <EmptyState
              tone="success"
              icon={<CheckCircle2 size={24} />}
              title="平台运行正常"
              description="全部健康信号无异常，出现问题会先出现在这里和告警中心。"
              className="min-h-0 py-8"
            />
          ) : (
            <div className="grid grid-cols-1 gap-1 sm:grid-cols-2">
              {healthItems.map((it) => {
                const Icon = it.icon
                const bad = (it.count ?? 0) > 0 || it.warn
                return (
                  <Link
                    key={it.label}
                    to={it.to}
                    className="group flex h-11 items-center justify-between rounded-lg px-3 text-[14px] text-[var(--color-text)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand)]"
                  >
                    <span className="flex min-w-0 items-center gap-2.5">
                      <Icon size={15} className={bad ? 'shrink-0 text-[var(--color-danger)]' : 'shrink-0 text-[var(--color-text-mute)]'} />
                      <span className="truncate">{it.label}</span>
                    </span>
                    <span className="flex shrink-0 items-center gap-2">
                      <span className={`rounded-full px-2 py-0.5 text-xs font-semibold tabular-nums ${bad ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]' : 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'}`}>
                        {it.text ?? it.count}
                      </span>
                      <ArrowRight size={14} className="text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />
                    </span>
                  </Link>
                )
              })}
            </div>
          )}
        </Tile>

        <Tile title="待处理告警" rightLink={{ to: '/alerts?status=firing', label: '查看全部告警 →' }}>
          {o.top_alerts.length === 0 ? (
            <EmptyState
              tone="success"
              icon={<BellRing size={24} />}
              title="暂无待处理告警"
              description="评估器每分钟巡检一轮，新告警会出现在这里。"
              className="min-h-0 py-8"
            />
          ) : (
            <div className="space-y-1">
              {o.top_alerts.map((a) => (
                <Link
                  key={a.uuid}
                  to="/alerts?status=firing"
                  className="group flex items-center justify-between gap-2 rounded-lg px-3 py-2 transition hover:bg-[var(--color-brand-soft)]"
                >
                  <span className="flex min-w-0 items-center gap-2">
                    <span className={`h-2 w-2 shrink-0 rounded-full ${a.severity === 'critical' ? 'bg-[var(--color-danger)]' : 'bg-[var(--color-warn)]'}`} />
                    <span className="min-w-0">
                      <span className="block truncate text-[13px] font-medium text-[var(--color-text)] group-hover:text-[var(--color-brand)]">{a.title}</span>
                      <span className="block truncate text-[12px] text-[var(--color-text-mute)]">
                        {a.tenant_name || (a.tenant_id ? `租户 #${a.tenant_id}` : '平台级')} · 命中 {a.occurrence_count} 次
                      </span>
                    </span>
                  </span>
                  <ArrowRight size={14} className="shrink-0 text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />
                </Link>
              ))}
            </div>
          )}
        </Tile>
      </div>
    </div>
  )
}

function TenantDashboard() {
  const [o, setO] = useState<TenantOverview | null>(null)
  const [err, setErr] = useState('')
  useEffect(() => {
    Stats.tenantOverview().then(setO).catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <Err msg={err} />
  if (!o) return <Loading />

  const activation = o.members > 0 ? Math.round((o.active_members_7d / o.members) * 100) : null
  const healthBad = o.health.calls_failed_24h > 0 || o.health.instances_abnormal > 0
  const isNewTenant = o.digital_employees === 0 || o.members <= 1

  const cards = [
    { icon: Bot, label: '数字员工', value: o.digital_employees, hint: `已发布 ${o.published}`, color: 'text-terracotta-deep bg-terracotta-soft' },
    {
      icon: Users, label: '7 日活跃成员',
      value: `${o.active_members_7d}/${o.members}`,
      hint: activation === null ? '还没有成员' : `激活率 ${activation}%`,
      color: 'text-emerald-700 bg-emerald-50',
    },
    { icon: MessageSquare, label: '今日消息', value: o.messages_today, hint: `今日会话 ${o.conversations_today}`, color: 'text-indigo-700 bg-indigo-50' },
    {
      icon: Coins, label: '积分余额',
      value: o.billing ? o.billing.credit_balance.toLocaleString() : '—',
      hint: !o.billing
        ? '未开通套餐'
        : o.billing.wallet_frozen
          ? '钱包已冻结'
          : `本月消耗 ${o.billing.month_credits_used.toLocaleString()} · ${o.billing.plan_name}`,
      color: o.billing?.wallet_frozen ? 'text-red-700 bg-red-50' : 'text-amber-700 bg-amber-50',
      to: '/billing/subscription?tab=wallet',
    },
    {
      icon: Activity, label: '24h 调用',
      value: o.health.calls_24h,
      hint: `失败 ${o.health.calls_failed_24h}${o.health.instances_total > 0 ? ` · 实例就绪 ${o.health.instances_ready}/${o.health.instances_total}` : ''}`,
      color: healthBad ? 'text-red-700 bg-red-50' : 'text-emerald-700 bg-emerald-50',
      to: '/observability/agent-runs',
    },
  ]

  const trendPoints = o.trend.map((p) => ({
    label: p.date,
    title: `${p.date} · 成员消息 ${p.user_messages} · 员工回复 ${p.agent_messages} · 活跃成员 ${p.active_accounts}`,
    values: { user: p.user_messages, agent: p.agent_messages },
  }))

  return (
    <div>
      <Header title="租户控制台" subtitle="一眼看清采用、用量、成本、健康与待办，再决定去哪里处理。" />
      <StatGrid cards={cards} />

      <div className="mt-6 grid grid-cols-1 gap-5 lg:grid-cols-3">
        <Tile className="lg:col-span-2" title="近 14 天使用趋势">
          <TrendChart
            points={trendPoints}
            series={[
              { key: 'user', label: '成员消息', color: 'var(--color-icon-blue)' },
              { key: 'agent', label: '员工回复', color: 'var(--color-icon-purple)' },
            ]}
            height={200}
            emptyText="近 14 天还没有消息记录"
          />
        </Tile>
        {isNewTenant ? <OnboardingTile o={o} /> : <TodoTile todos={o.todos} />}

        <Tile className="lg:col-span-2" title="最活跃数字员工 · 近 7 天" rightLink={{ to: '/agents', label: '管理数字员工 →' }}>
          {o.top_agents.length === 0 ? (
            <EmptyState
              icon={<Bot size={24} />}
              title="近 7 天还没有使用记录"
              description="成员在客户端与数字员工对话后，这里会出现使用排行。"
              className="min-h-0 py-8"
            />
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left border-b border-[var(--color-line)]">
                  <Th>数字员工</Th>
                  <Th>会话</Th>
                  <Th>消息</Th>
                  <Th>服务成员</Th>
                </tr>
              </thead>
              <tbody>
                {o.top_agents.map((t, i) => (
                  <tr key={`${t.name}-${i}`} className="border-b border-[var(--color-line-soft)] last:border-b-0 hover:bg-[var(--color-parchment-sub)]/40">
                    <td className="px-2 py-2.5">
                      <span className="inline-flex max-w-full items-center gap-2">
                        <span className="grid h-5 w-5 shrink-0 place-items-center rounded bg-[var(--color-brand-soft)] text-[11px] font-semibold text-[var(--color-brand)]">{i + 1}</span>
                        <span className="truncate">{t.name}</span>
                      </span>
                    </td>
                    <td className="px-2 py-2.5 tabular-nums">{t.conversations_7d}</td>
                    <td className="px-2 py-2.5 tabular-nums">{t.messages_7d}</td>
                    <td className="px-2 py-2.5 tabular-nums">{t.users_7d}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Tile>
        <Tile title="快捷入口">
          <NavLink to="/agents" label="数字员工" />
          <NavLink to="/skills" label="技能管理" />
          <NavLink to="/kb" label="知识库" />
          <NavLink to="/members" label="成员" />
          <NavLink to="/billing/usage" label="用量明细" />
          <NavLink to="/observability/call-logs" label="调用日志" />
        </Tile>
      </div>
    </div>
  )
}

// 待办事项：只列 >0 的项；全空给正常空态。
function TodoTile({ todos }: { todos: TenantTodos }) {
  const items = [
    { icon: BellRing, label: '未处理告警', count: todos.alerts_firing ?? 0, to: '/alerts?status=firing' },
    { icon: CheckSquare, label: '待审批件', count: todos.approvals_pending ?? 0, to: '/approvals' },
    { icon: Bot, label: '草稿待发布的数字员工', count: todos.draft_agents, to: '/agents' },
    { icon: Timer, label: '定时任务异常', count: todos.cron_errors, to: '/cron' },
    { icon: BookOpen, label: '知识库导入失败 · 近 7 天', count: todos.kb_ingest_failed_7d, to: '/kb-documents' },
    { icon: ServerCog, label: '运行实例异常', count: todos.instances_abnormal, to: '/runtime-environments' },
  ].filter((item) => item.count > 0)
  return (
    <Tile title="待办事项">
      {items.length === 0 ? (
        <EmptyState
          tone="success"
          icon={<CheckCircle2 size={24} />}
          title="一切正常"
          description="暂无需要处理的事项。"
          className="min-h-0 py-8"
        />
      ) : (
        <div className="space-y-1">
          {items.map((item) => {
            const Icon = item.icon
            return (
              <Link
                key={item.label}
                to={item.to}
                className="group flex h-11 items-center justify-between rounded-lg px-3 text-[14px] text-[var(--color-text)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand)]"
              >
                <span className="flex min-w-0 items-center gap-2.5">
                  <Icon size={15} className="shrink-0 text-[var(--color-text-mute)]" />
                  <span className="truncate">{item.label}</span>
                </span>
                <span className="flex shrink-0 items-center gap-2">
                  <span className="rounded-full bg-[var(--color-danger-bg)] px-2 py-0.5 text-xs font-semibold tabular-nums text-[var(--color-danger)]">
                    {item.count}
                  </span>
                  <ArrowRight size={14} className="text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />
                </span>
              </Link>
            )
          })}
        </div>
      )}
    </Tile>
  )
}

// 新租户（还没有数字员工或只有 1 个成员）用入门清单替代待办。
function OnboardingTile({ o }: { o: TenantOverview }) {
  const steps = [
    { label: '创建第一个数字员工', done: o.digital_employees > 0, to: '/agents' },
    { label: '发布数字员工', done: o.published > 0, to: '/agents' },
    { label: '创建知识库', done: o.kb_count > 0, to: '/kb' },
    { label: '邀请成员加入', done: o.members > 1, to: '/members' },
  ]
  const doneCount = steps.filter((s) => s.done).length
  return (
    <Tile title="快速开始">
      <div className="mb-3 text-[13px] text-[var(--color-text-sub)]">
        完成 {doneCount}/{steps.length} 步，把数字员工交付给团队。
      </div>
      <div className="space-y-1">
        {steps.map((s) => (
          <Link
            key={s.label}
            to={s.to}
            className="group flex h-11 items-center justify-between rounded-lg px-3 text-[14px] transition hover:bg-[var(--color-brand-soft)]"
          >
            <span className="flex min-w-0 items-center gap-2.5">
              {s.done ? (
                <CheckCircle2 size={16} className="shrink-0 text-emerald-600" />
              ) : (
                <Circle size={16} className="shrink-0 text-[var(--color-text-mute)]" />
              )}
              <span className={s.done ? 'truncate text-[var(--color-text-mute)] line-through' : 'truncate text-[var(--color-text)] group-hover:text-[var(--color-brand)]'}>
                {s.label}
              </span>
            </span>
            {!s.done && <ArrowRight size={14} className="shrink-0 text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />}
          </Link>
        ))}
      </div>
    </Tile>
  )
}

// --- 小组件 ---

function Header({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="mb-7">
      <div className="mb-2 text-[12px] font-semibold uppercase tracking-[0.08em] text-[var(--color-brand)]">
        {title.includes('平台') ? 'Platform Overview' : 'Tenant Overview'}
      </div>
      <h1 className="mb-2 text-[30px] font-semibold leading-tight text-[var(--color-text)]">{title}</h1>
      <p className="text-[15px] leading-6 text-[var(--color-text-sub)]">{subtitle}</p>
    </div>
  )
}

type StatCard = {
  icon: React.ComponentType<{ size?: number; className?: string }>
  label: string
  value: number | string
  hint?: string
  color: string
  // F25: 可点击卡片的下钻路由（如 积分余额 → 订阅与配额钱包 Tab）
  to?: string
}

function StatGrid({ cards }: { cards: StatCard[] }) {
  const xlColumns = cards.length === 5 ? 'xl:grid-cols-5' : 'xl:grid-cols-6'
  return (
    <div className={`grid grid-cols-2 gap-4 sm:grid-cols-3 ${xlColumns}`}>
      {cards.map((c) => {
        const Icon = c.icon
        const body = (
          <>
            <div className="mb-3 flex items-center justify-between gap-3">
              <div className="truncate text-[13px] text-[var(--color-text-mute)]">{c.label}</div>
              <div className={`grid h-8 w-8 shrink-0 place-items-center rounded-lg ${c.color}`}>
                <Icon size={15} />
              </div>
            </div>
            <div className="text-[30px] font-semibold leading-none text-[var(--color-text)]">{c.value}</div>
            {c.hint && <div className="mt-2 truncate text-[13px] text-[var(--color-text-mute)]">{c.hint}</div>}
          </>
        )
        const cls = 'min-h-[118px] rounded-lg border border-[var(--color-line)] bg-white/[0.94] px-4 py-4 shadow-[rgba(15,107,255,0.08)_0px_0px_0px_1px,rgba(15,23,42,0.04)_0px_12px_28px]'
        if (c.to) {
          return (
            <Link key={c.label} to={c.to} className={`${cls} block transition hover:border-[var(--color-brand-line)]`}>
              {body}
            </Link>
          )
        }
        return <div key={c.label} className={cls}>{body}</div>
      })}
    </div>
  )
}

function Tile({
  title,
  children,
  className = '',
  rightLink,
}: {
  title: string
  children: React.ReactNode
  className?: string
  rightLink?: { to: string; label: string }
}) {
  return (
    <div className={`rounded-lg border border-[var(--color-line)] bg-white/[0.94] p-6 shadow-[rgba(15,107,255,0.07)_0px_0px_0px_1px,rgba(15,23,42,0.04)_0px_16px_32px] ${className}`}>
      <div className="mb-4 flex items-baseline justify-between">
        <h3 className="text-[20px] font-semibold text-[var(--color-text)]">{title}</h3>
        {rightLink && (
          <Link to={rightLink.to} className="text-xs text-[var(--color-terracotta)] hover:underline">
            {rightLink.label}
          </Link>
        )}
      </div>
      {children}
    </div>
  )
}

function NavLink({ to, label }: { to: string; label: string }) {
  return (
    <Link
      to={to}
      className="group flex h-11 items-center justify-between rounded-lg px-3 text-[14px] text-[var(--color-text)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand)]"
    >
      <span>{label}</span>
      <ArrowRight size={14} className="text-[var(--color-text-mute)] group-hover:text-[var(--color-brand)]" />
    </Link>
  )
}

function Th({ children }: { children: React.ReactNode }) {
  return <th className="px-2 py-2 text-xs uppercase tracking-wide text-[var(--color-ink-mute)] font-medium">{children}</th>
}

function Loading() {
  return <div className="text-[var(--color-ink-mute)] py-10 text-center text-sm">加载中…</div>
}

function Err({ msg }: { msg: string }) {
  return <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md p-4">{msg}</div>
}
