import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from 'react'
import { useEffect, useRef, useState } from 'react'
import clsx from 'clsx'
import * as TooltipPrimitive from '@radix-ui/react-tooltip'
import { AlertTriangle, ChevronDown, ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, HelpCircle, Plus, Search, X } from 'lucide-react'
import { Bar, BarChart, CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis, type TooltipContentProps } from 'recharts'

type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'
type ButtonSize = 'sm' | 'md'

export function Button({
  variant = 'primary',
  size = 'md',
  tone,
  className,
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant
  size?: ButtonSize
  tone?: 'info' | 'success' | 'warn' | 'danger'
}) {
  return (
    <button
      className={clsx(
        'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md font-medium disabled:cursor-not-allowed disabled:opacity-60',
        variant === 'secondary' && tone ? 'transition-none' : 'transition',
        size === 'md' ? 'h-9 px-3.5 text-[13px]' : 'h-8 px-3 text-[13px]',
        variant === 'primary' && 'bg-[var(--color-brand)] text-white shadow-[rgba(15,107,255,0.24)_0px_8px_18px] hover:bg-[var(--color-brand-hover)]',
        variant === 'secondary' && !tone && 'ring-border bg-white text-[var(--color-text)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-brand)]',
        variant === 'secondary' && tone && 'border border-current/20 hover:border-current/40',
        variant === 'secondary' && tone === 'info' && 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
        variant === 'secondary' && tone === 'success' && 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
        variant === 'secondary' && tone === 'warn' && 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
        variant === 'secondary' && tone === 'danger' && 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
        variant === 'ghost' && 'text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]',
        variant === 'danger' && 'bg-[var(--color-danger)] text-white hover:bg-red-800',
        className
      )}
      {...props}
    >
      {children}
    </button>
  )
}

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={clsx(
        'h-9 w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 text-[13px] text-[var(--color-text)] transition placeholder:text-[var(--color-text-mute)]',
        'focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]',
        'disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]',
        className
      )}
      {...props}
    />
  )
}

export function Select({ className, children, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <span className="relative block w-full">
      <select
        className={clsx(
          'h-9 w-full appearance-none rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 pr-9 text-[13px] text-[var(--color-text)] transition',
          'focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]',
          'disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]',
          className
        )}
        {...props}
      >
        {children}
      </select>
      <ChevronDown
        size={16}
        className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]"
      />
    </span>
  )
}

export function FormField({
  label,
  hint,
  required,
  children,
  as = 'label',
}: {
  label: string
  hint?: string
  required?: boolean
  children: ReactNode
  as?: 'label' | 'div'
}) {
  const Tag = as
  return (
    <Tag className="block">
      <HelpLabel label={label} hint={hint} required={required} />
      {children}
    </Tag>
  )
}

function HoverHint({ hint, width = 260 }: { hint: string; width?: number }) {
  return (
    <TooltipPrimitive.Provider delayDuration={200}>
      <TooltipPrimitive.Root>
        <TooltipPrimitive.Trigger asChild>
          <span
            tabIndex={0}
            aria-label={hint}
            className="inline-flex h-4 w-4 cursor-help items-center justify-center rounded-full text-[var(--color-text-mute)] transition hover:text-[var(--color-text)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25"
          >
            <HelpCircle size={13} />
          </span>
        </TooltipPrimitive.Trigger>
        <TooltipPrimitive.Portal>
          <TooltipPrimitive.Content
            side="bottom"
            align="center"
            sideOffset={6}
            collisionPadding={8}
            style={{ width }}
            className="z-[80] whitespace-normal rounded-md bg-[var(--color-text)] px-2.5 py-2 text-left text-[12px] font-normal leading-relaxed text-white shadow-lg"
          >
            {hint}
            <TooltipPrimitive.Arrow className="fill-[var(--color-text)]" />
          </TooltipPrimitive.Content>
        </TooltipPrimitive.Portal>
      </TooltipPrimitive.Root>
    </TooltipPrimitive.Provider>
  )
}

export function HelpLabel({ label, hint, required }: { label: string; hint?: string; required?: boolean }) {
  return (
    <span className="mb-1.5 flex items-center gap-1.5 text-[13px] font-medium text-[var(--color-text)]">
      {label}
      {required && <span aria-hidden="true" className="text-[var(--color-danger)]">*</span>}
      {hint && <HoverHint hint={hint} />}
    </span>
  )
}

export function FormSection({
  title,
  titleHint,
  description,
  actions,
  children,
  className,
}: {
  title: ReactNode
  titleHint?: string
  description?: string
  actions?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className={clsx('rounded-lg border border-[var(--color-line)] bg-white p-4', className)}>
      <div className="mb-3 flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-1.5 text-[14px] font-semibold text-[var(--color-text)]">
            {title}
            {titleHint && <HoverHint hint={titleHint} width={300} />}
          </div>
          {description && <p className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">{description}</p>}
        </div>
        {actions}
      </div>
      {children}
    </section>
  )
}

export function ProgressBar({
  value,
  max = 100,
  label,
}: {
  value: number
  max?: number
  label: string
}) {
  const boundedMax = max > 0 ? max : 100
  const boundedValue = Math.min(boundedMax, Math.max(0, value))
  const percent = Math.round((boundedValue / boundedMax) * 100)

  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between gap-3 text-[12px] text-[var(--color-text-sub)]">
        <span className="min-w-0 truncate">{label}</span>
        <span className="shrink-0 font-medium tabular-nums text-[var(--color-text)]">{percent}%</span>
      </div>
      <div
        className="h-2 overflow-hidden rounded-full bg-[var(--color-line-soft)]"
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={boundedMax}
        aria-valuenow={boundedValue}
      >
        <div
          className="h-full rounded-full bg-[var(--color-brand)] transition-[width] duration-200"
          style={{ width: `${percent}%` }}
        />
      </div>
    </div>
  )
}

export function DrawerShell({
  title,
  subtitle,
  icon,
  onClose,
  children,
  footer,
  width = 'md',
  variant = 'default',
}: {
  title: string
  subtitle?: string
  icon?: ReactNode
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
  width?: 'sm' | 'md' | 'lg'
  variant?: 'default' | 'polished'
}) {
  const widthClass = width === 'lg' ? 'max-w-[920px]' : width === 'sm' ? 'max-w-[560px]' : 'max-w-[720px]'
  const polishedWidthClass = width === 'lg'
    ? 'max-w-[min(960px,100vw)]'
    : width === 'sm'
      ? 'max-w-[min(560px,100vw)]'
      : 'max-w-[min(760px,100vw)]'

  if (variant === 'polished') {
    return (
      <div className="fixed inset-0 z-50 flex justify-end bg-black/35 backdrop-blur-[1px]" onClick={onClose}>
        <div
          className={clsx('flex h-full w-full flex-col overflow-hidden bg-white shadow-2xl ring-1 ring-black/10', polishedWidthClass)}
          onClick={(e) => e.stopPropagation()}
        >
          <header className="shrink-0 border-b border-[var(--color-line)] bg-white px-7 py-5">
            <div className="flex items-start justify-between gap-5">
              <div className="min-w-0 pt-0.5">
                <div className="truncate text-[22px] font-semibold tracking-tight text-[var(--color-text)]">{title}</div>
                {subtitle && <p className="mt-1.5 text-[13px] leading-relaxed text-[var(--color-text-sub)]">{subtitle}</p>}
              </div>
              <button
                type="button"
                onClick={onClose}
                className="grid h-9 w-9 shrink-0 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-line-soft)] hover:text-[var(--color-text)]"
                title="关闭"
              >
                <X size={20} />
              </button>
            </div>
          </header>
          <div className="flex-1 overflow-y-auto bg-white px-7 py-6">
            {children}
          </div>
          {footer && (
            <footer className="shrink-0 bg-white px-7 py-4">
              {footer}
            </footer>
          )}
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex" onClick={onClose}>
      <div className="flex-1 bg-black/25 backdrop-blur-[1px]" />
      <div
        className={clsx('flex h-full w-full flex-col overflow-hidden bg-white shadow-2xl', widthClass)}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="shrink-0 border-b border-[var(--color-line)] bg-white px-6 py-4">
          <div className="flex items-start justify-between gap-4">
            <div className="flex min-w-0 items-start gap-3">
              {icon && (
                <div className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-[var(--color-line-soft)] text-[var(--color-text-sub)] ring-1 ring-[var(--color-line)]">
                  {icon}
                </div>
              )}
              <div className="min-w-0">
                <div className="truncate text-[18px] font-semibold tracking-tight text-[var(--color-text)]">{title}</div>
                {subtitle && <p className="mt-1 text-[12.5px] leading-relaxed text-[var(--color-text-sub)]">{subtitle}</p>}
              </div>
            </div>
            <button
              type="button"
              onClick={onClose}
              className="grid h-8 w-8 shrink-0 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-line-soft)]"
              title="关闭"
            >
              <X size={16} />
            </button>
          </div>
        </header>
        <div className="flex-1 overflow-y-auto px-6 py-5">
          {children}
        </div>
        {footer && (
          <footer className="shrink-0 bg-white px-6 py-3">
            {footer}
          </footer>
        )}
      </div>
    </div>
  )
}

export function DialogShell({
  title,
  subtitle,
  icon,
  onClose,
  children,
  footer,
  size = 'md',
}: {
  title: string
  subtitle?: string
  icon?: ReactNode
  onClose: () => void
  children: ReactNode
  footer?: ReactNode
  size?: 'sm' | 'md' | 'lg'
}) {
  const sizeClass = size === 'lg' ? 'max-w-3xl' : size === 'sm' ? 'max-w-md' : 'max-w-xl'
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/35 px-4 backdrop-blur-[1px]" onClick={onClose}>
      <div
        className={clsx('flex max-h-[92vh] w-full flex-col overflow-hidden rounded-lg bg-white shadow-2xl ring-1 ring-black/5', sizeClass)}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="shrink-0 border-b border-[var(--color-line)] bg-white px-6 py-4">
          <div className="flex items-start justify-between gap-4">
            <div className="flex min-w-0 items-start gap-3">
              {icon && (
                <div className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-[var(--color-line-soft)] text-[var(--color-text-sub)] ring-1 ring-[var(--color-line)]">
                  {icon}
                </div>
              )}
              <div className="min-w-0">
                <div className="truncate text-[18px] font-semibold tracking-tight text-[var(--color-text)]">{title}</div>
                {subtitle && <p className="mt-1 text-[12.5px] leading-relaxed text-[var(--color-text-sub)]">{subtitle}</p>}
              </div>
            </div>
            <button
              type="button"
              onClick={onClose}
              className="grid h-8 w-8 shrink-0 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-line-soft)]"
              title="关闭"
            >
              <X size={16} />
            </button>
          </div>
        </header>
        <div className="flex-1 overflow-y-auto px-6 py-5">
          {children}
        </div>
        {footer && (
          <footer className="shrink-0 bg-white px-6 py-3">
            {footer}
          </footer>
        )}
      </div>
    </div>
  )
}

export function ConfirmDialog({
  title,
  description,
  children,
  confirmLabel = '确认',
  busyLabel,
  cancelLabel = '取消',
  tone = 'danger',
  confirmDisabled = false,
  onClose,
  onConfirm,
}: {
  title: string
  description?: ReactNode
  children?: ReactNode
  confirmLabel?: string
  busyLabel?: string
  cancelLabel?: string
  tone?: 'danger' | 'warn' | 'info'
  confirmDisabled?: boolean
  onClose: () => void
  onConfirm: () => Promise<void> | void
}) {
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const confirmVariant = tone === 'danger' ? 'danger' : 'primary'
  return (
    <DialogShell
      title={title}
      icon={(
        <AlertTriangle
          size={18}
          className={clsx(
            tone === 'danger' && 'text-[var(--color-danger)]',
            tone === 'warn' && 'text-[var(--color-warn)]',
            tone === 'info' && 'text-[var(--color-info)]'
          )}
        />
      )}
      onClose={onClose}
      size="sm"
      footer={(
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>{cancelLabel}</Button>
          <Button
            variant={confirmVariant}
            disabled={busy || confirmDisabled}
            onClick={async () => {
              setBusy(true)
              setErr('')
              try {
                await onConfirm()
                setBusy(false)
              } catch (e) {
                setErr((e as Error).message)
                setBusy(false)
              }
            }}
          >
            {busy ? (busyLabel || `${confirmLabel}中...`) : confirmLabel}
          </Button>
        </div>
      )}
    >
      <div className="space-y-3">
        {description && (
          <div className="text-[14px] leading-relaxed text-[var(--color-text-sub)]">
            {description}
          </div>
        )}
        {children}
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DialogShell>
  )
}

export function Tabs<T extends string>({
  value,
  items,
  onChange,
  className,
  variant = 'segmented',
}: {
  value: T
  items: Array<{ value: T; label: string }>
  onChange: (value: T) => void
  className?: string
  variant?: 'segmented' | 'underline'
}) {
  if (variant === 'underline') {
    return (
      <div className={clsx('flex border-b border-[var(--color-line)]', className)}>
        {items.map((item) => (
          <button
            key={item.value}
            type="button"
            onClick={() => onChange(item.value)}
            className={clsx(
              '-mb-px h-10 border-b-2 px-1 text-[13px] font-medium transition',
              value === item.value
                ? 'border-[var(--color-brand)] text-[var(--color-brand)]'
                : 'border-transparent text-[var(--color-text-sub)] hover:text-[var(--color-text)]',
              'mr-6 last:mr-0',
            )}
          >
            {item.label}
          </button>
        ))}
      </div>
    )
  }

  return (
    <div className={clsx('inline-flex rounded-lg bg-[var(--color-brand-soft)] p-1', className)}>
      {items.map((item) => (
        <button
          key={item.value}
          type="button"
          onClick={() => onChange(item.value)}
          className={clsx(
            'h-8 flex-1 whitespace-nowrap rounded-md px-4 text-[13px] font-medium transition-all',
            value === item.value
              ? 'bg-white text-[var(--color-brand)] shadow-[0_1px_4px_rgba(15,23,42,0.14)]'
              : 'text-[var(--color-text-sub)] hover:text-[var(--color-text)]'
          )}
        >
          {item.label}
        </button>
      ))}
    </div>
  )
}

// 分段选择器：用于「二/三选一」的互斥表单选项。
// 与 Tabs 区分：Tabs 是页面/分区导航，SegmentedControl 是表单内的取值控件。
export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  size = 'md',
  className,
}: {
  options: { value: T; label: string; icon?: ReactNode; disabled?: boolean }[]
  value: T
  onChange: (value: T) => void
  size?: 'sm' | 'md'
  className?: string
}) {
  const seg = size === 'sm' ? 'h-8 px-3 text-[12px]' : 'h-9 px-4 text-[13px]'
  return (
    <div className={clsx('inline-flex rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-0.5', className)}>
      {options.map((opt) => {
        const active = opt.value === value
        return (
          <button
            key={opt.value}
            type="button"
            disabled={opt.disabled}
            aria-pressed={active}
            onClick={() => onChange(opt.value)}
            className={clsx(
              'inline-flex items-center justify-center gap-1.5 rounded-[5px] font-medium transition',
              seg,
              active && 'bg-white shadow-sm',
              opt.disabled
                ? 'cursor-not-allowed text-[var(--color-text-mute)]'
                : active
                  ? 'text-[var(--color-text)]'
                  : 'text-[var(--color-text-sub)] hover:text-[var(--color-text)]',
            )}
          >
            {opt.icon && <span className="grid place-items-center">{opt.icon}</span>}
            {opt.label}
          </button>
        )
      })}
    </div>
  )
}

export function Panel({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return <section className={clsx('console-panel rounded-lg', className)}>{children}</section>
}

// KpiCard — 列表页顶部统计卡的统一形态（本月新增/进行中/… 一类「量」指标）。
// 放一排 `grid gap-3 md:grid-cols-4` 里用；tone 只染数字色，标签/底色保持一致。
type KpiTone = 'success' | 'warn' | 'danger'

const KPI_TONE: Record<KpiTone, string> = {
  success: 'text-[var(--color-success)]',
  warn: 'text-[var(--color-warn)]',
  danger: 'text-[var(--color-danger)]',
}

export function KpiCard({
  label,
  value,
  hint,
  tone,
  icon,
}: {
  label: string
  value: ReactNode
  hint?: string
  tone?: KpiTone
  icon?: ReactNode
}) {
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white p-3">
      <div className="flex items-center gap-1.5 text-[12px] text-[var(--color-text-sub)]">
        {icon && <span className="text-[var(--color-text-mute)]">{icon}</span>}
        {label}
      </div>
      <div className={clsx('mt-1 text-[22px] font-semibold tabular-nums', tone ? KPI_TONE[tone] : 'text-[var(--color-text)]')}>
        {value}
      </div>
      {hint && <div className="mt-0.5 text-[11px] text-[var(--color-text-mute)]">{hint}</div>}
    </div>
  )
}

type EmptyStateTone = 'neutral' | 'info' | 'success' | 'danger' | 'warning'

// tone → 软色 icon 圈调色板 (统一来源, 避免每页自己拼色)
const EMPTY_TONE_PALETTE: Record<EmptyStateTone, { ring: string; bg: string; fg: string; halo: string }> = {
  neutral: {
    ring: 'ring-[var(--color-line)]',
    bg: 'bg-gradient-to-br from-[var(--color-line-soft)] to-white',
    fg: 'text-[var(--color-text-sub)]',
    halo: 'before:bg-[radial-gradient(circle_at_center,rgba(15,23,42,0.06),transparent_70%)]',
  },
  info: {
    ring: 'ring-sky-200/80',
    bg: 'bg-gradient-to-br from-sky-50 to-white',
    fg: 'text-sky-600',
    halo: 'before:bg-[radial-gradient(circle_at_center,rgba(56,189,248,0.18),transparent_70%)]',
  },
  success: {
    ring: 'ring-emerald-200/80',
    bg: 'bg-gradient-to-br from-emerald-50 to-white',
    fg: 'text-emerald-600',
    halo: 'before:bg-[radial-gradient(circle_at_center,rgba(16,185,129,0.18),transparent_70%)]',
  },
  danger: {
    ring: 'ring-rose-200/80',
    bg: 'bg-gradient-to-br from-rose-50 to-white',
    fg: 'text-rose-600',
    halo: 'before:bg-[radial-gradient(circle_at_center,rgba(244,63,94,0.18),transparent_70%)]',
  },
  warning: {
    ring: 'ring-amber-200/80',
    bg: 'bg-gradient-to-br from-amber-50 to-white',
    fg: 'text-amber-600',
    halo: 'before:bg-[radial-gradient(circle_at_center,rgba(245,158,11,0.18),transparent_70%)]',
  },
}

export function EmptyState({
  icon,
  title,
  description,
  action,
  tone = 'neutral',
  className,
}: {
  icon?: ReactNode
  title: string
  description?: ReactNode
  action?: ReactNode
  /** icon 圈调色 (默认中性灰); 用于回收站空态(neutral)、配置完成(success)、错误(danger) 等场景 */
  tone?: EmptyStateTone
  className?: string
}) {
  const palette = EMPTY_TONE_PALETTE[tone]
  return (
    <div className={clsx('flex min-h-[260px] flex-col items-center justify-center px-6 py-14 text-center', className)}>
      {icon && (
        <div
          className={clsx(
            'relative mb-5 grid h-16 w-16 place-items-center rounded-2xl ring-1 shadow-[0_1px_2px_rgba(15,23,42,0.04)]',
            // 软色 halo (radial gradient) 让 icon 区域有焦点
            'before:absolute before:inset-[-22px] before:rounded-full before:opacity-90 before:[z-index:-1]',
            palette.bg,
            palette.ring,
            palette.fg,
            palette.halo,
          )}
        >
          {/* icon size 由 caller 决定 (推荐 22-28px) */}
          {icon}
        </div>
      )}
      <div className="text-[16px] font-semibold tracking-[-0.005em] text-[var(--color-text)]">{title}</div>
      {description && (
        <div className="mt-2 max-w-xl text-[13px] leading-relaxed text-[var(--color-text-sub)]">
          {description}
        </div>
      )}
      {action && <div className="mt-6">{action}</div>}
    </div>
  )
}

/** 宽表格固定列 td 类（与 DataTable stickyFirstCol/stickyLastCol 配套；tr 必须带 `group`）。
 * 不透明背景遮住横向滚动内容；group-hover 与普通行 hover 视觉一致。 */
export const stickyLeftTdCls =
  'sticky left-0 z-[5] bg-white shadow-[inset_-1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]'
export const stickyRightTdCls =
  'sticky right-0 z-[5] bg-white shadow-[inset_1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]'

export function DataTable({
  headers,
  children,
  loading,
  empty,
  className,
  stickyFirstCol,
  stickyLastCol,
}: {
  headers: ReactNode[]
  children?: ReactNode
  loading?: ReactNode
  empty?: ReactNode
  className?: string
  /** 宽表格（列多需横向滚动）时固定首列；行内 td 配 stickyLeftTdCls。 */
  stickyFirstCol?: boolean
  /** 宽表格时固定「操作」末列；行内 td 配 stickyRightTdCls。 */
  stickyLastCol?: boolean
}) {
  const scrollX = stickyFirstCol || stickyLastCol
  const table = (
    <table className="w-full text-[13px]">
      <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
        <tr>
          {headers.map((header, index) => (
            <th
              key={index}
              className={clsx(
                'px-4 py-2.5 text-left font-semibold whitespace-nowrap',
                stickyFirstCol && index === 0 &&
                  'sticky left-0 z-10 bg-[var(--color-bg-sub)] shadow-[inset_-1px_0_0_var(--color-line-soft)]',
                stickyLastCol && index === headers.length - 1 &&
                  'sticky right-0 z-10 bg-[var(--color-bg-sub)] shadow-[inset_1px_0_0_var(--color-line-soft)]',
              )}
            >
              {header}
            </th>
          ))}
        </tr>
      </thead>
      <tbody className="divide-y divide-[var(--color-line-soft)]">
        {children}
      </tbody>
    </table>
  )
  return (
    <section className={clsx('overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[0_1px_0_rgba(23,23,23,0.02)]', className)}>
      {scrollX ? <div className="overflow-x-auto">{table}</div> : table}
      {loading}
      {empty}
    </section>
  )
}

export function Pagination({
  total,
  page,
  pageSize,
  onPageChange,
  onPageSizeChange,
  pageSizeOptions = [10, 20, 50],
}: {
  total: number
  page: number
  pageSize: number
  onPageChange: (page: number) => void
  onPageSizeChange: (pageSize: number) => void
  pageSizeOptions?: number[]
}) {
  if (total <= 0) return null
  const pageCount = Math.max(1, Math.ceil(total / pageSize))
  const safePage = Math.min(Math.max(page, 1), pageCount)
  const start = (safePage - 1) * pageSize + 1
  const end = Math.min(total, safePage * pageSize)
  return (
    <div className="mt-2 flex flex-wrap items-center justify-between gap-3 text-[12.5px] text-[var(--color-text-sub)]">
      <div>
        第 <span className="font-medium tabular-nums text-[var(--color-text)]">{start}-{end}</span> 条，
        共 <span className="font-medium tabular-nums text-[var(--color-text)]">{total}</span> 条
      </div>
      <div className="flex items-center gap-2">
        <span className="text-[var(--color-text-mute)]">每页</span>
        <div className="w-[92px]">
          <Select
            value={pageSize}
            onChange={(e) => onPageSizeChange(Number(e.target.value))}
          >
            {pageSizeOptions.map((size) => (
              <option key={size} value={size}>{size} 条</option>
            ))}
          </Select>
        </div>
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={safePage <= 1}
          onClick={() => onPageChange(1)}
          aria-label="首页"
          title="首页"
        >
          <ChevronsLeft size={14} />
        </Button>
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={safePage <= 1}
          onClick={() => onPageChange(safePage - 1)}
          aria-label="上一页"
          title="上一页"
        >
          <ChevronLeft size={14} />
        </Button>
        <span className="min-w-[64px] text-center tabular-nums text-[var(--color-text)]">
          {safePage} / {pageCount}
        </span>
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={safePage >= pageCount}
          onClick={() => onPageChange(safePage + 1)}
          aria-label="下一页"
          title="下一页"
        >
          <ChevronRight size={14} />
        </Button>
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={safePage >= pageCount}
          onClick={() => onPageChange(pageCount)}
          aria-label="尾页"
          title="尾页"
        >
          <ChevronsRight size={14} />
        </Button>
      </div>
    </div>
  )
}

export function InlineAlert({
  tone = 'danger',
  children,
}: {
  tone?: 'danger' | 'info' | 'warn' | 'success'
  children: ReactNode
}) {
  return (
    <div
      className={clsx(
        'rounded-md border px-3 py-2 text-[13px] leading-relaxed',
        tone === 'danger' && 'border-red-200 bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
        tone === 'info' && 'border-blue-200 bg-[var(--color-info-bg)] text-[var(--color-info)]',
        tone === 'warn' && 'border-amber-200 bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
        tone === 'success' && 'border-emerald-200 bg-[var(--color-success-bg)] text-[var(--color-success)]'
      )}
    >
      {children}
    </div>
  )
}

// ===========================================================================
// 统一列表页骨架：PageHeader + Toolbar + SearchInput + PrimaryButton + RowActions
// ---------------------------------------------------------------------------
// 设计目标：admin 所有 "管理类" 列表页（租户/技能/分类/服务/托管...）共享同一套
// 视觉规范，避免「每页一种主按钮文案、一种搜索框、一种行操作」的飘移。
//
// 用法：
//   <PageHeader title="租户管理" subtitle="..." actions={<PrimaryButton>新建租户</PrimaryButton>} />
//   <Toolbar
//     search={<SearchInput value={q} onChange={setQ} placeholder="搜索名称/ID" />}
//     filters={<><Select .../><Select .../></>}
//     summary={<>共 <b>{total}</b> 条</>}
//     actions={<PrimaryButton>新建XX</PrimaryButton>}
//   />
//   <RowActions onEdit={...} onDelete={...} />
//
// 文案规则：主按钮统一用 "新建XX"，不再混用 "创建/新增"。
// ===========================================================================

export function PageHeader({
  title,
  subtitle,
  actions,
  className,
}: {
  title: string
  subtitle?: ReactNode
  actions?: ReactNode
  className?: string
}) {
  return (
    <header className={clsx('mb-5 flex flex-wrap items-start justify-between gap-3', className)}>
      <div className="min-w-0">
        <h1 className="text-[28px] font-semibold leading-tight tracking-tight text-[var(--color-text)]">{title}</h1>
        {subtitle && (
          <p className="mt-1.5 max-w-4xl text-[13px] leading-relaxed text-[var(--color-text-sub)]">{subtitle}</p>
        )}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </header>
  )
}

export function Toolbar({
  search,
  filters,
  summary,
  actions,
  className,
}: {
  /** 左侧搜索框 slot：建议传 <SearchInput />，最大宽度 360。 */
  search?: ReactNode
  /** 中间筛选 slot：一个或多个 <Select>，每个外层 div 固定 w-[140px]~[180px]。 */
  filters?: ReactNode
  /** "共 N 条" 类灰字汇总，可选。 */
  summary?: ReactNode
  /** 右侧操作 slot：主按钮 + 可选 refresh ghost。 */
  actions?: ReactNode
  className?: string
}) {
  return (
    <div className={clsx('mb-3 flex flex-wrap items-center gap-3', className)}>
      {search && <div className="min-w-[260px] flex-1 max-w-[360px]">{search}</div>}
      {filters}
      {summary && (
        <div className="whitespace-nowrap text-[12.5px] text-[var(--color-text-sub)]">{summary}</div>
      )}
      {actions && <div className="ml-auto flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  )
}

export function SearchInput({
  value,
  onChange,
  placeholder = '搜索',
  className,
}: {
  value: string
  onChange: (v: string) => void
  placeholder?: string
  className?: string
}) {
  return (
    <div className={clsx('relative', className)}>
      <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
      <Input
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className="pl-9"
      />
    </div>
  )
}

/** 主按钮语义化壳：强制 + 图标 + "新建XX" 文案规范。 */
export function PrimaryButton({
  children,
  icon = <Plus size={14} strokeWidth={2.4} />,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { icon?: ReactNode }) {
  return (
    <Button {...rest}>
      {icon}
      {children}
    </Button>
  )
}

/**
 * 统一行操作。
 * - 默认 inline 模式：可见文字按钮平铺，删除一律使用危险色文字（不再红底+文字混搭）。
 * - extras 可在 编辑/删除 前插入自定义图标按钮（例如 "刷新连通性" / "设为默认"）。
 */
export function RowActions({
  onEdit,
  onDelete,
  editLabel = '编辑',
  deleteLabel = '删除',
  editDisabled,
  deleteDisabled,
  extras,
  className,
}: {
  onEdit?: () => void
  onDelete?: () => void
  editLabel?: string
  deleteLabel?: string
  editDisabled?: boolean
  deleteDisabled?: boolean
  /** 在编辑/删除前插入自定义操作，例如「管理」详情链接。 */
  extras?: ReactNode
  className?: string
}) {
  // 文字 + 颜色为主, 不带图标 — 用色彩做语义信号 (编辑=品牌蓝, 删除=危险红)。
  // 行操作密度高, 图标+文字会让一行变拥挤; 去图标后整列更整齐, hover 时背景色给反馈。
  //
  // -ml-3 (-12px) 把第一个按钮拉回去对齐列头:
  //   th 文字: cell 左缘 + cell px-4 (16px) = 16px
  //   button 文字: cell px-4 (16px) + button px-3 (12px) = 28px → 多出 12px
  //   给容器 -ml-3 抵消 button 自带的左内边距, 第一个按钮文字回到 16px。
  // 如果想右对齐, 在 className 传 "ml-auto justify-end"。
  // 注意: 不用 <Button variant="ghost">, 因为 ghost variant 自带 text-text-sub,
  // 与 className 里的 text-brand / text-danger 优先级冲突, Tailwind 编译顺序赢者通吃 →
  // 蓝/红色被吞。这里直接写裸 <button> 把语义色作为基础色, 绝对生效。
  const baseBtn =
    'inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium transition disabled:cursor-not-allowed disabled:opacity-60'
  return (
    <div className={clsx('-ml-3 flex items-center gap-1', className)}>
      {extras}
      {onEdit && (
        <button
          type="button"
          onClick={onEdit}
          disabled={editDisabled}
          title={editLabel}
          className={clsx(
            baseBtn,
            'text-[var(--color-brand)] hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]',
          )}
        >
          {editLabel}
        </button>
      )}
      {onDelete && (
        <button
          type="button"
          onClick={onDelete}
          disabled={deleteDisabled}
          title={deleteLabel}
          className={clsx(
            baseBtn,
            'text-[var(--color-danger)] hover:bg-red-50 hover:text-[var(--color-danger)]',
          )}
        >
          {deleteLabel}
        </button>
      )}
    </div>
  )
}

/**
 * 「更多操作」下拉菜单（抽屉底部操作区主次分离，2026-07-22 向导化）：
 * 主线下一步用唯一 primary 按钮，兜底/低频操作收进本菜单——操作员永远
 * 只需要认一个主按钮。菜单向上展开（通常位于抽屉 footer）。
 */
export function ActionMenu({ label = '更多操作', items }: {
  label?: string
  items: { key: string; label: string; danger?: boolean; onSelect: () => void }[]
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [open])
  if (!items.length) return null
  return (
    <div ref={ref} className="relative">
      <Button variant="secondary" size="sm" onClick={() => setOpen((v) => !v)}>
        {label}
        <ChevronDown size={13} className={clsx('ml-1 transition-transform', open && 'rotate-180')} />
      </Button>
      {open && (
        <div className="absolute bottom-full left-0 z-30 mb-1 min-w-[160px] rounded-md border border-[var(--color-line)] bg-[var(--color-bg)] py-1 shadow-lg">
          {items.map((it) => (
            <button
              key={it.key}
              type="button"
              className={clsx(
                'block w-full whitespace-nowrap px-3 py-1.5 text-left text-[13px] transition hover:bg-[var(--color-bg-sub)]',
                it.danger ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]',
              )}
              onClick={() => {
                setOpen(false)
                it.onSelect()
              }}
            >
              {it.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

/**
 * 受控 toggle 开关。
 * - onChange 返回 Promise 时, 会自动 disable 直到 promise 完成 (避免双击)。
 * - disabled 由外部强制锁住 (例如"默认项无法关闭"的业务规则)。
 * - 整个组件不带 label, 调用方负责把它放在格子里。
 */
export function Switch({
  checked,
  onChange,
  disabled,
  ariaLabel,
}: {
  checked: boolean
  onChange: (checked: boolean) => Promise<void> | void
  disabled?: boolean
  ariaLabel?: string
}) {
  const [busy, setBusy] = useState(false)
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      disabled={disabled || busy}
      onClick={async () => {
        setBusy(true)
        try {
          await onChange(!checked)
        } finally {
          setBusy(false)
        }
      }}
      className={clsx(
        'relative h-5 w-9 rounded-full transition disabled:cursor-not-allowed disabled:opacity-60',
        checked ? 'bg-[var(--color-success)]' : 'bg-[var(--color-line)]',
      )}
    >
      <span className={clsx('absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition', checked ? 'left-[18px]' : 'left-0.5')} />
    </button>
  )
}

export function BrandMark({ size = 'md' }: { size?: 'sm' | 'md' }) {
  return (
    <div className="flex items-center gap-2">
      <img
        src="/zhiban-logo.png"
        alt="知办AI logo"
        className={clsx('shrink-0 rounded-md object-cover shadow-[rgba(15,107,255,0.18)_0px_6px_16px]', size === 'md' ? 'h-8 w-8' : 'h-6 w-6')}
      />
      <div>
        <div className={clsx('font-semibold text-[var(--color-text)]', size === 'md' ? 'text-[15px]' : 'text-[14px]')}>知办AI Agent Bus</div>
        {size === 'md' && <div className="text-[12px] text-[var(--color-text-mute)]">Admin Console</div>}
      </div>
    </div>
  )
}

export type TrendChartSeriesDef = {
  key: string
  label: string
  /** CSS token 名（如 'var(--color-icon-blue)'），禁止裸 hex。 */
  color: string
}

export type TrendChartPoint = {
  label: string
  /** hover title；缺省用 label + 各系列值拼接。 */
  title?: string
  values: Record<string, number>
}

/**
 * TrendChart：无第三方依赖的堆叠柱状趋势图。
 * 用于「按时间桶 × 分类」的数值趋势（如用量统计的积分消耗）。
 * 只适合同单位可加总的数值（如积分）；不同单位的量不要堆在一张图里。
 */
export function TrendChart({
  points,
  series,
  height = 160,
  emptyText = '暂无趋势数据',
}: {
  points: TrendChartPoint[]
  series: TrendChartSeriesDef[]
  height?: number
  emptyText?: string
}) {
  const totals = points.map((p) => series.reduce((acc, s) => acc + (p.values[s.key] || 0), 0))
  const max = Math.max(...totals, 1)
  const hasData = points.length > 0 && totals.some((t) => t > 0)
  // x 轴标签最多展示 ~8 个，过密时抽稀。
  const labelStep = Math.max(1, Math.ceil(points.length / 8))

  if (!hasData) {
    return (
      <div className="grid place-items-center text-[12.5px] text-[var(--color-text-mute)]" style={{ height }}>
        {emptyText}
      </div>
    )
  }

  return (
    <div>
      <div className="flex items-end gap-[6px] border-b border-[var(--color-line-soft)] pb-px" style={{ height }}>
        {points.map((p, i) => {
          const total = totals[i]
          const title = p.title ?? [p.label, ...series.map((s) => `${s.label} ${p.values[s.key] || 0}`)].join(' · ')
          return (
            <div key={`${p.label}-${i}`} className="flex h-full min-w-0 flex-1 flex-col items-center justify-end" title={title}>
              <div
                className="flex w-full max-w-[44px] flex-col-reverse overflow-hidden rounded-t-[3px]"
                style={{ height: `${Math.max((total / max) * 100, total > 0 ? 2 : 0)}%` }}
              >
                {series.map((s) => {
                  const v = p.values[s.key] || 0
                  if (v <= 0 || total <= 0) return null
                  return <div key={s.key} style={{ height: `${(v / total) * 100}%`, backgroundColor: s.color }} />
                })}
              </div>
            </div>
          )
        })}
      </div>
      <div className="mt-1 flex gap-[6px]">
        {points.map((p, i) => (
          <div key={`${p.label}-${i}`} className="min-w-0 flex-1 truncate text-center text-[11px] tabular-nums text-[var(--color-text-mute)]">
            {i % labelStep === 0 ? p.label : ''}
          </div>
        ))}
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[12px] text-[var(--color-text-sub)]">
        {series.map((s) => (
          <span key={s.key} className="inline-flex items-center gap-1.5">
            <span className="h-2.5 w-2.5 rounded-[3px]" style={{ backgroundColor: s.color }} />
            {s.label}
          </span>
        ))}
        <span className="ml-auto tabular-nums text-[var(--color-text-mute)]">峰值 {max.toLocaleString()}</span>
      </div>
    </div>
  )
}

export function StackedTrendChart({
  points,
  series,
  height = 220,
  emptyText = '暂无趋势数据',
}: {
  points: TrendChartPoint[]
  series: TrendChartSeriesDef[]
  height?: number
  emptyText?: string
}) {
  const hasData = points.length > 0 && points.some((p) => series.some((s) => (p.values[s.key] || 0) > 0))

  if (!hasData) {
    return (
      <div className="grid place-items-center text-[12.5px] text-[var(--color-text-mute)]" style={{ height }}>
        {emptyText}
      </div>
    )
  }

  const data = points.map((p) => ({ label: p.label, title: p.title, ...p.values }))

  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} barCategoryGap={4}>
        <CartesianGrid vertical={false} stroke="var(--color-line-soft)" />
        <XAxis
          dataKey="label"
          tick={{ fontSize: 11, fill: 'var(--color-text-mute)' }}
          axisLine={{ stroke: 'var(--color-line-soft)' }}
          tickLine={false}
        />
        <YAxis
          allowDecimals={false}
          width={36}
          tick={{ fontSize: 11, fill: 'var(--color-text-mute)' }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip
          cursor={{ fill: 'var(--color-bg-sub)' }}
          contentStyle={{
            fontSize: 12,
            borderRadius: 8,
            border: '1px solid var(--color-line)',
            boxShadow: '0 4px 16px rgba(15,23,42,0.08)',
          }}
          labelStyle={{ color: 'var(--color-text)', fontWeight: 600, marginBottom: 4 }}
        />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        {series.map((s, i) => (
          <Bar
            key={s.key}
            dataKey={s.key}
            name={s.label}
            stackId="trend"
            fill={s.color}
            radius={i === series.length - 1 ? [3, 3, 0, 0] : undefined}
            maxBarSize={44}
          />
        ))}
      </BarChart>
    </ResponsiveContainer>
  )
}

type LineTrendRow = { label: string; title?: string; values: Record<string, number> }

function LineTrendTooltip({ active, payload, series }: TooltipContentProps & { series: TrendChartSeriesDef[] }) {
  if (!active || !payload?.length) return null
  const row = payload[0].payload as LineTrendRow
  return (
    <div
      style={{
        fontSize: 12,
        borderRadius: 8,
        border: '1px solid var(--color-line)',
        background: 'white',
        padding: '8px 10px',
        boxShadow: '0 4px 16px rgba(15,23,42,0.08)',
      }}
    >
      <div style={{ fontWeight: 600, color: 'var(--color-text)', marginBottom: 4 }}>{row.label}</div>
      {series.map((s) => (
        <div key={s.key} style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--color-text-sub)' }}>
          <span style={{ width: 8, height: 8, borderRadius: 2, background: s.color, display: 'inline-block' }} />
          {s.label} {row.values[s.key] ?? 0}
        </div>
      ))}
      {row.title && <div style={{ marginTop: 4, color: 'var(--color-text-mute)' }}>{row.title}</div>}
    </div>
  )
}

export function LineTrendChart({
  points,
  series,
  height = 220,
  emptyText = '暂无趋势数据',
}: {
  points: TrendChartPoint[]
  series: TrendChartSeriesDef[]
  height?: number
  emptyText?: string
}) {
  const hasData = points.length > 0 && points.some((p) => series.some((s) => (p.values[s.key] || 0) > 0))

  if (!hasData) {
    return (
      <div className="grid place-items-center text-[12.5px] text-[var(--color-text-mute)]" style={{ height }}>
        {emptyText}
      </div>
    )
  }

  const data: LineTrendRow[] = points.map((p) => ({ label: p.label, title: p.title, values: p.values }))

  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data}>
        <CartesianGrid vertical={false} stroke="var(--color-line-soft)" />
        <XAxis
          dataKey="label"
          tick={{ fontSize: 11, fill: 'var(--color-text-mute)' }}
          axisLine={{ stroke: 'var(--color-line-soft)' }}
          tickLine={false}
          minTickGap={24}
        />
        <YAxis
          allowDecimals={false}
          width={36}
          tick={{ fontSize: 11, fill: 'var(--color-text-mute)' }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip content={(props) => <LineTrendTooltip {...props} series={series} />} />
        {series.length > 1 && <Legend wrapperStyle={{ fontSize: 12 }} />}
        {series.map((s) => (
          <Line
            key={s.key}
            type="monotone"
            dataKey={(row: LineTrendRow) => row.values[s.key] ?? 0}
            name={s.label}
            stroke={s.color}
            strokeWidth={2.5}
            dot={{ r: 3, fill: 'white', stroke: s.color, strokeWidth: 2 }}
            activeDot={{ r: 5 }}
          />
        ))}
      </LineChart>
    </ResponsiveContainer>
  )
}
