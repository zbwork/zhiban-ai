import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  ArrowRight, Eye, EyeOff, LockKeyhole, RotateCw, UserRound,
} from 'lucide-react'
import {
  Auth, auth, PublicAuth,
  type CaptchaResp, type PublicIdentityProvider, type ScopeOption,
} from '../lib/api'
import { Button, DialogShell, FormField, Input } from '../components/ui'
import { notifyError } from '../lib/toast'

type Tab = 'password' | 'sms'

/** 同一账号加入多家企业时,登录后让用户自己选进哪家。
 *
 * 不做选择的话控制台只会取 me.scopes 里的第一个 tenant scope(后端按 tenant_id 升序),
 * 于是加入了两家企业的人永远进不去 id 较大的那家。 */
function scopeKey(s: ScopeOption) {
  return `${s.kind}:${s.tenantId ?? 0}:${s.workspaceId ?? 0}`
}

function scopeLabel(s: ScopeOption) {
  if (s.kind === 'platform') return '平台管理'
  if (s.kind === 'workspace') return s.workspaceName || `工作空间 ${s.workspaceId ?? ''}`
  return s.tenantName || s.tenantSlug || `企业 ${s.tenantId ?? ''}`
}

export function Login() {
  const nav = useNavigate()
  const [tab, setTab] = useState<Tab>('password')
  const [busy, setBusy] = useState(false)

  // 账密 tab 状态
  const [identifier, setIdentifier] = useState('admin')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)

  // SMS tab 状态
  const [mobile, setMobile] = useState('')
  const [smsCode, setSmsCode] = useState('')
  const [captcha, setCaptcha] = useState<CaptchaResp | null>(null)
  const [captchaCode, setCaptchaCode] = useState('')
  const [smsCooldown, setSmsCooldown] = useState(0)
  const [smsSending, setSmsSending] = useState(false)
  const smsSendingRef = useRef(false)

  // 多企业账号:登录后先选进哪家(null = 不需要选)
  const [scopeChoices, setScopeChoices] = useState<ScopeOption[] | null>(null)
  const [switchingScope, setSwitchingScope] = useState('')

  // M4 SSO: 拉公开 IdP 列表; 渲染"用 X 登录"按钮
  const [ssoProviders, setSsoProviders] = useState<PublicIdentityProvider[]>([])
  useEffect(() => {
    PublicAuth.listIdentityProviders()
      .then(setSsoProviders)
      .catch(() => setSsoProviders([])) // 静默: 没配 SSO 也不该把 Login 页挂掉
  }, [])

  const onSsoLogin = async (uuid: string) => {
    try {
      const r = await PublicAuth.oidcStart(uuid, '/dashboard')
      // window.location.assign 是行为一致但 lint-friendly 的替代 (react-hooks/immutability 禁止赋值 location.href)
      window.location.assign(r.authUrl)
    } catch (e) {
      notifyError((e as Error).message || 'SSO 启动失败')
    }
  }

  const refreshCaptcha = useCallback(async () => {
    try {
      const c = await Auth.captcha()
      setCaptcha(c)
      setCaptchaCode('')
    } catch {
      // API errors are surfaced by the global toast.
    }
  }, [])

  // SMS 冷却倒计时
  useEffect(() => {
    if (smsCooldown <= 0) return
    const t = setTimeout(() => setSmsCooldown(smsCooldown - 1), 1000)
    return () => clearTimeout(t)
  }, [smsCooldown])

  // 冷却从 >0 → 0 的临界点自动刷新图形码 (旧 captcha 已被服务端消费, 用户重发前必须输新值)。
  // 用 ref 跟踪上一次值, 避免首次进入页面 (cooldown=0) 触发额外刷新。
  const prevCooldownRef = useRef(smsCooldown)
  useEffect(() => {
    if (prevCooldownRef.current > 0 && smsCooldown === 0) {
      refreshCaptcha()
    }
    prevCooldownRef.current = smsCooldown
  }, [smsCooldown, refreshCaptcha])

  const onSendSms = async () => {
    if (smsSendingRef.current || smsCooldown > 0) return
    if (!mobile) {
      notifyError('请输入手机号')
      return
    }
    if (!captcha || !captchaCode) {
      notifyError('请输入图形验证码')
      return
    }
    try {
      smsSendingRef.current = true
      setSmsSending(true)
      await Auth.sendSms(mobile, captcha.captchaId, captchaCode, 'login')
      setSmsCooldown(60)
      // 后端已消费图形码; /auth/login/sms 不再用图形码, 所以发送成功后不拉新图,
      // 保留已用的旧图 + 用户已输入的文案, 仅置灰显示 (见 captcha 区 disabled 逻辑)。
      // 冷却结束 (smsCooldown=0) 时若用户再次发短信再 refresh。
    } catch (e) {
      if (/cooldown not elapsed|短信发送过于频繁/.test((e as Error).message || '')) {
        setSmsCooldown((current) => (current > 0 ? current : 60))
      }
      // 失败 (captcha 错 / 冷却中 / 后端拒) → 旧 captcha 已被服务端消费, 必须刷新。
      refreshCaptcha()
    } finally {
      smsSendingRef.current = false
      setSmsSending(false)
    }
  }


  const rememberActScope = (scope?: ScopeOption) => {
    auth.setTenant(scope?.kind === 'tenant' && scope.tenantId ? scope.tenantId : 0)
  }

  /** 登录成功后决定去向:多企业先选,单企业(或拉不到 scope)保持原行为直接进控制台。 */
  const enterConsole = async () => {
    try {
      const me = await Auth.me()
      const options = me.scopes || []
      if (options.filter((s) => s.kind === 'tenant').length > 1) {
        setScopeChoices(options)
        return
      }
    } catch {
      // 拉 scope 失败不该把人挡在登录页:退回原来的直接进入。
    }
    nav('/')
  }

  const onPickScope = async (scope: ScopeOption) => {
    setSwitchingScope(scopeKey(scope))
    try {
      const resp = await Auth.switchScope(scope.kind, scope.tenantId, scope.workspaceId)
      auth.setToken(resp.accessToken)
      auth.setRefresh(resp.refreshToken)
      rememberActScope(resp.actScope)
      nav('/')
    } catch {
      // 切换失败由全局 toast 提示,弹层保持打开让用户重选。
    } finally {
      setSwitchingScope('')
    }
  }

  /** 放弃选择 = 放弃这次登录:留着一个没选定企业的会话只会又落回第一家。 */
  const cancelScopeChoice = () => {
    setScopeChoices(null)
    auth.clearAll()
  }

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    try {
      const resp =
        tab === 'password'
          ? await Auth.loginPassword(identifier, password)
          : await Auth.loginSms(mobile, smsCode)
      auth.setToken(resp.accessToken)
      auth.setRefresh(resp.refreshToken)
      rememberActScope(resp.actScope)
      // 必须改密 → 强制走改密流程，不进入控制台
      if (resp.account?.mustChangePassword) {
        nav('/force-change-password', { replace: true })
      } else {
        await enterConsole()
      }
    } catch {
      // API errors are surfaced by the global toast.
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-stage-bg box-border min-h-[100dvh] overflow-auto p-[clamp(16px,3vw,48px)] text-[var(--color-text)] xl:h-[100dvh] xl:overflow-hidden">
      <main className="login-stage-shell relative mx-auto flex min-h-[calc(100dvh-32px)] w-full max-w-[1680px] items-center rounded-[24px] border border-white/80 sm:min-h-[calc(100dvh-48px)] xl:h-full xl:min-h-0">
        <div className="relative grid w-full items-center gap-[clamp(24px,4vw,56px)] p-[clamp(24px,4vw,64px)] xl:grid-cols-[minmax(0,1fr)_minmax(390px,462px)] 2xl:grid-cols-[minmax(0,680px)_minmax(440px,520px)] 2xl:justify-between">
          <section className="hidden xl:block">
            <div className="flex items-center gap-3 whitespace-nowrap xl:gap-4 2xl:gap-5">
              <BlueBrandLogo size="lg" />
              <div className="flex items-baseline gap-3 xl:gap-4">
                <span className="text-[34px] font-bold leading-none tracking-tight text-[#07122f] xl:text-[44px] 2xl:text-[56px]">知办AI</span>
                <span className="text-[18px] font-medium leading-none tracking-tight text-[#1f2d4f] xl:text-[22px] 2xl:text-[26px]">管理后台</span>
              </div>
            </div>

            <div className="brand-accent-line ml-[14px] mt-3 xl:mt-4 2xl:mt-5" />

            <div className="mt-3 max-w-[600px] xl:mt-4 2xl:mt-5 2xl:max-w-[690px]">
              <div className="text-[18px] font-semibold leading-tight xl:text-[20px] 2xl:text-[22px]" style={{ color: 'var(--color-brand)' }}>
                企业级数字身份与权限管理平台
              </div>
              <p className="mt-2 max-w-[520px] text-[14px] leading-6 text-slate-500 xl:text-[16px] 2xl:max-w-[620px] 2xl:text-[18px] 2xl:leading-7">
                一站式管理数字员工、组织权限与访问控制。
              </p>
            </div>

            <div className="login-feature-grid mt-12 xl:mt-14 2xl:mt-16">
              {[
                {
                  title: '数字员工管理',
                  desc: '配置与管理企业数字员工，统一身份入口',
                  image: '/login-assets/feature-employee.png',
                },
                {
                  title: '组织权限管控',
                  desc: '基于角色与作用域的细粒度权限分发',
                  image: '/login-assets/feature-permission.png',
                },
                {
                  title: '全链路审计追踪',
                  desc: '所有访问操作留痕，审计日志可追溯',
                  image: '/login-assets/feature-audit.png',
                },
              ].map((item) => <FeatureCard key={item.title} {...item} />)}
            </div>
          </section>

          <div className="mx-auto w-full max-w-[430px] xl:max-w-[462px] 2xl:max-w-[520px]">
            <div className="mb-8 flex items-center gap-3 lg:hidden">
              <BlueBrandLogo />
              <div>
                <div className="text-[17px] font-semibold tracking-tight">知办AI 管理后台</div>
                <div className="text-[13px] text-slate-500">Admin Console</div>
              </div>
            </div>
            <section className="login-panel-card relative flex flex-col rounded-[24px] border border-white/90 bg-white/[0.95] p-7 backdrop-blur-xl sm:p-9 lg:min-h-[500px] lg:px-8 lg:py-8 xl:min-h-[512px] xl:px-9 2xl:min-h-[548px] 2xl:px-10 2xl:py-10">
              <div className="mb-5 2xl:mb-7">
                <h2 className="login-panel-title text-[28px] leading-[1.18] tracking-[0] sm:text-[30px] 2xl:text-[32px]">登录控制台</h2>
                <p className="mt-3 text-[14px] leading-6 text-[#40516f] 2xl:text-[15px]">
                  使用账号密码或手机短信码进入 知办AI 管理后台。
                </p>
              </div>

              <div className="login-auth-tabs mb-4 grid grid-cols-2 rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-1.5 shadow-[inset_0_1px_2px_rgba(15,23,42,0.04)] 2xl:mb-6">
                {[
                  { value: 'password' as const, label: '账号密码' },
                  { value: 'sms' as const, label: '手机短信码' },
                ].map((item) => (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() => {
                      setTab(item.value)
                      if (item.value === 'sms' && !captcha) refreshCaptcha()
                    }}
                    className={[
                      'login-auth-tab-button flex items-center justify-center rounded-md text-[14px] font-semibold transition 2xl:text-[15px]',
                      tab === item.value
                        ? 'login-primary-gradient text-white shadow-[rgba(15,107,255,0.30)_0px_10px_24px]'
                        : 'text-[#40516f] hover:text-[#17223b]',
                    ].join(' ')}
                  >
                    {item.label}
                  </button>
                ))}
              </div>

              <form onSubmit={onSubmit} className="flex flex-col">
                <div className={[
                  'space-y-4 2xl:space-y-5',
                  tab === 'password' ? 'min-h-0' : 'min-h-[252px] 2xl:min-h-[282px]',
                ].join(' ')}>
                  {tab === 'password' ? (
                    <>
                      <FormField label="账号">
                        <div className="relative">
                          <UserRound className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" size={18} />
                          <Input
                            type="text"
                            value={identifier}
                            onChange={(e) => setIdentifier(e.target.value)}
                            className="login-input h-[46px] rounded-lg border-slate-200 pl-12 text-[14px] text-[#101828] shadow-[rgba(15,23,42,0.04)_0px_1px_2px] 2xl:h-[52px] 2xl:text-[15px]"
                            placeholder="手机号 / 邮箱 / 用户名"
                            required
                            autoFocus
                          />
                        </div>
                      </FormField>
                      <FormField label="密码">
                        <div className="relative">
                          <LockKeyhole className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" size={18} />
                          <Input
                            type={showPassword ? 'text' : 'password'}
                            value={password}
                            onChange={(e) => setPassword(e.target.value)}
                            className="login-input h-[46px] rounded-lg border-slate-200 pl-12 pr-12 text-[14px] text-[#101828] shadow-[rgba(15,23,42,0.04)_0px_1px_2px] 2xl:h-[52px] 2xl:text-[15px]"
                            required
                          />
                          <button
                            type="button"
                            onClick={() => setShowPassword((v) => !v)}
                            className="absolute right-3 top-1/2 grid h-8 w-8 -translate-y-1/2 place-items-center rounded text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                            aria-label={showPassword ? '隐藏密码' : '显示密码'}
                          >
                            {showPassword ? <EyeOff size={15} /> : <Eye size={15} />}
                          </button>
                        </div>
                      </FormField>
                      <div className="flex items-center justify-between py-1 text-[13px] text-[#40516f] 2xl:py-1.5">
                        <label className="inline-flex items-center gap-2">
                          <input type="checkbox" className="h-4 w-4 rounded border-slate-300 accent-blue-600" defaultChecked />
                          记住账号
                        </label>
                        <button type="button" className="font-medium text-blue-600 hover:text-blue-700">
                          忘记密码？
                        </button>
                      </div>
                    </>
                  ) : (
                    <>
                      <FormField label="手机号">
                        <Input
                          type="tel"
                          value={mobile}
                          onChange={(e) => setMobile(e.target.value)}
                          className="login-input h-[46px] rounded-lg border-slate-200 text-[14px] text-[#101828] shadow-[rgba(15,23,42,0.04)_0px_1px_2px] 2xl:h-[52px] 2xl:text-[15px]"
                          placeholder="请输入手机号"
                          required
                          autoFocus
                        />
                      </FormField>
                      <FormField label="图形验证码">
                        <div className="flex gap-2">
                          <Input
                            type="text"
                            value={captchaCode}
                            onChange={(e) => setCaptchaCode(e.target.value)}
                            className="login-input h-[46px] flex-1 rounded-lg border-slate-200 text-[14px] text-[#101828] shadow-[rgba(15,23,42,0.04)_0px_1px_2px] 2xl:h-[52px] 2xl:text-[15px] disabled:bg-slate-50 disabled:text-slate-400"
                            placeholder="字母 / 数字"
                            required={smsCooldown === 0}
                            disabled={smsCooldown > 0}
                          />
                          {captcha?.captchaImage ? (
                            <button
                              type="button"
                              onClick={refreshCaptcha}
                              disabled={smsCooldown > 0}
                              className="grid h-[46px] w-[104px] place-items-center rounded-lg border border-slate-200 bg-white 2xl:h-[52px] 2xl:w-[108px] disabled:cursor-not-allowed disabled:opacity-50"
                              title={smsCooldown > 0 ? '冷却结束后可重新输入' : '点击刷新'}
                            >
                              <img src={captcha.captchaImage} alt="captcha" className="max-h-9 object-contain" />
                            </button>
                          ) : (
                            <Button type="button" variant="secondary" onClick={refreshCaptcha} className="h-[46px] w-[104px] 2xl:h-[52px] 2xl:w-[108px]">
                              <RotateCw size={14} />
                            </Button>
                          )}
                        </div>
                      </FormField>
                      <FormField label="短信验证码">
                        <div className="flex gap-2">
                          <Input
                            type="text"
                            value={smsCode}
                            onChange={(e) => setSmsCode(e.target.value)}
                            className="login-input h-[46px] flex-1 rounded-lg border-slate-200 text-[14px] text-[#101828] shadow-[rgba(15,23,42,0.04)_0px_1px_2px] 2xl:h-[52px] 2xl:text-[15px]"
                            placeholder="6 位数字"
                            required
                          />
                          <Button
                            type="button"
                            variant="secondary"
                            disabled={smsSending || smsCooldown > 0}
                            onClick={onSendSms}
                            className="h-[46px] w-[88px] 2xl:h-[52px]"
                          >
                            {smsCooldown > 0 ? `${smsCooldown}s` : smsSending ? '发送中' : '发送'}
                          </Button>
                        </div>
                      </FormField>
                    </>
                  )}
                </div>

                <div className="pt-6 2xl:pt-8">
                  <button
                    type="submit"
                    disabled={busy}
                    className="login-primary-gradient inline-flex h-[52px] w-full items-center justify-center gap-3 rounded-lg text-[16px] font-semibold text-white shadow-[rgba(15,107,255,0.35)_0px_13px_28px] transition hover:brightness-95 disabled:cursor-not-allowed disabled:opacity-60 2xl:h-[60px] 2xl:text-[17px]"
                  >
                    {busy ? '登录中...' : '登录'}
                    {!busy && <ArrowRight size={16} />}
                  </button>
                </div>
              </form>

              {ssoProviders.length > 0 && (
                <div className="mt-6">
                  <div className="relative my-4">
                    <div className="absolute inset-0 flex items-center"><div className="w-full border-t border-[var(--color-border)]" /></div>
                    <div className="relative flex justify-center text-[11px]">
                      <span className="bg-white px-3 text-[var(--color-text-sub)]">或使用企业账号</span>
                    </div>
                  </div>
                  <div className="space-y-2">
                    {ssoProviders.map((p) => (
                      <button
                        key={p.uuid}
                        type="button"
                        onClick={() => onSsoLogin(p.uuid)}
                        className="inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg ring-border bg-white text-[14px] font-medium hover:bg-[var(--color-bg-soft)] transition"
                      >
                        <LockKeyhole size={14} /> {p.name}
                      </button>
                    ))}
                  </div>
                </div>
              )}

            </section>
          </div>
        </div>
      </main>

      {scopeChoices && (
        <DialogShell
          title="选择要进入的企业"
          subtitle="你的账号加入了多家企业，进入后可退出重新登录切换。"
          size="sm"
          onClose={cancelScopeChoice}
          footer={
            <Button variant="secondary" onClick={cancelScopeChoice} disabled={!!switchingScope}>
              取消
            </Button>
          }
        >
          <div className="flex flex-col gap-2">
            {scopeChoices.map((s) => (
              <button
                key={scopeKey(s)}
                type="button"
                onClick={() => onPickScope(s)}
                disabled={!!switchingScope}
                className="flex w-full items-center justify-between gap-3 rounded-md border border-[var(--color-line)] bg-white px-4 py-3 text-left transition hover:border-[var(--color-brand-line)] hover:bg-[var(--color-brand-soft)] disabled:cursor-not-allowed disabled:opacity-60"
              >
                <span className="min-w-0">
                  <span className="block truncate text-[14px] font-medium text-[var(--color-text)]">
                    {scopeLabel(s)}
                  </span>
                  <span className="mt-0.5 block truncate text-[12px] text-[var(--color-text-mute)]">
                    {s.kind === 'platform' ? '平台级管理权限' : s.tenantSlug || `企业 ID ${s.tenantId ?? ''}`}
                  </span>
                </span>
                {switchingScope === scopeKey(s) ? (
                  <RotateCw size={16} className="shrink-0 animate-spin text-[var(--color-text-mute)]" />
                ) : (
                  <ArrowRight size={16} className="shrink-0 text-[var(--color-text-mute)]" />
                )}
              </button>
            ))}
          </div>
        </DialogShell>
      )}
    </div>
  )
}

function BlueBrandLogo({ size = 'md' }: { size?: 'md' | 'lg' }) {
  const box = size === 'lg'
    ? 'h-[56px] w-[56px] rounded-[14px] xl:h-[68px] xl:w-[68px] xl:rounded-[16px] 2xl:h-[80px] 2xl:w-[80px] 2xl:rounded-[18px]'
    : 'h-12 w-12 rounded-[13px]'
  return (
    <img
      src="/zhiban-logo.png"
      alt="知办AI logo"
      className={`${box} shrink-0 object-cover shadow-[rgba(15,107,255,0.24)_0px_16px_38px]`}
    />
  )
}

function FeatureCard({
  title,
  desc,
  image,
}: {
  title: string
  desc: string
  image: string
}) {
  return (
    <div className="login-feature-card">
      <div className="login-feature-icon">
        <img src={image} alt="" className="login-feature-image" aria-hidden="true" />
      </div>
      <div className="login-feature-title">{title}</div>
      <div className="login-feature-desc">{desc}</div>
    </div>
  )
}
