// 后端 structured 错误码 → 中文友好提示。
//
// 后端不少地方用 apperr.ErrXxx.Withf("code: explain ...") 拼错误, 给客户端看到的 message
// 经常是裸的 code 字符串 (例如 "kb.provider_degraded")。运营用户不知道这是啥, 需要在前端
// 翻译成可读中文。
//
// 用法:
//   import { humanizeError } from './errorMessages'
//   notifyError(humanizeError(err))
//
// 匹配规则:
//   1. 完整匹配 (整段 message 等于某个 code)
//   2. 前缀匹配 (message 以 code 开头, 后面可能跟 ": detail")
//   3. 包含匹配 (message 里出现 code 关键字, 用于 wrapped error)
//   4. 都不命中 → 原样返回 (保留 fallback)

const CODE_MAP: Record<string, string> = {
  // —— KB provider ——
  'kb.provider_degraded': '服务连接异常，未通过健康检查',
  'kb.provider.has_references': '已有知识库引用此服务，无法删除',
  'kb.provider.set_default_requires_active': '只能将「启用」状态的服务设为默认',
  'kb.provider.not_found': '知识库服务不存在或已被删除',
  'kb.folder_not_empty': '目录中仍有子目录或文件，请先处理后再删除',

  // —— Runtime / hosting ——
  'runtime.bound_agents_blocked': '当前环境仍被数字员工绑定，无法停用或删除',
  'runtime.must_pass_probe': '请先在编辑面板完成连通性测试，再启用或开放给租户',

  // —— Client version / Sparkle Delta ——
  'client_version.missing_delta_from': '请填写来源构建号（旧版应用的 CFBundleVersion，例如 12300）后重新选择 Delta 文件。',
  'client_version.invalid_delta_signature': 'Delta EdDSA 签名格式错误：请粘贴 generate_appcast 生成的 appcast 中 sparkle:edSignature 的完整 Base64 值，不要填写文件 SHA-256。',

  // —— Common ——
  'conflict: 该账号已是本租户成员': '已添加过该成员',
  'conflict: 该手机号已是本租户成员': '已添加过该成员',
  'conflict: 租户创建人不能直接移出，请先转让租户所有权': '租户创建人不能直接移出，请先转让租户所有权',
  'conflict: 租户创建人不能改为非在职状态，请先转让租户所有权': '租户创建人不能改为非在职状态，请先转让租户所有权',
  'conflict: 该成员是租户最后一名超级管理员，请先将其他成员设为超级管理员': '该成员是租户最后一名超级管理员，请先将其他成员设为超级管理员',
  'forbidden: 普通管理员不能移出超级管理员': '普通管理员不能移出超级管理员',
  'forbidden: 普通管理员不能将超级管理员改为非在职状态': '普通管理员不能将超级管理员改为非在职状态',
  'invalid_params': '参数不合法',
  'unauthorized': '当前账号无权限执行此操作',
  'not_found': '资源不存在',
  'conflict': '操作与当前状态冲突',
  'upstream_unavailable': '上游服务不可用',
}

function detailAfterCode(message: string, code: string): string {
  const index = message.toLowerCase().indexOf(code.toLowerCase())
  if (index < 0) return ''
  return message.slice(index + code.length).replace(/^\s*:\s*/, '').trim()
}

function appendAction(detail: string, action: string): string {
  if (!detail) return action
  const normalized = detail.replace(/[。；，,;\s]+$/, '')
  return `${normalized}，${action}`
}

function humanizeQuotaError(message: string): string | null {
  const lower = message.toLowerCase()
  if (lower.includes('billing.entitlement_exceeded')) {
    return appendAction(
      detailAfterCode(message, 'billing.entitlement_exceeded'),
      '请升级套餐或调整配额后重试。',
    )
  }
  if (lower.includes('billing.feature_not_available')) {
    return appendAction(
      detailAfterCode(message, 'billing.feature_not_available'),
      '请升级套餐后重试。',
    )
  }
  if (lower.includes('billing.entitlement_not_configured')) {
    return appendAction(
      detailAfterCode(message, 'billing.entitlement_not_configured'),
      '请联系平台管理员检查套餐配置。',
    )
  }
  if (lower.includes('billing.insufficient_credits')) {
    return '积分不足，请购买积分包或升级套餐后重试。'
  }
  if (lower.includes('kb.quota_exceeded')) {
    return '知识库容量已达当前套餐上限，请清理文件、升级套餐或调整容量后重试。'
  }
  if (lower.includes('drive.quota_exceeded')) {
    return '云盘容量已达当前套餐上限，请清理文件、升级套餐或调整容量后重试。'
  }
  return null
}

export function humanizeError(input: unknown): string {
  const raw = typeof input === 'string'
    ? input
    : (input instanceof Error ? input.message : String(input ?? ''))
  if (!raw) return '操作失败'

  const trimmed = raw.trim()

  const quotaMessage = humanizeQuotaError(trimmed)
  if (quotaMessage) return quotaMessage

  // 1. 完整等于某个 code
  if (CODE_MAP[trimmed]) return CODE_MAP[trimmed]

  // 2. 前缀匹配 "code: detail" 或 "code" + 空白
  for (const code of Object.keys(CODE_MAP)) {
    if (trimmed === code) return CODE_MAP[code]
    if (trimmed.startsWith(code + ':') || trimmed.startsWith(code + ' ')) {
      return CODE_MAP[code]
    }
  }

  // 3. 包含匹配 (用于 wrapped error, 例如 "resolver: kb.provider_degraded")
  for (const code of Object.keys(CODE_MAP)) {
    if (trimmed.includes(code)) return CODE_MAP[code]
  }

  // 4. 兜底: 返回原文 (至少不让用户看到空白)
  return trimmed
}
