import { useEffect, useMemo, useState } from 'react'
import { hasAdminPermission } from '../lib/adminPermissions'
import { Departments, type Department } from '../lib/api'
import { ChevronRight, Users, Folder, Plus, Edit2, Trash2, X } from 'lucide-react'
import { ConfirmDialog, InlineAlert, PageHeader, PrimaryButton, Select, Toolbar } from '../components/ui'

type Node = Department & { children: Node[] }

function subtreeMemberCount(node: Node): number {
  return node.children.reduce((sum, child) => sum + subtreeMemberCount(child), node.member_count || 0)
}

function buildTree(items: Department[]): Node[] {
  const map = new Map<number, Node>()
  items.forEach((d) => map.set(d.id, { ...d, children: [] }))
  const roots: Node[] = []
  items.forEach((d) => {
    const node = map.get(d.id)!
    if (d.parent_id && map.has(d.parent_id)) map.get(d.parent_id)!.children.push(node)
    else roots.push(node)
  })
  return roots
}

export function DepartmentTree() {
  const [items, setItems] = useState<Department[]>([])
  const [err, setErr] = useState('')
  const [expanded, setExpanded] = useState<Record<number, boolean>>({})

  const [creating, setCreating] = useState<{ parent?: Department } | null>(null)
  const [editing, setEditing] = useState<Department | null>(null)
  const [deleting, setDeleting] = useState<Department | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    Departments.list()
      .then((r) => {
        setItems(r.items || [])
        // 只默认展开顶级部门，往下按需手动展开；否则大规模组织（几百上千个部门）
        // 一进页面就把整棵树全铺开，卡顿且没法看。
        const exp: Record<number, boolean> = {}
        ;(r.items || []).forEach((d) => {
          if (!d.parent_id) exp[d.id] = true
        })
        setExpanded(exp)
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [tick])

  const tree = useMemo(() => buildTree(items), [items])
  const totalMembers = useMemo(() => items.reduce((s, d) => s + (d.member_count || 0), 0), [items])
  const refresh = () => setTick((t) => t + 1)

  return (
    <div>
      <PageHeader title="部门管理" subtitle="管理租户组织部门和成员归属。" />

      {err && <Err msg={err} />}

      <Toolbar
        summary={
          <>
            共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{items.length}</span> 个部门
            <span className="ml-2 text-[var(--color-text-mute)]">在岗 {totalMembers} 人</span>
          </>
        }
        actions={hasAdminPermission('tenant.department.create') ? <PrimaryButton onClick={() => setCreating({})}>新建部门</PrimaryButton> : undefined}
      />

      <div className="bg-white rounded-lg card-shadow p-3">
        {tree.length === 0 && (
          <div className="text-center py-12 text-sm text-[var(--color-text-mute)]">还没有部门</div>
        )}
        {tree.map((n) => (
          <Branch
            key={n.id}
            node={n}
            depth={0}
            expanded={expanded}
            setExpanded={setExpanded}
            onAddChild={(parent) => setCreating({ parent })}
            onEdit={(d) => setEditing(d)}
            onDelete={(d) => setDeleting(d)}
          />
        ))}
      </div>

      {creating && (
        <DeptFormModal
          title={creating.parent ? `在「${creating.parent.name}」下新建子部门` : '新建顶级部门'}
          allDepartments={items}
          parentId={creating.parent?.id}
          onClose={() => setCreating(null)}
          onSubmit={async (body) => {
            await Departments.create(body)
            setCreating(null)
            refresh()
          }}
        />
      )}
      {editing && (
        <DeptFormModal
          title={`编辑部门：${editing.name}`}
          allDepartments={items}
          initial={editing}
          onClose={() => setEditing(null)}
          onSubmit={async (body) => {
            await Departments.update(editing.id, body)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmDelete
          dept={deleting}
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await Departments.remove(deleting.id)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function Branch({
  node,
  depth,
  expanded,
  setExpanded,
  onAddChild,
  onEdit,
  onDelete,
}: {
  node: Node
  depth: number
  expanded: Record<number, boolean>
  setExpanded: React.Dispatch<React.SetStateAction<Record<number, boolean>>>
  onAddChild: (parent: Department) => void
  onEdit: (d: Department) => void
  onDelete: (d: Department) => void
}) {
  const open = expanded[node.id]
  const hasChildren = node.children.length > 0
  return (
    <div>
      <div
        className="flex items-center gap-2 py-1.5 px-2 rounded-md hover:bg-[var(--color-line-soft)] group"
        style={{ paddingLeft: depth * 24 + 8 }}
      >
        {hasChildren ? (
          <button
            onClick={() => setExpanded((s) => ({ ...s, [node.id]: !s[node.id] }))}
            className="grid place-items-center w-5 h-5 text-[var(--color-text-mute)] hover:text-[var(--color-text)]"
          >
            <ChevronRight size={14} className={`transition-transform ${open ? 'rotate-90' : ''}`} />
          </button>
        ) : (
          <span className="w-5 h-5" />
        )}
        <Folder size={14} className="text-[var(--color-text-mute)]" />
        <span className="text-[13px] font-medium">{node.name}</span>
        <span className="ml-auto flex items-center gap-2">
          <span className="inline-flex items-center gap-1 text-[11px] text-[var(--color-text-mute)]" title="含所有子部门人数">
            <Users size={11} />
            {subtreeMemberCount(node)}
          </span>
          <div className="opacity-0 group-hover:opacity-100 transition flex items-center gap-0.5">
            {hasAdminPermission('tenant.department.create') && <IconBtn title="新建子部门" onClick={() => onAddChild(node)}><Plus size={12} /></IconBtn>}
            {hasAdminPermission('tenant.department.update') && <IconBtn title="编辑" onClick={() => onEdit(node)}><Edit2 size={12} /></IconBtn>}
            {hasAdminPermission('tenant.department.delete') && <IconBtn title="删除" danger onClick={() => onDelete(node)}><Trash2 size={12} /></IconBtn>}
          </div>
        </span>
      </div>
      {open && node.children.map((c) => (
        <Branch key={c.id} node={c} depth={depth + 1} expanded={expanded} setExpanded={setExpanded}
          onAddChild={onAddChild} onEdit={onEdit} onDelete={onDelete} />
      ))}
    </div>
  )
}

function IconBtn({ children, onClick, title, danger = false }: { children: React.ReactNode; onClick: () => void; title: string; danger?: boolean }) {
  return (
    <button
      title={title}
      onClick={onClick}
      className={`w-6 h-6 grid place-items-center rounded text-[var(--color-text-mute)] hover:bg-white ${danger ? 'hover:text-[var(--color-danger)]' : 'hover:text-[var(--color-text)]'}`}
    >
      {children}
    </button>
  )
}

/* ---------- form modal ---------- */

function DeptFormModal({
  title,
  allDepartments,
  initial,
  parentId,
  onClose,
  onSubmit,
}: {
  title: string
  allDepartments: Department[]
  initial?: Department
  parentId?: number
  onClose: () => void
  onSubmit: (body: { name: string; parent_id?: number | null; sort_order?: number; metadata?: Record<string, unknown> }) => Promise<void>
}) {
  const [name, setName] = useState(initial?.name || '')
  const [externalCode, setExternalCode] = useState(
    (initial?.metadata?.external_code as string) || ''
  )
  const [showAdvanced, setShowAdvanced] = useState(!!externalCode)
  const [parent, setParent] = useState<number | ''>(initial?.parent_id ?? parentId ?? '')
  const [sortOrder, setSortOrder] = useState(initial?.sort_order || 0)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const validParents = useMemo(() => {
    if (!initial) return allDepartments
    const forbid = new Set<number>([initial.id])
    let changed = true
    while (changed) {
      changed = false
      allDepartments.forEach((d) => {
        if (d.parent_id && forbid.has(d.parent_id) && !forbid.has(d.id)) {
          forbid.add(d.id)
          changed = true
        }
      })
    }
    return allDepartments.filter((d) => !forbid.has(d.id))
  }, [allDepartments, initial])

  const submit = async () => {
    if (!name.trim()) { setErr('请填部门名称'); return }
    setBusy(true); setErr('')
    try {
      const meta: Record<string, unknown> = { ...(initial?.metadata || {}) }
      if (externalCode.trim()) meta.external_code = externalCode.trim()
      else delete meta.external_code
      await onSubmit({
        name,
        parent_id: parent === '' ? null : Number(parent),
        sort_order: sortOrder,
        metadata: meta,
      })
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={title} onClose={onClose}>
      <div className="space-y-4">
        <FormField label="部门名称">
          <input value={name} onChange={(e) => setName(e.target.value)} className={inputCls} placeholder="例如：研发部" autoFocus />
        </FormField>
        <FormField label="排序">
          <input type="number" value={sortOrder} onChange={(e) => setSortOrder(Number(e.target.value))} className={inputCls} />
        </FormField>
        <FormField label="上级部门" hint="留空表示顶级部门">
          <Select value={parent} onChange={(e) => setParent(e.target.value === '' ? '' : Number(e.target.value))}>
            <option value="">— 顶级部门 —</option>
            {validParents.map((d) => (
              <option key={d.id} value={d.id}>
                {'　'.repeat(d.depth)}
                {d.name}
              </option>
            ))}
          </Select>
        </FormField>
        <button
          type="button"
          onClick={() => setShowAdvanced((v) => !v)}
          className="text-[12px] text-[var(--color-text-sub)] hover:text-[var(--color-brand)]"
        >
          {showAdvanced ? '收起' : '高级选项 (HR 系统对账)'}
        </button>
        {showAdvanced && (
          <FormField label="外部对账码 (可选)" hint="跟 SAP / Workday / 飞书 对接时填">
            <input
              value={externalCode}
              onChange={(e) => setExternalCode(e.target.value)}
              className={inputCls + ' font-mono'}
              placeholder="例 DEPT-RD-001"
            />
          </FormField>
        )}
      </div>
      {err && <div className="mt-4 text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md px-3 py-2">{err}</div>}
      <div className="flex justify-end gap-2 mt-6">
        <button onClick={onClose} className="h-9 px-3 rounded-md text-[13px] text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)]">取消</button>
        <button onClick={submit} disabled={busy} className="h-9 px-4 rounded-md bg-[var(--color-text)] text-white text-[13px] font-medium hover:bg-black disabled:opacity-60">
          {busy ? '保存中…' : initial ? '保存' : '创建'}
        </button>
      </div>
    </Modal>
  )
}

function ConfirmDelete({ dept, onClose, onConfirm }: { dept: Department; onClose: () => void; onConfirm: () => Promise<void> }) {
  return (
    <ConfirmDialog
      title="删除部门"
      description={<>你将删除部门 <strong className="text-[var(--color-text)]">{dept.name}</strong>。</>}
      confirmLabel="删除"
      busyLabel="删除中..."
      onClose={onClose}
      onConfirm={onConfirm}
    >
      <InlineAlert tone="warn">
        如果该部门下还有子部门或成员，删除会失败。请先把成员迁出或移走子部门。
      </InlineAlert>
    </ConfirmDialog>
  )
}

/* ---------- shared ---------- */

const inputCls = 'w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] focus:outline-none focus:shadow-[var(--color-focus)_0px_0px_0px_2px]'

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 bg-[hsla(0,0%,0%,0.35)] grid place-items-center z-50 px-4 backdrop-blur-sm" onClick={onClose}>
      <div className="bg-white rounded-lg card-shadow w-full max-w-md p-6" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <h3 className="text-[20px] font-semibold tracking-tight">{title}</h3>
          <button onClick={onClose} className="w-7 h-7 grid place-items-center rounded-md hover:bg-[var(--color-line-soft)]"><X size={14} /></button>
        </div>
        {children}
      </div>
    </div>
  )
}

function FormField({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[12px] font-medium text-[var(--color-text)] mb-1">{label}</label>
      {children}
      {hint && <p className="text-[11px] text-[var(--color-text-mute)] mt-1">{hint}</p>}
    </div>
  )
}

function Err({ msg }: { msg: string }) {
  return <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md px-3 py-2 mb-4">{msg}</div>
}
