import { useEffect, useState } from 'react'
import { ContactPolicyApi, type ContactPolicy } from '../lib/api'
import { PageHeader } from '../components/ui'

// M2 §6.3 通讯录配置页, 三组卡片: 默认入口 / 字段可见性 / 拉群规则。
// 修改即生效 (M2.6 PG NOTIFY 后客户端缓存失效); 这里 admin 端单纯调 PUT。
export function ContactPolicyPage() {
  const [policy, setPolicy] = useState<ContactPolicy | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [ok, setOk] = useState('')

  useEffect(() => {
    ContactPolicyApi.get()
      .then((p) => setPolicy(p))
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [])

  const save = async (patch: Partial<ContactPolicy>) => {
    if (!policy) return
    setBusy(true)
    setErr('')
    setOk('')
    try {
      const next = await ContactPolicyApi.update(patch)
      setPolicy(next)
      setOk('已保存')
      setTimeout(() => setOk(''), 2000)
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <div className="text-sm text-[var(--color-ink-mute)]">加载中…</div>
  if (!policy) return <div className="text-sm text-[var(--color-danger)]">{err || '未配置'}</div>

  return (
    <div>
      <PageHeader
        title="通讯录配置"
        subtitle="控制本租户客户端通讯录的默认入口、字段可见性和拉群规则。修改即时生效。"
      />

      {err && (
        <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md p-3 mb-4">
          {err}
        </div>
      )}
      {ok && (
        <div className="text-[13px] text-emerald-700 bg-emerald-50 ring-border rounded-md p-3 mb-4">{ok}</div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        {/* 默认入口 */}
        <Card title="默认入口">
          <Row label="客户端默认 Tab">
            <Select
              value={policy.defaultLanding}
              onChange={(v) => save({ defaultLanding: v as ContactPolicy['defaultLanding'] })}
              busy={busy}
              options={[
                { value: 'org_tree', label: '组织树' },
                { value: 'agent_plaza', label: '数字员工广场' },
              ]}
            />
          </Row>
          <Row label="搜索范围">
            <Select
              value={policy.searchScope}
              onChange={(v) => save({ searchScope: v as ContactPolicy['searchScope'] })}
              busy={busy}
              options={[
                { value: 'current_dept', label: '仅当前部门' },
                { value: 'tenant', label: '全租户' },
                { value: 'tenant_plus_platform_agents', label: '全租户 + 平台预置数字员工' },
              ]}
            />
          </Row>
          <Row label="是否展示平台预置数字员工">
            <Toggle
              checked={policy.showPlatformAgents}
              onChange={(v) => save({ showPlatformAgents: v })}
              busy={busy}
            />
          </Row>
        </Card>

        {/* 字段可见性 */}
        <Card title="字段默认可见性">
          <p className="text-[12px] text-[var(--color-ink-mute)] mb-4">
            成员级 metadata.field_mask 优先于此处。
          </p>
          <Row label="电话">
            <FieldVisibility
              value={policy.defaultShowPhone}
              onChange={(v) => save({ defaultShowPhone: v })}
              busy={busy}
            />
          </Row>
          <Row label="邮箱">
            <FieldVisibility
              value={policy.defaultShowEmail}
              onChange={(v) => save({ defaultShowEmail: v })}
              busy={busy}
            />
          </Row>
          <Row label="岗位">
            <FieldVisibility
              value={policy.defaultShowTitle}
              onChange={(v) => save({ defaultShowTitle: v })}
              busy={busy}
            />
          </Row>
        </Card>

        {/* 拉群规则 */}
        <Card title="拉群规则">
          <Row label="谁可以创建含数字员工的群">
            <Select
              value={policy.whoCanCreateGroupWithAgent}
              onChange={(v) =>
                save({ whoCanCreateGroupWithAgent: v as ContactPolicy['whoCanCreateGroupWithAgent'] })
              }
              busy={busy}
              options={[
                { value: 'any_member', label: '任意成员' },
                { value: 'tenant_admin', label: '仅租户管理员' },
                { value: 'disabled', label: '禁用' },
              ]}
            />
          </Row>
          <Row label="新成员默认可被拉群">
            <Toggle
              checked={policy.humansDefaultInvitable}
              onChange={(v) => save({ humansDefaultInvitable: v })}
              busy={busy}
            />
          </Row>
          <Row label="新数字员工默认可被拉群">
            <Toggle
              checked={policy.agentsDefaultInvitable}
              onChange={(v) => save({ agentsDefaultInvitable: v })}
              busy={busy}
            />
          </Row>
        </Card>
      </div>
    </div>
  )
}

// ---------- 子组件 ----------

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="bg-white rounded-lg card-shadow p-5">
      <h3 className="text-base font-medium mb-4">{title}</h3>
      <div className="space-y-3">{children}</div>
    </div>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[11px] uppercase tracking-wide text-[var(--color-ink-mute)] mb-1">
        {label}
      </label>
      {children}
    </div>
  )
}

function Select({
  value,
  onChange,
  busy,
  options,
}: {
  value: string
  onChange: (v: string) => void
  busy: boolean
  options: Array<{ value: string; label: string }>
}) {
  return (
    <select
      value={value}
      disabled={busy}
      onChange={(e) => onChange(e.target.value)}
      className="w-full px-3 py-2 rounded-md ring-border bg-white text-sm disabled:opacity-50"
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  )
}

function Toggle({
  checked,
  onChange,
  busy,
}: {
  checked: boolean
  onChange: (v: boolean) => void
  busy: boolean
}) {
  return (
    <label className="inline-flex items-center gap-2 text-sm cursor-pointer">
      <input
        type="checkbox"
        checked={checked}
        disabled={busy}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span>{checked ? '开启' : '关闭'}</span>
    </label>
  )
}

function FieldVisibility({
  value,
  onChange,
  busy,
}: {
  value: 'all' | 'department' | 'self' | 'hidden'
  onChange: (v: 'all' | 'department' | 'self' | 'hidden') => void
  busy: boolean
}) {
  return (
    <Select
      value={value}
      onChange={(v) => onChange(v as 'all' | 'department' | 'self' | 'hidden')}
      busy={busy}
      options={[
        { value: 'all', label: '所有人可见' },
        { value: 'department', label: '同部门可见' },
        { value: 'self', label: '仅本人可见' },
        { value: 'hidden', label: '完全隐藏' },
      ]}
    />
  )
}
