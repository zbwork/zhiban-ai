import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { AlertTriangle, Archive, Check, CircleCheck, CircleX, Clock3, Download, Edit3, LoaderCircle, Package, Play, Plus, RefreshCw, RotateCcw, SendHorizontal, Square, TerminalSquare, Trash2 } from 'lucide-react'

import {
  ClientVersions,
  ClientBuildJobs,
  type ClientBuildJob,
  type ClientBuildLog,
  type ClientVersion,
  type ClientVersionArch,
  type ClientVersionChannel,
  type ClientVersionInput,
  type ClientVersionPlatform,
  type ClientVersionStatus,
  type UploadProgress,
} from '../lib/api'
import { notifyError, notifyOk } from '../lib/toast'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  ProgressBar,
  SearchInput,
  Select,
  stickyRightTdCls,
  Tabs,
  Toolbar,
} from '../components/ui'
import { BuildLogViewer } from '../components/BuildLogViewer'
import { FileUploadPicker } from '../components/form/FileUploadPicker'
import { clientReleaseVersionError } from '../lib/clientReleaseVersion'

type PlatformTab = ClientVersionPlatform

const PLATFORM_TABS: Array<{ value: PlatformTab; label: string }> = [
  { value: 'macos', label: 'macOS' },
  { value: 'windows', label: 'Windows' },
  { value: 'ios', label: 'iOS' },
  { value: 'android', label: 'Android' },
]

const PLATFORM_LABEL: Record<ClientVersionPlatform, string> = {
  macos: 'macOS',
  windows: 'Windows',
  ios: 'iOS',
  android: 'Android',
}

const ARCH_LABEL: Record<ClientVersionArch, string> = {
  universal: 'Universal',
  arm64: 'ARM64',
  x64: 'x64',
}

const CHANNEL_LABEL: Record<ClientVersionChannel, string> = {
  stable: '正式版',
  beta: 'Beta',
  dev: 'Dev',
}

const STATUS_LABEL: Record<ClientVersionStatus, string> = {
  draft: '草稿',
  published: '已发布',
  archived: '已归档',
}

const STATUS_TONE: Record<ClientVersionStatus, string> = {
  draft: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
  published: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  archived: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
}

const textareaCls = 'min-h-[96px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-relaxed text-[var(--color-text)] outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]'

function needsSparkleSignature(platform: string) {
  return platform === 'macos' || platform === 'windows'
}

function needsInstallerPackage(platform: ClientVersionPlatform) {
  return platform !== 'ios'
}

function isValidDeltaEdSignature(value: string) {
  if (!/^[A-Za-z0-9+/]{86}==$/.test(value)) return false
  try {
    return atob(value).length === 64
  } catch {
    return false
  }
}

function formatFileSize(bytes: number): string {
  if (bytes <= 0) return '-'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

type UploadTaskState = UploadProgress & { fileName: string }

function uploadProgressText(progress: UploadTaskState) {
  if (progress.loaded >= progress.total) return '文件已发送，服务器处理中...'
  return `${formatFileSize(progress.loaded)} / ${formatFileSize(progress.total)}`
}

export function ClientVersionsPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const platform = (searchParams.get('platform') || 'macos') as PlatformTab

  const [items, setItems] = useState<ClientVersion[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [keyword, setKeyword] = useState('')
  const [channel, setChannel] = useState('')
  const [status, setStatus] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<ClientVersion | null>(null)
  const [publishing, setPublishing] = useState<ClientVersion | null>(null)
  const [archiving, setArchiving] = useState<ClientVersion | null>(null)
  const [deleting, setDeleting] = useState<ClientVersion | null>(null)
  const [pipelineOpen, setPipelineOpen] = useState(false)

  const setPlatform = (p: PlatformTab) => {
    const sp = new URLSearchParams(searchParams)
    sp.set('platform', p)
    setSearchParams(sp, { replace: true })
    setPage(1)
  }

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    ClientVersions.list({
      q: keyword || undefined,
      platform: platform || undefined,
      channel: channel || undefined,
      status: status || undefined,
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
  }, [keyword, platform, channel, status, page, pageSize, tick])

  const summary = useMemo(() => `共 ${total} 个版本`, [total])
  const resetPage = (fn: () => void) => { setPage(1); fn() }
  const refresh = useCallback(() => setTick((v) => v + 1), [])

  return (
    <div>
      <PageHeader
        title="客户端版本"
        subtitle="维护各平台安装包版本和更新说明；发布后客户端自动获取更新提示，Appcast 由后端动态生成。"
      />

      <div className="mb-4">
        <Tabs<PlatformTab> value={platform} items={PLATFORM_TABS} onChange={setPlatform} />
      </div>

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索版本号 / 构建号 / 标题"
          />
        }
        filters={
          <>
            <div className="w-[132px]">
              <Select value={channel} onChange={(e) => resetPage(() => setChannel(e.target.value))}>
                <option value="">全部渠道</option>
                {Object.entries(CHANNEL_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
            <div className="w-[132px]">
              <Select value={status} onChange={(e) => resetPage(() => setStatus(e.target.value))}>
                <option value="">全部状态</option>
                {Object.entries(STATUS_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </div>
          </>
        }
        summary={summary}
        actions={
          <>
            <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新客户端版本">
              <RefreshCw size={14} />
            </Button>
            <BuildStatusButton key={platform} platform={platform} onOpen={() => setPipelineOpen(true)} onBuildCompleted={refresh} />
            <Button onClick={() => setCreating(true)}>
              <Plus size={14} />
              新建 {PLATFORM_LABEL[platform]} 版本
            </Button>
          </>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        headers={['版本', '构建号', '架构', '渠道', '标题', '安装包', '状态', '强制', '发布时间', '操作']}
        stickyLastCol
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载客户端版本</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<Package size={20} />}
            title="暂无客户端版本"
            description="新建版本后发布，客户端即可通过 Bus 获取更新提示。"
          />
        ) : undefined}
      >
        {!loading && items.map((item) => (
          <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
            <td className="whitespace-nowrap px-4 py-3 font-medium text-[var(--color-text)]">
              {item.version}
            </td>
            <td className="whitespace-nowrap px-4 py-3 font-mono text-[var(--color-text-sub)]">
              {item.build_number}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
              {ARCH_LABEL[item.arch] || item.arch}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
              {CHANNEL_LABEL[item.channel] || item.channel}
            </td>
            <td className="max-w-[220px] px-4 py-3">
              <div className="truncate text-[var(--color-text)]" title={item.title || item.version}>
                {item.title || item.version}
              </div>
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              {!needsInstallerPackage(item.platform) ? (
                <span className="text-[12px] text-[var(--color-text-sub)]">App Store 托管</span>
              ) : item.download_url ? (
                <div className="flex items-center gap-2">
                  <span className="inline-flex items-center gap-1 text-[12px] font-medium text-[var(--color-success)]">
                    <Check size={12} />
                    已上传
                    {item.file_size_bytes > 0 && <span className="ml-1 text-[var(--color-text-mute)]">({formatFileSize(item.file_size_bytes)})</span>}
                  </span>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => {
                      ClientVersions.downloadPackage(item.uuid)
                        .then((resp) => window.open(resp.download_url, '_blank', 'noopener,noreferrer'))
                        .catch((e: Error) => notifyError(e.message))
                    }}
                    title="下载安装包"
                    aria-label="下载安装包"
                  >
                    <Download size={14} />
                  </Button>
                </div>
              ) : (
                <span className="text-[12px] text-[var(--color-text-mute)]">未上传</span>
              )}
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              <Badge className={STATUS_TONE[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{item.is_forced ? '是' : '否'}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.published_at)}</td>
            <td className={`whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
              <div className="flex items-center gap-1">
                {item.status === 'draft' && (!needsInstallerPackage(item.platform) || !!item.download_url) && (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setPublishing(item)}
                    title="发布"
                    aria-label="发布客户端版本"
                  >
                    <SendHorizontal size={14} />
                  </Button>
                )}
                {item.status === 'published' && (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setArchiving(item)}
                    title="归档（取消发布）"
                    aria-label="归档客户端版本"
                  >
                    <Archive size={14} />
                  </Button>
                )}
                <Button variant="ghost" size="sm" onClick={() => setEditing(item)} title="编辑" aria-label="编辑客户端版本">
                  <Edit3 size={14} />
                </Button>
                <Button variant="ghost" size="sm" onClick={() => setDeleting(item)} title="删除" aria-label="删除客户端版本">
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
        <NewVersionDialog
          platform={platform}
          onClose={() => setCreating(false)}
          onCreated={(item) => {
            setCreating(false)
            setEditing(item)
            refresh()
          }}
        />
      )}

      {editing && (
        <ClientVersionDrawer
          item={editing}
          onClose={() => { setEditing(null); refresh() }}
          onSaved={(updated) => setEditing(updated)}
        />
      )}

      {publishing && (
        <ConfirmDialog
          title="发布客户端版本"
          description={`确认将 ${PLATFORM_LABEL[publishing.platform]} ${publishing.version} (${publishing.build_number}) 发布给客户端？发布后用户将收到更新提示。`}
          confirmLabel="发布"
          busyLabel="发布中..."
          tone="info"
          onClose={() => setPublishing(null)}
          onConfirm={async () => {
            await ClientVersions.patch(publishing.uuid, { ...toInput(publishing), status: 'published' })
            notifyOk('已发布客户端版本')
            setPublishing(null)
            refresh()
          }}
        />
      )}

      {archiving && (
        <ConfirmDialog
          title="归档客户端版本"
          description={`确认将 ${PLATFORM_LABEL[archiving.platform]} ${archiving.version} (${archiving.build_number}) 归档？归档后客户端不会再获取该版本更新。`}
          confirmLabel="归档"
          busyLabel="归档中..."
          tone="warn"
          onClose={() => setArchiving(null)}
          onConfirm={async () => {
            await ClientVersions.patch(archiving.uuid, { ...toInput(archiving), status: 'archived' })
            notifyOk('已归档客户端版本')
            setArchiving(null)
            refresh()
          }}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title="删除客户端版本"
          description={`确认删除 ${PLATFORM_LABEL[deleting.platform] || deleting.platform} ${deleting.version} (${deleting.build_number})？删除后客户端不会再获取该版本。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await ClientVersions.delete(deleting.uuid)
            notifyOk('已删除客户端版本')
            setDeleting(null)
            refresh()
          }}
        />
      )}
      {pipelineOpen && <BuildPipelineDrawer platform={platform} onBuildCompleted={refresh} onClose={() => { setPipelineOpen(false); refresh() }} />}
    </div>
  )
}

const BUILD_STATUS_LABEL: Record<ClientBuildJob['status'], string> = {
  queued: '排队中', dispatching: '正在派发', running: '构建中', stopping: '停止中', cancelled: '已停止', succeeded: '已完成', failed: '失败',
}

const BUILD_STATUS_STYLE = {
  queued: { tone: 'info', icon: Clock3 },
  dispatching: { tone: 'info', icon: LoaderCircle },
  running: { tone: 'info', icon: LoaderCircle },
  stopping: { tone: 'warn', icon: Square },
  cancelled: { tone: undefined, icon: Square },
  succeeded: { tone: 'success', icon: CircleCheck },
  failed: { tone: 'danger', icon: CircleX },
} as const

function BuildStatusButton({ platform, onOpen, onBuildCompleted }: {
  platform: ClientVersionPlatform
  onOpen: () => void
  onBuildCompleted: () => void
}) {
  const [job, setJob] = useState<ClientBuildJob | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    let stopped = false
    let timer: number | undefined
    const completed = new Set<string>()
    const poll = async () => {
      let delay = 10000
      try {
        const response = await ClientBuildJobs.list({ platform, limit: 1 })
        if (stopped) return
        const latest = response.items?.[0] ?? null
        setJob(latest)
        setError('')
        if (latest && ['queued', 'dispatching', 'running', 'stopping'].includes(latest.status)) delay = 2000
        if (latest?.status === 'succeeded' && !completed.has(latest.uuid)) {
          completed.add(latest.uuid)
          onBuildCompleted()
        }
      } catch (e) {
        if (!stopped) setError((e as Error).message)
      } finally {
        if (!stopped) timer = window.setTimeout(poll, delay)
      }
    }
    void poll()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [platform, onBuildCompleted])
  const statusStyle = error ? { tone: 'warn' as const, icon: AlertTriangle }
    : job ? BUILD_STATUS_STYLE[job.status] : { tone: undefined, icon: TerminalSquare }
  const StatusIcon = statusStyle.icon
  const spinning = !error && (job?.status === 'dispatching' || job?.status === 'running')
  return (
    <Button variant="secondary" tone={statusStyle.tone} onClick={onOpen}
      title={error ? `构建状态获取失败：${error}` : job ? `最近构建：${job.version}（${job.build_number}）· ${BUILD_STATUS_LABEL[job.status]}` : '查看构建任务'}>
      <StatusIcon size={14} aria-hidden="true" className={spinning ? 'motion-safe:animate-spin' : undefined} />
      <span aria-live="polite">构建{error ? ' · 状态获取失败' : job ? ` · ${BUILD_STATUS_LABEL[job.status]}` : ''}</span>
    </Button>
  )
}

function BuildPipelineDrawer({ platform, onBuildCompleted, onClose }: { platform: ClientVersionPlatform; onBuildCompleted: () => void; onClose: () => void }) {
  const defaultArch: ClientVersionArch = platform === 'windows' ? 'x64' : 'arm64'
  const [jobs, setJobs] = useState<ClientBuildJob[]>([])
  const [selected, setSelected] = useState<ClientBuildJob | null>(null)
  const [logs, setLogs] = useState<ClientBuildLog[]>([])
  const lastLogSeq = useRef(0)
  const refreshedBuilds = useRef(new Set<string>())
  const [version, setVersion] = useState('')
  const [buildNumber, setBuildNumber] = useState('')
  const [arch, setArch] = useState<ClientVersionArch>(defaultArch)
  const [releaseNotes, setReleaseNotes] = useState('')
  const [forced, setForced] = useState(false)
  const [generateDelta, setGenerateDelta] = useState(false)
  const [busy, setBusy] = useState(false)
  const [stopTarget, setStopTarget] = useState<ClientBuildJob | null>(null)
  const [err, setErr] = useState('')
  const selectedUUID = selected?.uuid

  const load = async () => {
    const resp = await ClientBuildJobs.list({ platform, limit: 30 })
    setJobs(resp.items || [])
    let shouldRefreshVersions = false
    for (const job of resp.items || []) {
      if (job.status === 'succeeded' && !refreshedBuilds.current.has(job.uuid)) {
        refreshedBuilds.current.add(job.uuid)
        shouldRefreshVersions = true
      }
    }
    if (shouldRefreshVersions) onBuildCompleted()
    if (selected) {
      const current = resp.items.find((job) => job.uuid === selected.uuid)
      if (current) {
        setSelected(current)
      } else {
        setSelected(null)
        setLogs([])
        lastLogSeq.current = 0
      }
    } else {
      setSelected((current) => current ?? resp.items?.[0] ?? null)
    }
  }
  useEffect(() => {
    let stopped = false
    const tick = async () => { try { if (!stopped) await load() } catch (e) { if (!stopped) setErr((e as Error).message) } }
    void tick()
    const timer = window.setInterval(tick, 2000)
    return () => { stopped = true; window.clearInterval(timer) }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [platform, selectedUUID])
  useEffect(() => {
    if (!selectedUUID) return
    lastLogSeq.current = 0
    let stopped = false
    const tick = async () => {
      try {
        const resp = await ClientBuildJobs.logs(selectedUUID, lastLogSeq.current)
        if (!stopped && resp.items?.length) {
          lastLogSeq.current = resp.items[resp.items.length - 1].seq
          setLogs((current) => [...current, ...resp.items])
        }
      } catch (e) { if (!stopped) setErr((e as Error).message) }
    }
    void tick()
    const timer = window.setInterval(tick, 2000)
    return () => { stopped = true; window.clearInterval(timer) }
  }, [selectedUUID])

  const start = async () => {
    if (!version.trim() || !buildNumber.trim()) { setErr('请输入版本号和构建号'); return }
    const versionError = clientReleaseVersionError(version)
    if (versionError) { setErr(versionError); return }
    setBusy(true); setErr('')
    try {
      const resp = await ClientBuildJobs.create({ platform, arch, channel: 'stable', version: version.trim(), build_number: buildNumber.trim(), release_notes: releaseNotes.trim(), is_forced: forced, generate_delta: platform === 'macos' && generateDelta })
      setLogs([]); lastLogSeq.current = 0; setSelected(resp.item); await load(); notifyOk('打包任务已开始')
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }
  const retry = async (job: ClientBuildJob) => {
    setBusy(true); setErr('')
    try { const resp = await ClientBuildJobs.retry(job.uuid); setLogs([]); lastLogSeq.current = 0; setSelected(resp.item); await load(); notifyOk('已创建重试任务') }
    catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }
  const stop = async (job: ClientBuildJob) => {
    setBusy(true); setErr('')
    try {
      const resp = await ClientBuildJobs.stop(job.uuid)
      setSelected((current) => current?.uuid === job.uuid ? resp.item : current)
      setStopTarget(null)
      await load()
      notifyOk(resp.item.status === 'cancelled' ? '构建已停止' : '正在停止构建')
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  return <><DrawerShell title="客户端构建" subtitle="构建机直接执行 zhiban CLI 并上传后台/S3" icon={<TerminalSquare size={18} />} onClose={onClose} width="lg" footer={<div className="flex justify-end"><Button variant="secondary" onClick={onClose}>关闭</Button></div>}>
    <div className="space-y-5">
      {err && <InlineAlert>{err}</InlineAlert>}
      <FormSection title={`开始 ${PLATFORM_LABEL[platform]} 打包`} description={`${platform === 'windows' ? '任务将发送到 Windows 构建机。' : '任务将发送到 Mac 构建机。'} 构建环境跟随当前后台部署环境。`}>
        <div className="grid gap-3 md:grid-cols-2">
          <FormField label="版本号" required hint="次版本和修订版本各只能为 0–9，例如 1.4.9。"><Input required value={version} onChange={(e) => setVersion(e.target.value)} placeholder="1.4.9" /></FormField>
          <FormField label="构建号" required><Input required value={buildNumber} onChange={(e) => setBuildNumber(e.target.value)} placeholder="12902" /></FormField>
          <FormField label="架构"><Select value={arch} onChange={(e) => setArch(e.target.value as ClientVersionArch)}>{platform === 'macos' && <option value="universal">Universal</option>}<option value="arm64">ARM64</option>{platform !== 'ios' && platform !== 'android' && <option value="x64">x64</option>}</Select></FormField>
        </div>
        <FormField label="发布说明"><textarea className={textareaCls} value={releaseNotes} onChange={(e) => setReleaseNotes(e.target.value)} /></FormField>
        <div className="flex flex-wrap items-center gap-5 text-[13px] text-[var(--color-text)]">
          <label className="flex items-center gap-2"><input type="checkbox" checked={forced} onChange={(e) => setForced(e.target.checked)} />强制更新提示</label>
          {platform === 'macos' && <label className="flex items-center gap-2"><input type="checkbox" checked={generateDelta} onChange={(e) => setGenerateDelta(e.target.checked)} />自动生成 Delta</label>}
          <Button onClick={start} disabled={busy}><Play size={14} />{busy ? '正在提交...' : '开始任务'}</Button>
        </div>
      </FormSection>
      <FormSection title="任务记录">
        <div className="space-y-2">{jobs.length === 0 ? <div className="py-6 text-center text-[13px] text-[var(--color-text-sub)]">暂无打包任务</div> : jobs.map((job) => <div key={job.uuid} className={`flex w-full items-center gap-3 rounded-md border px-3 py-2 ${selected?.uuid === job.uuid ? 'border-[var(--color-brand)] bg-[var(--color-brand-soft)]' : 'border-[var(--color-line-soft)] bg-[var(--color-bg-sub)]'}`}>
          <button type="button" onClick={() => { if (selectedUUID === job.uuid) return; setLogs([]); lastLogSeq.current = 0; setSelected(job) }} className="min-w-0 flex-1 text-left"><span className="font-medium text-[var(--color-text)]">{job.version} ({job.build_number})</span><span className="ml-2 text-[12px] text-[var(--color-text-sub)]">第 {job.attempt} 次 · {BUILD_STATUS_LABEL[job.status]}</span>{job.error && <span className="mt-1 block truncate text-[12px] text-[var(--color-danger)]">{job.error}</span>}</button>
          {(job.status === 'queued' || job.status === 'dispatching' || job.status === 'running') && <Button variant="danger" size="sm" disabled={busy} onClick={(e) => { e.stopPropagation(); setStopTarget(job) }}><Square size={13} />停止</Button>}
          {job.status === 'stopping' && <Button variant="danger" size="sm" disabled><Square size={13} />停止中</Button>}
          {job.status === 'failed' && <Button variant="ghost" size="sm" disabled={busy} onClick={(e) => { e.stopPropagation(); void retry(job) }}><RotateCcw size={13} />重试</Button>}
        </div>)}</div>
      </FormSection>
      {selected && <FormSection title={`构建日志 · ${BUILD_STATUS_LABEL[selected.status]}`} description={selected.client_version_uuid ? `客户端版本 UUID：${selected.client_version_uuid}` : undefined}>
        <BuildLogViewer key={selected.uuid} logs={logs} />
      </FormSection>}
    </div>
  </DrawerShell>{stopTarget && <ConfirmDialog title="停止客户端构建" description={`确认停止 ${PLATFORM_LABEL[stopTarget.platform]} ${stopTarget.version} (${stopTarget.build_number}) 的构建？已产生的构建日志会保留。`} confirmLabel="停止" busyLabel="停止中..." tone="warn" onClose={() => setStopTarget(null)} onConfirm={() => stop(stopTarget)} />}</>
}

// ─── 新建版本弹框 ─────────────────────────────────────────────────────────────

function NewVersionDialog({
  platform,
  onClose,
  onCreated,
}: {
  platform: ClientVersionPlatform
  onClose: () => void
  onCreated: (item: ClientVersion) => void
}) {
  const [version, setVersion] = useState('')
  const [buildNumber, setBuildNumber] = useState('')
  const [arch, setArch] = useState<ClientVersionArch>('universal')
  const [channel, setChannel] = useState<ClientVersionChannel>('stable')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const handleConfirm = async () => {
    if (!version.trim()) { setErr('请输入版本号'); return }
    if (!buildNumber.trim()) { setErr('请输入构建号'); return }
    const versionError = clientReleaseVersionError(version)
    if (versionError) { setErr(versionError); return }
    setBusy(true)
    setErr('')
    try {
      const resp = await ClientVersions.create({
        platform,
        arch,
        channel,
        version: version.trim(),
        build_number: buildNumber.trim(),
        title: '',
        release_notes: '',
        sparkle_ed_signature: '',
        is_forced: false,
        status: 'draft',
      })
      onCreated(resp.item)
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title="新建版本"
      subtitle={`平台：${PLATFORM_LABEL[platform]}，创建后进入草稿编辑。`}
      icon={<Package size={18} />}
      onClose={onClose}
      size="sm"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={handleConfirm} disabled={busy}>
            {busy ? '创建中...' : '创建草稿'}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        <div className="grid grid-cols-2 gap-3">
          <FormField label="版本号" required hint="次版本和修订版本各只能为 0–9，例如 1.4.9。">
            <Input
              required
              value={version}
              onChange={(e) => setVersion(e.target.value)}
              placeholder="1.0.0"
              autoFocus
              onKeyDown={(e) => { if (e.key === 'Enter') handleConfirm() }}
            />
          </FormField>
          <FormField label="构建号" required>
            <Input
              required
              value={buildNumber}
              onChange={(e) => setBuildNumber(e.target.value)}
              placeholder="10018"
              onKeyDown={(e) => { if (e.key === 'Enter') handleConfirm() }}
            />
          </FormField>
          <FormField label="架构">
            <Select value={arch} onChange={(e) => setArch(e.target.value as ClientVersionArch)}>
              {Object.entries(ARCH_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </Select>
          </FormField>
          <FormField label="渠道">
            <Select value={channel} onChange={(e) => setChannel(e.target.value as ClientVersionChannel)}>
              {Object.entries(CHANNEL_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </Select>
          </FormField>
        </div>
      </div>
    </DialogShell>
  )
}

// ─── 编辑抽屉 ────────────────────────────────────────────────────────────────

function ClientVersionDrawer({
  item,
  onClose,
  onSaved,
}: {
  item: ClientVersion
  onClose: () => void
  onSaved: (updated: ClientVersion) => void
}) {
  const [form, setForm] = useState<ClientVersionInput>(() => toInput(item))
  const [saving, setSaving] = useState(false)
  const [packageUpload, setPackageUpload] = useState<UploadTaskState | null>(null)
  const [deltaUpload, setDeltaUpload] = useState<UploadTaskState | null>(null)
  const [uploadedInfo, setUploadedInfo] = useState<{ fileName: string; sha256: string; size: number } | null>(
    item.sha256 ? { fileName: '', sha256: item.sha256, size: item.file_size_bytes || 0 } : null
  )
  const [packageUploadErr, setPackageUploadErr] = useState('')
  const [deltaUploadErr, setDeltaUploadErr] = useState('')
  const [deltaURL, setDeltaURL] = useState('')
  const [deltaFrom, setDeltaFrom] = useState('')
  const [deltaSignature, setDeltaSignature] = useState('')
  const [err, setErr] = useState('')

  const set = <K extends keyof ClientVersionInput>(key: K, value: ClientVersionInput[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }))

  const uploading = packageUpload !== null || deltaUpload !== null
  const requestClose = () => {
    if (!saving && !uploading) onClose()
  }

  const handleFileSelect = async (file: File) => {
    setPackageUpload({ fileName: file.name, loaded: 0, total: file.size, percent: 0 })
    setPackageUploadErr('')
    try {
      const resp = await ClientVersions.uploadPackage(item.uuid, file, (progress) => {
        setPackageUpload({
          ...progress,
          fileName: file.name,
          total: progress.total || file.size,
        })
      })
      setUploadedInfo({ fileName: resp.file_name, sha256: resp.sha256, size: resp.size_bytes })
      // 上传已把地址、大小与 SHA-256 落库；表单一并回填，否则随后点「保存」
      // 会用表单里的旧值（新建记录为 0 / 空）把大小与哈希覆盖掉。
      setForm((prev) => ({
        ...prev,
        download_url: resp.item.download_url_raw || resp.item.download_url,
        file_size_bytes: resp.size_bytes,
        sha256: resp.sha256,
      }))
      onSaved(resp.item)
      notifyOk('安装包已上传')
    } catch (e) {
      setPackageUploadErr((e as Error).message)
    } finally {
      setPackageUpload(null)
    }
  }

  const doSave = async () => {
    setSaving(true)
    setErr('')
    try {
      const resp = await ClientVersions.patch(item.uuid, { ...form, status: item.status })
      onSaved(resp.item)
      notifyOk('已保存')
      onClose()
    } catch (e) {
      setErr((e as Error).message)
      setSaving(false)
    }
  }

  const handleDeltaSelect = async (file: File) => {
    const sourceBuild = deltaFrom.trim()
    const signature = deltaSignature.trim()
    if (!sourceBuild) {
      setDeltaUploadErr('请先填写来源构建号（delta_from）')
      return
    }
    if (!signature) {
      setDeltaUploadErr('请先填写 Delta 的 Sparkle EdDSA 签名')
      return
    }
    if (/^[a-f0-9]{64}$/i.test(signature)) {
      setDeltaUploadErr('这里需要填写 appcast 中的 sparkle:edSignature，不是 Delta 文件的 SHA-256。')
      return
    }
    if (!isValidDeltaEdSignature(signature)) {
      setDeltaUploadErr('Delta EdDSA 签名格式错误：请粘贴 generate_appcast 生成的完整 Base64 签名。')
      return
    }
    setDeltaUpload({ fileName: file.name, loaded: 0, total: file.size, percent: 0 })
    setDeltaUploadErr('')
    try {
      const resp = await ClientVersions.uploadDelta(
        item.uuid,
        file,
        sourceBuild,
        signature,
        (progress) => {
          setDeltaUpload({
            ...progress,
            fileName: file.name,
            total: progress.total || file.size,
          })
        },
      )
      setDeltaURL(resp.download_url)
      onSaved({
        ...item,
        deltas: [
          ...(item.deltas || []).filter((delta) => delta.delta_from !== resp.delta_from),
          {
            file_name: resp.file_name,
            delta_from: resp.delta_from,
            size_bytes: resp.size_bytes,
            sha256: resp.sha256,
            ed_signature: resp.ed_signature,
          },
        ],
      })
      notifyOk('Delta 已上传并写入版本 appcast 元数据')
    } catch (e) {
      setDeltaUploadErr((e as Error).message)
    } finally {
      setDeltaUpload(null)
    }
  }

  return (
    <DrawerShell
      title="编辑客户端版本"
      subtitle={`${PLATFORM_LABEL[item.platform]} ${item.version} (${item.build_number}) · ${STATUS_LABEL[item.status]}`}
      icon={<Package size={18} />}
      onClose={requestClose}
      width="lg"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={requestClose} disabled={saving || uploading}>关闭</Button>
          <Button onClick={doSave} disabled={saving || uploading}>
            {saving ? '保存中...' : '保存'}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}

        <FormSection title="版本信息">
          <div className="grid gap-4 md:grid-cols-2">
            <FormField label="架构">
              <Select value={form.arch} onChange={(e) => set('arch', e.target.value as ClientVersionArch)}>
                {Object.entries(ARCH_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </FormField>
            <FormField label="渠道">
              <Select value={form.channel} onChange={(e) => set('channel', e.target.value as ClientVersionChannel)}>
                {Object.entries(CHANNEL_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </Select>
            </FormField>
          </div>
        </FormSection>

        {item.platform === 'macos' && (
          <FormSection title="Sparkle 增量包（Delta）" description="上传由 Sparkle generate_appcast 生成的 .delta，并填写同一 enclosure 中的 deltaFrom 与 EdDSA 签名；Bus appcast 会自动输出该元数据。">
            <div className="mb-3 grid gap-3 md:grid-cols-2">
              <FormField label="来源构建号" hint="必须与旧版 CFBundleVersion 完全一致，例如 12102。">
                <Input
                  value={deltaFrom}
                  onChange={(e) => setDeltaFrom(e.target.value)}
                  placeholder="12102"
                  inputMode="numeric"
                />
              </FormField>
              <FormField label="Delta EdDSA 签名" hint="复制 generate_appcast 生成的 delta enclosure 中 sparkle:edSignature。">
                <Input
                  value={deltaSignature}
                  onChange={(e) => setDeltaSignature(e.target.value)}
                  placeholder="粘贴 Delta 的 sparkle:edSignature"
                />
              </FormField>
            </div>
            <FileUploadPicker
              title="上传 Delta"
              description="仅支持由 Sparkle BinaryDelta / generate_appcast 生成并签名的 .delta 文件。"
              accept=".delta,application/octet-stream"
              busy={deltaUpload !== null}
              disabled={packageUpload !== null}
              busyLabel="Delta 上传中..."
              onSelect={handleDeltaSelect}
            />
            {deltaUpload && (
              <div className="mt-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-3">
                <ProgressBar value={deltaUpload.loaded} max={deltaUpload.total} label={deltaUpload.fileName} />
                <div className="mt-1.5 text-[11px] tabular-nums text-[var(--color-text-sub)]">{uploadProgressText(deltaUpload)}</div>
              </div>
            )}
            {deltaUploadErr && <div className="mt-2 text-[12px] text-[var(--color-danger)]">{deltaUploadErr}</div>}
            {deltaURL && <Input className="mt-3 font-mono text-[12px]" value={deltaURL} readOnly onFocus={(e) => e.currentTarget.select()} aria-label="Delta 下载地址" />}
            {!!item.deltas?.length && (
              <div className="mt-3 space-y-2">
                {item.deltas.map((delta) => (
                  <div key={`${delta.delta_from}-${delta.file_name}`} className="rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
                    <span className="font-medium text-[var(--color-text)]">来源构建 {delta.delta_from}</span>
                    <span className="mx-2">·</span>{delta.file_name}
                    <span className="mx-2">·</span>{formatFileSize(delta.size_bytes)}
                  </div>
                ))}
              </div>
            )}
          </FormSection>
        )}

        <FormSection
          title={needsInstallerPackage(item.platform) ? '安装包' : '发布设置'}
          description={needsInstallerPackage(item.platform)
            ? '选择文件后立即上传到 OSS，无需等待保存。'
            : 'iOS 安装包由 App Store Connect 托管，此处无需上传。'}
        >
          {needsInstallerPackage(item.platform) && (
            <>
              <FileUploadPicker
                title="上传安装包"
                description="支持 DMG / PKG / ZIP / EXE / APK。"
                accept=".dmg,.pkg,.zip,.exe,.apk,application/octet-stream,application/zip,application/x-apple-diskimage,application/vnd.android.package-archive"
                busy={packageUpload !== null}
                disabled={deltaUpload !== null}
                busyLabel="安装包上传中..."
                onSelect={handleFileSelect}
              />
              {packageUpload && (
                <div className="mt-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-3">
                  <ProgressBar value={packageUpload.loaded} max={packageUpload.total} label={packageUpload.fileName} />
                  <div className="mt-1.5 text-[11px] tabular-nums text-[var(--color-text-sub)]">{uploadProgressText(packageUpload)}</div>
                </div>
              )}
              {packageUploadErr && <div className="mt-2 text-[12px] text-[var(--color-danger)]">{packageUploadErr}</div>}
              {uploadedInfo && (
                <div className="mt-3 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
                  <span className="font-medium text-[var(--color-text)]">已上传</span>
                  {uploadedInfo.fileName && <><span className="mx-2">·</span>{uploadedInfo.fileName}</>}
                  <span className="mx-2">·</span>
                  {formatFileSize(uploadedInfo.size)}
                  {uploadedInfo.sha256 && (
                    <>
                      <span className="mx-2">·</span>
                      <span className="font-mono">SHA256: {uploadedInfo.sha256.slice(0, 16)}…</span>
                    </>
                  )}
                </div>
              )}
            </>
          )}
          <label className="mt-4 flex items-center gap-2 text-[13px] text-[var(--color-text)]">
            <input
              type="checkbox"
              checked={!!form.is_forced}
              onChange={(e) => set('is_forced', e.target.checked)}
            />
            强制更新提示
          </label>
        </FormSection>

        {needsSparkleSignature(item.platform) && (
          <FormSection title="EdDSA 签名" description="macOS / Windows 安装包的 Sparkle EdDSA 签名，由本地 sign_update 工具生成。">
            <Input
              value={form.sparkle_ed_signature || ''}
              onChange={(e) => set('sparkle_ed_signature', e.target.value)}
              placeholder="粘贴 sign_update 输出的签名"
            />
          </FormSection>
        )}

        <FormSection title="发布说明">
          <FormField label="标题">
            <Input value={form.title || ''} onChange={(e) => set('title', e.target.value)} placeholder="留空则用版本号" />
          </FormField>
          <textarea
            value={form.release_notes || ''}
            onChange={(e) => set('release_notes', e.target.value)}
            className={`${textareaCls} mt-3`}
            placeholder="输入本版本变更说明"
          />
        </FormSection>
      </div>
    </DrawerShell>
  )
}

// ─── 工具函数 ─────────────────────────────────────────────────────────────────

function toInput(item: ClientVersion): ClientVersionInput {
  return {
    platform: item.platform,
    arch: item.arch,
    channel: item.channel,
    version: item.version,
    build_number: item.build_number,
    title: item.title,
    release_notes: item.release_notes,
    download_url: item.download_url_raw || item.download_url,
    appcast_url: item.appcast_url_raw || item.appcast_url,
    sparkle_ed_signature: item.sparkle_ed_signature,
    file_size_bytes: item.file_size_bytes || 0,
    sha256: item.sha256,
    min_os_version: item.min_os_version,
    min_supported_version: item.min_supported_version,
    is_forced: item.is_forced,
    status: item.status,
  }
}

function Badge({ children, className }: { children: ReactNode; className: string }) {
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-[12px] font-medium ${className}`}>{children}</span>
}

function formatTime(value?: string) {
  if (!value) return '-'
  try {
    return new Date(value).toLocaleString('zh-CN', { hour12: false })
  } catch {
    return value
  }
}
