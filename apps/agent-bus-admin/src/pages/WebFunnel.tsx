// 独立 Web 入口（创业助手站）的获客漏斗：访客→开聊→登录→留资→开单→提交→支付。
// 口径与数据源见 baigong 侧 specs/2026-08-11-baigong-funnel-metrics-design.md：
// 会话三段取访客台账，留资/开单/提交取事项库，支付取支付台账。
// 访客段自 beacon 上线（2026-08-11）起有数，之前的历史只有「开聊」口径。
import { useCallback, useEffect, useMemo, useState } from 'react'
import { RefreshCw } from 'lucide-react'

import {
  Button,
  DataTable,
  EmptyState,
  FormSection,
  InlineAlert,
  KpiCard,
  LineTrendChart,
  PageHeader,
  Pagination,
  Select,
  Toolbar,
  type TrendChartPoint,
} from '../components/ui'
import { WebLeads, type WebFunnel, type WebQuality, type WebUserRow } from '../lib/api'

const DAY_OPTIONS = [
  { value: 7, label: '近 7 天' },
  { value: 30, label: '近 30 天' },
  { value: 90, label: '近 90 天' },
]

type Step = {
  key: keyof WebFunnel
  label: string
  hint: string
}

// 漏斗层级：上一段是下一段的分母，顺序即用户路径
const STEPS: Step[] = [
  { key: 'sessions', label: '访客', hint: '打开页面的会话（含工具页）' },
  { key: 'chatted', label: '开聊', hint: '发过至少一条消息' },
  { key: 'logged', label: '登录', hint: '完成手机号登录' },
  { key: 'leads', label: '留资', hint: '留下联系方式' },
  { key: 'reg_created', label: '开单', hint: '开始填写注册资料' },
  { key: 'reg_submitted', label: '提交', hint: '资料提交待核价' },
  { key: 'reg_paid', label: '支付', hint: '注册服务费支付成功' },
]

// 上游 fail-soft 用 -1 表示该段查询异常，不能当 0 参与计算
const isBroken = (n: number) => n < 0
const fmt = (n: number) => (isBroken(n) ? '异常' : n.toLocaleString('zh-CN'))

function rate(cur: number, prev: number): string {
  if (isBroken(cur) || isBroken(prev) || prev <= 0) return '—'
  return `${((cur / prev) * 100).toFixed(1)}%`
}

export function WebFunnelPage() {
  const [days, setDays] = useState(30)
  const [data, setData] = useState<WebFunnel | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [reloadKey, setReloadKey] = useState(0)

  // effect 只负责取数与卸载清理；「进入加载态」放在触发处，避免在 effect 体内
  // 同步 setState（react-hooks/set-state-in-effect）。
  useEffect(() => {
    let cancelled = false
    WebLeads.funnel(days)
      .then((res) => { if (!cancelled) { setData(res); setError('') } })
      .catch((e: unknown) => {
        if (!cancelled) setError(e instanceof Error ? e.message : '漏斗数据加载失败')
      })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [days, reloadKey])

  const changeDays = useCallback((value: number) => {
    setLoading(true)
    setDays(value)
  }, [])

  const load = useCallback(() => {
    setLoading(true)
    setReloadKey((k) => k + 1)
  }, [])

  // 办理质量（数据线第二批）：核名一次通过率 + 交付时长分位，跟随天数筛选
  const [quality, setQuality] = useState<WebQuality | null>(null)

  useEffect(() => {
    let cancelled = false
    WebLeads.quality(days)
      .then((res) => { if (!cancelled) setQuality(res) })
      .catch(() => { if (!cancelled) setQuality(null) })
    return () => { cancelled = true }
  }, [days, reloadKey])

  // 注册用户明细（下钻）：独立分页，不跟随漏斗的天数筛选——运营找人时要看全量
  const [users, setUsers] = useState<WebUserRow[]>([])
  const [userTotal, setUserTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)

  useEffect(() => {
    let cancelled = false
    WebLeads.users(pageSize, (page - 1) * pageSize)
      .then((res) => {
        if (cancelled) return
        setUsers(res.items ?? [])
        setUserTotal(res.total ?? 0)
      })
      .catch(() => { if (!cancelled) setUsers([]) })
    return () => { cancelled = true }
  }, [page, pageSize, reloadKey])

  const maxValue = useMemo(() => {
    if (!data) return 0
    return Math.max(...STEPS.map((s) => Math.max(0, Number(data[s.key]) || 0)))
  }, [data])

  const trendPoints: TrendChartPoint[] = useMemo(() => {
    if (!data?.daily) return []
    return Object.keys(data.daily)
      .sort()
      .map((day) => ({
        label: day.slice(5),
        title: day,
        values: {
          sessions: Math.max(0, data.daily[day].sessions),
          chatted: Math.max(0, data.daily[day].chatted),
          logged: Math.max(0, data.daily[day].logged),
        },
      }))
  }, [data])

  const inviteRows = useMemo(() => {
    if (!data?.by_invite) return []
    return Object.entries(data.by_invite)
      .map(([invite, seg]) => ({ invite, ...seg }))
      .sort((a, b) => b.sessions - a.sessions)
  }, [data])

  return (
    <div>
      <PageHeader
        title="获客漏斗"
        subtitle="创业助手站从访客到付费的分段转化。访客段自 2026-08-11 起有数，此前历史只有「开聊」口径；渠道切片按访问链接携带的推广参数归因。"
      />

      <Toolbar
        filters={
          <div className="w-[140px]">
            <Select value={days} onChange={(e) => changeDays(Number(e.target.value))}>
              {DAY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
          </div>
        }
        summary={data ? `统计区间 ${data.days} 天` : undefined}
        actions={
          <Button variant="ghost" onClick={load} disabled={loading}>
            <RefreshCw size={14} className="mr-1" />
            刷新
          </Button>
        }
      />

      {error && (
        <div className="mb-3">
          <InlineAlert tone="danger">{error}</InlineAlert>
        </div>
      )}

      {data && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
            <KpiCard label="访客" value={fmt(data.sessions)} hint="打开页面的会话数" />
            <KpiCard
              label="开聊率"
              value={rate(data.chatted, data.sessions)}
              hint={`开聊 ${fmt(data.chatted)}`}
            />
            <KpiCard
              label="开单率"
              value={rate(data.reg_created, data.logged)}
              hint={`开单 ${fmt(data.reg_created)} · 登录 ${fmt(data.logged)}`}
              tone="success"
            />
            <KpiCard
              label="支付"
              value={fmt(data.reg_paid)}
              hint={`代账支付 ${fmt(data.bookkeeping_paid)}`}
              tone="success"
            />
          </div>

          <FormSection
            title="转化分段"
            description="每段的相对转化率以上一段为分母；某段显示「异常」表示该数据源本次查询失败。"
          >
            <div className="space-y-2">
              {STEPS.map((step, i) => {
                const value = Number(data[step.key]) || 0
                const prev = i === 0 ? value : Number(data[STEPS[i - 1].key]) || 0
                const width = maxValue > 0 && value > 0 ? Math.max(4, (value / maxValue) * 100) : 0
                return (
                  <div key={step.key} className="flex items-center gap-3">
                    <div className="w-[68px] shrink-0 text-[13px] text-[var(--color-text)]">
                      {step.label}
                    </div>
                    <div className="h-8 flex-1 rounded bg-[var(--color-bg-sub)]">
                      <div
                        className="flex h-8 items-center rounded bg-[var(--color-brand-soft)] px-2"
                        style={{ width: `${width}%` }}
                      >
                        <span className="whitespace-nowrap text-[12.5px] font-medium tabular-nums text-[var(--color-brand)]">
                          {fmt(value)}
                        </span>
                      </div>
                    </div>
                    <div className="w-[64px] shrink-0 text-right text-[12.5px] tabular-nums text-[var(--color-text-sub)]">
                      {i === 0 ? '' : rate(value, prev)}
                    </div>
                    <div className="hidden w-[180px] shrink-0 text-[12px] text-[var(--color-text-mute)] lg:block">
                      {step.hint}
                    </div>
                  </div>
                )
              })}
            </div>
          </FormSection>

          <FormSection
            title="每日趋势"
            description="会话三段的按日走势，用于观察投放与内容的即时反应。"
            className="mt-4"
          >
            <LineTrendChart
              points={trendPoints}
              series={[
                { key: 'sessions', label: '访客', color: 'var(--color-icon-blue)' },
                { key: 'chatted', label: '开聊', color: 'var(--color-icon-green)' },
                { key: 'logged', label: '登录', color: 'var(--color-icon-purple)' },
              ]}
              emptyText="这个区间还没有访问数据"
            />
          </FormSection>

          <FormSection
            title="渠道切片"
            description="按访问链接携带的推广参数归因；开单按账号关联到首次会话的渠道。"
            className="mt-4"
          >
            {inviteRows.length === 0 ? (
              <EmptyState
                title="暂无渠道数据"
                description="推广链接带上渠道参数（如 ?invite=xhs）后，来自该渠道的访问会在这里分开统计。"
              />
            ) : (
              <DataTable headers={['渠道', '访客', '开聊', '登录', '留资', '开单']}>
                {inviteRows.map((row) => (
                  <tr key={row.invite}>
                    <td className="px-4 py-2.5 text-[var(--color-text)]">{row.invite}</td>
                    <td className="px-4 py-2.5 tabular-nums">{fmt(row.sessions)}</td>
                    <td className="px-4 py-2.5 tabular-nums">{fmt(row.chatted)}</td>
                    <td className="px-4 py-2.5 tabular-nums">{fmt(row.logged)}</td>
                    <td className="px-4 py-2.5 tabular-nums">{fmt(row.leads ?? 0)}</td>
                    <td className="px-4 py-2.5 tabular-nums">{fmt(row.reg_created ?? 0)}</td>
                  </tr>
                ))}
              </DataTable>
            )}
          </FormSection>
        </>
      )}

      {quality && (
        <FormSection
          title="办理质量"
          description="核名一次通过率=首次核名即通过的注册单占比（备选字号递补通过不算一次过）；交付时长=建单到办结的天数分位，跟随上方天数筛选。"
          className="mt-4"
        >
          <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
            <KpiCard
              label="核名一次通过率"
              value={
                quality.naming_cases > 0
                  ? `${((quality.naming_first_pass / quality.naming_cases) * 100).toFixed(1)}%`
                  : '—'
              }
              hint={
                quality.naming_cases >= 0
                  ? `一次通过 ${quality.naming_first_pass} · 有核名结果 ${quality.naming_cases}`
                  : '数据源异常'
              }
              tone="success"
            />
            <KpiCard
              label="窗口内办结"
              value={quality.delivery.reduce((n, d) => n + d.count, 0).toLocaleString('zh-CN')}
              hint="建单到办结均在统计区间"
            />
          </div>
          {quality.delivery.length === 0 ? (
            <EmptyState
              title="暂无交付数据"
              description="统计区间内有办结的单据后，这里会展示各类型的交付时长分位。"
            />
          ) : (
            <DataTable headers={['单据类型', '办结数', '交付 P50（天）', '交付 P90（天）']}>
              {quality.delivery.map((d) => (
                <tr key={d.label}>
                  <td className="px-4 py-2.5 text-[var(--color-text)]">{d.label}</td>
                  <td className="px-4 py-2.5 tabular-nums">{d.count}</td>
                  <td className="px-4 py-2.5 tabular-nums">{d.p50_days}</td>
                  <td className="px-4 py-2.5 tabular-nums">{d.p90_days}</td>
                </tr>
              ))}
            </DataTable>
          )}
        </FormSection>
      )}

      {data && (
        <FormSection
          title="注册用户"
          description="按注册时间倒序；手机号按掩码展示，需要完整号码请到对应的注册申请单查看。"
          className="mt-4"
        >
          {users.length === 0 ? (
            <EmptyState
              title="暂无注册用户"
              description="用户在创业助手站完成手机号登录后，会出现在这里。"
            />
          ) : (
            <>
              <DataTable headers={['手机号', '注册时间', '最近登录', '渠道', '对话轮数', '办理阶段']}>
                {users.map((u) => (
                  <tr key={u.user_id}>
                    <td className="px-4 py-2.5 font-medium tabular-nums text-[var(--color-text)]">
                      {u.phone_masked}
                    </td>
                    <td className="px-4 py-2.5 text-[var(--color-text-sub)]">
                      {u.created_at.slice(0, 16).replace('T', ' ')}
                    </td>
                    <td className="px-4 py-2.5 text-[var(--color-text-sub)]">
                      {u.last_login_at.slice(0, 16).replace('T', ' ')}
                    </td>
                    <td className="px-4 py-2.5 text-[var(--color-text-sub)]">
                      {u.invite || '直接访问'}
                    </td>
                    <td className="px-4 py-2.5 tabular-nums text-[var(--color-text-sub)]">
                      {u.turns}
                    </td>
                    <td className="px-4 py-2.5 text-[var(--color-text-sub)]">
                      {u.stage || '未开单'}
                    </td>
                  </tr>
                ))}
              </DataTable>
              <Pagination
                total={userTotal}
                page={page}
                pageSize={pageSize}
                onPageChange={setPage}
                onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
              />
            </>
          )}
        </FormSection>
      )}

      {!data && !loading && !error && (
        <EmptyState
          title="暂无漏斗数据"
          description="创业助手站有访问后，这里会展示从访客到付费的分段转化。"
        />
      )}
    </div>
  )
}
