import { useEffect, useState } from 'react'
import { useOutletContext } from 'react-router-dom'
import { Tag } from 'lucide-react'

import { AppCategories, PlatformAppCategories, type AppCategory } from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import { Button, ConfirmDialog, DataTable, DialogShell, EmptyState, FormField, InlineAlert, Input, PageHeader, Pagination, PrimaryButton, RowActions } from '../components/ui'

export function AppCategoriesPage() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isTenantScope = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const isPlatformScope = actScope?.kind === 'platform'
  const api = isPlatformScope ? PlatformAppCategories : AppCategories
  const [items, setItems] = useState<AppCategory[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [editing, setEditing] = useState<AppCategory | null>(null)
  const [deleting, setDeleting] = useState<AppCategory | null>(null)
  const [creating, setCreating] = useState(false)
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)

  useEffect(() => {
    let cancelled = false
    void Promise.resolve().then(() => {
      if (cancelled) return
      if (!isTenantScope && !isPlatformScope) {
        setLoading(false)
        return
      }
      setLoading(true)
      return api.list({ limit: pageSize, offset: (page - 1) * pageSize })
        .then((r) => {
          if (cancelled) return
          setItems(r.items || [])
          setTotal(r.total || 0)
          setErr('')
        })
        .catch((e: Error) => { if (!cancelled) setErr(e.message) })
        .finally(() => { if (!cancelled) setLoading(false) })
      })
    return () => { cancelled = true }
  }, [tick, isTenantScope, isPlatformScope, api, page, pageSize])

  const refresh = () => setTick((t) => t + 1)

  if (switchingScope || !actScope) return null
  if (!isTenantScope && !isPlatformScope) {
    return (
      <div>
        <PageHeader title="应用分类" subtitle="请切换到平台或租户视图后再管理应用分类。" />
        <InlineAlert>请先在左上角切换到平台或租户视图后再管理应用分类。</InlineAlert>
      </div>
    )
  }

  return (
    <div>
      <PageHeader
        title="应用分类"
        subtitle={isPlatformScope
          ? '维护平台预置应用分类；租户可引用但不可修改或删除。'
          : '管理本租户自建应用分类；平台预置分类仅可使用，不可修改或删除。'}
        actions={<PrimaryButton onClick={() => setCreating(true)}>新建分类</PrimaryButton>}
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <DataTable
        headers={['名称', '编码', '排序', '来源', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</div> : undefined}
        empty={!loading && items.length === 0 ? <EmptyState icon={<Tag size={22} />} title="还没有分类" /> : undefined}
      >
        {!loading && items.map((c) => (
          <tr key={c.uuid} className="hover:bg-[var(--color-bg-sub)]">
            <td className="px-4 py-3 font-medium">{c.name}</td>
            <td className="px-4 py-3 font-mono text-[12px] text-[var(--color-text-sub)]">{c.code}</td>
            <td className="px-4 py-3">{c.sortOrder}</td>
            <td className="px-4 py-3 text-[var(--color-text-sub)]">{c.isSystem ? '平台预置' : '租户自建'}</td>
            <td className="px-4 py-3">
              {(!c.isSystem || isPlatformScope) && (
                <RowActions onEdit={() => setEditing(c)} onDelete={() => setDeleting(c)} />
              )}
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

      {creating && <CategoryDialog mode="create" api={api} isPlatform={isPlatformScope} onClose={() => setCreating(false)} onSaved={() => { setCreating(false); refresh() }} />}
      {editing && <CategoryDialog mode="edit" api={api} isPlatform={isPlatformScope} category={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); refresh() }} />}
      {deleting && (
        <ConfirmDialog
          title="删除应用分类"
          description={`确认删除分类「${deleting.name}」？已使用该分类的应用会保留分类 ID，建议先调整应用分类。`}
          confirmLabel="删除"
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await api.delete(deleting.uuid)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

type CategoryApi = typeof AppCategories

function CategoryDialog(props: { mode: 'create' | 'edit'; api: CategoryApi; isPlatform: boolean; category?: AppCategory; onClose: () => void; onSaved: () => void }) {
  const [code, setCode] = useState(props.category?.code || '')
  const [name, setName] = useState(props.category?.name || '')
  const [sortOrder, setSortOrder] = useState(String(props.category?.sortOrder || 0))
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  const submit = async () => {
    if (!code.trim() || !name.trim()) {
      setErr('请填写编码和名称')
      return
    }
    setSubmitting(true)
    setErr('')
    try {
      if (props.mode === 'create') {
        await props.api.create({ code: code.trim(), name: name.trim(), sortOrder: Number(sortOrder) || 0 })
      } else if (props.category) {
        await props.api.patch(props.category.uuid, { code: code.trim(), name: name.trim(), sortOrder: Number(sortOrder) || 0 })
      }
      props.onSaved()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <DialogShell
      title={props.mode === 'create' ? '新建分类' : '编辑分类'}
      subtitle={props.isPlatform ? '平台预置分类对所有租户可见。' : '分类仅在当前租户内生效。'}
      icon={<Tag size={18} />}
      onClose={props.onClose}
      size="sm"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={props.onClose} disabled={submitting}>取消</Button>
          <Button onClick={submit} disabled={submitting}>{submitting ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="编码" hint="租户内唯一，建议使用英文小写、数字和下划线。">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="finance" />
        </FormField>
        <FormField label="名称">
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="财务" />
        </FormField>
        <FormField label="排序">
          <Input type="number" value={sortOrder} onChange={(e) => setSortOrder(e.target.value)} />
        </FormField>
      </div>
    </DialogShell>
  )
}
