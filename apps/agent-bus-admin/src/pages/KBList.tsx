import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { BookOpen, Database, FileText, RefreshCw, ShieldCheck } from 'lucide-react'
import { ManagedKB, type ManagedKBScope, type TenantKBItem } from '../lib/api'
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
} from '../components/ui'
import { notifyOk } from '../lib/toast'

type StatusFilter = 'all' | 'active' | 'pending' | 'failed'

function isActive(kb: TenantKBItem) {
  return kb.status === 'active' && (kb.provision_status === 'ready' || kb.provision_status === 'active')
}

function isFailed(kb: TenantKBItem) {
  return kb.status === 'failed' || kb.provision_status === 'failed' || kb.provision_status === 'error'
}

function kbStatusLabel(kb: TenantKBItem) {
  if (isFailed(kb)) return '异常'
  if (isActive(kb)) return '可用'
  return '配置中'
}

function kbStatusClass(kb: TenantKBItem) {
  if (isFailed(kb)) return 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
  if (isActive(kb)) return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  return 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
}

function formatDate(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString()
}

export function KBListPage() {
  return <ManagedKBListPage scope="tenant" />
}

export function PlatformKBListPage() {
  return <ManagedKBListPage scope="platform" />
}

function ManagedKBListPage({ scope }: { scope: ManagedKBScope }) {
  const platform = scope === 'platform'
  const [items, setItems] = useState<TenantKBItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState<StatusFilter>('all')
  const [editing, setEditing] = useState<TenantKBItem | 'new' | null>(null)
  const [deleting, setDeleting] = useState<{ kb: TenantKBItem; refs: number } | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      const result = await ManagedKB.list(scope, {
        q: query,
        status: status === 'all' ? '' : status,
        limit: pageSize,
        offset: (page - 1) * pageSize,
      })
      setItems(result.items || [])
      setTotal(result.total || 0)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [page, pageSize, query, scope, status])

  useEffect(() => {
    const timer = window.setTimeout(load, 200)
    return () => window.clearTimeout(timer)
  }, [load])

  const summary = useMemo(() => ({
    active: items.filter(isActive).length,
    failed: items.filter(isFailed).length,
    documents: items.reduce((sum, kb) => sum + (kb.total_documents || 0), 0),
  }), [items])

  const requestDelete = async (kb: TenantKBItem) => {
    setErr('')
    try {
      const refs = await ManagedKB.references(scope, kb.uuid)
      setDeleting({ kb, refs: refs.active_agent_count || 0 })
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  return (
    <div>
      <PageHeader
        title="知识库管理"
        subtitle={platform
          ? '维护平台内置知识库，并将已就绪知识库装配给平台数字员工模版。'
          : '维护租户共享知识库、目录和文件；个人私有知识库仍由用户在客户端管理。'}
        actions={(
          <div className="flex gap-2">
            <Button variant="secondary" onClick={load} disabled={loading}>
              <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />刷新
            </Button>
            <PrimaryButton onClick={() => setEditing('new')}>新建知识库</PrimaryButton>
          </div>
        )}
      />

      {err && <div className="mb-4"><InlineAlert tone="danger">{err}</InlineAlert></div>}

      <div className="mb-4 grid grid-cols-1 gap-3 md:grid-cols-4">
        <Metric icon={<Database size={16} />} label="知识库" value={total} />
        <Metric icon={<ShieldCheck size={16} />} label="本页可用" value={summary.active} />
        <Metric icon={<FileText size={16} />} label="本页文档" value={summary.documents} />
        <Metric icon={<RefreshCw size={16} />} label="本页异常" value={summary.failed} tone={summary.failed > 0 ? 'danger' : 'muted'} />
      </div>

      <Toolbar
        search={<SearchInput value={query} onChange={(value) => { setQuery(value); setPage(1) }} placeholder="搜索知识库名称" />}
        filters={(
          <div className="w-[150px]">
            <Select value={status} onChange={(e) => { setStatus(e.target.value as StatusFilter); setPage(1) }}>
              <option value="all">全部状态</option>
              <option value="active">可用</option>
              <option value="pending">配置中</option>
              <option value="failed">异常</option>
            </Select>
          </div>
        )}
      />

      <DataTable
        headers={['名称', '范围', '服务', '文档数', '状态', '创建时间', '操作']}
        loading={loading ? <EmptyState title="正在加载知识库" description="正在读取知识库列表。" /> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<BookOpen size={22} />}
            title={query || status !== 'all' ? '没有匹配的知识库' : '暂无知识库'}
            description={query || status !== 'all' ? '调整搜索词或状态筛选后再试。' : '点击“新建知识库”创建第一个知识库。'}
          />
        ) : undefined}
      >
        {!loading && items.map((kb) => (
          <tr key={kb.uuid} className="transition hover:bg-[var(--color-bg-sub)]">
            <td className="px-4 py-3">
              <div className="min-w-0">
                <div className="truncate font-medium text-[var(--color-text)]">{kb.name}</div>
                <div className="truncate text-[11px] text-[var(--color-text-mute)]">{kb.description || '暂无描述'}</div>
              </div>
            </td>
            <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{platform ? '平台内置' : '租户共享'}</td>
            <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{kb.provider_kind || '-'}</td>
            <td className="px-4 py-3 text-[12px] tabular-nums text-[var(--color-text-sub)]">{kb.total_documents ?? 0}</td>
            <td className="px-4 py-3">
              <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] font-medium ${kbStatusClass(kb)}`}>{kbStatusLabel(kb)}</span>
            </td>
            <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{formatDate(kb.created_at)}</td>
            <td className="px-4 py-3">
              <RowActions
                extras={(
                  <Link
                    to={`${platform ? '/platform-kb' : '/kb'}/${encodeURIComponent(kb.uuid)}`}
                    title="查看知识库详情"
                    className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                  >
                    详情
                  </Link>
                )}
                onEdit={() => setEditing(kb)}
                onDelete={() => { void requestDelete(kb) }}
              />
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination total={total} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={(size) => { setPageSize(size); setPage(1) }} />

      {editing && <KnowledgeBaseDrawer scope={scope} item={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load() }} />}
      {deleting && (
        <ConfirmDialog
          title="删除知识库"
          description={deleting.refs > 0
            ? `「${deleting.kb.name}」仍被 ${deleting.refs} 个数字员工引用，请先解除绑定。`
            : `确认删除「${deleting.kb.name}」及其中所有目录和文件？此操作不可撤销。`}
          confirmLabel="删除"
          confirmDisabled={deleting.refs > 0}
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await ManagedKB.remove(scope, deleting.kb.uuid)
            notifyOk('知识库已删除')
            setDeleting(null)
            if (items.length === 1 && page > 1) setPage(page - 1)
            else load()
          }}
        />
      )}
    </div>
  )
}

function KnowledgeBaseDrawer({ scope, item, onClose, onSaved }: { scope: ManagedKBScope; item: TenantKBItem | null; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(item?.name || '')
  const [description, setDescription] = useState(item?.description || '')
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')
  const save = async () => {
    if (name.trim().length < 2) { setErr('知识库名称至少 2 个字符'); return }
    setSaving(true); setErr('')
    try {
      if (item) await ManagedKB.patch(scope, item.uuid, { name: name.trim(), description: description.trim() })
      else await ManagedKB.create(scope, { name: name.trim() })
      notifyOk(item ? '知识库信息已保存' : '知识库已创建')
      onSaved()
    } catch (e) { setErr((e as Error).message) } finally { setSaving(false) }
  }
  return (
    <DialogShell
      title={item ? '编辑知识库' : '新建知识库'}
      subtitle={scope === 'platform' ? '平台知识库仅供数字员工绑定和召回，不对租户用户直接展示。' : '租户知识库对本租户管理员和获授权数字员工可用。'}
      onClose={onClose}
      size="sm"
      footer={<div className="flex justify-end gap-2"><Button variant="secondary" onClick={onClose}>取消</Button><Button onClick={save} disabled={saving}>{saving ? '保存中...' : '保存'}</Button></div>}
    >
      <div className="space-y-4">
        {err && <InlineAlert tone="danger">{err}</InlineAlert>}
        <FormField label="知识库名称"><Input value={name} maxLength={128} onChange={(e) => setName(e.target.value)} placeholder="例如：产品使用手册" /></FormField>
        {item && (
          <FormField label="描述" hint="帮助管理员在装配数字员工时判断用途。">
            <textarea className="min-h-28 w-full rounded-md border border-[var(--color-line)] px-3 py-2 text-sm outline-none focus:border-[var(--color-brand)]" value={description} maxLength={500} onChange={(e) => setDescription(e.target.value)} placeholder="简要说明知识范围和适用场景" />
          </FormField>
        )}
      </div>
    </DialogShell>
  )
}

function Metric({ icon, label, value, tone = 'normal' }: { icon: ReactNode; label: string; value: number; tone?: 'normal' | 'danger' | 'muted' }) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-3">
      <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-mute)]">{icon}{label}</div>
      <div className={`mt-2 text-[22px] font-semibold tabular-nums ${tone === 'danger' ? 'text-[var(--color-danger)]' : tone === 'muted' ? 'text-[var(--color-text-sub)]' : 'text-[var(--color-text)]'}`}>{value}</div>
    </div>
  )
}
