import { useRef, useState, type DragEvent, type KeyboardEvent } from 'react'
import { File, UploadCloud, X } from 'lucide-react'

type FileUploadPickerProps = {
  title: string
  description: string
  accept?: string
  file?: File | null
  disabled?: boolean
  busy?: boolean
  busyLabel?: string
  onSelect: (file: File) => void
  onClear?: () => void
}

function formatFileSize(size: number): string {
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`
  return `${(size / 1024 / 1024).toFixed(2)} MB`
}

export function FileUploadPicker({
  title,
  description,
  accept,
  file,
  disabled = false,
  busy = false,
  busyLabel = '上传中...',
  onSelect,
  onClear,
}: FileUploadPickerProps) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)
  const inactive = disabled || busy

  const chooseFile = () => {
    if (!inactive) inputRef.current?.click()
  }

  const selectFile = (next: File | null) => {
    if (next && !inactive) onSelect(next)
  }

  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    selectFile(event.dataTransfer.files?.[0] || null)
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'Enter' && event.key !== ' ') return
    event.preventDefault()
    chooseFile()
  }

  return (
    <div
      className={`rounded-md border border-dashed transition ${dragging
        ? 'border-[var(--color-brand)] bg-[var(--color-brand-bg)]'
        : 'border-[var(--color-line)] bg-[var(--color-bg-sub)]'}`}
      onDragEnter={(event) => { event.preventDefault(); if (!inactive) setDragging(true) }}
      onDragOver={(event) => event.preventDefault()}
      onDragLeave={() => setDragging(false)}
      onDrop={onDrop}
    >
      <input
        ref={inputRef}
        type="file"
        className="hidden"
        accept={accept}
        disabled={inactive}
        aria-label={title}
        onChange={(event) => {
          selectFile(event.currentTarget.files?.[0] || null)
          event.currentTarget.value = ''
        }}
      />

      <div
        role="button"
        tabIndex={inactive ? -1 : 0}
        aria-disabled={inactive}
        className={`flex items-center gap-3 px-4 py-4 outline-none transition focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[var(--color-brand)]/25 ${inactive
          ? 'cursor-not-allowed opacity-60'
          : 'cursor-pointer hover:bg-[var(--color-control-hover)]'}`}
        onClick={chooseFile}
        onKeyDown={onKeyDown}
      >
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-[var(--color-brand-line)] bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
          <UploadCloud size={19} />
        </span>
        <span className="min-w-0 flex-1 text-left">
          <span className="block text-[13px] font-medium text-[var(--color-text)]">
            {busy ? busyLabel : title}
          </span>
          <span className="mt-1 block text-[12px] leading-5 text-[var(--color-text-sub)]">
            {description}
          </span>
        </span>
        <span className="shrink-0 rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] px-3 py-2 text-[12px] font-medium text-[var(--color-text)]">
          {file ? '重新选择' : '选择文件'}
        </span>
      </div>

      {file && (
        <div className="mx-3 mb-3 flex items-center gap-3 rounded-md border border-[var(--color-line)] bg-[var(--color-surface)] px-3 py-2.5">
          <File size={16} className="shrink-0 text-[var(--color-brand)]" />
          <div className="min-w-0 flex-1">
            <div className="truncate text-[13px] font-medium text-[var(--color-text)]" title={file.name}>{file.name}</div>
            <div className="mt-0.5 text-[11px] text-[var(--color-text-sub)]">{formatFileSize(file.size)}</div>
          </div>
          {onClear && (
            <button
              type="button"
              className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-line-soft)] hover:text-[var(--color-danger)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25 disabled:cursor-not-allowed disabled:opacity-60"
              aria-label={`移除文件 ${file.name}`}
              title="移除文件"
              disabled={inactive}
              onClick={onClear}
            >
              <X size={15} />
            </button>
          )}
        </div>
      )}
    </div>
  )
}
