import { useCallback, useEffect, useState } from 'react'
import { Billing, type BeeBridgePricingResponse } from '../../lib/api'
import { Button, DataTable, EmptyState, FormField, InlineAlert, Input, Pagination } from '../../components/ui'

function localMinute(value: Date) {
  const local = new Date(value.getTime() - value.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

export default function BeeBridgePricing() {
  const [data, setData] = useState<BeeBridgePricingResponse | null>(null)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [rate, setRate] = useState('7.2')
  const [credits, setCredits] = useState('1000')
  const [quota, setQuota] = useState('500000')
  const [effective, setEffective] = useState(() => localMinute(new Date(Date.now() + 60_000)))
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const load = useCallback(async () => {
    setLoading(true)
    try { setData(await Billing.listBeeBridgePricing(pageSize, (page - 1) * pageSize)); setError('') }
    catch (e) { setError((e as Error).message) }
    finally { setLoading(false) }
  }, [page, pageSize])
  useEffect(() => { const timer = setTimeout(() => void load(), 0); return () => clearTimeout(timer) }, [load])

  async function publish() {
    const amount = Number(credits)
    const quotaPerUSD = Number(quota)
    if (!/^(0|[1-9]\d*)(\.\d{1,6})?$/.test(rate) || Number(rate) <= 0 || Number(rate) > 1000 || !Number.isSafeInteger(amount) || amount <= 0 || amount > 1_000_000 || !Number.isSafeInteger(quotaPerUSD) || quotaPerUSD <= 0 || quotaPerUSD > 1_000_000_000 || !effective) {
      setError('请输入有效汇率、每元积分和生效时间。汇率最多 6 位小数，每元积分为 1–1000000、每美元蜂桥额度为 1–1000000000 的整数。'); return
    }
    setSaving(true); setError(''); setNotice('')
    try {
      await Billing.publishBeeBridgePricing({ usd_cny_rate: rate, credits_per_cny: amount, quota_per_usd: quotaPerUSD, effective_from: new Date(effective).toISOString() })
      setNotice('新计价版本已发布。已入账消费和已创建充值订单保持原计价。')
      if (page !== 1) setPage(1); else await load()
    } catch (e) { setError((e as Error).message) }
    finally { setSaving(false) }
  }

  return <div className="space-y-4">
    {error && <InlineAlert>{error}</InlineAlert>}
    {notice && <p role="status" className="text-sm text-[var(--color-text-sub)]">{notice}</p>}
    {data?.total === 0 && <InlineAlert tone="warn">尚未配置计价。收到的费用会保留为待处理，请先发布覆盖消费时间的首版规则。</InlineAlert>}
    {(data?.inbox.pending ?? 0) > 0 && <InlineAlert tone="warn">
      有 {data?.inbox.pending} 份费用通知待处理。{data?.inbox.last_error || '后台正在处理。'}
      {data?.inbox.oldest_pending_at && ` 最早收到：${new Date(data.inbox.oldest_pending_at).toLocaleString('zh-CN')}`}。配置或余额恢复后自动重试。
    </InlineAlert>}
    <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
      <FormField label="美元兑人民币汇率" hint="1 美元对应的人民币元数，默认 7.2，可修改；发布后生效，非实时汇率。">
        <Input value={rate} inputMode="decimal" onChange={e => setRate(e.target.value.trim())} placeholder="填写结算汇率" />
      </FormField>
      <FormField label="每元人民币对应积分" hint="内部积分口径默认 1000。">
        <Input value={credits} inputMode="numeric" onChange={e => setCredits(e.target.value)} />
      </FormField>
      <FormField label="每美元蜂桥额度（quota）" hint="默认 500000，表示 1 美元对应的蜂桥兑换码额度；与知办积分不同，需与蜂桥金额单位一致。">
        <Input value={quota} inputMode="numeric" onChange={e => setQuota(e.target.value)} />
      </FormField>
      <FormField label="生效时间" hint="按当前时区填写；影响生效后的新充值订单和消费分钟。">
        <Input type="datetime-local" value={effective} onChange={e => setEffective(e.target.value)} />
      </FormField>
    </div>
    <p className="text-[13px] text-[var(--color-text-sub)]">消费积分 = 蜂桥净消费美元金额 × 汇率 × 每元积分；充值额度 = 人民币金额 ÷ 汇率 × 每美元蜂桥额度（向下取整）。套餐充值和增购使用同一生效版本，历史订单不重算。</p>
    <div className="flex items-center justify-between gap-3">
      <span className="text-sm text-[var(--color-text-sub)]">共 {data?.total ?? 0} 个计价版本</span>
      <div className="flex gap-2">
        <Button variant="secondary" onClick={() => void load()} disabled={loading}>刷新</Button>
        <Button onClick={() => void publish()} disabled={saving || loading || !data}>{saving ? '发布中…' : '发布计价版本'}</Button>
      </div>
    </div>
    <DataTable headers={['版本', '汇率（人民币 / 美元）', '积分 / 人民币元', '蜂桥额度 / 美元', '生效时间', '发布时间']}
      loading={loading ? <div className="p-4 text-sm">加载中…</div> : null}
      empty={!loading && data !== null && !data.items.length ? <EmptyState title="暂无计价版本" description="填写汇率并发布首版计价。" /> : null}>
      {data?.items.map(p => <tr key={p.id}>
        {[p.id, p.usd_cny_rate, p.credits_per_cny, p.quota_per_usd.toLocaleString('zh-CN'), new Date(p.effective_from).toLocaleString('zh-CN'), new Date(p.created_at).toLocaleString('zh-CN')].map((value, i) =>
          <td key={i} className="px-4 py-3 text-sm text-[var(--color-text)]">{value}</td>)}
      </tr>)}
    </DataTable>
    <Pagination total={data?.total ?? 0} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={size => { setPageSize(size); setPage(1) }} />
  </div>
}
