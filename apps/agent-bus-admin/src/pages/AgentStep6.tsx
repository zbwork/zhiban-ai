// Agent Step 6 — Capabilities Binding · /tenant/agents/{uuid}/capabilities
//
// 三类 binding + cron 能力面板:
//   Tab 1: Composer Skills (kind=composer_skill)
//   Tab 2: Apps (kind=app)
//   Tab 3: Knowledge Bases (kind=knowledge_base)
//   Tab 4: Cron — 只读面板, 展示 cron_supported + reason; 不挂 binding (cron job 走 /cron/jobs).
//
// API contract (round-6 P1-3 已对齐):
//   list      -> normalize CapabilityBinding (PascalCase) → AgentCapability (snake)
//   available -> already snake_case, top-level cron_supported / reason
//   attach    -> POST {capability_kind, capability_uuid, source:'borrow'} (后端要求)
//   patch     -> PATCH {pinned?, sort_order?}
//   detach    -> DELETE
//   reset     -> POST capabilities/reset-defaults
//   refresh   -> POST agent-card/refresh body:{capabilities}
//
// 适配在 src/lib/api.ts 完成, 页面内部用统一 AgentCapability DTO.

import { useEffect, useMemo, useState } from 'react'
import { useParams, useNavigate, useLocation } from 'react-router-dom'
import {
  AgentCapabilities, type AgentCapability, type AgentCapabilityKind,
  AgentKBBindings, type AgentKBBinding,
  TenantKB, type TenantKBItem,
  AgentApps, Apps, type App,
} from '../lib/api'
import { Button, Tabs } from '../components/ui'
import { Plus, X, Pin, RefreshCw } from 'lucide-react'

type Tab = AgentCapabilityKind | 'cron'

const TABS: Array<{ value: Tab; label: string }> = [
  { value: 'composer_skill', label: '技能' },
  { value: 'app', label: '应用' },
  { value: 'knowledge_base', label: '知识库' },
  { value: 'cron', label: '定时任务' },
]

// IA round-2: AgentDetail 顶部 Tab 用 location hash 跳进来选默认子 Tab。
//   #skill_app      → composer_skill
//   #app            → app
//   #knowledge_base → knowledge_base
//   #cron           → cron
const HASH_TO_TAB: Record<string, Tab> = {
  '#skill_app': 'composer_skill',
  '#composer_skill': 'composer_skill',
  '#app': 'app',
  '#knowledge_base': 'knowledge_base',
  '#kb': 'knowledge_base',
  '#cron': 'cron',
}

export function AgentStep6Page() {
  const params = useParams()
  const agentUUID = params.uuid || ''
  const nav = useNavigate()
  const loc = useLocation()
  const [tab, setTab] = useState<Tab>(() => HASH_TO_TAB[loc.hash] || 'composer_skill')
  // React "adjust state while rendering" 模式: hash 变化时直接调谐 tab, 不进 effect。
  const [prevHash, setPrevHash] = useState(loc.hash)
  if (loc.hash !== prevHash) {
    setPrevHash(loc.hash)
    const t = HASH_TO_TAB[loc.hash]
    if (t && t !== tab) setTab(t)
  }
  const [items, setItems] = useState<AgentCapability[]>([])
  const [available, setAvailable] = useState<AgentCapability[]>([])
  const [boundApps, setBoundApps] = useState<App[]>([])
  const [availableApps, setAvailableApps] = useState<App[]>([])
  const [cronSupported, setCronSupported] = useState(false)
  const [cronReason, setCronReason] = useState('')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)
  const [reloadTick, setReloadTick] = useState(0)
  const refresh = () => setReloadTick((t) => t + 1)

  useEffect(() => {
    if (!agentUUID) return
    let cancelled = false
    Promise.all([
      AgentCapabilities.list(agentUUID),
      AgentCapabilities.available(agentUUID),
      AgentApps.list(agentUUID),
      Apps.list({ status: 'active' }),
    ]).then(([l, a, appBindings, appPool]) => {
      if (cancelled) return
      setItems(l.items || [])
      setAvailable(a.items || [])
      setBoundApps(appBindings.items || [])
      setAvailableApps((appPool.items || []).filter(isAgentUsableApp))
      setCronSupported(a.cron_supported)
      setCronReason(a.cron_supported_reason || '')
    }).catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [agentUUID, reloadTick])

  const filtered = useMemo(() => {
    if (tab === 'cron') return []
    if (tab === 'app') return boundApps.map(appToCapability)
    return items.filter((i) => i.kind === tab)
  }, [items, boundApps, tab])
  const remaining = useMemo(() => {
    if (tab === 'cron') return []
    if (tab === 'app') {
      const bound = new Set(boundApps.map((i) => i.uuid))
      return availableApps.filter((a) => !bound.has(a.uuid)).map(appToCapability)
    }
    const bound = new Set(filtered.map((i) => i.resource_uuid))
    return available.filter((a) => a.kind === tab && !bound.has(a.resource_uuid))
  }, [filtered, available, availableApps, boundApps, tab])

  const attach = async (resourceUUID: string) => {
    if (tab === 'cron') return
    try {
      if (tab === 'app') {
        await AgentApps.bind(agentUUID, [...boundApps.map((a) => a.uuid), resourceUUID])
        refresh()
        return
      }
      await AgentCapabilities.attach(agentUUID, { kind: tab, resource_uuid: resourceUUID })
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }
  const detach = async (b: AgentCapability) => {
    if (tab === 'app') {
      try {
        await AgentApps.bind(agentUUID, boundApps.filter((a) => a.uuid !== b.resource_uuid).map((a) => a.uuid))
        refresh()
      } catch (e) { setErr((e as Error).message) }
      return
    }
    if (!b.binding_id) return
    try {
      await AgentCapabilities.detach(agentUUID, b.binding_id)
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }
  const togglePin = async (b: AgentCapability) => {
    if (tab === 'app') return
    if (!b.binding_id) return
    try {
      await AgentCapabilities.patch(agentUUID, b.binding_id, { pinned: !b.pinned })
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }
  const resetDefaults = async () => {
    if (!confirm('重置为默认装配? 已自定义的 pin/sort 会被覆盖')) return
    try {
      await AgentCapabilities.resetDefaults(agentUUID)
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }
  const refreshAgentCard = async () => {
    const raw = prompt('AgentCard capabilities JSON (manual upload, Phase A):\n例: {"streaming":true, "supports_cron":false, "supported_emp_blocks":["markdown","image"]}')
    if (raw === null) return
    let caps: Record<string, unknown> = {}
    if (raw.trim()) {
      try {
        caps = JSON.parse(raw)
      } catch {
        setErr('AgentCard capabilities JSON 非法')
        return
      }
    }
    try {
      const r = await AgentCapabilities.refreshAgentCard(agentUUID, caps)
      setErr(`AgentCard 刷新成功 (capabilities_declared keys: ${Object.keys(r.capabilities_declared || {}).join(', ')})`)
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }

  return (
    <div>
      <div className="flex items-baseline justify-between mb-6">
        <div>
          <h1 className="text-[28px] font-semibold tracking-tight">能力与应用</h1>
          <p className="text-[var(--color-ink-sub)] mt-1 text-sm font-mono">{agentUUID}</p>
        </div>
        <div className="space-x-2">
          <Button variant="ghost" onClick={() => nav(`/agents/${agentUUID}`)}>返回 Agent 详情</Button>
          <Button variant="secondary" onClick={resetDefaults}>重置默认</Button>
          <Button variant="secondary" onClick={refreshAgentCard}><RefreshCw size={14} /> AgentCard 刷新 (manual)</Button>
        </div>
      </div>

      <div className="mb-4">
        <Tabs<Tab> value={tab} items={TABS} onChange={setTab} />
      </div>

      {err && <div className="text-[13px] text-[var(--color-text-sub)] bg-[var(--color-bg-sub)] rounded-md p-3 mb-4">{err}</div>}

      {tab === 'cron' ? (
        <div className="bg-white rounded-lg card-shadow p-6">
          <h3 className="font-semibold mb-3">定时任务能力（只读）</h3>
          {cronSupported ? (
            <div className="text-green-700 mb-2">✓ 支持 cron</div>
          ) : (
            <div className="text-amber-700 mb-2">⚠ 当前不支持 cron</div>
          )}
          <div className="text-sm text-[var(--color-ink-mute)] mb-4">{cronReason}</div>
          <div className="text-xs text-[var(--color-ink-mute)] border-t pt-3 leading-relaxed">
            <p><strong>Cron capability gating (F02 v0.3):</strong> 仅 OpenClaw / Hermes framework 的 runtime environment 允许 cron;
            ZAP / 外部自托管 runtime 不在 Phase A 范围 (推 follow-up).</p>
            <p className="mt-2">
              本面板只读. cron job 创建走 <code>/cron/jobs</code> 端点; 平台运营能力冲突检查见
              <a className="text-[var(--color-brand)] ml-1" href="/cron-dashboard">/cron-dashboard</a>.
            </p>
          </div>
        </div>
      ) : (
        <>
        {tab === 'knowledge_base' && <KBBindingsPanelF07 agentUUID={agentUUID} />}
        <div className="grid grid-cols-2 gap-4">
          <div className="bg-white rounded-lg card-shadow p-4">
            <h3 className="font-semibold mb-3">已装配 ({filtered.length})</h3>
            <ul className="space-y-2">
              {filtered.map((b) => (
                <li key={b.binding_id || b.resource_uuid} className="flex items-center justify-between border border-[var(--color-line)] rounded-md p-3">
                  <div className="flex-1 min-w-0">
                    <div className="font-medium truncate">{b.resource_label}</div>
                    <div className="text-xs text-[var(--color-ink-mute)] font-mono truncate">{b.resource_uuid}</div>
                    {b.source && (
                      <div className="text-xs text-[var(--color-ink-mute)] mt-1">source: {b.source} · sort: {b.sort_order ?? 0}</div>
                    )}
                  </div>
                  <div className="flex items-center gap-1 ml-2">
                    {tab !== 'app' && (
                      <Button size="sm" variant="ghost" onClick={() => togglePin(b)} title={b.pinned ? '取消置顶' : '置顶'}>
                        <Pin size={14} className={b.pinned ? 'text-amber-500' : ''} />
                      </Button>
                    )}
                    <Button size="sm" variant="danger" onClick={() => detach(b)}><X size={14} /></Button>
                  </div>
                </li>
              ))}
              {!filtered.length && !loading && <li className="text-sm text-[var(--color-ink-mute)] p-4 text-center">该 Tab 暂无装配</li>}
            </ul>
          </div>

          <div className="bg-white rounded-lg card-shadow p-4">
            <h3 className="font-semibold mb-3">可装配 ({remaining.length})</h3>
            <ul className="space-y-2">
              {remaining.map((a) => (
                <li key={a.resource_uuid} className="flex items-center justify-between border border-[var(--color-line)] rounded-md p-3">
                  <div className="flex-1 min-w-0">
                    <div className="font-medium truncate">{a.resource_label}</div>
                    <div className="text-xs text-[var(--color-ink-mute)] font-mono truncate">{a.resource_uuid}</div>
                    {a.exec_kind && (
                      <div className="text-xs text-[var(--color-ink-mute)] mt-1">{a.exec_kind}{a.default_pinned ? ' · 默认置顶' : ''}</div>
                    )}
                  </div>
                  <Button size="sm" variant="secondary" onClick={() => attach(a.resource_uuid)}>
                    <Plus size={14} /> 装配
                  </Button>
                </li>
              ))}
              {!remaining.length && !loading && <li className="text-sm text-[var(--color-ink-mute)] p-4 text-center">无可装配资源</li>}
            </ul>
          </div>
        </div>
        </>
      )}
    </div>
  )
}

function isAgentUsableApp(app: App) {
  return app.usageScope !== 'end_user'
}

// F07 D5: agent_kb_bindings 是召回授权的权威表 (跟老 capability_bindings 平滑共存)。
// 老表只控制 AgentCard 上"展示哪些 KB chip"; 新表才能让 Recall 通过 assertAgentKBBound 检查。
// 老表无任何新表 binding 的 agent 现阶段仍走老表兜底, 但建议尽快迁移到新表。
function KBBindingsPanelF07({ agentUUID }: { agentUUID: string }) {
  const [bindings, setBindings] = useState<AgentKBBinding[]>([])
  const [allKBs, setAllKBs] = useState<TenantKBItem[]>([])
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const [showPicker, setShowPicker] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    if (!agentUUID) return
    let cancelled = false
    Promise.all([
      AgentKBBindings.list(agentUUID),
      TenantKB.list(),
    ]).then(([b, k]) => {
      if (cancelled) return
      setBindings(b.items || [])
      setAllKBs(k.items || [])
    }).catch((e: Error) => { if (!cancelled) setErr(e.message) })
    return () => { cancelled = true }
  }, [agentUUID, tick])

  const boundSet = new Set(bindings.map((b) => b.kb_uuid))
  const candidates = allKBs.filter((k) => !boundSet.has(k.uuid))

  const attach = async (kbUUID: string, kind: 'attached' | 'required' | 'optional') => {
    setBusy(true)
    try {
      await AgentKBBindings.attach(agentUUID, kbUUID, kind)
      setTick((t) => t + 1)
      setShowPicker(false)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }
  const detach = async (kbUUID: string) => {
    if (!confirm('解绑该 KB? Agent 将无法再召回此知识库。')) return
    setBusy(true)
    try {
      await AgentKBBindings.detach(agentUUID, kbUUID)
      setTick((t) => t + 1)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="font-semibold text-amber-900">
          F07 召回授权 (权威) · {bindings.length}
        </h3>
        <Button size="sm" variant="secondary" onClick={() => setShowPicker((s) => !s)} disabled={busy}>
          <Plus size={12} /> 授权新 KB
        </Button>
      </div>
      <p className="text-xs text-amber-800 mb-3">
        ⚠ 上方"已装配 / 可装配"控制 AgentCard 上的 KB chip 展示; <b>本面板</b>是 Recall API 真正的访问授权 (F07 D5)。
        新 Agent 必须在此授权才能调 RAGFlow 召回; 老 agent 平滑兼容 (新表为空时回退老 capability_bindings)。
      </p>
      {err && <div className="text-[12px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] rounded p-2 mb-2">{err}</div>}

      {showPicker && (
        <div className="bg-white border border-amber-200 rounded p-3 mb-3">
          <div className="text-xs text-[var(--color-ink-sub)] mb-2">选择 KB · binding_kind = attached (默认)</div>
          {candidates.length === 0 && (
            <div className="text-sm text-[var(--color-ink-mute)] py-2 text-center">无可授权 KB (已全部绑定 或 租户暂无 KB)</div>
          )}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
            {candidates.map((k) => (
              <button
                key={k.uuid}
                onClick={() => attach(k.uuid, 'attached')}
                disabled={busy}
                className="text-left border border-[var(--color-line)] rounded p-2 hover:bg-amber-50"
              >
                <div className="text-sm font-medium truncate">{k.name}</div>
                <div className="text-xs text-[var(--color-ink-mute)] font-mono truncate">{k.uuid}</div>
                <div className="text-xs text-[var(--color-ink-sub)] mt-0.5">{k.visibility || '—'} · {k.total_documents ?? 0} 文档</div>
              </button>
            ))}
          </div>
        </div>
      )}

      {bindings.length === 0 ? (
        <div className="text-sm text-amber-700 bg-amber-100 rounded p-2">
          🟠 当前 agent 在 F07 新表无任何授权 → 走老表兼容路径 (任何老的 capability_binding KB 都可召回)。
          建议尽快显式授权。
        </div>
      ) : (
        <ul className="space-y-1.5">
          {bindings.map((b) => (
            <li key={b.kb_uuid} className="flex items-center justify-between bg-white border border-amber-200 rounded p-2">
              <div className="flex-1 min-w-0">
                <div className="text-sm font-medium truncate">{b.kb_name}</div>
                <div className="text-xs text-[var(--color-ink-mute)] font-mono truncate">{b.kb_uuid}</div>
                <div className="text-xs text-[var(--color-ink-sub)] mt-0.5">
                  kind={b.binding_kind} · priority={b.priority}
                  {b.note ? ` · ${b.note}` : ''}
                </div>
              </div>
              <Button size="sm" variant="danger" onClick={() => detach(b.kb_uuid)} disabled={busy}>
                <X size={12} />
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

function appToCapability(app: App): AgentCapability {
  return {
    kind: 'app',
    resource_uuid: app.uuid,
    resource_label: app.name,
    display_mode: app.displayMode,
  }
}
