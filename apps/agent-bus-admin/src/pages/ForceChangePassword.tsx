import { useEffect, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { LogOut, LockKeyhole, ShieldAlert } from 'lucide-react'
import { Auth, auth, type AccountSummary } from '../lib/api'
import { Button, FormField, InlineAlert, Input } from '../components/ui'

// 放在 <Layout> 外，作为登录流程页面：
//   - 不展示后台菜单
//   - 仅顶部显示账号与"退出登录"
//   - 改密成功后清 token，跳 /login 重新登录（旧 token 已被 backend revoke）
export function ForceChangePassword() {
  const nav = useNavigate()
  const [account, setAccount] = useState<AccountSummary | null>(null)
  const [newPwd, setNewPwd] = useState('')
  const [confirmPwd, setConfirmPwd] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [info, setInfo] = useState('')
  const isFirstPassword = account?.passwordSet === false

  useEffect(() => {
    if (!auth.token()) {
      nav('/login', { replace: true })
      return
    }
    Auth.me()
      .then((me) => {
        setAccount(me.account)
        // 已不再需要强改密 → 直接跳首页（防 deep link 误入）
        if (!me.account?.mustChangePassword) {
          nav('/', { replace: true })
        }
      })
      .catch(() => nav('/login', { replace: true }))
  }, [nav])

  const onLogout = async () => {
    try { await Auth.logout() } catch { /* ignore */ }
    auth.clearAll()
    nav('/login', { replace: true })
  }

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault()
    setErr('')
    setInfo('')
    if (newPwd.length < 8) {
      setErr(`${isFirstPassword ? '密码' : '新密码'}长度至少 8 位`)
      return
    }
    if (newPwd !== confirmPwd) {
      setErr(`两次输入的${isFirstPassword ? '密码' : '新密码'}不一致`)
      return
    }
    setBusy(true)
    try {
      // mustChangePassword=true 时后端不校验旧密码；新邀请账号此前没有密码。
      await Auth.changePassword('', newPwd)
      setInfo(`${isFirstPassword ? '密码设置' : '改密'}成功，正在跳转到登录页...`)
      // backend 已撤销所有 session / refresh + Redis account revoke；本地 token 失效
      auth.clearAll()
      setTimeout(() => nav('/login', { replace: true }), 800)
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="min-h-screen bg-[var(--color-bg)] text-[var(--color-text)]">
      {/* 顶部：账号 + 退出 */}
      <header className="flex items-center justify-between border-b border-[var(--color-line)] bg-white px-6 py-3">
        <div className="flex items-center gap-3">
          <span className="grid h-9 w-9 place-items-center rounded-lg bg-amber-50 text-amber-600">
            <ShieldAlert size={18} />
          </span>
          <div className="leading-tight">
            <div className="text-[15px] font-semibold">{isFirstPassword ? '首次登录 · 设置密码' : '首次登录 · 修改密码'}</div>
            <div className="text-[12px] text-slate-500">{isFirstPassword ? '设置密码后即可使用密码登录' : '完成改密后才能进入控制台'}</div>
          </div>
        </div>
        <div className="flex items-center gap-4">
          {account && (
            <div className="text-[13px] text-slate-600">
              <span className="text-slate-400">账号：</span>
              <span className="font-medium text-slate-900">
                {account.displayName || account.username || account.email || account.phone || `#${account.id}`}
              </span>
            </div>
          )}
          <Button type="button" variant="secondary" onClick={onLogout} className="h-9 gap-2 px-3 text-[13px]">
            <LogOut size={14} /> 退出登录
          </Button>
        </div>
      </header>

      {/* 主体 form */}
      <main className="mx-auto max-w-[480px] px-6 py-12">
        <div className="rounded-2xl border border-[var(--color-line)] bg-white p-8 shadow-[rgba(15,23,42,0.05)_0px_4px_24px]">
          <h1 className="text-[22px] font-semibold leading-tight">{isFirstPassword ? '设置密码' : '设置新密码'}</h1>
          <p className="mt-2 text-[14px] leading-6 text-slate-600">
            {isFirstPassword
              ? '你刚刚使用短信验证码完成身份验证，请为账号设置登录密码。设置完成后将自动退出。'
              : '为保障账号安全，请设置一个只有你本人知道的新密码。设置完成后将自动退出。'}
          </p>

          <form onSubmit={onSubmit} className="mt-6 space-y-4">
            {/* 首次设置/强制改密均已完成身份验证，不重复要求旧密码；
                后端 ChangePassword 在 mustChange=true 时跳过旧密码校验。 */}
            <FormField label={`${isFirstPassword ? '密码' : '新密码'}（≥ 8 位）`}>
              <div className="relative">
                <LockKeyhole className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
                <Input
                  type="password"
                  value={newPwd}
                  onChange={(e) => setNewPwd(e.target.value)}
                  className="h-11 pl-10"
                  autoFocus
                  required
                />
              </div>
            </FormField>

            <FormField label={`确认${isFirstPassword ? '密码' : '新密码'}`}>
              <div className="relative">
                <LockKeyhole className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
                <Input
                  type="password"
                  value={confirmPwd}
                  onChange={(e) => setConfirmPwd(e.target.value)}
                  className="h-11 pl-10"
                  required
                />
              </div>
            </FormField>

            {err && <InlineAlert>{err}</InlineAlert>}
            {info && <InlineAlert tone="info">{info}</InlineAlert>}

            <Button type="submit" disabled={busy} className="mt-2 h-11 w-full">
              {busy ? '提交中...' : `${isFirstPassword ? '设置' : '保存新'}密码并重新登录`}
            </Button>
          </form>
        </div>
      </main>
    </div>
  )
}
