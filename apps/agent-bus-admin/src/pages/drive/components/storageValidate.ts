// 抽到独立文件供 PlatformDriveStoragePage / TenantDriveStorageOverridePage 共用,
// 同时满足 react-refresh/only-export-components: StorageConfigForm.tsx 只导组件.

import type { StorageFormValue } from './StorageConfigForm'

// 后端仍接收内部凭证引用；admin web 只让用户输入真实凭证，表单层会自动包装。
export function validateSecretRef(ref: string | undefined, label: string): string | null {
  const v = (ref || '').trim()
  if (!v) return `请填写${label}`
  if (v.startsWith('value://')) return null
  // 理论上不会走到这里 (UI 包了), 但留个兜底防止外部调用绕过 UI。
  return `${label}格式不正确`
}

// 仅平台 create/edit 调用; 租户 override 走全字段可空, 由 caller 自己判断.
export function validatePlatformForm(form: StorageFormValue): string | null {
  if (!form.kind) return '请选择存储类型'
  if (!form.name?.trim()) return '请填写名称'
  if (!form.bucket?.trim()) return '请填写存储桶'
  const ak = validateSecretRef(form.access_key_secret_ref, 'Access Key')
  if (ak) return ak
  const sk = validateSecretRef(form.secret_key_secret_ref, 'Secret Key')
  if (sk) return sk
  return null
}
