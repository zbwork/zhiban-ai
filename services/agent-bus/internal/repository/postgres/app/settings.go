package app

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// =====================================================
// TenantAppSettingRepo
// =====================================================

type TenantAppSettingRepo struct{ pool *pgxpool.Pool }

func NewTenantAppSettingRepo(pool *pgxpool.Pool) *TenantAppSettingRepo {
	return &TenantAppSettingRepo{pool: pool}
}

const tasCols = `id, tenant_id, app_id, is_universal, is_enabled, sort_order, created_at, updated_at`

func scanTAS(row pgx.Row) (*dom.TenantAppSetting, error) {
	var x dom.TenantAppSetting
	if err := row.Scan(&x.ID, &x.TenantID, &x.AppID, &x.IsUniversal, &x.IsEnabled,
		&x.SortOrder, &x.CreatedAt, &x.UpdatedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *TenantAppSettingRepo) Upsert(ctx context.Context, s *dom.TenantAppSetting) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO tenant_app_settings (tenant_id, app_id, is_universal, is_enabled, sort_order)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (tenant_id, app_id) DO UPDATE
		SET is_universal = EXCLUDED.is_universal,
		    is_enabled   = EXCLUDED.is_enabled,
		    sort_order   = EXCLUDED.sort_order,
		    updated_at   = now()
		RETURNING `+tasCols,
		s.TenantID, s.AppID, s.IsUniversal, s.IsEnabled, s.SortOrder)
	got, err := scanTAS(row)
	if err != nil {
		return err
	}
	*s = *got
	return nil
}

func (r *TenantAppSettingRepo) GetByTenantApp(ctx context.Context, tenantID, appID int64) (*dom.TenantAppSetting, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+tasCols+` FROM tenant_app_settings WHERE tenant_id=$1 AND app_id=$2`,
		tenantID, appID)
	x, err := scanTAS(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *TenantAppSettingRepo) ListUniversalByTenant(ctx context.Context, tenantID int64) ([]dom.TenantAppSetting, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+tasCols+` FROM tenant_app_settings
		 WHERE tenant_id=$1 AND is_universal=true AND is_enabled=true
		 ORDER BY sort_order, app_id`,
		tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.TenantAppSetting
	for rows.Next() {
		x, err := scanTAS(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

// =====================================================
// AgentAppBindingRepo
// =====================================================

type AgentAppBindingRepo struct{ pool *pgxpool.Pool }

func NewAgentAppBindingRepo(pool *pgxpool.Pool) *AgentAppBindingRepo {
	return &AgentAppBindingRepo{pool: pool}
}

const aabCols = `id, agent_id, app_id, sort_order, created_at, updated_at`

func scanAAB(row pgx.Row) (*dom.AgentAppBinding, error) {
	var x dom.AgentAppBinding
	if err := row.Scan(&x.ID, &x.AgentID, &x.AppID, &x.SortOrder, &x.CreatedAt, &x.UpdatedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *AgentAppBindingRepo) ListByAgent(ctx context.Context, agentID int64) ([]dom.AgentAppBinding, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+aabCols+` FROM agent_app_bindings WHERE agent_id=$1 ORDER BY sort_order, id`,
		agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.AgentAppBinding
	for rows.Next() {
		x, err := scanAAB(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

// ListByAgents 批量版 ListByAgent；排序 agent_id, sort_order, id（单 agent 内序与逐条版一致）。
func (r *AgentAppBindingRepo) ListByAgents(ctx context.Context, agentIDs []int64) ([]dom.AgentAppBinding, error) {
	if len(agentIDs) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+aabCols+` FROM agent_app_bindings WHERE agent_id = ANY($1) ORDER BY agent_id, sort_order, id`,
		agentIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.AgentAppBinding
	for rows.Next() {
		x, err := scanAAB(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

func (r *AgentAppBindingRepo) ListAppIDsByAgent(ctx context.Context, agentID int64) ([]int64, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT app_id FROM agent_app_bindings WHERE agent_id=$1 ORDER BY sort_order, id`,
		agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// ReplaceForAgent 一次性把 agent 的绑定列表替换为 appIDs (按顺序记 sort_order=index)。
// 走事务: 先全删, 再批 insert。
func (r *AgentAppBindingRepo) ReplaceForAgent(ctx context.Context, agentID int64, appIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	if _, err := tx.Exec(ctx, `DELETE FROM agent_app_bindings WHERE agent_id=$1`, agentID); err != nil {
		return err
	}
	for i, appID := range appIDs {
		if _, err := tx.Exec(ctx,
			`INSERT INTO agent_app_bindings (agent_id, app_id, sort_order) VALUES ($1, $2, $3)`,
			agentID, appID, i); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
