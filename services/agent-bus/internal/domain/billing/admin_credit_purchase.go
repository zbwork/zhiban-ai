package billing

import "context"

const AdminCreditPurchaseSource = "admin_credit_purchase"
const MaxAdminCreditPurchaseCents int64 = 100_000_000

type CreditPurchasePricing struct {
	ID            int64 `json:"pricing_id"`
	CreditsPerCNY int64 `json:"credits_per_cny"`
}

type AdminCreditPurchaseOptions struct {
	CreditPurchasePricing
	MinAmountCents   int64 `json:"min_amount_cents"`
	MaxAmountCents   int64 `json:"max_amount_cents"`
	AvailableCredits int64 `json:"available_credits"`
}

type AdminCreditPurchaseInput struct {
	TenantID    int64  `json:"-"`
	OperatorID  int64  `json:"-"`
	RequestID   string `json:"request_id"`
	AmountCents int64  `json:"amount_cents"`
	PricingID   int64  `json:"pricing_id"`
	Remark      string `json:"remark"`
}

type AdminCreditPurchaseResult struct {
	OrderID         int64  `json:"order_id"`
	OutTradeNo      string `json:"out_trade_no"`
	AmountCents     int64  `json:"amount_cents"`
	Credits         int64  `json:"credits"`
	Fulfilled       bool   `json:"fulfilled"`
	BeeBridgeStatus string `json:"beebridge_status"`
}

type AdminCreditPurchaseService interface {
	AdminCreditPurchaseOptions(context.Context, int64) (*AdminCreditPurchaseOptions, error)
	AdminPurchaseCredits(context.Context, AdminCreditPurchaseInput) (*AdminCreditPurchaseResult, error)
	GetAdminCreditPurchase(context.Context, int64, int64, string) (*AdminCreditPurchaseResult, error)
}
