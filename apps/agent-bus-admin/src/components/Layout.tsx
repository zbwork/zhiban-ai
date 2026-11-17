import { useEffect, useState, useMemo, useRef } from 'react'
import { flushSync } from 'react-dom'
import { Outlet, useLocation, useNavigate, Link } from 'react-router-dom'
import { A2AApprovalsAdmin, Alerts, Auth, clearInflightGet, parseAccessToken, type Menu, type AccountSummary, type ScopeOption, auth } from '../lib/api'
import { iconFor } from '../lib/icons'
import { PAGE_MENUS } from '../lib/pageMenus'
import { FormField, Select, EmptyState } from './ui'
import clsx from 'clsx'
import { canViewAdminRoute, isUnrestrictedScope } from '../lib/adminPermissions'
import {
  LogOut, ChevronDown, User as UserIcon, Key as KeyIcon, MessageSquare,
  Home, Building2, Briefcase, Cpu, Settings2, ShieldCheck, UsersRound,
  Bot, Wand2, BookOpen, HardDrive, MessagesSquare, Shield, ListChecks, Layers,
  PanelLeftOpen, X, Activity, Bell,
} from 'lucide-react'

export type LayoutOutletContext = {
  actScope: ScopeOption | null
  switchingScope: boolean
}

type ManagementView = 'platform' | 'tenant'

// IA round-2: admin web 严格按 docs/tasks §F.5 目标菜单。10 个平台 / 10 个租户分组顺序见下。
// 不允许出现 "能力装配 / 知办AI SkillHub / Composer / Runtime 接入 / KB Provider" 这类技术词。
const GROUP_ORDER_BY_VIEW: Record<ManagementView, string[]> = {
  platform: [
    '概览', '租户管理', '企业管理', 'Agent 平台', '技能中心', '应用管理',
    '知识库', '云盘', '群组与协同', '任务与自动化', '系统管理', '监控与告警', '审计与合规', '平台管理',
  ],
  tenant: [
    '概览', '数字员工', '技能中心', '应用管理', '知识库',
    '云盘', '任务', '组织与人员', '群聊与协同', '凭证与接入', '系统管理', '监控与告警', '审计与合规',
  ],
}

const DEFAULT_OPEN_GROUPS = new Set(['概览'])
const A2A_APPROVALS_CHANGED_EVENT = 'a2a-approvals:changed'
// F25 铃铛刷新事件（与 pages/AlertCenter.tsx 的 ALERTS_CHANGED_EVENT 字面量保持一致）
const ALERTS_CHANGED_EVENT = 'alerts:changed'
// F25 铃铛轮询间隔：低频轮询 + 页面操作事件即时刷新，不做秒级轮询
const ALERTS_POLL_MS = 60_000
const GROUP_ICONS = {
  '概览': Home,
  '租户管理': Building2,
  '企业管理': Briefcase,
  'Agent 平台': Cpu,
  '技能中心': Wand2,
  '应用管理': Settings2,
  '知识库与云盘': BookOpen,
  '知识库': BookOpen,
  '云盘': HardDrive,
  '群组与协同': MessagesSquare,
  '任务与自动化': ListChecks,
  '任务': ListChecks,
  '数字员工': Bot,
  '系统管理': ShieldCheck,
  '组织与人员': UsersRound,
  '审批与协同': MessagesSquare,
  '群聊与协同': MessageSquare,
  '监控与告警': Activity,
  '凭证与接入': KeyIcon,
  '审计与合规': Shield,
  '平台管理': Settings2,
} satisfies Record<string, React.ComponentType<{ size?: number; className?: string }>>

// 路由 → 产品化中文菜单名 (DB seed 兜底)；scope 敏感的 (/apps /rooms) 不写在这里，让 DB 行的 name 直出。
const MENU_NAME_OVERRIDES: Record<string, string> = {
  '/dashboard': '概览',
  '/client-analytics': '客户端分析',
  // platform
  '/tenants': '租户管理',
  '/alerts': '告警中心',
  '/runtimes': '运行环境',
  '/platform-types': 'Agent 平台类型',
  '/runtime-hosting': '平台托管配置',
  '/preset-agents': '数字员工模版',
  // 技能中心 (平台 4 项 + 租户 1 项): 名称在 SQL 000100 已 seed,
  // 这里保留兜底, 防 sys_menus 落库失败时 admin web 仍能展示中文。
  '/skills': '技能管理',
  '/skill-categories': '技能分类',
  '/skill-labels': '技能标签',
  '/builtin-keys': '客户端能力注册表',
  '/tenant-skills/platform': '平台技能',
  '/tenant-skills/own': '企业技能',
  '/app-categories': '应用分类',
  '/kb-providers': '知识库服务配置',
  '/ragflow-ops': '监控运维',
  '/platform-kb': '知识库管理',
  '/user-kb-inspect': '用户知识库审计',
  // F06 Phase 4: /drive-s3 旧入口已废, 不再列入 overrides.
  // F06 Phase 3 IA cutover: 平台 / 租户 drive 子路由产品名.
  // 平台 scope 三项:
  '/drive/storage': '云盘存储配置',
  '/drive/usage': '云盘用量',
  '/drive/workers': '云盘定时任务',
  // 租户 scope 三项 (/drive 已在下方 tenant 区注册名 "企业云盘"):
  '/drive/quotas': '云盘配额',
  '/drive/recycle': '云盘回收站',
  '/drive/storage-override': '专属云盘存储',
  '/wukongim': 'IM 运行监控',
  '/cron-dashboard': '统计看板',
  '/cron-jobs': '定时任务列表',
  '/cron-prompt-templates': '定时任务模板',
  '/cron-prompt-templates-ops': '定时任务模板',
  '/roles': '权限与角色',
  '/menus': '菜单管理',
  '/sys-users': '系统用户',
  '/audit': '审计日志',
  '/observability/call-logs': '调用日志',
  '/support-feedback': '问题反馈',
  '/marketing-leads': '官网线索',
  '/download-channels': '下载渠道',
  // F24 企业管理 (创业助手运营, sys_menu 000101/000103 迁移落库)
  '/startup-agent-cases': '企业注册申请',
  '/bookkeeping-tickets': '代理记账工单',
  '/provider-pricing': '服务商与定价',
  '/company-profiles': '企业档案',
  '/web-leads': '创业助手咨询单',
  '/web-funnel': '获客漏斗',
  '/web-feedback': '回复反馈',
  '/share-growth': '用户分享',
  // F01 凭证与接入 (新加, sys_menu 000056 迁移落库)
  '/api-keys': 'API Key 管理',
  '/org-sync': '组织同步',
  '/agent-sdk-credentials': 'Agent SDK 凭证',
  '/sso-config': '单点登录 (SSO)',
  // tenant
  '/agents': '数字员工列表',
  '/workspace-apps': '工作台应用',
  '/kb': '知识库管理',
  '/kb-documents': '文档管理',
  '/drive': '企业云盘',
  '/cron': '定时任务',
  '/members': '成员',
  '/departments': '部门',
  '/positions': '职位',
  '/contacts': '通讯录配置',
  // F09 Phase B.4 / PR8: A2A 治理 + Orchestration + Speaker 策略 (sys_menus 000128 也已落库)
  '/rooms/a2a': 'A2A 调用治理',
  '/rooms/orchestrations': '协作编排',
  '/rooms/speaker-policies': 'Speaker 策略',
  '/approvals': '审批',
}

export function Layout({ showAllPages = false }: { showAllPages?: boolean }) {
  const nav = useNavigate()
  const navRef = useRef(nav)
  const pendingScopeRef = useRef<ScopeOption | null>(null)
  const loc = useLocation()
  const [menus, setMenus] = useState<Menu[]>([])
  const [account, setAccount] = useState<AccountSummary | null>(null)
  const [scopes, setScopes] = useState<ScopeOption[]>([])
  const [actScope, setActScope] = useState<ScopeOption | null>(null)
  const [loading, setLoading] = useState(true)
  const [menuOpen, setMenuOpen] = useState(false)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [switching, setSwitching] = useState(false)
  const [viewMode, setViewMode] = useState<ManagementView>('platform')
  const [openGroups, setOpenGroups] = useState<Set<string>>(new Set())
  const [closedGroups, setClosedGroups] = useState<Set<string>>(new Set())
  const [pendingApprovalCount, setPendingApprovalCount] = useState<number | null>(null)
  const [firingAlertCount, setFiringAlertCount] = useState<number | null>(null)

  useEffect(() => {
    navRef.current = nav
  }, [nav])

  useEffect(() => {
    const pending = pendingScopeRef.current
    if (!pending) return
    pendingScopeRef.current = null
    setActScope(pending)
    setViewMode(viewForScope(pending) || 'platform')
    setSwitching(false)
  }, [loc.pathname])

  useEffect(() => {
    if (!auth.token()) {
      navRef.current('/login')
      return
    }
    Promise.all([Auth.me(), showAllPages ? Promise.resolve(PAGE_MENUS) : Auth.menus()])
      .then(([me, ms]) => {
        // 必须改密的账号不能进入控制台（即使直接敲 URL）
        if (me.account?.mustChangePassword) {
          navRef.current('/force-change-password', { replace: true })
          return
        }
        const nextScopes = me.scopes || []
        setAccount(me.account)
        setScopes(nextScopes)
        setActScope(me.actScope || null)
        setViewMode(defaultViewForScopes(nextScopes, me.actScope || null))
        setMenus(ms || [])
      })
      .catch(() => navRef.current('/login'))
      .finally(() => setLoading(false))
  }, [showAllPages])

  const currentView = useMemo(
    () => normalizeView(viewMode, scopes, actScope),
    [actScope, scopes, viewMode]
  )
  const availableViews = useMemo(() => {
    const out: ManagementView[] = []
    if (scopes.some((s) => s.kind === 'platform')) out.push('platform')
    if (scopes.some((s) => s.kind === 'tenant' || s.kind === 'workspace')) out.push('tenant')
    return out
  }, [scopes])

  // M1: 路由不带 /platform 或 /tenant 前缀；左侧菜单按当前管理视图过滤。
  // 同一路由若有多个 scope 版本，保留当前视图对应的菜单项。
  const menuSections = useMemo(() => {
    type Item = Menu & { group: string }
    const unrestricted = isUnrestrictedScope(scopes, actScope)
    const rawItems: Item[] = menus
      .filter((m) => unrestricted || canViewAdminRoute(m.route))
      .filter((m) => menuBelongsToView(m, currentView))
      .map((m) => ({ ...m, group: menuGroup(m, currentView) }))
    const byRoute = new Map<string, Item>()
    rawItems.forEach((it) => {
      const prev = byRoute.get(it.route)
      if (!prev || menuPriority(it, currentView) < menuPriority(prev, currentView)) {
        byRoute.set(it.route, it)
      }
    })
    const items = Array.from(byRoute.values())

    const groups = new Map<string, Item[]>()
    items.forEach((it) => {
      if (!groups.has(it.group)) groups.set(it.group, [])
      groups.get(it.group)!.push(it)
    })
    groups.forEach((arr, group) => arr.sort((a, b) => menuItemOrder(a, group) - menuItemOrder(b, group)))
    return Array.from(groups.entries()).sort(([a], [b]) => {
      const groupOrder = GROUP_ORDER_BY_VIEW[currentView]
      const ia = groupOrder.indexOf(a)
      const ib = groupOrder.indexOf(b)
      if (ia === -1 && ib === -1) return a.localeCompare(b)
      if (ia === -1) return 1
      if (ib === -1) return -1
      return ia - ib
    })
  }, [currentView, menus, scopes, actScope])

  useEffect(() => {
    if (!loading && (loc.pathname === '/' || loc.pathname === '/dashboard') && !isUnrestrictedScope(scopes, actScope) && !canViewAdminRoute('/dashboard')) {
      const first = menuSections.flatMap(([, items]) => items)[0]
      if (first) nav(first.route, { replace: true })
    }
  }, [loading, loc.pathname, scopes, actScope, menuSections, nav])

  const activeMenuRoute = useMemo(() => {
    let best = ''
    for (const [, items] of menuSections) {
      for (const item of items) {
        if (!item.route) continue
        const matched = loc.pathname === item.route || loc.pathname.startsWith(item.route + '/')
        if (matched && item.route.length > best.length) {
          best = item.route
        }
      }
    }
    return best
  }, [loc.pathname, menuSections])

  const activeGroup = useMemo(() => {
    for (const [group, items] of menuSections) {
      if (items.some((m) => m.route === activeMenuRoute)) {
        return group
      }
    }
    return ''
  }, [activeMenuRoute, menuSections])

  // Static page links do not advertise server capabilities or trigger badge requests.
  const canShowApprovalBadge = useMemo(
    () => currentView === 'tenant' && !showAllPages && menuSections.some(([, items]) => items.some((item) => item.route === '/approvals')),
    [currentView, menuSections, showAllPages],
  )

  useEffect(() => {
    if (!canShowApprovalBadge) {
      return undefined
    }
    let cancelled = false
    A2AApprovalsAdmin.list({ status: 'pending', limit: 1, offset: 0 })
      .then((resp) => {
        if (!cancelled) setPendingApprovalCount(resp.total || 0)
      })
      .catch(() => {
        if (!cancelled) setPendingApprovalCount(null)
      })
    return () => {
      cancelled = true
    }
  }, [actScope?.tenantId, canShowApprovalBadge])

  useEffect(() => {
    const refresh = () => {
      if (!canShowApprovalBadge) return
      A2AApprovalsAdmin.list({ status: 'pending', limit: 1, offset: 0 })
        .then((resp) => setPendingApprovalCount(resp.total || 0))
        .catch(() => setPendingApprovalCount(null))
    }
    window.addEventListener(A2A_APPROVALS_CHANGED_EVENT, refresh)
    return () => window.removeEventListener(A2A_APPROVALS_CHANGED_EVENT, refresh)
  }, [canShowApprovalBadge])

  // F25 告警铃铛：菜单里有 /alerts（即持有 *.alerts.read）才拉取；当前 scope 决定平台/租户计数。
  const canShowAlertBell = useMemo(
    () => !showAllPages && menuSections.some(([, items]) => items.some((item) => item.route === '/alerts')),
    [menuSections, showAllPages],
  )

  useEffect(() => {
    // 铃铛不可见时不拉取；渲染侧已由 canShowAlertBell 守卫，无需同步清零计数
    if (!canShowAlertBell) {
      return undefined
    }
    const scope = currentView === 'platform' ? 'platform' as const : 'tenant' as const
    let cancelled = false
    const fetchCount = () => {
      Alerts.unhandledCount(scope)
        .then((resp) => { if (!cancelled) setFiringAlertCount(resp.count ?? 0) })
        .catch(() => { if (!cancelled) setFiringAlertCount(null) })
    }
    fetchCount()
    const timer = window.setInterval(fetchCount, ALERTS_POLL_MS)
    window.addEventListener(ALERTS_CHANGED_EVENT, fetchCount)
    return () => {
      cancelled = true
      window.clearInterval(timer)
      window.removeEventListener(ALERTS_CHANGED_EVENT, fetchCount)
    }
  }, [canShowAlertBell, currentView, actScope?.tenantId])

  const toggleGroup = (group: string) => {
    const isOpen = isGroupOpen(group, activeGroup, openGroups, closedGroups)
    setOpenGroups((prev) => {
      const next = new Set(prev)
      if (isOpen) next.delete(group)
      else next.add(group)
      return next
    })
    setClosedGroups((prev) => {
      const next = new Set(prev)
      // 删掉 activeGroup !== group 守卫: 用户点 chevron 就听用户的, 当前组也允许关闭
      if (isOpen) next.add(group)
      else next.delete(group)
      return next
    })
  }

  const switchScope = async (scope: ScopeOption, nextRoute = '/dashboard') => {
    if (switching) return
    flushSync(() => setSwitching(true))
    try {
      const resp = await Auth.switchScope(scope.kind, scope.tenantId, scope.workspaceId)
      auth.setToken(resp.accessToken)
      if (resp.refreshToken) auth.setRefresh(resp.refreshToken)
      auth.setTenant(resp.actScope.kind === 'tenant' ? resp.actScope.tenantId || 0 : 0)
      clearInflightGet()
      setAccount(resp.account || account)
      setMenuOpen(false)
      pendingScopeRef.current = resp.actScope
      nav(nextRoute)
      if (loc.pathname === nextRoute) {
        pendingScopeRef.current = null
        setActScope(resp.actScope)
        setViewMode(viewForScope(resp.actScope) || currentView)
        setSwitching(false)
      }
    } catch (err) {
      pendingScopeRef.current = null
      setSwitching(false)
      throw err
    }
  }

  const switchManagementView = async (nextView: ManagementView) => {
    if (nextView === currentView || switching) return
    const nextScope = defaultScopeForView(nextView, scopes)
    if (!nextScope) return
    await switchScope(nextScope, '/dashboard')
  }

  const openMenu = async (e: React.MouseEvent<HTMLAnchorElement>, menu: Menu) => {
    const targetScope = scopeForMenu(menu, actScope, scopes)
    if (!targetScope || sameScope(targetScope, actScope)) return
    e.preventDefault()
    await switchScope(targetScope, menu.route)
  }

  if (loading) {
    return (
      <div className="flex h-[100dvh] items-center justify-center text-sm text-[var(--color-text-mute)]">
        Loading…
      </div>
    )
  }

  return (
    <div className="admin-app-bg flex h-[100dvh] overflow-hidden text-[var(--color-text)]">
      <div
        className={clsx(
          'fixed inset-0 z-30 bg-slate-950/20 backdrop-blur-[2px] transition-opacity lg:hidden',
          sidebarOpen ? 'opacity-100' : 'pointer-events-none opacity-0'
        )}
        onClick={() => setSidebarOpen(false)}
      />
      {/* Sidebar */}
      <aside
        className={clsx(
          'fixed inset-y-0 left-0 z-40 flex h-full w-[min(82vw,272px)] shrink-0 flex-col border-r border-[var(--color-line)] bg-white/[0.97] shadow-[rgba(15,107,255,0.12)_12px_0px_40px] backdrop-blur transition-transform duration-200 ease-out lg:relative lg:z-auto lg:w-[272px] lg:translate-x-0 lg:bg-white/[0.95] lg:shadow-[rgba(15,107,255,0.05)_12px_0px_40px]',
          sidebarOpen ? 'translate-x-0' : '-translate-x-full'
        )}
      >
        {/* Logo */}
        <div className="flex h-[76px] items-center justify-between border-b border-[var(--color-line-soft)] px-5">
          <Link to="/" className="flex min-w-0 items-center gap-3" onClick={() => setSidebarOpen(false)}>
            <img
              src="/zhiban-logo.png"
              alt="知办AI logo"
              className="h-10 w-10 shrink-0 rounded-[12px] object-cover shadow-[rgba(15,107,255,0.14)_0px_8px_20px]"
            />
            <div className="min-w-0 whitespace-nowrap text-[17px] font-semibold tracking-tight text-[var(--color-text)]">知办AI管理后台</div>
          </Link>
          <div className="flex items-center gap-1">
            {canShowAlertBell && (
              <button
                type="button"
                className="relative grid h-9 w-9 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-line-soft)] hover:text-[var(--color-brand)]"
                onClick={() => {
                  setSidebarOpen(false)
                  nav('/alerts?status=firing')
                }}
                title={firingAlertCount ? `${firingAlertCount} 条待处理告警` : '告警中心'}
                aria-label="打开告警中心"
              >
                <Bell size={17} />
                {firingAlertCount != null && firingAlertCount > 0 && (
                  <span className="absolute -right-0.5 -top-0.5 inline-flex h-4 min-w-4 items-center justify-center rounded-full bg-[var(--color-danger)] px-1 text-[10px] font-semibold tabular-nums text-white">
                    {firingAlertCount > 99 ? '99+' : firingAlertCount}
                  </span>
                )}
              </button>
            )}
            <button
              type="button"
              className="grid h-9 w-9 place-items-center rounded-md text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)] lg:hidden"
              onClick={() => setSidebarOpen(false)}
              aria-label="关闭菜单"
            >
              <X size={18} />
            </button>
          </div>
        </div>

        {/* 当前管理视图下的一套二级业务菜单。视角切换统一走用户下拉里的 CurrentSpaceSwitcher。 */}
        <nav className="relative flex-1 overflow-y-auto px-4 py-4">
          {menuSections.map(([group, items], index) => (
            <div key={group || `group-${index}`} className="mb-1.5">
              <MenuGroupButton
                group={group || '其他'}
                active={activeGroup === group}
                open={isGroupOpen(group, activeGroup, openGroups, closedGroups)}
                onClick={() => toggleGroup(group)}
              />
              <div
                className={clsx(
                  'ml-4 mt-1 space-y-1 border-l border-[var(--color-line-soft)] pl-3',
                  !isGroupOpen(group, activeGroup, openGroups, closedGroups) && 'hidden'
                )}
              >
                {items.map((m) => {
                  const Icon = iconFor(m.icon || 'puzzle')
                  const active = activeMenuRoute === m.route
                  return (
                    <Link
                      key={m.uuid}
                      to={m.route}
                      onClick={(e) => {
                        setSidebarOpen(false)
                        void openMenu(e, m)
                      }}
                      className={clsx(
                        'relative flex h-[38px] items-center gap-2.5 rounded-lg px-3 text-[14px] font-medium tracking-tight transition',
                        active
                          ? 'bg-[var(--color-brand-soft)] text-[var(--color-brand)] shadow-[rgba(15,107,255,0.08)_0px_6px_18px]'
                          : 'text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)] hover:text-[var(--color-brand)]'
                      )}
                    >
                      {active && (
                        <span className="absolute -left-[13px] top-1/2 h-6 w-[2px] -translate-y-1/2 rounded-full bg-[var(--color-brand)]" />
                      )}
                      <Icon size={16} />
                      <span className="min-w-0 flex-1 truncate">{menuDisplayName(m)}</span>
                      {m.route === '/approvals' && pendingApprovalCount != null && pendingApprovalCount > 0 && (
                        <span className="ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-[var(--color-danger)] px-1.5 text-[11px] font-semibold tabular-nums text-white">
                          {pendingApprovalCount > 99 ? '99+' : pendingApprovalCount}
                        </span>
                      )}
                    </Link>
                  )
                })}
              </div>
            </div>
          ))}
        </nav>

        {/* User dropdown */}
        <div className="relative border-t border-[var(--color-line-soft)] px-4 py-4">
          <button
            onClick={() => setMenuOpen((v) => !v)}
            className="flex w-full items-center gap-3 rounded-xl border border-transparent px-2.5 py-2 transition hover:border-[var(--color-line)] hover:bg-[var(--color-brand-soft)]"
          >
            <div className="brand-mark-blue grid h-9 w-9 place-items-center rounded-full text-[13px] font-semibold text-white">
              {account?.displayName?.[0] || '?'}
            </div>
            <div className="flex-1 min-w-0 text-left">
              <div className="truncate text-[13px] font-semibold text-[var(--color-text)]">{account?.displayName}</div>
              <div className="truncate font-mono text-[11px] text-[var(--color-text-mute)]">
                {account?.username || account?.email || account?.phone || 'admin'}
              </div>
            </div>
            <ChevronDown size={14} className="text-[var(--color-text-mute)]" />
          </button>
          {menuOpen && (
            <div className="absolute bottom-[60px] left-2 right-2 bg-white rounded-md card-shadow p-1 z-50">
              {availableViews.length > 1 && (
                <CurrentSpaceSwitcher
                  views={availableViews}
                  currentView={currentView}
                  disabled={switching}
                  onChange={(nextView) => void switchManagementView(nextView)}
                />
              )}
              {scopes.some((scope) => scope.kind === 'tenant') && (
                <div className="px-2.5 py-2">
                  <FormField label="当前租户">
                    <Select
                      aria-label="当前租户"
                      value={actScope?.kind === 'tenant' ? scopeKey(actScope) : ''}
                      disabled={switching}
                      onChange={(event) => {
                        const next = scopes.find((scope) => scope.kind === 'tenant' && scopeKey(scope) === event.target.value)
                        if (next) void switchScope(next)
                      }}
                    >
                      <option value="" disabled>选择已授权租户</option>
                      {scopes.filter((scope) => scope.kind === 'tenant').map((scope) => (
                        <option key={scopeKey(scope)} value={scopeKey(scope)}>
                          {scope.tenantName || scope.tenantSlug || `租户 #${scope.tenantId}`}
                        </option>
                      ))}
                    </Select>
                  </FormField>
                </div>
              )}
              <DropLink to="/me/profile" icon={UserIcon} onClick={() => setMenuOpen(false)}>个人资料</DropLink>
              <DropLink to="/me/sessions" icon={MessageSquare} onClick={() => setMenuOpen(false)}>我的会话</DropLink>
              {/* API Key 是租户级权限，不是个人级；走 sidebar 凭证与接入组的 /api-keys，避免头像下拉误导。 */}
              <div className="border-t border-[var(--color-line)] mt-1 pt-1">
                <button
                  onClick={() => {
                    clearInflightGet()
                    auth.clearAll()
                    nav('/login')
                  }}
                  className="w-full text-left px-2.5 py-1.5 text-[13px] rounded hover:bg-[var(--color-line-soft)] flex items-center gap-2 text-[var(--color-danger)]"
                >
                  <LogOut size={12} /> 退出登录
                </button>
              </div>
            </div>
          )}
        </div>
      </aside>

      {/* Main */}
      <main className="min-h-0 min-w-0 flex-1 overflow-y-auto overflow-x-hidden">
        <div className="sticky top-0 z-20 flex h-14 items-center border-b border-[var(--color-line)] bg-white/85 px-4 backdrop-blur lg:hidden">
          <button
            type="button"
            className="inline-flex h-9 items-center gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 text-[13px] font-medium text-[var(--color-text-sub)] shadow-[rgba(15,23,42,0.04)_0px_1px_2px]"
            onClick={() => setSidebarOpen(true)}
            aria-label="打开菜单"
          >
            <PanelLeftOpen size={16} />
            菜单
          </button>
        </div>
        {/* M3 (F01 §3.4): impersonate 模式横幅 — 平台 admin 代入了某租户时顶部红条提示, 一键退出 */}
        <ImpersonateBanner scopes={scopes} actScope={actScope} onExitImpersonate={async () => {
          // 切回 platform scope; 后端会签新 token (不再有 acting_as claim)
          try {
            setSwitching(true)
            const platformScope = scopes.find((s) => s.kind === 'platform')
            if (!platformScope) {
              throw new Error('当前账号没有 platform scope, 无法退出代入')
            }
            const resp = await Auth.switchScope('platform')
            auth.setToken(resp.accessToken)
            auth.setRefresh(resp.refreshToken)
            auth.setTenant(0)
            clearInflightGet()
            setActScope(resp.actScope)
            setViewMode('platform')
            navRef.current('/dashboard', { replace: true })
          } catch (e) {
            console.error('exit impersonate failed', e)
          } finally {
            setSwitching(false)
          }
        }} />
        <div className="w-full px-[clamp(16px,2vw,36px)] py-[clamp(20px,2.4vw,36px)]">
          {isUnrestrictedScope(scopes, actScope) || canViewAdminRoute(loc.pathname) ?
            <Outlet context={{ actScope, switchingScope: switching }} /> :
            <EmptyState title="没有访问权限" description="当前角色没有此功能的访问权限，请联系管理员。" />
          }
        </div>
      </main>
    </div>
  )
}

function CurrentSpaceSwitcher({
  views,
  currentView,
  disabled,
  onChange,
}: {
  views: ManagementView[]
  currentView: ManagementView
  disabled: boolean
  onChange: (view: ManagementView) => void
}) {
  const [open, setOpen] = useState(false)
  const currentLabel = viewLabel(currentView)

  return (
    <div className="mb-1 rounded-md px-2 py-2">
      <div className="mb-1.5 px-0.5 text-[12px]">
        <span className="font-medium text-[var(--color-text-mute)]">当前空间</span>
      </div>
      <div className="relative">
        <button
          type="button"
          disabled={disabled}
          aria-expanded={open}
          onClick={() => setOpen((v) => !v)}
          className={clsx(
            'flex h-11 w-full items-center justify-between rounded-lg border border-[var(--color-line)] bg-white px-3.5 text-left text-[14px] font-medium text-[var(--color-text-sub)] shadow-[rgba(15,23,42,0.04)_0px_2px_8px,rgba(15,107,255,0.05)_0px_8px_20px] transition hover:border-[var(--color-brand-line)] hover:shadow-[rgba(15,107,255,0.10)_0px_8px_22px]',
            disabled && 'cursor-wait opacity-70'
          )}
        >
          <span className="flex min-w-0 items-center gap-2.5">
            <Layers size={16} strokeWidth={2.1} className="shrink-0 text-[var(--color-text-mute)]" />
            <span className="truncate">{currentLabel}</span>
          </span>
          <ChevronDown
            size={16}
            strokeWidth={2.1}
            className={clsx('shrink-0 text-[var(--color-text-mute)] transition-transform', open && 'rotate-180')}
          />
        </button>
        {open && (
          <div className="absolute left-0 right-0 top-[calc(100%+6px)] z-[60] overflow-hidden rounded-lg border border-[var(--color-line)] bg-white p-1.5 shadow-[rgba(15,23,42,0.12)_0px_10px_24px]">
            {views.map((view) => {
              const active = currentView === view
              return (
                <button
                  key={view}
                  type="button"
                  disabled={disabled}
                  onClick={() => {
                    setOpen(false)
                    if (!active) onChange(view)
                  }}
                  className={clsx(
                    'flex h-9 w-full items-center justify-between rounded-md px-2.5 text-left text-[13px] transition',
                    active
                      ? 'bg-[var(--color-brand-soft)] font-semibold text-[var(--color-brand)]'
                      : 'text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)] hover:text-[var(--color-text)]',
                    disabled && 'cursor-wait opacity-70'
                  )}
                >
                  <span className="flex items-center gap-2">
                    <Layers size={14} className={clsx(active ? 'text-[var(--color-brand)]' : 'text-[var(--color-text-mute)]')} />
                    {viewLabel(view)}
                  </span>
                  {active && <span className="h-1.5 w-1.5 rounded-full bg-[var(--color-brand)]" />}
                </button>
              )
            })}
          </div>
        )}
      </div>
      <div className="mt-2 border-t border-[var(--color-line)]" />
    </div>
  )
}

function viewLabel(view: ManagementView) {
  return view === 'platform' ? '平台管理' : '租户管理'
}

function MenuGroupButton({
  group,
  active,
  open,
  onClick,
}: {
  group: string
  active: boolean
  open: boolean
  onClick: () => void
}) {
  const Icon = GROUP_ICONS[group as keyof typeof GROUP_ICONS] || Settings2
  return (
    <button
      onClick={onClick}
      className={clsx(
        'flex h-[42px] w-full items-center gap-3 rounded-xl px-3 text-[15px] font-semibold tracking-tight transition-colors duration-200 ease-out',
        active
          ? 'bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
          : 'text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)] hover:text-[var(--color-brand)]'
      )}
    >
      <span
        className={clsx(
          'grid h-7 w-7 shrink-0 place-items-center rounded-lg transition-colors',
          active ? 'bg-white text-[var(--color-brand)] shadow-[rgba(15,107,255,0.12)_0px_4px_12px]' : 'text-[var(--color-text-sub)]'
        )}
      >
        <Icon size={18} strokeWidth={active ? 2.2 : 1.9} />
      </span>
      <span className="flex-1 truncate text-left">{group}</span>
      <ChevronDown
        size={14}
        className={clsx(
          'shrink-0 text-[var(--color-text-mute)] transition-transform',
          open && 'rotate-180',
          active && 'text-[var(--color-brand)]'
        )}
      />
    </button>
  )
}

function isGroupOpen(
  group: string,
  activeGroup: string,
  openGroups: Set<string>,
  closedGroups: Set<string>
) {
  // 用户显式关闭优先级最高 — 即使你当前页就在这个组里, 也允许关闭。
  // 之前 activeGroup === group 直接 return true 导致用户在当前组里时 chevron 完全无效。
  if (closedGroups.has(group)) return false
  if (openGroups.has(group)) return true
  if (activeGroup === group) return true
  return DEFAULT_OPEN_GROUPS.has(group)
}

function scopeKey(scope: ScopeOption | null | undefined) {
  if (!scope) return ''
  return `${scope.kind}:${scope.tenantId || 0}:${scope.workspaceId || 0}`
}

function sameScope(a: ScopeOption | null | undefined, b: ScopeOption | null | undefined) {
  return scopeKey(a) === scopeKey(b)
}

function hasView(scopes: ScopeOption[], view: ManagementView) {
  if (view === 'platform') return scopes.some((s) => s.kind === 'platform')
  return scopes.some((s) => s.kind === 'tenant' || s.kind === 'workspace')
}

function viewForScope(scope: ScopeOption | null | undefined): ManagementView | null {
  if (scope?.kind === 'platform') return 'platform'
  if (scope?.kind === 'tenant' || scope?.kind === 'workspace') return 'tenant'
  return null
}

function defaultViewForScopes(scopes: ScopeOption[], actScope: ScopeOption | null): ManagementView {
  const fromScope = viewForScope(actScope)
  if (fromScope && hasView(scopes, fromScope)) return fromScope
  if (hasView(scopes, 'platform')) return 'platform'
  return 'tenant'
}

function normalizeView(view: ManagementView, scopes: ScopeOption[], actScope: ScopeOption | null) {
  if (hasView(scopes, view)) return view
  return defaultViewForScopes(scopes, actScope)
}

function defaultScopeForView(view: ManagementView, scopes: ScopeOption[]) {
  if (view === 'platform') return scopes.find((s) => s.kind === 'platform')
  const preferredTenantID = auth.tenant()
  return (
    scopes.find((s) => s.kind === 'tenant' && s.tenantId === preferredTenantID) ||
    scopes.find((s) => s.kind === 'tenant') ||
    scopes.find((s) => s.kind === 'workspace')
  )
}

function menuBelongsToView(menu: Menu, view: ManagementView) {
  if (!menu.route || menu.route.startsWith('/me/')) return false
  // Runtime 凭证已并入「Agent 平台 -> 平台托管配置」行操作，不再作为独立菜单暴露。
  if (menu.route === '/runtime-credentials') return false
  // F02: 创建数字员工是列表页内主操作，不作为侧边栏二级菜单暴露。
  if (menu.route === '/agents/new') return false
  if (menu.scopeKind === 'self' || menu.scopeKind === 'me') return false
  if (view === 'platform' && menu.route === '/rooms') return false
  if (menu.scopeKind === 'any') return true
  if (view === 'platform') return menu.scopeKind === 'platform'
  return menu.scopeKind === 'tenant' || menu.scopeKind === 'workspace'
}

function menuPriority(menu: Menu, view: ManagementView) {
  if (view === 'platform' && menu.scopeKind === 'platform') return 0
  if (view === 'tenant' && (menu.scopeKind === 'tenant' || menu.scopeKind === 'workspace')) return 0
  if (menu.scopeKind === 'any') return 1
  return 2
}

function menuGroup(menu: Menu, view: ManagementView) {
  if (menu.route === '/dashboard') return '概览'
  if (menu.route?.startsWith('/me/')) return '个人'

  if (view === 'platform') {
    if (menu.route === '/tenants') return '租户管理'
    // F24 企业管理 = 创业助手运营侧 (W2 起: 注册申请 + 代账工单 + 定价; 企业档案 W3)。
    if (menu.route === '/startup-agent-cases' ||
        menu.route === '/bookkeeping-tickets' ||
        menu.route === '/provider-pricing' ||
        menu.route === '/web-leads' ||
        menu.route === '/web-funnel' ||
        menu.route === '/web-feedback') return '企业管理'
    if (menu.route === '/runtimes' || menu.route === '/runtime-environments' ||
        menu.route === '/runtime-hosting' ||
        menu.route === '/platform-types' || menu.route === '/preset-agents' ||
        menu.route === '/emp-blocks') {
      return 'Agent 平台'
    }
    // 技能中心 = 平台 4 项 (技能管理 / 技能分类 / 技能标签 / 客户端能力注册表)
    // 业务线已按 ADR 0014 砍掉。
    if (menu.route === '/skills' || menu.route === '/skill-categories' ||
        menu.route === '/skill-labels' || menu.route === '/builtin-keys') {
      return '技能中心'
    }
    if (menu.route === '/apps' || menu.route === '/app-categories') return '应用管理'
    // F06 IA refresh: 知识库 与 云盘 拆为两个一级菜单, 各自增长曲线独立。
    if (menu.route === '/kb-providers' || menu.route === '/ragflow-ops' || menu.route === '/platform-kb') return '知识库'
    if (menu.route === '/drive/storage' || menu.route === '/drive/usage' || menu.route === '/drive/workers') {
      return '云盘'
    }
    if (
      menu.route === '/cron-dashboard' ||
      menu.route === '/cron-jobs' ||
      menu.route === '/cron-prompt-templates-ops'
    ) {
      return '任务与自动化'
    }
    if (menu.route === '/menus' || menu.route === '/sys-users' || menu.route === '/roles') {
      return '系统管理'
    }
    // F25: 处置型监控（告警/运行监测/调用日志）与留证型合规（审计/会话检索）拆为两组
    if (menu.route === '/alerts' || menu.route === '/wukongim' || menu.route === '/observability/agent-runs' ||
        menu.route === '/observability/call-logs') {
      return '监控与告警'
    }
    if (menu.route === '/audit' || menu.route === '/observability/conversations') return '审计与合规'
    if (
      menu.route === '/support-feedback' ||
      menu.route === '/marketing-leads' ||
      menu.route === '/download-channels' ||
      menu.route === '/client-versions' ||
      menu.route === '/local-coding-tool-versions' ||
      menu.route === '/client-analytics'
    ) return '平台管理'
  } else {
    // tenant 视角：能力配置走 /agents/:uuid 详情的 "能力与应用" Tab，不挂一级菜单。
    // /runtime-environments 是租户视角"运行环境启用"页面（管理本租户可用的运行环境），归数字员工组。
    if (menu.route === '/agents' || menu.route === '/runtime-environments') return '数字员工'
    // 租户视角的技能中心 (F03 §1.5 方案 B):
    // /tenant-skills/platform = 平台技能列表 + 启用 Switch + 偏好 Select (合并 §3.2 disables + preferences)
    // /tenant-skills/own      = 本租户自有技能 (Phase B CRUD, 现为预留)
    if (menu.route === '/tenant-skills/platform' || menu.route === '/tenant-skills/own') return '技能中心'
    // F04: 应用管理含 /apps /workspace-apps /app-categories
    if (menu.route === '/apps' || menu.route === '/workspace-apps' || menu.route === '/app-categories') return '应用管理'
    if (menu.route === '/kb' || menu.route === '/kb-documents' || menu.route === '/user-kb-inspect') return '知识库'
    if (menu.route === '/drive' || menu.route === '/drive/quotas' ||
        menu.route === '/drive/recycle' || menu.route === '/drive/storage-override') {
      return '云盘'
    }
    if (menu.route === '/cron' || menu.route === '/cron-jobs' || menu.route === '/cron-prompt-templates') return '任务'
    if (menu.route === '/members' || menu.route === '/departments' ||
        menu.route === '/positions' || menu.route === '/org-sync' || menu.route === '/contacts') {
      return '组织与人员'
    }
    // F25: 审批上架为「群聊与协同」第一项（排序见 menuItemOrder）
    if (menu.route === '/rooms' || menu.route === '/approvals') return '群聊与协同'
    // F01 凭证类菜单: API Key / Agent SDK / SSO 都是租户级配置, 单独分组 (业界 Stripe/Slack 也是 dev settings 独立组)
    if (menu.route === '/api-keys' || menu.route === '/agent-sdk-credentials' || menu.route === '/sso-config') return '凭证与接入'
    if (menu.route === '/roles') return '系统管理'
    if (menu.route === '/alerts' || menu.route === '/observability/agent-runs' ||
        menu.route === '/observability/call-logs') {
      return '监控与告警'
    }
    if (menu.route === '/audit' || menu.route === '/observability/conversations') return '审计与合规'
  }

  const configured = typeof menu.metadata?.group === 'string' ? menu.metadata.group.trim() : ''
  if (configured === '运维与审计') return '审计与合规'
  if (configured === '审计与设置') return '审计与合规'
  if (configured === '租户') return '租户管理'
  if (configured) return configured
  return '其他'
}

function menuItemOrder(menu: Menu, group: string) {
  const byGroup: Record<string, Record<string, number>> = {
    '概览': { '/dashboard': 10 },
    '租户管理': { '/tenants': 10 },
    // 技能中心: platform 菜单 sort_order 与 SQL 000100 seed 一致;
    // tenant 菜单按 SQL 000106 (拆分后) sort_order 排: platform=10, own=20。
    '技能中心': {
      '/skills': 10,
      '/skill-categories': 20,
      '/skill-labels': 30,
      '/builtin-keys': 40,
      // tenant 视角:
      '/tenant-skills/platform': 10,
      '/tenant-skills/own': 20,
    },
    '应用管理': { '/apps': 10, '/workspace-apps': 15, '/app-categories': 20 },
    // F06 IA refresh: 知识库 / 云盘 拆开。这里合并 platform + tenant 路由,
    // 因为两套 scope 的 route 集合互不相交, 一张表足够。
    '知识库': {
      // platform
      '/kb-providers': 10,
      '/platform-kb': 15,
      '/ragflow-ops': 20,
      // tenant
      '/kb': 30,
      '/kb-documents': 40,
      '/user-kb-inspect': 90,
    },
    '云盘': {
      // platform
      '/drive/storage': 10,
      '/drive/usage': 20,
      '/drive/workers': 30,
      // tenant
      '/drive': 50,
      '/drive/quotas': 60,
      '/drive/recycle': 70,
      '/drive/storage-override': 80,
    },
    '任务与自动化': { '/cron-dashboard': 10, '/cron-jobs': 20, '/cron-prompt-templates-ops': 30 },
    '任务': { '/cron': 10, '/cron-prompt-templates': 20 },
    '数字员工': { '/agents': 10, '/runtime-environments': 20 },
    'Agent 平台': { '/platform-types': 10, '/runtime-hosting': 20, '/runtime-environments': 30, '/preset-agents': 40, '/emp-blocks': 50 },
    '组织与人员': { '/members': 10, '/departments': 20, '/positions': 30, '/org-sync': 40, '/contacts': 50 },
    '系统管理': { '/roles': 10, '/menus': 20, '/sys-users': 30 },
    '审批与协同': { '/approvals': 10 },
    '群聊与协同': { '/approvals': 10, '/rooms': 20 },
    '凭证与接入': { '/api-keys': 10, '/agent-sdk-credentials': 20, '/sso-config': 30 },
    '监控与告警': { '/alerts': 10, '/wukongim': 20, '/observability/agent-runs': 30, '/observability/call-logs': 40 },
    '审计与合规': { '/audit': 10, '/observability/conversations': 20 },
    '企业管理': { '/startup-agent-cases': 10, '/bookkeeping-tickets': 20, '/company-profiles': 25, '/web-leads': 28, '/web-funnel': 29, '/web-feedback': 29.5, '/provider-pricing': 30 },
    '平台管理': { '/support-feedback': 10, '/marketing-leads': 15, '/download-channels': 17, '/share-growth': 18, '/client-versions': 20, '/local-coding-tool-versions': 22, '/client-analytics': 30 },
    '个人': { '/me/profile': 10, '/me/keys': 20, '/me/sessions': 30 },
  }
  return byGroup[group]?.[menu.route] ?? menu.sortOrder
}

function menuDisplayName(menu: Menu) {
  // scope 敏感的 (route 在 platform / tenant 各有意义):
  if (menu.route === '/apps') {
    return menu.scopeKind === 'platform' ? '应用管理' : '应用栏配置'
  }
  if (menu.route === '/app-categories') {
    return '应用分类'
  }
  if (menu.route === '/rooms') return '群聊'
  if (menu.route === '/runtime-environments') {
    // tenant 视角 = 智能体托管环境（管理本租户可用环境）；platform 视角 = 隐藏，但兜底命名
    return '智能体托管环境'
  }
  if (menu.route && MENU_NAME_OVERRIDES[menu.route]) return MENU_NAME_OVERRIDES[menu.route]
  return menu.name
}

function scopeForMenu(menu: Menu, actScope: ScopeOption | null, scopes: ScopeOption[]) {
  if (menu.scopeKind === 'any') return actScope
  if (menu.scopeKind === 'platform') return scopes.find((s) => s.kind === 'platform')
  if (menu.scopeKind === 'tenant') {
    if (actScope?.kind === 'tenant') return actScope
    return scopes.find((s) => s.kind === 'tenant')
  }
  if (menu.scopeKind === 'workspace') {
    if (actScope?.kind === 'workspace') return actScope
    return scopes.find((s) => s.kind === 'workspace')
  }
  return actScope
}

function DropLink({
  to,
  icon: Icon,
  onClick,
  children,
}: {
  to: string
  icon: React.ComponentType<{ size?: number }>
  onClick?: () => void
  children: React.ReactNode
}) {
  return (
    <Link
      to={to}
      onClick={onClick}
      className="flex items-center gap-2 px-2.5 py-1.5 text-[13px] rounded hover:bg-[var(--color-line-soft)] text-[var(--color-text-sub)]"
    >
      <Icon size={12} />
      {children}
    </Link>
  )
}

// ImpersonateBanner — F01 §3.4 M3:
//
// 平台 admin 代入租户后, JWT 带 acting_as='platform_admin'; 顶部红条提示 +
// 一键 "退出代入" 按钮调 /auth/scope/switch 回 platform scope。
//
// 不显示场景: token 无 acting_as / 当前是 platform scope / 解 token 失败 (静默隐藏)。
function ImpersonateBanner({
  scopes,
  actScope,
  onExitImpersonate,
}: {
  scopes: ScopeOption[]
  actScope: ScopeOption | null
  onExitImpersonate: () => void
}) {
  const claims = parseAccessToken()
  const isImpersonate = claims?.acting_as === 'platform_admin' && actScope?.kind === 'tenant'
  if (!isImpersonate) return null
  const tenantId = actScope?.tenantId ?? claims?.act_tid ?? 0
  const hasPlatform = scopes.some((s) => s.kind === 'platform')
  return (
    <div className="sticky top-0 z-40 flex items-center gap-3 border-b border-red-300 bg-red-50 px-6 py-2.5 text-[13px] text-red-800 shadow-sm">
      <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-red-200 text-red-700">!</div>
      <div className="flex-1">
        <b>代入中</b>: 你正在以租户 <code className="px-1 bg-red-100 rounded">#{tenantId}</code> 管理员身份操作.
        所有动作会以 <code className="px-1 bg-red-100 rounded">acting_as=platform_admin</code> 写入审计日志.
        Token 60min 后自动失效.
      </div>
      <button
        onClick={onExitImpersonate}
        disabled={!hasPlatform}
        className="h-7 px-3 rounded-md bg-red-600 text-white text-[12px] font-medium hover:bg-red-700 disabled:opacity-50"
        title={hasPlatform ? '切回平台 scope' : '当前账号没有 platform scope, 无法退出'}
      >
        退出代入
      </button>
    </div>
  )
}
