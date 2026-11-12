// F08 §5.1 · 平台跨租户「定时任务列表」(/cron-jobs, platform scope).
//
// 平台管理员/运维视角: 查询全平台定时任务、定位具体租户/任务并查看最近运行记录。
// 统计看板拆到 /cron-dashboard。
//
// V1 只读监控: 不做任何跨租户写操作 (强停/恢复/立即执行)。那些仍走租户 scope 的
// 既有接口 (/cron 页 + /tenant/cron-jobs/*)。详情不暴露 prompt 渲染结果与执行日志正文。
//
// 调用:
//   GET /api/admin/v1/platform/cron-jobs?tenant_keyword=&task_keyword=&status=&last_result=&only_consecutive_failure=&limit=&offset=
//   GET /api/admin/v1/platform/cron-jobs/{uuid}?run_limit=
import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { ListChecks, ShieldAlert } from 'lucide-react'
import {
  PlatformCronJobs,
  type CronJobStatus,
  type PlatformCronJobDTO,
  type PlatformCronJobDetailDTO,
  type PlatformCronRunDTO,
} from '../lib/api'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  InlineAlert,
  PageHeader,
  Panel,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'

const STATUS_LABEL: Record<CronJobStatus, string> = {
  active: '运行中',
  paused: '已暂停',
  error: '失败暂停',
  archived: '已归档',
}

const LAST_RUN_STATUS_LABEL: Record<string, string> = {
  succeeded: '成功',
  success: '成功',
  failed: '失败',
  running: '执行中',
  queued: '排队中',
  cancelled: '已取消',
  '': '未运行',
}

const PAGE_SIZE_DEFAULT = 20

function formatDateTime(raw?: string): string {
  if (!raw) return '-'
  const t = new Date(raw)
  if (isNaN(t.getTime())) return '-'
  return t.toLocaleString('zh-CN', { hour12: false })
}

function formatDuration(ms?: number): string {
  if (!ms || ms <= 0) return '-'
  if (ms < 1000) return `${ms} ms`
  return `${(ms / 1000).toFixed(1)} s`
}

export default function PlatformCronJobsPage() {
  const [items, setItems] = useState<PlatformCronJobDTO[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  // 筛选
  const [tenantKeyword, setTenantKeyword] = useState('')
  const [taskKeyword, setTaskKeyword] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [lastResult, setLastResult] = useState('')
  // F25 评审返修：告警「去排查」深链 ?only_consecutive_failure=1 直接落到连续失败筛选
  const [searchParams] = useSearchParams()
  const [onlyConsecutive, setOnlyConsecutive] = useState(() => searchParams.get('only_consecutive_failure') === '1')

  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(PAGE_SIZE_DEFAULT)

  const [detailOpen, setDetailOpen] = useState(false)
  const [detail, setDetail] = useState<PlatformCronJobDetailDTO | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')
  // 记录当前详情请求的 uuid, 防止先点 A 后点 B 时 A 的迟到响应覆盖 B。
  const detailReqRef = useRef<string | null>(null)

  // 刷新用: bump tick 重新触发下面两个 effect (筛选变化不动 tick)。
  const [reloadTick, setReloadTick] = useState(0)

  // 列表: 随筛选/分页/刷新重取。loading 初值 true, 首次完成置 false, 刷新沿用旧数据不闪空态。
  useEffect(() => {
    let active = true
    PlatformCronJobs.list({
      tenant_keyword: tenantKeyword.trim() || undefined,
      task_keyword: taskKeyword.trim() || undefined,
      status: statusFilter || undefined,
      last_result: lastResult || undefined,
      only_consecutive_failure: onlyConsecutive || undefined,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((res) => {
        if (!active) return
        setItems(res.items || [])
        setTotal(res.total || 0)
        setErr('')
      })
      .catch((e: unknown) => {
        if (!active) return
        setErr((e as Error).message || '加载失败')
        setItems([])
        setTotal(0)
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [tenantKeyword, taskKeyword, statusFilter, lastResult, onlyConsecutive, page, pageSize, reloadTick])

  // 筛选变化时页码重置到第 1 页 (避免停留在旧 offset 看到空数据)。
  function resetToFirstPage() {
    setPage(1)
  }

  async function openDetail(uuid: string) {
    // 立刻清空旧详情并打开抽屉进 loading 态, 避免请求期间/失败时残留上一条任务的详情。
    detailReqRef.current = uuid
    setDetailOpen(true)
    setDetail(null)
    setDetailError('')
    setDetailLoading(true)
    try {
      const res = await PlatformCronJobs.detail(uuid, 20)
      if (detailReqRef.current !== uuid) return // 已被更晚的点击取代
      setDetail(res)
    } catch (e: unknown) {
      if (detailReqRef.current !== uuid) return
      setDetail(null)
      setDetailError((e as Error).message || '加载失败')
    } finally {
      if (detailReqRef.current === uuid) setDetailLoading(false)
    }
  }

  function closeDetail() {
    detailReqRef.current = null
    setDetailOpen(false)
    setDetail(null)
    setDetailError('')
    setDetailLoading(false)
  }

  function refresh() {
    setReloadTick((t) => t + 1)
  }

  return (
    <div className="space-y-4">
      <PageHeader
        className="mb-1"
        title="定时任务列表"
        subtitle="跨租户查询定时任务、查看最近运行记录。平台视图只读，强停/恢复请进入对应租户任务页处理。"
      />

      <Panel className="px-3 py-3">
        <Toolbar
          className="mb-0"
          search={
            <SearchInput
              value={tenantKeyword}
              onChange={(v) => {
                setTenantKeyword(v)
                resetToFirstPage()
              }}
              placeholder="搜索租户名称 / 租户 ID"
            />
          }
          filters={
            <>
              <div className="w-[180px]">
                <SearchInput
                  value={taskKeyword}
                  onChange={(v) => {
                    setTaskKeyword(v)
                    resetToFirstPage()
                  }}
                  placeholder="搜索任务名称"
                />
              </div>
              <div className="w-[150px]">
                <Select
                  value={statusFilter}
                  onChange={(e) => {
                    setStatusFilter(e.target.value)
                    resetToFirstPage()
                  }}
                >
                  <option value="">全部状态</option>
                  <option value="active">运行中</option>
                  <option value="paused">已暂停</option>
                  <option value="error">失败暂停</option>
                  <option value="archived">已归档</option>
                </Select>
              </div>
              <div className="w-[150px]">
                <Select
                  value={lastResult}
                  onChange={(e) => {
                    setLastResult(e.target.value)
                    resetToFirstPage()
                  }}
                >
                  <option value="">全部最近结果</option>
                  <option value="succeeded">成功</option>
                  <option value="failed">失败</option>
                  <option value="running">执行中</option>
                  <option value="none">未运行</option>
                </Select>
              </div>
              <label className="flex h-9 items-center gap-2 whitespace-nowrap rounded-md border border-[var(--color-line)] bg-white px-3 text-[13px] text-[var(--color-text-sub)]">
                <input
                  type="checkbox"
                  checked={onlyConsecutive}
                  onChange={(e) => {
                    setOnlyConsecutive(e.target.checked)
                    resetToFirstPage()
                  }}
                />
                只看连续失败
              </label>
            </>
          }
          summary={<span className="tabular-nums">共 {total} 条</span>}
          actions={
            <Button variant="secondary" size="sm" onClick={refresh}>
              刷新
            </Button>
          }
        />
      </Panel>

      {err && (
        <div className="mb-3">
          <InlineAlert tone="danger">{err}</InlineAlert>
        </div>
      )}

      <DataTable
        stickyFirstCol
        stickyLastCol
        className="shadow-sm"
        headers={[
          '租户名称',
          '租户 ID',
          '任务名称',
          '数字员工',
          '状态',
          '调度',
          '下次执行',
          '最近结果',
          '最近执行时间',
          '连续失败',
          '操作',
        ]}
        empty={
          !loading && items.length === 0 ? (
            <EmptyState title="暂无定时任务" description="当前筛选条件下没有匹配的跨租户定时任务。" />
          ) : undefined
        }
      >
        {items.map((row) => (
          <tr key={row.uuid} className="group">
            <td className={`${stickyLeftTdCls} w-[180px] whitespace-nowrap px-4 py-2.5`}>
              <span className="block max-w-[160px] truncate font-medium text-[var(--color-text)]" title={row.tenant_name || '-'}>
                {row.tenant_name || '-'}
              </span>
            </td>
            <td className="whitespace-nowrap px-4 py-2.5">
              <TenantId value={row.tenant_id} />
            </td>
            <td className="min-w-[180px] whitespace-nowrap px-4 py-2.5">
              <span className="block max-w-[220px] truncate font-medium text-[var(--color-text)]" title={row.name}>
                {row.name}
              </span>
            </td>
            <td className="min-w-[150px] whitespace-nowrap px-4 py-2.5">
              <span className="block max-w-[180px] truncate text-[var(--color-text-sub)]" title={row.agent_name || '-'}>
                {row.agent_name || '-'}
              </span>
            </td>
            <td className="whitespace-nowrap px-4 py-2.5">
              <StatusBadge status={row.status} adminDisabled={row.admin_disabled} />
            </td>
            <td className="whitespace-nowrap px-4 py-2.5">
              <code className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-[11px]">{row.schedule_cron}</code>
            </td>
            <td className="whitespace-nowrap px-4 py-2.5 text-[var(--color-text-sub)]">{formatDateTime(row.next_run_at)}</td>
            <td className="whitespace-nowrap px-4 py-2.5">
              <LastResult status={row.last_run_status} />
            </td>
            <td className="whitespace-nowrap px-4 py-2.5 text-[var(--color-text-sub)]">{formatDateTime(row.last_run_at)}</td>
            <td className="whitespace-nowrap px-4 py-2.5">
              <span className={row.consecutive_failures > 0 ? 'font-medium text-[var(--color-danger)]' : 'text-[var(--color-text-mute)]'}>
                {row.consecutive_failures} / {row.failure_threshold}
              </span>
            </td>
            <td className={stickyRightTdCls}>
              <Button variant="ghost" size="sm" onClick={() => openDetail(row.uuid)}>
                详情
              </Button>
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(n) => {
          setPageSize(n)
          setPage(1)
        }}
      />

      {detailOpen && (
        <CronJobDetailDrawer job={detail} loading={detailLoading} error={detailError} onClose={closeDetail} />
      )}
    </div>
  )
}

function TenantId({ value }: { value: number }) {
  return (
    <span className="inline-flex h-6 items-center rounded-md bg-[var(--color-bg-sub)] px-2 font-mono text-[12px] tabular-nums text-[var(--color-text-sub)] ring-1 ring-[var(--color-line-soft)]">
      {value}
    </span>
  )
}

// ---------- 状态 / 最近结果 badge ----------

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

function LastResult({ status }: { status?: string }) {
  const key = status ?? ''
  const label = LAST_RUN_STATUS_LABEL[key] ?? (key || '未运行')
  const tone =
    key === 'failed'
      ? 'text-[var(--color-danger)]'
      : key === 'succeeded' || key === 'success'
        ? 'text-[var(--color-success)]'
        : 'text-[var(--color-text-sub)]'
  return <span className={tone}>{label}</span>
}

// ---------- 详情抽屉 ----------

function CronJobDetailDrawer({
  job,
  loading,
  error,
  onClose,
}: {
  job: PlatformCronJobDetailDTO | null
  loading: boolean
  error: string
  onClose: () => void
}) {
  return (
    <DrawerShell
      onClose={onClose}
      title={job ? `任务详情 · ${job.name}` : '任务详情'}
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
      {loading ? (
        <div className="py-12 text-center text-[13px] text-[var(--color-text-mute)]">加载中…</div>
      ) : error || !job ? (
        <div className="py-12">
          <InlineAlert tone="danger">{error || '加载失败，请重试。'}</InlineAlert>
        </div>
      ) : (
        <div className="space-y-4">
          <KeyValueGrid
            rows={[
              { k: '任务名称', v: job.name },
              { k: '任务 UUID', v: <code className="font-mono text-xs">{job.uuid}</code> },
              { k: '描述', v: job.description || '-' },
              { k: '租户', v: `${job.tenant_name || '-'}（ID ${job.tenant_id}）` },
              {
                k: '所有者',
                v: job.owner_display_name ? `${job.owner_display_name}（账号 #${job.owner_account_id}）` : `#${job.owner_account_id}`,
              },
              { k: '数字员工', v: job.agent_name || '-' },
              { k: '数字员工 UUID', v: <code className="font-mono text-xs">{job.agent_uuid}</code> },
              { k: '调度表达式', v: <code className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-xs">{job.schedule_cron}</code> },
              { k: '时区', v: job.timezone || '-' },
              { k: '调度类型', v: job.scheduler_kind },
              { k: '状态', v: STATUS_LABEL[job.status] },
              { k: '连续失败', v: `${job.consecutive_failures} / ${job.failure_threshold}` },
              { k: '上次运行', v: formatDateTime(job.last_run_at) },
              { k: '上次运行状态', v: LAST_RUN_STATUS_LABEL[job.last_run_status ?? ''] ?? (job.last_run_status || '-') },
              { k: '下次触发', v: formatDateTime(job.next_run_at) },
              { k: '创建时间', v: formatDateTime(job.created_at) },
              { k: '更新时间', v: formatDateTime(job.updated_at) },
            ]}
          />

          <div>
            <div className="mb-2 text-[13px] font-medium text-[var(--color-text-sub)]">最近运行记录（最多 20 条）</div>
            <RunTable runs={job.runs} />
          </div>

          <InlineAlert tone="info">
            管理员路径不暴露 prompt 渲染结果与执行日志正文（仅所有者可在客户端任务页查看）；如需深入排查触发链路，请用 run UUID 反查审计日志。
          </InlineAlert>
        </div>
      )}
    </DrawerShell>
  )
}

function RunTable({ runs }: { runs: PlatformCronRunDTO[] }) {
  if (!runs || runs.length === 0) {
    return (
      <div className="rounded-lg border border-[var(--color-line)] px-4 py-6 text-center text-[12.5px] text-[var(--color-text-mute)]">
        暂无运行记录。
      </div>
    )
  }
  return (
    <div className="overflow-hidden rounded-lg border border-[var(--color-line)]">
      <table className="w-full text-[12.5px]">
        <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] text-left font-semibold text-[var(--color-text)]">
          <tr>
            <th className="px-3 py-2">触发时间</th>
            <th className="px-3 py-2">结果</th>
            <th className="px-3 py-2">触发方式</th>
            <th className="px-3 py-2">耗时</th>
            <th className="px-3 py-2">失败原因</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-[var(--color-line-soft)]">
          {runs.map((r) => (
            <tr key={r.uuid}>
              <td className="whitespace-nowrap px-3 py-2 text-[var(--color-text-sub)]">{formatDateTime(r.started_at)}</td>
              <td className="whitespace-nowrap px-3 py-2">
                <LastResult status={r.status} />
              </td>
              <td className="whitespace-nowrap px-3 py-2 text-[var(--color-text-sub)]">{r.trigger_kind || '-'}</td>
              <td className="whitespace-nowrap px-3 py-2 text-[var(--color-text-sub)]">{formatDuration(r.duration_ms)}</td>
              <td className="px-3 py-2 text-[var(--color-text-sub)]">
                <span className="line-clamp-2" title={r.error_message || ''}>{r.error_message || '-'}</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function KeyValueGrid({ rows }: { rows: Array<{ k: string; v: React.ReactNode }> }) {
  return (
    <div className="overflow-hidden rounded-lg border border-[var(--color-line)]">
      <table className="w-full text-[13px]">
        <tbody>
          {rows.map((row, i) => (
            <tr key={i} className="border-b border-[var(--color-line-soft)] last:border-b-0">
              <th className="w-[140px] bg-[var(--color-bg-sub)] px-3 py-2 text-left font-medium text-[var(--color-text-sub)]">{row.k}</th>
              <td className="px-4 py-3 text-[var(--color-text)]">{row.v}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
