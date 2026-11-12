// TenantDriveStorageOverridePage — F06 Phase 4 / §5.1 租户云盘存储覆盖 (tenant scope only).
//
// 取代旧 DriveS3Config 的租户 override 部分; 平台 default 列表移到 PlatformDriveStoragePage.
// 能力: get / put (upsert) / delete / test-connection.
// 单租户单行: 所有字段留空时继承平台默认.
//
// 权限: tenant.drive.manage_storage_override. 后端最终把关.
//
// 2026-05-27 整页重做 + 收口:
//   - 去掉外层 Panel (与 StorageConfigForm 自身 3 张卡片重叠不必要)
//   - 操作收到底部 sticky 操作栏: 测试连接 / 保存; "恢复默认" 仅 override 存在时显示
//   - "删除覆盖" → "恢复默认" (描述结果, 不描述实现)
//   - 文案脱工程词: "存储覆盖" → "专属存储"

import { useEffect, useState } from 'react'
import { DriveStorage, type DriveStorageOverride } from '../../lib/api'
import { Button, InlineAlert, PageHeader } from '../../components/ui'
import { useConfirmDialog } from '../../components/useConfirmDialog'
import { notifyError, notifyOk } from '../../lib/toast'
import { RotateCcw } from 'lucide-react'
import {
  StorageConfigForm,
  type StorageFormValue,
} from './components/StorageConfigForm'

function toFormValue(o: DriveStorageOverride | null): StorageFormValue {
  if (!o || !o.exists) return {
    region: '', endpoint: '', read_endpoint: '', bucket: '',
    access_key_secret_ref: '', secret_key_secret_ref: '',
  }
  return {
    region: o.region || '',
    endpoint: o.endpoint || '',
    read_endpoint: o.read_endpoint || '',
    bucket: o.bucket || '',
    access_key_secret_ref: o.access_key_secret_ref || '',
    secret_key_secret_ref: o.secret_key_secret_ref || '',
    // force_path_style / prefix_tpl: UI 已砍, 不再读取。
  }
}

export function TenantDriveStorageOverridePage() {
  const confirm = useConfirmDialog()
  const [override, setOverride] = useState<DriveStorageOverride | null>(null)
  const [form, setForm] = useState<StorageFormValue>(toFormValue(null))
  const [loadErr, setLoadErr] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [tick, setTick] = useState(0)
  const refresh = () => setTick((t) => t + 1)

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DriveStorage.getOverride()
      .then((ov) => {
        if (cancelled) return
        setOverride(ov)
        setForm(toFormValue(ov))
        setLoadErr('')
      })
      .catch((e: Error) => { if (!cancelled) setLoadErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick])

  const save = async () => {
    setBusy(true)
    try {
      const body: Partial<DriveStorageOverride> = {
        region: form.region || undefined,
        endpoint: form.endpoint || undefined,
        read_endpoint: form.read_endpoint || undefined,
        bucket: form.bucket || undefined,
        access_key_secret_ref: form.access_key_secret_ref || undefined,
        secret_key_secret_ref: form.secret_key_secret_ref || undefined,
      }
      await DriveStorage.putOverride(body)
      notifyOk('已保存')
      refresh()
    } catch (e) { notifyError((e as Error).message) }
    finally { setBusy(false) }
  }

  const test = async () => {
    setBusy(true)
    try {
      const r = await DriveStorage.testOverride()
      if (r.status === 'ok') notifyOk('连接通过 · 可用')
      else notifyError(`连接异常 (${r.status})${r.message ? ': ' + r.message : ''}`)
    } catch (e) { notifyError((e as Error).message) }
    finally { setBusy(false) }
  }

  const revert = async () => {
    const ok = await confirm.confirm({
      title: '恢复为平台默认存储',
      description: (
        <>
          本租户云盘将切回平台默认 OSS/S3 桶。
          <br />
          <span className="text-[12px] text-[var(--color-text-sub)]">
            已签发的下载 URL 仍可用; 新签发的 URL 会指向平台默认桶。
          </span>
        </>
      ),
      confirmLabel: '恢复默认',
    })
    if (!ok) return
    setBusy(true)
    try {
      await DriveStorage.deleteOverride()
      notifyOk('已恢复为平台默认存储')
      refresh()
    } catch (e) { notifyError((e as Error).message) }
    finally { setBusy(false) }
  }

  const disabled = loading || busy
  const hasOverride = !!override?.exists

  return (
    <div>
      {confirm.dialog}
      <PageHeader
        title="专属云盘存储"
        subtitle="本租户使用独立的 OSS/S3 桶。未配置时继承平台默认; 填写下方字段即可切到本租户专属存储。"
      />

      {loadErr && (
        <div className="mb-3">
          <InlineAlert tone="danger">读取存储配置失败: {loadErr}</InlineAlert>
        </div>
      )}

      <StorageConfigForm mode="tenant-override" value={form} onChange={setForm} />

      {/* Sticky 底部操作栏: main 是 scrollable, sticky 吃满 main 视野底。
          负 margin 抵消 Layout main 的 horizontal padding, 让 bar 顶到左右边缘。 */}
      <div className="sticky bottom-0 z-20 mt-6 -mx-[clamp(16px,2vw,36px)] -mb-[clamp(20px,2.4vw,36px)] border-t border-[var(--color-line)] bg-white/95 backdrop-blur supports-[backdrop-filter]:bg-white/85">
        <div className="flex items-center justify-end gap-2 px-[clamp(16px,2vw,36px)] py-3">
          {hasOverride && (
            <Button variant="ghost" onClick={revert} disabled={disabled}>
              <RotateCcw size={13} /> 恢复默认
            </Button>
          )}
          <Button variant="secondary" onClick={test} disabled={disabled}>测试连接</Button>
          <Button onClick={save} disabled={disabled}>{busy ? '保存中…' : '保存'}</Button>
        </div>
      </div>
    </div>
  )
}
