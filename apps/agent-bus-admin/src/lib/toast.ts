export type ToastKind = 'error' | 'success' | 'info'

export type ToastPayload = {
  kind?: ToastKind
  message: string
  durationMs?: number
}

export const TOAST_EVENT = 'zhiban:toast'

export function notifyToast(payload: ToastPayload) {
  if (!payload.message.trim()) return
  window.dispatchEvent(new CustomEvent<ToastPayload>(TOAST_EVENT, {
    detail: {
      kind: 'error',
      durationMs: 3000,
      ...payload,
    },
  }))
}

export function notifyError(message: string, durationMs = 3000) {
  notifyToast({ kind: 'error', message, durationMs })
}

/** 成功提示。绿色背景，2 秒后消失。 */
export function notifyOk(message: string, durationMs = 2000) {
  notifyToast({ kind: 'success', message, durationMs })
}

/** 中性信息提示。 */
export function notifyInfo(message: string, durationMs = 2500) {
  notifyToast({ kind: 'info', message, durationMs })
}

export function subscribeToast(handler: (payload: Required<ToastPayload>) => void) {
  const listener = (event: Event) => {
    const detail = (event as CustomEvent<ToastPayload>).detail
    if (!detail?.message) return
    handler({
      kind: detail.kind || 'error',
      message: detail.message,
      durationMs: detail.durationMs || 3000,
    })
  }
  window.addEventListener(TOAST_EVENT, listener)
  return () => window.removeEventListener(TOAST_EVENT, listener)
}
