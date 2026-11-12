// PlatformDriveWorkersPage — F06 §5.1 平台「云盘定时任务」看板 (2026-07-06 更名并增强).
//
// 能力:
//   - 列出 5 类 backend job: 状态 / 调度周期 / 上次运行 / 耗时 / 处理结果 / 堆积量 / 下次运行
//   - 停摆检测: stalled=true 渲染红色「调度停摆」(后端按 3×interval 判定)
//   - 手动触发一轮 (ConfirmDialog, ~10s 内被 drive-worker 消费; 幂等排队)
//   - 失败明细 DrawerShell (drive_worker_job_failures, 后端分页, 14 天滚动保留)
//
// 权限: 看板/明细 platform.drive.read_workers; 触发 platform.drive.manage_workers (后端最终把关,
// 前端沿用 manage_quota 现状不按权限隐藏按钮).

import { useEffect, useState } from 'react'
import {
  DriveWorkersAdmin,
  type DriveWorkerFailure,
  type DriveWorkerJobStatus,
} from '../../lib/api'
import {
  Button, ConfirmDialog, DataTable, DrawerShell, EmptyState, InlineAlert,
  PageHeader, Pagination, Toolbar, stickyRightTdCls,
} from '../../components/ui'
import { notifyOk } from '../../lib/toast'
import {
  Activity, AlertCircle, AlertTriangle, CheckCircle2, Loader2, Pause, Play, RefreshCw,
} from 'lucide-react'

// JOB_META — 每个后台 job 给管理员看的"标题 + 一句话说明"。
// 写作原则: 标题用动词短语 (做什么), 说明讲清楚 *为什么* 要跑这个 job (即不跑会怎样)。
// 不要出现 "reaper / cleaner / executor" 这种工程词, 那些留在下方 mono 代码里给开发查日志。
const JOB_META: Record<string, { title: string; desc: string }> = {
  staging_reaper: {
    title: '清理未完成的上传',
    desc: '用户上传中途取消/掉线留下的临时碎片, 超过保留期自动回收, 防止占用存储桶。',
  },
  recycle_cleaner: {
    title: '清空过期回收站',
    desc: '删除已超过保留天数的回收站文件, 物理删存储桶对象并释放租户配额。',
  },
  version_cleaner: {
    title: '清理多余的历史版本',
    desc: '同一文件只保留最近 N 个版本, 更老的版本对应的对象会被物理删除。',
  },
  copy_executor: {
    title: '跨空间复制 (异步)',
    desc: '跨空间复制当前即时完成, 无需后台任务; 异步复制能力上线后启用。',
  },
  thumbnail: {
    title: '生成预览缩略图',
    desc: '为图片 / PDF 等生成首屏预览缩略图; 能力上线后自动启用。',
  },
}

const OBJECT_KIND_LABEL: Record<string, string> = {
  upload_ticket: '上传票据',
  recycle_entry: '回收站条目',
  file: '文件',
  file_version: '历史版本',
}

const PENDING_TIP =
  '实时待处理量, 三个任务口径不同: 清理未完成的上传 = 过期未完成的上传票据数; '
  + '清空过期回收站 = 已到期的回收站条目数; 清理多余的历史版本 = 版本数超过保留上限的文件数。'

// 时间统一本地时区展示 (后端返 RFC3339 UTC)。
function fmtTime(iso?: string) {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleString('zh-CN', { hour12: false })
}

function fmtInterval(seconds?: number) {
  if (!seconds || seconds <= 0) return '—'
  if (seconds % 3600 === 0) return `每 ${seconds / 3600} 小时`
  if (seconds % 60 === 0) return `每 ${seconds / 60} 分钟`
  return `每 ${seconds} 秒`
}

function sinceText(iso?: string) {
  if (!iso) return '从未运行, 请确认 drive-worker 进程已启动'
  const ms = Date.now() - new Date(iso).getTime()
  if (!Number.isFinite(ms) || ms < 0) return ''
  const min = Math.floor(ms / 60000)
  if (min < 60) return `上次运行距今 ${min} 分钟`
  const hours = Math.floor(min / 60)
  if (hours < 48) return `上次运行距今 ${hours} 小时`
  return `上次运行距今 ${Math.floor(hours / 24)} 天`
}

function statusView(job: DriveWorkerJobStatus) {
  if (!job.enabled || job.status === 'disabled') {
    return { icon: <Pause size={14} className="text-[var(--color-text-mute)]" aria-label="未启用" />, text: '未启用', danger: false }
  }
  if (job.stalled) {
    return { icon: <AlertTriangle size={14} className="text-[var(--color-danger)]" aria-label="调度停摆" />, text: '调度停摆', danger: true }
  }
  if (job.status === 'running') {
    return { icon: <Loader2 size={14} className="animate-spin text-[var(--color-brand)]" aria-label="运行中" />, text: '运行中', danger: false }
  }
  if (job.status === 'failed' || job.last_error || (job.last_failed ?? 0) > 0) {
    return { icon: <AlertCircle size={14} className="text-[var(--color-danger)]" aria-label="上次失败" />, text: '失败', danger: true }
  }
  return { icon: <CheckCircle2 size={14} className="text-emerald-600" aria-label="正常" />, text: '正常', danger: false }
}

export function PlatformDriveWorkersPage() {
  const [items, setItems] = useState<DriveWorkerJobStatus[]>([])
  const [loading, setLoading] = useState(true)
  const [loadErr, setLoadErr] = useState('')
  const [tick, setTick] = useState(0)
  const refresh = () => setTick((t) => t + 1)

  // 手动触发确认框
  const [confirmJob, setConfirmJob] = useState<{ job: string; title: string } | null>(null)

  // 失败明细抽屉 (后端分页)
  const [failView, setFailView] = useState<{ job: string; title: string } | null>(null)
  const [failPage, setFailPage] = useState(1)
  const [failPageSize, setFailPageSize] = useState(20)
  const [failRows, setFailRows] = useState<DriveWorkerFailure[]>([])
  const [failTotal, setFailTotal] = useState(0)
  const [failLoading, setFailLoading] = useState(false)
  const [failErr, setFailErr] = useState('')

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DriveWorkersAdmin.list()
      .then((r) => { if (!cancelled) { setItems(r.items || []); setLoadErr('') } })
      .catch((e: Error) => { if (!cancelled) setLoadErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick])

  useEffect(() => {
    if (!failView) return
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setFailLoading(true)
    DriveWorkersAdmin.failures(failView.job, failPageSize, (failPage - 1) * failPageSize)
      .then((r) => { if (!cancelled) { setFailRows(r.items || []); setFailTotal(r.total || 0); setFailErr('') } })
      .catch((e: Error) => { if (!cancelled) setFailErr(e.message) })
      .finally(() => { if (!cancelled) setFailLoading(false) })
    return () => { cancelled = true }
  }, [failView, failPage, failPageSize])

  const openFailures = (job: DriveWorkerJobStatus) => {
    setFailRows([])
    setFailTotal(0)
    setFailErr('')
    setFailPage(1)
    setFailView({ job: job.job, title: JOB_META[job.job]?.title || job.job })
  }

  return (
    <div>
      <PageHeader
        title="云盘定时任务"
        subtitle="云盘配套的定时清理任务, 自动回收上传残片、过期回收站与多余历史版本, 防止存储无限增长。任务由 drive-worker 进程按固定周期调度, 支持手动触发一轮。"
      />

      {loadErr && (
        <div className="mb-3">
          <InlineAlert tone="danger">
            读取任务状态失败: {loadErr}
            <div className="mt-1 text-[12px] text-[var(--color-text-mute)]">
              请稍后重试; 若持续失败, 检查 agent-bus admin 服务与数据库连接。
            </div>
          </InlineAlert>
        </div>
      )}

      <Toolbar
        summary={<>共 <b className="text-[var(--color-text)]">{items.length}</b> 个任务</>}
        actions={<Button variant="secondary" onClick={refresh} disabled={loading}><RefreshCw size={14} /> 刷新</Button>}
      />

      <DataTable
        stickyLastCol
        headers={[
          '任务', '代码', '说明', '状态', '调度周期', '上次运行', '上次结束', '耗时', '处理结果',
          <span key="pending" title={PENDING_TIP} className="cursor-help underline decoration-dotted underline-offset-2">堆积量</span>,
          '下次运行', '上次错误', '操作',
        ]}
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<Activity size={20} />}
            title="尚无任务状态"
            description={loadErr ? '上方错误信息说明问题。' : '后端尚未上报任何任务状态; 检查 drive-worker 进程是否已启动。'}
          />
        ) : null}
      >
        {items.map((job) => {
          const meta = JOB_META[job.job]
          const st = statusView(job)
          return (
          <tr key={job.job} className="group">
            <td className="px-4 py-3 align-middle">
              <div className="font-medium text-[var(--color-text)] whitespace-nowrap">{meta?.title || job.job}</div>
            </td>
            <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-mute)] whitespace-nowrap">
              {job.job}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] leading-snug text-[var(--color-text-sub)] min-w-[260px] max-w-[420px] whitespace-normal">
              {meta?.desc || '—'}
            </td>
            <td className="px-4 py-3 align-middle whitespace-nowrap">
              <span className={`inline-flex items-center gap-1.5 text-[12px] ${st.danger ? 'font-medium text-[var(--color-danger)]' : 'text-[var(--color-text-sub)]'}`}>
                {st.icon}
                {st.text}
              </span>
              {job.stalled && job.enabled && (
                <div className="mt-1 text-[11px] text-[var(--color-danger)]">
                  {sinceText(job.last_run_at)}
                </div>
              )}
              {(job.consecutive_failures ?? 0) >= 2 && (
                <div className="mt-1 text-[11px] text-[var(--color-danger)]">
                  连续失败 {job.consecutive_failures} 次
                </div>
              )}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)] whitespace-nowrap">
              {job.enabled ? fmtInterval(job.interval_seconds) : '—'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)] whitespace-nowrap">
              {fmtTime(job.last_run_at)}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)] whitespace-nowrap">
              {fmtTime(job.last_finished_at)}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums whitespace-nowrap">
              {job.last_run_duration_ms != null ? `${job.last_run_duration_ms} ms` : '—'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums whitespace-nowrap">
              {job.last_processed != null ? `${job.last_processed} 成功 / ${job.last_failed ?? 0} 失败` : '—'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums whitespace-nowrap">
              {job.pending_count ?? '—'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] whitespace-nowrap">
              {job.next_due_at
                ? <span className={job.stalled ? 'text-[var(--color-danger)]' : 'text-[var(--color-text-sub)]'}>{fmtTime(job.next_due_at)}</span>
                : '—'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] leading-snug text-[var(--color-danger)] min-w-[200px] max-w-[360px] whitespace-normal">
              {job.last_error || '—'}
            </td>
            <td className={`px-4 py-3 align-middle whitespace-nowrap ${stickyRightTdCls}`}>
              {job.enabled ? (
                <div className="flex items-center gap-1.5">
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={job.trigger_pending}
                    onClick={() => setConfirmJob({ job: job.job, title: JOB_META[job.job]?.title || job.job })}
                  >
                    <Play size={13} /> {job.trigger_pending ? '已排队' : '立即执行'}
                  </Button>
                  <Button variant="ghost" size="sm" onClick={() => openFailures(job)}>失败明细</Button>
                </div>
              ) : (
                <span className="text-[12px] text-[var(--color-text-mute)]">—</span>
              )}
            </td>
          </tr>
          )
        })}
      </DataTable>

      {confirmJob && (
        <ConfirmDialog
          title={`立即执行「${confirmJob.title}」?`}
          description="将插队执行一轮清理, drive-worker 约 10 秒内开始; 每轮最多处理 100 条, 堆积较多时需多次触发或等自动调度消化。"
          tone="info"
          confirmLabel="立即执行"
          busyLabel="提交中…"
          onClose={() => setConfirmJob(null)}
          onConfirm={async () => {
            const r = await DriveWorkersAdmin.trigger(confirmJob.job)
            notifyOk(r.already_pending ? '该任务已在排队中, 无需重复触发' : '已加入执行队列, 约 10 秒内开始')
            setConfirmJob(null)
            refresh()
          }}
        />
      )}

      {failView && (
        <DrawerShell
          title={`失败明细 · ${failView.title}`}
          subtitle="最近失败对象的原因明细, 保留 14 天; 更早的追溯请查 drive-worker 服务日志。"
          width="lg"
          onClose={() => setFailView(null)}
        >
          {failErr && (
            <div className="mb-3">
              <InlineAlert tone="danger">读取失败明细失败: {failErr}</InlineAlert>
            </div>
          )}
          <DataTable
            headers={['时间', '对象类型', '对象标识', '租户', '失败原因']}
            empty={!failLoading && !failRows.length ? (
              <EmptyState
                icon={<CheckCircle2 size={20} />}
                title="暂无失败记录"
                description="该任务最近 14 天没有对象级失败。"
              />
            ) : null}
          >
            {failRows.map((f) => (
              <tr key={f.id}>
                <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)] whitespace-nowrap">
                  {fmtTime(f.occurred_at)}
                </td>
                <td className="px-4 py-3 align-middle text-[12px] whitespace-nowrap">
                  {OBJECT_KIND_LABEL[f.object_kind] || f.object_kind}
                </td>
                <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-mute)] max-w-[220px] truncate" title={f.object_ref}>
                  {f.object_ref}
                </td>
                <td className="px-4 py-3 align-middle text-[12px] tabular-nums whitespace-nowrap">
                  {f.tenant_id != null ? `#${f.tenant_id}` : '—'}
                </td>
                <td className="px-4 py-3 align-middle text-[12px] leading-snug text-[var(--color-text-sub)] min-w-[240px] max-w-[420px] whitespace-normal">
                  {f.reason}
                </td>
              </tr>
            ))}
          </DataTable>
          <Pagination
            total={failTotal}
            page={failPage}
            pageSize={failPageSize}
            onPageChange={setFailPage}
            onPageSizeChange={(size) => { setFailPageSize(size); setFailPage(1) }}
          />
        </DrawerShell>
      )}
    </div>
  )
}
