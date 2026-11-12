// PlatformDriveUsagePage — F06 Phase 4 / §5.1 平台云盘用量监控.
//
// 能力:
//   - 平台汇总卡 (租户数 / 总用量 / 文件数 / 已设配额 / 接近配额), 与列表筛选同口径
//   - 全租户用量汇总 (按 tenant 维度), 默认按总用量降序, 可切排序
//   - 筛选: q (租户名模糊或 id 精确) / tenant_status
//   - 占比 ≥80% 黄 / ≥95% 红预警色
//   - 平台视角不暴露底层 drive_spaces.kind; 列内拆个人空间用量 / 协作空间用量.
//
// 权限: platform.drive.read_usage. 后端最终把关.

import { useEffect, useState, type ComponentType } from 'react'
import {
  DriveUsageAdmin,
  DrivePlatformQuotasAdmin,
  type DriveUsageRow,
  type DriveUsageSummary,
} from '../../lib/api'
import {
  Button, DataTable, DialogShell, EmptyState, FormField, InlineAlert, Input,
  PageHeader, Pagination, Select, Toolbar,
} from '../../components/ui'
import { AlertTriangle, BarChart3, Building2, Files, Gauge, HardDrive } from 'lucide-react'
import { fmtBytes } from './components/format'

type QuotaEdit = {
  tenantID: number
  tenantName: string
  usedBytes: number
  currentQuota?: number
  draft: string
}

const TENANT_STATUS_OPTIONS: { value: string; label: string }[] = [
  { value: 'active', label: '正式租户' },
  { value: 'trial', label: '试用租户' },
  { value: 'suspended', label: '已暂停租户' },
  { value: 'deactivated', label: '已停用租户' },
  { value: 'all', label: '全部租户' },
]

const SORT_OPTIONS: { value: string; label: string }[] = [
  { value: 'usage_desc', label: '用量从高到低' },
  { value: 'usage_asc', label: '用量从低到高' },
  { value: 'tenant_id', label: '按租户 ID' },
]

// 汇总卡: 与列表筛选同口径 (接口不分页); 接近配额 = 已用 ≥ 配额 80%, 与占比预警色阈值一致。
function UsageStatCards({ s }: { s: DriveUsageSummary | null }) {
  const cards: {
    icon: ComponentType<{ size?: number }>
    label: string
    value: string
    hint?: string
    danger?: boolean
    color: string
  }[] = [
    {
      icon: Building2, label: '租户数',
      value: s ? String(s.tenants_count) : '—',
      hint: s ? `空间 ${s.spaces_count} 个` : undefined,
      color: 'bg-[var(--color-icon-blue-bg)] text-[var(--color-icon-blue)]',
    },
    {
      icon: HardDrive, label: '总用量',
      value: s ? fmtBytes(s.used_bytes) : '—',
      hint: s ? `个人 ${fmtBytes(s.personal_used_bytes)} · 协作 ${fmtBytes(s.collaboration_used_bytes)}` : undefined,
      color: 'bg-[var(--color-icon-purple-bg)] text-[var(--color-icon-purple)]',
    },
    {
      icon: Files, label: '文件数',
      value: s ? String(s.files_count) : '—',
      color: 'bg-[var(--color-icon-green-bg)] text-[var(--color-icon-green)]',
    },
    {
      icon: Gauge, label: '已设配额租户',
      value: s ? String(s.quota_set_count) : '—',
      hint: '含无限额度',
      color: 'bg-[var(--color-icon-orange-bg)] text-[var(--color-icon-orange)]',
    },
    {
      icon: AlertTriangle, label: '接近配额租户',
      value: s ? String(s.near_quota_count) : '—',
      hint: '已用 ≥ 配额 80%',
      danger: !!s && s.near_quota_count > 0,
      color: 'bg-[var(--color-icon-red-bg)] text-[var(--color-icon-red)]',
    },
  ]
  return (
    <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-5">
      {cards.map((c) => {
        const Icon = c.icon
        return (
          <div key={c.label} className="rounded-lg border border-[var(--color-line)] bg-[var(--color-surface)] px-4 py-3">
            <div className="flex items-center justify-between gap-3">
              <div className="truncate text-[12px] text-[var(--color-text-mute)]">{c.label}</div>
              <div className={`grid h-7 w-7 shrink-0 place-items-center rounded-md ${c.color}`}>
                <Icon size={14} />
              </div>
            </div>
            <div className={`mt-1.5 text-[22px] font-semibold leading-none tabular-nums ${c.danger ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]'}`}>
              {c.value}
            </div>
            <div className="mt-1.5 truncate text-[12px] text-[var(--color-text-mute)]">{c.hint ?? ' '}</div>
          </div>
        )
      })}
    </div>
  )
}

// 状态徽章: 语义与视觉同「租户管理」页 StatusPill (试用/正式/已暂停/已停用)。
const TENANT_STATUS_LABEL: Record<string, string> = {
  trial: '试用',
  active: '正式',
  suspended: '已暂停',
  deactivated: '已停用',
}

function TenantStatusPill({ status }: { status?: string }) {
  if (!status) return <span className="text-[12px] text-[var(--color-text-mute)]">—</span>
  const map: Record<string, string> = {
    active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    trial: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
    suspended: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
    deactivated: 'bg-[var(--color-line-soft)] text-[var(--color-text-mute)]',
  }
  return (
    <span className={`inline-block whitespace-nowrap px-2 py-0.5 text-[11px] rounded ring-border-soft ${map[status] || map.deactivated}`}>
      {TENANT_STATUS_LABEL[status] || status}
    </span>
  )
}

export function PlatformDriveUsagePage() {
  const [rows, setRows] = useState<DriveUsageRow[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [loadErr, setLoadErr] = useState('')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [searchInput, setSearchInput] = useState('')
  const [search, setSearch] = useState('')
  const [tenantStatus, setTenantStatus] = useState('active')
  const [sort, setSort] = useState('usage_desc')
  const [summary, setSummary] = useState<DriveUsageSummary | null>(null)

  const load = (p = page, ps = pageSize) => {
    setLoading(true)
    DriveUsageAdmin.list({
      q: search || undefined,
      tenant_status: tenantStatus,
      sort,
      limit: ps,
      offset: (p - 1) * ps,
    })
      .then((r) => {
        setRows(r.items || [])
        setTotal(r.total || 0)
        setLoadErr('')
      })
      .catch((e: Error) => setLoadErr(e.message))
      .finally(() => setLoading(false))
  }

  // 汇总卡与列表同口径 (q / tenant_status), 不随分页/排序变化.
  const loadSummary = () => {
    DriveUsageAdmin.summary({ q: search || undefined, tenant_status: tenantStatus })
      .then(setSummary)
      .catch(() => setSummary(null))
  }

  // eslint-disable-next-line react-hooks/set-state-in-effect, react-hooks/exhaustive-deps
  useEffect(() => { load(page, pageSize) }, [page, pageSize, search, tenantStatus, sort])
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { loadSummary() }, [search, tenantStatus])

  const applyFilter = () => {
    const s = searchInput.trim()
    if (s === search) return
    setPage(1)
    setSearch(s)
  }

  // F06 v0.3.1 §3.3: 平台调整租户总额度 dialog state.
  const [quotaEdit, setQuotaEdit] = useState<QuotaEdit | null>(null)
  const [quotaSaveErr, setQuotaSaveErr] = useState('')
  const [quotaNotice, setQuotaNotice] = useState('')

  const openQuotaDialog = (r: DriveUsageRow) => {
    setQuotaEdit({
      tenantID: r.tenant_id,
      tenantName: r.tenant_name || `tenant#${r.tenant_id}`,
      usedBytes: r.used_bytes,
      currentQuota: r.quota_bytes ?? undefined,
      draft: r.quota_bytes != null ? String(r.quota_bytes) : '',
    })
    setQuotaSaveErr('')
  }

  const saveQuota = async () => {
    if (!quotaEdit) return
    setQuotaSaveErr('')
    const n = Number(quotaEdit.draft.trim())
    if (!Number.isFinite(n) || n < -1) {
      setQuotaSaveErr('请输入字节数 (整数), -1 表示无限')
      return
    }
    try {
      await DrivePlatformQuotasAdmin.setTenantQuota(quotaEdit.tenantID, n)
      setQuotaNotice(`已更新 ${quotaEdit.tenantName} 的总额度`)
      setQuotaEdit(null)
      load(page, pageSize)
      loadSummary()
    } catch (e) {
      setQuotaSaveErr((e as Error).message)
    }
  }

  return (
    <div>
      <PageHeader
        title="云盘用量"
        subtitle="默认展示正式租户的云盘总用量, 按租户聚合并拆分个人空间与协作空间。"
      />

      {loadErr && (
        <div className="mb-3">
          <InlineAlert tone="danger">
            读取用量数据失败: {loadErr}
            <div className="mt-1 text-[12px] text-[var(--color-text-mute)]">
              请确认当前账号具备平台云盘用量读取权限, 并检查 admin 服务与数据库连接。
            </div>
          </InlineAlert>
        </div>
      )}
      {quotaNotice && <div className="mb-3"><InlineAlert tone="info">{quotaNotice}</InlineAlert></div>}

      <UsageStatCards s={summary} />

      <Toolbar
        search={
          <Input
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            placeholder="按租户名称或 ID 搜索 (回车或失焦生效)"
            onKeyDown={(e) => { if (e.key === 'Enter') applyFilter() }}
            onBlur={applyFilter}
          />
        }
        filters={
          <div className="flex items-center gap-2">
            <div className="w-[140px]">
              <Select value={tenantStatus} onChange={(e) => { setTenantStatus(e.target.value); setPage(1) }} aria-label="租户状态">
                {TENANT_STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </Select>
            </div>
            <div className="w-[140px]">
              <Select value={sort} onChange={(e) => { setSort(e.target.value); setPage(1) }} aria-label="排序方式">
                {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </Select>
            </div>
          </div>
        }
        summary={<>共 <b className="text-[var(--color-text)]">{total}</b> 行聚合</>}
      />

      <DataTable
        headers={['租户', '状态', '空间数', '文件数', '总用量', '个人空间用量', '协作空间用量', '配额', '占比', '操作']}
        empty={!loading && !rows.length ? (
          <EmptyState
            icon={<BarChart3 size={20} />}
            title="无用量数据"
            description={loadErr ? '上方错误信息说明问题。' : '该筛选条件下没有命中行; 改一下筛选试试。'}
          />
        ) : null}
      >
        {rows.map((r) => {
          const pct = r.quota_bytes && r.quota_bytes > 0
            ? Math.min(100, Math.round((r.used_bytes / r.quota_bytes) * 100))
            : null
          // 预警阈值与 summary near_quota (80%) 对齐; 95% 升级红色.
          const pctCls = pct != null && pct >= 95
            ? 'text-[var(--color-danger)] font-medium'
            : pct != null && pct >= 80
              ? 'text-[var(--color-warn)] font-medium'
              : 'text-[var(--color-text-sub)]'
          return (
            <tr key={r.tenant_id}>
              <td className="px-4 py-3 align-middle">
                <div className="font-medium text-[var(--color-text)]">
                  {r.tenant_name || `tenant#${r.tenant_id}`}
                </div>
                <div className="text-[11px] text-[var(--color-text-mute)] tabular-nums">id: {r.tenant_id}</div>
              </td>
              <td className="px-4 py-3 align-middle">
                <TenantStatusPill status={r.tenant_status} />
              </td>
              <td className="px-4 py-3 align-middle text-[12px] tabular-nums">{r.spaces_count}</td>
              <td className="px-4 py-3 align-middle text-[12px] tabular-nums">{r.files_count}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums">{fmtBytes(r.used_bytes)}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums">{fmtBytes(r.personal_used_bytes)}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums">{fmtBytes(r.collaboration_used_bytes)}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums">
                {r.quota_bytes == null
                  ? <span className="text-[12px] text-[var(--color-text-mute)]">未设置 (不限)</span>
                  : fmtBytes(r.quota_bytes)}
              </td>
              <td className={`px-4 py-3 align-middle text-[12px] tabular-nums ${pctCls}`}>
                {pct == null ? '—' : `${pct}%`}
              </td>
              <td className="px-4 py-3 align-middle">
                <Button size="sm" variant="ghost" onClick={() => openQuotaDialog(r)}>
                  调整总额度
                </Button>
              </td>
            </tr>
          )
        })}
      </DataTable>

      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(n) => { setPageSize(n); setPage(1) }}
      />

      {quotaEdit && (
        <DialogShell
          title={`调整租户总额度 · ${quotaEdit.tenantName}`}
          subtitle="平台 admin only; -1 表示无限。不能低于当前已用 (会返 412 drive.quota_below_used)。"
          icon={<Gauge size={18} />}
          size="sm"
          onClose={() => setQuotaEdit(null)}
          footer={
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0 flex-1 text-[12px] text-[var(--color-danger)]">
                {quotaSaveErr}
              </div>
              <div className="flex shrink-0 gap-2">
                <Button variant="secondary" onClick={() => setQuotaEdit(null)}>取消</Button>
                <Button onClick={saveQuota}>保存</Button>
              </div>
            </div>
          }
        >
          <div className="mb-3 grid grid-cols-2 gap-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3">
            <div>
              <div className="text-[11px] text-[var(--color-text-mute)]">当前已用</div>
              <div className="mt-0.5 text-[14px] font-medium tabular-nums">{fmtBytes(quotaEdit.usedBytes)}</div>
            </div>
            <div>
              <div className="text-[11px] text-[var(--color-text-mute)]">当前总额度</div>
              <div className="mt-0.5 text-[14px] font-medium tabular-nums">{fmtBytes(quotaEdit.currentQuota)}</div>
            </div>
          </div>
          <FormField label="新总额度 (字节)" hint="-1 表示无限; 示例 107374182400 = 100 GB">
            <Input
              value={quotaEdit.draft}
              onChange={(e) => setQuotaEdit({ ...quotaEdit, draft: e.target.value })}
              placeholder="例: 107374182400"
              autoFocus
            />
          </FormField>
        </DialogShell>
      )}
    </div>
  )
}
