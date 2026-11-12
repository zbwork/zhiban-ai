import BeeBridgePricing from './billing/BeeBridgePricing'
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Coins, CreditCard, Database, Download, MessageSquareText, Pencil, Phone, Power, RefreshCw, RotateCcw, Save, Wrench } from 'lucide-react'
import { useOutletContext } from 'react-router-dom'

import {
  Billing as BillingAPI,
  type BillingConfigItem,
  type BillingCreditPack,
  type BillingCreditRate,
  type BillingEntitlementOverride,
  type BillingFeature,
  type BillingPaymentOrder,
  type BillingPlan,
  type BillingPlanFeature,
  type BillingPlanPrice,
  type BillingTenantUsageRank,
  type BillingUsageAggregate,
  type BillingUsageAggregateSummary,
  type BillingUsageEvent,
} from '../lib/api'
import type { LayoutOutletContext } from '../components/Layout'
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
  Pagination,
  Panel,
  PrimaryButton,
  SearchInput,
  Select,
  Switch,
  Tabs,
  Toolbar,
  TrendChart,
  stickyLeftTdCls,
  stickyRightTdCls,
  type TrendChartPoint,
  type TrendChartSeriesDef,
} from '../components/ui'

type BillingSection = 'plans' | 'features' | 'credits' | 'orders' | 'config' | 'usage' | 'overrides'
type BillingConfigTab = 'llm' | 'rtc' | 'rules'

const pageMeta: Record<BillingSection, { title: string; subtitle: string }> = {
  plans: { title: '套餐管理', subtitle: '管理套餐目录、价格、月赠积分、试用期和启停状态。' },
  features: { title: '权益项', subtitle: '定义套餐可配置的功能、额度和频率限制维度。' },
  credits: { title: '积分包配置', subtitle: '管理用户可购买的积分加量包。' },
  orders: { title: '订单管理', subtitle: '查看支付订单、履约状态，并对已支付订单发起退款。' },
  config: { title: '计费配置', subtitle: '维护蜂桥模型、通话分钟等资源计价，以及宽限期、订单超时、透支比例等全局账务策略。' },
  usage: { title: '用量统计', subtitle: '按资源类型和统计周期查看积分与消费记录。' },
  overrides: { title: '权益覆写', subtitle: '过渡页：为指定租户维护临时或定制化权益值，后续迁入租户详情。' },
}

const PAGE_SIZE = 10
const BILLING_CODE_RE = /^[a-z][a-z0-9_]{2,63}$/
const BILLING_CODE_HINT = '3-64 位，小写字母开头，仅允许小写字母、数字和下划线。'
const BILLING_CONFIG_TABS: Array<{ value: BillingConfigTab; label: string }> = [
  { value: 'llm', label: '蜂桥模型计价' },
  { value: 'rtc', label: '通话分钟计价' },
  { value: 'rules', label: '账务规则' },
]

type PlanPriceRow = {
  key: string
  code: string
  billingCycle: 'monthly' | 'yearly' | 'none'
  amount: string
  displayMonthlyAmount: string
  originalAmount: string
  promotionText: string
  isActive: boolean
  sortOrder: number
}

function validateBillingCode(value: string) {
  return BILLING_CODE_RE.test(value.trim()) ? '' : `编码需为${BILLING_CODE_HINT}`
}

function BillingSectionPage({ section }: { section: BillingSection }) {
  const meta = pageMeta[section]
  return (
    <div>
      <PageHeader
        title={meta.title}
        subtitle={meta.subtitle}
      />
      {section === 'plans' && <PlansTab />}
      {section === 'features' && <FeaturesTab />}
      {section === 'credits' && <CreditsTab />}
      {section === 'orders' && <OrdersTab />}
      {section === 'config' && <ConfigTab />}
      {section === 'usage' && <><InlineAlert tone="warn">模型费用按蜂桥分钟通知更新，通常延迟 1–2 分钟；待处理通知可在计费配置查看。</InlineAlert><UsageTab /></>}
      {section === 'overrides' && <OverridesTab />}
    </div>
  )
}

export function BillingPlansPage() { return <BillingSectionPage section="plans" /> }
export function BillingFeaturesPage() { return <BillingSectionPage section="features" /> }
export function BillingCreditsPage() { return <BillingSectionPage section="credits" /> }
export function BillingOrdersPage() { return <BillingSectionPage section="orders" /> }
export function BillingConfigPage() { return <BillingSectionPage section="config" /> }
export function BillingUsagePage() { return <BillingSectionPage section="usage" /> }
export function BillingOverridesPage() { return <BillingSectionPage section="overrides" /> }

export function BillingPage() {
  return <BillingPlansPage />
}

function PlansTab() {
  const [q, setQ] = useState('')
  const [active, setActive] = useState('')
  const [page, setPage] = useState(1)
  const [data, setData] = useState<{ items: BillingPlan[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<BillingPlan | 'new' | null>(null)
  const [configuring, setConfiguring] = useState<BillingPlan | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      setData(await BillingAPI.listPlans({ q, is_active: active, limit: PAGE_SIZE, offset: offset(page) }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [active, page, q])

  useEffect(() => scheduleLoad(load), [load])

  const togglePlanStatus = async (plan: BillingPlan, nextActive: boolean) => {
    setErr('')
    try {
      await BillingAPI.updatePlanStatus(plan.id, nextActive)
      setData((prev) => ({
        ...prev,
        items: prev.items.map((item) =>
          item.id === plan.id ? { ...item, is_active: nextActive } : item,
        ),
      }))
    } catch (e) {
      setErr((e as Error).message)
      throw e
    }
  }

  const togglePlanRecommended = async (plan: BillingPlan, nextRecommended: boolean) => {
    setErr('')
    try {
      await BillingAPI.updatePlan(plan.id, { is_recommended: nextRecommended })
      setData((prev) => ({
        ...prev,
        items: prev.items.map((item) => {
          if (item.id === plan.id) return { ...item, is_recommended: nextRecommended }
          return nextRecommended ? { ...item, is_recommended: false } : item
        }),
      }))
    } catch (e) {
      setErr((e as Error).message)
      throw e
    }
  }

  return (
    <section>
      <Toolbar
        search={<SearchInput value={q} onChange={(v) => { setQ(v); setPage(1) }} placeholder="搜索套餐名称或编码" />}
        filters={<StatusFilter value={active} onChange={(v) => { setActive(v); setPage(1) }} />}
        summary={<span>共 {data.total} 个套餐</span>}
        actions={(
          <div className="flex gap-2">
            <PrimaryButton onClick={() => setEditing('new')}>新建套餐</PrimaryButton>
            <RefreshButton onClick={load} loading={loading} />
          </div>
        )}
      />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['名称', '编码', '月付', '年付', '月积分', '试用', '推荐', '状态', '更新时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无套餐" description="创建套餐后会在这里展示给运营人员维护权益。" /> : null}
        stickyLastCol
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td strong>{item.name}</Td>
            <Td mono>{item.code}</Td>
            <Td>{money(planAmountForCycle(item, 'monthly'), item.currency)}</Td>
            <Td>{money(planAmountForCycle(item, 'yearly'), item.currency)}</Td>
            <Td>{item.monthly_credits > 0 ? item.monthly_credits.toLocaleString() : '-'}</Td>
            <Td>{item.trial_days > 0 ? `${item.trial_days} 天` : '-'}</Td>
            <Td>
              <Switch
                checked={item.is_recommended === true}
                ariaLabel={`${item.is_recommended ? '取消推荐' : '设为推荐'}套餐 ${item.name}`}
                onChange={(checked) => togglePlanRecommended(item, checked)}
              />
            </Td>
            <Td>
              <Switch
                checked={item.is_active}
                disabled={item.is_system}
                ariaLabel={`${item.is_active ? '停用' : '启用'}套餐 ${item.name}`}
                onChange={(checked) => togglePlanStatus(item, checked)}
              />
            </Td>
            <Td>{dateTime(item.updated_at)}</Td>
            <td className={`${stickyRightTdCls} whitespace-nowrap px-4 py-2`}>
              <div className="-ml-3 flex items-center gap-1">
                <BillingRowAction label="权益" onClick={() => setConfiguring(item)} />
                <BillingRowAction label="编辑" onClick={() => setEditing(item)} />
              </div>
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={PAGE_SIZE} onPageChange={setPage} onPageSizeChange={() => {}} pageSizeOptions={[PAGE_SIZE]} />
      {editing && (
        <PlanDrawer
          plan={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
          onDone={() => { setEditing(null); void load() }}
        />
      )}
      {configuring && (
        <PlanFeaturesDrawer
          plan={configuring}
          onClose={() => setConfiguring(null)}
          onDone={() => { setConfiguring(null); void load() }}
        />
      )}
    </section>
  )
}

type FeatureLimitMode = 'disabled' | 'limited' | 'unlimited' | 'enabled'
type PlanFeaturePayload = { feature_id: number; limit_value: number | null; limit_unit?: string | null }

function PlanFeaturesDrawer({ plan, onClose, onDone }: { plan: BillingPlan; onClose: () => void; onDone: () => void }) {
  const [features, setFeatures] = useState<BillingFeature[]>([])
  const [existing, setExisting] = useState<BillingPlanFeature[]>([])
  const [hiddenPlanFeatures, setHiddenPlanFeatures] = useState<PlanFeaturePayload[]>([])
  const [modes, setModes] = useState<Record<number, FeatureLimitMode>>({})
  const [values, setValues] = useState<Record<number, string>>({})
  const [units, setUnits] = useState<Record<number, string>>({})
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    try {
      const [featureRes, planFeatureRes] = await Promise.all([
        BillingAPI.listFeatures({ is_active: 'true', limit: 200, offset: 0 }),
        BillingAPI.getPlanFeatures(plan.id),
      ])
      const rows = featureRes.items
        .filter((feature) => feature.code !== 'monthly_credits')
        .sort((a, b) => (a.sort_order - b.sort_order) || a.id - b.id)
      const hiddenRows = featureRes.items.filter((feature) => feature.code === 'monthly_credits')
      const visibleFeatureIds = new Set(rows.map((feature) => feature.id))
      const byFeature = new Map(planFeatureRes.items.map((item) => [item.feature_id, item]))
      const nextHiddenPlanFeatures = hiddenRows.map((feature) => {
        const current = byFeature.get(feature.id)
        return {
          feature_id: feature.id,
          limit_value: plan.monthly_credits,
          limit_unit: current?.limit_unit ?? feature.unit ?? '积分/月',
        }
      })
      const nextModes: Record<number, FeatureLimitMode> = {}
      const nextValues: Record<number, string> = {}
      const nextUnits: Record<number, string> = {}
      rows.forEach((feature) => {
        const current = byFeature.get(feature.id)
        const raw = current?.limit_value
        if (feature.type === 'boolean') {
          nextModes[feature.id] = raw && raw > 0 ? 'enabled' : 'disabled'
          nextValues[feature.id] = raw && raw > 0 ? '1' : '0'
        } else if (raw === null && current) {
          nextModes[feature.id] = 'unlimited'
          nextValues[feature.id] = ''
        } else if (raw && raw > 0) {
          nextModes[feature.id] = 'limited'
          nextValues[feature.id] = String(raw)
        } else {
          nextModes[feature.id] = 'disabled'
          nextValues[feature.id] = '0'
        }
        nextUnits[feature.id] = current?.limit_unit ?? feature.unit ?? ''
      })
      setFeatures(rows)
      setExisting(planFeatureRes.items.filter((item) => visibleFeatureIds.has(item.feature_id)))
      setHiddenPlanFeatures(nextHiddenPlanFeatures)
      setModes(nextModes)
      setValues(nextValues)
      setUnits(nextUnits)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [plan.id, plan.monthly_credits])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      const visiblePayload = features.map((feature) => {
        const mode = modes[feature.id] ?? 'disabled'
        let limitValue: number | null = 0
        if (feature.type === 'boolean') {
          limitValue = mode === 'enabled' ? 1 : 0
        } else if (mode === 'unlimited') {
          limitValue = null
        } else if (mode === 'limited') {
          limitValue = Number(values[feature.id] || '0')
        }
        return {
          feature_id: feature.id,
          limit_value: limitValue,
          limit_unit: (units[feature.id] || feature.unit || '').trim() || null,
        }
      })
      const payload = [...hiddenPlanFeatures, ...visiblePayload]
      await BillingAPI.setPlanFeatures(plan.id, payload)
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const configured = existing.filter((item) => item.limit_value === null || (item.limit_value ?? 0) > 0).length

  return (
    <DrawerShell
      title={`配置权益 - ${plan.name}`}
      subtitle={`维护该套餐关联的权益额度。已启用 ${configured} 项权益。`}
      width="lg"
      onClose={onClose}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy || loading}>{busy ? '保存中...' : '保存权益'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        {err && <InlineAlert>{err}</InlineAlert>}
        {loading ? (
          <TableLoading />
        ) : features.length === 0 ? (
          <EmptyState title="暂无可配置权益项" description="请先在权益项页面创建并启用权益维度。" />
        ) : (
          <DataTable headers={['权益项', '类型', '状态/额度', '单位']} stickyLastCol={false}>
            {features.map((feature) => {
              const mode = modes[feature.id] ?? 'disabled'
              return (
                <tr key={feature.id} className="hover:bg-[var(--color-bg-sub)]">
                  <Td strong>
                    <div>{feature.name}</div>
                  </Td>
                  <Td>{featureTypeText(feature.type)}</Td>
                  <Td>
                    <div className="flex items-center gap-2">
                      <Select
                        value={mode}
                        onChange={(e) => setModes((prev) => ({ ...prev, [feature.id]: e.target.value as FeatureLimitMode }))}
                        className="w-32"
                      >
                        {feature.type === 'boolean' ? (
                          <>
                            <option value="enabled">启用</option>
                            <option value="disabled">关闭</option>
                          </>
                        ) : (
                          <>
                            <option value="disabled">关闭</option>
                            <option value="limited">指定额度</option>
                            <option value="unlimited">不限量</option>
                          </>
                        )}
                      </Select>
                      {feature.type !== 'boolean' && mode === 'limited' && (
                        <Input
                          className="w-28"
                          inputMode="numeric"
                          value={values[feature.id] ?? ''}
                          onChange={(e) => setValues((prev) => ({ ...prev, [feature.id]: e.target.value.replace(/[^\d]/g, '') }))}
                        />
                      )}
                    </div>
                  </Td>
                  <Td>
                    <Input
                      className="w-28"
                      value={units[feature.id] ?? ''}
                      onChange={(e) => setUnits((prev) => ({ ...prev, [feature.id]: e.target.value }))}
                      placeholder={feature.unit || '-'}
                    />
                  </Td>
                </tr>
              )
            })}
          </DataTable>
        )}
      </div>
    </DrawerShell>
  )
}

function featureTypeText(type: string) {
  if (type === 'boolean') return '开关'
  if (type === 'metered') return '计量'
  if (type === 'rate_limit') return '频率限制'
  return type
}

function PlanDrawer({ plan, onClose, onDone }: { plan: BillingPlan | null; onClose: () => void; onDone: () => void }) {
  const isNew = plan === null
  const [name, setName] = useState(plan?.name ?? '')
  const [code, setCode] = useState(plan?.code ?? '')
  const [desc, setDesc] = useState(plan?.description ?? '')
  const [priceRows, setPriceRows] = useState<PlanPriceRow[]>(() => initialPlanPriceRows(plan))
  const [monthlyCredits, setMonthlyCredits] = useState(plan?.monthly_credits?.toString() ?? '0')
  const [trialDays, setTrialDays] = useState(plan?.trial_days?.toString() ?? '0')
  const [sortOrder, setSortOrder] = useState(plan?.sort_order?.toString() ?? '0')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const updatePriceRow = (key: string, patch: Partial<PlanPriceRow>) => {
    setPriceRows((rows) => rows.map((row) => (row.key === key ? { ...row, ...patch } : row)))
  }

  const submit = async () => {
    if (!name.trim() || !code.trim()) { setErr('名称和编码必填'); return }
    if (isNew) {
      const codeErr = validateBillingCode(code)
      if (codeErr) { setErr(codeErr); return }
    }
    setBusy(true)
    setErr('')
    try {
      const planCode = code.trim()
      const activeRows = priceRows.filter((row) => row.isActive)
      if (activeRows.length === 0) {
        setErr('至少启用一个价格点')
        return
      }
      const prices = priceRows.map((row) => planPriceFromRow(planCode, row))
      const monthlyPrice = prices.find((item) => item.billing_cycle === 'monthly' && item.is_active)
      const yearlyPrice = prices.find((item) => item.billing_cycle === 'yearly' && item.is_active)
      const body = {
        name: name.trim(),
        description: desc.trim(),
        billing_cycle: 'monthly',
        price_monthly: monthlyPrice?.amount ?? null,
        price_yearly: yearlyPrice?.amount ?? null,
        prices,
        monthly_credits: Number(monthlyCredits) || 0,
        trial_days: Number(trialDays) || 0,
        sort_order: Number(sortOrder) || 0,
      }
      if (isNew) {
        await BillingAPI.createPlan({
          ...body,
          code: code.trim(),
          currency: 'CNY',
          is_system: false,
        })
      }
      else await BillingAPI.updatePlan(plan!.id, body)
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={isNew ? '新建套餐' : '编辑套餐'}
      onClose={onClose}
      width="lg"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <FormSection title="套餐信息" description="套餐只表达权益层级，价格按下方价格点维护。">
          <div className="grid gap-4 md:grid-cols-2">
            <FormField label="名称"><Input value={name} onChange={(e) => setName(e.target.value)} /></FormField>
            <FormField label="编码" hint={BILLING_CODE_HINT}><Input value={code} onChange={(e) => setCode(e.target.value)} disabled={!isNew} /></FormField>
            <FormField label="描述"><Input value={desc} onChange={(e) => setDesc(e.target.value)} /></FormField>
            <FormField label="月赠积分"><Input value={monthlyCredits} inputMode="numeric" onChange={(e) => setMonthlyCredits(e.target.value.replace(/[^\d]/g, ''))} placeholder="每月订阅赠送积分数" /></FormField>
            <FormField label="试用天数"><Input value={trialDays} inputMode="numeric" onChange={(e) => setTrialDays(e.target.value.replace(/[^\d]/g, ''))} /></FormField>
            <FormField label="排序"><Input value={sortOrder} inputMode="numeric" onChange={(e) => setSortOrder(e.target.value.replace(/[^\d]/g, ''))} /></FormField>
          </div>
        </FormSection>
        <FormSection
          title="价格点"
          description="每一行对应一个可售价格点；按年付的主价格仍填写实际年付金额，折算月费用于客户端卡片展示。"
        >
          <DataTable
            headers={['价格点', '计费周期', '实付金额', '展示月费', '划线原价', '运营文案', '启用']}
            stickyFirstCol
          >
            {priceRows.map((row) => (
              <tr key={row.key} className="group hover:bg-[var(--color-bg-sub)]">
                <Td strong className={`${stickyLeftTdCls} min-w-[150px]`}>{priceCodeForCycle(code, row.billingCycle)}</Td>
                <Td className="min-w-[110px]">{priceCycleText(row.billingCycle)}</Td>
                <Td className="min-w-[120px]">
                  <Input
                    value={row.amount}
                    inputMode="decimal"
                    onChange={(e) => updatePriceRow(row.key, { amount: e.target.value })}
                    placeholder="0.00"
                  />
                </Td>
                <Td className="min-w-[120px]">
                  <Input
                    value={row.displayMonthlyAmount}
                    inputMode="decimal"
                    onChange={(e) => updatePriceRow(row.key, { displayMonthlyAmount: e.target.value })}
                    placeholder={row.billingCycle === 'yearly' ? '自动折算' : '可空'}
                    disabled={row.billingCycle === 'none'}
                  />
                </Td>
                <Td className="min-w-[120px]">
                  <Input
                    value={row.originalAmount}
                    inputMode="decimal"
                    onChange={(e) => updatePriceRow(row.key, { originalAmount: e.target.value })}
                    placeholder="可空"
                    disabled={row.billingCycle === 'none'}
                  />
                </Td>
                <Td className="min-w-[220px]">
                  <Input
                    value={row.promotionText}
                    onChange={(e) => updatePriceRow(row.key, { promotionText: e.target.value })}
                    placeholder={row.billingCycle === 'yearly' ? '例如：首年 ¥948，次年续费 ¥948' : '可空'}
                    disabled={row.billingCycle === 'none'}
                  />
                </Td>
                <Td className="min-w-[80px]">
                  <Switch
                    checked={row.isActive}
                    onChange={(checked) => updatePriceRow(row.key, { isActive: checked })}
                    ariaLabel={`${priceCodeForCycle(code, row.billingCycle)} ${row.isActive ? '停用' : '启用'}`}
                  />
                </Td>
              </tr>
            ))}
          </DataTable>
        </FormSection>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DrawerShell>
  )
}

function FeaturesTab() {
  const [q, setQ] = useState('')
  const [active, setActive] = useState('')
  const [page, setPage] = useState(1)
  const [data, setData] = useState<{ items: BillingFeature[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<BillingFeature | 'new' | null>(null)
  const [toggling, setToggling] = useState<BillingFeature | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      setData(await BillingAPI.listFeatures({ q, is_active: active, limit: PAGE_SIZE, offset: offset(page) }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [active, page, q])

  useEffect(() => scheduleLoad(load), [load])

  const featureTypeLabel = (t: string) => {
    if (t === 'boolean') return '开关'
    if (t === 'metered') return '计量'
    if (t === 'rate_limit') return '频率限制'
    return t
  }

  return (
    <section>
      <Toolbar
        search={<SearchInput value={q} onChange={(v) => { setQ(v); setPage(1) }} placeholder="搜索权益项名称或编码" />}
        filters={<StatusFilter value={active} onChange={(v) => { setActive(v); setPage(1) }} />}
        summary={<span>共 {data.total} 个权益项</span>}
        actions={(
          <div className="flex gap-2">
            <PrimaryButton onClick={() => setEditing('new')}>新建权益项</PrimaryButton>
            <RefreshButton onClick={load} loading={loading} />
          </div>
        )}
      />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['名称', '编码', '类型', '单位', '排序', '状态', '更新时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无权益项" description="创建权益项后可在套餐中关联。" /> : null}
        stickyLastCol
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td strong>{item.name}</Td>
            <Td mono>{item.code}</Td>
            <Td>{featureTypeLabel(item.type)}</Td>
            <Td>{item.unit || '-'}</Td>
            <Td>{item.sort_order}</Td>
            <Td><StatusBadge active={item.is_active} /></Td>
            <Td>{dateTime(item.updated_at)}</Td>
            <td className="sticky right-0 z-[5] whitespace-nowrap bg-white px-4 py-2 shadow-[inset_1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]">
              <Button size="sm" variant="ghost" onClick={() => setEditing(item)}>
                <Pencil size={14} /> 编辑
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setToggling(item)}>
                <Power size={14} /> {item.is_active ? '停用' : '启用'}
              </Button>
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={PAGE_SIZE} onPageChange={setPage} onPageSizeChange={() => {}} pageSizeOptions={[PAGE_SIZE]} />
      {editing && (
        <FeatureDrawer
          feature={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
          onDone={() => { setEditing(null); void load() }}
        />
      )}
      {toggling && (
        <ConfirmDialog
          title={toggling.is_active ? '停用权益项' : '启用权益项'}
          description={`确认${toggling.is_active ? '停用' : '启用'}权益项「${toggling.name}」？`}
          confirmLabel={toggling.is_active ? '停用' : '启用'}
          onClose={() => setToggling(null)}
          onConfirm={async () => {
            await BillingAPI.updateFeature(toggling.id, { is_active: !toggling.is_active })
            setToggling(null)
            void load()
          }}
        />
      )}
    </section>
  )
}

function FeatureDrawer({ feature, onClose, onDone }: { feature: BillingFeature | null; onClose: () => void; onDone: () => void }) {
  const isNew = feature === null
  const [name, setName] = useState(feature?.name ?? '')
  const [code, setCode] = useState(feature?.code ?? '')
  const [desc, setDesc] = useState(feature?.description ?? '')
  const [type, setType] = useState(feature?.type ?? 'boolean')
  const [unit, setUnit] = useState(feature?.unit ?? '')
  const [sortOrder, setSortOrder] = useState(feature?.sort_order?.toString() ?? '0')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    if (!name.trim() || !code.trim()) { setErr('名称和编码必填'); return }
    if (isNew) {
      const codeErr = validateBillingCode(code)
      if (codeErr) { setErr(codeErr); return }
    }
    setBusy(true)
    setErr('')
    try {
      const body = {
        name: name.trim(),
        description: desc.trim(),
        unit: unit.trim() || undefined,
        sort_order: Number(sortOrder) || 0,
      }
      if (isNew) {
        await BillingAPI.createFeature({
          ...body,
          code: code.trim(),
          type,
        })
      }
      else await BillingAPI.updateFeature(feature!.id, body)
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={isNew ? '新建权益项' : '编辑权益项'}
      onClose={onClose}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <FormField label="名称"><Input value={name} onChange={(e) => setName(e.target.value)} /></FormField>
        <FormField label="编码" hint={BILLING_CODE_HINT}><Input value={code} onChange={(e) => setCode(e.target.value)} disabled={!isNew} /></FormField>
        <FormField label="描述"><Input value={desc} onChange={(e) => setDesc(e.target.value)} /></FormField>
        <FormField label="类型">
          <Select value={type} onChange={(e) => setType(e.target.value)} disabled={!isNew}>
            <option value="boolean">开关</option>
            <option value="metered">计量</option>
            <option value="rate_limit">频率限制</option>
          </Select>
        </FormField>
        <FormField label="单位"><Input value={unit} onChange={(e) => setUnit(e.target.value)} placeholder="如 次、个" /></FormField>
        <FormField label="排序"><Input value={sortOrder} inputMode="numeric" onChange={(e) => setSortOrder(e.target.value.replace(/[^\d]/g, ''))} /></FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DrawerShell>
  )
}

function CreditsTab() {
  return (
    <div className="space-y-8">
      <section>
        <div className="mb-3">
          <h2 className="text-[15px] font-semibold text-[var(--color-text)]">积分包</h2>
          <p className="mt-1 text-[13px] text-[var(--color-text-sub)]">配置用户可购买的积分加量包。</p>
        </div>
        <CreditPacksTab />
      </section>
    </div>
  )
}

type CreditRateDraft = {
  resource_name: string
  credits_per_unit: string
  unit_name: string
  is_active: boolean
}

function CreditRatesTable() {
  const [items, setItems] = useState<BillingCreditRate[]>([])
  const [draft, setDraft] = useState<Record<number, CreditRateDraft>>({})
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [savingID, setSavingID] = useState<number | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      const res = await BillingAPI.listCreditRates()
      setItems(res.items)
      setDraft(Object.fromEntries(res.items.map((item) => [item.id, {
        resource_name: item.resource_name,
        credits_per_unit: String(item.credits_per_unit),
        unit_name: item.unit_name,
        is_active: item.is_active,
      }])))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => scheduleLoad(load), [load])

  const updateDraft = (id: number, patch: Partial<CreditRateDraft>) => {
    setDraft((prev) => ({ ...prev, [id]: { ...prev[id], ...patch } }))
  }

  const save = async (item: BillingCreditRate) => {
    const next = draft[item.id]
    if (!next) return
    const creditsPerUnit = Number(next.credits_per_unit)
    if (!next.resource_name.trim()) { setErr('资源名称必填'); return }
    if (!next.unit_name.trim()) { setErr('单位名称必填'); return }
    if (!Number.isFinite(creditsPerUnit) || creditsPerUnit < 0) { setErr('折算比例不能为负'); return }
    setSavingID(item.id)
    setErr('')
    try {
      await BillingAPI.updateCreditRate(item.id, {
        resource_name: next.resource_name.trim(),
        credits_per_unit: creditsPerUnit,
        unit_name: next.unit_name.trim(),
        is_active: next.is_active,
      })
      await load()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSavingID(null)
    }
  }

  return (
    <section>
      <Toolbar summary={<span>共 {items.length} 项折算比例</span>} actions={<RefreshButton onClick={load} loading={loading} />} />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['资源类型', '资源名称', '折算比例', '单位', '状态', '更新时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && items.length === 0 ? <EmptyState title="暂无折算比例" description="初始化计费策略后，会在这里展示资源到积分的换算规则。" /> : null}
        stickyLastCol
      >
        {items.map((item) => {
          const row = draft[item.id] ?? {
            resource_name: item.resource_name,
            credits_per_unit: String(item.credits_per_unit),
            unit_name: item.unit_name,
            is_active: item.is_active,
          }
          return (
            <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
              <Td mono>{item.resource_type}</Td>
              <td className="px-4 py-2">
                <Input value={row.resource_name} onChange={(e) => updateDraft(item.id, { resource_name: e.target.value })} />
              </td>
              <td className="px-4 py-2">
                <Input value={row.credits_per_unit} inputMode="decimal" onChange={(e) => updateDraft(item.id, { credits_per_unit: e.target.value })} />
              </td>
              <td className="px-4 py-2">
                <Input value={row.unit_name} onChange={(e) => updateDraft(item.id, { unit_name: e.target.value })} />
              </td>
              <td className="px-4 py-2">
                <Select value={row.is_active ? 'true' : 'false'} onChange={(e) => updateDraft(item.id, { is_active: e.target.value === 'true' })}>
                  <option value="true">启用</option>
                  <option value="false">停用</option>
                </Select>
              </td>
              <Td>{dateTime(item.updated_at)}</Td>
              <td className="sticky right-0 z-[5] whitespace-nowrap bg-white px-4 py-2 shadow-[inset_1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]">
                <Button size="sm" variant="secondary" onClick={() => void save(item)} disabled={savingID === item.id}>
                  <Save size={14} /> {savingID === item.id ? '保存中' : '保存'}
                </Button>
              </td>
            </tr>
          )
        })}
      </DataTable>
    </section>
  )
}

function CreditPacksTab() {
  const [active, setActive] = useState('')
  const [page, setPage] = useState(1)
  const [data, setData] = useState<{ items: BillingCreditPack[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<BillingCreditPack | 'new' | null>(null)
  const [toggling, setToggling] = useState<BillingCreditPack | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      setData(await BillingAPI.listCreditPacks({ is_active: active, limit: PAGE_SIZE, offset: offset(page) }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [active, page])

  useEffect(() => scheduleLoad(load), [load])

  return (
    <section>
      <Toolbar
        filters={<StatusFilter value={active} onChange={(v) => { setActive(v); setPage(1) }} />}
        summary={<span>共 {data.total} 个积分包</span>}
        actions={(
          <div className="flex gap-2">
            <PrimaryButton onClick={() => setEditing('new')}>新建积分包</PrimaryButton>
            <RefreshButton onClick={load} loading={loading} />
          </div>
        )}
      />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['名称', '积分', '价格', '状态', '排序', '更新时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无积分包" description="配置积分包后，用户可在客户端购买补充积分。" /> : null}
        stickyLastCol
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td strong>{item.name}</Td>
            <Td>{item.credits.toLocaleString()} 积分</Td>
            <Td>{money(item.price, item.currency)}</Td>
            <Td><StatusBadge active={item.is_active} /></Td>
            <Td>{item.sort_order}</Td>
            <Td>{dateTime(item.updated_at)}</Td>
            <td className="sticky right-0 z-[5] whitespace-nowrap bg-white px-4 py-2 shadow-[inset_1px_0_0_var(--color-line-soft)] group-hover:bg-[var(--color-bg-sub)]">
              <div className="flex gap-1">
                <Button size="sm" variant="ghost" onClick={() => setEditing(item)}>
                  <Pencil size={14} /> 编辑
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setToggling(item)}>
                  <Power size={14} /> {item.is_active ? '停用' : '启用'}
                </Button>
              </div>
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={PAGE_SIZE} onPageChange={setPage} onPageSizeChange={() => {}} pageSizeOptions={[PAGE_SIZE]} />
      {editing && (
        <CreditPackDrawer
          pack={editing === 'new' ? null : editing}
          onClose={() => setEditing(null)}
          onDone={() => { setEditing(null); void load() }}
        />
      )}
      {toggling && (
        <ConfirmDialog
          title={toggling.is_active ? '停用积分包' : '启用积分包'}
          description={`确认${toggling.is_active ? '停用' : '启用'}积分包「${toggling.name}」？`}
          confirmLabel={toggling.is_active ? '停用' : '启用'}

          onConfirm={async () => {
            await BillingAPI.updateCreditPackStatus(toggling.id, !toggling.is_active)
            setToggling(null)
            void load()
          }}
          onClose={() => setToggling(null)}
        />
      )}
    </section>
  )
}

function CreditPackDrawer({ pack, onClose, onDone }: { pack: BillingCreditPack | null; onClose: () => void; onDone: () => void }) {
  const isNew = pack === null
  const [name, setName] = useState(pack?.name ?? '')
  const [credits, setCredits] = useState(pack?.credits?.toString() ?? '')
  const [price, setPrice] = useState(pack?.price?.toString() ?? '')
  const [sortOrder, setSortOrder] = useState(pack?.sort_order?.toString() ?? '0')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    if (!name.trim()) { setErr('名称必填'); return }
    if (!credits || Number(credits) <= 0) { setErr('积分数必须大于 0'); return }
    if (!price || Number(price) < 0) { setErr('价格不能为负'); return }
    setBusy(true)
    setErr('')
    try {
      const body = {
        name: name.trim(),
        credits: Number(credits),
        price: Number(price),
        sort_order: Number(sortOrder) || 0,
      }
      if (isNew) await BillingAPI.createCreditPack({ ...body, currency: 'CNY' })
      else await BillingAPI.updateCreditPack(pack!.id, body)
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DrawerShell
      title={isNew ? '新建积分包' : '编辑积分包'}
      onClose={onClose}
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy}>{busy ? '保存中...' : '保存'}</Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <FormField label="名称"><Input value={name} onChange={(e) => setName(e.target.value)} /></FormField>
        <FormField label="积分数"><Input value={credits} inputMode="numeric" onChange={(e) => setCredits(e.target.value.replace(/[^\d]/g, ''))} /></FormField>
        <FormField label="价格（元）"><Input value={price} inputMode="decimal" onChange={(e) => setPrice(e.target.value)} /></FormField>
        <FormField label="排序"><Input value={sortOrder} inputMode="numeric" onChange={(e) => setSortOrder(e.target.value.replace(/[^\d]/g, ''))} /></FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DrawerShell>
  )
}

function OrdersTab() {
  const [tenantID, setTenantID] = useState('')
  const [status, setStatus] = useState('')
  const [orderType, setOrderType] = useState('')
  const [page, setPage] = useState(1)
  const [data, setData] = useState<{ items: BillingPaymentOrder[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [refundOrder, setRefundOrder] = useState<BillingPaymentOrder | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      setData(await BillingAPI.listOrders({
        tenant_id: tenantID,
        status,
        order_type: orderType,
        limit: PAGE_SIZE,
        offset: offset(page),
      }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [orderType, page, status, tenantID])

  useEffect(() => scheduleLoad(load), [load])

  return (
    <section>
      <Toolbar
        search={<SearchInput value={tenantID} onChange={(v) => { setTenantID(v.replace(/[^\d]/g, '')); setPage(1) }} placeholder="输入租户 ID" />}
        filters={(
          <>
            <div className="w-[140px]">
              <Select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1) }}>
                <option value="">全部状态</option>
                <option value="created">已创建</option>
                <option value="paying">支付中</option>
                <option value="paid">已支付</option>
                <option value="closed">已关闭</option>
                <option value="refunding">退款中</option>
                <option value="refunded">已退款</option>
                <option value="needs_review">待审核</option>
              </Select>
            </div>
            <div className="w-[150px]">
              <Select value={orderType} onChange={(e) => { setOrderType(e.target.value); setPage(1) }}>
                <option value="">全部订单</option>
                <option value="subscription">套餐订阅</option>
                <option value="credit_pack">积分包</option>
              </Select>
            </div>
          </>
        )}
        summary={<span>共 {data.total} 笔订单</span>}
        actions={<>
          <Button onClick={() => BillingAPI.exportOrders({ tenant_id: tenantID, status, order_type: orderType })}><Download className="w-3.5 h-3.5 mr-1" />导出</Button>
          <RefreshButton onClick={load} loading={loading} />
        </>}
      />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['订单号', '租户名称', '用户名称', '用户 ID', '类型', '金额', '渠道', '状态', '履约', '创建时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无订单" description="支付订单产生后，会在这里展示状态和退款入口。" /> : null}
        stickyFirstCol
        stickyLastCol
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td mono className={`${stickyLeftTdCls} min-w-[220px]`}>{item.out_trade_no}</Td>
            <Td className="min-w-[150px]">{item.tenant_name || `租户 #${item.tenant_id}`}</Td>
            <Td className="min-w-[140px]">{item.account_name || `用户 #${item.account_id}`}</Td>
            <Td mono className="min-w-[90px]">{item.account_id}</Td>
            <Td>{orderTypeLabel(item.order_type)}</Td>
            <Td>{money(item.amount_cents / 100, item.currency)}</Td>
            <Td>{providerLabel(item.provider)}</Td>
            <Td>{paymentStatusLabel(item.status)}</Td>
            <Td>{item.fulfilled ? '已履约' : '未履约'}</Td>
            <Td>{dateTime(item.created_at)}</Td>
            <td className={`${stickyRightTdCls} whitespace-nowrap px-4 py-2`}>
              <Button
                size="sm"
                variant="ghost"
                disabled={item.status !== 'paid' && item.status !== 'refunding'}
                onClick={() => setRefundOrder(item)}
              >
                <RotateCcw size={14} /> 退款
              </Button>
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={PAGE_SIZE} onPageChange={setPage} onPageSizeChange={() => {}} pageSizeOptions={[PAGE_SIZE]} />
      {refundOrder && (
        <RefundDialog
          order={refundOrder}
          onClose={() => setRefundOrder(null)}
          onDone={() => { setRefundOrder(null); void load() }}
        />
      )}
    </section>
  )
}

function RefundDialog({ order, onClose, onDone }: { order: BillingPaymentOrder; onClose: () => void; onDone: () => void }) {
  const [amount, setAmount] = useState(String(order.amount_cents))
  const [reason, setReason] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      await BillingAPI.refundOrder(order.id, {
        refund_amount_cents: Number(amount),
        reason,
      })
      onDone()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <DialogShell
      title="发起退款"
      subtitle={`订单 ${order.out_trade_no}`}
      icon={<CreditCard size={18} />}
      onClose={onClose}
      size="sm"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy || Number(amount) <= 0 || Number(amount) > order.amount_cents || !reason.trim()}>
            {busy ? '提交中...' : '确认退款'}
          </Button>
        </div>
      )}
    >
      <div className="space-y-4">
        <InlineAlert tone="warn">
          退款会提交到支付渠道；渠道明确成功后订单才会进入已退款状态。
        </InlineAlert>
        <FormField label="退款金额（分）">
          <Input value={amount} inputMode="numeric" onChange={(e) => setAmount(e.target.value.replace(/[^\d]/g, ''))} />
        </FormField>
        <FormField label="退款原因" hint="必填，用于审计记录">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="填写给审计查看的原因" />
        </FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DialogShell>
  )
}

function ConfigTab() {
  const [tab, setTab] = useState<BillingConfigTab>('llm')
  const [items, setItems] = useState<BillingConfigItem[]>([])
  const [draft, setDraft] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      const res = await BillingAPI.listConfig()
      setItems(res.items)
      setDraft(Object.fromEntries(res.items.map((item) => [item.key, item.value])))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => scheduleLoad(load), [load])

  const save = async (key: string) => {
    await BillingAPI.updateConfig(key, draft[key] ?? '')
    await load()
  }

  const visibleItems = items.filter((item) => !item.key.startsWith('llm_credit_per_million_'))

  return (
    <div className="space-y-4">
      <Tabs<BillingConfigTab> value={tab} items={BILLING_CONFIG_TABS} onChange={setTab} className="w-full max-w-[520px]" />

      {tab === 'llm' && (
        <section>
          <div className="mb-3">
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">蜂桥模型计价</h2>
            <p className="mt-1 text-[13px] text-[var(--color-text-sub)]">蜂桥净消费美元金额按生效汇率转换为积分。发布新版本后，历史消费继续使用当时的计价规则。</p>
          </div>
          <BeeBridgePricing />
        </section>
      )}

      {tab === 'rtc' && (
        <section>
          <div className="mb-3">
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">通话分钟计价</h2>
            <p className="mt-1 text-[13px] text-[var(--color-text-sub)]">配置人对人、人对 Agent 通话分钟折算积分的比例，保存后影响后续 RTC 扣费。</p>
          </div>
          <CreditRatesTable />
        </section>
      )}

      {tab === 'rules' && (
        <section>
          <div className="mb-3">
            <h2 className="text-[15px] font-semibold text-[var(--color-text)]">账务规则</h2>
            <p className="mt-1 text-[13px] text-[var(--color-text-sub)]">维护订单、宽限期、透支、催缴提醒和功能开关等全局策略。</p>
          </div>
          <Toolbar summary={<span>共 {visibleItems.length} 项配置</span>} actions={<RefreshButton onClick={load} loading={loading} />} />
          {err && <InlineAlert>{err}</InlineAlert>}
          <DataTable
            headers={['配置项', '说明', '当前值', '更新时间', '操作']}
            loading={loading ? <TableLoading /> : null}
            empty={!loading && visibleItems.length === 0 ? <EmptyState title="暂无配置" description="计费配置初始化后，会在这里展示账务规则和功能开关。" /> : null}
          >
            {visibleItems.map((item) => (
              <tr key={item.key} className="group hover:bg-[var(--color-bg-sub)]">
                <Td strong>{configLabel(item.key)}</Td>
                <Td>{item.description || '-'}</Td>
                <td className="px-4 py-2">
                  <Input value={draft[item.key] ?? ''} onChange={(e) => setDraft((prev) => ({ ...prev, [item.key]: e.target.value }))} />
                </td>
                <Td>{dateTime(item.updated_at)}</Td>
                <td className="px-4 py-2">
                  <Button size="sm" variant="secondary" onClick={() => void save(item.key)}>
                    <Save size={14} /> 保存
                  </Button>
                </td>
              </tr>
            ))}
          </DataTable>
        </section>
      )}
    </div>
  )
}

function UsageTab() {
  const { actScope, switchingScope } = useOutletContext<LayoutOutletContext>()
  const isTenantScope = actScope?.kind === 'tenant' || actScope?.kind === 'workspace'
  const initialTenantID = new URLSearchParams(window.location.search).get('tenant_id') || ''
  const [tenantID, setTenantID] = useState(initialTenantID.replace(/[^\d]/g, ''))
  const [resourceType, setResourceType] = useState('')
  const [period, setPeriod] = useState('monthly')
  const [range, setRange] = useState(() => usageDefaultRange('monthly'))
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(PAGE_SIZE)
  const [data, setData] = useState<{ items: BillingUsageAggregate[]; total: number }>({ items: [], total: 0 })
  const [summary, setSummary] = useState<BillingUsageAggregateSummary | null>(null)
  const [ranking, setRanking] = useState<BillingTenantUsageRank[]>([])
  const [rankErr, setRankErr] = useState('')
  const [drawerRow, setDrawerRow] = useState<BillingUsageAggregate | null>(null)
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    if (!actScope) return
    setLoading(true)
    setErr('')
    try {
      const base = { resource_type: resourceType, period, from: range.from, to: range.to }
      const listParams = { ...base, limit: pageSize, offset: Math.max(0, page - 1) * pageSize }
      // 排行是辅助面板:失败只降级本面板,不拖垮主列表与汇总(catch 吞掉转 null)
      const [list, sum, rank] = await Promise.all([
        isTenantScope
          ? BillingAPI.listTenantUsageAggregates(listParams)
          : BillingAPI.listUsageAggregates({ ...listParams, tenant_id: tenantID }),
        isTenantScope
          ? BillingAPI.getTenantUsageSummary(base)
          : BillingAPI.getUsageSummary({ ...base, tenant_id: tenantID }),
        isTenantScope
          ? Promise.resolve({ items: [] as BillingTenantUsageRank[] })
          : BillingAPI.listTenantUsageRanking({ tenant_id: tenantID, resource_type: resourceType, period, from: range.from, to: range.to, limit: 10 })
            .catch(() => null),
      ])
      setData(list)
      setSummary(sum)
      setRanking(rank?.items ?? [])
      setRankErr(rank ? '' : '租户排行加载失败，点右上角刷新可重试')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [actScope, isTenantScope, page, pageSize, period, range, resourceType, tenantID])

  useEffect(() => scheduleLoad(load), [load])

  const totals = useMemo(() => (summary?.by_resource ?? []).reduce(
    (acc, r) => ({ credits: acc.credits + finiteNumber(r.total_credits), events: acc.events + finiteNumber(r.event_count) }),
    { credits: 0, events: 0 },
  ), [summary])

  const trendPoints = useMemo<TrendChartPoint[]>(() => {
    const buckets = new Map<string, TrendChartPoint>()
    for (const t of summary?.trend ?? []) {
      let b = buckets.get(t.period_start)
      if (!b) {
        b = { label: usageTrendLabel(t.period_start, period), values: {} }
        buckets.set(t.period_start, b)
      }
      b.values[t.resource_type] = (b.values[t.resource_type] || 0) + finiteNumber(t.total_credits)
    }
    return [...buckets.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([, v]) => v)
  }, [summary, period])
  const trendSeries = USAGE_TREND_SERIES.filter((s) => trendPoints.some((p) => (p.values[s.key] || 0) > 0))

  if (switchingScope || !actScope) return null

  return (
    <section>
      <Toolbar
        search={isTenantScope ? undefined : <SearchInput value={tenantID} onChange={(v) => { setTenantID(v.replace(/[^\d]/g, '')); setPage(1) }} placeholder="输入租户 ID" />}
        filters={(
          <>
            <div className="w-[120px]">
              <Select value={resourceType} onChange={(e) => { setResourceType(e.target.value); setPage(1) }}>
                <option value="">全部类型</option>
                {USAGE_RESOURCE_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </Select>
            </div>
            <div className="w-[110px]">
              <Select value={period} onChange={(e) => { const p = e.target.value; setPeriod(p); setRange(usageDefaultRange(p)); setPage(1) }}>
                <option value="daily">日统计</option>
                <option value="monthly">月统计</option>
              </Select>
            </div>
            <div className="w-[150px]">
              <Input type="date" value={range.from} max={range.to || undefined} onChange={(e) => { const v = e.target.value; setRange((r) => ({ ...r, from: v })); setPage(1) }} aria-label="开始日期" />
            </div>
            <span className="text-[12px] text-[var(--color-text-mute)]">至</span>
            <div className="w-[150px]">
              <Input type="date" value={range.to} min={range.from || undefined} onChange={(e) => { const v = e.target.value; setRange((r) => ({ ...r, to: v })); setPage(1) }} aria-label="结束日期" />
            </div>
          </>
        )}
        summary={<span>共 {data.total} 条聚合</span>}
        actions={(
          <>
            {!isTenantScope && (
              <>
                <Button onClick={() => BillingAPI.exportUsageAggregates({ tenant_id: tenantID, resource_type: resourceType, period, from: range.from, to: range.to })}><Download className="w-3.5 h-3.5 mr-1" />导出</Button>
                <Button onClick={() => BillingAPI.exportLedger({ tenant_id: tenantID, from: range.from, to: range.to })}><Download className="w-3.5 h-3.5 mr-1" />积分流水</Button>
              </>
            )}
            <RefreshButton onClick={load} loading={loading} />
          </>
        )}
      />
      {err && <InlineAlert>{err}</InlineAlert>}

      <div className="mb-4 grid grid-cols-2 gap-3 xl:grid-cols-4">
        <UsageMetricCard
          icon={<Coins size={15} />}
          label="积分消耗合计"
          value={totals.credits.toLocaleString()}
          hint={`筛选范围内 ${totals.events.toLocaleString()} 条消费记录`}
        />
        {(summary?.by_resource ?? []).map((r) => (
          <UsageMetricCard
            key={r.resource_type}
            icon={usageResourceIcon(r.resource_type)}
            label={usageResourceLabel(r.resource_type)}
            value={r.unknown_amount_count ? '用量不完整' : fmtUsageAmount(finiteNumber(r.total_amount), r.resource_type)}
            hint={`${finiteNumber(r.total_credits).toLocaleString()} 积分 · ${finiteNumber(r.event_count).toLocaleString()} 消费记录`}
          />
        ))}
      </div>

      <div className={`mb-4 grid gap-3 ${isTenantScope ? '' : 'xl:grid-cols-2'}`}>
        <Panel className="p-4">
          <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">积分消耗趋势</div>
          <TrendChart points={trendPoints} series={trendSeries.length > 0 ? trendSeries : USAGE_TREND_SERIES} height={150} />
        </Panel>
        {!isTenantScope && (
          <Panel className="p-4">
            <div className="mb-3 text-[13px] font-semibold text-[var(--color-text)]">
              租户用量排行
              <span className="ml-1.5 text-[12px] font-normal text-[var(--color-text-mute)]">按消耗积分 Top 10</span>
            </div>
            {rankErr ? (
              <div className="grid h-[150px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">{rankErr}</div>
            ) : ranking.length === 0 ? (
              <div className="grid h-[150px] place-items-center text-[12.5px] text-[var(--color-text-mute)]">暂无租户消耗</div>
            ) : (
              <table className="w-full text-[12.5px]">
                <thead>
                  <tr className="text-left text-[var(--color-text-mute)]">
                    <th className="pb-1.5 font-medium">租户</th>
                    <th className="pb-1.5 font-medium">套餐</th>
                    <th className="pb-1.5 text-right font-medium">消耗积分</th>
                    <th className="pb-1.5 text-right font-medium">积分余额</th>
                    <th className="pb-1.5 text-right font-medium">操作</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-[var(--color-line-soft)]">
                  {ranking.map((r) => (
                    <tr key={r.tenant_id}>
                      <td className="max-w-[180px] truncate py-1.5 pr-2 text-[var(--color-text)]" title={`租户 ID ${r.tenant_id}`}>{r.tenant_name || `租户 #${r.tenant_id}`}</td>
                      <td className="py-1.5 pr-2 text-[var(--color-text-sub)]">{r.plan_name || '-'}</td>
                      <td className="py-1.5 text-right tabular-nums text-[var(--color-text)]">{r.total_credits.toLocaleString()}</td>
                      <td className="py-1.5 text-right tabular-nums text-[var(--color-text-sub)]">{r.wallet_balance_known === false ? '暂不可用' : r.wallet_balance.toLocaleString()}</td>
                      <td className="py-1.5 text-right">
                        <button
                          type="button"
                          className="text-[var(--color-brand)] hover:underline"
                          onClick={() => { setTenantID(String(r.tenant_id)); setPage(1) }}
                        >
                          查看用量
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </Panel>
        )}
      </div>

      <DataTable
        headers={['租户 ID', '租户名称', '周期', '时间', '资源类型', '技能 ID', '接口', '用量', '积分', '消费记录数', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无用量统计" description="当前筛选条件下还没有可展示的用量聚合。" /> : null}
        stickyLastCol
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td mono>{item.tenant_id}</Td>
            <Td className="min-w-[120px]">{item.tenant_name || `租户 #${item.tenant_id}`}</Td>
            <Td>{usagePeriodLabel(item.period)}</Td>
            <Td>{dateOnly(item.period_start)}</Td>
            <Td>{usageResourceLabel(item.resource_type)}</Td>
            <Td mono>{item.skill_id ?? '-'}</Td>
            <Td mono>{item.operation_code || '-'}</Td>
            <Td className="tabular-nums">{item.unknown_amount_count ? '用量不完整' : fmtUsageAmount(finiteNumber(item.total_amount), item.resource_type)}</Td>
            <Td strong className="tabular-nums">{finiteNumber(item.total_credits).toLocaleString()}</Td>
            <Td className="tabular-nums">{finiteNumber(item.event_count).toLocaleString()}</Td>
            <Td className={stickyRightTdCls}>
              <button
                type="button"
                aria-label="查看逐笔用量明细"
                className="text-[13px] text-[var(--color-brand)] hover:underline"
                onClick={() => setDrawerRow(item)}
              >
                明细
              </button>
            </Td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={(s) => { setPageSize(s); setPage(1) }} />

      {drawerRow && <UsageEventsDrawer row={drawerRow} isTenantScope={isTenantScope} onClose={() => setDrawerRow(null)} />}
    </section>
  )
}

function finiteNumber(value: unknown) {
  const n = Number(value)
  return Number.isFinite(n) ? n : 0
}

function usagePeriodLabel(period: string) {
  switch (period) {
    case 'monthly':
      return '月'
    case 'daily':
      return '日'
    default:
      return period || '-'
  }
}

function usageResourceLabel(resourceType: string) {
  switch (resourceType) {
    case 'llm':
      return 'LLM 对话'
    case 'rtc_minute':
      return 'AI 通话'
    case 'skill':
      return '技能调用'
    case 'data_query':
      return '数据查询'
    default:
      return resourceType || '-'
  }
}

const USAGE_RESOURCE_OPTIONS = [
  { value: 'llm', label: 'LLM 对话' },
  { value: 'rtc_minute', label: 'AI 通话' },
  { value: 'skill', label: '技能调用' },
]

// 趋势图只堆叠积分（唯一跨资源类型可加总的单位）；颜色走资源图标 token。
const USAGE_TREND_SERIES: TrendChartSeriesDef[] = [
  { key: 'llm', label: 'LLM 对话', color: 'var(--color-icon-blue)' },
  { key: 'rtc_minute', label: 'AI 通话', color: 'var(--color-icon-green)' },
  { key: 'skill', label: '技能调用', color: 'var(--color-icon-purple)' },
  { key: 'data_query', label: '数据查询', color: 'var(--color-icon-orange)' },
]

function usageResourceIcon(resourceType: string) {
  switch (resourceType) {
    case 'llm':
      return <MessageSquareText size={15} />
    case 'rtc_minute':
      return <Phone size={15} />
    case 'skill':
      return <Wrench size={15} />
    case 'data_query':
      return <Database size={15} />
    default:
      return <CreditCard size={15} />
  }
}

// 不同资源类型的用量单位不可比：LLM=tokens、通话=分钟、技能/数据查询=次。
function usageAmountUnit(resourceType: string) {
  switch (resourceType) {
    case 'llm':
      return 'tokens'
    case 'rtc_minute':
      return '分钟'
    case 'skill':
    case 'data_query':
      return '次'
    default:
      return ''
  }
}

function fmtUsageAmount(value: number, resourceType: string) {
  const unit = usageAmountUnit(resourceType)
  return unit ? `${value.toLocaleString()} ${unit}` : value.toLocaleString()
}

function fmtDateInput(d: Date) {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

// 缺省时间范围：月统计近 6 个自然月，日统计近 30 天。
function usageDefaultRange(period: string) {
  const now = new Date()
  const to = fmtDateInput(now)
  if (period === 'monthly') {
    return { from: fmtDateInput(new Date(now.getFullYear(), now.getMonth() - 5, 1)), to }
  }
  const from = new Date(now)
  from.setDate(from.getDate() - 29)
  return { from: fmtDateInput(from), to }
}

function usageTrendLabel(periodStart: string, period: string) {
  const d = new Date(periodStart)
  if (Number.isNaN(d.getTime())) return periodStart
  if (period === 'monthly') return `${d.getFullYear()}/${d.getMonth() + 1}`
  return `${d.getMonth() + 1}/${d.getDate()}`
}

function usageSceneLabel(scene?: string) {
  switch (scene) {
    case 'chat':
      return '对话'
    case 'cron':
      return '定时任务'
    case 'rtc':
      return '通话'
    case 'external_api':
      return '外部 API'
    case 'system':
      return '系统'
    default:
      return scene || '-'
  }
}

// 聚合行覆盖的事件时间窗：[period_start, 下一周期起点)。
function usagePeriodWindow(row: BillingUsageAggregate) {
  const start = new Date(row.period_start)
  if (Number.isNaN(start.getTime())) return { from: undefined, to: undefined }
  const end = new Date(start)
  if (row.period === 'monthly') {
    end.setMonth(end.getMonth() + 1)
  } else {
    end.setDate(end.getDate() + 1)
  }
  return { from: fmtDateInput(start), to: fmtDateInput(end) }
}

function fmtEventTime(value?: string | null) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString('zh-CN', { hour12: false })
}

function UsageMetricCard({ icon, label, value, hint }: { icon: ReactNode; label: string; value: string; hint: string }) {
  return (
    <Panel className="p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[12px] text-[var(--color-text-mute)]">{label}</div>
          <div className="mt-2 truncate text-[22px] font-semibold tabular-nums text-[var(--color-text)]" title={value}>{value}</div>
          <div className="mt-1 truncate text-[12px] text-[var(--color-text-sub)]" title={hint}>{hint}</div>
        </div>
        <div className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-[var(--color-brand-soft)] text-[var(--color-brand)]">{icon}</div>
      </div>
    </Panel>
  )
}

// 明细下钻抽屉：展示聚合行覆盖的逐笔用量事件（成员/场景/标题归因）。
function UsageEventsDrawer({ row, isTenantScope, onClose }: { row: BillingUsageAggregate; isTenantScope: boolean; onClose: () => void }) {
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(PAGE_SIZE)
  const [chargedOnly, setChargedOnly] = useState(false)
  const [data, setData] = useState<{ items: BillingUsageEvent[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const win = useMemo(() => usagePeriodWindow(row), [row])

  const baseParams = useMemo(() => ({
    resource_type: row.resource_type,
    skill_id: row.skill_id != null ? String(row.skill_id) : undefined,
    operation_code: row.operation_code || undefined,
    // 聚合行只统计 succeeded,下钻(含导出)同口径,抽屉总数才对得上 event_count
    status: 'succeeded',
    charged_only: chargedOnly || undefined,
    from: win.from,
    to: win.to,
  }), [chargedOnly, row, win])

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      const params = { ...baseParams, limit: pageSize, offset: Math.max(0, page - 1) * pageSize }
      setData(isTenantScope
        ? await BillingAPI.listTenantUsageEvents(params)
        : await BillingAPI.listUsageEvents({ ...params, tenant_id: String(row.tenant_id) }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [baseParams, isTenantScope, page, pageSize, row.tenant_id])

  useEffect(() => scheduleLoad(load), [load])

  return (
    <DrawerShell
      title="用量明细"
      subtitle={`${row.tenant_name || `租户 #${row.tenant_id}`} · ${usageResourceLabel(row.resource_type)} · ${usagePeriodLabel(row.period)}统计 ${dateOnly(row.period_start)}${row.operation_code ? ` · ${row.operation_code}` : ''}`}
      onClose={onClose}
      width="lg"
      footer={(
        <div className="flex w-full items-center justify-between">
          <span className="text-[12px] text-[var(--color-text-mute)]">积分为 0 的事件是免计费留痕（试用/免费套餐或失败不扣费）。</span>
          <div className="flex items-center gap-2">
            {!isTenantScope && (
              <Button onClick={() => BillingAPI.exportUsageEvents({ ...baseParams, tenant_id: String(row.tenant_id) })}>
                <Download className="w-3.5 h-3.5 mr-1" />导出明细
              </Button>
            )}
            <Button variant="secondary" onClick={onClose}>关闭</Button>
          </div>
        </div>
      )}
    >
      <div className="mb-3 flex items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-[13px] text-[var(--color-text-sub)]">
          <Switch checked={chargedOnly} onChange={(v) => { setChargedOnly(v); setPage(1) }} ariaLabel="仅看扣费事件" />
          仅看扣费
        </label>
        <span className="text-[12.5px] text-[var(--color-text-sub)]">共 {data.total} 条明细</span>
      </div>
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['时间', '成员', '场景', '模型 / 标题', '用量', '输入 Token', '输出 Token', '积分', '状态']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无用量事件" description="该聚合行覆盖的时间窗内没有符合条件的逐笔事件。" /> : null}
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td mono>{item.metering_source === 'beebridge' ? new Date(item.occurred_at || item.created_at || '').toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }) : fmtEventTime(item.occurred_at || item.created_at)}</Td>
            <Td>{item.account_name || (item.account_id ? `用户 #${item.account_id}` : item.metering_source === 'beebridge' ? '未归属成员' : '系统')}</Td>
            <Td>{usageSceneLabel(item.source_scene)}</Td>
            <Td className="max-w-[220px]"><span className="block max-w-[220px] truncate" title={item.display_title || ''}>{item.display_title || '-'}</span></Td>
            <Td className="tabular-nums">{item.amount_known === false ? 'Token 未知' : fmtUsageAmount(finiteNumber(item.amount), item.resource_type)}</Td>
            <Td>{item.metering_source === 'beebridge' ? item.input_tokens ?? '未知' : '-'}</Td>
<Td>{item.metering_source === 'beebridge' ? item.output_tokens ?? '未知' : '-'}</Td>
            <Td strong={item.credits_cost > 0} className="tabular-nums">{finiteNumber(item.credits_cost).toLocaleString()}</Td>
            <Td className={item.status === 'failed' ? 'text-[var(--color-danger)]' : ''}>{item.status === 'failed' ? '失败' : '成功'}</Td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={pageSize} onPageChange={setPage} onPageSizeChange={(s) => { setPageSize(s); setPage(1) }} />
    </DrawerShell>
  )
}

function StatusFilter({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="w-[130px]">
      <Select value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">全部状态</option>
        <option value="true">启用</option>
        <option value="false">停用</option>
      </Select>
    </div>
  )
}

function OverridesTab() {
  const [tenantID, setTenantID] = useState('')
  const [featureCode, setFeatureCode] = useState('')
  const [statusFilter, setStatusFilter] = useState('')
  const [page, setPage] = useState(1)
  const [data, setData] = useState<{ items: BillingEntitlementOverride[]; total: number }>({ items: [], total: 0 })
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [editing, setEditing] = useState<BillingEntitlementOverride | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setErr('')
    try {
      setData(await BillingAPI.listOverrides({
        tenant_id: tenantID || undefined,
        feature_code: featureCode || undefined,
        status: statusFilter || undefined,
        limit: PAGE_SIZE,
        offset: offset(page),
      }))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [page, tenantID, featureCode, statusFilter])

  useEffect(() => scheduleLoad(load), [load])

  const toggleStatus = async (item: BillingEntitlementOverride) => {
    const next = item.status === 'active' ? 'disabled' : 'active'
    await BillingAPI.patchOverrideStatus(item.id, next)
    await load()
  }

  return (
    <section>
      <Toolbar
        search={<SearchInput value={tenantID} onChange={(v) => { setTenantID(v.replace(/[^\d]/g, '')); setPage(1) }} placeholder="租户 ID" />}
        filters={(
          <>
            <SearchInput value={featureCode} onChange={(v) => { setFeatureCode(v); setPage(1) }} placeholder="权益项 code" />
            <div className="w-[120px]">
              <Select value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value); setPage(1) }}>
                <option value="">全部状态</option>
                <option value="active">启用</option>
                <option value="disabled">停用</option>
              </Select>
            </div>
          </>
        )}
        summary={<span>共 {data.total} 条覆写</span>}
        actions={(
          <>
            <PrimaryButton onClick={() => setCreating(true)}>新建</PrimaryButton>
            <RefreshButton onClick={load} loading={loading} />
          </>
        )}
      />
      {err && <InlineAlert>{err}</InlineAlert>}
      <DataTable
        headers={['ID', '租户', '权益项', '覆写值', '单位', '原因', '状态', '生效开始', '生效结束', '创建时间', '操作']}
        loading={loading ? <TableLoading /> : null}
        empty={!loading && data.items.length === 0 ? <EmptyState title="暂无权益覆写" description="为特定租户创建权益覆写以调整配额限制。" /> : null}
      >
        {data.items.map((item) => (
          <tr key={item.id} className="group hover:bg-[var(--color-bg-sub)]">
            <Td mono>{item.id}</Td>
            <Td>{item.tenant_id}</Td>
            <Td mono>{item.feature_id}</Td>
            <Td>{item.override_value ?? '-'}</Td>
            <Td>{item.override_unit || '-'}</Td>
            <Td>{item.reason || '-'}</Td>
            <td className="px-4 py-2">
              <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${item.status === 'active' ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-500'}`}>
                {item.status === 'active' ? '启用' : '停用'}
              </span>
            </td>
            <Td>{dateOnly(item.effective_from)}</Td>
            <Td>{item.effective_to ? dateOnly(item.effective_to) : '永久'}</Td>
            <Td>{dateTime(item.created_at)}</Td>
            <td className="px-4 py-2">
              <div className="flex gap-1">
                <Button size="sm" variant="secondary" onClick={() => setEditing(item)}>
                  <Pencil size={14} />
                </Button>
                <Button size="sm" variant="secondary" onClick={() => void toggleStatus(item)}>
                  <Power size={14} />
                </Button>
              </div>
            </td>
          </tr>
        ))}
      </DataTable>
      <Pagination total={data.total} page={page} pageSize={PAGE_SIZE} onPageChange={setPage} onPageSizeChange={() => {}} pageSizeOptions={[PAGE_SIZE]} />
      {creating && (
        <OverrideFormDialog
          onClose={() => setCreating(false)}
          onSaved={() => { setCreating(false); void load() }}
        />
      )}
      {editing && (
        <OverrideFormDialog
          override={editing}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); void load() }}
        />
      )}
    </section>
  )
}

function OverrideFormDialog({ override, onClose, onSaved }: {
  override?: BillingEntitlementOverride
  onClose: () => void
  onSaved: () => void
}) {
  const isEdit = !!override
  const [tenantId, setTenantId] = useState(override ? String(override.tenant_id) : '')
  const [featureCode, setFeatureCode] = useState('')
  const [overrideValue, setOverrideValue] = useState(override?.override_value != null ? String(override.override_value) : '')
  const [overrideUnit, setOverrideUnit] = useState(override?.override_unit || '')
  const [reason, setReason] = useState(override?.reason || '')
  const [effectiveFrom, setEffectiveFrom] = useState(override?.effective_from?.slice(0, 10) || '')
  const [effectiveTo, setEffectiveTo] = useState(override?.effective_to?.slice(0, 10) || '')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const submit = async () => {
    setBusy(true)
    setErr('')
    try {
      if (isEdit) {
        await BillingAPI.updateOverride(override!.id, {
          override_value: overrideValue ? Number(overrideValue) : undefined,
          override_unit: overrideUnit || undefined,
          reason: reason || undefined,
          effective_from: effectiveFrom || undefined,
          effective_to: effectiveTo || undefined,
        })
      } else {
        await BillingAPI.createOverride({
          tenant_id: Number(tenantId),
          feature_code: featureCode,
          override_value: overrideValue ? Number(overrideValue) : undefined,
          override_unit: overrideUnit || undefined,
          reason,
          effective_from: effectiveFrom || undefined,
          effective_to: effectiveTo || undefined,
        })
      }
      onSaved()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const canSubmit = isEdit
    ? (overrideValue || reason)
    : (tenantId && featureCode && reason)

  return (
    <DialogShell
      title={isEdit ? '编辑覆写' : '新建权益覆写'}
      icon={<Pencil size={18} />}
      onClose={onClose}
      size="sm"
      footer={(
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} disabled={busy}>取消</Button>
          <Button onClick={submit} disabled={busy || !canSubmit}>
            {busy ? '保存中...' : '保存'}
          </Button>
        </div>
      )}
    >
      <div className="space-y-4">
        {!isEdit && (
          <>
            <FormField label="租户 ID">
              <Input value={tenantId} inputMode="numeric" onChange={(e) => setTenantId(e.target.value.replace(/[^\d]/g, ''))} />
            </FormField>
            <FormField label="权益项 Code" hint="如 max_agents、monthly_credits">
              <Input value={featureCode} onChange={(e) => setFeatureCode(e.target.value)} />
            </FormField>
          </>
        )}
        <FormField label="覆写值" hint="留空表示不限">
          <Input value={overrideValue} inputMode="numeric" onChange={(e) => setOverrideValue(e.target.value.replace(/[^\d]/g, ''))} />
        </FormField>
        <FormField label="单位" hint="如 count、credits">
          <Input value={overrideUnit} onChange={(e) => setOverrideUnit(e.target.value)} />
        </FormField>
        <FormField label="原因">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="覆写原因" />
        </FormField>
        <FormField label="生效开始" hint="可选，YYYY-MM-DD">
          <Input type="date" value={effectiveFrom} onChange={(e) => setEffectiveFrom(e.target.value)} />
        </FormField>
        <FormField label="生效结束" hint="可选，留空为永久">
          <Input type="date" value={effectiveTo} onChange={(e) => setEffectiveTo(e.target.value)} />
        </FormField>
        {err && <InlineAlert>{err}</InlineAlert>}
      </div>
    </DialogShell>
  )
}

function scheduleLoad(load: () => Promise<void>) {
  const timer = window.setTimeout(() => { void load() }, 0)
  return () => window.clearTimeout(timer)
}

function RefreshButton({ onClick, loading }: { onClick: () => void | Promise<void>; loading: boolean }) {
  return (
    <Button type="button" variant="secondary" onClick={() => void onClick()} disabled={loading}>
      <RefreshCw size={14} className={loading ? 'animate-spin' : ''} /> 刷新
    </Button>
  )
}

function TableLoading() {
  return <div className="border-t border-[var(--color-line-soft)] px-4 py-5 text-[13px] text-[var(--color-text-sub)]">正在加载...</div>
}

function Td({ children, strong, mono, className }: { children: ReactNode; strong?: boolean; mono?: boolean; className?: string }) {
  return (
    <td className={[
      'whitespace-nowrap px-4 py-2 text-[13px]',
      strong ? 'font-medium text-[var(--color-text)]' : 'text-[var(--color-text-sub)]',
      mono ? 'font-mono text-[12px]' : '',
      className ?? '',
    ].join(' ')}
    >
      {children}
    </td>
  )
}

function StatusBadge({ active }: { active: boolean }) {
  return (
    <span className={active
      ? 'inline-flex rounded-full bg-[var(--color-success-bg)] px-2 py-0.5 text-[12px] font-medium text-[var(--color-success)]'
      : 'inline-flex rounded-full bg-[var(--color-line-soft)] px-2 py-0.5 text-[12px] font-medium text-[var(--color-text-sub)]'}
    >
      {active ? '启用' : '停用'}
    </span>
  )
}

function BillingRowAction({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <button
      type="button"
      title={label}
      onClick={onClick}
      className="inline-flex h-8 items-center justify-center whitespace-nowrap rounded-md px-3 text-[13px] font-medium text-[var(--color-brand)] transition hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand-hover)]"
    >
      {label}
    </button>
  )
}

function offset(page: number) {
  return Math.max(0, page - 1) * PAGE_SIZE
}

function money(value?: number | null, currency = 'CNY') {
  if (value == null) return '-'
  const prefix = currency === 'CNY' ? '¥' : `${currency} `
  return `${prefix}${Number(value).toFixed(2)}`
}

function planPriceForCycle(plan: BillingPlan | null | undefined, cycle: string) {
  if (!plan?.prices?.length) return null
  return plan.prices.find((price) => price.billing_cycle === cycle && price.is_active !== false) ?? null
}

function planAmountForCycle(plan: BillingPlan, cycle: string) {
  const price = planPriceForCycle(plan, cycle)
  if (price) return price.amount
  if (cycle === 'yearly') return plan.price_yearly
  if (cycle === 'monthly') return plan.price_monthly
  return null
}

function initialPlanPriceRows(plan: BillingPlan | null): PlanPriceRow[] {
  const prices = [...(plan?.prices ?? [])].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0))
  if (prices.length === 0) {
    return [
      emptyPlanPriceRow('monthly', true, 10, plan?.code),
      emptyPlanPriceRow('yearly', false, 20, plan?.code),
    ]
  }
  const rows = prices.map((price) => ({
    key: price.billing_cycle,
    code: price.code || `${plan?.code ?? 'plan'}_${price.billing_cycle}`,
    billingCycle: normalizePriceCycle(price.billing_cycle),
    amount: amountText(price.amount),
    displayMonthlyAmount: amountText(price.display_monthly_amount),
    originalAmount: amountText(price.original_amount),
    promotionText: price.promotion_text ?? '',
    isActive: price.is_active !== false,
    sortOrder: price.sort_order ?? cycleSortOrder(price.billing_cycle),
  }))
  const cycles = new Set(rows.map((row) => row.billingCycle))
  if (!cycles.has('monthly') && !cycles.has('none')) rows.push(emptyPlanPriceRow('monthly', false, 10, plan?.code))
  if (!cycles.has('yearly') && !cycles.has('none')) rows.push(emptyPlanPriceRow('yearly', false, 20, plan?.code))
  return rows.sort((a, b) => a.sortOrder - b.sortOrder)
}

function emptyPlanPriceRow(cycle: PlanPriceRow['billingCycle'], active: boolean, sortOrder: number, planCode = 'plan'): PlanPriceRow {
  return {
    key: cycle,
    code: `${planCode}_${cycle}`,
    billingCycle: cycle,
    amount: '',
    displayMonthlyAmount: '',
    originalAmount: '',
    promotionText: '',
    isActive: active,
    sortOrder,
  }
}

function planPriceFromRow(planCode: string, row: PlanPriceRow): BillingPlanPrice {
  return {
    code: priceCodeForCycle(planCode, row.billingCycle),
    billing_cycle: row.billingCycle,
    amount: parseRequiredMoney(row.amount),
    currency: 'CNY',
    interval_count: 1,
    display_monthly_amount: parseOptionalMoney(row.displayMonthlyAmount),
    original_amount: parseOptionalMoney(row.originalAmount),
    promotion_text: row.promotionText.trim(),
    sort_order: row.sortOrder,
    is_active: row.isActive,
  }
}

function priceCodeForCycle(planCode: string, cycle: PlanPriceRow['billingCycle']) {
  return `${planCode.trim() || 'plan'}_${cycle}`
}

function parseRequiredMoney(value: string) {
  const trimmed = value.trim()
  if (trimmed === '') return 0
  const n = Number(trimmed)
  if (!Number.isFinite(n) || n < 0) throw new Error('价格点金额必须为大于等于 0 的数字')
  return n
}

function parseOptionalMoney(value: string) {
  const trimmed = value.trim()
  if (trimmed === '') return null
  const n = Number(trimmed)
  if (!Number.isFinite(n) || n < 0) throw new Error('展示月费和划线原价必须为大于等于 0 的数字')
  return n
}

function amountText(value?: number | null) {
  return value == null ? '' : Number(value).toString()
}

function normalizePriceCycle(value: string): PlanPriceRow['billingCycle'] {
  if (value === 'yearly' || value === 'none') return value
  return 'monthly'
}

function cycleSortOrder(value: string) {
  if (value === 'none') return 0
  if (value === 'monthly') return 10
  if (value === 'yearly') return 20
  return 99
}

function priceCycleText(value: PlanPriceRow['billingCycle']) {
  if (value === 'monthly') return '按月付'
  if (value === 'yearly') return '按年付'
  return '无周期'
}

function dateTime(value?: string | null) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleString('zh-CN', { hour12: false })
}

function dateOnly(value?: string | null) {
  if (!value) return '-'
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return value
  return d.toLocaleDateString('zh-CN')
}

function configLabel(key: string) {
  const labels: Record<string, string> = {
    annual_discount_months: '年付折扣月数',
    dunning_retry_days: '催缴重试日程',
    expiring_credit_warning_days: '积分过期提醒天数',
    grace_period_days: '欠费宽限期',
    low_credit_warning_threshold: '低余额提醒阈值',
    order_expire_minutes: '支付订单超时',
    overdraft_ratio: '透支额度比例',
  }
  return labels[key] || key
}

function orderTypeLabel(v: string) {
  if (v === 'subscription') return '套餐订阅'
  if (v === 'upgrade') return '套餐订阅'
  if (v === 'credit_pack') return '积分包'
  return v
}

function providerLabel(v: string) {
  if (v === 'wechat') return '微信'
  if (v === 'alipay') return '支付宝'
  if (v === 'manual') return '人工'
  if (v === 'mock') return 'Mock'
  return v
}

function paymentStatusLabel(v: string) {
  const labels: Record<string, string> = {
    created: '已创建',
    paying: '支付中',
    paid: '已支付',
    closed: '已关闭',
    refunding: '退款中',
    refunded: '已退款',
  }
  return labels[v] || v
}
