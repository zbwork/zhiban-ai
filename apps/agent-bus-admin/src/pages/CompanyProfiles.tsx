// 企业档案（contracts/admin-startup-agent-api.md §2.7）。
// 企业主档与用户、注册申请、代账工单均通过显式关系维护；不按账号或时间猜测关联。
import { useCallback, useEffect, useState } from 'react'
import { BadgeCheck, Building2, Link2, RefreshCw } from 'lucide-react'

import {
  Auth,
  CompanyProfiles,
  type CompanyProfileBusinessStatus,
  type CompanyProfileDetail,
  type CompanyProfileItem,
  type CompanyProfilePatch,
  type CompanyProfileRelated,
  type CompanyProfileTaxpayerType,
  type CompanyProfileVerificationStatus,
} from '../lib/api'
import { notifyOk } from '../lib/toast'
import { CaseBadge as Badge, CaseField as Field } from '../components/caseTimeline'
import { CASE_TONE as TONE } from '../components/caseTone'
import {
  Button,
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
  RowActions,
  SearchInput,
  Select,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'

type DrawerMode = 'detail' | 'edit'

type ProfileFormValue = {
  company_name: string
  credit_code: string
  legal_representative: string
  established_date: string
  registered_address: string
  taxpayer_type: CompanyProfileTaxpayerType
  business_status: CompanyProfileBusinessStatus
  verification_status: CompanyProfileVerificationStatus
}

function sourceInfo(source: string): { label: string; tone: string } {
  switch (source) {
    case 'registration': return { label: '注册办结', tone: TONE.success }
    case 'self_reported': return { label: '用户录入', tone: TONE.info }
    case 'bookkeeping_confirmed': return { label: '用户确认', tone: TONE.gray }
    default: return { label: source || '未知来源', tone: TONE.gray }
  }
}

function profileStatusInfo(item: CompanyProfileItem): { label: string; tone: string } {
  if (item.needs_completion) return { label: '待补全', tone: TONE.warn }
  switch (item.verification_status) {
    case 'verified': return { label: '已核验', tone: TONE.success }
    case 'pending': return { label: '用户提交·待核验', tone: TONE.info }
    case 'rejected': return { label: '核验未通过', tone: TONE.danger }
    default: return { label: '待核验', tone: TONE.gray }
  }
}

const RELATED_KIND_LABELS: Record<string, string> = {
  company_reg: '注册申请',
  bookkeeping: '代账工单',
}

const RELATED_STATUS_LABELS: Record<string, string> = {
  active: '进行中',
  completed: '已完成',
  cancelled: '已取消',
  failed: '已驳回',
}

const TAXPAYER_LABELS: Record<CompanyProfileTaxpayerType, string> = {
  small_scale: '小规模纳税人',
  general: '一般纳税人',
  unknown: '待确认',
}

const BUSINESS_STATUS_LABELS: Record<CompanyProfileBusinessStatus, string> = {
  active: '存续',
  deregistered: '已注销',
  unknown: '待确认',
}

const VERIFICATION_LABELS: Record<CompanyProfileVerificationStatus, string> = {
  unverified: '待核验',
  pending: '用户提交·待核验',
  verified: '已核验',
  rejected: '核验未通过',
}

function relatedStatusTone(status: string): string {
  switch (status) {
    case 'active': return TONE.info
    case 'completed': return TONE.success
    case 'failed': return TONE.danger
    default: return TONE.gray
  }
}

function fmtTime(iso: string): string {
  return iso ? iso.slice(0, 16).replace('T', ' ') : '—'
}

function formValueOf(detail: CompanyProfileDetail): ProfileFormValue {
  return {
    company_name: detail.company_name || '',
    credit_code: detail.credit_code || '',
    legal_representative: detail.legal_representative || '',
    established_date: detail.established_date || '',
    registered_address: detail.registered_address || '',
    taxpayer_type: detail.taxpayer_type || 'unknown',
    business_status: detail.business_status || 'unknown',
    verification_status: detail.verification_status || 'unverified',
  }
}

function changedPatch(initial: ProfileFormValue, current: ProfileFormValue): CompanyProfilePatch {
  const patch: CompanyProfilePatch = {}
  if (initial.company_name !== current.company_name) patch.company_name = current.company_name.trim()
  if (initial.credit_code !== current.credit_code) patch.credit_code = current.credit_code.trim()
  if (initial.legal_representative !== current.legal_representative) {
    patch.legal_representative = current.legal_representative.trim()
  }
  if (initial.established_date !== current.established_date) patch.established_date = current.established_date
  if (initial.registered_address !== current.registered_address) {
    patch.registered_address = current.registered_address.trim()
  }
  if (initial.taxpayer_type !== current.taxpayer_type) patch.taxpayer_type = current.taxpayer_type
  if (initial.business_status !== current.business_status) patch.business_status = current.business_status
  if (initial.verification_status !== current.verification_status) {
    patch.verification_status = current.verification_status
  }
  return patch
}

export function CompanyProfilesPage() {
  const [items, setItems] = useState<CompanyProfileItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [q, setQ] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [drawer, setDrawer] = useState<{ detail: CompanyProfileDetail; mode: DrawerMode } | null>(null)
  const [linking, setLinking] = useState<CompanyProfileDetail | null>(null)
  const [canOperate, setCanOperate] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    Auth.permissions()
      .then((codes) => {
        if (!cancelled) setCanOperate((codes ?? []).includes('platform.startup_agent.operate'))
      })
      .catch(() => { if (!cancelled) setCanOperate(false) })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    let cancelled = false
    CompanyProfiles.list({ q: q.trim() || undefined, page, page_size: pageSize })
      .then((res) => {
        if (cancelled) return
        setItems(res.items ?? [])
        setTotal(res.total ?? 0)
        setError('')
      })
      .catch((e: Error) => {
        if (!cancelled) setError(e.message || '企业档案加载失败，请稍后重试')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => { cancelled = true }
  }, [q, page, pageSize, tick])

  const refresh = useCallback(() => {
    setLoading(true)
    setTick((value) => value + 1)
  }, [])
  const resetPage = (fn: () => void) => {
    setLoading(true)
    setPage(1)
    fn()
  }

  const openProfile = useCallback(async (item: CompanyProfileItem, mode: DrawerMode) => {
    try {
      setError('')
      const detail = await CompanyProfiles.get(item.id, item.tenant_uuid)
      setDrawer({ detail, mode })
    } catch (e) {
      setError(e instanceof Error ? e.message : '企业档案详情加载失败，请稍后重试')
    }
  }, [])

  const finishMutation = useCallback(() => {
    setDrawer(null)
    setLinking(null)
    refresh()
  }, [refresh])

  return (
    <div>
      <PageHeader
        title="企业档案"
        subtitle="集中维护用户已有企业、工商核验状态及其注册申请和代账工单关系。所有关联均按明确对象写入，不会按账号或创建时间自动匹配。"
      />
      <Toolbar
        search={<SearchInput value={q} onChange={(value) => resetPage(() => setQ(value))} placeholder="搜索企业名 / 信用代码 / 注册单号" />}
        summary={<>共 {total} 条</>}
        actions={<Button variant="secondary" onClick={refresh}><RefreshCw size={14} /> 刷新</Button>}
      />
      {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={['企业名称', '统一社会信用代码', '租户', '档案状态', '来源', '成员数', '代账工单数', '更新时间', '操作']}
        loading={loading ? <div className="px-4 py-8 text-center text-[var(--color-text-sub)]">正在加载企业档案</div> : undefined}
        empty={!loading && items.length === 0 ? (
          <EmptyState title="暂无企业档案" description="用户在工作台录入已有企业，或注册申请出照后，企业档案会出现在这里。" />
        ) : undefined}
      >
        {items.map((item) => {
          const source = sourceInfo(item.source)
          const status = profileStatusInfo(item)
          return (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <td className={`w-[220px] min-w-[220px] max-w-[220px] px-4 py-3 ${stickyLeftTdCls}`}>
                <div className="truncate font-medium text-[var(--color-text)]" title={item.company_name}>
                  {item.company_name || <span className="text-[var(--color-text-mute)]">待补全企业名称</span>}
                </div>
              </td>
              <td className="min-w-[188px] whitespace-nowrap px-4 py-3 font-mono text-[13px] text-[var(--color-text)]">
                {item.credit_code || <span className="text-[var(--color-text-mute)]">—</span>}
              </td>
              <td className="min-w-[160px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]" title={item.tenant_name}>
                <div className="max-w-[200px] truncate">{item.tenant_name}</div>
              </td>
              <td className="min-w-[142px] whitespace-nowrap px-4 py-3"><Badge className={status.tone}>{status.label}</Badge></td>
              <td className="min-w-[96px] whitespace-nowrap px-4 py-3"><Badge className={source.tone}>{source.label}</Badge></td>
              <td className="min-w-[88px] whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text)]">{item.member_count ?? 0}</td>
              <td className="min-w-[108px] whitespace-nowrap px-4 py-3 tabular-nums text-[var(--color-text)]">{item.bookkeeping_count ?? 0}</td>
              <td className="min-w-[148px] whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{fmtTime(item.updated_at)}</td>
              <td className={`min-w-[168px] whitespace-nowrap px-4 py-3 ${stickyRightTdCls}`}>
                <RowActions
                  extras={(
                    <Button variant="ghost" size="sm" onClick={() => void openProfile(item, 'detail')}>
                      详情
                    </Button>
                  )}
                  onEdit={canOperate ? () => void openProfile(item, 'edit') : undefined}
                />
              </td>
            </tr>
          )
        })}
      </DataTable>
      <Pagination
        page={page}
        pageSize={pageSize}
        total={total}
        onPageChange={(nextPage) => { setLoading(true); setPage(nextPage) }}
        onPageSizeChange={(size) => resetPage(() => setPageSize(size))}
      />

      {drawer && (
        <ProfileDrawer
          detail={drawer.detail}
          mode={drawer.mode}
          canOperate={canOperate}
          onModeChange={(mode) => setDrawer({ detail: drawer.detail, mode })}
          onLink={() => setLinking(drawer.detail)}
          onClose={() => setDrawer(null)}
          onSaved={finishMutation}
        />
      )}
      {linking && (
        <LinkBookkeepingDialog
          detail={linking}
          onClose={() => setLinking(null)}
          onDone={finishMutation}
        />
      )}
    </div>
  )
}

function ProfileDrawer({ detail, mode, canOperate, onModeChange, onLink, onClose, onSaved }: {
  detail: CompanyProfileDetail
  mode: DrawerMode
  canOperate: boolean
  onModeChange: (mode: DrawerMode) => void
  onLink: () => void
  onClose: () => void
  onSaved: () => void
}) {
  const initial = formValueOf(detail)
  const [form, setForm] = useState<ProfileFormValue>(initial)
  const [saving, setSaving] = useState(false)
  const [formError, setFormError] = useState('')
  const source = sourceInfo(detail.source)
  const status = profileStatusInfo(detail)

  const enterEdit = () => {
    setForm(initial)
    setFormError('')
    onModeChange('edit')
  }
  const cancelEdit = () => {
    setForm(initial)
    setFormError('')
    onModeChange('detail')
  }

  const save = async () => {
    if (!form.company_name.trim()) {
      setFormError('企业名称不能为空')
      return
    }
    const patch = changedPatch(initial, form)
    if (Object.keys(patch).length === 0) {
      setFormError('企业资料没有变化')
      return
    }
    setSaving(true)
    setFormError('')
    try {
      await CompanyProfiles.update(detail.id, detail.tenant_uuid, patch)
      notifyOk('企业资料已保存')
      onSaved()
    } catch (e) {
      setFormError(e instanceof Error ? e.message : '企业资料保存失败，请稍后重试')
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      title={mode === 'edit' ? `编辑企业 · ${detail.company_name || detail.id.slice(0, 8)}` : detail.company_name || '待补全企业档案'}
      subtitle={`租户 ${detail.tenant_name} · 建档于 ${fmtTime(detail.created_at)}`}
      icon={mode === 'edit' ? <Building2 size={16} /> : <BadgeCheck size={16} />}
      onClose={onClose}
      width="lg"
      footer={mode === 'edit' ? (
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={cancelEdit} disabled={saving}>取消</Button>
          <Button variant="primary" onClick={() => void save()} disabled={saving}>{saving ? '保存中…' : '保存'}</Button>
        </div>
      ) : (
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>关闭</Button>
          {canOperate && <Button variant="secondary" onClick={onLink}><Link2 size={14} /> 关联代账工单</Button>}
          {canOperate && <Button variant="primary" onClick={enterEdit}>编辑企业资料</Button>}
        </div>
      )}
    >
      <div className="space-y-4">
        {mode === 'edit' && formError && <InlineAlert tone="danger">{formError}</InlineAlert>}
        {mode === 'edit' ? (
          <ProfileForm value={form} onChange={setForm} />
        ) : (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <Badge className={status.tone}>{status.label}</Badge>
              <Badge className={source.tone}>{source.label}</Badge>
              {detail.needs_completion && (
                <span className="text-[12px] text-[var(--color-text-mute)]">企业名称或统一社会信用代码尚未补全</span>
              )}
            </div>

            <FormSection title="企业信息" description="企业资料来自用户工作台录入、注册出照或平台运营核验。">
              <div className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
                <Field label="企业名称" value={detail.company_name} />
                <Field label="统一社会信用代码" value={detail.credit_code} />
                <Field label="法定代表人" value={detail.legal_representative} />
                <Field label="成立日期" value={detail.established_date} />
                <Field label="纳税人类型" value={TAXPAYER_LABELS[detail.taxpayer_type] ?? detail.taxpayer_type} />
                <Field label="经营状态" value={BUSINESS_STATUS_LABELS[detail.business_status] ?? detail.business_status} />
                <Field label="核验状态" value={VERIFICATION_LABELS[detail.verification_status] ?? detail.verification_status} />
                <Field label="注册地址" value={detail.registered_address} span />
                <Field label="开户银行" value={detail.bank_name} />
                <Field label="对公账号" value={detail.bank_account} />
                <Field label="关联注册单号" value={detail.reg_business_no} />
                <Field label="出照时间" value={fmtTime(detail.licensed_at)} />
              </div>
            </FormSection>

            <FormSection title="企业成员" description={`共 ${detail.member_count ?? 0} 个显式成员关系；默认企业只对当前成员生效。`}>
              {(detail.members ?? []).length === 0 ? (
                <div className="text-[13px] text-[var(--color-text-mute)]">暂无企业成员</div>
              ) : (
                <div className="space-y-2">
                  {detail.members.map((member) => (
                    <div key={member.account_uuid} className="flex items-center gap-3 rounded-md border border-[var(--color-line)] px-3 py-2">
                      <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-[var(--color-text)]" title={member.account_uuid}>{member.account_uuid}</span>
                      <span className="text-[12px] text-[var(--color-text-sub)]">{member.role === 'owner' ? '企业负责人' : member.role}</span>
                      {member.is_primary && <Badge className={TONE.info}>默认企业</Badge>}
                    </div>
                  ))}
                </div>
              )}
            </FormSection>

            <FormSection title="关联记录" description="只展示明确保存了企业档案 ID 的注册申请和代账工单。">
              {(detail.related ?? []).length === 0 ? (
                <div className="text-[13px] text-[var(--color-text-mute)]">暂无关联记录</div>
              ) : (
                <div className="space-y-2">
                  {detail.related.map((related: CompanyProfileRelated) => (
                    <div key={related.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md border border-[var(--color-line)] px-3 py-2">
                      <span className="text-[13px] text-[var(--color-text-sub)]">{RELATED_KIND_LABELS[related.kind] ?? related.kind}</span>
                      <span className="font-medium text-[var(--color-brand)]">{related.business_no || related.id.slice(0, 8)}</span>
                      <Badge className={relatedStatusTone(related.status)}>{RELATED_STATUS_LABELS[related.status] ?? related.status}</Badge>
                      <span className="ml-auto text-[12px] text-[var(--color-text-mute)]">{fmtTime(related.created_at)}</span>
                    </div>
                  ))}
                </div>
              )}
            </FormSection>
          </>
        )}
      </div>
    </DrawerShell>
  )
}

function ProfileForm({ value, onChange }: {
  value: ProfileFormValue
  onChange: (value: ProfileFormValue) => void
}) {
  const set = <K extends keyof ProfileFormValue>(key: K, next: ProfileFormValue[K]) => {
    onChange({ ...value, [key]: next })
  }
  return (
    <FormSection title="企业资料" description="信用代码保存时会自动去除空格并转为大写；同租户重复代码会拒绝保存。">
      <div className="grid gap-4 sm:grid-cols-2">
        <FormField label="企业名称">
          <Input value={value.company_name} onChange={(event) => set('company_name', event.target.value)} placeholder="请输入企业全称" />
        </FormField>
        <FormField label="统一社会信用代码">
          <Input value={value.credit_code} onChange={(event) => set('credit_code', event.target.value)} placeholder="18 位统一社会信用代码" />
        </FormField>
        <FormField label="法定代表人">
          <Input value={value.legal_representative} onChange={(event) => set('legal_representative', event.target.value)} placeholder="可选" />
        </FormField>
        <FormField label="成立日期">
          <Input type="date" value={value.established_date} onChange={(event) => set('established_date', event.target.value)} />
        </FormField>
        <FormField label="纳税人类型" as="div">
          <Select value={value.taxpayer_type} onChange={(event) => set('taxpayer_type', event.target.value as CompanyProfileTaxpayerType)}>
            <option value="unknown">待确认</option>
            <option value="small_scale">小规模纳税人</option>
            <option value="general">一般纳税人</option>
          </Select>
        </FormField>
        <FormField label="经营状态" as="div">
          <Select value={value.business_status} onChange={(event) => set('business_status', event.target.value as CompanyProfileBusinessStatus)}>
            <option value="unknown">待确认</option>
            <option value="active">存续</option>
            <option value="deregistered">已注销</option>
          </Select>
        </FormField>
        <FormField label="核验状态" as="div">
          <Select value={value.verification_status} onChange={(event) => set('verification_status', event.target.value as CompanyProfileVerificationStatus)}>
            <option value="unverified">待核验</option>
            <option value="pending">用户提交·待核验</option>
            <option value="verified">已核验</option>
            <option value="rejected">核验未通过</option>
          </Select>
        </FormField>
        <div className="sm:col-span-2">
          <FormField label="注册地址">
            <Input value={value.registered_address} onChange={(event) => set('registered_address', event.target.value)} placeholder="可选" />
          </FormField>
        </div>
      </div>
    </FormSection>
  )
}

function LinkBookkeepingDialog({ detail, onClose, onDone }: {
  detail: CompanyProfileDetail
  onClose: () => void
  onDone: () => void
}) {
  const [caseID, setCaseID] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')

  const submit = async () => {
    if (!caseID.trim()) {
      setError('请输入代账工单 ID')
      return
    }
    setSubmitting(true)
    setError('')
    try {
      await CompanyProfiles.linkBookkeeping(detail.id, detail.tenant_uuid, caseID.trim())
      notifyOk('代账工单已关联')
      onDone()
    } catch (e) {
      setError(e instanceof Error ? e.message : '代账工单关联失败，请稍后重试')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <DialogShell
      title="关联代账工单"
      subtitle={`企业 ${detail.company_name || detail.id.slice(0, 8)} · ${detail.tenant_name}`}
      icon={<Link2 size={16} />}
      onClose={onClose}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={submitting}>取消</Button>
          <Button variant="primary" onClick={() => void submit()} disabled={submitting}>{submitting ? '关联中…' : '确认关联'}</Button>
        </div>
      )}
    >
      <div className="space-y-3">
        <InlineAlert tone="info">请填写明确的代账工单 ID。系统不会按账号、单号前缀或创建时间自动选择工单。</InlineAlert>
        <FormField label="代账工单 ID" hint="可从代账工单详情复制完整 ID。">
          <Input value={caseID} onChange={(event) => setCaseID(event.target.value)} placeholder="请输入完整工单 ID" />
        </FormField>
        {error && <InlineAlert tone="danger">{error}</InlineAlert>}
      </div>
    </DialogShell>
  )
}
