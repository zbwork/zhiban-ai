import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Archive, Check, CloudUpload, Download, Edit3, Link2, Plus, Radar, RefreshCw, RotateCcw, SendHorizontal, TerminalSquare, Trash2, X } from 'lucide-react'

import {
  LocalCodingToolVersions,
  type LocalCodingAutoSyncResult,
  type LocalCodingAutoSyncStatus,
  type LocalCodingToolArch,
  type LocalCodingToolLayout,
  type LocalCodingToolPlatform,
  type LocalCodingToolTarget,
  type LocalCodingToolVersion,
  type LocalCodingToolVersionInput,
  type LocalCodingToolVersionStatus,
  Tenants,
  type Tenant,
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
  SearchInput,
  Select,
  stickyRightTdCls,
  Tabs,
  Toolbar,
} from '../components/ui'
import { FileUploadPicker } from '../components/form/FileUploadPicker'

// 本地开发工具版本目录：平台维护 Codex / Claude 的工具包版本，发布后由 Bus 签名下发给桌面端。
// 设计与状态流转见 docs/features/F31-local-coding-tools-version-catalog-plan.md。

type PlatformTab = LocalCodingToolPlatform

const PLATFORM_TABS: Array<{ value: PlatformTab; label: string }> = [
  { value: 'macos', label: 'macOS' },
  { value: 'windows', label: 'Windows' },
]

const PLATFORM_LABEL: Record<LocalCodingToolPlatform, string> = { macos: 'macOS', windows: 'Windows' }

const TARGET_LABEL: Record<LocalCodingToolTarget, string> = {
  codex_cli: 'Codex CLI',
  claude_cli: 'Claude Code',
  codex_desktop: 'Codex 桌面端',
  claude_desktop: 'Claude 桌面端',
  claude_code_host: 'Claude 桌面端运行组件',
}

// 架构按平台用用户熟悉的叫法：macOS 分 Apple 芯片 / Intel，Windows 仍按 x64 / ARM64。
const ARCH_ORDER: LocalCodingToolArch[] = ['arm64', 'x64', 'universal']
function archLabel(platform: LocalCodingToolPlatform, arch: LocalCodingToolArch): string {
  if (platform === 'macos') {
    return arch === 'arm64' ? 'Apple 芯片' : arch === 'x64' ? 'Intel' : '通用（Apple 芯片 + Intel）'
  }
  return arch === 'arm64' ? 'ARM64' : arch === 'x64' ? 'x64' : '通用'
}

const LAYOUT_LABEL: Record<LocalCodingToolLayout, string> = {
  tarball_single: 'tar.gz（单文件）',
  tarball_member: 'tar.gz / tgz（取包内成员）',
  tarball_tree: 'tgz（整棵包目录，Codex）',
  bare_binary: '裸二进制',
  app_bundle_zip: '应用 zip（macOS）',
  app_bundle_dmg: '应用 DMG（macOS）',
  msix: 'MSIX 安装包（Windows 桌面端）',
  host_binary_npm_tgz: '运行组件 npm tgz',
  host_bundle_tar_zst: '运行组件 tar.zst',
}

// Windows 桌面端只能是 MSIX，macOS 桌面端不能是；其余布局跟平台无关。
function layoutOptions(platform: LocalCodingToolPlatform, target: LocalCodingToolTarget): LocalCodingToolLayout[] {
  const all = Object.keys(LAYOUT_LABEL) as LocalCodingToolLayout[]
  if (isDesktop(target)) {
    return platform === 'windows' ? ['msix'] : all.filter((l) => l !== 'msix' && l !== 'tarball_tree')
  }
  return all.filter((l) => l !== 'msix' && (l !== 'tarball_tree' || target === 'codex_cli'))
}

const STATUS_LABEL: Record<LocalCodingToolVersionStatus, string> = {
  draft: '草稿',
  canary: '灰度中',
  current: '当前版本',
  previous: '上一版本',
  deprecated: '已下线',
}

const STATUS_TONE: Record<LocalCodingToolVersionStatus, string> = {
  draft: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
  canary: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  current: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  previous: 'bg-[var(--color-line-soft)] text-[var(--color-text)]',
  deprecated: 'bg-[var(--color-line-soft)] text-[var(--color-text-mute)]',
}

const textareaCls = 'min-h-[96px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-5 text-[var(--color-text)] outline-none focus:border-[var(--color-primary)]'

function isCli(target: LocalCodingToolTarget) {
  return target === 'codex_cli' || target === 'claude_cli'
}

function isDesktop(target: LocalCodingToolTarget) {
  return target === 'codex_desktop' || target === 'claude_desktop'
}

function formatFileSize(bytes: number): string {
  if (bytes <= 0) return '-'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function formatTime(value?: string) {
  if (!value) return '-'
  try {
    return new Date(value).toLocaleString('zh-CN', { hour12: false })
  } catch {
    return value
  }
}

function hasPackage(item: LocalCodingToolVersion) {
  return !!item.storage_uri && item.file_size_bytes > 0 && !!item.sha256
}

// ─── 灰度租户：按名称选，按"名称（ID）"显示 ───────────────────────────────────

const tenantNameCache = new Map<number, string>()

function tenantLabel(id: number, names: Record<number, string>): string {
  const name = names[id]
  return name ? `${name}（${id}）` : `租户 ${id}`
}

/** 解析一组租户 ID 的名称；模块级缓存，同一 ID 只请求一次。 */
function useTenantNames(ids: number[]): Record<number, string> {
  const key = Array.from(new Set(ids)).sort((a, b) => a - b).join(',')
  // 名称从缓存里派生；缓存补齐后 bump 一次触发重算。
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    const missing = (key ? key.split(',').map(Number) : []).filter((id) => !tenantNameCache.has(id))
    if (missing.length === 0) return
    let cancelled = false
    Promise.all(
      missing.map((id) =>
        Tenants.get(id)
          .then((t) => { tenantNameCache.set(id, t.DisplayName || t.Name || '') })
          .catch(() => { tenantNameCache.set(id, '') }),
      ),
    ).then(() => { if (!cancelled) setRevision((r) => r + 1) })
    return () => { cancelled = true }
  }, [key])
  return useMemo(() => {
    const next: Record<number, string> = {}
    ;(key ? key.split(',').map(Number) : []).forEach((id) => {
      const name = tenantNameCache.get(id)
      if (name) next[id] = name
    })
    return next
    // revision 只用于在缓存补齐后重算
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, revision])
}

/** 灰度租户选择器：搜索租户名称加入，或直接输入 ID 回车；已选以标签显示。 */
function TenantPicker({ value, onChange }: { value: number[]; onChange: (ids: number[]) => void }) {
  const [q, setQ] = useState('')
  const [results, setResults] = useState<Tenant[]>([])
  const [searching, setSearching] = useState(false)
  const names = useTenantNames(value)

  useEffect(() => {
    const keyword = q.trim()
    let cancelled = false
    // 状态更新都放在定时器回调里（防抖），不在 effect 体内同步 setState。
    const timer = setTimeout(() => {
      if (cancelled) return
      if (!keyword || /^\d+$/.test(keyword)) { setResults([]); setSearching(false); return }
      setSearching(true)
      Tenants.list('', keyword, 10, 0)
        .then((resp) => { if (!cancelled) setResults(resp.items || []) })
        .catch(() => { if (!cancelled) setResults([]) })
        .finally(() => { if (!cancelled) setSearching(false) })
    }, keyword ? 300 : 0)
    return () => { cancelled = true; clearTimeout(timer) }
  }, [q])

  const addID = (id: number) => {
    if (!value.includes(id)) onChange([...value, id])
    setQ('')
    setResults([])
  }
  const addTenant = (t: Tenant) => {
    tenantNameCache.set(t.ID, t.DisplayName || t.Name || '')
    addID(t.ID)
  }

  return (
    <div className="space-y-2">
      {value.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {value.map((id) => (
            <span key={id} className="inline-flex items-center gap-1 rounded-md bg-[var(--color-line-soft)] px-2 py-0.5 text-[12px] text-[var(--color-text)]">
              {tenantLabel(id, names)}
              <button
                type="button"
                className="text-[var(--color-text-mute)] hover:text-[var(--color-text)]"
                onClick={() => onChange(value.filter((v) => v !== id))}
                aria-label="移除租户"
              >
                <X size={12} />
              </button>
            </span>
          ))}
        </div>
      )}
      <Input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="输入租户名称搜索；知道 ID 也可直接输入后回车"
        autoFocus
        onKeyDown={(e) => {
          if (e.key !== 'Enter') return
          const n = Number(q.trim())
          if (Number.isInteger(n) && n > 0) { e.preventDefault(); addID(n) }
        }}
      />
      {(results.length > 0 || searching) && (
        <div className="max-h-48 overflow-auto rounded-md border border-[var(--color-line)] bg-[var(--color-surface)]">
          {searching && results.length === 0 && (
            <div className="px-3 py-2 text-[12px] text-[var(--color-text-mute)]">搜索中...</div>
          )}
          {results.map((t) => (
            <button
              type="button"
              key={t.ID}
              className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-[13px] hover:bg-[var(--color-line-soft)]"
              onClick={() => addTenant(t)}
            >
              <span className="truncate">{t.DisplayName || t.Name}</span>
              <span className="shrink-0 font-mono text-[12px] text-[var(--color-text-mute)]">{t.Slug} · {t.ID}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// 上一轮自动同步的结果：有录入或失败才值得占一行，全是"已是最新"就一句话带过。
function AutoSyncReportAlert({ results, finishedAt }: { results: LocalCodingAutoSyncResult[]; finishedAt: string }) {
  const label = (r: LocalCodingAutoSyncResult) => `${TARGET_LABEL[r.target_id] || r.target_id} ${archLabel(r.platform, r.arch)} ${r.version}`.trim()
  const failed = results.filter((r) => r.outcome === 'failed')
  const recorded = results.filter((r) => r.outcome === 'recorded' || r.outcome === 'published_canary' || r.outcome === 'published_current')
  const waiting = results.filter((r) => r.outcome === 'skipped_too_new')
  const disabled = results.filter((r) => r.outcome === 'skipped_disabled')
  const at = new Date(finishedAt).toLocaleString()
  return (
    <div className="mb-3">
      <InlineAlert tone={failed.length > 0 ? 'warn' : recorded.length > 0 ? 'success' : 'info'}>
        <div>上次检查新版本（{at}，仅本实例）：录入 {recorded.length} 个，失败 {failed.length} 个，未启用 {disabled.length} 个。</div>
        {recorded.map((r) => (
          <div key={`ok-${r.target_id}-${r.platform}-${r.arch}`}>
            · {label(r)}：{r.outcome === 'published_current' ? `已全量发布${r.detail ? `（${r.detail}）` : ''}` : r.outcome === 'published_canary' ? '已录入并灰度' : `已录入为草稿${r.detail ? `（${r.detail}）` : ''}`}
          </div>
        ))}
        {waiting.length > 0 && <div>· {label(waiting[0])} 等 {waiting.length} 个：{waiting[0].detail || '发布时间未满，暂不收'}</div>}
        {disabled.map((r) => <div key={`disabled-${r.target_id}-${r.platform}-${r.arch}`}>· {label(r)}：{r.detail}</div>)}
        {failed.map((r) => (
          <div key={`bad-${r.target_id}-${r.platform}-${r.arch}`}>· {label(r)}：失败，{r.detail}</div>
        ))}
      </InlineAlert>
    </div>
  )
}

// 包在第三方外链上（npm 镜像 / GitHub 代理等）而不是平台对象存储。
function isExternalPackage(item: LocalCodingToolVersion) {
  return item.storage_uri.startsWith('https://')
}

// 分享链接（CDN 过渡）：服务端对已发布的对象存储包定时生成网盘分享地址，剩余不足 10 天重生成；
// 版本目录只下发剩余超过 7 天的 https 链接，其余情况回退服务端下载地址。这里只展示，不提供手动操作。
function shareLinkStatus(item: LocalCodingToolVersion): { label: string; cls: string; title: string } | null {
  const published = item.status === 'canary' || item.status === 'current' || item.status === 'previous'
  if (!published || !hasPackage(item) || !item.storage_uri.startsWith('oss://')) return null
  if (!item.share_url || !item.share_expires_at) {
    return { label: '未生成', cls: 'text-[var(--color-text-mute)]', title: '发布后由服务端在 10 分钟内生成；持续未生成请查服务端日志' }
  }
  const remainingDays = (new Date(item.share_expires_at).getTime() - Date.now()) / 86_400_000
  const until = formatTime(item.share_expires_at)
  if (remainingDays <= 0) {
    return { label: '已过期', cls: 'text-[var(--color-danger)]', title: `${item.share_url}
目录已改发服务端下载地址，等待重生成` }
  }
  if (!item.share_url.startsWith('https://')) {
    return { label: `非 https · 有效至 ${until}`, cls: 'text-[var(--color-warn)]', title: `${item.share_url}
目录不会下发非 https 地址（对象存储 / 网盘无 TLS 的环境属正常）` }
  }
  if (remainingDays <= 7) {
    return { label: `即将到期 · ${until}`, cls: 'text-[var(--color-warn)]', title: `${item.share_url}
剩余不足 7 天，目录已改发服务端下载地址，等待重生成` }
  }
  return { label: `有效至 ${until}`, cls: 'text-[var(--color-success)]', title: item.share_url }
}

function ShareLinkCell({ item }: { item: LocalCodingToolVersion }) {
  const share = shareLinkStatus(item)
  if (!share) return <span className="text-[12px] text-[var(--color-text-mute)]">-</span>
  return <span className={`text-[12px] ${share.cls}`} title={share.title}>{share.label}</span>
}

function canPublish(item: LocalCodingToolVersion) {
  return (item.status === 'draft' || item.status === 'canary') && hasPackage(item)
}

// 平台级回滚：上一版本 / 已下线的版本重新设为所有租户的当前版本。
function canRollback(item: LocalCodingToolVersion) {
  return (item.status === 'previous' || item.status === 'deprecated') && hasPackage(item)
}

export function LocalCodingToolVersionsPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const platform = (searchParams.get('platform') || 'macos') as PlatformTab

  const [items, setItems] = useState<LocalCodingToolVersion[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [keyword, setKeyword] = useState('')
  const [target, setTarget] = useState('')
  const [status, setStatus] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<LocalCodingToolVersion | null>(null)
  const [publishing, setPublishing] = useState<LocalCodingToolVersion | null>(null)
  const [rollingBack, setRollingBack] = useState<LocalCodingToolVersion | null>(null)
  const [deprecating, setDeprecating] = useState<LocalCodingToolVersion | null>(null)
  const [deleting, setDeleting] = useState<LocalCodingToolVersion | null>(null)

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
    LocalCodingToolVersions.list({
      q: keyword || undefined,
      platform: platform || undefined,
      target_id: target || undefined,
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
  }, [keyword, platform, target, status, page, pageSize, tick])

  const summary = useMemo(() => `共 ${total} 个版本`, [total])
  const canaryIDs = useMemo(() => items.flatMap((item) => item.status === 'canary' ? item.canary_tenant_ids : []), [items])
  const tenantNames = useTenantNames(canaryIDs)
  const resetPage = (fn: () => void) => { setPage(1); fn() }
  const refresh = () => setTick((v) => v + 1)

  const download = (item: LocalCodingToolVersion) => {
    LocalCodingToolVersions.downloadPackage(item.uuid)
      .then((resp) => window.open(resp.download_url, '_blank', 'noopener,noreferrer'))
      .catch((e: Error) => notifyError(e.message))
  }

  // 有外链包正在搬入对象存储时每 5 秒刷新一次列表。
  const mirroring = items.some((item) => item.mirror_state === 'running')
  useEffect(() => {
    if (!mirroring) return
    const timer = setInterval(() => { refresh() }, 5000)
    return () => clearInterval(timer)
  }, [mirroring])
  const mirror = async (item: LocalCodingToolVersion) => {
    try {
      await LocalCodingToolVersions.mirrorPackage(item.uuid)
      notifyOk(`已开始搬入 ${TARGET_LABEL[item.target_id]} ${item.version} 的包`)
      refresh()
    } catch (e) {
      notifyError((e as Error).message)
    }
  }
  // 工具版本自动同步：未开启时不显示入口；一轮在后台跑，跑着的时候每 5 秒看一次结果并刷新列表。
  const [autoSync, setAutoSync] = useState<LocalCodingAutoSyncStatus | null>(null)
  useEffect(() => {
    let cancelled = false
    LocalCodingToolVersions.autoSyncStatus()
      .then((resp) => { if (!cancelled) setAutoSync(resp.status) })
      .catch(() => { if (!cancelled) setAutoSync(null) })
    return () => { cancelled = true }
  }, [tick])
  const autoSyncRunning = autoSync?.running === true
  useEffect(() => {
    if (!autoSyncRunning) return
    const timer = setInterval(() => { refresh() }, 5000)
    return () => clearInterval(timer)
  }, [autoSyncRunning])
  const startAutoSync = async () => {
    try {
      const resp = await LocalCodingToolVersions.startAutoSync()
      setAutoSync(resp.status)
      notifyOk('已开始检查新版本，有新版会自动录入、上传并全量发布')
      refresh()
    } catch (e) {
      notifyError((e as Error).message)
    }
  }
  const externalItems = items.filter((item) => isExternalPackage(item) && item.mirror_state !== 'running')
  const mirrorAll = async () => {
    for (const item of externalItems) {
      try { await LocalCodingToolVersions.mirrorPackage(item.uuid) } catch (e) { notifyError(`${TARGET_LABEL[item.target_id]} ${item.version}：${(e as Error).message}`) }
    }
    notifyOk(`已开始搬入 ${externalItems.length} 个外链包`)
    refresh()
  }

  return (
    <div>
      <PageHeader
        title="本地开发工具版本"
        subtitle="维护 Codex / Claude 命令行与桌面端的工具包版本；发布后桌面端按租户拿到签名目录，可升级或回退。"
      />

      <div className="mb-4">
        <Tabs<PlatformTab> value={platform} items={PLATFORM_TABS} onChange={setPlatform} />
      </div>

      <Toolbar
        search={
          <SearchInput
            value={keyword}
            onChange={(v) => resetPage(() => setKeyword(v))}
            placeholder="搜索版本号 / 发布说明"
          />
        }
        filters={
          <>
            <div className="w-[180px]">
              <Select value={target} onChange={(e) => resetPage(() => setTarget(e.target.value))}>
                <option value="">全部工具</option>
                {Object.entries(TARGET_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
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
            <Button variant="secondary" onClick={refresh} title="刷新" aria-label="刷新工具版本">
              <RefreshCw size={14} />
            </Button>
            {autoSync?.enabled && (
              <Button variant="secondary" onClick={startAutoSync} disabled={autoSyncRunning} title="检查 Codex / Claude 命令行和桌面端新版；检查来源与包信息后录入、上传并全量发布，无需人工确认">
                <Radar size={14} />
                {autoSyncRunning ? '检查中…' : '立即检查新版本'}
              </Button>
            )}
            <Button variant="secondary" onClick={mirrorAll} disabled={externalItems.length === 0} title="把当前列表里所有外链包复制进平台对象存储">
              <CloudUpload size={14} />
              搬入全部外链{externalItems.length > 0 ? `（${externalItems.length}）` : ''}
            </Button>
            <Button onClick={() => setCreating(true)}>
              <Plus size={14} />
              新建 {PLATFORM_LABEL[platform]} 版本
            </Button>
          </>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}
      {autoSync?.enabled && (
        <InlineAlert tone="info">自动检查命令行和桌面端官方新版，检查通过并上传成功后自动全量发布。发行者签名由客户端安装时校验。</InlineAlert>
      )}
      {autoSync?.enabled && autoSync.last_report && !autoSyncRunning && (
        <AutoSyncReportAlert results={autoSync.last_report.results} finishedAt={autoSync.last_report.finished_at} />
      )}

      <DataTable
        headers={['工具', '版本', '架构', '包布局', '包', '分享链接', '状态', '灰度租户', '发布时间', '操作']}
        stickyLastCol
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载工具版本</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<TerminalSquare size={20} />}
            title="暂无工具版本"
            description="新建草稿、上传发行方的安装包并填写合同检查记录后即可发布。"
          />
        ) : undefined}
      >
        {!loading && items.map((item) => (
          <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
            <td className="whitespace-nowrap px-4 py-3 font-medium text-[var(--color-text)]">
              {TARGET_LABEL[item.target_id] || item.target_id}
            </td>
            <td className="whitespace-nowrap px-4 py-3 font-mono text-[var(--color-text)]">
              {item.version}
              {item.auto_synced && (
                <span className="ml-2 rounded bg-[var(--color-info-bg)] px-1.5 py-0.5 font-sans text-[11px] text-[var(--color-info)]" title={item.contract_check_ref}>
                  自动
                </span>
              )}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{archLabel(item.platform, item.arch)}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{LAYOUT_LABEL[item.layout] || item.layout}</td>
            <td className="whitespace-nowrap px-4 py-3">
              {hasPackage(item) ? (
                <div className="flex items-center gap-2">
                  <span className="inline-flex items-center gap-1 text-[12px] font-medium text-[var(--color-success)]">
                    <Check size={12} />
                    已上传
                    <span className="ml-1 text-[var(--color-text-mute)]">({formatFileSize(item.file_size_bytes)})</span>
                  </span>
                  {isExternalPackage(item) && (
                    <span className="inline-flex items-center gap-1 rounded bg-[var(--color-warn-bg)] px-1.5 py-0.5 text-[11px] text-[var(--color-warn)]" title={item.storage_uri}>
                      <Link2 size={11} />
                      外链
                    </span>
                  )}
                  {isExternalPackage(item) && item.mirror_state === 'running' && (
                    <span className="text-[11px] text-[var(--color-text-mute)]">搬入中…</span>
                  )}
                  {isExternalPackage(item) && item.mirror_state === 'failed' && (
                    <span className="text-[11px] text-[var(--color-danger)]" title={item.mirror_error || '搬入失败'}>搬入失败</span>
                  )}
                  {isExternalPackage(item) && item.mirror_state !== 'running' && (
                    <Button variant="ghost" size="sm" onClick={() => mirror(item)} title="搬入对象存储" aria-label="搬入对象存储">
                      <CloudUpload size={14} />
                    </Button>
                  )}
                  <Button variant="ghost" size="sm" onClick={() => download(item)} title="下载包" aria-label="下载工具包">
                    <Download size={14} />
                  </Button>
                </div>
              ) : (
                <span className="text-[12px] text-[var(--color-text-mute)]">未上传</span>
              )}
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              <ShareLinkCell item={item} />
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              <Badge className={STATUS_TONE[item.status]}>{STATUS_LABEL[item.status] || item.status}</Badge>
            </td>
            <td className="max-w-[200px] px-4 py-3 text-[var(--color-text-sub)]">
              {item.status === 'canary' && item.canary_tenant_ids.length > 0 ? (
                <span className="text-[12px]" title={item.canary_tenant_ids.map((id) => tenantLabel(id, tenantNames)).join('、')}>
                  {item.canary_tenant_ids.slice(0, 3).map((id) => tenantLabel(id, tenantNames)).join('、')}
                  {item.canary_tenant_ids.length > 3 ? ` 等 ${item.canary_tenant_ids.length} 个` : ''}
                </span>
              ) : '-'}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.published_at)}</td>
            <td className={`whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
              <div className="flex items-center gap-1">
                {canPublish(item) && (
                  <Button variant="ghost" size="sm" onClick={() => setPublishing(item)} title={item.status === 'canary' ? '发布 / 全量' : '发布'} aria-label="发布工具版本">
                    <SendHorizontal size={14} />
                  </Button>
                )}
                {canRollback(item) && (
                  <Button variant="ghost" size="sm" onClick={() => setRollingBack(item)} title="回滚到此版本" aria-label="回滚到此版本">
                    <RotateCcw size={14} />
                  </Button>
                )}
                {(item.status === 'canary' || item.status === 'current' || item.status === 'previous') && (
                  <Button variant="ghost" size="sm" onClick={() => setDeprecating(item)} title="下线" aria-label="下线工具版本">
                    <Archive size={14} />
                  </Button>
                )}
                <Button variant="ghost" size="sm" onClick={() => setEditing(item)} title={item.status === 'draft' ? '编辑' : '查看'} aria-label="编辑工具版本">
                  <Edit3 size={14} />
                </Button>
                {(item.status === 'draft' || item.status === 'deprecated') && (
                  <Button variant="ghost" size="sm" onClick={() => setDeleting(item)} title="删除" aria-label="删除工具版本">
                    <Trash2 size={14} />
                  </Button>
                )}
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
        <VersionDrawer
          item={editing}
          onClose={() => { setEditing(null); refresh() }}
          onSaved={(updated) => setEditing(updated)}
        />
      )}

      {publishing && (
        <PublishDialog
          item={publishing}
          onClose={() => setPublishing(null)}
          onPublished={() => { setPublishing(null); refresh() }}
        />
      )}
      {rollingBack && (
        <PublishDialog
          item={rollingBack}
          rollback
          onClose={() => setRollingBack(null)}
          onPublished={() => { setRollingBack(null); refresh() }}
        />
      )}

      {deprecating && (
        <ConfirmDialog
          title="下线工具版本"
          description={`确认下线 ${TARGET_LABEL[deprecating.target_id]} ${deprecating.version}（${PLATFORM_LABEL[deprecating.platform]} / ${archLabel(deprecating.platform, deprecating.arch)}）？下线后桌面端不再拿到该版本，已安装的机器不受影响。`}
          confirmLabel="下线"
          busyLabel="下线中..."
          tone="warn"
          onClose={() => setDeprecating(null)}
          onConfirm={async () => {
            await LocalCodingToolVersions.deprecate(deprecating.uuid)
            notifyOk('已下线工具版本')
            setDeprecating(null)
            refresh()
          }}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title="删除工具版本"
          description={`确认删除 ${TARGET_LABEL[deleting.target_id]} ${deleting.version}（${PLATFORM_LABEL[deleting.platform]} / ${archLabel(deleting.platform, deleting.arch)}）？只有草稿和已下线版本可以删除。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await LocalCodingToolVersions.delete(deleting.uuid)
            notifyOk('已删除工具版本')
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

// ─── 新建版本弹框 ─────────────────────────────────────────────────────────────

function NewVersionDialog({
  platform,
  onClose,
  onCreated,
}: {
  platform: LocalCodingToolPlatform
  onClose: () => void
  onCreated: (item: LocalCodingToolVersion) => void
}) {
  const [target, setTarget] = useState<LocalCodingToolTarget>('codex_cli')
  const [arch, setArch] = useState<LocalCodingToolArch>('arm64')
  const [version, setVersion] = useState('')
  const [layout, setLayout] = useState<LocalCodingToolLayout>('tarball_single')
  const layouts = layoutOptions(platform, target)
  const chooseTarget = (next: LocalCodingToolTarget) => {
    setTarget(next)
    const allowed = layoutOptions(platform, next)
    if (!allowed.includes(layout)) setLayout(allowed[0])
  }
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const handleConfirm = async () => {
    if (!version.trim()) { setErr('请输入发行方版本号'); return }
    setBusy(true)
    setErr('')
    try {
      const resp = await LocalCodingToolVersions.create({
        target_id: target,
        platform,
        arch,
        version: version.trim(),
        layout,
      })
      onCreated(resp.item)
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title="新建工具版本"
      subtitle={`平台：${PLATFORM_LABEL[platform]}，创建后进入草稿编辑并上传包。`}
      icon={<TerminalSquare size={18} />}
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
          <FormField label="工具">
            <Select value={target} onChange={(e) => chooseTarget(e.target.value as LocalCodingToolTarget)}>
              {Object.entries(TARGET_LABEL).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </Select>
          </FormField>
          <FormField label="架构">
            <Select value={arch} onChange={(e) => setArch(e.target.value as LocalCodingToolArch)}>
              {ARCH_ORDER.map((value) => <option key={value} value={value}>{archLabel(platform, value)}</option>)}
            </Select>
          </FormField>
          <FormField label="发行方版本号">
            <Input
              value={version}
              onChange={(e) => setVersion(e.target.value)}
              placeholder="0.154.0"
              autoFocus
              onKeyDown={(e) => { if (e.key === 'Enter') handleConfirm() }}
            />
          </FormField>
          <FormField label="包布局">
            <Select value={layout} onChange={(e) => setLayout(e.target.value as LocalCodingToolLayout)}>
              {layouts.map((value) => <option key={value} value={value}>{LAYOUT_LABEL[value]}</option>)}
            </Select>
          </FormField>
        </div>
      </div>
    </DialogShell>
  )
}

// ─── 编辑抽屉 ────────────────────────────────────────────────────────────────

function VersionDrawer({
  item,
  onClose,
  onSaved,
}: {
  item: LocalCodingToolVersion
  onClose: () => void
  onSaved: (updated: LocalCodingToolVersion) => void
}) {
  const editable = item.status === 'draft'
  // 已发布但包还是外链：允许补传同一个文件（服务端核对大小与 SHA-256 后替换为对象存储）。
  const canReplacePackage = editable || isExternalPackage(item)
  const [form, setForm] = useState<LocalCodingToolVersionInput>(() => toInput(item))
  const [saving, setSaving] = useState(false)
  const [uploading, setUploading] = useState(false)
  const [uploaded, setUploaded] = useState<{ sha256: string; size: number } | null>(
    hasPackage(item) ? { sha256: item.sha256, size: item.file_size_bytes } : null,
  )
  const [uploadErr, setUploadErr] = useState('')
  const [err, setErr] = useState('')

  const set = <K extends keyof LocalCodingToolVersionInput>(key: K, value: LocalCodingToolVersionInput[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }))

  const handleFileSelect = async (file: File) => {
    setUploading(true)
    setUploadErr('')
    try {
      const resp = await LocalCodingToolVersions.uploadPackage(item.uuid, file)
      setUploaded({ sha256: resp.item.sha256, size: resp.item.file_size_bytes })
      onSaved(resp.item)
      notifyOk('工具包已上传')
    } catch (e) {
      setUploadErr((e as Error).message)
    } finally {
      setUploading(false)
    }
  }

  const doSave = async () => {
    setSaving(true)
    setErr('')
    try {
      const resp = await LocalCodingToolVersions.patch(item.uuid, form)
      setForm(toInput(resp.item))
      onSaved(resp.item)
      notifyOk('已保存')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      title={editable ? '编辑工具版本' : '查看工具版本'}
      subtitle={`${TARGET_LABEL[item.target_id]} ${item.version} · ${PLATFORM_LABEL[item.platform]} / ${archLabel(item.platform, item.arch)} · ${STATUS_LABEL[item.status]}`}
      icon={<TerminalSquare size={18} />}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={saving}>关闭</Button>
          {editable && (
            <Button onClick={doSave} disabled={saving || uploading}>
              {saving ? '保存中...' : '保存'}
            </Button>
          )}
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        {!editable && (
          <InlineAlert>
            {isExternalPackage(item)
              ? '已发布的版本不可修改字段；包目前是外链，可以补传同一个文件（大小与 SHA-256 必须与记录一致），或用列表里的「搬入对象存储」由服务端下载。'
              : '已发布的版本不可修改。需要改动请下线后新建一个版本。'}
          </InlineAlert>
        )}

        <FormSection title="工具包" description="选择文件后立即上传到平台对象存储，大小与 SHA-256 由服务端计算；也可以填写已托管的公开地址。">
          {canReplacePackage && (
            <FileUploadPicker
              title={editable ? '上传工具包' : '补传同一个文件到对象存储'}
              description="Codex / Claude Code 的 tar.gz、npm tgz，桌面端的 zip / DMG。上限 1 GB。"
              accept=".tar.gz,.tgz,.zip,.dmg,application/gzip,application/zip,application/x-apple-diskimage,application/octet-stream"
              busy={uploading}
              onSelect={handleFileSelect}
            />
          )}
          {uploadErr && <div className="mt-2 text-[12px] text-[var(--color-danger)]">{uploadErr}</div>}
          {uploaded && (
            <div className="mt-3 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
              <span className="font-medium text-[var(--color-text)]">已上传</span>
              <span className="mx-2">·</span>
              {formatFileSize(uploaded.size)}
              {uploaded.sha256 && (
                <>
                  <span className="mx-2">·</span>
                  <span className="font-mono">SHA256: {uploaded.sha256.slice(0, 16)}…</span>
                </>
              )}
            </div>
          )}
          {editable && (
            <div className="mt-4 grid gap-4 md:grid-cols-3">
              <FormField label="公开地址（可选）">
                <Input value={form.external_url || ''} onChange={(e) => set('external_url', e.target.value)} placeholder="https://dl.example.cn/…" disabled={!editable} />
              </FormField>
              <FormField label="文件大小（字节）">
                <Input value={form.file_size_bytes ? String(form.file_size_bytes) : ''} onChange={(e) => set('file_size_bytes', Number(e.target.value) || 0)} placeholder="填写公开地址时必填" disabled={!editable} />
              </FormField>
              <FormField label="包 SHA-256">
                <Input value={form.sha256 || ''} onChange={(e) => set('sha256', e.target.value)} placeholder="填写公开地址时必填" disabled={!editable} />
              </FormField>
            </div>
          )}
        </FormSection>

        <FormSection title="校验与兼容">
          <div className="grid gap-4 md:grid-cols-2">
            {(isCli(item.target_id) || item.target_id === 'claude_code_host') && (
              <FormField label="裸二进制 SHA-256">
                <Input value={form.binary_sha256 || ''} onChange={(e) => set('binary_sha256', e.target.value)} placeholder="发布前必填；来自发行方校验文件" disabled={!editable} />
              </FormField>
            )}
            {(form.layout === 'tarball_member' || form.layout === 'tarball_tree') && (
              <FormField label={form.layout === 'tarball_tree' ? '包内目录路径' : '包内成员路径'}>
                <Input value={form.member || ''} onChange={(e) => set('member', e.target.value)} placeholder="package/vendor/aarch64-apple-darwin/bin/codex" disabled={!editable} />
              </FormField>
            )}
            {isDesktop(item.target_id) && item.platform === 'macos' && (
              <>
                <FormField label="Bundle 标识">
                  <Input value={form.bundle_identifier || ''} onChange={(e) => set('bundle_identifier', e.target.value)} placeholder="留空用默认" disabled={!editable} />
                </FormField>
                <FormField label="发行方 Team ID">
                  <Input value={form.team_identifier || ''} onChange={(e) => set('team_identifier', e.target.value)} placeholder="留空用默认" disabled={!editable} />
                </FormField>
              </>
            )}
            <FormField label="Profile 版本">
              <Input value={form.profile_version || ''} onChange={(e) => set('profile_version', e.target.value)} placeholder="合同检查时使用的 Profile 版本" disabled={!editable} />
            </FormField>
            <FormField label="最低桌面端版本">
              <Input value={form.min_app_version || ''} onChange={(e) => set('min_app_version', e.target.value)} placeholder="可选" disabled={!editable} />
            </FormField>
            <FormField label="最低连接组件版本">
              <Input value={form.min_bridge_version || ''} onChange={(e) => set('min_bridge_version', e.target.value)} placeholder="可选" disabled={!editable} />
            </FormField>
          </div>
        </FormSection>

        <FormSection title="合同检查与说明" description="发布前必须填写合同检查记录（检查器运行记录或链接）。">
          <FormField label="合同检查记录">
            <Input value={form.contract_check_ref || ''} onChange={(e) => set('contract_check_ref', e.target.value)} placeholder="例如：2026-09-10 检查器全绿，记录见 …" disabled={!editable} />
          </FormField>
          <textarea
            value={form.release_notes || ''}
            onChange={(e) => set('release_notes', e.target.value)}
            className={`${textareaCls} mt-3`}
            placeholder="桌面端「可升级到 x.y.z」里展示的说明"
            disabled={!editable}
          />
        </FormSection>
      </div>
    </DrawerShell>
  )
}

// ─── 发布弹框（灰度 / 全量） ─────────────────────────────────────────────────

function PublishDialog({
  item,
  rollback = false,
  onClose,
  onPublished,
}: {
  item: LocalCodingToolVersion
  /** 平台级回滚：把上一版本 / 已下线版本重新设为当前版本，只允许全量。 */
  rollback?: boolean
  onClose: () => void
  onPublished: () => void
}) {
  const [mode, setMode] = useState<'canary' | 'current'>(rollback || item.status === 'canary' ? 'current' : 'canary')
  const [tenantIDs, setTenantIDs] = useState<number[]>(item.canary_tenant_ids)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const handleConfirm = async () => {
    if (mode === 'canary' && tenantIDs.length === 0) { setErr('灰度发布至少填写一个租户 ID'); return }
    setBusy(true)
    setErr('')
    try {
      await LocalCodingToolVersions.publish(item.uuid, mode === 'canary' ? { mode, tenant_ids: tenantIDs } : { mode })
      notifyOk(rollback ? `已回滚到 ${item.version}` : mode === 'canary' ? `已灰度到 ${tenantIDs.length} 个租户` : '已全量发布')
      onPublished()
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title={rollback ? '回滚到此版本' : '发布工具版本'}
      subtitle={`${TARGET_LABEL[item.target_id]} ${item.version} · ${PLATFORM_LABEL[item.platform]} / ${archLabel(item.platform, item.arch)}`}
      icon={rollback ? <RotateCcw size={18} /> : <SendHorizontal size={18} />}
      onClose={onClose}
      size="sm"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={handleConfirm} disabled={busy} variant={rollback ? 'danger' : 'primary'}>
            {busy ? (rollback ? '回滚中...' : '发布中...') : rollback ? '回滚' : (mode === 'canary' ? '灰度发布' : '全量发布')}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        {rollback ? (
          <div className="text-[13px] text-[var(--color-text-sub)]">
            将把 {item.version} 重新设为所有租户的当前版本：现在的当前版本变为"上一版本"（用户可回退），原"上一版本"下线。
            已升级到被撤回版本的用户，会在客户端看到"回退到 {item.version}"；尚未升级的用户不受影响。
          </div>
        ) : (
          <>
            <FormField label="发布范围">
              <Select value={mode} onChange={(e) => setMode(e.target.value as 'canary' | 'current')}>
                <option value="canary">灰度：只对指定租户生效</option>
                <option value="current">全量：所有租户的当前版本</option>
              </Select>
            </FormField>
            {mode === 'canary' ? (
              <FormField label="灰度租户">
                <TenantPicker value={tenantIDs} onChange={setTenantIDs} />
                <div className="mt-1 text-[12px] text-[var(--color-text-sub)]">
                  已选 {tenantIDs.length} 个租户。同一工具下不同灰度版本的租户不能重叠。
                </div>
              </FormField>
            ) : (
              <div className="text-[13px] text-[var(--color-text-sub)]">
                全量发布后，原"当前版本"自动变为"上一版本"（供回退），原"上一版本"自动下线。
              </div>
            )}
          </>
        )}
      </div>
    </DialogShell>
  )
}

// ─── 工具函数 ─────────────────────────────────────────────────────────────────

function toInput(item: LocalCodingToolVersion): LocalCodingToolVersionInput {
  return {
    target_id: item.target_id,
    platform: item.platform,
    arch: item.arch,
    version: item.version,
    layout: item.layout,
    member: item.member,
    binary_sha256: item.binary_sha256,
    bundle_identifier: item.bundle_identifier,
    team_identifier: item.team_identifier,
    min_bridge_version: item.min_bridge_version,
    min_app_version: item.min_app_version,
    profile_version: item.profile_version,
    contract_check_ref: item.contract_check_ref,
    release_notes: item.release_notes,
    external_url: '',
    file_size_bytes: 0,
    sha256: '',
  }
}

function Badge({ children, className }: { children: ReactNode; className: string }) {
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-[12px] font-medium ${className}`}>{children}</span>
}
