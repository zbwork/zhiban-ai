// crypto.randomUUID() 只在安全上下文(HTTPS / localhost)可用；测试/内网环境
// 走明文 HTTP + 非 localhost 域名时它是 undefined,直接调用会
// "crypto.randomUUID is not a function"。统一走本函数,非安全上下文回落到
// crypto.getRandomValues 拼 RFC4122 v4;再退化到 Math.random(幂等 key 用途,
// 不需要密码学强度)。
export function randomUUID(): string {
  const c = typeof crypto !== 'undefined' ? crypto : undefined
  if (c && typeof c.randomUUID === 'function') {
    return c.randomUUID()
  }
  if (c && typeof c.getRandomValues === 'function') {
    const b = new Uint8Array(16)
    c.getRandomValues(b)
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    const h = Array.from(b, (x) => x.toString(16).padStart(2, '0'))
    return `${h[0]}${h[1]}${h[2]}${h[3]}-${h[4]}${h[5]}-${h[6]}${h[7]}-${h[8]}${h[9]}-${h[10]}${h[11]}${h[12]}${h[13]}${h[14]}${h[15]}`
  }
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}-${Math.random().toString(36).slice(2, 10)}`
}
