import { useEffect, useMemo, useState } from 'react'
import { Copy, KeyRound, ShieldAlert } from 'lucide-react'
import { ApiKeys, type ApiKey, type CreateApiKeyResult } from '../lib/api'
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
  Pagination,
  PrimaryButton,
  RowActions,
  SearchInput,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

const SCOPE_LABEL: Record<string, string> = {
  'tenant.kb.read': '知识库读取',
  'tenant.kb.write': '知识库写入',
  'tenant.kb.admin': '知识库管理员',
  'tenant.kb.list_user_private': '跨用户私有 KB metadata',
  'tenant.kb.read_user_private': '跨用户私有 KB 内容',
  'tenant.memory.read': '记忆读取',
  'tenant.memory.write': '记忆写入',
  'kb.read': '知识库读取(旧)',
  'drive.read': '云盘读取',
  'tenant.org.read': '组织架构读取',
  'tenant.org.write': '组织架构写入',
  'tenant.org.admin': '组织架构管理员',
  'tenant.auth.introspect': '用户 token 解码',
  'tenant.notification.write': '通知写入',
  'tenant.chat.message.write': '主动消息写入',
}

const ALL_SCOPES = [
  'tenant.kb.read',
  'tenant.kb.write',
  'tenant.kb.admin',
  'tenant.kb.list_user_private',
  'tenant.kb.read_user_private',
  'tenant.memory.read',
  'tenant.memory.write',
  'drive.read',
  'tenant.org.read',
  'tenant.org.write',
  'tenant.org.admin',
  'tenant.auth.introspect',
  'tenant.notification.write',
  'tenant.chat.message.write',
]

type ApiKeyStatusFilter = '' | ApiKey['status']

const STATUS_LABEL: Record<ApiKey['status'], string> = {
  active: '生效中',
  revoked: '已撤销',
  expired: '已过期',
}

function statusClass(status: ApiKey['status']) {
  if (status === 'active') return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  if (status === 'expired') return 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
  return 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'
}

function columnHeader(label: string, className: string) {
  return <span className={`inline-block ${className}`}>{label}</span>
}

function formatDateTime(raw?: string) {
  if (!raw) return '-'
  const t = new Date(raw)
  if (Number.isNaN(t.getTime())) return '-'
  return t.toLocaleString('zh-CN', { hour12: false })
}

function formatDate(raw?: string) {
  if (!raw) return '永不'
  const t = new Date(raw)
  if (Number.isNaN(t.getTime())) return '-'
  return t.toLocaleDateString('zh-CN')
}

export function ApiKeysPage() {
  const [items, setItems] = useState<ApiKey[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [keyword, setKeyword] = useState('')
  const [status, setStatus] = useState<ApiKeyStatusFilter>('active')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [credential, setCredential] = useState<CreateApiKeyResult | null>(null)
  const [revoking, setRevoking] = useState<ApiKey | null>(null)

  useEffect(() => {
    let alive = true
    ApiKeys.list({
      status,
      q: keyword,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (!alive) return
        setItems(r.items || [])
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => alive && setErr(e.message))
      .finally(() => alive && setLoading(false))
    return () => { alive = false }
  }, [status, keyword, page, pageSize, tick])

  const refresh = () => {
    setLoading(true)
    setTick((t) => t + 1)
  }
  const changeKeyword = (value: string) => {
    setKeyword(value)
    setPage(1)
    setLoading(true)
  }
  const changeStatus = (value: ApiKeyStatusFilter) => {
    setStatus(value)
    setPage(1)
    setLoading(true)
  }
  const changePage = (value: number) => {
    setPage(value)
    setLoading(true)
  }
  const changePageSize = (value: number) => {
    setPageSize(value)
    setPage(1)
    setLoading(true)
  }
  const statusSummary = useMemo(() => {
    if (!status) return '全部状态'
    return STATUS_LABEL[status]
  }, [status])

  return (
    <div>
      <PageHeader
        title="API Keys"
        subtitle="外部系统调用 Bus 的长期机器凭证。明文 secret 仅在创建时返回一次，关闭后不可恢复。"
      />

      <Toolbar
        search={<SearchInput value={keyword} onChange={changeKeyword} placeholder="搜索名称 / Key 前缀" />}
        filters={(
          <div className="w-[148px]">
            <Select value={status} onChange={(e) => changeStatus(e.target.value as ApiKeyStatusFilter)}>
              <option value="active">生效中</option>
              <option value="">全部状态</option>
              <option value="revoked">已撤销</option>
              <option value="expired">已过期</option>
            </Select>
          </div>
        )}
        summary={<span>{statusSummary} · 共 {total} 条</span>}
        actions={<PrimaryButton onClick={() => setCreating(true)}>新建 Key</PrimaryButton>}
      />

      {err && <div className="mb-3"><InlineAlert>{err}</InlineAlert></div>}

      <DataTable
        stickyLastCol
        headers={[
          columnHeader('名称', 'min-w-[260px]'),
          columnHeader('Key 前缀', 'min-w-[176px]'),
          columnHeader('Scope', 'min-w-[260px]'),
          columnHeader('状态', 'min-w-[96px]'),
          columnHeader('最近使用', 'min-w-[168px]'),
          columnHeader('过期时间', 'min-w-[124px]'),
          columnHeader('创建时间', 'min-w-[124px]'),
          columnHeader('操作', 'min-w-[104px]'),
        ]}
        loading={loading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div> : null}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<KeyRound size={28} />}
            title="暂无 API Key"
            description={keyword || status !== 'active' ? '当前筛选条件下没有匹配的 API Key。' : '创建后，外部系统可使用 scoped key 调用授权的 External API。'}
          />
        ) : null}
      >
        {items.map((k) => (
          <tr key={k.uuid} className="group">
            <td className="min-w-[260px] max-w-[360px] truncate px-4 py-3 font-medium text-[var(--color-text)]" title={k.name}>
              {k.name}
            </td>
            <td className="min-w-[176px] whitespace-nowrap px-4 py-3 font-mono text-[12px] text-[var(--color-text-sub)]">
              ek_{k.keyPrefix}_********
            </td>
            <td className="min-w-[260px] px-4 py-3">
              <ScopeBadges scopes={k.scopes || []} />
            </td>
            <td className="min-w-[96px] whitespace-nowrap px-4 py-3">
              <span className={`inline-flex rounded-md px-2 py-0.5 text-[12px] ${statusClass(k.status)}`}>
                {STATUS_LABEL[k.status] || k.status}
              </span>
            </td>
            <td className="min-w-[168px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
              {formatDateTime(k.lastUsedAt)}
            </td>
            <td className="min-w-[124px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
              {formatDate(k.expiresAt)}
            </td>
            <td className="min-w-[124px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">
              {formatDate(k.createdAt)}
            </td>
            <td className={`${stickyRightTdCls} min-w-[104px] px-4 py-3`}>
              {k.status === 'active' ? (
                <RowActions deleteLabel="撤销" onDelete={() => setRevoking(k)} />
              ) : (
                <span className="text-[var(--color-text-mute)]">-</span>
              )}
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={changePage}
        onPageSizeChange={changePageSize}
      />

      {creating && (
        <CreateDialog
          onCancel={() => setCreating(false)}
          onCreated={(res) => { setCreating(false); setCredential(res); refresh() }}
        />
      )}
      {credential && (
        <CredentialCreatedDialog credential={credential} onClose={() => setCredential(null)} />
      )}
      {revoking && (
        <ConfirmDialog
          title="撤销 API Key"
          description={(
            <span>
              确认撤销 <b>{revoking.name}</b> 吗？撤销后调用方会立即收到 401，该操作不可恢复。
            </span>
          )}
          confirmLabel="确认撤销"
          busyLabel="撤销中..."
          onClose={() => setRevoking(null)}
          onConfirm={async () => {
            await ApiKeys.revoke(revoking.uuid)
            setRevoking(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function ScopeBadges({ scopes }: { scopes: string[] }) {
  if (scopes.length === 0) return <span className="text-[var(--color-text-mute)]">-</span>
  return (
    <div className="flex max-w-[360px] flex-wrap gap-1.5">
      {scopes.map((s) => (
        <span
          key={s}
          className="inline-flex rounded-md bg-[var(--color-brand-soft)] px-1.5 py-0.5 text-[11px] text-[var(--color-brand)]"
          title={s}
        >
          {SCOPE_LABEL[s] || s}
        </span>
      ))}
    </div>
  )
}

function CreateDialog({ onCancel, onCreated }: { onCancel: () => void; onCreated: (r: CreateApiKeyResult) => void }) {
  const [name, setName] = useState('')
  const [scopes, setScopes] = useState<string[]>(['tenant.kb.read'])
  const [expiresAt, setExpiresAt] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  const submit = async () => {
    setErr('')
    if (!name.trim()) { setErr('名称必填'); return }
    if (scopes.length === 0) { setErr('至少勾选一个 Scope'); return }
    setSubmitting(true)
    try {
      const r = await ApiKeys.create({
        name: name.trim(),
        scopes,
        expiresAt: expiresAt ? new Date(expiresAt).toISOString() : null,
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
      title="新建 API Key"
      subtitle="创建完成后请立即复制 secret；后台不会再次展示明文。"
      icon={<KeyRound size={18} />}
      onClose={onCancel}
      size="lg"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onCancel} disabled={submitting}>取消</Button>
          <Button onClick={submit} disabled={submitting}>{submitting ? '创建中...' : '创建'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <FormField label="名称">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="例：CRM 同步任务"
          />
        </FormField>
        <FormField label="Scope" as="div" hint="只勾选外部系统实际需要的能力，避免过度授权。">
          <div className="grid gap-2 sm:grid-cols-2">
            {ALL_SCOPES.map((s) => (
              <label
                key={s}
                className="flex cursor-pointer items-start gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 py-2 text-[13px] hover:bg-[var(--color-bg-sub)]"
              >
                <input
                  type="checkbox"
                  className="mt-0.5 accent-[var(--color-brand)]"
                  checked={scopes.includes(s)}
                  onChange={(e) => setScopes(e.target.checked ? [...scopes, s] : scopes.filter((x) => x !== s))}
                />
                <span className="min-w-0">
                  <span className="block font-medium text-[var(--color-text)]">{SCOPE_LABEL[s] || s}</span>
                  <span className="block truncate font-mono text-[11px] text-[var(--color-text-sub)]" title={s}>{s}</span>
                </span>
              </label>
            ))}
          </div>
        </FormField>
        <FormField label="过期时间" hint="留空表示永不过期；生产系统建议按调用方系统设置合理有效期。">
          <Input
            type="date"
            value={expiresAt}
            onChange={(e) => setExpiresAt(e.target.value)}
          />
        </FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DialogShell>
  )
}

function CredentialCreatedDialog({ credential, onClose }: { credential: CreateApiKeyResult; onClose: () => void }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    navigator.clipboard.writeText(credential.secret).then(() => setCopied(true))
  }
  return (
    <DialogShell
      title="API Key 创建成功"
      subtitle="明文 secret 只显示这一次。"
      icon={<ShieldAlert size={18} />}
      onClose={onClose}
      size="lg"
      footer={(
        <div className="flex justify-end">
          <Button onClick={onClose}>我已保存</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <InlineAlert tone="warn">
          请立即复制并保存到调用方的 env / Vault。关闭弹窗后不可再次查看；库里只存 sha256 哈希。
        </InlineAlert>
        <div>
          <div className="mb-1.5 text-[12px] font-medium text-[var(--color-text-sub)]">明文 Secret</div>
          <div className="break-all rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3 font-mono text-[12px] text-[var(--color-text)]">
            {credential.secret}
          </div>
          <Button variant="secondary" onClick={copy} className="mt-2">
            <Copy size={14} /> {copied ? '已复制' : '复制到剪贴板'}
          </Button>
        </div>
        <div className="text-[12px] text-[var(--color-text-sub)]">
          调用示例:
          <pre className="mt-1 overflow-x-auto rounded-md bg-[var(--color-bg-sub)] p-3 text-[11px]">
{`curl -H "Authorization: Bearer ${credential.secret}" \\
  https://api.example.com/api/external/v1/knowledge-bases/<kb_uuid>/documents`}
          </pre>
        </div>
      </div>
    </DialogShell>
  )
}
