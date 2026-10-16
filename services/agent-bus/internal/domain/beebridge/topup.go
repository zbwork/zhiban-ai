package beebridge

import (
	"context"
	"time"
)

type GrantPlan struct {
	UserID int64
	Quota  int64
	Name   string
	Grant  Grant
}

type TopupOrder struct {
	ID, TenantID, UserID, Quota, RedemptionID int64
	State, PaymentState, Name                 string
	CodesCiphertext                           []byte
}

type Settlement struct {
	Quota       int64     `json:"quota"`
	UserID      int64     `json:"user_id"`
	ConfirmedAt time.Time `json:"confirmed_at"`
	Method      string    `json:"method"`
}

// Each write is committed before returning. Claim uses an atomic state/paid
// predicate; no network call may run while a payment row lock is held.
type TopupStore interface {
	CurrentPricing(context.Context) (TopupPricing, error)
	ReadyTenant(context.Context, int64) (TenantBinding, error)
	Order(context.Context, int64) (TopupOrder, error)
	Claim(context.Context, int64, string, string) (bool, error)
	SaveCodes(context.Context, int64, []byte, string) (bool, error)
	RegisterCode(context.Context, int64, int64) (bool, error)
	Review(context.Context, int64, string, string) error
	Complete(context.Context, int64, string, Settlement) (bool, error)
}
