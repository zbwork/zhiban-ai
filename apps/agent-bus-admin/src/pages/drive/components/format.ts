// 字节展示 helper, 与旧 DriveBrowse 同实现; -1 表示无限 quota.
export function fmtBytes(n?: number | null): string {
  if (n === undefined || n === null) return '—'
  if (n === -1) return '无限制'
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB'
  if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB'
  if (n < 1024 * 1024 * 1024 * 1024) return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB'
  return (n / 1024 / 1024 / 1024 / 1024).toFixed(2) + ' TB'
}
