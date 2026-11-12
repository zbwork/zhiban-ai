import type { CSSProperties, ReactNode } from 'react'
import { ArrowLeft, ChevronLeft, ChevronRight } from 'lucide-react'
import { Button, InlineAlert, PageHeader, Panel } from '../ui'

export type AgentEditorStep<T extends string> = {
  value: T
  label: string
  description: string
}

export function AgentEditorShell<T extends string>({
  title,
  subtitle,
  actions,
  backAction,
  finalActions,
  tab,
  steps,
  onTabChange,
  notice,
  error,
  lockedWarning,
  children,
}: {
  title: string
  subtitle: string
  actions?: ReactNode
  backAction?: {
    label: string
    onClick: () => void
  }
  finalActions?: ReactNode
  tab: T
  steps: Array<AgentEditorStep<T>>
  onTabChange: (value: T) => void
  notice?: string
  error?: string
  lockedWarning?: string
  children: ReactNode
}) {
  const currentIndex = Math.max(0, steps.findIndex((step) => step.value === tab))
  const previousStep = currentIndex > 0 ? steps[currentIndex - 1] : null
  const nextStep = currentIndex < steps.length - 1 ? steps[currentIndex + 1] : null

  return (
    <div className="pb-8">
      {backAction && (
        <Button
          type="button"
          variant="ghost"
          onClick={backAction.onClick}
          className="-ml-2 mb-2"
        >
          <ArrowLeft size={14} />
          {backAction.label}
        </Button>
      )}
      <PageHeader
        title={title}
        subtitle={subtitle}
        className="mb-6"
        actions={actions}
      />

      <StepTabs value={tab} items={steps} onChange={onTabChange} />

      <Panel className="mt-4 p-5 md:p-6">
        {notice && <div className="mb-4 text-right text-[12px] text-[var(--color-success)]">{notice}</div>}
        {error && <div className="mb-4"><InlineAlert>{error}</InlineAlert></div>}
        {lockedWarning && (
          <div className="mb-4">
            <InlineAlert tone="warn">{lockedWarning}</InlineAlert>
          </div>
        )}
        {children}
        {steps.length > 1 && (
          <div className="mt-6 flex flex-col gap-3 border-t border-[var(--color-line)] pt-4 sm:flex-row sm:items-center sm:justify-between">
            <Button
              type="button"
              variant="secondary"
              onClick={() => previousStep && onTabChange(previousStep.value)}
              disabled={!previousStep}
              className="sm:min-w-[96px]"
            >
              <ChevronLeft size={14} />
              上一步
            </Button>
            <span className="text-center text-[12px] text-[var(--color-text-mute)]">
              第 <span className="tabular-nums">{currentIndex + 1}</span> / <span className="tabular-nums">{steps.length}</span> 步
            </span>
            {nextStep ? (
              <Button
                type="button"
                onClick={() => onTabChange(nextStep.value)}
                className="sm:min-w-[96px]"
              >
                下一步
                <ChevronRight size={14} />
              </Button>
            ) : finalActions ? (
              <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-end">
                {finalActions}
              </div>
            ) : (
              <Button type="button" disabled className="sm:min-w-[96px]">
                下一步
                <ChevronRight size={14} />
              </Button>
            )}
          </div>
        )}
      </Panel>
    </div>
  )
}

function StepTabs<T extends string>({
  value,
  items,
  onChange,
}: {
  value: T
  items: Array<AgentEditorStep<T>>
  onChange: (value: T) => void
}) {
  return (
    <nav className="overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[0_10px_28px_rgba(15,23,42,0.06)]">
      <div
        className="grid grid-cols-1 md:[grid-template-columns:repeat(var(--step-count),minmax(0,1fr))]"
        style={{ '--step-count': items.length } as CSSProperties}
      >
        {items.map((item, idx) => {
          const active = value === item.value
          return (
            <button
              key={item.value}
              type="button"
              onClick={() => onChange(item.value)}
              className={`relative flex min-h-[88px] items-center gap-3 px-6 text-left transition ${
                active
                  ? 'bg-[var(--color-brand-soft)] shadow-[inset_0_0_0_1px_var(--color-brand-line)]'
                  : 'bg-white hover:bg-[var(--color-bg-sub)]'
              }`}
            >
              {idx > 0 && <span className="absolute left-0 top-1/2 hidden h-8 -translate-y-1/2 border-l border-dashed border-[var(--color-line)] md:block" />}
              <span
                className={`grid h-9 w-9 shrink-0 place-items-center rounded-full border text-[14px] font-semibold ${
                  active
                    ? 'border-[var(--color-brand)] bg-[var(--color-brand)] text-white shadow-[0_8px_18px_rgba(15,107,255,0.28)]'
                    : 'border-[var(--color-line)] bg-white text-[var(--color-text-sub)]'
                }`}
              >
                {idx + 1}
              </span>
              <span className="min-w-0">
                <span className={`block text-[14px] font-semibold ${active ? 'text-[var(--color-brand)]' : 'text-[var(--color-text)]'}`}>
                  {item.label}
                </span>
                <span className="mt-1 block truncate text-[12px] text-[var(--color-text-sub)]">{item.description}</span>
              </span>
            </button>
          )
        })}
      </div>
    </nav>
  )
}
