import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { ChevronRight, FileText, Folder, FolderOpen, FolderPlus, ListTree, MoreHorizontal, Pencil, Trash2, Upload } from 'lucide-react'
import { ManagedKB, type KBFolderItem, type KBDocumentItem, type ManagedKBScope } from '../../lib/api'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  InlineAlert,
  Input,
  Pagination,
  RowActions,
  Toolbar,
  stickyRightTdCls,
} from '../ui'
import { notifyError, notifyOk } from '../../lib/toast'

type EditTarget = { kind: 'folder'; item?: KBFolderItem } | { kind: 'document'; item: KBDocumentItem }
type DeleteTarget = { kind: 'folder'; item: KBFolderItem } | { kind: 'document'; item: KBDocumentItem }
type FolderTreeNode = { item: KBFolderItem; children: FolderTreeNode[] }
type VisibleTreeNode = {
  key: string
  item?: KBFolderItem
  label: string
  depth: number
  parentKey?: string
  hasChildren: boolean
}

const ROOT_NODE_KEY = '__kb_root__'
const ROW_ACTION_CLASS = 'inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)] disabled:cursor-not-allowed disabled:opacity-60'

export function KBContentPanel({ scope, kbUuid, kbName }: { scope: ManagedKBScope; kbUuid: string; kbName: string }) {
  const [folders, setFolders] = useState<KBFolderItem[]>([])
  const [folderUuid, setFolderUuid] = useState('')
  const [documents, setDocuments] = useState<KBDocumentItem[]>([])
  const [total, setTotal] = useState(0)
  const [offset, setOffset] = useState(0)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const [retrying, setRetrying] = useState<Record<string, boolean>>({})
  const [expanded, setExpanded] = useState<Record<string, boolean>>({ [ROOT_NODE_KEY]: true })
  const [mobileTreeOpen, setMobileTreeOpen] = useState(false)
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<EditTarget | null>(null)
  const [deleting, setDeleting] = useState<DeleteTarget | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)

  const load = useCallback(async () => {
    setLoading(true); setErr('')
    try {
      const [folderRes, docRes] = await Promise.all([
        ManagedKB.folders(scope, kbUuid),
        ManagedKB.documents(scope, kbUuid, { folder_uuid: folderUuid || undefined, limit: pageSize, offset }),
      ])
      const nextFolders = folderRes.items || []
      setFolders(nextFolders)
      setExpanded((current) => {
        let changed = current[ROOT_NODE_KEY] === undefined
        const next: Record<string, boolean> = { ...current, [ROOT_NODE_KEY]: current[ROOT_NODE_KEY] ?? true }
        nextFolders.forEach((folder) => {
          if (next[folder.uuid] === undefined) {
            next[folder.uuid] = true
            changed = true
          }
        })
        return changed ? next : current
      })
      setDocuments(docRes.items || [])
      setTotal(docRes.total || 0)
    } catch (e) { setErr((e as Error).message) } finally { setLoading(false) }
  }, [folderUuid, kbUuid, offset, pageSize, scope])

  // eslint-disable-next-line react-hooks/set-state-in-effect -- 当前目录或分页变化后必须重新拉取后端目录/文件快照。
  useEffect(() => { load() }, [load])

  const folderTree = useMemo(() => buildFolderTree(folders), [folders])
  const visibleTreeNodes = useMemo(() => flattenFolderTree(folderTree, expanded, kbName), [expanded, folderTree, kbName])
  const currentFolder = useMemo(() => folders.find((folder) => folder.uuid === folderUuid), [folderUuid, folders])
  const currentFolderLabel = currentFolder?.path || kbName

  const selectFolder = (uuid: string) => {
    setFolderUuid(uuid)
    setOffset(0)
    setMobileTreeOpen(false)
  }

  const toggleFolder = (key: string) => {
    if (expanded[key] && key !== (folderUuid || ROOT_NODE_KEY)) {
      if (key === ROOT_NODE_KEY) selectFolder('')
      else if (folderUuid && isFolderDescendant(folderUuid, key, folders)) selectFolder(key)
    }
    setExpanded((current) => ({ ...current, [key]: !current[key] }))
  }

  const upload = async (files: FileList | null) => {
    if (!files?.length) return
    setUploading(true); setErr('')
    try {
      const result = await ManagedKB.upload(scope, kbUuid, Array.from(files), folderUuid || undefined)
      if (result.total > 0) notifyOk(`${result.total} 个文件处理完成`)
      await load()
      if (result.failures?.length) setErr(result.failures.map((item) => `${item.filename}：${item.error}`).join('；'))
    } catch (e) { setErr((e as Error).message) } finally {
      setUploading(false)
      if (fileInput.current) fileInput.current.value = ''
    }
  }

  const download = async (doc: KBDocumentItem) => {
    try {
      const result = await ManagedKB.downloadURL(scope, kbUuid, doc.uuid)
      window.open(result.url, '_blank', 'noopener,noreferrer')
    } catch (e) { setErr((e as Error).message) }
  }

  const retry = async (doc: KBDocumentItem) => {
    setRetrying((current) => ({ ...current, [doc.uuid]: true })); setErr('')
    try {
      await ManagedKB.retryDocument(scope, kbUuid, doc.uuid)
      notifyOk('文件已重新解析')
      await load()
    } catch (e) { setErr((e as Error).message) } finally {
      setRetrying((current) => { const next = { ...current }; delete next[doc.uuid]; return next })
    }
  }

  const beginFolderDelete = async (item: KBFolderItem) => {
    const hasChildFolder = folders.some((folder) => folder.parent_uuid === item.uuid)
    if (hasChildFolder) {
      notifyError('目录中仍有子目录或文件，请先处理后再删除')
      return
    }
    try {
      const result = await ManagedKB.documents(scope, kbUuid, { folder_uuid: item.uuid, limit: 1, offset: 0 })
      if (result.total > 0 || (result.items?.length ?? 0) > 0) {
        notifyError('目录中仍有子目录或文件，请先处理后再删除')
        return
      }
    } catch {
      return
    }
    selectFolder(item.uuid)
    setDeleting({ kind: 'folder', item })
  }

  const tree = (
    <FolderTree
      nodes={visibleTreeNodes}
      selectedKey={folderUuid || ROOT_NODE_KEY}
      expanded={expanded}
      onSelect={(key) => selectFolder(key === ROOT_NODE_KEY ? '' : key)}
      onToggle={toggleFolder}
      onCreateChild={(node) => {
        selectFolder(node.item?.uuid || '')
        setEditing({ kind: 'folder' })
      }}
      onRename={(item) => {
        selectFolder(item.uuid)
        setEditing({ kind: 'folder', item })
      }}
      onDelete={(item) => {
        void beginFolderDelete(item)
      }}
    />
  )

  return (
    <div className="space-y-4">
      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <div className="grid min-w-0 gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
        <aside className="hidden min-h-[520px] overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[0_1px_0_rgba(23,23,23,0.02)] lg:flex lg:flex-col">
          <div className="flex h-12 items-center gap-2 border-b border-[var(--color-line)] px-4 text-[13px] font-semibold text-[var(--color-text)]">
            <ListTree size={16} className="text-[var(--color-text-sub)]" />
            目录
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">{tree}</div>
          <div className="border-t border-[var(--color-line-soft)] px-4 py-2.5 text-[12px] text-[var(--color-text-mute)]">
            共 {folders.length} 个目录
          </div>
        </aside>

        <section className="min-w-0">
          <Toolbar
            filters={(
              <div className="flex min-w-0 items-center gap-3">
                <Button className="lg:hidden" variant="secondary" onClick={() => setMobileTreeOpen(true)}>
                  <ListTree size={14} />选择目录
                </Button>
                <div className="min-w-0">
                  <div className="text-[11px] text-[var(--color-text-mute)]">当前目录</div>
                  <div className="max-w-[320px] truncate text-[13px] font-medium text-[var(--color-text)]" title={currentFolderLabel}>{currentFolderLabel}</div>
                </div>
              </div>
            )}
            actions={(
              <div className="flex flex-wrap justify-end gap-2">
                <Button onClick={() => fileInput.current?.click()} disabled={uploading}><Upload size={14} />{uploading ? '上传中...' : '上传文件'}</Button>
                <input ref={fileInput} className="hidden" type="file" multiple accept=".txt,.md,.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.csv,.html,.json" onChange={(e) => upload(e.target.files)} />
              </div>
            )}
          />

          <DataTable
            headers={[
              <span className="block min-w-[220px]">文件名</span>,
              <span className="block min-w-[280px]">类型</span>,
              <span className="block min-w-[72px]">大小</span>,
              <span className="block min-w-[72px]">片段数</span>,
              <span className="block min-w-[72px]">状态</span>,
              <span className="block min-w-[220px]">错误信息</span>,
              <span className="block min-w-[140px]">更新时间</span>,
              <span className="block min-w-[176px]">操作</span>,
            ]}
            loading={loading ? <EmptyState title="正在加载文件" description="正在读取当前目录内容。" /> : undefined}
            empty={!loading && documents.length === 0 ? <EmptyState icon={<FileText size={22} />} title="当前目录暂无文件" description="点击“上传文件”添加知识内容。" /> : undefined}
            stickyLastCol
            className="[&_table]:min-w-[1400px]"
          >
            {!loading && documents.map((doc) => (
              <tr key={doc.uuid} className="group hover:bg-[var(--color-bg-sub)]">
                <td className="whitespace-nowrap px-4 py-3"><div className="flex min-w-0 items-center gap-2"><FileText size={14} className="shrink-0 text-[var(--color-text-mute)]" /><span className="max-w-[260px] truncate font-medium" title={doc.title}>{doc.title}</span></div></td>
                <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]"><span className="block max-w-[280px] truncate whitespace-nowrap" title={doc.mime_type || '-'}>{doc.mime_type || '-'}</span></td>
                <td className="whitespace-nowrap px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{formatSize(doc.file_size)}</td>
                <td className="whitespace-nowrap px-4 py-3 text-[12px] tabular-nums text-[var(--color-text-sub)]">{doc.chunk_count}</td>
                <td className="whitespace-nowrap px-4 py-3"><DocumentStatus item={doc} /></td>
                <td className="px-4 py-3 text-[12px]">
                  <span
                    className={`block max-w-[260px] truncate ${doc.error_message ? 'text-[var(--color-danger)]' : 'text-[var(--color-text-mute)]'}`}
                    title={doc.error_message || ''}
                  >
                    {doc.error_message || '—'}
                  </span>
                </td>
                <td className="whitespace-nowrap px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{formatDate(doc.updated_at || doc.created_at)}</td>
                <td className={`whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                  <RowActions
                    extras={(
                      <>
                        {isDocumentFailed(doc) && (
                          <button type="button" className={ROW_ACTION_CLASS} disabled={!!retrying[doc.uuid]} onClick={() => retry(doc)} title={doc.error_message || '重新解析文件'}>
                            {retrying[doc.uuid] ? '重试中' : '重试'}
                          </button>
                        )}
                        <button type="button" className={ROW_ACTION_CLASS} onClick={() => download(doc)}>下载</button>
                      </>
                    )}
                    onEdit={() => setEditing({ kind: 'document', item: doc })}
                    onDelete={() => setDeleting({ kind: 'document', item: doc })}
                  />
                </td>
              </tr>
            ))}
          </DataTable>

          <Pagination
            total={total}
            page={Math.floor(offset / pageSize) + 1}
            pageSize={pageSize}
            onPageChange={(page) => setOffset((page - 1) * pageSize)}
            onPageSizeChange={(size) => { setPageSize(size); setOffset(0) }}
          />
        </section>
      </div>

      {mobileTreeOpen && (
        <DrawerShell title="选择目录" subtitle="选择后右侧只展示该目录直属文件。" onClose={() => setMobileTreeOpen(false)} width="sm">
          {tree}
        </DrawerShell>
      )}
      {editing && <RenameDialog scope={scope} kbUuid={kbUuid} folderUuid={folderUuid} target={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load() }} />}
      {deleting && (
        <ConfirmDialog
          title={deleting.kind === 'folder' ? '删除目录' : '删除文件'}
          description={deleting.kind === 'folder' ? `确认删除空目录「${deleting.item.name}」？` : `确认删除文件「${deleting.item.title}」？删除后不可恢复。`}
          confirmLabel="删除"
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            if (deleting.kind === 'folder') {
              await ManagedKB.removeFolder(scope, kbUuid, deleting.item.uuid)
              setFolderUuid('')
              setOffset(0)
            } else {
              await ManagedKB.removeDocument(scope, kbUuid, deleting.item.uuid)
              await load()
            }
            notifyOk('已删除')
            setDeleting(null)
          }}
        />
      )}
    </div>
  )
}

function FolderTree({
  nodes,
  selectedKey,
  expanded,
  onSelect,
  onToggle,
  onCreateChild,
  onRename,
  onDelete,
}: {
  nodes: VisibleTreeNode[]
  selectedKey: string
  expanded: Record<string, boolean>
  onSelect: (key: string) => void
  onToggle: (key: string) => void
  onCreateChild: (node: VisibleTreeNode) => void
  onRename: (item: KBFolderItem) => void
  onDelete: (item: KBFolderItem) => void
}) {
  const itemRefs = useRef(new Map<string, HTMLButtonElement>())
  const [menuKey, setMenuKey] = useState('')

  useEffect(() => {
    if (!menuKey) return
    const close = () => setMenuKey('')
    document.addEventListener('pointerdown', close)
    return () => document.removeEventListener('pointerdown', close)
  }, [menuKey])

  const focusAt = (index: number) => {
    const node = nodes[index]
    if (node) itemRefs.current.get(node.key)?.focus()
  }

  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>, node: VisibleTreeNode, index: number) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault(); focusAt(Math.min(nodes.length - 1, index + 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault(); focusAt(Math.max(0, index - 1))
    } else if (event.key === 'Home') {
      event.preventDefault(); focusAt(0)
    } else if (event.key === 'End') {
      event.preventDefault(); focusAt(nodes.length - 1)
    } else if (event.key === 'ArrowRight' && node.hasChildren) {
      event.preventDefault()
      if (!expanded[node.key]) onToggle(node.key)
      else if (nodes[index + 1]?.depth === node.depth + 1) focusAt(index + 1)
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault()
      if (node.hasChildren && expanded[node.key]) onToggle(node.key)
      else if (node.parentKey) itemRefs.current.get(node.parentKey)?.focus()
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault(); onSelect(node.key)
    }
  }

  return (
    <div role="tree" aria-label="知识库目录" className="space-y-0.5">
      {nodes.map((node, index) => {
        const selected = selectedKey === node.key
        const open = !!expanded[node.key]
        const menuOpen = menuKey === node.key
        return (
          <div key={node.key} role="none" className="group relative">
            <button
              ref={(element) => { if (element) itemRefs.current.set(node.key, element); else itemRefs.current.delete(node.key) }}
              type="button"
              role="treeitem"
              aria-level={node.depth}
              aria-selected={selected}
              aria-expanded={node.hasChildren ? open : undefined}
              tabIndex={selected ? 0 : -1}
              title={`查看：${node.label}`}
              onClick={() => { setMenuKey(''); onSelect(node.key) }}
              onKeyDown={(event) => onKeyDown(event, node, index)}
              className={`flex h-9 w-full items-center gap-1.5 rounded-md pr-10 text-left text-[13px] transition focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand-line)] ${selected ? 'bg-[var(--color-brand-soft)] font-medium text-[var(--color-brand)]' : 'text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]'}`}
              style={{ paddingLeft: `${8 + (node.depth - 1) * 16}px` }}
            >
              <span
                aria-hidden="true"
                className={`grid h-5 w-5 shrink-0 place-items-center rounded ${node.hasChildren ? 'hover:bg-white/80' : ''}`}
                onClick={(event) => {
                  if (!node.hasChildren) return
                  event.preventDefault(); event.stopPropagation(); onToggle(node.key)
                }}
              >
                {node.hasChildren ? <ChevronRight size={14} className={`transition-transform ${open ? 'rotate-90' : ''}`} /> : null}
              </span>
              {open && node.hasChildren ? <FolderOpen size={15} className="shrink-0" /> : <Folder size={15} className="shrink-0" />}
              <span className="min-w-0 flex-1 truncate">{node.label}</span>
            </button>

            <button
              type="button"
              aria-label={`${node.label}目录操作`}
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              title="目录操作"
              onPointerDown={(event) => event.stopPropagation()}
              onClick={() => setMenuKey((current) => current === node.key ? '' : node.key)}
              className={`absolute right-1 top-1/2 grid h-7 w-7 -translate-y-1/2 place-items-center rounded-md text-[var(--color-text-mute)] transition hover:bg-white hover:text-[var(--color-text)] focus:opacity-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand-line)] ${selected || menuOpen ? 'opacity-100' : 'opacity-0 group-hover:opacity-100 group-focus-within:opacity-100'}`}
            >
              <MoreHorizontal size={15} />
            </button>

            {menuOpen && (
              <div
                role="menu"
                aria-label={`${node.label}目录操作`}
                onPointerDown={(event) => event.stopPropagation()}
                className="absolute right-1 top-9 z-20 w-36 rounded-md border border-[var(--color-line)] bg-white p-1 shadow-lg"
              >
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => { setMenuKey(''); onCreateChild(node) }}
                  className="flex h-8 w-full items-center gap-2 rounded px-2 text-left text-[12px] text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                >
                  <FolderPlus size={14} />新建子目录
                </button>
                {node.item && (
                  <>
                    <button
                      type="button"
                      role="menuitem"
                      onClick={() => { setMenuKey(''); onRename(node.item!) }}
                      className="flex h-8 w-full items-center gap-2 rounded px-2 text-left text-[12px] text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                    >
                      <Pencil size={14} />重命名
                    </button>
                    <button
                      type="button"
                      role="menuitem"
                      onClick={() => { setMenuKey(''); onDelete(node.item!) }}
                      className="flex h-8 w-full items-center gap-2 rounded px-2 text-left text-[12px] text-[var(--color-danger)] hover:bg-[var(--color-danger-bg)]"
                    >
                      <Trash2 size={14} />删除
                    </button>
                  </>
                )}
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

function buildFolderTree(items: KBFolderItem[]) {
  const map = new Map<string, FolderTreeNode>()
  items.forEach((item) => map.set(item.uuid, { item, children: [] }))
  const roots: FolderTreeNode[] = []
  map.forEach((node) => {
    const parent = node.item.parent_uuid ? map.get(node.item.parent_uuid) : undefined
    if (parent) parent.children.push(node)
    else roots.push(node)
  })
  const sort = (nodes: FolderTreeNode[]) => {
    nodes.sort((left, right) => left.item.name.localeCompare(right.item.name, 'zh-CN'))
    nodes.forEach((node) => sort(node.children))
  }
  sort(roots)
  return roots
}

function flattenFolderTree(tree: FolderTreeNode[], expanded: Record<string, boolean>, kbName: string) {
  const result: VisibleTreeNode[] = [{ key: ROOT_NODE_KEY, label: kbName, depth: 1, hasChildren: tree.length > 0 }]
  if (!expanded[ROOT_NODE_KEY]) return result
  const append = (nodes: FolderTreeNode[], depth: number, parentKey: string) => {
    nodes.forEach((node) => {
      result.push({
        key: node.item.uuid,
        item: node.item,
        label: node.item.name,
        depth,
        parentKey,
        hasChildren: node.children.length > 0,
      })
      if (node.children.length && expanded[node.item.uuid]) append(node.children, depth + 1, node.item.uuid)
    })
  }
  append(tree, 2, ROOT_NODE_KEY)
  return result
}

function isFolderDescendant(folderUuid: string, ancestorUuid: string, folders: KBFolderItem[]) {
  const byUuid = new Map(folders.map((folder) => [folder.uuid, folder]))
  let current = byUuid.get(folderUuid)
  while (current?.parent_uuid) {
    if (current.parent_uuid === ancestorUuid) return true
    current = byUuid.get(current.parent_uuid)
  }
  return false
}

function RenameDialog({ scope, kbUuid, folderUuid, target, onClose, onSaved }: { scope: ManagedKBScope; kbUuid: string; folderUuid: string; target: EditTarget; onClose: () => void; onSaved: () => void }) {
  const initial = target.kind === 'folder' ? target.item?.name || '' : target.item.title
  const [name, setName] = useState(initial)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')
  const isCreate = target.kind === 'folder' && !target.item
  const save = async () => {
    if (!name.trim()) { setErr('名称不能为空'); return }
    setSaving(true); setErr('')
    try {
      if (target.kind === 'document') await ManagedKB.patchDocument(scope, kbUuid, target.item.uuid, name.trim())
      else if (target.item) await ManagedKB.patchFolder(scope, kbUuid, target.item.uuid, name.trim())
      else await ManagedKB.createFolder(scope, kbUuid, { name: name.trim(), parent_uuid: folderUuid || undefined })
      notifyOk(isCreate ? '目录已创建' : '名称已更新')
      onSaved()
    } catch (e) { setErr((e as Error).message) } finally { setSaving(false) }
  }
  const title = isCreate ? '新建目录' : target.kind === 'document' ? '重命名文件' : '重命名目录'
  return (
    <DialogShell title={title} subtitle={isCreate && folderUuid ? '新目录将创建在当前所选目录下。' : undefined} onClose={onClose} size="sm" footer={<div className="flex justify-end gap-2"><Button variant="secondary" onClick={onClose}>取消</Button><Button onClick={save} disabled={saving}>{saving ? '保存中...' : '保存'}</Button></div>}>
      <div className="space-y-4">{err && <InlineAlert tone="danger">{err}</InlineAlert>}<FormField label={target.kind === 'document' ? '文件显示名称' : '目录名称'}><Input value={name} maxLength={255} autoFocus onChange={(e) => setName(e.target.value)} /></FormField></div>
    </DialogShell>
  )
}

function DocumentStatus({ item }: { item: KBDocumentItem }) {
  const failed = isDocumentFailed(item)
  const ready = item.status === 'ready'
  return <span title={item.status} className={`inline-flex rounded px-2 py-1 text-[12px] ${failed ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]' : ready ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]' : 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'}`}>{failed ? '解析失败' : ready ? '已就绪' : '解析中'}</span>
}

function isDocumentFailed(item: KBDocumentItem) {
  return item.status === 'failed' || item.status === 'error' || !!item.error_message
}

function formatSize(size: number) {
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`
  return `${(size / 1024 / 1024).toFixed(2)} MB`
}

function formatDate(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString()
}
