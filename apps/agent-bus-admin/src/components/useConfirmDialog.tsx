import { useState, type ReactNode } from 'react'
import { ConfirmDialog } from './ui'

export function useConfirmDialog() {
  const [state, setState] = useState<{
    title: string
    description?: ReactNode
    confirmLabel?: string
    tone?: 'danger' | 'warn' | 'info'
    resolve: (ok: boolean) => void
  } | null>(null)

  const confirm = (options: {
    title: string
    description?: ReactNode
    confirmLabel?: string
    tone?: 'danger' | 'warn' | 'info'
  }) => new Promise<boolean>((resolve) => {
    setState({ ...options, resolve })
  })

  const dialog = state ? (
    <ConfirmDialog
      title={state.title}
      description={state.description}
      confirmLabel={state.confirmLabel || '确认'}
      busyLabel="处理中..."
      tone={state.tone || 'danger'}
      onClose={() => {
        state.resolve(false)
        setState(null)
      }}
      onConfirm={() => {
        state.resolve(true)
        setState(null)
      }}
    />
  ) : null

  return { confirm, dialog }
}
