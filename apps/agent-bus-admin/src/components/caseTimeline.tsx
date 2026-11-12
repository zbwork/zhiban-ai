// 创业助手运营台共用小件（企业注册申请 / 代理记账工单两页共享）：
// 状态徽标 tone、Badge、原型式时间线条目（图标节点 + 竖连线 + 语义标签 +
// 时间·操作人副行）、两列 label/value 信息行。视觉全部走 --color-* token。
import type { ReactNode } from 'react'
import { AlertTriangle, Bell, NotebookPen, StickyNote, UserRound, Zap } from 'lucide-react'

import { CASE_TONE } from './caseTone'

export function CaseBadge({ children, className = '', title }: {
  children: ReactNode
  className?: string
  title?: string
}) {
  return (
    <span
      title={title}
      className={`inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-[12px] font-medium ${className}`}
    >
      {children}
    </span>
  )
}

// 原型式信息行：label 在上、值在下，两列排版；值为空整行不渲染。
export function CaseField({ label, value, span = false }: {
  label: string
  value: string
  span?: boolean
}) {
  if (!value) return null
  return (
    <div className={span ? 'sm:col-span-2' : ''}>
      <div className="text-[12px] leading-5 text-[var(--color-text-mute)]">{label}</div>
      <div className="break-words text-[13px] leading-6 text-[var(--color-text)]">{value}</div>
    </div>
  )
}

// 时间线节点语义：push=顾问事件已推送用户 / op=顾问操作（不推送）/
// note=内部备注 / urge=用户催办 / user=用户会话动作（提交/补交等）/
// fail=系统动作失败（如交接邮件发送失败），需顾问介入处理。
export type CaseTimelineKind = 'push' | 'op' | 'note' | 'urge' | 'user' | 'fail'

const NODE_META: Record<CaseTimelineKind, { icon: ReactNode; iconCls: string; tag: { label: string; tone: string } | null }> = {
  push: {
    icon: <Bell size={12} />,
    iconCls: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
    tag: { label: '已推送用户', tone: CASE_TONE.info },
  },
  op: {
    icon: <NotebookPen size={12} />,
    iconCls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
    tag: null,
  },
  note: {
    icon: <StickyNote size={12} />,
    iconCls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
    tag: null,
  },
  urge: {
    icon: <Zap size={12} />,
    iconCls: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
    tag: null,
  },
  user: {
    icon: <UserRound size={12} />,
    iconCls: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
    tag: null,
  },
  fail: {
    icon: <AlertTriangle size={12} />,
    iconCls: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
    tag: { label: '需处理', tone: CASE_TONE.danger },
  },
}

// 原型式时间线条目：左侧图标节点 + 竖连线，右侧事件行 + 时间·操作人副行。
export function CaseTimelineItem({ kind, label, summary, time, operator, last }: {
  kind: CaseTimelineKind
  label: string
  summary?: string
  time: string
  operator?: string
  last: boolean
}) {
  const meta = NODE_META[kind]
  return (
    <div className="flex gap-3">
      <div className="flex flex-col items-center">
        <div className={`flex h-[26px] w-[26px] shrink-0 items-center justify-center rounded-full ${meta.iconCls}`}>
          {meta.icon}
        </div>
        {!last && <div className="mt-1 w-px flex-1 bg-[var(--color-line-soft)]" />}
      </div>
      <div className={`min-w-0 ${last ? 'pb-0.5' : 'pb-4'}`}>
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] leading-6">
          <span className="font-medium text-[var(--color-text)]">{label}</span>
          {meta.tag && <CaseBadge className={meta.tag.tone}>{meta.tag.label}</CaseBadge>}
          {summary && <span className="text-[var(--color-text-sub)]">{summary}</span>}
        </div>
        <div className="mt-0.5 text-[12px] text-[var(--color-text-mute)]">
          {time}{operator ? ` · ${operator}` : ''}
        </div>
      </div>
    </div>
  )
}
