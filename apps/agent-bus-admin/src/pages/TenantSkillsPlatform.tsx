// /tenant/skills/platform · 租户视角的平台技能列表。
//
// 对照 F03 §1.5: "平台技能广场（只读浏览 + 禁用开关）" + "租户偏好（force_on / force_off 设置）"。
// 本页把"启用/禁用"和"默认偏好"合并在同一张表里, 每行直接操作, 不再切 Tab。
//
// 列设计 (中文化):
//   图标 / 名称 / Code / 描述 / 分类 / 类型 / 来源 / 费用 / 装配数 /
//   更新时间 / 本租户启用(Switch) / 默认装配(Select 三档) / 操作
//
// 启用 Switch:
//   - ON  = 未禁用 (tenant_disabled=false), 客户端可见可用
//   - OFF = 已禁用 (tenant_disabled=true),  客户端不可见 (chip rail/广场/消息校验全方位拒绝)
//   - 关时弹小对话框收"禁用原因" (选填); 开时直接 DELETE /disable
//
// 默认偏好 Select:
//   跟随默认 = 清除偏好 (DELETE)
//   默认装上 = force_on  (新建数字员工时自动装配)
//   默认不装 = force_off (新建数字员工时不装, 但管理员可手动加)
//
// 鉴权 (后端):
//   - GET /tenant/skills         需要 tenant.skill.read
//   - POST/DELETE /disable       需要 tenant.skill.enable
//   - PUT/DELETE /skill-preferences/{uuid}  需要 tenant.skill.update

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Eye, Wand } from 'lucide-react'
import { TenantOwnSkills, TenantSkills, type SkillCategory, type TenantSkill } from '../lib/api'
import {
  Button, ConfirmDialog, DataTable, DrawerShell, EmptyState, FormField, InlineAlert, Input,
  PageHeader, Pagination, SearchInput, Select, Switch, Toolbar, stickyLeftTdCls, stickyRightTdCls,
} from '../components/ui'
import {
  SKILL_KIND_LABEL, SKILL_PREFERENCE_OPTIONS,
  labelOrCode, type SkillPreferenceValue,
} from '../lib/skillLabels'
import { notifyError, notifyOk } from '../lib/toast'
import { humanizeError } from '../lib/errorMessages'

type KindFilter = '' | 'agent' | 'builtin'
type StatusFilter = '' | 'enabled' | 'disabled'

const SKILL_SOURCE_LABEL: Record<string, string> = {
  internal: '平台内置',
  open_source: '开源',
  third_party: '第三方',
}

function billingTypeLabel(value?: string) {
  return value === 'paid' ? '付费' : '免费'
}

function fmtDate(s?: string): string {
  if (!s) return '-'
  const d = new Date(s)
  if (Number.isNaN(d.getTime())) return s
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function TenantSkillsPlatformPage() {
  const [items, setItems] = useState<TenantSkill[]>([])
  const [categories, setCategories] = useState<SkillCategory[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)

  // 筛选
  const [q, setQ] = useState('')
  const [kindFilter, setKindFilter] = useState<KindFilter>('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('')

  // 分页
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)

  // "禁用 + 收原因" 二次确认弹窗
  const [disabling, setDisabling] = useState<TenantSkill | null>(null)
  const [disableReason, setDisableReason] = useState('')
  const [detailSkill, setDetailSkill] = useState<TenantSkill | null>(null)

  const refresh = useCallback(() => setTick((t) => t + 1), [])

  useEffect(() => {
    let cancelled = false
    TenantOwnSkills.listCategories({ status: 'active', limit: 200, offset: 0 })
      .then((r) => {
        if (!cancelled) setCategories(r.items || [])
      })
      .catch(() => {
        if (!cancelled) setCategories([])
      })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 拉新页前显式置 loading, 防上一页缓存闪
    setLoading(true)
    TenantSkills.list({
      q: q || undefined,
      kind: kindFilter || undefined,
      // status 是技能本身的发布状态 (active/draft/archived), 不是 tenant 禁用维度;
      // 租户禁用走前端 client-side 过滤 (tenant_disabled), 比再发一次请求更稳定。
      limit: pageSize,
      offset: (page - 1) * pageSize,
    })
      .then((r) => {
        if (cancelled) return
        setItems(r.items || [])
        setTotal(r.total || 0)
        setErr('')
      })
      .catch((e: Error) => { if (!cancelled) setErr(humanizeError(e)) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick, q, kindFilter, page, pageSize])

  // 只显示 scope_kind=platform; 租户自有技能在另一页。
  // 按租户禁用维度做 client-side 过滤 (状态筛选: 启用/禁用)。
  const filtered = useMemo(() => {
    const onlyPlatform = items.filter((s) => s.scope_kind === 'platform')
    if (statusFilter === 'enabled') return onlyPlatform.filter((s) => !s.tenant_disabled)
    if (statusFilter === 'disabled') return onlyPlatform.filter((s) => s.tenant_disabled)
    return onlyPlatform
  }, [items, statusFilter])

  const hasFilter = !!(q || kindFilter || statusFilter)
  const categoryMap = useMemo(() => new Map(categories.map((c) => [c.id, c.name])), [categories])

  // —— 启用/禁用 ——
  const onToggleEnable = async (skill: TenantSkill, enable: boolean) => {
    if (enable) {
      // 启用: 直接 DELETE /disable
      try {
        await TenantSkills.enable(skill.uuid)
        refresh()
        notifyOk(`已启用「${skill.name}」`)
      } catch (e) {
        notifyError(humanizeError(e))
      }
    } else {
      // 禁用: 弹弹窗收原因
      setDisabling(skill)
      setDisableReason('')
    }
  }

  const confirmDisable = async () => {
    if (!disabling) return
    try {
      await TenantSkills.disable(disabling.uuid, { disable_reason: disableReason || undefined })
      refresh()
      notifyOk(`已禁用「${disabling.name}」`)
      setDisabling(null)
    } catch (e) {
      notifyError(humanizeError(e))
    }
  }

  // —— 偏好 Select ——
  const onChangePreference = async (skill: TenantSkill, next: SkillPreferenceValue) => {
    try {
      if (!next) {
        await TenantSkills.clearPreference(skill.uuid)
        notifyOk(`已清除「${skill.name}」的偏好`)
      } else {
        await TenantSkills.setPreference(skill.uuid, { behavior: next })
        const label = next === 'force_on' ? '默认装上' : '默认不装'
        notifyOk(`「${skill.name}」偏好已设为「${label}」`)
      }
      refresh()
    } catch (e) {
      notifyError(humanizeError(e))
    }
  }

  return (
    <div>
      <PageHeader
        title="平台技能"
        subtitle="查看平台上架的技能, 控制本租户的启用状态和默认装配偏好。禁用后客户端不再可见; 偏好仅影响本租户新建数字员工时的默认装配。"
      />

      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => { setQ(v); setPage(1) }}
            placeholder="按名称 / Code / 描述搜索"
          />
        }
        filters={
          <>
            <div className="w-[140px]">
              <Select value={kindFilter} onChange={(e) => { setKindFilter(e.target.value as KindFilter); setPage(1) }}>
                <option value="">全部类型</option>
                <option value="agent">Agent 技能</option>
                <option value="builtin">客户端原生</option>
              </Select>
            </div>
            <div className="w-[140px]">
              <Select value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value as StatusFilter); setPage(1) }}>
                <option value="">全部状态</option>
                <option value="enabled">本租户启用</option>
                <option value="disabled">本租户禁用</option>
              </Select>
            </div>
          </>
        }
        summary={<>共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{filtered.length}</span> 个技能</>}
      />

      {err && <div className="mb-4"><InlineAlert>{err}</InlineAlert></div>}

      <DataTable
        headers={['图标', '名称', 'Code', '描述', '分类', '类型', '来源', '费用', '装配数', '更新时间', '本租户启用', '默认装配', '操作']}
        stickyFirstCol
        stickyLastCol
        loading={loading ? <EmptyState title="正在加载技能" description="正在读取平台上架的技能列表。" /> : undefined}
        empty={!loading && filtered.length === 0 ? (
          <EmptyState
            icon={<Wand size={22} />}
            title={hasFilter ? '没有匹配的技能' : '暂无平台技能'}
            description={hasFilter ? '调整搜索词或筛选条件后再试。' : '等待平台管理员上架技能后, 本页会自动展示。'}
            action={hasFilter ? <Button variant="secondary" onClick={() => { setQ(''); setKindFilter(''); setStatusFilter('') }}>清空筛选</Button> : undefined}
          />
        ) : undefined}
      >
        {!loading && filtered.map((skill) => {
          const categoryName = skill.category_id ? categoryMap.get(skill.category_id) : undefined
          return (
            <tr key={skill.uuid} className="group transition hover:bg-[var(--color-bg-sub)]">
              <td className={`${stickyLeftTdCls} px-4 py-3 align-middle`}>
                {skill.icon_url ? (
                  <img src={skill.icon_url} alt="" className="h-8 w-8 rounded-md border border-[var(--color-line)] object-cover" />
                ) : (
                  <div className="grid h-8 w-8 place-items-center rounded-md bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
                    <Wand size={14} />
                  </div>
                )}
              </td>
              <td className="min-w-[160px] px-4 py-3 align-middle font-medium text-[var(--color-text)]" title={skill.name || '-'}>
                <span className="block truncate">{skill.name || '-'}</span>
              </td>
              <td className="min-w-[180px] px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-sub)]" title={skill.code}>
                <span className="block truncate">{skill.code}</span>
              </td>
              <td className="min-w-[320px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]" title={skill.description || '-'}>
                <span className="block truncate">{skill.description || '-'}</span>
              </td>
              <td className="min-w-[120px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]">
                {categoryName || '-'}
              </td>
              <td className="min-w-[116px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]">
                {labelOrCode(SKILL_KIND_LABEL, skill.kind)}
              </td>
              <td className="min-w-[100px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]">
                {labelOrCode(SKILL_SOURCE_LABEL, skill.source)}
              </td>
              <td className="min-w-[88px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]">
                {billingTypeLabel(skill.billing_type)}
              </td>
              <td className="min-w-[92px] px-4 py-3 align-middle tabular-nums text-[13px] text-[var(--color-text-sub)]">
                {skill.install_count ?? 0}
              </td>
              <td className="min-w-[116px] px-4 py-3 align-middle text-[13px] text-[var(--color-text-sub)]">
                {fmtDate(skill.updated_at)}
              </td>
              <td className="min-w-[116px] px-4 py-3 align-middle">
                <div className="flex items-center gap-2">
                  <Switch
                    checked={!skill.tenant_disabled}
                    ariaLabel={skill.tenant_disabled ? '点击启用此技能' : '点击禁用此技能'}
                    onChange={(next) => onToggleEnable(skill, next)}
                  />
                  {skill.tenant_disabled && skill.disable_reason && (
                    <span
                      title={`禁用原因: ${skill.disable_reason}`}
                      className="inline-block h-2 w-2 rounded-full bg-[var(--color-warn)]"
                      aria-label="有禁用原因记录"
                    />
                  )}
                </div>
              </td>
              <td className="min-w-[148px] px-4 py-3 align-middle">
                <Select
                  value={skill.tenant_preference || ''}
                  disabled={skill.tenant_disabled}
                  onChange={(e) => onChangePreference(skill, e.target.value as SkillPreferenceValue)}
                >
                  {SKILL_PREFERENCE_OPTIONS.map((opt) => (
                    <option key={opt.value || 'none'} value={opt.value} title={opt.hint}>{opt.label}</option>
                  ))}
                </Select>
              </td>
              <td className={`${stickyRightTdCls} px-4 py-3 align-middle`}>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  title="查看技能详情"
                  onClick={() => setDetailSkill(skill)}
                >
                  <Eye size={14} />
                  查看
                </Button>
              </td>
            </tr>
          )
        })}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {/* 禁用确认 + 收原因 */}
      {disabling && (
        <ConfirmDialog
          title="禁用平台技能"
          description={<>确认禁用「<span className="font-medium text-[var(--color-text)]">{disabling.name}</span>」?<br />禁用后客户端 chip rail / 广场都不再展示, 已装配的数据保留, 解禁后自动恢复。</>}
          confirmLabel="禁用"
          tone="danger"
          onClose={() => setDisabling(null)}
          onConfirm={confirmDisable}
        >
          <FormField label="禁用原因 (选填)" hint="管理员审计用, 后续解禁时可以看到">
            <Input
              value={disableReason}
              onChange={(e) => setDisableReason(e.target.value)}
              placeholder="例如: 合规审核中, 暂不开放"
            />
          </FormField>
        </ConfirmDialog>
      )}

      {detailSkill && (
        <SkillDetailDrawer
          skill={detailSkill}
          categoryName={detailSkill.category_id ? categoryMap.get(detailSkill.category_id) : undefined}
          onClose={() => setDetailSkill(null)}
        />
      )}
    </div>
  )
}

function SkillDetailDrawer({
  skill,
  categoryName,
  onClose,
}: {
  skill: TenantSkill
  categoryName?: string
  onClose: () => void
}) {
  return (
    <DrawerShell
      title={skill.name || '技能详情'}
      subtitle="平台技能在本租户下的展示信息与治理状态。"
      icon={<Wand size={16} />}
      onClose={onClose}
      width="md"
    >
      <div className="space-y-6">
        <div>
          <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">基础信息</div>
          <div className="grid grid-cols-2 gap-x-6 gap-y-4">
            <DetailField label="名称" value={skill.name || '-'} />
            <DetailField label="Code" value={skill.code || '-'} mono />
            <DetailField label="分类" value={categoryName || '-'} />
            <DetailField label="类型" value={labelOrCode(SKILL_KIND_LABEL, skill.kind)} />
            <DetailField label="来源" value={labelOrCode(SKILL_SOURCE_LABEL, skill.source)} />
            <DetailField label="费用" value={billingTypeLabel(skill.billing_type)} />
            <DetailField label="装配数" value={String(skill.install_count ?? 0)} />
            <DetailField label="更新时间" value={fmtDate(skill.updated_at)} />
          </div>
        </div>

        <div>
          <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">能力说明</div>
          <p className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-2.5 text-[13px] leading-relaxed text-[var(--color-text-sub)]">
            {skill.description || '暂无描述'}
          </p>
        </div>

        <div>
          <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">租户配置</div>
          <div className="grid grid-cols-2 gap-x-6 gap-y-4">
            <DetailField label="本租户启用" value={skill.tenant_disabled ? '禁用' : '启用'} />
            <DetailField
              label="默认装配"
              value={SKILL_PREFERENCE_OPTIONS.find((opt) => opt.value === (skill.tenant_preference || ''))?.label || '-'}
            />
            <DetailField label="禁用原因" value={skill.tenant_disabled ? (skill.disable_reason || '-') : '-'} wide />
          </div>
        </div>
      </div>
    </DrawerShell>
  )
}

function DetailField({
  label,
  value,
  mono,
  wide,
}: {
  label: string
  value: string
  mono?: boolean
  wide?: boolean
}) {
  return (
    <div className={wide ? 'col-span-2 min-w-0' : 'min-w-0'}>
      <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
      <div className={`mt-1 truncate text-[13px] text-[var(--color-text)] ${mono ? 'font-mono' : ''}`} title={value}>
        {value}
      </div>
    </div>
  )
}
