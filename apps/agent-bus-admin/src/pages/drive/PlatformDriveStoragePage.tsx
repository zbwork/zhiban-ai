// PlatformDriveStoragePage — F06 Phase 4 / §5.1 平台云盘存储配置 (only platform scope).
//
// 取代旧 DriveS3Config 的平台默认列表部分; 租户 override 移到 TenantDriveStorageOverridePage.
// 能力: list / create / patch / remove / set-default / test-connection.
//
// 权限: platform.drive.manage_storage. 后端最终把关.

import { useEffect, useState } from 'react'
import {
  DriveStorage,
  type DriveStorageDefault,
  type DriveStorageDefaultCreateInput,
} from '../../lib/api'
import {
  Button, DataTable, DrawerShell, EmptyState, InlineAlert, PageHeader,
  PrimaryButton, RowActions, Switch, Toolbar,
} from '../../components/ui'
import { useConfirmDialog } from '../../components/useConfirmDialog'
import { notifyError, notifyOk } from '../../lib/toast'
import { Database, HardDrive, Star } from 'lucide-react'
import {
  StorageConfigForm,
  type StorageFormValue,
} from './components/StorageConfigForm'
import { validatePlatformForm } from './components/storageValidate'

const emptyForm: StorageFormValue = {
  kind: 'oss',
  name: '',
  region: '',
  endpoint: '',
  read_endpoint: '',
  bucket: '',
  access_key_secret_ref: '',
  secret_key_secret_ref: '',
}

// 启用/禁用 cell: switch 控制 admin 意图 (active <-> disabled)。
//  - 默认行不能禁用 (会留下空默认), Switch 锁死并加 aria-label 提示。
//  - 'degraded' 是 TestConnection 瞬时态, 不会落库, 这里不再渲染该值;
//    若旧数据残留 'degraded', 视作未启用 (off) 并加灰色 "未启用" 标注。
function StatusSwitchCell({
  status,
  isDefault,
  onChange,
}: {
  status: string
  isDefault: boolean
  onChange: (next: 'active' | 'disabled') => Promise<void>
}) {
  const on = status === 'active'
  const ariaLabel = isDefault
    ? '默认存储不可禁用; 请先把其他行设为默认再操作'
    : on ? '禁用此存储' : '启用此存储'
  return (
    <div className="inline-flex items-center gap-2">
      <Switch
        checked={on}
        disabled={isDefault && on}
        ariaLabel={ariaLabel}
        onChange={(next) => onChange(next ? 'active' : 'disabled')}
      />
      <span className="text-[12px] text-[var(--color-text-sub)]">
        {on ? '已启用' : '已禁用'}
      </span>
    </div>
  )
}

export function PlatformDriveStoragePage() {
  const confirm = useConfirmDialog()
  const [items, setItems] = useState<DriveStorageDefault[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [notice, setNotice] = useState('')
  const [editing, setEditing] = useState<DriveStorageDefault | null>(null)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const [form, setForm] = useState<StorageFormValue>(emptyForm)
  const [tick, setTick] = useState(0)
  const refresh = () => setTick((t) => t + 1)

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    DriveStorage.list()
      .then((r) => { if (!cancelled) { setItems(r.items || []); setErr('') } })
      .catch((e: Error) => { if (!cancelled) setErr(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick])

  const openCreate = () => { setEditing(null); setForm(emptyForm); setNotice(''); setDrawerOpen(true) }
  const openEdit = (p: DriveStorageDefault) => {
    setEditing(p)
    setForm({
      kind: (p.kind as StorageFormValue['kind']) || 'oss',
      name: p.name,
      region: p.region,
      endpoint: p.endpoint,
      read_endpoint: p.read_endpoint || '',
      bucket: p.bucket,
      access_key_secret_ref: p.access_key_secret_ref,
      secret_key_secret_ref: p.secret_key_secret_ref,
      // 注意: force_path_style / prefix_tpl / lifecycle_rules 这 3 个字段从 UI 砍掉了,
      // PATCH 时不会再发, 后端 sparse map 不动既有 DB 值 (现有行保留, 例如 caiwu S3 的 path_style=true)。
    })
    setNotice('')
    setDrawerOpen(true)
  }

  const [submitErr, setSubmitErr] = useState('')
  const submit = async () => {
    setSubmitErr('')
    const v = validatePlatformForm(form)
    if (v) { setSubmitErr(v); return }
    const body: DriveStorageDefaultCreateInput = {
      name: form.name!,
      kind: form.kind!,
      region: form.region || '',
      endpoint: form.endpoint || '',
      read_endpoint: form.read_endpoint || undefined,
      bucket: form.bucket!,
      access_key_secret_ref: form.access_key_secret_ref!,
      secret_key_secret_ref: form.secret_key_secret_ref!,
      // force_path_style / prefix_tpl / lifecycle_rules: UI 已砍, 不再发送。
      // 新建行 force_path_style 后端默认 false (适合 AWS S3 / 阿里云 OSS);
      // MinIO / 自建 S3 兼容如需 path-style, 临时通过 PATCH API 或直接改 DB 设 true。
    }
    try {
      if (editing) await DriveStorage.patch(editing.uuid, body)
      else await DriveStorage.create(body)
      setDrawerOpen(false)
      refresh()
    } catch (e) { setSubmitErr((e as Error).message) }
  }

  const setDefault = async (p: DriveStorageDefault) => {
    setNotice('')
    if (p.status !== 'active') { setErr('当前配置已禁用, 不能设为默认'); return }
    try { await DriveStorage.setDefault(p.uuid); setErr(''); refresh() }
    catch (e) { setErr((e as Error).message) }
  }
  const toggleStatus = async (p: DriveStorageDefault, next: 'active' | 'disabled') => {
    setErr('')
    setNotice('')
    try {
      await DriveStorage.patch(p.uuid, { status: next })
      setNotice(`「${p.name}」已${next === 'active' ? '启用' : '禁用'}`)
      refresh()
    } catch (e) { setErr((e as Error).message) }
  }
  const testConn = async (p: DriveStorageDefault) => {
    try {
      const r = await DriveStorage.testConnection(p.uuid)
      if (r.status === 'ok') notifyOk(`「${p.name}」连接通过 · 可用`)
      else notifyError(`「${p.name}」连接异常 (${r.status})${r.message ? ': ' + r.message : ''}`)
    } catch (e) { notifyError((e as Error).message) }
  }
  const remove = async (p: DriveStorageDefault) => {
    const ok = await confirm.confirm({
      title: '删除存储配置',
      description: <>确认删除「<span className="font-medium text-[var(--color-text)]">{p.name}</span>」吗?</>,
      confirmLabel: '删除',
    })
    if (!ok) return
    try { await DriveStorage.remove(p.uuid); refresh() }
    catch (e) { setErr((e as Error).message) }
  }

  return (
    <div>
      {confirm.dialog}
      <PageHeader
        title="云盘存储配置"
        subtitle="平台默认 OSS/S3/MinIO 桶; 列表全租户共用, 单租户可在租户视角下做覆盖。"
      />

      <Toolbar
        summary={<>共 <b className="text-[var(--color-text)]">{items.length}</b> 条配置</>}
        actions={<PrimaryButton onClick={openCreate}>新建存储配置</PrimaryButton>}
      />

      {err && <div className="mb-3"><InlineAlert tone="danger">{err}</InlineAlert></div>}
      {notice && <div className="mb-3"><InlineAlert tone="info">{notice}</InlineAlert></div>}

      <DataTable
        headers={['名称', '类型', '区域', '服务地址', '存储桶', '状态', '默认', '操作']}
        empty={!loading && !items.length ? (
          <EmptyState
            icon={<HardDrive size={20} />}
            title="还没有存储配置"
            description="点击右上角「新建存储配置」加入第一个 OSS/S3/MinIO 桶。"
          />
        ) : null}
      >
        {items.map((p) => (
          <tr key={p.uuid}>
            <td className="px-4 py-3 align-middle">
              <span className="inline-flex items-center gap-2 font-medium text-[var(--color-text)]">
                <Database size={14} className="text-[var(--color-text-mute)]" />
                {p.name}
              </span>
            </td>
            <td className="px-4 py-3 align-middle font-mono text-[12px]">{p.kind}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-sub)]">{p.region || '—'}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px] text-[var(--color-text-sub)]">{p.endpoint}</td>
            <td className="px-4 py-3 align-middle font-mono text-[12px]">{p.bucket}</td>
            <td className="px-4 py-3 align-middle">
              <StatusSwitchCell
                status={p.status}
                isDefault={p.is_default}
                onChange={(next) => toggleStatus(p, next)}
              />
            </td>
            <td className="px-4 py-3 align-middle">
              {p.is_default ? <Star size={14} className="text-amber-500" aria-label="当前默认" /> : '—'}
            </td>
            <td className="px-4 py-3 align-middle">
              <RowActions
                extras={
                  <>
                    <Button size="sm" variant="ghost" onClick={() => testConn(p)}>测试连接</Button>
                    <Button size="sm" variant="ghost" onClick={() => setDefault(p)} disabled={p.is_default}>
                      {p.is_default ? '默认' : '设为默认'}
                    </Button>
                  </>
                }
                onEdit={() => openEdit(p)}
                onDelete={() => remove(p)}
              />
            </td>
          </tr>
        ))}
      </DataTable>

      {drawerOpen && (
        <DrawerShell
          title={editing ? `编辑 ${editing.name}` : '新建存储配置'}
          subtitle={editing ? '修改后立即生效, 已有 URL 不会失效, 但新签的 URL 会使用新参数' : '新增一项平台候选存储; 设为默认后立即生效'}
          width="lg"
          variant="polished"
          onClose={() => setDrawerOpen(false)}
          footer={
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0 flex-1 text-[12px] text-[var(--color-text-sub)]">
                {submitErr && <span className="text-[var(--color-danger)]">{submitErr}</span>}
              </div>
              <div className="flex shrink-0 gap-2">
                <Button variant="secondary" onClick={() => setDrawerOpen(false)}>取消</Button>
                <Button onClick={submit}>{editing ? '保存' : '创建'}</Button>
              </div>
            </div>
          }
        >
          <StorageConfigForm mode="platform" value={form} onChange={setForm} />
        </DrawerShell>
      )}
    </div>
  )
}
