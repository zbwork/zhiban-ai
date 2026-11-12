package main

import (
	"context"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// agentSDKRuntimeChecker 是 adminhttp.AgentSDKRuntimeChecker 的最薄实现。
type agentSDKRuntimeChecker struct{ pool *pgxpool.Pool }

func (c *agentSDKRuntimeChecker) IsVisibleForTenant(ctx context.Context, runtimeID, tenantID int64) (bool, error) {
	var scope string
	var owner *int64
	var status string
	var enabled bool
	err := c.pool.QueryRow(ctx, `
		SELECT scope, tenant_id, status, enabled
		  FROM runtime_environments
		 WHERE id=$1 AND is_deleted=false`, runtimeID).Scan(&scope, &owner, &status, &enabled)
	if err != nil {
		if err == pgx.ErrNoRows {
			return false, nil
		}
		return false, err
	}
	if status != "active" || !enabled {
		return false, nil
	}
	if scope == "platform" {
		return true, nil
	}
	return owner != nil && *owner == tenantID, nil
}

func (c *agentSDKRuntimeChecker) IsPlatformCredentialTarget(ctx context.Context, runtimeID int64) (bool, error) {
	var scope, status string
	var enabled bool
	err := c.pool.QueryRow(ctx, `
		SELECT scope, status, enabled
		  FROM runtime_environments
		 WHERE id=$1 AND is_deleted=false`, runtimeID).Scan(&scope, &status, &enabled)
	if err != nil {
		if err == pgx.ErrNoRows {
			return false, nil
		}
		return false, err
	}
	return scope == "platform" && status == "active" && enabled, nil
}
