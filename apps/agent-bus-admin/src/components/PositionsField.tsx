import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, Star, StarOff, X } from 'lucide-react'
import type { Position } from '../lib/api'

export type PositionsFieldValue = {
  positionIds: number[]
  primaryPositionId: number | null
}

/**
 * 职位选择字段。
 *
 * - mode='single' (默认): 单选, 一人一岗 (对齐飞书/企微通讯录约定)。
 *   后端 N:N 表保留, value 永远是 `{positionIds: [id], primaryPositionId: id}` 或空。
 * - mode='multi': 多选 + 星标主职位。预留给未来如果租户有「一人多岗」需求。
 */
export function PositionsField({
  value,
  onChange,
  positions,
  disabled,
  mode = 'single',
}: {
  value: PositionsFieldValue
  onChange: (v: PositionsFieldValue) => void
  positions: Position[]
  disabled?: boolean
  mode?: 'single' | 'multi'
}) {
  const [open, setOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', onDocClick)
    return () => document.removeEventListener('mousedown', onDocClick)
  }, [open])

  const selected = new Set(value.positionIds)

  const selectSingle = (id: number) => {
    if (disabled) return
    if (selected.has(id) && value.positionIds.length === 1) {
      onChange({ positionIds: [], primaryPositionId: null })
    } else {
      onChange({ positionIds: [id], primaryPositionId: id })
    }
    setOpen(false)
  }

  const toggleMulti = (id: number) => {
    if (disabled) return
    if (selected.has(id)) {
      const next = value.positionIds.filter((x) => x !== id)
      onChange({
        positionIds: next,
        primaryPositionId:
          value.primaryPositionId === id
            ? next.length > 0
              ? next[0]
              : null
            : value.primaryPositionId,
      })
    } else {
      const next = [...value.positionIds, id]
      onChange({
        positionIds: next,
        primaryPositionId: value.primaryPositionId ?? id,
      })
    }
  }

  const setPrimary = (id: number) => {
    if (disabled) return
    onChange({ ...value, primaryPositionId: id })
  }

  const clear = () => {
    if (disabled) return
    onChange({ positionIds: [], primaryPositionId: null })
  }

  const selectedPositions = value.positionIds
    .map((id) => positions.find((p) => p.id === id))
    .filter((p): p is Position => !!p)

  // -------- SINGLE mode: <select>-like dropdown showing selection inside trigger --------
  if (mode === 'single') {
    const current = selectedPositions[0]
    return (
      <div ref={wrapRef} className="relative">
        <div className="flex items-stretch gap-2">
          <button
            type="button"
            onClick={() => !disabled && setOpen((o) => !o)}
            disabled={disabled || positions.length === 0}
            className="inline-flex h-10 flex-1 items-center justify-between rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 text-[14px] text-[var(--color-text)] transition hover:bg-white focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]"
          >
            <span className={current ? 'font-medium' : 'text-[var(--color-text-mute)]'}>
              {current ? current.name : '选择职位…'}
            </span>
            <ChevronDown className={'w-4 h-4 text-[var(--color-text-mute)] transition ' + (open ? 'rotate-180' : '')} />
          </button>
          {current && !disabled && (
            <button
              type="button"
              onClick={clear}
              title="清除职位"
              className="inline-flex h-10 w-10 items-center justify-center rounded-md border border-[var(--color-line)] bg-white text-[var(--color-text-mute)] transition hover:bg-[var(--color-line-soft)] hover:text-[var(--color-danger)]"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        {open && positions.length > 0 && (
          <div className="absolute z-[70] mt-1.5 max-h-72 w-full overflow-y-auto rounded-md border border-[var(--color-line)] bg-white py-1.5 shadow-[0_16px_44px_rgba(15,23,42,0.16)]">
            {positions.map((p) => {
              const isCurrent = current?.id === p.id
              return (
                <button
                  type="button"
                  key={p.id}
                  onClick={() => selectSingle(p.id)}
                  className={
                    'flex w-full items-center gap-2 px-3 py-2 text-left text-[13px] transition hover:bg-[var(--color-line-soft)] ' +
                    (isCurrent ? 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]' : 'text-[var(--color-text)]')
                  }
                >
                  <span className="inline-flex items-center justify-center w-4 h-4">
                    {isCurrent && <Check className="w-3.5 h-3.5 text-[var(--color-brand)]" />}
                  </span>
                  <span className={isCurrent ? 'font-medium' : ''}>{p.name}</span>
                  {p.description && (
                    <span className="text-[11px] text-[var(--color-text-mute)] truncate">{p.description}</span>
                  )}
                </button>
              )
            })}
          </div>
        )}

        {positions.length === 0 && (
          <p className="text-[12px] text-[var(--color-text-mute)] mt-1.5">
            本租户尚未配置职位，先到「职位」菜单创建。
          </p>
        )}
      </div>
    )
  }

  // -------- MULTI mode: chips above + dropdown with checkboxes + star primary --------
  return (
    <div ref={wrapRef} className="relative">
      {selectedPositions.length > 0 && (
        <div className="flex flex-wrap gap-1.5 mb-2">
          {selectedPositions.map((p) => {
            const isPrimary = value.primaryPositionId === p.id
            return (
              <span
                key={p.id}
                className={
                  'inline-flex items-center gap-1 h-7 pl-2 pr-1 rounded-full text-[12px] ring-border ' +
                  (isPrimary
                    ? 'bg-[var(--color-brand)] text-white'
                    : 'bg-[var(--color-control-bg)] text-[var(--color-text)]')
                }
              >
                <button
                  type="button"
                  onClick={() => setPrimary(p.id)}
                  disabled={disabled}
                  title={isPrimary ? '主职位' : '设为主职位'}
                  className={
                    'inline-flex items-center justify-center h-5 w-5 rounded-full transition ' +
                    (isPrimary ? 'text-white' : 'text-[var(--color-text-mute)] hover:text-[var(--color-brand)]')
                  }
                >
                  {isPrimary ? <Star className="w-3.5 h-3.5 fill-current" /> : <StarOff className="w-3.5 h-3.5" />}
                </button>
                <span className="font-medium">{p.name}</span>
                <button
                  type="button"
                  onClick={() => toggleMulti(p.id)}
                  disabled={disabled}
                  className={
                    'inline-flex items-center justify-center h-5 w-5 rounded-full transition ' +
                    (isPrimary
                      ? 'hover:bg-white/20'
                      : 'text-[var(--color-text-mute)] hover:text-[var(--color-danger)] hover:bg-[var(--color-line-soft)]')
                  }
                  aria-label="移除"
                >
                  <X className="w-3 h-3" />
                </button>
              </span>
            )
          })}
        </div>
      )}

      <button
        type="button"
        onClick={() => !disabled && setOpen((o) => !o)}
        disabled={disabled || positions.length === 0}
        className="inline-flex h-10 w-full items-center justify-between rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 text-[14px] text-[var(--color-text)] transition hover:bg-white focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]"
      >
        <span className={selectedPositions.length === 0 ? 'text-[var(--color-text-mute)]' : ''}>
          {selectedPositions.length === 0 ? '选择职位…' : `已选 ${selectedPositions.length} 个职位`}
        </span>
        <ChevronDown className={'w-4 h-4 text-[var(--color-text-mute)] transition ' + (open ? 'rotate-180' : '')} />
      </button>

      {open && positions.length > 0 && (
        <div className="absolute z-[70] mt-1.5 max-h-72 w-full overflow-y-auto rounded-md border border-[var(--color-line)] bg-white py-1.5 shadow-[0_16px_44px_rgba(15,23,42,0.16)]">
          {positions.map((p) => {
            const checked = selected.has(p.id)
            return (
              <button
                type="button"
                key={p.id}
                onClick={() => toggleMulti(p.id)}
                className="flex w-full items-center gap-2 px-3 py-2 text-left text-[13px] text-[var(--color-text)] transition hover:bg-[var(--color-line-soft)]"
              >
                <span
                  className={
                    'inline-flex items-center justify-center w-4 h-4 rounded ring-border ' +
                    (checked ? 'bg-[var(--color-brand)] text-white border-transparent' : 'bg-white')
                  }
                >
                  {checked && <Check className="w-3 h-3" />}
                </span>
                <span className={checked ? 'font-medium' : ''}>{p.name}</span>
                {p.description && (
                  <span className="text-[11px] text-[var(--color-text-mute)] truncate">{p.description}</span>
                )}
              </button>
            )
          })}
        </div>
      )}

      {positions.length === 0 && (
        <p className="text-[12px] text-[var(--color-text-mute)] mt-1.5">
          本租户尚未配置职位，先到「职位」菜单创建。
        </p>
      )}

      {selectedPositions.length > 1 && (
        <p className="text-[11px] text-[var(--color-text-mute)] mt-1.5">
          已选 {selectedPositions.length} 个职位；星标的为主职位，用于通讯录主显示。
        </p>
      )}
    </div>
  )
}
