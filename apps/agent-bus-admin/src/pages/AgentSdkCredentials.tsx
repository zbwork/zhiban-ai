import { useEffect, useMemo, useState } from 'react'
import { Bot, Copy, KeyRound, ShieldAlert } from 'lucide-react'
import {
  AgentSdkCredentials,
  PlatformRuntimeEnvs,
  Tenants,
  type AgentSdkCapability,
  type AgentSdkCredential,
  type CreateAgentSdkCredentialResult,
  type RuntimeEnv,
  type Tenant,
} from '../lib/api'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  EmptyState,
  FormField,
  InlineAlert,
  Input,
  PageHeader,
  PrimaryButton,
  RowActions,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

type PageMode = 'tenant' | 'platform'

const CAP_LABEL: Record<AgentSdkCapability, string> = {
  'kb.read': '知识库读取',
  'zhiban.kb.search': '知识库搜索',
  'drive.read': '云盘读取',
  'memory.read': '记忆读取',
  'memory.write': '记忆写入',
  'notification.write': '通知发送',
  'chat.message.write': '主动消息发送',
  'chat.file.read': '会话附件读取',
  'org.read': '组织与人员读取',
  'a2a.invoke': 'Agent 间调用(A2A)',
  // 平台级:允许可信自营服务代企业开通租户(目前仅 HR助手/OPC 自注册企业用)。
  'platform.tenant.provision': '代开通租户(平台级)',
}

const TENANT_CAPS: AgentSdkCapability[] = ['kb.read', 'drive.read']
const PLATFORM_CAPS: AgentSdkCapability[] = [
  'notification.write',
  'chat.message.write',
  'chat.file.read',
  'kb.read',
  'zhiban.kb.search',
  'drive.read',
  'memory.read',
  'memory.write',
  'org.read',
  'a2a.invoke',
  'platform.tenant.provision',
]

const STATUS_LABEL: Record<string, string> = {
  active: '生效中',
  revoked: '已撤销',
}

function columnHeader(label: string, className: string) {
  return <span className={`inline-block ${className}`}>{label}</span>
}

function statusClass(status: string) {
  if (status === 'active') return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  if (status === 'revoked') return 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'
  return 'bg-[var(--color-info-bg)] text-[var(--color-info)]'
}

export function AgentSdkCredentialsPage() {
  return <AgentSdkCredentialsView mode="tenant" />
}

export function RuntimeCredentialPanel({ runtime }: { runtime: RuntimeEnv }) {
  const [items, setItems] = useState<AgentSdkCredential[]>([])
  const [tenants, setTenants] = useState<Tenant[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [credential, setCredential] = useState<CreateAgentSdkCredentialResult | null>(null)
  const [revoking, setRevoking] = useState<AgentSdkCredential | null>(null)

  useEffect(() => {
    let alive = true
    Promise.all([
      AgentSdkCredentials.listPlatform(),
      Tenants.list('active', '', 100, 0).catch(() => ({ items: [] as Tenant[], total: 0 })),
    ])
      .then(([credRes, tenantRes]) => {
        if (!alive) return
        setItems((credRes.items || []).filter((c) => c.runtimeRegistrationId === runtime.ID))
        setTenants(tenantRes.items || [])
        setErr('')
      })
      .catch((e: Error) => alive && setErr(e.message))
      .finally(() => alive && setLoading(false))
    return () => { alive = false }
  }, [runtime.ID, tick])

  const tenantByID = useMemo(() => {
    const m = new Map<number, Tenant>()
    for (const t of tenants) m.set(t.ID, t)
    return m
  }, [tenants])
  const refresh = () => {
    setLoading(true)
    setTick((t) => t + 1)
  }

  return (
    <div className="space-y-4">
      <Toolbar
        summary={<span>共 {items.length} 条换发凭证</span>}
        actions={(
          <PrimaryButton onClick={() => setCreating(true)}>
            新建凭证
          </PrimaryButton>
        )}
      />

      <InlineAlert tone="info">
        这里的长期凭证只用于换发短期 st_ Runtime Access Token，不能直接作为 Bearer 调业务接口。
      </InlineAlert>

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        stickyLastCol
        headers={[
          columnHeader('名称', 'min-w-[180px]'),
          columnHeader('Client ID', 'min-w-[260px]'),
          columnHeader('授权租户', 'min-w-[160px]'),
          columnHeader('可用能力', 'min-w-[180px]'),
          columnHeader('状态', 'min-w-[96px]'),
          columnHeader('最近换发', 'min-w-[168px]'),
          columnHeader('创建时间', 'min-w-[132px]'),
          columnHeader('操作', 'min-w-[112px]'),
        ]}
        loading={loading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div> : null}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<KeyRound size={28} />}
            title="暂无 Runtime 换发凭证"
            description="创建后，该托管 Runtime 可按租户、数字员工和能力集合换发短期 st_。"
          />
        ) : null}
      >
        {items.map((c) => (
          <tr key={c.uuid} className="group">
            <td className="min-w-[180px] px-4 py-3 font-medium text-[var(--color-text)]">{c.name}</td>
            <td className="min-w-[260px] max-w-[320px] truncate px-4 py-3 font-mono text-[11px] text-[var(--color-text-sub)]" title={c.clientId}>{c.clientId}</td>
            <td className="min-w-[160px] px-4 py-3 text-[13px] text-[var(--color-text)]">
              <TenantGrantSummary credential={c} tenantByID={tenantByID} />
            </td>
            <td className="min-w-[180px] px-4 py-3">
              <CapabilityBadges caps={c.capabilityBindings || []} />
            </td>
            <td className="min-w-[96px] whitespace-nowrap px-4 py-3">
              <span className={`inline-flex rounded-md px-2 py-0.5 text-[12px] ${statusClass(c.status)}`}>
                {STATUS_LABEL[c.status] || c.status}
              </span>
            </td>
            <td className="min-w-[168px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{c.lastUsedAt ? new Date(c.lastUsedAt).toLocaleString() : '-'}</td>
            <td className="min-w-[132px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{new Date(c.createdAt).toLocaleDateString()}</td>
            <td className={`${stickyRightTdCls} min-w-[112px] px-4 py-3`}>
              {c.status === 'active' && (
                <RowActions deleteLabel="撤销" onDelete={() => setRevoking(c)} />
              )}
            </td>
          </tr>
        ))}
      </DataTable>

      {creating && (
        <CreateCredentialDialog
          mode="platform"
          runtimes={[runtime]}
          fixedRuntime={runtime}
          tenants={tenants}
          onCancel={() => setCreating(false)}
          onCreated={(res) => { setCreating(false); setCredential(res); refresh() }}
        />
      )}
      {credential && (
        <CredentialCreatedDialog
          mode="platform"
          credential={credential}
          onClose={() => setCredential(null)}
        />
      )}
      {revoking && (
        <ConfirmDialog
          title="撤销换发凭证"
          description={(
            <span>
              确认撤销 <b>{revoking.name}</b> 吗？该凭证已颁发的 active 短期 token 会一起失效。
            </span>
          )}
          confirmLabel="确认撤销"
          busyLabel="撤销中..."
          onClose={() => setRevoking(null)}
          onConfirm={async () => {
            await AgentSdkCredentials.revokePlatform(revoking.uuid)
            setRevoking(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function AgentSdkCredentialsView({ mode }: { mode: PageMode }) {
  const [items, setItems] = useState<AgentSdkCredential[]>([])
  const [runtimes, setRuntimes] = useState<RuntimeEnv[]>([])
  const [tenants, setTenants] = useState<Tenant[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [credential, setCredential] = useState<CreateAgentSdkCredentialResult | null>(null)
  const [revoking, setRevoking] = useState<AgentSdkCredential | null>(null)

  useEffect(() => {
    let alive = true
    const listCredentials = mode === 'platform'
      ? AgentSdkCredentials.listPlatform()
      : AgentSdkCredentials.list()
    const listRuntimes = mode === 'platform'
      ? PlatformRuntimeEnvs.list(true).catch(() => ({ items: [] as RuntimeEnv[], total: 0 }))
      : Promise.resolve({ items: [] as RuntimeEnv[], total: 0 })
    const listTenants = mode === 'platform'
      ? Tenants.list('active', '', 100, 0).catch(() => ({ items: [] as Tenant[], total: 0 }))
      : Promise.resolve({ items: [] as Tenant[], total: 0 })

    Promise.all([listCredentials, listRuntimes, listTenants])
      .then(([credRes, runtimeRes, tenantRes]) => {
        if (!alive) return
        setItems(credRes.items || [])
        setRuntimes((runtimeRes.items || []).filter((r) => r.Scope === 'platform'))
        setTenants(tenantRes.items || [])
        setErr('')
      })
      .catch((e: Error) => alive && setErr(e.message))
      .finally(() => alive && setLoading(false))
    return () => { alive = false }
  }, [mode, tick])

  const runtimeByID = useMemo(() => {
    const m = new Map<number, RuntimeEnv>()
    for (const r of runtimes) m.set(r.ID, r)
    return m
  }, [runtimes])
  const tenantByID = useMemo(() => {
    const m = new Map<number, Tenant>()
    for (const t of tenants) m.set(t.ID, t)
    return m
  }, [tenants])
  const refresh = () => setTick((t) => t + 1)
  const title = mode === 'platform' ? 'Runtime 凭证' : 'Agent SDK 凭证'
  const subtitle = mode === 'platform'
    ? '平台托管 Runtime 使用长期换发凭证换短期 Runtime Access Token。凭证必须绑定一个平台运行环境。'
    : '租户自建 Agent 使用长期换发凭证换短期 session_token。明文 client_secret 仅创建时返回一次。'

  return (
    <div>
      <PageHeader title={title} subtitle={subtitle} />

      <Toolbar
        summary={<span>共 {items.length} 条</span>}
        actions={(
          <PrimaryButton onClick={() => setCreating(true)}>
            {mode === 'platform' ? '新建 Runtime 凭证' : '接入新 Agent'}
          </PrimaryButton>
        )}
      />

      {err && <div className="mb-3"><InlineAlert>{err}</InlineAlert></div>}

      <DataTable
        stickyLastCol
        headers={[
          columnHeader('名称', 'min-w-[180px]'),
          columnHeader('Client ID', 'min-w-[260px]'),
          ...(mode === 'platform' ? [columnHeader('绑定运行环境', 'min-w-[180px]')] : []),
          ...(mode === 'platform' ? [columnHeader('授权租户', 'min-w-[160px]')] : []),
          columnHeader('可用能力', 'min-w-[180px]'),
          columnHeader('状态', 'min-w-[96px]'),
          columnHeader('最近换发', 'min-w-[168px]'),
          columnHeader('创建时间', 'min-w-[132px]'),
          columnHeader('操作', 'min-w-[112px]'),
        ]}
        loading={loading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div> : null}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<Bot size={28} />}
            title={mode === 'platform' ? '暂无 Runtime 凭证' : '暂无 Agent SDK 凭证'}
            description={mode === 'platform' ? '创建后，平台托管 Runtime 可按租户和数字员工换发短期 token。' : '创建后，租户自建 Agent 可使用短期 token 反向调用授权接口。'}
          />
        ) : null}
      >
        {items.map((c) => {
          const runtime = c.runtimeRegistrationId ? runtimeByID.get(c.runtimeRegistrationId) : null
          return (
            <tr key={c.uuid} className="group">
              <td className="min-w-[180px] px-4 py-3 font-medium text-[var(--color-text)]">{c.name}</td>
              <td className="min-w-[260px] max-w-[320px] truncate px-4 py-3 font-mono text-[11px] text-[var(--color-text-sub)]" title={c.clientId}>{c.clientId}</td>
              {mode === 'platform' && (
                <td className="min-w-[180px] px-4 py-3 text-[13px] text-[var(--color-text)]">
                  {runtime ? runtime.Name : c.runtimeRegistrationId ? `#${c.runtimeRegistrationId}` : '未绑定'}
                </td>
              )}
              {mode === 'platform' && (
                <td className="min-w-[160px] px-4 py-3 text-[13px] text-[var(--color-text)]">
                  <TenantGrantSummary credential={c} tenantByID={tenantByID} />
                </td>
              )}
              <td className="min-w-[180px] px-4 py-3">
                <CapabilityBadges caps={c.capabilityBindings || []} />
              </td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3">
                <span className={`inline-flex rounded-md px-2 py-0.5 text-[12px] ${statusClass(c.status)}`}>
                  {STATUS_LABEL[c.status] || c.status}
                </span>
              </td>
              <td className="min-w-[168px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{c.lastUsedAt ? new Date(c.lastUsedAt).toLocaleString() : '-'}</td>
              <td className="min-w-[132px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{new Date(c.createdAt).toLocaleDateString()}</td>
              <td className={`${stickyRightTdCls} min-w-[112px] px-4 py-3`}>
                {c.status === 'active' && (
                  <RowActions deleteLabel="撤销" onDelete={() => setRevoking(c)} />
                )}
              </td>
            </tr>
          )
        })}
      </DataTable>

      {creating && (
        <CreateCredentialDialog
          mode={mode}
          runtimes={runtimes}
          tenants={tenants}
          onCancel={() => setCreating(false)}
          onCreated={(res) => { setCreating(false); setCredential(res); refresh() }}
        />
      )}
      {credential && (
        <CredentialCreatedDialog
          mode={mode}
          credential={credential}
          onClose={() => setCredential(null)}
        />
      )}
      {revoking && (
        <ConfirmDialog
          title="撤销换发凭证"
          description={(
            <span>
              确认撤销 <b>{revoking.name}</b> 吗？该凭证已颁发的 active 短期 token 会一起失效。
            </span>
          )}
          confirmLabel="确认撤销"
          busyLabel="撤销中..."
          onClose={() => setRevoking(null)}
          onConfirm={async () => {
            if (mode === 'platform') await AgentSdkCredentials.revokePlatform(revoking.uuid)
            else await AgentSdkCredentials.revoke(revoking.uuid)
            setRevoking(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function CapabilityBadges({ caps }: { caps: AgentSdkCapability[] }) {
  if (caps.length === 0) return <span className="text-[var(--color-text-mute)]">-</span>
  return (
    <div className="flex flex-wrap gap-1.5">
      {caps.map((s) => (
        <span key={s} className="inline-flex rounded-md bg-[var(--color-brand-soft)] px-1.5 py-0.5 text-[11px] text-[var(--color-brand)]">
          {CAP_LABEL[s] || s}
        </span>
      ))}
    </div>
  )
}

function TenantGrantSummary({
  credential,
  tenantByID,
}: {
  credential: AgentSdkCredential
  tenantByID: Map<number, Tenant>
}) {
  if (credential.tenantGrantMode === 'all_enabled') {
    return <span>全部已启用租户</span>
  }
  const ids = credential.allowedTenantIds || []
  if (ids.length === 0) {
    return <span className="text-[var(--color-danger)]">未授权租户</span>
  }
  const labels = ids.slice(0, 3).map((id) => {
    const t = tenantByID.get(id)
    return t?.DisplayName || t?.Name || `#${id}`
  })
  return (
    <span title={ids.join(', ')}>
      {labels.join('、')}{ids.length > 3 ? ` 等 ${ids.length} 个` : ''}
    </span>
  )
}

function CreateCredentialDialog({
  mode,
  runtimes,
  fixedRuntime,
  tenants,
  onCancel,
  onCreated,
}: {
  mode: PageMode
  runtimes: RuntimeEnv[]
  fixedRuntime?: RuntimeEnv
  tenants: Tenant[]
  onCancel: () => void
  onCreated: (r: CreateAgentSdkCredentialResult) => void
}) {
  const capsSource = mode === 'platform' ? PLATFORM_CAPS : TENANT_CAPS
  const activeRuntimes = runtimes.filter((r) => !r.Status || r.Status === 'active')
  const [name, setName] = useState('')
  const [runtimeID, setRuntimeID] = useState(fixedRuntime?.ID || activeRuntimes[0]?.ID || 0)
  const [tenantGrantMode, setTenantGrantMode] = useState<'all_enabled' | 'allowlist'>('allowlist')
  const [allowedTenantIDs, setAllowedTenantIDs] = useState<number[]>([])
  const [caps, setCaps] = useState<AgentSdkCapability[]>(mode === 'platform' ? ['notification.write', 'chat.message.write'] : ['kb.read'])
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  const submit = async () => {
    setErr('')
    if (!name.trim()) { setErr('名称必填'); return }
    if (mode === 'platform' && runtimeID <= 0) { setErr('请选择运行环境'); return }
    if (mode === 'platform' && tenantGrantMode === 'allowlist' && allowedTenantIDs.length === 0) { setErr('请选择至少一个授权租户'); return }
    if (caps.length === 0) { setErr('至少选择一个能力'); return }
    setSubmitting(true)
    try {
      const r = mode === 'platform'
        ? await AgentSdkCredentials.createPlatform({
          name: name.trim(),
          runtimeEnvironmentId: runtimeID,
          capabilityBindings: caps,
          tenantGrantMode,
          allowedTenantIds: tenantGrantMode === 'allowlist' ? allowedTenantIDs : [],
        })
        : await AgentSdkCredentials.create({
          name: name.trim(),
          capabilityBindings: caps,
        })
      onCreated(r)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <DialogShell
      title={mode === 'platform' ? '新建 Runtime 凭证' : '接入新 Agent'}
      subtitle="client_secret 只在创建完成后显示一次。"
      icon={<KeyRound size={18} />}
      onClose={onCancel}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onCancel}>取消</Button>
          <Button onClick={submit} disabled={submitting}>{submitting ? '创建中...' : '创建'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <InlineAlert tone="info">
          {mode === 'platform'
            ? '平台凭证只能用于换发短期 st_，不能直接作为 Bearer 调业务接口。'
            : '租户凭证只能在本租户范围内换发短期 st_，不能跨租户使用。'}
        </InlineAlert>
        <FormField label="名称">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={mode === 'platform' ? '例：HR Runtime Backchannel' : '例：销售助理 Agent'}
          />
        </FormField>
        {mode === 'platform' && !fixedRuntime && (
          <FormField label="绑定运行环境">
            <Select value={runtimeID || ''} onChange={(e) => setRuntimeID(Number(e.target.value))}>
              <option value="">请选择运行环境</option>
              {activeRuntimes.map((r) => (
                <option key={r.ID} value={r.ID}>{r.Name} ({r.Code || r.UUID})</option>
              ))}
            </Select>
          </FormField>
        )}
        {mode === 'platform' && (
          <FormField label="授权租户" as="div">
            <div className="space-y-2">
              <label className="flex cursor-pointer items-center gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px]">
                <input
                  type="radio"
                  checked={tenantGrantMode === 'all_enabled'}
                  onChange={() => setTenantGrantMode('all_enabled')}
                />
                <span>全部已启用该 Runtime 的租户</span>
              </label>
              <label className="flex cursor-pointer items-center gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px]">
                <input
                  type="radio"
                  checked={tenantGrantMode === 'allowlist'}
                  onChange={() => setTenantGrantMode('allowlist')}
                />
                <span>指定租户名单</span>
              </label>
              {tenantGrantMode === 'allowlist' && (
                <div className="grid max-h-48 gap-2 overflow-auto rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-2 sm:grid-cols-2">
                  {tenants.length === 0 ? (
                    <div className="col-span-full px-2 py-3 text-[13px] text-[var(--color-text-sub)]">暂无可选租户</div>
                  ) : tenants.map((t) => (
                    <label key={t.ID} className="flex cursor-pointer items-center gap-2 rounded-md bg-white px-3 py-2 text-[13px]">
                      <input
                        type="checkbox"
                        checked={allowedTenantIDs.includes(t.ID)}
                        onChange={(e) => setAllowedTenantIDs(e.target.checked
                          ? [...allowedTenantIDs, t.ID]
                          : allowedTenantIDs.filter((id) => id !== t.ID))}
                      />
                      <span className="min-w-0 flex-1 truncate" title={t.DisplayName || t.Name}>{t.DisplayName || t.Name}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>
          </FormField>
        )}
        <FormField label="可用能力" as="div">
          <div className="grid gap-2 sm:grid-cols-2">
            {capsSource.map((s) => (
              <label key={s} className="flex cursor-pointer items-center gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px]">
                <input
                  type="checkbox"
                  checked={caps.includes(s)}
                  onChange={(e) => setCaps(e.target.checked ? [...caps, s] : caps.filter((x) => x !== s))}
                />
                <span>{CAP_LABEL[s]}</span>
                <span className="ml-auto font-mono text-[11px] text-[var(--color-text-mute)]">{s}</span>
              </label>
            ))}
          </div>
        </FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DialogShell>
  )
}

export function CredentialCreatedDialog({
  mode,
  credential,
  onClose,
}: {
  mode: PageMode
  credential: CreateAgentSdkCredentialResult
  onClose: () => void
}) {
  const [copied, setCopied] = useState<'id' | 'sec' | null>(null)
  const c = credential.credential
  const copy = (text: string, which: 'id' | 'sec') => {
    navigator.clipboard.writeText(text).then(() => setCopied(which))
  }
  return (
    <DialogShell
      title="凭证创建成功"
      subtitle="关闭后 client_secret 不可再次查看。"
      icon={<ShieldAlert size={18} />}
      onClose={onClose}
      size="lg"
      footer={<div className="flex justify-end"><Button onClick={onClose}>我已保存</Button></div>}
    >
      <div className="space-y-4">
        <SecretRow label="Client ID" value={c.clientId} copied={copied === 'id'} onCopy={() => copy(c.clientId, 'id')} />
        <SecretRow label="Client Secret" value={credential.clientSecret} copied={copied === 'sec'} onCopy={() => copy(credential.clientSecret, 'sec')} />
        <div>
          <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">换发示例</div>
          <pre className="overflow-x-auto rounded-md bg-[var(--color-bg-sub)] p-3 text-[11px] leading-relaxed text-[var(--color-text)]">
            {mode === 'platform' ? platformCurl(c.clientId) : tenantCurl(c.clientId)}
          </pre>
        </div>
      </div>
    </DialogShell>
  )
}

function SecretRow({
  label,
  value,
  copied,
  onCopy,
}: {
  label: string
  value: string
  copied: boolean
  onCopy: () => void
}) {
  return (
    <div>
      <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">{label}</div>
      <div className="flex gap-2">
        <div className="min-w-0 flex-1 break-all rounded-md bg-[var(--color-bg-sub)] p-2 font-mono text-[12px] text-[var(--color-text)]">
          {value}
        </div>
        <Button variant="secondary" onClick={onCopy}>
          <Copy size={14} /> {copied ? '已复制' : '复制'}
        </Button>
      </div>
    </div>
  )
}

function tenantCurl(clientID: string) {
  return `curl -X POST https://api.example.com/api/external/v1/oauth/token \\
  -H "Content-Type: application/json" \\
  -d '{
    "grant_type": "client_credentials",
    "client_id": "${clientID}",
    "client_secret": "<client_secret>"
  }'`
}

function platformCurl(clientID: string) {
  return `curl -X POST https://api.example.com/api/external/v1/oauth/token \\
  -H "Content-Type: application/json" \\
  -d '{
    "grant_type": "runtime_access",
    "client_id": "${clientID}",
    "client_secret": "<client_secret>",
    "tenant_id": "<tenant_id>"
  }'`
}
