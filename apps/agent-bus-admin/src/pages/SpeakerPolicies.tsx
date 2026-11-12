// F09-B4-03: Speaker 策略治理 (/rooms/speaker-policies).
//
// 列表 + DrawerShell variant="polished" 创建 / 编辑; 软删确认走 ConfirmDialog.
// base_policy 改变时 selector_config 子表单切换 (round_robin / auto_llm / manager / parallel / handoff).
// selector_config 用受控 textarea JSON 编辑 + 提交前 JSON.parse 校验.

import { useEffect, useState } from 'react'
import {
  AdminSpeakerPolicies,
  type AdminSpeakerPolicy,
  type AdminSpeakerPolicyUpsert,
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
  Pagination,
  Panel,
  PrimaryButton,
  RowActions,
  SearchInput,
  Select,
  Switch,
} from '../components/ui'
import { useConfirmDialog } from '../components/useConfirmDialog'

type BasePolicy = AdminSpeakerPolicy['base_policy']

const POLICY_OPTIONS: { value: BasePolicy; label: string; hint: string }[] = [
  { value: 'manual', label: 'manual', hint: '客户端指定，selector 不挑选' },
  { value: 'round_robin', label: 'round_robin', hint: '轮转 Agent (selector_config: {})' },
  { value: 'auto_llm', label: 'auto_llm', hint: 'LLM judge 挑选 (selector_config: {judge_model?, prompt?})' },
  { value: 'manager', label: 'manager', hint: 'manager_agent 强制挑 (manager_agent_uuid 必填)' },
  { value: 'parallel', label: 'parallel', hint: '所有候选并发回复' },
  { value: 'handoff', label: 'handoff', hint: '上一发言 Agent 决定下一棒 (selector_config: {max_depth?})' },
]

function emptyForm(): AdminSpeakerPolicyUpsert {
  return {
    name: '',
    description: '',
    is_template: false,
    base_policy: 'round_robin',
    manager_agent_uuid: '',
    selector_config: {},
    max_speaker_decisions_per_minute: 30,
  }
}

export default function SpeakerPoliciesPage() {
  const [items, setItems] = useState<AdminSpeakerPolicy[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const pageSize = 20
  const [q, setQ] = useState('')
  const [tpl, setTpl] = useState<'' | 'true' | 'false'>('')
  const [err, setErr] = useState('')

  const [editing, setEditing] = useState<AdminSpeakerPolicy | null>(null)
  const [creating, setCreating] = useState(false)

  const { confirm, dialog: confirmDialog } = useConfirmDialog()

  async function reload() {
    try {
      const res = await AdminSpeakerPolicies.list({
        is_template: tpl === '' ? undefined : tpl === 'true',
        q: q || undefined,
        page,
        page_size: pageSize,
      })
      setItems(res.items || [])
      setTotal(res.total)
      setErr('')
    } catch (e: unknown) {
      setErr((e as Error).message || '加载失败')
    }
  }

  useEffect(() => {
    let mounted = true
    AdminSpeakerPolicies.list({
      is_template: tpl === '' ? undefined : tpl === 'true',
      q: q || undefined,
      page,
      page_size: pageSize,
    })
      .then((res) => {
        if (!mounted) return
        setItems(res.items || [])
        setTotal(res.total)
        setErr('')
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr((e as Error).message || '加载失败')
      })
    return () => { mounted = false }
  }, [tpl, q, page])

  async function handleDelete(p: AdminSpeakerPolicy) {
    const ok = await confirm({
      title: '删除 Speaker 策略',
      description: `确认删除 "${p.name}"？该策略将被软删（仍保留审计），现有引用此策略的 room 不受影响。`,
      tone: 'danger',
      confirmLabel: '删除',
    })
    if (!ok) return
    try {
      await AdminSpeakerPolicies.remove(p.uuid)
      await reload()
    } catch (e: unknown) {
      setErr((e as Error).message || '删除失败')
    }
  }

  return (
    <div className="p-6 space-y-4 max-w-7xl">
      <PageHeader
        title="Speaker 策略"
        subtitle="本租户群聊 SpeakerSelector 策略模板与配置 (F09 Phase B)。"
      />

      <Panel>
        <div className="flex flex-wrap items-center gap-3">
          <FormField label="模板">
            <Select value={tpl} onChange={(e) => { setTpl(e.target.value as ''); setPage(1) }}>
              <option value="">全部</option>
              <option value="true">仅模板</option>
              <option value="false">仅实例</option>
            </Select>
          </FormField>
          <SearchInput value={q} onChange={(v) => { setQ(v); setPage(1) }} placeholder="按名称搜索..." />
          <PrimaryButton onClick={() => setCreating(true)}>+ 新建策略</PrimaryButton>
        </div>
      </Panel>

      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <DataTable
        headers={['名称', 'base_policy', 'Manager Agent', 'RPM 上限', '模板', '创建时间', '操作']}
      >
        {items.length === 0 ? (
          <tr><td colSpan={7} className="px-3 py-8"><EmptyState title="暂无 Speaker 策略" description="点击右上「+ 新建策略」添加。" /></td></tr>
        ) : items.map((p) => (
          <tr key={p.uuid} className="border-t border-[var(--color-line-soft)]">
            <td className="px-3 py-2">
              <div>{p.name}</div>
              {p.description && <div className="text-xs text-[var(--color-text-mute)] mt-0.5 truncate max-w-md">{p.description}</div>}
            </td>
            <td className="px-3 py-2"><code className="text-xs px-1.5 py-0.5 rounded bg-[var(--color-bg-sub)]">{p.base_policy}</code></td>
            <td className="px-3 py-2 text-xs text-[var(--color-text-sub)]">{p.manager_agent_name || '-'}</td>
            <td className="px-3 py-2 text-right tabular-nums">{p.max_speaker_decisions_per_minute}</td>
            <td className="px-3 py-2">{p.is_template ? <span className="text-[var(--color-info)] text-xs">是</span> : '-'}</td>
            <td className="px-3 py-2 text-xs text-[var(--color-text-mute)]">{new Date(p.created_at).toLocaleString('zh-CN', { hour12: false })}</td>
            <td className="px-3 py-2 sticky right-0 bg-[var(--color-surface)]">
              <RowActions
                onEdit={() => setEditing(p)}
                onDelete={() => void handleDelete(p)}
              />
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination page={page} pageSize={pageSize} total={total} onPageChange={setPage} onPageSizeChange={() => { /* fixed */ }} />

      {(creating || editing) && (
        <PolicyDrawer
          initial={editing ?? null}
          onClose={() => { setCreating(false); setEditing(null) }}
          onSaved={async () => { setCreating(false); setEditing(null); await reload() }}
        />
      )}

      {confirmDialog}
    </div>
  )
}

// ----- DrawerShell variant="polished" -----

function PolicyDrawer({
  initial,
  onClose,
  onSaved,
}: {
  initial: AdminSpeakerPolicy | null
  onClose: () => void
  onSaved: () => Promise<void>
}) {
  const isEdit = !!initial
  const [form, setForm] = useState<AdminSpeakerPolicyUpsert>(() => {
    if (!initial) return emptyForm()
    return {
      name: initial.name,
      description: initial.description ?? '',
      is_template: initial.is_template,
      base_policy: initial.base_policy,
      manager_agent_uuid: initial.manager_agent_uuid ?? '',
      selector_config: initial.selector_config,
      max_speaker_decisions_per_minute: initial.max_speaker_decisions_per_minute,
    }
  })
  const [cfgText, setCfgText] = useState(() => JSON.stringify(initial?.selector_config ?? {}, null, 2))
  const [cfgErr, setCfgErr] = useState('')
  const [err, setErr] = useState('')
  const [saving, setSaving] = useState(false)

  function bind<K extends keyof AdminSpeakerPolicyUpsert>(k: K) {
    return (v: AdminSpeakerPolicyUpsert[K]) => setForm((f) => ({ ...f, [k]: v }))
  }

  async function submit() {
    if (!form.name.trim()) {
      setErr('名称必填')
      return
    }
    let cfg: Record<string, unknown>
    try {
      const parsed = cfgText.trim() === '' ? {} : JSON.parse(cfgText)
      if (typeof parsed !== 'object' || Array.isArray(parsed) || parsed === null) {
        throw new Error('selector_config 必须是 JSON object')
      }
      cfg = parsed
      setCfgErr('')
    } catch (e: unknown) {
      setCfgErr((e as Error).message || 'selector_config JSON 不合法')
      return
    }
    const body: AdminSpeakerPolicyUpsert = { ...form, selector_config: cfg }
    setSaving(true)
    try {
      if (isEdit && initial) {
        await AdminSpeakerPolicies.update(initial.uuid, body)
      } else {
        await AdminSpeakerPolicies.create(body)
      }
      await onSaved()
    } catch (e: unknown) {
      setErr((e as Error).message || '保存失败')
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      onClose={onClose}
      title={isEdit ? `编辑策略 · ${initial?.name}` : '新建 Speaker 策略'}
      variant="polished"
      footer={
        <>
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <PrimaryButton onClick={() => void submit()} disabled={saving}>{saving ? '保存中…' : '保存'}</PrimaryButton>
        </>
      }
    >
      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <FormSection title="基本">
        <FormField label="名称">
          <Input value={form.name} onChange={(e) => bind('name')(e.target.value)} placeholder="给策略起个清晰名字" />
        </FormField>
        <FormField label="描述" hint="可选, 给运维一句解释。">
          <Input value={form.description ?? ''} onChange={(e) => bind('description')(e.target.value)} placeholder="可选" />
        </FormField>
        <FormField label="是否模板">
          <div className="flex items-center gap-3">
            <Switch
              checked={!!form.is_template}
              onChange={(v) => bind('is_template')(v)}
              ariaLabel="是否作为模板"
            />
            <span className="text-sm text-[var(--color-text-sub)]">
              {form.is_template ? '模板（其它 room 可引用）' : '实例'}
            </span>
          </div>
        </FormField>
      </FormSection>

      <FormSection title="策略" description="选不同 base_policy, selector_config 字段不同; manager 需 manager_agent_uuid。">
        <FormField label="base_policy">
          <Select value={form.base_policy} onChange={(e) => bind('base_policy')(e.target.value as BasePolicy)}>
            {POLICY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
          <p className="mt-1 text-xs text-[var(--color-text-mute)]">{POLICY_OPTIONS.find((p) => p.value === form.base_policy)?.hint}</p>
        </FormField>
        {form.base_policy === 'manager' && (
          <FormField label="manager_agent_uuid" hint="manager 模式必填: tenant 内一个 active 数字员工 UUID。">
            <Input value={form.manager_agent_uuid ?? ''} onChange={(e) => bind('manager_agent_uuid')(e.target.value)} placeholder="例: 9c1f..." />
          </FormField>
        )}
        <FormField label="selector_config (JSON)" hint="根据 base_policy 填子配置; 空对象 {} 也合法。">
          <textarea
            value={cfgText}
            onChange={(e) => setCfgText(e.target.value)}
            className="w-full h-40 px-2 py-1.5 rounded border border-[var(--color-line)] bg-[var(--color-surface)] font-mono text-xs"
            spellCheck={false}
            placeholder="{}"
          />
          {cfgErr && <p className="mt-1 text-xs text-[var(--color-danger)]">{cfgErr}</p>}
        </FormField>
        <FormField label="RPM 上限" hint="每分钟最多多少次 SpeakerSelector 决策 (默认 30)。">
          <Input
            type="number"
            value={String(form.max_speaker_decisions_per_minute ?? 30)}
            onChange={(e) => bind('max_speaker_decisions_per_minute')(Number(e.target.value) || 30)}
          />
        </FormField>
      </FormSection>
    </DrawerShell>
  )
}
