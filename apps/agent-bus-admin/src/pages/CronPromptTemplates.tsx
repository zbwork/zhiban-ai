// F08 §5.2 · 定时任务 Prompt 模板管理 (/cron-prompt-templates, tenant scope)
//
// 调用 admin tenant CRUD:
//   GET    /api/admin/v1/tenant/cron-prompt-templates
//   POST   /api/admin/v1/tenant/cron-prompt-templates
//   PATCH  /api/admin/v1/tenant/cron-prompt-templates/{uuid}
//   DELETE /api/admin/v1/tenant/cron-prompt-templates/{uuid}
//
// 边界 (F08 H 返修结论, 必读):
//   - 本租户模板: 本页可创建 / 修改 / 删除 draft / active / archived 全部状态.
//   - platform 模板: is_readonly=true, 仅 active 可见, 用户只能查看不能改删.
//   - is_system=true 的模板: 任何 scope 都 readonly.
//   - 失败错误码翻译:
//     * cron.prompt_template_in_use      → 仍有定时任务引用, 请先迁移或停用相关任务
//     * cron.prompt_template_readonly    → 平台模板不可修改或删除
//     * cron.prompt_template_code_conflict → 模板编号已存在
//     * cron.prompt_template_not_found   → 模板不存在或不在管辖范围
//
// 不要把任何字段直接拼成 client /api/agent-bus/v1/cron/prompt-templates;
// client 那条只读 API 只暴露 active, 把 admin 复用过去会回退到 H 返修前的契约错位.

import { useEffect, useMemo, useRef, useState } from 'react'
import { FileText } from 'lucide-react'
import {
  CronPromptTemplatesAdmin,
  CronPromptTemplatesPlatformAdmin,
  type CronPromptTemplatesClient,
  type CreatePromptTemplateReq,
  type PatchPromptTemplateReq,
  type PromptTemplateAdminDTO,
  type PromptTemplateStatus,
  type PromptTemplateVarType,
  type PromptTemplateVariableDTO,
} from '../lib/api'
import {
  Button,
  DataTable,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  PageHeader,
  PrimaryButton,
  RowActions,
  Select,
  Tabs,
  Toolbar,
} from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'

// 运营视角只有「员工能否选用」两态: active=启用, 其余(draft/archived)=禁用。
// draft 是历史遗留的后端内部状态, 界面不再提供, 存量按禁用展示。
const STATUS_LABEL: Record<PromptTemplateStatus, string> = {
  draft: '禁用',
  active: '启用',
  archived: '禁用',
}

type ScopeTab = 'tenant' | 'platform'

// K · 简洁本地化时间格式: 2026-06-06 19:00; 空值显示 '-'.
// 不引入 dayjs / luxon 等三方库, 与项目其他列表的本地格式风格一致.
function formatUpdatedAt(raw?: string): string {
  if (!raw) return '-'
  const t = new Date(raw)
  if (isNaN(t.getTime())) return '-'
  return t.toLocaleString('zh-CN', { hour12: false })
}

// 错误码 → 中文文案; 未识别的错误码直接透传 message.
function translateError(message: string): string {
  if (!message) return ''
  if (message.includes('cron.prompt_template_in_use')) {
    return '仍有定时任务引用此模板，请先迁移或停用相关任务。'
  }
  if (message.includes('cron.prompt_template_readonly')) {
    return '平台模板或系统模板不可修改 / 删除。'
  }
  if (message.includes('cron.prompt_template_code_conflict')) {
    return '模板编号已存在，请换一个。'
  }
  if (message.includes('cron.prompt_template_not_found')) {
    return '模板不存在或不在管辖范围。'
  }
  return message
}

export default function CronPromptTemplatesPage() {
  return <CronPromptTemplatesView consoleScope="tenant" />
}

// 平台控制台变体：平台模板全量 CRUD（main.tsx /cron-prompt-templates-ops 挂载）。
// 这里建的模板对全部租户的员工可见（启用状态下），租户后台对其只读。
export function PlatformCronPromptTemplatesPage() {
  return <CronPromptTemplatesView consoleScope="platform" />
}

function CronPromptTemplatesView({ consoleScope }: { consoleScope: ScopeTab }) {
  const client: CronPromptTemplatesClient =
    consoleScope === 'platform' ? CronPromptTemplatesPlatformAdmin : CronPromptTemplatesAdmin
  const [items, setItems] = useState<PromptTemplateAdminDTO[]>([])
  const [scope, setScope] = useState<ScopeTab>('tenant')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<PromptTemplateAdminDTO | null>(null)
  const { confirm, dialog: confirmDialog } = useConfirmDialog()

  async function reload() {
    setLoading(true)
    try {
      const res = await client.list()
      setItems(res.items || [])
      setErr('')
    } catch (e: unknown) {
      setErr(translateError((e as Error).message || ''))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    let mounted = true
    client.list()
      .then((res) => {
        if (!mounted) return
        setItems(res.items || [])
        setErr('')
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr(translateError((e as Error).message || '加载失败'))
      })
      .finally(() => {
        if (mounted) setLoading(false)
      })
    return () => {
      mounted = false
    }
    // client 由 consoleScope 决定且组件生命周期内不变。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const tenantItems = useMemo(() => items.filter((t) => t.scope_kind === 'tenant'), [items])
  const platformItems = useMemo(() => items.filter((t) => t.scope_kind === 'platform'), [items])
  // 平台控制台无 tab：列表即全部平台模板。
  const visibleItems =
    consoleScope === 'platform' ? items : scope === 'tenant' ? tenantItems : platformItems

  async function handleDelete(row: PromptTemplateAdminDTO) {
    if (row.is_readonly) {
      setErr('平台模板或系统模板不可删除。')
      return
    }
    // K: 删除前用 active_job_count 给出更可操作的引导.
    //
    // 字段名沿用后端 active_job_count, 但实际口径 = "本租户未软删 cron 数 (deleted_at IS NULL)",
    // 含 paused / error / pending; archived / soft-deleted 不算. 文案故意避开"启用中" /
    // "active", 防止运营误以为 paused 状态的 cron 不会阻止删除.
    //
    // active_job_count > 0 时, RowActions 已经 deleteDisabled 拦掉按钮 (不会走到这);
    // 仍保留分支文案做防御 (RowActions 失效或后端口径变化时, dialog 也能给运营提示);
    // 后端 cron.prompt_template_in_use 兜底拦截.
    const hasActive = (row.active_job_count ?? 0) > 0
    const ok = await confirm({
      title: '删除模板',
      description: hasActive ? (
        <span>
          当前有 <b>{row.active_job_count}</b> 个未删除的定时任务引用本模板（编号 {row.code}，含暂停 / 出错状态）。删除会被后端拒绝，请先迁移或删除相关任务后再试。
        </span>
      ) : (
        <span>
          确认删除模板 "<b>{row.name}</b>"（编号 {row.code}）？
          <br />
          删除后该模板不再可被员工选用；现有使用该模板的定时任务会在下次触发时回退到模板未找到的错误。
        </span>
      ),
      tone: 'danger',
      confirmLabel: '删除',
    })
    if (!ok) return
    try {
      await client.remove(row.uuid)
      await reload()
    } catch (e: unknown) {
      setErr(translateError((e as Error).message || '删除失败'))
    }
  }

  return (
    <div>
      <PageHeader
        title="定时任务模板"
        subtitle={
          consoleScope === 'platform'
            ? '维护平台预置的任务提示模板：写好提示词内容，启用后全部租户的员工创建定时任务时可选用并在其基础上修改。'
            : '维护本租户可复用的任务提示模板：写好提示词内容，员工创建定时任务时选择「使用模板」即可套用并继续修改。'
        }
      />

      <Toolbar
        filters={
          consoleScope === 'tenant' ? (
            <Tabs
              value={scope}
              onChange={(v) => setScope(v as ScopeTab)}
              items={[
                { value: 'tenant', label: '本租户' },
                { value: 'platform', label: '平台模板' },
              ]}
            />
          ) : undefined
        }
        summary={
          consoleScope === 'platform'
            ? `共 ${items.length} 个平台模板（租户后台只读，可被全部租户员工选用）`
            : undefined
        }
        actions={
          (consoleScope === 'platform' || scope === 'tenant') && (
            <PrimaryButton onClick={() => setCreating(true)}>新建模板</PrimaryButton>
          )
        }
      />

      {err && (
        <div className="mb-4">
          <InlineAlert tone="danger">{err}</InlineAlert>
        </div>
      )}

      <DataTable
        headers={['编号', '名称', '状态', '范围', '引用数', '更新时间', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中...</div> : undefined}
        empty={!loading && visibleItems.length === 0 ? (
          <EmptyState
            icon={<FileText size={22} />}
            title={
              consoleScope === 'platform' || scope === 'tenant'
                ? '暂无定时任务模板'
                : '当前无平台模板可浏览'
            }
            description={
              consoleScope === 'platform'
                ? '点击右上「新建模板」添加。启用后全部租户的员工创建定时任务时可选用并在其基础上修改。'
                : scope === 'tenant'
                  ? '点击右上「新建模板」添加。员工创建定时任务时选择「使用模板」即可套用并继续修改。'
                  : '平台模板由平台管理员维护，这里仅供参考阅读。'
            }
          />
        ) : undefined}
      >
        {!loading &&
          visibleItems.map((row) => {
            const hasActive = (row.active_job_count ?? 0) > 0
            return (
              <tr key={row.uuid} className="hover:bg-[var(--color-bg-sub)]">
                <td className="px-4 py-3">
                  <code className="rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-xs">{row.code}</code>
                </td>
                <td className="px-4 py-3">
                  <div className="text-[13px] font-medium text-[var(--color-text)]">{row.name}</div>
                </td>
                <td className="px-4 py-3">
                  <StatusBadge status={row.status} />
                </td>
                <td className="px-4 py-3 text-xs text-[var(--color-text-sub)]">
                  {row.scope_kind === 'tenant' ? '本租户' : '平台'}
                  {row.is_system && (
                    <span className="ml-1 rounded bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-[11px] text-[var(--color-text-mute)]">
                      系统
                    </span>
                  )}
                </td>
                <td className="px-4 py-3 text-xs tabular-nums text-[var(--color-text-sub)]">
                  {/* 0 也显式展示, 不留空 */}
                  <span
                    title={
                      consoleScope === 'platform'
                        ? '全部租户的定时任务引用数 (未删除即计入, 含暂停/出错)'
                        : '本租户当前定时任务引用数 (未删除即计入, 含暂停/出错)'
                    }
                  >
                    {row.active_job_count ?? 0}
                  </span>
                </td>
                <td className="px-4 py-3 text-xs text-[var(--color-text-mute)]">
                  {formatUpdatedAt(row.updated_at)}
                </td>
                <td className="px-4 py-3">
                  <RowActions
                    onEdit={() => setEditing(row)}
                    editLabel={row.is_readonly ? '查看' : '编辑'}
                    onDelete={row.is_readonly ? undefined : () => void handleDelete(row)}
                    // 引用数 > 0 时按钮禁用 (UI 提前拦截 + 后端 cron.prompt_template_in_use 兜底)
                    deleteDisabled={hasActive}
                  />
                </td>
              </tr>
            )
          })}
      </DataTable>

      {(creating || editing) && (
        <TemplateDrawer
          client={client}
          consoleScope={consoleScope}
          initial={editing}
          onClose={() => {
            setCreating(false)
            setEditing(null)
          }}
          onSaved={async () => {
            setCreating(false)
            setEditing(null)
            await reload()
          }}
          onError={(msg) => setErr(translateError(msg))}
        />
      )}

      {confirmDialog}
    </div>
  )
}

function StatusBadge({ status }: { status: PromptTemplateStatus }) {
  const tone: Record<PromptTemplateStatus, string> = {
    draft: 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]',
    active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    archived: 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]',
  }
  return (
    <span className={`inline-flex rounded px-2 py-1 text-[12px] ${tone[status]}`}>{STATUS_LABEL[status]}</span>
  )
}

// ====== 创建 / 编辑 Drawer ======

// VariableRowForm 是 drawer 内部使用的本地 row 类型: default_value / options 用纯字符串
// 编辑, 提交时再按 var_type 解析回 backend 期望的 JSON 形态.
type VariableRowForm = {
  var_name: string
  var_type: PromptTemplateVarType
  required: boolean
  default_value_text: string
  options_text: string
  display_name: string
}

function dtoToFormRows(vars: PromptTemplateVariableDTO[] | undefined): VariableRowForm[] {
  if (!vars || vars.length === 0) return []
  return vars
    .slice()
    .sort((a, b) => a.order_index - b.order_index)
    .map((v) => ({
      var_name: v.var_name,
      var_type: v.var_type,
      required: !!v.required,
      default_value_text: defaultValueToText(v.default_value, v.var_type),
      options_text: optionsToText(v.options),
      display_name: v.display_name || '',
    }))
}

function defaultValueToText(val: unknown, ty: PromptTemplateVarType): string {
  if (val === undefined || val === null) return ''
  if (ty === 'list') {
    if (Array.isArray(val)) return val.map((x) => String(x)).join(', ')
    return String(val)
  }
  if (typeof val === 'object') return JSON.stringify(val)
  return String(val)
}

function optionsToText(opts: unknown[] | undefined): string {
  if (!opts || opts.length === 0) return ''
  return opts.map((x) => String(x)).join(', ')
}

function parseDefaultValue(text: string, ty: PromptTemplateVarType): unknown {
  const trimmed = text.trim()
  if (!trimmed) return undefined
  if (ty === 'int') {
    const n = Number(trimmed)
    if (!Number.isFinite(n) || !Number.isInteger(n)) {
      throw new Error(`变量默认值不是整数: ${text}`)
    }
    return n
  }
  if (ty === 'list') {
    return splitTokens(trimmed)
  }
  // string / enum / datetime: 都按字符串落库.
  return trimmed
}

function parseOptions(text: string, ty: PromptTemplateVarType): unknown[] | undefined {
  const trimmed = text.trim()
  if (!trimmed) return undefined
  const tokens = splitTokens(trimmed)
  if (ty === 'int') {
    const out: number[] = []
    for (const t of tokens) {
      const n = Number(t)
      if (!Number.isFinite(n) || !Number.isInteger(n)) {
        throw new Error(`枚举/列表候选项不是整数: ${t}`)
      }
      out.push(n)
    }
    return out
  }
  return tokens
}

function splitTokens(text: string): string[] {
  return text
    .split(/[,\n]/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
}

function TemplateDrawer({
  client,
  consoleScope,
  initial,
  onClose,
  onSaved,
  onError,
}: {
  client: CronPromptTemplatesClient
  consoleScope: ScopeTab
  initial: PromptTemplateAdminDTO | null
  onClose: () => void
  onSaved: () => Promise<void>
  onError: (msg: string) => void
}) {
  const isEdit = !!initial
  const isReadonly = !!initial?.is_readonly

  const [loadingDetail, setLoadingDetail] = useState(isEdit)
  const [detailErr, setDetailErr] = useState('')

  // form fields:
  const [code, setCode] = useState(initial?.code || '')
  const [name, setName] = useState(initial?.name || '')
  const [description, setDescription] = useState('')
  const [templateBody, setTemplateBody] = useState('')
  const [status, setStatus] = useState<PromptTemplateStatus>(initial?.status || 'active')
  const [vars, setVars] = useState<VariableRowForm[]>([])
  // varsTouched: PATCH 时区分 "用户没动" 与 "用户清空" — false → 不传 variables 字段.
  // 变量编辑区已随客户端「粘贴即编辑」交互下线（2026-06-12 产品决策），本状态恒为
  // false：编辑保存永不重置已有变量定义；新建提交空变量列表。后台数据能力保留。
  const [varsTouched] = useState(false)
  const [saving, setSaving] = useState(false)
  const [formErr, setFormErr] = useState('')
  const detailLoadedRef = useRef(false)

  useEffect(() => {
    if (!isEdit || !initial) {
      return
    }
    let mounted = true
    // 编辑场景需要 body + variables; admin list 不返这两个字段, 单独走 admin GET detail.
    // admin resolver: 管辖范围内 draft/active/archived 全可读, 不复检 status.
    client.get(initial.uuid)
      .then((d) => {
        if (!mounted) return
        setCode(d.code)
        setName(d.name)
        // J 返修: description 从 detail 回填; 老实现没字段, 保存时会从空 state 把 description 抹空.
        setDescription(d.description ?? '')
        setTemplateBody(d.template_body || '')
        setStatus(d.status)
        setVars(dtoToFormRows(d.variables))
        detailLoadedRef.current = true
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setDetailErr(translateError((e as Error).message || '加载模板详情失败'))
      })
      .finally(() => {
        if (mounted) setLoadingDetail(false)
      })
    return () => {
      mounted = false
    }
  }, [isEdit, initial, client])

  function buildVariablesPayload(): PromptTemplateVariableDTO[] {
    const seen = new Set<string>()
    const out: PromptTemplateVariableDTO[] = []
    vars.forEach((row, i) => {
      const varName = row.var_name.trim()
      if (!varName) {
        throw new Error(`第 ${i + 1} 个变量缺少变量名`)
      }
      if (seen.has(varName)) {
        throw new Error(`变量名重复: ${varName}`)
      }
      seen.add(varName)
      const dto: PromptTemplateVariableDTO = {
        var_name: varName,
        var_type: row.var_type,
        required: row.required,
        order_index: i,
      }
      const dv = parseDefaultValue(row.default_value_text, row.var_type)
      if (dv !== undefined) dto.default_value = dv
      const opts = parseOptions(row.options_text, row.var_type)
      if (opts && opts.length > 0) dto.options = opts
      const dn = row.display_name.trim()
      if (dn) dto.display_name = dn
      out.push(dto)
    })
    return out
  }

  async function submit() {
    setFormErr('')
    if (isReadonly) {
      // 只读模式只展示查看; 不应该走到这里.
      onClose()
      return
    }
    if (!code.trim() && !isEdit) {
      setFormErr('请填写模板编号')
      return
    }
    if (!name.trim()) {
      setFormErr('请填写模板名称')
      return
    }
    if (!templateBody.trim()) {
      setFormErr('请填写任务提示模板正文')
      return
    }
    let variablesPayload: PromptTemplateVariableDTO[]
    try {
      variablesPayload = buildVariablesPayload()
    } catch (e: unknown) {
      setFormErr((e as Error).message || '变量定义不合法')
      return
    }

    setSaving(true)
    try {
      if (isEdit && initial) {
        const body: PatchPromptTemplateReq = {
          name,
          description,
          template_body: templateBody,
          status,
        }
        // variables 字段语义: 用户没动 → 不传; 否则全量替换 (含 [] 清空).
        if (varsTouched) {
          body.variables = variablesPayload
        }
        await client.patch(initial.uuid, body)
      } else {
        const body: CreatePromptTemplateReq = {
          code: code.trim(),
          name: name.trim(),
          description: description.trim() || undefined,
          template_body: templateBody,
          status,
          variables: variablesPayload,
        }
        await client.create(body)
      }
      await onSaved()
    } catch (e: unknown) {
      const msg = (e as Error).message || '保存失败'
      setFormErr(translateError(msg))
      onError(msg)
    } finally {
      setSaving(false)
    }
  }

  const drawerTitle = isReadonly
    ? `查看模板 · ${initial?.name || ''}`
    : isEdit
      ? `编辑模板 · ${initial?.name || ''}`
      : '新建模板'

  return (
    <DrawerShell
      onClose={onClose}
      title={drawerTitle}
      subtitle="员工创建定时任务时可选用启用状态的模板，并在其内容基础上修改。"
      icon={<FileText size={18} />}
      width="md"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            {isReadonly ? '关闭' : '取消'}
          </Button>
          {!isReadonly && (
            <PrimaryButton onClick={() => void submit()} disabled={saving || loadingDetail}>
              {saving ? '保存中…' : '保存'}
            </PrimaryButton>
          )}
        </div>
      }
    >
      <div className="space-y-4">
        {loadingDetail && (
          <div className="text-[13px] text-[var(--color-text-mute)]">加载模板详情…</div>
        )}
        {detailErr && <InlineAlert tone="danger">{detailErr}</InlineAlert>}
        {formErr && <InlineAlert tone="danger">{formErr}</InlineAlert>}
        {isReadonly && !loadingDetail && (
          <InlineAlert tone="info">
            这是平台模板或系统模板，仅供查看。如需调整请联系平台管理员。
          </InlineAlert>
        )}

        {!loadingDetail && (
          <>
          <FormSection title="基本信息">
            <div className="grid grid-cols-2 gap-3">
              <FormField
                label="模板编号"
                hint={
                  consoleScope === 'platform'
                    ? '平台内唯一，用于系统识别；创建后不可修改。'
                    : '租户内唯一，用于系统识别；创建后不可修改。'
                }
              >
                <Input
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  disabled={isEdit || isReadonly}
                  placeholder="例：daily-sales-report"
                />
              </FormField>
              <FormField label="模板名称">
                <Input
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  disabled={isReadonly}
                  placeholder="给运营看的中文名"
                />
              </FormField>
              <FormField label="说明" hint="可选，帮助员工理解此模板用途。">
                <Input
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  disabled={isReadonly}
                  placeholder="可选"
                />
              </FormField>
              <FormField label="状态">
                <Select
                  value={status === 'active' ? 'active' : 'archived'}
                  onChange={(e) => setStatus(e.target.value as PromptTemplateStatus)}
                  disabled={isReadonly}
                >
                  <option value="active">启用</option>
                  <option value="archived">禁用</option>
                </Select>
              </FormField>
            </div>
          </FormSection>

          <FormSection
            title="任务提示模板"
            description="员工选用模板后，这段内容会原样填进任务的「助手任务提示」输入框，员工可在其基础上修改后提交。"
          >
            <FormField label="提示词正文">
              <textarea
                className="h-44 w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 font-mono text-[12.5px] text-[var(--color-text)] transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]"
                value={templateBody}
                onChange={(e) => setTemplateBody(e.target.value)}
                disabled={isReadonly}
                spellCheck={false}
                placeholder="例：每天收集 AI 行业最新动态，输出 5 条要点摘要并附来源链接。"
              />
            </FormField>
          </FormSection>
          </>
        )}
      </div>
    </DrawerShell>
  )
}
