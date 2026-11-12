export function secretRefToDisplay(
  ref?: string,
): { display: string; isEnvRef: boolean; hasHiddenRef: boolean } {
  if (!ref) return { display: '', isEnvRef: false, hasHiddenRef: false }
  if (ref.startsWith('value://')) {
    return { display: ref.slice('value://'.length), isEnvRef: false, hasHiddenRef: false }
  }
  if (ref.startsWith('env://')) {
    return { display: '', isEnvRef: true, hasHiddenRef: true }
  }
  return { display: ref, isEnvRef: false, hasHiddenRef: false }
}

export function secretValueToRef(input: string): string {
  const v = input.trim()
  if (!v) return ''
  if (v.startsWith('value://')) return v
  if (v.startsWith('env://')) return `value://${v.slice('env://'.length)}`
  return `value://${v}`
}
