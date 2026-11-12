import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useOutletContext } from 'react-router-dom'
import {
  Activity,
  AlertTriangle,
  CheckCircle2,
  Clock3,
  Eye,
  Filter,
  RefreshCw,
  RotateCcw,
  Search,
  ShieldCheck,
} from 'lucide-react'

import { AuditCenter, type AuditDLQItem, type AuditEvent, type AuditListParams, type AuditSummary } from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  Panel,
  Select,
  Tabs,
  Toolbar,
} from '../components/ui'

type AuditTab = 'operation' | 'system' | 'dlq'
type AuditEventCategory = 'operation' | 'system'

type EventFilters = {
  tenantId: string
  accountId: string
  actorKind: string
  domain: string
  eventKind: string
  severity: string
  traceId: string
  q: string
  from: string
  to: string
}

type DLQFilters = {
  topic: string
  q: string
}

const DEFAULT_EVENT_FILTERS: EventFilters = {
  tenantId: '',
  accountId: '',
  actorKind: '',
  domain: '',
  eventKind: '',
  severity: '',
  traceId: '',
  q: '',
  from: '',
  to: '',
}

const DEFAULT_DLQ_FILTERS: DLQFilters = {
  topic: '',
  q: '',
}

const ACTOR_KIND_OPTIONS = [
  ['', '全部操作人'],
  ['user', '用户'],
  ['admin', '管理员'],
  ['platform_admin', '平台管理员'],
  ['agent', '数字员工'],
  ['system', '系统'],
]

const DOMAIN_OPTIONS = [
  ['', '全部类型'],
  ['auth', '登录与身份'],
  ['tenant', '租户管理'],
  ['member', '成员权限'],
  ['agent', '数字员工'],
  ['kb', '知识库'],
  ['room', '群聊'],
  ['cron', '定时任务'],
  ['audit', '审计运维'],
  ['runtime', '运行时'],
]

const RESULT_OPTIONS = [
  ['', '全部结果'],
  ['info', '成功 / 信息'],
  ['warning', '需关注'],
  ['error', '失败'],
  ['critical', '严重'],
]

const EVENT_FEATURE_LABELS: Record<string, string> = {
  'audit.auth.login.success': '后台登录',
  'audit.auth.login.failed': '后台登录',
  'audit.auth.logout': '后台登录',
  'audit.auth.scope.switch': '管理范围切换',
  'audit.auth.scope_switch': '管理范围切换',
  'audit.auth.impersonate': '租户代入',
  'audit.tenant.created': '租户生命周期',
  'audit.tenant.updated': '租户生命周期',
  'audit.tenant.suspended': '租户生命周期',
  'audit.member.invited': '成员管理',
  'audit.member.updated': '成员管理',
  'audit.role.assigned': '角色权限',
  'audit.agent.created': '数字员工管理',
  'audit.agent.updated': '数字员工管理',
  'audit.kb.created': '知识库管理',
  'audit.kb.updated': '知识库管理',
  'audit.room.created': '群聊管理',
  'audit.cron.run_started': '定时任务调度',
  'audit.cron.run_finished': '定时任务调度',
  'audit.cron.run_failed': '定时任务调度',
  'audit.cron.catchup_last_merged': '补偿调度',
  'audit.cron.openclaw_run_finished': '运行时调度回写',
  'audit.cron.job_created': '定时任务配置',
  'audit.cron.job_updated': '定时任务配置',
  'audit.cron.job_deleted': '定时任务配置',
  'audit.cron.force_disabled': '定时任务配置',
  'audit.cron.admin_flag_cleared': '定时任务配置',
  'audit.cron.job_disabled_due_to_failures': '定时任务保护',
  'audit.outbox.retry': '审计写入异常处理',
  'audit.outbox.ignore': '审计写入异常处理',
}

const EVENT_ACTION_LABELS: Record<string, string> = {
  'audit.auth.login.success': '登录成功',
  'audit.auth.login.failed': '登录失败',
  'audit.auth.logout': '退出登录',
  'audit.auth.scope.switch': '切换管理范围',
  'audit.auth.scope_switch': '切换管理范围',
  'audit.auth.impersonate': '进入租户视图',
  'audit.tenant.created': '创建租户',
  'audit.tenant.updated': '更新租户',
  'audit.tenant.suspended': '暂停租户',
  'audit.member.invited': '邀请成员',
  'audit.member.updated': '更新成员',
  'audit.role.assigned': '分配角色',
  'audit.agent.created': '创建数字员工',
  'audit.agent.updated': '更新数字员工',
  'audit.kb.created': '创建知识库',
  'audit.kb.updated': '更新知识库',
  'audit.room.created': '创建群聊',
  'audit.cron.run_started': '开始执行',
  'audit.cron.run_finished': '执行完成',
  'audit.cron.run_failed': '执行失败',
  'audit.cron.catchup_last_merged': '合并完成',
  'audit.cron.openclaw_run_finished': '回写完成',
  'audit.cron.job_created': '创建定时任务',
  'audit.cron.job_updated': '更新定时任务',
  'audit.cron.job_deleted': '删除定时任务',
  'audit.cron.force_disabled': '强制暂停',
  'audit.cron.admin_flag_cleared': '解除强制暂停',
  'audit.cron.job_disabled_due_to_failures': '自动暂停',
  'audit.outbox.retry': '重新写入',
  'audit.outbox.ignore': '标记已处理',
}

const DOMAIN_LABELS: Record<string, string> = {
  auth: '登录与身份',
  tenant: '租户管理',
  member: '成员权限',
  role: '角色权限',
  agent: '数字员工',
  kb: '知识库',
  room: '群聊',
  cron: '定时任务',
  audit: '审计运维',
  runtime: '运行时',
}

const RESOURCE_LABELS: Record<string, string> = {
  agent_cron_run: '定时任务执行',
  agent_cron_job: '定时任务',
  events_outbox: '审计写入事件',
  tenant: '租户',
  account: '账号',
  role: '角色',
  digital_employee: '数字员工',
  knowledge_base: '知识库',
  room: '群聊',
}

const RESOURCE_FEATURE_LABELS: Record<string, string> = {
  agent_cron_run: '定时任务调度',
  agent_cron_job: '定时任务配置',
  events_outbox: '审计写入异常处理',
  tenant: '租户生命周期',
  account: '账号管理',
  role: '角色权限',
  digital_employee: '数字员工管理',
  knowledge_base: '知识库管理',
  room: '群聊管理',
}

export function AuditPage() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isPlatform = actScope?.kind === 'platform'
  const isTenant = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const [tab, setTab] = useState<AuditTab>('operation')
  const [refreshKey, setRefreshKey] = useState(0)
  const effectiveTab: AuditTab = isPlatform ? tab : (tab === 'dlq' ? 'operation' : tab)
  const refresh = () => setRefreshKey((v) => v + 1)

  if (switchingScope || !actScope) return null
  if (!isPlatform && !isTenant) {
    return (
      <div>
        <PageHeader title="操作审计" subtitle="请切换到平台或租户视图后再查看审计日志。" />
        <InlineAlert>请先在左上角切换到平台或租户视图。</InlineAlert>
      </div>
    )
  }

  return (
    <div>
      <PageHeader
        title="操作审计"
        subtitle={isPlatform
          ? '默认展示人发起或有业务影响的操作留痕；系统事件和写入异常按页签分开查看。'
          : '默认展示当前租户的人为操作留痕；系统自动执行记录按页签分开查看。'}
      />

      <AuditSummaryStrip isPlatform={isPlatform} refreshKey={refreshKey} />

      <div className="mb-4">
        <Tabs<AuditTab>
          value={effectiveTab}
          onChange={setTab}
          items={[
            { value: 'operation', label: '操作审计' },
            { value: 'system', label: '系统事件' },
            ...(isPlatform ? [{ value: 'dlq' as const, label: '写入异常' }] : []),
          ]}
        />
      </div>

      {effectiveTab === 'operation' || effectiveTab === 'system' ? (
        <AuditEventsPane key={effectiveTab} category={effectiveTab} isPlatform={isPlatform} refreshKey={refreshKey} onRefresh={refresh} />
      ) : (
        <AuditDLQPane refreshKey={refreshKey} onRefresh={refresh} />
      )}
    </div>
  )
}

function AuditSummaryStrip({ isPlatform, refreshKey }: { isPlatform: boolean; refreshKey: number }) {
  const [summary, setSummary] = useState<AuditSummary | null>(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    let cancelled = false
    const req = isPlatform ? AuditCenter.getPlatformSummary() : AuditCenter.getTenantSummary()
    req
      .then((r) => {
        if (cancelled) return
        setSummary(r)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
    return () => { cancelled = true }
  }, [isPlatform, refreshKey])

  if (err) {
    return <div className="mb-4"><InlineAlert>{err}</InlineAlert></div>
  }

  return (
    <div className="mb-4 grid gap-3 md:grid-cols-3 xl:grid-cols-4">
      <MetricCard
        icon={<Activity size={17} />}
        label="今日事件"
        value={summary ? String(summary.todayTotal) : '...'}
        hint="今天写入审计事实表的记录"
      />
      <MetricCard
        icon={<AlertTriangle size={17} />}
        label="失败/高危"
        value={summary ? String(summary.riskTotal) : '...'}
        hint="今天 warning、error、critical 等级事件"
        tone={summary && summary.riskTotal > 0 ? 'warn' : 'success'}
      />
      {isPlatform && (
        <MetricCard
          icon={<ShieldCheck size={17} />}
          label="写入异常"
          value={summary ? String(summary.dlqTotal) : '...'}
          hint={summary ? `待写入 ${summary.pendingTotal} / 失败 ${summary.failedTotal}` : '审计写入死信数量'}
          tone={summary && summary.dlqTotal > 0 ? 'danger' : 'success'}
        />
      )}
      <MetricCard
        icon={<Clock3 size={17} />}
        label="最近写入"
        value={summary?.lastAuditAt ? relativeTime(summary.lastAuditAt) : '暂无'}
        hint={summary?.lastAuditAt ? formatTime(summary.lastAuditAt) : '当前范围还没有审计记录'}
      />
    </div>
  )
}

function AuditEventsPane({
  category,
  isPlatform,
  refreshKey,
  onRefresh,
}: {
  category: AuditEventCategory
  isPlatform: boolean
  refreshKey: number
  onRefresh: () => void
}) {
  const [filters, setFilters] = useState<EventFilters>(DEFAULT_EVENT_FILTERS)
  const [items, setItems] = useState<AuditEvent[]>([])
  const [selected, setSelected] = useState<AuditEvent | null>(null)
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)

  const params = useMemo(() => eventParams(filters, category, pageSize, (page - 1) * pageSize, isPlatform), [filters, category, page, pageSize, isPlatform])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 切换筛选/分页时立即反馈加载态
    setLoading(true)
    const req = isPlatform ? AuditCenter.listPlatformEvents(params) : AuditCenter.listTenantEvents(params)
    req
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [params, isPlatform, refreshKey])

  const patchFilter = (patch: Partial<EventFilters>) => {
    setFilters((prev) => ({ ...prev, ...patch }))
    setPage(1)
  }

  const resetFilters = () => {
    setFilters(DEFAULT_EVENT_FILTERS)
    setPage(1)
  }

  const headers = isPlatform
    ? ['时间', '业务模块', '功能', '业务对象', '执行对象', '操作', '操作人', '账号 ID', '资源类型', '资源 ID', '租户', '租户 ID', '结果', '来源', 'Trace', '查看']
    : ['时间', '业务模块', '功能', '业务对象', '执行对象', '操作', '操作人', '账号 ID', '资源类型', '资源 ID', '结果', '来源', 'Trace', '查看']
  const colSpan = headers.length

  return (
    <>
      <Toolbar
        search={(
          <div className="relative">
            <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
            <Input
              value={filters.q}
              onChange={(e) => patchFilter({ q: e.target.value })}
              placeholder="搜索操作、对象、操作人"
              className="pl-9"
            />
          </div>
        )}
        filters={(
          <>
            {isPlatform && (
              <div className="w-[132px]">
                <Input
                  type="number"
                  min="1"
                  value={filters.tenantId}
                  onChange={(e) => patchFilter({ tenantId: e.target.value })}
                  placeholder="租户 ID"
                />
              </div>
            )}
            <div className="w-[146px]">
              <Select value={filters.domain} onChange={(e) => patchFilter({ domain: e.target.value })}>
                {DOMAIN_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
            <div className="w-[142px]">
              <Select value={filters.actorKind} onChange={(e) => patchFilter({ actorKind: e.target.value })}>
                {ACTOR_KIND_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
            <div className="w-[136px]">
              <Select value={filters.severity} onChange={(e) => patchFilter({ severity: e.target.value })}>
                {RESULT_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
          </>
        )}
        summary={<>共 <b className="text-[var(--color-text)] tabular-nums">{total}</b> 条</>}
        actions={(
          <>
            <Button variant="ghost" onClick={() => setAdvancedOpen((v) => !v)}>
              <Filter size={14} /> 高级筛选
            </Button>
            <Button variant="secondary" onClick={onRefresh} disabled={loading}>
              <RefreshCw size={14} /> 刷新
            </Button>
          </>
        )}
      />

      <div className="mb-3 grid gap-3 lg:grid-cols-[190px_190px_1fr]">
        <FormField label="开始时间">
          <Input type="datetime-local" value={filters.from} onChange={(e) => patchFilter({ from: e.target.value })} />
        </FormField>
        <FormField label="结束时间">
          <Input type="datetime-local" value={filters.to} onChange={(e) => patchFilter({ to: e.target.value })} />
        </FormField>
        <div className="flex items-end justify-end gap-2">
          <Button variant="ghost" onClick={resetFilters}>清空筛选</Button>
        </div>
      </div>

      {advancedOpen && (
        <Panel className="mb-3 p-4">
          <div className="grid gap-3 lg:grid-cols-[150px_220px_1fr]">
            <FormField label="账号 ID">
              <Input type="number" min="1" value={filters.accountId} onChange={(e) => patchFilter({ accountId: e.target.value })} placeholder="精确账号 ID" />
            </FormField>
            <FormField label="原始事件名">
              <Input value={filters.eventKind} onChange={(e) => patchFilter({ eventKind: e.target.value })} placeholder="如 audit.auth.login.success" />
            </FormField>
            <FormField label="Trace ID">
              <Input value={filters.traceId} onChange={(e) => patchFilter({ traceId: e.target.value })} placeholder="按 trace 精确查询" />
            </FormField>
          </div>
        </Panel>
      )}

      {err && <div className="mb-3"><InlineAlert>{err}</InlineAlert></div>}

      <div className="overflow-x-auto">
        <DataTable
          headers={headers}
          className={isPlatform ? 'min-w-[2040px]' : 'min-w-[1800px]'}
          empty={!loading && !items.length ? (
            <EmptyState
              icon={<ShieldCheck size={24} />}
              title={category === 'operation' ? '暂无操作审计' : '暂无系统事件'}
              description={category === 'operation' ? '当前筛选条件下没有人为操作或业务影响类审计记录。' : '当前筛选条件下没有系统自动执行记录。'}
            />
          ) : null}
        >
          {loading && <tr><td colSpan={colSpan} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</td></tr>}
          {!loading && items.map((item) => (
            <tr key={item.id} className="hover:bg-[var(--color-bg-sub)]">
              <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{formatTime(item.occurredAt)}</td>
              <td className="px-4 py-3 max-w-[130px] truncate whitespace-nowrap text-[12px] text-[var(--color-text-sub)]" title={businessModuleText(item)}>{businessModuleText(item)}</td>
              <td className="px-4 py-3 max-w-[170px] truncate whitespace-nowrap font-medium text-[var(--color-text)]" title={featureText(item)}>{featureText(item)}</td>
              <td className="px-4 py-3 max-w-[180px] truncate whitespace-nowrap font-medium text-[var(--color-text)]" title={businessObjectText(item)}>{businessObjectText(item)}</td>
              <td className="px-4 py-3 max-w-[150px] truncate whitespace-nowrap text-[12px] text-[var(--color-text-sub)]" title={executorText(item)}>{executorText(item)}</td>
              <td className="px-4 py-3 max-w-[160px] truncate whitespace-nowrap font-medium text-[var(--color-text)]" title={item.eventKind}>{actionText(item)}</td>
              <td className="px-4 py-3 max-w-[160px] truncate whitespace-nowrap font-medium text-[var(--color-text)]" title={actorName(item)}>{actorName(item)}</td>
              <td className="px-4 py-3 whitespace-nowrap tabular-nums text-[12px] text-[var(--color-text-sub)]">{accountIdText(item)}</td>
              <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{resourceKindText(item)}</td>
              <td className="px-4 py-3 max-w-[180px] truncate whitespace-nowrap font-mono text-[12px] text-[var(--color-text-mute)]" title={item.resourceUuid || ''}>{resourceIdText(item)}</td>
              {isPlatform && <td className="px-4 py-3 max-w-[160px] truncate whitespace-nowrap" title={tenantNameText(item)}>{tenantNameText(item)}</td>}
              {isPlatform && <td className="px-4 py-3 whitespace-nowrap tabular-nums text-[12px] text-[var(--color-text-sub)]">{tenantIdText(item)}</td>}
              <td className="px-4 py-3 whitespace-nowrap"><ResultBadge value={item.severity} /></td>
              <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{sourceText(item)}</td>
              <td className="px-4 py-3 max-w-[180px] truncate whitespace-nowrap font-mono text-[12px] text-[var(--color-text-mute)]" title={item.traceId || ''}>{item.traceId || '—'}</td>
              <td className="sticky right-0 bg-white px-4 py-3">
                <Button variant="ghost" size="sm" onClick={() => setSelected(item)} title="查看详情" aria-label="查看详情">
                  <Eye size={14} />
                </Button>
              </td>
            </tr>
          ))}
        </DataTable>
      </div>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {selected && <AuditEventDrawer item={selected} onClose={() => setSelected(null)} />}
    </>
  )
}

function AuditDLQPane({ refreshKey, onRefresh }: { refreshKey: number; onRefresh: () => void }) {
  const [filters, setFilters] = useState<DLQFilters>(DEFAULT_DLQ_FILTERS)
  const [items, setItems] = useState<AuditDLQItem[]>([])
  const [selected, setSelected] = useState<AuditDLQItem | null>(null)
  const [confirming, setConfirming] = useState<{ item: AuditDLQItem; action: 'retry' | 'ignore' } | null>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)

  const params = useMemo(() => ({
    topic: filters.topic || undefined,
    q: filters.q || undefined,
    limit: pageSize,
    offset: (page - 1) * pageSize,
  }), [filters, page, pageSize])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 切换筛选/分页时立即反馈加载态
    setLoading(true)
    AuditCenter.listDLQ(params)
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [params, refreshKey])

  const patchFilter = (patch: Partial<DLQFilters>) => {
    setFilters((prev) => ({ ...prev, ...patch }))
    setPage(1)
  }

  return (
    <>
      <div className="mb-3">
        <InlineAlert tone="warn">
          写入异常表示审计记录没有成功落入审计事实表，不代表业务动作本身一定失败。重新写入会回到待消费队列；标记已处理不会补写事实表。
        </InlineAlert>
      </div>

      <Toolbar
        search={(
          <div className="relative">
            <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
            <Input
              value={filters.q}
              onChange={(e) => patchFilter({ q: e.target.value })}
              placeholder="搜索 topic、错误、payload"
              className="pl-9"
            />
          </div>
        )}
        filters={<div className="w-[220px]"><Input value={filters.topic} onChange={(e) => patchFilter({ topic: e.target.value })} placeholder="topic 精确匹配" /></div>}
        summary={<>共 <b className="text-[var(--color-text)] tabular-nums">{total}</b> 条写入异常</>}
        actions={<Button variant="secondary" onClick={onRefresh} disabled={loading}><RefreshCw size={14} /> 刷新</Button>}
      />

      {err && <div className="mb-3"><InlineAlert>{err}</InlineAlert></div>}

      <DataTable
        headers={['进入时间', 'Topic', '范围', '租户 ID', '尝试次数', '失败原因', '建议处理', '操作']}
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<CheckCircle2 size={24} />}
            title="暂无写入异常"
            description="审计写入队列当前没有需要处理的死信。"
            tone="success"
          />
        ) : null}
      >
        {loading && <tr><td colSpan={8} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</td></tr>}
        {!loading && items.map((item) => (
          <tr key={item.id} className="hover:bg-[var(--color-bg-sub)]">
            <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{formatTime(item.dlqAt || item.doneAt || item.createdAt)}</td>
            <td className="px-4 py-3 whitespace-nowrap font-mono text-[12px]">{item.topic}</td>
            <td className="px-4 py-3 whitespace-nowrap">{item.tenantId ? '租户' : '平台'}</td>
            <td className="px-4 py-3 whitespace-nowrap tabular-nums text-[12px] text-[var(--color-text-sub)]">{item.tenantId ?? '—'}</td>
            <td className="px-4 py-3 whitespace-nowrap tabular-nums">{item.attempts}</td>
            <td className="px-4 py-3 max-w-[420px] truncate text-[12px] text-[var(--color-danger)]" title={item.lastError || ''}>
              {item.lastError || '—'}
            </td>
            <td className="px-4 py-3 whitespace-nowrap text-[12px] text-[var(--color-text-sub)]">{dlqAdvice(item)}</td>
            <td className="sticky right-0 bg-white px-4 py-3">
              <div className="flex items-center gap-1">
                <Button variant="ghost" size="sm" onClick={() => setSelected(item)} title="查看详情" aria-label="查看详情"><Eye size={14} /></Button>
                <Button variant="secondary" size="sm" onClick={() => setConfirming({ item, action: 'retry' })}><RotateCcw size={14} /> 重新写入</Button>
                <Button variant="ghost" size="sm" onClick={() => setConfirming({ item, action: 'ignore' })}>标记已处理</Button>
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
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {selected && <AuditDLQDrawer item={selected} onClose={() => setSelected(null)} />}
      {confirming && (
        <ConfirmDialog
          title={confirming.action === 'retry' ? '重新写入审计记录' : '标记异常已处理'}
          description={confirming.action === 'retry'
            ? `确认将编号 ${confirming.item.id} 重置为待消费？审计写入进程会重新处理该事件。`
            : `确认将编号 ${confirming.item.id} 标记为已处理？该事件不会补写到审计事实表。`}
          tone={confirming.action === 'retry' ? 'info' : 'warn'}
          confirmLabel={confirming.action === 'retry' ? '重新写入' : '标记已处理'}
          onClose={() => setConfirming(null)}
          onConfirm={async () => {
            if (confirming.action === 'retry') await AuditCenter.retryDLQ(confirming.item.id)
            else await AuditCenter.ignoreDLQ(confirming.item.id)
            setConfirming(null)
            onRefresh()
          }}
        />
      )}
    </>
  )
}

function AuditEventDrawer({ item, onClose }: { item: AuditEvent; onClose: () => void }) {
  return (
    <DrawerShell title="审计详情" subtitle={auditSentence(item)} onClose={onClose} width="lg">
      <DetailSection title="审计摘要" rows={[
        ['时间', formatTime(item.occurredAt)],
        ['业务模块', businessModuleText(item)],
        ['功能', featureText(item)],
        ['业务对象', businessObjectText(item)],
        ['执行对象', executorText(item)],
        ['操作', actionText(item)],
        ['操作人', actorName(item)],
        ['操作人类型', actorKindLabel(item.actorKind)],
        ['账号 ID', accountIdText(item)],
        ['结果', resultLabel(item.severity)],
        ['等级', item.severity],
      ]} />
      <DetailSection title="对象信息" rows={[
        ['租户', tenantNameText(item)],
        ['租户 ID', tenantIdText(item)],
        ['资源类型', resourceKindText(item)],
        ['资源 ID', resourceIdText(item)],
        ['目标账号 ID', item.targetAccountId ? String(item.targetAccountId) : '—'],
        ['目标资源 ID', item.targetResourceUuid || '—'],
      ]} />
      <DetailSection title="来源与链路" rows={[
        ['来源', sourceText(item)],
        ['来源 IP', item.ip || '—'],
        ['User-Agent', item.userAgent || '—'],
        ['Trace ID', item.traceId || '—'],
        ['耗时', `${item.durationMs} ms`],
        ['原始事件名', item.eventKind],
      ]} />
      <JSONBlock value={item.payload} />
    </DrawerShell>
  )
}

function AuditDLQDrawer({ item, onClose }: { item: AuditDLQItem; onClose: () => void }) {
  return (
    <DrawerShell title="写入异常详情" subtitle={item.topic} onClose={onClose} width="lg">
      <InlineAlert tone="warn">
        这里记录的是审计写入失败。处理前请确认 payload 格式是否已经修复，或该事件是否确实可以跳过。
      </InlineAlert>
      <div className="mt-4">
        <DetailSection title="异常摘要" rows={[
          ['Outbox ID', item.id],
          ['范围', item.tenantId ? '租户' : '平台'],
          ['租户 ID', item.tenantId ?? '—'],
          ['尝试次数', item.attempts],
          ['建议处理', dlqAdvice(item)],
          ['错误', item.lastError || '—'],
          ['DLQ 原因', item.dlqReason || '—'],
        ]} />
        <DetailSection title="链路信息" rows={[
          ['创建时间', formatTime(item.createdAt)],
          ['进入异常时间', item.dlqAt ? formatTime(item.dlqAt) : '—'],
          ['Trace ID', item.traceId || '—'],
          ['幂等键', item.idempotencyKey || '—'],
        ]} />
        <JSONBlock value={item.payload} />
      </div>
    </DrawerShell>
  )
}

function MetricCard({
  icon,
  label,
  value,
  hint,
  tone = 'neutral',
}: {
  icon: ReactNode
  label: string
  value: string
  hint: string
  tone?: 'neutral' | 'success' | 'warn' | 'danger'
}) {
  const toneClass = tone === 'danger'
    ? 'text-[var(--color-danger)] bg-[var(--color-danger-bg)]'
    : tone === 'warn'
      ? 'text-[var(--color-warn)] bg-[var(--color-warn-bg)]'
      : tone === 'success'
        ? 'text-[var(--color-success)] bg-[var(--color-success-bg)]'
        : 'text-[var(--color-brand)] bg-[var(--color-brand-soft)]'
  return (
    <Panel className="p-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
          <div className="mt-2 text-[24px] font-semibold tabular-nums text-[var(--color-text)]">{value}</div>
          <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]" title={hint}>{hint}</div>
        </div>
        <div className={`grid h-8 w-8 shrink-0 place-items-center rounded-md ${toneClass}`}>{icon}</div>
      </div>
    </Panel>
  )
}

function DetailSection({ title, rows }: { title: string; rows: Array<[string, unknown]> }) {
  return (
    <section className="mb-5">
      <div className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">{title}</div>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        {rows.map(([label, value]) => (
          <div key={label} className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2">
            <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
            <div className="mt-1 break-all text-[13px] text-[var(--color-text)]">{String(value)}</div>
          </div>
        ))}
      </div>
    </section>
  )
}

function JSONBlock({ value }: { value: unknown }) {
  return (
    <section>
      <div className="mb-2 text-[13px] font-semibold text-[var(--color-text)]">原始数据</div>
      <pre className="max-h-[420px] overflow-auto rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3 text-[12px] leading-relaxed text-[var(--color-text)]">
        {JSON.stringify(value ?? {}, null, 2)}
      </pre>
    </section>
  )
}

function eventParams(filters: EventFilters, category: AuditEventCategory, limit: number, offset: number, includeTenantID: boolean): AuditListParams {
  const out: AuditListParams = { category, limit, offset }
  if (includeTenantID && filters.tenantId) out.tenant_id = Number(filters.tenantId)
  if (filters.accountId) out.account_id = Number(filters.accountId)
  if (filters.actorKind) out.actor_kind = filters.actorKind
  if (filters.domain.trim()) out.domain = filters.domain.trim()
  if (filters.eventKind.trim()) out.event_kind = filters.eventKind.trim()
  if (filters.severity) out.severity = filters.severity
  if (filters.traceId.trim()) out.trace_id = filters.traceId.trim()
  if (filters.q.trim()) out.q = filters.q.trim()
  if (filters.from) out.occurred_from = new Date(filters.from).toISOString()
  if (filters.to) out.occurred_to = new Date(filters.to).toISOString()
  return out
}

function businessModuleText(item: AuditEvent) {
  return domainLabel(item.domain)
}

function featureText(item: AuditEvent) {
  if (EVENT_FEATURE_LABELS[item.eventKind]) return EVENT_FEATURE_LABELS[item.eventKind]
  if (item.resourceKind) return RESOURCE_FEATURE_LABELS[item.resourceKind] || resourceKindText(item)
  return domainLabel(item.domain)
}

function businessObjectText(item: AuditEvent) {
  if (item.businessObject) return item.businessObject
  const payloadName = payloadString(item.payload, ['job_name', 'cron_job_name', 'task_name', 'name'])
  if (payloadName) return payloadName
  if (item.resourceKind === 'agent_cron_job') return item.resourceUuid || '—'
  const jobUUID = payloadString(item.payload, ['job_uuid'])
  if (jobUUID) return jobUUID
  if (item.resourceUuid) return `${resourceKindText(item)} ${item.resourceUuid}`
  if (item.targetResourceUuid) return item.targetResourceUuid
  return '—'
}

function executorText(item: AuditEvent) {
  if (item.executorName) return item.executorName
  if (item.targetAccountName) return item.targetAccountName
  if (item.targetAccountId) return `账号 ${item.targetAccountId}`
  if (item.targetResourceUuid) return item.targetResourceUuid
  return payloadString(item.payload, ['agent_name', 'digital_employee_name']) || '—'
}

function actionText(item: AuditEvent) {
  if (EVENT_ACTION_LABELS[item.eventKind]) return EVENT_ACTION_LABELS[item.eventKind]
  const suffix = item.eventKind.split('.').filter(Boolean).at(-1)
  if (suffix === 'created') return '创建'
  if (suffix === 'updated') return '更新'
  if (suffix === 'deleted') return '删除'
  if (suffix === 'disabled') return '禁用'
  if (suffix === 'enabled') return '启用'
  if (suffix === 'invited') return '邀请'
  if (suffix === 'assigned') return '分配'
  if (suffix === 'success') return '成功'
  if (suffix === 'failed') return '失败'
  return `${domainLabel(item.domain)}操作`
}

function auditSentence(item: AuditEvent) {
  return `${actorName(item)}在 ${formatTime(item.occurredAt)} 对${businessModuleText(item)} / ${featureText(item)}执行${actionText(item)}，结果为${resultLabel(item.severity)}。`
}

function actorName(item: AuditEvent) {
  if (item.accountName) return item.accountName
  if (item.accountUsername) return item.accountUsername
  return actorKindLabel(item.actorKind)
}

function accountIdText(item: AuditEvent) {
  return item.accountId ? String(item.accountId) : '—'
}

function actorKindLabel(value: string) {
  const found = ACTOR_KIND_OPTIONS.find(([v]) => v === value)
  return found?.[1] || value || '未知'
}

function tenantNameText(item: AuditEvent) {
  if (!item.tenantId) return '平台'
  return item.tenantName || '租户'
}

function tenantIdText(item: AuditEvent) {
  return item.tenantId ? String(item.tenantId) : '—'
}

function resourceKindText(item: AuditEvent) {
  if (!item.resourceKind) return '—'
  return RESOURCE_LABELS[item.resourceKind] || item.resourceKind
}

function resourceIdText(item: AuditEvent) {
  return item.resourceUuid || '—'
}

function sourceText(item: AuditEvent) {
  if (item.ip) return item.ip
  if (item.actorKind === 'system' || item.domain === 'cron') return '系统任务'
  if (item.actorKind === 'agent') return '数字员工'
  if (item.actorKind === 'admin' || item.actorKind === 'platform_admin') return '管理后台'
  return '—'
}

function domainLabel(value: string) {
  return DOMAIN_LABELS[value] || value || '业务'
}

function resultLabel(value: string) {
  if (value === 'critical') return '严重'
  if (value === 'error') return '失败'
  if (value === 'warning') return '需关注'
  return '成功'
}

function payloadString(payload: unknown, keys: string[]) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return ''
  const record = payload as Record<string, unknown>
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.trim()) return value.trim()
    if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  }
  return ''
}

function ResultBadge({ value }: { value: string }) {
  const tone = value === 'critical' || value === 'error'
    ? 'border-[var(--color-danger)] bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
    : value === 'warning'
      ? 'border-[var(--color-warn)] bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
      : 'border-[var(--color-success)] bg-[var(--color-success-bg)] text-[var(--color-success)]'
  return <span className={`inline-flex rounded border px-2 py-0.5 text-[12px] ${tone}`}>{resultLabel(value)}</span>
}

function dlqAdvice(item: AuditDLQItem) {
  const text = `${item.lastError || ''} ${item.dlqReason || ''}`.toLowerCase()
  if (text.includes('actor_kind')) return '补齐操作人类型后重新写入'
  if (text.includes('json') || text.includes('payload')) return '修复 payload 后重新写入'
  if (item.attempts >= 5) return '确认原因后重新写入'
  return '可尝试重新写入'
}

function formatTime(value?: string) {
  if (!value) return '—'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString()
}

function relativeTime(value: string) {
  const t = new Date(value).getTime()
  if (Number.isNaN(t)) return value
  const diff = Date.now() - t
  if (diff < 60_000) return '刚刚'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`
  return `${Math.floor(diff / 86_400_000)} 天前`
}
