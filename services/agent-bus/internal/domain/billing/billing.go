// Package billing 定义 F11 套餐权益 / 技能定价领域模型的类型和接口契约。
//
// 此包仅承载领域类型 + 接口契约；SQL 实现由计费 PostgreSQL 仓储层负责；
// 业务编排由计费服务层负责；HTTP 路由在 internal/transport/http/admin。
//
// 详见 docs/features/F11-subscription-billing-quota.md §3。
package billing

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	bee "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/beebridge"
)

// ----------------------------------------------------------------------------
// 枚举（跟 SQL CHECK 约束一致；新增值必须同步改 migration + 这里）
// ----------------------------------------------------------------------------

// FeatureType 取值（features.type，F11 §3.1.1）。
const (
	FeatureTypeBoolean   = "boolean"
	FeatureTypeMetered   = "metered"
	FeatureTypeRateLimit = "rate_limit"
)

// BillingCycle 取值（plans.billing_cycle，F11 §3.1.2）。
const (
	BillingCycleMonthly = "monthly"
	BillingCycleYearly  = "yearly"
	BillingCycleNone    = "none"
)

// OperationStatus 取值（skill_operations.status，F11 §3.1.8）。
const (
	OperationStatusActive     = "active"
	OperationStatusDisabled   = "disabled"
	OperationStatusDeprecated = "deprecated"
)

// PriceStatus 取值（skill_default_prices / skill_operation_prices.status，F11 §3.1.9-§3.1.10）。
const (
	PriceStatusActive   = "active"
	PriceStatusDisabled = "disabled"
)

// ----------------------------------------------------------------------------
// Catalog 领域类型（F11 §3.1.1–§3.1.6）
// ----------------------------------------------------------------------------

// Feature 是 features 表的领域映射。
type Feature struct {
	ID          int64
	Code        string
	Name        string
	Description string
	Type        string // FeatureTypeBoolean / Metered / RateLimit
	Unit        string
	SortOrder   int
	IsActive    bool
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Plan 是 plans 表的领域映射。
type Plan struct {
	ID             int64
	Code           string
	Name           string
	Description    string
	PriceMonthly   *float64
	PriceYearly    *float64
	Currency       string
	BillingCycle   string // BillingCycleMonthly / Yearly / None
	TrialDays      int
	MonthlyCredits int64
	SortOrder      int
	IsActive       bool
	IsSystem       bool
	IsRecommended  bool
	Prices         []PlanPrice
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// PlanPrice 是 plan_prices 表的领域映射。Plan 表达权益层级，PlanPrice 表达按月/按年等价格点。
type PlanPrice struct {
	ID                   int64
	PlanID               int64
	Code                 string
	BillingCycle         string
	Amount               float64
	Currency             string
	IntervalCount        int
	DisplayMonthlyAmount *float64
	OriginalAmount       *float64
	PromotionText        string
	SortOrder            int
	IsActive             bool
	CreatedAt            time.Time
	UpdatedAt            time.Time
}

// PlanVersion 是 plan_versions 表的领域映射（不可变快照）。
type PlanVersion struct {
	ID          int64
	PlanID      int64
	Version     int
	Snapshot    []byte // JSON
	EffectiveAt time.Time
	CreatedAt   time.Time
}

// PlanFeature 是 plan_features 表的领域映射。
type PlanFeature struct {
	ID         int64
	PlanID     int64
	FeatureID  int64
	LimitValue *int64
	LimitUnit  *string
}

// PlanFeatureView 是套餐卡片/后台矩阵展示用的权益行，包含 feature 元数据。
type PlanFeatureView struct {
	ID          int64
	PlanID      int64
	FeatureID   int64
	FeatureCode string
	FeatureName string
	FeatureType string
	SortOrder   int
	LimitValue  *int64
	LimitUnit   *string
}

// CreditExchangeRate 是 credit_exchange_rates 表的领域映射。
type CreditExchangeRate struct {
	ID             int64
	ResourceType   string
	ResourceName   string
	CreditsPerUnit float64 // numeric(12,4)
	UnitName       string
	IsActive       bool
	UpdatedAt      time.Time
}

// CreditPack 是 credit_packs 表的领域映射。
type CreditPack struct {
	ID        int64
	Name      string
	Credits   int64
	Price     float64 // numeric(12,2)
	Currency  string
	SortOrder int
	IsActive  bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// ----------------------------------------------------------------------------
// Skill Pricing 领域类型（F11 §3.1.7–§3.1.11）
// ----------------------------------------------------------------------------

// SkillOperation 是 skill_operations 表的领域映射。
type SkillOperation struct {
	ID            int64
	SkillID       int64
	OperationCode string
	OperationName string
	Description   string
	InputSchema   []byte // JSON
	OutputSchema  []byte // JSON
	Status        string // OperationStatusActive / Disabled / Deprecated
	SortOrder     int
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// SkillDefaultPrice 是 skill_default_prices 表的领域映射。
type SkillDefaultPrice struct {
	ID             int64
	SkillID        int64
	CreditsPerCall int64
	EffectiveFrom  time.Time
	EffectiveTo    *time.Time
	Status         string // PriceStatusActive / Disabled
	CreatedBy      *int64
	UpdatedBy      *int64
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// SkillOperationPrice 是 skill_operation_prices 表的领域映射。
type SkillOperationPrice struct {
	ID             int64
	SkillID        int64
	OperationCode  string
	CreditsPerCall int64
	EffectiveFrom  time.Time
	EffectiveTo    *time.Time
	Status         string // PriceStatusActive / Disabled
	CreatedBy      *int64
	UpdatedBy      *int64
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// SkillBillingConsent 是 skill_billing_consents 表的领域映射（只追加）。
type SkillBillingConsent struct {
	ID                      int64
	TenantID                int64
	AccountID               int64
	SkillID                 int64
	PricingMode             string
	DefaultCreditsSnapshot  *int64
	OperationPricesSnapshot []byte // JSON
	ConsentedAt             time.Time
}

// SkillBillingConfig 是扣费链路读取的技能计费配置快照。
type SkillBillingConfig struct {
	SkillID        int64
	SkillUUID      string
	SkillName      string
	SkillVersionID *int64
	BillingType    string
	PricingMode    string
}

// UsageEvent 是 usage_events 表的领域映射。它记录一次资源实际消耗，作为报表与审计事实。
type UsageEvent struct {
	MeteringSource           string  `json:"metering_source,omitempty"`
	Model                    *string `json:"model"`
	InputTokens              *string `json:"input_tokens"`
	OutputTokens             *string `json:"output_tokens"`
	CacheCreationInputTokens *string `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     *string `json:"cache_read_input_tokens"`
	AmountKnown              bool    `json:"amount_known"`
	ChargeCount              int64   `json:"charge_count"`
	RefundCount              int64   `json:"refund_count"`
	NetUSD                   string  `json:"net_usd,omitempty"`
	ID                       int64
	TenantID                 int64
	AccountID                *int64
	AccountName              string
	AgentID                  *int64
	AgentUUID                string
	SkillID                  *int64
	SkillUUID                string
	SkillVersionID           *int64
	OperationCode            string
	PricingMode              string
	ResourceType             string
	Amount                   int64
	CreditsCost              int64
	IdempotencyKey           string
	Status                   string
	Metadata                 []byte
	CreatedAt                time.Time

	// 归因字段（000042 起；扣费主体仍是 TenantID，这些用于用户/场景/数字员工归因与账单下钻）。
	OccurredAt       *time.Time
	SourceScene      string
	SourceObjectType string
	SourceObjectID   string
	DisplayTitle     string
}

// UsageAggregate 是 usage_aggregates 表的领域映射。
type UsageAggregate struct {
	UnknownAmountCount int64 `json:"unknown_amount_count"`
	ID                 int64
	TenantID           int64
	TenantName         string // 列表查询富化：LEFT JOIN tenants 取租户名，不持久化
	ResourceType       string
	Period             string
	PeriodStart        time.Time
	SkillID            *int64
	OperationCode      string
	TotalAmount        int64
	TotalCredits       int64
	EventCount         int64
	LastAggregatedAt   time.Time
	UpdatedAt          time.Time
}

// UsageTrendPoint 是按 period_start 桶的用量趋势点（admin 用量统计趋势图）。
type UsageTrendPoint struct {
	UnknownAmountCount int64     `json:"unknown_amount_count"`
	PeriodStart        time.Time `json:"period_start"`
	ResourceType       string    `json:"resource_type"`
	TotalAmount        int64     `json:"total_amount"`
	TotalCredits       int64     `json:"total_credits"`
	EventCount         int64     `json:"event_count"`
}

// UsageAggregateSummary 是 admin 用量统计页汇总视图：
// 筛选范围内按资源类型合计 + 按 period_start 桶的趋势序列。
// 不同资源类型的 total_amount 单位不可比（token/分钟/次），只有积分可跨类型加总。
type UsageAggregateSummary struct {
	ByResource []UsageResourceSum `json:"by_resource"`
	Trend      []UsageTrendPoint  `json:"trend"`
}

// TenantUsageRank 是租户用量排行行（LEFT JOIN tenants / credit_wallets / 有效订阅套餐富化）。
type TenantUsageRank struct {
	UnknownAmountCount int64  `json:"unknown_amount_count"`
	TenantID           int64  `json:"tenant_id"`
	TenantName         string `json:"tenant_name"`
	PlanName           string `json:"plan_name"`
	WalletBalance      int64  `json:"wallet_balance"`
	TotalCredits       int64  `json:"total_credits"`
	TotalAmount        int64  `json:"total_amount"`
	EventCount         int64  `json:"event_count"`
}

const (
	UsageResourceSkill     = "skill"
	UsageResourceLLM       = "llm"
	UsageResourceRTCMinute = "rtc_minute"

	UsageEventStatusSucceeded = "succeeded"
	UsageEventStatusFailed    = "failed"

	UsagePeriodDaily   = "daily"
	UsagePeriodMonthly = "monthly"

	// source_scene 取值。
	UsageSceneChat        = "chat"
	UsageSceneCron        = "cron"
	UsageSceneRTC         = "rtc"
	UsageSceneExternalAPI = "external_api"
	UsageSceneSystem      = "system"

	// source_object_type 取值。
	UsageObjectConversation = "conversation"
	UsageObjectCronRun      = "cron_run"
	UsageObjectCallSession  = "call_session"
	UsageObjectAPIRequest   = "api_request"

	// RTC 通话分钟折算比 resource_type（credit_exchange_rates seed，000042）。
	RateRTCHumanToHumanMinute = "rtc_human_to_human_minute"
	RateRTCHumanToAgentMinute = "rtc_human_to_agent_minute"

	// RTC 计费场景（metadata.billing_scene）。
	RTCBillingHumanToHuman = "human_to_human"
	RTCBillingHumanToAgent = "human_to_agent"
)

// ----------------------------------------------------------------------------
// 查询视图类型
// ----------------------------------------------------------------------------

// SkillPriceSummary 是技能定价列表页的聚合视图。
type SkillPriceSummary struct {
	SkillID        int64
	SkillUUID      string
	SkillName      string
	BillingType    string
	PricingMode    string
	CreditsPerCall *int64 // from skill_default_prices; nil = not set
	OperationCount int64  // count of active skill_operations
}

// SkillOperationPriceView 是 operation 定价列表的聚合视图。
type SkillOperationPriceView struct {
	SkillID         int64
	OperationCode   string
	OperationName   string
	OperationStatus string
	CreditsPerCall  *int64 // from skill_operation_prices; nil = uses default
	IsOverridden    bool
}

// ----------------------------------------------------------------------------
// 筛选类型
// ----------------------------------------------------------------------------

// PlanFilter 套餐列表筛选。
type PlanFilter struct {
	IsActive *bool
	Keyword  string
	Offset   int
	Limit    int
}

// FeatureFilter 权益特性列表筛选。
type FeatureFilter struct {
	IsActive *bool
	Type     string
	Keyword  string
	Offset   int
	Limit    int
}

// CreditPackFilter 加量包列表筛选。
type CreditPackFilter struct {
	IsActive *bool
	Offset   int
	Limit    int
}

// SkillPriceFilter 技能定价列表筛选。
type SkillPriceFilter struct {
	BillingType string
	PricingMode string
	Keyword     string
	Offset      int
	Limit       int
}

// SkillOperationFilter 技能 operation 列表筛选。
type SkillOperationFilter struct {
	Status  string
	Keyword string
	Offset  int
	Limit   int
}

// UsageEventFilter 用于查询用量明细。
type UsageEventFilter struct {
	TenantID     *int64
	AccountID    *int64
	AgentID      *int64
	ResourceType string
	SourceScene  string
	SkillID      *int64
	// OperationCode 精确匹配 operation_code（技能接口级明细下钻用）。
	OperationCode string
	// Status 精确匹配事件状态（succeeded/failed）；空串不过滤。
	// 聚合行下钻传 succeeded，保证抽屉总数与 usage_aggregates.event_count 同口径。
	Status string
	From   *time.Time
	To     *time.Time
	// ChargedOnly=true 时只返回 credits_cost>0 的事件（账单/消耗明细用，过滤 record-only 留痕）。
	ChargedOnly bool
	Offset      int
	Limit       int
}

// UsageAggregateFilter 用于查询聚合用量。
type UsageAggregateFilter struct {
	TenantID     *int64
	ResourceType string
	Period       string
	PeriodStart  *time.Time
	// PeriodFrom / PeriodTo 对 period_start 做闭区间范围筛选（>= from AND <= to），
	// 与 PeriodStart 精确匹配可同时存在但语义上应互斥使用。
	PeriodFrom *time.Time
	PeriodTo   *time.Time
	SkillID    *int64
	Offset     int
	Limit      int
}

// ----------------------------------------------------------------------------
// Repository（Phase 1A：catalog + skill pricing，不含 wallet / payment / usage）
// ----------------------------------------------------------------------------

// Repository 定义 billing 领域的数据持久化接口。
type Repository interface {
	// --- Features ---
	ListFeatures(ctx context.Context, f FeatureFilter) ([]Feature, int64, error)
	GetFeature(ctx context.Context, id int64) (*Feature, error)
	GetFeatureByCode(ctx context.Context, code string) (*Feature, error)
	CreateFeature(ctx context.Context, feat *Feature) error
	UpdateFeature(ctx context.Context, feat *Feature) error

	// --- Plans ---
	ListPlans(ctx context.Context, f PlanFilter) ([]Plan, int64, error)
	GetPlan(ctx context.Context, id int64) (*Plan, error)
	GetPlanByCode(ctx context.Context, code string) (*Plan, error)
	CreatePlan(ctx context.Context, p *Plan) error
	UpdatePlan(ctx context.Context, p *Plan) error
	PatchPlanStatus(ctx context.Context, id int64, isActive bool) error
	SetRecommended(ctx context.Context, planID int64) error
	ClearRecommended(ctx context.Context, planID int64) error

	// --- Plan Versions ---
	ListPlanVersions(ctx context.Context, planID int64) ([]PlanVersion, error)
	CreatePlanVersion(ctx context.Context, pv *PlanVersion) error

	// --- Plan Features ---
	ListPlanFeatures(ctx context.Context, planID int64) ([]PlanFeature, error)
	ListPlanFeatureViews(ctx context.Context, planID int64) ([]PlanFeatureView, error)
	SetPlanFeatures(ctx context.Context, planID int64, entries []PlanFeature) error

	// --- Credit Exchange Rates ---
	ListCreditRates(ctx context.Context) ([]CreditExchangeRate, error)
	GetCreditRate(ctx context.Context, id int64) (*CreditExchangeRate, error)
	UpdateCreditRate(ctx context.Context, rate *CreditExchangeRate) error

	// --- Credit Packs ---
	ListCreditPacks(ctx context.Context, f CreditPackFilter) ([]CreditPack, int64, error)
	GetCreditPack(ctx context.Context, id int64) (*CreditPack, error)
	CreateCreditPack(ctx context.Context, cp *CreditPack) error
	UpdateCreditPack(ctx context.Context, cp *CreditPack) error
	PatchCreditPackStatus(ctx context.Context, id int64, isActive bool) error

	// --- Skill Billing Fields ---
	PatchSkillBilling(ctx context.Context, skillID int64, billingType, pricingMode string) error
	GetSkillBillingConfig(ctx context.Context, skillID int64) (*SkillBillingConfig, error)
	GetSkillBillingConfigByUUID(ctx context.Context, skillUUID string) (*SkillBillingConfig, error)

	// --- Skill Operations ---
	ListSkillOperations(ctx context.Context, skillID int64, f SkillOperationFilter) ([]SkillOperation, int64, error)
	GetSkillOperation(ctx context.Context, skillID int64, operationCode string) (*SkillOperation, error)
	CreateSkillOperation(ctx context.Context, op *SkillOperation) error
	BatchCreateSkillOperations(ctx context.Context, ops []SkillOperation) (int64, error)
	UpdateSkillOperation(ctx context.Context, op *SkillOperation) error
	CountActiveSkillOperations(ctx context.Context, skillID int64) (int64, error)

	// --- Skill Default Prices ---
	GetSkillDefaultPrice(ctx context.Context, skillID int64) (*SkillDefaultPrice, error)
	SetSkillDefaultPrice(ctx context.Context, dp *SkillDefaultPrice) error

	// --- Skill Operation Prices ---
	ListSkillOperationPrices(ctx context.Context, skillID int64) ([]SkillOperationPrice, error)
	GetSkillOperationPrice(ctx context.Context, skillID int64, operationCode string) (*SkillOperationPrice, error)
	SetSkillOperationPrice(ctx context.Context, op *SkillOperationPrice) error
	BatchSetSkillOperationPrices(ctx context.Context, prices []SkillOperationPrice) error
	DeleteSkillOperationPrice(ctx context.Context, skillID int64, operationCode string) error

	// --- Skill Billing Consents ---
	GetSkillBillingConsent(ctx context.Context, tenantID, accountID, skillID int64) (*SkillBillingConsent, error)
	CreateSkillBillingConsent(ctx context.Context, consent *SkillBillingConsent) error

	// --- Skill Pricing Views ---
	ListSkillPrices(ctx context.Context, f SkillPriceFilter) ([]SkillPriceSummary, int64, error)
	ListSkillOperationPriceViews(ctx context.Context, skillID int64) ([]SkillOperationPriceView, error)

	// WithTenantBillingTransaction serializes subscription changes and grants for one tenant.
	WithTenantBillingTransaction(ctx context.Context, tenantID int64, fn func(Repository) error) error

	// --- Phase 1B: Subscriptions ---
	GetActiveSubscription(ctx context.Context, tenantID int64) (*Subscription, error)
	GetLatestSubscription(ctx context.Context, tenantID int64) (*Subscription, error)
	GetSubscription(ctx context.Context, id int64) (*Subscription, error)
	GetTenantCreatedAt(ctx context.Context, tenantID int64) (time.Time, error)
	GetTenantUUID(ctx context.Context, tenantID int64) (string, error)
	CreateSubscription(ctx context.Context, sub *Subscription) error
	CreateSubscriptionWithEntitlements(ctx context.Context, sub *Subscription, ents []Entitlement) error
	UpdateSubscriptionStatus(ctx context.Context, id int64, status string) error
	UpdateSubscriptionPeriod(ctx context.Context, id int64, start, end time.Time) error
	UpdateSubscriptionPlan(ctx context.Context, id int64, planID int64, planVersionID *int64) error
	UpdateSubscriptionMetadata(ctx context.Context, id int64, metadata []byte) error
	CancelSubscription(ctx context.Context, id int64, reason string, canceledAt time.Time) error
	ListExpiredSubscriptions(ctx context.Context, before time.Time, limit int) ([]Subscription, error)
	ListRenewableSubscriptions(ctx context.Context, before time.Time, limit int) ([]Subscription, error)
	ListGraceExpiredSubscriptions(ctx context.Context, graceDays int, now time.Time, limit int) ([]Subscription, error)
	ListPendingPlanChangeSubscriptions(ctx context.Context, now time.Time, limit int) ([]Subscription, error)
	ListActiveSubscriptionsByPlan(ctx context.Context, planID int64) ([]Subscription, error)

	// --- Phase 1B: Entitlements ---
	ListEntitlements(ctx context.Context, tenantID int64) ([]Entitlement, error)
	ListEntitlementViews(ctx context.Context, tenantID int64) ([]EntitlementView, error)
	GetEntitlement(ctx context.Context, tenantID int64, featureCode string) (*Entitlement, error)
	CreateEntitlement(ctx context.Context, ent *Entitlement) error
	BatchCreateEntitlements(ctx context.Context, ents []Entitlement) error
	DeactivateEntitlementsBySubscription(ctx context.Context, subscriptionID int64) error
	ReplaceEntitlementsBySubscription(ctx context.Context, subscriptionID int64, ents []Entitlement) error
	SyncDriveQuotaFromEntitlement(ctx context.Context, tenantID int64) error

	// --- Phase 1B: Entitlement Overrides ---
	ListEntitlementOverrides(ctx context.Context, tenantID int64) ([]EntitlementOverride, error)
	ListEntitlementOverridesFiltered(ctx context.Context, f OverrideFilter) ([]EntitlementOverride, int64, error)
	GetEntitlementOverride(ctx context.Context, id int64) (*EntitlementOverride, error)
	GetActiveOverride(ctx context.Context, tenantID int64, featureID int64) (*EntitlementOverride, error)
	CreateEntitlementOverride(ctx context.Context, ov *EntitlementOverride) error
	UpdateEntitlementOverride(ctx context.Context, ov *EntitlementOverride) error
	PatchOverrideStatus(ctx context.Context, id int64, status string, updatedBy *int64) error

	// --- Phase 1B: Credit Wallet ---
	GetWalletByTenant(ctx context.Context, tenantID int64) (*CreditWallet, error)
	CreateWallet(ctx context.Context, w *CreditWallet) error
	LockWalletForUpdate(ctx context.Context, tx pgx.Tx, tenantID int64) (*CreditWallet, error)
	UpdateWalletBalance(ctx context.Context, tx pgx.Tx, walletID int64, balance, overdraftUsed int64) error
	UpdateWalletOverdraftLimit(ctx context.Context, walletID int64, overdraftLimit int64) error
	SetWalletFrozen(ctx context.Context, walletID int64, frozen bool) error
	ListRecoverableWallets(ctx context.Context, limit int) ([]CreditWallet, error)

	// --- Phase 1B: Credit Grants ---
	CreateGrant(ctx context.Context, tx pgx.Tx, g *CreditGrant) error
	ListActiveGrants(ctx context.Context, tx pgx.Tx, walletID int64) ([]CreditGrant, error)
	DeductGrant(ctx context.Context, tx pgx.Tx, grantID int64, amount int64) error
	ExpireGrant(ctx context.Context, tx pgx.Tx, grantID int64) error
	ListExpirableGrants(ctx context.Context, before time.Time, limit int) ([]CreditGrant, error)
	ListGrantsByReference(ctx context.Context, tx pgx.Tx, refType string, refID int64) ([]CreditGrant, error)
	SumExpiringCredits(ctx context.Context, walletID int64, withinDays int) (total int64, nearestAt *time.Time, err error)

	// --- Phase 1B: Credit Ledger ---
	CreateLedgerEntry(ctx context.Context, tx pgx.Tx, entry *CreditLedgerEntry) error
	LedgerEntryExists(ctx context.Context, bizNo string) (bool, error)
	ListLedgerEntries(ctx context.Context, f LedgerFilter) ([]CreditLedgerEntry, int64, error)

	// --- Phase 1B: Payment Orders ---
	CreatePaymentOrder(ctx context.Context, order *PaymentOrder) error
	GetCreditPurchasePricing(ctx context.Context) (*CreditPurchasePricing, error)
	GetPaymentOrder(ctx context.Context, id int64) (*PaymentOrder, error)
	GetPaymentOrderByOutTradeNo(ctx context.Context, outTradeNo string) (*PaymentOrder, error)
	LockPaymentOrderForUpdate(ctx context.Context, tx pgx.Tx, id int64) (*PaymentOrder, error)
	UpdatePaymentOrderStatus(ctx context.Context, tx pgx.Tx, id int64, status string) error
	UpdatePaymentOrderPrepay(ctx context.Context, tx pgx.Tx, id int64, status string, providerPrepay []byte) error
	MarkPaymentOrderPaid(ctx context.Context, tx pgx.Tx, id int64, providerTradeNo string, paidAt time.Time) error
	MarkPaymentOrderFulfilled(ctx context.Context, tx pgx.Tx, id int64) error
	ListPaymentOrders(ctx context.Context, f PaymentOrderFilter) ([]PaymentOrder, int64, error)
	ListPendingProviderPaymentOrders(ctx context.Context, limit int) ([]PaymentOrder, error)
	ListExpiredUnpaidOrders(ctx context.Context, limit int) ([]PaymentOrder, error)
	ListPaidUnfulfilledOrders(ctx context.Context, limit int) ([]PaymentOrder, error)
	HasPendingSubscriptionPayment(ctx context.Context, tenantID, planID int64) (bool, error)
	ClosePaymentOrder(ctx context.Context, id int64) error
	// GetActiveCaseFeeOrderByCase 查同租户同 baigong 工单（product_snapshot->>'case_id'）
	// 的未过期未支付服务费订单（created/paying），用于复用防重复扣款；无则 ErrNotFound。
	GetActiveCaseFeeOrderByCase(ctx context.Context, tenantID int64, caseID string) (*PaymentOrder, error)
	// GetPaidCaseFeeOrderByCase 查该 baigong 工单已支付（paid/refunding）的服务费订单
	//（取消退款用，F24 收款线上化）；无则 ErrNotFound。
	GetPaidCaseFeeOrderByCase(ctx context.Context, caseID string) (*PaymentOrder, error)

	// --- Phase 1B: Payment Callback Logs ---
	CreateCallbackLog(ctx context.Context, log *PaymentCallbackLog) error
	CallbackLogExists(ctx context.Context, provider, providerEventID string) (bool, error)
	MarkCallbackProcessed(ctx context.Context, id int64, processError *string) error

	// --- Phase 1B: Refund Orders ---
	CreateRefundOrder(ctx context.Context, order *RefundOrder) error
	GetRefundOrder(ctx context.Context, id int64) (*RefundOrder, error)
	GetRefundOrderByOutRefundNo(ctx context.Context, outRefundNo string) (*RefundOrder, error)
	LockRefundOrderForUpdate(ctx context.Context, tx pgx.Tx, id int64) (*RefundOrder, error)
	UpdateRefundStatus(ctx context.Context, tx pgx.Tx, id int64, status string) error
	UpdateRefundResult(ctx context.Context, tx pgx.Tx, id int64, status string, providerRefundNo *string, refundedAt *time.Time) error
	MarkRefundFulfilled(ctx context.Context, tx pgx.Tx, id int64, creditsDeducted int64) error
	SumRefundAmountByStatus(ctx context.Context, paymentOrderID int64, statuses []string) (int64, error)
	ListPendingRefunds(ctx context.Context, limit int) ([]RefundOrder, error)

	// --- Phase 1B: Billing Config ---
	ListBillingConfig(ctx context.Context) ([]BillingConfig, error)
	GetBillingConfig(ctx context.Context, key string) (*BillingConfig, error)
	UpdateBillingConfig(ctx context.Context, key, value string, updatedBy *int64) error

	// --- Phase 1C: Usage / Metering ---
	CreateUsageEvent(ctx context.Context, event *UsageEvent) error
	UpsertQuotaUsageEvent(ctx context.Context, event QuotaUsageEventInput) error
	GetUsageEventByIdempotencyKey(ctx context.Context, key string) (*UsageEvent, error)
	ListUsageEvents(ctx context.Context, f UsageEventFilter) ([]UsageEvent, int64, error)
	SumUsageByResource(ctx context.Context, f UsageEventFilter) ([]UsageResourceSum, error)
	SumUsageByScene(ctx context.Context, f UsageEventFilter) ([]UsageSceneSum, error)
	SumLedgerAmounts(ctx context.Context, tenantID int64, from, to time.Time) (granted, consumed int64, err error)
	// ListChargeFailedUsageEvents 列出待补扣的 usage_event（charge_failed=true，排除 rtc_minute）。
	ListChargeFailedUsageEvents(ctx context.Context, limit int) ([]UsageEvent, error)
	// UpdateUsageEventChargeOutcome 原地更新 usage_event 的 credits_cost 与 metadata（补偿结果）。
	UpdateUsageEventChargeOutcome(ctx context.Context, id int64, creditsCost int64, metadata []byte) error
	UpsertUsageAggregate(ctx context.Context, aggregate *UsageAggregate) error
	RefreshUsageAggregates(ctx context.Context, period string, since time.Time, limit int) (int64, error)
	ListUsageAggregates(ctx context.Context, f UsageAggregateFilter) ([]UsageAggregate, int64, error)
	// SumUsageAggregatesByResource 在筛选范围内按 resource_type 合计聚合用量（admin 汇总卡片）。
	SumUsageAggregatesByResource(ctx context.Context, f UsageAggregateFilter) ([]UsageResourceSum, error)
	// TrendUsageAggregates 在筛选范围内按 period_start × resource_type 输出趋势序列（admin 趋势图）。
	TrendUsageAggregates(ctx context.Context, f UsageAggregateFilter) ([]UsageTrendPoint, error)
	// RankTenantUsage 在筛选范围内按租户合计并按消耗积分降序（admin 租户排行）。
	RankTenantUsage(ctx context.Context, f UsageAggregateFilter, limit int) ([]TenantUsageRank, error)
	// CountTenantLLMCredentials distinguishes never-provisioned tenants from missing active mappings.
	CountTenantLLMCredentials(ctx context.Context, tenantID int64) (active, total int, err error)

	// --- Phase 1B: Transaction support ---
	BeginTx(ctx context.Context) (pgx.Tx, error)
}

// ----------------------------------------------------------------------------
// Service（Phase 1A：catalog + skill pricing CRUD）
// ----------------------------------------------------------------------------

// Service 定义 billing 领域的业务编排接口。
type Service interface {
	// --- Catalog: Features ---
	ListFeatures(ctx context.Context, f FeatureFilter) ([]Feature, int64, error)
	CreateFeature(ctx context.Context, in CreateFeatureInput) (*Feature, error)
	UpdateFeature(ctx context.Context, id int64, in UpdateFeatureInput) (*Feature, error)

	// --- Catalog: Plans ---
	ListPlans(ctx context.Context, f PlanFilter) ([]Plan, int64, error)
	GetPlan(ctx context.Context, id int64) (*Plan, error)
	CreatePlan(ctx context.Context, in CreatePlanInput) (*Plan, error)
	UpdatePlan(ctx context.Context, id int64, in UpdatePlanInput) (*Plan, error)
	PatchPlanStatus(ctx context.Context, id int64, isActive bool) error
	ListPlanVersions(ctx context.Context, planID int64) ([]PlanVersion, error)
	GetPlanFeatures(ctx context.Context, planID int64) ([]PlanFeature, error)
	GetPlanFeatureViews(ctx context.Context, planID int64) ([]PlanFeatureView, error)
	SetPlanFeatures(ctx context.Context, planID int64, in SetPlanFeaturesInput) error

	// --- Catalog: Credit Config ---
	ListCreditRates(ctx context.Context) ([]CreditExchangeRate, error)
	UpdateCreditRate(ctx context.Context, id int64, in SetCreditRateInput) error
	ListCreditPacks(ctx context.Context, f CreditPackFilter) ([]CreditPack, int64, error)
	GetCreditPack(ctx context.Context, id int64) (*CreditPack, error)
	CreateCreditPack(ctx context.Context, in CreateCreditPackInput) (*CreditPack, error)
	UpdateCreditPack(ctx context.Context, id int64, in UpdateCreditPackInput) (*CreditPack, error)
	PatchCreditPackStatus(ctx context.Context, id int64, isActive bool) error

	// --- Skill Pricing ---
	ListSkillPrices(ctx context.Context, f SkillPriceFilter) ([]SkillPriceSummary, int64, error)
	PatchSkillBilling(ctx context.Context, skillID int64, in SetSkillBillingInput) error
	GetSkillDefaultPrice(ctx context.Context, skillID int64) (*SkillDefaultPrice, error)
	SetSkillDefaultPrice(ctx context.Context, skillID int64, in SetSkillDefaultPriceInput) error
	ListSkillOperations(ctx context.Context, skillID int64, f SkillOperationFilter) ([]SkillOperation, int64, error)
	ImportSkillOperations(ctx context.Context, skillID int64, in ImportSkillOperationsInput) (int64, error)
	PatchSkillOperation(ctx context.Context, skillID int64, operationCode string, in PatchSkillOperationInput) error
	ListSkillOperationPrices(ctx context.Context, skillID int64) ([]SkillOperationPriceView, error)
	SetSkillOperationPrices(ctx context.Context, skillID int64, in BatchSetSkillOperationPricesInput) error
	DeleteSkillOperationPrice(ctx context.Context, skillID int64, operationCode string) error
	SaveSkillPricingConfig(ctx context.Context, skillID int64, in SaveSkillPricingConfigInput) error

	// --- Phase 1B: Subscriptions ---
	CreateSubscription(ctx context.Context, in CreateSubscriptionInput) (*Subscription, error)
	GetActiveSubscription(ctx context.Context, tenantID int64) (*Subscription, error)
	GetSubscriptionDetail(ctx context.Context, tenantID int64) (*SubscriptionDetail, error)
	CancelSubscription(ctx context.Context, in CancelSubscriptionInput) error
	RenewSubscription(ctx context.Context, subscriptionID int64) error
	ExpireGracePeriodSubscriptions(ctx context.Context) (int64, error)
	ChangePlan(ctx context.Context, in ChangePlanInput) (*ChangePlanResult, error)
	// AdminAssignTenantPlan 是平台管理员的直接套餐调整：不走支付，不读写 tenants.plan_id。
	AdminAssignTenantPlan(ctx context.Context, in AdminAssignTenantPlanInput) (*AdminAssignTenantPlanResult, error)
	ApplyPendingPlanChanges(ctx context.Context) (int64, error)

	// --- Phase 1B: Entitlements ---
	ProjectEntitlements(ctx context.Context, subscriptionID int64) error
	CheckEntitlement(ctx context.Context, in CheckEntitlementInput) (*EntitlementCheckResult, error)
	ListEntitlements(ctx context.Context, tenantID int64) ([]EntitlementView, error)

	// --- Entitlement Overrides (Admin) ---
	ListEntitlementOverrides(ctx context.Context, f OverrideFilter) ([]EntitlementOverride, int64, error)
	CreateEntitlementOverride(ctx context.Context, in CreateOverrideInput) (*EntitlementOverride, error)
	UpdateEntitlementOverride(ctx context.Context, id int64, in UpdateOverrideInput) (*EntitlementOverride, error)
	// PatchOverrideStatus 状态变更并返回覆写对象（调用方审计取归属租户，无需二次查询）。
	PatchOverrideStatus(ctx context.Context, id int64, status string, operatorID int64) (*EntitlementOverride, error)

	// --- Phase 1B: Wallet ---
	GetOrCreateWallet(ctx context.Context, tenantID int64) (*CreditWallet, error)
	GrantCredits(ctx context.Context, in GrantCreditsInput) (*CreditGrant, error)
	ConsumeCredits(ctx context.Context, in ConsumeCreditsInput) (*ConsumeResult, error)
	ExpireCredits(ctx context.Context) (int64, error)
	RepayOverdraft(ctx context.Context, tenantID int64) error
	GetWalletBalance(ctx context.Context, tenantID int64) (*CreditWallet, error)
	GetWalletSummary(ctx context.Context, tenantID int64) (*WalletSummary, error)
	ListLedger(ctx context.Context, f LedgerFilter) ([]CreditLedgerEntry, int64, error)

	// --- Phase 1B: Payment ---
	CreatePaymentOrder(ctx context.Context, in CreatePaymentOrderInput) (*PaymentOrder, error)
	// CreateCaseFeeOrder 垂域工单服务费下单（F24 收款线上化，代账/注册按 kind 分派）：
	// 金额服务端经 baigong ops 查工单 final_price 决定；同工单存在未过期未支付
	// 且金额渠道一致的订单时复用。
	CreateCaseFeeOrder(ctx context.Context, in CreateCaseFeeOrderInput) (*PaymentOrder, error)
	// RefundCaseFeeByCase 工单维度退款（F24 取消退款）：按 case 找已支付服务费订单，
	// amount<=0 时退剩余全额；经 CreateRefund 走微信原路退。
	RefundCaseFeeByCase(ctx context.Context, in RefundCaseFeeInput) (*RefundOrder, error)
	GetPaymentOrderByOutTradeNo(ctx context.Context, outTradeNo string) (*PaymentOrder, error)
	// SyncPaymentOrder 主动向支付渠道查询单个订单，并在已支付时完成落账与履约。
	SyncPaymentOrder(ctx context.Context, tenantID int64, outTradeNo string) (*PaymentOrder, error)
	MarkOrderPaid(ctx context.Context, in MarkOrderPaidInput) error
	FulfillPaidOrder(ctx context.Context, orderID int64) error
	CloseExpiredOrders(ctx context.Context) (int64, error)
	SyncPendingPaymentOrders(ctx context.Context, limit int) (int64, error)
	FulfillPaidOrders(ctx context.Context, limit int) (int64, error)
	ListPaymentOrders(ctx context.Context, f PaymentOrderFilter) ([]PaymentOrder, int64, error)
	HandlePaymentCallback(ctx context.Context, provider string, body []byte, headers map[string]string) error

	// --- Phase 1B: Refund ---
	CreateRefund(ctx context.Context, in CreateRefundInput) (*RefundOrder, error)
	FulfillRefund(ctx context.Context, refundID int64) error
	SyncPendingRefunds(ctx context.Context, limit int) (int64, error)
	ListPendingRefunds(ctx context.Context) ([]RefundOrder, error)

	// --- Phase 1B: Config ---
	ListBillingConfig(ctx context.Context) ([]BillingConfig, error)
	GetBillingConfig(ctx context.Context, key string) (*BillingConfig, error)
	UpdateBillingConfig(ctx context.Context, key string, in UpdateBillingConfigInput) error

	// --- Phase 1C: Usage / Skill Billing ---
	RecordUsageEvent(ctx context.Context, in RecordUsageEventInput) (*UsageEvent, error)
	ListUsageEvents(ctx context.Context, f UsageEventFilter) ([]UsageEvent, int64, error)
	RefreshUsageAggregates(ctx context.Context, period string, since time.Time, limit int) (int64, error)
	ListUsageAggregates(ctx context.Context, f UsageAggregateFilter) ([]UsageAggregate, int64, error)
	// GetUsageAggregateSummary 返回 admin 用量统计页汇总（按资源类型合计 + 趋势）。
	GetUsageAggregateSummary(ctx context.Context, f UsageAggregateFilter) (*UsageAggregateSummary, error)
	// RankTenantUsage 返回租户用量排行（按消耗积分降序，limit 默认 10、上限 100）。
	RankTenantUsage(ctx context.Context, f UsageAggregateFilter, limit int) ([]TenantUsageRank, error)
	ChargeSkillCall(ctx context.Context, in ChargeSkillCallInput) (*SkillChargeResult, error)
	ChargeSkillCallBySkillUUID(ctx context.Context, in ChargeSkillCallInput) (*SkillChargeResult, error)

	// --- Phase 1E: LLM Usage Billing ---

	// --- Usage Billing 基础（000042）：统一 facade / AIGC push / RTC / 汇总 ---
	RecordAndChargeUsage(ctx context.Context, in RecordAndChargeUsageInput) (*UsageChargeResult, error)
	ChargeRTCCallSession(ctx context.Context, in ChargeRTCInput) (*UsageChargeResult, error)
	GetUsageSummary(ctx context.Context, f UsageSummaryFilter) (*UsageSummary, error)
	GetMonthlyStatement(ctx context.Context, tenantID int64, month string) (*MonthlyStatement, error)
	ReconcileChargeFailedUsage(ctx context.Context, limit int) (ReconcileResult, error)
}

// ----------------------------------------------------------------------------
// Input DTO（全部 Admin 操作专用）
// ----------------------------------------------------------------------------

// CreateFeatureInput 创建权益特性。
type CreateFeatureInput struct {
	Code        string
	Name        string
	Description string
	Type        string // FeatureTypeBoolean / Metered / RateLimit
	Unit        string
	SortOrder   int
	OperatorID  int64
}

// UpdateFeatureInput 更新权益特性（指针字段 nil = 不更新）。
type UpdateFeatureInput struct {
	Name        *string
	Description *string
	Unit        *string
	SortOrder   *int
	IsActive    *bool
	OperatorID  int64
}

// CreatePlanInput 创建套餐。
type CreatePlanInput struct {
	Code           string
	Name           string
	Description    string
	PriceMonthly   *float64
	PriceYearly    *float64
	Currency       string
	BillingCycle   string
	Prices         []PlanPriceInput
	TrialDays      int
	MonthlyCredits int64
	SortOrder      int
	IsSystem       bool
	IsRecommended  bool
	OperatorID     int64
}

// UpdatePlanInput 更新套餐（指针字段 nil = 不更新）。
type UpdatePlanInput struct {
	Name           *string
	Description    *string
	PriceMonthly   *float64
	PriceYearly    *float64
	BillingCycle   *string
	Prices         *[]PlanPriceInput
	TrialDays      *int
	MonthlyCredits *int64
	SortOrder      *int
	IsRecommended  *bool
	OperatorID     int64
}

// PlanPriceInput 是 Admin 写入套餐价格点的输入。
type PlanPriceInput struct {
	Code                 string
	BillingCycle         string
	Amount               float64
	Currency             string
	IntervalCount        int
	DisplayMonthlyAmount *float64
	OriginalAmount       *float64
	PromotionText        string
	SortOrder            int
	IsActive             bool
}

// PlanFeatureEntry 套餐权益矩阵的单行。
type PlanFeatureEntry struct {
	FeatureID  int64
	LimitValue *int64
	LimitUnit  *string
}

// SetPlanFeaturesInput 全量替换套餐权益矩阵。
type SetPlanFeaturesInput struct {
	Features   []PlanFeatureEntry
	OperatorID int64
}

// SetCreditRateInput 更新积分折算比例。
type SetCreditRateInput struct {
	ResourceName   string
	CreditsPerUnit float64
	UnitName       string
	IsActive       bool
	OperatorID     int64
}

// CreateCreditPackInput 创建加量包。
type CreateCreditPackInput struct {
	Name       string
	Credits    int64
	Price      float64
	Currency   string
	SortOrder  int
	OperatorID int64
}

// UpdateCreditPackInput 更新加量包（指针字段 nil = 不更新）。
type UpdateCreditPackInput struct {
	Name       *string
	Credits    *int64
	Price      *float64
	SortOrder  *int
	OperatorID int64
}

// RecordUsageEventInput 记录一次用量事件。
type RecordUsageEventInput struct {
	TenantID       int64
	AccountID      int64
	AgentID        *int64
	AgentUUID      string
	SkillID        *int64
	SkillUUID      string
	SkillVersionID *int64
	OperationCode  string
	PricingMode    string
	ResourceType   string
	Amount         int64
	CreditsCost    int64
	IdempotencyKey string
	Status         string
	Metadata       []byte

	// 归因字段（000042 起）。
	OccurredAt       *time.Time
	SourceScene      string
	SourceObjectType string
	SourceObjectID   string
	DisplayTitle     string
}

// ChargeSkillCallInput 是技能调用前置扣费输入。
type ChargeSkillCallInput struct {
	TenantID       int64
	AccountID      int64
	AgentID        *int64
	AgentUUID      string
	SkillID        int64
	SkillUUID      string
	OperationCode  string
	IdempotencyKey string
	Metadata       []byte
}

// SkillChargeResult 是技能调用扣费结果。
type SkillChargeResult struct {
	Allowed        bool
	SkillID        int64
	SkillUUID      string
	SkillVersionID *int64
	BillingType    string
	PricingMode    string
	OperationCode  string
	CreditsCost    int64
	BalanceAfter   int64
	Reason         string
	UsageEvent     *UsageEvent
}

// SetSkillBillingInput 修改技能 billing_type + pricing_mode。
type SetSkillBillingInput struct {
	BillingType string
	PricingMode string
	OperatorID  int64
}

// SetSkillDefaultPriceInput 设置技能默认价。
type SetSkillDefaultPriceInput struct {
	CreditsPerCall int64
	OperatorID     int64
}

// ImportSkillOperationEntry 批量导入的单条 operation。
type ImportSkillOperationEntry struct {
	OperationCode string
	OperationName string
	Description   string
	InputSchema   []byte // JSON
	OutputSchema  []byte // JSON
	SortOrder     int
}

// ImportSkillOperationsInput 批量导入技能 operation。
type ImportSkillOperationsInput struct {
	Operations []ImportSkillOperationEntry
	OperatorID int64
}

// PatchSkillOperationInput 编辑/禁用单个 operation（指针字段 nil = 不更新）。
type PatchSkillOperationInput struct {
	OperationName *string
	Description   *string
	Status        *string
	SortOrder     *int
	OperatorID    int64
}

// SetSkillOperationPriceEntry 单条 operation 价格设置。
type SetSkillOperationPriceEntry struct {
	OperationCode  string
	CreditsPerCall int64
}

// BatchSetSkillOperationPricesInput 批量设置 operation 价格。
type BatchSetSkillOperationPricesInput struct {
	Prices     []SetSkillOperationPriceEntry
	OperatorID int64
}

// SaveSkillPricingOperationEntry 是技能计费设置聚合保存中的单条 operation。
type SaveSkillPricingOperationEntry struct {
	OperationCode  string
	OperationName  string
	Description    string
	InputSchema    []byte
	OutputSchema   []byte
	SortOrder      int
	CreditsPerCall *int64 // nil = 使用默认价
}

// SaveSkillPricingConfigInput 一次性保存技能计费设置，供 Admin 抽屉底部保存使用。
type SaveSkillPricingConfigInput struct {
	BillingType           string
	PricingMode           string
	DefaultCreditsPerCall *int64
	Operations            []SaveSkillPricingOperationEntry
	DeletedOperationCodes []string
	OperatorID            int64
}

// ============================================================================
// Phase 1B 枚举
// ============================================================================

// SubscriptionStatus 取值（subscriptions.status，F11 §3.2）。
const (
	SubStatusTrialing = "trialing"
	SubStatusActive   = "active"
	SubStatusPastDue  = "past_due"
	SubStatusCanceled = "canceled"
	SubStatusExpired  = "expired"
)

// CreditGrantSource 取值（credit_grants.source，F11 §3.3）。
const (
	GrantSourceSubscription = "subscription"
	GrantSourcePromotion    = "promotion"
	GrantSourcePack         = "pack"
)

// CreditGrantPriority 消耗优先级（数值越小越先消耗）。
const (
	GrantPrioritySubscription = 10
	GrantPriorityPromotion    = 20
	GrantPriorityPack         = 30
)

// LedgerDirection 取值（credit_ledger.direction）。
const (
	LedgerDirectionCredit = "credit"
	LedgerDirectionDebit  = "debit"
)

// LedgerBizType 取值（credit_ledger.biz_type）。
const (
	BizTypeSubscriptionGrant = "subscription_grant"
	BizTypePackPurchase      = "pack_purchase"
	BizTypePromotionGrant    = "promotion_grant"
	BizTypeSkillConsume      = "skill_consume"
	BizTypeConsumeMarker     = "consume_marker"
	BizTypeExpire            = "expire"
	BizTypeRefund            = "refund"
	BizTypeRefundClawback    = "refund_clawback"
	BizTypeLLMConsume        = "llm_consume"
	BizTypeRTCConsume        = "rtc_consume"
	BizTypeOverdraftRepay    = "overdraft_repay"
)

// PaymentOrderType 取值（payment_orders.order_type）。
const (
	OrderTypeSubscription = "subscription"
	OrderTypeCreditPack   = "credit_pack"
	OrderTypeUpgrade      = "upgrade"
	// OrderTypeBookkeepingFee / OrderTypeRegistrationFee 垂域工单服务费（F24 收款
	// 线上化）：金额来自 baigong 工单 final_price，履约=向 baigong ops 推
	// payment_recorded（非积分/订阅入账）。代账=bookkeeping_fee，注册=registration_fee。
	OrderTypeBookkeepingFee  = "bookkeeping_fee"
	OrderTypeRegistrationFee = "registration_fee"
)

// ChangePlanAction 套餐变更结果动作。
const (
	ChangePlanActionUpgrade   = "upgrade"
	ChangePlanActionDowngrade = "downgrade"
	ChangePlanActionScheduled = "scheduled"
)

// PaymentOrderStatus 取值（payment_orders.status）。
const (
	PaymentStatusCreated   = "created"
	PaymentStatusPaying    = "paying"
	PaymentStatusPaid      = "paid"
	PaymentStatusClosed    = "closed"
	PaymentStatusRefunding = "refunding"
	PaymentStatusRefunded  = "refunded"
)

// PaymentProvider 取值（payment_orders.provider）。
const (
	ProviderWechat = "wechat"
	ProviderAlipay = "alipay"
	ProviderManual = "manual"
	ProviderMock   = "mock"
)

const (
	PaymentTradeTypeApp    = "app"
	PaymentTradeTypeNative = "native"
)

// RefundStatus 取值（refund_orders.status）。
const (
	RefundStatusPending     = "pending"
	RefundStatusProcessing  = "processing"
	RefundStatusSuccess     = "success"
	RefundStatusFailed      = "failed"
	RefundStatusNeedsReview = "needs_review"
)

// ============================================================================
// Phase 1B 领域类型
// ============================================================================

// Subscription 订阅记录。
type Subscription struct {
	ID                 int64
	TenantID           int64
	PlanID             int64
	PlanVersionID      *int64
	Status             string
	CurrentPeriodStart time.Time
	CurrentPeriodEnd   time.Time
	TrialEnd           *time.Time
	CanceledAt         *time.Time
	CancelReason       string
	AutoRenew          bool
	Metadata           []byte
	CreatedBy          *int64
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

// Entitlement 权益投影（从 plan_features 生成）。
type Entitlement struct {
	ID             int64
	TenantID       int64
	SubscriptionID int64
	FeatureID      int64
	FeatureCode    string
	FeatureType    string
	GrantedValue   *int64
	GrantedUnit    *string
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// EntitlementView 是 transport 展示和配额页使用的生效权益视图。
type EntitlementView struct {
	Entitlement
	FeatureName       string
	SortOrder         int
	CurrentUsage      *int64
	GrantedValueBytes *int64
	CurrentUsageBytes *int64
	OverrideValue     *int64
	OverrideUnit      *string
	PlanValue         *int64
	PlanUnit          *string
	PlanCode          string
	PlanName          string
}

// EntitlementOverride 权益覆盖。
type EntitlementOverride struct {
	ID            int64
	TenantID      int64
	FeatureID     int64
	OverrideValue *int64
	OverrideUnit  *string
	Reason        string
	Status        string // "active" or "disabled"
	EffectiveFrom time.Time
	EffectiveTo   *time.Time
	CreatedBy     *int64
	UpdatedBy     *int64
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// CreditWallet 积分钱包（一个租户一个）。
type CreditWallet struct {
	ID             int64
	TenantID       int64
	Balance        int64
	OverdraftUsed  int64
	OverdraftLimit int64
	Frozen         bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// WalletSummary 客户端展示用的钱包摘要。
type WalletSummary struct {
	TenantID                  int64      `json:"tenant_id"`
	Balance                   int64      `json:"balance"`
	SubscriptionCredits       int64      `json:"subscription_credits"`
	AddOnCredits              int64      `json:"add_on_credits"`
	ActivityCredits           int64      `json:"activity_credits"`
	OverdraftUsed             int64      `json:"overdraft_used"`
	OverdraftLimit            int64      `json:"overdraft_limit"`
	Frozen                    bool       `json:"frozen"`
	AvailableCredits          int64      `json:"available_credits"`
	ExpiringCreditsTotal      int64      `json:"expiring_credits_total"`
	NearestExpiringAt         *time.Time `json:"nearest_expiring_at"`
	LowCreditWarningThreshold int64      `json:"low_credit_warning_threshold"`
}

// SubscriptionDetail 客户端展示用的订阅详情。
type SubscriptionDetail struct {
	Subscription
	PlanName            string     `json:"plan_name"`
	PlanCode            string     `json:"plan_code"`
	PendingPlanID       int64      `json:"pending_plan_id,omitempty"`
	PendingPlanName     string     `json:"pending_plan_name,omitempty"`
	PendingPlanCode     string     `json:"pending_plan_code,omitempty"`
	PendingBillingCycle string     `json:"pending_billing_cycle,omitempty"`
	PendingEffectiveAt  *time.Time `json:"pending_effective_at,omitempty"`
	InGracePeriod       bool       `json:"in_grace_period"`
	GracePeriodEnd      *time.Time `json:"grace_period_end"`
}

// CreditGrant 积分批次（分桶余额）。
type CreditGrant struct {
	// Metadata is the immutable credit ledger snapshot for this grant.
	Metadata                 []byte
	ID                       int64
	TenantID                 int64
	WalletID                 int64
	Source                   string
	Priority                 int
	OriginalAmount           int64
	Remaining                int64
	ExpiresAt                *time.Time
	ReferenceID              *int64
	ReferenceType            string
	Memo                     string
	IsExpired                bool
	BeeBridgeFundedQuota     int64
	BeeBridgeFundingSnapshot []byte
	PaymentOrderID           *int64
	CreatedAt                time.Time
}

// CreditLedgerEntry 积分流水（只追加）。
type CreditLedgerEntry struct {
	ID           int64
	TenantID     int64
	WalletID     int64
	GrantID      *int64
	Direction    string
	Amount       int64
	BalanceAfter int64
	BizType      string
	BizNo        string
	Metadata     []byte
	CreatedAt    time.Time
}

// PaymentOrder 支付订单。
type PaymentOrder struct {
	// Internal grant plan is persisted into the seven BeeBridge columns, never a DTO.
	BeeBridgeGrant  *bee.GrantPlan `json:"-"`
	ID              int64
	TenantID        int64
	TenantName      string
	AccountID       int64
	AccountName     string
	OutTradeNo      string
	OrderType       string
	ProductID       *int64
	ProductSnapshot []byte
	AmountCents     int64
	Currency        string
	Status          string
	Provider        string
	ProviderTradeNo *string
	ProviderPrepay  []byte
	PaidAt          *time.Time
	ClosedAt        *time.Time
	ExpireAt        *time.Time
	Fulfilled       bool
	FulfilledAt     *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time

	BeeBridgeTopupStatus string `json:"-"`
}

// PaymentCallbackLog 支付回调日志。
type PaymentCallbackLog struct {
	ID              int64
	Provider        string
	ProviderEventID *string
	OutTradeNo      *string
	RawBody         string
	HeadersDigest   *string
	Processed       bool
	ProcessError    *string
	CreatedAt       time.Time
}

// RefundOrder 退款订单。
type RefundOrder struct {
	ID                int64
	TenantID          int64
	PaymentOrderID    int64
	OutRefundNo       string
	RefundAmountCents int64
	Reason            string
	Status            string
	Provider          string
	ProviderRefundNo  *string
	CreditsDeducted   int64
	RefundedAt        *time.Time
	Fulfilled         bool
	FulfilledAt       *time.Time
	CreatedBy         *int64
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// BillingConfig 全局计费配置键值对。
type BillingConfig struct {
	ID          int64
	Key         string
	Value       string
	Description string
	UpdatedBy   *int64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type QuotaUsageEventInput struct {
	TenantID         int64
	FeatureCode      string
	ThresholdPercent int
	UsedValue        int64
	LimitValue       int64
	Unit             string
	Source           string
	PeriodKey        string
	Metadata         []byte
}

// EntitlementCheckResult 权益检查结果。
type EntitlementCheckResult struct {
	Allowed      bool
	FeatureCode  string
	FeatureType  string
	GrantedValue *int64
	GrantedUnit  *string
	CurrentUsage *int64
	Reason       string
}

// UsageCounter 为 billing 展示路径提供各业务域的实时用量计数。
type UsageCounter func(ctx context.Context, tenantID int64) (int64, error)

// EntitlementChecker 是各业务 service 做配额前置检查的窄接口。
type EntitlementChecker interface {
	EnsureWithinLimit(ctx context.Context, tenantID int64, featureCode string, currentUsage, delta int64) error
	EnsureStorageWithinLimit(ctx context.Context, tenantID int64, featureCode string, usedBytes, needBytes int64) error
	EnsureFeatureEnabled(ctx context.Context, tenantID int64, featureCode string) error
}

// ConsumeResult 积分消耗结果。
type ConsumeResult struct {
	Success       bool
	Consumed      int64
	BalanceAfter  int64
	Overdrafted   int64
	Reason        string
	LedgerEntries []CreditLedgerEntry
}

// ============================================================================
// Phase 1B 筛选/输入类型
// ============================================================================

// SubscriptionFilter 订阅列表筛选。
type SubscriptionFilter struct {
	TenantID *int64
	Status   string
	Offset   int
	Limit    int
}

// PaymentOrderFilter 支付订单列表筛选。
type PaymentOrderFilter struct {
	TenantID  *int64
	Status    string
	OrderType string
	From      *time.Time
	To        *time.Time
	Offset    int
	Limit     int
}

// LedgerFilter 积分流水列表筛选。
type LedgerFilter struct {
	TenantID  *int64
	WalletID  *int64
	Direction string
	BizType   string
	From      *time.Time
	To        *time.Time
	Offset    int
	Limit     int
}

// OverrideFilter 权益覆写列表筛选。
type OverrideFilter struct {
	TenantID    *int64
	FeatureCode string
	Status      string
	Offset      int
	Limit       int
}

// OverrideStatusActive / Disabled.
const (
	OverrideStatusActive   = "active"
	OverrideStatusDisabled = "disabled"
)

// CreateOverrideInput 创建权益覆写。
type CreateOverrideInput struct {
	TenantID      int64
	FeatureCode   string
	OverrideValue *int64
	OverrideUnit  *string
	Reason        string
	EffectiveFrom *time.Time
	EffectiveTo   *time.Time
	OperatorID    int64
}

// UpdateOverrideInput 更新权益覆写。
type UpdateOverrideInput struct {
	OverrideValue *int64
	OverrideUnit  *string
	Reason        *string
	EffectiveFrom *time.Time
	EffectiveTo   *time.Time
	OperatorID    int64
}

// ChangePlanInput 套餐升降级输入。
type ChangePlanInput struct {
	TenantID         int64
	NewPlanID        int64
	AccountID        int64
	Provider         string
	PaymentTradeType string
	BillingCycle     string
}

// ChangePlanResult 套餐变更结果。
type ChangePlanResult struct {
	Action       string        `json:"action"`
	Order        *PaymentOrder `json:"order,omitempty"`
	EffectiveAt  *time.Time    `json:"effective_at,omitempty"`
	ProratedDays int           `json:"prorated_days,omitempty"`
}

// AdminAssignTenantPlanInput 平台管理员直接调整租户套餐。
type AdminAssignTenantPlanInput struct {
	TenantID   int64
	PlanID     int64
	OperatorID int64
}

// AdminAssignTenantPlanResult 返回调整后的有效订阅及审计所需的前值。
type AdminAssignTenantPlanResult struct {
	Subscription   *SubscriptionDetail
	PreviousPlanID int64
	Changed        bool
	Created        bool
}

// CreateSubscriptionInput 创建订阅。
type CreateSubscriptionInput struct {
	TenantID     int64
	PlanID       int64
	BillingCycle string
	CreatedBy    int64
}

// CancelSubscriptionInput 取消订阅。
type CancelSubscriptionInput struct {
	TenantID   int64
	Reason     string
	Immediate  bool
	OperatorID int64
}

// GrantCreditsInput 发放积分。
type GrantCreditsInput struct {
	Metadata       []byte
	TenantID       int64
	Source         string
	Amount         int64
	ExpiresAt      *time.Time
	ReferenceID    *int64
	ReferenceType  string
	Memo           string
	BizNo          string
	PaymentOrderID *int64
}

// ConsumeCreditsInput 消耗积分。
type ConsumeCreditsInput struct {
	TenantID  int64
	AccountID int64
	Amount    int64
	BizNo     string
	BizType   string
	Metadata  []byte
}

// CreatePaymentOrderInput 创建支付订单。
type CreatePaymentOrderInput struct {
	TenantID         int64
	AccountID        int64
	OrderType        string
	ProductID        *int64
	ProductSnapshot  []byte
	AmountCents      int64
	Currency         string
	Provider         string
	PaymentTradeType string
	ExpireMinutes    int
}

// CreateCaseFeeOrderInput 垂域工单服务费下单（F24 收款线上化，代账/注册通用）。
// 金额不在入参里：服务端按 baigong 工单 final_price 定价，客户端不可传。
type CreateCaseFeeOrderInput struct {
	TenantID         int64
	AccountID        int64
	CaseID           string // baigong 工单 case UUID（聊天 action_id 携带）
	Provider         string // wechat | mock（测试）
	PaymentTradeType string // app | native | ""
}

// RefundCaseFeeInput 工单服务费退款（F24 取消退款）。
type RefundCaseFeeInput struct {
	CaseID            string
	TenantUUID        string // 必须与订单快照一致（跨租户防护）
	RefundAmountCents int64  // <=0 = 退剩余全额
	Reason            string
	CreatedBy         int64
}

// MarkOrderPaidInput 标记订单已支付。
type MarkOrderPaidInput struct {
	OutTradeNo      string
	ProviderTradeNo string
	AmountCents     int64
	PaidAt          time.Time
}

// CreateRefundInput 创建退款。
type CreateRefundInput struct {
	PaymentOrderID    int64
	RefundAmountCents int64
	Reason            string
	CreatedBy         int64
}

// ProviderRefundResult 是支付渠道退款申请/查询后的标准化结果。
type ProviderRefundResult struct {
	ProviderRefundNo string
	Status           string // RefundStatusProcessing / Success / Failed
	RefundedAt       *time.Time
}

// CheckEntitlementInput 权益检查输入。
type CheckEntitlementInput struct {
	TenantID     int64
	FeatureCode  string
	CurrentUsage *int64
}

// UpdateBillingConfigInput 更新全局计费配置。
type UpdateBillingConfigInput struct {
	Value      string
	OperatorID int64
}

// ----------------------------------------------------------------------------
// Usage Billing 基础（000042）：统一计量+扣费 facade / AIGC LLM push / RTC 分钟 / 汇总
// ----------------------------------------------------------------------------

// RecordAndChargeUsageInput 是 L1 计量 + L2 扣费的统一入口。
//
// 语义：先写 usage_events（计量事实，幂等键=IdempotencyKey），CreditsCost>0 时再
// ConsumeCredits 扣租户钱包（biz_no=LedgerBizPrefix:IdempotencyKey，ledger metadata
// 携带 usage_event_id + usage_ref 双向追溯）。CreditsCost=0 时只留痕不扣费。
type RecordAndChargeUsageInput struct {
	TenantID         int64
	AccountID        int64
	AgentID          *int64
	AgentUUID        string
	ResourceType     string
	Amount           int64
	CreditsCost      int64
	IdempotencyKey   string // usage_ref：usage_events.idempotency_key
	LedgerBizPrefix  string // ledger biz_no 前缀，如 "llm" / "rtc" / "skill"
	BizType          string // credit_ledger.biz_type
	Status           string
	OccurredAt       *time.Time
	SourceScene      string
	SourceObjectType string
	SourceObjectID   string
	DisplayTitle     string
	Metadata         []byte
}

// UsageChargeResult 是 RecordAndChargeUsage 的结果。
type UsageChargeResult struct {
	UsageEvent          *UsageEvent
	Charged             bool
	CreditsCost         int64
	BalanceAfter        int64
	InsufficientBalance bool
	Reason              string
}

// ChargeRTCInput 是数字员工/用户语音视频通话按分钟扣费输入。
//
// 调用方（call 服务/DingRTC webhook）负责判定通话是否真正接通（active）并提供 active 时长；
// 未接通/拒接/取消/超时不应调用本方法。计费秒数取整为分钟：ceil(ActiveSeconds/60)。
type ChargeRTCInput struct {
	TenantID        int64
	AccountID       int64
	AgentID         *int64
	CallSessionID   int64
	CallSessionUUID string
	RoomID          int64
	CallKind        string // audio / video
	BillingScene    string // human_to_human / human_to_agent
	ActiveSeconds   int64
	StartedAt       *time.Time
	EndedAt         *time.Time
	EndReason       string
	ProviderRef     string
}

// UsageSummaryFilter 用于客户端「本月消耗」汇总。
type UsageSummaryFilter struct {
	TenantID  int64
	AccountID *int64
	From      *time.Time
	To        *time.Time
}

// UsageResourceSum 是按 resource_type 的消耗汇总。
type UsageResourceSum struct {
	UnknownAmountCount int64  `json:"unknown_amount_count"`
	ResourceType       string `json:"resource_type"`
	TotalCredits       int64  `json:"total_credits"`
	TotalAmount        int64  `json:"total_amount"`
	EventCount         int64  `json:"event_count"`
}

// UsageSummary 是客户端积分消耗概览（仅统计 credits_cost>0 的成功事件）。
type UsageSummary struct {
	From          *time.Time         `json:"from,omitempty"`
	To            *time.Time         `json:"to,omitempty"`
	TotalCredits  int64              `json:"total_credits"`
	TotalEvents   int64              `json:"total_events"`
	WalletBalance int64              `json:"wallet_balance"`
	ByResource    []UsageResourceSum `json:"by_resource"`
}

// UsageSceneSum 是按 source_scene 的消耗汇总。
type UsageSceneSum struct {
	SourceScene  string `json:"source_scene"`
	TotalCredits int64  `json:"total_credits"`
	EventCount   int64  `json:"event_count"`
}

// ReconcileResult 是一次扣费失败补偿批次的结果统计。
type ReconcileResult struct {
	Processed int64 // 本批扫描处理的条数
	Charged   int64 // 补扣成功
	Skipped   int64 // 缺字段需人工 / 无需处理
	Failed    int64 // 仍余额不足等可重试失败
}

// MonthlyStatement 是月度积分消耗对账单（预付费积分，非后付费 invoice）。
type MonthlyStatement struct {
	Month           string             `json:"month"` // YYYY-MM
	TenantID        int64              `json:"tenant_id"`
	OpeningBalance  *int64             `json:"opening_balance"`  // nullable：无快照时由 closing 反推，过往月份可能为空
	GrantedCredits  int64              `json:"granted_credits"`  // 本月充值/赠送/订阅发放（ledger credit 方向）
	ConsumedCredits int64              `json:"consumed_credits"` // 本月消耗（usage_events charged 合计）
	ClosingBalance  *int64             `json:"closing_balance"`  // nullable：仅当月可由钱包当前余额得出
	EventCount      int64              `json:"event_count"`
	ByResource      []UsageResourceSum `json:"by_resource"`
	ByScene         []UsageSceneSum    `json:"by_scene"`
}

// PaymentProvider 支付网关抽象。
type PaymentProvider interface {
	Name() string
	CreatePrepay(ctx context.Context, order *PaymentOrder, tradeType string) (prepayParams []byte, err error)
	QueryOrder(ctx context.Context, order *PaymentOrder) (providerTradeNo string, amountCents int64, paid bool, err error)
	Refund(ctx context.Context, order *PaymentOrder, refund *RefundOrder) (*ProviderRefundResult, error)
	QueryRefund(ctx context.Context, outRefundNo string) (*ProviderRefundResult, error)
	VerifyCallback(ctx context.Context, body []byte, headers map[string]string) (outTradeNo, providerTradeNo string, amountCents int64, eventID string, err error)
}
