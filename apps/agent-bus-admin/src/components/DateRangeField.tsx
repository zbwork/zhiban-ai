import { Input } from './ui'

export function DateRangeField({
  start,
  end,
  onChange,
}: {
  start: string
  end: string
  onChange: (start: string, end: string) => void
}) {
  return (
    <div className="flex items-center gap-1.5">
      <Input
        type="date"
        value={start}
        max={end || undefined}
        onChange={(e) => onChange(e.target.value, end)}
        className="w-[140px]"
      />
      <span className="text-[12.5px] text-[var(--color-text-mute)]">至</span>
      <Input
        type="date"
        value={end}
        min={start || undefined}
        onChange={(e) => onChange(start, e.target.value)}
        className="w-[140px]"
      />
    </div>
  )
}
