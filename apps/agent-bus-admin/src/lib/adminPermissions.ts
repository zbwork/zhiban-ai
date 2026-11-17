import { parseAccessToken, type ScopeOption } from './api'

// UI hints only. Every Admin API continues to enforce its own scope and permission.
const reads: Record<string, string[]> = {
 '/departments':['tenant.department.read'], '/members':['tenant.member.read'], '/positions':['tenant.position.read'],
 '/contacts':['tenant.member.read'], '/roles':['tenant.role.read','platform.role.read'],
 '/agents':['tenant.agent.read'], '/runtime-environments':['tenant.runtime_env.read'],
 '/apps':['tenant.app.read','platform.app.read'], '/workspace-apps':['tenant.app.read'],
 '/sso-config':['tenant.identity_provider.read'], '/api-keys':['tenant.api_key.read'],
 '/agent-sdk-credentials':['tenant.agent_sdk.read'], '/org-sync':['tenant.org_webhook.read'],
 '/kb':['tenant.kb.read'], '/kb-documents':['tenant.kb.read'], '/user-kb-inspect':['tenant.kb.read_user_private'],
 '/drive':['tenant.drive.read_metadata'], '/drive/quotas':['tenant.drive.manage_quota'], '/drive/recycle':['tenant.drive.manage_recycle'],
 '/tenant-skills/platform':['tenant.skill.read'], '/tenant-skills/own':['tenant.skill.read'],
 '/cron':['tenant.agent.read'], '/cron-prompt-templates':['tenant.agent.read'],
 '/audit':['tenant.audit.read','platform.audit.read'], '/dashboard':['tenant.overview.read','platform.overview.read'],
 '/observability/agent-runs':['tenant.observability.read','platform.observability.read'],
 '/observability/call-logs':['tenant.observability.read','platform.observability.read'],
 '/tenants':['platform.tenant.read'], '/rooms':['tenant.agent.read'], '/rooms/a2a':['tenant.agent.read'], '/rooms/orchestrations':['tenant.agent.read'], '/rooms/speaker-policies':['tenant.agent.read'], '/approvals':['tenant.agent.read'], '/drive/storage-override':['tenant.drive.manage_storage'],
}
export function hasAdminPermission(code: string) { return (parseAccessToken()?.perms ?? []).includes(code) }
export function isUnrestrictedScope(scopes: ScopeOption[], active: ScopeOption | null) {
 const match=scopes.find(s=>s.kind===active?.kind && (s.tenantId??0)===(active?.tenantId??0) && (s.workspaceId??0)===(active?.workspaceId??0))
 return (match?.roles??[]).some(r=>r==='tenant.admin'||r==='platform.admin')
}
export function canViewAdminRoute(path: string) {
 if(path.startsWith('/me/'))return true
 const route=Object.keys(reads).sort((a,b)=>b.length-a.length).find(r=>path===r || path.startsWith(r+'/'))
 return route ? reads[route].some(hasAdminPermission) : false
}
