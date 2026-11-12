// F08 §5.3 · 平台定时任务统计看板 (/cron-dashboard, platform scope).
//
// 统计看板回答三个运营问题:
// 1. 平台调度今天是否健康?
// 2. 失败集中在哪些租户/原因?
// 3. 哪些任务或能力冲突需要优先处理?
//
// 调用:
//   GET /api/admin/v1/platform/cron-jobs/overview
//   GET /api/admin/v1/platform/cron/capability-dry-run
import { useEffect, useState, type ComponentType, type ReactNode } from 'react'
import {
  Activity,
  AlertTriangle,
  ArrowUpRight,
  CheckCircle2,
  Clock3,
  ListChecks,
  ShieldAlert,
  ShieldCheck,
  TrendingUp,
  XCircle,
} from 'lucide-react'
import {
  CronAdmin,
  PlatformCronJobs,
  type CronDryRunConflict,
  type CronDryRunReport,
  type PlatformCronOverviewDTO,
} from '../lib/api'
import { Button, InlineAlert, PageHeader, Panel } from '../components/ui'

function formatDateTime(raw?: string): string {
  if (!raw) return '-'
  const t = new Date(raw)
  if (isNaN(t.getTime())) return '-'
  return t.toLocaleString('zh-CN', { hour12: false })
}

export default function PlatformCronDashboardPage() {
  const [overview, setOverview] = useState<PlatformCronOverviewDTO | null>(null)
  const [overviewLoading, setOverviewLoading] = useState(true)
  const [overviewErr, setOverviewErr] = useState('')
  const [capabilityReport, setCapabilityReport] = useState<CronDryRunReport | null>(null)
  const [capabilityLoading, setCapabilityLoading] = useState(true)
  const [capabilityErr, setCapabilityErr] = useState('')
  const [reloadTick, setReloadTick] = useState(0)

  useEffect(() => {
    let active = true
    PlatformCronJobs.overview()
      .then((res) => {
        if (!active) return
        setOverview(res)
        setOverviewErr('')
      })
      .catch((e: unknown) => {
        if (!active) return
        setOverview(null)
        setOverviewErr((e as Error).message || '统计加载失败')
      })
      .finally(() => {
        if (active) setOverviewLoading(false)
      })
    return () => {
      active = false
    }
  }, [reloadTick])

  useEffect(() => {
    let active = true
    CronAdmin.dryRun()
      .then((res) => {
        if (!active) return
        setCapabilityReport(res)
        setCapabilityErr('')
      })
      .catch((e: unknown) => {
        if (!active) return
        setCapabilityReport(null)
        setCapabilityErr((e as Error).message || '能力冲突检查失败')
      })
      .finally(() => {
        if (active) setCapabilityLoading(false)
      })
    return () => {
      active = false
    }
  }, [reloadTick])

  function refresh() {
    setOverviewLoading(true)
    setCapabilityLoading(true)
    setReloadTick((t) => t + 1)
  }

  return (
    <div className="space-y-4">
      <PageHeader
        className="mb-1"
        title="统计看板"
        subtitle="按运营场景查看平台定时任务健康度、失败集中点和待处理风险。具体任务查询请进入「定时任务列表」。"
        actions={overview ? (
          <div className="flex flex-wrap items-center justify-end gap-2">
            <TimePill icon={<Clock3 size={13} />} label="最近调度" value={formatDateTime(overview.last_run_at)} />
            <TimePill icon={<AlertTriangle size={13} />} label="最近失败" value={formatDateTime(overview.last_failure_at)} />
            <Button variant="secondary" size="sm" onClick={refresh}>刷新</Button>
          </div>
        ) : (
          <Button variant="secondary" size="sm" onClick={refresh}>刷新</Button>
        )}
      />

      {overviewErr && <InlineAlert tone="danger">{overviewErr}</InlineAlert>}

      {overview ? (
        <>
          <OverviewCards overview={overview} />
          <ScenarioPanel overview={overview} capabilityReport={capabilityReport} capabilityLoading={capabilityLoading} />
          <FailureStats overview={overview} />
        </>
      ) : overviewLoading ? (
        <Panel className="px-4 py-8 text-center text-[13px] text-[var(--color-text-mute)]">统计加载中...</Panel>
      ) : null}

      <CapabilityPanel
        report={capabilityReport}
        loading={capabilityLoading}
        error={capabilityErr}
      />
    </div>
  )
}

function OverviewCards({ overview }: { overview: PlatformCronOverviewDTO }) {
  const rate = overview.success_rate == null ? '-' : `${overview.success_rate}%`
  const cards = [
    { label: '任务总数', value: overview.total_jobs, icon: ListChecks },
    { label: '运行中', value: overview.active_jobs, icon: Activity },
    { label: '近 24h 成功', value: overview.runs_24h_succeeded, icon: CheckCircle2, success: true },
    { label: '近 24h 失败', value: overview.runs_24h_failed, icon: XCircle, danger: overview.runs_24h_failed > 0 },
    { label: '近 24h 成功率', value: rate, icon: TrendingUp, danger: overview.success_rate != null && overview.success_rate < 95 },
    { label: '连续失败任务', value: overview.consecutive_failure_jobs, icon: AlertTriangle, danger: overview.consecutive_failure_jobs > 0 },
  ]
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
      {cards.map((c) => (
        <MetricCard key={c.label} {...c} />
      ))}
    </div>
  )
}

function ScenarioPanel({
  overview,
  capabilityReport,
  capabilityLoading,
}: {
  overview: PlatformCronOverviewDTO
  capabilityReport: CronDryRunReport | null
  capabilityLoading: boolean
}) {
  const conflicts = capabilityReport?.conflicts ?? []
  const failureReasons = overview.top_failure_reasons ?? []
  const failureTenants = overview.top_failure_tenants ?? []
  const conflictCount = conflicts.length
  const healthOk = overview.runs_24h_failed === 0 && overview.consecutive_failure_jobs === 0
  const failureHasPattern = failureReasons.length > 0 || failureTenants.length > 0
  const riskCount = overview.consecutive_failure_jobs + (capabilityLoading ? 0 : conflictCount)

  return (
    <Panel className="px-4 py-4">
      <div className="mb-3">
        <div className="text-[16px] font-semibold text-[var(--color-text)]">运营判断</div>
        <div className="mt-0.5 text-[12px] text-[var(--color-text-mute)]">
          从平台值班、租户排障和任务治理三个场景组织统计维度。
        </div>
      </div>
      <div className="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <ScenarioCard
          title="平台调度是否健康"
          status={healthOk ? '正常' : '需关注'}
          tone={healthOk ? 'success' : 'danger'}
          description={healthOk ? '近 24 小时无失败和连续失败任务。' : `近 24 小时失败 ${overview.runs_24h_failed} 次，连续失败任务 ${overview.consecutive_failure_jobs} 个。`}
        />
        <ScenarioCard
          title="失败集中在哪里"
          status={failureHasPattern ? '有集中点' : '暂无集中失败'}
          tone={failureHasPattern ? 'danger' : 'success'}
          description={failureHasPattern ? '优先查看失败原因 Top 和失败租户 Top，判断是单租户问题还是运行环境问题。' : '近 24 小时没有可聚合的失败租户或失败原因。'}
        />
        <ScenarioCard
          title="哪些风险要先处理"
          status={capabilityLoading ? '检查中' : riskCount > 0 ? `${riskCount} 项风险` : '暂无风险'}
          tone={riskCount > 0 ? 'danger' : 'success'}
          description={capabilityLoading ? '正在检查连续失败与数字员工运行能力冲突。' : riskCount > 0 ? '先处理连续失败任务和能力冲突，避免重复调度失败。' : '当前没有连续失败任务，能力闸口也未发现冲突。'}
          href="/cron-jobs"
        />
      </div>
    </Panel>
  )
}

function ScenarioCard({
  title,
  status,
  description,
  tone,
  href,
}: {
  title: string
  status: string
  description: string
  tone: 'success' | 'danger'
  href?: string
}) {
  const toneClass = tone === 'danger' ? 'text-[var(--color-danger)] bg-[var(--color-danger-bg)]' : 'text-[var(--color-success)] bg-[var(--color-success-bg)]'
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-3 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[13px] font-semibold text-[var(--color-text)]">{title}</div>
          <div className="mt-2 text-[12.5px] leading-5 text-[var(--color-text-sub)]">{description}</div>
        </div>
        <span className={`shrink-0 rounded-md px-2 py-1 text-[12px] font-medium ${toneClass}`}>{status}</span>
      </div>
      {href && (
        <a className="mt-3 inline-flex items-center gap-1 text-[12px] font-medium text-[var(--color-brand)]" href={href}>
          查看任务列表
          <ArrowUpRight size={13} />
        </a>
      )}
    </div>
  )
}

function TimePill({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <span className="inline-flex h-8 items-center gap-1.5 rounded-md border border-[var(--color-line)] bg-white px-3 text-[12px] text-[var(--color-text-sub)] shadow-sm">
      <span className="text-[var(--color-text-mute)]">{icon}</span>
      {label}：<span className="font-medium tabular-nums text-[var(--color-text)]">{value}</span>
    </span>
  )
}

function MetricCard({
  label,
  value,
  icon: Icon,
  danger,
  success,
}: {
  label: string
  value: ReactNode
  icon: ComponentType<{ size?: number; className?: string }>
  danger?: boolean
  success?: boolean
}) {
  const tone = danger
    ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
    : success
      ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
      : 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-4 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate text-[12px] text-[var(--color-text-mute)]">{label}</div>
          <div className={`mt-1 text-[24px] font-semibold tabular-nums ${danger ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]'}`}>
            {value}
          </div>
        </div>
        <div className={`grid h-10 w-10 shrink-0 place-items-center rounded-lg ${tone}`}>
          <Icon size={20} />
        </div>
      </div>
    </div>
  )
}

function FailureStats({ overview }: { overview: PlatformCronOverviewDTO }) {
  const failureReasons = overview.top_failure_reasons ?? []
  const failureTenants = overview.top_failure_tenants ?? []
  const consecutiveFailures = overview.top_consecutive_failures ?? []
  const hasAny =
    failureReasons.length > 0 ||
    failureTenants.length > 0 ||
    consecutiveFailures.length > 0
  if (!hasAny) {
    return (
      <Panel className="px-4 py-4">
        <div className="text-[16px] font-semibold text-[var(--color-text)]">失败排行</div>
        <div className="mt-3 rounded-lg border border-[var(--color-line)] bg-white px-4 py-6 text-center text-[13px] text-[var(--color-text-mute)]">
          近 24 小时暂无失败排行数据。
        </div>
      </Panel>
    )
  }
  return (
    <Panel className="px-4 py-4">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <div className="text-[16px] font-semibold text-[var(--color-text)]">失败排行</div>
          <div className="mt-0.5 text-[12px] text-[var(--color-text-mute)]">按近 24 小时失败记录与当前连续失败任务聚合。</div>
        </div>
      </div>
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <FailureColumn title="失败原因 Top（近 24h）">
          {failureReasons.map((r, i) => (
            <StatRow key={i} label={r.reason} count={r.count} />
          ))}
        </FailureColumn>
        <FailureColumn title="失败租户 Top（近 24h）">
          {failureTenants.map((t, i) => (
            <StatRow key={i} label={t.tenant_name || `租户 #${t.tenant_id}`} count={t.count} />
          ))}
        </FailureColumn>
        <FailureColumn title="连续失败 Top">
          {consecutiveFailures.map((c, i) => (
            <StatRow
              key={i}
              label={`${c.name} · ${c.tenant_name || `租户 #${c.tenant_id}`}`}
              count={c.consecutive_failures}
              countSuffix=" 次"
            />
          ))}
        </FailureColumn>
      </div>
    </Panel>
  )
}

function FailureColumn({ title, children }: { title: string; children: ReactNode }) {
  const items = Array.isArray(children) ? children : [children]
  return (
    <div className="min-w-0 rounded-lg border border-[var(--color-line)] bg-white px-4 py-3 shadow-sm">
      <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">{title}</div>
      {items.filter(Boolean).length === 0 ? (
        <div className="text-[12.5px] text-[var(--color-text-mute)]">近 24h 无数据</div>
      ) : (
        <div className="space-y-2">{children}</div>
      )}
    </div>
  )
}

function StatRow({ label, count, countSuffix }: { label: string; count: number; countSuffix?: string }) {
  return (
    <div className="flex min-w-0 items-center justify-between gap-3 text-[13px]">
      <span className="min-w-0 truncate text-[var(--color-text-sub)]" title={label}>{label}</span>
      <span className="shrink-0 tabular-nums font-medium text-[var(--color-danger)]">
        {count}
        {countSuffix ?? ''}
      </span>
    </div>
  )
}

function CapabilityPanel({
  report,
  loading,
  error,
}: {
  report: CronDryRunReport | null
  loading: boolean
  error: string
}) {
  const conflicts = report?.conflicts ?? []
  return (
    <Panel className="px-4 py-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="flex items-center gap-2 text-[16px] font-semibold text-[var(--color-text)]">
            {conflicts.length > 0 ? <ShieldAlert size={17} className="text-[var(--color-danger)]" /> : <ShieldCheck size={17} className="text-[var(--color-success)]" />}
            能力冲突
          </div>
          <div className="mt-0.5 text-[12px] text-[var(--color-text-mute)]">
            检查已启用任务绑定的数字员工是否满足当前运行环境要求。
          </div>
        </div>
        <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-sub)]">
          <span className="rounded-md bg-[var(--color-bg-sub)] px-2 py-1 tabular-nums">已启用 {report?.total_enabled ?? '-'}</span>
          <span className={`rounded-md px-2 py-1 tabular-nums ${conflicts.length > 0 ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]' : 'bg-[var(--color-success-bg)] text-[var(--color-success)]'}`}>
            冲突 {loading ? '-' : conflicts.length}
          </span>
        </div>
      </div>

      {error ? (
        <InlineAlert tone="danger">{error}</InlineAlert>
      ) : loading ? (
        <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-6 text-center text-[13px] text-[var(--color-text-mute)]">能力冲突检查中...</div>
      ) : conflicts.length === 0 ? (
        <div className="flex items-center gap-2 rounded-lg border border-[var(--color-line)] bg-white px-4 py-3 text-[13px] text-[var(--color-text-sub)]">
          <ShieldCheck size={16} className="text-[var(--color-success)]" />
          所有已启用定时任务均满足运行要求。
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border border-[var(--color-line)] bg-white">
          <table className="w-full text-[13px]">
            <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] text-left font-semibold text-[var(--color-text)]">
              <tr>
                <th className="px-3 py-2.5">任务</th>
                <th className="px-3 py-2.5">数字员工 UUID</th>
                <th className="px-3 py-2.5">租户 ID</th>
                <th className="px-3 py-2.5">账号 ID</th>
                <th className="px-3 py-2.5">原因</th>
                <th className="px-3 py-2.5">下次运行</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[var(--color-line-soft)]">
              {conflicts.slice(0, 6).map((row) => (
                <CapabilityRow key={row.job_uuid} row={row} />
              ))}
            </tbody>
          </table>
          {conflicts.length > 6 && (
            <div className="border-t border-[var(--color-line-soft)] px-3 py-2 text-[12px] text-[var(--color-text-mute)]">
              仅展示前 6 条冲突，请结合租户 ID 进入对应租户任务页处理。
            </div>
          )}
        </div>
      )}
    </Panel>
  )
}

function CapabilityRow({ row }: { row: CronDryRunConflict }) {
  return (
    <tr>
      <td className="min-w-[180px] px-3 py-2.5">
        <div className="max-w-[240px] truncate font-medium text-[var(--color-text)]" title={row.name}>{row.name}</div>
        <div className="max-w-[240px] truncate font-mono text-[11px] text-[var(--color-text-mute)]" title={row.job_uuid}>{row.job_uuid}</div>
      </td>
      <td className="whitespace-nowrap px-3 py-2.5 font-mono text-[12px] text-[var(--color-text-sub)]">{row.agent_uuid}</td>
      <td className="whitespace-nowrap px-3 py-2.5"><TenantId value={row.tenant_id} /></td>
      <td className="whitespace-nowrap px-3 py-2.5 font-mono text-[12px] text-[var(--color-text-sub)]">{row.account_id}</td>
      <td className="min-w-[220px] px-3 py-2.5 text-[12.5px] text-[var(--color-danger)]">
        <span className="line-clamp-2" title={row.reason}>{row.reason}</span>
      </td>
      <td className="whitespace-nowrap px-3 py-2.5 text-[var(--color-text-sub)]">{formatDateTime(row.next_run_at)}</td>
    </tr>
  )
}

function TenantId({ value }: { value: number }) {
  return (
    <span className="inline-flex h-6 items-center rounded-md bg-[var(--color-bg-sub)] px-2 font-mono text-[12px] tabular-nums text-[var(--color-text-sub)] ring-1 ring-[var(--color-line-soft)]">
      {value}
    </span>
  )
}
