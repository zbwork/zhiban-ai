import { useCallback, useEffect, useMemo, useState } from 'react'
import QRCode from 'qrcode'
import { Members, Departments, MemberContactFields, MemberRoles, Positions, Roles, type MemberDetail, type Department, type InviteMemberInput, type MemberInviteLink, type UpdateMemberInput, type ContactFieldsInput, type ContactFieldVisibility, type Position, type Role } from '../lib/api'
import { Copy, Download, RefreshCw, X } from 'lucide-react'
import { PositionsField, type PositionsFieldValue } from '../components/PositionsField'
import { Button, ConfirmDialog, DrawerShell, FormField as UIFormField, FormSection, InlineAlert, Input as UIInput, PageHeader, Pagination, PrimaryButton, RowActions, SearchInput, Select, Tabs, Toolbar } from '../components/ui'
import { MemberDepartmentSelect } from '../components/form/MemberDepartmentSelect'
import { defaultRootDepartmentID } from '../lib/memberDepartments'
import { notifyOk } from '../lib/toast'
import { copyToClipboard } from '../lib/clipboard'

// Batch 2B T2B.3: suspended 即"已禁用"——schema enum 用 suspended, UI 用更直观的"已禁用"
const STATUS_LABEL: Record<string, string> = {
  active: '在职',
  invited: '已邀请',
  suspended: '已禁用',
  left: '已离开',
}

export function MemberList() {
  const [items, setItems] = useState<MemberDetail[]>([])
  const [total, setTotal] = useState(0)
  const [departments, setDepartments] = useState<Department[]>([])
  const [positions, setPositions] = useState<Position[]>([])
  const [roles, setRoles] = useState<Role[]>([])
  const [deptFilter, setDeptFilter] = useState<number>(0)
  const [q, setQ] = useState('')
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  const [tick, setTick] = useState(0)

  const [inviting, setInviting] = useState(false)
  const [editing, setEditing] = useState<MemberDetail | null>(null)
  const [removing, setRemoving] = useState<MemberDetail | null>(null)
  const [contactFields, setContactFields] = useState<MemberDetail | null>(null)

  useEffect(() => {
    Departments.list().then((r) => setDepartments(r.items || [])).catch(() => {})
    Positions.list('', 200, 0).then((r) => setPositions(r.items || [])).catch(() => {})
    // 拉租户内可分配的角色, 用于把 role.code → role.name 反查渲染。
    Roles.list('tenant', '', 200, 0).then((r) => setRoles(r.items || [])).catch(() => {})
  }, [])

  useEffect(() => {
    Members.list(deptFilter, q, pageSize, (page - 1) * pageSize)
      .then((r) => { setItems(r.items || []); setTotal(r.total); setErr('') })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [deptFilter, q, page, pageSize, tick])

  const deptMap = useMemo(() => {
    const m = new Map<number, string>()
    departments.forEach((d) => m.set(d.id, d.name))
    return m
  }, [departments])

  const roleNameMap = useMemo(() => {
    const m = new Map<string, string>()
    roles.forEach((r) => m.set(r.Code, r.Name))
    return m
  }, [roles])

  const refresh = () => setTick((t) => t + 1)

  return (
    <div>
      <PageHeader title="租户成员" subtitle="管理租户成员、角色、部门和通讯录字段。" />

      <Toolbar
        search={
          <SearchInput
            value={q}
            onChange={(v) => { setQ(v); setPage(1) }}
            placeholder="搜索姓名 / 手机 / 邮箱"
          />
        }
        filters={
          <div className="w-[160px]">
            <Select
              value={deptFilter}
              onChange={(e) => { setDeptFilter(Number(e.target.value)); setPage(1) }}
            >
              <option value={0}>全部部门</option>
              {departments.map((d) => (
                <option key={d.id} value={d.id}>{d.name}（{d.member_count}）</option>
              ))}
            </Select>
          </div>
        }
        summary={<>共 <span className="font-semibold text-[var(--color-text)] tabular-nums">{total}</span> 人</>}
        actions={<PrimaryButton onClick={() => setInviting(true)}>邀请成员</PrimaryButton>}
      />

      {err && <Err msg={err} />}

      <div className="bg-white rounded-lg card-shadow overflow-hidden">
        <div className="table-sticky-actions overflow-x-auto">
        <table className="w-full text-[13px]" style={{ minWidth: 'max-content' }}>
          <thead>
            <tr className="text-left bg-[var(--color-bg-sub)]">
              <Th>成员</Th>
              <Th>工号</Th>
              <Th>联系方式</Th>
              <Th>部门</Th>
              <Th>职位</Th>
              <Th>角色</Th>
              <Th>加入时间</Th>
              <Th>状态</Th>
              <Th>通讯录</Th>
              <Th>操作</Th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr><td colSpan={10} className="px-4 py-10 text-center text-[var(--color-text-mute)]">加载中…</td></tr>
            ) : items.length === 0 ? (
              <tr><td colSpan={10} className="px-4 py-10 text-center text-[var(--color-text-mute)]">没有匹配的成员</td></tr>
            ) : (
              items.map((m) => (
                <tr key={m.membership_id} className="border-t border-[var(--color-line)] hover:bg-[var(--color-bg-sub)]/60 transition">
                  <Td>
                    <div className="font-medium truncate">{m.display_name}</div>
                  </Td>
                  <Td className="text-[12px] text-[var(--color-text-sub)] font-mono">
                    {m.employee_id || <span className="text-[var(--color-text-mute)] font-sans">—</span>}
                  </Td>
                  <Td className="text-[var(--color-text-sub)]">
                    {m.phone && <div className="font-mono text-[12px]">{m.phone}</div>}
                    {m.email && <div className="font-mono text-[12px]">{m.email}</div>}
                  </Td>
                  <Td className="text-[var(--color-text-sub)]">
                    {m.department_name || (m.department_id ? deptMap.get(m.department_id) : '—')}
                  </Td>
                  <Td className="text-[var(--color-text-sub)] text-[12px]">
                    {m.title || '—'}
                  </Td>
                  <Td>
                    <div className="flex items-center gap-1.5 flex-wrap">
                      {(m.roles || []).map((code) => {
                        const name = roleNameMap.get(code)
                        return (
                          <span
                            key={code}
                            title={code}
                            className="text-[12px] px-2 py-0.5 rounded ring-border-soft bg-[var(--color-bg-sub)] text-[var(--color-text-sub)]"
                          >
                            {name || code}
                          </span>
                        )
                      })}
                      {(!m.roles || m.roles.length === 0) && <span className="text-[12px] text-[var(--color-text-mute)]">—</span>}
                    </div>
                  </Td>
                  <Td className="text-[12px] text-[var(--color-text-mute)] font-mono">{m.joined_at || '—'}</Td>
                  <Td><StatusPill status={m.status} /></Td>
                  <Td><ContactVisibilityPill hidden={m.contact_fields?.hidden_in_contacts === true} /></Td>
                  <Td>
                    <RowActions
                      extras={
                        <Button size="sm" variant="ghost" onClick={() => setContactFields(m)}>通讯录</Button>
                      }
                      onEdit={() => setEditing(m)}
                      onDelete={() => setRemoving(m)}
                      deleteLabel="移出"
                    />
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
        </div>
      </div>
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {inviting && (
        <InviteModal
          departments={departments}
          positions={positions}
          roles={roles}
          onClose={() => setInviting(false)}
          onSubmit={async (body, posValue, roleIds) => {
            const result = await Members.invite({
              ...body,
              role_ids: roleIds,
              position_ids: posValue.positionIds,
              primary_position_id: posValue.primaryPositionId ?? null,
            })
            setInviting(false)
            if (result.status === 'accepted') {
              notifyOk('短信确认已临时旁路（应急开关开启中），该成员已直接加入企业')
            } else {
              notifyOk(result.sms_sent
                ? '邀请已发送，对方接受后才会成为企业成员'
                : '邀请已创建，但短信模板暂未配置或发送失败，请稍后重发')
            }
            refresh()
          }}
        />
      )}
      {editing && (
        <EditModal
          member={editing}
          departments={departments}
          positions={positions}
          roles={roles}
          onClose={() => setEditing(null)}
          onSubmit={async (body, posValue, roleIds) => {
            await Members.update(editing.membership_id, body)
            await Positions.assignToMember(editing.membership_id, {
              positionIds: posValue.positionIds,
              primaryPositionId: posValue.primaryPositionId ?? null,
            })
            if (roleIds.length > 0) await MemberRoles.syncTenantRoles(editing.membership_id, roleIds)
            setEditing(null)
            refresh()
          }}
        />
      )}
      {removing && (
        <RemoveConfirm
          member={removing}
          onClose={() => setRemoving(null)}
          onConfirm={async () => { await Members.remove(removing.membership_id); setRemoving(null); refresh() }}
        />
      )}
      {contactFields && (
        <ContactFieldsDrawer
          member={contactFields}
          onClose={() => setContactFields(null)}
          onSaved={() => { setContactFields(null); refresh() }}
        />
      )}
    </div>
  )
}

/* ---------- modals ---------- */

function InviteModal({ departments, positions, roles, onClose, onSubmit }: {
  departments: Department[]
  positions: Position[]
  roles: Role[]
  onClose: () => void
  onSubmit: (b: InviteMemberInput, p: PositionsFieldValue, roleIds: number[]) => Promise<void>
}) {
  const [tab, setTab] = useState<'phone' | 'qr' | 'link'>('phone')
  const [phone, setPhone] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [employeeID, setEmployeeID] = useState('')
  const [departmentID, setDepartmentID] = useState<number | ''>(() => defaultRootDepartmentID(departments))
  const [roleIds, setRoleIds] = useState<number[]>(() => defaultTenantRoleIds(roles))
  const [posValue, setPosValue] = useState<PositionsFieldValue>({ positionIds: [], primaryPositionId: null })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [inviteLink, setInviteLink] = useState<MemberInviteLink | null>(null)
  const [linkLoading, setLinkLoading] = useState(false)
  const [linkErr, setLinkErr] = useState('')
  const [qrDataURL, setQRDataURL] = useState('')
  const [resetConfirming, setResetConfirming] = useState(false)
  const effectiveRoleIds = roleIds.length > 0 ? roleIds : defaultTenantRoleIds(roles)
  const effectiveDepartmentID = departmentID === '' ? defaultRootDepartmentID(departments) : departmentID

  const loadInviteLink = useCallback(async () => {
    setLinkLoading(true)
    setLinkErr('')
    try {
      setInviteLink(await Members.invitationLink())
    } catch (e: unknown) {
      setLinkErr((e as Error).message)
    } finally {
      setLinkLoading(false)
    }
  }, [])

  useEffect(() => {
    if (!inviteLink?.url) {
      return
    }
    let active = true
    QRCode.toDataURL(inviteLink.url, { width: 320, margin: 2, errorCorrectionLevel: 'M' })
      .then((dataURL) => {
        if (active) setQRDataURL(dataURL)
      })
      .catch(() => {
        if (active) setLinkErr('二维码生成失败，请刷新后重试')
      })
    return () => { active = false }
  }, [inviteLink?.url])

  const submit = async () => {
    if (!phone) { setErr('请输入手机号'); return }
    if (!displayName.trim()) { setErr('请输入姓名'); return }
    if (effectiveDepartmentID === '') { setErr('请选择部门'); return }
    if (roles.length === 0) { setErr('角色数据未加载，请刷新后重试'); return }
    if (effectiveRoleIds.length === 0) { setErr('请至少选择一个角色'); return }
    setBusy(true); setErr('')
    try {
      await onSubmit({
        phone,
        display_name: displayName.trim(),
        employee_id: employeeID || undefined,
        department_id: Number(effectiveDepartmentID),
        role_ids: effectiveRoleIds,
      }, posValue, effectiveRoleIds)
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const copyLink = async () => {
    if (!inviteLink?.url) return
    if (await copyToClipboard(inviteLink.url)) {
      notifyOk('邀请链接已复制')
    } else {
      setLinkErr('复制失败，请手动选择链接复制')
    }
  }

  const downloadQRCode = () => {
    if (!qrDataURL) return
    const anchor = document.createElement('a')
    anchor.href = qrDataURL
    anchor.download = 'zhiban-member-invite-qrcode.png'
    anchor.click()
    notifyOk('二维码已下载')
  }

  const resetLink = async () => {
    setLinkErr('')
    try {
      const next = await Members.resetInvitationLink()
      setInviteLink(next)
      setResetConfirming(false)
      notifyOk('邀请二维码和链接已重置')
    } catch (e: unknown) {
      setLinkErr((e as Error).message)
      throw e
    }
  }

  return (
    <>
      <DrawerShell
        title="邀请成员"
        subtitle="可按手机号定向邀请，也可分享二维码或链接；对方确认后才会成为企业成员。"
        onClose={onClose}
        width="md"
        footer={(
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={onClose} disabled={busy}>关闭</Button>
            {tab === 'phone' && (
              <Button variant="primary" onClick={submit} disabled={busy}>
                {busy ? '发送中…' : '发送邀请'}
              </Button>
            )}
          </div>
        )}
      >
        <div className="space-y-5">
          <Tabs
            value={tab}
            onChange={(value) => {
              setTab(value)
              setErr('')
              if (value !== 'phone' && inviteLink === null && !linkLoading) {
                void loadInviteLink()
              }
            }}
            className="grid w-full grid-cols-3"
            items={[
              { value: 'phone', label: '手机号邀请' },
              { value: 'qr', label: '邀请二维码' },
              { value: 'link', label: '邀请链接' },
            ]}
          />
          {tab === 'phone' ? (
            <>
              <InlineAlert tone="info">
                受邀人将通过短信打开确认页，可选择接受或拒绝。接受前不会获得本企业的任何访问权限。
              </InlineAlert>
              <FormSection title="成员信息">
                <div className="grid grid-cols-2 gap-4">
                  <UIFormField label="手机号">
                    <UIInput value={phone} onChange={(e) => setPhone(e.target.value)} className="font-mono" placeholder="13800000000" autoFocus />
                  </UIFormField>
                  <UIFormField label="姓名">
                    <UIInput value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="张三" />
                  </UIFormField>
                  <UIFormField label="工号">
                    <UIInput value={employeeID} onChange={(e) => setEmployeeID(e.target.value)} className="font-mono" />
                  </UIFormField>
                  <UIFormField label="部门（必选）">
                    <MemberDepartmentSelect departments={departments} value={effectiveDepartmentID} onChange={setDepartmentID} />
                  </UIFormField>
                </div>
              </FormSection>
              <FormSection title="入职配置">
                <div className="space-y-4">
                  <UIFormField label="职位" hint="接受邀请后写入通讯录职位">
                    <PositionsField value={posValue} onChange={setPosValue} positions={positions} />
                  </UIFormField>
                  {roles.length > 0 && (
                    <UIFormField label="角色" hint="接受邀请前角色不会生效">
                      <TenantRoleChecks roles={roles} selected={effectiveRoleIds} onChange={setRoleIds} />
                    </UIFormField>
                  )}
                </div>
              </FormSection>
              {err && <InlineAlert tone="danger">{err}</InlineAlert>}
            </>
          ) : (
            <div className="space-y-4">
              <InlineAlert tone="info">
                通过二维码或链接加入的成员将进入根部门，并获得普通成员角色。链接可被转发，不会携带管理角色或其他预设权限。
              </InlineAlert>
              {linkLoading && (
                <div className="rounded-lg border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-4 py-12 text-center text-[13px] text-[var(--color-text-mute)]">
                  正在生成邀请信息…
                </div>
              )}
              {linkErr && (
                <InlineAlert tone="danger">
                  <div className="flex items-center justify-between gap-3">
                    <span>{linkErr}</span>
                    {!inviteLink && <Button size="sm" variant="secondary" onClick={() => void loadInviteLink()}>重试</Button>}
                  </div>
                </InlineAlert>
              )}
              {inviteLink && (
                <FormSection
                  title={tab === 'qr' ? '企业邀请二维码' : '企业邀请链接'}
                  description={`${inviteLink.tenant_name} · 有效期至 ${formatInviteExpiry(inviteLink.expires_at)}`}
                >
                  {tab === 'qr' ? (
                    <div className="flex flex-col items-center gap-4 py-2">
                      <div className="rounded-lg border border-[var(--color-line)] bg-white p-3">
                        {qrDataURL
                          ? <img src={qrDataURL} alt={`${inviteLink.tenant_name} 邀请二维码`} className="h-64 w-64" />
                          : <div className="grid h-64 w-64 place-items-center text-[13px] text-[var(--color-text-mute)]">正在生成二维码…</div>}
                      </div>
                      <p className="text-center text-[12px] text-[var(--color-text-mute)]">
                        对方扫码后需填写姓名、手机号并通过短信验证，确认后才会加入企业。
                      </p>
                      <div className="flex flex-wrap justify-center gap-2">
                        <Button variant="secondary" onClick={downloadQRCode} disabled={!qrDataURL}>
                          <Download size={15} />下载二维码
                        </Button>
                        <Button variant="secondary" onClick={() => void copyLink()}>
                          <Copy size={15} />复制邀请链接
                        </Button>
                        <Button variant="ghost" onClick={() => setResetConfirming(true)}>
                          <RefreshCw size={15} />重置
                        </Button>
                      </div>
                    </div>
                  ) : (
                    <div className="space-y-4 py-1">
                      <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-3 font-mono text-[12px] leading-5 text-[var(--color-text-sub)] break-all">
                        {inviteLink.url}
                      </div>
                      <p className="text-[12px] text-[var(--color-text-mute)]">
                        复制后发送给受邀人。重置后，之前发出的二维码和链接都会立即失效。
                      </p>
                      <div className="flex flex-wrap gap-2">
                        <Button variant="primary" onClick={() => void copyLink()}>
                          <Copy size={15} />复制链接
                        </Button>
                        <Button variant="secondary" onClick={() => setResetConfirming(true)}>
                          <RefreshCw size={15} />重置链接
                        </Button>
                      </div>
                    </div>
                  )}
                </FormSection>
              )}
            </div>
          )}
        </div>
      </DrawerShell>
      {resetConfirming && (
        <ConfirmDialog
          title="重置邀请二维码和链接"
          description="重置后，之前发出的二维码和邀请链接将立即失效。确认生成新的邀请信息吗？"
          confirmLabel="确认重置"
          busyLabel="重置中…"
          onClose={() => setResetConfirming(false)}
          onConfirm={resetLink}
        />
      )}
    </>
  )
}

function formatInviteExpiry(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
}

function EditModal({ member, departments, positions, roles, onClose, onSubmit }: {
  member: MemberDetail
  departments: Department[]
  positions: Position[]
  roles: Role[]
  onClose: () => void
  onSubmit: (b: UpdateMemberInput, p: PositionsFieldValue, roleIds: number[]) => Promise<void>
}) {
  const [displayName, setDisplayName] = useState(member.display_name || '')
  const [employeeID, setEmployeeID] = useState(member.employee_id || '')
  const [departmentID, setDepartmentID] = useState<number | ''>(member.department_id ?? '')
  const [status, setStatus] = useState(member.status)
  const [posValue, setPosValue] = useState<PositionsFieldValue>({ positionIds: [], primaryPositionId: null })
  const [roleIds, setRoleIds] = useState<number[]>(() => roles.filter((r) => member.roles?.includes(r.Code)).map((r) => r.ID))
  const [loadingPos, setLoadingPos] = useState(true)
  const [loadingRoles, setLoadingRoles] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const effectiveDepartmentID = departmentID === '' ? defaultRootDepartmentID(departments) : departmentID

  useEffect(() => {
    Positions.listForMember(member.membership_id)
      .then((r) => {
        const items = r.items || []
        setPosValue({
          positionIds: items.map((it) => it.positionId),
          primaryPositionId: items.find((it) => it.isPrimary)?.positionId ?? null,
        })
      })
      .catch(() => {})
      .finally(() => setLoadingPos(false))
  }, [member.membership_id])

  useEffect(() => {
    MemberRoles.list(member.membership_id)
      .then((r) => {
        const ids = (r.items || [])
          .filter((it) => it.ScopeKind === 'tenant')
          .map((it) => it.RoleID)
        setRoleIds(ids.length ? ids : roles.filter((role) => member.roles?.includes(role.Code)).map((role) => role.ID))
      })
      .catch(() => {})
      .finally(() => setLoadingRoles(false))
  }, [member.membership_id, member.roles, roles])

  const submit = async () => {
    if (roles.length > 0 && roleIds.length === 0) { setErr('请至少选择一个角色'); return }
    if (effectiveDepartmentID === '') { setErr('请选择部门'); return }
    setBusy(true); setErr('')
    try {
      await onSubmit({
        display_name: displayName,
        employee_id: employeeID,
        department_id: Number(effectiveDepartmentID),
        status,
      }, posValue, roleIds)
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={`编辑成员：${member.display_name}`} onClose={onClose}>
      <div className="space-y-4">
        <FormField label="显示名" hint="该租户成员列表和通讯录优先展示此名称">
          <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} className={inputCls} placeholder="张三" />
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField label="工号">
            <input value={employeeID} onChange={(e) => setEmployeeID(e.target.value)} className={inputCls + ' font-mono'} />
          </FormField>
          <FormField label="部门（必选）">
            <MemberDepartmentSelect departments={departments} value={effectiveDepartmentID} onChange={setDepartmentID} />
          </FormField>
        </div>
        <FormField label="职位" hint={loadingPos ? '加载中…' : '通讯录主显示字段（一人一岗）'}>
          <PositionsField value={posValue} onChange={setPosValue} positions={positions} disabled={loadingPos} />
        </FormField>
        {roles.length > 0 && (
          <FormField label="角色" hint={loadingRoles ? '加载中…' : '可同时授予多个角色'}>
            <TenantRoleChecks roles={roles} selected={roleIds} onChange={setRoleIds} disabled={loadingRoles} />
          </FormField>
        )}
        <div className="grid grid-cols-2 gap-3">
          <FormField label="状态">
            <Select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="active">在职</option>
              <option value="invited">已邀请</option>
              <option value="suspended">已暂停</option>
              <option value="left">已离开</option>
            </Select>
          </FormField>
        </div>
      </div>
      {err && <div className="mt-4 text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md px-3 py-2">{err}</div>}
      <div className="flex justify-end gap-2 mt-6">
        <Button variant="secondary" onClick={onClose}>取消</Button>
        <PrimaryButton onClick={submit} disabled={busy}>{busy ? '保存中…' : '保存'}</PrimaryButton>
      </div>
    </Modal>
  )
}

function RemoveConfirm({ member, onClose, onConfirm }: { member: MemberDetail; onClose: () => void; onConfirm: () => Promise<void> }) {
  return (
    <ConfirmDialog
      title="移出租户"
      description={<>你将把 <strong className="text-[var(--color-text)]">{member.display_name}</strong> 从本租户移除。</>}
      confirmLabel="确认移出"
      busyLabel="处理中…"
      onClose={onClose}
      onConfirm={onConfirm}
    >
      <InlineAlert tone="warn">
        租户创建人需要先转让所有权；最后一名超级管理员不能被移出。此操作只删除该用户在本租户的成员关系与角色，不会删除账号本身。
      </InlineAlert>
    </ConfirmDialog>
  )
}

function defaultTenantRoleIds(roles: Role[]) {
  const member = roles.find((r) => r.Code === 'tenant.member')
  if (member) return [member.ID]
  return roles[0] ? [roles[0].ID] : []
}

function TenantRoleChecks({ roles, selected, disabled = false, onChange }: {
  roles: Role[]
  selected: number[]
  disabled?: boolean
  onChange: (ids: number[]) => void
}) {
  if (roles.length === 0) {
    return <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] px-3 py-3 text-[13px] text-[var(--color-text-mute)]">暂无可分配角色</div>
  }
  return (
    <div className="max-h-44 overflow-auto rounded-md border border-[var(--color-line)] bg-white p-2">
      {roles.map((role) => (
        <label key={role.ID} title={role.Code} className="flex items-center gap-2 rounded px-2 py-1.5 text-[13px] hover:bg-[var(--color-line-soft)]">
          <input
            type="checkbox"
            disabled={disabled}
            checked={selected.includes(role.ID)}
            onChange={(e) => onChange(toggleId(selected, role.ID, e.target.checked))}
          />
          <span className="min-w-0 truncate text-[var(--color-text)]">{role.Name}</span>
        </label>
      ))}
    </div>
  )
}

function toggleId(ids: number[], id: number, enabled: boolean) {
  return enabled ? Array.from(new Set([...ids, id])) : ids.filter((x) => x !== id)
}

/* ---------- shared ---------- */

const inputCls = 'w-full h-9 px-3 rounded-md ring-border bg-white text-[13px] focus:outline-none focus:shadow-[var(--color-focus)_0px_0px_0px_2px]'

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 bg-[hsla(0,0%,0%,0.35)] grid place-items-center z-50 px-4 backdrop-blur-sm" onClick={onClose}>
      <div className="bg-white rounded-lg card-shadow w-full max-w-lg p-6" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <h3 className="text-[20px] font-semibold tracking-tight">{title}</h3>
          <button onClick={onClose} className="w-7 h-7 grid place-items-center rounded-md hover:bg-[var(--color-line-soft)]"><X size={14} /></button>
        </div>
        {children}
      </div>
    </div>
  )
}

function FormField({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[12px] font-medium text-[var(--color-text)] mb-1">{label}</label>
      {children}
      {hint && <p className="text-[11px] text-[var(--color-text-mute)] mt-1">{hint}</p>}
    </div>
  )
}

// 列头永远不允许 char-by-char 折断; 列值默认也 nowrap (本表全是短值: 工号/电话/部门/岗位/时间/状态)。
// 长内容 (name) 自身用 truncate 控制宽度, 不靠 cell 折断。
function Th({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2.5 text-[13px] text-left font-semibold text-[var(--color-text)] whitespace-nowrap ${className}`}>{children}</th>
}
function Td({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 whitespace-nowrap ${className}`}>{children}</td>
}

function StatusPill({ status }: { status: string }) {
  const map: Record<string, string> = {
    active: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
    invited: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
    suspended: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
    left: 'bg-[var(--color-line-soft)] text-[var(--color-text-mute)]',
  }
  return (
    <span className={`inline-block px-2 py-0.5 text-[11px] rounded ring-border-soft ${map[status] || map.left}`}>
      {STATUS_LABEL[status] || status}
    </span>
  )
}

function ContactVisibilityPill({ hidden }: { hidden: boolean }) {
  return (
    <span
      className={`inline-block px-2 py-0.5 text-[11px] rounded ring-border-soft ${
        hidden
          ? 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
          : 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
      }`}
    >
      {hidden ? '隐藏' : '显示'}
    </span>
  )
}

function Err({ msg }: { msg: string }) {
  return <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md px-3 py-2 mb-4">{msg}</div>
}

// ContactFieldsDrawer M2 §5.3 / §6.4 成员通讯录设置抽屉。
// 成员接口只返回白名单化 contact_fields，抽屉必须回填真实值，避免再次保存时覆盖为默认值。
function ContactFieldsDrawer({ member, onClose, onSaved }: { member: MemberDetail; onClose: () => void; onSaved: () => void }) {
  const fields = member.contact_fields
  const [hiddenInContacts, setHidden] = useState(fields?.hidden_in_contacts ?? false)
  const [allowInvite, setAllowInvite] = useState(fields?.allow_invite_to_group ?? true)
  const [phoneVis, setPhoneVis] = useState<ContactFieldVisibility>(fields?.field_mask?.phone ?? 'department')
  const [emailVis, setEmailVis] = useState<ContactFieldVisibility>(fields?.field_mask?.email ?? 'department')
  const [titleVis, setTitleVis] = useState<ContactFieldVisibility>(fields?.field_mask?.title ?? 'all')
  const [positionLabel, setPositionLabel] = useState(fields?.position_label_override ?? '')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const hiddenID = `member-contact-hidden-${member.membership_id}`
  const inviteID = `member-contact-invite-${member.membership_id}`

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      const body: ContactFieldsInput = {
        hidden_in_contacts: hiddenInContacts,
        allow_invite_to_group: allowInvite,
        field_mask: { phone: phoneVis, email: emailVis, title: titleVis },
        // 空字符串有明确“清除覆盖值”语义，不能省略字段。
        position_label_override: positionLabel.trim(),
      }
      await MemberContactFields.patch(member.membership_id, body)
      notifyOk('通讯录设置已保存')
      onSaved()
    } catch (e: unknown) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={`通讯录设置 · ${member.display_name}`}
      subtitle="设置该成员在客户端通讯录中的展示范围和拉群权限，保存后即时生效。"
      onClose={onClose}
      width="sm"
      footer={(
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <PrimaryButton onClick={() => void submit()} disabled={busy}>
            {busy ? '保存中…' : '保存'}
          </PrimaryButton>
        </div>
      )}
    >
      <div className="space-y-4">
        {err && <InlineAlert tone="danger">{err}</InlineAlert>}

        <FormSection title="展示与拉群">
          <div className="space-y-3">
            <div className="flex items-center gap-3">
              <input id={hiddenID} type="checkbox" checked={hiddenInContacts} onChange={(e) => setHidden(e.target.checked)} />
              <label htmlFor={hiddenID} className="text-[13px] text-[var(--color-text)]">不进入客户端通讯录</label>
            </div>
            <div className="flex items-center gap-3">
              <input id={inviteID} type="checkbox" checked={allowInvite} onChange={(e) => setAllowInvite(e.target.checked)} />
              <label htmlFor={inviteID} className="text-[13px] text-[var(--color-text)]">允许被任意成员拉群</label>
            </div>
          </div>
        </FormSection>

        <FormSection title="字段可见性" description="成员级设置覆盖租户通讯录默认策略。">
          <div className="space-y-4">
            <FieldVisRow label="电话可见性" value={phoneVis} onChange={setPhoneVis} />
            <FieldVisRow label="邮箱可见性" value={emailVis} onChange={setEmailVis} />
            <FieldVisRow label="岗位可见性" value={titleVis} onChange={setTitleVis} />
            <UIFormField label="通讯录展示职位（可选）" hint="留空并保存会清除覆盖值，恢复使用成员岗位。">
              <UIInput
                value={positionLabel}
                onChange={(e) => setPositionLabel(e.target.value)}
                placeholder="留空则使用成员岗位"
              />
            </UIFormField>
          </div>
        </FormSection>
      </div>
    </DrawerShell>
  )
}

function FieldVisRow({ label, value, onChange }: { label: string; value: ContactFieldVisibility; onChange: (v: ContactFieldVisibility) => void }) {
  return (
    <UIFormField label={label}>
      <Select value={value} onChange={(e) => onChange(e.target.value as ContactFieldVisibility)}>
        <option value="all">所有人可见</option>
        <option value="department">同部门可见</option>
        <option value="self">仅本人可见</option>
        <option value="hidden">完全隐藏</option>
      </Select>
    </UIFormField>
  )
}
