import { api } from './httpClient'
export type Account = {
  id: number
  uuid: string
  email?: string
  phone?: string
  username?: string
  display_name: string
  avatar_url?: string
  status: string
  mfa_enabled?: boolean
  locale?: string
  timezone?: string
  last_login_at?: string
  created_at?: string
  updated_at?: string
}

export type Membership = {
  tenant_id: number
  tenant_name: string
  title?: string
}

// 后端 LoginResp 字段为 camelCase (M1)。
export type AccountSummary = {
  id: number
  uuid: string
  displayName: string
  email?: string
  phone?: string
  username?: string
  avatarUrl?: string
  mustChangePassword?: boolean
  passwordSet?: boolean
}

export type ScopeOption = {
  kind: 'platform' | 'tenant' | 'workspace'
  tenantId?: number
  tenantSlug?: string
  tenantName?: string
  workspaceId?: number
  workspaceName?: string
  roles?: string[]
  perms?: string[]
}

export type LoginResp = {
  accessToken: string
  accessTokenExpiresAt: string
  refreshToken: string
  refreshTokenExpiresAt: string
  account: AccountSummary
  actScope: ScopeOption
}

export type CaptchaResp = { captchaId: string; captchaImage: string }

export const Auth = {
  // 账号密码登录 (账号 = 手机号 / 邮箱 / 用户名)
  loginPassword: (identifier: string, password: string) =>
    api<LoginResp>('/api/admin/v1/auth/login/password', {
      method: 'POST',
      body: JSON.stringify({ identifier, password }),
    }),
  // 手机号 + 短信码登录
  loginSms: (mobile: string, code: string) =>
    api<LoginResp>('/api/admin/v1/auth/login/sms', {
      method: 'POST',
      body: JSON.stringify({ mobile, code }),
    }),
  captcha: () => api<CaptchaResp>('/api/admin/v1/auth/captcha'),
  sendSms: (mobile: string, captchaId: string, captchaCode: string, scene = 'login') =>
    api<{ sent: boolean }>('/api/admin/v1/auth/sms/send', {
      method: 'POST',
      body: JSON.stringify({ mobile, captchaId, captchaCode, scene }),
    }),
  refresh: (refreshToken: string) =>
    api<LoginResp>('/api/admin/v1/auth/token/refresh', {
      method: 'POST',
      body: JSON.stringify({ refreshToken }),
    }),
  logout: () => api<{ ok: boolean }>('/api/admin/v1/auth/logout', { method: 'POST' }),
  changePassword: (oldPwd: string, newPwd: string) =>
    api<{ ok: boolean }>('/api/admin/v1/auth/password/change', {
      method: 'POST',
      body: JSON.stringify({ old: oldPwd, new: newPwd }),
    }),
  switchScope: (kind: 'platform' | 'tenant' | 'workspace', tenantId?: number, workspaceId?: number) =>
    api<LoginResp>('/api/admin/v1/auth/scope/switch', {
      method: 'POST',
      body: JSON.stringify({ kind, tenantId, workspaceId }),
    }),

  me: () => api<{ account: AccountSummary; scopes: ScopeOption[]; actScope: ScopeOption }>('/api/admin/v1/me'),
  menus: () => api<Menu[]>('/api/admin/v1/me/menus'),
  permissions: () => api<string[] | null>('/api/admin/v1/me/permissions'),
}

export type Menu = {
  id: number
  uuid: string
  parentId?: number | null
  path: string
  depth: number
  name: string
  icon: string
  route: string
  sortOrder: number
  scopeKind: 'platform' | 'tenant' | 'workspace' | 'self' | 'any' | 'me'
  isVisible: boolean
  isSystem: boolean
  metadata?: { group?: string; [k: string]: unknown }
}
