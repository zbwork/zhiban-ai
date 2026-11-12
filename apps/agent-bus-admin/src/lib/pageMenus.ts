import type { Menu } from './authApi'

// Existing list/workspace routes. Detail and create routes stay inside their pages.
// The community entrypoint uses these links independently of database menu seeds.
const pages: Record<'platform' | 'tenant', Record<string, [string, string][]>> = {
  platform: {
    '概览': [['/dashboard', '概览']],
    '租户管理': [['/tenants', '租户管理']],
    '企业管理': [
      ['/startup-agent-cases', '企业注册申请'], ['/bookkeeping-tickets', '代理记账工单'],
      ['/company-profiles', '企业档案'], ['/web-leads', '创业助手咨询单'],
      ['/web-funnel', '获客漏斗'], ['/web-feedback', '回复反馈'], ['/provider-pricing', '服务商与定价'],
    ],
    '计费中心': [
      ['/plans', '计费中心'], ['/billing/plans', '套餐管理'], ['/billing/features', '权益项'],
      ['/billing/credits', '积分包配置'], ['/billing/orders', '订单管理'],
      ['/billing/config', '计费配置'], ['/billing/usage', '用量统计'], ['/billing/overrides', '权益覆写'],
    ],
    'Agent 平台': [
      ['/platform-types', 'Agent 平台类型'], ['/runtime-hosting', '平台托管配置'],
      ['/runtimes', '运行环境'], ['/runtime-environments', '智能体托管环境'],
      ['/preset-agents', '数字员工模版'], ['/emp-blocks', 'EMP 协议管理'], ['/mcp', 'MCP 服务'],
    ],
    '技能中心': [
      ['/skills', '技能管理'], ['/skill-categories', '技能分类'],
      ['/skill-labels', '技能标签'], ['/builtin-keys', '客户端能力注册表'],
    ],
    '应用管理': [['/apps', '应用管理'], ['/app-categories', '应用分类']],
    '知识库': [
      ['/kb-providers', '知识库服务配置'], ['/platform-kb', '知识库管理'],
      ['/ragflow-ops', '监控运维'],
    ],
    '云盘': [
      ['/drive/storage', '云盘存储配置'], ['/drive/usage', '云盘用量'], ['/drive/workers', '云盘定时任务'],
    ],
    '任务与自动化': [
      ['/cron-dashboard', '统计看板'], ['/cron-jobs', '定时任务列表'],
      ['/cron-prompt-templates-ops', '定时任务模板'],
    ],
    '系统管理': [['/roles', '权限与角色'], ['/menus', '菜单管理'], ['/sys-users', '系统用户']],
    '监控与告警': [
      ['/alerts', '告警中心'], ['/wukongim', 'IM 运行监控'],
      ['/observability/agent-runs', '运行监测'], ['/observability/call-logs', '调用日志'],
    ],
    '审计与合规': [['/audit', '审计日志'], ['/observability/conversations', '会话检索']],
    '平台管理': [
      ['/support-feedback', '问题反馈'], ['/marketing-leads', '官网线索'],
      ['/download-channels', '下载渠道'], ['/share-growth', '用户分享'],
      ['/client-versions', '客户端版本'], ['/local-coding-tool-versions', '本地编程工具版本'],
      ['/client-analytics', '客户端分析'],
    ],
  },
  tenant: {
    '概览': [['/dashboard', '概览']],
    '计费中心': [['/billing/subscription', '订阅与配额'], ['/billing/usage', '用量统计']],
    '数字员工': [['/agents', '数字员工列表'], ['/runtime-environments', '智能体托管环境']],
    '技能中心': [['/tenant-skills/platform', '平台技能'], ['/tenant-skills/own', '企业技能']],
    '应用管理': [
      ['/apps', '应用栏配置'], ['/workspace-apps', '工作台应用'],
    ],
    '知识库': [
      ['/kb', '知识库管理'], ['/kb-documents', '文档管理'], ['/user-kb-inspect', '用户知识库审计'],
    ],
    '云盘': [
      ['/drive', '企业云盘'], ['/drive/quotas', '云盘配额'],
      ['/drive/recycle', '云盘回收站'], ['/drive/storage-override', '专属云盘存储'],
    ],
    '任务': [['/cron', '定时任务'], ['/cron-prompt-templates', '定时任务模板']],
    '组织与人员': [
      ['/members', '成员'], ['/departments', '部门'], ['/positions', '职位'],
      ['/org-sync', '组织同步'], ['/contacts', '通讯录配置'],
    ],
    '群聊与协同': [
      ['/approvals', '审批'], ['/rooms', '群聊'], ['/rooms/a2a', 'A2A 调用治理'],
      ['/rooms/orchestrations', '协作编排'], ['/rooms/speaker-policies', 'Speaker 策略'],
    ],
    '凭证与接入': [
      ['/api-keys', 'API Key 管理'], ['/agent-sdk-credentials', 'Agent SDK 凭证'], ['/sso-config', '单点登录 (SSO)'],
    ],
    '系统管理': [['/roles', '权限与角色']],
    '监控与告警': [
      ['/alerts', '告警中心'], ['/observability/agent-runs', '运行监测'], ['/observability/call-logs', '调用日志'],
    ],
    '审计与合规': [['/audit', '审计日志'], ['/observability/conversations', '会话检索']],
  },
}

const groupIcons: Record<string, string> = {
  '概览': 'layout-dashboard', '租户管理': 'building-2', '企业管理': 'briefcase',
  '计费中心': 'layers', 'Agent 平台': 'cpu', '技能中心': 'wand', '应用管理': 'settings',
  '知识库': 'book-open', '云盘': 'hard-drive', '任务与自动化': 'list-checks', '任务': 'list-checks',
  '数字员工': 'bot', '系统管理': 'shield-check', '组织与人员': 'users',
  '群聊与协同': 'message-square', '凭证与接入': 'key', '监控与告警': 'activity',
  '审计与合规': 'shield', '平台管理': 'settings',
}

export const PAGE_MENUS: Menu[] = Object.entries(pages).flatMap(([scopeKind, groups]) =>
  Object.entries(groups).flatMap(([group, links]) =>
    links.map(([route, name], index) => ({
      id: 0, uuid: `${scopeKind}:${route}`, parentId: null, path: route, depth: 0,
      name, icon: groupIcons[group] || 'puzzle', route, sortOrder: index, scopeKind: scopeKind as 'platform' | 'tenant',
      isVisible: true, isSystem: true, metadata: { group },
    })),
  ),
).map((menu, index) => ({ ...menu, id: -(index + 1) }))
