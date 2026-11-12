// F08 §5.1 / L · 租户后台「定时任务」列表 (/cron, tenant scope).
//
// 调用 admin tenant cron-jobs CRUD (read-only + force-disable / clear-admin-flag):
//   GET    /api/admin/v1/tenant/cron-jobs
//   GET    /api/admin/v1/tenant/cron-jobs/{uuid}       → 详情 + 净化运行记录 (F25 返修)
//   POST   /api/admin/v1/tenant/cron-jobs/{uuid}/force-disable
//   POST   /api/admin/v1/tenant/cron-jobs/{uuid}/clear-admin-flag
//
// 范围:
//   - 本租户全员工 cron metadata 概览 + 排查"为什么停了" (pause_reason 标签).
//   - 强停 / 清强停标 + 详情 drawer (展示原始关键字段; 不展示 payload/rendered_prompt
//     避免泄露; admin DTO 已 strip payload).
//   - 后端 list 当前**不分页 + 不带筛选参数**, 走客户端聚合 + 过滤; 200 上限.
//
// 不包含 (本期):
//   - 跨租户列表 (走 platform scope, 暂未做; 见 §5.1 platform 部分 / §8.2 #12).
//   - 离职 cron 移交 (R10 不做 transfer; admin 仅能 force-disable / 清强停标).

import { useEffect, useMemo, useState } from 'react'
import { ListChecks, Pause, ShieldAlert, RotateCcw } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'
import {
  CronJobsAdmin,
  type CronDeliveryKind,
  type CronJobAdminDTO,
  type CronJobStatus,
  type CronPauseReason,
  type CronRunAdminDTO,
} from '../lib/api'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  InlineAlert,
  PageHeader,
  RowActions,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'

// ---------- 文案映射 ----------

const STATUS_LABEL: Record<CronJobStatus, string> = {
  active: '运行中',
  paused: '已暂停',
  error: '失败暂停',
  archived: '已归档',
}

const PAUSE_REASON_LABEL: Record<CronPauseReason, string> = {
  admin_disabled: '管理员强停',
  owner_inactive: '所有者已离职/挂起',
  quota_exceeded: '触发配额超限',
  user_paused: '用户手动暂停',
}

const DELIVERY_KIND_LABEL: Record<CronDeliveryKind, string> = {
  direct: '单聊',
  group: '群聊',
}

const LAST_RUN_STATUS_LABEL: Record<string, string> = {
  succeeded: '成功',
  success: '成功',
  failed: '失败',
  running: '执行中',
  queued: '排队中',
  cancelled: '已取消',
  '': '-',
}

// 错误码 → 中文文案; 未识别透传后端 message.
function translateError(message: string): string {
  if (!message) return ''
  if (message.includes('cron.job_not_found')) return '任务不存在或不在本租户。'
  if (message.includes('cron.resume_blocked_by_admin')) return '任务被管理员强停，需先「清除强停标」再让所有者自行恢复。'
  if (message.includes('cron.delivery_conversation_not_found'))
    return '投递会话不存在；可能会话已删除或不在所有者可见范围。'
  if (message.includes('cron.agent_not_visible')) return '数字员工对所有者不再可见（被下线或权限变更）。'
  if (message.includes('cron.agent_not_found')) return '数字员工不存在或已被删除。'
  return message
}

function formatDateTime(raw?: string): string {
  if (!raw) return '-'
  const t = new Date(raw)
  if (isNaN(t.getTime())) return '-'
  return t.toLocaleString('zh-CN', { hour12: false })
}

// 5 字段 cron → 人话（与客户端 task_utils._humanizeCron 同款映射）。
// 不认识的形态返回 null，由调用方回退展示原表达式。
function humanizeCron(expr: string): string | null {
  const parts = expr.trim().split(/\s+/)
  if (parts.length !== 5) return null
  const [m, h, dom, mon, dow] = parts
  if (mon !== '*') return null
  const isAny = (s: string) => s === '*'

  if (m === '*' && isAny(h) && isAny(dom) && isAny(dow)) return '每分钟'
  const everyMin = /^\*\/(\d+)$/.exec(m)
  if (everyMin && isAny(h) && isAny(dom) && isAny(dow)) return `每 ${everyMin[1]} 分钟`
  if (m === '0' && h === '*' && isAny(dom) && isAny(dow)) return '每小时整点'
  const everyHour = /^\*\/(\d+)$/.exec(h)
  if (m === '0' && everyHour && isAny(dom) && isAny(dow)) return `每 ${everyHour[1]} 小时`

  const mn = Number(m)
  const hn = Number(h)
  if (!Number.isInteger(mn) || !Number.isInteger(hn)) return null
  if (mn < 0 || mn > 59 || hn < 0 || hn > 23) return null
  const hhmm = `${String(hn).padStart(2, '0')}:${String(mn).padStart(2, '0')}`

  if (isAny(dom) && isAny(dow)) return `每天 ${hhmm}`
  if (isAny(dom)) {
    if (dow === '1-5') return `工作日 ${hhmm}`
    if (dow === '0,6' || dow === '6,0') return `周末 ${hhmm}`
    const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
    const d = Number(dow)
    if (Number.isInteger(d) && d >= 0 && d <= 6) return `${names[d]} ${hhmm}`
    return null
  }
  if (isAny(dow)) {
    const d = Number(dom)
    if (Number.isInteger(d) && d >= 1 && d <= 31) return `每月 ${d} 日 ${hhmm}`
  }
  return null
}

// ---------- 主页面 ----------

export default function TenantCronJobsPage() {
  const [items, setItems] = useState<CronJobAdminDTO[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [keyword, setKeyword] = useState('')
  const [statusFilter, setStatusFilter] = useState<CronJobStatus | ''>('')
  const [pauseReasonFilter, setPauseReasonFilter] = useState<CronPauseReason | ''>('')
  const [deliveryFilter, setDeliveryFilter] = useState<CronDeliveryKind | ''>('')
  const [detail, setDetail] = useState<CronJobAdminDTO | null>(null)
  const { confirm, dialog: confirmDialog } = useConfirmDialog()
  // F25 返修：告警「去排查」深链 /cron?job=<uuid> 直接打开对应任务详情
  const [searchParams] = useSearchParams()
  const deepLinkJob = searchParams.get('job') ?? ''

  async function reload() {
    setLoading(true)
    try {
      const res = await CronJobsAdmin.list()
      setItems(res.items || [])
      setErr('')
    } catch (e: unknown) {
      setErr(translateError((e as Error).message || '加载失败'))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    let mounted = true
    CronJobsAdmin.list()
      .then((res) => {
        if (!mounted) return
        setItems(res.items || [])
        setErr('')
        if (deepLinkJob) {
          const hit = (res.items || []).find((j) => j.uuid === deepLinkJob)
          if (hit) setDetail(hit)
        }
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr(translateError((e as Error).message || '加载失败'))
      })
      .finally(() => {
        if (mounted) setLoading(false)
      })
    return () => {
      mounted = false
    }
  }, [deepLinkJob])

  // KPI: 本租户列表本地聚合 (后端无统计端点; 200 上限内可接受).
  const kpis = useMemo(() => {
    const counts = { total: items.length, active: 0, paused: 0, error: 0 }
    for (const j of items) {
      if (j.status === 'active') counts.active++
      else if (j.status === 'paused') counts.paused++
      else if (j.status === 'error') counts.error++
    }
    return counts
  }, [items])

  // 客户端过滤: 后端 list 不带任何筛选参数, 都在前端做.
  const filtered = useMemo(() => {
    const kw = keyword.trim().toLowerCase()
    return items.filter((j) => {
      if (statusFilter && j.status !== statusFilter) return false
      if (pauseReasonFilter && j.pause_reason !== pauseReasonFilter) return false
      if (deliveryFilter && j.delivery_kind !== deliveryFilter) return false
      if (kw) {
        const hay = `${j.name} ${j.uuid} ${j.agent_uuid} ${j.description ?? ''}`.toLowerCase()
        if (!hay.includes(kw)) return false
      }
      return true
    })
  }, [items, keyword, statusFilter, pauseReasonFilter, deliveryFilter])

  async function handleForceDisable(row: CronJobAdminDTO) {
    const ok = await confirm({
      title: '强停定时任务',
      description: (
        <span>
          强停 "<b>{row.name}</b>" 后任务将立即停止调度，所有者无法自行恢复，需管理员先「清除强停标」。
          <br />
          所有者：账号 {row.owner_account_id}；数字员工：{row.agent_uuid}
        </span>
      ),
      tone: 'danger',
      confirmLabel: '强停',
    })
    if (!ok) return
    try {
      await CronJobsAdmin.forceDisable(row.uuid)
      await reload()
    } catch (e: unknown) {
      setErr(translateError((e as Error).message || '强停失败'))
    }
  }

  async function handleClearAdminFlag(row: CronJobAdminDTO) {
    const ok = await confirm({
      title: '清除强停标',
      description: (
        <span>
          清除强停标后，任务**不**会自动恢复；需所有者自行进入客户端任务页点「恢复」。
          <br />
          任务："<b>{row.name}</b>"；所有者账号 {row.owner_account_id}。
        </span>
      ),
      tone: 'warn',
      confirmLabel: '清除强停标',
    })
    if (!ok) return
    try {
      await CronJobsAdmin.clearAdminFlag(row.uuid)
      await reload()
    } catch (e: unknown) {
      setErr(translateError((e as Error).message || '操作失败'))
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="定时任务"
        subtitle="管理本租户所有数字员工的定时任务：查看运行状态、暂停原因，必要时强停或清除强停标。"
      />

      {/* KPI 4 块 */}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <KpiCard label="任务总数" value={kpis.total} />
        <KpiCard label="运行中" value={kpis.active} tone="success" />
        <KpiCard label="已暂停" value={kpis.paused} tone="warn" />
        <KpiCard label="失败暂停" value={kpis.error} tone="danger" />
      </div>

      <Toolbar
        search={
          <SearchInput value={keyword} onChange={setKeyword} placeholder="名称 / UUID / 数字员工" />
        }
        filters={
          <>
            <div className="w-[140px]">
              <Select
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value as CronJobStatus | '')}
                title="状态"
              >
                <option value="">全部状态</option>
                <option value="active">运行中</option>
                <option value="paused">已暂停</option>
                <option value="error">失败暂停</option>
                <option value="archived">已归档</option>
              </Select>
            </div>
            <div className="w-[170px]">
              <Select
                value={pauseReasonFilter}
                onChange={(e) => setPauseReasonFilter(e.target.value as CronPauseReason | '')}
                title="暂停原因"
              >
                <option value="">全部暂停原因</option>
                <option value="admin_disabled">管理员强停</option>
                <option value="owner_inactive">所有者离职/挂起</option>
                <option value="quota_exceeded">触发配额超限</option>
                <option value="user_paused">用户手动暂停</option>
              </Select>
            </div>
            <div className="w-[130px]">
              <Select
                value={deliveryFilter}
                onChange={(e) => setDeliveryFilter(e.target.value as CronDeliveryKind | '')}
                title="投递类型"
              >
                <option value="">全部投递</option>
                <option value="direct">单聊</option>
                <option value="group">群聊</option>
              </Select>
            </div>
          </>
        }
        summary={`共 ${filtered.length} 条 · 客户端筛选，单次最多 200 条`}
        actions={
          <Button variant="secondary" onClick={() => void reload()} title="重新拉取">
            刷新
          </Button>
        }
      />

      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={[
          '名称',
          '所有者',
          '数字员工',
          '调度 (cron)',
          '时区',
          '下次触发',
          '状态',
          '暂停原因',
          '投递',
          '上次运行',
          '上次结果',
          '操作',
        ]}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</div> : undefined}
        empty={!loading && filtered.length === 0 ? (
          <EmptyState
            icon={<ListChecks size={22} />}
            title={items.length === 0 ? '本租户暂无定时任务' : '当前筛选无匹配任务'}
            description={
              items.length === 0
                ? '员工可在客户端任务页自助创建定时任务。'
                : '调整搜索 / 状态 / 暂停原因 / 投递类型筛选条件后重试。'
            }
          />
        ) : undefined}
      >
        {!loading && filtered.map((row) => {
          const adminPaused = row.admin_disabled || row.pause_reason === 'admin_disabled'
          return (
            <tr key={row.uuid} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`max-w-[220px] px-4 py-3 ${stickyLeftTdCls}`}>
                <div className="truncate font-medium text-[var(--color-text)]" title={row.name}>
                  {row.name}
                </div>
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={`账号 #${row.owner_account_id}`}>
                {row.owner_display_name || `#${row.owner_account_id}`}
              </td>
              <td className="max-w-[180px] px-4 py-3">
                <div
                  className={`truncate ${row.agent_name ? 'text-[var(--color-text-sub)]' : 'font-mono text-[11px] text-[var(--color-text-mute)]'}`}
                  title={row.agent_uuid}
                >
                  {row.agent_name || row.agent_uuid}
                </div>
              </td>
              <td className="whitespace-nowrap px-4 py-3" title={row.schedule_cron}>
                {humanizeCron(row.schedule_cron) ?? (
                  <code className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-[11px]">{row.schedule_cron}</code>
                )}
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-[var(--color-text-sub)]">{row.timezone || '-'}</td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-[var(--color-text-mute)]">{formatDateTime(row.next_run_at)}</td>
              <td className="whitespace-nowrap px-4 py-3">
                <StatusBadge status={row.status} adminDisabled={adminPaused} />
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-[var(--color-text-sub)]">
                {row.pause_reason ? PAUSE_REASON_LABEL[row.pause_reason as CronPauseReason] : '-'}
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-[var(--color-text-sub)]">
                {row.delivery_kind ? DELIVERY_KIND_LABEL[row.delivery_kind as CronDeliveryKind] : '-'}
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-[var(--color-text-mute)]">{formatDateTime(row.last_run_at)}</td>
              <td className="whitespace-nowrap px-4 py-3 text-xs">
                <span
                  className={
                    row.last_run_status === 'succeeded' || row.last_run_status === 'success'
                      ? 'text-[var(--color-success)]'
                      : row.last_run_status === 'failed'
                        ? 'text-[var(--color-danger)]'
                        : 'text-[var(--color-text-sub)]'
                  }
                  title={row.last_run_summary}
                >
                  {LAST_RUN_STATUS_LABEL[row.last_run_status ?? ''] ?? (row.last_run_status || '-')}
                </span>
              </td>
              <td className={`whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <RowActions
                  onEdit={() => setDetail(row)}
                  editLabel="详情"
                  extras={
                    <>
                      {!adminPaused && (
                        <button
                          type="button"
                          onClick={() => void handleForceDisable(row)}
                          title="强停 (admin)"
                          className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-danger)] transition hover:bg-red-50"
                        >
                          <Pause size={14} className="mr-1" />
                          强停
                        </button>
                      )}
                      {adminPaused && (
                        <button
                          type="button"
                          onClick={() => void handleClearAdminFlag(row)}
                          title="清除强停标 (不自动恢复)"
                          className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-warn)] transition hover:bg-amber-50"
                        >
                          <RotateCcw size={14} className="mr-1" />
                          清除强停标
                        </button>
                      )}
                    </>
                  }
                />
              </td>
            </tr>
          )
        })}
      </DataTable>

      {detail && <CronJobDetailDrawer job={detail} onClose={() => setDetail(null)} />}
      {confirmDialog}
    </div>
  )
}

// ---------- 子组件 ----------

function KpiCard({ label, value, tone }: { label: string; value: number; tone?: 'success' | 'warn' | 'danger' }) {
  const palette =
    tone === 'success'
      ? 'text-[var(--color-success)]'
      : tone === 'warn'
        ? 'text-[var(--color-warn)]'
        : tone === 'danger'
          ? 'text-[var(--color-danger)]'
          : 'text-[var(--color-text)]'
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white p-3">
      <div className="text-[12px] text-[var(--color-text-sub)]">{label}</div>
      <div className={`mt-1 text-[22px] font-semibold tabular-nums ${palette}`}>{value}</div>
    </div>
  )
}

function StatusBadge({ status, adminDisabled }: { status: CronJobStatus; adminDisabled?: boolean }) {
  const tone: Record<CronJobStatus, string> = {
    active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    paused: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
    error: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
    archived: 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]',
  }
  return (
    <span className="inline-flex items-center gap-1">
      <span className={`rounded px-2 py-0.5 text-[12px] ${tone[status]}`}>{STATUS_LABEL[status]}</span>
      {adminDisabled && (
        <span
          className="inline-flex items-center gap-0.5 rounded bg-[var(--color-danger-bg)] px-1.5 py-0.5 text-[11px] text-[var(--color-danger)]"
          title="被管理员强停"
        >
          <ShieldAlert size={10} />
          强停
        </span>
      )}
    </span>
  )
}

const RUN_STATUS_LABEL: Record<string, string> = {
  succeeded: '成功',
  failed: '失败',
  running: '运行中',
}

const RUN_TRIGGER_LABEL: Record<string, string> = {
  cron: '定时触发',
  manual: '手动触发',
}

function formatDuration(ms?: number) {
  if (ms == null) return '-'
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

function CronJobDetailDrawer({ job, onClose }: { job: CronJobAdminDTO; onClose: () => void }) {
  const [runs, setRuns] = useState<CronRunAdminDTO[] | null>(null)
  const [runsErr, setRunsErr] = useState('')

  useEffect(() => {
    let mounted = true
    CronJobsAdmin.detail(job.uuid)
      .then((res) => {
        if (mounted) setRuns(res.runs || [])
      })
      .catch((e: unknown) => {
        if (mounted) setRunsErr(translateError((e as Error).message || '运行记录加载失败'))
      })
    return () => {
      mounted = false
    }
  }, [job.uuid])

  return (
    <DrawerShell
      onClose={onClose}
      title={`任务详情 · ${job.name}`}
      icon={<ListChecks size={18} />}
      variant="polished"
      width="lg"
      footer={
        <div className="flex justify-end">
          <Button variant="secondary" onClick={onClose}>
            关闭
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        <KeyValueGrid
          rows={[
            { k: 'UUID', v: <code className="font-mono text-xs">{job.uuid}</code> },
            { k: '名称', v: job.name },
            { k: '描述', v: job.description || '-' },
            {
              k: '所有者',
              v: job.owner_display_name
                ? `${job.owner_display_name}（账号 #${job.owner_account_id}）`
                : `#${job.owner_account_id}`,
            },
            { k: '数字员工', v: job.agent_name || '-' },
            { k: '数字员工 UUID', v: <code className="font-mono text-xs">{job.agent_uuid}</code> },
            {
              k: '调度表达式',
              v: <code className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-xs">{job.schedule_cron}</code>,
            },
            { k: '时区', v: job.timezone || '-' },
            { k: '投递类型', v: job.delivery_kind ? DELIVERY_KIND_LABEL[job.delivery_kind as CronDeliveryKind] : '-' },
            {
              k: '投递目标',
              v: <code className="break-all font-mono text-[11px]">{JSON.stringify(job.delivery ?? {})}</code>,
            },
            { k: '状态', v: STATUS_LABEL[job.status] },
            {
              k: '暂停原因',
              v: job.pause_reason ? PAUSE_REASON_LABEL[job.pause_reason as CronPauseReason] : '-',
            },
            { k: '所有者离开时间', v: formatDateTime(job.owner_inactive_at) },
            { k: '调度类型', v: job.scheduler_kind },
            { k: '连续失败', v: `${job.consecutive_failures} / ${job.failure_threshold}` },
            { k: '上次运行', v: formatDateTime(job.last_run_at) },
            { k: '上次运行状态', v: job.last_run_status || '-' },
            { k: '上次运行摘要', v: job.last_run_summary || '-' },
            { k: '下次触发', v: formatDateTime(job.next_run_at) },
            { k: '创建时间', v: formatDateTime(job.created_at) },
            { k: '更新时间', v: formatDateTime(job.updated_at) },
          ]}
        />
        <div>
          <div className="mb-2 text-[13px] font-medium text-[var(--color-text)]">最近运行记录</div>
          {runsErr ? (
            <InlineAlert tone="danger">{runsErr}</InlineAlert>
          ) : runs == null ? (
            <div className="py-3 text-center text-xs text-[var(--color-text-sub)]">加载中…</div>
          ) : runs.length === 0 ? (
            <div className="rounded-lg border border-[var(--color-line)] py-4 text-center text-xs text-[var(--color-text-sub)]">
              暂无运行记录
            </div>
          ) : (
            <div className="overflow-hidden rounded-lg border border-[var(--color-line)]">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-[var(--color-bg-sub)] text-left text-[var(--color-text-sub)]">
                    <th className="px-3 py-2 font-medium">状态</th>
                    <th className="px-3 py-2 font-medium">触发方式</th>
                    <th className="px-3 py-2 font-medium">开始时间</th>
                    <th className="px-3 py-2 font-medium">耗时</th>
                    <th className="px-3 py-2 font-medium">错误摘要</th>
                  </tr>
                </thead>
                <tbody>
                  {runs.map((run) => (
                    <tr key={run.uuid} className="border-t border-[var(--color-line-soft)]">
                      <td className="px-3 py-2">
                        <span className={run.status === 'failed' ? 'text-[var(--color-danger)]' : run.status === 'succeeded' ? 'text-[var(--color-success)]' : 'text-[var(--color-text)]'}>
                          {RUN_STATUS_LABEL[run.status] ?? run.status}
                        </span>
                      </td>
                      <td className="px-3 py-2 text-[var(--color-text-sub)]">
                        {RUN_TRIGGER_LABEL[run.trigger_kind] ?? run.trigger_kind ?? '-'}
                      </td>
                      <td className="px-3 py-2 whitespace-nowrap text-[var(--color-text-sub)]">{formatDateTime(run.started_at)}</td>
                      <td className="px-3 py-2 text-[var(--color-text-sub)]">{formatDuration(run.duration_ms)}</td>
                      <td className="max-w-[320px] px-3 py-2">
                        {run.error_message ? (
                          <span className="break-all text-[var(--color-danger)]" title={run.error_message}>
                            {run.error_message}
                          </span>
                        ) : (
                          <span className="text-[var(--color-text-sub)]">-</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
        <InlineAlert tone="info">
          管理员路径仅展示运行状态与错误摘要，不暴露 prompt 渲染结果与投递正文（仅所有者可在客户端任务页查看）；如需排查触发链路，请通过审计日志反查 cron_run_uuid。
        </InlineAlert>
      </div>
    </DrawerShell>
  )
}

function KeyValueGrid({ rows }: { rows: Array<{ k: string; v: React.ReactNode }> }) {
  return (
    <div className="overflow-hidden rounded-lg border border-[var(--color-line)]">
      <table className="w-full text-[13px]">
        <tbody>
          {rows.map((row, i) => (
            <tr key={i} className="border-b border-[var(--color-line-soft)] last:border-b-0">
              <th className="w-[140px] bg-[var(--color-bg-sub)] px-3 py-2 text-left font-medium text-[var(--color-text-sub)]">
                {row.k}
              </th>
              <td className="px-4 py-3 text-[var(--color-text)]">{row.v}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
