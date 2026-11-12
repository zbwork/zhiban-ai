// LabelMultiSelect — 标签多选公共组件。
//
// 设计依据：docs/standards/admin-web-component-reuse.md R1（同字段 = 同控件）。
// 调用方：apps/agent-bus-admin/src/pages/PlatformSkills.tsx 的 create / edit 抽屉。
// 后续如有租户技能 / 数字员工技能装配等需要选标签的页面，全部改走本组件，
// 不要在页面里重新实现 chip 切换或下拉选择。
//
// Props 契约（见 R4）：
//   - labels：从调用方注入的标签字典；组件不自己 fetch。
//   - value：已选 label_id 数组。
//   - onChange：派发新数组（number[]）。
//   - disabled：禁用所有交互。
//   - emptyHint：当 labels 为空时展示的中文提示，默认走"暂无可选标签"。

import type { SkillLabel } from '../../lib/api'

export type LabelMultiSelectProps = {
  labels: SkillLabel[]
  value: number[]
  onChange: (next: number[]) => void
  disabled?: boolean
  emptyHint?: string
}

export function LabelMultiSelect({
  labels,
  value,
  onChange,
  disabled,
  emptyHint = '暂无可选标签',
}: LabelMultiSelectProps) {
  const visible = labels.filter((l) => l.status !== 'archived')
  if (visible.length === 0) {
    return (
      <div className="rounded-md border border-dashed border-[var(--color-line)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
        {emptyHint}
      </div>
    )
  }
  const toggle = (id: number) => {
    if (disabled) return
    onChange(value.includes(id) ? value.filter((x) => x !== id) : [...value, id])
  }
  return (
    <div className="flex flex-wrap gap-2">
      {visible.map((l) => {
        const active = value.includes(l.id)
        return (
          <button
            type="button"
            key={l.id}
            onClick={() => toggle(l.id)}
            disabled={disabled}
            className={`rounded-full border px-3 py-1 text-[12px] transition disabled:cursor-not-allowed disabled:opacity-50 ${
              active
                ? 'border-[var(--color-brand)] bg-[var(--color-brand-bg)] text-[var(--color-brand)]'
                : 'border-[var(--color-line)] bg-[var(--color-control-bg)] text-[var(--color-text-sub)] hover:border-[var(--color-text-sub)]'
            }`}
          >
            {l.name}
          </button>
        )
      })}
    </div>
  )
}
