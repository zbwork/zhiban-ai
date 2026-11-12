import { type ReactNode, useEffect, useRef, useState } from 'react'
import { Archive, Bot, Building2, Contact, Cpu, MoreVertical, Pencil, Puzzle, Rocket, Shield, Tags, Trash2 } from 'lucide-react'
import type { AgentFull, RuntimeEnv } from '../../lib/api'
import { Button } from '../ui'

export function AgentCard({
  agent,
  runtimeEnv,
  onEdit,
  onPublish,
  onUnpublish,
  onDelete,
  deleteLabel = '删除',
  allowArchivedPublish = false,
}: {
  agent: AgentFull
  runtimeEnv?: RuntimeEnv | null
  onEdit?: () => void
  onPublish?: () => void
  onUnpublish?: () => void
  onDelete?: () => void
  deleteLabel?: string
  allowArchivedPublish?: boolean
}) {
  const tags = agentDisplayTags(agent)
  const canPublish = (agent.Status === 'draft' || (allowArchivedPublish && agent.Status === 'archived')) && !!onPublish
  const publishLabel = agent.Status === 'archived' ? '上架' : '发布'
  const canUnpublish = (agent.Status === 'published' || agent.Status === 'grayed') && !!onUnpublish
  const canDelete = agent.Status !== 'published' && agent.Status !== 'grayed' && !!onDelete
  const hasMenu = !!(onEdit || canPublish || canUnpublish || canDelete)
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const left = [
    { icon: <Puzzle size={14} />, label: '状态', value: <StatusValue status={agent.Status} /> },
    { icon: <Puzzle size={14} />, label: '来源', value: sourceLabel(agent.Source || '') },
    { icon: <Contact size={14} />, label: '通讯录', value: agent.ContactEnabled === false ? '不展示' : '展示' },
  ]
  const right = [
    { icon: <Shield size={14} />, label: '范围', value: visibilityLabel(agent.Visibility) },
    { icon: <Cpu size={14} />, label: '运行', value: agent.execution_locus === 'local' ? `用户电脑 · ${agent.local_engine === 'codex_app_server' ? 'Codex App Server' : 'DeepSeek Harness'}` : runtimeEnv?.Framework ? `云端 · ${runtimeEnv.Framework.toUpperCase()}` : agent.RuntimeEnvironmentID ? '云端 · 环境不可用' : '云端 · 未绑定环境' },
    agent.PositionLabel ? { icon: <Building2 size={14} />, label: '职位', value: agent.PositionLabel } : null,
  ].filter(Boolean) as Array<{ icon: ReactNode; label: string; value: ReactNode }>

  useEffect(() => {
    if (!menuOpen) return
    const closeOnOutside = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setMenuOpen(false)
    }
    const closeOnEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false)
    }
    document.addEventListener('mousedown', closeOnOutside)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('mousedown', closeOnOutside)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [menuOpen])

  return (
    <div className="card-shadow group flex h-[304px] min-w-0 flex-col rounded-lg border border-[var(--color-line)] bg-white p-5 text-left transition hover:border-[var(--color-brand-line)]">
      <div className="flex h-[84px] items-start gap-4">
        <Avatar agent={agent} />
        <div className="min-w-0 flex-1 pt-1">
          <div className="truncate text-[17px] font-semibold leading-6 text-[var(--color-text)]">
            {agent.Name}
          </div>
          {agentDescription(agent) && (
            <p className="mt-1.5 line-clamp-2 text-[13px] leading-5 text-[var(--color-text-sub)]">
              {agentDescription(agent)}
            </p>
          )}
        </div>
        <div className="flex shrink-0 items-start gap-2">
          {hasMenu && (
            <div ref={menuRef} className="relative">
              <button
                type="button"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                aria-label={`打开「${agent.Name}」操作菜单`}
                onClick={() => setMenuOpen((open) => !open)}
                className="grid h-8 w-8 place-items-center rounded-md text-[var(--color-text-mute)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25"
              >
                <MoreVertical size={18} />
              </button>
              {menuOpen && (
                <div
                  role="menu"
                  className="absolute right-0 top-10 z-20 w-36 rounded-lg border border-[var(--color-line)] bg-white p-1.5 shadow-[0_18px_42px_rgba(15,23,42,0.16)]"
                >
                  {onEdit && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="w-full justify-start text-[var(--color-text)]"
                      onClick={() => {
                        setMenuOpen(false)
                        onEdit()
                      }}
                    >
                      <Pencil size={14} /> 编辑
                    </Button>
                  )}
                  {canPublish && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="mt-1 w-full justify-start text-[var(--color-brand)] hover:text-[var(--color-brand)]"
                      onClick={() => {
                        setMenuOpen(false)
                        onPublish?.()
                      }}
                    >
                      <Rocket size={14} /> {publishLabel}
                    </Button>
                  )}
                  {canUnpublish && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="mt-1 w-full justify-start text-[var(--color-warn)] hover:text-[var(--color-warn)]"
                      onClick={() => {
                        setMenuOpen(false)
                        onUnpublish?.()
                      }}
                    >
                      <Archive size={14} /> 下架
                    </Button>
                  )}
                  {canDelete && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="mt-1 w-full justify-start text-[var(--color-danger)] hover:text-[var(--color-danger)]"
                      onClick={() => {
                        setMenuOpen(false)
                        onDelete?.()
                      }}
                    >
                      <Trash2 size={14} /> {deleteLabel}
                    </Button>
                  )}
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      <div className="mt-4 border-t border-[var(--color-line-soft)] pt-4">
        <div className="grid grid-cols-[1fr_auto_1fr] gap-4">
          <MetaColumn items={left} />
          <div className="w-px bg-[var(--color-line-soft)]" />
          <MetaColumn items={right} />
        </div>
      </div>

      <div className="mt-auto border-t border-[var(--color-line-soft)] pt-4">
        <div className="flex min-w-0 items-center gap-3">
          <span className="inline-flex shrink-0 items-center gap-1.5 text-[13px] text-[var(--color-text-sub)]">
            <Tags size={14} className="text-[var(--color-text-mute)]" />
            标签
          </span>
          {tags.length > 0 ? (
            <div className="flex min-w-0 flex-nowrap items-center gap-2 overflow-hidden">
              {tags.map((tag) => (
                <Tag key={tag}>{tag}</Tag>
              ))}
            </div>
          ) : (
            <span className="text-[13px] text-[var(--color-text-mute)]">未设置</span>
          )}
        </div>
      </div>
    </div>
  )
}

function Avatar({ agent }: { agent: AgentFull }) {
  const avatarSrc = agent.AvatarPreviewURL || ''
  const [failedSrc, setFailedSrc] = useState('')
  const showImage = avatarSrc !== '' && failedSrc !== avatarSrc
  return (
    <div className="grid h-16 w-16 shrink-0 place-items-center overflow-hidden rounded-lg border border-[var(--color-brand-line)] bg-[var(--color-bg-sub)] text-[28px] font-semibold text-[var(--color-brand)]">
      {showImage ? (
        <img src={avatarSrc} alt={`${agent.Name}头像`} className="h-full w-full object-cover" onError={() => setFailedSrc(avatarSrc)} />
      ) : agent.Name ? (
        agent.Name.slice(0, 1)
      ) : (
        <Bot size={28} />
      )}
    </div>
  )
}

function MetaColumn({ items }: { items: Array<{ icon: ReactNode; label: string; value: ReactNode }> }) {
  return (
    <div className="space-y-3.5">
      {items.map((item) => (
        <MetaItem key={item.label} icon={item.icon} label={item.label} value={item.value} />
      ))}
    </div>
  )
}

function MetaItem({ icon, label, value }: { icon: ReactNode; label: string; value: ReactNode }) {
  return (
    <div className="flex min-w-0 items-center gap-2 text-[13px] leading-5">
      <span className="shrink-0 text-[var(--color-text-mute)]">{icon}</span>
      <span className="shrink-0 text-[var(--color-text-sub)]">{label}</span>
      <span className="min-w-0 truncate text-[var(--color-text)]">{value}</span>
    </div>
  )
}

function Tag({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex min-w-0 max-w-[140px] shrink-0 items-center rounded-md border border-[var(--color-brand-line)] bg-[var(--color-brand-bg)] px-2 py-0.5 text-[11px] leading-5 text-[var(--color-brand)]">
      <span className="truncate">{children}</span>
    </span>
  )
}

function agentDescription(a: AgentFull): string {
  return a.Intro || ''
}

function agentDisplayTags(a: AgentFull): string[] {
  const tags = ((a.Tags && a.Tags.length > 0) ? a.Tags : (a.Badges || [])).filter(Boolean)
  const unique = Array.from(new Set(tags))
  // 卡片高度固定，标签固定单行：最多 2 个标签 + 「+N」，避免溢出底部。
  if (unique.length <= 2) return unique
  return [...unique.slice(0, 2), `+${unique.length - 2}`]
}

function visibilityLabel(s: string): string {
  if (s === 'tenant') return '全租户'
  if (s === 'workspace') return '指定部门'
  if (s === 'private') return '仅创建者'
  if (s === 'platform') return '平台模版'
  return s || '未设置范围'
}

function sourceLabel(s: string): string {
  return s === 'enterprise' ? '租户创建' : s === 'personal' ? '个人创建' : s === 'platform' ? '平台创建' : s || '未设置'
}

function statusLabel(status: string): string {
  const label: Record<string, string> = {
    published: '已发布',
    draft: '草稿',
    grayed: '灰度',
    archived: '已下架',
  }
  return label[status] || status
}

function statusPalette(status: string) {
  if (status === 'published') {
    return {
      dot: 'bg-[var(--color-success)]',
      badge: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    }
  }
  if (status === 'archived') {
    return {
      dot: 'bg-[var(--color-text-mute)]',
      badge: 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]',
    }
  }
  return {
    dot: 'bg-[var(--color-warn)]',
    badge: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  }
}

function StatusValue({ status }: { status: string }) {
  const palette = statusPalette(status)
  return (
    <span className="inline-flex min-w-0 items-center gap-2">
      <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${palette.dot}`} />
      <span className={`inline-flex max-w-full items-center rounded-md px-2 py-0.5 text-[12px] leading-5 ${palette.badge}`}>
        <span className="truncate">{statusLabel(status)}</span>
      </span>
    </span>
  )
}
