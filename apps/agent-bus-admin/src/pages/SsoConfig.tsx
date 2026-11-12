import { useEffect, useState } from 'react'
import { IdentityProviders, type IdentityProvider, type CreateIdentityProviderInput } from '../lib/api'
import { X, ShieldCheck, ShieldOff, ShieldAlert } from 'lucide-react'
import { ConfirmDialog, PageHeader, PrimaryButton, RowActions } from '../components/ui'

const KIND_LABEL: Record<string, string> = {
  oidc: 'OIDC (推荐)',
  saml: 'SAML 2.0',
  ldap: 'LDAP',
  scim: 'SCIM Receiver',
}

const STATUS_COLOR: Record<string, string> = {
  active: 'bg-green-100 text-green-700',
  disabled: 'bg-gray-100 text-gray-600',
}

const STATUS_LABEL: Record<string, string> = {
  active: '启用',
  disabled: '已停用',
}

export function SsoConfigPage() {
  const [items, setItems] = useState<IdentityProvider[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [removing, setRemoving] = useState<IdentityProvider | null>(null)

  useEffect(() => {
    IdentityProviders.list()
      .then((r) => { setItems(r.items || []); setErr('') })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [tick])

  const refresh = () => setTick((t) => t + 1)

  return (
    <div>
      <PageHeader
        title="SSO 接入 (IdP 配置)"
        subtitle="把企业 IdP (Azure AD / Okta / Keycloak / Google) 接进来, 用户用企业账号扫码登 admin。支持 OIDC 协议; SAML/LDAP/SCIM 后续 milestone 落地。"
        actions={<PrimaryButton onClick={() => setCreating(true)}>接入新 IdP</PrimaryButton>}
      />

      {err && <div className="mb-4 p-3 rounded-md bg-red-50 text-red-700 text-[13px]">{err}</div>}

      <div className="rounded-md ring-border bg-white overflow-hidden">
        <table className="w-full text-[13px]">
          <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
            <tr>
              <th className="text-left px-4 py-3">名称</th>
              <th className="text-left px-4 py-3">协议</th>
              <th className="text-left px-4 py-3">Issuer / Endpoint</th>
              <th className="text-left px-4 py-3">Client ID</th>
              <th className="text-left px-4 py-3">Scopes</th>
              <th className="text-left px-4 py-3">状态</th>
              <th className="text-left px-4 py-3">创建</th>
              <th className="text-left px-4 py-3">操作</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr><td colSpan={8} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中…</td></tr>
            )}
            {!loading && items.length === 0 && (
              <tr><td colSpan={8} className="px-4 py-12 text-center text-[var(--color-text-sub)]">
                <ShieldCheck size={28} className="mx-auto mb-2 opacity-40" />
                还没接入 IdP。点右上角接入第一个。
              </td></tr>
            )}
            {items.map((p) => (
              <tr key={p.uuid} className="border-t border-[var(--color-border)]">
                <td className="px-4 py-3 font-medium">{p.name}</td>
                <td className="px-4 py-3">{KIND_LABEL[p.kind] || p.kind}</td>
                <td className="px-4 py-3 font-mono text-[11px] truncate max-w-xs">{p.issuer || '—'}</td>
                <td className="px-4 py-3 font-mono text-[11px] truncate max-w-xs">{p.clientId || '—'}</td>
                <td className="px-4 py-3 space-x-1">
                  {(p.scopes || []).map((s) => (
                    <span key={s} className="inline-block px-1.5 py-0.5 rounded bg-blue-50 text-blue-700 text-[11px]">{s}</span>
                  ))}
                </td>
                <td className="px-4 py-3">
                  <span className={`inline-block px-2 py-0.5 rounded text-[11px] ${STATUS_COLOR[p.status]}`}>
                    {p.status === 'active' ? <ShieldCheck size={11} className="inline mr-1" /> : <ShieldOff size={11} className="inline mr-1" />}
                    {STATUS_LABEL[p.status] || p.status}
                  </span>
                </td>
                <td className="px-4 py-3 text-[var(--color-text-sub)]">{new Date(p.createdAt).toLocaleDateString()}</td>
                <td className="px-4 py-3">
                  <RowActions onDelete={() => setRemoving(p)} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {creating && (
        <CreateModal
          onCancel={() => setCreating(false)}
          onCreated={() => { setCreating(false); refresh() }}
        />
      )}
      {removing && (
        <RemoveModal
          item={removing}
          onCancel={() => setRemoving(null)}
          onDone={() => { setRemoving(null); refresh() }}
        />
      )}
    </div>
  )
}

function CreateModal({ onCancel, onCreated }: { onCancel: () => void; onCreated: () => void }) {
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  const defaultRedirect = `${origin}/auth/oidc/callback`

  const [form, setForm] = useState<CreateIdentityProviderInput>({
    kind: 'oidc',
    name: '',
    issuer: '',
    clientId: '',
    clientSecret: '',
    redirectUri: defaultRedirect,
    scopes: ['openid', 'email', 'profile'],
  })
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  const set = <K extends keyof CreateIdentityProviderInput>(k: K, v: CreateIdentityProviderInput[K]) => setForm((f) => ({ ...f, [k]: v }))

  const submit = async () => {
    setErr('')
    if (!form.name.trim()) { setErr('名称必填'); return }
    if (form.kind === 'oidc') {
      if (!form.issuer || !form.clientId || !form.clientSecret || !form.redirectUri) {
        setErr('OIDC 必填: issuer / clientId / clientSecret / redirectUri'); return
      }
    }
    setSubmitting(true)
    try {
      await IdentityProviders.create({
        ...form,
        name: form.name.trim(),
        issuer: form.issuer?.trim(),
        clientId: form.clientId?.trim(),
        redirectUri: form.redirectUri?.trim(),
      })
      onCreated()
    } catch (e) {
      setErr((e as Error).message); setSubmitting(false)
    }
  }

  return (
    <Modal title="接入新 IdP" onClose={onCancel}>
      <div className="space-y-4">
        <div className="p-3 rounded-md bg-blue-50 border border-blue-200 text-blue-800 text-[12px] flex gap-2">
          <ShieldAlert size={16} className="flex-shrink-0 mt-0.5" />
          <div>
            <b>对 Google:</b> issuer = <code>https://accounts.google.com</code>。Client ID/Secret 在 Google Cloud Console
            "API 与服务 → 凭据" 里拿。Authorized redirect URI 必须等于下方 redirectUri。
            <br /><b>对 Azure AD:</b> issuer = <code>https://login.microsoftonline.com/{'{tenant_guid}'}/v2.0</code>
          </div>
        </div>
        <Field label="协议">
          <select
            value={form.kind}
            onChange={(e) => set('kind', e.target.value as never)}
            className="h-9 px-2 rounded-md ring-border bg-white text-[13px]"
          >
            {Object.entries(KIND_LABEL).map(([k, v]) => (
              <option key={k} value={k} disabled={k !== 'oidc'}>
                {v}{k !== 'oidc' ? ' (后续支持)' : ''}
              </option>
            ))}
          </select>
        </Field>
        <Field label="名称 (Login 页按钮文案)">
          <input value={form.name} onChange={(e) => set('name', e.target.value)} placeholder="例: 用 Google 登录" className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px]" />
        </Field>
        <Field label="Issuer URL">
          <input value={form.issuer || ''} onChange={(e) => set('issuer', e.target.value)} placeholder="https://accounts.google.com" className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] font-mono" />
        </Field>
        <Field label="Client ID">
          <input value={form.clientId || ''} onChange={(e) => set('clientId', e.target.value)} placeholder="从 IdP 后台复制" className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] font-mono" />
        </Field>
        <Field label="Client Secret (入库 AES-GCM 加密; 出库不可见)">
          <input type="password" value={form.clientSecret || ''} onChange={(e) => set('clientSecret', e.target.value)} placeholder="从 IdP 后台复制" className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] font-mono" />
        </Field>
        <Field label="Redirect URI (必须在 IdP 后台 Authorized redirect URIs 里登记)">
          <input value={form.redirectUri || ''} onChange={(e) => set('redirectUri', e.target.value)} className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] font-mono" />
        </Field>
        <Field label="Scopes (逗号分隔)">
          <input
            value={(form.scopes || []).join(', ')}
            onChange={(e) => set('scopes', e.target.value.split(',').map((s) => s.trim()).filter(Boolean))}
            className="w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] font-mono"
          />
        </Field>
        {err && <div className="text-red-600 text-[12px]">{err}</div>}
        <div className="flex justify-end gap-2 pt-2">
          <button onClick={onCancel} className="h-9 px-3 rounded-md ring-border bg-white text-[13px]">取消</button>
          <button onClick={submit} disabled={submitting} className="h-9 px-3 rounded-md bg-[var(--color-text)] text-white text-[13px] disabled:opacity-50">
            {submitting ? '保存中…' : '保存'}
          </button>
        </div>
      </div>
    </Modal>
  )
}

function RemoveModal({ item, onCancel, onDone }: { item: IdentityProvider; onCancel: () => void; onDone: () => void }) {
  return (
    <ConfirmDialog
      title="删除 IdP"
      description={<>确认删除 <b>{item.name}</b>（{item.kind}）吗？</>}
      confirmLabel="删除"
      busyLabel="删除中..."
      onClose={onCancel}
      onConfirm={async () => {
        await IdentityProviders.remove(item.uuid)
        onDone()
      }}
    >
      <p className="text-[13px] leading-relaxed text-[var(--color-text-sub)]">
        删除后，登录页该按钮会立即消失；已绑定该 IdP 的用户仍可使用账号密码登录。
      </p>
    </ConfirmDialog>
  )
}

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30" onClick={onClose}>
      <div className="bg-white rounded-lg shadow-lg w-[520px] max-w-[92vw] p-5 max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-[16px] font-semibold">{title}</h2>
          <button onClick={onClose} className="p-1 rounded hover:bg-[var(--color-bg-soft)]"><X size={16} /></button>
        </div>
        {children}
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="text-[12px] text-[var(--color-text-sub)] mb-1">{label}</div>
      {children}
    </div>
  )
}
