/** Streaming SGR decoder. Escape commands are data, never HTML or links. */
export type AnsiStyle = {
  color?: string; backgroundColor?: string; fontWeight?: 'bold'
  fontStyle?: 'italic'; textDecoration?: 'underline'
}
export type AnsiSpan = { text: string; style: AnsiStyle }
const esc = '\u001b'
function indexedColor(n: number): string {
  if (n < 16) return `var(--color-ansi-${n})`
  if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v}, ${v}, ${v})` }
  const v = n - 16
  const levels = [0, 95, 135, 175, 215, 255]
  return `rgb(${levels[Math.floor(v / 36)]}, ${levels[Math.floor(v / 6) % 6]}, ${levels[v % 6]})`
}
export class AnsiLogDecoder {
  private style: AnsiStyle = {}
  private pending = ''
  read(input: string): AnsiSpan[] {
    const text = this.pending + input
    this.pending = ''
    const spans: AnsiSpan[] = []
    const emit = (value: string) => {
      // Keep tabs; remove terminal controls, including CR/backspace/BEL.
      // eslint-disable-next-line no-control-regex -- deliberately strip terminal control bytes
      const safe = value.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
      if (safe) spans.push({ text: safe, style: { ...this.style } })
    }
    let i = 0
    while (i < text.length) {
      if (text[i] !== esc) {
        const end = text.indexOf(esc, i)
        emit(text.slice(i, end < 0 ? text.length : end))
        i = end < 0 ? text.length : end
        continue
      }
      const start = i++
      if (i === text.length) { this.pending = text.slice(start); break }
      if (text[i] === '[') {
        i++
        const params = i
        while (i < text.length && !/[@-~]/.test(text[i])) i++
        if (i === text.length) {
          this.pending = text.slice(start).slice(0, 4096); break
        }
        if (text[i] === 'm') this.sgr(text.slice(params, i))
        i++
      } else if (']PX^_'.includes(text[i])) {
        // OSC/DCS/APC strings terminate with ST, OSC also allows BEL.
        const osc = text[i] === ']'
        i++
        while (i < text.length && !(osc && text[i] === '\u0007') &&
          !(text[i] === esc && text[i + 1] === '\\')) i++
        if (i === text.length) { this.pending = text.slice(start).slice(0, 4096); break }
        i += text[i] === esc ? 2 : 1
      } else { i++ }
    }
    return spans
  }
  private sgr(params: string) {
    if (!/^[\d;]*$/.test(params)) return
    const codes = params.split(';').map((s) => Number(s || '0'))
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i]
      if (c === 0) this.style = {}
      else if (c === 1) this.style.fontWeight = 'bold'
      else if (c === 22) delete this.style.fontWeight
      else if (c === 3) this.style.fontStyle = 'italic'
      else if (c === 23) delete this.style.fontStyle
      else if (c === 4) this.style.textDecoration = 'underline'
      else if (c === 24) delete this.style.textDecoration
      else if (c === 39) delete this.style.color
      else if (c === 49) delete this.style.backgroundColor
      else if (c >= 30 && c <= 37) this.style.color = indexedColor(c - 30)
      else if (c >= 90 && c <= 97) this.style.color = indexedColor(c - 90 + 8)
      else if (c >= 40 && c <= 47) this.style.backgroundColor = indexedColor(c - 40)
      else if (c >= 100 && c <= 107) this.style.backgroundColor = indexedColor(c - 100 + 8)
      else if (c === 38 || c === 48) {
        const key = c === 38 ? 'color' : 'backgroundColor'
        const mode = codes[++i]
        const count = mode === 5 ? 1 : mode === 2 ? 3 : 0
        if (!count) break
        const values = codes.slice(i + 1, i + 1 + count)
        if (values.length === count && values.every((v) => Number.isInteger(v) && v >= 0 && v <= 255)) {
          this.style[key] = mode === 5 ? indexedColor(values[0]) : `rgb(${values.join(', ')})`
        }
        i += count
      }
    }
  }
}
