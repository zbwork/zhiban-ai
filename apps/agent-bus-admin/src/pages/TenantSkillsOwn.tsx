// /tenant-skills/own · 企业自建技能。
//
// 完全复用 PlatformSkills.tsx 里的 SkillsPage 公共组件 (scope='tenant'):
//   - 列表 / 详情 / 编辑 / 删除 / 版本管理 / SKILL.md zip 上传 100% 共用
//   - CRUD 通过 SkillAPICtx 注入到 TenantOwnSkills (后端 /api/admin/v1/tenant/skills/*)
//   - 列表 client-side filter scope_kind=tenant 只显示本企业自建
//   - title / subtitle 切换为企业语境
//
// 见 PlatformSkills.tsx 顶部 "公共组件: SkillsPage" 章节。
export { TenantSkillsOwnPage } from './PlatformSkills'
