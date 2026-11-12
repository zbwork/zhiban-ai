import { useEffect, useState, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { Auth, Billing, Tenants, type BillingPlan, type Tenant, type TenantProvisionInput, type TenantProvisionResult } from '../lib/api'
import { TenantBenefitsDialog } from './tenant/TenantBenefitsDialog'
import { BeeBridgeInfoDialog } from './tenant/BeeBridgeInfoDialog'
import { notifyError } from '../lib/toast'
import { Eye, X, MessageSquareText } from 'lucide-react'
import { Button, ConfirmDialog, InlineAlert, PageHeader, Pagination, PrimaryButton, RowActions, SearchInput, Select, Toolbar, stickyRightTdCls } from '../components/ui'

const STATUS_LABEL: Record<string, string> = {
  trial: '试用',
  active: '正式',
  suspended: '已暂停',
  deactivated: '已停用',
}
const STATUS_OPTIONS = [
  { v: 'trial', t: '试用' },
  { v: 'active', t: '正式' },
  { v: 'suspended', t: '已暂停' },
  { v: 'deactivated', t: '已停用' },
]

export function TenantList() {
  const navigate = useNavigate()
  const [items, setItems] = useState<Tenant[]>([])
  const [total, setTotal] = useState(0)
  const [plans, setPlans] = useState<BillingPlan[]>([])
  const [err, setErr] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [q, setQ] = useState('')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [tick, setTick] = useState(0)
  const [viewingBeeBridge, setViewingBeeBridge] = useState<Tenant | null>(null)
  const [canReadBeeBridge, setCanReadBeeBridge] = useState(false)
  const [canManageBilling, setCanManageBilling] = useState(false)
  const [operatorId, setOperatorId] = useState(0)

  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Tenant | null>(null)
  const [editingLoading, setEditingLoading] = useState(false)
  const [changingPlan, setChangingPlan] = useState<Tenant | null>(null)
  const [deleting, setDeleting] = useState<Tenant | null>(null)
  // Batch 2B T2B.1: 创建租户成功后用此 state 显示一次性凭据对话框
  const [credential, setCredential] = useState<TenantProvisionResult | null>(null)

  useEffect(() => {
    let cancelled = false
    Auth.permissions()
      .then((codes) => { if (!cancelled) {
        setCanReadBeeBridge((codes ?? []).includes('platform.tenant.credentials.read'))
        setCanManageBilling((codes ?? []).includes('platform.billing.manage'))
      } })
      .catch(() => { if (!cancelled) setCanReadBeeBridge(false) })
    Auth.me().then((me) => { if (!cancelled) setOperatorId(me.account.id) }).catch(() => {})
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    Tenants.list(statusFilter, q, pageSize, (page - 1) * pageSize)
      .then((r) => {
        setItems(r.items || [])
        setTotal(r.total)
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [statusFilter, q, page, pageSize, tick])

  useEffect(() => {
    Billing.listPlans({ is_active: 'true', limit: 200, offset: 0 })
      .then((r) => setPlans(r.items || []))
      .catch(() => {})
  }, [])

  const refresh = () => setTick((x) => x + 1)

  return (
    <div>
      <PageHeader title="租户管理" subtitle="管理平台租户、套餐、状态和开通管理员。" />

      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => { setQ(v); setPage(1) }}
            placeholder="搜索名称 / 租户 ID / 租户标识"
          />
        }
        filters={
          <div className="w-[140px]">
            <Select
              value={statusFilter}
              onChange={(e) => { setStatusFilter(e.target.value); setPage(1) }}
            >
              <option value="">全部状态</option>
              {STATUS_OPTIONS.map((s) => (
                <option key={s.v} value={s.v}>{s.t}</option>
              ))}
            </Select>
          </div>
        }
        summary={<>共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 个租户</>}
        actions={<PrimaryButton onClick={() => setCreating(true)}>新建租户</PrimaryButton>}
      />

      {err && <Err msg={err} />}

      <div className="overflow-x-auto rounded-lg bg-white card-shadow">
        <table className="w-full min-w-[1410px] table-fixed text-[13px]">
          <colgroup>
            <col className="w-[220px]" />
            <col className="w-[84px]" />
            <col className="w-[240px]" />
            <col className="w-[96px]" />
            <col className="w-[104px]" />
            <col className="w-[96px]" />
            <col className="w-[150px]" />
            <col className="w-[420px]" />
          </colgroup>
          <thead>
            <tr className="text-left bg-[var(--color-bg-sub)]">
              <Th>名称</Th>
              <Th>租户 ID</Th>
              <Th>租户标识</Th>
              <Th>行业</Th>
              <Th>套餐</Th>
              <Th>状态</Th>
              <Th>创建时间</Th>
              <Th className="sticky right-0 z-10 bg-[var(--color-bg-sub)]">操作</Th>
            </tr>
          </thead>
          <tbody>
            {items.length === 0 ? (
              <tr>
                <td colSpan={8} className="px-4 py-10 text-center text-[var(--color-text-mute)]">
                  没有匹配的租户
                </td>
              </tr>
            ) : (
              items.map((t) => (
                <tr key={t.ID} className="group border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60 transition">
                  <Td>
                    <div className="truncate font-medium" title={t.Name}>{t.Name}</div>
                  </Td>
                  <Td className="whitespace-nowrap"><code className="font-mono text-[12px]">{t.ID}</code></Td>
                  <Td><code className="block truncate font-mono text-[12px]" title={t.Slug}>{t.Slug}</code></Td>
                  <Td className="truncate text-[var(--color-text-sub)]" title={t.Industry}>{t.Industry}</Td>
                  <Td>
                    {t.EffectivePlanName ? (
                      <span className="block truncate" title={t.EffectivePlanCode || t.EffectivePlanName}>
                        {t.EffectivePlanName}
                      </span>
                    ) : (
                      <span className="text-[var(--color-text-mute)]">—</span>
                    )}
                  </Td>
                  <Td><StatusPill status={t.Status} /></Td>
                  <Td className="whitespace-nowrap text-[12px] text-[var(--color-text-mute)] font-mono">{new Date(t.CreatedAt).toLocaleString()}</Td>
                  <Td className={`whitespace-nowrap ${stickyRightTdCls}`}>
                    <RowActions
                      extras={
                        <>
                          <button
                            type="button"
                            onClick={() => navigate(`/tenants/${t.ID}`)}
                            title="查看详情"
                            className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-brand)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]"
                          >
                            <Eye size={14} className="mr-1" />
                            详情
                          </button>
                          {canManageBilling && operatorId > 0 && <Button variant="ghost" size="sm" className="!text-[var(--color-brand)]" onClick={() => setChangingPlan(t)}>权益套餐</Button>}
                          {canReadBeeBridge && <Button variant="ghost" size="sm" onClick={() => setViewingBeeBridge(t)}>查看蜂桥信息</Button>}
                        </>
                      }
                      onEdit={() => {
                        // 先用列表行数据立即开窗，再异步合并详情里的 OwnerInfo（列表接口不带，避免 N+1）。
                        setEditing(t)
                        setEditingLoading(true)
                        Tenants.get(t.ID)
                          .then((detail) => setEditing((cur) => (cur && cur.ID === detail.ID ? detail : cur)))
                          .catch(() => {})
                          .finally(() => setEditingLoading(false))
                      }}
                      onDelete={() => setDeleting(t)}
                    />
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {viewingBeeBridge && <BeeBridgeInfoDialog key={viewingBeeBridge.ID} tenant={viewingBeeBridge} onClose={() => setViewingBeeBridge(null)} />}
      {creating && (
        <TenantFormModal
          title="新建租户"
          plans={plans}
          onClose={() => setCreating(false)}
          onSubmit={async (body) => {
            const result = await Tenants.create(body as TenantProvisionInput)
            setCreating(false)
            refresh()
            // Batch 2B T2B.1: 弹出一次性凭据对话框；关掉就再也拿不到明文密码
            setCredential(result)
          }}
        />
      )}
      {credential && (
        <InitialCredentialModal result={credential} onClose={() => setCredential(null)} />
      )}
      {editing && (
        <TenantFormModal
          title={`编辑租户：${editing.Name}`}
          plans={plans}
          initial={editing}
          ownerLoading={editingLoading}
          onClose={() => setEditing(null)}
          onSubmit={async (body) => {
            await Tenants.update(editing.ID, body)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {changingPlan && (
        <TenantBenefitsDialog
          key={changingPlan.ID}
          operatorId={operatorId}
          tenant={changingPlan}
          plans={plans}
          onClose={() => setChangingPlan(null)}
          onChanged={() => {
            refresh()
          }}
        />
      )}
      {deleting && (
        <ConfirmDelete
          tenant={deleting}
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await Tenants.remove(deleting.ID)
            setDeleting(null)
            refresh()
          }}
        />
      )}
    </div>
  )
}

/* ---------- table cells ---------- */

function Th({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return (
    <th className={`whitespace-nowrap px-4 py-2.5 text-left text-[13px] font-semibold text-[var(--color-text)] ${className}`}>{children}</th>
  )
}
function Td({ children, className = '', ...props }: React.TdHTMLAttributes<HTMLTableCellElement>) {
  return <td {...props} className={`px-4 py-3 align-middle ${className}`}>{children}</td>
}

/* ---------- modal: create/edit ---------- */

// QA-2026-07-02: 创建租户后端约 16s（seed 角色/菜单/默认部门 + 启用默认运行环境 + 外部服务初始化）。
// 后端已加分阶段耗时日志；前端在此期间用阶段文案 + 假进度条替代干巴巴的“保存中…”，让运维知道在走哪一步。
// 仅 create path 使用；edit path 是普通更新，不套初始化流程。
const CREATE_STAGES = [
  '正在创建租户',
  '正在初始化管理员',
  '正在初始化权限与默认部门',
  '正在启用默认运行环境',
  '正在完成外部服务初始化',
]

function TenantFormModal({
  title,
  plans,
  initial,
  ownerLoading = false,
  onClose,
  onSubmit,
}: {
  title: string
  plans: BillingPlan[]
  initial?: Tenant
  ownerLoading?: boolean
  onClose: () => void
  onSubmit: (body: Partial<Tenant> | TenantProvisionInput) => Promise<void>
}) {
  const [name, setName] = useState(initial?.Name || '')
  const [slug, setSlug] = useState(initial?.Slug || '')
  const [adminMobile, setAdminMobile] = useState('')
  const [adminEmail, setAdminEmail] = useState('')
  const [adminDisplayName, setAdminDisplayName] = useState('')
  const [industry, setIndustry] = useState(initial?.Industry || '')
  const [description, setDescription] = useState(initial?.Description || '')
  const [status, setStatus] = useState(initial?.Status || 'trial')
  const [initialPlanID, setInitialPlanID] = useState<number | ''>('')
  const [busy, setBusy] = useState(false)
  // 创建向导阶段进度（仅 create path）。stageIdx 在请求期间由定时器推进，做假进度；不代表后端真实进度。
  const [stageIdx, setStageIdx] = useState(0)
  const stageTimer = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    // 组件卸载兜底清理定时器，避免泄漏。
    return () => {
      if (stageTimer.current) clearInterval(stageTimer.current)
    }
  }, [])

  // 错误反馈统一走全局 Toast (notifyError)；本地表单不再嵌错误条，避免和顶部 Toast 重复。
  // API 层 (api.ts::request) 在 4xx/5xx 时已会自动 notifyError + throw，这里只对前端校验失败手动 notifyError。
  const submit = async () => {
    if (!name.trim()) { notifyError('请填名称'); return }
    if (!initial && !slug.trim()) { notifyError('请填写租户标识'); return }
    if (!initial && !adminMobile.trim()) { notifyError('请填写租户管理员手机号'); return }
    setBusy(true)
    // 仅 create path 启动阶段推进：约每 2.6s 前进一档，封顶在最后一档（等后端真返回再收尾）。
    if (!initial) {
      setStageIdx(0)
      if (stageTimer.current) clearInterval(stageTimer.current)
      stageTimer.current = setInterval(() => {
        setStageIdx((i) => Math.min(i + 1, CREATE_STAGES.length - 1))
      }, 2600)
    }
    try {
      const body: Partial<Tenant> | TenantProvisionInput = initial
        ? { Name: name, Industry: industry, Description: description, Status: status }
        : {
            Name: name,
            Industry: industry,
            Description: description,
            Status: status,
            admin: {
              mobile: adminMobile.trim(),
              email: adminEmail.trim() || undefined,
              displayName: adminDisplayName.trim() || undefined,
            },
          }
      if (!initial) body.Slug = slug
      if (!initial && initialPlanID) body.InitialPlanID = Number(initialPlanID)
      await onSubmit(body)
    } catch {
      // API 错误已被 api.ts 的 notifyError 提示，无需重复处理
    } finally {
      if (stageTimer.current) {
        clearInterval(stageTimer.current)
        stageTimer.current = null
      }
      setBusy(false)
    }
  }

  return (
    <Modal title={title} onClose={onClose}>
      <div className="space-y-4">
        <FormField label="名称">
          <input value={name} onChange={(e) => setName(e.target.value)} className={inputCls} placeholder="例如：示例公司" autoFocus />
        </FormField>
        {initial ? (
          <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3">
            <div className="grid grid-cols-2 gap-3 text-[13px]">
              <ReadOnlyInfo label="租户标识" value={initial.Slug} mono />
              <ReadOnlyInfo label="租户 ID" value={String(initial.ID)} mono />
              <ReadOnlyInfo label="创建时间" value={new Date(initial.CreatedAt).toLocaleString()} />
              <ReadOnlyInfo
                label="开通管理员账号 ID"
                value={initial.OwnerInfo
                  ? String(initial.OwnerInfo.accountId)
                  : ownerLoading
                    ? '加载中…'
                    : (initial.OwnerID ? String(initial.OwnerID) : '未记录')}
                mono
              />
              <ReadOnlyInfo
                label="管理员手机号"
                value={initial.OwnerInfo?.phone || (ownerLoading ? '加载中…' : '—')}
                mono
              />
              <ReadOnlyInfo
                label="管理员邮箱"
                value={initial.OwnerInfo?.email || (ownerLoading ? '加载中…' : '—')}
              />
              <ReadOnlyInfo
                label="当前套餐"
                value={initial.EffectivePlanName || '暂无有效订阅'}
              />
            </div>
            <p className="mt-3 text-[12px] leading-5 text-[var(--color-text-mute)]">
              租户标识用于登录域名和路径，创建后不建议修改。开通管理员账号、角色和密码请到“成员 / 权限与角色”中维护。
            </p>
          </div>
        ) : (
          <FormField label="租户标识" hint="用于子域名和路径，全局唯一；只能使用小写字母、数字和连字符">
            <input
              value={slug}
              onChange={(e) => setSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''))}
              className={inputCls + ' font-mono'}
              placeholder="acme-corp"
            />
          </FormField>
        )}
        {!initial && (
          <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3">
            <div className="mb-3 text-[13px] font-medium text-[var(--color-text)]">租户管理员</div>
            <div className="grid grid-cols-2 gap-3">
                <FormField label="管理员手机号">
                  <input
                    value={adminMobile}
                    onChange={(e) => setAdminMobile(e.target.value.replace(/[^\d+ -]/g, ''))}
                    className={inputCls}
                    placeholder="例如：13900000000"
                  />
                </FormField>
                <FormField label="管理员姓名">
                  <input
                    value={adminDisplayName}
                    onChange={(e) => setAdminDisplayName(e.target.value)}
                    className={inputCls}
                    placeholder="默认：租户名称 + 管理员"
                  />
                </FormField>
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3">
                <FormField label="管理员邮箱">
                  <input
                    value={adminEmail}
                    onChange={(e) => setAdminEmail(e.target.value)}
                    className={inputCls}
                    placeholder="可选"
                  />
                </FormField>
              </div>
              <p className="mt-3 text-[12px] leading-5 text-[var(--color-text-mute)]">
                创建后系统会自动生成一次性初始密码；保存成功时仅本次显示一次，请立即复制给租户管理员。首次登录将强制改密。
              </p>
          </div>
        )}
        <div className="grid grid-cols-2 gap-3">
          <FormField label="行业">
            <input value={industry} onChange={(e) => setIndustry(e.target.value)} className={inputCls} placeholder="例如：教育 / 金融" />
          </FormField>
          <FormField label="状态">
            <Select value={status} onChange={(e) => setStatus(e.target.value)}>
              {STATUS_OPTIONS.map((s) => (
                <option key={s.v} value={s.v}>{s.t}</option>
              ))}
            </Select>
          </FormField>
        </div>
        {!initial && (
          <FormField label="初始套餐" hint="未选择时，系统会自动开通启用中的免费版套餐">
            <Select value={initialPlanID} onChange={(e) => setInitialPlanID(e.target.value ? Number(e.target.value) : '')}>
              <option value="">默认免费版</option>
              {plans.map((p) => (
                <option key={p.id} value={p.id}>
                  {formatPlanOption(p)}
                </option>
              ))}
            </Select>
          </FormField>
        )}
        <FormField label="描述">
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={2}
            className={inputCls + ' resize-none h-auto py-2'}
            placeholder="可选"
          />
        </FormField>
      </div>
      {busy && !initial && (
        <div className="mt-5" aria-live="polite">
          <div className="flex items-center gap-2 text-[13px] text-[var(--color-text-sub)]">
            <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-[var(--color-line)] border-t-[var(--color-text)]" />
            <span>{CREATE_STAGES[stageIdx]}…</span>
            <span className="text-[var(--color-text-mute)]">（{stageIdx + 1}/{CREATE_STAGES.length}）</span>
          </div>
          <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-[var(--color-line-soft)]">
            <div
              className="h-full rounded-full bg-[var(--color-text)] transition-all duration-500 ease-out"
              style={{ width: `${Math.round(((stageIdx + 1) / CREATE_STAGES.length) * 92)}%` }}
            />
          </div>
          <div className="mt-1.5 text-[11px] text-[var(--color-text-mute)]">首次开通租户需初始化权限、默认部门、运行环境和外部服务，约需十几秒，请勿关闭或重复提交。</div>
        </div>
      )}
      <div className="flex justify-end gap-2 mt-6">
        <button onClick={onClose} className="h-9 px-3 rounded-md text-[13px] text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)]">取消</button>
        <button
          onClick={submit}
          disabled={busy}
          className="h-9 px-4 rounded-md bg-[var(--color-text)] text-white text-[13px] font-medium hover:bg-black disabled:opacity-60"
        >
          {busy ? (initial ? '保存中…' : `${CREATE_STAGES[stageIdx]}…`) : initial ? '保存' : '创建租户'}
        </button>
      </div>
    </Modal>
  )
}

function formatPlanOption(plan: BillingPlan) {
  const monthly = plan.prices?.find((price) => price.is_active && price.billing_cycle === 'monthly')
  const price = monthly?.amount ?? plan.price_monthly ?? 0
  return `${plan.name} (${plan.code}) · ${price > 0 ? `¥${price}/月` : '免费'}`
}

/* ---------- modal: delete confirm ---------- */

function ConfirmDelete({
  tenant,
  onClose,
  onConfirm,
}: {
  tenant: Tenant
  onClose: () => void
  onConfirm: () => Promise<void>
}) {
  const [confirmText, setConfirmText] = useState('')
  return (
    <ConfirmDialog
      title="删除租户"
      description={(
        <>
        你将软删除租户 <strong className="text-[var(--color-text)]">{tenant.Name}</strong>（租户标识：<code className="font-mono">{tenant.Slug}</code>）。
        删除后，该租户下的成员与数字员工 <strong>不会自动级联删除</strong>，但所有客户端登录会被拒绝。
        </>
      )}
      confirmLabel="删除"
      busyLabel="删除中..."
      confirmDisabled={confirmText !== tenant.Slug}
      onClose={onClose}
      onConfirm={onConfirm}
    >
      <InlineAlert tone="warn">
        软删除可以联系管理员手动复活（清空 deleted_at）。30 天后会进入归档。
      </InlineAlert>
      <div className="text-[13px] text-[var(--color-text-sub)]">
        请输入 <code className="font-mono bg-[var(--color-bg-sub)] px-1.5 py-0.5 rounded">{tenant.Slug}</code> 确认操作：
      </div>
      <input
        value={confirmText}
        onChange={(e) => setConfirmText(e.target.value)}
        className={inputCls + ' font-mono'}
        placeholder={tenant.Slug}
      />
    </ConfirmDialog>
  )
}

/* ---------- shared bits ---------- */

const inputCls = 'w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] focus:outline-none focus:shadow-[var(--color-focus)_0px_0px_0px_2px]'

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/20 px-4 py-8" onClick={onClose}>
      <div
        className="flex max-h-[calc(100dvh-64px)] w-full max-w-lg flex-col overflow-hidden rounded-lg bg-white card-shadow"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex shrink-0 items-start justify-between px-6 pt-6 pb-4">
          <h3 className="text-[20px] font-semibold tracking-tight">{title}</h3>
          <button onClick={onClose} className="w-7 h-7 grid place-items-center rounded-md hover:bg-[var(--color-line-soft)]"><X size={14} /></button>
        </div>
        <div className="min-h-0 overflow-y-auto px-6 pb-6">
          {children}
        </div>
      </div>
    </div>
  )
}

function FormField({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[12px] font-medium text-[var(--color-text)] mb-1">{label}</label>
      {children}
      {hint && <p className="text-[11px] text-[var(--color-text-mute)] mt-1">{hint}</p>}
    </div>
  )
}

function ReadOnlyInfo({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <div className="mb-1 text-[11px] text-[var(--color-text-mute)]">{label}</div>
      <div className={`truncate text-[13px] text-[var(--color-text)] ${mono ? 'font-mono' : ''}`}>{value || '—'}</div>
    </div>
  )
}

function StatusPill({ status }: { status: string }) {
  const map: Record<string, string> = {
    active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    trial: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
    suspended: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
    deactivated: 'bg-[var(--color-line-soft)] text-[var(--color-text-mute)]',
  }
  return (
    <span className={`inline-block whitespace-nowrap px-2 py-0.5 text-[11px] rounded ring-border-soft ${map[status] || map.deactivated}`}>
      {STATUS_LABEL[status] || status}
    </span>
  )
}

function Err({ msg }: { msg: string }) {
  return <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md px-3 py-2 mb-4">{msg}</div>
}

/* ---------- modal: initial admin info (无密码，短信验证码登录) ---------- */

// 新建管理员账号不生成密码：告知操作者该账号需先用手机号+短信验证码登录，
// 登录后再自行设置密码；复用已有账号时提示对方用原有方式登录即可。
function InitialCredentialModal({ result, onClose }: { result: TenantProvisionResult; onClose: () => void }) {
  const reused = result.initial_admin.account_reused

  return (
    <Modal title="租户创建成功" onClose={onClose}>
      <div className="space-y-4">
        <div className="rounded-md ring-border bg-white p-3">
          <div className="grid grid-cols-2 gap-3 text-[13px]">
            <ReadOnlyInfo label="租户名称" value={result.tenant.Name} />
            <ReadOnlyInfo label="租户标识" value={result.tenant.Slug} mono />
            <ReadOnlyInfo label="管理员手机号" value={result.initial_admin.phone} mono />
            <ReadOnlyInfo
              label="账号"
              value={reused ? `复用已有账号 #${result.initial_admin.account_id}` : `新建 #${result.initial_admin.account_id}`}
            />
          </div>
        </div>
        {reused ? (
          <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-3 text-[13px] leading-6 text-[var(--color-text-sub)]">
            该手机号已经存在账号，请联系该账号本人用原有方式（密码或短信验证码）登入新租户。
          </div>
        ) : (
          <div className="rounded-md border border-blue-200 bg-blue-50 px-3 py-3 text-[13px] leading-6 text-blue-900 flex gap-2">
            <MessageSquareText size={18} className="shrink-0 mt-0.5" />
            <div>
              <div className="font-medium mb-1">该账号未设置密码</div>
              <div>请告知该租户管理员，首次登录用手机号 + 短信验证码，登录后可自行设置密码。</div>
            </div>
          </div>
        )}
      </div>
      <div className="flex justify-end gap-2 mt-6">
        <button
          onClick={onClose}
          className="h-9 px-4 rounded-md bg-[var(--color-text)] text-white text-[13px] font-medium hover:bg-black"
        >
          知道了，关闭
        </button>
      </div>
    </Modal>
  )
}
