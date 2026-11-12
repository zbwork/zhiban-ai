// F09 §5.14: IM 运行监控（平台 scope）。路由 /wukongim。

import { useCallback, useEffect, useState } from 'react'
import { Activity, AlertTriangle, Cable, History, Radio, RefreshCw, Settings, Users } from 'lucide-react'
import {
  WuKongIMAdmin,
  type IMConnectionEvent,
  type IMConnectionOverview,
  type IMConnectionState,
  type WuKongIMConfig,
  type WuKongIMProbeResult,
  type WuKongIMStats,
} from '../lib/api'
import {
  Button, DataTable, DrawerShell, EmptyState, InlineAlert, Input, KpiCard,
  Pagination, Panel, Select, stickyLeftTdCls, stickyRightTdCls, Tabs,
} from '../components/ui'

type Tab = 'connections' | 'anomalies' | 'events' | 'config'
const TAB_ITEMS: Array<{ value: Tab; label: string }> = [
  { value: 'connections', label: '在线连接' }, { value: 'anomalies', label: '异常设备' },
  { value: 'events', label: '连接事件' }, { value: 'config', label: '配置与探活' },
]
const DEVICE_LABEL: Record<number, string> = { 0: '移动 App', 1: 'Web', 2: '桌面端' }
const EVENT_LABEL: Record<string, string> = { connected: '首次连接', reconnected: '重新连接', disconnected: '断开连接' }
const REASON_LABEL: Record<string, string> = {
  observed: '首次在在线快照中发现',
  returned_after_missing_snapshots: '离线后重新出现在在线快照',
  connection_replaced: '在线连接编号发生替换',
  missing_two_snapshots: '连续两次采集未发现（推断断开）',
}

function initialTab(): Tab {
  const value = new URLSearchParams(window.location.search).get('tab')
  return TAB_ITEMS.some((item) => item.value === value) ? (value as Tab) : 'connections'
}
function formatTime(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString('zh-CN', { hour12: false })
}
function formatProtocolVersion(value?: string) {
  if (!value) return '-'
  return /^v/i.test(value) ? value : `v${value}`
}
function eventReasonLabel(event: IMConnectionEvent) {
  return event.reason ? REASON_LABEL[event.reason] || event.reason : '-'
}
function eventDeviceLabel(event: IMConnectionEvent) {
  return event.data_quality === 'legacy_unreliable' ? '设备类型未知' : DEVICE_LABEL[event.device_flag] || `未知类型（${event.device_flag}）`
}

export default function WuKongIMStatus() {
  const [tab, setTab] = useState<Tab>(initialTab)
  const [overview, setOverview] = useState<IMConnectionOverview | null>(null)
  const [items, setItems] = useState<IMConnectionState[]>([])
  const [events, setEvents] = useState<IMConnectionEvent[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState(tab === 'connections' ? 'online' : '')
  const [deviceFlag, setDeviceFlag] = useState('')
  const [eventType, setEventType] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [selected, setSelected] = useState<IMConnectionState | null>(null)
  const [detailEvents, setDetailEvents] = useState<IMConnectionEvent[]>([])

  const refreshOverview = useCallback(async () => {
    try { setOverview(await WuKongIMAdmin.overview()) }
    catch (e) { setError((e as Error).message || '运行概览加载失败') }
  }, [])
  const refreshList = useCallback(async () => {
    if (tab === 'config') return
    setLoading(true); setError('')
    try {
      const tenantId = Number(new URLSearchParams(window.location.search).get('tenant_id')) || undefined
      if (tab === 'events') {
        const out = await WuKongIMAdmin.events({ tenant_id: tenantId, event_type: eventType || undefined, page, page_size: pageSize })
        setEvents(out.items); setTotal(out.total)
      } else {
        const out = await WuKongIMAdmin.connections({
          q: query.trim() || undefined, tenant_id: tenantId, status: status || undefined,
          anomalous: tab === 'anomalies' || undefined,
          device_flag: deviceFlag === '' ? undefined : Number(deviceFlag), page, page_size: pageSize,
        })
        setItems(out.items); setTotal(out.total)
      }
    } catch (e) { setError((e as Error).message || '连接数据加载失败') }
    finally { setLoading(false) }
  }, [deviceFlag, eventType, page, pageSize, query, status, tab])

  useEffect(() => {
    const timer = window.setTimeout(() => void refreshOverview(), 0)
    return () => window.clearTimeout(timer)
  }, [refreshOverview])
  useEffect(() => {
    const timer = window.setTimeout(() => void refreshList(), 0)
    return () => window.clearTimeout(timer)
  }, [refreshList])
  useEffect(() => {
    const target = new URLSearchParams(window.location.search).get('connection')
    if (target) WuKongIMAdmin.connection(target).then(openDetail).catch(() => undefined)
  }, [])

  function changeTab(next: Tab) {
    setTab(next); setPage(1); setStatus(next === 'connections' ? 'online' : '')
    const params = new URLSearchParams(window.location.search); params.set('tab', next)
    window.history.replaceState(null, '', `${window.location.pathname}?${params}`)
  }
  async function openDetail(item: IMConnectionState) {
    setSelected(item); setDetailEvents([])
    try { setDetailEvents((await WuKongIMAdmin.events({ state_uuid: item.uuid, page: 1, page_size: 20 })).items) }
    catch { /* 主详情仍可用 */ }
  }

  return <div className="p-6"><div className="mx-auto max-w-[1440px] space-y-4">
    <header className="flex flex-wrap items-start justify-between gap-3"><div>
      <h1 className="text-xl font-semibold text-[var(--color-text)]">IM 运行监控</h1>
      <p className="mt-1 text-sm text-[var(--color-text-sub)]">按租户、用户和设备查看 WuKongIM 连接状态，定位频繁重连与异常断开。</p>
    </div><Button variant="secondary" onClick={() => { void refreshOverview(); void refreshList() }} disabled={loading}><RefreshCw size={15} />刷新</Button></header>
    {error && <InlineAlert tone="danger">{error}</InlineAlert>}
    {overview?.collector.last_error && <InlineAlert tone="warn">连接采集暂时异常，页面保留最近一次成功快照。最近成功：{formatTime(overview.collector.last_success_at)}。</InlineAlert>}
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
      <KpiCard label="在线连接" value={overview?.online_connections ?? '-'} icon={<Cable size={15} />} />
      <KpiCard label="在线用户" value={overview?.online_users ?? '-'} icon={<Users size={15} />} />
      <KpiCard label="在线租户" value={overview?.online_tenants ?? '-'} />
      <KpiCard label="异常设备" value={overview?.anomalous_devices ?? '-'} tone={overview?.anomalous_devices ? 'danger' : undefined} icon={<AlertTriangle size={15} />} />
      <KpiCard label="1h 恢复 / 替换" value={overview ? `${overview.recoveries_1h} / ${overview.replacements_1h}` : '-'} hint={`恢复在线 / 在线连接替换 · 最近采集 ${formatTime(overview?.collector.last_success_at)}`} icon={<Activity size={15} />} />
    </div>
    <Tabs<Tab> value={tab} items={TAB_ITEMS} onChange={changeTab} variant="underline" />
    {tab === 'config' ? <Configuration /> : tab === 'events' ?
      <EventsView events={events} total={total} page={page} pageSize={pageSize} loading={loading} eventType={eventType}
        onEventType={(v) => { setEventType(v); setPage(1) }} onPage={setPage} onPageSize={(v) => { setPageSize(v); setPage(1) }} /> :
      <ConnectionsView items={items} total={total} page={page} pageSize={pageSize} loading={loading} query={query} status={status}
        deviceFlag={deviceFlag} anomalies={tab === 'anomalies'} onQuery={(v) => { setQuery(v); setPage(1) }}
        onStatus={(v) => { setStatus(v); setPage(1) }} onDeviceFlag={(v) => { setDeviceFlag(v); setPage(1) }}
        onPage={setPage} onPageSize={(v) => { setPageSize(v); setPage(1) }} onOpen={openDetail} />}
  </div>{selected && <ConnectionDrawer item={selected} events={detailEvents} onClose={() => setSelected(null)} />}</div>
}

function ConnectionsView({ items, total, page, pageSize, loading, query, status, deviceFlag, anomalies, onQuery, onStatus, onDeviceFlag, onPage, onPageSize, onOpen }: {
  items: IMConnectionState[]; total: number; page: number; pageSize: number; loading: boolean; query: string; status: string; deviceFlag: string; anomalies: boolean
  onQuery: (v: string) => void; onStatus: (v: string) => void; onDeviceFlag: (v: string) => void; onPage: (v: number) => void; onPageSize: (v: number) => void; onOpen: (v: IMConnectionState) => void
}) {
  return <><Panel className="p-3"><div className="flex flex-wrap gap-2">
    <Input className="max-w-[320px]" value={query} onChange={(e) => onQuery(e.target.value)} placeholder="搜索租户、用户或 UID" />
    <div className="w-[150px]"><Select value={status} onChange={(e) => onStatus(e.target.value)}><option value="">全部状态</option><option value="online">在线</option><option value="offline">离线</option></Select></div>
    <div className="w-[160px]"><Select value={deviceFlag} onChange={(e) => onDeviceFlag(e.target.value)}><option value="">全部设备类型</option><option value="0">移动 App</option><option value="1">Web</option><option value="2">桌面端</option></Select></div>
  </div></Panel>
  <DataTable headers={['租户', '用户', 'WuKong 设备类型', '状态', '客户端版本', '协议版本', '最近活动', '5m / 1h 重连', '操作']}
    stickyFirstCol stickyLastCol
    loading={loading ? <div className="p-8 text-center text-sm text-[var(--color-text-mute)]">加载中…</div> : undefined}
    empty={!loading && items.length === 0 ? <EmptyState icon={anomalies ? <AlertTriangle size={26} /> : <Cable size={26} />} title={anomalies ? '当前没有异常设备' : '当前筛选下没有连接'} description={anomalies ? '频繁重连阈值：5 分钟 ≥5 次或 1 小时 ≥10 次。' : '可调整状态、设备类型或搜索条件。'} tone={anomalies ? 'success' : 'neutral'} /> : undefined}>
    {items.map((item) => <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
      <td className={`${stickyLeftTdCls} px-4 py-3`}><div className="font-medium">{item.tenant_name || `租户 ${item.tenant_id}`}</div><div className="text-xs text-[var(--color-text-mute)]">ID {item.tenant_id}</div></td>
      <td className="px-4 py-3"><div className="font-medium">{item.account_name || item.subject_uuid || '未匹配账号'}</div><div className="max-w-[220px] truncate font-mono text-xs text-[var(--color-text-mute)]" title={item.uid}>{item.uid}</div></td>
      <td className="px-4 py-3" title="WuKong 设备大类，不代表具体操作系统"><div>{DEVICE_LABEL[item.device_flag] || `未知类型（${item.device_flag}）`}</div><div className="font-mono text-xs text-[var(--color-text-mute)]">{item.device_id_masked}</div></td>
      <td className="px-4 py-3"><Status value={item.status} anomalous={item.anomalous} /></td>
      <td className="px-4 py-3"><div className="font-mono text-[var(--color-text-sub)]">{item.client_version || '—'}</div>{(item.client_platform || item.client_os_version) && <div className="text-xs text-[var(--color-text-mute)]">{[item.client_platform, item.client_os_version].filter(Boolean).join(' · ')}</div>}</td>
      <td className="px-4 py-3 font-mono text-[var(--color-text-sub)]">{formatProtocolVersion(item.protocol_version)}</td>
      <td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(item.last_activity_at || item.last_seen_at)}</td>
      <td className="px-4 py-3 tabular-nums" title="离线恢复与在线连接替换的合计"><span className={item.anomalous ? 'font-semibold text-[var(--color-danger)]' : ''}>{item.reconnects_5m} / {item.reconnects_1h}</span></td>
      <td className={`${stickyRightTdCls} px-4 py-3`}><Button variant="ghost" size="sm" onClick={() => onOpen(item)}>详情</Button></td>
    </tr>)}
  </DataTable><Pagination total={total} page={page} pageSize={pageSize} onPageChange={onPage} onPageSizeChange={onPageSize} /></>
}

function EventsView({ events, total, page, pageSize, loading, eventType, onEventType, onPage, onPageSize }: {
  events: IMConnectionEvent[]; total: number; page: number; pageSize: number; loading: boolean; eventType: string; onEventType: (v: string) => void; onPage: (v: number) => void; onPageSize: (v: number) => void
}) {
  return <><Panel className="p-3"><div className="w-[180px]"><Select value={eventType} onChange={(e) => onEventType(e.target.value)}><option value="">全部事件</option><option value="connected">首次连接</option><option value="reconnected">重新连接</option><option value="disconnected">断开连接</option></Select></div></Panel>
  <DataTable headers={['时间', '事件', '租户', '用户', '设备', '连接编号', '原因']} loading={loading ? <div className="p-8 text-center text-sm text-[var(--color-text-mute)]">加载中…</div> : undefined} empty={!loading && events.length === 0 ? <EmptyState icon={<History size={26} />} title="暂无连接事件" description="事件保留 30 天。" /> : undefined}>
    {events.map((event) => <tr key={event.uuid} className="hover:bg-[var(--color-bg-sub)]"><td className="whitespace-nowrap px-4 py-3 text-[var(--color-text-sub)]">{formatTime(event.occurred_at)}</td><td className="px-4 py-3 font-medium">{EVENT_LABEL[event.event_type] || event.event_type}</td><td className="px-4 py-3">{event.tenant_name || `租户 ${event.tenant_id}`}</td><td className="px-4 py-3">{event.account_name || event.uid}</td><td className="px-4 py-3"><div>{eventDeviceLabel(event)} · {event.device_id_masked}</div>{event.data_quality === 'legacy_unreliable' && <div className="text-xs text-[var(--color-warn)]">历史采集异常</div>}</td><td className="px-4 py-3 font-mono text-xs">{event.data_quality === 'legacy_unreliable' ? '—' : event.connection_id}</td><td className="px-4 py-3 text-[var(--color-text-sub)]"><div>{eventReasonLabel(event)}</div>{event.data_quality === 'legacy_unreliable' && <div className="text-xs text-[var(--color-text-mute)]">设备类型和连接编号不可信</div>}</td></tr>)}
  </DataTable><Pagination total={total} page={page} pageSize={pageSize} onPageChange={onPage} onPageSizeChange={onPageSize} /></>
}

function ConnectionDrawer({ item, events, onClose }: { item: IMConnectionState; events: IMConnectionEvent[]; onClose: () => void }) {
  const rows: Array<[string, string]> = [['租户', `${item.tenant_name || '-'}（ID ${item.tenant_id}）`], ['用户', item.account_name || '未匹配账号'], ['账号 UUID', item.account_uuid || '-'], ['WuKong UID', item.uid], ['WuKong 设备类型', DEVICE_LABEL[item.device_flag] || `未知类型（${item.device_flag}）`], ['设备 ID（脱敏）', item.device_id_masked], ['设备精度', item.device_id_available ? '精确设备（已哈希）' : '仅设备类型，可能合并多台设备'], ['客户端版本', item.client_version || '未上报'], ['客户端平台', item.client_platform || '未上报'], ['操作系统版本', item.client_os_version || '未上报'], ['主从级别', item.device_level === 1 ? '主设备' : '从设备'], ['连接编号', String(item.connection_id)], ['WuKong 协议版本', formatProtocolVersion(item.protocol_version)], ['连接时间', formatTime(item.connected_at)], ['最近活动', formatTime(item.last_activity_at)], ['最近采集', formatTime(item.last_seen_at)], ['5m / 1h 重连', `${item.reconnects_5m} / ${item.reconnects_1h}`]]
  return <DrawerShell title={`连接详情 · ${item.account_name || item.subject_uuid}`} subtitle={`${item.tenant_name} · ${DEVICE_LABEL[item.device_flag] || '未知设备'}`} onClose={onClose} width="lg" variant="polished" footer={<div className="flex justify-end"><Button variant="secondary" onClick={onClose}>关闭</Button></div>}><div className="space-y-5">
    <InlineAlert tone="info">WuKong 设备类型和协议版本来自长连接握手；客户端版本与操作系统版本由知办客户端上报，并按同一设备标识精确关联。老客户端未上报时显示“未上报”。</InlineAlert>
    {item.anomalous && <InlineAlert tone="warn">该设备达到频繁重连阈值，建议先核对知办 App 版本、多端登录策略和网络切换情况。</InlineAlert>}
    <dl className="grid grid-cols-[140px_1fr] gap-x-5 gap-y-3 text-sm">{rows.map(([key, value]) => <div className="contents" key={key}><dt className="text-[var(--color-text-sub)]">{key}</dt><dd className="break-all text-[var(--color-text)]">{value}</dd></div>)}</dl>
    <div><h3 className="mb-3 text-sm font-semibold">最近连接事件</h3>{events.length ? <div className="space-y-2">{events.map((event) => <div key={event.uuid} className="flex items-center justify-between gap-3 rounded-md border border-[var(--color-line)] px-3 py-2 text-sm"><span>{EVENT_LABEL[event.event_type] || event.event_type} · {eventReasonLabel(event)}{event.data_quality === 'legacy_unreliable' ? ' · 历史采集异常' : ''}</span><span className="shrink-0 text-xs text-[var(--color-text-mute)]">{formatTime(event.occurred_at)}</span></div>)}</div> : <p className="text-sm text-[var(--color-text-mute)]">暂无事件记录。</p>}</div>
  </div></DrawerShell>
}

function Configuration() {
  const [cfg, setCfg] = useState<WuKongIMConfig | null>(null), [stats, setStats] = useState<WuKongIMStats | null>(null)
  const [probe, setProbe] = useState<WuKongIMProbeResult | null>(null), [probing, setProbing] = useState(false)
  useEffect(() => { Promise.all([WuKongIMAdmin.config(), WuKongIMAdmin.stats()]).then(([c, s]) => { setCfg(c); setStats(s) }).catch(() => undefined) }, [])
  async function runProbe() { setProbing(true); try { setProbe(await WuKongIMAdmin.probe()) } catch (e) { setProbe({ status: 'error', latency_ms: 0, message: (e as Error).message || '探测失败' }) } finally { setProbing(false) } }
  return <div className="grid gap-4 lg:grid-cols-2"><Panel className="p-5"><div className="mb-4 flex items-center justify-between"><h2 className="flex items-center gap-2 text-sm font-semibold"><Settings size={16} />连接配置</h2><Button variant="secondary" size="sm" onClick={runProbe} disabled={probing}>{probing ? '探测中…' : '测试连通性'}</Button></div>
    {cfg ? <dl className="grid grid-cols-[150px_1fr] gap-y-3 text-sm"><dt className="text-[var(--color-text-sub)]">已启用</dt><dd>{cfg.enabled ? '是' : '否'}</dd><dt className="text-[var(--color-text-sub)]">特权 REST</dt><dd>{cfg.api_addr_configured ? '已配置' : '未配置'}</dd><dt className="text-[var(--color-text-sub)]">TCP 地址</dt><dd className="font-mono text-xs">{cfg.tcp_addr || '-'}</dd><dt className="text-[var(--color-text-sub)]">WS 地址</dt><dd className="font-mono text-xs">{cfg.ws_addr || '-'}</dd><dt className="text-[var(--color-text-sub)]">Webhook Secret</dt><dd>{cfg.webhook_secret_configured ? '已配置' : '未配置'}</dd></dl> : <p className="text-sm text-[var(--color-text-mute)]">加载中…</p>}
    {probe && <div className="mt-4"><InlineAlert tone={probe.status === 'ok' ? 'success' : 'danger'}>连通性：{probe.status} · {probe.latency_ms}ms{probe.message ? ` · ${probe.message}` : ''}</InlineAlert></div>}
  </Panel><Panel className="p-5"><h2 className="mb-4 flex items-center gap-2 text-sm font-semibold"><Radio size={16} />24h 业务指标</h2>{stats ? <div className="grid grid-cols-2 gap-3"><KpiCard label="新增频道链接" value={stats.rooms_linked_24h} /><KpiCard label="频道链接总数" value={stats.rooms_linked_total} /><KpiCard label="@Agent 事件" value={stats.agent_triggers_last_24h} /><KpiCard label="拒绝事件" value={stats.webhook_rejects_last_24h} /></div> : <p className="text-sm text-[var(--color-text-mute)]">加载中…</p>}</Panel></div>
}

function Status({ value, anomalous }: { value: string; anomalous: boolean }) {
  if (anomalous) return <span className="rounded-full bg-[var(--color-danger-bg)] px-2 py-1 text-xs font-medium text-[var(--color-danger)]">频繁重连</span>
  return <span className={value === 'online' ? 'text-[var(--color-success)]' : 'text-[var(--color-text-mute)]'}>{value === 'online' ? '在线' : '离线'}</span>
}
