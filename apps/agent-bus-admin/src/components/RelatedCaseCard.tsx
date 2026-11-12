import { ArrowUpRight } from 'lucide-react'

import { CaseBadge } from './caseTimeline'
import { CASE_TONE } from './caseTone'
import { Button, FormSection, InlineAlert } from './ui'

export type RelatedCaseCardProps = {
  heading: string
  businessNo: string
  title?: string
  statusLabel: string
  onOpen?: () => void
  missing?: boolean
  error?: string
}

export function RelatedCaseCard({
  heading,
  businessNo,
  title,
  statusLabel,
  onOpen,
  missing = false,
  error = '',
}: RelatedCaseCardProps) {
  const buttonLabel = heading.includes('注册') ? '查看注册申请' : '查看工单'
  return (
    <FormSection title={heading}>
      {error ? (
        <InlineAlert tone={error.includes('创建中') ? 'info' : 'danger'}>{error}</InlineAlert>
      ) : missing ? (
        <InlineAlert tone="warn">历史关联缺失，请核对数据或执行安全回填。</InlineAlert>
      ) : businessNo ? (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium text-[var(--color-brand)]">{businessNo}</span>
              {statusLabel && <CaseBadge className={CASE_TONE.gray}>{statusLabel}</CaseBadge>}
            </div>
            {title && (
              <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]" title={title}>
                {title}
              </div>
            )}
          </div>
          {onOpen && (
            <Button variant="secondary" size="sm" onClick={onOpen}>
              {buttonLabel}
              <ArrowUpRight size={13} />
            </Button>
          )}
        </div>
      ) : (
        <div className="text-[13px] text-[var(--color-text-mute)]">暂无关联记录。</div>
      )}
    </FormSection>
  )
}
