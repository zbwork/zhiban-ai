import { AnsiLogDecoder, type AnsiSpan } from './ansi-log.ts'
export type BuildLog = { stream: string; message: string; created_at?: string }

export type BuildLogGroup = {
  /** The starting line stays stable when a polling response appends logs. */
  startLine: number
  compression: boolean
  time: string
  lines: string[]
  styledLines: AnsiSpan[][]
}

function formatLogTime(value?: string): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `[${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}] `
}

/** Only group Inno Setup's per-file stdout messages, never stderr. */
export function groupBuildLogs(logs: readonly BuildLog[]): BuildLogGroup[] {
  const groups: BuildLogGroup[] = []
  let lineIndex = 0
  const decoders = new Map<string, AnsiLogDecoder>()
  for (const log of logs) {
    const time = formatLogTime(log.created_at)
    const decoder = decoders.get(log.stream) ?? new AnsiLogDecoder()
    decoders.set(log.stream, decoder)
    for (const rawLine of log.message.split(/\r?\n/)) {
      const spans = decoder.read(rawLine)
      const line = spans.map((span) => span.text).join('')
      const compression = log.stream === 'stdout' && /^\s*Compressing:\s+.+$/.test(line)
      let group = groups[groups.length - 1]
      if (!group || group.compression !== compression) {
        group = { startLine: lineIndex, compression, time, lines: [], styledLines: [] }
        groups.push(group)
      }
      group.styledLines.push([{ text: `${time}[${log.stream}] `, style: {} }, ...spans])
      group.lines.push(`${time}[${log.stream}] ${line}`)
      lineIndex++
    }
  }
  return groups
}

export function formatBuildLogs(logs: readonly BuildLog[]): string {
  return groupBuildLogs(logs).flatMap((group) => group.lines).join('\n')
}
