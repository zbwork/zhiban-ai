import { api, auth, uploadMultipart, parseApiBody, resolveErrorMessage, tryRefresh } from './httpClient'
import type { UploadProgress } from './httpClient'
import type { Menu, LoginResp } from './authApi'
import { beginLoading, endLoading } from './loading'
import { randomUUID } from './uuid'
import { humanizeError } from './errorMessages'
export * from './httpClient'
export * from './authApi'
export * from './departmentApi'
// ---- typed API helpers ----

export type BillingList<T> = { items: T[]; total: number }
type RawBillingList<T> = BillingList<T> & { Items?: T[]; Total?: number }

export type BillingPlan = {
  id: number
  code: string
  name: string
  description?: string
  price_monthly?: number | null
  price_yearly?: number | null
  currency: string
  billing_cycle: string
  prices?: BillingPlanPrice[]
  trial_days: number
  monthly_credits: number
  sort_order: number
  is_active: boolean
  is_system: boolean
  is_recommended?: boolean
  created_at?: string
  updated_at?: string
}

export type BillingPlanPrice = {
  id?: number
  plan_id?: number
  code: string
  billing_cycle: string
  amount: number
  currency: string
  interval_count: number
  display_monthly_amount?: number | null
  original_amount?: number | null
  promotion_text?: string
  sort_order: number
  is_active: boolean
}

export type BillingFeature = {
  id: number
  code: string
  name: string
  description?: string
  type: string
  unit?: string
  sort_order: number
  is_active: boolean
  created_at?: string
  updated_at?: string
}

export type BillingPlanFeature = {
  id?: number
  plan_id: number
  feature_id: number
  limit_value: number | null
  limit_unit?: string | null
}

export type BillingCreditPack = {
  id: number
  name: string
  credits: number
  price: number
  currency: string
  sort_order: number
  is_active: boolean
  created_at?: string
  updated_at?: string
}

export type BillingCreditPackCreateInput = {
  name: string
  credits: number
  price: number
  currency: string
  sort_order: number
}

export type BillingCreditPackUpdateInput = {
  name?: string
  credits?: number
  price?: number
  sort_order?: number
}

export type BillingCreditRate = {
  id: number
  resource_type: string
  resource_name: string
  credits_per_unit: number
  unit_name: string
  is_active: boolean
  updated_at?: string
}

export type BillingSkillPrice = {
  skill_id: number
  skill_uuid: string
  skill_name: string
  billing_type: string
  pricing_mode: string
  credits_per_call?: number | null
  operation_count: number
}

export type BillingSkillOperation = {
  id: number
  skill_id: number
  operation_code: string
  operation_name: string
  description?: string
  input_schema?: unknown
  output_schema?: unknown
  status: string
  sort_order: number
  created_at?: string
  updated_at?: string
}

export type BillingSkillOperationImport = {
  operation_code: string
  operation_name: string
  description?: string
  input_schema?: unknown
  output_schema?: unknown
  sort_order?: number
}

export type BillingSkillOperationPrice = {
  skill_id: number
  operation_code: string
  operation_name: string
  operation_status: string
  credits_per_call?: number | null
  is_overridden: boolean
}

export type BillingSkillPricingConfigOperation = {
  operation_code: string
  operation_name: string
  description?: string
  input_schema?: unknown
  output_schema?: unknown
  sort_order?: number
  credits_per_call?: number | null
}

export type BillingSkillPricingConfigPayload = {
  billing_type: string
  pricing_mode: string
  default_credits_per_call?: number | null
  operations?: BillingSkillPricingConfigOperation[]
  deleted_operation_codes?: string[]
}

export type BillingPaymentOrder = {
  id: number
  tenant_id: number
  tenant_name?: string
  account_id: number
  account_name?: string
  out_trade_no: string
  order_type: string
  product_id?: number | null
  amount_cents: number
  currency: string
  status: string
  provider: string
  provider_trade_no?: string | null
  paid_at?: string | null
  closed_at?: string | null
  expire_at?: string | null
  fulfilled: boolean
  fulfilled_at?: string | null
  created_at?: string
  updated_at?: string
}

type RawBillingPaymentOrder = BillingPaymentOrder & {
  ID?: number
  TenantID?: number
  TenantName?: string
  AccountID?: number
  AccountName?: string
  OutTradeNo?: string
  OrderType?: string
  ProductID?: number | null
  AmountCents?: number
  Currency?: string
  Status?: string
  Provider?: string
  ProviderTradeNo?: string | null
  PaidAt?: string | null
  ClosedAt?: string | null
  ExpireAt?: string | null
  Fulfilled?: boolean
  FulfilledAt?: string | null
  CreatedAt?: string
  UpdatedAt?: string
}

export type BillingConfigItem = {
  id: number
  key: string
  value: string
  description?: string
  updated_by?: number | null
  created_at?: string
  updated_at?: string
}

type RawBillingConfigItem = BillingConfigItem & {
  ID?: number
  Key?: string
  Value?: string
  Description?: string
  UpdatedBy?: number | null
  CreatedAt?: string
  UpdatedAt?: string
}

export type BillingUsageAggregate = {
  unknown_amount_count?: number
  id: number
  tenant_id: number
  tenant_name?: string
  resource_type: string
  period: string
  period_start: string
  skill_id?: number | null
  operation_code?: string
  total_amount: number
  total_credits: number
  event_count: number
  last_aggregated_at?: string
  updated_at?: string
}

type RawBillingUsageAggregate = BillingUsageAggregate & {
  ID?: number
  TenantID?: number
  TenantName?: string
  ResourceType?: string
  Period?: string
  PeriodStart?: string
  SkillID?: number | null
  OperationCode?: string
  TotalAmount?: number
  TotalCredits?: number
  EventCount?: number
  LastAggregatedAt?: string
  UpdatedAt?: string
}

export type BillingUsageEvent = {
  metering_source?: string
  model?: string | null
  input_tokens?: string | null
  output_tokens?: string | null
  amount_known?: boolean
  charge_count?: number
  refund_count?: number
  net_usd?: string
  id: number
  tenant_id: number
  account_id?: number | null
  account_name?: string
  agent_id?: number | null
  agent_uuid?: string
  skill_id?: number | null
  operation_code?: string
  pricing_mode?: string
  resource_type: string
  source_scene?: string
  source_object_type?: string
  source_object_id?: string
  display_title?: string
  amount: number
  credits_cost: number
  status: string
  occurred_at?: string
  created_at?: string
}

// 后端 UsageEvent 领域结构体无 json tag，实际以 PascalCase 序列化；两种命名都兜住。
type RawBillingUsageEvent = BillingUsageEvent & {
  ID?: number
  TenantID?: number
  AccountID?: number | null
  AccountName?: string
  AgentID?: number | null
  AgentUUID?: string
  SkillID?: number | null
  OperationCode?: string
  PricingMode?: string
  ResourceType?: string
  SourceScene?: string
  SourceObjectType?: string
  SourceObjectID?: string
  DisplayTitle?: string
  Amount?: number
  CreditsCost?: number
  Status?: string
  OccurredAt?: string | null
  CreatedAt?: string
}

export type BillingUsageTrendPoint = {
  unknown_amount_count?: number
  period_start: string
  resource_type: string
  total_amount: number
  total_credits: number
  event_count: number
}

export type BillingUsageAggregateSummary = {
  by_resource: BillingUsageResourceSum[]
  trend: BillingUsageTrendPoint[]
}

export type BillingTenantUsageRank = {
  wallet_balance_known?: boolean
  unknown_amount_count?: number
  tenant_id: number
  tenant_name: string
  plan_name: string
  wallet_balance: number
  total_credits: number
  total_amount: number
  event_count: number
}

export type BillingUsageResourceSum = {
  unknown_amount_count?: number
  resource_type: string
  total_credits: number
  total_amount: number
  event_count: number
}

export type BillingUsageSceneSum = {
  source_scene: string
  total_credits: number
  event_count: number
}

export type BillingMonthlyStatement = {
  balance_source?: string
  funding_history_known?: boolean
  month: string
  tenant_id: number
  opening_balance: number | null
  granted_credits: number
  consumed_credits: number
  closing_balance: number | null
  event_count: number
  by_resource: BillingUsageResourceSum[]
  by_scene: BillingUsageSceneSum[]
}

export type BillingEntitlementOverride = {
  id: number
  tenant_id: number
  feature_id: number
  override_value: number | null
  override_unit?: string | null
  reason: string
  status: string
  effective_from: string
  effective_to?: string | null
  created_by?: number | null
  updated_by?: number | null
  created_at: string
  updated_at: string
}

export type BillingSubscription = {
  id: number
  tenant_id: number
  plan_id: number
  plan_name: string
  plan_code: string
  pending_plan_id?: number
  pending_plan_name?: string
  pending_plan_code?: string
  pending_billing_cycle?: string
  pending_effective_at?: string
  status: string
  current_period_start: string
  current_period_end: string
  trial_end?: string
  canceled_at?: string
  auto_renew: boolean
  in_grace_period: boolean
  grace_period_end?: string
  created_at: string
}

export type BillingEntitlement = {
  feature_code: string
  feature_name?: string
  feature_type: string
  granted_value?: number | null
  granted_unit?: string | null
  granted_value_bytes?: number | null
  current_usage?: number | null
  current_usage_bytes?: number | null
  override_value?: number | null
  override_unit?: string | null
  plan_value?: number | null
  plan_unit?: string | null
  is_active: boolean
  sort_order?: number
}

export type BillingWalletOverview = {
  total_credits?: number | null
  used_credits?: number | null
  quota_used_raw?: number | null
  balance_source?: string
  balance_observed_at?: string
  balance_pricing_id?: number
  quota_raw?: number
  tenant_id: number
  balance: number
  overdraft_used: number
  overdraft_limit: number
  available_credits: number
  frozen: boolean
}

export type TenantBillingOverview = {
  subscription: BillingSubscription | null
  entitlements: BillingEntitlement[]
  wallet: BillingWalletOverview | null
}

export type CreditPurchaseOptions = {
  pricing_id: number
  credits_per_cny: number
  min_amount_cents: number
  max_amount_cents: number
  available_credits: number
}

export type CreditPurchaseInput = {
  request_id: string
  amount_cents: number
  pricing_id: number
  remark: string
}

export type CreditPurchaseResult = {
  order_id: number
  out_trade_no: string
  amount_cents: number
  credits: number
  fulfilled: boolean
  beebridge_status: string
}

async function downloadCSV(path: string) {
  const res = await fetch(path, {
    headers: { Authorization: `Bearer ${auth.token()}` },
  })
  if (!res.ok) throw new Error(`Export failed: ${res.status}`)
  const blob = await res.blob()
  const cd = res.headers.get('Content-Disposition') || ''
  const match = cd.match(/filename="?([^";\s]+)"?/)
  const filename = match?.[1] || 'export.csv'
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

// 认证态取文件 blob（预览/下载共用底座）：带 Bearer + 401 刷新重试。
// 预览场景拿 blob 自建 objectURL（附件端点是 attachment disposition，
// 直接 window.open 会被浏览器落成下载）。
async function fetchFileBlob(path: string, init: RequestInit, retried = false):
  Promise<{ blob: Blob; disposition: string }> {
  const headers: Record<string, string> = { ...(init.headers as Record<string, string>) }
  const token = auth.token()
  if (token) headers.Authorization = `Bearer ${token}`
  if (!(init.body instanceof FormData) && !headers['Content-Type']) headers['Content-Type'] = 'application/json'
  const res = await fetch(path, { ...init, headers })
  if (res.status === 401 && !retried && auth.refresh()) {
    const refreshed = await tryRefresh()
    if (refreshed) return fetchFileBlob(path, init, true)
  }
  if (!res.ok) {
    const bodyText = await res.text()
    const body = parseApiBody<unknown>(bodyText, res)
    throw new Error(humanizeError(resolveErrorMessage(body, res, bodyText)))
  }
  return { blob: await res.blob(), disposition: res.headers.get('Content-Disposition') || '' }
}

async function downloadFile(path: string, init: RequestInit, fallbackFilename: string, filenameOverride?: string) {
  const { blob, disposition: cd } = await fetchFileBlob(path, init)
  const match = cd.match(/filename="?([^";]+)"?/i)
  const filename = filenameOverride || match?.[1]?.trim() || fallbackFilename
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  URL.revokeObjectURL(url)
}

const billingBase = '/api/admin/v1/platform/billing'
const tenantBillingBase = '/api/admin/v1/tenant/billing'

function normalizeBillingConfigItem(item: RawBillingConfigItem): BillingConfigItem {
  return {
    id: item.id ?? item.ID ?? 0,
    key: item.key ?? item.Key ?? '',
    value: item.value ?? item.Value ?? '',
    description: item.description ?? item.Description ?? '',
    updated_by: item.updated_by ?? item.UpdatedBy ?? null,
    created_at: item.created_at ?? item.CreatedAt,
    updated_at: item.updated_at ?? item.UpdatedAt,
  }
}

function normalizePaymentOrder(item: RawBillingPaymentOrder): BillingPaymentOrder {
  return {
    id: item.id ?? item.ID ?? 0,
    tenant_id: item.tenant_id ?? item.TenantID ?? 0,
    tenant_name: item.tenant_name ?? item.TenantName ?? '',
    account_id: item.account_id ?? item.AccountID ?? 0,
    account_name: item.account_name ?? item.AccountName ?? '',
    out_trade_no: item.out_trade_no ?? item.OutTradeNo ?? '',
    order_type: item.order_type ?? item.OrderType ?? '',
    product_id: item.product_id ?? item.ProductID ?? null,
    amount_cents: item.amount_cents ?? item.AmountCents ?? 0,
    currency: item.currency ?? item.Currency ?? 'CNY',
    status: item.status ?? item.Status ?? '',
    provider: item.provider ?? item.Provider ?? '',
    provider_trade_no: item.provider_trade_no ?? item.ProviderTradeNo ?? null,
    paid_at: item.paid_at ?? item.PaidAt ?? null,
    closed_at: item.closed_at ?? item.ClosedAt ?? null,
    expire_at: item.expire_at ?? item.ExpireAt ?? null,
    fulfilled: item.fulfilled ?? item.Fulfilled ?? false,
    fulfilled_at: item.fulfilled_at ?? item.FulfilledAt ?? null,
    created_at: item.created_at ?? item.CreatedAt,
    updated_at: item.updated_at ?? item.UpdatedAt,
  }
}

function normalizeUsageAggregate(item: RawBillingUsageAggregate): BillingUsageAggregate {
  return {
    unknown_amount_count: item.unknown_amount_count ?? 0,
    id: item.id ?? item.ID ?? 0,
    tenant_id: item.tenant_id ?? item.TenantID ?? 0,
    tenant_name: item.tenant_name ?? item.TenantName ?? '',
    resource_type: item.resource_type ?? item.ResourceType ?? '',
    period: item.period ?? item.Period ?? '',
    period_start: item.period_start ?? item.PeriodStart ?? '',
    skill_id: item.skill_id ?? item.SkillID ?? null,
    operation_code: item.operation_code ?? item.OperationCode ?? '',
    total_amount: item.total_amount ?? item.TotalAmount ?? 0,
    total_credits: item.total_credits ?? item.TotalCredits ?? 0,
    event_count: item.event_count ?? item.EventCount ?? 0,
    last_aggregated_at: item.last_aggregated_at ?? item.LastAggregatedAt,
    updated_at: item.updated_at ?? item.UpdatedAt,
  }
}

function normalizeUsageEvent(item: RawBillingUsageEvent): BillingUsageEvent {
  return {
    metering_source: item.metering_source, model: item.model,
    input_tokens: item.input_tokens, output_tokens: item.output_tokens,
    amount_known: item.amount_known ?? true, charge_count: item.charge_count,
    refund_count: item.refund_count, net_usd: item.net_usd,
    id: item.id ?? item.ID ?? 0,
    tenant_id: item.tenant_id ?? item.TenantID ?? 0,
    account_id: item.account_id ?? item.AccountID ?? null,
    account_name: item.account_name ?? item.AccountName ?? '',
    agent_id: item.agent_id ?? item.AgentID ?? null,
    agent_uuid: item.agent_uuid ?? item.AgentUUID ?? '',
    skill_id: item.skill_id ?? item.SkillID ?? null,
    operation_code: item.operation_code ?? item.OperationCode ?? '',
    pricing_mode: item.pricing_mode ?? item.PricingMode ?? '',
    resource_type: item.resource_type ?? item.ResourceType ?? '',
    source_scene: item.source_scene ?? item.SourceScene ?? '',
    source_object_type: item.source_object_type ?? item.SourceObjectType ?? '',
    source_object_id: item.source_object_id ?? item.SourceObjectID ?? '',
    display_title: item.display_title ?? item.DisplayTitle ?? '',
    amount: item.amount ?? item.Amount ?? 0,
    credits_cost: item.credits_cost ?? item.CreditsCost ?? 0,
    status: item.status ?? item.Status ?? '',
    occurred_at: item.occurred_at ?? item.OccurredAt ?? undefined,
    created_at: item.created_at ?? item.CreatedAt,
  }
}

function qs(params: Record<string, string | number | boolean | undefined | null>) {
  const sp = new URLSearchParams()
  Object.entries(params).forEach(([k, v]) => {
    if (v === undefined || v === null || v === '') return
    sp.set(k, String(v))
  })
  const s = sp.toString()
  return s ? `?${s}` : ''
}

export type BeeBridgePricingVersion = {
  id: number; usd_cny_rate: string; credits_per_cny: number; quota_per_usd: number; effective_from: string; created_at: string; created_by: number
}
export type BeeBridgePricingResponse = {
  items: BeeBridgePricingVersion[]; total: number
  inbox: { pending: number; oldest_pending_at?: string; last_error: string }
}
export const Billing = {
  listBeeBridgePricing: (limit: number, offset: number) => api<BeeBridgePricingResponse>(`${billingBase}/beebridge-pricing${qs({ limit, offset })}`),
  publishBeeBridgePricing: (body: { usd_cny_rate: string; credits_per_cny: number; quota_per_usd: number; effective_from: string }) =>
    api(`${billingBase}/beebridge-pricing`, { method: 'POST', body: JSON.stringify(body) }),
  listPlans: (params: { q?: string; is_active?: string; limit?: number; offset?: number }) =>
    api<BillingList<BillingPlan>>(`${billingBase}/plans${qs(params)}`),
  createPlan: (body: {
    code: string
    name: string
    description?: string
    price_monthly?: number | null
    price_yearly?: number | null
    currency: string
    billing_cycle?: string
    prices?: BillingPlanPrice[]
    trial_days: number
    monthly_credits: number
    sort_order: number
    is_system: boolean
    is_recommended?: boolean
  }) =>
    api<BillingPlan>(`${billingBase}/plans`, { method: 'POST', body: JSON.stringify(body) }),
  updatePlan: (id: number, body: {
    name?: string
    description?: string
    price_monthly?: number | null
    price_yearly?: number | null
    billing_cycle?: string
    prices?: BillingPlanPrice[]
    trial_days?: number
    monthly_credits?: number
    sort_order?: number
    is_recommended?: boolean
  }) =>
    api<BillingPlan>(`${billingBase}/plans/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  updatePlanStatus: (id: number, is_active: boolean) =>
    api(`${billingBase}/plans/${id}/status`, { method: 'PATCH', body: JSON.stringify({ is_active }) }),
  getPlanFeatures: (planId: number) =>
    api<{ items: BillingPlanFeature[] }>(`${billingBase}/plans/${planId}/features`),
  setPlanFeatures: (
    planId: number,
    features: Array<{ feature_id: number; limit_value: number | null; limit_unit?: string | null }>,
  ) =>
    api<{ plan_id: number; count: number }>(`${billingBase}/plans/${planId}/features`, {
      method: 'PUT',
      body: JSON.stringify({ features }),
    }),
  listFeatures: (params: { q?: string; type?: string; is_active?: string; limit?: number; offset?: number }) =>
    api<BillingList<BillingFeature>>(`${billingBase}/features${qs(params)}`),
  createFeature: (body: {
    code: string
    name: string
    description?: string
    type: string
    unit?: string
    sort_order: number
  }) =>
    api<BillingFeature>(`${billingBase}/features`, { method: 'POST', body: JSON.stringify(body) }),
  updateFeature: (id: number, body: {
    name?: string
    description?: string
    unit?: string
    sort_order?: number
    is_active?: boolean
  }) =>
    api<BillingFeature>(`${billingBase}/features/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  listCreditRates: () =>
    api<{ items: BillingCreditRate[] }>(`${billingBase}/credit-rates`),
  updateCreditRate: (id: number, body: { resource_name: string; credits_per_unit: number; unit_name: string; is_active: boolean }) =>
    api(`${billingBase}/credit-rates/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  listCreditPacks: (params: { is_active?: string; limit?: number; offset?: number }) =>
    api<BillingList<BillingCreditPack>>(`${billingBase}/credit-packs${qs(params)}`),
  createCreditPack: (body: BillingCreditPackCreateInput) =>
    api<BillingCreditPack>(`${billingBase}/credit-packs`, { method: 'POST', body: JSON.stringify(body) }),
  updateCreditPack: (id: number, body: BillingCreditPackUpdateInput) =>
    api<BillingCreditPack>(`${billingBase}/credit-packs/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  updateCreditPackStatus: (id: number, is_active: boolean) =>
    api(`${billingBase}/credit-packs/${id}/status`, { method: 'PATCH', body: JSON.stringify({ is_active }) }),
  listSkillPrices: (params: { q?: string; billing_type?: string; pricing_mode?: string; limit?: number; offset?: number }) =>
    api<BillingList<BillingSkillPrice>>(`${billingBase}/skill-prices${qs(params)}`),
  updateSkillBilling: (skillId: number, body: { billing_type: string; pricing_mode: string }) =>
    api(`${billingBase}/skills/${skillId}/billing`, { method: 'PATCH', body: JSON.stringify(body) }),
  getSkillDefaultPrice: (skillId: number) =>
    api<{ credits_per_call: number }>(`${billingBase}/skill-prices/${skillId}/default`),
  setSkillDefaultPrice: (skillId: number, credits_per_call: number) =>
    api(`${billingBase}/skill-prices/${skillId}/default`, { method: 'PUT', body: JSON.stringify({ credits_per_call }) }),
  listSkillOperations: (skillId: number, params: { q?: string; status?: string; limit?: number; offset?: number } = {}) =>
    api<BillingList<BillingSkillOperation>>(`${billingBase}/skill-prices/${skillId}/operations${qs(params)}`),
  importSkillOperations: (skillId: number, operations: BillingSkillOperationImport[]) =>
    api<{ skill_id: number; submitted: number; affected_rows: number }>(`${billingBase}/skill-prices/${skillId}/operations/import`, {
      method: 'POST',
      body: JSON.stringify({ operations }),
    }),
  updateSkillOperation: (skillId: number, opCode: string, body: { operation_name?: string; description?: string; status?: string; sort_order?: number }) =>
    api(`${billingBase}/skill-prices/${skillId}/operations/${encodeURIComponent(opCode)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  listSkillOperationPrices: (skillId: number) =>
    api<{ items: BillingSkillOperationPrice[] }>(`${billingBase}/skill-prices/${skillId}/operations/prices`),
  setSkillOperationPrices: (skillId: number, prices: Array<{ operation_code: string; credits_per_call: number }>) =>
    api(`${billingBase}/skill-prices/${skillId}/operations/prices`, {
      method: 'PUT',
      body: JSON.stringify({ prices }),
    }),
  deleteSkillOperationPrice: (skillId: number, opCode: string) =>
    api(`${billingBase}/skill-prices/${skillId}/operations/${encodeURIComponent(opCode)}/price`, { method: 'DELETE' }),
  saveSkillPricingConfig: (skillId: number, payload: BillingSkillPricingConfigPayload) =>
    api(`${billingBase}/skill-prices/${skillId}/config`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  listOrders: async (params: { tenant_id?: string; status?: string; order_type?: string; limit?: number; offset?: number }) => {
    const res = await api<RawBillingList<RawBillingPaymentOrder>>(`${billingBase}/orders${qs(params)}`)
    const items = res.items ?? res.Items ?? []
    const total = res.total ?? res.Total ?? 0
    return { items: items.map(normalizePaymentOrder), total }
  },
  refundOrder: (id: number, body: { refund_amount_cents: number; reason: string }) =>
    api(`${billingBase}/orders/${id}/refund`, { method: 'POST', body: JSON.stringify(body) }),
  listConfig: async () => {
    const res = await api<{ items: RawBillingConfigItem[] }>(`${billingBase}/config`)
    return { items: res.items.map(normalizeBillingConfigItem) }
  },
  updateConfig: (key: string, value: string) =>
    api<{ key: string; updated: boolean }>(`${billingBase}/config/${encodeURIComponent(key)}`, {
      method: 'PUT',
      body: JSON.stringify({ value }),
    }),
  listUsageAggregates: async (params: { tenant_id?: string; resource_type?: string; period?: string; skill_id?: string; from?: string; to?: string; limit?: number; offset?: number }) => {
    const res = await api<RawBillingList<RawBillingUsageAggregate>>(`${billingBase}/usage/aggregates${qs(params)}`)
    const items = res.items ?? res.Items ?? []
    const total = res.total ?? res.Total ?? 0
    return { items: items.map(normalizeUsageAggregate), total }
  },
  listTenantUsageAggregates: async (params: { resource_type?: string; period?: string; skill_id?: string; from?: string; to?: string; limit?: number; offset?: number }) => {
    const res = await api<RawBillingList<RawBillingUsageAggregate>>(`${tenantBillingBase}/usage/aggregates${qs(params)}`)
    const items = res.items ?? res.Items ?? []
    const total = res.total ?? res.Total ?? 0
    return { items: items.map(normalizeUsageAggregate), total }
  },
  getUsageSummary: (params: { tenant_id?: string; resource_type?: string; period?: string; skill_id?: string; from?: string; to?: string }) =>
    api<BillingUsageAggregateSummary>(`${billingBase}/usage/summary${qs(params)}`),
  getTenantUsageSummary: (params: { resource_type?: string; period?: string; skill_id?: string; from?: string; to?: string }) =>
    api<BillingUsageAggregateSummary>(`${tenantBillingBase}/usage/summary${qs(params)}`),
  listTenantUsageRanking: async (params: { tenant_id?: string; resource_type?: string; period?: string; from?: string; to?: string; limit?: number }) => {
    const res = await api<{ items: BillingTenantUsageRank[] }>(`${billingBase}/usage/tenants${qs(params)}`)
    return { items: res.items ?? [] }
  },
  listUsageEvents: async (params: { tenant_id?: string; account_id?: string; agent_id?: string; resource_type?: string; source_scene?: string; skill_id?: string; operation_code?: string; status?: string; charged_only?: boolean; from?: string; to?: string; limit?: number; offset?: number }) => {
    const res = await api<RawBillingList<RawBillingUsageEvent>>(`${billingBase}/usage/events${qs(params)}`)
    const items = res.items ?? res.Items ?? []
    const total = res.total ?? res.Total ?? 0
    return { items: items.map(normalizeUsageEvent), total }
  },
  listTenantUsageEvents: async (params: { account_id?: string; agent_id?: string; resource_type?: string; source_scene?: string; skill_id?: string; operation_code?: string; status?: string; charged_only?: boolean; from?: string; to?: string; limit?: number; offset?: number }) => {
    const res = await api<RawBillingList<RawBillingUsageEvent>>(`${tenantBillingBase}/usage/events${qs(params)}`)
    const items = res.items ?? res.Items ?? []
    const total = res.total ?? res.Total ?? 0
    return { items: items.map(normalizeUsageEvent), total }
  },
  getMonthlyStatement: (params: { tenant_id: string; month?: string }) =>
    api<BillingMonthlyStatement>(`${billingBase}/usage/monthly-statement${qs(params)}`),
  exportOrders: (params: { tenant_id?: string; status?: string; order_type?: string; from?: string; to?: string }) =>
    downloadCSV(`${billingBase}/export/orders${qs(params)}`),
  exportUsageAggregates: (params: { tenant_id?: string; resource_type?: string; period?: string; skill_id?: string; from?: string; to?: string }) =>
    downloadCSV(`${billingBase}/export/usage-aggregates${qs(params)}`),
  exportUsageEvents: (params: { tenant_id?: string; account_id?: string; agent_id?: string; resource_type?: string; source_scene?: string; skill_id?: string; operation_code?: string; status?: string; charged_only?: boolean; from?: string; to?: string }) =>
    downloadCSV(`${billingBase}/export/usage-events${qs(params)}`),
  exportLedger: (params: { tenant_id?: string; wallet_id?: string; direction?: string; biz_type?: string; from?: string; to?: string }) =>
    downloadCSV(`${billingBase}/export/ledger${qs(params)}`),
  listOverrides: (params: { tenant_id?: string; feature_code?: string; status?: string; limit?: number; offset?: number }) =>
    api<BillingList<BillingEntitlementOverride>>(`${billingBase}/entitlement-overrides${qs(params)}`),
  createOverride: (body: { tenant_id: number; feature_code: string; override_value?: number | null; override_unit?: string; reason: string; effective_from?: string; effective_to?: string }) =>
    api<BillingEntitlementOverride>(`${billingBase}/entitlement-overrides`, { method: 'POST', body: JSON.stringify(body) }),
  updateOverride: (id: number, body: { override_value?: number | null; override_unit?: string; reason?: string; effective_from?: string; effective_to?: string }) =>
    api<BillingEntitlementOverride>(`${billingBase}/entitlement-overrides/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  patchOverrideStatus: (id: number, status: string) =>
    api(`${billingBase}/entitlement-overrides/${id}/status`, { method: 'PATCH', body: JSON.stringify({ status }) }),
  getTenantOverview: (tenantId: number) =>
    api<TenantBillingOverview>(`/api/admin/v1/platform/tenants/${tenantId}/billing/overview`),
  getTenantSubscription: () =>
    api<BillingSubscription>(`${tenantBillingBase}/subscription`),
  listTenantEntitlements: () =>
    api<BillingList<BillingEntitlement>>(`${tenantBillingBase}/entitlements`),
  // F25 §4.4: 租户侧钱包 / 流水 / 订单（只读透明度）
  getTenantWallet: () =>
    api<BillingWalletOverview>(`${tenantBillingBase}/wallet`),
  listTenantLedger: (params: { direction?: string; biz_type?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: BillingLedgerEntry[]; total: number }>(`${tenantBillingBase}/ledger${queryString(params)}`),
  listTenantOrders: (params: { status?: string; order_type?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: BillingPaymentOrder[]; total: number }>(`${tenantBillingBase}/orders${queryString(params)}`),
}

// F25: 积分流水条目（tenant scope 只读）
export type BillingLedgerEntry = {
  id: number
  direction: 'credit' | 'debit'
  amount: number
  balance_after: number
  biz_type: string
  biz_no: string
  created_at: string
}

// F25 §4.3: 平台侧租户 360° 聚合
export type TenantInsight = {
  overview: TenantOverview
  run_stats: {
    runs_14d: number
    failed_14d: number
    success_rate: number | null
    p95_duration_ms: number | null
  }
  active_members_30d: number
  open_alerts: number
}

export const TenantInsightAPI = {
  get: (tenantId: number) =>
    api<TenantInsight>(`/api/admin/v1/platform/tenants/${tenantId}/insight`),
}

export type Permission = {
  ID: number
  Code: string
  Name: string
  Kind: 'menu' | 'api' | 'data'
  ScopeKind: 'platform' | 'tenant' | 'workspace' | 'self'
  Resource: string
  Action: string
  Category: string
  IsSystem: boolean
  SortOrder: number
}

export const Permissions = {
  list: (scope = '') =>
    api<{ items: Permission[]; total: number }>(`/api/admin/v1/permissions?scope=${encodeURIComponent(scope)}`),
}

export type MenuDetail = { menu: Menu; permissionIds: number[] }
export type MenuInput = {
  parentId?: number | null
  name: string
  icon?: string
  route?: string
  sortOrder?: number
  scopeKind: Menu['scopeKind']
  isVisible: boolean
  metadata?: Record<string, unknown>
  permissionIds?: number[]
}

export const Menus = {
  list: (includeHidden = true) =>
    api<{ items: Menu[]; total: number }>(`/api/admin/v1/platform/menus?includeHidden=${includeHidden}`),
  get: (id: number) => api<MenuDetail>(`/api/admin/v1/platform/menus/${id}`),
  create: (body: MenuInput) =>
    api<MenuDetail>('/api/admin/v1/platform/menus', { method: 'POST', body: JSON.stringify(body) }),
  update: (id: number, body: MenuInput) =>
    api<MenuDetail>(`/api/admin/v1/platform/menus/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/menus/${id}`, { method: 'DELETE' }),
}

export type Role = {
  ID: number
  UUID: string
  ScopeKind: 'platform' | 'tenant'
  TenantID?: number | null
  Code: string
  Name: string
  Description?: string
  IsSystem: boolean
  CreatedAt: string
}
export type RoleDetail = { role: Role; permissionIds: number[] }
export type RoleInput = {
  code?: string
  name: string
  description?: string
  permissionIds?: number[]
}

export const Roles = {
  list: (scope: 'platform' | 'tenant', q = '', limit = 100, offset = 0) =>
    api<{ items: Role[]; total: number }>(
      `/api/admin/v1/${scope}/roles?q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`
    ),
  get: (scope: 'platform' | 'tenant', id: number) =>
    api<RoleDetail>(`/api/admin/v1/${scope}/roles/${id}`),
  create: (scope: 'platform' | 'tenant', body: RoleInput) =>
    api<RoleDetail>(`/api/admin/v1/${scope}/roles`, { method: 'POST', body: JSON.stringify(body) }),
  update: (scope: 'platform' | 'tenant', id: number, body: RoleInput) =>
    api<RoleDetail>(`/api/admin/v1/${scope}/roles/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  remove: (scope: 'platform' | 'tenant', id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/${scope}/roles/${id}`, { method: 'DELETE' }),
}

export type RoleAssignment = {
  ID: number
  AccountID: number
  RoleID: number
  ScopeKind: 'platform' | 'tenant' | 'workspace'
  TenantID?: number | null
  WorkspaceID?: number | null
  ExpiresAt?: string | null
  GrantedReason?: string
  CreatedAt: string
}

export const MemberRoles = {
  list: (membershipID: number) =>
    api<{ items: RoleAssignment[]; total: number }>(`/api/admin/v1/tenant/members/${membershipID}/roles`),
  assign: (membershipID: number, roleId: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/members/${membershipID}/roles`, {
      method: 'POST',
      body: JSON.stringify({ roleId }),
    }),
  revoke: (membershipID: number, roleId: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/members/${membershipID}/roles/${roleId}`, { method: 'DELETE' }),
  syncTenantRoles: async (membershipID: number, targetRoleIds: number[]) => {
    const current = await MemberRoles.list(membershipID)
    const currentRoleIds = new Set(
      (current.items || [])
        .filter((it) => it.ScopeKind === 'tenant')
        .map((it) => it.RoleID)
    )
    const target = new Set(targetRoleIds)
    // 先授予、后撤销：新增角色失败时保留原权限；撤销 tenant.admin 时
    // 后端还会事务内校验“至少一名常驻超级管理员”不变量。
    for (const id of targetRoleIds.filter((id) => !currentRoleIds.has(id))) {
      await MemberRoles.assign(membershipID, id)
    }
    for (const id of Array.from(currentRoleIds).filter((id) => !target.has(id))) {
      await MemberRoles.revoke(membershipID, id)
    }
  },
}

export type SysUser = {
  id: number
  account_id: number
  uuid: string
  email?: string
  phone?: string
  username?: string
  display_name: string
  status: string
  mfa_enabled: boolean
  is_platform: boolean
  must_change_password: boolean
  notes?: string
  last_login_at?: string
  created_at: string
  role_ids: number[]
  roles: string[]
}
export type SysUserInput = {
  email?: string
  phone?: string
  username?: string
  display_name?: string
  password?: string
  status?: string
  mfa_enabled?: boolean
  is_platform?: boolean
  must_change_password?: boolean
  notes?: string
  role_ids?: number[]
}

export const SysUsers = {
  list: (q = '', limit = 100, offset = 0) =>
    api<{ items: SysUser[]; total: number }>(
      `/api/admin/v1/platform/sys-users?q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`
    ),
  get: (id: number) => api<SysUser>(`/api/admin/v1/platform/sys-users/${id}`),
  create: (body: SysUserInput) =>
    api<SysUser>('/api/admin/v1/platform/sys-users', { method: 'POST', body: JSON.stringify(body) }),
  update: (id: number, body: SysUserInput) =>
    api<SysUser>(`/api/admin/v1/platform/sys-users/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/sys-users/${id}`, { method: 'DELETE' }),
}

export type TenantOwnerInfo = {
  accountId: number
  accountUuid: string
  displayName: string
  phone?: string
  email?: string
}

export type Tenant = {
  ID: number
  UUID: string
  Name: string
  Slug: string
  DisplayName?: string
  Description?: string
  Industry?: string
  OwnerID?: number
  Status: string
  // 旧 tenants.plan_id，只为兼容历史响应；现行套餐展示和变更不得使用。
  PlanID?: number
  // 创建租户时可选的新套餐 plans.id；后端只用于创建订阅，不落 tenants.plan_id。
  InitialPlanID?: number
  // 计费侧当前生效订阅对应的套餐，是租户当前套餐的唯一口径。
  EffectivePlanID?: number | null
  EffectivePlanCode?: string
  EffectivePlanName?: string
  CreatedAt: string
  UpdatedAt: string
  // 仅 GET /tenants/:id 详情接口返回；列表接口不带，避免 N+1。
  OwnerInfo?: TenantOwnerInfo
}

// Batch 2B T2B.1: body 不再接受 admin.password —— 后端 crypto/rand 生成一次性临时密码
export type TenantAdminInput = {
  mobile: string
  email?: string
  displayName?: string
}

export type TenantProvisionInput = Partial<Tenant> & {
  admin: TenantAdminInput
}

// 新建管理员账号不生成密码：该手机号必须先走短信验证码登录，登录后再自行设置密码。
export type TenantProvisionResult = {
  tenant: Tenant
  tenant_admin_role_id: number
  default_department_id: number
  initial_admin: {
    phone: string
    account_id: number
    account_uuid: string
    account_reused: boolean
  }
}

export type BeeBridgePasswordResetResult = {
  operation_id: string
  status: string
  message: string
  password_saved: boolean
  login_verified: boolean
  pat_verified: boolean
  model_key_checked: boolean
  model_key_verified: boolean
}

export type BeeBridgeLoginInfo = {
  reset_operation_id: string
  reset_stage: string
  tenant_id: number
  user_id: number
  username: string
  provision_status: string
  initialization_stage: string
  password_saved: boolean
  password: string
}

export const Tenants = {
  resetBeeBridgePassword: (id: number, operationID: string) =>
    api<BeeBridgePasswordResetResult>(`/api/admin/v1/platform/tenants/${id}/beebridge/password/reset`, { method: 'POST', cache: 'no-store', body: JSON.stringify({ operation_id: operationID }) }),
  beeBridgeInfo: (id: number) =>
    api<BeeBridgeLoginInfo>(`/api/admin/v1/platform/tenants/${id}/beebridge/info`, { method: 'POST', cache: 'no-store' }),
  initializeBeeBridge: (id: number) =>
    api<{ status: string; message: string }>(`/api/admin/v1/platform/tenants/${id}/beebridge/initialize`, { method: 'POST' }),
  list: (status = '', q = '', limit = 20, offset = 0) =>
    api<{ items: Tenant[]; total: number }>(
      `/api/admin/v1/platform/tenants?status=${encodeURIComponent(status)}&q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`
    ),
  get: (id: number) => api<Tenant>(`/api/admin/v1/platform/tenants/${id}`),
  create: (t: TenantProvisionInput) =>
    api<TenantProvisionResult>(`/api/admin/v1/platform/tenants`, {
      method: 'POST',
      body: JSON.stringify(t),
    }),
  update: (id: number, t: Partial<Tenant>) =>
    api<Tenant>(`/api/admin/v1/platform/tenants/${id}`, {
      method: 'PUT',
      body: JSON.stringify(t),
    }),
  assignPlan: (id: number, planId: number) =>
    api<{ subscription: BillingSubscription; changed: boolean; created: boolean }>(
      `/api/admin/v1/platform/tenants/${id}/billing/plan`,
      { method: 'POST', body: JSON.stringify({ plan_id: planId }) },
    ),
  creditPurchaseOptions: (id: number) =>
    api<CreditPurchaseOptions>(`/api/admin/v1/platform/tenants/${id}/billing/credit-purchase-options`),
  purchaseCredits: (id: number, body: CreditPurchaseInput) =>
    api<CreditPurchaseResult>(`/api/admin/v1/platform/tenants/${id}/billing/credit-purchases`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  creditPurchase: (id: number, requestId: string) =>
    api<CreditPurchaseResult>(`/api/admin/v1/platform/tenants/${id}/billing/credit-purchases/${encodeURIComponent(requestId)}`),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/tenants/${id}`, { method: 'DELETE' }),
}

export type Agent = {
  ID: number
  UUID: string
  TenantID: number
  CreatorID: number
  CreatorName?: string
  Name: string
  AvatarURL?: string
  AvatarPreviewURL?: string
  Intro?: string
  Description?: string
  WelcomeMsg?: string
  Tags?: string[]
  Visibility: string
  IntegrationMode: string
  Status: string
  IsSystem: boolean
  CreatedAt: string
}

export const Agents = {
  list: (limit = 50, offset = 0) =>
    api<{ items: Agent[]; total: number }>(
      `/api/admin/v1/tenant/agents?limit=${limit}&offset=${offset}`
    ),
}

export type Member = {
  account_id: number
  uuid: string
  email?: string
  phone?: string
  username?: string
  display_name: string
  avatar_url?: string
  status: string
  department_id?: number | null
  department_name?: string
  title?: string
  employee_id?: string
  joined_at?: string
  roles?: string[]
  contact_fields?: ContactFieldsInput
}

export type MemberDetail = Member & { membership_id: number; account_status: string }

// F28 v0.9：后台操作是定向邀请；角色/职位仅在被邀请人接受后生效。
export type InviteMemberInput = {
  phone: string
  display_name: string
  title?: string
  employee_id?: string
  department_id: number
  role_ids: number[]
  position_ids?: number[]
  primary_position_id?: number | null
}

// F28 v0.9：邀请只创建 pending 记录；接受前没有 member 或初始密码。
// status='accepted' 仅在服务端 member_invite.skip_confirmation 应急开关打开时出现
// （短信模板未报备通过前的临时旁路，跳过受邀人确认直接建立成员关系）。
export type MemberInviteResult = {
  invitation_uuid: string
  status: 'pending' | 'accepted'
  expires_at: string
  sms_sent: boolean
}

export type MemberInviteLink = {
  url: string
  expires_at: string
  tenant_name: string
}

export type UpdateMemberInput = {
  display_name?: string
  title?: string
  employee_id?: string
  department_id?: number
  status?: string  // active / suspended (= disabled) / left / invited
}

export type CreateMemberInput = {
  email: string
  display_name: string
  employee_id?: string
  title?: string
  department_id: number
}
export type CreateMemberResult = { member: MemberDetail; account_reused: boolean; initial_password?: string }

export const Members = {
  create: (body: CreateMemberInput) =>
    api<CreateMemberResult>('/api/admin/v1/tenant/members', { method: 'POST', body: JSON.stringify(body) }),
  list: (department_id = 0, q = '', limit = 50, offset = 0) =>
    api<{ items: MemberDetail[]; total: number }>(
      `/api/admin/v1/tenant/members?department_id=${department_id}&q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`
    ),
  invite: (body: InviteMemberInput) =>
    api<MemberInviteResult>('/api/admin/v1/tenant/member-invitations', { method: 'POST', body: JSON.stringify(body) }),
  invitationLink: () =>
    api<MemberInviteLink>('/api/admin/v1/tenant/member-invitations/link'),
  resetInvitationLink: () =>
    api<MemberInviteLink>('/api/admin/v1/tenant/member-invitations/link/reset', { method: 'POST' }),
  update: (membershipID: number, body: UpdateMemberInput) =>
    api<MemberDetail>(`/api/admin/v1/tenant/members/${membershipID}`, { method: 'PUT', body: JSON.stringify(body) }),
  remove: (membershipID: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/members/${membershipID}`, { method: 'DELETE' }),
}

// ---- F01 §1 tenant positions (ADR-0010: 业务实体表无 code, stable id 走 uuid) ----
export type Position = {
  id: number
  uuid: string
  tenantId: number
  name: string
  description?: string
  icon?: string
  sortOrder: number
  isSystem: boolean
  metadata?: Record<string, unknown>
  createdAt: string
  updatedAt: string
  memberCount: number
  agentCount: number
}
export type CreatePositionInput = {
  name: string
  description?: string
  icon?: string
  sortOrder?: number
  metadata?: Record<string, unknown>
}
export type UpdatePositionInput = {
  name?: string
  description?: string
  icon?: string
  sortOrder?: number
  metadata?: Record<string, unknown>
}
export type MemberPositionAssignment = {
  id: number
  membershipId: number
  positionId: number
  positionName: string
  isPrimary: boolean
  assignedAt: string
  assignedBy?: number | null
}
export type AgentPositionAssignment = {
  id: number
  agentId: number
  positionId: number
  positionName: string
  isPrimary: boolean
  assignedAt: string
}
export const Positions = {
  list: (q = '', limit = 20, offset = 0) =>
    api<{ items: Position[]; total: number }>(
      `/api/admin/v1/tenant/positions?q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`,
    ),
  create: (body: CreatePositionInput) =>
    api<Position>(`/api/admin/v1/tenant/positions`, { method: 'POST', body: JSON.stringify(body) }),
  update: (id: number, body: UpdatePositionInput) =>
    api<Position>(`/api/admin/v1/tenant/positions/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/positions/${id}`, { method: 'DELETE' }),
  listForMember: (membershipId: number) =>
    api<{ items: MemberPositionAssignment[] }>(`/api/admin/v1/tenant/members/${membershipId}/positions`),
  assignToMember: (membershipId: number, body: { positionIds: number[]; primaryPositionId?: number | null }) =>
    api<{ items: MemberPositionAssignment[] }>(`/api/admin/v1/tenant/members/${membershipId}/positions`,
      { method: 'PUT', body: JSON.stringify(body) }),
  listForAgent: (agentId: number) =>
    api<{ items: AgentPositionAssignment[] }>(`/api/admin/v1/tenant/agents/${agentId}/positions`),
  assignToAgent: (agentId: number, body: { positionIds: number[]; primaryPositionId?: number | null }) =>
    api<{ items: AgentPositionAssignment[] }>(`/api/admin/v1/tenant/agents/${agentId}/positions`,
      { method: 'PUT', body: JSON.stringify(body) }),
}

// ---- platform & tenant stats ----

export type PlatformStats = {
  tenants: number; active_tenants: number; runtimes: number; emp_blocks: number
  accounts: number; digital_employees: number
  conversations_today: number; messages_today: number
}
// ---- F25 平台首页聚合 (口径见 docs/features/F25-alert-center-and-admin-visibility.md §4.2) ----
export type PlatformHealth = {
  runs_today: number; runs_failed_today: number
  success_rate: number | null; p95_duration_ms: number | null
  affected_tenants: number; instances_abnormal: number; providers_abnormal: number
  cron_error_jobs: number; drive_worker_backlog: number; outbox_backlog: number
}
export type PlatformTopAlert = {
  uuid: string; severity: 'warning' | 'critical'; title: string
  source_kind: string; alert_type: string
  tenant_id: number | null; tenant_name: string
  last_triggered_at: string; occurrence_count: number
}
export type PlatformOverview = PlatformStats & {
  health: PlatformHealth
  top_alerts: PlatformTopAlert[]
}
// ---- F23 租户控制台概览 (口径见 docs/features/F23-tenant-console-overview.md) ----
export type TenantBilling = {
  plan_name: string; subscription_status: string; period_end: string
  credit_balance: number; wallet_frozen: boolean; month_credits_used: number
}
export type TenantHealth = {
  calls_24h: number; calls_failed_24h: number
  instances_total: number; instances_ready: number; instances_abnormal: number
}
export type TenantTodos = {
  draft_agents: number; cron_errors: number; kb_ingest_failed_7d: number; instances_abnormal: number
  // F25 增量: 未处理告警 / 待审批件
  alerts_firing: number; approvals_pending: number
}
export type TenantTrendPoint = {
  date: string; user_messages: number; agent_messages: number; active_accounts: number
}
export type TenantTopAgent = {
  name: string; conversations_7d: number; messages_7d: number; users_7d: number
}
export type TenantOverview = {
  members: number; departments: number; digital_employees: number; published: number
  conversations: number; messages_today: number
  conversations_today: number; active_members_7d: number; kb_count: number
  billing: TenantBilling | null
  health: TenantHealth
  todos: TenantTodos
  trend: TenantTrendPoint[]
  top_agents: TenantTopAgent[]
}
export const Stats = {
  platform: () => api<PlatformStats>('/api/admin/v1/platform/stats'),
  platformOverview: () => api<PlatformOverview>('/api/admin/v1/platform/overview'),
  tenantOverview: () => api<TenantOverview>('/api/admin/v1/tenant/overview'),
}

export type ClientAnalyticsPoint = { date: string; active_users: number }
export type ClientAnalyticsDimension = { key: string; active_users: number }
export type ClientAnalyticsTenant = {
  tenant_id: number
  tenant_name: string
  active_users: number
  last_active_at: string
}
export type ClientAnalyticsErrorPoint = {
  date: string
  error_count: number
  affected_users: number
}
export type ClientAnalyticsErrorGroup = {
  fingerprint: string
  error_type: string
  error_message: string
  source_location: string
  occurrences: number
  affected_users: number
  platforms: string
  app_versions: string
  archived: boolean
  last_seen_at: string
}
export type ClientAnalyticsAffectedAccount = {
  account_id: number
  account_uuid: string
  display_name: string
  tenant_id: number
  tenant_name: string
  occurrences: number
  last_seen_at: string
}
export type ClientAnalyticsErrorDetail = {
  fingerprint: string
  error_type: string
  error_message: string
  stacktrace: string
  mechanism: string
  severity: string
  platform: string
  app_version: string
  properties: Record<string, unknown>
  occurrences: number
  affected_users: number
  archived: boolean
  first_seen_at: string
  last_seen_at: string
  affected_accounts?: ClientAnalyticsAffectedAccount[]
}
export type ClientAnalyticsOverview = {
  generated_at: string
  timezone: string
  range_days: number
  dau: number
  wau: number
  mau: number
  stickiness_pct: number
  active_tenants_24h: number
  new_accounts_24h: number
  trend: ClientAnalyticsPoint[]
  platforms: ClientAnalyticsDimension[]
  versions: ClientAnalyticsDimension[]
  tenants: ClientAnalyticsTenant[]
  error_count: number
  error_users: number
  error_fingerprints: number
  error_trend: ClientAnalyticsErrorPoint[]
  top_errors: ClientAnalyticsErrorGroup[]
}
export const ClientAnalytics = {
  overview: (days: 7 | 30 | 90, includeArchived = false) =>
    api<ClientAnalyticsOverview>(
      `/api/admin/v1/platform/client-analytics/overview?days=${days}${includeArchived ? '&status=all' : ''}`
    ),
  errorDetail: (fingerprint: string) =>
    api<ClientAnalyticsErrorDetail>(`/api/admin/v1/platform/client-analytics/errors/${fingerprint}`),
  archiveError: (fingerprint: string) =>
    api<{ archived: boolean }>(`/api/admin/v1/platform/client-analytics/errors/${fingerprint}/archive`, {
      method: 'POST',
    }),
  unarchiveError: (fingerprint: string) =>
    api<{ archived: boolean }>(`/api/admin/v1/platform/client-analytics/errors/${fingerprint}/unarchive`, {
      method: 'POST',
    }),
}

// ---- runtimes ----

// M3 完整 Registration (PascalCase, 跟后端 Go json tag 一致)
export type Runtime = {
  ID: number; UUID: string; Code: string; Name: string; Description?: string
  Vendor?: string; Framework?: string
  AdapterKind: 'builtin' | 'plugin' | 'external'
  Endpoints?: Record<string, unknown>
  DataEgress: string
  EgressAuditStatus: 'pending' | 'approved' | 'rejected' | 'needs_revision'
  EgressAuditReason?: string
  Status: 'active' | 'disabled'
  LastHealthyAt?: string | null
  RateLimit?: Record<string, unknown>
  Metadata?: Record<string, unknown>
  EgressDocs?: Record<string, unknown>
  BoundAgents?: number
}

export type RuntimeInstance = {
  ID: number; UUID: string; TenantID: number; RuntimeID: number
  WorkloadInstanceID?: number | null
  TenantName?: string
  AccountName?: string
  AccountPhone?: string
  K8sNamespace?: string; K8sDeployment?: string; K8sService?: string
  ImageVersion?: string; TargetImageVersion?: string; EndpointURL?: string
  Status: string; LastHealthyAt?: string | null; ErrorMessage?: string
}

export const Runtimes = {
  list: (includeDisabled = false) =>
    api<{ items: Runtime[]; total: number }>(
      `/api/admin/v1/platform/runtimes${includeDisabled ? '?include_disabled=true' : ''}`
    ),
  get: (id: number) => api<Runtime>(`/api/admin/v1/platform/runtimes/${id}`),
  create: (body: Partial<Runtime>) =>
    api<Runtime>('/api/admin/v1/platform/runtimes', { method: 'POST', body: JSON.stringify(body) }),
  update: (id: number, body: Partial<Runtime>) =>
    api<Runtime>(`/api/admin/v1/platform/runtimes/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/runtimes/${id}`, { method: 'DELETE' }),
  healthCheck: (id: number) =>
    api<{ status: string; error?: string }>(`/api/admin/v1/platform/runtimes/${id}/health-check`, { method: 'POST' }),
  submitEgress: (id: number) =>
    api<Runtime>(`/api/admin/v1/platform/runtimes/${id}/egress/submit`, { method: 'POST' }),
  reviewEgress: (id: number, decision: 'approved' | 'rejected' | 'needs_revision', reason: string) =>
    api<Runtime>(`/api/admin/v1/platform/runtimes/${id}/egress/review`, {
      method: 'POST',
      body: JSON.stringify({ decision, reason }),
    }),
  instances: (id: number) =>
    api<{ items: RuntimeInstance[]; total: number }>(`/api/admin/v1/platform/runtimes/${id}/instances`),
}

// Batch 2C T2C.3: 给 tenant.admin Agent 创建/编辑下拉用的 runtime 选项 (只读, 不含 endpoints/api_key)。
export type RuntimeOption = {
  id: number
  uuid: string
  code: string
  name: string
  framework: string
  adapter_kind: string
}
export const RuntimeOptions = {
  list: () =>
    api<{ items: RuntimeOption[]; total: number }>(`/api/admin/v1/tenant/runtime-options`),
}

// ---- emp blocks ----

export type EMPBlock = {
  id: number; code: string; version: number; name: string
  category: 'content' | 'interactive' | 'process' | 'artifact'
  status: 'draft' | 'stable' | 'deprecated'
  min_client_version?: string; fallback_block_type: string
  description?: string; json_schema?: Record<string, unknown>
  breaking_changes?: string; deprecated_at?: string; eol_date?: string
  is_system?: boolean; created_at?: string; updated_at?: string
}
export const EMPBlocks = {
  list: () => api<{ items: EMPBlock[]; total: number }>('/api/admin/v1/platform/emp-blocks'),
}

// ---- M2 contact-policy ----

export type ContactPolicy = {
  tenantId: number
  defaultLanding: 'org_tree' | 'agent_plaza'
  defaultShowPhone: 'all' | 'department' | 'self' | 'hidden'
  defaultShowEmail: 'all' | 'department' | 'self' | 'hidden'
  defaultShowTitle: 'all' | 'department' | 'self' | 'hidden'
  searchScope: 'current_dept' | 'tenant' | 'tenant_plus_platform_agents'
  whoCanCreateGroupWithAgent: 'tenant_admin' | 'any_member' | 'disabled'
  agentsDefaultInvitable: boolean
  humansDefaultInvitable: boolean
  showPlatformAgents: boolean
}

export const ContactPolicyApi = {
  get: () => api<ContactPolicy>('/api/admin/v1/tenant/contact-policy'),
  update: (body: Partial<ContactPolicy>) =>
    api<ContactPolicy>('/api/admin/v1/tenant/contact-policy', {
      method: 'PUT',
      body: JSON.stringify(body),
    }),
}

// ---- M2 成员通讯录设置 ----

export type ContactFieldsInput = {
  hidden_in_contacts?: boolean
  allow_invite_to_group?: boolean
  field_mask?: {
    phone?: ContactFieldVisibility
    email?: ContactFieldVisibility
    title?: ContactFieldVisibility
  }
  position_label_override?: string
}

export type ContactFieldVisibility = 'all' | 'department' | 'self' | 'hidden'

export const MemberContactFields = {
  patch: (membershipID: number, body: ContactFieldsInput) =>
    api<MemberDetail>(`/api/admin/v1/tenant/members/${membershipID}/contact-fields`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
}

// ---- agent detail / CRUD ----

export type AgentFull = Agent & {
  execution_locus?: 'cloud' | 'local'
  local_engine?: 'dsh' | 'codex_app_server' | ''
  Intro: string; Description: string; WelcomeMsg: string
  Tags: string[] | null; ModelPrimary: string
  // ADR-0037 BYOK: model_source='byok' 时 ModelPrimary 为空，真正的模型信息在
  // ModelServiceConfigJSON 里（{endpoint_type, base_url, model_id}，不含密钥）。
  // ModelServiceAPIKeyPrefix 只是密钥前缀，用于后台展示"配置了哪把 key"，绝不是明文；
  // 密钥本身按设计只有数字员工创建者能在客户端写入，后台只读展示这几个字段。
  ModelSource?: 'platform_whitelist' | 'byok' | string
  ModelServiceConfigJSON?: string
  ModelServiceAPIKeyPrefix?: string
  Temperature: number; ContextWindow: number
  RuntimeEnvironmentID: number | null
  Metadata?: Record<string, unknown> | null
  UpdatedAt?: string
  IsDefaultForCreator: boolean
  SupportsGroupChat: boolean
  CallableByAgents: boolean
  // M2 通讯录字段
  PositionLabel?: string
  Badges?: string[]
  Source?: 'enterprise' | 'personal' | 'platform'
  ContactEnabled?: boolean
  AllowInviteToGroup?: boolean
  WorkspaceID?: number | null
  TenantHidden?: boolean
  TenantSortOrder?: number
  // 工具权限（dsh 运行时装配层门控）：allow 空数组 = 跟随平台安全默认（命令执行关闭、其余开启）；
  // 非空 = 纯白名单，只启用列出的组。可选值 bash/fs/skill/platform，后端 fail-closed 校验。
  ToolAllow?: string[] | null
  ToolDeny?: string[] | null
}
export type CreateAgentInput = Partial<AgentFull> & {
  runtime_environment_uuid?: string | null
}
export type MediaUploadResult = {
  storage_key: string
  storage_uri: string
  signed_url: string
  size_bytes: number
  sha256: string
}
export const MediaAdmin = {
  preview: (uris: string[]) =>
    api<{ items: { storage_uri: string; preview_url: string }[] }>('/api/admin/v1/tenant/media/preview', {
      method: 'POST',
      body: JSON.stringify({ uris }),
    }),
}
export type AgentBinding = {
  ID: number; DigitalEmpID: number
  CapabilityKind: string; CapabilityUUID: string
  Source: 'self' | 'borrow'
  GrantedTools?: string[] | null; GrantedScopes?: string[] | null
  Pinned: boolean; SortOrder: number
}
// doc-15 P1：租户「从模板创建」picker 的只读模板 DTO（后端白名单，不含 runtime token/endpoint）。
export interface TenantAgentTemplate {
  uuid: string
  name: string
  position_label: string
  intro: string
  description: string
  avatar_url: string
  avatar_preview_url?: string
  welcome_msg?: string
  system_prompt?: string
  runtime_environment_id?: number | null
  execution_locus?: string
  local_engine?: 'dsh' | 'codex_app_server' | ''
  updated_at?: string
  knowledge_bases?: Array<{ uuid: string; name: string }> | null
  tags: string[] | null
  model_primary: string
  agent_kind: string // single / orchestrator
  orchestration?: { strategy: string; child_template_uuids: string[] | null } | null
  skill_uuids: string[] | null
  app_uuids: string[] | null
}

// doc-15 P1/P6：租户后台「从模板创建」的数据源——平台已发布模板（取代旧的本地示例假数据）。
// list 支持后端分页/搜索/类型筛选；get 取单个模板用于新建页精确预填（fail-closed：非已发布平台模板 404）。
export const TenantAgentTemplates = {
  list: (params: { limit?: number; offset?: number; q?: string; kind?: string } = {}) => {
    const qs = new URLSearchParams()
    if (params.limit != null) qs.set('limit', String(params.limit))
    if (params.offset != null) qs.set('offset', String(params.offset))
    if (params.q?.trim()) qs.set('q', params.q.trim())
    if (params.kind) qs.set('kind', params.kind)
    const suffix = qs.toString() ? `?${qs.toString()}` : ''
    return api<{ items: TenantAgentTemplate[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/tenant/agent-templates${suffix}`,
    )
  },
  get: (uuid: string) =>
    api<TenantAgentTemplate>(`/api/admin/v1/tenant/agent-templates/${encodeURIComponent(uuid)}`),
}

export interface AgentCreatorDistributionItem {
  creator_id: number
  creator_name: string
  count: number
}

export const AgentsAdmin = {
  list: (limit = 50, offset = 0, params: { creator_id?: string; source?: 'platform' | 'enterprise' | 'personal' } = {}) =>
    api<{ items: AgentFull[]; total: number }>(
      `/api/admin/v1/tenant/agents?limit=${limit}&offset=${offset}${params.source ? `&source=${encodeURIComponent(params.source)}` : ''}${params.creator_id ? `&creator_id=${encodeURIComponent(params.creator_id)}` : ''}`,
    ),
  creatorDistribution: () =>
    api<{ items: AgentCreatorDistributionItem[] }>('/api/admin/v1/tenant/agents/creator-distribution'),
  get: (uuid: string) =>
    api<{ agent: AgentFull; bindings: AgentBinding[] | null }>(`/api/admin/v1/tenant/agents/${uuid}`),
  create: (body: CreateAgentInput & AgentEditorSaveBindingsInput) =>
    api<AgentFull>('/api/admin/v1/tenant/agents', { method: 'POST', body: JSON.stringify(body) }),
  update: (uuid: string, body: Partial<AgentFull> & AgentEditorSaveBindingsInput) =>
    api<AgentFull>(`/api/admin/v1/tenant/agents/${uuid}`, { method: 'PUT', body: JSON.stringify(body) }),
  uploadAvatar: async (file: File, uuid?: string, scope: 'tenant' | 'platform' = 'tenant') => {
    const fd = new FormData()
    fd.append('file', file)
    void uuid
    const path = scope === 'platform'
      ? '/api/admin/v1/platform/media/agent-avatars/upload'
      : '/api/admin/v1/tenant/media/agent-avatars/upload'
    return api<MediaUploadResult>(path, { method: 'POST', body: fd })
  },
  remove: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/agents/${uuid}`, { method: 'DELETE' }),
  // M3 §3.2.2 + Batch 2C T2C.3: publish 升级为快照 + current_version + OpenClaw 同步, body 可选 notes
  publish: (uuid: string, notes?: string) =>
    api<{ agent: AgentFull; version: AgentVersion }>(
      `/api/admin/v1/tenant/agents/${uuid}/publish`,
      { method: 'POST', body: JSON.stringify({ notes: notes || '' }) }
    ),
  // Batch 2C T2C.3: 下架 = status archived + 同步 OpenClaw agents delete + RemoveDir; 复用 publish perm
  unpublish: (uuid: string) =>
    api<{ agent: AgentFull }>(
      `/api/admin/v1/tenant/agents/${uuid}/unpublish`,
      { method: 'POST' }
    ),
  setVisibilityOverride: (uuid: string, hidden: boolean, sortOrder = 0) =>
    api<{ ok: boolean; hidden: boolean; sortOrder: number }>(
      `/api/admin/v1/tenant/agents/${uuid}/visibility-override`,
      { method: 'PUT', body: JSON.stringify({ hidden, sortOrder }) }
    ),
  // M3 §6.2 草稿 capabilities (borrow)
  listBindings: (uuid: string) =>
    api<{ items: AgentBinding[]; total: number }>(`/api/admin/v1/tenant/agents/${uuid}/capabilities`),
  addBinding: (uuid: string, body: { capability_kind: string; capability_uuid: string; granted_tools?: string[]; granted_scopes?: string[]; sort_order?: number; pinned?: boolean }) =>
    api<AgentBinding>(`/api/admin/v1/tenant/agents/${uuid}/capabilities`, { method: 'POST', body: JSON.stringify({ ...body, source: 'borrow' }) }),
  removeBinding: (uuid: string, bindingId: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/agents/${uuid}/capabilities/${bindingId}`, { method: 'DELETE' }),

  // M3 §6.2 版本 / 灰度 / 回滚
  versions: (uuid: string) =>
    api<{ items: AgentVersion[]; current_version: number }>(`/api/admin/v1/tenant/agents/${uuid}/versions`),
  gray: (uuid: string, ver: number, pct: number, groups: string[]) =>
    api<AgentVersion>(`/api/admin/v1/tenant/agents/${uuid}/versions/${ver}/gray`, {
      method: 'POST', body: JSON.stringify({ grayscale_pct: pct, grayscale_groups: groups }),
    }),
  rollback: (uuid: string, ver: number) =>
    api<AgentFull>(`/api/admin/v1/tenant/agents/${uuid}/versions/${ver}/rollback`, { method: 'POST' }),

  // M3 §6.2 A2A 白名单
  listCallable: (uuid: string) =>
    api<{ items: CallableEntry[]; total: number }>(`/api/admin/v1/tenant/agents/${uuid}/callable-whitelist`),
  addCallable: (uuid: string, callerUUID: string, note?: string) =>
    api<CallableEntry>(`/api/admin/v1/tenant/agents/${uuid}/callable-whitelist`, {
      method: 'POST', body: JSON.stringify({ caller_uuid: callerUUID, note: note || '' }),
    }),
  removeCallable: (uuid: string, entryId: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/agents/${uuid}/callable-whitelist/${entryId}`, { method: 'DELETE' }),

  // M3 §6.2 sandbox
  sandboxPrompt: (uuid: string, text: string) =>
    api<SandboxResult>(`/api/admin/v1/tenant/agents/${uuid}/sandbox-prompt`, {
      method: 'POST', body: JSON.stringify({ text }),
    }),

  // M3 §6.3 平台预置能力池
  catalog: (kind: 'composer_skill' | 'background_skill' | 'mcp' | 'knowledge_base') =>
    api<{ items: CatalogItem[]; total: number }>(`/api/admin/v1/tenant/capability-catalog?kind=${kind}`),
}

export type A2AApprovalStatus = 'pending' | 'approved' | 'rejected' | 'expired' | 'cancelled'

export interface A2AApprovalItem {
  id: string
  edge_id: string
  edge_created_at: string
  from_agent_id?: string
  from_agent_name?: string
  to_agent_id?: string
  to_agent_name?: string
  status: A2AApprovalStatus
  invoke_kind?: string
  request_payload?: unknown
  form_schema?: unknown
  form_result?: unknown
  reason?: string
  expires_at?: string
  decided_at?: string
  decided_by_account_id?: number
  created_at: string
}

// ===== F25 告警中心 =====

export type AlertScope = 'platform' | 'tenant'
export type AlertStatus = 'firing' | 'acknowledged' | 'resolved'
export type AlertSeverity = 'warning' | 'critical'

export type AlertItem = {
  uuid: string
  scopeKind: AlertScope
  tenantId?: number | null
  tenantName?: string
  sourceKind: string
  alertType: string
  severity: AlertSeverity
  status: AlertStatus
  title: string
  summary: string
  resourceKind: string
  resourceUuid: string
  firstTriggeredAt: string
  lastTriggeredAt: string
  occurrenceCount: number
  acknowledgedBy?: number | null
  acknowledgedAt?: string | null
  resolvedAt?: string | null
  resolvedBy?: number | null
  context: Record<string, unknown>
}

export type AlertListParams = {
  status?: string
  severity?: string
  source_kind?: string
  alert_type?: string
  tenant_id?: number
  // 仅平台侧：true 时包含租户经营类告警（配额/积分不足/订阅到期，默认排除）
  include_tenant_ops?: boolean
  from?: string
  to?: string
  limit?: number
  offset?: number
}

const alertBase = (scope: AlertScope) => `/api/admin/v1/${scope}/alerts`

export const Alerts = {
  list: (scope: AlertScope, params: AlertListParams = {}) => {
    const qs = new URLSearchParams()
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== null && v !== '') qs.set(k, String(v))
    }
    const suffix = qs.toString() ? `?${qs.toString()}` : ''
    return api<{ items: AlertItem[]; total: number }>(`${alertBase(scope)}${suffix}`)
  },
  get: (scope: AlertScope, uuid: string) =>
    api<AlertItem>(`${alertBase(scope)}/${encodeURIComponent(uuid)}`),
  unhandledCount: (scope: AlertScope) =>
    api<{ count: number }>(`${alertBase(scope)}/unhandled-count`),
  acknowledge: (scope: AlertScope, uuid: string) =>
    api<AlertItem>(`${alertBase(scope)}/${encodeURIComponent(uuid)}/acknowledge`, { method: 'POST', body: '{}' }),
  resolve: (scope: AlertScope, uuid: string, reason: string) =>
    api<AlertItem>(`${alertBase(scope)}/${encodeURIComponent(uuid)}/resolve`, {
      method: 'POST',
      body: JSON.stringify({ reason }),
    }),
}

export const A2AApprovalsAdmin = {
  list: (params: { status?: string; limit?: number; offset?: number } = {}) => {
    const qs = new URLSearchParams()
    if (params.status) qs.set('status', params.status)
    if (params.limit != null) qs.set('limit', String(params.limit))
    if (params.offset != null) qs.set('offset', String(params.offset))
    const suffix = qs.toString() ? `?${qs.toString()}` : ''
    return api<{ items: A2AApprovalItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/tenant/a2a/approvals${suffix}`,
    )
  },
  get: (approvalRequestID: string) =>
    api<A2AApprovalItem>(`/api/admin/v1/tenant/a2a/approvals/${encodeURIComponent(approvalRequestID)}`),
  decide: (approvalRequestID: string, body: { decision: 'approved' | 'rejected'; reason?: string; form_result?: unknown }) =>
    api<{
      approval_request_id: string
      edge_id: string
      edge_created_at: string
      approval_status: A2AApprovalStatus
      edge_status: string
    }>(`/api/admin/v1/tenant/a2a/approvals/${encodeURIComponent(approvalRequestID)}/decide`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
}

export type AgentEditorSaveBindingsInput = Partial<{
  position_ids: number[]
  primary_position_id: number | null
  skill_uuids: string[]
  app_uuids: string[]
  kb_uuids: string[]
}>

export const PlatformPresetAgentsAdmin = {
  list: (limit = 20, offset = 0, q = '', status = '') => {
    const params = new URLSearchParams()
    params.set('limit', String(limit))
    params.set('offset', String(offset))
    if (q.trim()) params.set('q', q.trim())
    if (status) params.set('status', status)
    return api<{ items: AgentFull[]; total: number }>(
      `/api/admin/v1/platform/preset-agents?${params.toString()}`,
    )
  },
  create: (body: CreateAgentInput & { skill_uuids?: string[]; app_uuids?: string[] }) =>
    api<AgentFull>('/api/admin/v1/platform/preset-agents', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  get: (uuid: string) =>
    api<{ agent: AgentFull; bindings: AgentBinding[] | null }>(`/api/admin/v1/platform/preset-agents/${uuid}`),
  update: (uuid: string, body: Partial<AgentFull> & { skill_uuids?: string[]; app_uuids?: string[] }) =>
    api<AgentFull>(`/api/admin/v1/platform/preset-agents/${uuid}`, {
      method: 'PUT',
      body: JSON.stringify(body),
    }),
  remove: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/preset-agents/${uuid}`, { method: 'DELETE' }),
  publish: (uuid: string, notes?: string) =>
    api<{ agent: AgentFull; version: AgentVersion }>(`/api/admin/v1/platform/preset-agents/${uuid}/publish`, {
      method: 'POST',
      body: JSON.stringify({ notes: notes || '' }),
    }),
  unpublish: (uuid: string) =>
    api<{ agent: AgentFull }>(`/api/admin/v1/platform/preset-agents/${uuid}/unpublish`, { method: 'POST' }),
}

export type PlatformPresetKBBinding = {
  agent_uuid: string
  kb_uuid: string
  kb_name: string
  binding_kind: string
  priority: number
}

export const PlatformPresetKBBindings = {
  list: (agentUuid: string) =>
    api<{ items: PlatformPresetKBBinding[] }>(
      `/api/admin/v1/platform/preset-agents/${encodeURIComponent(agentUuid)}/kb-bindings`,
    ),
  replace: (agentUuid: string, kbUuids: string[], expectedAgentUpdatedAt: string) =>
    api<{ agent_uuid: string; kb_uuids: string[]; agent_updated_at: string }>(
      `/api/admin/v1/platform/preset-agents/${encodeURIComponent(agentUuid)}/kb-bindings`,
      { method: 'PUT', body: JSON.stringify({ kb_uuids: kbUuids, expected_agent_updated_at: expectedAgentUpdatedAt }) },
    ),
}

// M3 类型
export type AgentVersion = {
  ID: number; DigitalEmpID: number; Version: number
  Status: 'draft' | 'published' | 'grayed' | 'rolled_back' | 'archived'
  GrayscalePct: number; GrayscaleGroups: string[] | null
  Notes?: string
  PublishedBy?: number | null; PublishedAt?: string | null
  CreatedAt: string; UpdatedAt: string
  Snapshot?: Record<string, unknown>
}

export type CallableEntry = {
  ID: number; CalleeID: number; CallerID: number
  GrantedBy?: number | null; Note?: string; CreatedAt: string
  CallerUUID?: string; CallerName?: string
}

export type SandboxResult = {
  run_id: number; run_uuid: string
  output_text: string
  output_blocks?: Array<Record<string, unknown>>
  tool_calls?: Array<Record<string, unknown>>
  kb_citations?: Array<Record<string, unknown>>
  usage?: { input_tokens?: number; output_tokens?: number; cost_usd?: number }
  finish_reason?: string
  status: string
  transcript: Array<{ role: string; content: string; ts: string; tokens?: Record<string, number> }>
}

export type CatalogItem = {
  kind: string; uuid: string; code?: string; name: string
  description?: string; vendor?: string; category?: string
}

// ---- try chat ----

export type TryChatSendResp = {
  conversation_uuid: string; stream_id: string; user_message_uuid: string
}
export type TryChatEvent = {
  kind: 'delta' | 'final' | 'error' | 'block'
  text?: string; blocks?: Array<Record<string, unknown>>
  final?: boolean; error?: string; ts?: string
}
export const TryChat = {
  send: (agent_uuid: string, text: string, conversation_uuid?: string) =>
    api<TryChatSendResp>('/api/admin/v1/tenant/try-chat/send', {
      method: 'POST',
      body: JSON.stringify({ agent_uuid, text, conversation_uuid }),
    }),
  streamURL: (stream_id: string) =>
    `/api/admin/v1/tenant/try-chat/stream?stream_id=${encodeURIComponent(stream_id)}&token=${encodeURIComponent(auth.token())}`,
}

// ---- M8B KB Providers (Codex round-5) ----
//
// 列表 / 新建 / 编辑 / 删除 / 设默认 / 健康检查; 后端权限 platform.kb_provider.read|manage.
// KB provider secret_ref 由表单层转换；用户不需要手写 env:// / value://.

export type KBProvider = {
  provider_uuid: string
  provider_kind: 'stub' | 'dify' | 'tablestore' | 'ragflow'
  name: string
  endpoint_url?: string
  api_key_ref?: string
  settings?: Record<string, unknown>
  admin_email?: string
  is_default: boolean
  status: 'active' | 'degraded' | 'disabled' | string
}

export type KBProviderCreateInput = {
  provider_kind: 'stub' | 'dify' | 'tablestore' | 'ragflow'
  name: string
  endpoint_url?: string
  api_key_ref?: string
  settings?: Record<string, unknown>
  is_default?: boolean
}

export type KBProviderPatchInput = {
  name?: string
  endpoint_url?: string
  api_key_ref?: string
  settings?: Record<string, unknown>
  /** 仅允许 'active' / 'disabled' (启用/禁用), degraded 由健康检查自动写。 */
  status?: 'active' | 'disabled'
}

export type KBProviderHealthResp = {
  provider_uuid: string
  status: string
  message: string
  health_error?: string
}

export const KBProviders = {
  list: () => api<{ items: KBProvider[] }>('/api/admin/v1/platform/kb-providers'),
  create: (body: KBProviderCreateInput) =>
    api<KBProvider>('/api/admin/v1/platform/kb-providers', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: KBProviderPatchInput) =>
    api<KBProvider>(`/api/admin/v1/platform/kb-providers/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  remove: (uuid: string) =>
    api<{ provider_uuid: string; deleted: boolean }>(
      `/api/admin/v1/platform/kb-providers/${encodeURIComponent(uuid)}`,
      { method: 'DELETE' },
    ),
  setDefault: (uuid: string) =>
    api<KBProvider>(
      `/api/admin/v1/platform/kb-providers/${encodeURIComponent(uuid)}/set-default`,
      { method: 'POST' },
    ),
  healthCheck: (uuid: string) =>
    api<KBProviderHealthResp>(
      `/api/admin/v1/platform/kb-providers/${encodeURIComponent(uuid)}/health-check`,
      { method: 'POST' },
    ),
  // F07 平台 admin 写 RAGFlow admin 凭证 (admin_email + admin_password_plain → backend AES-GCM 加密)
  setRagflowCredentials: (uuid: string, admin_email: string, admin_password_plain: string) =>
    api<{ provider_uuid: string; admin_email: string; message: string }>(
      `/api/admin/v1/platform/kb-providers/${encodeURIComponent(uuid)}/ragflow-credentials`,
      { method: 'PUT', body: JSON.stringify({ admin_email, admin_password_plain }) },
    ),
}

// ===== F07 §5.1 监控运维 (RAGFlow ops) =====

export type RagflowHealth = {
  provider_uuid?: string
  provider_name?: string
  config_present: boolean
  admin_ok: boolean
  api_ok: boolean
  bindings_total: number
  bindings_active: number
  bindings_pending: number
  bindings_failed: number
  bindings_deactivated: number
  outbox_pending: number
  outbox_failed: number
  outbox_dlq: number
  message: string
  checked_at: string
  admin_latency_ms: number
  api_latency_ms: number
}

export type RagflowBinding = {
  tenant_id: number
  tenant_name: string
  ragflow_email: string
  ragflow_user_id: string
  api_key_prefix: string
  api_key_version: number
  status: 'pending' | 'active' | 'failed' | 'deactivated' | 'pending_cleanup' | string
  provisioned_at?: string
  deactivated_at?: string
  last_used_at?: string
  error_msg?: string
  created_at: string
}

export type RagflowKBOverviewRow = {
  tenant_id: number
  tenant_name: string
  kb_total: number
  kb_tenant_level: number
  kb_personal: number
  document_total: number
}

export type KBOutboxEvent = {
  uuid: string
  occurred_at: string
  tenant_id?: number
  tenant_name: string
  scope_kind: 'platform' | 'tenant' | string
  kb_id?: number
  op: string
  status: 'pending' | 'running' | 'done' | 'failed' | 'dlq' | 'discarded' | string
  attempts: number
  next_retry_at: string
  last_error?: string
  completed_at?: string
  locked_by?: string
  locked_until?: string
  lock_expired: boolean
  payload: unknown
  created_at: string
  updated_at: string
}

export type PagedResp<T> = { items: T[]; total: number; limit: number; offset: number }

function pagedQuery(params: Record<string, string | number | undefined>) {
  const qs = Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== '')
    .map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`)
    .join('&')
  return qs ? `?${qs}` : ''
}

export const RagflowOpsAPI = {
  health: (providerUUID?: string) =>
    api<RagflowHealth>(`/api/admin/v1/platform/ragflow-health${pagedQuery({ provider_uuid: providerUUID })}`),
  listBindings: (params: { limit: number; offset: number; status?: string; q?: string }) =>
    api<PagedResp<RagflowBinding>>(`/api/admin/v1/platform/ragflow-bindings${pagedQuery(params)}`),
  reconcileBinding: (tenantId: number) =>
    api<{ event_uuid: string; status: string; message: string }>(
      `/api/admin/v1/platform/ragflow-bindings/${tenantId}/reconcile`,
      { method: 'POST' },
    ),
  kbOverview: () =>
    api<{ items: RagflowKBOverviewRow[] }>('/api/admin/v1/platform/knowledge-bases-overview'),
  listOutboxEvents: (params: { limit: number; offset: number; status?: string; op?: string; tenant_id?: number }) =>
    api<PagedResp<KBOutboxEvent>>(`/api/admin/v1/platform/kb-outbox-events${pagedQuery(params)}`),
  retryOutboxEvent: (uuid: string) =>
    api<{ uuid: string; status: string; message: string }>(
      `/api/admin/v1/platform/kb-outbox-events/${encodeURIComponent(uuid)}/retry`,
      { method: 'POST' },
    ),
  discardOutboxEvent: (uuid: string) =>
    api<{ uuid: string; status: string; message: string }>(
      `/api/admin/v1/platform/kb-outbox-events/${encodeURIComponent(uuid)}/discard`,
      { method: 'POST' },
    ),
}

export type PlatformModelCapability = 'embedding' | 'rerank'

export type PlatformModelOption = {
  id: string
  name: string
  capabilities: string[]
  source: 'aigc_gateway' | string
}

export const PlatformModelOptions = {
  list: (capability: PlatformModelCapability) =>
    api<{ items: PlatformModelOption[]; capability: string; source: string; warning?: string }>(
      `/api/admin/v1/platform/model-options?capability=${encodeURIComponent(capability)}`,
    ),
}

export type AgentModelOption = {
  id: string
  label: string
  default?: boolean
}

export const AgentModelOptions = {
  tenant: () => api<{ items: AgentModelOption[] }>('/api/admin/v1/tenant/agent-model-options'),
  platform: () => api<{ items: AgentModelOption[] }>('/api/admin/v1/platform/agent-model-options'),
}

// ---- F07 数字员工 KB 绑定 ----
export type AgentKBBinding = {
  agent_uuid: string
  kb_uuid: string
  kb_name: string
  binding_kind: 'attached' | 'required' | 'optional'
  priority: number
  note?: string
  created_at: string
  space_kind: string
  managed_by: 'platform' | 'tenant'
  editable: boolean
  kb_status: string
}

export const AgentKBBindings = {
  list: (agent_uuid: string) =>
    api<{ items: AgentKBBinding[] }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agent_uuid)}/kb-bindings`,
    ),
  attach: (agent_uuid: string, kb_uuid: string, binding_kind: 'attached' | 'required' | 'optional' = 'attached', priority = 0, note = '') =>
    api<{ agent_uuid: string; kb_uuid: string; binding_kind: string; priority: number }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agent_uuid)}/kb-bindings`,
      { method: 'POST', body: JSON.stringify({ kb_uuid, binding_kind, priority, note }) },
    ),
  detach: (agent_uuid: string, kb_uuid: string) =>
    api<{ detached: boolean }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agent_uuid)}/kb-bindings/${encodeURIComponent(kb_uuid)}`,
      { method: 'DELETE' },
    ),
}

// ---- F07 D13 跨用户查私有 KB (admin web JWT 路径) ----
export type UserPrivateKB = {
  uuid: string
  name: string
  description?: string
  space_kind: string
  visibility: string
  status: string
  total_documents: number
  creator_id: number
  created_at: string
  updated_at: string
}

export const UserKBInspect = {
  list: (user_uuid: string) =>
    api<{ items: UserPrivateKB[] }>(
      `/api/admin/v1/tenant/users/${encodeURIComponent(user_uuid)}/knowledge-bases`,
    ),
}

// ---- F07 R-2.3 文档解析失败 retry + 列文档 ----
export interface KBDocumentItem {
  uuid: string
  kb_uuid: string
  kb_folder_uuid?: string
  title: string
  mime_type?: string
  file_size: number
  chunk_count: number
  status: string
  error_message?: string
  created_at: string
  updated_at?: string
}

export const KBDocumentOps = {
  // 分页 list; limit 默认后端 50, 上限 500; offset 默认 0。
  list: (kb_uuid: string, opts?: { limit?: number; offset?: number }) => {
    const qs = new URLSearchParams()
    if (opts?.limit != null) qs.set('limit', String(opts.limit))
    if (opts?.offset != null) qs.set('offset', String(opts.offset))
    const q = qs.toString() ? `?${qs}` : ''
    return api<{ items: KBDocumentItem[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/tenant/knowledge-bases/${encodeURIComponent(kb_uuid)}/documents${q}`,
    )
  },
  retry: (kb_uuid: string, doc_uuid: string) =>
    api<{ status: string; message: string }>(
      `/api/admin/v1/tenant/knowledge-bases/${encodeURIComponent(kb_uuid)}/documents/${encodeURIComponent(doc_uuid)}/retry`,
      { method: 'POST' },
    ),
}

// ---- Agent Step 6: capabilities binding (composer / app / kb) ----
//
// 后端字段 (round-6 P1-3): list 走 Agent.Bindings() 返 CapabilityBinding (PascalCase 序列化:
// ID / DigitalEmpID / CapabilityKind / CapabilityUUID / Source / GrantedTools / GrantedScopes /
// Pinned / SortOrder). available 端点返 snake_case
// {capability_kind, capability_uuid, code, label, icon, ...} + 顶部 cron_supported /
// cron_supported_reason. 这里 adapter 归一化成统一 AgentCapability 给页面.
//
// Cron 不是一个 binding kind (后端 binding 枚举: composer_skill / app / knowledge_base /
// background_skill / mcp_server). cron 能力开关在 available 返回顶部体现, 单独展示.

export type AgentCapabilityKind = 'composer_skill' | 'app' | 'knowledge_base'

// AgentCapability 统一前端 DTO (页面用); list / available / attach / patch 都用它.
export type AgentCapability = {
  binding_id?: number
  kind: AgentCapabilityKind
  resource_uuid: string
  resource_label: string
  pinned?: boolean
  sort_order?: number
  source?: 'self' | 'borrow'
  default_pinned?: boolean
  exec_kind?: 'platform_backchannel' | 'agent_routed'
  display_mode?: string
}

// AvailableResp · /capabilities/available 后端原始响应顶部.
// F02 v0.3 (ADR-0012): integration_mode 字段已删, cron_supported 改纯 runtime
// framework 维度判定。
export type AgentCapabilitiesAvailable = {
  items: AgentCapability[]
  cron_supported: boolean
  cron_supported_reason: string
}

// 后端原始 binding 行 (PascalCase, 与 Go default JSON 一致).
type rawBinding = {
  ID: number
  DigitalEmpID: number
  CapabilityKind: AgentCapabilityKind | string
  CapabilityUUID: string
  Source: 'self' | 'borrow'
  Pinned: boolean
  SortOrder: number
}

// 后端原始 available 行.
type rawAvailable = {
  capability_kind: string
  capability_uuid: string
  label?: string
  code?: string
  default_pinned?: boolean
  exec_kind?: string
  display_mode?: string
}

function normalizeBinding(r: rawBinding): AgentCapability {
  return {
    binding_id: r.ID,
    kind: r.CapabilityKind as AgentCapabilityKind,
    resource_uuid: r.CapabilityUUID,
    resource_label: r.CapabilityUUID, // list 端点不返 label; 页面 fallback 显示 uuid
    pinned: r.Pinned,
    sort_order: r.SortOrder,
    source: r.Source,
  }
}

function normalizeAvailable(r: rawAvailable): AgentCapability {
  return {
    kind: r.capability_kind as AgentCapabilityKind,
    resource_uuid: r.capability_uuid,
    resource_label: r.label || r.code || r.capability_uuid,
    default_pinned: r.default_pinned,
    exec_kind: r.exec_kind as 'platform_backchannel' | 'agent_routed' | undefined,
    display_mode: r.display_mode,
  }
}

export const AgentCapabilities = {
  // list 返回 Agent.Bindings(); 各 row 适配后给页面.
  list: async (agentUUID: string): Promise<{ items: AgentCapability[] }> => {
    const r = await api<{ items: rawBinding[]; total: number }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities`,
    )
    return { items: (r.items || []).map(normalizeBinding) }
  },
  available: async (agentUUID: string): Promise<AgentCapabilitiesAvailable> => {
    const r = await api<{
      items: rawAvailable[]
      cron_supported: boolean
      cron_supported_reason: string
    }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities/available`,
    )
    return {
      items: (r.items || []).map(normalizeAvailable),
      cron_supported: r.cron_supported,
      cron_supported_reason: r.cron_supported_reason,
    }
  },
  // 后端 PATCH 接 {pinned?, sort_order?}; display_mode 留 follow-up.
  patch: async (agentUUID: string, bindingID: number, body: { pinned?: boolean; sort_order?: number }) => {
    return api<{ ok: boolean; id: number }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities/${bindingID}`,
      { method: 'PATCH', body: JSON.stringify(body) },
    )
  },
  // attach 必须发 capability_kind / capability_uuid (round-6 P1-3 修复).
  attach: async (agentUUID: string, body: { kind: AgentCapabilityKind; resource_uuid: string }) => {
    const r = await api<rawBinding>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities`,
      {
        method: 'POST',
        body: JSON.stringify({
          capability_kind: body.kind,
          capability_uuid: body.resource_uuid,
          source: 'borrow',
        }),
      },
    )
    return normalizeBinding(r)
  },
  detach: (agentUUID: string, bindingID: number) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities/${bindingID}`,
      { method: 'DELETE' },
    ),
  resetDefaults: async (agentUUID: string): Promise<{ items: AgentCapability[] }> => {
    const r = await api<{ items: rawAvailable[]; total: number }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/capabilities/reset-defaults`,
      { method: 'POST' },
    )
    return { items: (r.items || []).map(normalizeAvailable) }
  },
  refreshAgentCard: (agentUUID: string, capabilities?: Record<string, unknown>) =>
    api<{ agent_uuid: string; capabilities_declared: Record<string, unknown> }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/agent-card/refresh`,
      { method: 'POST', body: JSON.stringify({ capabilities: capabilities || {} }) },
    ),
}

// ---- Cron capability dry-run (后端: platform.cron.read) ----
//
// 平台侧只把 capability-dry-run 作为 /cron-dashboard「能力冲突」模块的数据源。
// 跨租户强停 / 恢复 / 立即执行不在平台页做, 需要切到对应租户的任务功能处理。

export type CronDryRunConflict = {
  job_uuid: string
  account_id: number
  tenant_id: number
  agent_uuid: string
  name: string
  reason: string
  next_run_at?: string
}

export type CronDryRunReport = {
  total_enabled: number
  conflicts: CronDryRunConflict[] | null
}

export const CronAdmin = {
  dryRun: (limit = 1000) =>
    api<CronDryRunReport>(
      `/api/admin/v1/platform/cron/capability-dry-run?limit=${limit}`,
    ),
}

// ---- F08 §5.1 / L · 租户后台 Cron 任务列表 (/cron) ----
//
// 后端端点:
//   GET    /api/admin/v1/tenant/cron-jobs                          → list (无分页参数, 上限 200)
//   POST   /api/admin/v1/tenant/cron-jobs/{uuid}/force-disable    → 强停 (set admin_disabled)
//   POST   /api/admin/v1/tenant/cron-jobs/{uuid}/clear-admin-flag → 清强停标 (不自动 resume)
//
// 权限: read=tenant.agent.read, write=tenant.agent.update.
// 严格走 admin scope; 不要复用 Bus client API (/api/agent-bus/v1/cron/*).
//
// DTO 与 services/agent-bus/internal/service/cron/service.go::JobDTO 对齐;
// 字段顺序保持一致便于 grep.

export type CronJobStatus = 'active' | 'paused' | 'error' | 'archived'
export type CronPauseReason =
  | 'admin_disabled'
  | 'owner_inactive'
  | 'quota_exceeded'
  | 'user_paused'
export type CronDeliveryKind = 'direct' | 'group'

export type CronJobAdminDTO = {
  uuid: string
  name: string
  description?: string
  agent_uuid: string
  schedule_cron: string
  timezone: string
  payload?: Record<string, unknown>
  delivery: Record<string, unknown>
  enabled: boolean
  status: CronJobStatus
  scheduler_kind: string
  consecutive_failures: number
  failure_threshold: number
  last_run_at?: string
  last_run_status?: string
  last_run_summary?: string
  next_run_at?: string
  admin_disabled: boolean
  created_at: string
  updated_at: string
  // L 增量
  owner_account_id: number
  pause_reason?: CronPauseReason | ''
  delivery_kind?: CronDeliveryKind | ''
  owner_inactive_at?: string
  // 2026-06-12 显示名 (后端批查回填; 缺省回退 id/uuid)
  owner_display_name?: string
  agent_name?: string
}

// F25 返修：租户任务详情附带净化运行记录（状态/触发/耗时/错误摘要，无 prompt 正文）
export type CronRunAdminDTO = {
  uuid: string
  status: string
  trigger_kind: string
  started_at: string
  finished_at?: string | null
  duration_ms?: number
  error_message?: string
  retry_count?: number
}

export const CronJobsAdmin = {
  list: () =>
    api<{ items: CronJobAdminDTO[] }>(
      `/api/admin/v1/tenant/cron-jobs`,
    ),
  detail: (uuid: string, runLimit = 20) =>
    api<{ job: CronJobAdminDTO; runs: CronRunAdminDTO[] }>(
      `/api/admin/v1/tenant/cron-jobs/${encodeURIComponent(uuid)}?run_limit=${runLimit}`,
    ),
  forceDisable: (uuid: string) =>
    api<CronJobAdminDTO>(
      `/api/admin/v1/tenant/cron-jobs/${encodeURIComponent(uuid)}/force-disable`,
      { method: 'POST' },
    ),
  clearAdminFlag: (uuid: string) =>
    api<CronJobAdminDTO>(
      `/api/admin/v1/tenant/cron-jobs/${encodeURIComponent(uuid)}/clear-admin-flag`,
      { method: 'POST' },
    ),
}

// ---- F08 §5.1/§5.3 · 平台跨租户定时任务列表/统计看板 (platform scope, 只读) ----

export type PlatformCronJobDTO = CronJobAdminDTO & {
  tenant_id: number
  tenant_name?: string
}

export type PlatformCronRunDTO = {
  uuid: string
  status: string
  trigger_kind?: string
  started_at: string
  finished_at?: string
  duration_ms?: number
  // 平台运营不返回 run summary (后端来源是 prompt 截断，属用户任务内容)。
  error_message?: string
  retry_count?: number
}

export type PlatformCronJobDetailDTO = PlatformCronJobDTO & {
  runs: PlatformCronRunDTO[]
}

export type PlatformCronOverviewDTO = {
  total_jobs: number
  active_jobs: number
  runs_24h_succeeded: number
  runs_24h_failed: number
  success_rate: number | null
  consecutive_failure_jobs: number
  last_run_at?: string
  last_failure_at?: string
  top_failure_reasons: { reason: string; count: number }[] | null
  top_failure_tenants: { tenant_id: number; tenant_name?: string; count: number }[] | null
  top_consecutive_failures: {
    job_uuid: string
    name: string
    tenant_id: number
    tenant_name?: string
    consecutive_failures: number
  }[] | null
}

export type PlatformCronListParams = {
  tenant_keyword?: string
  task_keyword?: string
  status?: string
  last_result?: string
  only_consecutive_failure?: boolean
  limit?: number
  offset?: number
}

export const PlatformCronJobs = {
  overview: () => api<PlatformCronOverviewDTO>('/api/admin/v1/platform/cron-jobs/overview'),
  list: (p: PlatformCronListParams = {}) => {
    const q = new URLSearchParams()
    if (p.tenant_keyword) q.set('tenant_keyword', p.tenant_keyword)
    if (p.task_keyword) q.set('task_keyword', p.task_keyword)
    if (p.status) q.set('status', p.status)
    if (p.last_result) q.set('last_result', p.last_result)
    if (p.only_consecutive_failure) q.set('only_consecutive_failure', '1')
    q.set('limit', String(p.limit ?? 20))
    q.set('offset', String(p.offset ?? 0))
    return api<{ items: PlatformCronJobDTO[]; total: number }>(
      `/api/admin/v1/platform/cron-jobs?${q.toString()}`,
    )
  },
  detail: (uuid: string, runLimit = 20) =>
    api<PlatformCronJobDetailDTO>(
      `/api/admin/v1/platform/cron-jobs/${encodeURIComponent(uuid)}?run_limit=${runLimit}`,
    ),
}

// ---- F08 §5.2 / G4 · 租户后台 Cron Prompt Template CRUD ----
//
// admin 路径 (与 client `/api/agent-bus/v1/cron/prompt-templates` 严格区分):
//   - GET    /api/admin/v1/tenant/cron-prompt-templates           // 本租户 draft/active/archived + platform active (只读)
//   - POST   /api/admin/v1/tenant/cron-prompt-templates           // 建本租户模板, scope=tenant 强制
//   - PATCH  /api/admin/v1/tenant/cron-prompt-templates/{uuid}    // 改本租户模板 (含 draft/archived)
//   - DELETE /api/admin/v1/tenant/cron-prompt-templates/{uuid}    // 软删本租户模板
//
// admin scope vs client scope (F08 H 返修结论):
//   - 本租户模板: admin 看到 draft/active/archived 全部; client 仅 active.
//   - platform 模板: admin 只读浏览 (active only); client 同样仅 active 可读.
//   - 跨租户 / 不存在 / 软删 → not_found, 不泄露存在性.
//
// Variables 语义:
//   - PromptTemplateVariableDTO 对齐后端 svccron.PromptTemplateVariableDTO.
//   - PATCH 中 variables 字段语义: 不传 = 不动; 传 [] = 全删; 传 [...] = 全量替换 (后端 ReplaceVars=true).

export type PromptTemplateScopeKind = 'platform' | 'tenant'
export type PromptTemplateStatus = 'draft' | 'active' | 'archived'
export type PromptTemplateVarType = 'string' | 'enum' | 'int' | 'datetime' | 'list'

// 列表项 (admin 视角, 含 draft / archived + readonly 标志).
//
// K 增量:
//   - active_job_count: 本租户名下 active cron 引用本模板数; 用于列表展示 + 删除前提示.
//   - updated_at: 模板最近一次更新时间 (RFC3339 字符串). 列表展示"上次更新".
export type PromptTemplateAdminDTO = {
  uuid: string
  scope_kind: PromptTemplateScopeKind
  code: string
  name: string
  is_system: boolean
  status: PromptTemplateStatus
  is_readonly: boolean
  active_job_count: number
  updated_at?: string
}

// 变量定义 (UI 表单生成 + create/patch 用).
export type PromptTemplateVariableDTO = {
  var_name: string
  var_type: PromptTemplateVarType
  required: boolean
  default_value?: unknown
  options?: unknown[]
  display_name?: string
  order_index: number
}

// 详情 (含 template_body + variables; admin 路径不复检 status, draft/archived 也回完整体).
// J 返修: description 字段后端始终返回 (omitempty 时为空串就省略), 编辑 drawer 直接回填.
export type PromptTemplateDetailDTO = {
  uuid: string
  scope_kind: PromptTemplateScopeKind
  code: string
  name: string
  description?: string
  template_body: string
  is_system: boolean
  status: PromptTemplateStatus
  is_readonly: boolean
  variables: PromptTemplateVariableDTO[]
}

export type CreatePromptTemplateReq = {
  code: string
  name: string
  description?: string
  template_body: string
  status?: PromptTemplateStatus
  variables?: PromptTemplateVariableDTO[]
}

// PATCH 请求 — 全 optional 语义:
//   - 字段为 undefined → 不传 (后端不动该字段)
//   - variables 区分: undefined (不传) vs [] (清空) vs [...] (全量替换)
export type PatchPromptTemplateReq = {
  name?: string
  description?: string
  template_body?: string
  status?: PromptTemplateStatus
  variables?: PromptTemplateVariableDTO[] | null
}

export const CronPromptTemplatesAdmin = {
  list: () =>
    api<{ items: PromptTemplateAdminDTO[] }>(
      `/api/admin/v1/tenant/cron-prompt-templates`,
    ),
  // get: admin scope 详情 (含 body + variables); list DTO 不带这两个字段, 编辑 drawer 用.
  get: (uuid: string) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/tenant/cron-prompt-templates/${encodeURIComponent(uuid)}`,
    ),
  create: (body: CreatePromptTemplateReq) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/tenant/cron-prompt-templates`,
      { method: 'POST', body: JSON.stringify(body) },
    ),
  patch: (uuid: string, body: PatchPromptTemplateReq) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/tenant/cron-prompt-templates/${encodeURIComponent(uuid)}`,
      { method: 'PATCH', body: JSON.stringify(body) },
    ),
  remove: (uuid: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/cron-prompt-templates/${encodeURIComponent(uuid)}`,
      { method: 'DELETE' },
    ),
}

// 模板 CRUD client 形状（租户 / 平台两个控制台共用同一页面组件时注入）。
export type CronPromptTemplatesClient = typeof CronPromptTemplatesAdmin

// 平台控制台 · 平台模板 CRUD（scope=platform，全租户员工可选用其启用版本）。
// 读 platform.cron.read；写 platform.cron.create/update/delete。
export const CronPromptTemplatesPlatformAdmin: CronPromptTemplatesClient = {
  list: () =>
    api<{ items: PromptTemplateAdminDTO[] }>(
      `/api/admin/v1/platform/cron-prompt-templates`,
    ),
  get: (uuid: string) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/platform/cron-prompt-templates/${encodeURIComponent(uuid)}`,
    ),
  create: (body: CreatePromptTemplateReq) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/platform/cron-prompt-templates`,
      { method: 'POST', body: JSON.stringify(body) },
    ),
  patch: (uuid: string, body: PatchPromptTemplateReq) =>
    api<PromptTemplateDetailDTO>(
      `/api/admin/v1/platform/cron-prompt-templates/${encodeURIComponent(uuid)}`,
      { method: 'PATCH', body: JSON.stringify(body) },
    ),
  remove: (uuid: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/platform/cron-prompt-templates/${encodeURIComponent(uuid)}`,
      { method: 'DELETE' },
    ),
}

// ===========================================================================
// M3 v1.1 · Agent 平台环境 (Runtime Environments) — Stage 4-5 + 协议查看/下载
// ===========================================================================

export type RuntimeEnv = {
  ID: number
  UUID: string
  Code: string
  Name: string
  Description: string
  Framework: string
  AdapterKind: string
  Scope: 'platform' | 'tenant' | 'personal'
  OwnerTenantID?: number | null
  OwnerAccountID?: number | null
  ImageRepository: string
  ImageTag: string
  Endpoints: Record<string, unknown>
  PrimaryEndpoint?: string
  ExternalEnvironmentID?: string
  DataEgress: string
  EgressAuditStatus: string
  Status: string
  ProtocolVersion: string
  ZAPSchemaVersion: string
  SupportsMultiAgent: boolean
  DefaultAgentKey: string
  MaxAgents: number
  RuntimeCard: Record<string, unknown>
  APIKeySecretRef: string
  HostingKind?: 'clawmanager' | 'k8s_native' | 'external_endpoint' | ''
  IsPlatformDefault: boolean
  Metadata: Record<string, unknown>
  CreatedAt: string
  UpdatedAt: string
  BoundAgents: number
  IsDefaultForCaller: boolean
  EnablementUUID: string
  LastProbeStatus?: string
  OpenToTenants?: boolean
}

export type Enablement = {
  ID: number
  UUID: string
  TenantID: number
  RuntimeRegID: number
  IsDefault: boolean
  EnabledBy?: number | null
  EnabledAt: string
}

export type ProbeRequest = {
  framework: string
  endpoints: Record<string, string>
  // P1-1: secret_ref 必填; probe + create 必须用同一 ref, 否则 auth_config_sha256 不匹配。
  auth: { kind: string; secret: string; secret_ref: string }
  timeout_sec?: number
  expect_multi_agent?: boolean | null
}

export type ProbeResult = {
  ok: boolean
  latency_ms: number
  probe_token?: string
  protocol_version?: string
  framework_detected?: string
  runtime_card?: Record<string, unknown>
  missing_required_endpoints?: string[]
  warnings?: string[]
  error_code?: string
  error_message?: string
}

export const PlatformRuntimeEnvs = {
  list: (includeDisabled = false) =>
    api<{ items: RuntimeEnv[]; total: number }>(
      `/api/admin/v1/platform/runtime-environments${includeDisabled ? '?include_disabled=true' : ''}`,
    ),
  setDefault: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/runtimes/${uuid}/set-as-default`, { method: 'POST' }),
  remove: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/runtime-environments/${uuid}`, { method: 'DELETE' }),
  probe: (body: ProbeRequest) =>
    api<ProbeResult>(`/api/admin/v1/platform/runtimes/probe`, { method: 'POST', body: JSON.stringify(body) }),
}

export type TenantRuntimeEnvList = {
  platform_enabled: RuntimeEnv[]
  platform_available: RuntimeEnv[]
  tenant_custom: RuntimeEnv[]
  total: number
  limit: number
  offset: number
}

export type CreateCustomEnvInput = {
  name: string
  description?: string
  framework: string
  hosting_kind?: 'external_endpoint' | 'clawmanager' | 'k8s_native'
  // external_endpoint (ZAP) 字段
  primary_endpoint?: string
  api_key_secret_ref?: string
  external_environment_id?: string
  probe_token?: string
  // clawmanager (PaaS) 字段
  workload_api_base_url?: string
  workload_api_token_secret_ref?: string
  // k8s_native 字段
  k8s_api_server_url?: string
  k8s_token_secret_ref?: string
  k8s_namespace?: string
  k8s_insecure_skip_verify?: boolean
  // hosting_kind != external_endpoint 共用部署 + quota 字段
  image_repository?: string
  image_tag?: string
  gateway_port?: number
  mount_path?: string
  storage_class?: string
  default_cpu_cores?: number
  default_memory_gb?: number
  default_disk_gb?: number
  workload_env?: Record<string, string>
  // 运行时参数 (ADR-0021)
  llm_default_model?: string
  http_proxy?: string
  https_proxy?: string
  no_proxy?: string
  data_egress?: string
  metadata?: Record<string, unknown>
  rate_limit?: Record<string, unknown>
  supports_multi_agent?: boolean
  default_agent_key?: string
  max_agents?: number
  protocol_version?: string
  runtime_card?: Record<string, unknown>
}

export const TenantRuntimeEnvs = {
  list: (limit = 20, offset = 0) =>
    api<TenantRuntimeEnvList>(`/api/admin/v1/tenant/runtime-environments?limit=${limit}&offset=${offset}`),
  enable: (runtime_environment_uuid: string, is_default = false) =>
    api<Enablement>(`/api/admin/v1/tenant/runtime-environments/enablements`, {
      method: 'POST',
      body: JSON.stringify({ runtime_environment_uuid, is_default }),
    }),
  disable: (enablementUUID: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/runtime-environments/enablements/${enablementUUID}`,
      { method: 'DELETE' },
    ),
  setDefault: (enablementUUID: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/runtime-environments/enablements/${enablementUUID}/set-default`,
      { method: 'POST' },
    ),
  createCustom: (body: CreateCustomEnvInput) =>
    api<RuntimeEnv>(`/api/admin/v1/tenant/runtime-environments/custom`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patchCustom: (uuid: string, body: Partial<CreateCustomEnvInput>) =>
    api<RuntimeEnv>(`/api/admin/v1/tenant/runtime-environments/custom/${uuid}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  deleteCustom: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/runtime-environments/custom/${uuid}`, {
      method: 'DELETE',
    }),
  probe: (body: ProbeRequest) =>
    api<ProbeResult>(`/api/admin/v1/tenant/runtime-environments/probe`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  // ADR-0022: 租户自带 K8s/PaaS 托管 (clawmanager / k8s_native) 的连通性 dry-run; 复用平台 ProbeDraft 不落库。
  probeHosting: (body: HostingConfig) =>
    api<HostingProbeResult>(`/api/admin/v1/tenant/runtime-environments/probe-hosting`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
}

// ===========================================================================
// 平台托管 (Hosting / K8s 工作负载) · M3 Stage 7
// ===========================================================================

export type HostingConfig = {
  runtime_environment_id: number
  // ADR-0025: 平台 ZAP 自建接入 → 'external_endpoint'; 其它 hosting_kind 继续走 K8s/PaaS 路径
  hosting_kind: 'clawmanager' | 'k8s_native' | 'external_endpoint'
  // ADR-0025 §2.1: external_endpoint 时框架必须走 ZAP 协议 (zap 或 ADR-0035 引入的 dsh);
  // 其它 hosting_kind 分支可选 'openclaw' | 'hermes' | 'zap'。
  framework?: 'zap' | 'dsh' | 'openclaw' | 'hermes' | string
  scope?: 'platform' | 'tenant'
  open_to_tenants: boolean
  // ADR-0025: external_endpoint 表单提供; clawmanager/k8s_native 实例签发后回填
  primary_endpoint?: string
  // platform external 的 UI 直接收访问凭证; 内部仍走 api_key_secret_ref (value:// / env://)
  api_key_secret_ref?: string
  external_environment_id?: string
  workload_api_base_url: string
  workload_api_token_secret_ref: string
  k8s_api_server_url: string
  k8s_token_secret_ref: string
  k8s_insecure_skip_verify: boolean
  k8s_ops_kubeconfig_secret_ref?: string
  image_repository: string
  image_tag: string
  k8s_namespace: string
  gateway_port: number
  mount_path: string
  storage_class: string
  pvc_name: string
  default_cpu_cores: number
  default_memory_gb: number
  default_disk_gb: number
  workload_env: Record<string, string> | null
  // 运行时参数 (ADR-0021)：默认模型 + 出口网络。LLM 网关 / Webhook 走 bus.yaml, 不在 UI 配置。
  llm_default_model?: string
  http_proxy?: string
  https_proxy?: string
  no_proxy?: string
  data_egress?: string
  egress_audit_status?: string
  enabled: boolean
  last_probed_at?: string | null
  last_probe_status?: string
  last_probe_message?: string
  last_probe_latency_ms?: number
  // ADR-0025 §2.8a: probe 时从 runtime_card 解析回填; 仅前端展示用
  multi_tenant_isolation?: boolean | null
  // S5e (doc-12 §4): runtime_card/probe 声明本 runtime 启用的 control-plane 能力 (key→true)。
  // key ∈ agent.read/create/update/delete/list, skill.install/uninstall/list。
  // 仅后台配置缓存; 不下发 zhiban-app / Bus client。
  control_plane_capabilities?: Record<string, boolean>
  // 新建平台托管配置时由前端显式传 true, 后端才会自动签发默认 Runtime 凭证。
  auto_issue_default_credential?: boolean
}

// 4 层模型 L2 列表项: hosting_config 本身 + runtime 元数据 + 实例计数
// (后端 GET /api/admin/v1/platform/runtime-hosting-configs 返回; 一次拉全部, 避免前端 N+1)。
export type HostingConfigListItem = HostingConfig & {
  runtime_uuid: string
  runtime_code: string
  runtime_name: string
  runtime_framework: string
  is_platform_default: boolean
  active_instance_count: number
  failed_instance_count: number
}

export type HostingProbeResult = {
  status: 'ok' | 'failed'
  message: string
  latency_ms: number
  hosting_kind: 'clawmanager' | 'k8s_native' | 'external_endpoint'
  runtime_card?: Record<string, unknown>
  // S5e (doc-12 §4.3): ZAP/custom 的 runtime_card 自报支持的 control-plane 能力 (key→true)。
  // 空 = runtime_card 未声明 (信息缺失, 不据此强制拦截)。OpenClaw 不做逐能力 probe。
  supported_control_plane_capabilities?: Record<string, boolean>
  // runtime_card.agent_instance_initialization.supports_initialize, 仅用于接口能力面板展示。
  agent_instance_initialize_supported?: boolean
}

// 4 层模型 L1: Agent 平台类型 (只读枚举)
export type PlatformType = {
  // ADR-0035: 'dsh' = 知办通用运行时 (平台内置; 线上协议同 ZAP, hosting_kind=external_endpoint)。
  code: 'openclaw' | 'hermes' | 'zap' | 'dsh'
  display_name: string
  description: string
  doc_anchor: string
  // ADR-0022: zap / dsh → 'external_endpoint' (协议接入); openclaw/hermes → 'clawmanager' / 'k8s_native'
  hosting_kinds: Array<'clawmanager' | 'k8s_native' | 'external_endpoint'>
}

export const PlatformTypes = {
  list: () =>
    api<{ items: PlatformType[] }>(`/api/admin/v1/runtime/platform-types`),
}

export type EnsureWorkloadResult = {
  InstanceUUID: string
  Status: string
  EndpointURL: string
  ErrorMessage: string
  WorkloadName: string
  WorkloadID: number
  PodIP: string
  Namespace: string
  DeploymentName: string
}

export type UpsertHostingConfigResult = {
  ok: boolean
  defaultCredential?: CreateAgentSdkCredentialResult
  defaultCredentialSkippedReason?: string
}

export const RuntimeHosting = {
  // 4 层模型 L2 批量列表: 一次拉所有 hosting_config + runtime 元数据 + 实例计数。
  // 列表页 (RuntimeHosting.tsx) 应只用这一个调用, 不要再对每行单独 getConfig。
  listConfigs: (limit = 20, offset = 0) =>
    api<{ items: HostingConfigListItem[]; total: number }>(
      `/api/admin/v1/platform/runtime-hosting-configs?limit=${limit}&offset=${offset}`,
    ),
  // 注意: hosting 接口 path 参数是 runtime_environment UUID (而非 runtime_environment ID)。
  // 后端 handler 先按 UUID 解到 env, 校 scope='platform', 然后取 env.ID 给 service。
  getConfig: (runtimeUUID: string) =>
    api<HostingConfig>(`/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting-config`),
  upsertConfig: (runtimeUUID: string, body: HostingConfig) =>
    api<UpsertHostingConfigResult>(`/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting-config`, {
      method: 'PUT',
      body: JSON.stringify(body),
    }),
  ensureWorkload: (runtimeUUID: string, body: { tenant_id?: number; account_id?: number; poll_timeout_ms?: number }) =>
    api<EnsureWorkloadResult>(`/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting/ensure-workload`, {
      method: 'POST',
      body: JSON.stringify(body || {}),
    }),
  deleteWorkload: (runtimeUUID: string, workloadName: string, workloadInstanceID?: number | null) =>
    api<{ ok: boolean; workload_name: string }>(
      `/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting/delete-workload`,
      { method: 'POST', body: JSON.stringify({ workload_name: workloadName, workload_instance_id: workloadInstanceID || 0 }) },
    ),
  restartWorkload: (runtimeUUID: string, workloadName: string, workloadInstanceID?: number | null) =>
    api<{ ok: boolean; workload_name: string }>(
      `/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting/restart-workload`,
      { method: 'POST', body: JSON.stringify({ workload_name: workloadName, workload_instance_id: workloadInstanceID || 0 }) },
    ),
  refreshInstance: (instanceUUID: string) =>
    api<EnsureWorkloadResult>(`/api/admin/v1/runtime-instances/${instanceUUID}/refresh`, { method: 'POST' }),
  // 4 层模型 L2: 连通性校验; UpsertConfig 前必须先 probe ok 才能 enabled/open_to_tenants=true。
  probeDraft: (body: HostingConfig) =>
    api<HostingProbeResult>(`/api/admin/v1/platform/runtime-hosting-configs/probe`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  probe: (runtimeUUID: string) =>
    api<HostingProbeResult>(`/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting/probe`, { method: 'POST' }),
  // 4 层模型 L2 CRUD: 删除该 runtime 的 hosting_config 行 (不删 runtime_environment 本身)。
  // 后端拒绝条件: 仍有 active runtime_instance (caller 应先 delete-workload)。
  deleteConfig: (runtimeUUID: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/runtimes/${runtimeUUID}/hosting-config`, { method: 'DELETE' }),
}

// ============================================================================
// M7 Phase B sprint — Drive Storage + Drive Browse
// ============================================================================

// F06 migration 000120: force_path_style / prefix_tpl / lifecycle_rules 三列已从 DB 删除,
// API 也不再返回 / 接受这些字段, force-path-style 改由后端 endpoint 启发式 (PickPathStyle) 推导。
export type DriveStorageDefault = {
  uuid: string
  name: string
  kind: 'oss' | 's3' | 'minio' | string
  region: string
  endpoint: string
  read_endpoint?: string
  bucket: string
  access_key_secret_ref: string
  secret_key_secret_ref: string
  status: 'active' | 'degraded' | 'disabled' | string
  is_default: boolean
  created_at: string
  updated_at: string
}

export type DriveStorageDefaultCreateInput = {
  name: string
  kind: 'oss' | 's3' | 'minio'
  region: string
  endpoint: string
  read_endpoint?: string
  bucket: string
  access_key_secret_ref: string
  secret_key_secret_ref: string
}

export type DriveStorageOverride = {
  exists: boolean
  tenant_id?: number
  default_id?: number | null
  region?: string
  endpoint?: string
  read_endpoint?: string
  bucket?: string
  access_key_secret_ref?: string
  secret_key_secret_ref?: string
  status?: string
}

export const DriveStorage = {
  list: () => api<{ items: DriveStorageDefault[] }>('/api/admin/v1/platform/drive/storage-defaults'),
  create: (body: DriveStorageDefaultCreateInput) =>
    api<DriveStorageDefault>('/api/admin/v1/platform/drive/storage-defaults', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: Partial<DriveStorageDefaultCreateInput> & { status?: 'active' | 'disabled' }) =>
    // status 字段只接受 'active' / 'disabled' (admin 启用意图); 'degraded' 是 TestConnection
    // 瞬时响应, 后端 service 层会拒收。详见 domain/drive/storage.go StorageStatus 注释。
    api<{ ok: boolean }>(`/api/admin/v1/platform/drive/storage-defaults/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  remove: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/drive/storage-defaults/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  setDefault: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/drive/storage-defaults/${encodeURIComponent(uuid)}/set-default`, {
      method: 'POST',
    }),
  testConnection: (uuid: string) =>
    api<{ status: string; message?: string }>(
      `/api/admin/v1/platform/drive/storage-defaults/${encodeURIComponent(uuid)}/test-connection`,
      { method: 'POST' },
    ),

  // Tenant override (单租户单行).
  getOverride: () => api<DriveStorageOverride>('/api/admin/v1/tenant/drive/storage-override'),
  putOverride: (body: Partial<DriveStorageOverride>) =>
    api<{ ok: boolean }>('/api/admin/v1/tenant/drive/storage-override', {
      method: 'PUT',
      body: JSON.stringify(body),
    }),
  deleteOverride: () =>
    api<{ ok: boolean }>('/api/admin/v1/tenant/drive/storage-override', { method: 'DELETE' }),
  testOverride: () =>
    api<{ status: string; message?: string }>(
      '/api/admin/v1/tenant/drive/storage-override/test-connection',
      { method: 'POST' },
    ),
}

export type TenantSpaceItem = {
  uuid: string
  space_kind: string
  name: string
  owner_id?: number
  owner_name?: string
  quota_bytes?: number
  used_bytes: number
  files_count: number
  folders_count: number
  status: string
  created_at: string
}

export type TenantFileItem = {
  uuid: string
  name: string
  mime_type: string
  file_size: number
  storage_kind: string
  storage_key: string
  folder_path: string
  uploader_id?: number
  uploader_name?: string
  source_kind?: string
  created_at: string
}

export const DriveBrowse = {
  listSpaces: () => api<{ items: TenantSpaceItem[] }>('/api/admin/v1/tenant/drive/spaces'),
  listFiles: (spaceUUID: string, q: { q?: string; mime_prefix?: string; limit?: number; cursor?: number } = {}) => {
    const usp = new URLSearchParams()
    if (q.q) usp.set('q', q.q)
    if (q.mime_prefix) usp.set('mime_prefix', q.mime_prefix)
    if (q.limit) usp.set('limit', String(q.limit))
    if (q.cursor) usp.set('cursor', String(q.cursor))
    const qs = usp.toString()
    return api<{ items: TenantFileItem[]; next_cursor: number }>(
      `/api/admin/v1/tenant/drive/spaces/${encodeURIComponent(spaceUUID)}/files${qs ? '?' + qs : ''}`,
    )
  },
}

// ============================================================================
// F06 Phase 4 — admin drive 周边 wrapper.
// quotas / recycle / usage / workers 这 4 类后端 admin API 仍 backend pending;
// 页面会拿到真实 404/500, 展示空态/错误态而非假数据 (符合 admin-web-design-standard §6).
// 后端就绪后只需在 backend 落地对应 handler, 这里 wrapper 已对齐 URL 不用改.
// ============================================================================

// 租户配额：租户总额 + per-account 配额。
export type DriveTenantQuotaSummary = {
  tenant_id?: number
  tenant_quota_bytes?: number    // 未返回或 -1 表示无限制
  tenant_used_bytes?: number
  // 每用户配额可在 items 里展开
  items?: DriveAccountQuotaItem[]
}

export type DriveAccountQuotaItem = {
  account_id: number
  account_name?: string
  employee_id?: string
  department_name?: string
  contact?: string
  status?: string
  quota_bytes: number  // -1 表示继承租户额度
  used_bytes: number
}

export type DriveAccountQuotaUpdateInput = {
  account_id: number
  quota_bytes: number  // -1 表示恢复继承
}

// F06 Phase B 拍定: 租户 admin 仅可看总额度 + 调整 per-account; 总额度由平台 admin 管 (后续 slice).
// 因此本 wrapper 不再暴露 setTenantQuota — 调用会找不到后端 endpoint.
export const DriveQuotasAdmin = {
  getTenantSummary: () => api<DriveTenantQuotaSummary>('/api/admin/v1/tenant/drive/quotas'),
  upsertAccountQuota: (input: DriveAccountQuotaUpdateInput) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/drive/quotas/accounts/${encodeURIComponent(String(input.account_id))}`,
      { method: 'PUT', body: JSON.stringify({ quota_bytes: input.quota_bytes }) },
    ),
}

// 租户回收站 admin 视图：列出本租户全部回收行 + 协助还原 / 提前清理。
// 与客户端 /api/agent-bus/v1/drive/recycle/* 区别：admin 看全租户范围, 不限 caller 自己删的项。
export type DriveRecycleAdminItem = {
  uuid: string
  target_kind: 'file' | 'folder'
  target_uuid?: string
  target_name?: string
  space_uuid?: string
  space_name?: string
  deleted_by?: number
  deleted_by_name?: string
  deleted_at: string
  expires_at: string
  bytes_to_reclaim: number
}

export const DriveRecycleAdmin = {
  list: (q: { limit?: number; cursor?: number } = {}) => {
    const usp = new URLSearchParams()
    if (q.limit) usp.set('limit', String(q.limit))
    if (q.cursor) usp.set('cursor', String(q.cursor))
    const qs = usp.toString()
    return api<{ items: DriveRecycleAdminItem[]; next_cursor: number }>(
      `/api/admin/v1/tenant/drive/recycle${qs ? '?' + qs : ''}`,
    )
  },
  restore: (recycleUUID: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/drive/recycle/${encodeURIComponent(recycleUUID)}/restore`,
      { method: 'POST' },
    ),
  purge: (recycleUUID: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/tenant/drive/recycle/${encodeURIComponent(recycleUUID)}/purge`,
      { method: 'DELETE' },
    ),
}

// 平台用量监控：全租户云盘用量汇总 (按 tenant 维度).
export type DriveUsageRow = {
  tenant_id: number
  tenant_name?: string
  tenant_status?: string
  spaces_count: number
  personal_spaces_count: number
  collaboration_spaces_count: number
  files_count: number
  used_bytes: number
  personal_used_bytes: number
  collaboration_used_bytes: number
  quota_bytes?: number
}

// 平台用量汇总卡 (与列表同过滤口径, 不分页); near = used >= quota*0.8.
export type DriveUsageSummary = {
  tenants_count: number
  spaces_count: number
  files_count: number
  used_bytes: number
  personal_used_bytes: number
  collaboration_used_bytes: number
  quota_set_count: number
  near_quota_count: number
}

export const DriveUsageAdmin = {
  // q: 租户名模糊或租户 id 精确; sort: usage_desc(默认)/usage_asc/tenant_id.
  list: (q: { q?: string; tenant_id?: number; tenant_status?: string; sort?: string; limit?: number; offset?: number } = {}) => {
    const usp = new URLSearchParams()
    if (q.q) usp.set('q', q.q)
    if (q.tenant_id) usp.set('tenant_id', String(q.tenant_id))
    if (q.tenant_status) usp.set('tenant_status', q.tenant_status)
    if (q.sort) usp.set('sort', q.sort)
    if (q.limit) usp.set('limit', String(q.limit))
    if (q.offset) usp.set('offset', String(q.offset))
    const qs = usp.toString()
    return api<{ items: DriveUsageRow[]; total: number }>(
      `/api/admin/v1/platform/drive/usage${qs ? '?' + qs : ''}`,
    )
  },
  summary: (q: { q?: string; tenant_id?: number; tenant_status?: string } = {}) => {
    const usp = new URLSearchParams()
    if (q.q) usp.set('q', q.q)
    if (q.tenant_id) usp.set('tenant_id', String(q.tenant_id))
    if (q.tenant_status) usp.set('tenant_status', q.tenant_status)
    const qs = usp.toString()
    return api<DriveUsageSummary>(
      `/api/admin/v1/platform/drive/usage/summary${qs ? '?' + qs : ''}`,
    )
  },
}

// F06 v0.3.1 §3.3 — 平台 admin 调整某租户云盘总额度 (区别于租户 scope 的 per-account 调整).
// 权限: platform.drive.manage_quota.
// -1 表示无限. 小于实时 used → 后端 412 drive.quota_below_used.
export const DrivePlatformQuotasAdmin = {
  setTenantQuota: (tenantID: number, quotaBytes: number) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/platform/drive/tenants/${encodeURIComponent(String(tenantID))}/quota`,
      { method: 'PUT', body: JSON.stringify({ quota_bytes: quotaBytes }) },
    ),
}

// drive-worker 状态：列出 5 类后台 job 最近一次运行 + 当前堆积量。
// staging reaper / recycle cleaner / version cleaner / copy executor / thumbnail.
export type DriveWorkerJobStatus = {
  job: string                // 'staging_reaper' | 'recycle_cleaner' | 'version_cleaner' | 'copy_executor' | 'thumbnail'
  status?: 'running' | 'success' | 'failed' | 'disabled'
  last_run_at?: string
  last_finished_at?: string
  last_run_duration_ms?: number
  last_processed?: number
  last_success?: number
  last_failed?: number
  last_error?: string
  consecutive_failures?: number
  pending_count?: number     // 堆积量 (e.g. expired tickets count / expired recycle count)
  enabled: boolean
  // 2026-07-06 F06 §4.7 增补: 调度周期 / 下次运行推算 / 停摆判定 / 手动触发排队中。
  interval_seconds?: number
  next_due_at?: string
  stalled?: boolean
  trigger_pending?: boolean
}

// drive-worker 失败明细行（drive_worker_job_failures, 最近 14 天滚动保留）。
export type DriveWorkerFailure = {
  id: number
  tenant_id?: number
  object_kind: string        // 'upload_ticket' | 'recycle_entry' | 'file' | 'file_version'
  object_ref: string
  reason: string
  occurred_at: string
}

export const DriveWorkersAdmin = {
  list: () => api<{ items: DriveWorkerJobStatus[] }>('/api/admin/v1/platform/drive/workers'),
  failures: (job: string, limit: number, offset: number) =>
    api<{ items: DriveWorkerFailure[]; total: number }>(
      `/api/admin/v1/platform/drive/workers/${encodeURIComponent(job)}/failures?limit=${limit}&offset=${offset}`,
    ),
  trigger: (job: string) =>
    api<{ queued: boolean; already_pending?: boolean }>(
      `/api/admin/v1/platform/drive/workers/${encodeURIComponent(job)}/trigger`,
      { method: 'POST' },
    ),
}

// ============================================================================
// M8 Phase B sprint — 租户 KB 完整 admin (复用 Phase A list, 加 recall-test/logs/stats)
// ============================================================================

export type TenantKBItem = {
  uuid: string
  name: string
  description?: string
  space_kind?: string
  visibility?: string
  access_mode?: string
  provider_kind?: string
  ragflow_dataset_id?: string
  provision_status?: string
  provision_error?: string
  creator_id?: number
  creator_name?: string
  owner_account_id?: number
  owner_name?: string
  total_documents?: number
  status?: string
  created_at?: string
}

export type KBFolderItem = {
  uuid: string
  kb_uuid: string
  parent_uuid?: string
  name: string
  path: string
  created_at: string
  updated_at: string
}

export type ManagedKBScope = 'platform' | 'tenant'

function managedKBBase(scope: ManagedKBScope) {
  return `/api/admin/v1/${scope}/knowledge-bases`
}

export const ManagedKB = {
  list: (scope: ManagedKBScope, params: { q?: string; status?: string; limit?: number; offset?: number } = {}) => {
    const qs = new URLSearchParams()
    if (params.q?.trim()) qs.set('q', params.q.trim())
    if (params.status) qs.set('status', params.status)
    qs.set('limit', String(params.limit ?? 20))
    qs.set('offset', String(params.offset ?? 0))
    return api<{ items: TenantKBItem[]; total: number; limit: number; offset: number }>(`${managedKBBase(scope)}?${qs}`)
  },
  get: (scope: ManagedKBScope, uuid: string) =>
    api<TenantKBItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}`),
  create: (scope: ManagedKBScope, body: { name: string; description?: string }) =>
    api<TenantKBItem>(managedKBBase(scope), { method: 'POST', body: JSON.stringify(body) }),
  patch: (scope: ManagedKBScope, uuid: string, body: { name?: string; description?: string }) =>
    api<TenantKBItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}`, { method: 'PATCH', body: JSON.stringify(body) }),
  references: (scope: ManagedKBScope, uuid: string) =>
    api<{ active_agent_count: number }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/references`),
  remove: (scope: ManagedKBScope, uuid: string) =>
    api<{ deleted: boolean }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),
  folders: (scope: ManagedKBScope, uuid: string) =>
    api<{ items: KBFolderItem[]; total: number }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/folders`),
  createFolder: (scope: ManagedKBScope, uuid: string, body: { name: string; parent_uuid?: string }) =>
    api<KBFolderItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/folders`, { method: 'POST', body: JSON.stringify(body) }),
  patchFolder: (scope: ManagedKBScope, uuid: string, folderUuid: string, name: string) =>
    api<KBFolderItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/folders/${encodeURIComponent(folderUuid)}`, { method: 'PATCH', body: JSON.stringify({ name }) }),
  removeFolder: (scope: ManagedKBScope, uuid: string, folderUuid: string) =>
    api<{ deleted: boolean }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/folders/${encodeURIComponent(folderUuid)}`, { method: 'DELETE' }),
  documents: (scope: ManagedKBScope, uuid: string, params: { folder_uuid?: string; limit?: number; offset?: number } = {}) => {
    const qs = new URLSearchParams()
    if (params.folder_uuid) qs.set('folder_uuid', params.folder_uuid)
    qs.set('limit', String(params.limit ?? 50)); qs.set('offset', String(params.offset ?? 0))
    return api<{ items: KBDocumentItem[]; total: number; limit: number; offset: number }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents?${qs}`)
  },
  upload: (scope: ManagedKBScope, uuid: string, files: File[], folderUuid?: string) => {
    const body = new FormData()
    files.forEach((file) => body.append('files', file))
    if (folderUuid) body.append('folder_uuid', folderUuid)
    return api<{ items: KBDocumentItem[]; total: number; failures: Array<{ filename: string; error: string }>; idempotency_key: string }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents/upload`, {
      method: 'POST', body, headers: { 'Idempotency-Key': randomUUID() },
    })
  },
  patchDocument: (scope: ManagedKBScope, uuid: string, documentUuid: string, title: string) =>
    api<KBDocumentItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents/${encodeURIComponent(documentUuid)}`, { method: 'PATCH', body: JSON.stringify({ title }) }),
  removeDocument: (scope: ManagedKBScope, uuid: string, documentUuid: string) =>
    api<{ deleted: boolean }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents/${encodeURIComponent(documentUuid)}`, { method: 'DELETE' }),
  retryDocument: (scope: ManagedKBScope, uuid: string, documentUuid: string) =>
    api<KBDocumentItem>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents/${encodeURIComponent(documentUuid)}/retry`, { method: 'POST' }),
  downloadURL: (scope: ManagedKBScope, uuid: string, documentUuid: string) =>
    api<{ url: string }>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/documents/${encodeURIComponent(documentUuid)}/download`),
  recallTest: (scope: ManagedKBScope, uuid: string, body: KBRecallTestReq) =>
    api<KBRecallTestResp>(`${managedKBBase(scope)}/${encodeURIComponent(uuid)}/recall-test`, {
      method: 'POST', body: JSON.stringify(body),
    }),
}

export const PlatformKB = {
  list: (params: { q?: string; status?: string; limit?: number; offset?: number } = {}) => ManagedKB.list('platform', params),
}

export type KBRecallTestReq = {
  query: string
  top_k?: number
  threshold?: number
}

export type KBRecallTestResp = {
  chunks: Array<{
    uuid: string
    document_id?: number
    chunk_index?: number
    content: string
    score: number
    source?: string
  }>
  duration_ms?: number
}

export type KBRecallLogItem = {
  occurred_at: string
  caller_kind: 'user' | 'agent' | 'admin' | string
  account_id?: number
  agent_id?: number
  query_text: string
  top_k: number
  threshold: number
  chunk_hits: number
  score_top: number
  latency_ms: number
  error_code?: string
}

export type KBReferenceStats = {
  window_days: number
  total: number
  hit: number
  err: number
  agent_count: number
  user_count: number
  avg_latency_ms: number
}

export const TenantKB = {
  list: () => ManagedKB.list('tenant', { limit: 200, offset: 0 }),
  recallTest: (uuid: string, body: KBRecallTestReq) =>
    api<KBRecallTestResp>(`/api/admin/v1/tenant/knowledge-bases/${encodeURIComponent(uuid)}/recall-test`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  recallLogs: (uuid: string, limit = 100) =>
    api<{ items: KBRecallLogItem[] }>(
      `/api/admin/v1/tenant/knowledge-bases/${encodeURIComponent(uuid)}/recall-logs?limit=${limit}`,
    ),
  referenceStats: (uuid: string, days = 30) =>
    api<KBReferenceStats>(
      `/api/admin/v1/tenant/knowledge-bases/${encodeURIComponent(uuid)}/reference-stats?days=${days}`,
    ),
}

// =====================================================================
// M1 B2 (F01 §3.5): 租户 API Key 管理 (/api/admin/v1/tenant/api-keys)
// =====================================================================

export type ApiKey = {
  uuid: string
  name: string
  keyPrefix: string
  scopes: string[]
  status: 'active' | 'revoked' | 'expired'
  lastUsedAt?: string
  expiresAt?: string
  createdAt: string
  updatedAt: string
  revokedAt?: string
}

export type CreateApiKeyInput = {
  name: string
  scopes: string[]
  expiresAt?: string | null // ISO8601; null/undefined = 永不过期
}

export type CreateApiKeyResult = {
  apiKey: ApiKey
  secret: string // 一次性明文 ek_<prefix>_<secret>
}

export type ApiKeyListParams = {
  status?: '' | ApiKey['status']
  q?: string
  limit?: number
  offset?: number
}

export type ApiKeyListResp = {
  items: ApiKey[]
  total: number
  limit: number
  offset: number
}

export type PatchApiKeyInput = {
  name?: string
  scopes?: string[]
  expiresAt?: string
  clearExpiresAt?: boolean
}

export const ApiKeys = {
  list: (params: ApiKeyListParams = {}) => {
    const qs = new URLSearchParams()
    if (params.status) qs.set('status', params.status)
    if (params.q?.trim()) qs.set('q', params.q.trim())
    if (params.limit) qs.set('limit', String(params.limit))
    if (params.offset) qs.set('offset', String(params.offset))
    const query = qs.toString()
    return api<ApiKeyListResp>(`/api/admin/v1/tenant/api-keys${query ? `?${query}` : ''}`)
  },
  create: (body: CreateApiKeyInput) =>
    api<CreateApiKeyResult>('/api/admin/v1/tenant/api-keys', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: PatchApiKeyInput) =>
    api<ApiKey>(`/api/admin/v1/tenant/api-keys/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  revoke: (uuid: string) =>
    api<{ uuid: string; status: string }>(`/api/admin/v1/tenant/api-keys/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

// =====================================================================
// F01 §3.5.1: 租户组织同步 Webhook 管理 (/api/admin/v1/tenant/org-webhooks)
// =====================================================================

export type OrgWebhookDelivery = {
  id: number
  eventType: string
  callbackUrl: string
  status: 'pending' | 'picked' | 'failed' | 'done' | 'dlq' | string
  attempts: number
  nextRetryAt?: string
  lastError?: string
  doneAt?: string
  createdAt: string
}

export type OrgWebhook = {
  uuid: string
  name: string
  callbackUrl: string
  enabled: boolean
  eventTypes: string[]
  description?: string
  createdAt: string
  updatedAt: string
  latestDelivery?: OrgWebhookDelivery
  hasSecret: boolean
}

export type CreateOrgWebhookInput = {
  name: string
  callbackUrl: string
  enabled?: boolean
  eventTypes: string[]
  description?: string
}

export type PatchOrgWebhookInput = {
  name?: string
  callbackUrl?: string
  enabled?: boolean
  eventTypes?: string[]
  description?: string
}

export type OrgWebhookSecretResult = {
  webhook: OrgWebhook
  secret: string
}

export const OrgWebhooks = {
  list: () =>
    api<{ items: OrgWebhook[]; total: number }>('/api/admin/v1/tenant/org-webhooks'),
  create: (body: CreateOrgWebhookInput) =>
    api<OrgWebhookSecretResult>('/api/admin/v1/tenant/org-webhooks', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: PatchOrgWebhookInput) =>
    api<OrgWebhook>(`/api/admin/v1/tenant/org-webhooks/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  remove: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/tenant/org-webhooks/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  rotateSecret: (uuid: string) =>
    api<OrgWebhookSecretResult>(`/api/admin/v1/tenant/org-webhooks/${encodeURIComponent(uuid)}/rotate-secret`, {
      method: 'POST',
    }),
  test: (uuid: string) =>
    api<{ statusCode: number; message: string }>(`/api/admin/v1/tenant/org-webhooks/${encodeURIComponent(uuid)}/test`, {
      method: 'POST',
    }),
  deliveries: (uuid: string, limit = 20) =>
    api<{ items: OrgWebhookDelivery[]; total: number }>(
      `/api/admin/v1/tenant/org-webhooks/${encodeURIComponent(uuid)}/deliveries?limit=${limit}`
    ),
}

// =====================================================================
// M4 (F01 §4.3): 租户 SSO IdP 配置 (/api/admin/v1/tenant/identity-providers)
// 公开 IdP 列表 (Login 页) + OIDC start (/api/agent-bus/v1/auth/login/oidc/start)
// =====================================================================

export type IdentityProviderKind = 'oidc' | 'saml' | 'ldap' | 'scim'

export type IdentityProvider = {
  uuid: string
  tenantId: number
  kind: IdentityProviderKind
  name: string
  issuer?: string
  clientId?: string
  redirectUri?: string
  scopes: string[]
  settings: Record<string, unknown>
  status: 'active' | 'disabled'
  createdAt: string
  updatedAt: string
}

export type CreateIdentityProviderInput = {
  kind: IdentityProviderKind
  name: string
  issuer?: string
  clientId?: string
  clientSecret?: string
  redirectUri?: string
  scopes?: string[]
  settings?: Record<string, unknown>
}

export type PatchIdentityProviderInput = Partial<CreateIdentityProviderInput> & {
  status?: 'active' | 'disabled'
}

export const IdentityProviders = {
  list: () =>
    api<{ items: IdentityProvider[] }>('/api/admin/v1/tenant/identity-providers'),
  create: (body: CreateIdentityProviderInput) =>
    api<IdentityProvider>('/api/admin/v1/tenant/identity-providers', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: PatchIdentityProviderInput) =>
    api<IdentityProvider>(`/api/admin/v1/tenant/identity-providers/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  remove: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/tenant/identity-providers/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

// ----- 公开端点 (Login 页用; 不鉴权) -----

export type PublicIdentityProvider = {
  uuid: string
  name: string
  kind: IdentityProviderKind
}

export type OIDCStartResp = {
  authUrl: string
  state: string
}

// 这里**不**走 api() 的 token 注入逻辑; 公开端点无需 Authorization 头。
// 直接用 fetch + ResponseInterceptor 兼容外壳。
export const PublicAuth = {
  listIdentityProviders: async (): Promise<PublicIdentityProvider[]> => {
    const r = await fetch('/api/admin/v1/auth/identity-providers/public')
    const body = await r.json()
    if (!r.ok || body.success === false) {
      throw new Error(body.message || `HTTP ${r.status}`)
    }
    return body.data?.items || []
  },
  oidcStart: async (providerUuid: string, afterRedirect?: string): Promise<OIDCStartResp> => {
    const r = await fetch('/api/admin/v1/auth/login/oidc/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ providerUuid, afterRedirect }),
    })
    const body = await r.json()
    if (!r.ok || body.success === false) {
      throw new Error(body.message || `HTTP ${r.status}`)
    }
    return body.data
  },
  oidcCallback: async (code: string, state: string): Promise<LoginResp> => {
    const r = await fetch('/api/admin/v1/auth/login/oidc/callback', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, state }),
    })
    const body = await r.json()
    if (!r.ok || body.success === false) {
      throw new Error(body.message || `HTTP ${r.status}`)
    }
    return body.data
  },
}

// =====================================================================
// M2 (F01 §3.6): 自定义 Agent SDK 凭证管理
// /api/admin/v1/tenant/agent-sdk-credentials
// =====================================================================

export type AgentSdkCapability =
  | 'kb.read'
  | 'zhiban.kb.search'
  | 'drive.read'
  | 'memory.read'
  | 'memory.write'
  | 'notification.write'
  | 'chat.message.write'
  | 'chat.file.read'
  | 'org.read'
  | 'a2a.invoke'
  | 'platform.tenant.provision'

export type AgentSdkCredential = {
  uuid: string
  name: string
  clientId: string
  capabilityBindings: AgentSdkCapability[]
  runtimeRegistrationId?: number | null
  scope?: 'tenant' | 'platform'
  tenantGrantMode?: 'all_enabled' | 'allowlist'
  allowedTenantIds?: number[]
  status: 'active' | 'revoked'
  lastUsedAt?: string
  createdAt: string
  updatedAt: string
  revokedAt?: string
}

export type CreateAgentSdkCredentialInput = {
  name: string
  capabilityBindings: AgentSdkCapability[]
  runtimeRegistrationId?: number | null
}

export type CreatePlatformAgentSdkCredentialInput = {
  name: string
  capabilityBindings: AgentSdkCapability[]
  runtimeEnvironmentId: number
  tenantGrantMode: 'all_enabled' | 'allowlist'
  allowedTenantIds?: number[]
}

export type CreateAgentSdkCredentialResult = {
  credential: AgentSdkCredential
  clientSecret: string // 一次性明文 sk_xxxx; 关闭后不可恢复
}

export type PatchAgentSdkCredentialInput = {
  name?: string
  capabilityBindings?: AgentSdkCapability[]
}

export const AgentSdkCredentials = {
  list: () =>
    api<{ items: AgentSdkCredential[] }>('/api/admin/v1/tenant/agent-sdk-credentials'),
  listPlatform: () =>
    api<{ items: AgentSdkCredential[] }>('/api/admin/v1/platform/agent-sdk-credentials'),
  create: (body: CreateAgentSdkCredentialInput) =>
    api<CreateAgentSdkCredentialResult>('/api/admin/v1/tenant/agent-sdk-credentials', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  createPlatform: (body: CreatePlatformAgentSdkCredentialInput) =>
    api<CreateAgentSdkCredentialResult>('/api/admin/v1/platform/agent-sdk-credentials', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: PatchAgentSdkCredentialInput) =>
    api<AgentSdkCredential>(`/api/admin/v1/tenant/agent-sdk-credentials/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  revoke: (uuid: string) =>
    api<{ uuid: string; status: string }>(`/api/admin/v1/tenant/agent-sdk-credentials/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  revokePlatform: (uuid: string) =>
    api<{ uuid: string; status: string }>(`/api/admin/v1/platform/agent-sdk-credentials/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

// =====================================================================
// 技能中心 — 平台 admin / 租户 admin API
// docs/features/F03-skills.md
// =====================================================================

export type Skill = {
  id: number
  uuid: string
  code: string
  name: string
  description?: string
  usage_example?: string
  usage_example_images?: SkillUsageExampleImage[]
  icon_url?: string
  placeholder?: string
  submit_label?: string
  kind: 'agent' | 'builtin'
  builtin_key?: string
  execution_mode: 'synchronous_inline' | 'asynchronous_floating'
  scope_kind: 'platform' | 'tenant'
  tenant_id?: number
  source: 'internal' | 'open_source' | 'third_party'
  visibility: 'private' | 'workspace' | 'tenant' | 'platform'
  category_id?: number
  input_chips_schema: unknown[]
  hosting_modes: string[]
  agent_compat: Record<string, unknown>
  label_ids: number[]
  default_attached: boolean
  default_pinned: boolean
  sort_order: number
  latest_version_id?: number
  status: 'draft' | 'active' | 'archived'
  install_count: number
  marketing_visible: boolean
  billing_type?: 'free' | 'paid'
  pricing_mode?: 'per_skill' | 'per_operation'
  default_credits?: number | null
  operation_count?: number
  created_at: string
  updated_at: string
}

export type SkillUsageExampleImage = {
  storage_uri?: string
  url: string
  file_name?: string
}

export type SkillVersion = {
  id?: number
  uuid: string
  version: string
  status: 'draft' | 'published' | 'archived'
  changelog?: string
  package_url?: string
  package_sha256?: string
  package_size_bytes?: number
  input_chips_schema_snapshot?: unknown[]
  agent_compat_snapshot?: Record<string, unknown>
  grayscale_pct: number
  grayscale_strategy: string
  grayscale_allowlist?: number[]
  published_at?: string
  created_at: string
  updated_at: string
}

export type SkillCategory = { id: number; code: string; name: string; category_kind: string; description?: string; sort_order: number; status: string; is_deleted?: boolean; created_at?: string; updated_at?: string }
export type SkillLabel = { id: number; code: string; name: string; description?: string; sort_order: number; status: string; is_deleted?: boolean; created_at?: string; updated_at?: string }
export type SkillBuiltinKey = {
  id: number; code: string; name: string; status: string;
  is_deleted?: boolean;
  description?: string;
  supported_platforms: string[];
  min_client_versions?: unknown;
  default_execution_mode?: string;
  default_native_capabilities?: string[];
  registered_at?: string;
  updated_at?: string;
}

export type CreateSkillInput = {
  code: string
  name: string
  description?: string
  usage_example?: string
  usage_example_images?: Array<{ storage_uri: string; file_name?: string }>
  icon_url?: string
  placeholder?: string
  submit_label?: string
  kind: 'agent' | 'builtin'
  builtin_key?: string
  execution_mode: 'synchronous_inline' | 'asynchronous_floating'
  source: 'internal' | 'open_source' | 'third_party'
  visibility: 'private' | 'workspace' | 'tenant' | 'platform'
  category_id?: number
  label_ids?: number[]
  hosting_modes?: string[]
  agent_compat?: Record<string, unknown>
  input_chips_schema?: unknown[]
  default_attached?: boolean
  default_pinned?: boolean
  sort_order?: number
}

export type PatchSkillInput = Partial<{
  name: string
  description: string
  usage_example: string
  usage_example_images: Array<{ storage_uri: string; file_name?: string }>
  icon_url: string
  placeholder: string
  submit_label: string
  execution_mode: 'synchronous_inline' | 'asynchronous_floating'
  visibility: 'private' | 'workspace' | 'tenant' | 'platform'
  source: 'internal' | 'open_source' | 'third_party'
  category_id: number
  label_ids: number[]
  hosting_modes: string[]
  agent_compat: Record<string, unknown>
  input_chips_schema: unknown[]
  default_attached: boolean
  default_pinned: boolean
  sort_order: number
  status: 'draft' | 'active' | 'archived'
  marketing_visible: boolean
}>

export type SkillBundleImportItem = {
  code: string
  version: string
  status: 'created' | 'updated' | 'skipped' | 'conflict' | 'failed'
  message?: string
}

export type SkillBundleImportResult = {
  bundle_sha256: string
  created: number
  updated: number
  skipped: number
  conflict: number
  failed: number
  items: SkillBundleImportItem[]
}

type SkillListParams = {
  q?: string
  status?: string
  execution_mode?: string
  limit?: number
  offset?: number
}

function queryString(params: Record<string, unknown> = {}) {
  const q = new URLSearchParams()
  Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== '') q.set(k, String(v))
  })
  const qs = q.toString()
  return qs ? `?${qs}` : ''
}

export const PlatformSkills = {
  list: (params: { kind?: string; status?: string; q?: string; category_id?: number; billing_type?: string; pricing_mode?: string; default_price?: string; operations?: string; limit?: number; offset?: number } = {}) => {
    return api<{ items: Skill[]; total: number }>(`/api/admin/v1/platform/skills${queryString(params)}`)
  },
  get: (uuid: string) => api<Skill>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}`),
  create: (body: CreateSkillInput) =>
    api<{ uuid: string; code: string; status: string; auto_created_version_uuid?: string | null }>(
      '/api/admin/v1/platform/skills', { method: 'POST', body: JSON.stringify(body) }),
  patch: (uuid: string, body: PatchSkillInput) =>
    api<Skill>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}`, {
      method: 'PATCH', body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<void>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),

  exportBundle: async (skillUUIDs: string[], filename?: string) => {
    beginLoading()
    try {
      await downloadFile(
        '/api/admin/v1/platform/skills:export',
        { method: 'POST', body: JSON.stringify({ skill_uuids: skillUUIDs }) },
        'skills.skillbundle.zip',
        filename,
      )
    } finally {
      endLoading()
    }
  },
  importBundle: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<SkillBundleImportResult>(
      '/api/admin/v1/platform/skills:import',
      { method: 'POST', body: fd },
    )
  },
  batchDelete: (skillUUIDs: string[]) =>
    api<{ deleted: number; items: Array<{ uuid: string; code: string }> }>(
      '/api/admin/v1/platform/skills:batchDelete',
      { method: 'POST', body: JSON.stringify({ skill_uuids: skillUUIDs }) },
    ),

  listVersions: (uuid: string) =>
    api<{ items: SkillVersion[] }>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions`),
  createAgentVersion: (uuid: string, body: {
    version: string; changelog?: string; package_url: string; package_sha256: string; package_size_bytes: number;
    input_chips_schema_snapshot: unknown[]; agent_compat_snapshot?: Record<string, unknown>;
  }) => api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions`, {
    method: 'POST', body: JSON.stringify(body),
  }),
  createBuiltinVersion: (uuid: string, body: { version: string; changelog?: string; grayscale_pct?: number; grayscale_strategy?: string; grayscale_allowlist?: number[] }) =>
    api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/builtin-versions`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  patchVersion: (uuid: string, vuuid: string, body: Partial<{ changelog: string; grayscale_pct: number; grayscale_strategy: string; grayscale_allowlist: number[] }>) =>
    api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}`, {
      method: 'PATCH', body: JSON.stringify(body),
    }),
  publish: (uuid: string, vuuid: string, body: Partial<{ grayscale_pct: number; grayscale_strategy: string; grayscale_allowlist: number[] }> = {}) =>
    api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/publish`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  archive: (uuid: string, vuuid: string) =>
    api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/archive`, {
      method: 'POST',
    }),
  rollback: (uuid: string, vuuid: string) =>
    api<SkillVersion>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/rollback`, {
      method: 'POST',
    }),

  listCategories: (params: SkillListParams = {}) =>
    api<{ items: SkillCategory[]; total: number; limit?: number; offset?: number }>(`/api/admin/v1/platform/skill-categories${queryString(params)}`),
  listLabels: (params: SkillListParams = {}) =>
    api<{ items: SkillLabel[]; total: number; limit?: number; offset?: number }>(`/api/admin/v1/platform/skill-labels${queryString(params)}`),
  listBuiltinKeys: (params: SkillListParams = {}) =>
    api<{ items: SkillBuiltinKey[]; total: number; limit?: number; offset?: number }>(`/api/admin/v1/platform/builtin-skill-keys${queryString(params)}`),

  createCategory: (body: { code: string; name: string; category_kind?: 'foundation' | 'scenario'; description?: string; sort_order?: number }) =>
    api<SkillCategory>('/api/admin/v1/platform/skill-categories', { method: 'POST', body: JSON.stringify(body) }),
  patchCategory: (id: number, body: Partial<{ code: string; name: string; description: string; sort_order: number; status: string }>) =>
    api<SkillCategory>(`/api/admin/v1/platform/skill-categories/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  deleteCategory: (id: number) =>
    api<{ id: number; deleted: boolean }>(`/api/admin/v1/platform/skill-categories/${id}`, { method: 'DELETE' }),

  createLabel: (body: { code: string; name: string; description?: string; sort_order?: number }) =>
    api<SkillLabel>('/api/admin/v1/platform/skill-labels', { method: 'POST', body: JSON.stringify(body) }),
  patchLabel: (id: number, body: Partial<{ code: string; name: string; description: string; sort_order: number; status: string }>) =>
    api<SkillLabel>(`/api/admin/v1/platform/skill-labels/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  deleteLabel: (id: number) =>
    api<{ id: number; deleted: boolean }>(`/api/admin/v1/platform/skill-labels/${id}`, { method: 'DELETE' }),

  createBuiltinKey: (body: {
    code: string; name: string; description?: string;
    supported_platforms: string[];
    min_client_versions?: unknown;
    default_execution_mode: string;
    default_native_capabilities?: string[];
    status?: 'active' | 'deprecated';
  }) =>
    api<SkillBuiltinKey>('/api/admin/v1/platform/builtin-skill-keys', { method: 'POST', body: JSON.stringify(body) }),
  patchBuiltinKey: (id: number, body: Partial<{
    name: string; description: string;
    supported_platforms: string[]; min_client_versions: unknown;
    default_execution_mode: string; default_native_capabilities: string[];
    status: 'active' | 'deprecated';
  }>) =>
    api<SkillBuiltinKey>(`/api/admin/v1/platform/builtin-skill-keys/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  deleteBuiltinKey: (id: number) =>
    api<{ id: number; deleted: boolean }>(`/api/admin/v1/platform/builtin-skill-keys/${id}`, { method: 'DELETE' }),

  preview: (uuid: string, body: { version_uuid?: string; params: Record<string, unknown> }) =>
    api<{
      skill_uuid: string; version: string; version_uuid?: string;
      user_message_metadata_sample: Record<string, unknown>;
      validation_errors?: string[];
    }>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/preview`, {
      method: 'POST', body: JSON.stringify(body),
    }),

  // SKILL.md zip 上传：multipart 直传到 admin → bus 落 OSS。
  uploadPackage: async (uuid: string, vuuid: string, file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<{
      storage_key: string;
      package_url_placeholder: string;
      package_size_bytes: number;
      package_sha256: string;
      input_chips_schema_snapshot?: unknown[];
    }>(
      `/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/upload-package`,
      { method: 'POST', body: fd },
    )
  },
  // F03 §4.7 R1：版本文件浏览（zip 投影到 skill_version_files）。
  listVersionFiles: (uuid: string, vuuid: string) =>
    api<{
      items: Array<{
        path: string
        size_bytes: number
        sha256: string
        content_type: string
        is_binary: boolean
        truncated: boolean
      }>
      total: number
    }>(`/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/files`),
  getVersionFileContent: (uuid: string, vuuid: string, path: string) =>
    api<{
      path: string
      size_bytes: number
      sha256: string
      content_type: string
      is_binary: boolean
      truncated: boolean
      content: string
      total_lines: number
    }>(
      `/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/file-content?path=${encodeURIComponent(path)}`,
    ),
  getVersionDownloadURL: (uuid: string, vuuid: string) =>
    api<{ url: string }>(
      `/api/admin/v1/platform/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/download-url`,
    ),

  // 图标上传：multipart 直传到 admin → bus 落 OSS（skill-icons/<sha256>.<ext>）。
  // storage_uri 是 oss:// 形态，admin 把它作为 icon_url 提交给 create / patch；
  // signed_url 仅供即时预览/回显（TTL = 后端 cfg.CDNDownloadTTL，默认 1h）。
  uploadIcon: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<MediaUploadResult>(
      '/api/admin/v1/platform/media/skill-icons/upload',
      { method: 'POST', body: fd },
    )
  },
  uploadExampleImage: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<MediaUploadResult>(
      '/api/admin/v1/platform/media/skill-example-images/upload',
      { method: 'POST', body: fd },
    )
  },
}

// TenantSkill 是 GET /api/admin/v1/tenant/skills 返回项 — 平台技能 + 本租户技能 + tenant 覆盖。
// 比 Skill 多 tenant_disabled / disable_reason / tenant_preference。
export type TenantSkill = Skill & {
  tenant_disabled: boolean
  disable_reason?: string
  tenant_preference?: 'force_on' | 'force_off' | ''
}

// F03 §3.2 租户自建技能 CRUD (后端 P1 收口后补齐)。
// 与 PlatformSkills 同款 API 形状, 仅 URL 前缀从 /platform/ → /tenant/。
// 由 TenantSkills 命名空间承载, 不污染 platform 域。
export const TenantOwnSkills = {
  create: (body: CreateSkillInput) =>
    api<{ uuid: string; code: string; status: string; auto_created_version_uuid?: string | null }>(
      '/api/admin/v1/tenant/skills', { method: 'POST', body: JSON.stringify(body) }),
  get: (uuid: string) =>
    api<Skill>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}`),
  patch: (uuid: string, body: PatchSkillInput) =>
    api<Skill>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}`, {
      method: 'PATCH', body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<void>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),

  // 版本管理 — 镜像 PlatformSkills 同款方法。
  createAgentVersion: (uuid: string, body: {
    version: string; changelog?: string; package_url: string; package_sha256: string; package_size_bytes: number;
    input_chips_schema_snapshot: unknown[]; agent_compat_snapshot?: Record<string, unknown>;
  }) => api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions`, {
    method: 'POST', body: JSON.stringify(body),
  }),
  createBuiltinVersion: (uuid: string, body: { version: string; changelog?: string; grayscale_pct?: number; grayscale_strategy?: string; grayscale_allowlist?: number[] }) =>
    api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/builtin-versions`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  patchVersion: (uuid: string, vuuid: string, body: Partial<{ changelog: string; grayscale_pct: number; grayscale_strategy: string; grayscale_allowlist: number[] }>) =>
    api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}`, {
      method: 'PATCH', body: JSON.stringify(body),
    }),
  publish: (uuid: string, vuuid: string, body: Partial<{ grayscale_pct: number; grayscale_strategy: string; grayscale_allowlist: number[] }> = {}) =>
    api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/publish`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  archive: (uuid: string, vuuid: string) =>
    api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/archive`, {
      method: 'POST',
    }),
  rollback: (uuid: string, vuuid: string) =>
    api<SkillVersion>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/rollback`, {
      method: 'POST',
    }),
  uploadPackage: async (uuid: string, vuuid: string, file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<{
      storage_key: string;
      package_url_placeholder: string;
      package_size_bytes: number;
      package_sha256: string;
      input_chips_schema_snapshot?: unknown[];
    }>(
      `/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/upload-package`,
      { method: 'POST', body: fd },
    )
  },

  // 版本列表 (TenantListSkillVersions 只返 published; 与 PlatformSkills.listVersions 同名)
  listVersions: (uuid: string) =>
    api<{ items: SkillVersion[] }>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions`),
  listVersionFiles: (uuid: string, vuuid: string) =>
    api<{
      items: Array<{
        path: string
        size_bytes: number
        sha256: string
        content_type: string
        is_binary: boolean
        truncated: boolean
      }>
      total: number
    }>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/files`),
  getVersionFileContent: (uuid: string, vuuid: string, path: string) =>
    // shape 与 PlatformSkills.getVersionFileContent 对齐 (后端返回字段同款)
    api<{
      path: string
      size_bytes: number
      sha256: string
      content_type: string
      is_binary: boolean
      truncated: boolean
      content: string
      total_lines: number
    }>(
      `/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/file-content?path=${encodeURIComponent(path)}`,
    ),
  getVersionDownloadURL: (uuid: string, vuuid: string) =>
    api<{ url: string }>(  // shape 与 PlatformSkills 对齐
      `/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions/${encodeURIComponent(vuuid)}/download-url`,
    ),

  // 图标上传 — 后端独立 endpoint /tenant/skills/upload-icon
  uploadIcon: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    // shape 与 PlatformSkills.uploadIcon 对齐 (后端 handler 同一个)
    return api<MediaUploadResult>(
      '/api/admin/v1/tenant/media/skill-icons/upload',
      { method: 'POST', body: fd },
    )
  },
  uploadExampleImage: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<MediaUploadResult>(
      '/api/admin/v1/tenant/media/skill-example-images/upload',
      { method: 'POST', body: fd },
    )
  },

  // 字典只读镜像 (后端复用 platform handler, 仅权限点改 tenant.skill.read)。
  // 租户技能页需要读分类 / 标签 / builtin keys 字典, 不能直接调 platform 路径 (会 403)。
  listCategories: (params: SkillListParams = {}) =>
    api<{ items: SkillCategory[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/tenant/skill-categories${queryString(params)}`),
  listLabels: (params: SkillListParams = {}) =>
    api<{ items: SkillLabel[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/tenant/skill-labels${queryString(params)}`),
  listBuiltinKeys: (params: SkillListParams = {}) =>
    api<{ items: SkillBuiltinKey[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/tenant/builtin-skill-keys${queryString(params)}`),
}

export const TenantSkills = {
  // 租户视角技能列表（GET /api/admin/v1/tenant/skills）。
  // tenant.skill.read 即可，避免后台调 platform 路由。
  list: (params: { kind?: string; status?: string; q?: string; limit?: number; offset?: number } = {}) => {
    const q = new URLSearchParams()
    Object.entries(params).forEach(([k, v]) => {
      if (v !== undefined && v !== null && v !== '') q.set(k, String(v))
    })
    const qs = q.toString()
    return api<{ items: TenantSkill[]; total: number }>(`/api/admin/v1/tenant/skills${qs ? '?' + qs : ''}`)
  },
  listVersions: (uuid: string) =>
    api<{ items: SkillVersion[] }>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/versions`),

  disable: (uuid: string, body: { disable_reason?: string } = {}) =>
    api<{ disabled_at: string }>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/disable`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  enable: (uuid: string) =>
    api<void>(`/api/admin/v1/tenant/skills/${encodeURIComponent(uuid)}/disable`, { method: 'DELETE' }),
  listPreferences: () =>
    api<{ items: { skill_uuid: string; skill_code: string; skill_name: string; behavior: string; note?: string }[] }>(
      '/api/admin/v1/tenant/skill-preferences'),
  setPreference: (uuid: string, body: { behavior: 'force_on' | 'force_off'; note?: string }) =>
    api<{ behavior: string }>(`/api/admin/v1/tenant/skill-preferences/${encodeURIComponent(uuid)}`, {
      method: 'PUT', body: JSON.stringify(body),
    }),
  clearPreference: (uuid: string) =>
    api<void>(`/api/admin/v1/tenant/skill-preferences/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),

  listAgentSkills: (agentUUID: string) =>
    api<{ items: { binding_id: number; skill_uuid: string; skill_code: string; skill_name: string; pinned: boolean; sort_order: number; pinned_version_id?: number; default_params: unknown; source: string }[] }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/skills`),
  listAvailableSkills: (agentUUID: string) =>
    api<{ items: { skill_uuid: string; code: string; name: string; scope_kind: string; kind: string; icon_url?: string; is_attached: boolean; is_default_attached: boolean; tenant_preference?: string }[] }>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/skills/available`),
  attachAgentSkill: (agentUUID: string, body: { skill_uuid: string; pinned?: boolean; sort_order?: number; pinned_version_id?: number; default_params?: unknown; source?: string }) =>
    api<{ binding_id: number }>(`/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/skills`, {
      method: 'POST', body: JSON.stringify(body),
    }),
  patchBinding: (agentUUID: string, bindingID: number, body: Partial<{ pinned: boolean; sort_order: number; pinned_version_id: number; clear_pinned_version: boolean; default_params: unknown }>) =>
    api<{ binding_id: number }>(`/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/skills/${bindingID}`, {
      method: 'PATCH', body: JSON.stringify(body),
    }),
  detachBinding: (agentUUID: string, bindingID: number) =>
    api<void>(`/api/admin/v1/tenant/agents/${encodeURIComponent(agentUUID)}/skills/${bindingID}`, {
      method: 'DELETE',
    }),
}

// =====================================================================
// JWT claim 解析 (前端用; 不验证签名, 仅展示 / UI 状态用)
// =====================================================================

export type AccessTokenClaims = {
  aid?: number       // account id
  sid?: string       // session uuid
  act_scope?: string // platform / tenant / workspace
  act_tid?: number   // tenant id
  perms?: string[]
  acting_as?: string // 'platform_admin' = impersonate 模式
  kind?: string      // 'impersonation' = 这是 impersonate token
  exp?: number
}

// parseAccessToken 解 base64 中间段; 失败返 null (不抛, 不报错)。
export function parseAccessToken(token?: string): AccessTokenClaims | null {
  const t = (token || auth.token() || '').split('.')
  if (t.length < 2) return null
  try {
    // base64url → base64 → JSON
    const seg = t[1].replace(/-/g, '+').replace(/_/g, '/')
    const padded = seg + '='.repeat((4 - (seg.length % 4)) % 4)
    return JSON.parse(atob(padded))
  } catch {
    return null
  }
}

// =====================================================================
// F01 §4.5: /me/sessions 多设备管理
// =====================================================================

export type MySession = {
  uuid: string
  issuedAt: string
  expiresAt: string
  lastUsedAt: string
  userAgent?: string
  ip?: string
  actingAs?: string
  isCurrent: boolean
}

export const MySessions = {
  list: () =>
    api<{ items: MySession[] }>('/api/admin/v1/me/sessions'),
  revoke: (uuid: string) =>
    api<{ uuid: string; revoked: boolean }>(`/api/admin/v1/me/sessions/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

// =====================================================================
// F04: 应用管理 (/api/admin/v1/tenant/apps + app-categories + agents/{uuid}/apps)
// =====================================================================

export type App = {
  uuid: string
  code: string
  name: string
  description?: string
  iconUrl?: string
  color?: string
  displayMode: 'side_panel' | 'fullscreen' | 'external_browser'
  usageScope: 'all' | 'end_user' | 'agent'
  launchUri: string
  categoryUuid?: string
  sortOrder: number
  status: 'active' | 'disabled' | 'revoked'
  isSystem?: boolean
  openToTenants?: boolean
  isUniversal?: boolean
  isEnabled?: boolean
  createdAt: string
}

export type AppOAuthClient = {
  clientId: string
  clientSecret?: string // 仅创建 / rotate 时返
  redirectUris: string[]
  scopes: string[]
  tokenEndpoint?: string
  issuer?: string
  jwksUri?: string
  discoveryUri?: string
  accessTokenTtlSeconds: number
  refreshTokenTtlSeconds: number
  status: 'active' | 'revoked'
}

export type CreateAppInput = {
  code: string
  name: string
  description?: string
  iconUrl?: string
  color?: string
  displayMode: 'side_panel' | 'fullscreen' | 'external_browser'
  usageScope?: 'all' | 'end_user' | 'agent'
  launchUri: string
  redirectUris: string[]
  scopes: string[]
  categoryUuid?: string
  openToTenants?: boolean
  accessTokenTtlSeconds?: number
  refreshTokenTtlSeconds?: number
}

export type CreateAppResult = {
  app: App
  oauthClient: AppOAuthClient
}

export type AppDetail = {
  app: App
  oauthClient?: AppOAuthClient
}

export type AppCategory = {
  uuid: string
  code: string
  name: string
  sortOrder: number
  isSystem: boolean
}

type AppListParams = { workspaceOnly?: boolean; status?: string; keyword?: string; categoryId?: number; usageScope?: string; limit?: number; offset?: number }

export const Apps = {
  list: (params?: AppListParams) => {
    const q = new URLSearchParams()
    if (params?.status) q.set('status', params.status)
    if (params?.keyword) q.set('keyword', params.keyword)
    if (params?.categoryId) q.set('category_id', String(params.categoryId))
    if (params?.usageScope) q.set('usageScope', params.usageScope)
    if (params?.workspaceOnly) q.set('workspace_only', 'true')
    if (params?.limit != null) q.set('limit', String(params.limit))
    if (params?.offset != null) q.set('offset', String(params.offset))
    const suffix = q.toString() ? '?' + q.toString() : ''
    return api<{ items: App[]; total: number; limit?: number; offset?: number; readOnlyReason?: string }>('/api/admin/v1/tenant/apps' + suffix)
  },
  get: (uuid: string) =>
    api<AppDetail>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}`),
  create: (body: CreateAppInput) =>
    api<CreateAppResult>('/api/admin/v1/tenant/apps', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: Partial<CreateAppInput> & { sortOrder?: number; status?: string }) =>
    api<App>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  rotateSecret: (uuid: string) =>
    api<{ clientSecret: string }>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}/secret/rotate`, {
      method: 'POST',
    }),
  launchTest: (uuid: string) =>
    api<{ uuid: string; launchUrl: string; displayMode: string; status: string }>(
      `/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}/launch-test`,
    ),
  setUniversal: (uuid: string, isUniversal: boolean, sortOrder: number) =>
    api<{ uuid: string; isUniversal: boolean }>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}/universal`, {
      method: 'PATCH',
      body: JSON.stringify({ isUniversal, sortOrder }),
    }),
  setEnabled: (uuid: string, isEnabled: boolean) =>
    api<{ uuid: string; isEnabled: boolean }>(`/api/admin/v1/tenant/apps/${encodeURIComponent(uuid)}/enabled`, {
      method: 'PATCH',
      body: JSON.stringify({ isEnabled }),
    }),
}

export const PlatformApps = {
  list: (params?: AppListParams) => {
    const q = new URLSearchParams()
    if (params?.status) q.set('status', params.status)
    if (params?.keyword) q.set('keyword', params.keyword)
    if (params?.categoryId) q.set('category_id', String(params.categoryId))
    if (params?.usageScope) q.set('usageScope', params.usageScope)
    if (params?.workspaceOnly) q.set('workspace_only', 'true')
    if (params?.limit != null) q.set('limit', String(params.limit))
    if (params?.offset != null) q.set('offset', String(params.offset))
    const suffix = q.toString() ? '?' + q.toString() : ''
    return api<{ items: App[]; total: number; limit?: number; offset?: number; readOnlyReason?: string }>('/api/admin/v1/platform/apps' + suffix)
  },
  get: (uuid: string) =>
    api<AppDetail>(`/api/admin/v1/platform/apps/${encodeURIComponent(uuid)}`),
  create: (body: CreateAppInput) =>
    api<CreateAppResult>('/api/admin/v1/platform/apps', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: Partial<CreateAppInput> & { sortOrder?: number; status?: string }) =>
    api<App>(`/api/admin/v1/platform/apps/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/platform/apps/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  rotateSecret: (uuid: string) =>
    api<{ clientSecret: string }>(`/api/admin/v1/platform/apps/${encodeURIComponent(uuid)}/secret/rotate`, {
      method: 'POST',
    }),
  launchTest: (uuid: string) =>
    api<{ uuid: string; launchUrl: string; displayMode: string; status: string }>(
      `/api/admin/v1/platform/apps/${encodeURIComponent(uuid)}/launch-test`,
    ),
}

export const AgentApps = {
  list: (agentUuid: string) =>
    api<{ items: App[] }>(`/api/admin/v1/tenant/agents/${encodeURIComponent(agentUuid)}/apps`),
  bind: (agentUuid: string, appUuids: string[]) =>
    api<{ agentUuid: string; appUuids: string[] }>(`/api/admin/v1/tenant/agents/${encodeURIComponent(agentUuid)}/apps`, {
      method: 'PUT',
      body: JSON.stringify({ appUuids }),
    }),
}

export const AppCategories = {
  list: (params?: { limit?: number; offset?: number }) =>
    api<{ items: AppCategory[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/tenant/app-categories${queryString(params || {})}`,
    ),
  create: (body: { code: string; name: string; sortOrder?: number }) =>
    api<AppCategory>('/api/admin/v1/tenant/app-categories', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: { code?: string; name?: string; sortOrder?: number }) =>
    api<AppCategory>(`/api/admin/v1/tenant/app-categories/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/tenant/app-categories/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

export const PlatformAppCategories = {
  list: (params?: { limit?: number; offset?: number }) =>
    api<{ items: AppCategory[]; total: number; limit?: number; offset?: number }>(
      `/api/admin/v1/platform/app-categories${queryString(params || {})}`,
    ),
  create: (body: { code: string; name: string; sortOrder?: number }) =>
    api<AppCategory>('/api/admin/v1/platform/app-categories', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: { code?: string; name?: string; sortOrder?: number }) =>
    api<AppCategory>(`/api/admin/v1/platform/app-categories/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(`/api/admin/v1/platform/app-categories/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

// =====================================================================
// F18: 平台客户端安装包版本管理
// =====================================================================

export type ClientVersionPlatform = 'macos' | 'windows' | 'ios' | 'android'
export type ClientVersionArch = 'universal' | 'arm64' | 'x64'
export type ClientVersionChannel = 'stable' | 'beta' | 'dev'
export type ClientVersionStatus = 'draft' | 'published' | 'archived'

export type ClientVersionDelta = {
  file_name: string
  delta_from: string
  size_bytes: number
  sha256: string
  ed_signature: string
}

export type ClientVersion = {
  uuid: string
  platform: ClientVersionPlatform
  arch: ClientVersionArch
  channel: ClientVersionChannel
  version: string
  build_number: string
  title: string
  release_notes: string
  download_url: string
  download_url_raw?: string
  appcast_url: string
  appcast_url_raw?: string
  sparkle_ed_signature: string
  file_size_bytes: number
  sha256: string
  min_os_version: string
  min_supported_version: string
  is_forced: boolean
  status: ClientVersionStatus
  deltas?: ClientVersionDelta[]
  published_at?: string
  created_at: string
  updated_at: string
}

export type ClientVersionInput = {
  platform: ClientVersionPlatform
  arch: ClientVersionArch
  channel: ClientVersionChannel
  version: string
  build_number: string
  title?: string
  release_notes?: string
  download_url?: string
  appcast_url?: string
  sparkle_ed_signature?: string
  file_size_bytes?: number
  sha256?: string
  min_os_version?: string
  min_supported_version?: string
  is_forced?: boolean
  status: ClientVersionStatus
}

export const ClientVersions = {
  list: (params: { platform?: string; arch?: string; channel?: string; status?: string; q?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: ClientVersion[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/client-versions${queryString(params)}`,
    ),
  get: (uuid: string) =>
    api<{ item: ClientVersion }>(`/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}`),
  create: (body: ClientVersionInput) =>
    api<{ item: ClientVersion }>('/api/admin/v1/platform/client-versions', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: ClientVersionInput) =>
    api<{ item: ClientVersion }>(`/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
  uploadPackage: (uuid: string, file: File, onProgress?: (progress: UploadProgress) => void) => {
    const fd = new FormData()
    fd.append('file', file)
    return uploadMultipart<{
      storage_uri: string
      download_url: string
      file_name: string
      size_bytes: number
      sha256: string
      item: ClientVersion
    }>(`/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}/upload-package`, fd, onProgress)
  },
  uploadAppcast: (uuid: string, file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<{
      storage_uri: string
      download_url: string
      file_name: string
      size_bytes: number
      sha256: string
      item: ClientVersion
    }>(`/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}/upload-appcast`, {
      method: 'POST',
      body: fd,
    })
  },
  uploadDelta: (uuid: string, file: File, deltaFrom: string, edSignature: string, onProgress?: (progress: UploadProgress) => void) => {
    const fd = new FormData()
    fd.append('file', file)
    fd.append('delta_from', deltaFrom)
    fd.append('ed_signature', edSignature)
    return uploadMultipart<{ storage_uri: string; download_url: string; file_name: string; size_bytes: number; sha256: string; delta_from: string; ed_signature: string }>(
      `/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}/upload-delta`,
      fd,
      onProgress,
    )
  },
  // 下载接口要带 Bearer 才过 platformPerm，浏览器直接 window.open 新标签页不会带鉴权头
  // (401 unauthorized)；但也不能像 exportBundle 那样走 downloadFile 的 fetch+跟随
  // 302——签名 URL 落在跨域的 OSS host 上，没配 CORS，fetch 读那一跳的响应体会直接
  // 失败（真实验证过）。所以后端不 302，返回 JSON 签名 URL，这里 fetch 只打一跳
  // 同源的 admin API（带 Authorization，没有跨域读取问题），拿到 URL 后用
  // window.open 做一次普通页面跳转去下载——跳转不受 CORS 限制。
  downloadPackage: (uuid: string) =>
    api<{ download_url: string }>(
      `/api/admin/v1/platform/client-versions/${encodeURIComponent(uuid)}/download-package`,
    ),
}

export type ClientBuildJobStatus = 'queued' | 'dispatching' | 'running' | 'stopping' | 'cancelled' | 'succeeded' | 'failed'
export type ClientBuildJob = {
  uuid: string
  platform: ClientVersionPlatform
  arch: ClientVersionArch
  environment: 'test' | 'prod'
  channel: ClientVersionChannel
  version: string
  build_number: string
  release_notes: string
  is_forced: boolean
  generate_delta: boolean
  status: ClientBuildJobStatus
  attempt: number
  retry_of?: string
  client_version_uuid?: string
  error?: string
  created_at: string
  updated_at: string
}
export type ClientBuildLog = { seq: number; stream: 'stdout' | 'stderr' | 'system'; message: string; created_at: string }
export type ClientBuildInput = Pick<ClientBuildJob, 'platform' | 'arch' | 'channel' | 'version' | 'build_number' | 'release_notes' | 'is_forced' | 'generate_delta'>

export const ClientBuildJobs = {
  list: (params: { platform?: string; status?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: ClientBuildJob[]; total: number }>(`/api/admin/v1/platform/client-build-jobs${queryString(params)}`),
  get: (uuid: string) => api<{ item: ClientBuildJob }>(`/api/admin/v1/platform/client-build-jobs/${encodeURIComponent(uuid)}`),
  create: (body: ClientBuildInput) => api<{ item: ClientBuildJob }>('/api/admin/v1/platform/client-build-jobs', { method: 'POST', body: JSON.stringify(body) }),
  retry: (uuid: string) => api<{ item: ClientBuildJob }>(`/api/admin/v1/platform/client-build-jobs/${encodeURIComponent(uuid)}/retry`, { method: 'POST' }),
  stop: (uuid: string) => api<{ item: ClientBuildJob }>(`/api/admin/v1/platform/client-build-jobs/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),
  logs: (uuid: string, afterSeq = 0) => api<{ items: ClientBuildLog[] }>(`/api/admin/v1/platform/client-build-jobs/${encodeURIComponent(uuid)}/logs${queryString({ after_seq: afterSeq })}`),
}

// ===== F31 本地开发工具版本目录 admin API =====
// 平台维护 Codex / Claude 工具包版本：草稿 → 上传包 → 发布（灰度到租户 / 全量）→ 下线。
// 权限复用 platform.client_version.*。契约见 docs/features/F31-local-coding-tools-version-catalog-plan.md §3。

export type LocalCodingToolTarget = 'codex_cli' | 'claude_cli' | 'codex_desktop' | 'claude_desktop' | 'claude_code_host'
export type LocalCodingToolPlatform = 'macos' | 'windows'
export type LocalCodingToolArch = 'arm64' | 'x64' | 'universal'
export type LocalCodingToolLayout =
  | 'tarball_single' | 'tarball_member' | 'tarball_tree' | 'bare_binary' | 'app_bundle_zip'
  | 'app_bundle_dmg' | 'msix' | 'host_binary_npm_tgz' | 'host_bundle_tar_zst'
export type LocalCodingToolVersionStatus = 'draft' | 'canary' | 'current' | 'previous' | 'deprecated'

export type LocalCodingToolVersion = {
  uuid: string
  target_id: LocalCodingToolTarget
  platform: LocalCodingToolPlatform
  arch: LocalCodingToolArch
  version: string
  layout: LocalCodingToolLayout
  member: string
  storage_uri: string
  file_size_bytes: number
  sha256: string
  binary_sha256: string
  bundle_identifier: string
  team_identifier: string
  min_bridge_version: string
  min_app_version: string
  profile_version: string
  contract_check_ref: string
  release_notes: string
  status: LocalCodingToolVersionStatus
  canary_tenant_ids: number[]
  // 外链包搬入对象存储的进度：'' 未搬 / running / done / failed
  mirror_state: '' | 'running' | 'done' | 'failed'
  mirror_error?: string
  // 网盘分享链接（CDN 过渡）：Bus 对已发布的对象存储包定时生成，剩余不足 10 天重生成；空 = 未生成。
  share_code: string
  share_url: string
  share_expires_at?: string
  // 由工具版本自动同步录入（服务端按合同检查记录的固定前缀判定，不是独立字段）。
  auto_synced: boolean
  published_at?: string
  created_at: string
  updated_at: string
}

// 命令行与桌面工具版本自动同步：一轮对每个工具 × 平台的处理结果。
export type LocalCodingAutoSyncOutcome =
  | 'recorded'
  | 'published_canary'
  | 'published_current'
  | 'skipped_exists'
  | 'skipped_not_newer'
  | 'skipped_too_new'
  | 'skipped_disabled'
  | 'failed'

export type LocalCodingAutoSyncResult = {
  target_id: LocalCodingToolTarget
  platform: LocalCodingToolPlatform
  arch: LocalCodingToolArch
  version: string
  outcome: LocalCodingAutoSyncOutcome
  detail?: string
}

export type LocalCodingAutoSyncStatus = {
  desktop_platforms?: string[]
  enabled: boolean
  running: boolean
  last_report?: { started_at: string; finished_at: string; results: LocalCodingAutoSyncResult[] }
}

export type LocalCodingToolVersionInput = {
  target_id: LocalCodingToolTarget
  platform: LocalCodingToolPlatform
  arch: LocalCodingToolArch
  version: string
  layout: LocalCodingToolLayout
  member?: string
  binary_sha256?: string
  bundle_identifier?: string
  team_identifier?: string
  min_bridge_version?: string
  min_app_version?: string
  profile_version?: string
  contract_check_ref?: string
  release_notes?: string
  external_url?: string
  file_size_bytes?: number
  sha256?: string
}

export const LocalCodingToolVersions = {
  list: (params: { target_id?: string; platform?: string; arch?: string; status?: string; q?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: LocalCodingToolVersion[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/local-coding-tool-versions${queryString(params)}`,
    ),
  get: (uuid: string) =>
    api<{ item: LocalCodingToolVersion }>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}`),
  create: (body: LocalCodingToolVersionInput) =>
    api<{ item: LocalCodingToolVersion }>('/api/admin/v1/platform/local-coding-tool-versions', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: LocalCodingToolVersionInput) =>
    api<{ item: LocalCodingToolVersion }>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<void>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}`, { method: 'DELETE' }),
  uploadPackage: (uuid: string, file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    return api<{ item: LocalCodingToolVersion }>(
      `/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}/upload-package`,
      { method: 'POST', body: fd },
    )
  },
  publish: (uuid: string, body: { mode: 'canary' | 'current'; tenant_ids?: number[] }) =>
    api<{ item: LocalCodingToolVersion }>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}/publish`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  deprecate: (uuid: string) =>
    api<{ item: LocalCodingToolVersion }>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}/deprecate`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  // 外链包搬入平台对象存储（后台执行，轮询列表看 mirror_state）。
  mirrorPackage: (uuid: string) =>
    api<{ item: LocalCodingToolVersion }>(`/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}/mirror-package`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  // 同 ClientVersions.downloadPackage：后端返回 JSON 签名地址，前端 window.open 跳转下载。
  downloadPackage: (uuid: string) =>
    api<{ download_url: string }>(
      `/api/admin/v1/platform/local-coding-tool-versions/${encodeURIComponent(uuid)}/download-package`,
    ),
  // 自动同步：状态只读；start 在后台起一轮（要下载几百 MB），用 status 轮询结果。
  autoSyncStatus: () =>
    api<{ status: LocalCodingAutoSyncStatus }>('/api/admin/v1/platform/local-coding-tool-auto-sync'),
  startAutoSync: () =>
    api<{ status: LocalCodingAutoSyncStatus }>('/api/admin/v1/platform/local-coding-tool-auto-sync', {
      method: 'POST',
      body: JSON.stringify({}),
    }),
}

// ===== F09-A6-05 群聊治理 admin API =====

export type AdminRoomSummary = {
  uuid: string
  title: string
  room_kind: string
  status: string
  speaker_policy: string
  manager_agent_uuid?: string
  human_count: number
  agent_count: number
  frozen: boolean
  triggers_24h: number
  wukong_channel_id?: string
  wukong_channel_type?: number
  created_at: string
}

export type AdminTriggerRow = {
  uuid: string
  sender_account_id?: number
  agent_id?: number
  decision: 'triggered' | 'skipped' | 'rejected'
  reject_reason?: string
  im_message_id: string
  received_at: string
}

export const AdminRooms = {
  list: (params: { room_kind?: string; status?: string; q?: string; page?: number; page_size?: number }) =>
    api<{ items: AdminRoomSummary[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/tenant/rooms${queryString(params)}`,
    ),
  get: (uuid: string) =>
    api<AdminRoomSummary>(`/api/admin/v1/tenant/rooms/${encodeURIComponent(uuid)}`),
  triggers: (uuid: string, params?: { page?: number; page_size?: number }) =>
    api<{ items: AdminTriggerRow[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/tenant/rooms/${encodeURIComponent(uuid)}/triggers${queryString(params || {})}`,
    ),
  freeze: (uuid: string) =>
    api<{ uuid: string; frozen: boolean }>(
      `/api/admin/v1/tenant/rooms/${encodeURIComponent(uuid)}/freeze`,
      { method: 'POST' },
    ),
  unfreeze: (uuid: string) =>
    api<{ uuid: string; frozen: boolean }>(
      `/api/admin/v1/tenant/rooms/${encodeURIComponent(uuid)}/unfreeze`,
      { method: 'POST' },
    ),
}

// ===== ADR-0026 WuKongIM 状态 admin API =====

export type WuKongIMConfig = {
  enabled: boolean
  api_addr_configured: boolean
  tcp_addr?: string
  ws_addr?: string
  webhook_secret_configured: boolean
  webhook_ip_allowlist?: string
}

export type WuKongIMProbeResult = {
  status: 'ok' | 'error' | 'disabled'
  latency_ms: number
  message?: string
}

export type WuKongIMStats = {
  rooms_linked_24h: number
  rooms_linked_total: number
  agent_triggers_last_24h: number
  webhook_rejects_last_24h: number
  agent_replies_last_24h_best_effort: number
}

export type IMCollectorStatus = {
  last_attempt_at?: string
  last_success_at?: string
  last_error?: string
  connection_total: number
}

export type IMConnectionOverview = {
  online_connections: number
  online_users: number
  online_tenants: number
  anomalous_devices: number
  reconnects_5m: number
  reconnects_1h: number
  recoveries_1h: number
  replacements_1h: number
  collector: IMCollectorStatus
}

export type IMConnectionState = {
  uuid: string
  tenant_id: number
  tenant_name: string
  account_id?: number
  account_uuid?: string
  account_name?: string
  uid: string
  subject_kind: 'human' | 'agent' | 'unknown'
  subject_uuid: string
  device_id_masked: string
  device_id_available: boolean
  device_flag: number
  device_level: number
  connection_id: number
  protocol_version: string
  client_version: string
  client_platform: string
  client_os_version: string
  status: 'online' | 'offline'
  connected_at?: string
  last_activity_at?: string
  first_seen_at: string
  last_seen_at: string
  last_event_type: string
  reconnects_5m: number
  reconnects_1h: number
  anomalous: boolean
}

export type IMConnectionEvent = {
  uuid: string
  state_uuid: string
  tenant_id: number
  tenant_name: string
  account_uuid?: string
  account_name?: string
  uid: string
  device_id_masked: string
  device_flag: number
  connection_id: number
  previous_connection_id?: number
  event_type: 'connected' | 'reconnected' | 'disconnected'
  reason?: string
  data_quality: 'verified' | 'legacy_unreliable'
  protocol_version?: string
  occurred_at: string
}

export const WuKongIMAdmin = {
  config: () => api<WuKongIMConfig>('/api/admin/v1/platform/wukong/config'),
  probe: () =>
    api<WuKongIMProbeResult>('/api/admin/v1/platform/wukong/probe', { method: 'POST' }),
  stats: () => api<WuKongIMStats>('/api/admin/v1/platform/wukong/stats'),
  overview: () => api<IMConnectionOverview>('/api/admin/v1/platform/wukong/overview'),
  connections: (params: {
    q?: string
    tenant_id?: number
    status?: string
    anomalous?: boolean
    device_flag?: number
    page?: number
    page_size?: number
  }) => api<{ items: IMConnectionState[]; total: number; page: number; page_size: number }>(
    `/api/admin/v1/platform/wukong/connections${queryString(params)}`,
  ),
  connection: (uuid: string) => api<IMConnectionState>(
    `/api/admin/v1/platform/wukong/connections/${encodeURIComponent(uuid)}`,
  ),
  events: (params: {
    state_uuid?: string
    tenant_id?: number
    event_type?: string
    page?: number
    page_size?: number
  }) => api<{ items: IMConnectionEvent[]; total: number; page: number; page_size: number }>(
    `/api/admin/v1/platform/wukong/events${queryString(params)}`,
  ),
}

// =====================================================================
// F09-B4 / PR8: A2A 治理 / Orchestrations / Speaker policies / Decisions / Callable
// =====================================================================

// ----- A2A edges -----

export type AdminA2AEdgeSummary = {
  id: string
  created_at: string
  status: string
  from_agent_id: string
  from_agent_name?: string
  to_agent_id: string
  to_agent_name?: string
  depth: number
  invoke_kind: string
  orchestration_id?: string
  room_id?: string
  tokens_in: number
  tokens_out: number
  latency_ms?: number
  error_message?: string
}

export type AdminA2AEdgeDetail = AdminA2AEdgeSummary & {
  idem_key: string
  parent_edge_id?: string
  started_at?: string
  completed_at?: string
  // request/response payload 是后端写入时已 redact 的 JSON; admin **无权解 redact**.
  request_payload?: unknown
  response_payload?: unknown
}

export type AdminA2AAgentNode = {
  agent_id: string
  agent_name: string
  out_degree: number
  in_degree: number
  failed_out: number
}

export const AdminA2A = {
  list: (params: {
    from?: string
    to?: string
    from_agent_id?: string
    to_agent_id?: string
    room_id?: string
    orchestration_id?: string
    status?: string
    page?: number
    page_size?: number
  } = {}) =>
    api<{
      items: AdminA2AEdgeSummary[]
      total: number
      page: number
      page_size: number
    }>(`/api/admin/v1/tenant/a2a${queryString(params)}`),

  get: (edgeID: string, createdAt: string) =>
    api<AdminA2AEdgeDetail>(
      `/api/admin/v1/tenant/a2a/${encodeURIComponent(edgeID)}${queryString({ created_at: createdAt })}`,
    ),

  agentNodes: (params: { from?: string; to?: string } = {}) =>
    api<{ items: AdminA2AAgentNode[]; from: string; to: string }>(
      `/api/admin/v1/tenant/a2a/agents${queryString(params)}`,
    ),
}

// ----- Orchestrations -----

export type AdminOrchestrationSummary = {
  uuid: string
  created_at: string
  status: string
  master_agent_id: number
  master_agent_name?: string
  room_id?: number
  plan_summary?: string
  depth_limit: number
  token_budget: number
  time_budget_ms: number
  tokens_in_total: number
  tokens_out_total: number
  edges_count: number
  max_depth_reached: number
  started_at?: string
  completed_at?: string
}

export type AdminOrchestrationStep = {
  uuid: string
  step_index: number
  role: string
  status: string
  worker_agent_id?: number
  worker_name?: string
  call_edge_id?: number
  input_summary?: string
  output_summary?: string
  error_message?: string
  tokens_in: number
  tokens_out: number
  started_at?: string
  completed_at?: string
  created_at: string
}

export type AdminOrchestrationDetail = AdminOrchestrationSummary & {
  final_summary?: string
  error_message?: string
  trigger_msg_id?: number
  steps: AdminOrchestrationStep[]
}

export const AdminOrchestrations = {
  list: (params: {
    status?: string
    master_agent_id?: number
    room_id?: number
    from?: string
    to?: string
    page?: number
    page_size?: number
  } = {}) =>
    api<{
      items: AdminOrchestrationSummary[]
      total: number
      page: number
      page_size: number
    }>(`/api/admin/v1/tenant/orchestrations${queryString(params)}`),

  get: (uuid: string) =>
    api<AdminOrchestrationDetail>(
      `/api/admin/v1/tenant/orchestrations/${encodeURIComponent(uuid)}`,
    ),
}

// ----- Speaker policies -----

export type AdminSpeakerPolicy = {
  uuid: string
  name: string
  description?: string
  is_template: boolean
  base_policy: 'manual' | 'round_robin' | 'auto_llm' | 'manager' | 'parallel' | 'handoff'
  manager_agent_id?: number
  manager_agent_uuid?: string
  manager_agent_name?: string
  selector_config: Record<string, unknown>
  max_speaker_decisions_per_minute: number
  created_at: string
  updated_at: string
}

export type AdminSpeakerPolicyUpsert = {
  name: string
  description?: string
  is_template?: boolean
  base_policy: AdminSpeakerPolicy['base_policy']
  manager_agent_uuid?: string
  selector_config?: Record<string, unknown>
  max_speaker_decisions_per_minute?: number
}

export const AdminSpeakerPolicies = {
  list: (params: { is_template?: boolean; q?: string; page?: number; page_size?: number } = {}) =>
    api<{
      items: AdminSpeakerPolicy[]
      total: number
      page: number
      page_size: number
    }>(`/api/admin/v1/tenant/speaker-policies${queryString(params)}`),

  get: (uuid: string) =>
    api<AdminSpeakerPolicy>(
      `/api/admin/v1/tenant/speaker-policies/${encodeURIComponent(uuid)}`,
    ),

  create: (body: AdminSpeakerPolicyUpsert) =>
    api<AdminSpeakerPolicy>(`/api/admin/v1/tenant/speaker-policies`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  update: (uuid: string, body: AdminSpeakerPolicyUpsert) =>
    api<AdminSpeakerPolicy>(
      `/api/admin/v1/tenant/speaker-policies/${encodeURIComponent(uuid)}`,
      { method: 'PUT', body: JSON.stringify(body) },
    ),

  remove: (uuid: string) =>
    api<{ uuid: string; deleted: boolean }>(
      `/api/admin/v1/tenant/speaker-policies/${encodeURIComponent(uuid)}`,
      { method: 'DELETE' },
    ),
}

// ----- Speaker decisions (per room) -----

export type AdminSpeakerDecision = {
  uuid: string
  created_at: string
  base_policy: string
  candidates: unknown // 候选 Agent JSON 数组 (selector 写入时格式)
  selected_agent_id?: number
  selected_agent_name?: string
  selected_reason?: string
  selection_kind: 'single' | 'parallel' | 'none'
  latency_ms?: number
  judge_tokens_in?: number
  judge_tokens_out?: number
  trigger_msg_id?: number
  policy_id?: number
  policy_uuid?: string
  policy_name?: string
}

export const AdminSpeakerDecisions = {
  listByRoom: (
    roomUUID: string,
    params: { from?: string; to?: string; page?: number; page_size?: number } = {},
  ) =>
    api<{
      items: AdminSpeakerDecision[]
      total: number
      page: number
      page_size: number
      room_uuid: string
      from: string
      to: string
    }>(
      `/api/admin/v1/tenant/rooms/${encodeURIComponent(roomUUID)}/speaker-decisions${queryString(params)}`,
    ),
}

// ----- digital_employees.callable_by_agents -----

export type AdminAgentCallable = {
  mode: 'none' | 'all' | 'workspace' | 'explicit'
  agent_ids: string[]
}

export const AdminAgentCallable = {
  get: (agentID: string) =>
    api<AdminAgentCallable>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/callable-by-agents`,
    ),
  update: (agentID: string, body: AdminAgentCallable) =>
    api<AdminAgentCallable>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/callable-by-agents`,
      { method: 'PUT', body: JSON.stringify(body) },
    ),
}

// ----- A2A collaboration settings -----

export type AdminAgentA2AInvokeCapability = {
  enabled: boolean
}

export const AdminAgentA2AInvokeCapability = {
  get: (agentID: string) =>
    api<AdminAgentA2AInvokeCapability>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/a2a-invoke-capability`,
    ),
  update: (agentID: string, body: AdminAgentA2AInvokeCapability) =>
    api<AdminAgentA2AInvokeCapability>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/a2a-invoke-capability`,
      { method: 'PUT', body: JSON.stringify(body) },
    ),
}

export type AdminAgentA2ACardExample = {
  input: string
  expect?: string
}

export type AdminAgentA2ACard = {
  schema_version: string
  summary: string
  when_to_use: string[]
  when_not_to_use: string[]
  examples: AdminAgentA2ACardExample[]
  input_schema: Record<string, unknown>
  output_schema: Record<string, unknown>
  supported_modes: string[]
  risk_level: 'low' | 'medium' | 'high'
  requires_approval: boolean
  card_version: number
}

export const AdminAgentA2ACard = {
  get: (agentID: string) =>
    api<AdminAgentA2ACard>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/a2a-card`,
    ),
  update: (agentID: string, body: AdminAgentA2ACard) =>
    api<AdminAgentA2ACard>(
      `/api/admin/v1/tenant/agents/${encodeURIComponent(agentID)}/a2a-card`,
      { method: 'PUT', body: JSON.stringify(body) },
    ),
}

export const AdminPlatformPresetA2ACard = {
  get: (agentID: string) =>
    api<AdminAgentA2ACard>(
      `/api/admin/v1/platform/preset-agents/${encodeURIComponent(agentID)}/a2a-card`,
    ),
  update: (agentID: string, body: AdminAgentA2ACard) =>
    api<AdminAgentA2ACard>(
      `/api/admin/v1/platform/preset-agents/${encodeURIComponent(agentID)}/a2a-card`,
      { method: 'PUT', body: JSON.stringify(body) },
    ),
}

// ----- Support feedback -----

export type SupportFeedbackStatus = 'open' | 'triaged' | 'in_progress' | 'resolved' | 'closed'
export type SupportFeedbackCategory = 'usage_question' | 'bug' | 'product_suggestion' | 'account_access' | 'performance' | 'other'
export type SupportFeedbackPriority = 'low' | 'normal' | 'high' | 'urgent'

export type SupportFeedbackItem = {
  uuid: string
  tenant_id: number
  tenant_name?: string
  account_id?: number
  account_name?: string
  agent_id?: number
  agent_name?: string
  conversation_id?: number
  message_id?: number
  source: string
  category: SupportFeedbackCategory
  priority: SupportFeedbackPriority
  status: SupportFeedbackStatus
  title: string
  description: string
  page_url?: string
  client_info?: Record<string, unknown>
  attachments?: unknown[]
  assigned_to?: number
  assigned_to_name?: string
  assigned_at?: string
  handler_note?: string
  handled_by?: number
  handled_by_name?: string
  handled_at?: string
  created_at: string
  updated_at: string
}

export type SupportFeedbackListParams = {
  tenant_id?: number
  status?: string
  category?: string
  priority?: string
  q?: string
  limit?: number
  offset?: number
}

export type SupportFeedbackAttachmentURL = {
  url: string
  expires_at: string
  file_name: string
  mime_type: string
  size_bytes: number
  inline: boolean
}

export const SupportFeedback = {
  list: (params: SupportFeedbackListParams = {}) =>
    api<{ items: SupportFeedbackItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/support-feedback${queryString(params)}`,
    ),
  update: (
    uuid: string,
    body: { status?: string; priority?: string; handler_note?: string; assigned_to?: number | null },
  ) =>
    api<{ item: SupportFeedbackItem }>(
      `/api/admin/v1/platform/support-feedback/${encodeURIComponent(uuid)}`,
      { method: 'PATCH', body: JSON.stringify(body) },
    ),
  previewAttachment: (uuid: string, fileUUID: string) =>
    api<SupportFeedbackAttachmentURL>(
      `/api/admin/v1/platform/support-feedback/${encodeURIComponent(uuid)}/attachments/${encodeURIComponent(fileUUID)}/preview`,
    ),
  downloadAttachment: (uuid: string, fileUUID: string) =>
    api<SupportFeedbackAttachmentURL>(
      `/api/admin/v1/platform/support-feedback/${encodeURIComponent(uuid)}/attachments/${encodeURIComponent(fileUUID)}/download`,
    ),
  attachmentContentURL: (uuid: string, fileUUID: string) =>
    `/api/admin/v1/platform/support-feedback/${encodeURIComponent(uuid)}/attachments/${encodeURIComponent(fileUUID)}/content`,
}

// ----- Marketing leads -----

export type MarketingLeadStatus = 'new' | 'contacted' | 'qualified' | 'closed' | 'spam'

export type MarketingLeadItem = {
  uuid: string
  contact_name: string
  phone?: string
  phone_masked: string
  company: string
  message: string
  source: string
  page_url?: string
  status: MarketingLeadStatus
  assigned_to?: number
  assigned_to_name?: string
  assigned_at?: string
  handled_by?: number
  handled_by_name?: string
  handled_at?: string
  remark?: string
  user_agent?: string
  created_at: string
  updated_at: string
}

export type MarketingLeadListParams = {
  status?: string
  q?: string
  created_gte?: string
  created_lte?: string
  limit?: number
  offset?: number
}

export const MarketingLeads = {
  list: (params: MarketingLeadListParams = {}) =>
    api<{ items: MarketingLeadItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/marketing-leads${queryString(params)}`,
    ),
  update: (
    uuid: string,
    body: { status?: string; remark?: string; assigned_to?: number | null },
  ) =>
    api<{ item: MarketingLeadItem }>(
      `/api/admin/v1/platform/marketing-leads/${encodeURIComponent(uuid)}`,
      { method: 'PATCH', body: JSON.stringify(body) },
    ),
}

// ----- Startup agent ops (F24 创业助手运营通道; contracts/admin-startup-agent-api.md) -----

export type StartupAgentCaseStatus = 'active' | 'completed' | 'cancelled' | 'failed'

export type StartupAgentCaseItem = {
  id: string
  tenant_uuid: string
  tenant_name: string
  kind: string
  status: StartupAgentCaseStatus
  stage: string
  business_no: string
  // 列表摘要（baigong 从 draft 抽，未填为空串）：申请人 / 首选字号 / 注册城市。
  applicant: string
  brand: string
  city: string
  // 进度元数据（v2-W1，契约 §2.1）：预计完成 YYYY-MM-DD（draft 为空串）/
  // 用户催办未回执 / 已登记收款金额（元，未收款为 0）。
  eta: string
  expedite_pending: boolean
  fee_amount: number
  // 交接未送出（2026-07-21，契约 §2.1）：company_reg 已收款但交接资料包从未
  // 成功送出（handoff_version=0）；前端标角标引导重发/下载手动发送。
  handoff_pending: boolean
  termination_pending: boolean
  // 收款线上化取消退款（2026-07-24）：取消/驳回后待退款角标
  refund_pending: boolean
  months_served: number // 已回传月数（月度服务台账，2026-07-21）
  renewal_due: boolean // 已回传满 11 个月，续费将至（按年签口径）
  // 代账工单摘要（v2-W2，kind=bookkeeping 时有值；注册单为空/0，契约 §2.1）。
  source: string
  taxpayer_type: string
  insured_count: string
  receipts_band: string
  quote_low: number
  quote_high: number
  final_price: number
  // 办理企业（2026-07-17，契约 §2.1）：显式关联的企业档案与实时解析的企业名；
  // 历史未关联工单两者为空串，前端显示「未关联企业」。
  company_profile_id: string
  company_name: string
  related_case_id: string
  related_business_no: string
  related_kind: string
  related_status: string
  related_stage: string
  related_title: string
  created_at: string
  updated_at: string
}

// 运营看板顶部统计卡（GET /startup-agent/stats）。
export type StartupAgentStats = {
  new_this_month: number
  done_this_month: number
  active: number
  serving: number // stage=serving 在服单量（代账看板「服务中」卡）
  avg_done_days: number
}

export type StartupAgentCaseEvent = {
  event_type: string
  payload: Record<string, unknown>
  received_at: string
}

export type StartupAgentCaseDetail = StartupAgentCaseItem & {
  data: Record<string, unknown>
  events: StartupAgentCaseEvent[]
}

export type StartupAgentEventOutcome = {
  ok: boolean
  case_id: string
  status: string
  stage: string
  // duplicate_event = 幂等命中（该操作已处理过），非错误。
  reason: string
}

// PII 明文（v2-W1，契约 §2.4）：需要 platform.startup_agent.pii_read 权限码，
// 每次调用后端落 startup_agent.pii.view 审计。
// 键动态（2026-08-06 四期）：法人/监事四键恒出，任职人员/股东的
// _id_number/_mobile 按 draft 实际内容并入。
export type StartupAgentCasePII = Record<string, string>

// 代账定价矩阵（v2-W2，契约 §2.6）：{纳税人类型: {月票据档: [低, 高]}} 元/月。
export type BookkeepingPricing = {
  matrix: Record<string, Record<string, [number, number]>>
  bands: string[]
}

// 注册交接供应商分单（契约 §2.8）：城市→供应商→邮箱；default_supplier 为
// 未命中城市的兜底供应商（空=回退内部邮箱人工分配）。
export type HandoffSupplier = { id: string; name: string; email: string; note: string }
export type HandoffRoutes = {
  suppliers: HandoffSupplier[]
  city_routes: Record<string, string>
  default_supplier: string
}

export const StartupAgentCases = {
  list: (
    params: {
      kind?: 'company_reg' | 'bookkeeping'
      stage?: string
      status?: string
      q?: string
      city?: string
      paid?: 'paid' | 'unpaid' | ''
      created_from?: string
      created_to?: string
      page?: number
      page_size?: number
    } = {},
  ) =>
    api<{ items: StartupAgentCaseItem[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/startup-agent/cases${queryString(params)}`,
    ),
  stats: (kind: 'company_reg' | 'bookkeeping' = 'company_reg') =>
    api<StartupAgentStats>(`/api/admin/v1/startup-agent/stats${queryString({ kind })}`),
  getPricing: () =>
    api<BookkeepingPricing>('/api/admin/v1/startup-agent/bookkeeping/pricing'),
  putPricing: (matrix: BookkeepingPricing['matrix']) =>
    api<{ ok: boolean }>('/api/admin/v1/startup-agent/bookkeeping/pricing', {
      method: 'PUT', body: JSON.stringify({ matrix }),
    }),
  // 城市地址价目（契约 §2.6a）：成本仅 admin 面；售价=运营手动，空=不报价走顾问
  getCityPricing: () =>
    api<{ cities: CityPricingRow[] }>('/api/admin/v1/startup-agent/web/city-pricing'),
  putCityPricing: (cities: CityPricingRow[]) =>
    api<{ ok: boolean }>('/api/admin/v1/startup-agent/web/city-pricing', {
      method: 'PUT', body: JSON.stringify({ cities }),
    }),
  getHandoffRoutes: () =>
    api<HandoffRoutes>('/api/admin/v1/startup-agent/registration/handoff-routes'),
  putHandoffRoutes: (cfg: HandoffRoutes) =>
    api<{ ok: boolean }>('/api/admin/v1/startup-agent/registration/handoff-routes', {
      method: 'PUT', body: JSON.stringify(cfg),
    }),
  get: (id: string, tenantUUID: string) =>
    api<StartupAgentCaseDetail>(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  getPII: (id: string, tenantUUID: string) =>
    api<{ pii: StartupAgentCasePII }>(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}/pii${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  // 材料预览（v2-W1.5，契约 §2.5）：短时效 inline URL；权限码同 pii_read，签发落审计。
  getFileURL: (id: string, tenantUUID: string, fileUUID: string) =>
    api<{ url: string; file_name: string; mime_type: string; expires_at: string }>(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}/files/${encodeURIComponent(fileUUID)}${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  // 交接资料包 ZIP 下载（契约 §2.5a）：与交接邮件同源，邮件故障时人工兜底；
  // 权限码同 pii_read，每次下载落审计。二进制响应不走 api() 的 JSON 封套。
  downloadPackage: async (id: string, tenantUUID: string): Promise<{ blob: Blob; filename: string }> => {
    const headers: Record<string, string> = {}
    const t = auth.token()
    if (t) headers.Authorization = `Bearer ${t}`
    const res = await fetch(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}/package${queryString({ tenant_uuid: tenantUUID })}`,
      { headers },
    )
    if (!res.ok) {
      let msg = `下载资料包失败（HTTP ${res.status}）`
      try {
        const body = JSON.parse(await res.text()) as { message?: string }
        if (body?.message) msg = body.message
      } catch { /* 非 JSON 错误体，用默认文案 */ }
      throw new Error(msg)
    }
    const cd = res.headers.get('Content-Disposition') || ''
    const star = /filename\*=UTF-8''([^;]+)/i.exec(cd)
    const plain = /filename="([^"]+)"/.exec(cd)
    const filename = star ? decodeURIComponent(star[1]) : plain ? plain[1] : `${id}-资料包.zip`
    return { blob: await res.blob(), filename }
  },
  // event_key 由调用方在弹窗打开时生成（crypto.randomUUID()），重试/双击复用同 key（幂等）。
  ingestEvent: (
    id: string,
    body: { tenant_uuid: string; type: string; event_key: string; payload?: Record<string, unknown> },
  ) =>
    api<StartupAgentEventOutcome & { refund_triggered?: boolean; refund_error?: string }>(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}/events`,
      { method: 'POST', body: JSON.stringify(body) },
    ),
  // F24 取消退款：手动发起工单服务费退款（微信原路退）；amount_cents 缺省=剩余全额
  refund: (
    id: string,
    body: { tenant_uuid: string; amount_cents?: number; reason?: string },
  ) =>
    api<{ id: number; refund_amount_cents: number; status: string }>(
      `/api/admin/v1/startup-agent/cases/${encodeURIComponent(id)}/refund`,
      { method: 'POST', body: JSON.stringify(body) },
    ),
}

// 企业档案（v2-W3，契约 §2.7）：用户与企业的显式关系主档。
export type CompanyProfileVerificationStatus = 'unverified' | 'pending' | 'verified' | 'rejected'
export type CompanyProfileTaxpayerType = 'small_scale' | 'general' | 'unknown'
export type CompanyProfileBusinessStatus = 'active' | 'deregistered' | 'unknown'

export type CompanyProfileItem = {
  id: string
  tenant_uuid: string
  tenant_name: string
  business_key: string
  company_name: string
  credit_code: string
  // registration = 出照自动建档；self_reported / bookkeeping_confirmed = 用户自述。
  source: string
  verification_status: CompanyProfileVerificationStatus
  legal_representative: string
  established_date: string
  registered_address: string
  taxpayer_type: CompanyProfileTaxpayerType
  business_status: CompanyProfileBusinessStatus
  // 对公账户（用户在聊天里登记的开户结果；未登记为空串）
  bank_name: string
  bank_account: string
  reg_business_no: string
  licensed_at: string
  member_count: number
  bookkeeping_count: number
  needs_completion: boolean
  created_at: string
  updated_at: string
}

export type CompanyProfileMember = {
  account_uuid: string
  role: string
  is_primary: boolean
}

export type CompanyProfileRelated = {
  id: string
  kind: string
  business_no: string
  stage: string
  status: string
  created_at: string
}

export type CompanyProfileDetail = CompanyProfileItem & {
  members: CompanyProfileMember[]
  related: CompanyProfileRelated[]
}

export type CompanyProfilePatch = {
  company_name?: string
  credit_code?: string
  legal_representative?: string
  established_date?: string
  registered_address?: string
  taxpayer_type?: CompanyProfileTaxpayerType
  business_status?: CompanyProfileBusinessStatus
  verification_status?: CompanyProfileVerificationStatus
}

export const CompanyProfiles = {
  list: (params: { q?: string; page?: number; page_size?: number } = {}) =>
    api<{ items: CompanyProfileItem[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/startup-agent/profiles${queryString(params)}`,
    ),
  get: (id: string, tenantUUID: string) =>
    api<CompanyProfileDetail>(
      `/api/admin/v1/startup-agent/profiles/${encodeURIComponent(id)}${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  update: (id: string, tenantUUID: string, patch: CompanyProfilePatch) =>
    api<CompanyProfileItem>(
      `/api/admin/v1/startup-agent/profiles/${encodeURIComponent(id)}`,
      { method: 'PATCH', body: JSON.stringify({ tenant_uuid: tenantUUID, ...patch }) },
    ),
  linkBookkeeping: (id: string, tenantUUID: string, bookkeepingCaseID: string) =>
    api<{ ok: boolean; profile_id: string; bookkeeping_case_id: string }>(
      `/api/admin/v1/startup-agent/profiles/${encodeURIComponent(id)}/link-bookkeeping`,
      {
        method: 'POST',
        body: JSON.stringify({ tenant_uuid: tenantUUID, bookkeeping_case_id: bookkeepingCaseID }),
      },
    ),
}

// ---------------------------------------------------------------- F30 Web 线索
// 独立 Web 入口（创业助手 chuangye 站）的匿名访客留资；契约 §2.9 / §2.10。
// 列表 contact 由服务端脱敏，明文只在详情。

export type WebLeadStage = 'new' | 'contacted' | 'converted' | 'invalid'

export type WebLeadItem = {
  id: string
  tenant_uuid: string
  stage: WebLeadStage
  status: string
  name: string
  contact: string
  city: string
  intent: string
  note: string
  phone: string
  converted_case_id: string
  // 四期：注册类咨询转的是 company_reg 注册申请单（老数据两者为空 = 办理单）
  converted_case_kind: string
  converted_business_no: string
  source: string
  agent: string
  invite: string
  created_at: string
  updated_at: string
}

export type WebLeadDetail = WebLeadItem & {
  chat_digest: string
  events: { event_type: string; payload: Record<string, unknown>; received_at: string }[]
}

export type WebContactCard = { image_data_uri: string; note: string }

// 访客与转化统计（契约 §2.9a）：visitors=来聊过的会话数（分母），
// converted=其中留了联系方式的（分子）。
export type WebLeadStats = {
  visitors: number
  visitors_today: number
  turns: number
  avg_turns: number
  converted: number
  conversion_rate: number
  leads: number
  by_stage: Record<string, number>
  days: number
}

// 获客漏斗：访客→开聊→登录→留资→开单→提交→支付。任一数据源查询失败时
// 该段为 -1（上游 fail-soft），前端显示「异常」而不是 0，避免把故障读成没转化。
export type WebFunnelSeg = {
  sessions: number
  chatted: number
  logged: number
  leads?: number
  reg_created?: number
}

export type WebFunnel = {
  sessions: number
  chatted: number
  logged: number
  leads: number
  reg_created: number
  reg_submitted: number
  reg_paid: number
  bookkeeping_paid: number
  days: number
  daily: Record<string, WebFunnelSeg>
  by_invite: Record<string, WebFunnelSeg>
}

// 注册用户明细（漏斗下钻）：手机号只出掩码，全号属 PII 不经此接口。
export type WebUserRow = {
  user_id: string
  phone_masked: string
  created_at: string
  last_login_at: string
  invite: string
  turns: number
  sessions: number
  stage: string
}

// 回复反馈（数据线第一批，契约 §2.9b）：👍👎 与点踩分类，问答只存摘录。
export type WebFeedbackItem = {
  id: number
  session_id: string
  verdict: 'up' | 'down'
  reason: string
  q_excerpt: string
  a_excerpt: string
  created_at: string
}

export type WebFeedbackStats = {
  up: number
  down: number
  reasons: Record<string, number>
  daily: { date: string; up: number; down: number }[]
  days: number
}

// 办理质量（数据线第二批，契约 §2.9c）：核名一次通过率 + 交付时长分位。
export type WebQuality = {
  days: number
  naming_cases: number
  naming_first_pass: number
  delivery: { label: string; count: number; p50_days: number; p90_days: number }[]
}

// 城市地址价目行（契约 §2.6a）
export type CityPricingRow = {
  city: string
  sell: { reg_fee: number | null; addr_fee_year: number | null; note: string }
  suppliers: {
    code: string
    reg_cost: number | null
    seal: string
    addr_cost_year: number | null
    term: string
    area: string
    note?: string
  }[]
}

export const WebLeads = {
  list: (params: { stage?: string; q?: string; page?: number; page_size?: number } = {}) =>
    api<{ items: WebLeadItem[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/startup-agent/leads${queryString(params)}`,
    ),
  get: (id: string, tenantUUID: string) =>
    api<WebLeadDetail>(
      `/api/admin/v1/startup-agent/leads/${encodeURIComponent(id)}${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  follow: (id: string, tenantUUID: string, stage: WebLeadStage, note?: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/startup-agent/leads/${encodeURIComponent(id)}/follow`, {
      method: 'POST',
      body: JSON.stringify({ tenant_uuid: tenantUUID, stage, note: note ?? '' }),
    }),
  stats: (days = 30) =>
    api<WebLeadStats>(`/api/admin/v1/startup-agent/web/stats${queryString({ days })}`),
  funnel: (days = 30) =>
    api<WebFunnel>(`/api/admin/v1/startup-agent/web/funnel${queryString({ days })}`),
  users: (limit = 20, offset = 0) =>
    api<{ items: WebUserRow[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/startup-agent/web/users${queryString({ limit, offset })}`,
    ),
  feedback: (params: { verdict?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: WebFeedbackItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/startup-agent/web/feedback${queryString(params)}`,
    ),
  feedbackStats: (days = 30) =>
    api<WebFeedbackStats>(`/api/admin/v1/startup-agent/web/feedback/stats${queryString({ days })}`),
  quality: (days = 30) =>
    api<WebQuality>(`/api/admin/v1/startup-agent/web/quality${queryString({ days })}`),
  getContactCard: () => api<WebContactCard>('/api/admin/v1/startup-agent/web/contact-card'),
  putContactCard: (card: WebContactCard) =>
    api<{ ok: boolean }>('/api/admin/v1/startup-agent/web/contact-card', {
      method: 'PUT',
      body: JSON.stringify(card),
    }),
}

// ---------------------------------------------------------------- F30 二期 Web 办理单
// 线索成交后的履约跟踪单（契约 §2.11）；用户在 Web 端只读查看进度。
// 列表 phone 由服务端脱敏，明文只在详情。

export type WebCaseStage = 'received' | 'materials' | 'processing' | 'done' | 'cancelled'

export type WebCaseItem = {
  id: string
  tenant_uuid: string
  case_no: string
  stage: WebCaseStage
  stage_label: string
  status: string
  title: string
  service_type: string
  phone: string
  lead_id: string
  created_at: string
  updated_at: string
}

export type WebCasePayment = { amount_cents: number; desc: string; status: string }

export type WebCaseDetail = WebCaseItem & {
  note: string
  // 海外里程碑（2026-08-07）：核名结果，录证书弹框默认值
  approved_name: string
  payment: WebCasePayment | null
  materials_done: boolean
  materials_draft: Record<string, unknown>
  events: { event_type: string; payload: Record<string, unknown>; received_at: string }[]
}

export const WebCases = {
  // 2026-08-06 拍板：留资只做联系标记不再转化（转办理单入口下线）；办理
  // 一律在 Web 对话里自助发起。service_type 供企业注册申请页海外 Tab 过滤。
  list: (params: {
    stage?: string; q?: string; service_type?: string
    page?: number; page_size?: number
  } = {}) =>
    api<{ items: WebCaseItem[]; total: number; page: number; page_size: number }>(
      `/api/admin/v1/startup-agent/web-cases${queryString(params)}`,
    ),
  get: (id: string, tenantUUID: string) =>
    api<WebCaseDetail>(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}${queryString({ tenant_uuid: tenantUUID })}`,
    ),
  progress: (
    id: string,
    tenantUUID: string,
    body: { stage: WebCaseStage; title?: string; note?: string },
  ) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/progress`,
      { method: 'POST', body: JSON.stringify({ tenant_uuid: tenantUUID, ...body }) },
    ),
  // 海外里程碑（2026-08-07 对齐内地）：核名通过 / 录入注册证书
  naming: (id: string, tenantUUID: string, approvedName: string) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/naming`,
      { method: 'POST', body: JSON.stringify({ tenant_uuid: tenantUUID, approved_name: approvedName }) },
    ),
  license: (
    id: string,
    tenantUUID: string,
    body: { company_name?: string; reg_no: string; established_date?: string },
  ) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/license`,
      { method: 'POST', body: JSON.stringify({ tenant_uuid: tenantUUID, ...body }) },
    ),
  setPayment: (id: string, tenantUUID: string, body: { amount_cents: number; desc: string }) =>
    api<{ ok: boolean }>(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/set-payment`,
      { method: 'POST', body: JSON.stringify({ tenant_uuid: tenantUUID, ...body }) },
    ),
  downloadFile: (id: string, tenantUUID: string, fileID: string) =>
    downloadFile(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/files/${encodeURIComponent(fileID)}${queryString({ tenant_uuid: tenantUUID })}`,
      { method: 'GET' },
      fileID,
    ),
  // 预览用：拿 blob 不触发下载（材料点开看，另存走 downloadFile/资料包）
  fileBlob: (id: string, tenantUUID: string, fileID: string) =>
    fetchFileBlob(
      `/api/admin/v1/startup-agent/web-cases/${encodeURIComponent(id)}/files/${encodeURIComponent(fileID)}${queryString({ tenant_uuid: tenantUUID })}`,
      { method: 'GET' },
    ),
  // 预览打开（内地/海外材料共用）：先开空窗防拦截，blob objectURL 回填
  // ——图片/PDF 新窗即看；弹窗被拦截退回强制下载。失败向上抛由调用方提示。
  previewFile: async (id: string, tenantUUID: string, fileID: string) => {
    const win = window.open('', '_blank', 'noopener=false')
    if (!win) {
      await WebCases.downloadFile(id, tenantUUID, fileID)
      return
    }
    try {
      const { blob } = await WebCases.fileBlob(id, tenantUUID, fileID)
      win.location.replace(URL.createObjectURL(blob))  // 预览窗生命周期内不回收
    } catch (e) {
      win.close()
      throw e
    }
  },
}

export type DownloadChannelStatus = 'active' | 'archived'

export type DownloadChannelItem = {
  uuid: string
  code: string
  name: string
  description: string
  status: DownloadChannelStatus
  visit_count: number
  download_count: number
  created_at: string
  updated_at: string
}

export type DownloadChannelInput = {
  code: string
  name: string
  description?: string
  status: DownloadChannelStatus
}

export type DownloadChannelListParams = {
  q?: string
  status?: string
  start?: string
  end?: string
  limit?: number
  offset?: number
}

export type DownloadChannelDailyPoint = {
  date: string
  visit_count: number
  download_count: number
}

export type DownloadChannelPlatformPoint = {
  platform: string
  download_count: number
}

export type DownloadChannelStats = {
  total_visits: number
  total_downloads: number
  trend: DownloadChannelDailyPoint[]
  platforms: DownloadChannelPlatformPoint[]
}

export const DownloadChannels = {
  list: (params: DownloadChannelListParams = {}) =>
    api<{ items: DownloadChannelItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/download-channels${queryString(params)}`,
    ),
  stats: (params: Pick<DownloadChannelListParams, 'q' | 'status' | 'start' | 'end'> = {}) =>
    api<DownloadChannelStats>(`/api/admin/v1/platform/download-channels/stats${queryString(params)}`),
  create: (body: DownloadChannelInput) =>
    api<{ item: DownloadChannelItem }>('/api/admin/v1/platform/download-channels', {
      method: 'POST',
      body: JSON.stringify(body),
    }),
  patch: (uuid: string, body: DownloadChannelInput) =>
    api<{ item: DownloadChannelItem }>(`/api/admin/v1/platform/download-channels/${encodeURIComponent(uuid)}`, {
      method: 'PATCH',
      body: JSON.stringify(body),
    }),
  delete: (uuid: string) =>
    api<{ ok: boolean }>(`/api/admin/v1/platform/download-channels/${encodeURIComponent(uuid)}`, {
      method: 'DELETE',
    }),
}

export type ShareGrowthItem = {
  owner_account_uuid: string
  owner_display_name: string
  owner_phone_masked: string
  invite_code: string
  status: DownloadChannelStatus
  visit_count: number
  download_count: number
  first_event_at?: string
  last_event_at?: string
  created_at: string
}

export type ShareGrowthListParams = {
  q?: string
  status?: string
  start?: string
  end?: string
  limit?: number
  offset?: number
}

export type ShareGrowthPlatformPoint = {
  platform: string
  download_count: number
}

export type ShareGrowthStats = {
  total_codes: number
  active_sharers: number
  total_visits: number
  total_downloads: number
  trend: DownloadChannelDailyPoint[]
  platforms: ShareGrowthPlatformPoint[]
}

export const ShareGrowth = {
  list: (params: ShareGrowthListParams = {}) =>
    api<{ items: ShareGrowthItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/share-growth${queryString(params)}`,
    ),
  stats: (params: Pick<ShareGrowthListParams, 'q' | 'status' | 'start' | 'end'> = {}) =>
    api<ShareGrowthStats>(`/api/admin/v1/platform/share-growth/stats${queryString(params)}`),
}

// ----- Audit center -----

export type AuditEvent = {
  id: number
  occurredAt: string
  tenantId?: number
  tenantName?: string
  accountId?: number
  accountName?: string
  accountUsername?: string
  actorKind: string
  actingAs?: string
  domain: string
  eventKind: string
  severity: string
  resourceKind?: string
  resourceUuid?: string
  businessObject?: string
  executorName?: string
  targetAccountId?: number
  targetAccountName?: string
  targetResourceUuid?: string
  traceId?: string
  ip?: string
  userAgent?: string
  payload: unknown
  durationMs: number
}

export type AuditSummary = {
  todayTotal: number
  riskTotal: number
  dlqTotal: number
  pendingTotal: number
  failedTotal: number
  lastAuditAt?: string
}

export type AuditDLQItem = {
  id: number
  topic: string
  tenantId?: number
  traceId?: string
  payload: unknown
  attempts: number
  lastError?: string
  createdAt: string
  doneAt?: string
  dlqAt?: string
  dlqReason?: string
  idempotencyKey?: string
}

export type AuditListParams = {
  category?: 'operation' | 'system' | 'all'
  tenant_id?: number
  actor_kind?: string
  account_id?: number
  domain?: string
  event_kind?: string
  severity?: string
  trace_id?: string
  q?: string
  occurred_from?: string
  occurred_to?: string
  limit?: number
  offset?: number
}

export const AuditCenter = {
  getPlatformSummary: () =>
    api<AuditSummary>('/api/admin/v1/platform/audit-summary'),
  getTenantSummary: () =>
    api<AuditSummary>('/api/admin/v1/tenant/audit-summary'),
  listPlatformEvents: (params: AuditListParams = {}) =>
    api<{ items: AuditEvent[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/audit-events${queryString(params)}`,
    ),
  listTenantEvents: (params: AuditListParams = {}) =>
    api<{ items: AuditEvent[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/tenant/audit-events${queryString(params)}`,
    ),
  listDLQ: (params: { topic?: string; q?: string; limit?: number; offset?: number } = {}) =>
    api<{ items: AuditDLQItem[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/audit-outbox-dlq${queryString(params)}`,
    ),
  retryDLQ: (id: number) =>
    api<{ id: number; action: string; ok: boolean }>(
      `/api/admin/v1/platform/audit-outbox-dlq/${encodeURIComponent(String(id))}/retry`,
      { method: 'POST', body: JSON.stringify({}) },
    ),
  ignoreDLQ: (id: number) =>
    api<{ id: number; action: string; ok: boolean }>(
      `/api/admin/v1/platform/audit-outbox-dlq/${encodeURIComponent(String(id))}/ignore`,
      { method: 'POST', body: JSON.stringify({}) },
    ),
}

// ----- F19: Observability — Runtime Call Logs -----

export type CallLogEntry = {
  id: number
  uuid: string
  tenantId?: number
  accountId?: number
  traceId?: string
  spanId?: string
  direction: string
  targetService: string
  operation?: string
  runtimeEnvironmentId?: number
  agentId?: number
  agentName?: string
  digitalEmployeeId?: number
  digitalEmployeeName?: string
  conversationUuid?: string
  messageUuid?: string
  streamId?: string
  method: string
  path: string
  httpStatus?: number
  grpcCode?: number
  latencyMs: number
  requestBodyJson: unknown
  responseBodyJson: unknown
  bodyTruncated: boolean
  errorMessage?: string
  tags: unknown
  createdAt: string
}

export type CallLogListParams = {
  tenant_id?: number
  target_service?: string
  method?: string
  http_status?: number
  direction?: string
  trace_id?: string
  operation?: string
  runtime_environment_id?: number
  agent_id?: number
  agent_name?: string
  digital_employee_id?: number
  digital_employee_name?: string
  conversation_uuid?: string
  message_uuid?: string
  stream_id?: string
  from?: string
  to?: string
  errors_only?: string
  q?: string
  limit?: number
  offset?: number
}

export const ObservabilityCallLogs = {
  listPlatform: (params: CallLogListParams = {}) =>
    api<{ items: CallLogEntry[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/platform/observability/call-logs${queryString(params)}`,
    ),
  listTenant: (params: CallLogListParams = {}) =>
    api<{ items: CallLogEntry[]; total: number; limit: number; offset: number }>(
      `/api/admin/v1/tenant/observability/call-logs${queryString(params)}`,
    ),
  getDetail: (uuid: string, scope: 'platform' | 'tenant') =>
    api<CallLogEntry>(
      `/api/admin/v1/${scope}/observability/call-logs/${encodeURIComponent(uuid)}`,
    ),
  getTimeline: (
    params: Pick<CallLogListParams, 'trace_id' | 'message_uuid' | 'stream_id'>,
    scope: 'platform' | 'tenant',
  ) =>
    api<{ items: CallLogEntry[]; total: number }>(
      `/api/admin/v1/${scope}/observability/call-log-timeline${queryString(params)}`,
    ),
}

// ===== F24: Agent 运行监测 + 会话检索 (observability) =====

export type AgentRunItem = {
  uuid: string
  startedAt: string
  tenantId: number
  tenantName?: string
  digitalEmployeeId: number
  agentName: string
  accountId?: number
  accountName?: string
  runtimeKind: string
  triggerSource: string
  status: string
  durationMs?: number
  firstOutputMs?: number
  thinkingMs?: number
  hitlWaitMs?: number
  toolCallCount: number
  toolErrorCount: number
  a2aEdgeCount: number
  totalTokens?: number
  usageSource: string
  model?: string
  agentVersion?: number
  errorCode?: string
  conversationUuid?: string
  messageUuid: string
  traceId?: string
  backfilled?: boolean
}

export type AgentRunStep = {
  seq: number
  stepKind: string
  name?: string
  status: string
  startedAt: string
  durationMs?: number
  refKind?: string
  refUuid?: string
  errorMessage?: string
}

export type AgentRunDetail = {
  run: AgentRunItem
  inputTokens?: number
  outputTokens?: number
  errorMessage?: string
  roomId?: number
  steps: AgentRunStep[]
  billingUsage?: { matchedLevel: string; totalTokens: number; credits: number }
  links: {
    conversationUuid?: string
    traceId?: string
    a2aEdges: string[]
    contentAvailable: boolean
    rootA2aEdgeUuid?: string
  }
}

export type AgentRunStats = {
  totals: {
    runs: number
    completed: number
    failed: number
    cancelled: number
    awaitingUser: number
    successRate: number | null
    conversations: number
    p50DurationMs: number | null
    p95DurationMs: number | null
    avgThinkingMs: number | null
    thinkingCoverage: number | null
    totalTokens: number
    tokenCoverage: number | null
  }
  buckets: { key: string; runs: number; completed: number; failed: number; totalTokens: number }[]
  slowest_tools: { name: string; calls: number; avgDurationMs: number; errorCount: number }[]
}

export type AgentRunChain = {
  root_run_uuid: string
  nodes: {
    runUuid: string
    digitalEmployeeId: number
    agentName: string
    runtimeKind: string
    status: string
    durationMs?: number
    totalTokens?: number
    depth: number
  }[]
  edges: {
    edgeUuid: string
    fromAgentId: number
    fromAgentName: string
    toAgentId: number
    toAgentName: string
    status: string
    invokeKind: string
    depth: number
    latencyMs?: number
    tokensIn?: number
    tokensOut?: number
    createdAt: string
    requestPayload?: unknown
    responsePayload?: unknown
    errorMessage?: string
  }[]
  truncated: boolean
}

export type AgentRunListParams = {
  tenant_id?: number
  digital_employee_id?: number
  account_id?: number
  runtime_kind?: string
  trigger_source?: string
  status?: string
  model?: string
  min_duration_ms?: number
  errors_only?: string
  has_tool_error?: string
  conversation_uuid?: string
  from?: string
  to?: string
  q?: string
  limit?: number
  offset?: number
}

export type ObsConversationItem = {
  uuid: string
  tenantId: number
  tenantName?: string
  title: string
  accountId: number
  accountName?: string
  digitalEmployeeId?: number
  agentName?: string
  roomId?: number
  source?: string
  messageCount: number
  lastMessageAt?: string
  createdAt: string
}

export type ObsMessageItem = {
  uuid: string
  role: string
  senderAccountId?: number
  senderAgentId?: number
  status: string
  blocks: unknown
  errorCode?: string
  createdAt: string
}

export const ObservabilityAgentRuns = {
  list: (scope: 'platform' | 'tenant', params: AgentRunListParams = {}) =>
    api<{ items: AgentRunItem[]; total: number }>(
      `/api/admin/v1/${scope}/observability/agent-runs${queryString(params)}`,
    ),
  stats: (
    scope: 'platform' | 'tenant',
    params: Pick<AgentRunListParams, 'tenant_id' | 'digital_employee_id' | 'from' | 'to'> & { group_by?: string } = {},
  ) =>
    api<AgentRunStats>(
      `/api/admin/v1/${scope}/observability/agent-runs/stats${queryString(params)}`,
    ),
  detail: (scope: 'platform' | 'tenant', uuid: string) =>
    api<AgentRunDetail>(
      `/api/admin/v1/${scope}/observability/agent-runs/${encodeURIComponent(uuid)}`,
    ),
  chain: (scope: 'platform' | 'tenant', uuid: string, includePayloads: boolean) =>
    api<AgentRunChain>(
      `/api/admin/v1/${scope}/observability/agent-runs/${encodeURIComponent(uuid)}/chain${includePayloads ? '?include_payloads=true' : ''}`,
    ),
}

export const ObservabilityConversations = {
  list: (
    scope: 'platform' | 'tenant',
    params: {
      tenant_id?: number
      account_id?: number
      digital_employee_id?: number
      q?: string
      from?: string
      to?: string
      limit?: number
      offset?: number
    } = {},
  ) =>
    api<{ items: ObsConversationItem[]; total: number }>(
      `/api/admin/v1/${scope}/observability/conversations${queryString(params)}`,
    ),
  messages: (scope: 'platform' | 'tenant', uuid: string, params: { limit?: number; offset?: number } = {}) =>
    api<{ items: ObsMessageItem[]; total: number; conversation_uuid: string }>(
      `/api/admin/v1/${scope}/observability/conversations/${encodeURIComponent(uuid)}/messages${queryString(params)}`,
    ),
}
