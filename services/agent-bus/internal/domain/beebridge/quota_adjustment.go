package beebridge

import "context"

type QuotaAdjustment struct {
	ID           int64
	TenantID     int64
	GrantID      int64
	UserID       int64
	Quota        int64
	AttemptCount int
}

type QuotaAdjustmentStore interface {
	ClaimQuotaAdjustment(context.Context) (*QuotaAdjustment, error)
	CompleteQuotaAdjustment(context.Context, int64) error
	FailQuotaAdjustment(context.Context, int64, bool, string) error
}
