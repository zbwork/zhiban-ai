import { useEffect, useState } from 'react'
import { api } from '../lib/httpClient'
import { Departments, type Department } from '../lib/departmentApi'
import { MemberDepartmentSelect } from '../components/form/MemberDepartmentSelect'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { Button, DataTable, DialogShell, FormField, Input, Pagination, EmptyState, InlineAlert, RowActions, stickyRightTdCls } from '../components/ui'

type Member = { membership_id: number; display_name: string; email?: string; status: string; department_id?: number; department_name?: string; title?: string }
const statusLabels: Record<string, string> = { active: '在职', invited: '已邀请', suspended: '已禁用', left: '已离开' }

export function Organization({ view }: { view: 'members' | 'departments' }) {
  const [departments, setDepartments] = useState<Department[]>([])
  const [members, setMembers] = useState<Member[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [query, setQuery] = useState('')
  const [tick, setTick] = useState(0)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [member, setMember] = useState<Member | null>(null)
  const [department, setDepartment] = useState<Department | 'new' | null>(null)
  const [name, setName] = useState('')
  const [title, setTitle] = useState('')
  const [departmentID, setDepartmentID] = useState<number | ''>('')
  const { confirm, dialog } = useConfirmDialog()
  useEffect(() => {
    let active = true
    void Departments.list().then(result => { if (active) { setDepartments(result.items || []); setError('') } }).catch((failure: Error) => { if (active) setError(failure.message) })
    return () => { active = false }
  }, [tick])
  useEffect(() => {
    if (view !== 'members') return
    const controller = new AbortController()
    void api<{ items: Member[]; total: number }>('/api/admin/v1/tenant/members?limit=20&offset=' + (page - 1) * 20 + '&q=' + encodeURIComponent(query), { signal: controller.signal })
      .then(result => { if (!controller.signal.aborted) { setMembers(result.items || []); setTotal(result.total); setError('') } }).catch((failure: Error) => { if (!controller.signal.aborted) setError(failure.message) }).finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [view, page, query, tick])
  const refresh = () => { setLoading(true); setTick(value => value + 1) }
  async function remove(id: number, label: string) {
    if (!await confirm({ title: view === 'members' ? '移除成员' : '删除部门', description: '确认操作：' + label + '？', confirmLabel: view === 'members' ? '移除' : '删除' })) return
    setBusy(true)
    try {
      await api('/api/admin/v1/tenant/' + view + '/' + id, { method: 'DELETE' })
      if (view === 'members' && members.length === 1 && page > 1) setPage(value => value - 1)
      refresh()
    } catch { /* API client displays errors. */ } finally { setBusy(false) }
  }
  async function save(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    try {
      if (member) {
        await api('/api/admin/v1/tenant/members/' + member.membership_id, { method: 'PUT', body: JSON.stringify({ display_name: name.trim(), title, ...(departmentID ? { department_id: departmentID } : {}) }) })
        setMember(null)
      } else if (department) {
        if (department === 'new') await Departments.create({ name: name.trim() })
        else await Departments.update(department.id, { name: name.trim() })
        setDepartment(null)
      }
      refresh()
    } catch { /* API client displays errors. */ } finally { setBusy(false) }
  }
  return <section>
    {error && <InlineAlert tone="danger">{error}，请重试或联系管理员。</InlineAlert>}
    <h2 className="my-4 text-lg font-semibold">{view === 'members' ? '租户成员' : '部门管理'}</h2>
    <div className="mb-4 flex items-center justify-between gap-3">
      {view === 'members' ? <FormField label="搜索成员"><Input value={query} placeholder="姓名 / 邮箱 / 手机" onChange={event => { setQuery(event.target.value); setPage(1); setLoading(true) }} /></FormField> : <span>共 {departments.length} 个部门</span>}
      <div className="flex gap-2"><Button variant="secondary" disabled={busy} onClick={refresh}>刷新</Button>{view === 'departments' && <Button variant="primary" onClick={() => { setName(''); setDepartment('new') }}>创建部门</Button>}</div>
    </div>
    {view === 'members' ? <>
      {loading && <p role="status">正在加载成员…</p>}
      <DataTable stickyLastCol headers={['姓名', '邮箱', '部门', '职务', '状态', '操作']} empty={!members.length ? <EmptyState title={loading ? '正在加载成员…' : '暂无成员'} /> : undefined}>
        {members.map(item => <tr key={item.membership_id} className="group"><td className="px-4 py-3">{item.display_name}</td><td className="px-4 py-3">{item.email || '—'}</td><td className="px-4 py-3">{item.department_name || '—'}</td><td className="px-4 py-3">{item.title || '—'}</td><td className="px-4 py-3">{statusLabels[item.status] || item.status}</td><td className={stickyRightTdCls}><RowActions editDisabled={busy} deleteDisabled={busy} deleteLabel="移除" onEdit={() => { setMember(item); setName(item.display_name); setTitle(item.title || ''); setDepartmentID(item.department_id || '') }} onDelete={() => { void remove(item.membership_id, item.display_name) }} /></td></tr>)}
      </DataTable>
      <Pagination total={total} page={page} pageSize={20} pageSizeOptions={[20]} onPageSizeChange={() => {}} onPageChange={setPage} />
    </> : <DataTable stickyLastCol headers={['部门名称', '层级', '直属成员数', '操作']} empty={!departments.length ? <EmptyState title="暂无部门" /> : undefined}>
      {departments.map(item => <tr key={item.id} className="group"><td className="px-4 py-3">{item.name}</td><td className="px-4 py-3">{item.depth + 1}</td><td className="px-4 py-3">{item.member_count}</td><td className={stickyRightTdCls}><RowActions editDisabled={busy} deleteDisabled={busy} onEdit={() => { setDepartment(item); setName(item.name) }} onDelete={() => { void remove(item.id, item.name) }} /></td></tr>)}
    </DataTable>}
    {(member || department) && <DialogShell title={member ? '编辑成员' : department === 'new' ? '创建部门' : '编辑部门'} onClose={() => { if (!busy) { setMember(null); setDepartment(null) } }} footer={<><Button variant="secondary" disabled={busy} onClick={() => { setMember(null); setDepartment(null) }}>取消</Button><Button variant="primary" type="submit" form="community-organization-form" disabled={busy || !name.trim()}>{busy ? '正在保存…' : '保存'}</Button></>}>
      <form id="community-organization-form" className="space-y-4" onSubmit={save}>
        <FormField label={member ? '姓名' : '部门名称'} required><Input required maxLength={128} value={name} onChange={event => setName(event.target.value)} /></FormField>
        {member && <><FormField label="职务"><Input maxLength={128} value={title} onChange={event => setTitle(event.target.value)} /></FormField><FormField label="部门"><MemberDepartmentSelect departments={departments} value={departmentID} onChange={setDepartmentID} disabled={busy} /></FormField></>}
      </form>
    </DialogShell>}
    {dialog}
  </section>
}
