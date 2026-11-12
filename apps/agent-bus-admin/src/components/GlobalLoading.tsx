import { useEffect, useState } from 'react'
import { subscribeLoading, getLoadingCount } from '../lib/loading'

// 全局 mutating 请求遮罩 · v4 (ambient indicator)。
//
// 设计转向: 不再用 pill 卡片 (太像按钮)。改为 viewport 正中的"环+文字"裸组合, 配合
// 更浓的 frosted glass 背景, 让 spinner 像悬浮在玻璃中, 而不是悬浮按钮被点亮。
//
// 1. 背景: 50% 白 + 8px blur, 营造毛玻璃景深, 不刺眼又有存在感。
// 2. Spinner: 36px conic-gradient sweep arc; 比 v3 (22px) 更大, 一眼就知道是在转。
// 3. 文字: 13px medium tint (text-sub), 不夺主, 副信息感。
// 4. 不要卡片 / 不要 shadow / 不要 border → 不再像 "loading 按钮"。
// 5. 入场: fade 220ms + spinner scale-in, 没有 pop, 更克制。
//
// 显示延迟 120ms 不变, 避免秒回闪烁。

const SHOW_DELAY_MS = 120

export function GlobalLoading() {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    let timer: number | null = null
    const apply = (n: number) => {
      if (n > 0) {
        if (timer == null && !visible) {
          timer = window.setTimeout(() => {
            timer = null
            setVisible(true)
          }, SHOW_DELAY_MS)
        }
      } else {
        if (timer != null) {
          window.clearTimeout(timer)
          timer = null
        }
        setVisible(false)
      }
    }
    apply(getLoadingCount())
    const off = subscribeLoading(apply)
    return () => {
      off()
      if (timer != null) window.clearTimeout(timer)
    }
  }, [visible])

  if (!visible) return null

  return (
    <div
      className="fixed inset-0 z-[1100] grid place-items-center bg-white/50 backdrop-blur-[8px] animate-[gl-fade_220ms_ease-out]"
      role="status"
      aria-live="polite"
      aria-busy="true"
      onClickCapture={(e) => { e.stopPropagation(); e.preventDefault() }}
      onKeyDownCapture={(e) => { e.stopPropagation(); e.preventDefault() }}
    >
      <style>{`
        @keyframes gl-fade { from { opacity: 0 } to { opacity: 1 } }
        @keyframes gl-spin { to { transform: rotate(360deg) } }
        @keyframes gl-scale-in {
          from { opacity: 0; transform: scale(0.86); }
          to   { opacity: 1; transform: scale(1); }
        }

        .gl-wrap {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 16px;
          animation: gl-scale-in 280ms cubic-bezier(0.16, 1, 0.3, 1);
        }

        .gl-spinner {
          width: 36px;
          height: 36px;
          border-radius: 50%;
          /* conic-gradient sweep arc · 主品牌色, 用 mask 抠出 3px 粗环 */
          background: conic-gradient(
            from 0deg,
            color-mix(in srgb, var(--color-brand) 0%, transparent),
            color-mix(in srgb, var(--color-brand) 100%, transparent) 300deg,
            color-mix(in srgb, var(--color-brand) 100%, transparent) 360deg
          );
          -webkit-mask: radial-gradient(circle, transparent 14px, #000 14.5px);
                  mask: radial-gradient(circle, transparent 14px, #000 14.5px);
          animation: gl-spin 800ms linear infinite;
        }

        .gl-text {
          font-size: 13px;
          font-weight: 500;
          letter-spacing: 0.02em;
          color: var(--color-text-sub);
        }
      `}</style>

      <div className="gl-wrap">
        <span className="gl-spinner" aria-hidden="true" />
        <span className="gl-text">处理中</span>
      </div>
    </div>
  )
}
