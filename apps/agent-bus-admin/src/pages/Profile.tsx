import { useEffect, useState } from 'react'
import { Auth, type AccountSummary, type ScopeOption } from '../lib/api'
import { PageHeader } from '../components/ui'

export function Profile() {
  const [account, setAccount] = useState<AccountSummary | null>(null)
  const [scopes, setScopes] = useState<ScopeOption[]>([])
  const [err, setErr] = useState('')

  useEffect(() => {
    Auth.me()
      .then((d) => {
        setAccount(d.account)
        setScopes(d.scopes || [])
      })
      .catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <div className="text-sm text-red-700">{err}</div>
  if (!account) return <div className="text-[var(--color-ink-mute)]">加载中…</div>

  return (
    <div>
      <PageHeader title="个人资料" subtitle="查看与管理你在 Agent Bus 上的账号。" />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 bg-white rounded-lg card-shadow p-6">
          <div className="flex items-center gap-4 mb-6">
            <div className="w-16 h-16 rounded-full bg-[var(--color-terracotta)]/15 text-[var(--color-terracotta-deep)] grid place-items-center text-2xl font-medium">
              {account.displayName[0]}
            </div>
            <div>
              <div className="text-xl font-semibold">{account.displayName}</div>
              <div className="text-xs text-[var(--color-ink-mute)] font-mono">{account.uuid}</div>
            </div>
          </div>

          <dl className="grid grid-cols-1 sm:grid-cols-2 gap-y-4 gap-x-8 text-sm">
            <Row label="账号 ID" value={`#${account.id}`} mono />
            <Row label="邮箱" value={account.email || '—'} mono />
            <Row label="手机号" value={account.phone || '—'} mono />
            <Row label="用户名" value={account.username || '—'} mono />
          </dl>
        </div>

        <div className="bg-white rounded-lg card-shadow p-6">
          <h3 className="text-lg mb-3">可切换范畴</h3>
          {scopes.length === 0 && (
            <div className="text-sm text-[var(--color-ink-mute)]">暂无可切换范畴</div>
          )}
          <div className="space-y-2">
            {scopes.map((s) => (
              <div key={`${s.kind}:${s.tenantId || 0}:${s.workspaceId || 0}`} className="p-3 rounded-lg border border-[var(--color-line)]">
                <div className="text-sm font-medium">{scopeLabel(s)}</div>
                <div className="text-xs text-[var(--color-ink-mute)] mt-0.5">{s.roles?.join(', ') || '成员'}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

function scopeLabel(scope: ScopeOption) {
  if (scope.kind === 'platform') return '平台'
  if (scope.kind === 'workspace') return scope.workspaceName || `工作区 #${scope.workspaceId}`
  return scope.tenantName || `租户 #${scope.tenantId}`
}

function Row({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <dt className="text-xs uppercase tracking-wide text-[var(--color-ink-mute)] mb-0.5">{label}</dt>
      <dd className={mono ? 'font-mono text-[var(--color-ink)]' : 'text-[var(--color-ink)]'}>{value}</dd>
    </div>
  )
}
