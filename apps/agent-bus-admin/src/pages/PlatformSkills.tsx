// PlatformSkills — 平台技能管理 (/skills)。
//
// 平台技能采用列表页 + 右侧抽屉详情结构，避免三栏常驻编辑区挤压主列表。

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ChangeEvent, type DragEvent as ReactDragEvent, type ReactNode } from 'react'
import JSZip from 'jszip'
import {
  Box,
  ChevronDown,
  ChevronRight,
  Download,
  FileArchive,
  FileText,
  Plus,
  RefreshCw,
  Save,
  Search,
  Trash2,
  Upload,
  Wand,
} from 'lucide-react'
import {
  Billing as BillingAPI,
  PlatformSkills,
  PlatformTypes,
  TenantOwnSkills,
  TenantSkills,
  type BillingSkillOperation,
  type BillingSkillOperationImport,
  type BillingSkillOperationPrice,
  type SkillBuiltinKey,
  type SkillCategory,
  type SkillLabel,
  type SkillBundleImportResult,
  type Skill,
  type SkillVersion,
  type PlatformType,
} from '../lib/api'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  InlineAlert,
  Input,
  PageHeader,
  Pagination,
  PrimaryButton,
  RowActions,
  Select,
} from '../components/ui'
import { FileUploadPicker } from '../components/form/FileUploadPicker'
import { LabelMultiSelect } from '../components/form/LabelMultiSelect'
import { SKILL_KIND_LABEL as KIND_LABEL, SKILL_VISIBILITY_LABEL as VISIBILITY_LABEL } from '../lib/skillLabels'
import { notifyOk } from '../lib/toast'

const skillTableClass = 'table-sticky-first table-sticky-actions overflow-x-auto'
const skillNameCellClass = 'w-[170px] min-w-[170px] max-w-[190px] whitespace-nowrap px-4 py-2'
const skillCodeCellClass = 'min-w-[160px] whitespace-nowrap px-4 py-2 font-mono text-[12px] text-[var(--color-text-sub)]'
const skillTextCellClass = 'min-w-[110px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]'
const skillNumberCellClass = 'min-w-[72px] whitespace-nowrap px-4 py-2 text-[12px] tabular-nums text-[var(--color-text-sub)]'
const skillTimeCellClass = 'min-w-[140px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]'
const skillStatusCellClass = 'w-[72px] min-w-[72px] whitespace-nowrap px-4 py-2'
const skillPriceCellClass = 'min-w-[96px] whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]'
const skillActionCellClass = 'w-[150px] min-w-[150px] whitespace-nowrap px-4 py-2'
const textareaClass = 'min-h-[96px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-relaxed text-[var(--color-text)] outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]'
const compactTextareaClass = 'min-h-[64px] w-full resize-y rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] leading-relaxed text-[var(--color-text)] outline-none transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px] disabled:cursor-not-allowed disabled:bg-[var(--color-line-soft)] disabled:text-[var(--color-text-mute)]'
type SkillStatus = 'draft' | 'active' | 'archived'

function isSkillEnabled(status?: string): boolean {
  return status === 'active'
}

function skillStatusFromEnabled(enabled: boolean): SkillStatus {
  return enabled ? 'active' : 'archived'
}

function versionStateLabel(v: SkillVersion, skill: Skill): string {
  if (v.status === 'archived') return '已归档'
  if (v.id && skill.latest_version_id === v.id) return '已发布'
  return '未发布'
}

// 类型 / 可见范围 label 统一从 lib/skillLabels 拿 (KIND_LABEL / VISIBILITY_LABEL 别名仅
// 为最小化下文调用点改动)。real imports 在文件顶部。
const GRAYSCALE_STRATEGY_LABEL: Record<string, string> = {
  tenant_hash: '按租户',
  agent_hash: '按数字员工',
  user_hash: '按用户',
  tenant_allowlist: '指定租户',
}
const EMPTY_AGENT_COMPAT: AgentCompatDraft = {
  required_models: '',
  required_runtimes: '',
  blocked_agent_tags: '',
}

function fmtDateTime(s?: string): string {
  if (!s) return '-'
  const d = new Date(s)
  if (Number.isNaN(d.getTime())) return s
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function statusClass(status?: string) {
  if (status === 'active' || status === 'published') return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  if (status === 'draft') return 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
  if (status === 'archived' || status === 'deprecated') return 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'
  return 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'
}

function billingTypeLabel(value?: string) {
  return value === 'paid' ? '付费' : '免费'
}

function pricingModeLabel(value?: string) {
  return value === 'per_operation' ? '按接口' : '按技能'
}

function InlineSwitch({
  checked,
  onChange,
  disabled,
  title,
}: {
  checked: boolean
  onChange: (next: boolean) => Promise<void> | void
  disabled?: boolean
  title?: string
}) {
  const [busy, setBusy] = useState(false)
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={title}
      title={title}
      disabled={disabled || busy}
      onClick={async () => {
        if (disabled || busy) return
        setBusy(true)
        try {
          await onChange(!checked)
        } finally {
          setBusy(false)
        }
      }}
      className={`relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-text)]/30 disabled:cursor-not-allowed disabled:opacity-60 ${checked ? 'bg-[var(--color-success)]' : 'bg-[var(--color-line)]'}`}
    >
      <span className={`inline-block h-4 w-4 rounded-full bg-white shadow-sm transition-transform ${checked ? 'translate-x-[18px]' : 'translate-x-[2px]'}`} />
    </button>
  )
}

function SelectionCheckbox({
  checked,
  mixed = false,
  disabled = false,
  label,
  onChange,
}: {
  checked: boolean
  mixed?: boolean
  disabled?: boolean
  label: string
  onChange: (checked: boolean) => void
}) {
  const ref = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = mixed
  }, [mixed])
  return (
    <input
      ref={ref}
      type="checkbox"
      checked={checked}
      disabled={disabled}
      aria-label={label}
      aria-checked={mixed ? 'mixed' : checked}
      onChange={(e) => onChange(e.target.checked)}
      className="h-4 w-4 rounded border-[var(--color-line)] accent-[var(--color-brand)] disabled:cursor-not-allowed disabled:opacity-45"
    />
  )
}

function SelectField({
  label,
  value,
  onChange,
  children,
  disabled,
  hint,
}: {
  label: string
  value: string | number
  onChange: (value: string) => void
  children: ReactNode
  disabled?: boolean
  hint?: string
}) {
  return (
    <FormField label={label} hint={hint}>
      <Select
        value={String(value)}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
      >
        {children}
      </Select>
    </FormField>
  )
}

type Filter = {
  kind?: string
  status?: string
  q?: string
  categoryID?: number
  billingType?: string
  pricingMode?: string
  defaultPrice?: string
  operations?: string
}

const MAX_SKILL_SELECTION = 100
const MAX_SKILL_BUNDLE_EXPORT = 20

function chunkSkillUUIDs(uuids: string[]): string[][] {
  const chunks: string[][] = []
  for (let i = 0; i < uuids.length; i += MAX_SKILL_BUNDLE_EXPORT) {
    chunks.push(uuids.slice(i, i + MAX_SKILL_BUNDLE_EXPORT))
  }
  return chunks
}

function skillBundleFilename(stamp: string, part: number, total: number): string {
  const partSuffix = total > 1
    ? `-part-${String(part).padStart(2, '0')}-of-${String(total).padStart(2, '0')}`
    : ''
  return `skills-${stamp}${partSuffix}.skillbundle.zip`
}

// ============================================================================
// 公共组件: SkillsPage(scope='platform' | 'tenant')
// ----------------------------------------------------------------------------
// PlatformSkillsPage 和 TenantSkillsOwnPage 都是它的薄包装。
//
// 复用面:
//   - 列表 / 详情 drawer / 版本管理 / SKILL.md zip 上传 / chip schema 编辑 100% 共用
//   - CRUD API endpoint 通过 SkillAPICtx 注入, 内部全部用 useSkillAPI() 拿
//   - 字典 (categories / labels / builtin keys) tenant 也读 platform 的, 不切
//
// scope 差异:
//   - title / subtitle 不同
//   - tenant 模式: 列表 client filter scope=tenant, 创建时 kind 限制 agent, visibility 强制 tenant
//   - platform 模式: 看所有 scope=platform 的技能, 可创建任意 kind
// ============================================================================

type SkillScope = 'platform' | 'tenant'

// SkillAPI · CRUD + 版本 + zip 上传方法的并集 (platform 和 tenant 同款 shape)。
// 字典方法 (listCategories/listLabels/...) 不收进来 — tenant 也读 platform 字典。
type SkillAPI = {
  create: typeof PlatformSkills.create
  patch: typeof PlatformSkills.patch
  delete: typeof PlatformSkills.delete
  listVersions: typeof PlatformSkills.listVersions
  createAgentVersion: typeof PlatformSkills.createAgentVersion
  createBuiltinVersion: typeof PlatformSkills.createBuiltinVersion
  publish: typeof PlatformSkills.publish
  rollback: typeof PlatformSkills.rollback
  uploadPackage: typeof PlatformSkills.uploadPackage
  listVersionFiles: typeof PlatformSkills.listVersionFiles
  getVersionFileContent: typeof PlatformSkills.getVersionFileContent
  getVersionDownloadURL: typeof PlatformSkills.getVersionDownloadURL
  uploadIcon: typeof PlatformSkills.uploadIcon
  uploadExampleImage: typeof PlatformSkills.uploadExampleImage
  // 字典 (categories / labels / builtin keys) — tenant 走 /tenant/* 镜像 endpoint
  listCategories: typeof PlatformSkills.listCategories
  listLabels: typeof PlatformSkills.listLabels
  listBuiltinKeys: typeof PlatformSkills.listBuiltinKeys
}

// Ctx 携带 api 和 scope, 让子组件 (CreateModal 等) 既能调 API 也能根据 scope 调 UI。
const SkillAPICtx = createContext<{ api: SkillAPI; scope: SkillScope }>({
  api: PlatformSkills as SkillAPI,
  scope: 'platform',
})
const useSkillAPI = () => useContext(SkillAPICtx).api
const useSkillScope = () => useContext(SkillAPICtx).scope

// platform 模式的薄包装 (保持原 export 不破坏路由 / 引用)
export function PlatformSkillsPage() {
  return <SkillsPage scope="platform" />
}

// tenant 模式的薄包装 — 复用同一个 SkillsPage, 仅 scope 不同。
// TenantSkillsOwn.tsx 内部就 mount 这个。
export function TenantSkillsOwnPage() {
  return <SkillsPage scope="tenant" />
}

// SkillsPage · 真正干活的公共组件 (原 PlatformSkillsPage 内容)。
function SkillsPage({ scope }: { scope: SkillScope }) {
  const skillApi: SkillAPI = scope === 'tenant' ? (TenantOwnSkills as SkillAPI) : PlatformSkills
  // tenant 模式: 列表走 TenantSkills.list (返回平台 + 本租户混合), 之后 client filter scope=tenant。
  // platform 模式: 沿用 PlatformSkills.list (只返 scope=platform)。
  const fetchList = useCallback((args: { kind?: string; status?: string; q?: string; category_id?: number; billing_type?: string; pricing_mode?: string; default_price?: string; operations?: string; limit?: number; offset?: number }) => {
    if (scope === 'tenant') {
      return TenantSkills.list({
        kind: args.kind, status: args.status, q: args.q,
        limit: args.limit, offset: args.offset,
      }).then((r) => {
        // 后端返回平台 + 本租户混合, 这里 client filter 只保留 scope=tenant。
        // total 也要按 filter 后的数量, 否则分页器显示"共 N 条"包含平台技能数, 跟可见行数对不上。
        const items = (r.items || []).filter((s) => s.scope_kind === 'tenant') as Skill[]
        return { items, total: items.length }
      })
    }
    return PlatformSkills.list(args)
  }, [scope])

  return (
    <SkillAPICtx.Provider value={{ api: skillApi, scope }}>
      <SkillsPageInner scope={scope} fetchList={fetchList} />
    </SkillAPICtx.Provider>
  )
}

function SkillsPageInner({
  scope,
  fetchList,
}: {
  scope: SkillScope
  fetchList: (args: { kind?: string; status?: string; q?: string; category_id?: number; billing_type?: string; pricing_mode?: string; default_price?: string; operations?: string; limit?: number; offset?: number }) => Promise<{ items: Skill[]; total: number }>
}) {
  const api = useSkillAPI()
  const isTenant = scope === 'tenant'
  const [items, setItems] = useState<Skill[]>([])
  const [categories, setCategories] = useState<SkillCategory[]>([])
  const [labels, setLabels] = useState<SkillLabel[]>([])
  const [activeUUID, setActiveUUID] = useState('')
  const [statusBusyUUID, setStatusBusyUUID] = useState('')
  const [marketingBusyUUID, setMarketingBusyUUID] = useState('')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState<Filter>({})
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [showCreate, setShowCreate] = useState(false)
  const [deleting, setDeleting] = useState<Skill | null>(null)
  const [pricingSkill, setPricingSkill] = useState<Skill | null>(null)
  const [selectedUUIDs, setSelectedUUIDs] = useState<Set<string>>(() => new Set())
  const [selectedUnpublishedUUIDs, setSelectedUnpublishedUUIDs] = useState<Set<string>>(() => new Set())
  const [showBundleImport, setShowBundleImport] = useState(false)
  const [showBatchDelete, setShowBatchDelete] = useState(false)
  const [exporting, setExporting] = useState(false)
  const [exportProgress, setExportProgress] = useState(0)
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let cancelled = false
    // fetchList 由外层 SkillsPage 注入: platform 走 PlatformSkills.list, tenant 走 TenantSkills.list + client filter。
    fetchList({
      kind: filter.kind,
      status: filter.status,
      q: filter.q,
      category_id: filter.categoryID,
      billing_type: filter.billingType,
      pricing_mode: filter.pricingMode,
      default_price: filter.defaultPrice,
      operations: filter.operations,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [fetchList, reload, filter.kind, filter.status, filter.q, filter.categoryID, filter.billingType, filter.pricingMode, filter.defaultPrice, filter.operations, page, pageSize])

  useEffect(() => {
    let cancelled = false
    api.listCategories({ limit: 200, offset: 0 })
      .then((r) => { if (!cancelled) setCategories(r.items || []) })
      .catch(() => {
        // 字典获取失败不阻塞主列表，用户可去字典页单独排查。
      })
    api.listLabels({ limit: 200, offset: 0 })
      .then((r) => { if (!cancelled) setLabels(r.items || []) })
      .catch(() => {})
    return () => { cancelled = true }
  }, [api])

  const active = useMemo(() => items.find((s) => s.uuid === activeUUID), [items, activeUUID])
  const categoryMap = useMemo(() => {
    const m = new Map<number, SkillCategory>()
    categories.forEach((c) => m.set(c.id, c))
    return m
  }, [categories])

  const isPermErr = !!err && /forbidden|denied|权限|permission/i.test(err)

  const refresh = useCallback(() => {
    setLoading(true)
    setErr('')
    setReload((t) => t + 1)
  }, [])

  const patchFilter = (next: Partial<Filter>) => {
    setLoading(true)
    setErr('')
    setPage(1)
    setSelectedUUIDs(new Set())
    setSelectedUnpublishedUUIDs(new Set())
    setFilter((prev) => ({ ...prev, ...next }))
  }

  const clearFilter = () => {
    setLoading(true)
    setErr('')
    setPage(1)
    setSelectedUUIDs(new Set())
    setSelectedUnpublishedUUIDs(new Set())
    setFilter({})
  }

  const setSkillEnabled = async (skill: Skill, enabled: boolean) => {
    setStatusBusyUUID(skill.uuid)
    setErr('')
    try {
      const updated = await api.patch(skill.uuid, { status: skillStatusFromEnabled(enabled) })
      setItems((prev) => prev.map((it) => it.uuid === updated.uuid ? updated : it))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setStatusBusyUUID('')
    }
  }

  const setSkillMarketingVisible = async (skill: Skill, visible: boolean) => {
    setMarketingBusyUUID(skill.uuid)
    setErr('')
    try {
      const updated = await api.patch(skill.uuid, { marketing_visible: visible })
      setItems((prev) => prev.map((it) => it.uuid === updated.uuid ? updated : it))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setMarketingBusyUUID('')
    }
  }

  const hasFilter = !!(filter.q || filter.kind || filter.status || filter.categoryID || filter.billingType || filter.pricingMode || filter.defaultPrice || filter.operations)
  const selectablePageItems = useMemo(() => isTenant ? [] : items, [isTenant, items])
  const selectedOnPage = selectablePageItems.filter((item) => selectedUUIDs.has(item.uuid)).length
  const allPageSelected = selectablePageItems.length > 0 && selectedOnPage === selectablePageItems.length
  const exportBatchCount = selectedUUIDs.size === 0
    ? 0
    : Math.ceil(selectedUUIDs.size / MAX_SKILL_BUNDLE_EXPORT)

  const setPageSelected = (checked: boolean) => {
    const next = new Set(selectedUUIDs)
    const nextUnpublished = new Set(selectedUnpublishedUUIDs)
    if (!checked) {
      selectablePageItems.forEach((item) => {
        next.delete(item.uuid)
        nextUnpublished.delete(item.uuid)
      })
    } else {
      const additions = selectablePageItems.filter((item) => !next.has(item.uuid))
      if (next.size + additions.length > MAX_SKILL_SELECTION) {
        setErr(`单次最多选择 ${MAX_SKILL_SELECTION} 个技能`)
        return
      }
      additions.forEach((item) => {
        next.add(item.uuid)
        if (item.latest_version_id == null) nextUnpublished.add(item.uuid)
      })
    }
    setSelectedUUIDs(next)
    setSelectedUnpublishedUUIDs(nextUnpublished)
  }

  const setRowSelected = (skill: Skill, checked: boolean) => {
    const next = new Set(selectedUUIDs)
    const nextUnpublished = new Set(selectedUnpublishedUUIDs)
    if (checked) {
      if (next.size >= MAX_SKILL_SELECTION) {
        setErr(`单次最多选择 ${MAX_SKILL_SELECTION} 个技能`)
        return
      }
      next.add(skill.uuid)
      if (skill.latest_version_id == null) nextUnpublished.add(skill.uuid)
    } else {
      next.delete(skill.uuid)
      nextUnpublished.delete(skill.uuid)
    }
    setSelectedUUIDs(next)
    setSelectedUnpublishedUUIDs(nextUnpublished)
  }

  const exportSelected = async () => {
    if (selectedUUIDs.size === 0 || exporting) return
    if (selectedUnpublishedUUIDs.size > 0) {
      setErr('批量导出只支持已发布技能，请取消未发布技能后重试')
      return
    }
    const batches = chunkSkillUUIDs(Array.from(selectedUUIDs))
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
    let completed = 0
    setExporting(true)
    setExportProgress(1)
    setErr('')
    try {
      for (let index = 0; index < batches.length; index += 1) {
        setExportProgress(index + 1)
        await PlatformSkills.exportBundle(
          batches[index],
          skillBundleFilename(stamp, index + 1, batches.length),
        )
        completed += 1
      }
      notifyOk(batches.length > 1
        ? `已分批导出 ${selectedUUIDs.size} 个技能，共 ${batches.length} 个 Bundle 文件`
        : `已导出 ${selectedUUIDs.size} 个技能`)
    } catch (e) {
      const message = (e as Error).message
      setErr(completed > 0
        ? `已导出 ${completed}/${batches.length} 个 Bundle，后续批次失败：${message}`
        : message)
    } finally {
      setExporting(false)
      setExportProgress(0)
    }
  }

  return (
    <div>
      <PageHeader
        title={isTenant ? '企业技能' : '技能管理'}
        subtitle={isTenant
          ? '本企业自建的 Agent 技能。仅本企业的数字员工可装配, 不对外发布。'
          : '维护平台上架的 Agent 技能与客户端原生技能。包含元信息编辑、启用禁用、版本管理、SKILL.md 包上传与版本发布。'}
      />

      {err && (
        <div className="mb-4">
          <InlineAlert>
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="font-medium">{errTitle(err)}</div>
                <div className="mt-1 text-[12px]">{err}</div>
                <div className="mt-1 text-[12px]">{errHint(err, isPermErr)}</div>
              </div>
              <Button size="sm" variant="ghost" onClick={refresh}>
                <RefreshCw size={14} />
                重试
              </Button>
            </div>
          </InlineAlert>
        </div>
      )}

      <div className="mb-2 flex flex-wrap items-end gap-3">
        <div className="relative min-w-[280px] flex-1">
          <Search size={15} className="pointer-events-none absolute left-3 top-[31px] text-[var(--color-text-mute)]" />
          <FormField label="关键词">
            <Input
              placeholder="按 code / 名称 / 描述搜索"
              value={filter.q || ''}
              onChange={(e) => patchFilter({ q: e.target.value || undefined })}
              className="pl-9"
            />
          </FormField>
        </div>
        <div className="w-[160px]">
          <SelectField label="类型" value={filter.kind || ''} onChange={(v) => patchFilter({ kind: v || undefined })}>
            <option value="">全部类型</option>
            <option value="agent">Agent 技能</option>
            <option value="builtin">客户端原生</option>
          </SelectField>
        </div>
        <div className="w-[150px]">
          <SelectField label="状态" value={filter.status || ''} onChange={(v) => patchFilter({ status: v || undefined })}>
            <option value="">全部状态</option>
            <option value="active">启用</option>
            <option value="inactive">禁用</option>
          </SelectField>
        </div>
        <div className="w-[190px]">
          <SelectField
            label="分类"
            value={filter.categoryID ?? ''}
            onChange={(v) => patchFilter({ categoryID: v ? Number(v) : undefined })}
          >
            <option value="">全部分类</option>
            {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </SelectField>
        </div>
        {!isTenant && (
          <>
            <div className="w-[140px]">
              <SelectField label="计费类型" value={filter.billingType || ''} onChange={(v) => patchFilter({ billingType: v || undefined })}>
                <option value="">全部计费</option>
                <option value="free">免费</option>
                <option value="paid">付费</option>
              </SelectField>
            </div>
            <div className="w-[150px]">
              <SelectField label="定价模式" value={filter.pricingMode || ''} onChange={(v) => patchFilter({ pricingMode: v || undefined })}>
                <option value="">全部模式</option>
                <option value="per_skill">按技能</option>
                <option value="per_operation">按接口</option>
              </SelectField>
            </div>
            <div className="w-[150px]">
              <SelectField label="默认价" value={filter.defaultPrice || ''} onChange={(v) => patchFilter({ defaultPrice: v || undefined })}>
                <option value="">全部价格</option>
                <option value="configured">已配置</option>
                <option value="missing">未配置</option>
              </SelectField>
            </div>
            <div className="w-[150px]">
              <SelectField label="接口配置" value={filter.operations || ''} onChange={(v) => patchFilter({ operations: v || undefined })}>
                <option value="">全部接口</option>
                <option value="has_operations">有接口</option>
                <option value="no_operations">无接口</option>
              </SelectField>
            </div>
          </>
        )}
        {hasFilter && (
          <Button variant="ghost" onClick={clearFilter}>清空筛选</Button>
        )}
      </div>

      <div className="mb-3 flex min-h-9 items-center justify-end gap-2">
        {!isTenant && selectedUUIDs.size > 0 && (
          <>
            <span className={`mr-1 text-[12px] ${selectedUnpublishedUUIDs.size > 0 ? 'text-[var(--color-warn)]' : 'text-[var(--color-text-sub)]'}`}>
              已选 {selectedUUIDs.size} 项
              {selectedUnpublishedUUIDs.size > 0
                ? ` · ${selectedUnpublishedUUIDs.size} 项未发布`
                : (exportBatchCount > 1 ? ` · 将下载 ${exportBatchCount} 个包` : '')}
            </span>
            <Button variant="secondary" onClick={() => { setSelectedUUIDs(new Set()); setSelectedUnpublishedUUIDs(new Set()) }}>取消选择</Button>
            <Button
              variant="secondary"
              onClick={exportSelected}
              disabled={exporting || selectedUnpublishedUUIDs.size > 0}
              title={selectedUnpublishedUUIDs.size > 0
                ? `批量导出只支持已发布技能，当前有 ${selectedUnpublishedUUIDs.size} 项未发布`
                : (exportBatchCount > 1 ? `将按每包最多 ${MAX_SKILL_BUNDLE_EXPORT} 项下载 ${exportBatchCount} 个文件` : undefined)}
            >
              <Download size={14} />
              {exporting
                ? `导出中 ${exportProgress}/${exportBatchCount}`
                : (exportBatchCount > 1 ? `分批导出（${exportBatchCount} 个包）` : '批量导出')}
            </Button>
            <Button variant="danger" onClick={() => setShowBatchDelete(true)}>
              <Trash2 size={14} />
              批量删除
            </Button>
          </>
        )}
        {!isTenant && (
          <Button variant="secondary" onClick={() => setShowBundleImport(true)}>
            <Upload size={14} />
            批量导入
          </Button>
        )}
        <PrimaryButton onClick={() => setShowCreate(true)}>新建技能</PrimaryButton>
      </div>

      <DataTable
        className={skillTableClass}
        headers={[
          ...(!isTenant ? [
            <span className="grid w-8 min-w-8 place-items-center">
              <SelectionCheckbox
                checked={allPageSelected}
                mixed={selectedOnPage > 0 && !allPageSelected}
                disabled={selectablePageItems.length === 0}
                label="选择当前页技能"
                onChange={setPageSelected}
              />
            </span>,
          ] : []),
          <span className="block w-[170px] min-w-[170px] max-w-[190px]">名称</span>,
          <span className="block min-w-[160px]">标识 Code</span>,
          <span className="block min-w-[110px]">类型</span>,
          <span className="block min-w-[72px]">状态</span>,
          ...(!isTenant ? [
            <span className="block min-w-[88px]">官网展示</span>,
            <span className="block min-w-[96px]">计费类型</span>,
            <span className="block min-w-[96px]">定价模式</span>,
            <span className="block min-w-[96px]">默认价</span>,
            <span className="block min-w-[72px]">接口数</span>,
          ] : []),
          <span className="block min-w-[110px]">分类</span>,
          <span className="block min-w-[110px]">可见范围</span>,
          <span className="block min-w-[72px]">装配数</span>,
          <span className="block min-w-[140px]">更新时间</span>,
          <span className="block min-w-[88px]">操作</span>,
        ]}
        loading={loading ? <EmptyState title="正在加载技能" description="正在读取平台技能列表。" /> : undefined}
        empty={!loading && !err && items.length === 0 ? (
          <EmptyState
            icon={<Wand size={22} />}
            title={hasFilter ? '没有匹配的技能' : (isTenant ? '本企业暂无自建技能' : '暂无平台技能')}
            description={hasFilter
              ? '调整搜索词、类型、状态或分类筛选后再试。'
              : (isTenant
                ? '点右上「新建技能」开始创建本企业专属的 Agent 技能。'
                : '创建技能后，租户管理员可以治理和装配到数字员工。')}
            action={hasFilter ? <Button variant="secondary" onClick={clearFilter}>清空筛选</Button> : undefined}
          />
        ) : undefined}
      >
        {!loading && items.map((skill) => {
          const category = skill.category_id ? categoryMap.get(skill.category_id) : undefined
          return (
            <tr key={skill.uuid} className="transition hover:bg-[var(--color-bg-sub)]">
              {!isTenant && (
                <td className="w-12 min-w-12 px-4 py-2 text-center">
                  <SelectionCheckbox
                    checked={selectedUUIDs.has(skill.uuid)}
                    label={`选择 ${skill.name}`}
                    onChange={(checked) => setRowSelected(skill, checked)}
                  />
                </td>
              )}
              <td className={skillNameCellClass} title={skill.name || '-'}>
                <button
                  type="button"
                  className="flex min-w-0 items-center gap-2 text-left"
                  onClick={() => setActiveUUID(skill.uuid)}
                >
                  <SkillListIcon skill={skill} />
                  <span className="min-w-0 truncate font-medium text-[var(--color-text)]">
                    {skill.name || '-'}
                  </span>
                </button>
              </td>
              <td className={skillCodeCellClass} title={skill.code}>{skill.code}</td>
              <td className={skillTextCellClass}>{KIND_LABEL[skill.kind] || skill.kind}</td>
              <td className={skillStatusCellClass}>
                <InlineSwitch
                  checked={isSkillEnabled(skill.status)}
                  disabled={statusBusyUUID === skill.uuid}
                  title={isSkillEnabled(skill.status) ? '点击禁用技能' : '点击启用技能'}
                  onChange={(next) => setSkillEnabled(skill, next)}
                />
              </td>
              {!isTenant && (
                <>
                  <td className={skillStatusCellClass}>
                    <InlineSwitch
                      checked={skill.marketing_visible !== false}
                      disabled={marketingBusyUUID === skill.uuid}
                      title={skill.marketing_visible !== false ? '点击后从官网技能商店隐藏' : '点击后展示在官网技能商店'}
                      onChange={(next) => setSkillMarketingVisible(skill, next)}
                    />
                  </td>
                  <td className={skillPriceCellClass}>{billingTypeLabel(skill.billing_type)}</td>
                  <td className={skillPriceCellClass}>{pricingModeLabel(skill.pricing_mode)}</td>
                  <td className={skillPriceCellClass}>{skill.billing_type === 'paid' && skill.default_credits != null ? `${skill.default_credits} 积分/次` : '-'}</td>
                  <td className={skillNumberCellClass}>{skill.operation_count ?? 0}</td>
                </>
              )}
              <td className={skillTextCellClass}>{category?.name || '-'}</td>
              <td className={skillTextCellClass}>{VISIBILITY_LABEL[skill.visibility] || skill.visibility}</td>
              <td className={skillNumberCellClass}>{skill.install_count ?? 0}</td>
              <td className={skillTimeCellClass}>{fmtDateTime(skill.updated_at)}</td>
              <td className={skillActionCellClass}>
                <RowActions
                  onEdit={() => setActiveUUID(skill.uuid)}
                  onDelete={() => setDeleting(skill)}
                  extras={!isTenant ? (
                    <button
                      type="button"
                      onClick={() => setPricingSkill(skill)}
                      title="计费设置"
                      className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-brand)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]"
                    >
                      计费
                    </button>
                  ) : undefined}
                />
              </td>
            </tr>
          )
        })}
      </DataTable>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={(next) => {
          setLoading(true)
          setPage(next)
        }}
        onPageSizeChange={(next) => {
          setLoading(true)
          setPageSize(next)
          setPage(1)
        }}
      />

      {active && (
        <SkillDrawer
          skill={active}
          categories={categories}
          labels={labels}
          onClose={() => setActiveUUID('')}
          onChanged={refresh}
          onDelete={() => setDeleting(active)}
        />
      )}

      {pricingSkill && (
        <SkillPriceDrawer
          skill={pricingSkill}
          onClose={() => setPricingSkill(null)}
          onDone={() => { setPricingSkill(null); refresh() }}
        />
      )}

      {showCreate && (
        <CreateModal
          onClose={() => setShowCreate(false)}
          onCreated={() => { setShowCreate(false); refresh() }}
          onErr={setErr}
        />
      )}

      {showBundleImport && (
        <SkillBundleImportDialog
          onClose={() => setShowBundleImport(false)}
          onImported={() => {
            setSelectedUUIDs(new Set())
            setSelectedUnpublishedUUIDs(new Set())
            refresh()
          }}
        />
      )}

      {showBatchDelete && selectedUUIDs.size > 0 && (
        <ConfirmDialog
          title="批量删除技能"
          description={`确认删除已选的 ${selectedUUIDs.size} 个平台技能？删除后将从技能管理列表移除；已有装配关系、版本历史、技能包、Icon 和示例图仍保留，但当前页面暂不支持恢复。`}
          confirmLabel={`删除 ${selectedUUIDs.size} 个技能`}
          busyLabel="批量删除中..."
          onClose={() => setShowBatchDelete(false)}
          onConfirm={async () => {
            const uuids = Array.from(selectedUUIDs)
            await PlatformSkills.batchDelete(uuids)
            if (activeUUID && selectedUUIDs.has(activeUUID)) setActiveUUID('')
            setSelectedUUIDs(new Set())
            setSelectedUnpublishedUUIDs(new Set())
            setShowBatchDelete(false)
            refresh()
          }}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title="删除技能"
          description={`确认删除「${deleting.name || deleting.code}」？删除后会从列表移除，不影响启用/禁用状态字段。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await api.delete(deleting.uuid)
            if (activeUUID === deleting.uuid) setActiveUUID('')
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function SkillBundleImportDialog({ onClose, onImported }: { onClose: () => void; onImported: () => void }) {
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [result, setResult] = useState<SkillBundleImportResult | null>(null)

  const submit = async () => {
    if (!file || busy) return
    if (file.size > 200 * 1024 * 1024) {
      setErr('bundle 不能超过 200MB')
      return
    }
    setBusy(true)
    setErr('')
    try {
      const imported = await PlatformSkills.importBundle(file)
      setResult(imported)
      onImported()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title="批量导入技能"
      subtitle="上传从测试环境导出的 skill bundle。系统会先完整校验，成功项将自动发布并启用。"
      icon={<FileArchive size={18} />}
      onClose={onClose}
      size="lg"
      footer={(
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>{result ? '关闭' : '取消'}</Button>
          {!result && (
            <Button onClick={submit} disabled={!file || busy}>
              <Upload size={14} />
              {busy ? '导入并启用中...' : '导入并启用'}
            </Button>
          )}
        </div>
      )}
    >
      {!result ? (
        <div className="space-y-4">
          <FormField label="技能 Bundle" hint="支持 .skillbundle.zip / .zip，最多 20 个技能，文件最大 200MB。">
            <FileUploadPicker
              title="点击或拖拽上传技能 Bundle"
              description="支持 .skillbundle.zip / .zip，最多 20 个技能，文件最大 200MB。"
              accept=".skillbundle.zip,.zip,application/zip"
              file={file}
              busy={busy}
              busyLabel="正在导入、发布并启用..."
              onSelect={(nextFile) => {
                setFile(nextFile)
                setErr('')
              }}
              onClear={() => {
                setFile(null)
                setErr('')
              }}
            />
          </FormField>
          <div className="rounded-md bg-[var(--color-line-soft)] px-4 py-3 text-[12px] leading-5 text-[var(--color-text-sub)]">
            匹配规则：按平台技能 Code 定位；同版本同摘要会补齐发布和启用，同版本不同摘要会标记冲突。分类和标签按 Code 映射，生产环境的租户绑定、偏好和安装量不会被修改。
          </div>
          {err && <InlineAlert>{err}</InlineAlert>}
        </div>
      ) : (
        <div className="space-y-4">
          <div className="grid grid-cols-5 gap-2">
            {[
              ['新增', result.created], ['更新', result.updated], ['跳过', result.skipped],
              ['冲突', result.conflict], ['失败', result.failed],
            ].map(([label, value]) => (
              <div key={String(label)} className="rounded-md border border-[var(--color-line)] px-3 py-2 text-center">
                <div className="text-[18px] font-semibold text-[var(--color-text)]">{value}</div>
                <div className="text-[11px] text-[var(--color-text-sub)]">{label}</div>
              </div>
            ))}
          </div>
          <div className="max-h-[360px] overflow-auto rounded-md border border-[var(--color-line)]">
            {result.items.map((item) => (
              <div key={`${item.code}-${item.version}`} className="grid grid-cols-[minmax(0,1fr)_90px_72px] gap-3 border-b border-[var(--color-line-soft)] px-4 py-3 text-[12px] last:border-b-0">
                <div className="min-w-0">
                  <div className="truncate font-medium text-[var(--color-text)]">{item.code}</div>
                  {item.message && <div className="mt-1 text-[var(--color-text-sub)]">{item.message}</div>}
                </div>
                <div className="font-mono text-[var(--color-text-sub)]">{item.version}</div>
                <div className={item.status === 'conflict' || item.status === 'failed' ? 'text-[var(--color-danger)]' : 'text-[var(--color-text-sub)]'}>{bundleStatusLabel(item.status)}</div>
              </div>
            ))}
          </div>
          <InlineAlert tone={result.failed > 0 || result.conflict > 0 ? 'warn' : 'success'}>
            {result.failed > 0 || result.conflict > 0
              ? '成功项已自动发布并启用；请根据逐项结果处理冲突或失败项。'
              : '导入完成，全部技能已自动发布并启用，可以直接使用。'}
          </InlineAlert>
        </div>
      )}
    </DialogShell>
  )
}

function bundleStatusLabel(status: string) {
  return ({ created: '新增', updated: '更新', skipped: '跳过', conflict: '冲突', failed: '失败' } as Record<string, string>)[status] || status
}

function SkillListIcon({ skill }: { skill: Skill }) {
  const [failed, setFailed] = useState(false)
  const iconURL = skill.icon_url || ''
  const showImage = !!iconURL && !failed

  return (
    <span className="grid h-7 w-7 shrink-0 place-items-center overflow-hidden rounded-md bg-[var(--color-line-soft)] text-[var(--color-text-sub)] ring-1 ring-[var(--color-line)]">
      {showImage ? (
        <img
          src={iconURL}
          alt=""
          className="h-full w-full object-cover"
          loading="lazy"
          onError={() => setFailed(true)}
        />
      ) : skill.kind === 'builtin' ? (
        <Box size={15} />
      ) : (
        <FileArchive size={15} />
      )}
    </span>
  )
}

function SkillDrawer({
  skill,
  categories,
  labels,
  onClose,
  onChanged,
  onDelete,
}: {
  skill: Skill
  categories: SkillCategory[]
  labels: SkillLabel[]
  onClose: () => void
  onChanged: () => void
  onDelete: () => void
}) {
  const [footer, setFooter] = useState<ReactNode>(null)
  // 抽屉内部的错误显示在抽屉顶部 banner，不再冒泡到页面（页面 banner 会被抽屉遮住）。
  // 列表加载失败等抽屉外操作不会到这里，仍走页面级 setErr。
  const [drawerErr, setDrawerErr] = useState('')
  const handleSaved = useCallback(() => {
    onChanged()
    onClose()
  }, [onChanged, onClose])

  return (
    <DrawerShell
      title="编辑技能"
      subtitle={`${skill.name || skill.code} · ${KIND_LABEL[skill.kind] || skill.kind} · ${VISIBILITY_LABEL[skill.visibility] || skill.visibility}`}
      width="lg"
      variant="polished"
      onClose={onClose}
      footer={footer}
    >
      <div className="space-y-4">
        {drawerErr && (
          <InlineAlert>
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="font-medium">操作失败</div>
                <div className="mt-1 text-[12px]">{drawerErr}</div>
              </div>
              <Button size="sm" variant="ghost" onClick={() => setDrawerErr('')}>
                关闭
              </Button>
            </div>
          </InlineAlert>
        )}
        <SkillDetail
          skill={skill}
          categories={categories}
          labels={labels}
          onClose={onClose}
          // 保存成功后既刷新列表也关闭抽屉, 让操作有明确的结束反馈。
          onSaved={handleSaved}
          onErr={setDrawerErr}
          onDelete={onDelete}
          onFooterChange={setFooter}
        />
        <VersionPanel skill={skill} onChanged={onChanged} onErr={setDrawerErr} />
      </div>
    </DrawerShell>
  )
}

const OPERATION_CODE_RE = /^[a-z][a-z0-9_]{2,63}$/
const OPERATION_IMPORT_EXAMPLE = '[{"operation_code":"search","operation_name":"搜索","description":"按关键词搜索","sort_order":10}]'

type OperationDraftRow = {
  key: string
  operation_code: string
  operation_name: string
  description: string
  operation_status: string
  price: string
  useDefault: boolean
  isNew?: boolean
  isDeleted?: boolean
}

function operationRowFromPrice(row: BillingSkillOperationPrice, operation?: BillingSkillOperation): OperationDraftRow {
  return {
    key: row.operation_code,
    operation_code: row.operation_code,
    operation_name: operation?.operation_name || row.operation_name || '',
    description: operation?.description || '',
    operation_status: operation?.status || row.operation_status || 'active',
    price: row.credits_per_call == null ? '' : String(row.credits_per_call),
    useDefault: !row.is_overridden,
  }
}

function SkillPriceDrawer({ skill, onClose, onDone }: { skill: Skill; onClose: () => void; onDone: () => void }) {
  const initialSkillID = Number(skill.id) > 0 ? Number(skill.id) : 0
  const [resolvedSkillID, setResolvedSkillID] = useState(initialSkillID)
  const [billingType, setBillingType] = useState(skill.billing_type || 'free')
  const [pricingMode, setPricingMode] = useState(skill.pricing_mode || 'per_skill')
  const [price, setPrice] = useState(skill.default_credits == null ? '' : String(skill.default_credits))
  const [opRows, setOpRows] = useState<OperationDraftRow[]>([])
  const [opLoading, setOpLoading] = useState(false)
  const [importDialogOpen, setImportDialogOpen] = useState(false)
  const [importText, setImportText] = useState('')
  const [deleteRow, setDeleteRow] = useState<OperationDraftRow | null>(null)
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const resolveSkillID = useCallback(async () => {
    if (resolvedSkillID > 0) return resolvedSkillID

    const res = await BillingAPI.listSkillPrices({ q: skill.name || skill.uuid, limit: 50, offset: 0 })
    const items = res.items || []
    const matched = items.find((item) => item.skill_uuid === skill.uuid)
      || items.find((item) => item.skill_name === skill.name)
      || (items.length === 1 ? items[0] : undefined)

    if (!matched?.skill_id) {
      throw new Error('无法定位技能计费 ID，请刷新技能列表后重试')
    }
    setResolvedSkillID(matched.skill_id)
    return matched.skill_id
  }, [resolvedSkillID, skill.name, skill.uuid])

  const loadOperationPrices = useCallback(async () => {
    setOpLoading(true)
    setErr('')
    try {
      const skillID = await resolveSkillID()
      const priceRes = await BillingAPI.listSkillOperationPrices(skillID)
      const operations: BillingSkillOperation[] = []
      let offset = 0
      let total = 0
      do {
        const res = await BillingAPI.listSkillOperations(skillID, { status: 'active', limit: 200, offset })
        const items = res.items || []
        operations.push(...items)
        total = res.total || operations.length
        offset += items.length
        if (items.length === 0) break
      } while (operations.length < total)
      const operationMap = new Map(operations.map((item) => [item.operation_code, item]))
      setOpRows((priceRes.items || []).map((row) => operationRowFromPrice(row, operationMap.get(row.operation_code))))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setOpLoading(false)
    }
  }, [resolveSkillID])

  const importSummary = useMemo(() => {
    const text = importText.trim()
    if (!text) return '支持 JSON 数组或单个对象；少量接口建议直接逐行新增。'
    try {
      const raw = JSON.parse(text)
      const count = Array.isArray(raw) ? raw.length : 1
      return `解析到 ${count} 个接口，导入后会先追加或更新到表格。`
    } catch {
      return 'JSON 格式暂未通过，请检查括号、逗号和字段名。'
    }
  }, [importText])

  useEffect(() => {
    if (billingType !== 'paid' || pricingMode !== 'per_operation') return
    const timer = window.setTimeout(() => {
      void loadOperationPrices()
    }, 0)
    return () => window.clearTimeout(timer)
  }, [billingType, loadOperationPrices, pricingMode])

  const submit = async () => {
    if (billingType === 'paid' && price.trim() === '') {
      setErr('付费技能需要设置默认价')
      return
    }
    if (billingType === 'paid' && price.trim() !== '' && Number(price) < 0) {
      setErr('默认价不能为负')
      return
    }
    const visibleOpRows = opRows.filter((row) => !row.isDeleted)
    if (billingType === 'paid' && pricingMode === 'per_operation' && visibleOpRows.length === 0) {
      setErr('按接口定价需要先加至少一个接口')
      return
    }
    if (billingType === 'paid' && pricingMode === 'per_operation') {
      const seen = new Set<string>()
      for (let idx = 0; idx < visibleOpRows.length; idx += 1) {
        const row = visibleOpRows[idx]
        const rowNo = idx + 1
        const code = row.operation_code.trim()
        const name = row.operation_name.trim()
        if (!code) {
          setErr(`第 ${rowNo} 行接口编码不能为空`)
          return
        }
        if (!OPERATION_CODE_RE.test(code)) {
          setErr(`第 ${rowNo} 行接口编码需为 3-64 位，小写字母开头，仅允许小写字母、数字和下划线`)
          return
        }
        if (seen.has(code)) {
          setErr(`第 ${rowNo} 行接口编码重复：${code}`)
          return
        }
        seen.add(code)
        if (!name) {
          setErr(`第 ${rowNo} 行接口名称不能为空`)
          return
        }
        if (!row.useDefault) {
          const rowPrice = row.price.trim()
          if (rowPrice === '') {
            setErr(`第 ${rowNo} 行单独价不能为空；如需使用默认价，请清空积分`)
            return
          }
          if (!Number.isInteger(Number(rowPrice)) || Number(rowPrice) < 0) {
            setErr(`第 ${rowNo} 行单独价必须是非负整数`)
            return
          }
        }
      }
    }
    setBusy(true)
    setErr('')
    try {
      const skillID = await resolveSkillID()
      await BillingAPI.saveSkillPricingConfig(skillID, {
        billing_type: billingType,
        pricing_mode: pricingMode,
        default_credits_per_call: billingType === 'paid' ? Number(price) : null,
        operations: pricingMode === 'per_operation'
          ? visibleOpRows.map((row, idx) => ({
            operation_code: row.operation_code.trim(),
            operation_name: row.operation_name.trim(),
            description: row.description.trim(),
            sort_order: idx * 10,
            credits_per_call: row.useDefault ? null : Number(row.price.trim()),
          }))
          : [],
        deleted_operation_codes: opRows
          .filter((row) => row.isDeleted && !row.isNew)
          .map((row) => row.operation_code.trim()),
      })
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const parseImportText = (): BillingSkillOperationImport[] => {
    let raw: unknown
    try {
      raw = JSON.parse(importText)
    } catch {
      throw new Error('接口导入内容必须是合法 JSON')
    }
    const arr = Array.isArray(raw) ? raw : [raw]
    return arr.map((item, idx) => {
      const row = item as Record<string, unknown>
      const operationCode = String(row.operation_code ?? row.code ?? '').trim()
      const operationName = String(row.operation_name ?? row.name ?? '').trim()
      if (!operationCode) throw new Error(`第 ${idx + 1} 行缺少 operation_code 或 code`)
      if (!OPERATION_CODE_RE.test(operationCode)) throw new Error(`第 ${idx + 1} 行 operation_code 格式不正确`)
      if (!operationName) throw new Error(`第 ${idx + 1} 行缺少 operation_name 或 name`)
      return {
        operation_code: operationCode,
        operation_name: operationName,
        description: typeof row.description === 'string' ? row.description : (typeof row.desc === 'string' ? row.desc : ''),
        input_schema: row.input_schema,
        output_schema: row.output_schema,
        sort_order: Number(row.sort_order ?? idx * 10),
      }
    })
  }

  const mergeOperationRows = (operations: BillingSkillOperationImport[]) => {
    setOpRows((prev) => {
      const next = [...prev]
      operations.forEach((op) => {
        const code = op.operation_code.trim()
        const index = next.findIndex((row) => row.operation_code.trim() === code)
        if (index >= 0) {
          next[index] = {
            ...next[index],
            operation_name: op.operation_name,
            description: typeof op.description === 'string' ? op.description : next[index].description,
          }
          return
        }
        next.push({
          key: `new-${Date.now()}-${code}-${next.length}`,
          operation_code: code,
          operation_name: op.operation_name,
          description: typeof op.description === 'string' ? op.description : '',
          operation_status: 'active',
          price: price || '',
          useDefault: true,
          isNew: true,
        })
      })
      return next
    })
  }

  const importOperations = () => {
    setErr('')
    if (!importText.trim()) {
      setErr('请先填写接口 JSON')
      return false
    }
    try {
      const operations = parseImportText()
      mergeOperationRows(operations)
      setImportText('')
      return true
    } catch (e) {
      setErr((e as Error).message)
      return false
    }
  }

  const addOperationRow = () => {
    setOpRows((prev) => ([
      ...prev,
      {
        key: `new-${Date.now()}-${prev.length}`,
        operation_code: '',
        operation_name: '',
        description: '',
        operation_status: 'active',
        price: price || '',
        useDefault: true,
        isNew: true,
      },
    ]))
  }

  const updateOperationRow = (key: string, patch: Partial<OperationDraftRow>) => {
    setOpRows((prev) => prev.map((row) => (row.key === key ? { ...row, ...patch } : row)))
  }

  const removeOperationRow = (key: string) => {
    setOpRows((prev) => prev.filter((row) => row.key !== key || !row.isNew))
  }

  const confirmDeleteOperationRow = (row: OperationDraftRow) => {
    if (row.isNew) {
      removeOperationRow(row.key)
      return
    }
    setOpRows((prev) => prev.map((item) => (item.key === row.key ? { ...item, isDeleted: true } : item)))
  }

  const visibleOpRows = opRows.filter((row) => !row.isDeleted)

  return (
    <DrawerShell
      title={`计费设置 - ${skill.name}`}
      subtitle="免费技能不扣积分；付费技能可按技能统一价或按接口单独定价。"
      onClose={onClose}
      width="lg"
      variant="polished"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <SkillDrawerSection title="技能级定价" description="默认价既是按技能模式的统一价，也是按接口模式下未单独配置接口价格时使用的价格。">
          <div className="grid grid-cols-2 gap-3">
            <FormField label="技能">
              <Input value={`${skill.name} (${skill.code})`} disabled />
            </FormField>
            <FormField label="UUID">
              <Input value={skill.uuid} disabled />
            </FormField>
            <SelectField label="计费类型" value={billingType} onChange={(v) => setBillingType(v === 'paid' ? 'paid' : 'free')}>
              <option value="free">免费</option>
              <option value="paid">付费</option>
            </SelectField>
            <SelectField label="定价模式" value={pricingMode} onChange={(v) => setPricingMode(v === 'per_operation' ? 'per_operation' : 'per_skill')}>
              <option value="per_skill">按技能（统一价）</option>
              <option value="per_operation">按接口（分接口定价）</option>
            </SelectField>
            {billingType === 'paid' && (
              <FormField
                label="默认价（积分/次）"
                hint={pricingMode === 'per_operation' ? '未单独设置价格的接口会使用这个默认价。' : undefined}
              >
                <Input value={price} inputMode="numeric" onChange={(e) => setPrice(e.target.value.replace(/[^\d]/g, ''))} />
              </FormField>
            )}
          </div>
          {billingType === 'free' && (
            <div className="mt-3">
              <InlineAlert tone="info">免费技能不会扣减用户积分，因此不需要维护默认价或接口价。</InlineAlert>
            </div>
          )}
        </SkillDrawerSection>

        {billingType === 'paid' && pricingMode === 'per_operation' && (
          <SkillDrawerSection
            title="接口价格"
            description="逐行编辑接口定义和价格；接口很多时可用 JSON 批量追加。"
          >
            <div className="space-y-4">
              <div className="flex items-center justify-between gap-3">
                <div className="text-[13px] text-[var(--color-text-sub)]">未设置单独价的接口使用默认价；所有改动在底部点保存后一起生效。</div>
                <div className="flex items-center gap-2">
                  <Button size="sm" variant="secondary" onClick={() => setImportDialogOpen(true)} disabled={busy}>
                    <Upload size={14} /> 导入 JSON
                  </Button>
                  <Button size="sm" variant="secondary" onClick={loadOperationPrices} disabled={opLoading}>
                    <RefreshCw size={14} /> 刷新
                  </Button>
                </div>
              </div>
              <DataTable
                headers={['接口编码', '接口名称', '描述', '状态', '积分/次', '操作']}
                loading={opLoading ? <EmptyState title="正在加载接口" description="正在读取接口价格列表。" className="min-h-[160px]" /> : null}
                empty={!opLoading && visibleOpRows.length === 0 ? <EmptyState title="暂无接口" description="点击“加一行”，或通过 JSON 快速导入。" className="min-h-[180px]" /> : null}
                stickyLastCol
              >
                {visibleOpRows.map((row) => (
                  <tr key={row.key} className="group hover:bg-[var(--color-bg-sub)]">
                    <td className="min-w-[180px] px-4 py-2">
                      <Input
                        value={row.operation_code}
                        onChange={(e) => updateOperationRow(row.key, { operation_code: e.target.value.trim() })}
                        placeholder="search"
                        disabled={!row.isNew}
                      />
                    </td>
                    <td className="min-w-[160px] px-4 py-2">
                      <Input
                        value={row.operation_name}
                        onChange={(e) => updateOperationRow(row.key, { operation_name: e.target.value })}
                        placeholder="搜索"
                      />
                    </td>
                    <td className="min-w-[220px] px-4 py-2">
                      <textarea
                        className={compactTextareaClass}
                        value={row.description}
                        onChange={(e) => updateOperationRow(row.key, { description: e.target.value })}
                        placeholder="可选"
                        rows={2}
                      />
                    </td>
                    <td className="whitespace-nowrap px-4 py-2 text-[12px] text-[var(--color-text-sub)]">{row.operation_status === 'active' ? '启用' : '停用'}</td>
                    <td className="min-w-[120px] px-4 py-2">
                      <Input
                        value={row.useDefault ? '' : row.price}
                        inputMode="numeric"
                        placeholder={price || '默认价'}
                        onChange={(e) => {
                          const nextPrice = e.target.value.replace(/[^\d]/g, '')
                          updateOperationRow(row.key, { price: nextPrice, useDefault: nextPrice === '' })
                        }}
                        disabled={row.operation_status !== 'active'}
                      />
                    </td>
                    <td className="sticky right-0 z-[5] whitespace-nowrap bg-white px-4 py-2 shadow-[inset_1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]">
                      <div className="flex items-center gap-1">
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-[var(--color-danger)] hover:text-[var(--color-danger)]"
                          onClick={() => setDeleteRow(row)}
                          title="删除接口"
                        >
                          删除
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </DataTable>
              <div className="flex justify-end">
                <Button size="sm" variant="secondary" onClick={addOperationRow} disabled={busy}>
                  <Plus size={14} /> 加一行
                </Button>
              </div>
            </div>
          </SkillDrawerSection>
        )}

        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
      {importDialogOpen && (
        <DialogShell
          title="导入接口 JSON"
          subtitle="粘贴 JSON 数组或单个对象；导入后先追加到表格，底部保存后生效。"
          onClose={() => setImportDialogOpen(false)}
          size="lg"
          footer={(
            <div className="flex items-center justify-end gap-2">
              <Button variant="secondary" onClick={() => setImportDialogOpen(false)}>取消</Button>
              <Button variant="secondary" onClick={() => setImportText(OPERATION_IMPORT_EXAMPLE)} disabled={busy}>填入示例</Button>
              <Button
                onClick={() => {
                  if (importOperations()) setImportDialogOpen(false)
                }}
                disabled={busy || !importText.trim()}
              >
                导入到表格
              </Button>
            </div>
          )}
        >
          <FormField label="JSON 内容" hint="字段支持 operation_code/operation_name，也兼容 code/name。">
            <textarea
              className={textareaClass}
              value={importText}
              onChange={(e) => setImportText(e.target.value)}
              placeholder={OPERATION_IMPORT_EXAMPLE}
              rows={8}
            />
          </FormField>
          <div className="mt-2 text-[12px] text-[var(--color-text-sub)]">{importSummary}</div>
        </DialogShell>
      )}
      {deleteRow && (
        <ConfirmDialog
          title="删除接口"
          description={`确认删除接口「${deleteRow.operation_name || deleteRow.operation_code}」？删除后需点击底部保存才会生效。`}
          confirmLabel="删除"
          onClose={() => setDeleteRow(null)}
          onConfirm={() => {
            confirmDeleteOperationRow(deleteRow)
            setDeleteRow(null)
          }}
        />
      )}
    </DrawerShell>
  )
}

function SkillDrawerSection({
  title,
  description,
  actions,
  children,
  className,
  defaultOpen = true,
}: {
  title: string
  description?: string
  actions?: ReactNode
  children: ReactNode
  className?: string
  defaultOpen?: boolean
}) {
  const [open, setOpen] = useState(defaultOpen)

  return (
    <section className={`overflow-hidden rounded-lg border border-[var(--color-line)] bg-white shadow-[rgba(15,23,42,0.04)_0px_8px_24px] ${className || ''}`}>
      <div className="flex items-start justify-between gap-4 border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] px-4 py-3">
        <button
          type="button"
          className="min-w-0 flex-1 text-left"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
        >
          <div className="flex items-center gap-2">
            <span className="h-5 w-1 rounded-full bg-[var(--color-brand)]" />
            <h3 className="truncate text-[15px] font-semibold text-[var(--color-text)]">{title}</h3>
          </div>
          {description && (
            <p className="mt-2 text-[12.5px] leading-relaxed text-[var(--color-text-sub)]">{description}</p>
          )}
        </button>
        <div className="flex shrink-0 items-center gap-3">
          {actions && <div onClick={(e) => e.stopPropagation()}>{actions}</div>}
          <button
            type="button"
            className="grid h-8 w-8 place-items-center rounded-md text-[var(--color-text-mute)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
            onClick={() => setOpen((v) => !v)}
            title={open ? '收起' : '展开'}
            aria-label={open ? `收起${title}` : `展开${title}`}
          >
            {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
          </button>
        </div>
      </div>
      {open && (
        <div className="p-4">
          {children}
        </div>
      )}
    </section>
  )
}

function SectionSwitchAction({
  label,
  checked,
  onChange,
  disabled,
  title,
  checkedText,
  uncheckedText,
}: {
  label: string
  checked: boolean
  onChange: (checked: boolean) => void
  disabled?: boolean
  title: string
  checkedText: string
  uncheckedText: string
}) {
  return (
    <div className="flex items-center gap-2 text-[13px] text-[var(--color-text-sub)]">
      <span>{label}</span>
      <InlineSwitch
        checked={checked}
        onChange={onChange}
        disabled={disabled}
        title={title}
      />
      <span className="min-w-[42px] text-[var(--color-text)]">{checked ? checkedText : uncheckedText}</span>
    </div>
  )
}

type ExampleImageDraft = {
  storageUri: string
  previewUrl: string
  fileName: string
}

function normalizeExampleImages(items?: Skill['usage_example_images']): ExampleImageDraft[] {
  if (!Array.isArray(items)) return []
  return items
    .map((item) => {
      const storageUri = item.storage_uri || item.url || ''
      return {
        storageUri,
        previewUrl: item.url || storageUri,
        fileName: item.file_name || '',
      }
    })
    .filter((item) => item.storageUri)
}

function serializeExampleImages(items: ExampleImageDraft[]) {
  return items
    .filter((item) => item.storageUri)
    .slice(0, 6)
    .map((item) => ({
      storage_uri: item.storageUri,
      file_name: item.fileName || undefined,
    }))
}

function SkillDetail({
  skill,
  categories,
  labels,
  onClose,
  onSaved,
  onErr,
  onDelete,
  onFooterChange,
}: {
  skill: Skill
  categories: SkillCategory[]
  labels: SkillLabel[]
  onClose: () => void
  onSaved: () => void
  onErr: (m: string) => void
  onDelete: () => void
  onFooterChange: (footer: ReactNode) => void
}) {
  const api = useSkillAPI()
  const isTenant = useSkillScope() === 'tenant'
  const [name, setName] = useState(skill.name)
  const [description, setDescription] = useState(skill.description || '')
  const [usageExample, setUsageExample] = useState(skill.usage_example || '')
  const [exampleImages, setExampleImages] = useState<ExampleImageDraft[]>(() => normalizeExampleImages(skill.usage_example_images))
  // 编辑态：iconURL 存原始 oss:// key（仅在用户重新上传后有值）；
  // iconPreview 是后端返回的现签 URL，保留用于展示，避免把 signed URL 写回 DB。
  const [iconURL, setIconURL] = useState('')
  const [iconPreview, setIconPreview] = useState(skill.icon_url || '')
  const [iconChanged, setIconChanged] = useState(false)
  const [executionMode, setExecutionMode] = useState<'synchronous_inline' | 'asynchronous_floating'>(
    (skill.execution_mode as 'synchronous_inline' | 'asynchronous_floating') || 'synchronous_inline',
  )
  const [visibility, setVisibility] = useState<'platform' | 'tenant'>(
    (skill.visibility === 'platform' || skill.visibility === 'tenant') ? skill.visibility : 'platform',
  )
  const [source, setSource] = useState<'internal' | 'open_source' | 'third_party'>(
    (skill.source as 'internal' | 'open_source' | 'third_party') || 'internal',
  )
  const [categoryID, setCategoryID] = useState<number | undefined>(skill.category_id)
  const [labelIDs, setLabelIDs] = useState<number[]>(skill.label_ids || [])
  const [chips, setChips] = useState<ChipDraft[]>(() =>
    skill.kind === 'builtin' ? deserializeChips(skill.input_chips_schema || []) : [],
  )
  const [defaultAttached, setDefaultAttached] = useState(skill.default_attached)
  const [defaultPinned, setDefaultPinned] = useState(skill.default_pinned)
  const [marketingVisible, setMarketingVisible] = useState(skill.marketing_visible !== false)
  const [sortOrder, setSortOrder] = useState(skill.sort_order)
  const [enabled, setEnabled] = useState(isSkillEnabled(skill.status))
  const [busy, setBusy] = useState(false)

  const save = useCallback(async () => {
    setBusy(true)
    try {
      const body: Parameters<typeof PlatformSkills.patch>[1] = {
        name,
        description,
        usage_example: usageExample,
        usage_example_images: serializeExampleImages(exampleImages),
        execution_mode: skill.kind === 'builtin' ? executionMode : undefined,
        visibility,
        source,
        category_id: categoryID,
        label_ids: labelIDs,
        default_attached: defaultAttached,
        default_pinned: defaultPinned,
        marketing_visible: isTenant ? undefined : marketingVisible,
        sort_order: sortOrder,
        status: skillStatusFromEnabled(enabled),
      }
      if (iconChanged) {
        body.icon_url = iconURL
      }
      if (skill.kind === 'builtin') {
        body.input_chips_schema = serializeChips(chips)
      }
      await api.patch(skill.uuid, body)
      onSaved()
    } catch (e) {
      onErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }, [
    api,
    name,
    description,
    usageExample,
    exampleImages,
    skill.kind,
    skill.uuid,
    executionMode,
    visibility,
    source,
    categoryID,
    labelIDs,
    defaultAttached,
    defaultPinned,
    marketingVisible,
    isTenant,
    sortOrder,
    enabled,
    iconChanged,
    iconURL,
    chips,
    onSaved,
    onErr,
  ])

  useEffect(() => {
    onFooterChange(
      <div className="flex items-center justify-between gap-3">
        <Button variant="ghost" onClick={onDelete} disabled={busy}>
          <Trash2 size={14} />
          删除
        </Button>
        <div className="flex items-center gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={save} disabled={busy}>
            <Save size={14} />
            {busy ? '保存中...' : '保存'}
          </Button>
        </div>
      </div>,
    )
    return () => onFooterChange(null)
  }, [busy, onClose, onDelete, onFooterChange, save])

  return (
    <div className="space-y-4">
      <SkillDrawerSection
        title="基础信息"
        actions={
          <SectionSwitchAction
            label="状态"
            checked={enabled}
            onChange={setEnabled}
            disabled={busy}
            title={enabled ? '点击禁用技能' : '点击启用技能'}
            checkedText="已启用"
            uncheckedText="已禁用"
          />
        }
      >
        <div className="mb-3">
          <FormField label="技能图标" hint="建议方形 PNG/JPG/WebP，单张 ≤ 1MB；不上传则保留原图标。">
            <IconUploader
              value={iconURL}
              previewUrl={iconPreview}
              onChange={(uri, preview) => {
                setIconURL(uri)
                setIconPreview(preview)
                setIconChanged(true)
              }}
              disabled={busy}
            />
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <FormField label="名称">
            <Input value={name} onChange={(e) => setName(e.target.value)} />
          </FormField>
          <FormField label="技能标识 Code" hint="创建后不可修改。">
            <Input value={skill.code} disabled />
          </FormField>
          {/* 租户场景仅 Agent 技能, 字段固定无需展示。 */}
          {!isTenant && (
            <FormField label="技能类型" hint="创建后不可修改。">
              <Input value={skill.kind === 'agent' ? 'Agent 技能' : '客户端原生技能'} disabled />
            </FormField>
          )}
          {skill.kind === 'builtin' && (
            <SelectField
              label="执行模式"
              value={executionMode}
              onChange={(v) => setExecutionMode(v as 'synchronous_inline' | 'asynchronous_floating')}
            >
              <option value="synchronous_inline">同步内联</option>
              <option value="asynchronous_floating">异步浮层</option>
            </SelectField>
          )}
          <SelectField
            label="来源"
            value={source}
            onChange={(v) => setSource(v as 'internal' | 'open_source' | 'third_party')}
          >
            <option value="internal">自研</option>
            <option value="open_source">开源</option>
            <option value="third_party">第三方</option>
          </SelectField>
          {/* 租户场景可见范围恒为 tenant, 隐藏不展示。 */}
          {!isTenant && (
            <SelectField
              label="可见范围"
              value={visibility}
              onChange={(v) => setVisibility(v as 'platform' | 'tenant')}
            >
              <option value="platform">全平台（所有租户可见）</option>
              <option value="tenant">租户级（仅当前租户）</option>
            </SelectField>
          )}
          <SelectField
            label="技能分类"
            value={categoryID ?? ''}
            onChange={(v) => setCategoryID(v ? Number(v) : undefined)}
          >
            <option value="">未分类</option>
            {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </SelectField>
        </div>
        <div className="mt-3">
          <FormField label="技能标签" hint="多选；支持按标签在技能广场快速筛选。">
            <LabelMultiSelect labels={labels} value={labelIDs} onChange={setLabelIDs} />
          </FormField>
        </div>
        <div className="mt-3">
          <FormField label="描述">
            <textarea
              className="min-h-[96px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
              value={description}
              placeholder="给最终用户看到的技能介绍，建议一句话说明用途"
              onChange={(e) => setDescription(e.target.value)}
            />
          </FormField>
        </div>
        <div className="mt-3">
          <FormField label="使用示例" hint="填写典型输入、操作步骤或预期输出，支持 Markdown。">
            <textarea
              className="min-h-[150px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
              value={usageExample}
              placeholder="例如：用户输入：帮我生成一篇关于无线除螨仪的小红书图文笔记..."
              onChange={(e) => setUsageExample(e.target.value)}
            />
          </FormField>
        </div>
        <div className="mt-3">
          <FormField label="示例图片" hint="支持 PNG/JPG/GIF/WebP，最多 6 张，单张 ≤ 5MB。">
            <ExampleImagesUploader value={exampleImages} onChange={setExampleImages} disabled={busy} />
          </FormField>
        </div>
      </SkillDrawerSection>

      {skill.kind === 'builtin' && skill.builtin_key && (
        <SkillDrawerSection title="客户端能力" description="客户端原生技能绑定的能力 Key（创建后不可修改）。">
          <FormField label="客户端能力 Key">
            <Input value={skill.builtin_key} disabled />
          </FormField>
        </SkillDrawerSection>
      )}

      {/* 参数设置：仅 builtin 显示。Agent 技能的 input_chips 真值源在 skill_versions.input_chips_schema_snapshot，
          编辑入口在下方版本管理里新建/上传版本时弹窗，不在主表上展示。 */}
      {skill.kind === 'builtin' && (
        <SkillDrawerSection
          title="参数设置"
          description="客户端原生技能的输入参数表单。保存后只是更新当前配置；需要在下方「版本管理」创建并发布新版本后，运行时才会读取新的参数快照。"
        >
          <ChipListEditor value={chips} onChange={setChips} />
        </SkillDrawerSection>
      )}

      <SkillDrawerSection
        title="默认装配"
        description="平台级默认行为：新建数字员工时是否自动带上此技能、是否置顶、以及在技能广场的排序权重。"
      >
        <div className="grid grid-cols-2 gap-3">
          <label className="flex items-center gap-2 text-[13px] text-[var(--color-text)]">
            <input type="checkbox" checked={defaultAttached} onChange={(e) => setDefaultAttached(e.target.checked)} />
            <span>默认装配到所有数字员工</span>
          </label>
          <label className="flex items-center gap-2 text-[13px] text-[var(--color-text)]">
            <input type="checkbox" checked={defaultPinned} onChange={(e) => setDefaultPinned(e.target.checked)} />
            <span>默认置顶（仅当默认装配生效）</span>
          </label>
          {!isTenant && (
            <label className="flex items-center gap-2 text-[13px] text-[var(--color-text)]">
              <input type="checkbox" checked={marketingVisible} onChange={(e) => setMarketingVisible(e.target.checked)} />
              <span>展示到官网技能商店</span>
            </label>
          )}
          <FormField label="排序权重" hint="数字越大越靠前；同权重按创建时间倒序。">
            <Input type="number" value={sortOrder} onChange={(e) => setSortOrder(Number(e.target.value))} />
          </FormField>
        </div>
      </SkillDrawerSection>
    </div>
  )
}


function MetaLine({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <span className="text-[var(--color-text-mute)]">{label}：</span>
      <span className="text-[var(--color-text-sub)]">{value}</span>
    </div>
  )
}

function VersionPanel({ skill, onChanged, onErr }: { skill: Skill; onChanged: () => void; onErr: (m: string) => void }) {
  const api = useSkillAPI()
  const [versions, setVersions] = useState<SkillVersion[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [reload, setReload] = useState(0)
  const [expandedUUID, setExpandedUUID] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    api.listVersions(skill.uuid)
      .then((r) => { if (!cancelled) setVersions(r.items || []) })
      .catch((e: Error) => { if (!cancelled) onErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [skill.uuid, reload]) // eslint-disable-line react-hooks/exhaustive-deps

  const refresh = () => {
    setLoading(true)
    setReload((t) => t + 1)
    onChanged()
  }

  // 发布开关只用于"切到线上"或"在多版本之间切换"。
  // 当前线上版本不允许直接取消（取消整个技能上下架请走「上架管理」），所以那种 toggle 在 UI 上会 disabled，
  // 这里只处理"打开"场景，UI 不会传 next=false 进来。
  const setVersionPublished = async (v: SkillVersion, next: boolean) => {
    if (!next) return
    try {
      if (v.status === 'draft') {
        await api.publish(skill.uuid, v.uuid)
      } else if (v.status === 'published' && skill.latest_version_id !== v.id) {
        await api.rollback(skill.uuid, v.uuid)
      }
      refresh()
    } catch (e) {
      onErr((e as Error).message)
    }
  }

  const uploadZip = async (v: SkillVersion, file: File) => {
    try {
      await api.uploadPackage(skill.uuid, v.uuid, file)
      refresh()
    } catch (e) {
      onErr((e as Error).message)
    }
  }

  return (
    <SkillDrawerSection
      title="版本管理"
      description={skill.kind === 'agent'
        ? 'Agent 技能通过 SKILL.md zip 包生成版本快照；发布开关决定当前线上版本，同一技能只能有一个线上版本。'
        : '客户端原生技能版本控制灰度参数；发布开关决定当前线上版本。'}
      actions={<Button size="sm" onClick={() => setShowCreate(true)}><Plus size={14} /> 新版本</Button>}
    >
      {loading ? (
        <EmptyState title="正在加载版本" description="正在读取当前技能版本列表。" className="min-h-[160px]" />
      ) : versions.length === 0 ? (
        <EmptyState
          icon={<FileArchive size={22} />}
          title="暂无版本"
          description="创建首个版本后，可以通过版本卡片上的发布开关上线。"
          action={<Button onClick={() => setShowCreate(true)}><Plus size={14} /> 新版本</Button>}
          className="min-h-[180px]"
        />
      ) : (
        <div className="space-y-2">
          {versions.map((v) => (
            <div key={v.uuid} className="rounded-lg border border-[var(--color-line)] bg-white p-3">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="font-mono text-[13px] font-medium text-[var(--color-text)]">v{v.version}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-[12px] text-[var(--color-text-sub)]">
                    <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] font-medium ${v.id && skill.latest_version_id === v.id ? statusClass('published') : statusClass(v.status === 'archived' ? 'archived' : undefined)}`}>
                      {versionStateLabel(v, skill)}
                    </span>
                    {v.id && skill.latest_version_id === v.id && (
                      <span className="rounded-full bg-[var(--color-brand-bg)] px-2 py-0.5 text-[11px] text-[var(--color-brand)]">
                        当前线上
                      </span>
                    )}
                    {v.grayscale_pct < 100 && (
                      <span className="rounded-full bg-amber-50 px-2 py-0.5 text-[11px] text-amber-700">
                        灰度 {v.grayscale_pct}%（{GRAYSCALE_STRATEGY_LABEL[v.grayscale_strategy] || v.grayscale_strategy}）
                      </span>
                    )}
                  </div>
                  {v.published_at && (
                    <div className="mt-1 text-[11px] text-[var(--color-text-mute)]">published {fmtDateTime(v.published_at)}</div>
                  )}
                </div>
                <div className="flex shrink-0 items-center gap-3">
                  {skill.kind === 'agent' && v.package_url && v.package_url !== 'pending://upload' && (
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => setExpandedUUID(expandedUUID === v.uuid ? null : v.uuid)}
                      title={expandedUUID === v.uuid ? '收起文件列表' : '查看文件列表'}
                    >
                      {expandedUUID === v.uuid ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                    </Button>
                  )}
                  {v.status === 'draft' && skill.kind === 'agent' && (
                    <label className="inline-flex h-8 cursor-pointer items-center justify-center gap-1 rounded-md px-2 text-[13px] text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)]" title="上传 SKILL.md zip 包">
                      <Upload size={14} />
                      <input
                        type="file"
                        accept=".zip,application/zip,application/x-zip-compressed"
                        className="hidden"
                        onChange={(e) => {
                          const f = e.target.files?.[0]
                          if (f) uploadZip(v, f)
                          e.target.value = ''
                        }}
                      />
                    </label>
                  )}
                  {(() => {
                    const isCurrent = !!(v.id && skill.latest_version_id === v.id)
                    const isArchived = v.status === 'archived'
                    const disabled = isCurrent || isArchived
                    const title = isCurrent
                      ? '当前线上版本不能直接取消。如需切换版本，请打开其他版本的「发布」开关；如需整体下架技能，请到「上架管理」里改状态。'
                      : isArchived
                        ? '已归档版本不可发布'
                        : '设为当前线上版本'
                    return (
                      <div className="flex items-center gap-2 text-[12px] text-[var(--color-text-sub)]">
                        <span>发布</span>
                        <InlineSwitch
                          checked={isCurrent}
                          disabled={disabled}
                          title={title}
                          onChange={(next) => setVersionPublished(v, next)}
                        />
                      </div>
                    )
                  })()}
                </div>
              </div>
              {v.changelog && (
                <div className="mt-2 whitespace-pre-wrap rounded-md bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
                  {v.changelog}
                </div>
              )}
              <VersionSnapshotSummary version={v} kind={skill.kind} />
              {expandedUUID === v.uuid && (
                <VersionFileBrowser
                  skillUUID={skill.uuid}
                  versionUUID={v.uuid}
                  onErr={onErr}
                />
              )}
            </div>
          ))}
        </div>
      )}

      {showCreate && (
        <CreateVersionModal
          skill={skill}
          onClose={() => setShowCreate(false)}
          onCreated={() => { setShowCreate(false); refresh() }}
          onErr={onErr}
        />
      )}
    </SkillDrawerSection>
  )
}

function VersionSnapshotSummary({ version, kind }: { version: SkillVersion; kind: Skill['kind'] }) {
  const chips = Array.isArray(version.input_chips_schema_snapshot)
    ? (version.input_chips_schema_snapshot as Record<string, unknown>[])
    : []
  const compat = normalizeCompat(version.agent_compat_snapshot)
  const hasCompat = compat.requiredModels.length > 0 || compat.requiredRuntimes.length > 0 || compat.blockedAgentTags.length > 0

  return (
    <div className="mt-2 space-y-2 rounded-md border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
      <div className="grid grid-cols-1 gap-2 md:grid-cols-2">
        <MetaLine
          label="输入参数快照"
          value={chips.length > 0 ? `${chips.length} 个参数` : '无参数'}
        />
        <MetaLine
          label="灰度"
          value={`${version.grayscale_pct}% · ${GRAYSCALE_STRATEGY_LABEL[version.grayscale_strategy] || version.grayscale_strategy}`}
        />
        {kind === 'agent' && (
          <>
            <MetaLine label="适用 Agent 类型" value={compat.requiredRuntimes.join('、') || '不限制'} />
            <MetaLine label="技能包大小" value={version.package_size_bytes ? fmtFileSize(version.package_size_bytes) : '-'} />
          </>
        )}
        {kind === 'builtin' && (
          <MetaLine label="参数来源" value="客户端原生技能主表快照" />
        )}
        {hasCompat && kind !== 'agent' && (
          <MetaLine label="兼容性快照" value="已配置" />
        )}
      </div>
      {chips.length > 0 && (
        <div className="border-t border-[var(--color-line-soft)] pt-2">
          <div className="mb-1 text-[var(--color-text-mute)]">参数列表</div>
          <ul className="space-y-1">
            {chips.map((c, i) => {
              const key = String((c as { key?: unknown }).key ?? '')
              const label = String((c as { label?: unknown }).label ?? '')
              const kindRaw = String((c as { kind?: unknown }).kind ?? 'text-inline') as ChipKind
              const kindLabel = CHIP_KIND_LABEL[kindRaw] || kindRaw
              const required = Boolean((c as { required?: unknown }).required)
              return (
                <li key={`${key}-${i}`} className="flex flex-wrap items-center gap-1.5 leading-5">
                  <span className="text-[var(--color-text)]">{label || key || `参数 ${i + 1}`}</span>
                  {key && <code className="rounded bg-[var(--color-control-bg)] px-1 text-[11px] text-[var(--color-text-sub)]">{key}</code>}
                  <span className="rounded-full bg-[var(--color-line-soft)] px-1.5 text-[11px]">{kindLabel}</span>
                  {required && <span className="rounded-full bg-rose-50 px-1.5 text-[11px] text-rose-600">必填</span>}
                </li>
              )
            })}
          </ul>
        </div>
      )}
    </div>
  )
}

// VersionFileBrowser — 单个版本的文件浏览（spec §4.7 R1）。
//
// 数据来自 skill_version_files 表（zip 上传时双写）：
//   - 列表 = GET /platform/skills/{uuid}/versions/{vuuid}/files
//   - 单文件预览 = GET /platform/skills/{uuid}/versions/{vuuid}/file-content?path=xxx
//   - 整包下载 = GET /platform/skills/{uuid}/versions/{vuuid}/download-url（OSS 签名 URL）
function VersionFileBrowser({
  skillUUID,
  versionUUID,
  onErr,
}: {
  skillUUID: string
  versionUUID: string
  onErr: (m: string) => void
}) {
  const api = useSkillAPI()
  type Entry = {
    path: string
    size_bytes: number
    sha256: string
    content_type: string
    is_binary: boolean
    truncated: boolean
  }
  type Content = {
    path: string
    size_bytes: number
    is_binary: boolean
    truncated: boolean
    content: string
    total_lines: number
  }

  const [files, setFiles] = useState<Entry[]>([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState<string | null>(null)
  const [content, setContent] = useState<Content | null>(null)
  const [contentLoading, setContentLoading] = useState(false)

  useEffect(() => {
    let cancelled = false
    queueMicrotask(() => { if (!cancelled) setLoading(true) })
    api.listVersionFiles(skillUUID, versionUUID)
      .then((r) => {
        if (cancelled) return
        const items = r.items || []
        setFiles(items)
        if (items.length > 0) {
          const md = items.find((f) => /^(.*\/)?SKILL\.md$/i.test(f.path))
          setSelected(md ? md.path : items[0].path)
        }
      })
      .catch((e: Error) => { if (!cancelled) onErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [skillUUID, versionUUID]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!selected) {
      queueMicrotask(() => setContent(null))
      return
    }
    let cancelled = false
    queueMicrotask(() => { if (!cancelled) setContentLoading(true) })
    api.getVersionFileContent(skillUUID, versionUUID, selected)
      .then((r) => { if (!cancelled) setContent(r) })
      .catch((e: Error) => { if (!cancelled) onErr(e.message) })
      .finally(() => { if (!cancelled) setContentLoading(false) })
    return () => { cancelled = true }
  }, [skillUUID, versionUUID, selected]) // eslint-disable-line react-hooks/exhaustive-deps

  const downloadPackage = async () => {
    try {
      const r = await api.getVersionDownloadURL(skillUUID, versionUUID)
      if (r.url) {
        window.open(r.url, '_blank', 'noopener')
      }
    } catch (e) {
      onErr((e as Error).message)
    }
  }

  if (loading) {
    return (
      <div className="mt-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3 text-[12px] text-[var(--color-text-sub)]">
        正在加载文件清单…
      </div>
    )
  }

  if (files.length === 0) {
    return (
      <div className="mt-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3 text-[12px] text-[var(--color-text-sub)]">
        文件清单为空。该版本可能由旧版后端创建（仅有 zip，未生成投影），重新上传同一 zip 包即可触发回填。
      </div>
    )
  }

  return (
    <div className="mt-3 overflow-hidden rounded-md border border-[var(--color-line)] bg-white">
      <div className="flex items-center justify-between border-b border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2">
        <div className="text-[12px] text-[var(--color-text-sub)]">
          文件 ({files.length})
        </div>
        <Button size="sm" variant="ghost" onClick={downloadPackage} title="下载完整技能包 zip">
          <Download size={14} /> 下载完整技能包
        </Button>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-[260px_1fr]">
        {/* 左侧文件列表 */}
        <div className="max-h-[420px] overflow-auto border-r border-[var(--color-line)]">
          {files.map((f) => (
            <button
              key={f.path}
              type="button"
              onClick={() => setSelected(f.path)}
              className={[
                'flex w-full items-start gap-2 px-3 py-2 text-left text-[12px] transition',
                selected === f.path
                  ? 'bg-[var(--color-primary-soft)] text-[var(--color-primary)]'
                  : 'text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)]',
              ].join(' ')}
            >
              <FileText size={14} className="mt-[2px] shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="truncate font-mono text-[12px]">{f.path}</div>
                <div className="mt-0.5 text-[11px] text-[var(--color-text-mute)]">
                  {fmtFileSize(f.size_bytes)}
                  {f.is_binary && <span className="ml-1">· 二进制</span>}
                  {f.truncated && <span className="ml-1">· 已截断</span>}
                </div>
              </div>
            </button>
          ))}
        </div>
        {/* 右侧文件内容 */}
        <div className="max-h-[420px] overflow-auto">
          {contentLoading ? (
            <div className="p-3 text-[12px] text-[var(--color-text-sub)]">正在加载文件内容…</div>
          ) : !content ? (
            <div className="p-3 text-[12px] text-[var(--color-text-sub)]">请选择左侧文件查看内容。</div>
          ) : content.is_binary ? (
            <div className="p-3 text-[12px] text-[var(--color-text-sub)]">
              该文件为二进制，无法预览。可点击右上"下载完整技能包"获取 zip 后查看。
            </div>
          ) : content.truncated ? (
            <div className="p-3 text-[12px] text-[var(--color-text-sub)]">
              该文件超过 1MB 未保存预览。可点击右上"下载完整技能包"获取 zip 后查看。
            </div>
          ) : (
            <pre className="m-0 whitespace-pre overflow-auto p-3 font-mono text-[12px] leading-[1.55] text-[var(--color-text)]">{content.content || '（空文件）'}</pre>
          )}
        </div>
      </div>
    </div>
  )
}

function fmtFileSize(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(2)} KB`
  return `${(n / 1024 / 1024).toFixed(2)} MB`
}

function CreateModal({
  onClose,
  onCreated,
  onErr,
}: {
  onClose: () => void
  onCreated: () => void
  onErr: (m: string) => void
}) {
  const api = useSkillAPI()
  const scope = useSkillScope()
  const isTenant = scope === 'tenant'
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [usageExample, setUsageExample] = useState('')
  const [exampleImages, setExampleImages] = useState<ExampleImageDraft[]>([])
  const [kind, setKind] = useState<'agent' | 'builtin'>('agent')
  const [builtinKey, setBuiltinKey] = useState('')
  // Agent 技能强制 synchronous_inline（chip rail 同步模式），仅 builtin 暴露选择。
  const [executionMode, setExecutionMode] = useState<'synchronous_inline' | 'asynchronous_floating'>('synchronous_inline')
  const [source, setSource] = useState<'internal' | 'open_source' | 'third_party'>('internal')
  // 平台管理端只允许 platform / tenant；workspace / private 留给后续租户管理与客户端入口。
  // tenant 模式下强制 'tenant' (不能开放给其他租户/全平台)。
  const [visibility, setVisibility] = useState<'platform' | 'tenant'>(isTenant ? 'tenant' : 'platform')
  const [categoryID, setCategoryID] = useState<number | undefined>()
  const [labelIDs, setLabelIDs] = useState<number[]>([])
  const [categories, setCategories] = useState<SkillCategory[]>([])
  const [labels, setLabels] = useState<SkillLabel[]>([])
  const [builtinKeys, setBuiltinKeys] = useState<SkillBuiltinKey[]>([])
  const [agentTypes, setAgentTypes] = useState<PlatformType[]>([])
  const [pkgState, setPkgState] = useState<PkgUploadState>(emptyPkgState())
  const [uploadInfo, setUploadInfo] = useState<string>('')
  const [iconURL, setIconURL] = useState('')           // oss:// 形态，create 提交用
  const [iconPreview, setIconPreview] = useState('')   // signed URL，仅预览
  // builtin 类技能的输入参数（spec §1.4 D27 R1B：仅 builtin 主表 input_chips_schema 可写；agent 类强制 [] + 由 SKILL.md 自动解析）。
  const [chips, setChips] = useState<ChipDraft[]>([])
  const [agentCompat, setAgentCompat] = useState<AgentCompatDraft>(EMPTY_AGENT_COMPAT)
  // 装配与状态：默认值跟后端 CreateSkill 默认值一致（false / 0）。
  const [defaultAttached, setDefaultAttached] = useState(false)
  const [defaultPinned, setDefaultPinned] = useState(false)
  const [sortOrder, setSortOrder] = useState(0)
  const [enabled, setEnabled] = useState(true)
  const [publishInitial, setPublishInitial] = useState(true)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let cancelled = false
    api.listCategories({ status: 'active', limit: 200, offset: 0 }).then((r) => { if (!cancelled) setCategories(r.items || []) }).catch(() => {})
    api.listLabels({ status: 'active', limit: 200, offset: 0 }).then((r) => { if (!cancelled) setLabels(r.items || []) }).catch(() => {})
    api.listBuiltinKeys({ status: 'active', limit: 200, offset: 0 }).then((r) => { if (!cancelled) setBuiltinKeys(r.items || []) }).catch(() => {})
    PlatformTypes.list().then((r) => { if (!cancelled) setAgentTypes(r.items || []) }).catch(() => {})
    return () => { cancelled = true }
  }, [api])

  // 当用户在 PackageUploader 选好 zip/文件夹后，前端读 SKILL.md frontmatter 自动填版本快照字段。
  // 仅在当前为空时填，避免覆盖用户手动编辑。
  useEffect(() => {
    if (kind !== 'agent') return
    let cancelled = false
    parseSkillMetadataFromPkg(pkgState).then((parsed) => {
      if (cancelled) return
      if (!parsed) return
      if (chips.length === 0 && parsed.chips.length > 0) {
        setChips(parsed.chips)
      }
      if (isEmptyAgentCompat(agentCompat) && !isEmptyAgentCompat(parsed.agentCompat)) {
        setAgentCompat(parsed.agentCompat)
      }
      if (parsed.chips.length > 0 || !isEmptyAgentCompat(parsed.agentCompat)) {
        setUploadInfo(`已从 SKILL.md frontmatter 自动解析到 ${parsed.chips.length} 个输入参数和兼容性配置，可继续调整后写入初始版本快照。`)
      }
    }).catch(() => { /* ignore parse errors; user can fill manually */ })
    return () => { cancelled = true }
  }, [pkgState, kind, chips.length, agentCompat])

  const submit = async () => {
    // agent 技能要求至少传一种包：文件夹 / zip 压缩包。
    if (kind === 'agent') {
      const err = validatePkgForAgent(pkgState)
      if (err) {
        onErr(err)
        return
      }
    }
    setBusy(true)
    setUploadInfo('')
    try {
      const created = await api.create({
        code,
        name,
        description: description || undefined,
        usage_example: usageExample || undefined,
        usage_example_images: exampleImages.length > 0 ? serializeExampleImages(exampleImages) : undefined,
        kind,
        icon_url: iconURL || undefined,
        builtin_key: kind === 'builtin' ? (builtinKey || undefined) : undefined,
        execution_mode: kind === 'agent' ? 'synchronous_inline' : executionMode,
        source,
        visibility,
        category_id: categoryID,
        label_ids: labelIDs.length > 0 ? labelIDs : undefined,
        default_attached: defaultAttached,
        default_pinned: defaultPinned,
        sort_order: sortOrder,
        // builtin 类把结构化参数序列化进主表；agent 类不传（spec §1.4 D27 强制 []）。
        input_chips_schema: kind === 'builtin' ? serializeChips(chips) : undefined,
      })
      if (kind === 'agent') {
        // agent 不会自动建版本，需要显式 POST /versions。snapshot 用用户编辑/自动解析后的 chips；
        // 后续 uploadPackage 因 service 层判空保留 snapshot，不会被 zip frontmatter 重新覆盖。
        setUploadInfo('创建首版本中...')
        const ver = await api.createAgentVersion(created.uuid, {
          version: '0.1.0',
          changelog: '初始版本',
          package_url: 'pending://upload',
          package_sha256: '',
          package_size_bytes: 0,
          input_chips_schema_snapshot: serializeChips(chips),
          agent_compat_snapshot: serializeAgentCompat(agentCompat),
        })
        setUploadInfo('打包并上传中...')
        const zipFile = await materializePkgFile(pkgState, code || 'skill')
        if (zipFile) {
          const upRes = await api.uploadPackage(created.uuid, ver.uuid, zipFile)
          setUploadInfo(`已上传，包大小 ${(upRes.package_size_bytes / 1024 / 1024).toFixed(2)} MB；输入参数 ${chips.length} 个已写入版本快照。`)
        }
        if (publishInitial) {
          setUploadInfo('发布初始版本中...')
          await api.publish(created.uuid, ver.uuid)
        }
      } else if (publishInitial && created.auto_created_version_uuid) {
        setUploadInfo('发布初始版本中...')
        await api.publish(created.uuid, created.auto_created_version_uuid)
      }
      await api.patch(created.uuid, { status: skillStatusFromEnabled(enabled) })
      onCreated()
    } catch (e) {
      onErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title="新建技能"
      subtitle="创建技能并生成初始版本；是否启用入口、是否发布初始版本可分开控制。"
      onClose={onClose}
      width="lg"
      variant="polished"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '创建中...' : '创建'}</Button>
        </div>
      }
    >
      <div className="space-y-4">
        {uploadInfo && <InlineAlert tone="info">{uploadInfo}</InlineAlert>}

        <SkillDrawerSection
          title="基础信息"
          actions={
            <SectionSwitchAction
              label="状态"
              checked={enabled}
              onChange={setEnabled}
              disabled={busy}
              title={enabled ? '点击禁用技能' : '点击启用技能'}
              checkedText="已启用"
              uncheckedText="已禁用"
            />
          }
        >
          <div className="mb-3">
            <FormField label="技能图标" hint="建议方形 PNG/JPG/WebP，单张 ≤ 1MB；不上传则在客户端显示默认扳手图标。">
              <IconUploader
                value={iconURL}
                previewUrl={iconPreview}
                onChange={(uri, preview) => { setIconURL(uri); setIconPreview(preview) }}
                disabled={busy}
              />
            </FormField>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <FormField label="名称">
              <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="如 图片生成" />
            </FormField>
            <FormField label="技能标识 Code" hint="全局唯一，建议小写英文、数字、下划线。">
              <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="image_generation" />
            </FormField>
            {/* 租户自建恒为 Agent 技能 — builtin 需要客户端 native runner, 仅平台可注册;
                字段值固定无可选项, 直接隐藏减少干扰。 */}
            {!isTenant && (
              <SelectField
                label="技能类型"
                value={kind}
                onChange={(v) => setKind(v as 'agent' | 'builtin')}
              >
                <option value="agent">Agent 技能</option>
                <option value="builtin">客户端原生技能</option>
              </SelectField>
            )}
            {kind === 'builtin' && (
              <SelectField
                label="执行模式"
                value={executionMode}
                onChange={(v) => setExecutionMode(v as 'synchronous_inline' | 'asynchronous_floating')}
              >
                <option value="synchronous_inline">同步内联</option>
                <option value="asynchronous_floating">异步浮层</option>
              </SelectField>
            )}
            <SelectField label="来源" value={source} onChange={(v) => setSource(v as 'internal' | 'open_source' | 'third_party')}>
              <option value="internal">内部</option>
              <option value="open_source">开源</option>
              <option value="third_party">第三方</option>
            </SelectField>
            {/* 企业自建强制 tenant 可见, 同理隐藏不展示无意义的固定下拉。 */}
            {!isTenant && (
              <SelectField
                label="可见范围"
                value={visibility}
                onChange={(v) => setVisibility(v as 'platform' | 'tenant')}
              >
                <option value="platform">全平台（所有租户可见）</option>
                <option value="tenant">租户级（仅当前租户）</option>
              </SelectField>
            )}
            <SelectField
              label="技能分类"
              value={categoryID ?? ''}
              onChange={(v) => setCategoryID(v ? Number(v) : undefined)}
            >
              <option value="">请选择</option>
              {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </SelectField>
          </div>
          <div className="mt-3">
            <FormField label="技能标签" hint={labels.length === 0 ? '请先在「技能标签」字典中维护标签。' : '多选；用于跨分类筛选与归档。'}>
              <LabelMultiSelect
                labels={labels}
                value={labelIDs}
                onChange={setLabelIDs}
                disabled={busy}
                emptyHint="请先在「技能标签」字典中维护标签"
              />
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="描述">
              <textarea
                className="min-h-[96px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
                value={description}
                placeholder="简要说明技能用途，可选"
                onChange={(e) => setDescription(e.target.value)}
                disabled={busy}
              />
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="使用示例" hint="填写典型输入、操作步骤或预期输出，支持 Markdown。">
              <textarea
                className="min-h-[150px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
                value={usageExample}
                placeholder="填写典型输入、操作步骤或预期输出"
                onChange={(e) => setUsageExample(e.target.value)}
                disabled={busy}
              />
            </FormField>
          </div>
          <div className="mt-3">
            <FormField label="示例图片" hint="支持 PNG/JPG/GIF/WebP，最多 6 张，单张 ≤ 5MB。">
              <ExampleImagesUploader value={exampleImages} onChange={setExampleImages} disabled={busy} />
            </FormField>
          </div>
        </SkillDrawerSection>

        {kind === 'builtin' && (
          <SkillDrawerSection title="客户端能力" description="选择客户端已注册的内置能力 Key，运行时由客户端原生执行，不走 Agent 调用。">
            <SelectField label="客户端能力 Key" value={builtinKey} onChange={setBuiltinKey}>
              <option value="">请选择</option>
              {builtinKeys.filter((k) => k.status === 'active').map((k) => (
                <option key={k.id} value={k.code}>{k.code} - {k.name}</option>
              ))}
            </SelectField>
          </SkillDrawerSection>
        )}

        {kind === 'agent' && (
          <SkillDrawerSection
            title="初始版本"
            description="创建技能时同步创建 v0.1.0 版本。技能包、输入参数和 Agent 兼容性都会写入这个版本快照。"
            actions={
              <SectionSwitchAction
                label="是否发布"
                checked={publishInitial}
                onChange={setPublishInitial}
                disabled={busy}
                title={publishInitial ? '创建后发布初始版本' : '创建后不发布初始版本'}
                checkedText="发布"
                uncheckedText="不发布"
              />
            }
          >
            <div className="space-y-3">
              <FormField
                label="技能包（SKILL.md）"
                hint="必须包含 SKILL.md。可直接选技能文件夹由前端自动打包，也支持上传已打好的 zip。上传后后端会再次解析 frontmatter。"
              >
                <PackageUploader value={pkgState} onChange={setPkgState} disabled={busy} />
              </FormField>
              <FormField
                label="输入参数快照"
                hint="来自 SKILL.md frontmatter 的 input_chips_schema；这里调整后会写入 v0.1.0 版本快照。"
              >
                <ChipListEditor value={chips} onChange={setChips} />
              </FormField>
              <FormField
                label="Agent 兼容性快照"
                hint="可限制此技能适用于哪些 Agent 平台类型；不选择表示不限制。"
              >
                <AgentCompatEditorInline value={agentCompat} onChange={setAgentCompat} agentTypes={agentTypes} />
              </FormField>
            </div>
          </SkillDrawerSection>
        )}

        {kind === 'builtin' && (
          <SkillDrawerSection
            title="初始版本"
            description="客户端原生技能会自动生成 v0.1.0 版本快照，发布后对运行时生效。"
            actions={
              <SectionSwitchAction
                label="是否发布"
                checked={publishInitial}
                onChange={setPublishInitial}
                disabled={busy}
                title={publishInitial ? '创建后发布初始版本' : '创建后不发布初始版本'}
                checkedText="发布"
                uncheckedText="不发布"
              />
            }
          >
            <ChipListEditor value={chips} onChange={setChips} />
          </SkillDrawerSection>
        )}

        <SkillDrawerSection
          title="默认装配"
          description="平台级默认行为：新建数字员工时是否自动带上此技能、是否置顶、以及在技能广场的排序权重。"
        >
          <div className="grid grid-cols-2 gap-3">
            <label className="flex items-center gap-2 text-[13px] text-[var(--color-text)]">
              <input type="checkbox" checked={defaultAttached} onChange={(e) => setDefaultAttached(e.target.checked)} disabled={busy} />
              <span>默认装配到所有数字员工</span>
            </label>
            <label className="flex items-center gap-2 text-[13px] text-[var(--color-text)]">
              <input type="checkbox" checked={defaultPinned} onChange={(e) => setDefaultPinned(e.target.checked)} disabled={busy} />
              <span>默认置顶（仅当默认装配生效）</span>
            </label>
            <FormField label="排序权重" hint="数字越大越靠前；同权重按创建时间倒序。">
              <Input type="number" value={sortOrder} onChange={(e) => setSortOrder(Number(e.target.value))} disabled={busy} />
            </FormField>
          </div>
        </SkillDrawerSection>
      </div>
    </DrawerShell>
  )
}

function CreateVersionModal({
  skill,
  onClose,
  onCreated,
  onErr,
}: {
  skill: Skill
  onClose: () => void
  onCreated: () => void
  onErr: (m: string) => void
}) {
  const api = useSkillAPI()
  const [version, setVersion] = useState('1.0.0')
  const [changelog, setChangelog] = useState('')
  const [pkgState, setPkgState] = useState<PkgUploadState>(emptyPkgState())
  const [uploadInfo, setUploadInfo] = useState('')
  const [chips, setChips] = useState<ChipDraft[]>([])
  const [agentCompat, setAgentCompat] = useState<AgentCompatDraft>(EMPTY_AGENT_COMPAT)
  const [agentTypes, setAgentTypes] = useState<PlatformType[]>([])
  const [grayscalePct, setGrayscalePct] = useState(100)
  const [grayscaleStrategy, setGrayscaleStrategy] = useState('tenant_hash')
  const [publishAfterCreate, setPublishAfterCreate] = useState(false)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let cancelled = false
    PlatformTypes.list().then((r) => { if (!cancelled) setAgentTypes(r.items || []) }).catch(() => {})
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    if (skill.kind !== 'agent') return
    let cancelled = false
    parseSkillMetadataFromPkg(pkgState).then((parsed) => {
      if (cancelled || !parsed) return
      if (chips.length === 0 && parsed.chips.length > 0) setChips(parsed.chips)
      if (isEmptyAgentCompat(agentCompat) && !isEmptyAgentCompat(parsed.agentCompat)) {
        setAgentCompat(parsed.agentCompat)
      }
      if (parsed.chips.length > 0 || !isEmptyAgentCompat(parsed.agentCompat)) {
        setUploadInfo(`已从 SKILL.md frontmatter 自动解析到 ${parsed.chips.length} 个输入参数和兼容性配置，可继续调整后写入版本快照。`)
      }
    }).catch(() => {})
    return () => { cancelled = true }
  }, [pkgState, skill.kind, chips.length, agentCompat])

  const submit = async () => {
    if (skill.kind === 'agent') {
      const err = validatePkgForAgent(pkgState)
      if (err) { onErr(err); return }
    }
    setBusy(true)
    setUploadInfo('')
    try {
      if (skill.kind === 'agent') {
        // 先建 draft（package_url 暂为 pending://upload，后端允许），再 uploadPackage 自动回写 url/sha256/size + frontmatter snapshot。
        const ver = await api.createAgentVersion(skill.uuid, {
          version,
          changelog,
          package_url: 'pending://upload',
          package_sha256: '',
          package_size_bytes: 0,
          input_chips_schema_snapshot: serializeChips(chips),
          agent_compat_snapshot: serializeAgentCompat(agentCompat),
        })
        setUploadInfo('打包并上传中...')
        const zipFile = await materializePkgFile(pkgState, skill.code || 'skill')
        if (zipFile) {
          const upRes = await api.uploadPackage(skill.uuid, ver.uuid, zipFile)
          let chipCount = 0
          if (Array.isArray(upRes.input_chips_schema_snapshot)) {
            chipCount = upRes.input_chips_schema_snapshot.length
          }
          setUploadInfo(`已上传，包大小 ${(upRes.package_size_bytes / 1024 / 1024).toFixed(2)} MB${chipCount > 0 ? `，自动解析到 ${chipCount} 个输入参数` : ''}`)
        }
        if (publishAfterCreate) {
          setUploadInfo('发布版本中...')
          await api.publish(skill.uuid, ver.uuid)
        }
      } else {
        const ver = await api.createBuiltinVersion(skill.uuid, {
          version,
          changelog,
          grayscale_pct: grayscalePct,
          grayscale_strategy: grayscaleStrategy,
        })
        if (publishAfterCreate) {
          await api.publish(skill.uuid, ver.uuid)
        }
      }
      onCreated()
    } catch (e) {
      onErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={`新建版本（${skill.name}）`}
      subtitle={`${KIND_LABEL[skill.kind] || skill.kind} · ${skill.code} · 创建新版本；可选择创建后立即设为当前线上版本。`}
      onClose={onClose}
      width="lg"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '创建中...' : (publishAfterCreate ? '创建并发布' : '创建')}</Button>
        </div>
      }
    >
      <div className="space-y-3">
        <FormField label="版本号（SemVer）">
          <Input value={version} onChange={(e) => setVersion(e.target.value)} />
        </FormField>
        <FormField label="创建后发布此版本" hint="打开后，该版本会成为当前线上版本，同一技能下其他版本的发布开关会自动关闭。">
          <div className="flex h-9 items-center gap-2">
            <InlineSwitch checked={publishAfterCreate} onChange={setPublishAfterCreate} disabled={busy} />
            <span className="text-[13px] text-[var(--color-text-sub)]">{publishAfterCreate ? '发布' : '不发布'}</span>
          </div>
        </FormField>
        <FormField label="变更说明">
          <textarea
            className="min-h-[88px] w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px] text-[var(--color-text)] transition focus:border-[var(--color-brand)] focus:outline-none focus:shadow-[rgba(15,107,255,0.16)_0px_0px_0px_3px]"
            value={changelog}
            onChange={(e) => setChangelog(e.target.value)}
          />
        </FormField>
        {skill.kind === 'agent' ? (
          <>
            <FormField
              label="技能包（SKILL.md）"
              hint="必须包含 SKILL.md。建议直接选技能文件夹由前端自动打包，也支持已打好的 zip 压缩包。上传后后端自动计算 SHA256、包大小，并解析 frontmatter。"
            >
              <PackageUploader value={pkgState} onChange={setPkgState} disabled={busy} />
            </FormField>
            {uploadInfo && (
              <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[12px] text-[var(--color-text-sub)]">
                {uploadInfo}
              </div>
            )}
            <FormField
              label="输入参数快照"
              hint="按 SKILL.md frontmatter 的 input_chips_schema 填写。每个参数选类型 + 文本字段，无需手写 JSON。"
            >
              <ChipListEditor value={chips} onChange={setChips} />
            </FormField>
            <FormField
              label="Agent 兼容性快照"
              hint="可限制此版本适用于哪些 Agent 平台类型；不选择表示不限制。"
            >
              <AgentCompatEditorInline value={agentCompat} onChange={setAgentCompat} agentTypes={agentTypes} />
            </FormField>
          </>
        ) : (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <FormField label="灰度比例（0-100）">
              <Input type="number" value={grayscalePct} onChange={(e) => setGrayscalePct(Number(e.target.value))} />
            </FormField>
            <SelectField label="灰度策略" value={grayscaleStrategy} onChange={setGrayscaleStrategy}>
              <option value="tenant_hash">按租户哈希</option>
              <option value="agent_hash">按数字员工哈希</option>
              <option value="user_hash">按用户哈希</option>
              <option value="tenant_allowlist">租户白名单</option>
            </SelectField>
          </div>
        )}
      </div>
    </DrawerShell>
  )
}

// ----- 结构化 chip / agent_compat 编辑器（替代手填 JSON） -----
//
// 设计权衡：
// - 真值源仍是 SKILL.md frontmatter（spec §1.4 D27 R1B）。这里的结构化编辑器
//   只在 zip 上传未实装、或临时覆盖时使用；提交时序列化为 JSON 字符串，
//   后端 v0.9 仍按 string 接收。
// - 仅覆盖 14 类 chip 中常用 8 类（text-inline / number / toggle / date /
//   enum-dropdown / enum-multi / file-upload / image-upload / model-picker）。
//   其余类型可暂时通过 SKILL.md frontmatter 走，后续 P2 再补 UI。

type ChipKind =
  | 'text-inline'
  | 'number'
  | 'toggle'
  | 'date'
  | 'enum-dropdown'
  | 'enum-multi'
  | 'file-upload'
  | 'image-upload'
  | 'model-picker'

type ChipDraft = {
  key: string
  label: string
  kind: ChipKind
  required: boolean
  default?: string
  placeholder?: string
  description?: string
  options?: { value: string; label: string }[]
  min?: number
  max?: number
  step?: number
  max_size_mb?: number
}

type AgentCompatDraft = {
  required_models: string
  required_runtimes: string
  blocked_agent_tags: string
}

const CHIP_KIND_LABEL: Record<ChipKind, string> = {
  'text-inline': '文本',
  number: '数字',
  toggle: '开关',
  date: '日期',
  'enum-dropdown': '单选下拉',
  'enum-multi': '多选',
  'file-upload': '文件上传',
  'image-upload': '图片上传',
  'model-picker': '模型选择器',
}

function serializeChips(drafts: ChipDraft[]): unknown[] {
  return drafts
    .filter((c) => c.key.trim() !== '')
    .map((c) => {
      const out: Record<string, unknown> = {
        key: c.key.trim(),
        kind: c.kind,
        label: c.label.trim() || c.key.trim(),
        required: !!c.required,
      }
      if (c.default !== undefined && c.default !== '') out.default = c.default
      if (c.placeholder) out.placeholder = c.placeholder
      if (c.description) out.description = c.description
      if (c.kind === 'enum-dropdown' || c.kind === 'enum-multi') {
        out.options = (c.options || []).filter((o) => o.value.trim() !== '').map((o) => ({
          value: o.value.trim(),
          label: o.label.trim() || o.value.trim(),
        }))
      }
      if (c.kind === 'number') {
        if (c.min !== undefined) out.min = c.min
        if (c.max !== undefined) out.max = c.max
        if (c.step !== undefined) out.step = c.step
      }
      if (c.kind === 'file-upload' || c.kind === 'image-upload') {
        if (c.max_size_mb && c.max_size_mb > 0) {
          out.file_constraint = { max_size_bytes: c.max_size_mb * 1024 * 1024 }
        }
      }
      return out
    })
}

function serializeAgentCompat(d: AgentCompatDraft): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const requiredModels = parseCSV(d.required_models)
  const requiredRuntimes = parseCSV(d.required_runtimes)
  const blockedAgentTags = parseCSV(d.blocked_agent_tags)
  if (requiredModels.length > 0) out.required_models = requiredModels
  if (requiredRuntimes.length > 0) out.required_runtimes = requiredRuntimes
  if (blockedAgentTags.length > 0) out.blocked_agent_tags = blockedAgentTags
  return out
}

function parseCSV(value: string): string[] {
  return value.split(',').map((s) => s.trim()).filter(Boolean)
}

function isEmptyAgentCompat(value: AgentCompatDraft): boolean {
  return !value.required_models.trim() && !value.required_runtimes.trim() && !value.blocked_agent_tags.trim()
}

function deserializeAgentCompat(raw: unknown): AgentCompatDraft {
  if (!raw || typeof raw !== 'object') return EMPTY_AGENT_COMPAT
  const o = raw as Record<string, unknown>
  return {
    required_models: stringifyList(o.required_models),
    required_runtimes: stringifyList(o.required_runtimes),
    blocked_agent_tags: stringifyList(o.blocked_agent_tags),
  }
}

function stringifyList(raw: unknown): string {
  if (!Array.isArray(raw)) return ''
  return raw.map((x) => String(x).trim()).filter(Boolean).join(', ')
}

function normalizeCompat(raw: unknown): { requiredModels: string[]; requiredRuntimes: string[]; blockedAgentTags: string[] } {
  if (!raw || typeof raw !== 'object') {
    return { requiredModels: [], requiredRuntimes: [], blockedAgentTags: [] }
  }
  const o = raw as Record<string, unknown>
  return {
    requiredModels: Array.isArray(o.required_models) ? o.required_models.map(String).filter(Boolean) : [],
    requiredRuntimes: Array.isArray(o.required_runtimes) ? o.required_runtimes.map(String).filter(Boolean) : [],
    blockedAgentTags: Array.isArray(o.blocked_agent_tags) ? o.blocked_agent_tags.map(String).filter(Boolean) : [],
  }
}

function ChipListEditor({ value, onChange }: { value: ChipDraft[]; onChange: (v: ChipDraft[]) => void }) {
  const update = (idx: number, patch: Partial<ChipDraft>) => {
    onChange(value.map((c, i) => i === idx ? { ...c, ...patch } : c))
  }
  const remove = (idx: number) => onChange(value.filter((_, i) => i !== idx))
  const add = () => onChange([...value, { key: '', label: '', kind: 'text-inline', required: false }])

  return (
    <div className="space-y-2">
      {value.length === 0 && (
        <div className="rounded-md border border-dashed border-[var(--color-line)] px-3 py-3 text-center text-[12px] text-[var(--color-text-sub)]">
          暂无参数。点击下方「添加参数」开始构建技能输入表单。
        </div>
      )}
      {value.map((chip, idx) => {
        return (
        <div key={idx} className="overflow-hidden rounded-md border border-[var(--color-line)] bg-white">
          <div className="flex items-center gap-2 border-b border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2">
            <span className="text-[13px] font-medium text-[var(--color-text)]">参数 {idx + 1}</span>
            <div className="flex-1" />
            <label className="inline-flex items-center gap-1 text-[12px] text-[var(--color-text-sub)]">
              <input
                type="checkbox"
                checked={chip.required}
                onChange={(e) => update(idx, { required: e.target.checked })}
              />
              必填
            </label>
            <button
              type="button"
              onClick={() => remove(idx)}
              title="删除参数"
              className="grid h-7 w-7 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-danger-bg)] hover:text-[var(--color-danger)]"
            >
              <Trash2 size={14} />
            </button>
          </div>
          <div className="space-y-2 p-3">
            <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
              <FormField label="参数 key">
                <Input value={chip.key} onChange={(e) => update(idx, { key: e.target.value })} placeholder="如 ratio" />
              </FormField>
              <FormField label="显示名称">
                <Input value={chip.label} onChange={(e) => update(idx, { label: e.target.value })} placeholder="如 比例" />
              </FormField>
              <SelectField
                label="类型"
                value={chip.kind}
                onChange={(v) => update(idx, { kind: v as ChipKind, options: undefined })}
              >
                {(Object.keys(CHIP_KIND_LABEL) as ChipKind[]).map((k) => (
                  <option key={k} value={k}>{CHIP_KIND_LABEL[k]}</option>
                ))}
              </SelectField>
            </div>
            <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
              <FormField label="默认值（可选）">
                <Input value={chip.default ?? ''} onChange={(e) => update(idx, { default: e.target.value })} />
              </FormField>
              <FormField label="预留提示（可选）">
                <Input value={chip.placeholder ?? ''} onChange={(e) => update(idx, { placeholder: e.target.value })} />
              </FormField>
              <FormField label="说明（可选）">
                <Input value={chip.description ?? ''} onChange={(e) => update(idx, { description: e.target.value })} />
              </FormField>
            </div>
            {(chip.kind === 'enum-dropdown' || chip.kind === 'enum-multi') && (
              <ChipOptionsEditor
                value={chip.options || []}
                onChange={(opts) => update(idx, { options: opts })}
              />
            )}
            {chip.kind === 'number' && (
              <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
                <FormField label="最小值">
                  <Input type="number" value={chip.min ?? ''} onChange={(e) => update(idx, { min: e.target.value === '' ? undefined : Number(e.target.value) })} />
                </FormField>
                <FormField label="最大值">
                  <Input type="number" value={chip.max ?? ''} onChange={(e) => update(idx, { max: e.target.value === '' ? undefined : Number(e.target.value) })} />
                </FormField>
                <FormField label="步长">
                  <Input type="number" value={chip.step ?? ''} onChange={(e) => update(idx, { step: e.target.value === '' ? undefined : Number(e.target.value) })} />
                </FormField>
              </div>
            )}
            {(chip.kind === 'file-upload' || chip.kind === 'image-upload') && (
              <FormField label="单文件大小上限（MB）">
                <Input
                  type="number"
                  value={chip.max_size_mb ?? ''}
                  onChange={(e) => update(idx, { max_size_mb: e.target.value === '' ? undefined : Number(e.target.value) })}
                />
              </FormField>
            )}
          </div>
        </div>
        )
      })}
      <Button size="sm" variant="ghost" onClick={add}><Plus size={12} /> 添加参数</Button>
    </div>
  )
}

function ChipOptionsEditor({
  value,
  onChange,
}: {
  value: { value: string; label: string }[]
  onChange: (v: { value: string; label: string }[]) => void
}) {
  const update = (idx: number, patch: Partial<{ value: string; label: string }>) => {
    onChange(value.map((o, i) => i === idx ? { ...o, ...patch } : o))
  }
  const remove = (idx: number) => onChange(value.filter((_, i) => i !== idx))
  const add = () => onChange([...value, { value: '', label: '' }])
  return (
    <div className="space-y-2">
      <div className="text-[12px] font-medium text-[var(--color-text-sub)]">选项</div>
      {value.map((opt, idx) => (
        <div key={idx} className="flex items-center gap-2">
          <div className="flex-1">
            <Input
              value={opt.value}
              onChange={(e) => update(idx, { value: e.target.value })}
              placeholder="value（如 16:9）"
            />
          </div>
          <div className="flex-1">
            <Input
              value={opt.label}
              onChange={(e) => update(idx, { label: e.target.value })}
              placeholder="label（如 16:9 横版）"
            />
          </div>
          <button
            type="button"
            onClick={() => remove(idx)}
            title="删除选项"
            className="grid h-8 w-8 shrink-0 place-items-center rounded-md text-[var(--color-text-sub)] transition hover:bg-[var(--color-danger-bg)] hover:text-[var(--color-danger)]"
          >
            <Trash2 size={14} />
          </button>
        </div>
      ))}
      <Button size="sm" variant="ghost" onClick={add}><Plus size={12} /> 添加选项</Button>
    </div>
  )
}

function AgentCompatEditorInline({
  value,
  onChange,
  agentTypes,
}: {
  value: AgentCompatDraft
  onChange: (v: AgentCompatDraft) => void
  agentTypes: PlatformType[]
}) {
  const selected = parseCSV(value.required_runtimes)
  const toggle = (code: string) => {
    const next = selected.includes(code) ? selected.filter((v) => v !== code) : [...selected, code]
    onChange({ ...value, required_runtimes: next.join(', ') })
  }

  return (
    <div className="space-y-2">
      <div className="text-[12px] text-[var(--color-text-sub)]">
        不选择表示不限制，所有符合托管模式的 Agent 都可装配。
      </div>
      {agentTypes.length === 0 ? (
        <div className="rounded-md border border-dashed border-[var(--color-line)] px-3 py-3 text-[12px] text-[var(--color-text-sub)]">
          暂未读取到 Agent 平台类型；保存时将不限制 Agent 类型。
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          {agentTypes.map((type) => {
            const active = selected.includes(type.code)
            return (
              <button
                type="button"
                key={type.code}
                onClick={() => toggle(type.code)}
                className={`rounded-md border px-3 py-2 text-left text-[12px] transition ${active
                  ? 'border-[var(--color-brand)] bg-[var(--color-brand-bg)] text-[var(--color-brand)]'
                  : 'border-[var(--color-line)] bg-[var(--color-control-bg)] text-[var(--color-text-sub)] hover:border-[var(--color-text-sub)]'}`}
              >
                <span className="block font-medium">{agentTypeLabel(type)}</span>
                <span className="mt-0.5 block font-mono text-[11px] opacity-80">{type.code}</span>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

function agentTypeLabel(type: PlatformType): string {
  if (type.code === 'zap') return '自定义智能体平台（ZAP 协议）'
  if (type.code === 'dsh') return '知办通用运行时（dsh）'
  if (type.code === 'openclaw') return 'OpenClaw'
  if (type.code === 'hermes') return 'Hermes'
  return type.display_name || type.code
}

// ----- 技能包上传器（文件夹 / zip 二选一） -----
//
// 设计参考 aigc-admin 的 SkillCreator 上传交互：
// - 支持点击 / 拖拽两种入口；
// - 文件夹模式下递归读取 FileSystemDirectoryEntry，前端用 JSZip 打包成单个 zip 后再上传；
// - zip 模式直接接受单个 .zip 文件；
// - 提交前校验 SKILL.md 必须存在于根目录。
//
// 选择前端打包而非后端 multipart files：复用现有 upload-package endpoint，
// 后端无需改协议；JSZip 已加入依赖，~100KB gzip 可接受。

type PkgUploadMode = 'folder' | 'archive'

type FolderEntry = { file: File; relPath: string }

type PkgUploadState = {
  mode: PkgUploadMode
  folder: FolderEntry[]
  archive: File | null
}

function emptyPkgState(): PkgUploadState {
  return { mode: 'folder', folder: [], archive: null }
}

function validatePkgForAgent(s: PkgUploadState): string | null {
  if (s.mode === 'archive') {
    if (!s.archive) return '请上传 zip 压缩包，或切换到文件夹模式'
    if (!s.archive.name.toLowerCase().endsWith('.zip')) return '只支持 .zip 格式压缩包'
    return null
  }
  if (s.folder.length === 0) return '请选择技能文件夹'
  const hasSkillMd = s.folder.some((e) => {
    const p = e.relPath.replace(/\\/g, '/').toLowerCase()
    return p === 'skill.md' || p.endsWith('/skill.md')
  })
  if (!hasSkillMd) return '所选文件夹中必须包含 SKILL.md'
  return null
}

async function materializePkgFile(s: PkgUploadState, codeName: string): Promise<File | null> {
  if (s.mode === 'archive') return s.archive
  if (s.folder.length === 0) return null
  const zip = new JSZip()
  for (const ent of s.folder) {
    zip.file(ent.relPath, ent.file)
  }
  const blob = await zip.generateAsync({ type: 'blob' })
  return new File([blob], `${codeName}.zip`, { type: 'application/zip' })
}

function pkgRelativePath(file: File): string {
  // 经 webkitdirectory 选择 / 拖拽 entry 都会带 webkitRelativePath。
  const rel = (file as File & { webkitRelativePath?: string }).webkitRelativePath || ''
  if (!rel) return file.name
  // 去掉顶层目录前缀（aigc-admin 同款），让后端看到的就是技能根目录。
  const idx = rel.indexOf('/')
  return idx >= 0 ? rel.slice(idx + 1) : rel
}

// errTitle / errHint：把 setErr 收上来的多种来源（list / create / upload / patch）
// 转成更精准的标题与建议，不再统一显示「请检查 …/skills 是否可达」误导排查。
function errTitle(msg: string): string {
  const m = msg.toLowerCase()
  if (m.includes('oss put') || m.includes('upload-package') || m.includes('package_too_large')) {
    return '上传技能包失败'
  }
  if (m.includes('upload-icon') || m.includes('icon')) return '上传图标失败'
  if (m.includes('skill.code_already_exists') || m.includes('skill.version_already_exists')) {
    return '创建失败'
  }
  return '加载失败'
}

function errHint(msg: string, isPermErr: boolean): string {
  if (isPermErr) return '请联系平台管理员授予 platform.skill.read 权限，或切回平台管理视图后重试。'
  const m = msg.toLowerCase()
  if (m.includes('oss put') && m.includes('eof')) {
    return '与对象存储服务器的连接被中断。常见原因：技能包过大或网络抖动；先把 zip 控制在 50MB 以内（剔除 node_modules/.venv 等不必要目录）后重试。'
  }
  if (m.includes('package_too_large')) return '技能包超出 50MB 上限，剔除依赖目录后再上传。'
  if (m.includes('skill.md not found')) return '技能包内必须包含 SKILL.md（根目录或一层子目录）。'
  if (m.includes('package_pending_upload')) return '版本仍在等待上传，请先完成 zip 上传后再发布。'
  if (m.includes('code_already_exists')) return '技能 code 已存在，请换一个唯一标识。'
  if (m.includes('version_already_exists')) return '版本号已存在，请使用更高的 semver。'
  return '请稍后重试；持续失败请检查 admin API 服务与对象存储是否可达。'
}

// PKG_SKIP_DIRS：客户端打包前必须剔除的目录段，避免误把整个工程打进 zip
// 触发后端 50MB 上限或 OSS put EOF。命中时直接 skip 该文件。
const PKG_SKIP_DIRS = [
  'node_modules', '.venv', 'venv', '__pycache__',
  'dist', 'build', '.next', '.turbo', '.parcel-cache',
  '.git', '.svn', '.hg', '.idea', '.vscode',
  '.dart_tool', '.gradle', '.mvn', 'target',
  '__macosx',
]
function pkgShouldSkip(file: File, relPath: string): boolean {
  const name = file.name.toLowerCase()
  if (name.startsWith('.') || name === 'thumbs.db' || name === 'desktop.ini') return true
  const rel = relPath.toLowerCase().replace(/\\/g, '/')
  for (const seg of PKG_SKIP_DIRS) {
    if (rel === seg || rel.startsWith(`${seg}/`) || rel.includes(`/${seg}/`)) return true
  }
  return false
}

async function readEntryRecursive(entry: FileSystemEntry): Promise<File[]> {
  if (entry.isFile) {
    return new Promise((resolve) => {
      ;(entry as FileSystemFileEntry).file((f) => {
        Object.defineProperty(f, 'webkitRelativePath', {
          value: entry.fullPath.replace(/^\//, ''),
          writable: false,
        })
        resolve([f])
      })
    })
  }
  if (entry.isDirectory) {
    const reader = (entry as FileSystemDirectoryEntry).createReader()
    const entries: FileSystemEntry[] = await new Promise((resolve) => {
      const all: FileSystemEntry[] = []
      const readBatch = () => {
        reader.readEntries((batch) => {
          if (batch.length === 0) {
            resolve(all)
          } else {
            all.push(...batch)
            readBatch()
          }
        })
      }
      readBatch()
    })
    const nested = await Promise.all(entries.map(readEntryRecursive))
    return nested.flat()
  }
  return []
}

function PackageUploader({
  value,
  onChange,
  disabled,
}: {
  value: PkgUploadState
  onChange: (v: PkgUploadState) => void
  disabled?: boolean
}) {
  const folderRef = useRef<HTMLInputElement>(null)
  const zipRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)

  const setMode = (mode: PkgUploadMode) => {
    if (disabled) return
    if (mode === 'folder') onChange({ ...value, mode, archive: null })
    else onChange({ ...value, mode, folder: [] })
  }

  const addFolderFiles = (files: File[]) => {
    const existing = new Set(value.folder.map((e) => e.relPath))
    const next: FolderEntry[] = [...value.folder]
    for (const f of files) {
      const rel = pkgRelativePath(f)
      if (pkgShouldSkip(f, rel)) continue
      if (f.size === 0) continue
      if (existing.has(rel)) continue
      next.push({ file: f, relPath: rel })
      existing.add(rel)
    }
    onChange({ ...value, mode: 'folder', archive: null, folder: next })
  }

  const onFolderInput = (e: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files || [])
    if (files.length === 0) return
    addFolderFiles(files)
    e.target.value = ''
  }

  const onZipInput = (e: ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0] || null
    if (f) onChange({ ...value, mode: 'archive', folder: [], archive: f })
    e.target.value = ''
  }

  const onDrop = async (e: ReactDragEvent) => {
    e.preventDefault()
    setDragging(false)
    if (disabled) return
    const items = e.dataTransfer.items
    if (!items || items.length === 0) return
    // zip 单文件拖拽
    if (items.length === 1) {
      const it = items[0]
      const entry = it.webkitGetAsEntry?.()
      if (entry?.isFile) {
        const f = it.getAsFile()
        if (f && f.name.toLowerCase().endsWith('.zip')) {
          onChange({ ...value, mode: 'archive', folder: [], archive: f })
          return
        }
      }
    }
    // 否则按文件夹处理
    const entries: FileSystemEntry[] = []
    for (let i = 0; i < items.length; i++) {
      const entry = items[i].webkitGetAsEntry?.()
      if (entry) entries.push(entry)
    }
    const lists = await Promise.all(entries.map(readEntryRecursive))
    addFolderFiles(lists.flat())
  }

  const removeFolderEntry = (rel: string) => {
    onChange({ ...value, folder: value.folder.filter((e) => e.relPath !== rel) })
  }

  const clear = () => {
    if (value.mode === 'folder') onChange({ ...value, folder: [] })
    else onChange({ ...value, archive: null })
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <ModeBtn active={value.mode === 'folder'} onClick={() => setMode('folder')} disabled={disabled}>技能文件夹</ModeBtn>
        <ModeBtn active={value.mode === 'archive'} onClick={() => setMode('archive')} disabled={disabled}>压缩包 (.zip)</ModeBtn>
      </div>
      <div
        className={`rounded-md border border-dashed px-4 py-5 text-center transition ${dragging
          ? 'border-[var(--color-brand)] bg-[var(--color-brand-bg)]'
          : 'border-[var(--color-line)] bg-[var(--color-control-bg)]'}`}
        onDragOver={(e) => { e.preventDefault(); if (!disabled) setDragging(true) }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        onClick={() => {
          if (disabled) return
          if (value.mode === 'folder') folderRef.current?.click()
          else zipRef.current?.click()
        }}
        role="button"
        style={{ cursor: disabled ? 'not-allowed' : 'pointer' }}
      >
        <FileArchive size={24} className="mx-auto mb-2 text-[var(--color-text-sub)]" />
        <div className="text-[13px] text-[var(--color-text)]">
          {value.mode === 'folder' ? '点击或拖拽技能文件夹到这里' : '点击或拖拽 .zip 压缩包到这里'}
        </div>
        <div className="mt-1 text-[12px] text-[var(--color-text-sub)]">
          {value.mode === 'folder'
            ? '文件夹根目录必须包含 SKILL.md，前端会自动打包成 zip 上传，单包不超过 50MB。'
            : 'zip 内根目录需包含 SKILL.md。'}
        </div>
      </div>
      <input
        ref={folderRef}
        type="file"
        multiple
        className="hidden"
        // webkitdirectory / directory 是非标准属性，TS 不识别，强转 unknown 后透传。
        {...({ webkitdirectory: '', directory: '' } as unknown as Record<string, string>)}
        onChange={onFolderInput}
      />
      <input
        ref={zipRef}
        type="file"
        accept=".zip,application/zip"
        className="hidden"
        onChange={onZipInput}
      />

      {value.mode === 'folder' && value.folder.length > 0 && (
        <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] p-3">
          <div className="mb-2 flex items-center justify-between text-[12px] text-[var(--color-text-sub)]">
            <span>已选 {value.folder.length} 个文件</span>
            <button type="button" className="text-[var(--color-brand)] hover:underline" onClick={clear} disabled={disabled}>清空</button>
          </div>
          <div className="flex max-h-[140px] flex-wrap gap-1 overflow-auto">
            {value.folder.slice(0, 80).map((ent) => (
              <span
                key={ent.relPath}
                className="inline-flex items-center gap-1 rounded-full border border-[var(--color-line)] bg-[var(--color-bg)] px-2 py-0.5 text-[11px] text-[var(--color-text-sub)]"
              >
                {ent.relPath}
                <button
                  type="button"
                  className="text-[var(--color-text-sub)] hover:text-[var(--color-danger)]"
                  onClick={(e) => { e.stopPropagation(); removeFolderEntry(ent.relPath) }}
                  disabled={disabled}
                >×</button>
              </span>
            ))}
            {value.folder.length > 80 && (
              <span className="text-[11px] text-[var(--color-text-sub)]">… 余 {value.folder.length - 80} 个</span>
            )}
          </div>
        </div>
      )}
      {value.mode === 'archive' && value.archive && (
        <div className="flex items-center gap-2 rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] px-3 py-2 text-[13px]">
          <FileArchive size={16} className="text-[var(--color-brand)]" />
          <div className="flex-1 truncate">
            <div>{value.archive.name}</div>
            <div className="text-[12px] text-[var(--color-text-sub)]">{(value.archive.size / 1024 / 1024).toFixed(2)} MB</div>
          </div>
          <button type="button" className="text-[12px] text-[var(--color-brand)] hover:underline" onClick={clear} disabled={disabled}>重选</button>
        </div>
      )}
    </div>
  )
}

// IconUploader — 技能图标上传，文件选 + 预览 + 移除。
//
// value: 父级保存的 oss:// URI（提交给后端 create/patch 用）
// previewUrl: 用于即时预览的 signed URL，由后端 upload-icon 返回
// onChange(uri, preview): 上传成功 / 移除时同步两份字段
function IconUploader({
  value,
  previewUrl,
  onChange,
  disabled,
}: {
  value: string
  previewUrl: string
  onChange: (uri: string, preview: string) => void
  disabled?: boolean
}) {
  const api = useSkillAPI()
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const handleFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    e.target.value = ''
    if (!f) return
    const allowed = new Set(['image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp'])
    if (!allowed.has(f.type)) {
      setErr('不支持的图片格式（仅 PNG/JPG/GIF/WebP）')
      return
    }
    if (f.size > 1024 * 1024) {
      setErr('图标文件不能超过 1MB')
      return
    }
    setErr('')
    setBusy(true)
    try {
      const res = await api.uploadIcon(f)
      onChange(res.storage_uri, res.signed_url || res.storage_uri)
    } catch (e2) {
      setErr((e2 as Error).message || '上传失败')
    } finally {
      setBusy(false)
    }
  }

  const remove = () => onChange('', '')

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-4">
        <button
          type="button"
          className="grid h-20 w-20 shrink-0 place-items-center overflow-hidden rounded-md border border-dashed border-[var(--color-line)] bg-[var(--color-control-bg)] text-[var(--color-text-sub)] transition hover:border-[var(--color-brand-line)] hover:bg-[var(--color-brand-soft)] disabled:cursor-not-allowed disabled:opacity-60"
          onClick={() => inputRef.current?.click()}
          disabled={disabled || busy}
          title={value ? '更换图标' : '上传图标'}
        >
          {previewUrl ? (
            <img src={previewUrl} alt="技能图标" className="h-full w-full object-cover" />
          ) : (
            <Wand size={28} />
          )}
        </button>
        <div className="min-w-0">
          <input
            ref={inputRef}
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp"
            className="hidden"
            onChange={handleFile}
          />
          <button
            type="button"
            className="inline-flex items-center gap-2 text-[13px] font-medium text-[var(--color-text)] transition hover:text-[var(--color-brand)] disabled:cursor-not-allowed disabled:opacity-60"
            disabled={disabled || busy}
            onClick={() => inputRef.current?.click()}
          >
            <Upload size={14} />
            {busy ? '上传中...' : value ? '更换图标' : '点击上传图标'}
          </button>
          <div className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">
            支持 PNG / JPG / WebP，建议 512×512 像素。
          </div>
          {value && (
            <button
              type="button"
              className="mt-2 text-[12px] text-[var(--color-text-sub)] transition hover:text-[var(--color-danger)] disabled:cursor-not-allowed disabled:opacity-60"
              disabled={disabled || busy}
              onClick={remove}
            >
              移除图标
            </button>
          )}
        </div>
      </div>
      {err && <div className="text-[12px] text-[var(--color-danger)]">{err}</div>}
    </div>
  )
}

function ExampleImagesUploader({
  value,
  onChange,
  disabled,
}: {
  value: ExampleImageDraft[]
  onChange: (value: ExampleImageDraft[]) => void
  disabled?: boolean
}) {
  const api = useSkillAPI()
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const remaining = Math.max(0, 6 - value.length)

  const handleFiles = async (e: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files || [])
    e.target.value = ''
    if (files.length === 0) return
    if (remaining <= 0) {
      setErr('最多上传 6 张示例图片')
      return
    }
    const allowed = new Set(['image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp'])
    const selected = files.slice(0, remaining)
    for (const file of selected) {
      if (!allowed.has(file.type)) {
        setErr('不支持的图片格式（仅 PNG/JPG/GIF/WebP）')
        return
      }
      if (file.size > 5 * 1024 * 1024) {
        setErr('示例图片单张不能超过 5MB')
        return
      }
    }
    setErr('')
    setBusy(true)
    try {
      const uploaded: ExampleImageDraft[] = []
      for (const file of selected) {
        const res = await api.uploadExampleImage(file)
        uploaded.push({
          storageUri: res.storage_uri,
          previewUrl: res.signed_url || res.storage_uri,
          fileName: file.name,
        })
      }
      onChange([...value, ...uploaded].slice(0, 6))
    } catch (e2) {
      setErr((e2 as Error).message || '上传失败')
    } finally {
      setBusy(false)
    }
  }

  const removeAt = (idx: number) => {
    onChange(value.filter((_, i) => i !== idx))
  }

  return (
    <div className="space-y-2">
      <input
        ref={inputRef}
        type="file"
        accept="image/png,image/jpeg,image/gif,image/webp"
        multiple
        className="hidden"
        onChange={handleFiles}
      />
      <div className="flex flex-wrap gap-3">
        {value.map((item, idx) => (
          <div key={`${item.storageUri}-${idx}`} className="group relative h-24 w-24 overflow-hidden rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)]">
            <img src={item.previewUrl} alt={item.fileName || '示例图片'} className="h-full w-full object-cover" />
            <button
              type="button"
              className="absolute right-1 top-1 rounded bg-[var(--color-surface)] px-1.5 py-0.5 text-[11px] text-[var(--color-danger)] shadow-sm opacity-0 transition group-hover:opacity-100 disabled:cursor-not-allowed disabled:opacity-60"
              onClick={() => removeAt(idx)}
              disabled={disabled || busy}
            >
              移除
            </button>
          </div>
        ))}
        {remaining > 0 && (
          <button
            type="button"
            className="flex h-24 w-24 flex-col items-center justify-center gap-2 rounded-md border border-dashed border-[var(--color-line)] bg-[var(--color-control-bg)] text-[12px] text-[var(--color-text-sub)] transition hover:border-[var(--color-brand-line)] hover:bg-[var(--color-brand-soft)] disabled:cursor-not-allowed disabled:opacity-60"
            onClick={() => inputRef.current?.click()}
            disabled={disabled || busy}
          >
            <Upload size={18} />
            <span>{busy ? '上传中...' : '上传图片'}</span>
          </button>
        )}
      </div>
      {err && <div className="text-[12px] text-[var(--color-danger)]">{err}</div>}
    </div>
  )
}

function ModeBtn({
  active,
  onClick,
  disabled,
  children,
}: {
  active: boolean
  onClick: () => void
  disabled?: boolean
  children: ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`rounded-md border px-3 py-1 text-[12px] transition ${active
        ? 'border-[var(--color-brand)] bg-[var(--color-brand-bg)] text-[var(--color-brand)]'
        : 'border-[var(--color-line)] bg-[var(--color-control-bg)] text-[var(--color-text-sub)] hover:border-[var(--color-text-sub)]'} ${disabled ? 'opacity-60 cursor-not-allowed' : ''}`}
    >
      {children}
    </button>
  )
}

// ----- SKILL.md frontmatter 客户端解析（用于 CreateModal 自动填 chips） -----
//
// 用户在 PackageUploader 里选好 zip 或文件夹后，立刻在前端解析 SKILL.md
// frontmatter 中的 input_chips_schema 字段，填到 ChipListEditor。
// 用户可继续手动增删改；最终值在提交时作为 input_chips_schema_snapshot
// 写入版本快照。后端 UploadSkillPackage 会判 snapshot 非空就跳过 frontmatter
// 自动覆盖，让用户编辑结果不被吞。
//
// v0.9.1 仅支持 JSON frontmatter（与后端 ParseSkillMDFrontmatter 一致），YAML 留 v0.9.2。

async function parseSkillMetadataFromPkg(s: PkgUploadState): Promise<{ chips: ChipDraft[]; agentCompat: AgentCompatDraft } | null> {
  let mdText = ''
  if (s.mode === 'archive' && s.archive) {
    mdText = await readSkillMDFromZipFile(s.archive)
  } else if (s.mode === 'folder' && s.folder.length > 0) {
    const target = s.folder.find((e) => {
      const p = e.relPath.replace(/\\/g, '/').toLowerCase()
      return p === 'skill.md' || p.endsWith('/skill.md')
    })
    if (target) {
      mdText = await target.file.text()
    }
  }
  if (!mdText) return null
  const fm = extractFrontmatter(mdText)
  if (!fm) return null
  let parsed: unknown
  try { parsed = JSON.parse(fm) } catch { return null }
  if (!parsed || typeof parsed !== 'object') return null
  const chipsRaw = (parsed as Record<string, unknown>).input_chips_schema
  const agentCompatRaw = (parsed as Record<string, unknown>).agent_compat
  return {
    chips: Array.isArray(chipsRaw) ? deserializeChips(chipsRaw) : [],
    agentCompat: deserializeAgentCompat(agentCompatRaw),
  }
}

async function readSkillMDFromZipFile(zipFile: File): Promise<string> {
  const zip = await JSZip.loadAsync(await zipFile.arrayBuffer())
  for (const path of Object.keys(zip.files)) {
    const lower = path.toLowerCase()
    const base = lower.split('/').pop() || ''
    if (base !== 'skill.md') continue
    const slashes = (lower.match(/\//g) || []).length
    if (slashes > 1) continue // 仅根 + 1 层子目录
    const f = zip.files[path]
    if (f.dir) continue
    return await f.async('string')
  }
  return ''
}

function extractFrontmatter(md: string): string | null {
  const trimmed = md.replace(/^\uFEFF/, '').replace(/^[ \t\r\n]+/, '')
  if (!trimmed.startsWith('---')) return null
  const rest = trimmed.slice(3).replace(/^[\r\n]+/, '')
  const idx = rest.indexOf('\n---')
  if (idx < 0) return null
  return rest.slice(0, idx).trim()
}

// 反序列化后端返回 / SKILL.md 解析出的 chip 数组到 ChipDraft[]，兼容字段松散度。
function deserializeChips(raw: unknown[]): ChipDraft[] {
  const out: ChipDraft[] = []
  for (const r of raw) {
    if (!r || typeof r !== 'object') continue
    const o = r as Record<string, unknown>
    const key = String(o.key || o.id || '').trim()
    if (!key) continue
    const kindRaw = String(o.kind || o.type || 'text-inline')
    const kind: ChipKind = (Object.keys(CHIP_KIND_LABEL) as ChipKind[]).includes(kindRaw as ChipKind)
      ? (kindRaw as ChipKind)
      : 'text-inline'
    const draft: ChipDraft = {
      key,
      label: String(o.label || key),
      kind,
      required: !!o.required,
    }
    if (typeof o.default === 'string' || typeof o.default === 'number' || typeof o.default === 'boolean') {
      draft.default = String(o.default)
    }
    if (typeof o.placeholder === 'string') draft.placeholder = o.placeholder
    if (typeof o.description === 'string') draft.description = o.description
    if ((kind === 'enum-dropdown' || kind === 'enum-multi') && Array.isArray(o.options)) {
      draft.options = o.options
        .filter((x) => x && typeof x === 'object')
        .map((x) => {
          const xo = x as Record<string, unknown>
          return {
            value: String(xo.value ?? ''),
            label: String(xo.label ?? xo.value ?? ''),
          }
        })
    }
    if (kind === 'number') {
      if (typeof o.min === 'number') draft.min = o.min
      if (typeof o.max === 'number') draft.max = o.max
      if (typeof o.step === 'number') draft.step = o.step
    }
    if (kind === 'file-upload' || kind === 'image-upload') {
      const fc = o.file_constraint
      if (fc && typeof fc === 'object') {
        const max = (fc as Record<string, unknown>).max_size_bytes
        if (typeof max === 'number' && max > 0) draft.max_size_mb = Math.round(max / 1024 / 1024)
      }
    }
    out.push(draft)
  }
  return out
}
