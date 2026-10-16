// 全局 mutating 请求 loading 计数。
// 用法：api.ts 在非 GET 请求前后调用 beginLoading / endLoading；
// <GlobalLoading /> 订阅计数并渲染居中遮罩。
//
// 设计要点：
// - 计数器允许并发 mutation 共用一层遮罩，先来后到都覆盖。
// - 通过 window 事件解耦，和 toast.ts 风格保持一致。
// - 上层不需要任何 per-button loading 状态，开关/保存/发布按钮无需改动。

export const LOADING_EVENT = 'zhiban:loading'

let count = 0

export function beginLoading() {
  count++
  window.dispatchEvent(new CustomEvent<number>(LOADING_EVENT, { detail: count }))
}

export function endLoading() {
  if (count > 0) count--
  window.dispatchEvent(new CustomEvent<number>(LOADING_EVENT, { detail: count }))
}

export function getLoadingCount() {
  return count
}

export function subscribeLoading(handler: (n: number) => void) {
  const listener = (event: Event) => {
    handler((event as CustomEvent<number>).detail ?? 0)
  }
  window.addEventListener(LOADING_EVENT, listener)
  return () => window.removeEventListener(LOADING_EVENT, listener)
}
