import { useEffect, useMemo, useState } from 'react'
import { CheckCircle2, Clipboard, RefreshCw, Send, Workflow } from 'lucide-react'
import {
  Button,
  ConfirmDialog,
  DataTable,
  DialogShell,
  DrawerShell,
  EmptyState,
  FormField,
  FormSection,
  InlineAlert,
  Input,
  PageHeader,
  PrimaryButton,
  RowActions,
  Switch,
  Toolbar,
  stickyLeftTdCls,
  stickyRightTdCls,
} from '../components/ui'
import {
  OrgWebhooks,
  type OrgWebhook,
  type OrgWebhookDelivery,
  type OrgWebhookSecretResult,
} from '../lib/api'

const ORG_EVENTS = [
  { value: 'org.member.created', label: '成员创建', group: '成员' },
  { value: 'org.member.updated', label: '成员更新', group: '成员' },
  { value: 'org.member.deleted', label: '成员删除', group: '成员' },
  { value: 'org.department.created', label: '部门创建', group: '部门' },
  { value: 'org.department.updated', label: '部门更新', group: '部门' },
  { value: 'org.department.deleted', label: '部门删除', group: '部门' },
  { value: 'org.position.created', label: '职位创建', group: '职位' },
  { value: 'org.position.updated', label: '职位更新', group: '职位' },
  { value: 'org.position.deleted', label: '职位删除', group: '职位' },
  // F25: 告警外发复用本通道；精确订阅事件时也能选告警
  { value: 'notify.alert.fired', label: '告警触发', group: '告警' },
  { value: 'notify.alert.resolved', label: '告警恢复', group: '告警' },
]

const STATUS_LABEL: Record<string, string> = {
  pending: '待投递',
  picked: '投递中',
  failed: '待重试',
  done: '成功',
  dlq: '已失败',
}

const STATUS_CLASS: Record<string, string> = {
  pending: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  picked: 'bg-[var(--color-info-bg)] text-[var(--color-info)]',
  failed: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]',
  done: 'bg-[var(--color-success-bg)] text-[var(--color-success)]',
  dlq: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]',
}

function formatTime(v?: string) {
  if (!v) return '-'
  return new Date(v).toLocaleString()
}

function eventSummary(types: string[]) {
  if (!types || types.length === 0) return '全部组织事件'
  return `${types.length} 类事件`
}

export function OrgSyncPage() {
  const [items, setItems] = useState<OrgWebhook[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [editing, setEditing] = useState<OrgWebhook | null>(null)
  const [creating, setCreating] = useState(false)
  const [secretResult, setSecretResult] = useState<OrgWebhookSecretResult | null>(null)
  const [removing, setRemoving] = useState<OrgWebhook | null>(null)
  const [deliveriesFor, setDeliveriesFor] = useState<OrgWebhook | null>(null)
  const [deliveries, setDeliveries] = useState<OrgWebhookDelivery[]>([])
  const [deliveriesLoading, setDeliveriesLoading] = useState(false)
  const [testResult, setTestResult] = useState<{ title: string; message: string; ok: boolean } | null>(null)

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 列表刷新进入加载态，与远端数据源同步。
    setLoading(true)
    OrgWebhooks.list()
      .then((r) => {
        setItems(r.items || [])
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [tick])

  useEffect(() => {
    if (!deliveriesFor) return
    // eslint-disable-next-line react-hooks/set-state-in-effect -- 切换配置后加载对应投递记录。
    setDeliveriesLoading(true)
    OrgWebhooks.deliveries(deliveriesFor.uuid, 20)
      .then((r) => setDeliveries(r.items || []))
      .catch((e: Error) => setErr(e.message))
      .finally(() => setDeliveriesLoading(false))
  }, [deliveriesFor, tick])

  const refresh = () => setTick((t) => t + 1)

  const activeCount = useMemo(() => items.filter((item) => item.enabled).length, [items])

  const testWebhook = async (item: OrgWebhook) => {
    try {
      const result = await OrgWebhooks.test(item.uuid)
      const ok = result.statusCode >= 200 && result.statusCode < 300
      setTestResult({
        ok,
        title: ok ? '测试发送成功' : '测试发送未通过',
        message: `HTTP ${result.statusCode}: ${result.message}`,
      })
    } catch (e) {
      setTestResult({ ok: false, title: '测试发送失败', message: (e as Error).message })
    }
  }

  return (
    <div>
      <PageHeader
        title="组织同步"
        subtitle="配置外部系统接收成员、部门、职位变更通知。外部系统收到通知后，可按 entity_uuid 或 updated_since 回查 External API。"
      />

      {err && <InlineAlert>{err}</InlineAlert>}

      <Toolbar
        summary={(
          <span>
            共 <span className="font-medium text-[var(--color-text)]">{items.length}</span> 个配置，
            <span className="font-medium text-[var(--color-text)]">{activeCount}</span> 个启用
          </span>
        )}
        actions={(
          <>
            <Button variant="secondary" onClick={refresh}><RefreshCw size={14} />刷新</Button>
            <PrimaryButton onClick={() => setCreating(true)}>新建同步</PrimaryButton>
          </>
        )}
      />

      <DataTable
        headers={['名称', '回调地址', '事件范围', '状态', '最近投递', '创建时间', '操作']}
        stickyFirstCol
        stickyLastCol
        loading={loading ? <div className="px-4 py-10 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div> : null}
        empty={!loading && items.length === 0 ? (
          <EmptyState
            icon={<Workflow size={26} />}
            title="暂无组织同步配置"
            description="配置后，成员、部门、职位变化会向外部系统发送薄通知。"
          />
        ) : null}
      >
        {!loading && items.map((item) => (
          <tr key={item.uuid} className="group hover:bg-[var(--color-bg-sub)]">
            <td className={`w-[260px] min-w-[260px] max-w-[260px] px-4 py-3 ${stickyLeftTdCls}`}>
              <div className="truncate font-medium text-[var(--color-text)]" title={item.name}>{item.name}</div>
              {item.description && <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]" title={item.description}>{item.description}</div>}
            </td>
            <td className="w-[460px] min-w-[420px] max-w-[520px] px-4 py-3">
              <div className="truncate font-mono text-[12px] text-[var(--color-text-sub)]" title={item.callbackUrl}>
                {item.callbackUrl}
              </div>
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{eventSummary(item.eventTypes)}</td>
            <td className="whitespace-nowrap px-4 py-3">
              <Switch
                checked={item.enabled}
                ariaLabel={item.enabled ? '停用组织同步' : '启用组织同步'}
                onChange={async (checked) => {
                  await OrgWebhooks.patch(item.uuid, { enabled: checked })
                  refresh()
                }}
              />
            </td>
            <td className="whitespace-nowrap px-4 py-3">
              {item.latestDelivery ? (
                <button
                  type="button"
                  className="text-left text-[13px] text-[var(--color-brand)] hover:underline"
                  onClick={() => setDeliveriesFor(item)}
                >
                  {STATUS_LABEL[item.latestDelivery.status] || item.latestDelivery.status}
                  <span className="ml-1 text-[var(--color-text-sub)]">{formatTime(item.latestDelivery.createdAt)}</span>
                </button>
              ) : (
                <span className="text-[var(--color-text-sub)]">暂无投递</span>
              )}
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{formatTime(item.createdAt)}</td>
            <td className={`${stickyRightTdCls} w-[340px] min-w-[340px] px-4 py-3`}>
              <RowActions
                onEdit={() => setEditing(item)}
                onDelete={() => setRemoving(item)}
                className="min-w-max"
                extras={(
                  <>
                    <button
                      type="button"
                      className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                      title="测试发送"
                      aria-label="测试发送"
                      onClick={() => void testWebhook(item)}
                    >
                      测试发送
                    </button>
                    <button
                      type="button"
                      className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                      title="重置密钥"
                      aria-label="重置密钥"
                      onClick={async () => {
                        const result = await OrgWebhooks.rotateSecret(item.uuid)
                        setSecretResult(result)
                        refresh()
                      }}
                    >
                      重置密钥
                    </button>
                    <button
                      type="button"
                      className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-text-sub)] transition hover:bg-[var(--color-control-hover)] hover:text-[var(--color-text)]"
                      title="投递记录"
                      aria-label="投递记录"
                      onClick={() => setDeliveriesFor(item)}
                    >
                      投递记录
                    </button>
                  </>
                )}
              />
            </td>
          </tr>
        ))}
      </DataTable>

      {deliveriesFor && (
        <DeliveryPanel
          item={deliveriesFor}
          deliveries={deliveries}
          loading={deliveriesLoading}
          onClose={() => setDeliveriesFor(null)}
        />
      )}

      {(creating || editing) && (
        <OrgWebhookDrawer
          initial={editing || undefined}
          onClose={() => { setCreating(false); setEditing(null) }}
          onSaved={(result) => {
            setCreating(false)
            setEditing(null)
            if (result) setSecretResult(result)
            refresh()
          }}
        />
      )}

      {secretResult && (
        <SecretDialog result={secretResult} onClose={() => setSecretResult(null)} />
      )}

      {removing && (
        <ConfirmDialog
          title="删除组织同步配置"
          description={`删除后不会再为「${removing.name}」创建新的 webhook 投递。历史投递记录仍保留用于排障。`}
          confirmLabel="删除"
          busyLabel="删除中..."
          onClose={() => setRemoving(null)}
          onConfirm={async () => {
            await OrgWebhooks.remove(removing.uuid)
            setRemoving(null)
            refresh()
          }}
        />
      )}

      {testResult && (
        <DialogShell
          title={testResult.title}
          icon={testResult.ok ? <CheckCircle2 size={18} className="text-[var(--color-success)]" /> : <Send size={18} className="text-[var(--color-danger)]" />}
          onClose={() => setTestResult(null)}
          size="sm"
          footer={<div className="flex justify-end"><Button variant="primary" onClick={() => setTestResult(null)}>知道了</Button></div>}
        >
          <InlineAlert tone={testResult.ok ? 'info' : 'danger'}>{testResult.message}</InlineAlert>
        </DialogShell>
      )}
    </div>
  )
}

function OrgWebhookDrawer({
  initial,
  onClose,
  onSaved,
}: {
  initial?: OrgWebhook
  onClose: () => void
  onSaved: (result?: OrgWebhookSecretResult) => void
}) {
  const [name, setName] = useState(initial?.name || '')
  const [callbackUrl, setCallbackUrl] = useState(initial?.callbackUrl || '')
  const [description, setDescription] = useState(initial?.description || '')
  const [enabled, setEnabled] = useState(initial?.enabled ?? true)
  const [mode, setMode] = useState<'all' | 'custom'>(initial && initial.eventTypes.length > 0 ? 'custom' : 'all')
  const [eventTypes, setEventTypes] = useState<string[]>(initial?.eventTypes || [])
  const [err, setErr] = useState('')
  const [saving, setSaving] = useState(false)
  const isEdit = Boolean(initial)

  const grouped = useMemo(() => {
    const map = new Map<string, typeof ORG_EVENTS>()
    ORG_EVENTS.forEach((ev) => {
      map.set(ev.group, [...(map.get(ev.group) || []), ev])
    })
    return Array.from(map.entries())
  }, [])

  const submit = async () => {
    setErr('')
    if (!name.trim()) {
      setErr('名称必填')
      return
    }
    if (!callbackUrl.trim()) {
      setErr('回调地址必填')
      return
    }
    const selectedEvents = mode === 'all' ? [] : eventTypes
    if (mode === 'custom' && selectedEvents.length === 0) {
      setErr('自定义事件范围至少选择一个事件')
      return
    }
    setSaving(true)
    try {
      if (initial) {
        await OrgWebhooks.patch(initial.uuid, {
          name: name.trim(),
          callbackUrl: callbackUrl.trim(),
          description: description.trim(),
          enabled,
          eventTypes: selectedEvents,
        })
        onSaved()
      } else {
        const result = await OrgWebhooks.create({
          name: name.trim(),
          callbackUrl: callbackUrl.trim(),
          description: description.trim(),
          enabled,
          eventTypes: selectedEvents,
        })
        onSaved(result)
      }
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <DrawerShell
      title={isEdit ? '编辑组织同步' : '新建组织同步'}
      subtitle="用于把成员、部门、职位变化通知给外部系统。"
      icon={<Workflow size={18} />}
      width="md"
      onClose={onClose}
      footer={(
        <div className="flex items-center justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={saving}>取消</Button>
          <Button onClick={submit} disabled={saving}>{saving ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <FormSection title="基础配置">
          <div className="grid gap-4">
            <FormField label="名称">
              <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="例：北森 HR 同步" />
            </FormField>
            <FormField label="回调地址" hint="必须是外部系统可访问的 HTTPS 地址。">
              <Input value={callbackUrl} onChange={(e) => setCallbackUrl(e.target.value)} placeholder="https://example.com/easyo/org-webhook" />
            </FormField>
            <FormField label="说明">
              <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="可填写对接系统、负责人或用途" />
            </FormField>
            <div className="flex items-center justify-between rounded-md border border-[var(--color-line)] px-3 py-2.5">
              <div>
                <div className="text-[13px] font-medium text-[var(--color-text)]">启用同步</div>
                <div className="mt-0.5 text-[12px] text-[var(--color-text-sub)]">停用后不会为新的组织变更创建投递。</div>
              </div>
              <Switch checked={enabled} onChange={setEnabled} ariaLabel="启用同步" />
            </div>
          </div>
        </FormSection>

        <FormSection title="事件范围" description="空范围表示接收全部成员、部门、职位事件。">
          <div className="space-y-3">
            <div className="flex gap-2">
              <Button type="button" variant={mode === 'all' ? 'primary' : 'secondary'} onClick={() => setMode('all')}>全部事件</Button>
              <Button type="button" variant={mode === 'custom' ? 'primary' : 'secondary'} onClick={() => setMode('custom')}>自定义事件</Button>
            </div>
            {mode === 'custom' && grouped.map(([group, events]) => (
              <div key={group} className="rounded-md border border-[var(--color-line)] p-3">
                <div className="mb-2 text-[13px] font-medium text-[var(--color-text)]">{group}</div>
                <div className="grid gap-2 sm:grid-cols-3">
                  {events.map((ev) => (
                    <label key={ev.value} className="flex items-center gap-2 text-[13px] text-[var(--color-text-sub)]">
                      <input
                        type="checkbox"
                        checked={eventTypes.includes(ev.value)}
                        onChange={(e) => setEventTypes(e.target.checked ? [...eventTypes, ev.value] : eventTypes.filter((x) => x !== ev.value))}
                      />
                      {ev.label}
                    </label>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </FormSection>

        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DrawerShell>
  )
}

function SecretDialog({ result, onClose }: { result: OrgWebhookSecretResult; onClose: () => void }) {
  const [copied, setCopied] = useState(false)
  return (
    <DialogShell
      title="请保存签名密钥"
      subtitle="密钥只在本次显示，关闭后无法再次查看。外部系统需要用它校验 X-Zhiban-Signature。"
      icon={<Clipboard size={18} />}
      onClose={onClose}
      size="lg"
      footer={(
        <div className="flex justify-end">
          <Button variant="primary" onClick={onClose}>我已保存</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <InlineAlert tone="warn">请立即保存「{result.webhook.name}」的签名密钥。后续只能重置，不能找回原密钥。</InlineAlert>
        <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3">
          <div className="break-all font-mono text-[13px] text-[var(--color-text)]">{result.secret}</div>
        </div>
        <Button
          variant="secondary"
          onClick={() => {
            void navigator.clipboard.writeText(result.secret).then(() => setCopied(true))
          }}
        >
          <Clipboard size={14} />{copied ? '已复制' : '复制密钥'}
        </Button>
      </div>
    </DialogShell>
  )
}

function DeliveryPanel({
  item,
  deliveries,
  loading,
  onClose,
}: {
  item: OrgWebhook
  deliveries: OrgWebhookDelivery[]
  loading: boolean
  onClose: () => void
}) {
  return (
    <DrawerShell
      title="投递记录"
      subtitle={item.name}
      icon={<Workflow size={18} />}
      width="lg"
      onClose={onClose}
      footer={(
        <div className="flex justify-end">
          <Button variant="secondary" onClick={onClose}>关闭</Button>
        </div>
      )}
    >
      <DataTable
        headers={['事件', '状态', '尝试次数', '下次重试', '错误信息', '完成时间', '创建时间']}
        loading={loading ? <div className="px-4 py-8 text-center text-[13px] text-[var(--color-text-sub)]">加载中...</div> : null}
        empty={!loading && deliveries.length === 0 ? <EmptyState title="暂无投递记录" description="有组织变更事件后，这里会显示最近投递状态。" /> : null}
      >
        {!loading && deliveries.map((d) => (
          <tr key={d.id} className="hover:bg-[var(--color-bg-sub)]">
            <td className="whitespace-nowrap px-4 py-3 font-mono text-[12px]">{d.eventType || '-'}</td>
            <td className="whitespace-nowrap px-4 py-3">
              <span className={`inline-flex rounded px-2 py-0.5 text-[12px] ${STATUS_CLASS[d.status] || 'bg-[var(--color-line-soft)] text-[var(--color-text-sub)]'}`}>
                {STATUS_LABEL[d.status] || d.status}
              </span>
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{d.attempts}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{formatTime(d.nextRetryAt)}</td>
            <td className="max-w-[360px] px-4 py-3">
              <div className="truncate text-[13px] text-[var(--color-text-sub)]" title={d.lastError || ''}>{d.lastError || '-'}</div>
            </td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{formatTime(d.doneAt)}</td>
            <td className="whitespace-nowrap px-4 py-3 text-[13px] text-[var(--color-text-sub)]">{formatTime(d.createdAt)}</td>
          </tr>
        ))}
      </DataTable>
    </DrawerShell>
  )
}
