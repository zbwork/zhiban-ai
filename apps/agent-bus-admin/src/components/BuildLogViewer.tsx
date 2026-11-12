import { useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import { groupBuildLogs, type BuildLog, type BuildLogGroup } from '../lib/build-log-display'
import type { AnsiSpan } from '../lib/ansi-log'
import { Button } from './ui'

function ColoredLines({ lines }: { lines: AnsiSpan[][] }) {
  return <pre className="m-0">{lines.map((line, i) => <span key={i}>
    {i > 0 ? '\n' : ''}{line.map((part, j) => <span key={j} style={part.style}>{part.text}</span>)}
  </span>)}</pre>
}

function CompressionGroup({ group, onToggle }: { group: BuildLogGroup; onToggle: () => void }) {
  const [expanded, setExpanded] = useState(false)
  const contentId = useId()
  return <div>
    <div className="sticky top-0 flex flex-wrap items-center gap-x-2 bg-[var(--color-surface)]">
      <span>{group.time}[stdout] {expanded ? '已展开' : '已折叠'} {group.lines.length} 条文件压缩日志</span>
      <Button type="button" variant="ghost" size="sm"
        aria-expanded={expanded} aria-controls={contentId}
        onClick={() => { onToggle(); setExpanded((current) => !current) }}>
        {expanded ? <ChevronDown size={14} aria-hidden="true" /> : <ChevronRight size={14} aria-hidden="true" />}
        {expanded ? '收起日志' : '显示完整日志'}
      </Button>
    </div>
    <div id={contentId} hidden={!expanded}>
      {expanded && <ColoredLines lines={group.styledLines} />}
    </div>
  </div>
}

/** Key by task UUID so a different task starts with every group collapsed. */
export function BuildLogViewer({ logs }: { logs: readonly BuildLog[] }) {
  const [showFullLogs, setShowFullLogs] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const followTail = useRef(true)
  const contentId = useId()
  const groups = useMemo(() => groupBuildLogs(logs), [logs])

  useLayoutEffect(() => {
    const container = containerRef.current
    if (container && followTail.current) container.scrollTop = container.scrollHeight
  }, [logs])

  return <>
    <div className="mb-2 flex items-center justify-between gap-2">
      <span className="text-xs text-[var(--color-text-mute)]">后台接收时间 · 本地时区 · 原始日志颜色</span>
      <Button type="button" variant="secondary" size="sm" aria-pressed={showFullLogs}
        aria-controls={contentId} onClick={() => { followTail.current = false; setShowFullLogs((current) => !current) }}>
        {showFullLogs ? '精简日志' : '显示完整日志'}
      </Button>
    </div>
    <div id={contentId} ref={containerRef}
      onScroll={(event) => {
        const container = event.currentTarget
        followTail.current = container.scrollHeight - container.scrollTop - container.clientHeight < 24
      }}
      className="max-h-[360px] overflow-auto py-2 font-mono text-[12px] leading-5 text-[var(--color-text-sub)]">
      {!logs.length ? '等待构建日志...' : groups.map((group) =>
        group.compression && !showFullLogs
          ? <CompressionGroup key={group.startLine} group={group} onToggle={() => { followTail.current = false }} />
          : <ColoredLines key={group.startLine} lines={group.styledLines} />,
      )}
    </div>
  </>
}
