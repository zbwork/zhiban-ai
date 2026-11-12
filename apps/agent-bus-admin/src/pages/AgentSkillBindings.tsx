// AgentSkillBindings — 数字员工 × 技能装配（agent_skill_bindings）。
//
// 路由：/agents/:uuid/skills
// 两栏：左 - 已装配 / 可装配；右 - 装配详情（pin / sort / pinned_version）。

import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import {
  TenantSkills,
  type SkillVersion,
} from '../lib/api'
import { Button, Tabs, FormField, Input, EmptyState, InlineAlert, DialogShell } from '../components/ui'
import { Plus, Pin, PinOff, Trash2, Save } from 'lucide-react'
import { SKILL_KIND_LABEL, SKILL_SCOPE_LABEL, labelOrCode, preferenceLabel } from '../lib/skillLabels'

type AttachedItem = {
  binding_id: number; skill_uuid: string; skill_code: string; skill_name: string;
  pinned: boolean; sort_order: number; pinned_version_id?: number;
  default_params: unknown; source: string;
}
type AvailableItem = {
  skill_uuid: string; code: string; name: string;
  scope_kind: string; kind: string; icon_url?: string;
  is_attached: boolean; is_default_attached: boolean; tenant_preference?: string;
}

type TabKey = 'attached' | 'available'

export function AgentSkillBindingsPage() {
  const { uuid = '' } = useParams<{ uuid: string }>()
  const [tab, setTab] = useState<TabKey>('attached')
  const [err, setErr] = useState('')
  const [reload, setReload] = useState(0)

  return (
    <div className="space-y-3">
      <div className="bg-white rounded-lg card-shadow p-4">
        <div className="flex items-center justify-between mb-2">
          <h2 className="font-semibold">数字员工技能装配</h2>
          <span className="text-xs text-gray-500">数字员工技能装配</span>
        </div>
        {err && <div className="mb-3"><InlineAlert>{err}</InlineAlert></div>}
        <Tabs<TabKey>
          value={tab}
          onChange={(v) => setTab(v)}
          items={[
            { value: 'attached', label: '已装配' },
            { value: 'available', label: '可添加' },
          ]}
        />
        <div className="mt-4">
          {tab === 'attached' && <AttachedPane key={reload} agentUUID={uuid} onError={setErr} onChanged={() => setReload((t) => t + 1)} />}
          {tab === 'available' && <AvailablePane agentUUID={uuid} onError={setErr} onChanged={() => setReload((t) => t + 1)} />}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 已装配
// ---------------------------------------------------------------------------

function AttachedPane({ agentUUID, onError, onChanged }: {
  agentUUID: string; onError: (m: string) => void; onChanged: () => void
}) {
  // loading 初始 true，仅在首次加载时显示骨架；之后的 reload 不再切回 true，避免列表闪烁
  // 同时也避免 react-hooks/set-state-in-effect lint 错误。
  const [items, setItems] = useState<AttachedItem[]>([])
  const [loading, setLoading] = useState(true)
  const [editing, setEditing] = useState<AttachedItem | null>(null)

  useEffect(() => {
    let cancelled = false
    TenantSkills.listAgentSkills(agentUUID)
      .then((r) => { if (!cancelled) setItems(r.items || []) })
      .catch((e: Error) => { if (!cancelled) onError(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [agentUUID, onError])

  const detach = async (it: AttachedItem) => {
    if (!confirm(`确认解除装配 "${it.skill_name}"？`)) return
    try {
      await TenantSkills.detachBinding(agentUUID, it.binding_id)
      setItems(items.filter((x) => x.binding_id !== it.binding_id))
      onChanged()
    } catch (e) { onError((e as Error).message) }
  }

  const togglePin = async (it: AttachedItem) => {
    try {
      await TenantSkills.patchBinding(agentUUID, it.binding_id, { pinned: !it.pinned })
      setItems(items.map((x) => x.binding_id === it.binding_id ? { ...x, pinned: !x.pinned } : x))
    } catch (e) { onError((e as Error).message) }
  }

  if (loading) return <div className="text-sm text-gray-500 py-8 text-center">加载中…</div>
  if (items.length === 0) return <EmptyState title="此数字员工暂未装配技能" description="切换到「可添加」标签从平台技能装配" />

  return (
    <div>
      <table className="w-full text-sm border rounded-md overflow-hidden">
        <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
          <tr>
            <th className="text-left px-3 py-2">技能</th>
            <th className="text-left px-3 py-2">来源</th>
            <th className="text-left px-3 py-2">Pin</th>
            <th className="text-left px-3 py-2">排序</th>
            <th className="text-left px-3 py-2">绑定版本</th>
            <th className="w-32" />
          </tr>
        </thead>
        <tbody>
          {items.map((it) => (
            <tr key={it.binding_id} className="border-t">
              <td className="px-3 py-2">
                <div className="font-medium">{it.skill_name}</div>
                <div className="text-xs text-gray-500">{it.skill_code}</div>
              </td>
              <td className="px-3 py-2 text-xs">{it.source}</td>
              <td className="px-3 py-2">
                <button onClick={() => togglePin(it)} title={it.pinned ? '取消 pin' : 'pin'}>
                  {it.pinned ? <Pin size={14} className="text-blue-600" /> : <PinOff size={14} />}
                </button>
              </td>
              <td className="px-3 py-2">{it.sort_order}</td>
              <td className="px-3 py-2 text-xs">
                {it.pinned_version_id ? `#${it.pinned_version_id}` : <span className="text-gray-400">latest</span>}
              </td>
              <td className="px-3 py-2 space-x-1">
                <Button size="sm" variant="ghost" onClick={() => setEditing(it)}><Save size={12} /></Button>
                <Button size="sm" variant="ghost" onClick={() => detach(it)}><Trash2 size={12} /></Button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {editing && (
        <BindingEditDialog
          agentUUID={agentUUID}
          binding={editing}
          onClose={() => setEditing(null)}
          onError={onError}
          onDone={() => { setEditing(null); onChanged() }}
        />
      )}
    </div>
  )
}

function BindingEditDialog({
  agentUUID, binding, onClose, onDone, onError,
}: {
  agentUUID: string; binding: AttachedItem
  onClose: () => void; onDone: () => void; onError: (m: string) => void
}) {
  const [pinned, setPinned] = useState(binding.pinned)
  const [sortOrder, setSortOrder] = useState<number>(binding.sort_order)
  const [versions, setVersions] = useState<SkillVersion[]>([])
  const [versionId, setVersionId] = useState<string>(binding.pinned_version_id ? String(binding.pinned_version_id) : '')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let cancelled = false
    // 走 tenant 视角的 published 版本列表（避免依赖 platform.skill.read 权限）
    TenantSkills.listVersions(binding.skill_uuid)
      .then((r) => { if (!cancelled) setVersions(r.items || []) })
      .catch(() => { /* 安静失败：编辑装配时不强制能 pin 版本 */ })
    return () => { cancelled = true }
  }, [binding.skill_uuid])

  const submit = async () => {
    setBusy(true)
    try {
      const body: Parameters<typeof TenantSkills.patchBinding>[2] = {
        pinned, sort_order: sortOrder,
      }
      if (versionId === '') {
        body.clear_pinned_version = true
      } else {
        body.pinned_version_id = Number(versionId)
      }
      await TenantSkills.patchBinding(agentUUID, binding.binding_id, body)
      onDone()
    } catch (e) { onError((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <DialogShell title={`编辑装配 - ${binding.skill_name}`} onClose={onClose} footer={
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>取消</Button>
        <Button onClick={submit} disabled={busy}>{busy ? '保存中…' : '保存'}</Button>
      </div>
    }>
      <div className="space-y-3">
        <FormField label="Pinned（在 chip rail 显示）">
          <input type="checkbox" checked={pinned} onChange={(e) => setPinned(e.target.checked)} />
        </FormField>
        <FormField label="排序">
          <Input type="number" value={sortOrder} onChange={(e) => setSortOrder(Number(e.target.value) || 0)} />
        </FormField>
        <FormField label="锁定版本（不锁则跟随灰度推送的最新 published）">
          <select className="border rounded px-2 py-1 w-full text-sm" value={versionId} onChange={(e) => setVersionId(e.target.value)}>
            <option value="">— 跟随最新 —</option>
            {versions.filter((v) => v.status === 'published').map((v) => (
              <option key={v.uuid} value={v.id}>v{v.version}（{v.status}）</option>
            ))}
          </select>
        </FormField>
      </div>
    </DialogShell>
  )
}

// ---------------------------------------------------------------------------
// 可添加
// ---------------------------------------------------------------------------

function AvailablePane({ agentUUID, onError, onChanged }: {
  agentUUID: string; onError: (m: string) => void; onChanged: () => void
}) {
  const [items, setItems] = useState<AvailableItem[]>([])
  const [loading, setLoading] = useState(true)
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let cancelled = false
    TenantSkills.listAvailableSkills(agentUUID)
      .then((r) => { if (!cancelled) setItems(r.items || []) })
      .catch((e: Error) => { if (!cancelled) onError(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [agentUUID, onError, reload])

  const attach = async (sk: AvailableItem) => {
    try {
      await TenantSkills.attachAgentSkill(agentUUID, {
        skill_uuid: sk.skill_uuid, pinned: true, sort_order: 0, source: 'manual_attach',
      })
      setReload((t) => t + 1)
      onChanged()
    } catch (e) { onError((e as Error).message) }
  }

  if (loading) return <div className="text-sm text-gray-500 py-8 text-center">加载中…</div>
  if (items.length === 0) return <EmptyState title="无可添加技能" />

  return (
    <table className="w-full text-sm border rounded-md overflow-hidden">
      <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
        <tr>
          <th className="text-left px-3 py-2">技能</th>
          <th className="text-left px-3 py-2">类型</th>
          <th className="text-left px-3 py-2">范围</th>
          <th className="text-left px-3 py-2">租户偏好</th>
          <th className="w-28" />
        </tr>
      </thead>
      <tbody>
        {items.map((it) => (
          <tr key={it.skill_uuid} className="border-t">
            <td className="px-3 py-2">
              <div className="font-medium">{it.name}</div>
              <div className="text-xs text-gray-500">{it.code}</div>
            </td>
            <td className="px-3 py-2 text-xs">{labelOrCode(SKILL_KIND_LABEL, it.kind)}</td>
            <td className="px-3 py-2 text-xs">{labelOrCode(SKILL_SCOPE_LABEL, it.scope_kind)}</td>
            <td className="px-3 py-2 text-xs">{preferenceLabel(it.tenant_preference)}</td>
            <td className="px-3 py-2">
              {it.is_attached
                ? <span className="text-xs text-gray-400">已装配</span>
                : <Button size="sm" onClick={() => attach(it)}><Plus size={12} /> 装配</Button>}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
