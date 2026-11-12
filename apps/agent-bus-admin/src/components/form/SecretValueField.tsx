import { useId, useState } from 'react'
import { Eye, EyeOff } from 'lucide-react'
import clsx from 'clsx'
import { FormField, Input } from '../ui'
import { secretRefToDisplay, secretValueToRef } from './secretValue'

export function SecretValueField({
  label,
  valueRef,
  onChangeRef,
  placeholder,
  hint,
  isSecret = true,
  error,
  readOnly = false,
}: {
  label: string
  valueRef?: string
  onChangeRef?: (ref: string) => void
  placeholder?: string
  hint?: string
  isSecret?: boolean
  error?: string
  readOnly?: boolean
}) {
  const [reveal, setReveal] = useState(false)
  const errorId = useId()
  const { display, hasHiddenRef } = secretRefToDisplay(valueRef)
  const useMask = isSecret && !reveal && !!display

  return (
    <FormField label={label} hint={hint} as="div">
      <div className="relative">
        <Input
          value={display}
          onChange={(e) => {
            onChangeRef?.(secretValueToRef(e.target.value))
          }}
          readOnly={readOnly}
          aria-label={label}
          type={useMask ? 'password' : 'text'}
          placeholder={hasHiddenRef ? '已保存访问凭证；输入真实凭证可替换' : placeholder}
          autoComplete="off"
          aria-invalid={!!error}
          aria-describedby={error ? errorId : undefined}
          className={clsx(
            isSecret ? 'pr-9 font-mono' : 'font-mono',
            error && 'border-[var(--color-danger)] focus:border-[var(--color-danger)] focus:shadow-[rgba(185,28,28,0.14)_0px_0px_0px_3px]'
          )}
        />
        {isSecret && display && (
          <button
            type="button"
            onClick={() => setReveal((x) => !x)}
            className="absolute inset-y-0 right-0 grid w-9 place-items-center text-[var(--color-text-mute)] hover:text-[var(--color-text)]"
            aria-pressed={reveal}
            aria-label={reveal ? '隐藏' : '显示'}
            title={reveal ? '隐藏凭证' : '显示凭证'}
          >
            {reveal ? <EyeOff size={14} /> : <Eye size={14} />}
          </button>
        )}
      </div>
      {hasHiddenRef && (
        <p className="mt-1 text-[11px] text-[var(--color-text-mute)]">
          当前为历史凭证引用，后台不展示内部引用格式；请直接粘贴真实凭证，保存后可默认掩码回显并用小眼睛查看。
        </p>
      )}
      {error && (
        <p id={errorId} className="mt-1 text-[11.5px] leading-relaxed text-[var(--color-danger)]">
          {error}
        </p>
      )}
    </FormField>
  )
}
