// SkillDictionaries — 技能中心字典管理。
//
// 每个左侧菜单对应一个独立页面内容；不再在右侧页面内提供 tab 切换。
// 业务线已按 ADR 0014 砍掉，不再呈现。

import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { FolderTree, KeyRound, RefreshCw, Tags } from 'lucide-react'
import {
  PlatformSkills,
  type SkillBuiltinKey, type SkillCategory, type SkillLabel,
} from '../lib/api'
import {
  Button, ConfirmDialog, DataTable, DialogShell, EmptyState, FormField, InlineAlert, Input, PageHeader, Pagination, PrimaryButton, RowActions, SearchInput, Select, Toolbar,
} from '../components/ui'

type DictPage = 'categories' | 'labels' | 'builtin-keys'

const PAGE_META: Record<DictPage, {
  title: string
  subtitle: string
  icon: ReactNode
}> = {
  categories: {
    title: '技能分类',
    subtitle: '管理 SkillHub 分类，用于技能归类、筛选与运营展示。',
    icon: <FolderTree size={22} />,
  },
  labels: {
    title: '技能标签',
    subtitle: '管理技能标签，用于客户端 chip rail 与广场筛选。',
    icon: <Tags size={22} />,
  },
  'builtin-keys': {
    title: '客户端能力注册表',
    subtitle: '注册知办AI 客户端 app 提供的原生能力，决定 builtin 类技能可用的 native capability 与每个平台最低 app 版本。',
    icon: <KeyRound size={22} />,
  },
}

export function SkillDictionariesPage({ initialTab }: { initialTab?: DictPage } = {}) {
  const page: DictPage = initialTab || 'categories'
  const meta = PAGE_META[page]
  const [err, setErr] = useState('')

  return (
    <div>
      <PageHeader title={meta.title} subtitle={meta.subtitle} />

      {err && <div className="mb-4"><InlineAlert>{err}</InlineAlert></div>}

      {page === 'categories' && <CategoriesPane onError={setErr} />}
      {page === 'labels' && <LabelsPane onError={setErr} />}
      {page === 'builtin-keys' && <BuiltinKeysPane onError={setErr} />}
    </div>
  )
}

function StatusBadge({ status }: { status?: string }) {
  const value = status || '-'
  const label: Record<string, string> = {
    active: '启用',
    archived: '禁用',
    deprecated: '禁用',
  }
  const cls = value === 'active'
    ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
    : value === 'deprecated' || value === 'archived'
      ? 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
      : 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'
  return (
    <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] font-medium ${cls}`}>
      {label[value] || value}
    </span>
  )
}

function fmtDateTime(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

function LoadingState({ title }: { title: string }) {
  return <EmptyState title={title} description="正在读取后台配置。" />
}

function ErrorState({ title, onRetry }: { title: string; onRetry: () => void }) {
  return (
    <EmptyState
      title={title}
      description="请稍后重试，或检查当前账号是否具备平台技能管理权限。"
      action={<Button variant="secondary" onClick={onRetry}><RefreshCw size={14} /> 重试</Button>}
    />
  )
}

function HeaderCell({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <span className={`block whitespace-nowrap ${className}`}>{children}</span>
}

const compactTableClass = 'table-sticky-actions'
const wideTableClass = 'dict-table-scroll table-sticky-actions overflow-x-auto'
const nameCellClass = 'w-[160px] min-w-[160px] max-w-[180px] whitespace-nowrap px-4 py-2 font-medium text-[var(--color-text)]'
const codeCellClass = 'min-w-[150px] whitespace-nowrap px-4 py-2 font-mono text-[12px] text-[var(--color-text-sub)]'
const descCellClass = 'min-w-[180px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]'
const numberCellClass = 'min-w-[72px] whitespace-nowrap px-4 py-2 text-[12px] tabular-nums text-[var(--color-text-sub)]'
const timeCellClass = 'min-w-[140px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]'
const statusCellClass = 'min-w-[80px] whitespace-nowrap px-4 py-2'
const actionCellClass = 'min-w-[128px] whitespace-nowrap px-4 py-2'

// ---------------------------------------------------------------------------
// 分类
// ---------------------------------------------------------------------------

function CategoriesPane({ onError }: { onError: (msg: string) => void }) {
  const [items, setItems] = useState<SkillCategory[]>([])
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('all')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [editing, setEditing] = useState<SkillCategory | null>(null)
  const [deleting, setDeleting] = useState<SkillCategory | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setFailed(false)
    onError('')
    try {
      const r = await PlatformSkills.listCategories({
        q: query || undefined,
        status: status === 'all' ? undefined : status,
        limit: pageSize,
        offset: (page - 1) * pageSize,
      })
      setItems(r.items || [])
      setTotal(r.total || 0)
    } catch (e) {
      setFailed(true)
      onError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [onError, page, pageSize, query, status])

  useEffect(() => {
    let cancelled = false
    PlatformSkills.listCategories({
      q: query || undefined,
      status: status === 'all' ? undefined : status,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
      })
      .catch((e: Error) => {
        if (!cancelled) {
          setFailed(true)
          onError(e.message)
        }
      })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [reload, onError, page, pageSize, query, status])

  return (
    <>
      <Toolbar
        search={
          <SearchInput
            value={query}
            onChange={(v) => { setQuery(v); setPage(1) }}
            placeholder="搜索名称、Code 或描述"
          />
        }
        filters={
          <div className="w-[140px]">
            <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
              <option value="all">全部状态</option>
              <option value="active">启用</option>
              <option value="archived">禁用</option>
            </Select>
          </div>
        }
        actions={<PrimaryButton onClick={() => setCreating(true)}>新建分类</PrimaryButton>}
      />

      <DataTable
        className={compactTableClass}
        headers={[
          <HeaderCell className="w-[160px] min-w-[160px] max-w-[180px]">名称</HeaderCell>,
          <HeaderCell className="min-w-[150px]">标识 Code</HeaderCell>,
          <HeaderCell className="min-w-[180px]">描述</HeaderCell>,
          <HeaderCell className="min-w-[72px]">排序</HeaderCell>,
          <HeaderCell className="min-w-[140px]">创建时间</HeaderCell>,
          <HeaderCell className="min-w-[80px]">状态</HeaderCell>,
          <HeaderCell className="min-w-[128px]">操作</HeaderCell>,
        ]}
        loading={loading ? <LoadingState title="正在加载技能分类" /> : undefined}
        empty={!loading && !failed && items.length === 0 ? (
          <EmptyState
            icon={<FolderTree size={22} />}
            title={total === 0 ? '暂无技能分类' : '没有匹配的技能分类'}
            description={total === 0 ? '创建分类后，可在技能管理中为技能选择归属。' : '调整搜索词、类型或状态筛选后再试。'}
          />
        ) : failed ? <ErrorState title="技能分类加载失败" onRetry={load} /> : undefined}
      >
        {!loading && !failed && items.map((item) => (
          <tr key={item.id} className="transition hover:bg-[var(--color-bg-sub)]">
            <td className={nameCellClass} title={item.name || '-'}>
              <span className="block truncate">{item.name || '-'}</span>
            </td>
            <td className={codeCellClass}>{item.code}</td>
            <td className={descCellClass}>{item.description || '-'}</td>
            <td className={numberCellClass}>{item.sort_order ?? 0}</td>
            <td className={timeCellClass}>{fmtDateTime(item.created_at)}</td>
            <td className={statusCellClass}><StatusBadge status={item.status} /></td>
            <td className={actionCellClass}>
              <RowActions
                onEdit={() => setEditing(item)}
                onDelete={() => setDeleting(item)}
              />
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => { setLoading(true); setPage(next) }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {(creating || editing) && (
        <CategoryDialog
          row={editing || undefined}
          onClose={() => { setCreating(false); setEditing(null) }}
          onError={onError}
          onDone={() => {
            setCreating(false)
            setEditing(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title="删除技能分类"
          description={`确认删除「${deleting.name || deleting.code}」？删除后会从列表移除，不影响启用/禁用状态字段。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await PlatformSkills.deleteCategory(deleting.id)
            setDeleting(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
    </>
  )
}

function CategoryDialog({
  row, onClose, onDone, onError,
}: { row?: SkillCategory; onClose: () => void; onDone: () => void; onError: (m: string) => void }) {
  const isEdit = !!row
  const [code, setCode] = useState(row?.code || '')
  const [name, setName] = useState(row?.name || '')
  const [desc, setDesc] = useState(row?.description || '')
  const [sort, setSort] = useState<number>(row?.sort_order ?? 0)
  const [status, setStatus] = useState(row?.status || 'active')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true)
    try {
      if (isEdit) {
        await PlatformSkills.patchCategory(row!.id, { code, name, description: desc, sort_order: sort, status })
      } else {
        await PlatformSkills.createCategory({ code, name, description: desc, sort_order: sort })
      }
      onDone()
    } catch (e) {
      onError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DialogShell title={isEdit ? '编辑分类' : '新建分类'} onClose={onClose} footer={
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>取消</Button>
        <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
      </div>
    }>
      <div className="space-y-3">
        <FormField label="名称">
          <Input value={name} onChange={(e) => setName(e.target.value)} />
        </FormField>
        <FormField label="标识 Code" hint="全局唯一，lower_snake_case；改名会影响 API、seed 与历史引用。">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="lower_snake_case" />
        </FormField>
        <FormField label="描述">
          <Input value={desc} onChange={(e) => setDesc(e.target.value)} />
        </FormField>
        <FormField label="排序">
          <Input type="number" value={sort} onChange={(e) => setSort(Number(e.target.value) || 0)} />
        </FormField>
        {isEdit && (
          <FormField label="状态">
            <Select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="active">启用</option>
              <option value="archived">禁用</option>
            </Select>
          </FormField>
        )}
      </div>
    </DialogShell>
  )
}

// ---------------------------------------------------------------------------
// 技能标签
// ---------------------------------------------------------------------------

function LabelsPane({ onError }: { onError: (msg: string) => void }) {
  return (
    <FlatDictPane<SkillLabel>
      icon={<Tags size={22} />}
      onError={onError}
      loadTitle="正在加载技能标签"
      emptyTitle="暂无技能标签"
      emptyDescription="创建标签后，可在技能管理中为技能补充能力维度。"
      createLabel="新建标签"
      editTitle="编辑标签"
      createTitle="新建标签"
      list={(params) => PlatformSkills.listLabels(params)}
      remove={(row) => PlatformSkills.deleteLabel(row.id)}
      save={(row, body) => row
        ? PlatformSkills.patchLabel(row.id, body)
        : PlatformSkills.createLabel({
          code: body.code || '',
          name: body.name || '',
          description: body.description,
          sort_order: body.sort_order,
        })}
    />
  )
}

type FlatDict = {
  id: number
  code: string
  name: string
  description?: string
  sort_order: number
  status: string
  created_at?: string
  updated_at?: string
}

function FlatDictPane<T extends FlatDict>({
  icon,
  onError,
  loadTitle,
  emptyTitle,
  emptyDescription,
  createLabel,
  createTitle,
  editTitle,
  list,
  remove,
  save,
}: {
  icon: ReactNode
  onError: (msg: string) => void
  loadTitle: string
  emptyTitle: string
  emptyDescription: string
  createLabel: string
  createTitle: string
  editTitle: string
  list: (params: { q?: string; status?: string; limit?: number; offset?: number }) => Promise<{ items: T[]; total: number }>
  remove: (row: T) => Promise<unknown>
  save: (row: T | null, body: Partial<{ code: string; name: string; description: string; sort_order: number; status: string }>) => Promise<unknown>
}) {
  const [items, setItems] = useState<T[]>([])
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('all')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [editing, setEditing] = useState<T | null>(null)
  const [deleting, setDeleting] = useState<T | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setFailed(false)
    onError('')
    try {
      const r = await list({
        q: query || undefined,
        status: status === 'all' ? undefined : status,
        limit: pageSize,
        offset: (page - 1) * pageSize,
      })
      setItems(r.items || [])
      setTotal(r.total || 0)
    } catch (e) {
      setFailed(true)
      onError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [list, onError, page, pageSize, query, status])

  useEffect(() => {
    let cancelled = false
    list({
      q: query || undefined,
      status: status === 'all' ? undefined : status,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
      })
      .catch((e: Error) => {
        if (!cancelled) {
          setFailed(true)
          onError(e.message)
        }
      })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [list, reload, onError, page, pageSize, query, status])

  return (
    <>
      <Toolbar
        search={
          <SearchInput
            value={query}
            onChange={(v) => { setQuery(v); setPage(1) }}
            placeholder="搜索名称、Code 或描述"
          />
        }
        filters={
          <div className="w-[140px]">
            <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
              <option value="all">全部状态</option>
              <option value="active">启用</option>
              <option value="archived">禁用</option>
            </Select>
          </div>
        }
        actions={<PrimaryButton onClick={() => setCreating(true)}>{createLabel}</PrimaryButton>}
      />

      <DataTable
        className={compactTableClass}
        headers={[
          <HeaderCell className="w-[160px] min-w-[160px] max-w-[180px]">名称</HeaderCell>,
          <HeaderCell className="min-w-[150px]">标识 Code</HeaderCell>,
          <HeaderCell className="min-w-[180px]">描述</HeaderCell>,
          <HeaderCell className="min-w-[72px]">排序</HeaderCell>,
          <HeaderCell className="min-w-[140px]">创建时间</HeaderCell>,
          <HeaderCell className="min-w-[80px]">状态</HeaderCell>,
          <HeaderCell className="min-w-[128px]">操作</HeaderCell>,
        ]}
        loading={loading ? <LoadingState title={loadTitle} /> : undefined}
        empty={!loading && !failed && items.length === 0 ? (
          <EmptyState
            icon={icon}
            title={total === 0 ? emptyTitle : '没有匹配的数据'}
            description={total === 0 ? emptyDescription : '调整搜索词或状态筛选后再试。'}
          />
        ) : failed ? <ErrorState title={`${emptyTitle.replace('暂无', '')}加载失败`} onRetry={load} /> : undefined}
      >
        {!loading && !failed && items.map((item) => (
          <tr key={item.id} className="transition hover:bg-[var(--color-bg-sub)]">
            <td className={nameCellClass} title={item.name || '-'}>
              <span className="block truncate">{item.name || '-'}</span>
            </td>
            <td className={codeCellClass}>{item.code}</td>
            <td className={descCellClass}>{item.description || '-'}</td>
            <td className={numberCellClass}>{item.sort_order ?? 0}</td>
            <td className={timeCellClass}>{fmtDateTime(item.created_at)}</td>
            <td className={statusCellClass}><StatusBadge status={item.status} /></td>
            <td className={actionCellClass}>
              <RowActions
                onEdit={() => setEditing(item)}
                onDelete={() => setDeleting(item)}
              />
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => { setLoading(true); setPage(next) }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {(creating || editing) && (
        <FlatDictDialog
          row={editing || undefined}
          title={editing ? editTitle : createTitle}
          onClose={() => { setCreating(false); setEditing(null) }}
          onError={onError}
          onSave={async (body) => { await save(editing, body) }}
          onDone={() => {
            setCreating(false)
            setEditing(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title="删除技能标签"
          description={`确认删除「${deleting.name || deleting.code}」？删除后会从列表移除，不影响启用/禁用状态字段。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await remove(deleting)
            setDeleting(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
    </>
  )
}

function FlatDictDialog({
  row, title, onClose, onSave, onDone, onError,
}: {
  row?: FlatDict
  title: string
  onClose: () => void
  onDone: () => void
  onError: (m: string) => void
  onSave: (body: { code: string; name: string; description: string; sort_order: number; status?: string }) => Promise<void>
}) {
  const [code, setCode] = useState(row?.code || '')
  const [name, setName] = useState(row?.name || '')
  const [desc, setDesc] = useState(row?.description || '')
  const [sort, setSort] = useState<number>(row?.sort_order ?? 0)
  const [status, setStatus] = useState(row?.status || 'active')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true)
    try {
      const body = row
        ? { code, name, description: desc, sort_order: sort, status }
        : { code, name, description: desc, sort_order: sort }
      await onSave(body)
      onDone()
    } catch (e) {
      onError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DialogShell title={title} onClose={onClose} footer={
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>取消</Button>
        <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
      </div>
    }>
      <div className="space-y-3">
        <FormField label="名称">
          <Input value={name} onChange={(e) => setName(e.target.value)} />
        </FormField>
        <FormField label="标识 Code" hint="全局唯一，lower_snake_case；改名会影响 API、seed 与历史引用。">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="lower_snake_case" />
        </FormField>
        <FormField label="描述">
          <Input value={desc} onChange={(e) => setDesc(e.target.value)} />
        </FormField>
        <FormField label="排序">
          <Input type="number" value={sort} onChange={(e) => setSort(Number(e.target.value) || 0)} />
        </FormField>
        {row && (
          <FormField label="状态">
            <Select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="active">启用</option>
              <option value="archived">禁用</option>
            </Select>
          </FormField>
        )}
      </div>
    </DialogShell>
  )
}

// ---------------------------------------------------------------------------
// 客户端能力注册表
// ---------------------------------------------------------------------------

function BuiltinKeysPane({ onError }: { onError: (msg: string) => void }) {
  const [items, setItems] = useState<SkillBuiltinKey[]>([])
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('all')
  const [mode, setMode] = useState('all')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [editing, setEditing] = useState<SkillBuiltinKey | null>(null)
  const [deleting, setDeleting] = useState<SkillBuiltinKey | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setFailed(false)
    onError('')
    try {
      const r = await PlatformSkills.listBuiltinKeys({
        q: query || undefined,
        status: status === 'all' ? undefined : status,
        execution_mode: mode === 'all' ? undefined : mode,
        limit: pageSize,
        offset: (page - 1) * pageSize,
      })
      setItems(r.items || [])
      setTotal(r.total || 0)
    } catch (e) {
      setFailed(true)
      onError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [mode, onError, page, pageSize, query, status])

  useEffect(() => {
    let cancelled = false
    PlatformSkills.listBuiltinKeys({
      q: query || undefined,
      status: status === 'all' ? undefined : status,
      execution_mode: mode === 'all' ? undefined : mode,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
      })
      .catch((e: Error) => {
        if (!cancelled) {
          setFailed(true)
          onError(e.message)
        }
      })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [reload, mode, onError, page, pageSize, query, status])

  return (
    <>
      <Toolbar
        search={
          <SearchInput
            value={query}
            onChange={(v) => { setQuery(v); setPage(1) }}
            placeholder="搜索名称、Code 或描述"
          />
        }
        filters={
          <>
            <div className="w-[190px]">
              <Select value={mode} onChange={(e) => { setMode(e.target.value); setPage(1) }}>
                <option value="all">全部执行模式</option>
                <option value="synchronous_inline">同步内联</option>
                <option value="asynchronous_floating">异步浮层</option>
              </Select>
            </div>
            <div className="w-[150px]">
              <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
                <option value="all">全部状态</option>
                <option value="active">启用</option>
                <option value="deprecated">禁用</option>
              </Select>
            </div>
          </>
        }
        actions={<PrimaryButton onClick={() => setCreating(true)}>注册能力</PrimaryButton>}
      />

      <DataTable
        className={wideTableClass}
        headers={[
          <HeaderCell className="w-[160px] min-w-[160px] max-w-[180px]">名称</HeaderCell>,
          <HeaderCell className="min-w-[150px]">标识 Code</HeaderCell>,
          <HeaderCell className="min-w-[220px]">描述</HeaderCell>,
          <HeaderCell className="min-w-[120px]">支持平台</HeaderCell>,
          <HeaderCell className="min-w-[130px]">执行模式</HeaderCell>,
          <HeaderCell className="min-w-[180px]">最低版本</HeaderCell>,
          <HeaderCell className="min-w-[140px]">创建时间</HeaderCell>,
          <HeaderCell className="min-w-[80px]">状态</HeaderCell>,
          <HeaderCell className="min-w-[128px]">操作</HeaderCell>,
        ]}
        loading={loading ? <LoadingState title="正在加载客户端能力" /> : undefined}
        empty={!loading && !failed && items.length === 0 ? (
          <EmptyState
            icon={<KeyRound size={22} />}
            title={total === 0 ? '暂无客户端能力' : '没有匹配的客户端能力'}
            description={total === 0 ? '注册能力后，builtin 技能才能选择对应的客户端原生能力。' : '调整搜索词、执行模式或状态筛选后再试。'}
          />
        ) : failed ? <ErrorState title="客户端能力加载失败" onRetry={load} /> : undefined}
      >
        {!loading && !failed && items.map((item) => (
          <tr key={item.id} className="transition hover:bg-[var(--color-bg-sub)]">
            <td className={nameCellClass} title={item.name || '-'}>
              <span className="block truncate">{item.name || '-'}</span>
            </td>
            <td className={codeCellClass}>{item.code}</td>
            <td className="min-w-[220px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]">{item.description || '-'}</td>
            <td className="min-w-[120px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]">{(item.supported_platforms || []).join(', ') || '-'}</td>
            <td className="min-w-[130px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]">{item.default_execution_mode || '-'}</td>
            <td className="min-w-[180px] whitespace-nowrap px-4 py-2 font-mono text-[11px] text-[var(--color-text-sub)]">{formatMinVersions(item.min_client_versions)}</td>
            <td className={timeCellClass}>{fmtDateTime(item.registered_at)}</td>
            <td className={statusCellClass}><StatusBadge status={item.status} /></td>
            <td className={actionCellClass}>
              <RowActions
                onEdit={() => setEditing(item)}
                onDelete={() => setDeleting(item)}
              />
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => { setLoading(true); setPage(next) }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {(creating || editing) && (
        <BuiltinKeyDialog
          row={editing || undefined}
          onClose={() => { setCreating(false); setEditing(null) }}
          onError={onError}
          onDone={() => {
            setCreating(false)
            setEditing(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title="删除客户端能力"
          description={`确认删除「${deleting.name || deleting.code}」？删除后会从列表移除，不影响启用/禁用状态字段。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await PlatformSkills.deleteBuiltinKey(deleting.id)
            setDeleting(null)
            setLoading(true)
            setFailed(false)
            onError('')
            setReload((t) => t + 1)
          }}
        />
      )}
    </>
  )
}

function formatMinVersions(value: unknown) {
  if (!value) return '-'
  if (typeof value === 'string') return value || '-'
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length === 0) return '-'
    return entries.map(([platform, version]) => `${platform}:${String(version)}`).join(' / ')
  }
  return String(value)
}

function BuiltinKeyDialog({
  row, onClose, onDone, onError,
}: { row?: SkillBuiltinKey; onClose: () => void; onDone: () => void; onError: (m: string) => void }) {
  const isEdit = !!row
  const [code, setCode] = useState(row?.code || '')
  const [name, setName] = useState(row?.name || '')
  const [desc, setDesc] = useState(row?.description || '')
  const [platforms, setPlatforms] = useState(((row?.supported_platforms) || []).join(','))
  const [mode, setMode] = useState(row?.default_execution_mode || 'asynchronous_floating')
  const [caps, setCaps] = useState(((row?.default_native_capabilities) || []).join(','))
  const [status, setStatus] = useState((row?.status as 'active' | 'deprecated') || 'active')
  const [minVer, setMinVer] = useState(JSON.stringify(row?.min_client_versions || {}, null, 2))
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true)
    try {
      let parsedMinVer: unknown = undefined
      if (minVer.trim()) {
        try {
          parsedMinVer = JSON.parse(minVer)
        } catch {
          onError('min_client_versions JSON 解析失败')
          setBusy(false)
          return
        }
      }
      const sps = platforms.split(',').map((s) => s.trim()).filter(Boolean)
      const cps = caps.split(',').map((s) => s.trim()).filter(Boolean)
      if (isEdit) {
        await PlatformSkills.patchBuiltinKey(row!.id, {
          name, description: desc, supported_platforms: sps, min_client_versions: parsedMinVer,
          default_execution_mode: mode, default_native_capabilities: cps, status,
        })
      } else {
        await PlatformSkills.createBuiltinKey({
          code, name, description: desc, supported_platforms: sps,
          min_client_versions: parsedMinVer, default_execution_mode: mode,
          default_native_capabilities: cps, status,
        })
      }
      onDone()
    } catch (e) {
      onError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DialogShell title={isEdit ? '编辑客户端能力' : '注册客户端能力'} onClose={onClose} footer={
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>取消</Button>
        <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
      </div>
    }>
      <div className="space-y-3">
        <FormField label="名称">
          <Input value={name} onChange={(e) => setName(e.target.value)} />
        </FormField>
        <FormField label="标识 Code" hint="例如 meeting_recorder；客户端能力 Code 是端侧协议 key，编辑时不可修改。">
          <Input value={code} onChange={(e) => setCode(e.target.value)} disabled={isEdit} />
        </FormField>
        <FormField label="描述">
          <Input value={desc} onChange={(e) => setDesc(e.target.value)} />
        </FormField>
        <FormField label="支持平台" hint="逗号分隔，如 ios,android,macos,windows,web">
          <Input value={platforms} onChange={(e) => setPlatforms(e.target.value)} />
        </FormField>
        <FormField label="执行模式">
          <Select value={mode} onChange={(e) => setMode(e.target.value)}>
            <option value="synchronous_inline">synchronous_inline</option>
            <option value="asynchronous_floating">asynchronous_floating</option>
          </Select>
        </FormField>
        <FormField label="默认 native capabilities" hint="逗号分隔，如 microphone,system_audio">
          <Input value={caps} onChange={(e) => setCaps(e.target.value)} />
        </FormField>
        <FormField label="最低客户端版本（JSON）" hint='例如 {"ios": "1.0.0", "android": "1.0.0"}'>
          <textarea
            className="min-h-[110px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 font-mono text-[12px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
            value={minVer}
            onChange={(e) => setMinVer(e.target.value)}
          />
        </FormField>
        <FormField label="状态">
          <Select value={status} onChange={(e) => setStatus(e.target.value as 'active' | 'deprecated')}>
            <option value="active">启用</option>
            <option value="deprecated">禁用</option>
          </Select>
        </FormField>
      </div>
    </DialogShell>
  )
}
