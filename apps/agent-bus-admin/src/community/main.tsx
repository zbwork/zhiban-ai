import { useCallback, useEffect, useState } from 'react'
import { Organization } from './Organization'
import '../index.css'
import { api, auth } from '../lib/httpClient'
import { Auth } from '../lib/authApi'
import { GlobalToast } from '../components/GlobalToast'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { Button, DataTable, EmptyState, FormField, Input, Panel, Pagination, Tabs } from '../components/ui'

type Tenant = { ID: number; Name: string; Slug: string; Status: string }
export function CommunityAdmin() {
  const [loggedIn, setLoggedIn] = useState(Boolean(auth.token()))
  const [identifier, setIdentifier] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [creating, setCreating] = useState(false)
  const [tenantName, setTenantName] = useState('')
  const [tenantSlug, setTenantSlug] = useState('')
  const [adminEmail, setAdminEmail] = useState('')
  const [items, setItems] = useState<Tenant[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [tenantID, setTenantID] = useState(0)
  const [view, setView] = useState<'agents' | 'members' | 'departments'>('agents')
  const { confirm, dialog } = useConfirmDialog()
  const [agentPage, setAgentPage] = useState(1)
  const [agentTotal, setAgentTotal] = useState(0)
  const [editingUUID, setEditingUUID] = useState('')
  const [runtimeID, setRuntimeID] = useState<number>()
  const [agents, setAgents] = useState<Array<{ UUID: string; Name: string; Intro: string; Status: string; RuntimeEnvironmentID: number }>>([])
  const [agentName, setAgentName] = useState('')
  const loadAgents = useCallback(async (targetPage = agentPage) => {
    const result = await api<{ items: typeof agents; total: number }>('/api/admin/v1/tenant/agents?limit=20&offset=' + (targetPage - 1) * 20)
    setAgents(result.items || [])
    if (result.items?.[0]?.RuntimeEnvironmentID) setRuntimeID(result.items[0].RuntimeEnvironmentID)
    setAgentTotal(result.total)
  }, [agentPage])
  useEffect(() => {
    if (!loggedIn) return
    void Auth.me().then(async result => {
      if (result.actScope.kind === 'tenant' && result.actScope.tenantId) {
        setTenantID(result.actScope.tenantId)
        await loadAgents()
      }
    }).catch(() => {})
  }, [loggedIn, loadAgents])
  async function enterTenant(id: number) {
    try {
      const result = await Auth.switchScope('tenant', id)
      auth.setToken(result.accessToken); auth.setRefresh(result.refreshToken)
      setTenantID(id)
      setAgentPage(1)
      setRuntimeID(undefined)
      await loadAgents(1)
    } catch { /* API client displays errors. */ }
  }
  const load = useCallback(async () => {
    const result = await api<{ items: Tenant[]; total: number }>(
      '/api/admin/v1/platform/tenants?limit=' + pageSize + '&offset=' + (page - 1) * pageSize,
    )
    setItems(result.items || [])
    setTotal(result.total)
  }, [page, pageSize])
  useEffect(() => {
    if (!loggedIn || tenantID) return
    const controller = new AbortController()
    void api<{ items: Tenant[]; total: number }>(
      '/api/admin/v1/platform/tenants?limit=' + pageSize + '&offset=' + (page - 1) * pageSize,
      { signal: controller.signal },
    ).then(result => {
      if (!controller.signal.aborted) { setItems(result.items || []); setTotal(result.total) }
    }).catch(() => {})
    return () => controller.abort()
  }, [loggedIn, tenantID, page, pageSize])
  async function login(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    try {
      const result = await Auth.loginPassword(identifier, password)
      auth.setToken(result.accessToken)
      auth.setRefresh(result.refreshToken)
      const platform = await Auth.switchScope('platform')
      auth.setToken(platform.accessToken)
      auth.setRefresh(platform.refreshToken)
      setPassword('')
      setLoggedIn(true)
    } catch { /* API client displays the error toast. */ }
    finally { setBusy(false) }
  }
  async function createTenant(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    try {
      await api('/api/admin/v1/platform/tenants', { method: 'POST', body: JSON.stringify({ Name: tenantName, Slug: tenantSlug, admin: { email: adminEmail } }) })
      setCreating(false)
      setTenantName('')
      setTenantSlug('')
      await load()
    } catch { /* API client displays the error toast. */ }
    finally { setBusy(false) }
  }
  return <main className="min-h-screen bg-[var(--color-bg-sub)] p-6 text-[var(--color-text)]">
    <header className="mb-6 flex items-center justify-between">
      <h1 className="text-xl font-semibold">知办AI · 社区管理后台</h1>
      {loggedIn && <Button variant="secondary" onClick={async () => { try { await Auth.logout() } finally { auth.clearAll(); setTenantID(0); setLoggedIn(false) } }}>退出登录</Button>}
    </header>
    {!loggedIn ? <Panel className="mx-auto max-w-md p-6">
      <h2 className="mb-5 text-lg font-semibold">登录控制台</h2>
      <form onSubmit={login} className="space-y-4">
        <FormField label="账号" required><Input required autoComplete="username" value={identifier} onChange={event => setIdentifier(event.target.value)} /></FormField>
        <FormField label="密码" required><Input required type="password" autoComplete="current-password" value={password} onChange={event => setPassword(event.target.value)} /></FormField>
        <Button variant="primary" type="submit" disabled={busy}>{busy ? '正在登录…' : '登录'}</Button>
      </form>
    </Panel> : tenantID ? <Panel className="p-4">
      <Tabs value={view} onChange={setView} items={[{ value: 'agents', label: '数字员工' }, { value: 'members', label: '成员管理' }, { value: 'departments', label: '部门管理' }]} />
      {view !== 'agents' && <Button variant="secondary" className="mt-4" onClick={async () => { try { const result = await Auth.switchScope('platform'); auth.setToken(result.accessToken); auth.setRefresh(result.refreshToken); setTenantID(0); await load() } catch { /* API client displays errors. */ } }}>返回租户管理</Button>}
      {view !== 'agents' && <Organization key={tenantID + view} view={view} />}
      <div hidden={view !== 'agents'}>
      <h2 className="mb-4 text-lg font-semibold">数字员工</h2>
      <div className="mb-3 flex gap-2"><Button variant="secondary" onClick={async () => { try { const result = await Auth.switchScope('platform'); auth.setToken(result.accessToken); auth.setRefresh(result.refreshToken); setTenantID(0); await load() } catch { /* Toast. */ } }}>返回租户管理</Button><Button variant="secondary" onClick={() => { void loadAgents().catch(() => {}) }}>刷新</Button></div>
      <form className="mb-4 flex items-end gap-3" onSubmit={async event => { event.preventDefault(); setBusy(true); try { await api('/api/admin/v1/tenant/agents' + (editingUUID ? '/' + editingUUID : ''), { method: editingUUID ? 'PUT' : 'POST', body: JSON.stringify({ name: agentName, intro: agents.find(agent => agent.UUID === editingUUID)?.Intro || "", runtime_environment_id: runtimeID }) }); setAgentName(''); setEditingUUID(''); await loadAgents() } catch { /* Toast. */ } finally { setBusy(false) } }}>
        <FormField label="员工名称" required><Input required maxLength={128} value={agentName} onChange={event => setAgentName(event.target.value)} /></FormField><Button variant="primary" type="submit" disabled={busy || !runtimeID}>{editingUUID ? '保存' : '创建员工'}</Button>{editingUUID && <Button variant="secondary" onClick={() => { setEditingUUID(''); setAgentName('') }}>取消编辑</Button>}
      </form>
      <DataTable headers={['名称', '状态', '操作']} empty={!agents.length ? <EmptyState title="暂无数字员工" /> : undefined}>
        {agents.map(agent => <tr key={agent.UUID}><td className="px-4 py-3">{agent.Name}</td><td className="px-4 py-3">{agent.Status === 'draft' ? '草稿' : agent.Status === 'published' ? '已发布' : agent.Status}</td><td className="px-4 py-3"><div className="flex gap-2"><Button variant="secondary" onClick={() => { setEditingUUID(agent.UUID); setAgentName(agent.Name) }}>编辑</Button><Button variant="secondary" disabled={agent.Status !== 'draft'} onClick={async () => { try { await api('/api/admin/v1/tenant/agents/' + agent.UUID + '/publish', { method: 'POST' }); await loadAgents() } catch { /* Toast. */ } }}>发布</Button><Button variant="danger" onClick={async () => { if (!await confirm({ title: '删除数字员工', description: '确认删除“' + agent.Name + '”？', confirmLabel: '删除' })) return; try { await api('/api/admin/v1/tenant/agents/' + agent.UUID, { method: 'DELETE' }); await loadAgents() } catch { /* Toast. */ } }}>删除</Button></div></td></tr>)}
      </DataTable>
      <Pagination total={agentTotal} page={agentPage} pageSize={20} onPageChange={value => { setAgentPage(value); void loadAgents(value).catch(() => {}) }} pageSizeOptions={[20]} onPageSizeChange={() => {}} />
      </div>
    </Panel> : <Panel className="p-4">
      <h2 className="mb-4 text-lg font-semibold">租户管理</h2>
      <div className="mb-3 flex items-center justify-between"><span>共 {total} 个租户</span><div className="flex gap-2"><Button variant="secondary" onClick={() => { void load().catch(() => {}) }}>刷新</Button><Button variant="primary" onClick={() => setCreating(true)}>创建租户</Button></div></div>
      {creating && <form onSubmit={createTenant} className="mb-4 grid gap-3 md:grid-cols-3">
        <FormField label="租户名称" required><Input required value={tenantName} onChange={event => setTenantName(event.target.value)} /></FormField>
        <FormField label="租户标识" required><Input required pattern="[a-z0-9-]+" value={tenantSlug} onChange={event => setTenantSlug(event.target.value)} /></FormField>
        <FormField label="已有管理员邮箱" required hint="复用已设置密码的账号；首次可填初始化时的管理员邮箱。"><Input required type="email" value={adminEmail} onChange={event => setAdminEmail(event.target.value)} /></FormField>
        <div className="flex gap-2"><Button variant="secondary" onClick={() => setCreating(false)}>取消</Button><Button variant="primary" type="submit" disabled={busy}>创建</Button></div>
      </form>}
      <DataTable headers={['名称', '标识', '状态', '操作']} empty={!items.length ? <EmptyState title="暂无租户" description="完成平台初始化后创建首个租户。" /> : undefined}>
        {items.map(item => <tr key={item.ID} className="border-b border-[var(--color-line-soft)]"><td className="px-4 py-3">{item.Name}</td><td className="px-4 py-3">{item.Slug}</td><td className="px-4 py-3">{item.Status}</td><td className="px-4 py-3"><Button variant="secondary" onClick={() => { void enterTenant(item.ID) }}>进入管理</Button></td></tr>)}
      </DataTable>
      <Pagination total={total} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={value => { setPageSize(value); setPage(1) }} />
    </Panel>}
    <GlobalToast />
    {dialog}
  </main>
}
