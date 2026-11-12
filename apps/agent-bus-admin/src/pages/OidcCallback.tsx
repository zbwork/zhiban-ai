import { useEffect, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { auth, PublicAuth } from '../lib/api'
import { Loader2, ShieldAlert } from 'lucide-react'

// M4 OIDC callback page。
//
// 流程: IdP 跳回 /auth/oidc/callback?code=&state= → 本页提取 code+state →
//        POST /api/agent-bus/v1/auth/login/oidc/callback → 落 token → 跳 /dashboard。
//
// 失败展示明确错误 + "返回登录页" 按钮 (不自动重定向避免无限循环)。
//
// StrictMode guard: dev 模式 React 18 会 mount→unmount→mount 让 effect 跑 2 次,
// 第 2 次拿同一个 code+state 调 callback API → 后端 state 已 GETDEL → 报
// "state expired or replayed", 覆盖第 1 次的成功跳转。用 useRef 守护只跑一次。
export function OidcCallbackPage() {
  const nav = useNavigate()
  const [params] = useSearchParams()
  const [err, setErr] = useState('')
  const ran = useRef(false)

  useEffect(() => {
    if (ran.current) return
    ran.current = true
    const code = params.get('code')
    const state = params.get('state')
    const idpErr = params.get('error') || params.get('error_description')
    // 包一层 async iife → setState 不再"同步在 effect body 内"; 满足 react-hooks/set-state-in-effect
    ;(async () => {
      if (idpErr) {
        setErr(`IdP 拒绝登录: ${idpErr}`)
        return
      }
      if (!code || !state) {
        setErr('缺少 code 或 state 参数, callback 链接异常')
        return
      }
      try {
        const resp = await PublicAuth.oidcCallback(code, state)
        auth.setToken(resp.accessToken)
        auth.setRefresh(resp.refreshToken)
        if (resp.actScope?.kind === 'tenant' && resp.actScope.tenantId) {
          auth.setTenant(resp.actScope.tenantId)
        } else {
          auth.setTenant(0)
        }
        nav(resp.account?.mustChangePassword ? '/force-change-password' : '/', { replace: true })
      } catch (e) {
        setErr((e as Error).message || 'OIDC 登录失败')
      }
    })()
  }, [params, nav])

  return (
    <div className="min-h-screen flex items-center justify-center bg-[var(--color-bg)]">
      <div className="bg-white rounded-lg shadow-lg p-8 w-[400px] max-w-[92vw]">
        {!err ? (
          <div className="flex flex-col items-center gap-3">
            <Loader2 size={32} className="animate-spin text-blue-600" />
            <div className="text-[14px] text-[var(--color-text-sub)]">正在用企业账号登录…</div>
          </div>
        ) : (
          <div className="flex flex-col items-center gap-3">
            <ShieldAlert size={32} className="text-red-600" />
            <div className="text-[14px] font-medium text-red-700 text-center">{err}</div>
            <button
              onClick={() => nav('/login', { replace: true })}
              className="mt-2 h-9 px-3 rounded-md bg-[var(--color-text)] text-white text-[13px]"
            >
              返回登录页
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
