// 「运行环境」产品化页面 v2：按"接入形态"分组 + 治理摘要。
//
// 完整需求映射（docs/design/agent-bus-admin-and-runtime-capabilities-design.md §2.3 + M3）：
//   - 第 1 层：平台接入治理（5 种接入形态：平台托管 OpenClaw / Hermes / 外部 ZAP / 租户自定义 / 个人自建）
//   - 第 4 层：数字员工创建时的 Runtime 选择数据源
//
// 页面骨架：
//   顶部：治理摘要卡（5 张：总数 / 健康 / 出境待审 / 失联 / 平台默认）
//   顶部行动：[+ 接入新 Runtime]（向导：先选接入形态 → 走对应字段集）
//   主体：按"接入形态"分组的列表，每组带 group 摘要 + 卡片
//   每行操作：详情 / 健康检查 / 设默认 / 提交出境审核 / 审批 / 启停 / 删除
//
// 不动后端 API；按已有字段 (Scope / Status / EgressAuditStatus / IsPlatformDefault / BoundAgents
// / SupportsMultiAgent / MaxAgents) 重新组织展现。
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  PlatformRuntimeEnvs,
  Runtimes,
  type RuntimeEnv,
  type ProbeRequest,
  type ProbeResult,
} from '../lib/api'
import {
  Cpu, Star, StarOff, Trash2, Heart, X, ChevronDown, ChevronRight,
  RefreshCw, ShieldCheck, AlertTriangle, Server,
  Layers, Power, PowerOff, CheckCircle2, XCircle, Pencil,
} from 'lucide-react'
import clsx from 'clsx'
import { secretValueToRef } from '../components/form/secretValue'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { Button, PageHeader, PrimaryButton } from '../components/ui'

// 5 种接入形态 (与 M3 §0.1 + ZAP-1.1 对齐)
type AccessForm = 'platform' | 'tenant' | 'personal' | 'zap-external' | 'unknown'

function accessFormOf(env: RuntimeEnv): AccessForm {
  if (env.Scope === 'platform') return 'platform'
  if (env.Scope === 'tenant') return 'tenant'
  if (env.Scope === 'personal') return 'personal'
  return 'unknown'
}

function isExternalZAP(env: RuntimeEnv): boolean {
  // Adapter kind external 或 framework 是 ZAP 自建接入方
  // dsh (ADR-0035 知办通用运行时) 线上协议同 ZAP, hosting_kind=external_endpoint, 归入此形态。
  return env.AdapterKind === 'external' ||
    ['agno', 'langgraph', 'autogen', 'custom', 'zap-external', 'zap', 'dsh'].includes((env.Framework || '').toLowerCase())
}

const FORM_DESC: Record<AccessForm, { title: string; subtitle: string; tone: string }> = {
  platform:      { title: '平台托管 Runtime',  subtitle: '知办AI 内置 adapter，由平台用 K8s 工作负载拉起（OpenClaw / Hermes）', tone: 'bg-sky-50 text-sky-700 ring-sky-200' },
  'zap-external':{ title: '外部 ZAP Runtime', subtitle: '第三方按 ZAP-1.1 协议接入（agno / langgraph / autogen / custom）', tone: 'bg-violet-50 text-violet-700 ring-violet-200' },
  tenant:        { title: '租户自定义',         subtitle: '某租户自己接入并自管 endpoint',                                       tone: 'bg-emerald-50 text-emerald-700 ring-emerald-200' },
  personal:      { title: '用户个人',           subtitle: '某账号自己接入（personal scope）',                                  tone: 'bg-amber-50 text-amber-700 ring-amber-200' },
  unknown:       { title: '其他',               subtitle: '未识别接入形态',                                                    tone: 'bg-slate-50 text-slate-600 ring-slate-200' },
}

export function RuntimesPage() {
  const [items, setItems] = useState<RuntimeEnv[]>([])
  const [err, setErr] = useState('')
  const [includeDisabled, setIncludeDisabled] = useState(true)
  const [reloadTick, setReloadTick] = useState(0)
  const reload = () => setReloadTick((t) => t + 1)
  const [showWizard, setShowWizard] = useState(false)
  const [editing, setEditing] = useState<RuntimeEnv | null>(null)

  useEffect(() => {
    let cancelled = false
    PlatformRuntimeEnvs.list(includeDisabled)
      .then((r) => { if (!cancelled) { setItems(r.items || []); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
    return () => { cancelled = true }
  }, [includeDisabled, reloadTick])

  // 按接入形态归集
  const groups = useMemo(() => {
    const result: Record<AccessForm, RuntimeEnv[]> = {
      platform: [], 'zap-external': [], tenant: [], personal: [], unknown: [],
    }
    items.forEach((it) => {
      const f = isExternalZAP(it) && it.Scope === 'platform' ? 'zap-external' : accessFormOf(it)
      result[f].push(it)
    })
    return result
  }, [items])

  // 治理摘要
  const stats = useMemo(() => {
    const total = items.length
    const healthy = items.filter((it) => it.Status === 'active' && it.EgressAuditStatus === 'approved').length
    const pendingEgress = items.filter((it) => it.EgressAuditStatus === 'pending').length
    const rejected = items.filter((it) => it.EgressAuditStatus === 'rejected' || it.EgressAuditStatus === 'needs_revision').length
    const platformDefault = items.find((it) => it.IsPlatformDefault)
    const bound = items.reduce((sum, it) => sum + (it.BoundAgents || 0), 0)
    return { total, healthy, pendingEgress, rejected, platformDefault, bound }
  }, [items])

  return (
    <div>
      <PageHeader
        title="运行环境"
        subtitle={<>
          管理 知办AI 接入的 Agent Runtime；包含 <strong>平台托管</strong>、<strong>外部 ZAP 接入</strong>、<strong>租户自定义</strong>、<strong>用户个人</strong> 四种形态。
          创建数字员工时按"运行环境"挑选；新租户开通默认启用 ⭐ 标记的环境。
        </>}
        actions={
          <>
            <Link to="/runtime-hosting">
              <Button variant="secondary" size="sm">
                <Server size={14} /> K8s 工作负载
              </Button>
            </Link>
            <PrimaryButton onClick={() => setShowWizard(true)}>接入新 Runtime</PrimaryButton>
          </>
        }
      />

      {/* 治理摘要 */}
      <div className="grid grid-cols-5 gap-3 mb-5">
        <Summary label="环境总数" value={stats.total} icon={Layers} />
        <Summary label="健康可用" value={stats.healthy} icon={CheckCircle2} accent="emerald" />
        <Summary label="出境待审" value={stats.pendingEgress} icon={ShieldCheck} accent="amber" />
        <Summary label="审核驳回 / 待修订" value={stats.rejected} icon={XCircle} accent="rose" />
        <SummaryRich
          label="平台默认环境"
          value={stats.platformDefault ? (stats.platformDefault.Name || stats.platformDefault.Code) : '— 未设置 —'}
          warn={!stats.platformDefault}
        />
      </div>

      {!stats.platformDefault && stats.total > 0 && (
        <div className="text-[13px] text-amber-700 bg-amber-50 border border-amber-200 rounded-md p-3 mb-4 flex items-start gap-2">
          <AlertTriangle size={14} className="mt-0.5 shrink-0" />
          <span>当前未配置 platform 默认运行环境，新租户开通会失败。请挑选一个 active 平台环境点 ⭐ 设为默认。</span>
        </div>
      )}
      {err && (
        <div className="text-[13px] text-rose-700 bg-rose-50 border border-rose-200 rounded-md p-3 mb-4">{err}</div>
      )}

      {/* 顶部工具条 */}
      <div className="flex items-center mb-3 text-xs">
        <span className="text-[var(--color-ink-mute)]">共 {stats.total} 个环境，被 {stats.bound} 个数字员工引用</span>
        <label className="ml-auto flex items-center gap-1.5 text-[var(--color-ink-sub)]">
          <input
            type="checkbox"
            checked={includeDisabled}
            onChange={(e) => setIncludeDisabled(e.target.checked)}
          />
          含已停用
        </label>
      </div>

      {/* 按形态分组 */}
      <div className="space-y-6">
        {(['platform', 'zap-external', 'tenant', 'personal', 'unknown'] as AccessForm[]).map((form) => {
          const list = groups[form]
          if (form === 'unknown' && list.length === 0) return null
          return (
            <GroupSection
              key={form}
              form={form}
              items={list}
              onChanged={reload}
              onEdit={setEditing}
            />
          )
        })}
      </div>

      {showWizard && (
        <RuntimeOnboardWizard
          onClose={() => setShowWizard(false)}
          onSaved={() => { setShowWizard(false); reload() }}
        />
      )}
      {editing && (
        <RuntimeDetailDrawer
          env={editing}
          onClose={() => setEditing(null)}
          onChanged={reload}
        />
      )}
    </div>
  )
}

function Summary({ label, value, icon: Icon, accent }: { label: string; value: number; icon: React.ComponentType<{ size?: number; className?: string }>; accent?: 'emerald' | 'amber' | 'rose' | 'sky' }) {
  const color = accent === 'emerald' ? 'text-emerald-600' :
    accent === 'amber' ? 'text-amber-600' :
    accent === 'rose' ? 'text-rose-600' :
    accent === 'sky' ? 'text-sky-600' : 'text-[var(--color-text)]'
  return (
    <div className="rounded-lg border border-[var(--color-line)] bg-white px-4 py-3">
      <div className="flex items-center gap-1.5 text-[11px] text-[var(--color-ink-mute)] mb-1">
        <Icon size={12} /> {label}
      </div>
      <div className={clsx('text-[24px] font-semibold leading-none', color)}>{value}</div>
    </div>
  )
}

function SummaryRich({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <div className={clsx(
      'rounded-lg border bg-white px-4 py-3 col-span-1',
      warn ? 'border-amber-200' : 'border-[var(--color-line)]'
    )}>
      <div className="flex items-center gap-1.5 text-[11px] text-[var(--color-ink-mute)] mb-1">
        <Star size={12} /> {label}
      </div>
      <div className={clsx('text-[14px] font-semibold leading-tight truncate', warn ? 'text-amber-700' : 'text-[var(--color-text)]')}>
        {value}
      </div>
    </div>
  )
}

function GroupSection({ form, items, onChanged, onEdit }: { form: AccessForm; items: RuntimeEnv[]; onChanged: () => void; onEdit: (env: RuntimeEnv) => void }) {
  const [open, setOpen] = useState(true)
  const desc = FORM_DESC[form]
  return (
    <section>
      <button
        onClick={() => setOpen((v) => !v)}
        className="w-full flex items-center gap-2 text-left mb-2"
      >
        {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
        <span className={clsx('text-[11px] px-2 py-0.5 rounded-md ring-1', desc.tone)}>{desc.title}</span>
        <span className="text-[12px] text-[var(--color-ink-mute)]">{desc.subtitle}</span>
        <span className="ml-auto text-[11px] text-[var(--color-ink-mute)] font-mono">{items.length}</span>
      </button>
      {open && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {items.length === 0 && (
            <div className="col-span-full rounded-md border border-dashed border-[var(--color-line)] p-6 text-center text-[12px] text-[var(--color-ink-mute)]">
              暂无{desc.title}
            </div>
          )}
          {items.map((env) => (
            <RuntimeEnvCard key={env.UUID} env={env} onChanged={onChanged} onEdit={() => onEdit(env)} />
          ))}
        </div>
      )}
    </section>
  )
}

function RuntimeEnvCard({ env, onChanged, onEdit }: { env: RuntimeEnv; onChanged: () => void; onEdit: () => void }) {
  const confirmDelete = useConfirmDialog()
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')

  const isPlatform = env.Scope === 'platform'
  const canSetDefault = isPlatform && !env.IsPlatformDefault && env.Status === 'active'
  const canSubmitEgress = env.EgressAuditStatus === 'pending'

  async function setDefault() {
    setBusy(true); setMsg('')
    try { await PlatformRuntimeEnvs.setDefault(env.UUID); onChanged() }
    catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }
  async function remove() {
    const ok = await confirmDelete.confirm({
      title: '删除运行环境',
      description: <>确认删除运行环境「<span className="font-medium text-[var(--color-text)]">{env.Name}</span>」吗？必须无租户启用、无数字员工绑定、无活跃实例。</>,
      confirmLabel: '删除',
    })
    if (!ok) return
    setBusy(true); setMsg('')
    try { await PlatformRuntimeEnvs.remove(env.UUID); onChanged() }
    catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }
  async function healthCheck() {
    setBusy(true); setMsg('')
    try {
      const res = await Runtimes.healthCheck(env.ID)
      setMsg(`健康检查：${res.status}${res.error ? ' — ' + res.error : ''}`)
      onChanged()
    } catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }
  async function submitEgress() {
    if (!confirm(`将"${env.Name}"提交出境合规审核？`)) return
    setBusy(true); setMsg('')
    try { await Runtimes.submitEgress(env.ID); setMsg('已提交审核'); onChanged() }
    catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }
  async function reviewEgress(decision: 'approved' | 'rejected' | 'needs_revision') {
    const reason = prompt(`${decision} — 审核理由（可空）`) ?? ''
    setBusy(true); setMsg('')
    try { await Runtimes.reviewEgress(env.ID, decision, reason); onChanged() }
    catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }
  async function toggleStatus() {
    const next = env.Status === 'active' ? 'disabled' : 'active'
    if (!confirm(`将 "${env.Name}" 切换为 ${next === 'active' ? '启用' : '停用'}?`)) return
    setBusy(true); setMsg('')
    try { await Runtimes.update(env.ID, { Status: next as 'active' | 'disabled' }); onChanged() }
    catch (e) { setMsg((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="bg-white rounded-lg ring-1 ring-[var(--color-line)] p-5 flex flex-col gap-3 hover:ring-[var(--color-brand)]/30 transition">
      {confirmDelete.dialog}
      <div className="flex items-start gap-3">
        <div className="w-10 h-10 rounded-xl bg-sky-50 text-sky-600 grid place-items-center">
          <Cpu size={18} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="font-medium truncate flex items-center gap-1.5">
            {env.Name || env.Code}
            {env.IsPlatformDefault && (
              <span className="text-[10px] px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 font-normal">默认</span>
            )}
          </div>
          <div className="text-[11px] text-[var(--color-ink-mute)] font-mono truncate">{env.Code}</div>
        </div>
        <StatusPill status={env.Status} />
      </div>

      <div className="grid grid-cols-2 gap-y-1.5 gap-x-3 text-xs">
        <Field label="框架" value={env.Framework || '—'} />
        <Field label="协议" value={env.ProtocolVersion || 'zap-1.1'} />
        <Field label="多 Agent" value={env.SupportsMultiAgent ? `是（≤${env.MaxAgents || '∞'}）` : '单 Agent'} />
        <Field label="出境合规" value={<EgressPill v={env.EgressAuditStatus} />} />
        <Field label="被引用" value={`${env.BoundAgents || 0} 个数字员工`} />
        <Field label="出口" value={<span className="font-mono text-[11px]">{env.DataEgress}</span>} />
      </div>

      {msg && (
        <div className="text-[11px] rounded bg-[var(--color-line-soft)] px-2 py-1.5 text-[var(--color-ink-sub)]">{msg}</div>
      )}

      <div className="flex items-center gap-1.5 mt-auto pt-2 border-t border-[var(--color-line)] flex-wrap">
        <button
          disabled={busy} onClick={healthCheck}
          className="text-xs px-2 py-1 rounded ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] flex items-center gap-1 disabled:opacity-50"
        ><Heart size={12} /> 健康</button>
        <button
          disabled={busy} onClick={onEdit}
          className="text-xs px-2 py-1 rounded ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] flex items-center gap-1 disabled:opacity-50"
        ><Pencil size={12} /> 详情</button>
        {isPlatform && canSetDefault && (
          <button
            disabled={busy} onClick={setDefault}
            className="text-xs px-2 py-1 rounded ring-1 ring-amber-200 text-amber-700 hover:bg-amber-50 flex items-center gap-1 disabled:opacity-50"
          ><Star size={12} /> 设为默认</button>
        )}
        {isPlatform && env.IsPlatformDefault && (
          <span className="text-xs px-2 py-1 rounded ring-1 ring-amber-200 text-amber-700 flex items-center gap-1">
            <StarOff size={12} /> 当前默认
          </span>
        )}
        {canSubmitEgress && (
          <button
            disabled={busy} onClick={submitEgress}
            className="text-xs px-2 py-1 rounded ring-1 ring-sky-200 text-sky-700 hover:bg-sky-50 flex items-center gap-1 disabled:opacity-50"
          ><ShieldCheck size={12} /> 提交审核</button>
        )}
        {env.EgressAuditStatus === 'pending' && (
          <div className="inline-flex gap-1">
            <button disabled={busy} onClick={() => reviewEgress('approved')}
              className="text-xs px-2 py-1 rounded ring-1 ring-emerald-200 text-emerald-700 hover:bg-emerald-50 disabled:opacity-50">批准</button>
            <button disabled={busy} onClick={() => reviewEgress('rejected')}
              className="text-xs px-2 py-1 rounded ring-1 ring-rose-200 text-rose-700 hover:bg-rose-50 disabled:opacity-50">驳回</button>
          </div>
        )}
        {isPlatform && (
          <button
            disabled={busy} onClick={toggleStatus}
            className="text-xs px-2 py-1 rounded ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] flex items-center gap-1 disabled:opacity-50"
          >{env.Status === 'active' ? <><PowerOff size={12} /> 停用</> : <><Power size={12} /> 启用</>}</button>
        )}
        {isPlatform && (
          <button
            disabled={busy} onClick={remove}
            className="ml-auto text-xs px-2 py-1 rounded ring-1 ring-rose-200 text-rose-700 hover:bg-rose-50 flex items-center gap-1 disabled:opacity-50"
          ><Trash2 size={12} /> 删除</button>
        )}
      </div>
    </div>
  )
}

function StatusPill({ status }: { status: string }) {
  const m: Record<string, string> = {
    active: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
    disabled: 'bg-slate-100 text-slate-600 ring-slate-200',
  }
  return (
    <span className={clsx('text-[10px] px-2 py-0.5 rounded-md ring-1 self-start', m[status] || m.disabled)}>
      {status === 'active' ? '运行中' : status === 'disabled' ? '已停用' : status}
    </span>
  )
}
function EgressPill({ v }: { v: string }) {
  const m: Record<string, string> = { approved: 'text-emerald-600', pending: 'text-amber-600', rejected: 'text-rose-600', needs_revision: 'text-rose-600' }
  const label: Record<string, string> = { approved: '已批准', pending: '待审', rejected: '已驳回', needs_revision: '待修订' }
  return (
    <span className={clsx('inline-flex items-center gap-1 font-mono text-[11px]', m[v] || 'text-[var(--color-ink-mute)]')}>
      <ShieldCheck size={10} /> {label[v] || v || '—'}
    </span>
  )
}
function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col">
      <span className="text-[10px] uppercase tracking-wide text-[var(--color-ink-mute)]">{label}</span>
      <span className="text-[12px] text-[var(--color-text)]">{value}</span>
    </div>
  )
}

// =========================== 接入向导 ===========================

type WizardForm = 'platform-builtin' | 'zap-external'
type Step = 1 | 2 | 3

function RuntimeOnboardWizard({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [form, setForm] = useState<WizardForm | null>(null)
  if (!form) {
    return (
      <Modal title="接入新 Runtime · 选择接入形态" onClose={onClose} size="lg">
        <p className="text-sm text-[var(--color-ink-sub)] mb-4">先决定这是哪一种 Runtime，下一步表单字段会按形态自适应。</p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <FormCard
            title="平台托管（OpenClaw / Hermes）"
            subtitle="知办AI 内置 adapter。后端用 K8s 工作负载拉起，无需对外暴露 HTTP /zap/v1/runtime_card。"
            onClick={() => setForm('platform-builtin')}
            tone="sky"
          />
          <FormCard
            title="外部 ZAP 接入"
            subtitle="第三方按 ZAP-1.1 协议实现 /runtime_card + /agents（参考实现见 apps/example/agent-example）。"
            onClick={() => setForm('zap-external')}
            tone="violet"
          />
        </div>
        <p className="text-[11px] text-[var(--color-ink-mute)] mt-4">
          租户自定义 / 用户个人 Runtime 在租户视角 / 客户端入口接入，不在这里。
        </p>
      </Modal>
    )
  }
  return (
    <RuntimeOnboardSteps form={form} onClose={onClose} onSaved={onSaved} onBack={() => setForm(null)} />
  )
}

function FormCard({ title, subtitle, onClick, tone }: { title: string; subtitle: string; onClick: () => void; tone: 'sky' | 'violet' }) {
  const t = tone === 'sky'
    ? 'border-sky-200 hover:bg-sky-50 hover:border-sky-300'
    : 'border-violet-200 hover:bg-violet-50 hover:border-violet-300'
  return (
    <button
      onClick={onClick}
      className={clsx('text-left rounded-lg border-2 p-4 transition', t)}
    >
      <div className="text-sm font-semibold mb-1">{title}</div>
      <div className="text-[12px] text-[var(--color-ink-sub)]">{subtitle}</div>
    </button>
  )
}

function RuntimeOnboardSteps({ form, onClose, onSaved, onBack }: { form: WizardForm; onClose: () => void; onSaved: () => void; onBack: () => void }) {
  const [step, setStep] = useState<Step>(1)
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [description, setDescription] = useState('')
  const [framework, setFramework] = useState(form === 'platform-builtin' ? 'openclaw' : 'agno')
  // 后端 probe 期望 endpoints.base = runtime 根地址；具体子路径由 framework adapter 内部拼接。
  const [endpoints, setEndpoints] = useState(form === 'platform-builtin'
    ? '{\n  "base": "http://openclaw.svc.cluster.local:18789"\n}'
    : '{\n  "base": "http://127.0.0.1:7801"\n}'
  )
  const [secretRef, setSecretRef] = useState('')
  const [authKind, setAuthKind] = useState('bearer')
  const [dataEgress, setDataEgress] = useState('platform-only')

  const [probe, setProbe] = useState<ProbeResult | null>(null)
  const [probing, setProbing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState('')

  const basicValid = name.trim() && code.trim() && framework.trim() && secretRef.trim()
  let endpointsObj: Record<string, string> = {}
  let endpointsValid = false
  try {
    const parsed = JSON.parse(endpoints)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      endpointsObj = parsed as Record<string, string>
      endpointsValid = true
    }
  } catch { /* ignore */ }

  async function runProbe() {
    setErr(''); setProbing(true); setProbe(null)
    try {
      const body: ProbeRequest = {
        framework, endpoints: endpointsObj,
        auth: { kind: authKind, secret: '', secret_ref: secretValueToRef(secretRef) },
      }
      const res = await PlatformRuntimeEnvs.probe(body)
      setProbe(res)
      if (res.ok) setStep(3)
    } catch (e) { setErr((e as Error).message) }
    finally { setProbing(false) }
  }
  async function save() {
    setErr(''); setSaving(true)
    try {
      await Runtimes.create({
        Code: code, Name: name, Description: description, Framework: framework,
        AdapterKind: form === 'platform-builtin' ? 'builtin' : 'external',
        Endpoints: endpointsObj, DataEgress: dataEgress,
        Metadata: { auth_kind: authKind, api_key_secret_ref: secretValueToRef(secretRef), access_form: form },
      })
      onSaved()
    } catch (e) { setErr((e as Error).message); setSaving(false) }
  }

  const formLabel = form === 'platform-builtin' ? '平台托管' : '外部 ZAP'

  return (
    <Modal title={`接入新 Runtime · ${formLabel}`} onClose={onClose} size="lg">
      <button onClick={onBack} className="text-xs text-[var(--color-ink-sub)] hover:text-[var(--color-brand)] mb-2 flex items-center gap-1">
        <ChevronRight size={12} className="rotate-180" /> 重新选接入形态
      </button>
      <Stepper step={step} />
      {err && <div className="text-[13px] text-rose-700 bg-rose-50 border border-rose-200 rounded-md p-2.5 mb-3">{err}</div>}

      {step === 1 && (
        <div className="space-y-3">
          <LabeledInput label="名称" placeholder={form === 'platform-builtin' ? '例如：OpenClaw 平台托管' : '例如：内部 Agno Agent'} value={name} onChange={setName} />
          <LabeledInput label="环境标识" placeholder={form === 'platform-builtin' ? '例如：openclaw-platform' : 'agno-internal'} value={code} onChange={setCode} mono />
          <LabeledTextArea label="描述" placeholder="可选；运营备注" value={description} onChange={setDescription} rows={2} />
          <LabeledSelect label="框架类型" value={framework} onChange={setFramework}
            options={form === 'platform-builtin'
              ? [{ value: 'openclaw', label: 'OpenClaw' }, { value: 'hermes', label: 'Hermes' }]
              : [
                // ADR-0035: 「知办通用运行时（dsh）」— 平台内置但线上协议同 ZAP, 通过此形态接入。
                { value: 'dsh', label: '知办通用运行时（dsh）' },
                { value: 'agno', label: 'Agno' },
                { value: 'langgraph', label: 'LangGraph' },
                { value: 'autogen', label: 'AutoGen' },
                { value: 'custom', label: '其他自建' },
              ]
            } />
          <LabeledInput label="访问凭证" placeholder="粘贴访问凭证" value={secretRef} onChange={setSecretRef} mono />
          <LabeledSelect label="认证类型" value={authKind} onChange={setAuthKind}
            options={[
              { value: 'bearer', label: 'Bearer Token' },
              { value: 'api_key', label: 'API Key Header' },
              { value: 'none', label: '无认证（仅 dev）' },
            ]} />
          <LabeledSelect label="数据出境" value={dataEgress} onChange={setDataEgress}
            options={[
              { value: 'platform-only', label: '不出境（仅平台内部）' },
              { value: 'cn', label: '中国大陆境内' },
              { value: 'abroad', label: '境外（需审核）' },
              { value: 'third_party', label: '第三方（需审核）' },
            ]} />
          <div>
            <label className="text-xs uppercase tracking-wide text-[var(--color-ink-mute)] mb-1.5 block">
              Endpoints (JSON map)
              <span className="ml-2 normal-case text-[10px] text-[var(--color-ink-mute)]">
                必含 base = runtime 根地址；子路径由 adapter 拼接（如 /zap/v1/runtime_card）
              </span>
            </label>
            <textarea
              value={endpoints} onChange={(e) => setEndpoints(e.target.value)} rows={6}
              className={clsx(
                'w-full px-3 py-2 text-[12px] font-mono rounded-md ring-1',
                endpointsValid ? 'ring-[var(--color-line)] focus:ring-[var(--color-brand)]' : 'ring-rose-300'
              )}
            />
            {!endpointsValid && <div className="text-[11px] text-rose-600 mt-1">JSON 解析失败</div>}
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <button onClick={onClose} className="px-3 py-1.5 rounded text-sm ring-1 ring-[var(--color-line)]">取消</button>
            <button
              disabled={!basicValid || !endpointsValid} onClick={() => setStep(2)}
              className="px-3 py-1.5 rounded text-white text-sm disabled:opacity-50"
              style={{ background: '#171717' }}
            >下一步：探测</button>
          </div>
        </div>
      )}

      {step === 2 && (
        <div className="space-y-3">
          <p className="text-sm text-[var(--color-ink-sub)]">
            点击「开始探测」会按以下 endpoint 拉取 RuntimeCard 并校验。探测通过才能保存。
          </p>
          <pre className="text-[12px] font-mono bg-[var(--color-line-soft)] rounded p-3 max-h-40 overflow-auto whitespace-pre">{endpoints}</pre>
          {probe && <ProbeReport probe={probe} />}
          <div className="flex justify-between pt-2">
            <button onClick={() => setStep(1)} className="px-3 py-1.5 rounded text-sm ring-1 ring-[var(--color-line)]">返回</button>
            <button
              onClick={runProbe} disabled={probing}
              className="px-3 py-1.5 rounded text-white text-sm disabled:opacity-50 flex items-center gap-1.5"
              style={{ background: '#171717' }}
            >
              {probing ? <RefreshCw size={14} className="animate-spin" /> : <Heart size={14} />}
              {probing ? '探测中…' : (probe ? '重新探测' : '开始探测')}
            </button>
          </div>
        </div>
      )}

      {step === 3 && probe && (
        <div className="space-y-3">
          <ProbeReport probe={probe} />
          <div className="rounded bg-emerald-50 border border-emerald-200 p-3 text-[12px] text-emerald-700">
            探测通过。保存后默认 status=active、egress_audit_status=pending；需要在「{formLabel}」分组里点「提交审核」走出境合规流程，批准后才会进入默认候选池。
          </div>
          <div className="flex justify-between pt-2">
            <button onClick={() => setStep(2)} className="px-3 py-1.5 rounded text-sm ring-1 ring-[var(--color-line)]">返回</button>
            <button
              onClick={save} disabled={saving}
              className="px-3 py-1.5 rounded text-white text-sm disabled:opacity-50"
              style={{ background: '#171717' }}
            >{saving ? '保存中…' : '保存并接入'}</button>
          </div>
        </div>
      )}
    </Modal>
  )
}

function Stepper({ step }: { step: Step }) {
  const items: Array<[Step, string]> = [[1, '基础信息'], [2, '探测'], [3, '确认']]
  return (
    <div className="flex items-center gap-2 mb-4">
      {items.map(([s, label], i) => (
        <div key={s} className="flex items-center gap-2">
          <span className={clsx(
            'w-6 h-6 rounded-full text-[11px] grid place-items-center font-semibold',
            step === s ? 'bg-[var(--color-brand)] text-white' :
            step > s ? 'bg-emerald-100 text-emerald-700' :
            'bg-[var(--color-line-soft)] text-[var(--color-ink-mute)]'
          )}>{s}</span>
          <span className="text-xs text-[var(--color-ink-sub)]">{label}</span>
          {i < items.length - 1 && <span className="w-6 h-px bg-[var(--color-line)]" />}
        </div>
      ))}
    </div>
  )
}

function ProbeReport({ probe }: { probe: ProbeResult }) {
  return (
    <div className={clsx(
      'rounded-md p-3 text-[12px] space-y-2',
      probe.ok ? 'bg-emerald-50 border border-emerald-200' : 'bg-rose-50 border border-rose-200'
    )}>
      <div className="flex items-center justify-between">
        <span className={probe.ok ? 'text-emerald-700 font-medium' : 'text-rose-700 font-medium'}>
          {probe.ok ? '✓ 探测成功' : '✗ 探测失败'}
        </span>
        <span className="text-[11px] text-[var(--color-ink-mute)]">latency {probe.latency_ms} ms</span>
      </div>
      {!probe.ok && (
        <div className="text-rose-700">
          <span className="font-mono text-[11px]">{probe.error_code}</span>
          <div className="mt-0.5">{probe.error_message}</div>
        </div>
      )}
      {probe.ok && (
        <>
          <div className="grid grid-cols-2 gap-1.5">
            <div>协议：<span className="font-mono">{probe.protocol_version || '—'}</span></div>
            <div>框架：<span className="font-mono">{probe.framework_detected || '—'}</span></div>
          </div>
          {probe.warnings && probe.warnings.length > 0 && (
            <div className="text-amber-700">
              <div className="text-[11px] uppercase tracking-wide mb-0.5">warnings</div>
              <ul className="list-disc pl-4">{probe.warnings.map((w, i) => <li key={i}>{w}</li>)}</ul>
            </div>
          )}
          {probe.missing_required_endpoints && probe.missing_required_endpoints.length > 0 && (
            <div className="text-rose-700">
              <div className="text-[11px] uppercase tracking-wide mb-0.5">缺少必需 endpoint</div>
              <ul className="list-disc pl-4">{probe.missing_required_endpoints.map((m, i) => <li key={i} className="font-mono text-[11px]">{m}</li>)}</ul>
            </div>
          )}
          {probe.runtime_card && (
            <details>
              <summary className="cursor-pointer text-[11px] text-[var(--color-ink-sub)]">RuntimeCard JSON</summary>
              <pre className="mt-1 text-[11px] font-mono bg-white/60 p-2 rounded max-h-40 overflow-auto">
                {JSON.stringify(probe.runtime_card, null, 2)}
              </pre>
            </details>
          )}
        </>
      )}
    </div>
  )
}

// =========================== 详情抽屉 ===========================

function RuntimeDetailDrawer({ env, onClose, onChanged }: { env: RuntimeEnv; onClose: () => void; onChanged: () => void }) {
  return (
    <div className="fixed inset-0 bg-black/40 z-50 flex justify-end" onClick={onClose}>
      <div className="bg-white w-[560px] max-w-[95vw] h-full overflow-auto p-6" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold">{env.Name || env.Code} · 详情</h2>
          <button onClick={onClose} className="p-1 hover:bg-[var(--color-line-soft)] rounded"><X size={16} /></button>
        </div>
        <div className="space-y-3 text-[13px]">
          <DetailRow label="代号" value={<span className="font-mono">{env.Code}</span>} />
          <DetailRow label="UUID" value={<span className="font-mono text-[11px]">{env.UUID}</span>} />
          <DetailRow label="接入形态" value={
            <span className="text-[12px]">
              {env.Scope === 'platform' ? '平台托管' : env.Scope === 'tenant' ? '租户自定义' : env.Scope === 'personal' ? '用户个人' : '其他'}
              {isExternalZAP(env) && env.Scope === 'platform' && <span className="ml-1 text-violet-600">· 外部 ZAP</span>}
            </span>
          } />
          <DetailRow label="框架" value={env.Framework} />
          <DetailRow label="Adapter" value={env.AdapterKind} />
          <DetailRow label="协议版本" value={env.ProtocolVersion || '—'} />
          <DetailRow label="ZAP Schema" value={env.ZAPSchemaVersion || '—'} />
          <DetailRow label="多 Agent" value={env.SupportsMultiAgent ? `是（最多 ${env.MaxAgents}）` : '否（单 Agent）'} />
          <DetailRow label="数据出境" value={env.DataEgress} />
          <DetailRow label="出境合规" value={<EgressPill v={env.EgressAuditStatus} />} />
          <DetailRow label="状态" value={<StatusPill status={env.Status} />} />
          <DetailRow label="平台默认" value={env.IsPlatformDefault ? '是' : '否'} />
          <DetailRow label="被引用" value={`${env.BoundAgents} 个数字员工`} />
          <DetailRow label="API Key" value={<span className="font-mono text-[11px]">{env.APIKeySecretRef || '—'}</span>} />
          <DetailRow label="创建于" value={new Date(env.CreatedAt).toLocaleString()} />
          <DetailRow label="更新于" value={new Date(env.UpdatedAt).toLocaleString()} />
          <details>
            <summary className="cursor-pointer text-[12px] text-[var(--color-ink-sub)]">Endpoints</summary>
            <pre className="mt-1 text-[11px] font-mono bg-[var(--color-line-soft)] p-2 rounded max-h-40 overflow-auto">{JSON.stringify(env.Endpoints, null, 2)}</pre>
          </details>
          {env.RuntimeCard && Object.keys(env.RuntimeCard).length > 0 && (
            <details>
              <summary className="cursor-pointer text-[12px] text-[var(--color-ink-sub)]">RuntimeCard</summary>
              <pre className="mt-1 text-[11px] font-mono bg-[var(--color-line-soft)] p-2 rounded max-h-60 overflow-auto">{JSON.stringify(env.RuntimeCard, null, 2)}</pre>
            </details>
          )}
        </div>
        {env.Scope === 'platform' && (
          <div className="mt-5 pt-4 border-t border-[var(--color-line)] flex items-center gap-2">
            <Link
              to={`/runtime-hosting?runtime_uuid=${env.UUID}`}
              onClick={() => { onClose(); onChanged() }}
              className="text-xs px-2 py-1 rounded ring-1 ring-[var(--color-line)] hover:bg-[var(--color-line-soft)] flex items-center gap-1"
            ><Server size={12} /> 该 Runtime 的 K8s 部署 / 实例 →</Link>
          </div>
        )}
      </div>
    </div>
  )
}

function DetailRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-baseline gap-3">
      <span className="text-[11px] uppercase tracking-wide text-[var(--color-ink-mute)] w-24 shrink-0">{label}</span>
      <span className="flex-1 break-all">{value}</span>
    </div>
  )
}

// =========================== Modal / Form 基础 ===========================

function Modal({ title, onClose, children, size }: { title: string; onClose: () => void; children: React.ReactNode; size?: 'md' | 'lg' }) {
  const w = size === 'lg' ? 'w-[640px]' : 'w-[560px]'
  return (
    <div className="fixed inset-0 bg-black/40 z-50 grid place-items-center p-6" onClick={onClose}>
      <div className={`bg-white rounded-lg ${w} max-w-[95vw] max-h-[90vh] overflow-auto p-6`} onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold">{title}</h2>
          <button onClick={onClose} className="p-1 hover:bg-[var(--color-line-soft)] rounded"><X size={16} /></button>
        </div>
        {children}
      </div>
    </div>
  )
}
function LabeledInput({ label, value, onChange, placeholder, mono }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string; mono?: boolean }) {
  return (
    <div>
      <label className="text-xs uppercase tracking-wide text-[var(--color-ink-mute)] mb-1.5 block">{label}</label>
      <input value={value} placeholder={placeholder} onChange={(e) => onChange(e.target.value)}
        className={clsx('w-full px-3 py-2 text-sm rounded-md ring-1 ring-[var(--color-line)] focus:ring-[var(--color-brand)] focus:outline-none', mono && 'font-mono text-[12px]')} />
    </div>
  )
}
function LabeledTextArea({ label, value, onChange, placeholder, rows }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string; rows?: number }) {
  return (
    <div>
      <label className="text-xs uppercase tracking-wide text-[var(--color-ink-mute)] mb-1.5 block">{label}</label>
      <textarea value={value} placeholder={placeholder} rows={rows || 3} onChange={(e) => onChange(e.target.value)}
        className="w-full px-3 py-2 text-sm rounded-md ring-1 ring-[var(--color-line)] focus:ring-[var(--color-brand)] focus:outline-none resize-none" />
    </div>
  )
}
function LabeledSelect({ label, value, onChange, options }: { label: string; value: string; onChange: (v: string) => void; options: { value: string; label: string }[] }) {
  return (
    <div>
      <label className="text-xs uppercase tracking-wide text-[var(--color-ink-mute)] mb-1.5 block">{label}</label>
      <select value={value} onChange={(e) => onChange(e.target.value)}
        className="w-full px-3 py-2 text-sm rounded-md ring-1 ring-[var(--color-line)] focus:ring-[var(--color-brand)] focus:outline-none bg-white">
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </div>
  )
}
