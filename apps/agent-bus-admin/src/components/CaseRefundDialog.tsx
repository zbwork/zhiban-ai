// F24 取消退款（2026-07-24）：工单服务费退款弹窗（微信原路退）。
// 金额缺省=剩余全额；代账终止结算可改为部分退款。注册/代账两页共用。
import { useState } from 'react'

import { StartupAgentCases } from '../lib/api'
import { notifyOk } from '../lib/toast'
import { Button, DialogShell, FormField, InlineAlert, Input } from './ui'

export function CaseRefundDialog({ caseId, tenantUuid, maxYuan, onClose, onDone }: {
  caseId: string
  tenantUuid: string
  /** 已收款金额（元），仅作提示与上限校验；0=未知不校验 */
  maxYuan: number
  onClose: () => void
  onDone: () => void
}) {
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const value = Number(amount)
  const invalid = amount !== '' && (Number.isNaN(value) || value <= 0 || (maxYuan > 0 && value > maxYuan))

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      await StartupAgentCases.refund(caseId, {
        tenant_uuid: tenantUuid,
        ...(amount !== '' ? { amount_cents: Math.round(value * 100) } : {}),
        ...(reason.trim() ? { reason: reason.trim() } : {}),
      })
      notifyOk('退款已发起，原路退回一般 1-3 个工作日到账；结果以时间线「退款已原路退回」为准')
      onDone()
    } catch (e) {
      setErr(e instanceof Error ? e.message : '退款发起失败')
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title="发起退款"
      subtitle="经微信原路退回；到账后系统自动通知用户并更新工单。"
      onClose={onClose}
      size="sm"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>取消</Button>
          <Button variant="danger" disabled={busy || invalid} onClick={() => void submit()}>
            {busy ? '提交中…' : '确认退款'}
          </Button>
        </div>
      }
    >
      <div className="space-y-3">
        {err && <InlineAlert>{err}</InlineAlert>}
        <FormField label="退款金额（元）"
                   hint={maxYuan > 0 ? `留空 = 全额退（已收 ¥${maxYuan}）；部分退款用于终止结算` : '留空 = 剩余全额退'}>
          <Input value={amount} onChange={(e) => setAmount(e.target.value)}
                 placeholder={maxYuan > 0 ? `如 ${maxYuan}` : '如 300'} inputMode="decimal" />
        </FormField>
        <FormField label="退款原因（选填）">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="如：用户取消 / 终止结算" />
        </FormField>
      </div>
    </DialogShell>
  )
}
