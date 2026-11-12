// F01 §1 租户级职位 CRUD 页. 列表 + 新建/编辑/删除 modal.
// 仿 DepartmentTree 风格但 flat list (职位不分层).
import { useEffect, useMemo, useState } from 'react'
import { Positions, type Position, type CreatePositionInput, type UpdatePositionInput } from '../lib/api'
import { X, BadgeCheck, Briefcase } from 'lucide-react'
import { ConfirmDialog, InlineAlert, PageHeader, Pagination, PrimaryButton, RowActions, SearchInput, Toolbar } from '../components/ui'

export function PositionList() {
  const [items, setItems] = useState<Position[]>([])
  const [total, setTotal] = useState(0)
  const [err, setErr] = useState('')
  const [q, setQ] = useState('')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Position | null>(null)
  const [deleting, setDeleting] = useState<Position | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    Positions.list(q, pageSize, (page - 1) * pageSize)
      .then((r) => { setItems(r.items || []); setTotal(r.total || 0); setErr('') })
      .catch((e: Error) => setErr(e.message))
  }, [q, page, pageSize, tick])

  const refresh = () => setTick((t) => t + 1)
  const totalMembers = useMemo(() => items.reduce((s, p) => s + (p.memberCount || 0), 0), [items])

  return (
    <div>
      <PageHeader title="职位" subtitle="管理成员和数字员工可挂载的职位标签。" />

      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => { setQ(v); setPage(1) }}
            placeholder="搜索名称 / 描述"
          />
        }
        summary={
          <>
            共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 个职位
            <span className="ml-2 text-[var(--color-text-mute)]">当前页已挂 {totalMembers} 人</span>
          </>
        }
        actions={<PrimaryButton onClick={() => setCreating(true)}>新建职位</PrimaryButton>}
      />

      {err && <div className="mb-4 p-3 rounded-md bg-red-50 text-red-700 text-[13px]">{err}</div>}

      <div className="bg-white rounded-lg card-shadow overflow-hidden">
        <table className="w-full text-[13px]">
          <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
            <tr>
              <th className="text-left px-4 py-3">名称</th>
              <th className="text-left px-4 py-3">类型</th>
              <th className="text-left px-4 py-3">挂载</th>
              <th className="text-left px-4 py-3">排序</th>
              <th className="text-left px-4 py-3">操作</th>
            </tr>
          </thead>
          <tbody>
            {items.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-12 text-center text-[var(--color-text-mute)]">
                  <Briefcase size={28} className="mx-auto mb-2 opacity-40" />
                  {q ? '没有匹配的职位' : '还没有职位, 点右上角新建第一个吧'}
                </td>
              </tr>
            )}
            {items.map((p) => (
              <tr key={p.id} className="border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60">
                <td className="px-4 py-3">
                  <div className="font-medium">{p.name}</div>
                  {p.description && <div className="text-[11px] text-[var(--color-text-mute)] mt-0.5">{p.description}</div>}
                </td>
                <td className="px-4 py-3">
                  {p.isSystem ? (
                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-blue-50 text-blue-700 text-[11px]">
                      <BadgeCheck size={11} /> 系统初始化
                    </span>
                  ) : (
                    <span className="text-[11px] text-[var(--color-text-mute)]">自定义</span>
                  )}
                </td>
                <td className="px-4 py-3 text-[var(--color-text-sub)]">
                  {p.memberCount} 人 · {p.agentCount} 数字员工
                </td>
                <td className="px-4 py-3 font-mono text-[12px]">{p.sortOrder}</td>
                <td className="px-4 py-3">
                  <RowActions onEdit={() => setEditing(p)} onDelete={() => setDeleting(p)} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {(creating || editing) && (
        <PositionFormModal
          title={creating ? '新建职位' : `编辑职位：${editing!.name}`}
          initial={editing}
          onClose={() => { setCreating(false); setEditing(null) }}
          onSubmit={async (body) => {
            if (creating) await Positions.create(body as CreatePositionInput)
            else await Positions.update(editing!.id, body)
            setCreating(false); setEditing(null); refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmDeleteModal
          name={deleting.name}
          isSystem={deleting.isSystem}
          memberCount={deleting.memberCount}
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await Positions.remove(deleting.id)
            setDeleting(null); refresh()
          }}
        />
      )}
    </div>
  )
}

function PositionFormModal({ title, initial, onClose, onSubmit }: {
  title: string
  initial?: Position | null
  onClose: () => void
  onSubmit: (body: CreatePositionInput | UpdatePositionInput) => Promise<void>
}) {
  const [name, setName] = useState(initial?.name || '')
  const [description, setDescription] = useState(initial?.description || '')
  const [sortOrder, setSortOrder] = useState(initial?.sortOrder || 0)
  const [externalCode, setExternalCode] = useState(
    (initial?.metadata?.external_code as string) || ''
  )
  const [showAdvanced, setShowAdvanced] = useState(!!externalCode)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm">
      <div className="bg-white rounded-lg shadow-2xl w-[480px] max-w-[92vw] p-6">
        <div className="flex items-start justify-between mb-4">
          <h2 className="text-[18px] font-semibold">{title}</h2>
          <button onClick={onClose} className="p-1 rounded hover:bg-[var(--color-line-soft)] text-[var(--color-text-mute)]">
            <X size={18} />
          </button>
        </div>

        {initial?.isSystem && (
          <div className="mb-4 p-3 rounded-md bg-blue-50 text-blue-700 text-[12px]">
            系统初始化的职位, 字段全可改 (含名称 / 描述 / 排序)。
          </div>
        )}

        <div className="space-y-3">
          <Field label="名称" hint="租户内唯一">
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px]"
              placeholder="高级工程师"
            />
          </Field>
          <Field label="描述 (可选)" hint="">
            <input
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px]"
              placeholder="P6+ 技术研发"
            />
          </Field>
          <Field label="排序" hint="小的在前">
            <input
              type="number"
              value={sortOrder}
              onChange={(e) => setSortOrder(Number(e.target.value) || 0)}
              className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px] font-mono"
            />
          </Field>

          <button
            type="button"
            onClick={() => setShowAdvanced((v) => !v)}
            className="text-[12px] text-[var(--color-text-sub)] hover:text-[var(--color-brand)] underline-offset-2 hover:underline"
          >
            {showAdvanced ? '收起' : '高级选项 (HR 系统对账)'}
          </button>
          {showAdvanced && (
            <Field label="外部对账码 (可选)" hint="跟 SAP / Workday / SuccessFactors 对接时填">
              <input
                value={externalCode}
                onChange={(e) => setExternalCode(e.target.value)}
                className="h-10 w-full rounded-md ring-border bg-white px-3 text-[14px] font-mono"
                placeholder="例 JC-SE-001"
              />
            </Field>
          )}
        </div>

        {err && <div className="mt-3 p-2 rounded bg-red-50 text-red-700 text-[12px]">{err}</div>}

        <div className="mt-5 flex items-center justify-end gap-2">
          <button onClick={onClose} className="h-9 px-3 rounded-md ring-border text-[13px] hover:bg-[var(--color-line-soft)]">
            取消
          </button>
          <button
            disabled={busy}
            onClick={async () => {
              if (!name.trim()) { setErr('名称必填'); return }
              setBusy(true); setErr('')
              const meta: Record<string, unknown> = { ...(initial?.metadata || {}) }
              if (externalCode.trim()) meta.external_code = externalCode.trim()
              else delete meta.external_code
              try { await onSubmit({ name, description, sortOrder, metadata: meta }) }
              catch (e) { setErr((e as Error).message); setBusy(false) }
            }}
            className="h-9 px-3 rounded-md bg-[var(--color-text)] text-white text-[13px] font-medium hover:bg-black disabled:opacity-50"
          >
            {busy ? '保存中…' : '保存'}
          </button>
        </div>
      </div>
    </div>
  )
}

function ConfirmDeleteModal({ name, isSystem, memberCount, onClose, onConfirm }: {
  name: string; isSystem: boolean; memberCount: number; onClose: () => void; onConfirm: () => Promise<void>
}) {
  return (
    <ConfirmDialog
      title="删除职位"
      description={<>确定删除「<span className="font-medium text-[var(--color-text)]">{name}</span>」吗？</>}
      confirmLabel="删除"
      busyLabel="删除中..."
      onClose={onClose}
      onConfirm={onConfirm}
    >
      {memberCount > 0 && (
        <InlineAlert tone="warn">
          当前有 {memberCount} 名员工挂着这个职位，删除后他们的职位标记会清空。
        </InlineAlert>
      )}
      {isSystem && (
        <InlineAlert tone="info">
          这是系统初始化的默认职位，删除后本租户内不再有「{name}」这一选项，其他租户不受影响。
        </InlineAlert>
      )}
    </ConfirmDialog>
  )
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-1">
        <label className="text-[12px] font-medium text-[var(--color-text-sub)]">{label}</label>
        {hint && <span className="text-[11px] text-[var(--color-text-mute)]">{hint}</span>}
      </div>
      {children}
    </div>
  )
}
