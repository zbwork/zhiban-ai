// Package orchestration postgres 实现 (F09 Phase B §2.3.10).
//
// agent_orchestrations + agent_orchestration_steps 是 1:N 聚合, 共用一个 Repo;
// orchestrations 是普通表 (PK=id), steps 是普通表 (PK=id).
//
// soft FK: steps.call_edge_id → a2a_call_edges 分区表受限, 仅 DB BIGINT, 不强制.
package orchestration

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orchestration"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const orchCols = `id, uuid, tenant_id, room_id, trigger_msg_id, master_agent_id,
    depth_limit, token_budget, time_budget_ms,
    status, COALESCE(plan_summary,''), COALESCE(final_summary,''),
    started_at, completed_at, COALESCE(error_message,''),
    tokens_in_total, tokens_out_total, edges_count, max_depth_reached,
    created_at, created_by, updated_at, updated_by, is_deleted, deleted_at`

const stepCols = `id, uuid, orchestration_id, call_edge_id, step_index,
    role, worker_agent_id, COALESCE(input_summary,''), COALESCE(output_summary,''),
    status, COALESCE(error_message,''), tokens_in, tokens_out,
    started_at, completed_at,
    created_at, created_by, updated_at, updated_by, is_deleted, deleted_at`

func scanOrch(row pgx.Row) (*dom.Orchestration, error) {
	var o dom.Orchestration
	var status string
	if err := row.Scan(
		&o.ID, &o.UUID, &o.TenantID, &o.RoomID, &o.TriggerMsgID, &o.MasterAgentID,
		&o.DepthLimit, &o.TokenBudget, &o.TimeBudgetMs,
		&status, &o.PlanSummary, &o.FinalSummary,
		&o.StartedAt, &o.CompletedAt, &o.ErrorMessage,
		&o.TokensInTotal, &o.TokensOutTotal, &o.EdgesCount, &o.MaxDepthReached,
		&o.CreatedAt, &o.CreatedBy, &o.UpdatedAt, &o.UpdatedBy, &o.IsDeleted, &o.DeletedAt,
	); err != nil {
		return nil, err
	}
	o.Status = dom.Status(status)
	return &o, nil
}

func scanStep(row pgx.Row) (*dom.Step, error) {
	var s dom.Step
	var role, status string
	if err := row.Scan(
		&s.ID, &s.UUID, &s.OrchestrationID, &s.CallEdgeID, &s.StepIndex,
		&role, &s.WorkerAgentID, &s.InputSummary, &s.OutputSummary,
		&status, &s.ErrorMessage, &s.TokensIn, &s.TokensOut,
		&s.StartedAt, &s.CompletedAt,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	); err != nil {
		return nil, err
	}
	s.Role = dom.StepRole(role)
	s.Status = dom.StepStatus(status)
	return &s, nil
}

// ---------- Orchestrations ----------

func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.Orchestration, error) {
	if in.TenantID == 0 || in.MasterAgentID == 0 {
		return nil, apperr.ErrInvalidParams.Withf("orchestration.Create: tenant_id/master_agent_id required")
	}
	depth := in.DepthLimit
	if depth <= 0 {
		depth = 3
	}
	tokens := in.TokenBudget
	if tokens <= 0 {
		tokens = 16000
	}
	timeMs := in.TimeBudgetMs
	if timeMs <= 0 {
		timeMs = 60000
	}
	row := r.pool.QueryRow(ctx, `
		INSERT INTO agent_orchestrations (
			tenant_id, room_id, trigger_msg_id, master_agent_id,
			depth_limit, token_budget, time_budget_ms,
			created_by, updated_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
		RETURNING `+orchCols,
		in.TenantID, in.RoomID, in.TriggerMsgID, in.MasterAgentID,
		depth, tokens, timeMs, in.CreatedBy,
	)
	return scanOrch(row)
}

func (r *Repo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Orchestration, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+orchCols+` FROM agent_orchestrations
		WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false`,
		tenantID, uuid,
	)
	o, err := scanOrch(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return o, err
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Orchestration, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+orchCols+` FROM agent_orchestrations
		WHERE id=$1 AND is_deleted=false`,
		id,
	)
	o, err := scanOrch(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return o, err
}

func (r *Repo) UpdateStatus(ctx context.Context, tenantID int64, uuid string, in dom.UpdateStatusInput) (*dom.Orchestration, error) {
	setClauses := []string{}
	args := []any{tenantID, uuid}
	idx := 2
	add := func(clause string, val any) {
		idx++
		setClauses = append(setClauses, fmt.Sprintf(clause, idx))
		args = append(args, val)
	}
	if in.Status != nil {
		add("status=$%d", string(*in.Status))
	}
	if in.PlanSummary != nil {
		add("plan_summary=NULLIF($%d,'')", *in.PlanSummary)
	}
	if in.FinalSummary != nil {
		add("final_summary=NULLIF($%d,'')", *in.FinalSummary)
	}
	if in.ErrorMessage != nil {
		add("error_message=NULLIF($%d,'')", *in.ErrorMessage)
	}
	if in.StartedAt != nil {
		add("started_at=$%d", *in.StartedAt)
	}
	if in.CompletedAt != nil {
		add("completed_at=$%d", *in.CompletedAt)
	}
	if in.TokensInTotal != nil {
		add("tokens_in_total=$%d", *in.TokensInTotal)
	}
	if in.TokensOutTotal != nil {
		add("tokens_out_total=$%d", *in.TokensOutTotal)
	}
	if in.EdgesCount != nil {
		add("edges_count=$%d", *in.EdgesCount)
	}
	if in.MaxDepthReached != nil {
		add("max_depth_reached=$%d", *in.MaxDepthReached)
	}
	if in.UpdatedBy != nil {
		add("updated_by=$%d", *in.UpdatedBy)
	}
	setClauses = append(setClauses, "updated_at=now()")
	if len(setClauses) == 1 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}

	set := setClauses[0]
	for i := 1; i < len(setClauses); i++ {
		set += ", " + setClauses[i]
	}

	row := r.pool.QueryRow(ctx, `
		UPDATE agent_orchestrations
		SET `+set+`
		WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false
		RETURNING `+orchCols,
		args...,
	)
	o, err := scanOrch(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return o, err
}

func (r *Repo) ListByTenant(ctx context.Context, tenantID int64, limit, offset int) ([]*dom.Orchestration, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	var total int
	if err := r.pool.QueryRow(ctx, `
		SELECT count(*) FROM agent_orchestrations
		WHERE tenant_id=$1 AND is_deleted=false`,
		tenantID,
	).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := r.pool.Query(ctx, `
		SELECT `+orchCols+` FROM agent_orchestrations
		WHERE tenant_id=$1 AND is_deleted=false
		ORDER BY created_at DESC
		LIMIT $2 OFFSET $3`,
		tenantID, limit, offset,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []*dom.Orchestration
	for rows.Next() {
		o, err := scanOrch(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return out, total, nil
}

// ---------- Steps ----------

func (r *Repo) CreateStep(ctx context.Context, in dom.CreateStepInput) (*dom.Step, error) {
	if in.OrchestrationID == 0 || in.Role == "" {
		return nil, apperr.ErrInvalidParams.Withf("CreateStep: orchestration_id/role required")
	}
	row := r.pool.QueryRow(ctx, `
		INSERT INTO agent_orchestration_steps (
			orchestration_id, call_edge_id, step_index, role,
			worker_agent_id, input_summary, created_by, updated_by)
		VALUES ($1, $2, $3, $4, $5, NULLIF($6,''), $7, $7)
		RETURNING `+stepCols,
		in.OrchestrationID, in.CallEdgeID, in.StepIndex, string(in.Role),
		in.WorkerAgentID, in.InputSummary, in.CreatedBy,
	)
	return scanStep(row)
}

func (r *Repo) UpdateStep(ctx context.Context, stepUUID string, in dom.UpdateStepInput) (*dom.Step, error) {
	setClauses := []string{}
	args := []any{stepUUID}
	idx := 1
	add := func(clause string, val any) {
		idx++
		setClauses = append(setClauses, fmt.Sprintf(clause, idx))
		args = append(args, val)
	}
	if in.CallEdgeID != nil {
		add("call_edge_id=$%d", *in.CallEdgeID)
	}
	if in.OutputSummary != nil {
		add("output_summary=NULLIF($%d,'')", *in.OutputSummary)
	}
	if in.Status != nil {
		add("status=$%d", string(*in.Status))
	}
	if in.ErrorMessage != nil {
		add("error_message=NULLIF($%d,'')", *in.ErrorMessage)
	}
	if in.TokensIn != nil {
		add("tokens_in=$%d", *in.TokensIn)
	}
	if in.TokensOut != nil {
		add("tokens_out=$%d", *in.TokensOut)
	}
	if in.StartedAt != nil {
		add("started_at=$%d", *in.StartedAt)
	}
	if in.CompletedAt != nil {
		add("completed_at=$%d", *in.CompletedAt)
	}
	if in.UpdatedBy != nil {
		add("updated_by=$%d", *in.UpdatedBy)
	}
	setClauses = append(setClauses, "updated_at=now()")
	if len(setClauses) == 1 {
		row := r.pool.QueryRow(ctx, `
			SELECT `+stepCols+` FROM agent_orchestration_steps
			WHERE uuid=$1 AND is_deleted=false`,
			stepUUID,
		)
		s, err := scanStep(row)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return s, err
	}

	set := setClauses[0]
	for i := 1; i < len(setClauses); i++ {
		set += ", " + setClauses[i]
	}
	row := r.pool.QueryRow(ctx, `
		UPDATE agent_orchestration_steps
		SET `+set+`
		WHERE uuid=$1 AND is_deleted=false
		RETURNING `+stepCols,
		args...,
	)
	s, err := scanStep(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return s, err
}

func (r *Repo) ListSteps(ctx context.Context, orchestrationID int64) ([]*dom.Step, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT `+stepCols+` FROM agent_orchestration_steps
		WHERE orchestration_id=$1 AND is_deleted=false
		ORDER BY step_index ASC, id ASC`,
		orchestrationID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*dom.Step
	for rows.Next() {
		s, err := scanStep(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// 静态接口断言.
var _ dom.Repository = (*Repo)(nil)
