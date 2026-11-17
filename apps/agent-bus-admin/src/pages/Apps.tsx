import { useEffect, useState } from 'react'
import { useNavigate, useOutletContext } from 'react-router-dom'
import { AppWindow, CheckCircle2, Copy, Eye, Globe } from 'lucide-react'

import { AppCategories, Apps, PlatformAppCategories, PlatformApps, type App, type AppCategory, type CreateAppResult } from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  PrimaryButton,
  RowActions,
  SearchInput,
  Select,
  Switch,
  Toolbar,
} from '../components/ui'

const DISPLAY_MODE_LABEL: Record<string, string> = {
  side_panel: '侧边栏',
  fullscreen: '全屏',
  external_browser: '外部浏览器',
}

const USAGE_SCOPE_LABEL: Record<string, string> = {
  all: '全部场景',
  end_user: '用户入口',
  agent: '数字员工入口',
}

const STATUS_LABEL: Record<string, string> = {
  active: '已上线',
  disabled: '已禁用',
  revoked: '已撤销',
}

const APP_SCOPE_OPTIONS = [
  { value: 'kb.read', label: '读取知识库' },
  { value: 'contacts.read', label: '读取通讯录' },
]
const SUPPORTED_APP_SCOPES = new Set(APP_SCOPE_OPTIONS.map((option) => option.value))

type AppFormFieldsState = {
  code: string
  name: string
  description: string
  iconUrl: string
  color: string
  displayMode: string
  usageScope: string
  launchUri: string
  redirectUri: string
  categoryUuid: string
}

type AppFormFieldKey = keyof AppFormFieldsState
type AppCrudApi = Pick<typeof Apps, 'create' | 'get' | 'patch' | 'delete' | 'rotateSecret' | 'launchTest'>

export function AppsPage({ workspaceView = false }: { workspaceView?: boolean }) {
  const navigate = useNavigate()
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isTenantScope = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const isPlatformScope = actScope?.kind === 'platform'
  const appApi = isPlatformScope ? PlatformApps : Apps
  const categoryApi = isPlatformScope ? PlatformAppCategories : AppCategories
  const [items, setItems] = useState<App[]>([])
  const [categories, setCategories] = useState<AppCategory[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [readOnlyReason, setReadOnlyReason] = useState('')
  const [tick, setTick] = useState(0)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<App | null>(null)
  const [secret, setSecret] = useState<CreateAppResult | null>(null)
  const [rotating, setRotating] = useState<App | null>(null)
  const [deleting, setDeleting] = useState<App | null>(null)
  const [launchTest, setLaunchTest] = useState<{ app: App; launchUrl: string } | null>(null)
  const [filterKeyword, setFilterKeyword] = useState('')
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)

  useEffect(() => {
    let cancelled = false
    void Promise.resolve().then(() => {
      if (cancelled) return
      if (!isTenantScope && !isPlatformScope) {
        setLoading(false)
        return
      }
      setLoading(true)
      return Promise.all([
        appApi.list({ keyword: filterKeyword || undefined, workspaceOnly: workspaceView || undefined, limit: pageSize, offset: (page - 1) * pageSize }),
        categoryApi.list({ limit: 200, offset: 0 }),
      ]).then(([appResp, catResp]) => {
        if (cancelled) return
        setItems(appResp.items || [])
        setReadOnlyReason(appResp.readOnlyReason || '')
        setTotal(appResp.total || 0)
        setCategories(catResp.items || [])
        setErr('')
      }).catch((e: Error) => {
        if (!cancelled) setErr(e.message)
      }).finally(() => {
        if (!cancelled) setLoading(false)
      })
    })
    return () => { cancelled = true }
  }, [tick, filterKeyword, page, pageSize, isTenantScope, isPlatformScope, appApi, categoryApi, workspaceView])

  const refresh = () => setTick((t) => t + 1)
  const catByUuid = Object.fromEntries(categories.map((c) => [c.uuid, c.name]))

  const setUniversal = async (app: App, isUniversal: boolean) => {
    await Apps.setUniversal(app.uuid, isUniversal, app.sortOrder || 0)
    refresh()
  }

  const setEnabled = async (app: App, isEnabled: boolean) => {
    await Apps.setEnabled(app.uuid, isEnabled)
    refresh()
  }

  const setOpenToTenants = async (app: App, openToTenants: boolean) => {
    await PlatformApps.patch(app.uuid, { openToTenants })
    refresh()
  }

  const runLaunchTest = async (app: App) => {
    const result = await appApi.launchTest(app.uuid)
    setLaunchTest({ app, launchUrl: result.launchUrl })
  }

  if (switchingScope || !actScope) return null
  if (!isTenantScope && !isPlatformScope) {
    return (
      <div>
        <PageHeader title="应用管理" subtitle="请切换到平台或租户视图后再管理应用。" />
        <InlineAlert>请先在左上角切换到平台或租户视图后再管理应用。</InlineAlert>
      </div>
    )
  }

  return (
    <div>
      <PageHeader
        title={workspaceView ? '工作台应用' : '应用管理'}
        subtitle={workspaceView ? '展示本租户已启用且设为通用的用户应用；配置、启停与应用管理保持一致。' : isPlatformScope
          ? '管理平台预置 H5 应用、OAuth2 SSO 凭证，并选择是否开放给租户使用。'
          : '管理租户自建 H5 应用、OAuth2 SSO 凭证、通用入口和数字员工可用应用。'}
      />

      <Toolbar
        search={
          <SearchInput
            value={filterKeyword}
            onChange={(v) => { setFilterKeyword(v); setPage(1) }}
            placeholder="按名称 / 编码搜索"
          />
        }
        actions={
          <PrimaryButton disabled={loading || !!readOnlyReason} onClick={() => workspaceView ? navigate('/apps') : setCreating(true)}>
            {workspaceView ? '管理全部应用' : isPlatformScope ? '新建平台应用' : '新建应用'}
          </PrimaryButton>
        }
      />

      {err && <InlineAlert>{err}</InlineAlert>}
      {readOnlyReason && <InlineAlert tone="info">{readOnlyReason}</InlineAlert>}

      <DataTable
        headers={isPlatformScope
          ? ['应用', '分类', '入口形态', '可用场景', '开放给租户', '状态', '操作']
          : ['应用', '来源', '分类', '入口形态', '可用场景', '通用', '启用', '状态', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<AppWindow size={22} />}
            title="还没有应用"
            description={workspaceView ? '在应用管理中启用应用并打开通用开关后，会显示在这里。' : '新建应用后会一次性展示 client_secret，请立即复制保存。'}
          />
        ) : undefined}
      >
        {!loading && items.map((a) => (
          <tr key={a.uuid} className="hover:bg-[var(--color-bg-sub)]">
            <td className="px-4 py-3">
              <div className="flex items-center gap-2">
                {a.iconUrl
                  ? <img src={a.iconUrl} alt="" className="h-8 w-8 rounded-md border border-[var(--color-line)]" />
                  : <div className="grid h-8 w-8 place-items-center rounded-md bg-[var(--color-brand-soft)] text-[var(--color-brand)]"><Globe size={15} /></div>}
                <div className="min-w-0">
                  <div className="truncate font-medium text-[var(--color-text)]">{a.name}</div>
                  <div className="truncate font-mono text-[11px] text-[var(--color-text-mute)]">{a.code}</div>
                </div>
              </div>
            </td>
            {!isPlatformScope && (
              <td className="px-4 py-3 text-[var(--color-text-sub)]">{a.isSystem ? '平台预置' : '租户自建'}</td>
            )}
            <td className="px-4 py-3 text-[var(--color-text-sub)]">{a.categoryUuid ? catByUuid[a.categoryUuid] || '-' : '-'}</td>
            <td className="px-4 py-3">{DISPLAY_MODE_LABEL[a.displayMode] || a.displayMode}</td>
            <td className="px-4 py-3">{USAGE_SCOPE_LABEL[a.usageScope || 'all'] || a.usageScope}</td>
            {isPlatformScope ? (
              <td className="px-4 py-3">
                <Switch disabled={!!readOnlyReason} checked={!!a.openToTenants} onChange={(checked) => setOpenToTenants(a, checked)} />
              </td>
            ) : (
              <>
                <td className="px-4 py-3">
                  <Switch disabled={!!readOnlyReason} checked={!!a.isUniversal} onChange={(checked) => setUniversal(a, checked)} />
                </td>
                <td className="px-4 py-3">
                  <Switch disabled={!!readOnlyReason} checked={a.isEnabled !== false} onChange={(checked) => setEnabled(a, checked)} />
                </td>
              </>
            )}
            <td className="px-4 py-3">
              <span className="rounded bg-[var(--color-line-soft)] px-2 py-1 text-[12px] text-[var(--color-text-sub)]">
                {STATUS_LABEL[a.status] || a.status}
              </span>
            </td>
            <td className="px-4 py-3">
              <RowActions
                extras={
                  <>
                    <Button variant="ghost" size="sm" disabled={!!readOnlyReason} onClick={() => runLaunchTest(a)}>检查启动配置</Button>
                    {!readOnlyReason && (!a.isSystem || isPlatformScope) && (
                      <Button variant="ghost" size="sm" onClick={() => setRotating(a)}>重置 secret</Button>
                    )}
                  </>
                }
                onEdit={(!readOnlyReason && (!a.isSystem || isPlatformScope)) ? () => setEditing(a) : undefined}
                onDelete={(!readOnlyReason && (!a.isSystem || isPlatformScope)) ? () => setDeleting(a) : undefined}
              />
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => { setLoading(true); setPage(next) }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {creating && (
        <CreateAppDrawer
          categories={categories}
          isPlatform={isPlatformScope}
          appApi={appApi}
          onClose={() => setCreating(false)}
          onCreated={(r) => { setCreating(false); setSecret(r); refresh() }}
        />
      )}
      {editing && (
        <EditAppDrawer
          app={editing}
          categories={categories}
          isPlatform={isPlatformScope}
          appApi={appApi}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); refresh() }}
        />
      )}
      {secret && <SecretDialog data={secret} onClose={() => setSecret(null)} />}
      {rotating && <RotateSecretDialog app={rotating} appApi={appApi} onClose={() => setRotating(null)} onRotated={() => { setRotating(null); refresh() }} />}
      {deleting && <DeleteAppDialog app={deleting} appApi={appApi} onClose={() => setDeleting(null)} onDeleted={() => { setDeleting(null); refresh() }} />}
      {launchTest && <LaunchTestDialog data={launchTest} onClose={() => setLaunchTest(null)} />}
    </div>
  )
}

function CreateAppDrawer(props: { categories: AppCategory[]; isPlatform: boolean; appApi: AppCrudApi; onClose: () => void; onCreated: (r: CreateAppResult) => void }) {
  const [form, setForm] = useState({
    code: '',
    name: '',
    description: '',
    iconUrl: '',
    color: '',
    displayMode: 'side_panel' as 'side_panel' | 'fullscreen' | 'external_browser',
    usageScope: 'all',
    launchUri: '',
    redirectUri: '',
    categoryUuid: '',
  })
  const [scopes, setScopes] = useState<string[]>([])
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  const set = (key: keyof typeof form, value: string) => setForm((f) => ({ ...f, [key]: value }))

  const submit = async () => {
    if (!form.code.trim() || !form.name.trim() || !form.launchUri.trim() || !form.redirectUri.trim()) {
      setErr('请填写编码、名称、启动地址和回调地址')
      return
    }
    setSubmitting(true)
    setErr('')
    try {
      const r = await props.appApi.create({
        code: form.code.trim(),
        name: form.name.trim(),
        description: form.description.trim(),
        iconUrl: form.iconUrl.trim() || undefined,
        color: form.color.trim() || undefined,
        displayMode: form.displayMode,
        usageScope: form.usageScope as 'all' | 'end_user' | 'agent',
        launchUri: form.launchUri.trim(),
        redirectUris: [form.redirectUri.trim()],
        scopes,
        categoryUuid: form.categoryUuid || undefined,
        openToTenants: props.isPlatform,
      })
      props.onCreated(r)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <DrawerShell
      title="新建应用"
      subtitle="创建后会自动生成 OAuth2 client_id / client_secret，secret 仅展示一次。"
      icon={<AppWindow size={18} />}
      onClose={props.onClose}
      width="md"
      footer={<Footer onCancel={props.onClose} onSubmit={submit} submitLabel="创建" busy={submitting} />}
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        <AppFormFields form={form} set={set} scopes={scopes} setScopes={setScopes} categories={props.categories} />
      </div>
    </DrawerShell>
  )
}

function EditAppDrawer(props: { app: App; categories: AppCategory[]; isPlatform: boolean; appApi: AppCrudApi; onClose: () => void; onSaved: () => void }) {
  const [form, setForm] = useState({
    code: props.app.code,
    name: props.app.name,
    description: props.app.description || '',
    iconUrl: props.app.iconUrl || '',
    color: props.app.color || '',
    displayMode: props.app.displayMode,
    usageScope: props.app.usageScope || 'all',
    launchUri: props.app.launchUri,
    redirectUri: '',
    categoryUuid: props.app.categoryUuid || '',
    status: props.app.status,
  })
  const [scopes, setScopes] = useState<string[]>([])
  const [clientId, setClientId] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [err, setErr] = useState('')

  useEffect(() => {
    let cancelled = false
    props.appApi.get(props.app.uuid).then((detail) => {
      if (cancelled) return
      const oc = detail.oauthClient
      setForm((f) => ({ ...f, redirectUri: oc?.redirectUris?.[0] || '' }))
      setScopes((oc?.scopes || []).filter((scope) => SUPPORTED_APP_SCOPES.has(scope)))
      setClientId(oc?.clientId || '')
    }).catch((e: Error) => {
      if (!cancelled) setErr(e.message)
    })
    return () => { cancelled = true }
  }, [props.app.uuid, props.appApi])

  const set = (key: keyof typeof form, value: string) => setForm((f) => ({ ...f, [key]: value }))

  const save = async () => {
    setSubmitting(true)
    setErr('')
    try {
      await props.appApi.patch(props.app.uuid, {
        name: form.name.trim(),
        description: form.description.trim(),
        iconUrl: form.iconUrl.trim() || undefined,
        color: form.color.trim() || undefined,
        displayMode: form.displayMode,
        usageScope: form.usageScope as 'all' | 'end_user' | 'agent',
        launchUri: form.launchUri.trim(),
        redirectUris: form.redirectUri.trim() ? [form.redirectUri.trim()] : [],
        scopes,
        categoryUuid: form.categoryUuid,
        openToTenants: props.isPlatform ? props.app.openToTenants : undefined,
        status: form.status,
      })
      props.onSaved()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <DrawerShell
      title={`编辑应用 · ${props.app.name}`}
      subtitle="可调整入口、分类、OAuth2 回调地址和可借用能力。"
      icon={<AppWindow size={18} />}
      onClose={props.onClose}
      width="md"
      footer={<Footer onCancel={props.onClose} onSubmit={save} submitLabel="保存" busy={submitting} />}
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        <AppFormFields form={form} set={set} scopes={scopes} setScopes={setScopes} categories={props.categories} editing />
        <FormSection title="OAuth2 凭证" description="client_id 永久不变, 公开值, 可放进 URL / log / token。client_secret 仅创建/重置时一次性显示, 忘记请用「重置 client_secret」生成新的。">
          <FormField label="client_id">
            <div className="flex items-center gap-2">
              <Input value={clientId || '加载中...'} readOnly className="flex-1 font-mono text-[12px]" />
              <button
                type="button"
                disabled={!clientId}
                onClick={() => { if (clientId) void navigator.clipboard.writeText(clientId) }}
                title="复制 client_id"
                className="grid h-9 w-9 place-items-center rounded-md border border-[var(--color-line)] hover:bg-[var(--color-bg-sub)] disabled:opacity-40"
              >
                <Copy size={14} />
              </button>
            </div>
          </FormField>
        </FormSection>
        <FormSection title="发布状态">
          <FormField label="状态">
            <Select value={form.status} onChange={(e) => set('status', e.target.value)}>
              <option value="active">已上线</option>
              <option value="disabled">已禁用</option>
            </Select>
          </FormField>
        </FormSection>
      </div>
    </DrawerShell>
  )
}

function AppFormFields(props: {
  form: AppFormFieldsState
  set: (key: AppFormFieldKey, value: string) => void
  scopes: string[]
  setScopes: (scopes: string[]) => void
  categories: AppCategory[]
  editing?: boolean
}) {
  return (
    <>
      <FormSection title="基础信息">
        <div className="grid grid-cols-2 gap-3">
          <FormField label="应用编码" hint="租户内唯一，建议使用英文小写、数字和下划线。">
            <Input value={props.form.code} disabled={props.editing} placeholder="tax_filing" onChange={(e) => props.set('code', e.target.value)} />
          </FormField>
          <FormField label="应用名称">
            <Input value={props.form.name} placeholder="税务申报" onChange={(e) => props.set('name', e.target.value)} />
          </FormField>
          <FormField label="分类">
            <Select value={props.form.categoryUuid} onChange={(e) => props.set('categoryUuid', e.target.value)}>
              <option value="">不设置分类</option>
              {props.categories.map((c) => <option key={c.uuid} value={c.uuid}>{c.name}</option>)}
            </Select>
          </FormField>
          <FormField label="入口形态">
            <Select value={props.form.displayMode} onChange={(e) => props.set('displayMode', e.target.value)}>
              <option value="side_panel">侧边栏</option>
              <option value="fullscreen">全屏</option>
            </Select>
          </FormField>
          <FormField label="可用场景" hint="控制应用进入用户入口、工作台或数字员工能力装配的候选池。">
            <Select value={props.form.usageScope} onChange={(e) => props.set('usageScope', e.target.value)}>
              <option value="all">全部场景</option>
              <option value="end_user">用户入口</option>
              <option value="agent">数字员工入口</option>
            </Select>
          </FormField>
          <FormField label="图标 URL">
            <Input value={props.form.iconUrl} placeholder="https://..." onChange={(e) => props.set('iconUrl', e.target.value)} />
          </FormField>
          <FormField label="主色">
            <Input value={props.form.color} placeholder="#0F6BFF" onChange={(e) => props.set('color', e.target.value)} />
          </FormField>
        </div>
        <div className="mt-3">
          <FormField label="应用描述">
            <textarea value={props.form.description} rows={3} onChange={(e) => props.set('description', e.target.value)} className={textareaCls} />
          </FormField>
        </div>
      </FormSection>

      <FormSection title="接入配置">
        <div className="space-y-3">
          <FormField label="启动地址" hint="用户点击应用后打开的 H5 入口地址，生产环境应使用 HTTPS。">
            <Input value={props.form.launchUri} placeholder="https://tax.example.com/zhiban-landing" onChange={(e) => props.set('launchUri', e.target.value)} />
          </FormField>
          <FormField label="回调地址" hint="OAuth2 redirect_uri，后端会做 exact match 校验。">
            <Input value={props.form.redirectUri} placeholder="https://tax.example.com/oauth/callback" onChange={(e) => props.set('redirectUri', e.target.value)} />
          </FormField>
        </div>
      </FormSection>

      <FormSection title="可借用能力" description="应用后端使用 access_token 反向调用知办AI API 时，只能使用这里授予的能力。">
        <InlineAlert tone="info">当前仅开放知识库和通讯录只读接口；云盘 External API 尚未开放。</InlineAlert>
        <div className="flex flex-wrap gap-2">
          {APP_SCOPE_OPTIONS.map((option) => (
            <label key={option.value} className="inline-flex h-8 items-center gap-2 rounded-md border border-[var(--color-line)] bg-white px-3 text-[13px]">
              <input
                type="checkbox"
                checked={props.scopes.includes(option.value)}
                onChange={(e) => {
                  if (e.target.checked) props.setScopes([...props.scopes, option.value])
                  else props.setScopes(props.scopes.filter((scope) => scope !== option.value))
                }}
              />
              {option.label}
            </label>
          ))}
        </div>
      </FormSection>
    </>
  )
}

function SecretDialog(props: { data: CreateAppResult; onClose: () => void }) {
  const oc = props.data.oauthClient
  return (
    <DialogShell title="请立即保存客户端密钥" subtitle="客户端密钥关闭后无法再次查看，只能重新生成。" icon={<Eye size={18} />} onClose={props.onClose} size="md" footer={<Button onClick={props.onClose}>我已保存</Button>}>
      <div className="space-y-3">
        <InlineAlert tone="warn">请将客户端编号和客户端密钥交给应用后端维护人员，并保存到安全配置中；不要放入前端、日志或代码仓库。</InlineAlert>
        <CodeRow label="客户端编号（client_id）" value={oc.clientId} />
        <CodeRow label="客户端密钥（client_secret）" value={oc.clientSecret || ''} highlight />
      </div>
    </DialogShell>
  )
}

function RotateSecretDialog(props: { app: App; appApi: AppCrudApi; onClose: () => void; onRotated: () => void }) {
  const [newSecret, setNewSecret] = useState('')
  if (newSecret) {
    return (
      <DialogShell title="新的 client_secret" subtitle="新 secret 仅展示一次。" onClose={props.onClose} size="lg" footer={<Button onClick={props.onRotated}>我已保存</Button>}>
        <CodeRow label="client_secret" value={newSecret} highlight />
      </DialogShell>
    )
  }
  return (
    <ConfirmDialog
      title="重置 client_secret"
      description={`确认重置应用「${props.app.name}」的 client_secret？旧 secret 会立即失效。`}
      confirmLabel="确认重置"
      busyLabel="重置中..."
      onClose={props.onClose}
      onConfirm={async () => {
        const r = await props.appApi.rotateSecret(props.app.uuid)
        setNewSecret(r.clientSecret)
      }}
    />
  )
}

function DeleteAppDialog(props: { app: App; appApi: AppCrudApi; onClose: () => void; onDeleted: () => void }) {
  return (
    <ConfirmDialog
      title="删除应用"
      description={`确认删除应用「${props.app.name}」？OAuth client 会被撤销，已颁发的 access_token 会在 TTL 内自然过期。`}
      confirmLabel="删除"
      busyLabel="删除中..."
      onClose={props.onClose}
      onConfirm={async () => {
        await props.appApi.delete(props.app.uuid)
        props.onDeleted()
      }}
    />
  )
}

function LaunchTestDialog(props: { data: { app: App; launchUrl: string }; onClose: () => void }) {
  return (
    <DialogShell title="启动配置检查通过" subtitle={`应用「${props.data.app.name}」的配置和凭据状态正常；尚未检查外部应用连通性或登录回跳。`} icon={<CheckCircle2 size={18} />} onClose={props.onClose} footer={<Button onClick={props.onClose}>关闭</Button>}>
      <CodeRow label="启动地址" value={props.data.launchUrl} />
    </DialogShell>
  )
}

function CodeRow(props: { label: string; value: string; highlight?: boolean }) {
  const [copied, setCopied] = useState(false)
  return (
    <div>
      <div className="mb-1 text-[12px] font-medium text-[var(--color-text-sub)]">{props.label}</div>
      <div className={`flex items-center gap-2 rounded-md border px-3 py-2 font-mono text-[12px] ${props.highlight ? 'border-[var(--color-warn)] bg-[var(--color-warn-bg)]' : 'border-[var(--color-line)] bg-[var(--color-bg-sub)]'}`}>
        <code className="min-w-0 flex-1 break-all">{props.value}</code>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => {
            navigator.clipboard.writeText(props.value)
            setCopied(true)
            setTimeout(() => setCopied(false), 1200)
          }}
        >
          <Copy size={13} /> {copied ? '已复制' : '复制'}
        </Button>
      </div>
    </div>
  )
}

function Footer(props: { onCancel: () => void; onSubmit: () => void; submitLabel: string; busy: boolean }) {
  return (
    <div className="flex justify-end gap-2">
      <Button variant="secondary" onClick={props.onCancel} disabled={props.busy}>取消</Button>
      <Button onClick={props.onSubmit} disabled={props.busy}>{props.busy ? `${props.submitLabel}中...` : props.submitLabel}</Button>
    </div>
  )
}

const textareaCls = 'w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]'
