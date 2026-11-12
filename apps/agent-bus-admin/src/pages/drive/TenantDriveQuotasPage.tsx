// TenantDriveQuotasPage — F06 Phase 4 / §5.1 租户云盘配额管理.
//
// 数据模型:
//   - 租户总额: 平台 admin 维护
//   - 账号独立配额: 给个别账号"开小灶", 不设时该账号共享租户总池
//
// 能力:
//   - 顶部卡: 租户容量总览
//   - 列表: 已设独立配额的账号 (account_id, quota, used, 占比)
//   - 主操作: + 设定独立额度 (drawer 选账号 + 填字节数)
//   - 行操作: 编辑 (调金额; -1 取消独立回归继承)
//
// 权限: tenant.drive.manage_quota. 后端最终把关.

import { useEffect, useRef, useState } from 'react'
import {
  DriveQuotasAdmin,
  Members,
  type DriveTenantQuotaSummary,
  type DriveAccountQuotaItem,
  type MemberDetail,
} from '../../lib/api'
import {
  Button, DataTable, DrawerShell, EmptyState, FormField, InlineAlert,
  Input, PageHeader, Panel, PrimaryButton, RowActions, Toolbar,
  stickyLeftTdCls, stickyRightTdCls,
} from '../../components/ui'
import { notifyError, notifyOk } from '../../lib/toast'
import { Check, ChevronDown, Gauge, Search, Users, X } from 'lucide-react'
import { fmtBytes } from './components/format'

// === AccountCombobox — 单输入框 + 浮层下拉 ===
// 替代之前的 "搜索 Input + Select" 两个独立框, 体验更接近 Linear / GitHub assignee picker。
// 输入时既是搜索又是显示, 选中后显示已选名 (可点 × 清除); 焦点 / 点击时浮层打开, 外部点击关闭。
function AccountCombobox({
  options,
  loading,
  query,
  onQueryChange,
  selectedId,
  onSelect,
  onClear,
  selectedLabel,
}: {
  options: MemberDetail[]
  loading: boolean
  query: string
  onQueryChange: (q: string) => void
  selectedId: number | null
  onSelect: (m: MemberDetail) => void
  onClear: () => void
  selectedLabel: string | null
}) {
  const rootRef = useRef<HTMLDivElement | null>(null)
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [open, setOpen] = useState(false)
  const [activeIdx, setActiveIdx] = useState(0)

  // 外部点击关闭
  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [open])

  // options 变化时重置 active highlight (没办法避开 setState-in-effect, lint 单条 disable)
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setActiveIdx(0) }, [options])

  const showSelectedChip = selectedId != null && !open
  const inputValue = open ? query : (selectedLabel || '')

  return (
    <div ref={rootRef} className="relative">
      <div className="relative">
        <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
        <input
          ref={inputRef}
          type="text"
          value={inputValue}
          placeholder={showSelectedChip ? '' : '搜索姓名 / 手机 / 邮箱'}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            onQueryChange(e.target.value)
            if (!open) setOpen(true)
          }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') {
              e.preventDefault()
              setOpen(true)
              setActiveIdx((i) => Math.min(i + 1, Math.max(0, options.length - 1)))
            } else if (e.key === 'ArrowUp') {
              e.preventDefault()
              setActiveIdx((i) => Math.max(0, i - 1))
            } else if (e.key === 'Enter') {
              e.preventDefault()
              const m = options[activeIdx]
              if (m) { onSelect(m); setOpen(false) }
            } else if (e.key === 'Escape') {
              e.preventDefault()
              setOpen(false)
              inputRef.current?.blur()
            }
          }}
          className="h-9 w-full rounded-md border border-[var(--color-line)] bg-[var(--color-control-bg)] pl-8 pr-9 text-[13px] text-[var(--color-text)] transition placeholder:text-[var(--color-text-mute)] focus:border-[var(--color-brand)] focus:outline-none"
        />
        {selectedId != null && !open ? (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation()
              onQueryChange('')
              onClear()
            }}
            className="absolute right-2 top-1/2 -translate-y-1/2 grid h-5 w-5 place-items-center rounded text-[var(--color-text-mute)] hover:bg-[var(--color-line-soft)] hover:text-[var(--color-text)]"
            aria-label="清除"
          >
            <X size={13} />
          </button>
        ) : (
          <ChevronDown
            size={14}
            className={'absolute right-2.5 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)] transition ' + (open ? 'rotate-180' : '')}
          />
        )}
      </div>

      {open && (
        <div className="absolute left-0 right-0 top-[calc(100%+4px)] z-10 max-h-[280px] overflow-y-auto rounded-md border border-[var(--color-line)] bg-white py-1 shadow-lg ring-1 ring-black/5">
          {loading ? (
            <div className="px-3 py-2 text-[12px] text-[var(--color-text-mute)]">加载中…</div>
          ) : options.length === 0 ? (
            <div className="px-3 py-3 text-[12px] text-[var(--color-text-mute)]">
              {query ? '没有匹配的账号' : '本租户所有账号都已设过独立额度, 或没有可分配的成员'}
            </div>
          ) : (
            options.map((m, idx) => {
              const active = idx === activeIdx
              const selected = m.account_id === selectedId
              return (
                <button
                  key={m.account_id}
                  type="button"
                  onMouseDown={(e) => e.preventDefault()} // 防 input blur
                  onClick={() => { onSelect(m); setOpen(false) }}
                  onMouseEnter={() => setActiveIdx(idx)}
                  className={
                    'flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px] transition ' +
                    (active ? 'bg-[var(--color-bg-sub)]' : '')
                  }
                >
                  <div className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-[var(--color-text)] text-[10px] font-medium text-white">
                    {(m.display_name || '?')[0]}
                  </div>
                  <div className="min-w-0 flex-1 truncate">
                    <span className="font-medium text-[var(--color-text)]">{m.display_name}</span>
                    {(m.employee_id || m.phone) && (
                      <span className="ml-2 text-[11px] text-[var(--color-text-mute)]">
                        {[m.employee_id, m.phone].filter(Boolean).join(' · ')}
                      </span>
                    )}
                  </div>
                  {selected && <Check size={14} className="shrink-0 text-[var(--color-primary)]" />}
                </button>
              )
            })
          )}
        </div>
      )}
    </div>
  )
}

type EditState =
  | { mode: 'create'; accountId: number | null; quotaBytes: string }
  | { mode: 'edit'; accountId: number; accountName: string; current: number; quotaBytes: string }

// GB / MB 快捷按钮 (bytes 实际值)
const QUOTA_PRESETS: { label: string; bytes: number }[] = [
  { label: '500 MB', bytes: 500 * 1024 * 1024 },
  { label: '2 GB', bytes: 2 * 1024 * 1024 * 1024 },
  { label: '10 GB', bytes: 10 * 1024 * 1024 * 1024 },
  { label: '50 GB', bytes: 50 * 1024 * 1024 * 1024 },
  { label: '无限制', bytes: -1 },
]

function fmtQuota(n?: number | null) {
  if (n === undefined || n === null || n === -1) return '无限制'
  return fmtBytes(n)
}

function quotaPercent(used: number, quota?: number | null) {
  if (!quota || quota < 0) return null
  return Math.min(100, Math.round((used / quota) * 100))
}

function fmtRemaining(used: number, quota?: number | null) {
  if (quota === undefined || quota === null || quota === -1) return '无限制'
  return fmtBytes(Math.max(0, quota - used))
}

function statusLabel(status?: string) {
  switch (status) {
    case 'active':
      return '正常'
    case 'invited':
      return '待加入'
    case 'suspended':
      return '已停用'
    case 'left':
      return '已离职'
    default:
      return status || '—'
  }
}

function usageTone(percent: number | null) {
  if (percent === null) return 'text-[var(--color-text-sub)]'
  if (percent >= 95) return 'text-[var(--color-danger)]'
  if (percent >= 80) return 'text-[var(--color-warn)]'
  return 'text-[var(--color-text-sub)]'
}

export function TenantDriveQuotasPage() {
  const [summary, setSummary] = useState<DriveTenantQuotaSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadErr, setLoadErr] = useState('')
  const [editing, setEditing] = useState<EditState | null>(null)
  const [tick, setTick] = useState(0)
  const refresh = () => setTick((t) => t + 1)

  // 账号候选: 仅 create 模式 drawer 打开时拉一次
  const [members, setMembers] = useState<MemberDetail[]>([])
  const [membersLoading, setMembersLoading] = useState(false)
  const [memberSearch, setMemberSearch] = useState('')

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DriveQuotasAdmin.getTenantSummary()
      .then((s) => {
        if (cancelled) return
        setSummary(s)
        setLoadErr('')
      })
      .catch((e: Error) => { if (!cancelled) setLoadErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick])

  // create drawer 打开后, 拉成员候选; q 变化时 debounce
  useEffect(() => {
    if (!editing || editing.mode !== 'create') return
    let cancelled = false
    const handle = setTimeout(() => {
      setMembersLoading(true)
      Members.list(0, memberSearch.trim(), 50, 0)
        .then((r) => { if (!cancelled) setMembers(r.items || []) })
        .catch((e: Error) => { if (!cancelled) notifyError(`加载成员列表失败: ${e.message}`) })
        .finally(() => { if (!cancelled) setMembersLoading(false) })
    }, 250)
    return () => { cancelled = true; clearTimeout(handle) }
  }, [editing, memberSearch])

  const items: DriveAccountQuotaItem[] = summary?.items || []
  const tenantQuota = summary?.tenant_quota_bytes
  const tenantUsed = summary?.tenant_used_bytes ?? 0
  const tenantPct = quotaPercent(tenantUsed, tenantQuota)
  const accountLimitedCount = items.filter((i) => i.quota_bytes >= 0).length
  const accountUnlimitedCount = items.filter((i) => i.quota_bytes < 0).length

  // 已设独立额度的 account_id 集合, 用于 create drawer 排除候选
  const existingAccountIds = new Set(items.map((i) => i.account_id))
  const availableMembers = members.filter((m) => !existingAccountIds.has(m.account_id))

  const openCreate = () => {
    setMembers([])
    setMemberSearch('')
    setEditing({ mode: 'create', accountId: null, quotaBytes: '' })
  }

  const openEdit = (row: DriveAccountQuotaItem) => {
    setEditing({
      mode: 'edit',
      accountId: row.account_id,
      accountName: row.account_name || `account#${row.account_id}`,
      current: row.quota_bytes,
      quotaBytes: String(row.quota_bytes),
    })
  }

  const saveAccount = async () => {
    if (!editing) return
    const accountId = editing.mode === 'create' ? editing.accountId : editing.accountId
    if (!accountId) { notifyError('请选择账号'); return }
    const raw = editing.quotaBytes.trim()
    const n = Number(raw)
    if (!Number.isFinite(n) || n < -1 || (n !== Math.floor(n))) {
      notifyError('请输入正整数 (字节数), -1 表示无限制')
      return
    }
    try {
      await DriveQuotasAdmin.upsertAccountQuota({ account_id: accountId, quota_bytes: n })
      const memberName = editing.mode === 'edit'
        ? editing.accountName
        : availableMembers.find((m) => m.account_id === accountId)?.display_name || `account#${accountId}`
      notifyOk(editing.mode === 'create' ? `已为「${memberName}」设独立额度` : `已更新「${memberName}」配额`)
      setEditing(null)
      refresh()
    } catch (e) { notifyError((e as Error).message) }
  }

  return (
    <div>
      <PageHeader
        title="云盘配额"
        subtitle="查看本租户云盘容量使用情况, 为重点成员设置个人上限。"
      />

      {loadErr && (
        <div className="mb-3">
          <InlineAlert tone="danger">
            读取配额信息失败: {loadErr}
            <div className="mt-1 text-[12px] text-[var(--color-text-mute)]">
              后端 admin 配额 API 可能尚未上线; 上线后该错误会自动消失。
            </div>
          </InlineAlert>
        </div>
      )}

      <Panel className="mb-4 p-5">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2 text-[14px] font-medium text-[var(--color-text)]">
              <Gauge size={16} className="text-[var(--color-text-mute)]" /> 租户容量总览
            </div>
            <p className="mt-1 text-[12px] text-[var(--color-text-mute)]">
              未设置个人上限的成员共享租户总池; 个人上限只约束该成员新增上传。
            </p>
          </div>
          <span className="rounded-md bg-[var(--color-brand-soft)] px-2.5 py-1 text-[12px] text-[var(--color-brand)]">
            默认策略: 共享租户总池
          </span>
        </div>
        <div className="grid gap-4 md:grid-cols-5">
          <div>
            <div className="text-[12px] text-[var(--color-text-mute)]">总额度</div>
            <div className="mt-1 text-[20px] font-semibold tabular-nums text-[var(--color-text)]">{fmtQuota(tenantQuota)}</div>
          </div>
          <div>
            <div className="text-[12px] text-[var(--color-text-mute)]">已用</div>
            <div className="mt-1 text-[20px] font-semibold tabular-nums text-[var(--color-text)]">{fmtBytes(tenantUsed)}</div>
          </div>
          <div>
            <div className="text-[12px] text-[var(--color-text-mute)]">剩余</div>
            <div className="mt-1 text-[20px] font-semibold tabular-nums text-[var(--color-text)]">{fmtRemaining(tenantUsed, tenantQuota)}</div>
          </div>
          <div>
            <div className="text-[12px] text-[var(--color-text-mute)]">整体使用率</div>
            <div className={'mt-1 text-[20px] font-semibold tabular-nums ' + usageTone(tenantPct)}>
              {tenantPct == null ? '—' : `${tenantPct}%`}
            </div>
          </div>
          <div>
            <div className="text-[12px] text-[var(--color-text-mute)]">账号策略</div>
            <div className="mt-1 text-[13px] leading-6 text-[var(--color-text)]">
              <span className="font-semibold tabular-nums">{accountLimitedCount}</span> 个有个人上限
              <span className="mx-1 text-[var(--color-text-mute)]">/</span>
              <span className="font-semibold tabular-nums">{accountUnlimitedCount}</span> 个无限制
            </div>
          </div>
        </div>
      </Panel>

      <Toolbar
        summary={<>共 <b className="text-[var(--color-text)]">{items.length}</b> 个账号用量记录</>}
        actions={<PrimaryButton onClick={openCreate}>设定独立额度</PrimaryButton>}
      />

      <DataTable
        stickyFirstCol
        stickyLastCol
        headers={[
          <span key="acct" className="inline-flex items-center gap-1"><Users size={13} /> 账号</span>,
          '部门', '工号 / 联系方式', '个人上限', '已用', '剩余', '使用率', '状态', '操作',
        ]}
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<Users size={26} />}
            title="尚无独立配额"
            description={
              <>
                所有账号当前共享租户总池 ({fmtQuota(tenantQuota)})。
                <br />
                点击右上角「<b className="text-[var(--color-text)]">设定独立额度</b>」给某个成员设置个人上限。
              </>
            }
          />
        ) : null}
      >
        {items.map((row) => {
          const pct = quotaPercent(row.used_bytes, row.quota_bytes)
          const accountName = row.account_name || `account#${row.account_id}`
          return (
            <tr key={row.account_id} className="group">
              <td className={'px-4 py-3 align-middle whitespace-nowrap ' + stickyLeftTdCls}>
                <div className="font-medium text-[var(--color-text)]">
                  {accountName}
                </div>
                <div className="text-[12px] text-[var(--color-text-mute)]">id: {row.account_id}</div>
              </td>
              <td className="px-4 py-3 align-middle text-[13px] whitespace-nowrap">{row.department_name || '—'}</td>
              <td className="px-4 py-3 align-middle text-[13px] whitespace-nowrap">
                <div>{row.employee_id || '—'}</div>
                {row.contact && <div className="text-[12px] text-[var(--color-text-mute)]">{row.contact}</div>}
              </td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums whitespace-nowrap">{fmtQuota(row.quota_bytes)}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums whitespace-nowrap">{fmtBytes(row.used_bytes)}</td>
              <td className="px-4 py-3 align-middle text-[13px] tabular-nums whitespace-nowrap">{fmtRemaining(row.used_bytes, row.quota_bytes)}</td>
              <td className={'px-4 py-3 align-middle text-[12px] tabular-nums whitespace-nowrap ' + usageTone(pct)}>
                {pct == null ? '—' : `${pct}%`}
              </td>
              <td className="px-4 py-3 align-middle text-[13px] whitespace-nowrap">{statusLabel(row.status)}</td>
              <td className={'px-4 py-3 align-middle ' + stickyRightTdCls}>
                <RowActions
                  onEdit={() => openEdit(row)}
                  onDelete={undefined}
                />
              </td>
            </tr>
          )
        })}
      </DataTable>

      {editing && (
        <DrawerShell
          title={editing.mode === 'create' ? '设定独立额度' : `调整配额 · ${editing.accountName}`}
          subtitle="输入 -1 表示该成员不设个人上限, 仍受租户总池约束。"
          width="sm"
          onClose={() => setEditing(null)}
          footer={
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setEditing(null)}>取消</Button>
              <Button onClick={saveAccount}>保存</Button>
            </div>
          }
        >
          <div className="space-y-4">
            {editing.mode === 'create' ? (
              <FormField label="账号" hint="选择要设置个人上限的成员; 已在列表中的账号可直接编辑">
                <AccountCombobox
                  options={availableMembers}
                  loading={membersLoading}
                  query={memberSearch}
                  onQueryChange={setMemberSearch}
                  selectedId={editing.accountId}
                  selectedLabel={
                    editing.accountId
                      ? availableMembers.find((m) => m.account_id === editing.accountId)?.display_name || null
                      : null
                  }
                  onClear={() => setEditing({ ...editing, accountId: null })}
                  onSelect={(m) => {
                    setEditing({ ...editing, accountId: m.account_id })
                    setMemberSearch('')
                  }}
                />
              </FormField>
            ) : (
              <FormField label="当前配额">
                <div className="text-[13px] tabular-nums text-[var(--color-text-sub)]">{fmtBytes(editing.current)}</div>
              </FormField>
            )}

            <FormField
              label="个人上限 (字节)"
              hint="可直接输入字节数, 或点下方快捷按钮"
            >
              <Input
                value={editing.quotaBytes}
                onChange={(e) => setEditing({ ...editing, quotaBytes: e.target.value })}
                placeholder="例: 5368709120 (5 GB)"
                autoFocus={editing.mode === 'edit'}
              />
              <div className="mt-2 flex flex-wrap gap-1.5">
                {QUOTA_PRESETS.map((p) => (
                  <button
                    key={p.label}
                    type="button"
                    onClick={() => setEditing({ ...editing, quotaBytes: String(p.bytes) })}
                    className="rounded-md border border-[var(--color-line)] bg-white px-2 py-1 text-[11px] text-[var(--color-text-sub)] transition hover:border-[var(--color-text-mute)] hover:text-[var(--color-text)]"
                  >
                    {p.label}
                  </button>
                ))}
              </div>
            </FormField>
          </div>
        </DrawerShell>
      )}

      {/* dev-only hint: backend 缺这套 API 时, 帮助 ops 排查 */}
      {!loadErr && !summary && !loading && (
        <div className="mt-4">
          <PrimaryButton onClick={refresh}>重试加载</PrimaryButton>
        </div>
      )}
    </div>
  )
}
