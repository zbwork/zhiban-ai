// TenantDrivePage — F06 Phase 4 / §5.1 租户云盘 metadata 浏览 (tenant scope).
//
// 取代旧 DriveBrowse: 同 API (/api/admin/v1/tenant/drive/spaces), 改走 DataTable / EmptyState /
// PageHeader / Toolbar / SearchInput 等 ui.tsx primitives.
//
// 重要 ACL 规则: admin 不提供文件下载/预览入口; 只展 metadata. 防 admin 越权读取用户私文件,
// 同时满足排障 "看到 storage_key + uploader + 大小 + mime" 的诉求.
//
// 权限: tenant.drive.read_metadata. 后端最终把关.

import { useEffect, useState } from 'react'
import {
  DriveBrowse,
  type TenantSpaceItem,
  type TenantFileItem,
} from '../../lib/api'
import {
  Button, DataTable, EmptyState, InlineAlert, PageHeader, SearchInput,
  Toolbar, Input,
} from '../../components/ui'
import { ArrowLeft, FileText, FolderTree } from 'lucide-react'
import { fmtBytes } from './components/format'

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white p-5">
      <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
      <div className="mt-1 text-[24px] font-semibold tabular-nums text-[var(--color-text)]">{value}</div>
    </div>
  )
}

function SpaceStatusPill({ status }: { status: string }) {
  const tone =
    status === 'active' ? 'bg-emerald-50 text-emerald-700' :
    status === 'archived' ? 'bg-zinc-100 text-zinc-600' :
                            'bg-amber-50 text-amber-700'
  return <span className={'inline-flex rounded px-2 py-0.5 text-[11px] font-medium ' + tone}>{status}</span>
}

function spaceOwnerLabel(space: TenantSpaceItem) {
  if (space.owner_name) return space.owner_name
  if (space.space_kind === 'tenant') return '租户'
  if (space.space_kind === 'department') return '部门'
  if (space.space_kind === 'personal') return '个人空间'
  if (space.space_kind === 'shared') return '共享空间'
  return '—'
}

export function TenantDrivePage() {
  const [spaces, setSpaces] = useState<TenantSpaceItem[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [active, setActive] = useState<TenantSpaceItem | null>(null)

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DriveBrowse.listSpaces()
      .then((r) => { if (!cancelled) { setSpaces(r.items || []); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])

  if (active) return <FileTable space={active} onBack={() => setActive(null)} />

  const totalUsed = spaces.reduce((s, x) => s + x.used_bytes, 0)
  const totalFiles = spaces.reduce((s, x) => s + x.files_count, 0)

  return (
    <div>
      <PageHeader
        title="企业云盘"
        subtitle="本租户云盘空间与文件 metadata。仅展示, 不提供文件下载/预览入口 (admin 不越权读用户私文件)。"
      />

      {err && <div className="mb-3"><InlineAlert tone="danger">读取空间列表失败: {err}</InlineAlert></div>}

      <div className="mb-5 grid grid-cols-3 gap-4">
        <SummaryCard label="空间数" value={String(spaces.length)} />
        <SummaryCard label="文件数" value={String(totalFiles)} />
        <SummaryCard label="总用量" value={fmtBytes(totalUsed)} />
      </div>

      <DataTable
        headers={['名称', '类型', '归属', '文件 / 目录', '用量', '状态', '操作']}
        empty={!loading && !spaces.length ? (
          <EmptyState
            icon={<FolderTree size={20} />}
            title="本租户暂无云盘空间"
            description="租户首次创建时会自动 bootstrap 出 4 类 space。若一直为空, 请检查后端 bootstrap 日志。"
          />
        ) : null}
      >
        {spaces.map((s) => (
          <tr key={s.uuid}>
            <td className="px-4 py-3 align-middle font-medium text-[var(--color-text)]">{s.name}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px]">{s.space_kind}</td>
            <td className="px-4 py-3 align-middle text-[13px]">
              {spaceOwnerLabel(s)}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)] tabular-nums">
              {s.files_count} / {s.folders_count}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums">
              {fmtBytes(s.used_bytes)}
              {s.quota_bytes != null && <span className="text-[var(--color-text-mute)]"> / {fmtBytes(s.quota_bytes)}</span>}
            </td>
            <td className="px-4 py-3 align-middle"><SpaceStatusPill status={s.status} /></td>
            <td className="px-4 py-3 align-middle">
              <Button size="sm" variant="secondary" onClick={() => setActive(s)}>进入</Button>
            </td>
          </tr>
        ))}
      </DataTable>
    </div>
  )
}

function FileTable({ space, onBack }: { space: TenantSpaceItem; onBack: () => void }) {
  const [files, setFiles] = useState<TenantFileItem[]>([])
  const [nextCursor, setNextCursor] = useState(0)
  const [q, setQ] = useState('')
  const [mimePrefix, setMimePrefix] = useState('')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  const load = (cursor = 0, append = false) => {
    setLoading(true)
    DriveBrowse.listFiles(space.uuid, {
      q: q || undefined,
      mime_prefix: mimePrefix || undefined,
      cursor: cursor || undefined,
      limit: 50,
    })
      .then((r) => {
        setNextCursor(r.next_cursor || 0)
        setFiles((prev) => append ? [...prev, ...(r.items || [])] : (r.items || []))
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }
  // eslint-disable-next-line react-hooks/set-state-in-effect, react-hooks/exhaustive-deps
  useEffect(() => { load(0, false) }, [space.uuid])

  return (
    <div>
      <div className="mb-5 flex items-center gap-3">
        <Button size="sm" variant="ghost" onClick={onBack}><ArrowLeft size={14} /> 返回</Button>
        <div className="min-w-0">
          <h1 className="text-[24px] font-semibold tracking-tight text-[var(--color-text)]">{space.name}</h1>
          <p className="text-[12px] text-[var(--color-text-sub)]">
            space_uuid: <span className="font-mono">{space.uuid}</span>
          </p>
        </div>
      </div>

      <Toolbar
        search={<SearchInput value={q} onChange={setQ} placeholder="按文件名搜索" />}
        filters={
          <div className="w-[200px]">
            <Input
              value={mimePrefix}
              onChange={(e) => setMimePrefix(e.target.value)}
              placeholder="MIME 前缀, 如 image/"
            />
          </div>
        }
        actions={<Button onClick={() => load(0, false)} disabled={loading}>{loading ? '搜索中…' : '搜索'}</Button>}
      />

      {err && <div className="mb-3"><InlineAlert tone="danger">{err}</InlineAlert></div>}

      <DataTable
        headers={['名称', '路径', 'MIME', '大小', '上传者', '来源', 'storage_key', '时间']}
        empty={!loading && !files.length ? (
          <EmptyState
            icon={<FileText size={20} />}
            title="无文件"
            description="当前 space 没有匹配的文件。试试清空搜索条件或更换 MIME 前缀。"
          />
        ) : null}
      >
        {files.map((f) => (
          <tr key={f.uuid}>
            <td className="px-4 py-3 align-middle font-medium text-[var(--color-text)]">{f.name}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-sub)] max-w-[240px] truncate" title={f.folder_path}>
              {f.folder_path || '—'}
            </td>
            <td className="px-4 py-3 align-middle font-mono text-[12px]">{f.mime_type || '—'}</td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums">{fmtBytes(f.file_size)}</td>
            <td className="px-4 py-3 align-middle text-[12px]">
              {f.uploader_name || (f.uploader_id ? `account#${f.uploader_id}` : '—')}
            </td>
            <td className="px-4 py-3 align-middle text-[12px]">{f.source_kind || '—'}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-sub)] max-w-[280px] truncate" title={f.storage_key}>
              {f.storage_key}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)]">{f.created_at}</td>
          </tr>
        ))}
      </DataTable>

      {nextCursor > 0 && (
        <div className="mt-3 text-center">
          <Button variant="secondary" onClick={() => load(nextCursor, true)} disabled={loading}>
            {loading ? '加载中…' : '加载更多'}
          </Button>
        </div>
      )}
    </div>
  )
}
