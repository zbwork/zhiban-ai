import { useEffect, useRef, useState } from 'react'
import { ApiError, Auth, Tenants, type BeeBridgeLoginInfo, type Tenant } from '../../lib/api'
import { notifyError, notifyOk } from '../../lib/toast'
import { Button, ConfirmDialog, DialogShell, FormField, InlineAlert, Input } from '../../components/ui'
import { randomUUID } from '../../lib/uuid'
import { SecretValueField } from '../../components/form/SecretValueField'

const PROVISION_LABEL: Record<string, string> = {
  pending: '未初始化', user_ready: '账号已创建', pat_ready: '已就绪', needs_review: '待核对',
}

export function BeeBridgeInfoDialog({ tenant, onClose }: { tenant: Tenant; onClose: () => void }) {
  const [info, setInfo] = useState<BeeBridgeLoginInfo | null>(null)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)

  const [canReset, setCanReset] = useState(false)
  const [canInitialize, setCanInitialize] = useState(false)
  const [initializing, setInitializing] = useState(false)
  const [confirmReset, setConfirmReset] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<{ status: string; message: string } | null>(null)
  const [operation, setOperation] = useState('')
  const inFlight = useRef(false)
  const mounted = useRef(true)
  const pending = !!info?.reset_operation_id && info.reset_stage !== 'verified'
  const needsInitialization = !!info && ['pending', 'user_ready', 'needs_review'].includes(info.provision_status)

  useEffect(() => {
    mounted.current = true
    Auth.permissions().then((codes) => {
      if (mounted.current) {
        setCanReset((codes ?? []).includes('platform.tenant.credentials.reset') && (codes ?? []).includes('platform.tenant.credentials.read'))
        setCanInitialize((codes ?? []).includes('platform.tenant.update'))
      }
    }).catch(() => { if (mounted.current) { setCanReset(false); setCanInitialize(false) } })
    return () => { mounted.current = false }
  }, [])

  const initialize = async () => {
    if (inFlight.current) return
    inFlight.current = true
    setBusy(true)
    setInitializing(true)
    setResult(null)
    setInfo(null)
    try {
      const outcome = await Tenants.initializeBeeBridge(tenant.ID)
      if (mounted.current) setResult(outcome)
    } catch (e) {
      if (mounted.current) {
        if (e instanceof ApiError && (e.status === 401 || e.status === 403)) setCanInitialize(false)
        setResult({ status: 'needs_review', message: (e as Error).message })
      }
    } finally {
      if (mounted.current) {
        setError('')
        setAttempt((n) => n + 1)
        setBusy(false)
        setInitializing(false)
      }
      inFlight.current = false
    }
  }

  const reset = async () => {
    if (inFlight.current) return
    inFlight.current = true
    setBusy(true)
    setResult(null)
    const op = operation || (pending ? info!.reset_operation_id : randomUUID())
    setOperation(op)
    // Hide any earlier password until a fresh audited read completes.
    setInfo(null)
    try {
      const outcome = await Tenants.resetBeeBridgePassword(tenant.ID, op)
      if (mounted.current) {
        setResult(outcome)
        if (outcome.status === 'ready') setOperation('')
      }
    } catch (e) {
      if (mounted.current) {
        if (e instanceof ApiError && (e.status === 401 || e.status === 403)) {
          setOperation('')
          setCanReset(false)
        }
        setResult({ status: 'needs_review', message: (e as Error).message })
      }
    } finally {
      if (mounted.current) {
        setConfirmReset(false)
        setError('')
        setAttempt((n) => n + 1)
        setBusy(false)
      }
      inFlight.current = false
    }
  }
  const close = () => { if (!inFlight.current && !confirmReset) onClose() }

  useEffect(() => {
    let cancelled = false
    Tenants.beeBridgeInfo(tenant.ID)
      .then((result) => {
        if (!cancelled) {
          setInfo(result)
          if (result.reset_operation_id && result.reset_stage !== 'verified') setOperation(result.reset_operation_id)
        }
      })
      .catch((e: Error) => {
        if (!cancelled) { setError(e.message); notifyError(e.message) }
      })
    return () => { cancelled = true }
  }, [tenant.ID, attempt])

  const copy = async (value: string, label: string) => {
    try { await navigator.clipboard.writeText(value); notifyOk(`${label}已复制`) }
    catch { notifyError('复制失败，请手动选择并复制') }
  }

  return (
    <>
    <DialogShell
      title="蜂桥信息"
      subtitle={`${tenant.Name} · 租户 ID ${tenant.ID}`}
      onClose={close}
      footer={<div className="flex justify-end"><Button variant="secondary" disabled={busy} onClick={close}>关闭</Button></div>}
    >
      {result && <div className="mb-4"><InlineAlert tone={result.status === 'ready' ? 'success' : 'warn'}>{result.message}</InlineAlert></div>}
      {error ? (
        <div className="space-y-3">
          <InlineAlert tone="danger">{error}</InlineAlert>
          <Button variant="secondary" onClick={() => { setError(''); setAttempt((n) => n + 1) }}>重试</Button>
        </div>
      ) : !info ? <p role="status" className="text-[13px] text-[var(--color-text-sub)]">{initializing ? '正在初始化蜂桥，请稍候…' : busy ? '正在重置并核验，请稍候…' : '正在加载蜂桥信息…'}</p> : (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <FormField label="蜂桥用户 ID"><Input readOnly value={info.user_id || '未绑定'} /></FormField>
            <FormField label="初始化状态"><Input readOnly value={PROVISION_LABEL[info.provision_status] || '待核对'} /></FormField>
          </div>
          {needsInitialization && <div className="space-y-3">
            <InlineAlert tone="info">客户端登录或使用模型时会自动初始化。此处可提前初始化租户账号，或重新检查未完成的初始化。</InlineAlert>
            {canInitialize && ['active', 'trial'].includes(tenant.Status) && <Button variant="secondary" disabled={busy} onClick={() => void initialize()}>{info.provision_status === 'pending' ? '初始化蜂桥' : '重新检查初始化'}</Button>}
          </div>}
          <FormField label="蜂桥账号">
            <div className="flex items-center gap-2">
              <Input readOnly value={info.username} placeholder="账号未记录" className="font-mono" />
              <Button variant="secondary" disabled={!info.username} onClick={() => void copy(info.username, '账号')}>复制账号</Button>
            </div>
          </FormField>
          <SecretValueField key={attempt} label="登录密码" valueRef={info.password ? `value://${info.password}` : ''} readOnly placeholder="密码未保存" />
          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" disabled={!info.password_saved || !info.password} onClick={() => void copy(info.password, '密码')}>复制密码</Button>
            {canReset && info.user_id > 0 && info.provision_status === 'pat_ready' && <Button variant="secondary" disabled={busy} onClick={() => setConfirmReset(true)}>{pending || operation ? '继续核验' : '重置并保存密码'}</Button>}
          </div>
          {!info.password_saved && info.provision_status === 'pat_ready' && <InlineAlert tone="info">{pending ? '密码操作尚未完成，请继续核验。' : canReset ? '历史密码未保存，可重置并保存一个新密码。' : '历史密码未保存，请联系有重置权限的平台管理员。'}</InlineAlert>}
          {!info.username && info.user_id > 0 && <InlineAlert tone="info">账号未记录，请按蜂桥用户 ID 在蜂桥侧核对。</InlineAlert>}
        </div>
      )}
    </DialogShell>
    {confirmReset && <ConfirmDialog
      title={pending || operation ? '继续密码操作' : '重置蜂桥密码'}
      description={<>{tenant.Name}（租户 ID {tenant.ID}）。{pending || operation ? '将继续同一次密码操作并核验结果。已发送的改密请求不会重复发送。' : '将生成并加密保存新密码，旧密码会失效，已有登录可能退出。请避免同时在蜂桥后台修改此用户资料。'}</>}
      confirmLabel={pending || operation ? '继续核验' : '确认重置'}
      busyLabel="正在处理…"
      tone="warn"
      onClose={() => { if (!inFlight.current) setConfirmReset(false) }}
      onConfirm={reset}
    />}
    </>
  )
}
