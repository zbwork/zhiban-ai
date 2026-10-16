import type { LoginResp } from './authApi'
// Thin API client over fetch. Reads token from localStorage.
import { notifyError } from './toast'
import { beginLoading, endLoading } from './loading'
import { humanizeError } from './errorMessages'

const TOKEN_KEY = 'agbus.token'
const REFRESH_KEY = 'agbus.refresh'
const TENANT_KEY = 'agbus.tenant'

export const auth = {
  token: () => localStorage.getItem(TOKEN_KEY) || '',
  setToken: (t: string) => localStorage.setItem(TOKEN_KEY, t),
  clearToken: () => localStorage.removeItem(TOKEN_KEY),
  refresh: () => localStorage.getItem(REFRESH_KEY) || '',
  setRefresh: (t: string) => localStorage.setItem(REFRESH_KEY, t),
  clearRefresh: () => localStorage.removeItem(REFRESH_KEY),
  tenant: () => Number(localStorage.getItem(TENANT_KEY) || '0'),
  setTenant: (id: number) => {
    if (id > 0) localStorage.setItem(TENANT_KEY, String(id))
    else localStorage.removeItem(TENANT_KEY)
  },
  clearAll: () => {
    localStorage.removeItem(TOKEN_KEY)
    localStorage.removeItem(REFRESH_KEY)
    localStorage.removeItem(TENANT_KEY)
  },
}

export type ApiResponse<T> = {
  success?: boolean
  code: number
  message: string
  data: T
  traceId?: string
}

export class ApiError extends Error {
  readonly status: number

  constructor(message: string, status: number) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

export type UploadProgress = {
  loaded: number
  total: number
  percent: number | null
}

const inflightGet = new Map<string, Promise<unknown>>()
const GET_REQUEST_TIMEOUT_MS = 30_000

export function clearInflightGet() {
  inflightGet.clear()
}

// 登录 / token 续期类路径跳过全屏 loading — 按钮自身的 "登录中" / "刷新中" 已足够反馈,
// 这种"未登录就先弹遮罩"也会盖住 captcha / 表单, UX 反而差。
const SKIP_GLOBAL_LOADING_PATHS = new Set([
  '/api/admin/v1/auth/login',
  '/api/admin/v1/auth/login/password',
  '/api/admin/v1/auth/login/sms',
  '/api/admin/v1/auth/token/refresh',
  '/api/admin/v1/auth/captcha',
  '/api/admin/v1/auth/sms/send',
])

export async function api<T = unknown>(
  path: string,
  init: RequestInit = {}
): Promise<T> {
  const method = (init.method || 'GET').toUpperCase()
  if (method === 'GET' && !init.body) {
    const key = `${auth.token()} ${auth.tenant()} ${path}`
    const existing = inflightGet.get(key)
    if (existing) return existing as Promise<T>
    const req = request<T>(path, init).finally(() => inflightGet.delete(key))
    inflightGet.set(key, req)
    return req
  }
  // 非 GET = mutating 请求（保存 / 启用禁用 / 发布版本 / 删除等）。
  // 全局计数 +1，<GlobalLoading /> 渲染居中遮罩并阻断点击；finally 必然 -1，
  // 失败抛错也走 finally，不会卡死。401 重试在 request() 内部完成，不影响计数。
  if (SKIP_GLOBAL_LOADING_PATHS.has(path)) {
    return await request<T>(path, init)
  }
  beginLoading()
  try {
    return await request<T>(path, init)
  } finally {
    endLoading()
  }
}

// 自动续期：401 时若本地有 refresh token，调一次 /auth/token/refresh，
// 成功就用新的 access token **重放原请求**；失败再清登录态跳登录页。
// 并发 401 共用一把锁，避免短时间内多次刷新 → refresh token rotation 被废。
let refreshInflight: Promise<boolean> | null = null

const REFRESH_ENDPOINTS = new Set([
  '/api/admin/v1/auth/login/password',
  '/api/admin/v1/auth/login/sms',
  '/api/admin/v1/auth/token/refresh',
  '/api/admin/v1/auth/logout',
])

export async function tryRefresh(): Promise<boolean> {
  const rt = auth.refresh()
  if (!rt) return false
  if (!refreshInflight) {
    refreshInflight = (async () => {
      try {
        const res = await fetch('/api/admin/v1/auth/token/refresh', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refreshToken: rt }),
        })
        const text = await res.text()
        const body = parseApiBody<LoginResp>(text, res)
        if (!res.ok || !body || body.code !== 0) return false
        auth.setToken(body.data.accessToken)
        if (body.data.refreshToken) auth.setRefresh(body.data.refreshToken)
        return true
      } catch {
        return false
      } finally {
        // 让下次 401 可以重新触发；但只在本次刷新结束后才解锁
        setTimeout(() => { refreshInflight = null }, 0)
      }
    })()
  }
  return refreshInflight
}

async function request<T = unknown>(
  path: string,
  init: RequestInit = {},
  retried = false,
): Promise<T> {
  const method = (init.method || 'GET').toUpperCase()
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(init.headers as Record<string, string>),
  }
  // FormData / Blob 让浏览器自己写 multipart boundary；强行覆盖 Content-Type 反而会破坏请求。
  if (init.body instanceof FormData || init.body instanceof Blob) {
    delete headers['Content-Type']
  }
  const t = auth.token()
  if (t) headers.Authorization = `Bearer ${t}`

  const timeoutController = method === 'GET' && !init.signal ? new AbortController() : null
  const timeoutID = timeoutController
    ? window.setTimeout(() => timeoutController.abort(), GET_REQUEST_TIMEOUT_MS)
    : null
  let res: Response
  try {
    res = await fetch(path, { ...init, headers, ...(timeoutController ? { signal: timeoutController.signal } : {}) })
  } catch (e) {
    if (timeoutController?.signal.aborted) {
      throw new Error('请求超时，请刷新后重试', { cause: e })
    }
    throw e
  } finally {
    if (timeoutID !== null) window.clearTimeout(timeoutID)
  }
  const bodyText = await res.text()
  const body = parseApiBody<T>(bodyText, res)

  if (!res.ok || !body || body.code !== 0) {
    const rawMessage = resolveErrorMessage(body, res, bodyText)
    // /me/permissions reads current grants, while the guard uses a JWT snapshot.
    // Only this explicit pre-handler denial is safe to refresh/replay here.
    // Preserve the operation ID; never retry upstream failures or arbitrary 403s.
    const resetPermissionDenied = method === 'POST'
      && /^\/api\/admin\/v1\/platform\/tenants\/[1-9]\d*\/beebridge\/password\/reset$/.test(path)
      && res.status === 403
      && /permission_denied: requires one of \[platform\.tenant\.credentials\.(read|reset)\]/.test(rawMessage)
    if (resetPermissionDenied && !retried && auth.refresh()) {
      if (await tryRefresh()) return request<T>(path, init, true)
    }
    // 401 自动续期：仅在 1) 非 refresh/login 自身 2) 未重试过 的情况下尝试。
    if (res.status === 401 && !retried && !REFRESH_ENDPOINTS.has(path) && auth.refresh()) {
      const ok = await tryRefresh()
      if (ok) {
        return request<T>(path, init, true)
      }
    }
    if (res.status === 401) {
      auth.clearAll()
      if (location.pathname !== '/login') location.href = '/login'
    }
    const message = resetPermissionDenied
      ? '当前会话没有蜂桥凭据操作权限，请重新登录；如仍无权限，请联系平台管理员。'
      : humanizeError(rawMessage)
    notifyError(message)
    throw new ApiError(message, res.status)
  }
  return body.data
}

export async function uploadMultipart<T>(
  path: string,
  body: FormData,
  onProgress?: (progress: UploadProgress) => void,
  retried = false,
): Promise<T> {
  const response = await new Promise<{ status: number; bodyText: string; contentType: string }>((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', path)
    const token = auth.token()
    if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`)
    xhr.upload.addEventListener('progress', (event) => {
      const total = event.lengthComputable ? event.total : 0
      onProgress?.({
        loaded: event.loaded,
        total,
        percent: total > 0 ? Math.min(100, Math.floor((event.loaded / total) * 100)) : null,
      })
    })
    xhr.addEventListener('load', () => resolve({
      status: xhr.status,
      bodyText: xhr.responseText,
      contentType: xhr.getResponseHeader('content-type') || '',
    }))
    xhr.addEventListener('error', () => reject(new Error('上传连接中断，请检查网络后重试')))
    xhr.addEventListener('abort', () => reject(new Error('上传已取消')))
    xhr.send(body)
  })

  let parsed: ApiResponse<T> | null = null
  if (response.bodyText.trim() && response.contentType.includes('application/json')) {
    try {
      parsed = JSON.parse(response.bodyText) as ApiResponse<T>
    } catch {
      parsed = null
    }
  }
  if (response.status === 401 && !retried && auth.refresh() && await tryRefresh()) {
    return uploadMultipart(path, body, onProgress, true)
  }
  if (response.status < 200 || response.status >= 300 || !parsed || parsed.code !== 0) {
    if (response.status === 401) {
      auth.clearAll()
      if (location.pathname !== '/login') location.href = '/login'
    }
    const nested = parsed?.data
    const detail = nested && typeof nested === 'object' ? nested as Record<string, unknown> : null
    const rawMessage = detail
      ? stringValue(detail.message) || stringValue(detail.code) || parsed?.message
      : parsed?.message
    const message = humanizeError(rawMessage || `上传失败（HTTP ${response.status || '未知'}）`)
    notifyError(message)
    throw new ApiError(message, response.status)
  }
  return parsed.data
}

export function parseApiBody<T>(bodyText: string, res: Response): ApiResponse<T> | null {
  if (!bodyText.trim()) return null
  const contentType = res.headers.get('content-type') || ''
  if (!contentType.includes('application/json')) return null
  try {
    return JSON.parse(bodyText) as ApiResponse<T>
  } catch {
    return null
  }
}

export function resolveErrorMessage<T>(body: ApiResponse<T> | null, res: Response, bodyText: string) {
  const nested = body?.data
  if (nested && typeof nested === 'object') {
    const detail = nested as Record<string, unknown>
    const message = stringValue(detail.message)
    const code = stringValue(detail.code)
    const stage = stringValue(detail.stage)
    const cause = stringValue(detail.detail)
    const primary = message || code
    const suffix = [stage, cause].filter(Boolean).join('：')
    if (primary && suffix) return `${primary}：${suffix}`
    if (primary) return primary
  }
  return body?.message || fallbackHTTPMessage(res, bodyText)
}

function stringValue(value: unknown) {
  return typeof value === 'string' ? value.trim() : ''
}

function fallbackHTTPMessage(res: Response, bodyText: string) {
  const detail = bodyText.trim()
  if (res.status === 502) return 'Admin API 暂不可用，请确认 agent-bus admin 后端已启动在 8082 端口'
  // 网关/负载均衡的 50x 兜底页是整页 HTML（内嵌 CSS/JS，能有几十 KB），不是
  // JSON 错误体——原样拼进错误消息会把这坨 HTML 整段糊在页面上；换成固定的
  // 网关错误提示，不展示原始 HTML。
  const isHTMLPage = /^<!doctype html/i.test(detail) || /^<html[\s>]/i.test(detail)
  if (isHTMLPage) return `HTTP ${res.status} ${res.statusText || ''}：网关/负载均衡返回了错误页面，不是接口本身的响应`.trim()
  if (detail) return `HTTP ${res.status} ${res.statusText}: ${detail}`
  if (!res.ok) return `HTTP ${res.status} ${res.statusText || 'Request failed'}`
  return 'Admin API 返回了空响应'
}
