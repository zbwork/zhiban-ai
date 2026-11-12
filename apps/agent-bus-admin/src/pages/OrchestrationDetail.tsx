// F09-B4-02: Orchestration 详情 (/rooms/orchestrations/:uuid).
//
// 展示 orchestration meta + 计量 + steps 时序 (role/agent/status/tokens/latency); hover 在
// 步骤上显示 step 完整数据 (title 属性 + 展开行).
//
// 当前不画 SVG 时序图 (PR8 -m 拒绝复杂可视化; 留 follow-up). step 表格够用.

import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { AdminOrchestrations, type AdminOrchestrationDetail, type AdminOrchestrationStep } from '../lib/api'
import {
  DataTable,
  EmptyState,
  FormSection,
  InlineAlert,
  PageHeader,
  Panel,
} from '../components/ui'

export default function OrchestrationDetailPage() {
  const { uuid = '' } = useParams<{ uuid: string }>()
  const [detail, setDetail] = useState<AdminOrchestrationDetail | null>(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    let mounted = true
    if (!uuid) return
    AdminOrchestrations.get(uuid)
      .then((d) => mounted && setDetail(d))
      .catch((e: unknown) => mounted && setErr((e as Error).message || '加载失败'))
    return () => { mounted = false }
  }, [uuid])

  if (err) {
    return (
      <div className="p-6 max-w-5xl">
        <InlineAlert tone="danger">{err}</InlineAlert>
        <div className="mt-3"><Link to="/rooms/orchestrations" className="text-[var(--color-brand)] hover:underline">← 返回列表</Link></div>
      </div>
    )
  }
  if (!detail) return <div className="p-6 text-sm text-[var(--color-text-sub)]">加载中...</div>

  return (
    <div className="p-6 space-y-4 max-w-6xl">
      <PageHeader
        title={`Orchestration · ${detail.uuid.slice(0, 8)}`}
        subtitle={
          <span className="text-xs">
            <Link to="/rooms/orchestrations" className="text-[var(--color-brand)] hover:underline">← 返回</Link>
            <span className="mx-2 text-[var(--color-text-mute)]">·</span>
            {detail.status}
            {detail.completed_at && <span className="ml-2 text-[var(--color-text-mute)]">完成于 {formatTime(detail.completed_at)}</span>}
          </span>
        }
      />

      <Panel>
        <FormSection title="基本">
          <KV k="UUID" v={detail.uuid} mono />
          <KV k="Master Agent" v={`${detail.master_agent_name || '?'} (#${detail.master_agent_id})`} />
          {detail.room_id && <KV k="Room ID" v={`#${detail.room_id}`} />}
          {detail.trigger_msg_id && <KV k="Trigger msg ID" v={`#${detail.trigger_msg_id}`} />}
          <KV k="创建时间" v={formatTime(detail.created_at)} />
          {detail.started_at && <KV k="started_at" v={formatTime(detail.started_at)} />}
          {detail.completed_at && <KV k="completed_at" v={formatTime(detail.completed_at)} />}
          {detail.plan_summary && <KV k="计划摘要" v={detail.plan_summary} />}
          {detail.final_summary && <KV k="最终摘要" v={detail.final_summary} />}
          {detail.error_message && <KV k="错误" v={<span className="text-[var(--color-danger)]">{detail.error_message}</span>} />}
        </FormSection>
      </Panel>

      <Panel>
        <FormSection title="预算 / 计量">
          <KV k="Depth limit" v={String(detail.depth_limit)} />
          <KV k="Max depth reached" v={String(detail.max_depth_reached)} />
          <KV k="Token budget" v={String(detail.token_budget)} />
          <KV k="Token 使用 (in/out)" v={`${detail.tokens_in_total} / ${detail.tokens_out_total}`} />
          <KV k="Time budget (ms)" v={String(detail.time_budget_ms)} />
          <KV k="Edges 数" v={String(detail.edges_count)} />
        </FormSection>
      </Panel>

      <Panel>
        <FormSection title={`步骤 (${detail.steps.length})`} description="按 step_index 时序展示; hover 一行看完整字段。">
          <DataTable
            headers={['#', 'Role', 'Worker Agent', '状态', '输入摘要', '输出摘要', 'Tokens (in/out)', '时间']}
          >
            {detail.steps.length === 0 ? (
              <tr><td colSpan={8} className="px-3 py-8"><EmptyState title="尚无步骤" /></td></tr>
            ) : detail.steps.map((s) => <StepRow key={s.uuid} s={s} />)}
          </DataTable>
        </FormSection>
      </Panel>
    </div>
  )
}

function StepRow({ s }: { s: AdminOrchestrationStep }) {
  const meta = `started=${s.started_at || '-'} · completed=${s.completed_at || '-'} · call_edge=#${s.call_edge_id ?? '-'}`
  return (
    <tr className="border-t border-[var(--color-line-soft)] hover:bg-[var(--color-bg-sub)]" title={meta}>
      <td className="px-3 py-2 text-right tabular-nums">{s.step_index}</td>
      <td className="px-3 py-2"><RoleChip role={s.role} /></td>
      <td className="px-3 py-2">{s.worker_name || (s.worker_agent_id ? `#${s.worker_agent_id}` : '-')}</td>
      <td className="px-3 py-2"><StepStatusBadge status={s.status} /></td>
      <td className="px-3 py-2 max-w-xs truncate text-xs text-[var(--color-text-sub)]" title={s.input_summary || ''}>{s.input_summary || '-'}</td>
      <td className="px-3 py-2 max-w-xs truncate text-xs text-[var(--color-text-sub)]" title={s.output_summary || ''}>{s.output_summary || '-'}</td>
      <td className="px-3 py-2 text-right tabular-nums text-xs text-[var(--color-text-sub)]">{s.tokens_in}/{s.tokens_out}</td>
      <td className="px-3 py-2 text-xs text-[var(--color-text-mute)]">{formatTime(s.created_at)}</td>
    </tr>
  )
}

function RoleChip({ role }: { role: string }) {
  const label = ({ planner: '规划', worker: '执行', reducer: '汇总', validator: '校验' } as Record<string, string>)[role] || role
  return (
    <span className="inline-flex px-1.5 py-0.5 rounded text-xs bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
      {label}
    </span>
  )
}

function StepStatusBadge({ status }: { status: string }) {
  const tone =
    status === 'done' ? 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
    : status === 'failed' ? 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
    : status === 'running' ? 'bg-[var(--color-info-bg)] text-[var(--color-info)]'
    : status === 'skipped' ? 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]'
    : 'bg-[var(--color-bg-sub)] text-[var(--color-text-mute)]'
  return <span className={`inline-flex px-2 py-0.5 rounded text-xs ${tone}`}>{status}</span>
}

function KV({ k, v, mono }: { k: string; v: React.ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline gap-3 text-sm py-0.5">
      <div className="w-36 shrink-0 text-[var(--color-text-mute)]">{k}</div>
      <div className={`flex-1 ${mono ? 'font-mono text-xs break-all' : ''}`}>{v}</div>
    </div>
  )
}

function formatTime(iso?: string): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('zh-CN', { hour12: false })
}
