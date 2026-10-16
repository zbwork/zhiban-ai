import { useEffect, useRef, useState } from 'react'
import { CheckCircle2, Info, XCircle } from 'lucide-react'
import { subscribeToast, type ToastPayload } from '../lib/toast'

type ActiveToast = Required<ToastPayload> & { id: number }

// 全局 toast 浮层。
// - 顶部正中, 通过 .global-api-toast (index.css) 做 fixed + flex 居中。
// - 三态语义色:
//     error   红 + XCircle
//     success 绿 + CheckCircle2
//     info    品牌蓝 + Info
// - 视觉: 浅色 tint 背景 + 同色调描边 + 文字主色, 不是塞满色块的廉价 toast。
//   左侧加一根 3px 同色实条作为 accent rail (editorial 风格强调)。
// - 入场动画在 CSS 类里; 切换 toast 时 React 重渲, key=id 触发动画重放。

type ToastKind = 'error' | 'success' | 'info'

const KIND_STYLE: Record<ToastKind, {
  rail: string
  bg: string
  border: string
  text: string
  iconBg: string
  iconColor: string
}> = {
  error: {
    rail: 'bg-[var(--color-danger)]',
    bg: 'bg-red-50/95',
    border: 'border-red-200/80',
    text: 'text-[var(--color-danger)]',
    iconBg: 'bg-red-100/80',
    iconColor: 'text-[var(--color-danger)]',
  },
  success: {
    rail: 'bg-[var(--color-success)]',
    bg: 'bg-emerald-50/95',
    border: 'border-emerald-200/80',
    text: 'text-[var(--color-success)]',
    iconBg: 'bg-emerald-100/80',
    iconColor: 'text-[var(--color-success)]',
  },
  info: {
    rail: 'bg-[var(--color-brand)]',
    bg: 'bg-blue-50/95',
    border: 'border-[var(--color-brand-line)]',
    text: 'text-[var(--color-brand)]',
    iconBg: 'bg-[var(--color-brand-soft)]',
    iconColor: 'text-[var(--color-brand)]',
  },
}

const KIND_ICON = {
  error: XCircle,
  success: CheckCircle2,
  info: Info,
} as const

export function GlobalToast() {
  const [toast, setToast] = useState<ActiveToast | null>(null)
  const timerRef = useRef<number | null>(null)

  useEffect(() => {
    return subscribeToast((payload) => {
      if (timerRef.current) window.clearTimeout(timerRef.current)
      setToast({ ...payload, id: Date.now() })
      timerRef.current = window.setTimeout(() => {
        setToast(null)
        timerRef.current = null
      }, payload.durationMs)
    })
  }, [])

  useEffect(() => {
    return () => {
      if (timerRef.current) window.clearTimeout(timerRef.current)
    }
  }, [])

  if (!toast) return null

  const kind = (toast.kind as ToastKind) || 'error'
  const style = KIND_STYLE[kind]
  const Icon = KIND_ICON[kind]

  return (
    <div className="global-api-toast pointer-events-none z-[1000]" role="alert" aria-live="assertive" key={toast.id}>
      <div
        className={[
          'pointer-events-auto relative inline-flex items-center gap-3 overflow-hidden',
          'rounded-xl border pl-4 pr-5 py-2.5',
          'shadow-[0_18px_44px_-12px_rgba(15,23,42,0.22),0_2px_6px_-2px_rgba(15,23,42,0.08)]',
          'backdrop-blur-sm',
          style.bg,
          style.border,
          style.text,
        ].join(' ')}
      >
        {/* 左侧 accent rail · 同色调实条, 强化语义且让 toast 不会被误读成中性提示 */}
        <span className={`absolute inset-y-0 left-0 w-[3px] ${style.rail}`} aria-hidden="true" />
        {/* 图标圆形 tinted 背景, 比纯色描边更精致 */}
        <span className={`grid h-7 w-7 shrink-0 place-items-center rounded-full ${style.iconBg}`}>
          <Icon size={15} className={style.iconColor} strokeWidth={2.5} />
        </span>
        <span className="text-[14px] font-medium leading-5 tracking-[0.01em]">{toast.message}</span>
      </div>
    </div>
  )
}
