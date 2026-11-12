import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'

import './index.css'
import { Login } from './pages/Login'
import { ForceChangePassword } from './pages/ForceChangePassword'
import { Layout } from './components/Layout'
import { GlobalToast } from './components/GlobalToast'
import { GlobalLoading } from './components/GlobalLoading'
import { TenantHiddenRoute, TenantOnlyRoute } from './components/TenantHiddenRoute'
import { ScopedDashboard } from './pages/Dashboard'
import { TenantList } from './pages/TenantList'
import { TenantBillingDetailPage, TenantBillingSubscriptionPage } from './pages/TenantBillingDetail'
import {
  BillingConfigPage,
  BillingCreditsPage,
  BillingFeaturesPage,
  BillingOrdersPage,
  BillingOverridesPage,
  BillingPage,
  BillingPlansPage,
  BillingUsagePage,
} from './pages/BillingPage'
import { AgentList } from './pages/AgentList'
import { AgentDetail } from './pages/AgentDetail'
import { RuntimesPage } from './pages/Runtimes'
import PlatformTypes from './pages/PlatformTypes'
import { RuntimeEnvironmentsRouter } from './pages/RuntimeEnvironmentsRouter'
import { RuntimeHostingPage } from './pages/RuntimeHosting'
import { PlatformPresetAgentDetail, PlatformPresetAgents } from './pages/PlatformPresetAgents'
import { EMPBlockList } from './pages/EMPBlockList'
import { KBProvidersPage } from './pages/KBProviders'
import { RagflowOpsPage } from './pages/RagflowOps'
import { UserKBInspectPage } from './pages/UserKBInspect'
// F06 Phase 4: 旧 DriveS3ConfigPage / DriveBrowsePage 拆分到 src/pages/drive/ 下 7 个新页面.
import { PlatformDriveStoragePage } from './pages/drive/PlatformDriveStoragePage'
import { PlatformDriveUsagePage } from './pages/drive/PlatformDriveUsagePage'
import { PlatformDriveWorkersPage } from './pages/drive/PlatformDriveWorkersPage'
import { TenantDrivePage } from './pages/drive/TenantDrivePage'
import { TenantDriveQuotasPage } from './pages/drive/TenantDriveQuotasPage'
import { TenantDriveRecyclePage } from './pages/drive/TenantDriveRecyclePage'
import { TenantDriveStorageOverridePage } from './pages/drive/TenantDriveStorageOverridePage'
import { KBListPage, PlatformKBListPage } from './pages/KBList'
import { KBDocumentsPage } from './pages/KBDocuments'
import { KBDetailPage, PlatformKBDetailPage } from './pages/KBDetail'
import { PlatformSkillsPage } from './pages/PlatformSkills'
import { SkillDictionariesPage } from './pages/SkillDictionaries'
import { TenantSkillsPlatformPage } from './pages/TenantSkillsPlatform'
import { TenantSkillsOwnPage } from './pages/TenantSkillsOwn'
import { AgentSkillBindingsPage } from './pages/AgentSkillBindings'
import CronPromptTemplatesPage, {
  PlatformCronPromptTemplatesPage,
} from './pages/CronPromptTemplates'
import TenantCronJobsPage from './pages/TenantCronJobs'
import PlatformCronJobsPage from './pages/PlatformCronJobs'
import PlatformCronDashboardPage from './pages/PlatformCronDashboard'
import ClientAnalyticsDashboardPage from './pages/ClientAnalyticsDashboard'
import { AgentStep6Page } from './pages/AgentStep6'
import { MemberList } from './pages/MemberList'
import { ApiKeysPage } from './pages/ApiKeys'
import { OrgSyncPage } from './pages/OrgSync'
import { SsoConfigPage } from './pages/SsoConfig'
import { OidcCallbackPage } from './pages/OidcCallback'
import { AgentSdkCredentialsPage } from './pages/AgentSdkCredentials'
import { MySessionsPage } from './pages/MySessions'
import { AuditPage } from './pages/Audit'
import { ObservabilityCallLogsPage } from './pages/ObservabilityCallLogs'
import { ObservabilityAgentRunsPage } from './pages/ObservabilityAgentRuns'
import { ObservabilityConversationsPage } from './pages/ObservabilityConversations'
import { A2AApprovalsPage } from './pages/A2AApprovals'
import { SupportFeedbackPage } from './pages/SupportFeedback'
import { MarketingLeadsPage } from './pages/MarketingLeads'
import { StartupAgentCasesPage } from './pages/StartupAgentCases'
import { BookkeepingTicketsPage } from './pages/BookkeepingTickets'
import { ProviderPricingPage } from './pages/ProviderPricing'
import { CompanyProfilesPage } from './pages/CompanyProfiles'
import { WebFunnelPage } from './pages/WebFunnel'
import { StartupFeedbackPage } from './pages/StartupFeedback'
import { WebLeadsPage } from './pages/WebLeads'
import { ClientVersionsPage } from './pages/ClientVersions'
import { LocalCodingToolVersionsPage } from './pages/LocalCodingToolVersions'
import { DownloadChannelsPage } from './pages/DownloadChannels'
import { ShareGrowthPage } from './pages/ShareGrowth'
import { DepartmentTree } from './pages/DepartmentTree'
import { PositionList } from './pages/Positions'
import { ContactPolicyPage } from './pages/ContactPolicy'
import { Profile } from './pages/Profile'
import { Placeholder } from './pages/Placeholder'
import { AlertCenterPage } from './pages/AlertCenter'
import WuKongIMStatus from './pages/WuKongIMStatus'
import Rooms from './pages/Rooms'
// F09 Phase B.4 / PR8: A2A / orchestration / speaker policy 治理 + RoomDetail Speaker tab.
import A2AGraph from './pages/A2AGraph'
import Orchestrations from './pages/Orchestrations'
import OrchestrationDetailPage from './pages/OrchestrationDetail'
import SpeakerPoliciesPage from './pages/SpeakerPolicies'
import RoomDetailPage from './pages/RoomDetail'
import { MenuManager, RoleManager, SysUserList } from './pages/SystemAdmin'
import { AppsPage } from './pages/Apps'
import { AppCategoriesPage } from './pages/AppCategoriesPage'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <GlobalToast />
      <GlobalLoading />
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/auth/oidc/callback" element={<OidcCallbackPage />} />
        <Route path="/force-change-password" element={<ForceChangePassword />} />
        <Route path="/" element={<Layout showAllPages />}>
          <Route index element={<Navigate to="/dashboard" replace />} />
          <Route path="dashboard" element={<ScopedDashboard />} />
          <Route path="client-analytics" element={<TenantHiddenRoute><ClientAnalyticsDashboardPage /></TenantHiddenRoute>} />
          <Route path="tenants" element={<TenantList />} />
          <Route path="tenants/:id" element={<TenantHiddenRoute><TenantBillingDetailPage /></TenantHiddenRoute>} />
          <Route path="plans" element={<BillingPage />} />
          <Route path="billing/subscription" element={<TenantOnlyRoute><TenantBillingSubscriptionPage /></TenantOnlyRoute>} />
          <Route path="billing/plans" element={<BillingPlansPage />} />
          <Route path="billing/features" element={<BillingFeaturesPage />} />
          <Route path="billing/credits" element={<BillingCreditsPage />} />
          <Route path="billing/orders" element={<BillingOrdersPage />} />
          <Route path="billing/config" element={<BillingConfigPage />} />
          <Route path="billing/usage" element={<BillingUsagePage />} />
          <Route path="billing/overrides" element={<BillingOverridesPage />} />
          {/* 产品化「运行环境」页面，统一消费 /platform/runtime-environments + /platform/runtimes。 */}
          <Route path="runtimes" element={<RuntimesPage />} />
          {/* 4 层 Agent 平台模型 L1: 只读类型枚举。 */}
          <Route path="platform-types" element={<PlatformTypes />} />
          {/* 运行环境按当前管理范围分发到 platform / tenant 视图。 */}
          <Route path="runtime-environments" element={<RuntimeEnvironmentsRouter />} />
          <Route path="runtime-hosting" element={<RuntimeHostingPage />} />
          <Route path="preset-agents" element={<PlatformPresetAgents />} />
          <Route path="preset-agents/new" element={<PlatformPresetAgentDetail />} />
          <Route path="preset-agents/:uuid" element={<PlatformPresetAgentDetail />} />
          <Route path="emp-blocks" element={<EMPBlockList />} />
          {/* F25 告警中心: platform / tenant 双 scope 复用同页面 */}
          <Route path="alerts" element={<AlertCenterPage />} />
          <Route path="audit" element={<AuditPage />} />
          <Route path="observability/call-logs" element={<ObservabilityCallLogsPage />} />
          <Route path="observability/agent-runs" element={<ObservabilityAgentRunsPage />} />
          <Route path="observability/conversations" element={<ObservabilityConversationsPage />} />
          <Route path="support-feedback" element={<TenantHiddenRoute><SupportFeedbackPage /></TenantHiddenRoute>} />
          <Route path="marketing-leads" element={<TenantHiddenRoute><MarketingLeadsPage /></TenantHiddenRoute>} />
          <Route path="startup-agent-cases" element={<TenantHiddenRoute><StartupAgentCasesPage /></TenantHiddenRoute>} />
          <Route path="bookkeeping-tickets" element={<TenantHiddenRoute><BookkeepingTicketsPage /></TenantHiddenRoute>} />
          <Route path="provider-pricing" element={<TenantHiddenRoute><ProviderPricingPage /></TenantHiddenRoute>} />
          <Route path="company-profiles" element={<TenantHiddenRoute><CompanyProfilesPage /></TenantHiddenRoute>} />
          <Route path="web-leads" element={<TenantHiddenRoute><WebLeadsPage /></TenantHiddenRoute>} />
          <Route path="web-funnel" element={<TenantHiddenRoute><WebFunnelPage /></TenantHiddenRoute>} />
          <Route path="web-feedback" element={<TenantHiddenRoute><StartupFeedbackPage /></TenantHiddenRoute>} />
          <Route path="client-versions" element={<TenantHiddenRoute><ClientVersionsPage /></TenantHiddenRoute>} />
          <Route path="local-coding-tool-versions" element={<TenantHiddenRoute><LocalCodingToolVersionsPage /></TenantHiddenRoute>} />
          <Route path="download-channels" element={<TenantHiddenRoute><DownloadChannelsPage /></TenantHiddenRoute>} />
          <Route path="share-growth" element={<TenantHiddenRoute><ShareGrowthPage /></TenantHiddenRoute>} />
          <Route path="menus" element={<MenuManager />} />
          <Route path="sys-users" element={<SysUserList />} />
          <Route path="roles" element={<RoleManager />} />
          <Route path="agents" element={<AgentList />} />
          <Route path="agents/new" element={<AgentDetail />} />
          <Route path="agents/:uuid" element={<AgentDetail />} />
          <Route path="skills" element={<TenantHiddenRoute><PlatformSkillsPage /></TenantHiddenRoute>} />
          {/* /contacts 是租户通讯录配置 (M2 ContactPolicy 真页面)，不应被 TenantHiddenRoute 重定向 */}
          <Route path="contacts" element={<ContactPolicyPage />} />
          <Route path="mcp" element={<Placeholder title="MCP 服务" />} />
          {/* ADR-0026: WuKongIM 状态 (platform scope) */}
          <Route path="wukongim" element={<TenantHiddenRoute><WuKongIMStatus /></TenantHiddenRoute>} />
          {/* 群聊列表 (tenant scope) */}
          <Route path="rooms" element={<TenantOnlyRoute><Rooms /></TenantOnlyRoute>} />
          {/* F09 Phase B.4 / PR8: A2A 治理 + Orchestration + Speaker 策略 + RoomDetail */}
          <Route path="rooms/a2a" element={<TenantOnlyRoute><A2AGraph /></TenantOnlyRoute>} />
          <Route path="rooms/orchestrations" element={<TenantOnlyRoute><Orchestrations /></TenantOnlyRoute>} />
          <Route path="rooms/orchestrations/:uuid" element={<TenantOnlyRoute><OrchestrationDetailPage /></TenantOnlyRoute>} />
          <Route path="rooms/speaker-policies" element={<TenantOnlyRoute><SpeakerPoliciesPage /></TenantOnlyRoute>} />
          <Route path="rooms/:uuid" element={<TenantOnlyRoute><RoomDetailPage /></TenantOnlyRoute>} />
          {/* M8B KB Provider 管理 (Codex round-5) */}
          <Route path="kb-providers" element={<TenantHiddenRoute><KBProvidersPage /></TenantHiddenRoute>} />
          {/* F07 监控运维综合页 (provider health + bindings + KB overview) */}
          <Route path="ragflow-ops" element={<TenantHiddenRoute><RagflowOpsPage /></TenantHiddenRoute>} />
          <Route path="platform-kb" element={<TenantHiddenRoute><PlatformKBListPage /></TenantHiddenRoute>} />
          <Route path="platform-kb/:uuid" element={<TenantHiddenRoute><PlatformKBDetailPage /></TenantHiddenRoute>} />
          {/* F07 D13 跨用户查私有 KB (审计敏感) */}
          <Route path="user-kb-inspect" element={<UserKBInspectPage />} />
          <Route path="skill-categories" element={<TenantHiddenRoute><SkillDictionariesPage initialTab="categories" /></TenantHiddenRoute>} />
          <Route path="skill-labels" element={<TenantHiddenRoute><SkillDictionariesPage initialTab="labels" /></TenantHiddenRoute>} />
          <Route path="builtin-keys" element={<TenantHiddenRoute><SkillDictionariesPage initialTab="builtin-keys" /></TenantHiddenRoute>} />
          {/* F03 §1.5 方案 B: 租户视角"技能中心"拆为两个菜单 (000106 migration) */}
          <Route path="tenant-skills/platform" element={<TenantSkillsPlatformPage />} />
          <Route path="tenant-skills/own" element={<TenantSkillsOwnPage />} />
          <Route path="cron-dashboard" element={<TenantHiddenRoute><PlatformCronDashboardPage /></TenantHiddenRoute>} />
          <Route path="cron-jobs" element={<TenantHiddenRoute><PlatformCronJobsPage /></TenantHiddenRoute>} />
          {/* F08 §5.1 / L: tenant scope cron jobs admin */}
          <Route path="cron" element={<TenantCronJobsPage />} />
          {/* F08 §5.2 / I: 租户后台 cron Prompt 模板管理 (tenant scope) */}
          <Route path="cron-prompt-templates" element={<CronPromptTemplatesPage />} />
          {/* 平台控制台 · 平台模板管理 (scope=platform, 全租户员工可选用其启用版) */}
          <Route
            path="cron-prompt-templates-ops"
            element={<PlatformCronPromptTemplatesPage />}
          />
          <Route path="agents/:uuid/capabilities" element={<AgentStep6Page />} />
          <Route path="agents/:uuid/skills" element={<AgentSkillBindingsPage />} />
          {/* M8 Phase B sprint: KB 管理 + 详情 5 tab */}
          <Route path="kb" element={<KBListPage />} />
          <Route path="kb/:uuid" element={<KBDetailPage />} />
          <Route path="kb-documents" element={<KBDocumentsPage />} />
          {/* F06 Phase 4 落地: 平台 (3) + 租户 (4) drive 子路由全部接入真实页面。
              旧 /drive-s3 入口已删除 (设计规范禁止 legacy redirect); 旧 DriveS3Config /
              DriveBrowse 文件由 Phase 4 拆分迁移到 src/pages/drive/ 下。 */}
          {/* tenant scope */}
          <Route path="drive" element={<TenantDrivePage />} />
          <Route path="drive/quotas" element={<TenantDriveQuotasPage />} />
          <Route path="drive/recycle" element={<TenantDriveRecyclePage />} />
          <Route path="drive/storage-override" element={<TenantDriveStorageOverridePage />} />
          {/* platform scope */}
          <Route path="drive/storage" element={<PlatformDriveStoragePage />} />
          <Route path="drive/usage" element={<PlatformDriveUsagePage />} />
          <Route path="drive/workers" element={<PlatformDriveWorkersPage />} />
          <Route path="apps" element={<AppsPage />} />
          <Route path="app-categories" element={<AppCategoriesPage />} />
          <Route path="workspace-apps" element={<Placeholder title="工作台应用" subtitle="租户工作台里曝光的应用集合与排序。" />} />
          <Route path="members" element={<MemberList />} />
          {/* M1 B2 (F01 §3.5): 租户 API Key 管理 */}
          <Route path="api-keys" element={<ApiKeysPage />} />
          <Route path="org-sync" element={<OrgSyncPage />} />
          {/* M4 (F01 §4.3): 租户 SSO IdP 配置 */}
          <Route path="sso-config" element={<SsoConfigPage />} />
          {/* M2 (F01 §3.6): 自定义 Agent SDK 凭证 */}
          <Route path="agent-sdk-credentials" element={<AgentSdkCredentialsPage />} />
          <Route path="departments" element={<DepartmentTree />} />
          <Route path="positions" element={<PositionList />} />
          <Route path="approvals" element={<A2AApprovalsPage />} />
          <Route path="me">
            <Route path="profile" element={<Profile />} />
            {/* F01 §4.5: 多设备会话管理 */}
            <Route path="sessions" element={<MySessionsPage />} />
            {/* "我的 API Key" 预留移除: API Key 是租户级权限，不是用户级。
                有该权限的用户走 /api-keys 即可。 */}
          </Route>
          {/* 404 catchall: 专业空态, 不带表情符号。 */}
          <Route path="*" element={
            <div className="flex flex-col items-center justify-center min-h-[60vh] text-center px-6">
              <div className="text-[var(--color-text-mute)] text-sm uppercase tracking-widest mb-3">404</div>
              <h1 className="text-2xl font-semibold mb-2">页面未找到</h1>
              <p className="text-sm text-[var(--color-ink-mute)] mb-6 max-w-md">
                你访问的链接没有对应的页面。可能是旧路径已迁移、菜单尚未上架，或当前账号无权访问。
              </p>
              <a href="/dashboard" className="text-[var(--color-brand)] hover:underline">返回概览</a>
            </div>
          } />
        </Route>
      </Routes>
    </BrowserRouter>
  </StrictMode>
)
