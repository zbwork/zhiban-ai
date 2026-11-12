// 群聊列表页 (租户 scope).
// 路由 /rooms. admin-web-design-standard §4: 工具栏右侧主操作 / 一列一字段 / 中文化空态 / 后端分页.

import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { AdminRooms, type AdminRoomSummary } from '../lib/api'
import {
  Button,
  DataTable,
  EmptyState,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Toolbar,
  stickyRightTdCls,
} from '../components/ui'

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

export default function Rooms() {
  const [items, setItems] = useState<AdminRoomSummary[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [status, setStatus] = useState('')
  const [q, setQ] = useState('')
  const [err, setErr] = useState('')

  useEffect(() => {
    let mounted = true
    AdminRooms.list({
      room_kind: 'group',
      status: status || undefined,
      q: q || undefined,
      page,
      page_size: pageSize,
    })
      .then((r) => {
        if (!mounted) return
        setItems(r.items || [])
        setTotal(r.total)
        setErr('')
      })
      .catch((e: unknown) => {
        if (!mounted) return
        setErr((e as Error).message || '加载失败')
      })
    return () => {
      mounted = false
    }
    // q 不放依赖里 — Enter 触发重新拉, 不随键入抖动
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, status, pageSize])

  async function reload() {
    try {
      const r = await AdminRooms.list({
        room_kind: 'group',
        status: status || undefined,
        q: q || undefined,
        page,
        page_size: pageSize,
      })
      setItems(r.items || [])
      setTotal(r.total)
      setErr('')
    } catch (e: unknown) {
      setErr((e as Error).message || '加载失败')
    }
  }

  return (
    <div>
      <PageHeader
        title="群聊"
        subtitle="查看本租户群聊、员工与数字员工规模、@数字员工触发和协作状态。"
      />

      <form
        onSubmit={(e) => {
          e.preventDefault()
          setPage(1)
          void reload()
        }}
      >
        <Toolbar
          search={
            <SearchInput
              value={q}
              onChange={setQ}
              placeholder="按群名搜索"
            />
          }
          filters={(
            <div className="w-[140px]">
              <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
                <option value="">全部状态</option>
                <option value="active">进行中</option>
                <option value="paused">已暂停</option>
                <option value="completed">已结束</option>
                <option value="archived">已归档</option>
              </Select>
            </div>
          )}
          summary={<>共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 条</>}
          actions={<Button type="submit" variant="secondary">搜索</Button>}
        />
      </form>

      {err && (
        <div className="rounded border border-[var(--color-danger)] bg-[var(--color-danger-bg)] px-3 py-2 text-sm text-[var(--color-danger)]">
          加载失败: {err}
        </div>
      )}

      <DataTable
        headers={['群聊名称', '员工数', '数字员工数', '数字员工响应方式', '24h @数字员工', '协作状态', '群状态', '操作']}
        stickyLastCol
        empty={items.length === 0 ? <EmptyState title="暂无群聊数据" description="当前租户还没有可展示的群聊。" /> : null}
      >
        {items.map((r) => (
          <tr key={r.uuid} className="group transition hover:bg-[var(--color-bg-sub)]/60">
            <td className="max-w-[22em] truncate px-4 py-3 font-medium text-[var(--color-text)]">{r.title || '—'}</td>
            <td className="px-4 py-3 text-right tabular-nums text-[var(--color-text)]">{r.human_count}</td>
            <td className="px-4 py-3 text-right tabular-nums text-[var(--color-text)]">{r.agent_count}</td>
            <td className="px-4 py-3 text-[var(--color-text)]">{SPEAKER_POLICY_LABEL[r.speaker_policy] || '未配置'}</td>
            <td className="px-4 py-3 text-right tabular-nums text-[var(--color-text)]">{r.triggers_24h}</td>
            <td className="px-4 py-3">
              <CollaborationPill room={r} />
            </td>
            <td className="px-4 py-3">
              <RoomStatusPill status={r.status} />
            </td>
            <td className={`${stickyRightTdCls} px-4 py-3`}>
              <Link to={`/rooms/${encodeURIComponent(r.uuid)}`} className="font-medium text-[var(--color-brand)] hover:underline">
                查看
              </Link>
            </td>
          </tr>
        ))}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />
    </div>
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

function RoomStatusPill({ status }: { status: string }) {
  return (
    <span className={`inline-flex items-center rounded-md px-2 py-0.5 text-[12px] font-medium ${STATUS_PILL_CLASS[status] || STATUS_PILL_CLASS.archived}`}>
      {STATUS_LABEL[status] || status}
    </span>
  )
}
