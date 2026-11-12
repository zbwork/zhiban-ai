import { useMemo, useState, type ReactNode } from 'react'
import { AlertTriangle, Eye, Search, ShieldCheck } from 'lucide-react'
import { Button, DataTable, EmptyState, FormField, InlineAlert, Input, PageHeader } from '../components/ui'
import { UserKBInspect, type UserPrivateKB } from '../lib/api'

function formatDate(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

function statusClass(status?: string) {
  if (status === 'active' || status === 'ready') return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  if (status === 'failed' || status === 'error') return 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
  return 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
}

function statusLabel(status?: string) {
  const labels: Record<string, string> = {
    active: '可用',
    ready: '可用',
    pending: '处理中',
    provisioning: '供给中',
    failed: '异常',
    error: '异常',
    archived: '已归档',
  }
  return status ? (labels[status] || status) : '-'
}

export function UserKBInspectPage() {
  const [userUuid, setUserUuid] = useState('')
  const [items, setItems] = useState<UserPrivateKB[]>([])
  const [consented, setConsented] = useState(false)
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [hasQueried, setHasQueried] = useState(false)
  const [lastQueryUser, setLastQueryUser] = useState('')

  const privateCount = useMemo(() => items.filter((kb) => kb.space_kind === 'personal' || kb.visibility === 'private').length, [items])
  const documentCount = useMemo(() => items.reduce((sum, kb) => sum + (kb.total_documents || 0), 0), [items])

  const query = async () => {
    const target = userUuid.trim()
    if (!target) {
      setErr('请输入用户 UUID')
      return
    }
    if (!consented) {
      setErr('请先确认本次查询有业务必要，并理解会写入审计记录')
      return
    }
    setLoading(true)
    setErr('')
    try {
      const r = await UserKBInspect.list(target)
      setItems(r.items || [])
      setLastQueryUser(target)
      setHasQueried(true)
    } catch (e) {
      setErr((e as Error).message)
      setItems([])
      setHasQueried(false)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="max-w-6xl">
      <PageHeader
        title="用户私有知识库审计查询"
        subtitle="按用户 UUID 查询该用户在当前租户下的个人知识库元数据，用于离职交接、合规排查和数据归集。"
      />

      <div className="mb-4 rounded-lg border border-amber-200 bg-[var(--color-warn-bg)] p-4">
        <div className="flex gap-3">
          <AlertTriangle size={18} className="mt-0.5 shrink-0 text-[var(--color-warn)]" />
          <div className="min-w-0">
            <div className="text-[14px] font-semibold text-[var(--color-text)]">审计查询确认</div>
            <p className="mt-1 text-[13px] leading-relaxed text-[var(--color-text-sub)]">
              本页只返回知识库名称、描述、状态和文档数，不返回文档内容；查询范围限定在当前租户。每次查询都会由后端写入审计记录。
            </p>
            <label className="mt-3 flex items-start gap-2 text-[13px] text-[var(--color-text)]">
              <input
                type="checkbox"
                className="mt-0.5 h-4 w-4 rounded border-[var(--color-line)]"
                checked={consented}
                onChange={(e) => {
                  setConsented(e.target.checked)
                  if (e.target.checked) setErr('')
                }}
              />
              <span>我确认本次查询有业务必要，并理解会记录查询人、目标用户、查询时间和结果数量。</span>
            </label>
          </div>
        </div>
      </div>

      <div className="mb-4 rounded-lg border border-[var(--color-line)] bg-white p-4">
        <div className="grid grid-cols-1 gap-3 md:grid-cols-[minmax(280px,1fr)_auto]">
          <FormField
            label="用户 UUID"
            hint="输入要审计的用户 UUID。查询结果仅限当前租户，不展示文档正文。"
          >
            <Input
              value={userUuid}
              onChange={(e) => setUserUuid(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && consented && !loading) void query()
              }}
              placeholder="例如 acc_xxxx-yyyy-..."
              disabled={loading}
            />
          </FormField>
          <div className="flex items-end">
            <Button onClick={query} disabled={loading || !consented}>
              <Search size={14} />
              {loading ? '查询中' : '查询'}
            </Button>
          </div>
        </div>
      </div>

      {err && <div className="mb-4"><InlineAlert>{err}</InlineAlert></div>}

      {hasQueried && (
        <>
          <div className="mb-4 grid grid-cols-1 gap-3 md:grid-cols-3">
            <Metric icon={<ShieldCheck size={16} />} label="目标用户" value={lastQueryUser} />
            <Metric icon={<Eye size={16} />} label="知识库数量" value={`${privateCount}`} />
            <Metric icon={<Search size={16} />} label="文档数" value={`${documentCount}`} />
          </div>

          <DataTable
            headers={['知识库 UUID', '名称', '描述', '文档数', '状态', '创建时间']}
            empty={items.length === 0 ? (
              <EmptyState
                icon={<Eye size={22} />}
                title="该用户没有个人知识库"
                description="后端已完成审计记录，本次查询未返回个人知识库元数据。"
              />
            ) : undefined}
          >
            {items.map((kb) => (
              <tr key={kb.uuid} className="transition hover:bg-[var(--color-bg-sub)]">
                <td className="px-4 py-3 font-mono text-[11px] text-[var(--color-text-mute)]">{kb.uuid}</td>
                <td className="px-4 py-3 font-medium text-[var(--color-text)]">{kb.name || '-'}</td>
                <td className="px-4 py-3 max-w-[360px] truncate text-[12px] text-[var(--color-text-sub)]" title={kb.description || ''}>
                  {kb.description || '-'}
                </td>
                <td className="px-4 py-3 text-[12px] tabular-nums text-[var(--color-text-sub)]">{kb.total_documents ?? 0}</td>
                <td className="px-4 py-3">
                  <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] font-medium ${statusClass(kb.status)}`}>
                    {statusLabel(kb.status)}
                  </span>
                </td>
                <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{formatDate(kb.created_at)}</td>
              </tr>
            ))}
          </DataTable>
        </>
      )}
    </div>
  )
}

function Metric({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-3">
      <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-mute)]">
        {icon}
        {label}
      </div>
      <div className="mt-2 truncate text-[16px] font-semibold text-[var(--color-text)]" title={value}>
        {value}
      </div>
    </div>
  )
}
