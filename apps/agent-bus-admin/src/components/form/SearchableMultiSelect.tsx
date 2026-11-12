// SearchableMultiSelect — 通用「已选标签 + 搜索候选列表多选」控件。
//
// 设计依据：
//   - docs/standards/admin-web-component-reuse.md R1：同字段 = 同控件
//   - docs/standards/admin-web-design-standard.md：admin 克制审美、design token、shadcn 风格
//   - docs/features/F02-agent-platform-and-runtime.md §5.4.4：能力装配（技能 / 应用 / 知识库）
//
// 布局：
//   │ 右上：已选择 N 项                          │
//   │ [chip A ×] [chip B ×] [预留提示] [×][点击收起]│
//   ↓ open 时
//   │ [🔍 搜索]                                  │
//   │ [全部分类⌄]                         共 N 项│
//   │ ☑  icon  option A   hint                  │
//   │          description                      │
//   └─ 支持 ↑↓ 选择，Enter 确认，Esc 关闭 ───────┘
//
// trigger 内最多展示两行 chip；超出滚动，避免把长表单撑爆。
//
// 交互：
//   - 触发区点击/键盘展开；展开后在面板搜索框输入过滤
//   - 选中：候选行点击切换勾选状态
//   - 移除：标签 × 移除单项，触发区 × 清空全部
//   - 键盘：↑↓ active option，Enter 切换草稿，Esc 取消折叠

import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { Check, ChevronDown, Lock, Search, X } from 'lucide-react'

export type SearchableMultiSelectOption = {
  value: string
  label: string
  hint?: string
  description?: string
  iconUrl?: string
  iconText?: string
  categoryKey?: string
  locked?: boolean
}

export type SearchableMultiSelectCategory = {
  value: string
  label: string
}

export type SearchableMultiSelectProps = {
  options: SearchableMultiSelectOption[]
  value: string[]
  onChange: (next: string[]) => void
  categoryOptions?: SearchableMultiSelectCategory[]
  categoryLabel?: string
  categoryPlaceholder?: string
  placeholder?: string
  emptyHint?: string
  maxHeight?: number
  disabled?: boolean
  /** 已选区单元（chip）颜色风格；默认 brand */
  chipTone?: 'brand' | 'neutral'
}

export function SearchableMultiSelect({
  options,
  value,
  onChange,
  categoryOptions = [],
  categoryLabel = '分类',
  categoryPlaceholder = '全部分类',
  placeholder = '输入关键字搜索…',
  emptyHint = '暂无可选项',
  maxHeight = 448,
  disabled,
  chipTone = 'brand',
}: SearchableMultiSelectProps) {
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const [category, setCategory] = useState('')
  const [draftValue, setDraftValue] = useState<string[]>(value)
  const [activeIdx, setActiveIdx] = useState(0)
  const rootRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const listboxId = useId()

  useEffect(() => {
    if (!open) return
    window.requestAnimationFrame(() => inputRef.current?.focus())
    const onDoc = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) {
        setOpen(false)
        setQ('')
      }
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      setOpen(false)
      setQ('')
    }
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      document.removeEventListener('keydown', onKey, true)
    }
  }, [open, value])

  const byValue = useMemo(() => {
    const m: Record<string, SearchableMultiSelectOption> = {}
    for (const o of options) m[o.value] = o
    return m
  }, [options])

  const selected = useMemo(
    () => value.map((v) => byValue[v]).filter(Boolean) as SearchableMultiSelectOption[],
    [value, byValue],
  )

  const draftSelected = useMemo(
    () => draftValue.map((v) => byValue[v]).filter(Boolean) as SearchableMultiSelectOption[],
    [draftValue, byValue],
  )

  const filtered = useMemo(() => {
    const kw = q.trim().toLowerCase()
    const scoped = category ? options.filter((o) => o.categoryKey === category) : options
    if (!kw) return scoped
    return scoped.filter(
      (o) =>
        o.label.toLowerCase().includes(kw) ||
        (o.hint ? o.hint.toLowerCase().includes(kw) : false) ||
        o.value.toLowerCase().includes(kw),
    )
  }, [category, options, q])

  useEffect(() => {
    if (!open) return
    const node = listRef.current?.querySelector<HTMLElement>(`[data-idx="${activeIdx}"]`)
    node?.scrollIntoView({ block: 'nearest' })
  }, [activeIdx, open])

  const openPicker = () => {
    if (disabled) return
    if (!open) setDraftValue(value)
    setOpen(true)
    setActiveIdx(0)
  }

  const toggleDraft = (v: string) => {
    if (disabled) return
    if (byValue[v]?.locked) return
    const base = draftValue.length > 0 || open ? draftValue : value
    const next = base.includes(v) ? base.filter((x) => x !== v) : [...base, v]
    setDraftValue(next)
    onChange(next)
    setQ('')
    inputRef.current?.focus()
  }

  const remove = (v: string, e?: React.MouseEvent<HTMLButtonElement>) => {
    if (disabled) return
    if (byValue[v]?.locked) return
    e?.preventDefault()
    e?.stopPropagation()
    onChange(value.filter((x) => x !== v))
    setDraftValue((current) => current.filter((x) => x !== v))
  }

  const cancel = () => {
    setOpen(false)
    setQ('')
  }

  const clearAll = (e?: React.MouseEvent<HTMLButtonElement>) => {
    if (disabled) return
    e?.preventDefault()
    e?.stopPropagation()
    const lockedValues = value.filter((v) => byValue[v]?.locked)
    onChange(lockedValues)
    setDraftValue(lockedValues)
    setQ('')
    inputRef.current?.focus()
  }

  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setOpen(true)
      setActiveIdx((i) => (filtered.length === 0 ? 0 : Math.min(filtered.length - 1, i + 1)))
      return
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActiveIdx((i) => Math.max(0, i - 1))
      return
    }
    if (e.key === 'Enter') {
      e.preventDefault()
      const target = filtered[activeIdx]
      if (target) toggleDraft(target.value)
      return
    }
    if (e.key === 'Escape') {
      cancel()
      return
    }
  }

  if (options.length === 0) {
    return (
      <div className="rounded-md border border-dashed border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-mute)]">
        {emptyHint}
      </div>
    )
  }

  const chipBase =
    chipTone === 'brand'
      ? 'border-[var(--color-brand-line)] bg-[var(--color-bg-sub)] text-[var(--color-text)] shadow-[inset_0_0_0_1px_var(--color-surface)]'
      : 'border-[var(--color-line)] bg-[var(--color-bg-sub)] text-[var(--color-text-sub)]'
  const chipXBase =
    chipTone === 'brand'
      ? 'text-[var(--color-text-mute)] hover:bg-white/80 hover:text-[var(--color-brand)]'
      : 'text-[var(--color-text-mute)] hover:bg-[var(--color-bg-sub)] hover:text-[var(--color-text)]'
  const hasQuery = q.trim().length > 0
  const hasCategoryFilter = categoryOptions.length > 0
  const triggerClass = `group relative flex min-h-11 items-center gap-2 rounded-md border bg-[var(--color-control-bg)] px-3 py-1.5 shadow-[0_1px_0_rgba(23,23,23,0.02)] transition-colors duration-150 hover:border-[var(--color-brand-line)] ${
    open ? 'border-[var(--color-brand)] shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]' : 'border-[var(--color-line)]'
  } ${disabled ? 'cursor-not-allowed opacity-60' : 'cursor-pointer'}`

  const onTriggerKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      openPicker()
      return
    }
    if (e.key === 'Escape') {
      cancel()
    }
  }

  return (
    <div
      ref={rootRef}
      className="relative text-[13px]"
    >
      {selected.length > 0 && (
        <div className="pointer-events-none absolute -top-6 right-0 flex items-center justify-end text-[12px]">
          <span className="text-[var(--color-brand)]">
            已选择 <b className="font-semibold tabular-nums">{selected.length}</b> 项
          </span>
        </div>
      )}

      <div>
        <div
          onClick={openPicker}
          onKeyDown={onTriggerKeyDown}
          role="combobox"
          tabIndex={disabled ? -1 : 0}
          aria-expanded={open}
          aria-controls={listboxId}
          aria-haspopup="listbox"
          className={triggerClass}
        >
          {selected.length === 0 && <Search size={16} className="shrink-0 text-[var(--color-text-mute)]" />}
          {selected.length > 0 && (
            <div
              role="presentation"
              onPointerDown={(e) => e.stopPropagation()}
              onMouseDown={(e) => e.stopPropagation()}
              onClick={(e) => e.stopPropagation()}
              className="flex max-h-[64px] min-w-0 flex-wrap items-center gap-2 overflow-y-auto pr-1"
            >
              {selected.map((o) => (
                <span
                  key={o.value}
                  title={o.hint ? `${o.label} · ${o.hint}` : o.label}
                  className={`pointer-events-none inline-flex h-7 max-w-full select-none items-center gap-2 rounded-md border pl-2 pr-1 text-[12px] transition ${chipBase}`}
                >
                  <OptionIcon option={o} size="xs" />
                  <span className="max-w-[180px] truncate">{o.label}</span>
                  {o.locked && <Lock size={11} className="shrink-0 text-[var(--color-text-mute)]" aria-label={`${o.label} 由平台管理`} />}
                  {!disabled && !o.locked && (
                    <button
                      type="button"
                      data-searchable-multiselect-action="remove"
                      tabIndex={0}
                      onMouseDown={(e) => {
                        e.preventDefault()
                        e.stopPropagation()
                      }}
                      onClick={(e) => remove(o.value, e)}
                      className={`pointer-events-auto inline-flex h-4 w-4 items-center justify-center rounded-full transition ${chipXBase}`}
                      aria-label={`移除 ${o.label}`}
                    >
                      <X size={11} />
                    </button>
                  )}
                </span>
              ))}
            </div>
          )}
          <span className="h-8 min-w-[160px] flex-1 select-none truncate py-1.5 text-[13px] text-[var(--color-text-mute)]">
            {placeholder}
          </span>
          {(hasQuery || selected.length > 0) && (
            <button
              type="button"
              tabIndex={-1}
              onMouseDown={(e) => e.preventDefault()}
              onClick={(e) => {
                e.stopPropagation()
                if (hasQuery) {
                  setQ('')
                  return
                }
                clearAll(e)
              }}
              className="ml-auto flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[var(--color-text-mute)] transition hover:bg-[var(--color-bg-sub)] hover:text-[var(--color-text-sub)]"
              aria-label={hasQuery ? '清空搜索' : '清空已选'}
            >
              <X size={14} />
            </button>
          )}
          <span className="h-5 w-px bg-[var(--color-line-soft)]" />
          <button
            type="button"
            tabIndex={-1}
            onMouseDown={(e) => e.preventDefault()}
            onClick={(e) => {
              e.stopPropagation()
              const nextOpen = !open
              if (nextOpen) {
                setDraftValue(value)
                setActiveIdx(0)
                setOpen(true)
                return
              }
              cancel()
            }}
            className={`flex h-6 shrink-0 items-center justify-center rounded transition ${
              open
                ? 'w-auto gap-1 px-2 text-[12px] font-medium text-[var(--color-brand)] hover:bg-[var(--color-brand-soft)]'
                : 'w-6 text-[var(--color-text-mute)] hover:bg-[var(--color-bg-sub)] hover:text-[var(--color-text-sub)]'
            }`}
            aria-label={open ? '点击收起候选列表' : '展开候选列表'}
          >
            {open && <span>点击收起</span>}
            <ChevronDown
              size={14}
              className={`transition-transform ${open ? 'rotate-180' : ''}`}
            />
          </button>
        </div>

        {open && (
          <div className="mt-1 overflow-hidden rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] shadow-[0_12px_32px_rgba(15,23,42,0.08)]">
            <div className="border-b border-[var(--color-line-soft)] p-3">
              <div className="flex h-10 items-center gap-2 rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 transition focus-within:border-[var(--color-brand)] focus-within:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]">
                <Search size={16} className="shrink-0 text-[var(--color-text-mute)]" />
                <input
                  value={q}
                  onChange={(e) => {
                    setQ(e.target.value)
                    setActiveIdx(0)
                  }}
                  onKeyDown={onKeyDown}
                  placeholder={placeholder.replace('点击挑选', '搜索').replace('...', '名称或关键字')}
                  className="h-full min-w-0 flex-1 border-0 bg-transparent p-0 text-[13px] text-[var(--color-text)] outline-none ring-0 shadow-none focus:border-0 focus:outline-none focus:ring-0 focus:shadow-none focus-visible:outline-none focus-visible:ring-0 placeholder:text-[var(--color-text-mute)]"
                  style={{ outline: 'none', boxShadow: 'none' }}
                  autoFocus
                />
              </div>
              <div className="mt-3 flex items-center justify-between gap-3">
                {hasCategoryFilter ? (
                  <div
                    className="relative"
                    onMouseDown={(e) => e.stopPropagation()}
                    onClick={(e) => e.stopPropagation()}
                  >
                    <label htmlFor={`${listboxId}-category`} className="sr-only">{categoryLabel}</label>
                    <select
                      id={`${listboxId}-category`}
                      value={category}
                      onChange={(e) => {
                        setCategory(e.target.value)
                        setActiveIdx(0)
                      }}
                      className="h-8 max-w-[220px] appearance-none rounded-full border border-transparent bg-[var(--color-brand-soft)] py-0 pl-3 pr-8 text-[12px] font-medium text-[var(--color-brand)] outline-none transition hover:border-[var(--color-brand-line)]"
                      aria-label={categoryLabel}
                    >
                      <option value="">{categoryPlaceholder}</option>
                      {categoryOptions.map((item) => (
                        <option key={item.value} value={item.value}>{item.label}</option>
                      ))}
                    </select>
                    <ChevronDown size={13} className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-[var(--color-brand)]" />
                  </div>
                ) : (
                  <span />
                )}
                <span className="shrink-0 text-[12px] text-[var(--color-text-mute)]">
                  共 <span className="tabular-nums">{filtered.length}</span> 项
                </span>
              </div>
            </div>
            <div
              ref={listRef}
              className="overflow-hidden"
              role="listbox"
              id={listboxId}
              aria-multiselectable
            >
              <div className="overflow-y-auto" style={{ maxHeight }}>
              {filtered.length === 0 ? (
                <div className="flex flex-col items-center gap-1 px-3 py-8 text-[12px] text-[var(--color-text-mute)]">
                  <Search size={16} className="text-[var(--color-text-mute)]" />
                  <span>{hasQuery ? `未匹配到「${q}」` : '当前分类下暂无可选项'}</span>
                </div>
              ) : (
                <div>
                  {filtered.map((o, idx) => {
                    const active = draftValue.includes(o.value)
                    const hover = idx === activeIdx
                    return (
                      <div
                        key={o.value}
                        data-idx={idx}
                        onMouseEnter={() => setActiveIdx(idx)}
                        onMouseDown={(e) => e.preventDefault()}
                        onClick={() => toggleDraft(o.value)}
                        role="option"
                        aria-selected={active}
                        aria-disabled={o.locked || undefined}
                        className={`grid min-h-[56px] grid-cols-[28px_36px_minmax(0,1fr)_24px] items-center gap-2 border-b border-[var(--color-line-soft)] px-3 py-2 last:border-b-0 transition ${o.locked ? 'cursor-not-allowed opacity-75' : 'cursor-pointer'} ${
                          active
                            ? 'bg-[var(--color-brand-soft)] text-[var(--color-text)]'
                            : hover
                              ? 'bg-[var(--color-bg-sub)] text-[var(--color-text)]'
                              : 'text-[var(--color-text)]'
                        }`}
                      >
                        <span
                          className={`grid h-4 w-4 place-items-center rounded border ${
                            active
                              ? 'border-[var(--color-brand)] bg-[var(--color-brand)] text-white'
                              : 'border-[var(--color-line)] bg-[var(--color-surface)] text-transparent'
                          }`}
                        >
                          <Check size={12} strokeWidth={3} />
                        </span>
                        <OptionIcon option={o} />
                        <div className="min-w-0">
                          <div className="flex min-w-0 items-baseline gap-2">
                            <span className="truncate text-[13px] font-medium text-[var(--color-text)]">{o.label}</span>
                            {o.hint && <span className="shrink-0 truncate text-[12px] text-[var(--color-text-mute)]">{o.hint}</span>}
                          </div>
                          {o.description && (
                            <div className="mt-0.5 truncate text-[11px] leading-4 text-[var(--color-text-sub)]">
                              {o.description}
                            </div>
                          )}
                        </div>
                        <span className={`justify-self-end text-[var(--color-brand)] transition ${active || o.locked ? 'opacity-100' : 'opacity-0'}`}>
                          {o.locked ? <Lock size={14} /> : <Check size={16} strokeWidth={3} />}
                        </span>
                      </div>
                    )
                  })}
                </div>
              )}
              </div>
              <div className="flex items-center justify-between border-t border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-mute)]">
                <span>支持 ↑↓ 选择，Enter 确认，Esc 关闭</span>
                <span>已选 <b className="font-semibold text-[var(--color-text)]">{draftSelected.length}</b> 项</span>
              </div>
            </div>
          </div>
        )}
      </div>

    </div>
  )
}

function OptionIcon({ option, size = 'md' }: { option: SearchableMultiSelectOption; size?: 'xs' | 'md' }) {
  const dim = size === 'xs' ? 'h-5 w-5 rounded-md' : 'h-8 w-8 rounded-full'
  const textSize = size === 'xs' ? 'text-[11px]' : 'text-[13px]'
  const label = option.iconText || option.label.slice(0, 1)
  const img = renderableImageUrl(option.iconUrl)
  const tone = optionIconTone(option)
  return (
    <span className={`grid shrink-0 place-items-center overflow-hidden shadow-[inset_0_0_0_1px_var(--color-surface)] ${tone} ${dim} ${textSize}`}>
      {img ? (
        <img src={img} alt="" className="h-full w-full object-cover" />
      ) : (
        <span className="font-semibold leading-none">{label}</span>
      )}
    </span>
  )
}

function optionIconTone(option: SearchableMultiSelectOption): string {
  const source = `${option.label} ${option.hint || ''} ${option.value}`.toLowerCase()
  if (source.includes('image') || source.includes('图片')) return 'bg-[var(--color-icon-purple-bg)] text-[var(--color-icon-purple)]'
  if (source.includes('xiaohongshu') || source.includes('小红书')) return 'bg-[var(--color-icon-red-bg)] text-[var(--color-icon-red)]'
  if (source.includes('excel') || source.includes('sheet') || source.includes('数据')) return 'bg-[var(--color-icon-green-bg)] text-[var(--color-icon-green)]'
  if (source.includes('api') || source.includes('接口')) return 'bg-[var(--color-icon-orange-bg)] text-[var(--color-icon-orange)]'
  if (source.includes('kb') || source.includes('知识')) return 'bg-[var(--color-info-bg)] text-[var(--color-info)]'
  return 'bg-[var(--color-icon-blue-bg)] text-[var(--color-icon-blue)]'
}

function renderableImageUrl(url?: string): string {
  if (!url) return ''
  if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('data:') || url.startsWith('/')) return url
  return ''
}
