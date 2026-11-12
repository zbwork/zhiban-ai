// admin web 通用枚举 → 中文 label 集中表。
//
// 目的:
//   后端返回的枚举值 (status / kind / behavior / scope_kind / visibility / execution_mode) 都是英文 code,
//   admin 用户全是中文场景, 直接展示英文 code 不友好。本模块把所有 code → 中文统一管理,
//   避免每个页面散落 if-else / Record 重复。
//
// 用法:
//   import { SKILL_STATUS_LABEL, behaviorLabel } from '../lib/skillLabels'
//   <span>{SKILL_STATUS_LABEL[skill.status] ?? skill.status}</span>
//   或 hook 风格: behaviorLabel(skill.tenant_preference)
//
// 增加新枚举时:
//   1. 在 backend 文档里确认枚举值是哪些
//   2. 在本文件加 Record + 一个 helper 函数 (兜底返回原 code)
//   3. 调用方用 helper 而不是裸 Record (避免 undefined 显示)

// ---------------- 技能 (skills) ----------------

/** skills.kind */
export const SKILL_KIND_LABEL: Record<string, string> = {
  agent: 'Agent 技能',
  builtin: '客户端原生',
}

/** skills.status — 产品语义只承认两态：启用 / 停用。
 *
 * 数据库 enum 仍是 (draft/active/archived) — 见 services/agent-bus/sql/postgres/000092_f03_skills_core.up.sql。
 * 但 admin 侧统一按 "active = 启用、其它(draft|archived) = 停用" 渲染；
 * 列表筛选用 status='active' (启用) / status='inactive' (停用; repo.go:144 映射 s.status<>'active')。
 * "是否发过版" 改读 skills.latest_version_id 而不是 status，避免一字段多语义。
 */
export const SKILL_STATUS_LABEL: Record<string, string> = {
  draft: '停用',
  active: '启用',
  archived: '停用',
}

/** skills.scope_kind */
export const SKILL_SCOPE_LABEL: Record<string, string> = {
  platform: '平台',
  tenant: '租户',
}

/** skills.visibility (F03 D27: boundaries §2.3 标准) */
export const SKILL_VISIBILITY_LABEL: Record<string, string> = {
  private: '私有',
  workspace: '工作区',
  tenant: '租户',
  platform: '全平台',
}

/** skills.execution_mode */
export const SKILL_EXECUTION_MODE_LABEL: Record<string, string> = {
  synchronous_inline: '同步内联',
  asynchronous_floating: '异步浮层',
}

// ---------------- 租户偏好 (tenant_skill_preferences) ----------------

/** tenant_skill_preferences.behavior */
export const SKILL_BEHAVIOR_LABEL: Record<string, string> = {
  force_on: '默认装上',
  force_off: '默认不装',
}

/** 偏好下拉选项 (含"跟随" = 清除偏好) */
export type SkillPreferenceValue = '' | 'force_on' | 'force_off'

export const SKILL_PREFERENCE_OPTIONS: Array<{ value: SkillPreferenceValue; label: string; hint?: string }> = [
  { value: '', label: '跟随默认', hint: '不强制, 由技能本身的 default_attached 决定' },
  { value: 'force_on', label: '默认装上', hint: '本租户新建数字员工时强制装上此技能' },
  { value: 'force_off', label: '默认不装', hint: '本租户新建数字员工时强制不装, 但管理员可手动加' },
]

export function preferenceLabel(value?: string | null): string {
  if (!value) return '跟随默认'
  return SKILL_BEHAVIOR_LABEL[value] ?? value
}

// ---------------- KB Provider ----------------

/** kb_provider_config.status (现 admin 用 Switch 表达 active/disabled, degraded 旁边小红点) */
export const KB_PROVIDER_STATUS_LABEL: Record<string, string> = {
  active: '可用',
  degraded: '健康异常',
  disabled: '已禁用',
}

// ---------------- 通用 helpers ----------------

/** 返回中文 label, 兜底原 code (避免 undefined)。 */
export function labelOrCode(map: Record<string, string>, code?: string | null): string {
  if (!code) return '-'
  return map[code] ?? code
}
