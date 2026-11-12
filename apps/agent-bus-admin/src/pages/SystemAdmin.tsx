import { useEffect, useMemo, useRef, useState } from 'react'
import { useOutletContext } from 'react-router-dom'
import { ChevronRight, Edit2, Plus, Trash2, X } from 'lucide-react'
import {
  Menus,
  Permissions,
  Roles,
  SysUsers,
  Auth,
  type Menu,
  type MenuInput,
  type Permission,
  type Role,
  type RoleInput,
  type SysUser,
  type SysUserInput,
} from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import { Button, ConfirmDialog, FormField, InlineAlert, Input, Panel } from '../components/ui'
import { iconFor } from '../lib/icons'

type Scope = 'platform' | 'tenant'

export function SysUserList() {
  const [items, setItems] = useState<SysUser[]>([])
  const [roles, setRoles] = useState<Role[]>([])
  const [q, setQ] = useState('')
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<SysUser | null>(null)
  const [creating, setCreating] = useState(false)
  const [deleting, setDeleting] = useState<SysUser | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    Promise.all([SysUsers.list(q), Roles.list('platform')])
      .then(([users, roleResp]) => {
        setItems(users.items || [])
        setRoles(roleResp.items || [])
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [q, tick])

  const refresh = () => setTick((x) => x + 1)

  return (
    <PageShell
      title="系统用户"
      desc="管理可以进入平台后台的内部员工账号。"
      action={<Button size="sm" onClick={() => setCreating(true)}><Plus size={14} />新建用户</Button>}
    >
      <Toolbar q={q} setQ={setQ} placeholder="搜索姓名 / 用户名 / 邮箱 / 手机号" />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['姓名', '登录账号', '平台权限', '角色', '状态', '最近登录', '操作']}
        empty="还没有系统用户"
      >
        {items.map((u) => (
          <tr key={u.id} className="border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60">
            <Td>
              <div className="font-medium">{u.display_name}</div>
              <div className="text-[11px] text-[var(--color-text-mute)] font-mono">{u.uuid.slice(0, 8)}...</div>
            </Td>
            <Td>{u.username || u.email || u.phone || '-'}</Td>
            <Td>{u.is_platform ? <Pill>平台</Pill> : <Muted>无</Muted>}</Td>
            <Td>{u.roles?.length ? u.roles.map((r) => <Pill key={r}>{r}</Pill>) : <Muted>未绑定</Muted>}</Td>
            <Td><Status status={u.status} /></Td>
            <Td>{u.last_login_at || <Muted>未登录</Muted>}</Td>
            <Td>
              <RowActions
                onEdit={() => setEditing(u)}
                onDelete={() => setDeleting(u)}
                deleteLabel="停用"
              />
            </Td>
          </tr>
        ))}
      </DataTable>

      {creating && (
        <SysUserModal
          roles={roles}
          title="新建系统用户"
          onClose={() => setCreating(false)}
          onSubmit={async (body) => {
            await SysUsers.create(body)
            setCreating(false)
            refresh()
          }}
        />
      )}
      {editing && (
        <SysUserModal
          roles={roles}
          title={`编辑系统用户：${editing.display_name}`}
          initial={editing}
          onClose={() => setEditing(null)}
          onSubmit={async (body) => {
            await SysUsers.update(editing.id, body)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmModal
          title="停用系统用户"
          message={`确定停用「${deleting.display_name}」吗？该用户的平台角色会被撤销，已有 token 会立即失效。`}
          confirm="停用"
          danger
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await SysUsers.remove(deleting.id)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </PageShell>
  )
}

export function MenuManager() {
  const [items, setItems] = useState<Menu[]>([])
  const [perms, setPerms] = useState<Permission[]>([])
  const [q, setQ] = useState('')
  const [err, setErr] = useState('')
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Menu | null>(null)
  const [deleting, setDeleting] = useState<Menu | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    Promise.all([Menus.list(true), Permissions.list()])
      .then(([menus, ps]) => {
        setItems(menus.items || [])
        setPerms(ps.items || [])
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [tick])

  const filtered = useMemo(() => {
    const k = q.trim().toLowerCase()
    if (!k) return items
    return items.filter((m) => `${m.name} ${m.route} ${m.scopeKind}`.toLowerCase().includes(k))
  }, [items, q])
  const refresh = () => setTick((x) => x + 1)

  return (
    <PageShell
      title="菜单管理"
      desc="维护后台左侧菜单、可见状态与菜单权限点。"
      action={<Button size="sm" onClick={() => setCreating(true)}><Plus size={14} />新建菜单</Button>}
    >
      <Toolbar q={q} setQ={setQ} placeholder="搜索菜单名称 / 路由 / scope" />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable headers={['名称', '路由', '范围', '排序', '可见', '系统', '操作']} empty="没有菜单">
        {filtered.map((m) => (
          <tr key={m.id} className="border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60">
            <Td>
              <div className="font-medium" style={{ paddingLeft: m.depth * 16 }}>{m.name}</div>
              <div className="text-[11px] text-[var(--color-text-mute)] font-mono">{m.path}</div>
            </Td>
            <Td><code>{m.route || '-'}</code></Td>
            <Td><Pill>{scopeLabel(m.scopeKind)}</Pill></Td>
            <Td>{m.sortOrder}</Td>
            <Td>{m.isVisible ? '显示' : <Muted>隐藏</Muted>}</Td>
            <Td>{m.isSystem ? <Pill>系统</Pill> : <Muted>自定义</Muted>}</Td>
            <Td><RowActions onEdit={() => setEditing(m)} onDelete={() => setDeleting(m)} disableDelete={m.isSystem} /></Td>
          </tr>
        ))}
      </DataTable>

      {creating && (
        <MenuModal
          title="新建菜单"
          menus={items}
          permissions={perms}
          onClose={() => setCreating(false)}
          onSubmit={async (body) => {
            await Menus.create(body)
            setCreating(false)
            refresh()
          }}
        />
      )}
      {editing && (
        <MenuModal
          title={`编辑菜单：${editing.name}`}
          menus={items}
          permissions={perms}
          initial={editing}
          onClose={() => setEditing(null)}
          onSubmit={async (body) => {
            await Menus.update(editing.id, body)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmModal
          title="删除菜单"
          message={`确定删除「${deleting.name}」吗？系统预置菜单不可删除。`}
          confirm="删除"
          danger
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await Menus.remove(deleting.id)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </PageShell>
  )
}

export function RoleManager() {
  const { actScope } = useOutletContext<LayoutOutletContext>()
  const scope: Scope = actScope?.kind === 'tenant' || actScope?.kind === 'workspace' ? 'tenant' : 'platform'
  const [items, setItems] = useState<Role[]>([])
  const [perms, setPerms] = useState<Permission[]>([])
  const [menus, setMenus] = useState<Menu[]>([])
  const [q, setQ] = useState('')
  const [err, setErr] = useState('')
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Role | null>(null)
  const [deleting, setDeleting] = useState<Role | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    Promise.all([Roles.list(scope, q), Permissions.list(scope), Auth.menus()])
      .then(([roles, ps, menuResp]) => {
        setItems(roles.items || [])
        setPerms(ps.items || [])
        setMenus(menuResp || [])
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [scope, q, tick])

  const refresh = () => setTick((x) => x + 1)

  return (
    <PageShell
      title={scope === 'platform' ? '平台角色' : '租户角色'}
      desc="维护角色与权限点集合；系统预置角色只读。"
      action={<Button size="sm" onClick={() => setCreating(true)}><Plus size={14} />新建角色</Button>}
    >
      <Toolbar q={q} setQ={setQ} placeholder="搜索角色编码 / 名称" />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable headers={['名称', '编码', '范围', '类型', '创建时间', '操作']} empty="没有角色">
        {items.map((r) => (
          <tr key={r.ID} className="border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60">
            <Td>
              <div className="font-medium">{r.Name}</div>
              {roleDescription(r) && <div className="text-[12px] text-[var(--color-text-mute)]">{roleDescription(r)}</div>}
            </Td>
            <Td><code>{r.Code}</code></Td>
            <Td><Pill>{scopeLabel(r.ScopeKind)}</Pill></Td>
            <Td>{isPresetRole(r) ? <Pill>系统预置</Pill> : <Muted>自定义</Muted>}</Td>
            <Td>{new Date(r.CreatedAt).toLocaleString()}</Td>
            <Td><RowActions onEdit={() => setEditing(r)} onDelete={() => setDeleting(r)} disableDelete={isPresetRole(r)} /></Td>
          </tr>
        ))}
      </DataTable>

      {creating && (
        <RoleModal
          title="新建角色"
          scope={scope}
          permissions={perms}
          menus={menus}
          onClose={() => setCreating(false)}
          onSubmit={async (body) => {
            await Roles.create(scope, body)
            setCreating(false)
            refresh()
          }}
        />
      )}
      {editing && (
        <RoleModal
          title={`编辑角色：${editing.Name}`}
          scope={scope}
          role={editing}
          permissions={perms}
          menus={menus}
          onClose={() => setEditing(null)}
          onSubmit={async (body) => {
            await Roles.update(scope, editing.ID, body)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmModal
          title="删除角色"
          message={`确定删除「${deleting.Name}」吗？系统预置角色不可删除。`}
          confirm="删除"
          danger
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await Roles.remove(scope, deleting.ID)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </PageShell>
  )
}

function SysUserModal({ title, roles, initial, onClose, onSubmit }: {
  title: string; roles: Role[]; initial?: SysUser; onClose: () => void; onSubmit: (body: SysUserInput) => Promise<void>
}) {
  const [form, setForm] = useState<SysUserInput>({
    display_name: initial?.display_name || '',
    username: initial?.username || '',
    email: initial?.email || '',
    phone: initial?.phone || '',
    status: initial?.status || 'active',
    is_platform: initial?.is_platform ?? true,
    must_change_password: initial?.must_change_password ?? true,
    mfa_enabled: initial?.mfa_enabled ?? false,
    notes: initial?.notes || '',
    role_ids: initial?.role_ids || [],
  })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  return (
    <Modal title={title} onClose={onClose}>
      <div className="grid grid-cols-2 gap-4">
        <FormField label="姓名"><Input value={form.display_name || ''} onChange={(e) => setForm({ ...form, display_name: e.target.value })} /></FormField>
        <FormField label="用户名"><Input value={form.username || ''} onChange={(e) => setForm({ ...form, username: e.target.value })} /></FormField>
        <FormField label="邮箱"><Input value={form.email || ''} onChange={(e) => setForm({ ...form, email: e.target.value })} /></FormField>
        <FormField label="手机号"><Input value={form.phone || ''} onChange={(e) => setForm({ ...form, phone: e.target.value })} /></FormField>
        {!initial && <FormField label="初始密码"><Input value={form.password || ''} placeholder="请输入初始密码" onChange={(e) => setForm({ ...form, password: e.target.value })} /></FormField>}
        <FormField label="状态">
          <select className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px]" value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
            <option value="active">启用</option>
            <option value="suspended">暂停</option>
            <option value="locked">锁定</option>
          </select>
        </FormField>
      </div>
      <CheckRow label="平台访问权限" checked={!!form.is_platform} onChange={(v) => setForm({ ...form, is_platform: v })} />
      <CheckRow label="首次登录强制改密" checked={!!form.must_change_password} onChange={(v) => setForm({ ...form, must_change_password: v })} />
      <CheckRow label="已启用 MFA" checked={!!form.mfa_enabled} onChange={(v) => setForm({ ...form, mfa_enabled: v })} />
      <RoleChecks roles={roles} selected={form.role_ids || []} onChange={(role_ids) => setForm({ ...form, role_ids })} />
      <FormField label="备注"><Input value={form.notes || ''} onChange={(e) => setForm({ ...form, notes: e.target.value })} /></FormField>
      {err && <InlineAlert>{err}</InlineAlert>}
      <ModalFooter busy={busy} onClose={onClose} onSubmit={async () => {
        if (!form.display_name?.trim()) { setErr('请填写姓名'); return }
        if (!initial && !form.password?.trim()) { setErr('请填写初始密码'); return }
        setBusy(true); setErr('')
        try { await onSubmit(form) } catch (e) { setErr((e as Error).message); setBusy(false) }
      }} />
    </Modal>
  )
}

function MenuModal({ title, menus, permissions, initial, onClose, onSubmit }: {
  title: string; menus: Menu[]; permissions: Permission[]; initial?: Menu; onClose: () => void; onSubmit: (body: MenuInput) => Promise<void>
}) {
  const [form, setForm] = useState<MenuInput>({
    parentId: initial?.parentId || null,
    name: initial?.name || '',
    icon: initial?.icon || 'puzzle',
    route: initial?.route || '',
    sortOrder: initial?.sortOrder || 0,
    scopeKind: initial?.scopeKind || 'platform',
    isVisible: initial?.isVisible ?? true,
    metadata: initial?.metadata || {},
    permissionIds: [],
  })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  useEffect(() => {
    if (!initial) return
    Menus.get(initial.id)
      .then((d) => setForm((f) => ({ ...f, permissionIds: d.permissionIds || [] })))
      .catch(() => {})
  }, [initial])
  const parentOptions = menus.filter((m) => !initial || m.id !== initial.id)
  return (
    <Modal title={title} onClose={onClose}>
      {initial?.isSystem && <InlineAlert tone="info">系统预置菜单只允许修改名称、图标、排序、显示状态和 metadata。</InlineAlert>}
      <div className="grid grid-cols-2 gap-4">
        <FormField label="名称"><Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></FormField>
        <FormField label="图标"><Input value={form.icon || ''} onChange={(e) => setForm({ ...form, icon: e.target.value })} /></FormField>
        <FormField label="路由"><Input disabled={initial?.isSystem} value={form.route || ''} onChange={(e) => setForm({ ...form, route: e.target.value })} /></FormField>
        <FormField label="排序"><Input type="number" value={form.sortOrder || 0} onChange={(e) => setForm({ ...form, sortOrder: Number(e.target.value) })} /></FormField>
        <FormField label="作用范围">
          <select disabled={initial?.isSystem} className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px]" value={form.scopeKind} onChange={(e) => setForm({ ...form, scopeKind: e.target.value as Menu['scopeKind'] })}>
            {['platform', 'tenant', 'workspace', 'self', 'any'].map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </FormField>
        <FormField label="父级">
          <select className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px]" value={form.parentId || ''} onChange={(e) => setForm({ ...form, parentId: e.target.value ? Number(e.target.value) : null })}>
            <option value="">无</option>
            {parentOptions.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
          </select>
        </FormField>
      </div>
      <CheckRow label="左侧菜单可见" checked={form.isVisible} onChange={(v) => setForm({ ...form, isVisible: v })} />
      <PermissionChecks permissions={permissions} selected={form.permissionIds || []} onChange={(permissionIds) => setForm({ ...form, permissionIds })} />
      {err && <InlineAlert>{err}</InlineAlert>}
      <ModalFooter busy={busy} onClose={onClose} onSubmit={async () => {
        if (!form.name.trim()) { setErr('请填写菜单名称'); return }
        setBusy(true); setErr('')
        try { await onSubmit(form) } catch (e) { setErr((e as Error).message); setBusy(false) }
      }} />
    </Modal>
  )
}

function RoleModal({ title, scope, permissions, menus, role, onClose, onSubmit }: {
  title: string; scope: Scope; permissions: Permission[]; menus: Menu[]; role?: Role; onClose: () => void; onSubmit: (body: RoleInput) => Promise<void>
}) {
  const [form, setForm] = useState<RoleInput>({ code: role?.Code || '', name: role?.Name || '', description: role?.Description || '', permissionIds: [] })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  useEffect(() => {
    if (!role) return
    Roles.get(scope, role.ID)
      .then((d) => setForm((f) => ({ ...f, permissionIds: d.permissionIds || [] })))
      .catch(() => {})
  }, [role, scope])
  const readonly = !!role && isPresetRole(role)
  return (
    <Modal title={title} onClose={onClose}>
      {readonly && <InlineAlert tone="info">系统预置角色只读，不能修改权限点或删除。</InlineAlert>}
      <div className="grid grid-cols-2 gap-4">
        <FormField label="角色名称"><Input disabled={readonly} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></FormField>
        <FormField label="角色编码"><Input disabled={!!role} value={form.code || ''} onChange={(e) => setForm({ ...form, code: e.target.value })} /></FormField>
      </div>
      <FormField label="描述"><Input disabled={readonly} value={form.description || ''} onChange={(e) => setForm({ ...form, description: e.target.value })} /></FormField>
      <PermissionChecks roleTree scope={scope} disabled={readonly} permissions={permissions} menus={menus} selected={form.permissionIds || []} onChange={(ids) => setForm({ ...form, permissionIds: ids })} />
      {err && <InlineAlert>{err}</InlineAlert>}
      {!readonly && <ModalFooter busy={busy} onClose={onClose} onSubmit={async () => {
        if (!form.name.trim() || (!role && !form.code?.trim())) { setErr('请填写名称和编码'); return }
        setBusy(true); setErr('')
        try { await onSubmit(form) } catch (e) { setErr((e as Error).message); setBusy(false) }
      }} />}
    </Modal>
  )
}

function PageShell({ title, desc, action, children }: { title: string; desc: string; action?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div>
      <div className="mb-6 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-[28px] font-semibold tracking-tight">{title}</h1>
          <p className="mt-1 text-[14px] text-[var(--color-text-sub)]">{desc}</p>
        </div>
        {action}
      </div>
      <div className="space-y-4">{children}</div>
    </div>
  )
}

function Toolbar({ q, setQ, placeholder }: { q: string; setQ: (v: string) => void; placeholder: string }) {
  return <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder={placeholder} className="max-w-md" />
}

function DataTable({ headers, empty, children }: { headers: string[]; empty: string; children: React.ReactNode }) {
  const hasRows = Array.isArray(children) ? children.length > 0 : !!children
  return (
    <Panel className="overflow-hidden p-0">
      <table className="w-full text-[13px]">
        <thead><tr className="bg-[var(--color-bg-sub)] text-left">{headers.map((h) => <Th key={h}>{h}</Th>)}</tr></thead>
        <tbody>{hasRows ? children : <tr><td colSpan={headers.length} className="px-4 py-10 text-center text-[var(--color-text-mute)]">{empty}</td></tr>}</tbody>
      </table>
    </Panel>
  )
}

function Th({ children }: { children: React.ReactNode }) {
  return <th className="px-4 py-2.5 text-[13px] text-left font-semibold text-[var(--color-text)]">{children}</th>
}
function Td({ children }: { children: React.ReactNode }) {
  return <td className="px-4 py-3 align-top">{children}</td>
}
function Muted({ children }: { children: React.ReactNode }) {
  return <span className="text-[var(--color-text-mute)]">{children}</span>
}
function Pill({ children }: { children: React.ReactNode }) {
  return <span className="mr-1 inline-flex rounded bg-[var(--color-line-soft)] px-1.5 py-0.5 text-[11px] text-[var(--color-text-sub)]">{children}</span>
}

function scopeLabel(scope: string) {
  const map: Record<string, string> = {
    platform: '平台',
    tenant: '租户',
    workspace: '部门',
    self: '个人',
    any: '通用',
    me: '个人',
  }
  return map[scope] || scope
}

function isPresetRole(role: Pick<Role, 'Code' | 'IsSystem'>) {
  return role.IsSystem || ['platform.admin', 'platform.operator', 'platform.auditor', 'tenant.admin', 'tenant.operator', 'tenant.member'].includes(role.Code)
}

function roleDescription(role: Pick<Role, 'Code' | 'Description'>) {
  const defaults: Record<string, string> = {
    'platform.operator': '日常运营与部分平台配置',
    'platform.auditor': '只读查看与审计相关权限',
    'tenant.admin': '拥有本租户全部管理权限',
    'tenant.operator': '管理成员、组织、数字员工和日常运营配置',
    'tenant.member': '普通成员，可使用客户端与个人能力',
  }
  const raw = defaults[role.Code] || role.Description || ''
  return raw.replace(/\s*\[[^\]]*M1[^\]]*\]\s*/g, '').trim()
}
function Status({ status }: { status: string }) {
  const label: Record<string, string> = { active: '启用', suspended: '暂停', locked: '锁定', pending: '待激活' }
  return <span>{label[status] || status}</span>
}

function RowActions({ onEdit, onDelete, disableDelete = false, deleteLabel = '删除' }: { onEdit: () => void; onDelete: () => void; disableDelete?: boolean; deleteLabel?: string }) {
  return (
    <div className="flex items-center gap-1">
      <Button variant="ghost" size="sm" onClick={onEdit}><Edit2 size={13} />编辑</Button>
      <Button variant="ghost" size="sm" disabled={disableDelete} onClick={onDelete}><Trash2 size={13} />{deleteLabel}</Button>
    </div>
  )
}

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/25 p-6">
      <div className="w-full max-w-3xl rounded-lg bg-white p-6 shadow-[rgba(0,0,0,0.18)_0px_12px_40px]">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="text-[22px] font-semibold">{title}</h2>
          <button aria-label="关闭" onClick={onClose} className="grid h-8 w-8 place-items-center rounded-md hover:bg-[var(--color-line-soft)]"><X size={16} /></button>
        </div>
        <div className="space-y-4">{children}</div>
      </div>
    </div>
  )
}

function ModalFooter({ busy, onClose, onSubmit }: { busy: boolean; onClose: () => void; onSubmit: () => void }) {
  return (
    <div className="flex justify-end gap-2 pt-2">
      <Button variant="ghost" onClick={onClose}>取消</Button>
      <Button disabled={busy} onClick={onSubmit}>{busy ? '保存中...' : '保存'}</Button>
    </div>
  )
}

function ConfirmModal({ title, message, confirm, danger, onClose, onConfirm }: { title: string; message: string; confirm: string; danger?: boolean; onClose: () => void; onConfirm: () => Promise<void> }) {
  return (
    <ConfirmDialog
      title={title}
      description={message}
      confirmLabel={confirm}
      busyLabel={`${confirm}中...`}
      tone={danger ? 'danger' : 'info'}
      onClose={onClose}
      onConfirm={onConfirm}
    />
  )
}

function CheckRow({ label, checked, onChange }: { label: string; checked: boolean; onChange: (v: boolean) => void }) {
  return <label className="flex items-center gap-2 text-[13px]"><input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />{label}</label>
}

function RoleChecks({ roles, selected, onChange }: { roles: Role[]; selected: number[]; onChange: (ids: number[]) => void }) {
  return (
    <CheckGrid title="平台角色">
      {roles.map((r) => <CheckChip key={r.ID} label={r.Name} title={r.Code} checked={selected.includes(r.ID)} onChange={(v) => onChange(toggleId(selected, r.ID, v))} />)}
    </CheckGrid>
  )
}

function PermissionChecks({ permissions, menus = [], selected, onChange, disabled = false, roleTree = false, scope = 'platform' }: {
  permissions: Permission[]
  menus?: Menu[]
  selected: number[]
  onChange: (ids: number[]) => void
  disabled?: boolean
  roleTree?: boolean
  scope?: Scope
}) {
  const visible = roleTree ? permissions.filter(isRoleEditorPermissionVisible) : permissions
  if (roleTree) {
    return (
      <PermissionTreeChecks
        scope={scope}
        permissions={visible}
        menus={menus}
        selected={selected}
        disabled={disabled}
        onChange={onChange}
      />
    )
  }
  const groups = groupPermissions(visible)
  return (
    <CheckGrid title="权限点">
      {groups.map((group) => (
        <div key={group.name} className="col-span-2">
          <div className="px-2 py-1 text-[12px] font-medium text-[var(--color-text-sub)]">{group.name}</div>
          <div className="grid grid-cols-2 gap-1">
            {group.items.map((p) => (
              <CheckChip
                key={p.ID}
                disabled={disabled}
                label={roleTree ? `${actionLabel(p)} · ${p.Name}` : `${p.Code} · ${p.Name}`}
                checked={selected.includes(p.ID)}
                onChange={(v) => onChange(toggleId(selected, p.ID, v))}
              />
            ))}
          </div>
        </div>
      ))}
    </CheckGrid>
  )
}

function PermissionTreeChecks({ scope, permissions, menus, selected, onChange, disabled = false }: {
  scope: Scope
  permissions: Permission[]
  menus: Menu[]
  selected: number[]
  onChange: (ids: number[]) => void
  disabled?: boolean
}) {
  const groups = useMemo(() => groupRolePermissions(permissions, menus, scope), [permissions, menus, scope])
  const defaultOpen = useMemo(() => {
    const keys = new Set<string>()
    groups.slice(0, 2).forEach((group) => {
      keys.add(group.key)
      group.items.forEach((item) => keys.add(item.key))
    })
    return keys
  }, [groups])
  const [openKeys, setOpenKeys] = useState<Set<string> | null>(null)
  const open = openKeys || defaultOpen

  const setGroup = (ids: number[], enabled: boolean) => {
    const next = new Set(selected)
    ids.forEach((id) => {
      if (enabled) next.add(id)
      else next.delete(id)
    })
    onChange(Array.from(next))
  }

  return (
    <div>
      <div className="mb-2 text-[13px] font-medium">权限点</div>
      <div className="max-h-64 overflow-auto rounded-md border border-[var(--color-line)] bg-white">
        {groups.map((group) => {
          const isOpen = open.has(group.key)
          const groupIds = permissionTreeGroupIds(group)
          const checkedCount = groupIds.filter((id) => selected.includes(id)).length
          const allChecked = checkedCount > 0 && checkedCount === groupIds.length
          const partialChecked = checkedCount > 0 && checkedCount < groupIds.length
          const Icon = iconFor(group.icon)
          return (
            <div key={group.key} className="border-b border-[var(--color-line-soft)] last:border-b-0">
              <div className="flex h-8 items-center gap-2 px-3">
                <button
                  type="button"
                  className="grid h-5 w-5 place-items-center rounded text-[var(--color-text-mute)] hover:bg-[var(--color-line-soft)]"
                  onClick={() => {
                    const next = new Set(open)
                    if (isOpen) next.delete(group.key)
                    else next.add(group.key)
                    setOpenKeys(next)
                  }}
                  aria-label={isOpen ? '收起权限分组' : '展开权限分组'}
                >
                  <ChevronRight size={14} className={isOpen ? 'rotate-90 transition-transform' : 'transition-transform'} />
                </button>
                <TreeCheckbox
                  disabled={disabled}
                  checked={allChecked}
                  indeterminate={partialChecked}
                  onChange={(v) => setGroup(groupIds, v)}
                />
                <Icon size={16} className="shrink-0 text-[var(--color-brand)]" />
                <span className="truncate text-[13px] font-medium">{group.name}</span>
              </div>
              {isOpen && (
                <div className="ml-[34px] border-l border-dashed border-[var(--color-line)] pb-1">
                  {group.items.map((item) => {
                    const itemOpen = open.has(item.key)
                    const itemIds = item.items.map((p) => p.ID)
                    const itemCheckedCount = itemIds.filter((id) => selected.includes(id)).length
                    const itemAllChecked = itemCheckedCount > 0 && itemCheckedCount === itemIds.length
                    const itemPartialChecked = itemCheckedCount > 0 && itemCheckedCount < itemIds.length
                    const ItemIcon = iconFor(item.icon)
                    return (
                      <div key={item.key} className="mr-3 border-t border-[var(--color-line-soft)] first:border-t-0">
                        <div className="flex h-[30px] items-center gap-2 pl-3 pr-3">
                          <button
                            type="button"
                            className="grid h-5 w-5 place-items-center rounded text-[var(--color-text-mute)] hover:bg-[var(--color-line-soft)]"
                            onClick={() => {
                              const next = new Set(open)
                              if (itemOpen) next.delete(item.key)
                              else next.add(item.key)
                              setOpenKeys(next)
                            }}
                            aria-label={itemOpen ? '收起菜单权限' : '展开菜单权限'}
                          >
                            <ChevronRight size={14} className={itemOpen ? 'rotate-90 transition-transform' : 'transition-transform'} />
                          </button>
                          <TreeCheckbox
                            disabled={disabled}
                            checked={itemAllChecked}
                            indeterminate={itemPartialChecked}
                            onChange={(v) => setGroup(itemIds, v)}
                          />
                          <ItemIcon size={15} className="shrink-0 text-[var(--color-brand)]" />
                          <span className="truncate text-[13px] text-[var(--color-text)]">{item.name}</span>
                        </div>
                        {itemOpen && (
                          <div className="ml-[34px] border-l border-dashed border-[var(--color-line)] py-1 pl-3">
                            <div className="grid grid-cols-[repeat(2,minmax(120px,180px))] gap-x-6 gap-y-0">
                              {item.items.map((p) => (
                                <CheckChip
                                  key={p.ID}
                                  disabled={disabled}
                                  label={permissionDisplayLabel(p)}
                                  title={`${p.Code} · ${p.Name}`}
                                  checked={selected.includes(p.ID)}
                                  onChange={(v) => onChange(toggleId(selected, p.ID, v))}
                                />
                              ))}
                            </div>
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function TreeCheckbox({ checked, indeterminate, disabled, onChange }: {
  checked: boolean
  indeterminate: boolean
  disabled?: boolean
  onChange: (v: boolean) => void
}) {
  const ref = useRef<HTMLInputElement | null>(null)
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = indeterminate
  }, [indeterminate])
  return (
    <input
      ref={ref}
      disabled={disabled}
      type="checkbox"
      checked={checked}
      onChange={(e) => onChange(e.target.checked)}
      aria-checked={indeterminate ? 'mixed' : checked}
    />
  )
}

function isRoleEditorPermissionVisible(p: Permission) {
  if (p.ScopeKind === 'platform' && ['alert', 'composer_skill', 'emp', 'params'].includes(p.Resource)) return false
  return true
}

function groupPermissions(permissions: Permission[]) {
  const m = new Map<string, Permission[]>()
  permissions.forEach((p) => {
    const group = permissionGroupLabel(p)
    m.set(group, [...(m.get(group) || []), p])
  })
  return Array.from(m.entries()).map(([name, items]) => ({ name, items }))
}

type PermissionTreeGroup = {
  key: string
  name: string
  icon: string
  sortOrder: number
  items: PermissionTreeMenu[]
}

type PermissionTreeMenu = {
  key: string
  name: string
  icon: string
  sortOrder: number
  items: Permission[]
}

function groupRolePermissions(permissions: Permission[], menus: Menu[], scope: Scope) {
  const groups = new Map<string, PermissionTreeGroup>()
  permissions.forEach((p) => {
    const matchedMenus = menusForPermission(p, menus)
    const targets = matchedMenus.length > 0 ? matchedMenus : [null]
    targets.forEach((menu) => {
      const groupName = menu ? roleTreeMenuGroup(menu, scope) : '其他权限'
      const groupKey = menu ? `${scope}.group.${groupName}` : `${scope}.group.other`
      const group = groups.get(groupKey) || {
        key: groupKey,
        name: groupName,
        icon: roleTreeGroupIcon(groupName),
        sortOrder: roleTreeGroupOrder(groupName, scope),
        items: [],
      }

      const itemKey = menu ? `${menu.scopeKind}:${menu.route}` : `${p.ScopeKind}.${p.Resource || 'other'}`
      const currentItem = group.items.find((item) => item.key === itemKey)
      const item: PermissionTreeMenu = currentItem || {
        key: itemKey,
        name: menu ? roleTreeMenuDisplayName(menu) : permissionGroupLabel(p),
        icon: menu?.icon || permissionResourceIcon(p),
        sortOrder: menu ? roleTreeMenuItemOrder(menu, groupName) : p.SortOrder || 9999,
        items: [],
      }
      if (!item.items.some((existing) => existing.ID === p.ID)) {
        item.items = [...item.items, p].sort((a, b) => (a.SortOrder || 0) - (b.SortOrder || 0))
      }
      if (!currentItem) group.items.push(item)
      group.items.sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name))
      groups.set(groupKey, group)
    })
  })
  return Array.from(groups.values()).sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name))
}

function permissionTreeGroupIds(group: PermissionTreeGroup) {
  return group.items.flatMap((item) => item.items.map((p) => p.ID))
}

function menusForPermission(p: Permission, menus: Menu[]) {
  const routes = permissionResourceRoutes(p)
  return routes
    .map((route) => menus.find((m) => m.route === route && (m.scopeKind === p.ScopeKind || m.scopeKind === 'any')))
    .filter((menu): menu is Menu => Boolean(menu))
}

function permissionResourceRoutes(p: Permission) {
  if (p.ScopeKind === 'tenant' && p.Resource === 'agent') {
    return tenantAgentPermissionRoutes(p)
  }
  const byScope: Record<string, Record<string, string[]>> = {
    platform: {
      overview: ['/dashboard'],
      tenant: ['/tenants'],
      plan: ['/billing/plans', '/billing/features', '/billing/credits'],
      billing: ['/billing/plans', '/billing/features', '/billing/credits', '/billing/orders', '/billing/config', '/billing/usage'],
      runtime: ['/runtime-hosting', '/runtimes'],
      runtime_env: ['/runtime-environments', '/runtimes'],
      preset_agent: ['/preset-agents'],
      drive: ['/drive/storage', '/drive/usage', '/drive/workers'],
      kb_provider: ['/kb-providers'],
      kb: ['/kb-providers', '/platform-kb'],
      cron: ['/cron-dashboard', '/cron-jobs', '/cron-prompt-templates-ops'],
      app: ['/apps'],
      app_category: ['/app-categories'],
      skill: ['/skills'],
      role: ['/roles'],
      menu: ['/menus'],
      sysuser: ['/sys-users'],
      audit: ['/audit'],
      observability: ['/observability/call-logs'],
    },
    tenant: {
      overview: ['/dashboard'],
      billing: ['/billing/subscription', '/billing/usage'],
      runtime_env: ['/runtime-environments'],
      skill: ['/tenant-skills/platform', '/tenant-skills/own', '/skills'],
      app: ['/apps', '/workspace-apps'],
      app_category: ['/app-categories'],
      kb: ['/kb'],
      drive: ['/drive', '/drive/quotas'],
      department: ['/departments'],
      member: ['/members'],
      position: ['/positions'],
      org_webhook: ['/org-sync'],
      role: ['/roles'],
      audit: ['/audit'],
      observability: ['/observability/call-logs'],
      api_key: ['/api-keys'],
      agent_sdk: ['/agent-sdk-credentials'],
      identity_provider: ['/sso-config'],
      mcp: ['/mcp'],
      room: ['/rooms'],
      approval: [],
    },
    workspace: {
      agent: ['/agents'],
      kb: ['/kb'],
    },
    self: {
      account: ['/me/profile'],
      session: ['/me/sessions'],
    },
  }
  return byScope[p.ScopeKind]?.[p.Resource] || []
}

function tenantAgentPermissionRoutes(p: Permission) {
  if (p.Action === 'read') {
    return ['/agents', '/rooms']
  }
  if (p.Action === 'update') {
    return ['/agents']
  }
  return ['/agents']
}

function roleTreeMenuGroup(menu: Menu, scope: Scope) {
  if (menu.route === '/dashboard') return '概览'
  if (scope === 'platform') {
    if (menu.route === '/tenants') return '租户管理'
    if (menu.route === '/plans' ||
        menu.route === '/billing/plans' ||
        menu.route === '/billing/features' ||
        menu.route === '/billing/credits' ||
        menu.route === '/billing/orders' ||
        menu.route === '/billing/config' ||
        menu.route === '/billing/usage' ||
        menu.route === '/billing/overrides') {
      return '计费中心'
    }
    if (menu.route === '/runtimes' || menu.route === '/runtime-environments' ||
        menu.route === '/runtime-hosting' || menu.route === '/platform-types' || menu.route === '/preset-agents' ||
        menu.route === '/emp-blocks') {
      return 'Agent 平台'
    }
    if (menu.route === '/skills' || menu.route === '/skill-categories' ||
        menu.route === '/skill-labels' || menu.route === '/builtin-keys') {
      return '技能中心'
    }
    if (menu.route === '/apps' || menu.route === '/app-categories') return '应用管理'
    if (menu.route === '/kb-providers' || menu.route === '/ragflow-ops' || menu.route === '/platform-kb') return '知识库'
    if (menu.route === '/drive/storage' || menu.route === '/drive/usage' || menu.route === '/drive/workers') return '云盘'
    if (menu.route === '/cron-dashboard' || menu.route === '/cron-jobs' || menu.route === '/cron-prompt-templates-ops') return '任务与自动化'
    if (menu.route === '/menus' || menu.route === '/sys-users' || menu.route === '/roles') return '系统管理'
    if (menu.route === '/alerts' || menu.route === '/wukongim' || menu.route === '/observability/agent-runs') return '监控与告警'
    if (menu.route === '/audit' || menu.route === '/observability/call-logs') return '审计与合规'
    if (menu.route === '/support-feedback' ||
        menu.route === '/marketing-leads' ||
        menu.route === '/download-channels' ||
        menu.route === '/client-versions' ||
        menu.route === '/local-coding-tool-versions' ||
        menu.route === '/client-analytics') {
      return '平台管理'
    }
  } else {
    if (menu.route === '/billing/subscription' || menu.route === '/billing/usage') return '计费中心'
    if (menu.route === '/agents' || menu.route === '/runtime-environments') return '数字员工'
    if (menu.route === '/tenant-skills/platform' || menu.route === '/tenant-skills/own') return '技能中心'
    if (menu.route === '/apps' || menu.route === '/workspace-apps' || menu.route === '/app-categories') return '应用管理'
    if (menu.route === '/kb' || menu.route === '/kb-documents' || menu.route === '/user-kb-inspect') return '知识库'
    if (menu.route === '/drive' || menu.route === '/drive/quotas' ||
        menu.route === '/drive/recycle' || menu.route === '/drive/storage-override') return '云盘'
    if (menu.route === '/cron' || menu.route === '/cron-jobs' || menu.route === '/cron-prompt-templates') return '任务'
    if (menu.route === '/members' || menu.route === '/departments' ||
        menu.route === '/positions' || menu.route === '/contacts') {
      return '组织与人员'
    }
    if (menu.route === '/rooms') return '群聊与协同'
    if (menu.route === '/api-keys' || menu.route === '/agent-sdk-credentials' || menu.route === '/sso-config') return '凭证与接入'
    if (menu.route === '/roles') return '系统管理'
    if (menu.route === '/audit' || menu.route === '/observability/call-logs') return '审计与合规'
  }
  const configured = typeof menu.metadata?.group === 'string' ? menu.metadata.group.trim() : ''
  if (configured === '审计与设置') return '审计与合规'
  if (configured) return configured
  return '其他'
}

function roleTreeGroupIcon(group: string) {
  const map: Record<string, string> = {
    概览: 'layout-dashboard',
    租户管理: 'building-2',
    计费中心: 'layers',
    'Agent 平台': 'cpu',
    技能中心: 'wand',
    应用管理: 'sliders',
    知识库: 'book-open',
    云盘: 'hard-drive',
    群组与协同: 'message-square',
    任务与自动化: 'check-square',
    任务: 'check-square',
    系统管理: 'shield',
    审计与合规: 'shield-check',
    平台管理: 'settings',
    数字员工: 'bot',
    组织与人员: 'users',
    审批与协同: 'message-square',
    群聊与协同: 'message-square',
    凭证与接入: 'key',
    其他: 'puzzle',
    其他权限: 'puzzle',
  }
  return map[group] || 'puzzle'
}

function roleTreeGroupOrder(group: string, scope: Scope) {
  const platform = ['概览', '租户管理', '计费中心', 'Agent 平台', '技能中心', '应用管理', '知识库', '云盘', '群组与协同', '任务与自动化', '系统管理', '审计与合规', '平台管理', '其他权限', '其他']
  const tenant = ['概览', '计费中心', '数字员工', '技能中心', '应用管理', '知识库', '云盘', '任务', '组织与人员', '群聊与协同', '凭证与接入', '系统管理', '审计与合规', '其他权限', '其他']
  const groups = scope === 'platform' ? platform : tenant
  const idx = groups.indexOf(group)
  return idx >= 0 ? (idx + 1) * 100 : 9999
}

function roleTreeMenuItemOrder(menu: Menu, group: string) {
  const byGroup: Record<string, Record<string, number>> = {
    概览: { '/dashboard': 10 },
    租户管理: { '/tenants': 10 },
    计费中心: {
      '/plans': 5,
      '/billing/plans': 10,
      '/billing/features': 20,
      '/billing/credits': 30,
      '/billing/orders': 40,
      '/billing/config': 50,
      '/billing/usage': 60,
      '/billing/overrides': 90,
    },
    'Agent 平台': { '/platform-types': 10, '/runtime-hosting': 20, '/runtime-environments': 30, '/preset-agents': 40, '/runtimes': 50, '/emp-blocks': 50 },
    技能中心: {
      '/skills': 10,
      '/skill-categories': 20,
      '/skill-labels': 30,
      '/builtin-keys': 40,
      '/tenant-skills/platform': 10,
      '/tenant-skills/own': 20,
    },
    应用管理: { '/apps': 10, '/workspace-apps': 15, '/app-categories': 20 },
    知识库: { '/kb-providers': 10, '/platform-kb': 15, '/ragflow-ops': 20, '/kb': 30, '/kb-documents': 40, '/user-kb-inspect': 90 },
    云盘: { '/drive/storage': 10, '/drive/usage': 20, '/drive/workers': 30, '/drive': 50, '/drive/quotas': 60, '/drive/recycle': 70, '/drive/storage-override': 80 },
    任务与自动化: { '/cron-dashboard': 10, '/cron-jobs': 20, '/cron-prompt-templates-ops': 30 },
    任务: { '/cron': 10, '/cron-prompt-templates': 20 },
    数字员工: { '/agents': 10, '/runtime-environments': 20 },
    组织与人员: { '/members': 10, '/departments': 20, '/positions': 30, '/org-sync': 40, '/contacts': 50 },
    系统管理: { '/roles': 10, '/menus': 20, '/sys-users': 30 },
    审批与协同: { '/approvals': 10 },
    群聊与协同: { '/rooms': 10 },
    凭证与接入: { '/api-keys': 10, '/agent-sdk-credentials': 20, '/sso-config': 30 },
    监控与告警: { '/alerts': 10, '/wukongim': 20, '/observability/agent-runs': 30 },
    审计与合规: { '/audit': 10, '/observability/call-logs': 20 },
    平台管理: { '/support-feedback': 10, '/marketing-leads': 15, '/download-channels': 17, '/client-versions': 20, '/local-coding-tool-versions': 22, '/client-analytics': 30 },
  }
  return byGroup[group]?.[menu.route] ?? menu.sortOrder
}

function roleTreeMenuDisplayName(menu: Menu) {
  const overrides: Record<string, string> = {
    '/tenants': '租户管理',
    '/plans': '套餐管理',
    '/billing/plans': '套餐管理',
    '/billing/features': '权益项',
    '/billing/credits': '积分包配置',
    '/billing/orders': '订单管理',
    '/billing/config': '计费配置',
    '/billing/subscription': '订阅信息',
    '/billing/usage': '用量统计',
    '/billing/overrides': '权益覆写',
    '/runtimes': '运行环境',
    '/platform-types': 'Agent 平台类型',
    '/runtime-hosting': '平台托管配置',
    '/preset-agents': '数字员工模版',
    '/skills': '技能管理',
    '/skill-categories': '技能分类',
    '/skill-labels': '技能标签',
    '/builtin-keys': '客户端能力注册表',
    '/tenant-skills/platform': '平台技能',
    '/tenant-skills/own': '企业技能',
    '/app-categories': '应用分类',
    '/kb-providers': '知识库服务配置',
    '/ragflow-ops': '监控运维',
    '/platform-kb': '知识库管理',
    '/user-kb-inspect': '用户知识库审计',
    '/drive/storage': '云盘存储配置',
    '/drive/usage': '云盘用量',
    '/drive/workers': '云盘后台维护',
    '/drive/quotas': '云盘配额',
    '/drive/recycle': '云盘回收站',
    '/drive/storage-override': '专属云盘存储',
    '/wukongim': 'IM 运行监控',
    '/cron-dashboard': '统计看板',
    '/cron-jobs': '定时任务列表',
    '/cron-prompt-templates': '定时任务模板',
    '/cron-prompt-templates-ops': '定时任务模板',
    '/roles': '权限与角色',
    '/menus': '菜单管理',
    '/sys-users': '系统用户',
    '/audit': '审计日志',
    '/observability/call-logs': '调用日志',
    '/api-keys': 'API Key 管理',
    '/agent-sdk-credentials': 'Agent SDK 凭证',
    '/sso-config': '单点登录 (SSO)',
    '/agents': '数字员工列表',
    '/workspace-apps': '工作台应用',
    '/kb': '知识库管理',
    '/kb-documents': '文档管理',
    '/drive': '企业云盘',
    '/cron': '定时任务',
    '/members': '成员',
    '/departments': '部门',
    '/positions': '职位',
    '/contacts': '通讯录配置',
    '/rooms/a2a': 'A2A 调用治理',
    '/rooms/orchestrations': '协作编排',
    '/rooms/speaker-policies': 'Speaker 策略',
    '/approvals': '审批',
    '/mcp': 'MCP 服务',
  }
  if (menu.route === '/apps') return menu.scopeKind === 'platform' ? '应用管理' : '应用栏配置'
  if (menu.route === '/rooms') return '群聊'
  if (menu.route === '/runtime-environments') return menu.scopeKind === 'platform' ? '运行环境' : '智能体托管环境'
  return overrides[menu.route] || menu.name
}

function permissionResourceIcon(p: Permission) {
  const map: Record<string, string> = {
    overview: 'layout-dashboard',
    tenant: 'building-2',
    plan: 'receipt',
    role: 'shield',
    menu: 'layout-list',
    sysuser: 'user-cog',
    department: 'git-branch',
    member: 'users',
    position: 'users',
    agent: 'bot',
    preset_agent: 'bot',
    runtime: 'cpu',
    runtime_env: 'server',
    kb: 'book-open',
    kb_provider: 'database',
    drive: 'hard-drive',
    app: 'grid',
    app_category: 'grid',
    skill: 'wand',
    audit: 'file-text',
    cron: 'sliders',
    api_key: 'key',
    agent_sdk: 'bot',
    identity_provider: 'shield-check',
    mcp: 'plug',
    account: 'user',
    session: 'message-square',
  }
  return map[p.Resource] || 'puzzle'
}

function permissionGroupLabel(p: Permission) {
  const map: Record<string, string> = {
    overview: '概览',
    tenant: '租户管理',
    plan: '套餐管理',
    billing: '计费中心',
    role: '权限与角色',
    menu: '菜单管理',
    sysuser: '系统用户',
    department: '部门',
    member: '成员',
    position: '职位',
    agent: '数字员工',
    preset_agent: '平台预置数字员工',
    runtime: '运行环境',
    runtime_env: '运行环境',
    kb: '知识库',
    kb_provider: '知识库服务',
    drive: '云盘',
    app: '应用管理',
    app_category: '应用分类',
    skill: '技能中心',
    audit: '审计',
    cron: '任务与自动化',
    room: '群组与协同',
    approval: '审批',
    api_key: 'API Key',
    agent_sdk: 'Agent SDK 凭证',
    identity_provider: '单点登录',
    mcp: 'MCP 接入',
    session: '账号安全',
    account: '个人资料',
  }
  return map[p.Resource] || `${p.ScopeKind}.${p.Resource || '其他'}`
}

function actionLabel(p: Permission) {
  if (p.Action === 'manage') return managePermissionLabel(p)
  if (p.Action === 'impersonate') return '进入租户后台'
  const map: Record<string, string> = {
    read: '查看',
    create: '新建',
    update: '编辑',
    delete: '删除',
    publish: '发布',
    invite: '邀请',
    remove: '移出',
    suspend: '停用',
    revoke: '撤销',
    assign: '分配',
    enable: '启用',
    set_default: '设为默认',
    probe: '连通性检查',
    review: '审核',
    operate: '运维',
    rotate_secret: '密钥轮换',
    launch_test: '启动测试',
    upload: '上传',
    preview: '预览',
    agent_bind: '数字员工绑定',
    recall: '召回测试',
  }
  return map[p.Action] || p.Action || p.Kind
}

function permissionDisplayLabel(p: Permission) {
  if (p.Action === 'manage') return managePermissionLabel(p)
  if (p.Action === 'impersonate') return '进入租户后台'
  const map: Record<string, string> = {
    read: '查看',
    create: '新建',
    update: '编辑',
    delete: '删除',
    publish: '发布',
    invite: '邀请',
    remove: '移出',
    suspend: '停用',
    revoke: '撤销',
    assign: '分配',
    enable: '启用',
    set_default: '设为默认',
    probe: '连通性检查',
    review: '审核',
    operate: '运维',
    rotate_secret: '密钥轮换',
    launch_test: '启动测试',
    upload: '上传',
    preview: '预览',
    admin: '高级管理',
    create_self_hosted: '创建自托管',
    manage_quota: '配额分配',
    read_usage: '用量读取',
    manage_storage: '存储配置',
    read_workers: '后台维护读取',
    read_metadata: '文件元数据查看',
    read_audit: '审计查看',
    universal_toggle: '通用开关',
    agent_bind: '数字员工绑定',
    recall: '召回测试',
  }
  return map[p.Action] || cleanPermissionName(p)
}

function managePermissionLabel(p: Permission) {
  const byCode: Record<string, string> = {
    'platform.alert.manage': '告警维护',
  }
  if (byCode[p.Code]) return byCode[p.Code]

  const byResource: Record<string, string> = {
    app: '应用维护',
    app_category: '分类维护',
    cron: '任务维护',
    drive: '云盘维护',
    identity_provider: 'SSO 配置',
    kb: '知识库维护',
    kb_provider: '服务配置',
    mcp: '服务维护',
    params: '参数维护',
    plan: '套餐维护',
    position: '职位维护',
    runtime: '配置维护',
    runtime_env: '环境维护',
    skill: '技能维护',
  }
  return byResource[p.Resource] || '维护'
}

function cleanPermissionName(p: Permission) {
  const group = permissionGroupLabel(p)
  return p.Name
    .replace(/^(平台|租户|个人|部门|工作区)[-－]/, '')
    .replace(new RegExp(`^${escapeRegExp(group)}[-－]`), '')
    .replace(/^平台云盘/, '')
    .replace(/^租户云盘/, '')
    .replace(/管理$/, '管理')
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function CheckGrid({ title, children }: { title: string; children: React.ReactNode }) {
  return <div><div className="mb-2 text-[13px] font-medium">{title}</div><div className="max-h-56 overflow-auto rounded-md border border-[var(--color-line)] p-2 grid grid-cols-2 gap-1">{children}</div></div>
}
function CheckChip({ label, checked, disabled, title, onChange }: { label: string; checked: boolean; disabled?: boolean; title?: string; onChange: (v: boolean) => void }) {
  return <label title={title} className="flex min-h-6 items-center gap-2 rounded px-2 py-0.5 text-[12px] hover:bg-[var(--color-line-soft)]"><input disabled={disabled} type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} /><span className="truncate">{label}</span></label>
}
function toggleId(ids: number[], id: number, enabled: boolean) {
  return enabled ? Array.from(new Set([...ids, id])) : ids.filter((x) => x !== id)
}
