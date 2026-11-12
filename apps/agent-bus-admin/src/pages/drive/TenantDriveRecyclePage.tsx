// TenantDriveRecyclePage — F06 Phase 4 / §5.1 租户云盘回收站 (admin 全租户视角).
//
// 与客户端 /api/agent-bus/v1/drive/recycle/* 区别: admin 看本租户全部回收行 (任何 caller 删的);
// 可代为还原 / 提前清理 (purge 走 ConfirmDialog).
//
// 能力 (UI 已就绪, 后端 admin 回收站 API 未接入):
//   - list (按 expires_at ASC, 临期靠前)
//   - restore (单行)
//   - purge (单行, ConfirmDialog)
//
// 权限: tenant.drive.manage_recycle. 后端最终把关.

import { useEffect, useState } from 'react'
import {
  DriveRecycleAdmin,
  type DriveRecycleAdminItem,
} from '../../lib/api'
import {
  Button, DataTable, EmptyState, InlineAlert, PageHeader, Toolbar,
} from '../../components/ui'
import { useConfirmDialog } from '../../components/useConfirmDialog'
import { FileText, Folder, Trash2 } from 'lucide-react'
import { fmtBytes } from './components/format'

function targetIcon(kind: 'file' | 'folder') {
  return kind === 'folder'
    ? <Folder size={14} className="text-[var(--color-text-mute)]" />
    : <FileText size={14} className="text-[var(--color-text-mute)]" />
}

export function TenantDriveRecyclePage() {
  const confirm = useConfirmDialog()
  const [items, setItems] = useState<DriveRecycleAdminItem[]>([])
  const [nextCursor, setNextCursor] = useState(0)
  const [loading, setLoading] = useState(true)
  const [loadErr, setLoadErr] = useState('')
  const [actionErr, setActionErr] = useState('')
  const [notice, setNotice] = useState('')
  const [tick, setTick] = useState(0)
  const refresh = () => setTick((t) => t + 1)

  const load = (cursor = 0, append = false) => {
    setLoading(true)
    DriveRecycleAdmin.list({ cursor: cursor || undefined, limit: 50 })
      .then((r) => {
        setItems((prev) => append ? [...prev, ...(r.items || [])] : (r.items || []))
        setNextCursor(r.next_cursor || 0)
        setLoadErr('')
      })
      .catch((e: Error) => setLoadErr(e.message))
      .finally(() => setLoading(false))
  }

  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { load(0, false) }, [tick])

  const restore = async (row: DriveRecycleAdminItem) => {
    setActionErr(''); setNotice('')
    try {
      await DriveRecycleAdmin.restore(row.uuid)
      setNotice(`已还原「${row.target_name || row.target_uuid || row.uuid}」`)
      refresh()
    } catch (e) { setActionErr((e as Error).message) }
  }

  const purge = async (row: DriveRecycleAdminItem) => {
    const ok = await confirm.confirm({
      title: '彻底清理',
      description: (
        <>
          确认彻底删除「<span className="font-medium text-[var(--color-text)]">{row.target_name || row.target_uuid || row.uuid}</span>」?
          <div className="mt-2 text-[12px] text-[var(--color-text-mute)]">
            物理删除文件 + 释放配额 + 删 S3 对象 (不可恢复)。
            原本将在 <span className="font-mono">{row.expires_at}</span> 自动清理, 现在提前。
          </div>
        </>
      ),
      confirmLabel: '彻底删除',
      tone: 'danger',
    })
    if (!ok) return
    setActionErr(''); setNotice('')
    try {
      await DriveRecycleAdmin.purge(row.uuid)
      setNotice(`已彻底删除「${row.target_name || row.target_uuid || row.uuid}」`)
      refresh()
    } catch (e) { setActionErr((e as Error).message) }
  }

  return (
    <div>
      {confirm.dialog}
      <PageHeader
        title="云盘回收站"
        subtitle="本租户全部待清理的文件 / 目录, 按到期时间排序; 30 天后由后台 worker 自动清理。"
      />

      {loadErr && (
        <div className="mb-3">
          <InlineAlert tone="danger">
            读取回收站失败: {loadErr}
            <div className="mt-1 text-[12px] text-[var(--color-text-mute)]">
              后端 admin 回收站 API 可能尚未上线; 上线后该错误会自动消失。
            </div>
          </InlineAlert>
        </div>
      )}
      {actionErr && <div className="mb-3"><InlineAlert tone="danger">{actionErr}</InlineAlert></div>}
      {notice && <div className="mb-3"><InlineAlert tone="info">{notice}</InlineAlert></div>}

      <Toolbar
        summary={<>共 <b className="text-[var(--color-text)]">{items.length}</b> 项{nextCursor ? '+ (有下一页)' : ''}</>}
      />

      <DataTable
        headers={['类型', '名称', '空间', '删除人', '删除时间', '到期', '可回收', '操作']}
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<Trash2 size={26} />}
            title="回收站为空"
            description="文件 / 目录被删除后会先放到这里, 默认停留 30 天供随时还原。"
          />
        ) : null}
      >
        {items.map((row) => (
          <tr key={row.uuid}>
            <td className="px-4 py-3 align-middle">
              <span className="inline-flex items-center gap-2 text-[12px] text-[var(--color-text-sub)]">
                {targetIcon(row.target_kind)} {row.target_kind === 'folder' ? '目录' : '文件'}
              </span>
            </td>
            <td className="px-4 py-3 align-middle font-medium text-[var(--color-text)]">
              {row.target_name || <span className="text-[var(--color-text-mute)]">(未知名)</span>}
              {row.target_uuid && (
                <div className="font-mono text-[11px] text-[var(--color-text-mute)]">{row.target_uuid}</div>
              )}
            </td>
            <td className="px-4 py-3 align-middle text-[12px]">
              {row.space_name || '未知空间'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px]">
              {row.deleted_by_name || '未知账号'}
            </td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)]">{row.deleted_at}</td>
            <td className="px-4 py-3 align-middle text-[12px] text-[var(--color-text-sub)]">{row.expires_at}</td>
            <td className="px-4 py-3 align-middle text-[12px] tabular-nums">{fmtBytes(row.bytes_to_reclaim)}</td>
            <td className="px-4 py-3 align-middle">
              <div className="flex items-center gap-2">
                <Button size="sm" variant="secondary" onClick={() => restore(row)}>还原</Button>
                <Button size="sm" variant="danger" onClick={() => purge(row)}>彻底删除</Button>
              </div>
            </td>
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
