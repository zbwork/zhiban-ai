import { useEffect, useState } from 'react'
import { Bot, Search } from 'lucide-react'
import { Button, DialogShell, InlineAlert, Input } from '../ui'
import { TenantAgentTemplates, type TenantAgentTemplate } from '../../lib/api'

// doc-15 P6：租户「从模板创建」选择弹窗。**数据源 = 后端平台已发布模板**（GET /tenant/agent-templates），
// 支持后端**搜索 / 分页(加载更多)**，不再用本地示例假数据、也不只默认拉第一页。
// Phase 2 (2026-06-08)：普通主路径不展示高级编排模板，固定请求 kind='single'；类型筛选 UI 下线，
// 等高级治理入口上线后再恢复（届时改为只在高级入口可见高级编排模板）。

const PAGE_SIZE = 12

export function TenantAgentTemplatePicker({
  onClose,
  onPick,
}: {
  onClose: () => void
  onPick: (t: TenantAgentTemplate) => void
}) {
  const [qInput, setQInput] = useState('')
  const [q, setQ] = useState('')
  const [offset, setOffset] = useState(0)
  const [items, setItems] = useState<TenantAgentTemplate[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 按 q/offset 拉取后端分页数据（与列表页同款）；kind 固定 single。
    setLoading(true)
    TenantAgentTemplates.list({ q, kind: 'single', limit: PAGE_SIZE, offset })
      .then((r) => {
        if (cancelled) return
        setTotal(r.total || 0)
        // offset===0：替换（首页 / 搜索）；offset>0：追加（加载更多）。
        setItems((prev) => (offset === 0 ? (r.items || []) : [...prev, ...(r.items || [])]))
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [q, offset])

  // 搜索变化时 offset 归零（回到第一页）。
  const applySearch = () => { setOffset(0); setQ(qInput.trim()) }
  const loadMore = () => setOffset(items.length)

  const hasMore = items.length < total

  return (
    <DialogShell
      title="从模板创建数字员工"
      subtitle="选择一个平台已发布模板作为起点，进入新建数字员工页预填后可继续编辑，再保存草稿或发布。"
      onClose={onClose}
      size="lg"
    >
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="flex min-w-[220px] flex-1 items-center gap-2">
          <div className="relative flex-1">
            <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
            <Input
              value={qInput}
              onChange={(e) => setQInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); applySearch() } }}
              placeholder="搜索模板名称 / 关键字"
              className="pl-9"
            />
          </div>
          <Button variant="secondary" onClick={applySearch}>搜索</Button>
        </div>
      </div>

      {err && <div className="mb-3"><InlineAlert tone="danger">{err}</InlineAlert></div>}

      {loading && items.length === 0 ? (
        <div className="px-4 py-10 text-center text-[13px] text-[var(--color-text-sub)]">加载模板中...</div>
      ) : items.length === 0 ? (
        <div className="px-4 py-10 text-center text-[13px] text-[var(--color-text-sub)]">
          {q ? '没有匹配的平台已发布模板，换个条件试试。' : '暂无可用的平台已发布模板。'}
        </div>
      ) : (
        <>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            {items.map((t) => (
              <TemplateCard key={t.uuid} t={t} onPick={onPick} />
            ))}
          </div>
          <div className="mt-4 flex items-center justify-center gap-3 text-[12px] text-[var(--color-text-mute)]">
            <span>已显示 {items.length} / {total}</span>
            {hasMore && (
              <Button variant="secondary" size="sm" onClick={loadMore} disabled={loading}>
                {loading ? '加载中...' : '加载更多'}
              </Button>
            )}
          </div>
        </>
      )}
    </DialogShell>
  )
}

function TemplateCard({ t, onPick }: { t: TenantAgentTemplate; onPick: (t: TenantAgentTemplate) => void }) {
  // Phase 2 (2026-06-08)：列表请求已固定 kind='single'，卡片不再区分高级编排类型，
  // 只展示统一的「模板」badge + Bot 图标。
  return (
    <button
      type="button"
      onClick={() => onPick(t)}
      className="flex h-full flex-col rounded-lg border border-[var(--color-line)] bg-white px-3 py-3 text-left transition hover:border-[var(--color-brand-line)] hover:bg-[var(--color-brand-bg)]"
    >
      <div className="flex items-center gap-2">
        {t.avatar_url ? (
            <img src={t.avatar_preview_url || t.avatar_url} alt="" className="h-8 w-8 shrink-0 rounded-md object-cover" />
        ) : (
          <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-[var(--color-bg-sub)] text-[var(--color-brand)]">
            <Bot size={16} />
          </span>
        )}
        <div className="min-w-0 flex-1">
          <div className="truncate text-[13px] font-medium text-[var(--color-text)]">{t.name}</div>
          {t.position_label && (
            <div className="truncate text-[12px] text-[var(--color-text-mute)]">{t.position_label}</div>
          )}
        </div>
        <span className="shrink-0 rounded-md bg-[var(--color-bg-sub)] px-2 py-0.5 text-[11px] text-[var(--color-text-sub)]">
          模板
        </span>
      </div>
      {t.intro && (
        <p className="mt-2 line-clamp-2 text-[12px] leading-relaxed text-[var(--color-text-sub)]">{t.intro}</p>
      )}
    </button>
  )
}
