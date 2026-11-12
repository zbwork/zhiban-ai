import { useEffect, useRef, useState } from 'react'
import { ApiError, Tenants, type BillingPlan, type CreditPurchaseInput, type CreditPurchaseOptions, type CreditPurchaseResult, type Tenant } from '../../lib/api'
import { randomUUID } from '../../lib/uuid'
import { notifyError, notifyOk } from '../../lib/toast'
import { Button, DialogShell, FormField, InlineAlert, Input, Select, Tabs } from '../../components/ui'

function restorePurchase(key: string): CreditPurchaseInput | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(key) || 'null') as CreditPurchaseInput | null
    return value && typeof value.request_id === 'string' && Number.isSafeInteger(value.amount_cents) && Number.isSafeInteger(value.pricing_id) && typeof value.remark === 'string' ? value : null
  } catch { return null }
}

function amountInCents(value: string): number | null {
  if (!/^\d+(\.\d{1,2})?$/.test(value.trim())) return null
  const [yuan, fraction = ''] = value.trim().split('.')
  const cents = Number(yuan) * 100 + Number(fraction.padEnd(2, '0'))
  return Number.isSafeInteger(cents) ? cents : null
}

export function TenantBenefitsDialog({ tenant, plans, operatorId, onClose, onChanged }: {
  tenant: Tenant
  plans: BillingPlan[]
  operatorId: number
  onClose: () => void
  onChanged: () => void
}) {
  const storageKey = `agbus.credit-purchase.${operatorId}.${tenant.ID}`
  const [pending, setPending] = useState(() => restorePurchase(storageKey))
  const [tab, setTab] = useState<'plan' | 'credits'>(() => restorePurchase(storageKey) ? 'credits' : 'plan')
  const [planId, setPlanId] = useState<number | ''>(tenant.EffectivePlanID || '')
  const [amount, setAmount] = useState(() => pending ? (pending.amount_cents / 100).toFixed(2) : '')
  const [remark, setRemark] = useState(() => pending?.remark || '')
  const [options, setOptions] = useState<CreditPurchaseOptions | null>(null)
  const [loadError, setLoadError] = useState('')
  const [reload, setReload] = useState(0)
  const [busy, setBusy] = useState(false)
  const submitting = useRef(false)
  const [result, setResult] = useState<CreditPurchaseResult | null>(null)
  const [uncertain, setUncertain] = useState(Boolean(pending))

  useEffect(() => {
    let cancelled = false
    Tenants.creditPurchaseOptions(tenant.ID)
      .then((value) => { if (!cancelled) { setOptions(value); setLoadError('') } })
      .catch((error: Error) => { if (!cancelled) setLoadError(error.message) })
    return () => { cancelled = true }
  }, [tenant.ID, reload])

  const cents = amountInCents(amount)
  const validAmount = options && cents !== null && cents >= options.min_amount_cents && cents <= options.max_amount_cents
  const previewCredits = validAmount ? Math.floor(cents * options.credits_per_cny / 100) : null
  const complete = Boolean(result?.fulfilled && result.beebridge_status === 'credited')
  const review = result && ['needs_review', 'create_unknown', 'redeem_unknown', 'cancelled'].includes(result.beebridge_status)
  const locked = busy || Boolean(pending) || Boolean(result)

  const acceptResult = (value: CreditPurchaseResult) => {
    setResult(value)
    setUncertain(false)
    onChanged()
    setReload((x) => x + 1)
    if (value.fulfilled && value.beebridge_status === 'credited') sessionStorage.removeItem(storageKey)
  }

  const submit = async () => {
    if (submitting.current) return
    submitting.current = true
    setBusy(true)
    try {
      if (tab === 'plan') {
        if (planId === '' || planId === tenant.EffectivePlanID) return
        await Tenants.assignPlan(tenant.ID, planId)
        notifyOk('租户套餐已更新')
        onChanged()
        onClose()
        return
      }
      if (complete) { onClose(); return }
      if (result && pending) {
        acceptResult(await Tenants.creditPurchase(tenant.ID, pending.request_id))
        return
      }
      if (!pending && (!validAmount || previewCredits === null || previewCredits < 1)) {
        notifyError('请输入有效金额，最多保留两位小数，且至少兑换 1 积分')
        return
      }
      const body = pending || { request_id: randomUUID(), amount_cents: cents!, pricing_id: options!.pricing_id, remark: remark.trim() }
      // Persist before sending: closing/reloading the page must not turn a lost response into a second purchase.
      sessionStorage.setItem(storageKey, JSON.stringify(body))
      setPending(body)
      acceptResult(await Tenants.purchaseCredits(tenant.ID, body))
    } catch (error) {
      if (tab === 'credits') {
        if (error instanceof ApiError && (error.status === 400 || (error.status === 409 && error.message.includes('比例已更新')))) {
          sessionStorage.removeItem(storageKey)
          setPending(null)
          setUncertain(false)
          setReload((x) => x + 1)
        } else {
          setUncertain(true)
        }
      }
      // API errors already use the global toast. Keep the same request for uncertain outcomes.
    } finally {
      submitting.current = false
      setBusy(false)
    }
  }

  return (
    <DialogShell title="权益套餐" subtitle={`${tenant.Name} · 租户 ID ${tenant.ID}`} size="md"
      onClose={() => { if (!submitting.current) onClose() }}
      footer={<div className="flex justify-end gap-2 border-t border-[var(--color-line)] pt-3">
        <Button variant="secondary" disabled={busy} onClick={onClose}>{result ? '关闭' : '取消'}</Button>
        <Button onClick={submit} disabled={busy || (tab === 'plan' ? planId === '' || planId === tenant.EffectivePlanID : !pending && (!validAmount || !previewCredits))}>
          {busy ? (tab === 'plan' ? '调整中…' : '处理中…') : tab === 'plan' ? '确认调整' : complete ? '完成' : result ? '刷新到账状态' : pending ? '重试原增购' : '确定增购积分'}
        </Button>
      </div>}
    >
      <div className="space-y-5">
        <dl className="flex flex-wrap gap-x-8 gap-y-2 text-[13px]">
          <div className="flex gap-3"><dt className="text-[var(--color-text-sub)]">当前套餐</dt><dd>{tenant.EffectivePlanName || '暂无有效订阅'}</dd></div>
          <div className="flex gap-3"><dt className="text-[var(--color-text-sub)]">可用积分</dt><dd className="tabular-nums">{options ? options.available_credits.toLocaleString('zh-CN') : '—'}</dd></div>
        </dl>
        <Tabs value={tab} onChange={(value) => { if (!submitting.current) setTab(value) }} items={[{ value: 'plan', label: '调整套餐' }, { value: 'credits', label: '增购积分' }]} />
        <div className="min-h-[392px] space-y-4">
          {tab === 'plan' ? <>
            <FormField label="目标套餐">
              <Select value={planId} disabled={busy} onChange={(e) => setPlanId(e.target.value ? Number(e.target.value) : '')}>
                <option value="">请选择套餐</option>
                {plans.map((plan) => <option key={plan.id} value={plan.id}>{plan.name}</option>)}
              </Select>
            </FormField>
            <p className="text-[12px] text-[var(--color-text-mute)]">套餐权益立即生效</p>
            <InlineAlert tone="info">调整后权益立即生效，不产生支付订单。<br />套餐额度作为权益参考，调整套餐不会单独增加可用积分。<br />需要增加可用积分时，请使用「增购积分」，以蜂桥实际到账为准。</InlineAlert>
          </> : <>
            {loadError && <InlineAlert tone="danger">{loadError}<Button variant="ghost" size="sm" onClick={() => setReload((x) => x + 1)}>重新加载</Button></InlineAlert>}
            <FormField label="增购金额（元）">
              <div className="relative"><span className="pointer-events-none absolute left-3 top-2 text-[var(--color-text-sub)]">¥</span>
                <Input aria-label="增购金额（元）" required inputMode="decimal" placeholder="请输入金额" className="pl-8 tabular-nums" value={amount} disabled={locked} onChange={(e) => setAmount(e.target.value)} />
              </div>
            </FormField>
            <p className="!mt-1 text-[12px] text-[var(--color-text-mute)]">输入人民币金额，自动计算到账积分；最多两位小数</p>
            <dl className="space-y-3 rounded-md border border-[var(--color-line)] bg-[var(--color-bg-sub)] p-4 text-[13px]">
              <div className="flex items-center justify-between gap-4"><dt className="text-[var(--color-text-sub)]">预计到账积分</dt><dd className="tabular-nums text-[var(--color-brand)]"><span className="text-xl font-medium">{result ? `+${result.credits.toLocaleString('zh-CN')}` : pending ? '待核对' : previewCredits === null ? '—' : `+${previewCredits.toLocaleString('zh-CN')}`}</span> 积分</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-[var(--color-text-sub)]">蜂桥同步充值</dt><dd className="tabular-nums">{cents !== null && cents > 0 ? `¥${(cents / 100).toFixed(2)} 等值额度` : '—'}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-[var(--color-text-sub)]">积分有效期</dt><dd>永久有效</dd></div>
            </dl>
            <FormField label="操作备注（选填）"><Input aria-label="操作备注" value={remark} disabled={locked} maxLength={200} onChange={(e) => setRemark(e.target.value)} placeholder="例如：客户积分补充" /></FormField>
            {result ? <InlineAlert tone={complete ? 'success' : 'info'}>
              {complete ? '蜂桥额度已到账，知办余额按模型账户同步。' : review ? '蜂桥到账待核对，请勿重复增购。' : '增购已记录，蜂桥充值处理中，尚未确认到账。'}
              <div className="mt-1 break-all text-[12px]">订单号：{result.out_trade_no}</div>
            </InlineAlert> : uncertain ? <InlineAlert tone="warn">已保留本次增购请求，结果尚未确认。可重试原增购，系统会核对同一订单，不重复入账。</InlineAlert> :
              <InlineAlert tone="info">后台增购无需在线支付。系统将充值蜂桥账户，确认到账后计入可用积分，并展示在客户端「购买记录 → 增购积分」。</InlineAlert>}
          </>}
        </div>
      </div>
    </DialogShell>
  )
}
