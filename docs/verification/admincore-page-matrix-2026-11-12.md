# 后台页面请求矩阵（2026-11-12）

地址：本机 38082，最终重建的 Admin 镜像；真实账号登录并切换 scope，逐个访问侧栏 92 个入口。每页收集实际 API 状态，重复请求单独计数；不等同于写入、详情或完整业务验收。

| scope | 页面 | 失败请求 |
| --- | --- | --- |
| tenant | 概览 (/dashboard) | HTTP 403 /tenant/overview |
| tenant | 订阅与配额 (/billing/subscription) | HTTP 404 /tenant/billing/subscription<br>HTTP 404 /tenant/billing/entitlements<br>HTTP 404 /tenant/billing/wallet |
| tenant | 用量统计 (/billing/usage) | HTTP 404 /tenant/billing/usage/summary<br>HTTP 404 /tenant/billing/usage/aggregates |
| tenant | 数字员工列表 (/agents) | HTTP 403 /tenant/runtime-environments |
| tenant | 智能体托管环境 (/runtime-environments) | HTTP 403 /tenant/runtime-environments |
| tenant | 平台技能 (/tenant-skills/platform) | HTTP 403 /tenant/skill-categories<br>HTTP 403 /tenant/skills |
| tenant | 企业技能 (/tenant-skills/own) | HTTP 403 /tenant/skill-categories<br>HTTP 403 /tenant/skill-labels<br>HTTP 403 /tenant/skills |
| tenant | 应用栏配置 (/apps) | 本次已观察请求均 200 |
| tenant | 工作台应用 (/workspace-apps) | 本次已观察请求均 200 |
| tenant | 知识库管理 (/kb) | HTTP 403 /tenant/knowledge-bases |
| tenant | 文档管理 (/kb-documents) | HTTP 403 /tenant/knowledge-bases |
| tenant | 用户知识库审计 (/user-kb-inspect) | 本次已观察请求均 200 |
| tenant | 企业云盘 (/drive) | HTTP 403 /tenant/drive/spaces |
| tenant | 云盘配额 (/drive/quotas) | HTTP 403 /tenant/drive/quotas |
| tenant | 云盘回收站 (/drive/recycle) | HTTP 403 /tenant/drive/recycle |
| tenant | 专属云盘存储 (/drive/storage-override) | HTTP 403 /tenant/drive/storage-override |
| tenant | 定时任务 (/cron) | 本次已观察请求均 200 |
| tenant | 定时任务模板 (/cron-prompt-templates) | 本次已观察请求均 200 |
| tenant | 成员 (/members) | HTTP 403 /tenant/roles<br>HTTP 403 /tenant/positions |
| tenant | 部门 (/departments) | 本次已观察请求均 200 |
| tenant | 职位 (/positions) | HTTP 403 /tenant/positions |
| tenant | 组织同步 (/org-sync) | HTTP 403 /tenant/org-webhooks |
| tenant | 通讯录配置 (/contacts) | 本次已观察请求均 200 |
| tenant | A2A 调用治理 (/rooms/a2a) | HTTP 500 /tenant/a2a/agents<br>HTTP 500 /tenant/a2a |
| tenant | 协作编排 (/rooms/orchestrations) | HTTP 500 /tenant/orchestrations |
| tenant | Speaker 策略 (/rooms/speaker-policies) | HTTP 500 /tenant/speaker-policies |
| tenant | 审批 (/approvals) | HTTP 500 /tenant/a2a/approvals |
| tenant | 群聊 (/rooms) | 本次已观察请求均 200 |
| tenant | API Key 管理 (/api-keys) | HTTP 403 /tenant/api-keys |
| tenant | Agent SDK 凭证 (/agent-sdk-credentials) | HTTP 403 /tenant/agent-sdk-credentials |
| tenant | 单点登录 (SSO) (/sso-config) | HTTP 403 /tenant/identity-providers |
| tenant | 权限与角色 (/roles) | HTTP 403 /permissions<br>HTTP 403 /tenant/roles |
| tenant | 告警中心 (/alerts) | HTTP 403 /tenant/alerts |
| tenant | 运行监测 (/observability/agent-runs) | HTTP 403 /tenant/observability/agent-runs/stats<br>HTTP 403 /tenant/observability/agent-runs |
| tenant | 调用日志 (/observability/call-logs) | HTTP 403 /tenant/observability/call-logs |
| tenant | 审计日志 (/audit) | HTTP 403 /tenant/audit-events<br>HTTP 403 /tenant/audit-summary |
| tenant | 会话检索 (/observability/conversations) | HTTP 403 /tenant/observability/conversations<br>HTTP 403 /tenant/roles<br>HTTP 403 /tenant/departments<br>HTTP 403 /tenant/members |
| platform | 概览 (/dashboard) | HTTP 403 /tenant/positions<br>HTTP 403 /platform/overview |
| platform | 租户管理 (/tenants) | HTTP 404 /platform/billing/plans |
| platform | 企业注册申请 (/startup-agent-cases) | HTTP 404 /startup-agent/stats<br>HTTP 404 /startup-agent/cases |
| platform | 代理记账工单 (/bookkeeping-tickets) | HTTP 404 /startup-agent/stats<br>HTTP 404 /startup-agent/cases |
| platform | 企业档案 (/company-profiles) | HTTP 404 /startup-agent/profiles |
| platform | 创业助手咨询单 (/web-leads) | HTTP 404 /startup-agent/web/stats<br>HTTP 404 /startup-agent/leads |
| platform | 获客漏斗 (/web-funnel) | HTTP 404 /startup-agent/web/quality<br>HTTP 404 /startup-agent/web/funnel<br>HTTP 404 /startup-agent/web/users |
| platform | 回复反馈 (/web-feedback) | HTTP 404 /startup-agent/web/feedback/stats<br>HTTP 404 /startup-agent/web/feedback |
| platform | 服务商与定价 (/provider-pricing) | HTTP 404 /startup-agent/registration/handoff-routes<br>HTTP 404 /startup-agent/bookkeeping/pricing<br>HTTP 404 /startup-agent/web/city-pricing |
| platform | 套餐管理 (/plans) | HTTP 404 /platform/billing/plans |
| platform | 套餐管理 (/billing/plans) | HTTP 404 /platform/billing/plans |
| platform | 权益项 (/billing/features) | HTTP 404 /platform/billing/features |
| platform | 积分包配置 (/billing/credits) | HTTP 404 /platform/billing/credit-packs |
| platform | 订单管理 (/billing/orders) | HTTP 404 /platform/billing/orders |
| platform | 计费配置 (/billing/config) | HTTP 404 /platform/billing/config<br>HTTP 404 /platform/billing/beebridge-pricing |
| platform | 用量统计 (/billing/usage) | HTTP 404 /platform/billing/usage/aggregates<br>HTTP 404 /platform/billing/usage/summary<br>HTTP 404 /platform/billing/usage/tenants |
| platform | 权益覆写 (/billing/overrides) | HTTP 404 /platform/billing/entitlement-overrides |
| platform | 运行环境 (/runtimes) | HTTP 403 /platform/runtime-environments |
| platform | MCP 服务 (/mcp) | 本次已观察请求均 200 |
| platform | Agent 平台类型 (/platform-types) | 本次已观察请求均 200 |
| platform | 平台托管配置 (/runtime-hosting) | HTTP 404 /platform/runtime-hosting-configs |
| platform | 智能体托管环境 (/runtime-environments) | HTTP 403 /platform/runtime-environments |
| platform | 数字员工模版 (/preset-agents) | HTTP 404 /platform/runtime-hosting-configs<br>HTTP 403 /platform/preset-agents |
| platform | EMP 协议管理 (/emp-blocks) | HTTP 403 /platform/emp-blocks |
| platform | 技能管理 (/skills) | 本次已观察请求均 200 |
| platform | 技能分类 (/skill-categories) | 本次已观察请求均 200 |
| platform | 技能标签 (/skill-labels) | 本次已观察请求均 200 |
| platform | 客户端能力注册表 (/builtin-keys) | HTTP 500 /platform/builtin-skill-keys |
| platform | 应用管理 (/apps) | HTTP 403 /platform/app-categories<br>HTTP 403 /platform/apps |
| platform | 应用分类 (/app-categories) | HTTP 403 /platform/app-categories |
| platform | 知识库服务配置 (/kb-providers) | HTTP 404 /platform/model-options<br>HTTP 404 /platform/model-options<br>HTTP 404 /platform/kb-providers |
| platform | 知识库管理 (/platform-kb) | HTTP 403 /platform/knowledge-bases |
| platform | 监控运维 (/ragflow-ops) | HTTP 404 /platform/kb-providers<br>HTTP 404 /platform/ragflow-bindings<br>HTTP 404 /platform/kb-outbox-events |
| platform | 云盘存储配置 (/drive/storage) | HTTP 403 /platform/drive/storage-defaults |
| platform | 云盘用量 (/drive/usage) | HTTP 403 /platform/drive/usage<br>HTTP 403 /platform/drive/usage/summary |
| platform | 云盘定时任务 (/drive/workers) | HTTP 403 /platform/drive/workers |
| platform | 统计看板 (/cron-dashboard) | HTTP 403 /platform/cron-jobs/overview<br>HTTP 403 /platform/cron/capability-dry-run |
| platform | 定时任务列表 (/cron-jobs) | HTTP 403 /platform/cron-jobs |
| platform | 定时任务模板 (/cron-prompt-templates-ops) | HTTP 403 /platform/cron-prompt-templates |
| platform | 权限与角色 (/roles) | HTTP 403 /platform/roles<br>HTTP 403 /permissions |
| platform | 菜单管理 (/menus) | HTTP 403 /platform/menus<br>HTTP 403 /permissions |
| platform | 系统用户 (/sys-users) | HTTP 403 /platform/roles<br>HTTP 403 /platform/sys-users |
| platform | 告警中心 (/alerts) | HTTP 403 /platform/alerts |
| platform | IM 运行监控 (/wukongim) | HTTP 403 /platform/wukong/overview<br>HTTP 403 /platform/wukong/connections |
| platform | 运行监测 (/observability/agent-runs) | HTTP 403 /platform/observability/agent-runs/stats<br>HTTP 403 /platform/observability/agent-runs |
| platform | 调用日志 (/observability/call-logs) | HTTP 403 /platform/observability/call-logs |
| platform | 审计日志 (/audit) | HTTP 403 /platform/audit-summary<br>HTTP 403 /platform/audit-events |
| platform | 会话检索 (/observability/conversations) | HTTP 403 /platform/observability/conversations |
| platform | 问题反馈 (/support-feedback) | HTTP 403 /platform/support-feedback |
| platform | 官网线索 (/marketing-leads) | HTTP 403 /platform/marketing-leads |
| platform | 下载渠道 (/download-channels) | HTTP 403 /platform/download-channels/stats<br>HTTP 403 /platform/download-channels |
| platform | 用户分享 (/share-growth) | HTTP 403 /platform/share-growth<br>HTTP 403 /platform/share-growth/stats |
| platform | 客户端版本 (/client-versions) | HTTP 404 /platform/client-build-jobs<br>HTTP 403 /platform/client-versions |
| platform | 本地编程工具版本 (/local-coding-tool-versions) | HTTP 403 /platform/local-coding-tool-versions<br>HTTP 403 /platform/local-coding-tool-auto-sync |
| platform | 客户端分析 (/client-analytics) | HTTP 403 /platform/client-analytics/overview |

未观察到请求或未触发的操作不在成功范围。[原始请求清单](admincore-page-requests-2026-11-12.json)。
