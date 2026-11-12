// M8B KB Provider 管理页 · /platform/kb-providers
//
// 能力: 列表 / 创建 / 编辑 / 删除 / 设默认 / health-check
// 权限: platform.kb_provider.read|manage; 后端最终把关.
// Dify API Key: UI 正常输入明文，提交前转换成后端内部凭证引用。
//
// status 三态:
//   - active   → 绿底, 可作为业务 provider;
//   - degraded → 黄底, 不参与业务路由 (health-check 仍可探测);
//   - disabled → 灰底, 完全不可用.

import { useEffect, useRef, useState, type ReactNode } from 'react'
import { KBProviders, PlatformModelOptions, type KBProvider, type KBProviderCreateInput, type PlatformModelOption } from '../lib/api'
import { Button, DrawerShell, Input, PageHeader, PrimaryButton, RowActions, Select, Switch, FormField } from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { notifyError, notifyOk } from '../lib/toast'
import { humanizeError } from '../lib/errorMessages'
import { Database, HelpCircle } from 'lucide-react'
import { SecretValueField } from '../components/form/SecretValueField'
import { secretRefToDisplay, secretValueToRef } from '../components/form/secretValue'

type ProviderForm = {
  provider_kind: 'stub' | 'dify' | 'tablestore' | 'ragflow'
  name: string
  endpoint_url: string
  api_key_ref: string
  settings_json: string
  is_default: boolean
}

const emptyForm: ProviderForm = {
  provider_kind: 'ragflow',
  name: '',
  endpoint_url: '',
  api_key_ref: '',
  settings_json: JSON.stringify({
    admin_port: 80,
    api_port: 80,
    default_embedding: 'text-embedding-3-large',
    default_rerank: 'bge-reranker-v2-m3',
  }, null, 2),
  is_default: false,
}

function providerSettingsPlaceholder(
  kind: ProviderForm['provider_kind'],
  defaults: { embedding?: string; rerank?: string } = {},
) {
  if (kind === 'ragflow') {
    return JSON.stringify({
      admin_port: 80,
      api_port: 80,
      default_embedding: defaults.embedding || 'text-embedding-3-large',
      default_rerank: defaults.rerank || 'bge-reranker-v2-m3',
    }, null, 2)
  }
  if (kind === 'dify') {
    return JSON.stringify({
      dataset_id: '',
      top_k: 5,
      threshold: 0.4,
      use_rerank: true,
    }, null, 2)
  }
  if (kind === 'stub') {
    return JSON.stringify({ top_k: 5, threshold: 0.05 }, null, 2)
  }
  return '{}'
}

function createEmptyForm(defaults: { embedding?: string; rerank?: string } = {}): ProviderForm {
  return {
    ...emptyForm,
    name: 'RAGFlow 测试环境',
    endpoint_url: providerEndpointPlaceholder('ragflow'),
    settings_json: providerSettingsPlaceholder('ragflow', defaults),
  }
}

function providerNamePlaceholder(kind: ProviderForm['provider_kind']) {
  return kind === 'dify' ? '比如 dify-prod' : '比如 ragflow-prod'
}

function providerEndpointPlaceholder(kind: ProviderForm['provider_kind']) {
  return kind === 'dify' ? 'https://api.dify.ai/v1' : ''
}

function providerLabel(kind: ProviderForm['provider_kind']) {
  if (kind === 'ragflow') return 'RAGFlow'
  if (kind === 'dify') return 'Dify'
  if (kind === 'stub') return '本地测试服务'
  if (kind === 'tablestore') return 'TableStore'
  return kind
}

function normalizeLegacyModelID(value: unknown) {
  return typeof value === 'string' ? value.replace(/@OpenAI-API-Compatible$/i, '') : value
}

function settingsForEdit(p: KBProvider) {
  const settings = { ...(p.settings || {}) }
  delete settings.api_token_secret_ref
  settings.default_embedding = normalizeLegacyModelID(settings.default_embedding)
  settings.default_rerank = normalizeLegacyModelID(settings.default_rerank)
  return JSON.stringify(settings, null, 2)
}

function visibleAPIKeyRef(ref: string) {
  return secretRefToDisplay(ref).display
}

function displayAPIKeyRef(ref: string) {
  if (!ref) return '—'
  return '已配置'
}

function toSecretRef(raw: string) {
  return secretValueToRef(raw)
}

const fallbackEmbeddingModelOptions = [
  'text-embedding-3-large',
  'text-embedding-3-small',
  'bge-m3',
]

const fallbackRerankModelOptions = [
  'bge-reranker-v2-m3',
  'bge-reranker-large',
]

function fallbackModelOptions(ids: string[], capability: 'embedding' | 'rerank'): PlatformModelOption[] {
  return ids.map((id) => ({ id, name: id, capabilities: [capability], source: 'fallback' }))
}

function modelOptionsWithCurrent(models: PlatformModelOption[], current: string, capability: 'embedding' | 'rerank') {
  if (!current || models.some((model) => model.id === current)) return models
  return [{ id: current, name: `${current}（当前配置）`, capabilities: [capability], source: 'current' }, ...models]
}

const modelHint = '模型候选由后台经 AIGC 网关获取；列表代表当前网关返回的候选模型，实际可用性以保存后的服务调用结果为准。'
const difyDatasetHint = '从 Dify 知识库设置页复制 URL 里的 dataset id，或该知识库 API 密钥弹窗对应的 dataset id。'

function HintLabel({ label, hint }: { label: string; hint: string }) {
  const anchorRef = useRef<HTMLSpanElement | null>(null)
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState({ left: 0, top: 0 })

  const show = () => {
    const rect = anchorRef.current?.getBoundingClientRect()
    if (!rect) return
    const width = 280
    const margin = 12
    setPos({
      left: Math.min(Math.max(margin, rect.right - width), window.innerWidth - width - margin),
      top: rect.bottom + 8,
    })
    setOpen(true)
  }

  return (
    <span className="mb-1.5 flex items-center gap-1.5 text-[13px] font-medium text-[var(--color-text)]">
      {label}
      <span className="inline-flex cursor-help">
        <span
          ref={anchorRef}
          tabIndex={0}
          aria-label={hint}
          onMouseEnter={show}
          onMouseLeave={() => setOpen(false)}
          onFocus={show}
          onBlur={() => setOpen(false)}
          className="inline-flex h-4 w-4 items-center justify-center rounded-full text-[var(--color-text-mute)] transition hover:text-[var(--color-text)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-brand)]/25"
        >
          <HelpCircle size={13} />
        </span>
        {open && (
          <span
            role="tooltip"
            className="pointer-events-none fixed z-[1000] w-[280px] whitespace-normal rounded-md bg-[var(--color-text)] px-2.5 py-2 text-left text-[12px] font-normal leading-relaxed text-white shadow-lg"
            style={{ left: pos.left, top: pos.top }}
          >
            {hint}
          </span>
        )}
      </span>
    </span>
  )
}

function ModelLabel({ label }: { label: string }) {
  return <HintLabel label={label} hint={modelHint} />
}

function ProviderConfigSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-4">
      <div className="mb-3 text-[15px] font-semibold text-[var(--color-text)]">{title}</div>
      {children}
    </div>
  )
}

async function fetchPlatformModelOptions() {
  const [embeddingResp, rerankResp] = await Promise.all([
    PlatformModelOptions.list('embedding').catch(() => null),
    PlatformModelOptions.list('rerank').catch(() => null),
  ])
  const embedding = embeddingResp?.items?.length
    ? embeddingResp.items
    : fallbackModelOptions(fallbackEmbeddingModelOptions, 'embedding')
  const rerank = rerankResp?.items?.length
    ? rerankResp.items
    : fallbackModelOptions(fallbackRerankModelOptions, 'rerank')
  return { embedding, rerank }
}

function parseSettings(json: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(json || '{}')
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    return parsed as Record<string, unknown>
  } catch {
    return {}
  }
}

function stringifySettings(settings: Record<string, unknown>) {
  return JSON.stringify(settings, null, 2)
}

function settingString(json: string, key: string, fallback = '') {
  const value = parseSettings(json)[key]
  return typeof value === 'string' ? value : fallback
}

function settingNumber(json: string, key: string, fallback: number) {
  const value = parseSettings(json)[key]
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const n = Number(value)
    if (Number.isFinite(n)) return n
  }
  return fallback
}

function settingBool(json: string, key: string, fallback: boolean) {
  const value = parseSettings(json)[key]
  return typeof value === 'boolean' ? value : fallback
}

function difyDatasetID(json: string) {
  const settings = parseSettings(json)
  return (
    (typeof settings.dataset_id === 'string' && settings.dataset_id) ||
    (typeof settings.tenant_dataset_id === 'string' && settings.tenant_dataset_id) ||
    (typeof settings.user_dataset_id === 'string' && settings.user_dataset_id) ||
    ''
  )
}

export function KBProvidersPage() {
  const confirmDelete = useConfirmDialog()
  const [items, setItems] = useState<KBProvider[]>([])
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)
  const [editing, setEditing] = useState<KBProvider | null>(null)
  const [form, setForm] = useState<ProviderForm>(emptyForm)
  const [ragflowAdminEmail, setRagflowAdminEmail] = useState('')
  const [ragflowAdminPassword, setRagflowAdminPassword] = useState('')
  const [showForm, setShowForm] = useState(false)
  const [embeddingModels, setEmbeddingModels] = useState<PlatformModelOption[]>(() =>
    fallbackModelOptions(fallbackEmbeddingModelOptions, 'embedding'))
  const [rerankModels, setRerankModels] = useState<PlatformModelOption[]>(() =>
    fallbackModelOptions(fallbackRerankModelOptions, 'rerank'))
  const [modelOptionsLoaded, setModelOptionsLoaded] = useState(false)

  const updateSetting = (key: string, value: unknown) => {
    setForm((prev) => {
      const settings = parseSettings(prev.settings_json)
      if (value === '' || value === undefined || value === null) {
        delete settings[key]
      } else {
        settings[key] = value
      }
      return { ...prev, settings_json: stringifySettings(settings) }
    })
  }

  const [reloadTick, setReloadTick] = useState(0)
  const refresh = () => setReloadTick((t) => t + 1)
  useEffect(() => {
    let cancelled = false
    KBProviders.list()
      .then((r) => { if (!cancelled) setItems(r.items || []) })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [reloadTick])

  useEffect(() => {
    let cancelled = false
    fetchPlatformModelOptions().then(({ embedding, rerank }) => {
      if (cancelled) return
      setEmbeddingModels(embedding)
      setRerankModels(rerank)
      setModelOptionsLoaded(true)
    })
    return () => { cancelled = true }
  }, [])

  const openCreate = async () => {
    setEditing(null)
    let nextEmbedding = embeddingModels
    let nextRerank = rerankModels
    if (!modelOptionsLoaded) {
      const loaded = await fetchPlatformModelOptions()
      nextEmbedding = loaded.embedding
      nextRerank = loaded.rerank
      setEmbeddingModels(loaded.embedding)
      setRerankModels(loaded.rerank)
      setModelOptionsLoaded(true)
    }
    setForm(createEmptyForm({
      embedding: nextEmbedding[0]?.id,
      rerank: nextRerank[0]?.id,
    }))
    setRagflowAdminEmail('admin@ragflow.io')
    setRagflowAdminPassword('')
    setShowForm(true)
  }
  const openEdit = (p: KBProvider) => {
    setEditing(p)
    setForm({
      provider_kind: p.provider_kind,
      name: p.name,
      endpoint_url: p.endpoint_url || '',
      api_key_ref: visibleAPIKeyRef(p.api_key_ref || ''),
      settings_json: settingsForEdit(p),
      is_default: p.is_default,
    })
    setRagflowAdminEmail(p.provider_kind === 'ragflow' ? (p.admin_email || '') : '')
    setRagflowAdminPassword('')
    setShowForm(true)
  }

  const submit = async () => {
    setErr('')
    let settings: Record<string, unknown>
    try {
      settings = JSON.parse(form.settings_json || '{}') as Record<string, unknown>
    } catch {
      setErr('高级 JSON 格式不正确')
      return
    }
    let apiKeyRef = ''
    if (form.provider_kind === 'dify') {
      apiKeyRef = toSecretRef(form.api_key_ref)
      const existingRef = editing?.settings?.api_token_secret_ref || editing?.api_key_ref || ''
      const secretRef = apiKeyRef || (typeof existingRef === 'string' ? existingRef : '')
      if (!secretRef) {
        setErr('Dify API Key 必填')
        return
      }
      const datasetID = difyDatasetID(form.settings_json).trim()
      if (!datasetID) {
        setErr('Dify Dataset ID 必填')
        return
      }
      settings.api_token_secret_ref = secretRef
      settings.dataset_id = datasetID
      settings.tenant_dataset_id = datasetID
      settings.user_dataset_id = datasetID
      delete settings.workspace_id
    } else {
      delete settings.api_token_secret_ref
    }
    if (form.provider_kind === 'ragflow') {
      const email = ragflowAdminEmail.trim()
      const password = ragflowAdminPassword
      if (!editing && (!email || !password)) {
        setErr('RAGFlow 管理员账号和密码必填')
        return
      }
      if (editing && (email || password) && (!email || !password)) {
        setErr('更新 RAGFlow 管理员凭证时，账号和密码需要一起填写')
        return
      }
    }
    try {
      let saved: KBProvider
      if (editing) {
        saved = await KBProviders.patch(editing.provider_uuid, {
          name: form.name,
          endpoint_url: form.endpoint_url,
          api_key_ref: form.provider_kind === 'dify' ? apiKeyRef : '',
          settings,
        })
      } else {
        const body: KBProviderCreateInput = {
          provider_kind: form.provider_kind,
          name: form.name,
          endpoint_url: form.endpoint_url,
          api_key_ref: form.provider_kind === 'dify' ? apiKeyRef : '',
          settings,
          is_default: form.is_default,
        }
        saved = await KBProviders.create(body)
      }
      if (form.provider_kind === 'ragflow' && ragflowAdminEmail.trim() && ragflowAdminPassword) {
        await KBProviders.setRagflowCredentials(saved.provider_uuid, ragflowAdminEmail.trim(), ragflowAdminPassword)
      }
      setShowForm(false)
      setRagflowAdminEmail('')
      setRagflowAdminPassword('')
      refresh()
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  const onSetDefault = async (p: KBProvider) => {
    if (p.status === 'degraded' || p.status === 'disabled') {
      setErr('当前服务不可用，不能设为默认')
      return
    }
    try {
      await KBProviders.setDefault(p.provider_uuid)
      refresh()
    } catch (e) {
      setErr((e as Error).message)
    }
  }
  const onToggleStatus = async (p: KBProvider, enable: boolean) => {
    // 默认 provider 不允许直接禁用 (避免业务断流); 先切换默认到别的 provider 再来。
    if (!enable && p.is_default) {
      notifyError('默认服务不能直接禁用，请先将默认切换到其他服务')
      return
    }
    try {
      await KBProviders.patch(p.provider_uuid, { status: enable ? 'active' : 'disabled' })
      refresh()
      notifyOk(`「${p.name}」已${enable ? '启用' : '禁用'}`)
    } catch (e) {
      notifyError(humanizeError(e))
    }
  }
  const onHealthCheck = async (p: KBProvider) => {
    try {
      const r = await KBProviders.healthCheck(p.provider_uuid)
      refresh()
      if (r.health_error) {
        // 后端探测失败: 错误码翻译成中文给 ops 看, 而不是裸的 "kb.provider_degraded"。
        notifyError(`「${p.name}」健康检查失败：${humanizeError(r.health_error)}`)
        return
      }
      // 成功: 后端写 active, 给绿色 toast 让 ops 知道按钮真的生效了。
      const statusLabel = r.status === 'active' ? '可用' : (r.status || 'active')
      notifyOk(`「${p.name}」健康检查通过 · ${statusLabel}`)
    } catch (e) {
      notifyError(humanizeError(e))
    }
  }
  const onRemove = async (p: KBProvider) => {
    const ok = await confirmDelete.confirm({
      title: '删除知识库服务',
      description: <>确认删除「<span className="font-medium text-[var(--color-text)]">{p.name}</span>」吗？如已有知识库引用，系统会拒绝删除。</>,
      confirmLabel: '删除',
    })
    if (!ok) return
    try {
      await KBProviders.remove(p.provider_uuid)
      refresh()
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  return (
    <div>
      {confirmDelete.dialog}
      <PageHeader
        title="知识库服务配置"
        subtitle="配置平台可用的知识库服务，支持设为默认、编辑和连接检查。"
        actions={<PrimaryButton onClick={openCreate}>新建服务</PrimaryButton>}
      />

      {err && <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] rounded-md p-3 mb-4">{err}</div>}

      <div className="bg-white rounded-lg card-shadow overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
            <tr>
              <th className="px-4 py-3 text-left">名称</th>
              <th className="px-4 py-3 text-left">类型</th>
              <th className="px-4 py-3 text-left">服务地址</th>
              <th className="px-4 py-3 text-left">密钥引用</th>
              <th className="px-4 py-3 text-left">状态</th>
              <th className="px-4 py-3 text-left">默认</th>
              <th className="px-4 py-3 text-left">操作</th>
            </tr>
          </thead>
          <tbody>
            {items.map((p) => (
              <tr key={p.provider_uuid} className="border-t border-[var(--color-line)]">
                <td className="px-4 py-3 font-medium flex items-center gap-2">
                  <Database size={14} className="text-[var(--color-ink-mute)]" />
                  {p.name}
                </td>
                <td className="px-4 py-3 font-mono text-xs">{p.provider_kind}</td>
                <td className="px-4 py-3 font-mono text-xs text-[var(--color-ink-sub)]">{p.endpoint_url || '—'}</td>
                <td className="px-4 py-3 font-mono text-xs">{p.provider_kind === 'dify' ? displayAPIKeyRef(p.api_key_ref || '') : '—'}</td>
                <td className="px-4 py-3">
                  <div className="flex items-center gap-2">
                    <Switch
                      // status 三态对照开关:
                      //   active   → ON  (启用 + 健康)
                      //   degraded → ON  (启用但健康检查失败, 旁边显示红点)
                      //   disabled → OFF (禁用)
                      checked={p.status !== 'disabled'}
                      ariaLabel={p.status === 'disabled' ? '已禁用, 点击启用' : '已启用, 点击禁用'}
                      onChange={(next) => onToggleStatus(p, next)}
                    />
                    {p.status === 'degraded' && (
                      <span
                        title="健康检查失败, 不参与业务路由; 请点 健康检查 重测"
                        className="inline-block h-2 w-2 rounded-full bg-[var(--color-warn)]"
                        aria-label="健康异常"
                      />
                    )}
                  </div>
                </td>
                <td className="px-4 py-3">
                  <Switch
                    checked={p.is_default}
                    // 已是默认时不允许关 (系统必须有一个默认 provider); 后端也会拒绝。
                    // 关掉只能通过把另一个 provider 切换为默认来实现。
                    disabled={p.is_default || p.status === 'degraded' || p.status === 'disabled'}
                    ariaLabel={p.is_default ? '已是默认服务' : '切换为默认服务'}
                    onChange={() => onSetDefault(p)}
                  />
                </td>
                <td className="px-4 py-3">
                  <RowActions
                    extras={
                      <Button size="sm" variant="ghost" onClick={() => onHealthCheck(p)}>健康检查</Button>
                    }
                    onEdit={() => openEdit(p)}
                    onDelete={() => onRemove(p)}
                  />
                </td>
              </tr>
            ))}
            {!items.length && !loading && (
              <tr><td colSpan={7} className="px-4 py-8 text-center text-[var(--color-ink-mute)]">还没有知识库服务</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {showForm && (
        <DrawerShell
          title={editing ? `编辑 ${editing.name}` : '新建知识库服务'}
          subtitle="配置知识库后端服务；RAGFlow 测试环境使用 PaaS 80 端口代理 admin/api。"
          width="md"
          onClose={() => setShowForm(false)}
          footer={(
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setShowForm(false)}>取消</Button>
              <Button onClick={submit}>{editing ? '保存' : '创建'}</Button>
            </div>
          )}
        >
          <div className="space-y-4">
            <FormField label="服务类型">
              {editing ? (
                <Input value={providerLabel(form.provider_kind)} disabled />
              ) : (
                <Select
                  className="h-10 bg-white text-sm"
                  value={form.provider_kind}
                  onChange={(e) => {
                    const providerKind = e.target.value as ProviderForm['provider_kind']
                    setForm({
                      ...form,
                      provider_kind: providerKind,
                      settings_json: providerSettingsPlaceholder(providerKind, {
                        embedding: embeddingModels[0]?.id,
                        rerank: rerankModels[0]?.id,
                      }),
                    })
                  }}
                >
                  <option value="ragflow">RAGFlow</option>
                  <option value="dify">Dify</option>
                </Select>
              )}
            </FormField>
            <FormField label="名称">
              <Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder={providerNamePlaceholder(form.provider_kind)} />
            </FormField>
            <FormField label="服务地址" hint="RAGFlow 填部署 host，例如 https://ragflow.example.com；Dify 填 /v1 地址">
              <Input value={form.endpoint_url} onChange={(e) => setForm({ ...form, endpoint_url: e.target.value })} placeholder={providerEndpointPlaceholder(form.provider_kind)} />
            </FormField>
            {form.provider_kind === 'ragflow' && (
              <ProviderConfigSection title="RAGFlow 配置">
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div>
                    <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">RAGFlow Admin 端口</div>
                    <Input
                      type="number"
                      min={1}
                      max={65535}
                      value={settingNumber(form.settings_json, 'admin_port', 80)}
                      onChange={(e) => updateSetting('admin_port', Number(e.target.value || 80))}
                    />
                  </div>
                  <div>
                    <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">RAGFlow API 端口</div>
                    <Input
                      type="number"
                      min={1}
                      max={65535}
                      value={settingNumber(form.settings_json, 'api_port', 80)}
                      onChange={(e) => updateSetting('api_port', Number(e.target.value || 80))}
                    />
                  </div>
                  <div>
                    <ModelLabel label="默认 Embedding 模型" />
                    {(() => {
                      const current = settingString(form.settings_json, 'default_embedding', embeddingModels[0]?.id || fallbackEmbeddingModelOptions[0])
                      return (
                    <Select
                      className="h-10 bg-white text-sm"
                      value={current}
                      onChange={(e) => updateSetting('default_embedding', e.target.value)}
                    >
                      {modelOptionsWithCurrent(embeddingModels, current, 'embedding').map((model) => <option key={model.id} value={model.id}>{model.name}</option>)}
                    </Select>
                      )
                    })()}
                  </div>
                  <div>
                    <ModelLabel label="默认 Rerank 模型" />
                    {(() => {
                      const current = settingString(form.settings_json, 'default_rerank', rerankModels[0]?.id || fallbackRerankModelOptions[0])
                      return (
                    <Select
                      className="h-10 bg-white text-sm"
                      value={current}
                      onChange={(e) => updateSetting('default_rerank', e.target.value)}
                    >
                      {modelOptionsWithCurrent(rerankModels, current, 'rerank').map((model) => <option key={model.id} value={model.id}>{model.name}</option>)}
                    </Select>
                      )
                    })()}
                  </div>
                  <div className="sm:col-span-2">
                    <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">RAGFlow 管理员账号</div>
                    <Input
                      value={ragflowAdminEmail}
                      onChange={(e) => setRagflowAdminEmail(e.target.value)}
                      placeholder="例如 admin@ragflow.io"
                    />
                  </div>
                  <div className="sm:col-span-2">
                    <FormField label="RAGFlow 管理员密码" hint={editing ? '留空表示不修改；如需更新，请同时填写账号和密码。' : '用于自动创建 RAGFlow 租户和用户，保存时加密存储。'}>
                      <Input
                        type="password"
                        value={ragflowAdminPassword}
                        onChange={(e) => setRagflowAdminPassword(e.target.value)}
                        placeholder={editing ? '留空表示不修改' : '输入 RAGFlow 管理员密码'}
                      />
                    </FormField>
                  </div>
                </div>
              </ProviderConfigSection>
            )}
            {form.provider_kind === 'dify' && (
              <ProviderConfigSection title="Dify 配置">
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div className="sm:col-span-2">
                    <SecretValueField
                      label="Dify API Key"
                      hint={editing && (editing.api_key_ref || editing.settings?.api_token_secret_ref) ? '已保存的 Key 默认掩码显示；粘贴新 Key 可替换。' : undefined}
                      valueRef={form.api_key_ref}
                      onChangeRef={(ref) => setForm({ ...form, api_key_ref: ref })}
                      placeholder={editing ? '粘贴新 Dify API Key 可替换' : '粘贴 Dify API Key'}
                    />
                  </div>
                  <div className="sm:col-span-2">
                    <HintLabel label="Dify Dataset ID" hint={difyDatasetHint} />
                    <Input
                      value={difyDatasetID(form.settings_json)}
                      onChange={(e) => {
                        const datasetID = e.target.value
                        setForm((prev) => {
                          const settings = parseSettings(prev.settings_json)
                          settings.dataset_id = datasetID
                          settings.tenant_dataset_id = datasetID
                          settings.user_dataset_id = datasetID
                          delete settings.workspace_id
                          return { ...prev, settings_json: stringifySettings(settings) }
                        })
                      }}
                      placeholder="例如 8e71cfd0-07e7-4657-91c6-61cf973428d3"
                    />
                  </div>
                  <div>
                    <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">默认召回条数</div>
                    <Input
                      type="number"
                      min={1}
                      max={100}
                      value={settingNumber(form.settings_json, 'top_k', 5)}
                      onChange={(e) => updateSetting('top_k', Number(e.target.value || 5))}
                    />
                  </div>
                  <div>
                    <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">召回阈值</div>
                    <Input
                      type="number"
                      min={0}
                      max={1}
                      step={0.01}
                      value={settingNumber(form.settings_json, 'threshold', 0.4)}
                      onChange={(e) => updateSetting('threshold', Number(e.target.value || 0))}
                    />
                  </div>
                  <label className="flex items-center gap-2 pt-6 text-sm">
                    <input
                      type="checkbox"
                      checked={settingBool(form.settings_json, 'use_rerank', true)}
                      onChange={(e) => updateSetting('use_rerank', e.target.checked)}
                    />
                    启用 rerank
                  </label>
                </div>
              </ProviderConfigSection>
            )}
            {!editing && (
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={form.is_default} onChange={(e) => setForm({ ...form, is_default: e.target.checked })} />
                设为默认服务
              </label>
            )}
          </div>
        </DrawerShell>
      )}
    </div>
  )
}
