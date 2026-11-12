// F09 RoomDetail (B4 follow-up): /rooms/:uuid 详情 + 数字员工响应记录 tab.
//
// 当前 PR8 范围: 仅"数字员工响应记录"tab (覆盖 PR7 留下的 RoomDetail Speaker decisions tab).
// 房间元数据 + 触发记录 复用 AdminRooms.get / AdminRooms.triggers 已有 API.

import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link, useParams } from 'react-router-dom'
import {
  AdminRooms,
  AdminSpeakerDecisions,
  type AdminRoomSummary,
  type AdminSpeakerDecision,
} from '../lib/api'
import {
  DataTable,
  EmptyState,
  FormSection,
  InlineAlert,
  PageHeader,
  Pagination,
  Panel,
  Tabs,
} from '../components/ui'

type TabKey = 'overview' | 'responses' | 'diagnostics'

const STATUS_LABEL: Record<string, string> = {
  active: '进行中',
  paused: '已暂停',
  completed: '已结束',
  archived: '已归档',
}

const STATUS_PILL_CLASS: Record<string, string> = {
  active: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  paused: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  completed: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  archived: 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]',
}

const SPEAKER_POLICY_LABEL: Record<string, string> = {
  manual: '仅被 @ 时响应',
  manager: 'Manager 调度',
  round_robin: '轮流响应',
  auto_llm: '智能判断响应',
  parallel: '多数字员工并行',
  handoff: '数字员工交接',
}

const SELECTION_KIND_LABEL: Record<string, string> = {
  single: '单个数字员工响应',
  parallel: '多数字员工并行',
  none: '未选中数字员工',
}

const WINDOWS = [
  { label: '近 24 小时', hours: 24 },
  { label: '近 7 天', hours: 24 * 7 },
  { label: '近 30 天', hours: 24 * 30 },
]

function defaultFrom(hours: number): string {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString()
}

export default function RoomDetailPage() {
  const { uuid = '' } = useParams<{ uuid: string }>()
  const [room, setRoom] = useState<AdminRoomSummary | null>(null)
  const [tab, setTab] = useState<TabKey>('overview')
  const [err, setErr] = useState('')

  useEffect(() => {
    let mounted = true
    if (!uuid) return
    AdminRooms.get(uuid)
      .then((r) => mounted && setRoom(r))
      .catch((e: unknown) => mounted && setErr((e as Error).message || '加载失败'))
    return () => { mounted = false }
  }, [uuid])

  return (
    <div className="p-6 space-y-4 max-w-6xl">
      <PageHeader
        title={room ? `群聊 · ${room.title}` : '群聊详情'}
        subtitle={
          <span className="text-xs">
            <Link to="/rooms" className="text-[var(--color-brand)] hover:underline">← 返回列表</Link>
          </span>
        }
      />

      {err && <InlineAlert tone="danger">{err}</InlineAlert>}

      <Tabs
        value={tab}
        onChange={setTab}
        items={[
          { value: 'overview', label: '概览' },
          { value: 'responses', label: '数字员工响应记录' },
          { value: 'diagnostics', label: '高级诊断' },
        ]}
      />

      {tab === 'overview' && <OverviewPane room={room} />}
      {tab === 'responses' && uuid && <ResponsesPane roomUUID={uuid} />}
      {tab === 'diagnostics' && <DiagnosticsPane room={room} />}
    </div>
  )
}

function OverviewPane({ room }: { room: AdminRoomSummary | null }) {
  if (!room) return <div className="text-sm text-[var(--color-text-sub)]">加载中...</div>
  return (
    <Panel>
      <FormSection title="基本">
        <KV k="群状态" v={<RoomStatusPill status={room.status} />} />
        <KV k="协作状态" v={<CollaborationPill room={room} />} />
        <KV k="数字员工响应方式" v={SPEAKER_POLICY_LABEL[room.speaker_policy] || '未配置'} />
        <KV k="员工数" v={String(room.human_count)} />
        <KV k="数字员工数" v={String(room.agent_count)} />
        <KV k="24h @数字员工" v={`${room.triggers_24h} 次`} />
        <KV k="创建时间" v={new Date(room.created_at).toLocaleString('zh-CN', { hour12: false })} />
      </FormSection>
    </Panel>
  )
}

function DiagnosticsPane({ room }: { room: AdminRoomSummary | null }) {
  if (!room) return <div className="text-sm text-[var(--color-text-sub)]">加载中...</div>
  return (
    <Panel>
      <FormSection
        title="高级诊断"
        description="以下字段用于接口联调、底座同步和排障；日常群治理优先看概览和数字员工响应记录。"
      >
        <KV k="UUID" v={room.uuid} mono />
        <KV k="类型" v={room.room_kind} />
        <KV k="原始状态" v={room.status} />
        <KV k="原始响应策略" v={room.speaker_policy} />
        {room.manager_agent_uuid && <KV k="Manager Agent UUID" v={room.manager_agent_uuid} mono />}
        <KV
          k="WuKong channel"
          v={room.wukong_channel_id ? `${room.wukong_channel_id} (${room.wukong_channel_type || '-'})` : '-'}
          mono
        />
        <KV k="冻结标记" v={room.frozen ? 'true' : 'false'} />
      </FormSection>
    </Panel>
  )
}

function ResponsesPane({ roomUUID }: { roomUUID: string }) {
  const [items, setItems] = useState<AdminSpeakerDecision[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const pageSize = 20
  const [hours, setHours] = useState(7 * 24)
  const [err, setErr] = useState('')

  useEffect(() => {
    let mounted = true
    AdminSpeakerDecisions.listByRoom(roomUUID, { from: defaultFrom(hours), page, page_size: pageSize })
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
  }, [roomUUID, hours, page])

  return (
    <Panel>
      <FormSection title="数字员工响应记录" description={`命中 ${total} 条 · 展示本群数字员工被选中响应的记录。`}>
        <div className="flex gap-2 mb-3">
          {WINDOWS.map((w) => (
            <button
              key={w.hours}
              onClick={() => { setHours(w.hours); setPage(1) }}
              className={`h-8 px-3 rounded text-xs border ${
                hours === w.hours
                  ? 'border-[var(--color-brand)] bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
                  : 'border-[var(--color-line)] bg-[var(--color-surface)] text-[var(--color-text-sub)]'
              }`}
            >
              {w.label}
            </button>
          ))}
        </div>

        {err && <InlineAlert tone="danger">{err}</InlineAlert>}

        <DataTable
          headers={['时间', '响应方式', '选中数字员工', '响应原因', '候选数', '处理耗时']}
        >
          {items.length === 0 ? (
            <tr>
              <td colSpan={6} className="px-3 py-8">
                <EmptyState
                  title="窗内无数字员工响应记录"
                  description="可能是本群未 @ 数字员工，或当前响应方式不产生自动决策。"
                />
              </td>
            </tr>
          ) : items.map((d) => <DecisionRow key={d.uuid} d={d} />)}
        </DataTable>

        <Pagination page={page} pageSize={pageSize} total={total} onPageChange={setPage} onPageSizeChange={() => { /* fixed */ }} />
      </FormSection>
    </Panel>
  )
}

function DecisionRow({ d }: { d: AdminSpeakerDecision }) {
  const candCount = useMemo(() => {
    if (Array.isArray(d.candidates)) return d.candidates.length
    return null
  }, [d.candidates])
  return (
    <tr className="border-t border-[var(--color-line-soft)]" title={d.policy_name ? `policy: ${d.policy_name} (${d.policy_uuid?.slice(0, 8)})` : ''}>
      <td className="px-3 py-2 text-xs text-[var(--color-text-sub)]">{new Date(d.created_at).toLocaleString('zh-CN', { hour12: false })}</td>
      <td className="px-3 py-2 text-xs">{formatResponseMode(d)}</td>
      <td className="px-3 py-2">{d.selected_agent_name || (d.selected_agent_id ? `#${d.selected_agent_id}` : '-')}</td>
      <td className="px-3 py-2 max-w-md truncate text-xs text-[var(--color-text-sub)]" title={d.selected_reason || ''}>{d.selected_reason || '-'}</td>
      <td className="px-3 py-2 text-right tabular-nums">{candCount ?? '-'}</td>
      <td className="px-3 py-2 text-right tabular-nums">{formatLatency(d.latency_ms)}</td>
    </tr>
  )
}

function RoomStatusPill({ status }: { status: string }) {
  return (
    <span className={`inline-flex items-center rounded-md px-2 py-0.5 text-[12px] font-medium ${STATUS_PILL_CLASS[status] || STATUS_PILL_CLASS.archived}`}>
      {STATUS_LABEL[status] || status}
    </span>
  )
}

function CollaborationPill({ room }: { room: AdminRoomSummary }) {
  if (room.frozen) {
    return (
      <span className="inline-flex items-center rounded-md bg-[var(--color-warn-bg)] px-2 py-0.5 text-[12px] font-medium text-[var(--color-warn)]">
        已冻结
      </span>
    )
  }
  if (room.status === 'paused') {
    return (
      <span className="inline-flex items-center rounded-md bg-[var(--color-warn-bg)] px-2 py-0.5 text-[12px] font-medium text-[var(--color-warn)]">
        待检查
      </span>
    )
  }
  return (
    <span className="inline-flex items-center rounded-md bg-[var(--color-success-bg)] px-2 py-0.5 text-[12px] font-medium text-[var(--color-success)]">
      正常
    </span>
  )
}

function formatResponseMode(d: AdminSpeakerDecision) {
  const policy = SPEAKER_POLICY_LABEL[d.base_policy] || d.base_policy || '未配置'
  const kind = SELECTION_KIND_LABEL[d.selection_kind]
  if (!kind || d.selection_kind === 'single') return policy
  return `${policy} · ${kind}`
}

function formatLatency(latency: number | undefined) {
  if (latency == null) return '-'
  return `${latency} ms`
}

function KV({ k, v, mono }: { k: string; v: ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline gap-3 text-sm py-0.5">
      <div className="w-36 shrink-0 text-[var(--color-text-mute)]">{k}</div>
      <div className={`flex-1 ${mono ? 'font-mono text-xs break-all' : ''}`}>{v}</div>
    </div>
  )
}
