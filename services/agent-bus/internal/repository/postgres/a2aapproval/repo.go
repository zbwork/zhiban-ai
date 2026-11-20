package a2aapproval

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2aapproval"
	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const cols = `id, uuid, tenant_id, edge_id, edge_uuid, edge_created_at,
	from_agent_id, to_agent_id, COALESCE(parent_session_token_id,0), COALESCE(parent_account_id,0), caller_capabilities,
	invoke_kind, request_payload, request_payload_redacted, form_schema, form_result,
	status, COALESCE(reason,''), expires_at, decided_by_account_id, decided_at, dispatched_at,
	created_at, updated_at, is_deleted, deleted_at`

const colsA = `a.id, a.uuid, a.tenant_id, a.edge_id, a.edge_uuid, a.edge_created_at,
	a.from_agent_id, a.to_agent_id, COALESCE(a.parent_session_token_id,0), COALESCE(a.parent_account_id,0), a.caller_capabilities,
	a.invoke_kind, a.request_payload, a.request_payload_redacted, a.form_schema, a.form_result,
	a.status, COALESCE(a.reason,''), a.expires_at, a.decided_by_account_id, a.decided_at, a.dispatched_at,
	a.created_at, a.updated_at, a.is_deleted, a.deleted_at`

func scan(row pgx.Row) (*dom.Request, error) {
	var r dom.Request
	var caps []byte
	var invokeKind, status string
	if err := row.Scan(
		&r.ID, &r.UUID, &r.TenantID, &r.EdgeID, &r.EdgeUUID, &r.EdgeCreatedAt,
		&r.FromAgentID, &r.ToAgentID, &r.ParentSessionTokenID, &r.ParentAccountID, &caps,
		&invokeKind, &r.RequestPayload, &r.RequestPayloadRedacted, &r.FormSchema, &r.FormResult,
		&status, &r.Reason, &r.ExpiresAt, &r.DecidedByAccountID, &r.DecidedAt, &r.DispatchedAt,
		&r.CreatedAt, &r.UpdatedAt, &r.IsDeleted, &r.DeletedAt,
	); err != nil {
		return nil, err
	}
	_ = json.Unmarshal(caps, &r.CallerCapabilities)
	r.InvokeKind = doma2a.InvokeKind(invokeKind)
	r.Status = dom.Status(status)
	return &r, nil
}

func jsonOrDefault(b []byte, def string) string {
	if len(b) == 0 {
		return def
	}
	return string(b)
}

func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.Request, error) {
	if in.TenantID <= 0 || in.EdgeID <= 0 || in.EdgeUUID == "" || in.EdgeCreatedAt.IsZero() ||
		in.FromAgentID <= 0 || in.ToAgentID <= 0 || in.ParentSessionTokenID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a_approval.Create: required fields missing")
	}
	caps, _ := json.Marshal(in.CallerCapabilities)
	row := r.pool.QueryRow(ctx, `
		INSERT INTO a2a_approval_requests (
			tenant_id, edge_id, edge_uuid, edge_created_at,
			from_agent_id, to_agent_id, parent_session_token_id, parent_account_id, caller_capabilities,
			invoke_kind, request_payload, request_payload_redacted, form_schema, expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,NULLIF($8,0),$9::jsonb,$10,$11::jsonb,$12::jsonb,$13::jsonb,$14)
		ON CONFLICT (tenant_id, edge_uuid, edge_created_at) DO UPDATE
		   SET updated_at = now()
		RETURNING `+cols,
		in.TenantID, in.EdgeID, in.EdgeUUID, in.EdgeCreatedAt,
		in.FromAgentID, in.ToAgentID, in.ParentSessionTokenID, in.ParentAccountID, string(caps),
		string(in.InvokeKind), jsonOrDefault(in.RequestPayload, "{}"),
		jsonOrDefault(in.RequestPayloadRedacted, "{}"), jsonOrDefault(in.FormSchema, "{}"),
		in.ExpiresAt,
	)
	return scan(row)
}

func (r *Repo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Request, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+cols+` FROM a2a_approval_requests
		WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false`,
		tenantID, uuid,
	)
	req, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return req, err
}

func (r *Repo) DecidePending(ctx context.Context, in dom.DecisionInput) (*dom.Request, error) {
	if in.TenantID <= 0 || in.ApprovalUUID == "" || in.ActorAccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a_approval.DecidePending: required fields missing")
	}
	if in.Decision != dom.StatusApproved && in.Decision != dom.StatusRejected {
		return nil, apperr.ErrInvalidParams.Withf("a2a_approval.DecidePending: decision must be approved|rejected")
	}
	when := in.DecidedAt
	if when.IsZero() {
		when = time.Now()
	}
	args := []any{
		in.TenantID, in.ApprovalUUID, string(in.Decision),
		jsonOrDefault(in.FormResult, "{}"), in.Reason,
		in.ActorAccountID, when,
	}
	setDispatch := ""
	clearRaw := ""
	if in.Decision != dom.StatusApproved || in.ClearRawPayload {
		clearRaw = ", request_payload='{}'::jsonb"
	}
	if in.MarkDispatchedAt != nil {
		args = append(args, *in.MarkDispatchedAt)
		setDispatch = fmt.Sprintf(", dispatched_at=$%d", len(args))
	}
	scopeWhere := ""
	if in.ParentAccountID > 0 {
		args = append(args, in.ParentAccountID)
		scopeWhere = fmt.Sprintf(" AND parent_account_id=$%d", len(args))
	}
	decisionSQL := `
		UPDATE a2a_approval_requests
		   SET status=$3,
		       form_result=$4::jsonb,
		       reason=NULLIF($5,''),
		       decided_by_account_id=$6,
		       decided_at=$7,
		       updated_at=now()
		       ` + clearRaw + `
		       ` + setDispatch + `
		 WHERE tenant_id=$1 AND uuid=$2 AND status='pending' AND is_deleted=false` + scopeWhere + `
		 RETURNING ` + cols
	var request *dom.Request
	err := pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		decided, err := scan(tx.QueryRow(ctx, decisionSQL, args...))
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrConflict.Withf("a2a approval is not pending")
		}
		if err != nil {
			return err
		}
		if in.Decision == dom.StatusRejected {
			tag, err := tx.Exec(ctx, `
				UPDATE a2a_call_edges
				SET status='rejected', error_message='a2a.approval_rejected', completed_at=$4, updated_at=now()
				WHERE tenant_id=$1 AND uuid=$2 AND created_at=$3
				  AND status='awaiting_approval' AND NOT is_deleted`,
				in.TenantID, decided.EdgeUUID, decided.EdgeCreatedAt, when)
			if err != nil {
				return err
			}
			if tag.RowsAffected() != 1 {
				return apperr.New(apperr.PreconditionFailed, "对应的协作调用已不在待审批状态")
			}
		}
		request = decided
		return nil
	})
	if err != nil {
		return nil, err
	}
	return request, nil
}

func (r *Repo) MarkDispatchedAndClear(ctx context.Context, tenantID int64, approvalUUID string, dispatchedAt time.Time) error {
	if dispatchedAt.IsZero() {
		dispatchedAt = time.Now()
	}
	tag, err := r.pool.Exec(ctx, `
		UPDATE a2a_approval_requests
		   SET dispatched_at=$3,
		       request_payload='{}'::jsonb,
		       updated_at=now()
		 WHERE tenant_id=$1 AND uuid=$2 AND status='approved' AND is_deleted=false`,
		tenantID, approvalUUID, dispatchedAt,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *Repo) CancelPendingByEdge(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, now time.Time) error {
	if now.IsZero() {
		now = time.Now()
	}
	_, err := r.pool.Exec(ctx, `
		UPDATE a2a_approval_requests
		   SET status='cancelled',
		       request_payload='{}'::jsonb,
		       decided_at=$4,
		       updated_at=now()
		 WHERE tenant_id=$1 AND edge_uuid=$2 AND edge_created_at=$3
		   AND status='pending' AND is_deleted=false`,
		tenantID, edgeUUID, edgeCreatedAt, now,
	)
	return err
}

func (r *Repo) ExpirePending(ctx context.Context, now time.Time, limit int) ([]*dom.Request, error) {
	if now.IsZero() {
		now = time.Now()
	}
	if limit <= 0 {
		limit = 500
	}
	if limit > 1000 {
		limit = 1000
	}
	rows, err := r.pool.Query(ctx, `
WITH due AS (
	SELECT id
	  FROM a2a_approval_requests
	 WHERE status='pending'
	   AND expires_at IS NOT NULL
	   AND expires_at <= $1
	   AND is_deleted=false
	 ORDER BY expires_at ASC, id ASC
	 LIMIT $2
	 FOR UPDATE SKIP LOCKED
)
UPDATE a2a_approval_requests a
   SET status='expired',
       request_payload='{}'::jsonb,
       decided_at=$1,
       updated_at=now()
  FROM due
 WHERE a.id=due.id
 RETURNING `+colsA,
		now, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*dom.Request{}
	for rows.Next() {
		req, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, req)
	}
	return out, rows.Err()
}

func (r *Repo) List(ctx context.Context, f dom.ListFilter) ([]*dom.Request, int, error) {
	if f.TenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("a2a_approval.List: tenant_id required")
	}
	limit, offset := f.Limit, f.Offset
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	args := []any{f.TenantID}
	where := "tenant_id=$1 AND is_deleted=false"
	if f.ParentAccountID > 0 {
		args = append(args, f.ParentAccountID)
		where += fmt.Sprintf(" AND parent_account_id=$%d", len(args))
	}
	if f.Status != "" {
		args = append(args, string(f.Status))
		where += fmt.Sprintf(" AND status=$%d", len(args))
	}
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx, `
		SELECT `+cols+`, count(*) OVER()
		  FROM a2a_approval_requests
		 WHERE `+where+`
		 ORDER BY created_at DESC
		 LIMIT $`+fmt.Sprint(len(args)-1)+` OFFSET $`+fmt.Sprint(len(args)),
		args...,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []*dom.Request{}
	total := 0
	for rows.Next() {
		var req dom.Request
		var caps []byte
		var invokeKind, status string
		if err := rows.Scan(
			&req.ID, &req.UUID, &req.TenantID, &req.EdgeID, &req.EdgeUUID, &req.EdgeCreatedAt,
			&req.FromAgentID, &req.ToAgentID, &req.ParentSessionTokenID, &req.ParentAccountID, &caps,
			&invokeKind, &req.RequestPayload, &req.RequestPayloadRedacted, &req.FormSchema, &req.FormResult,
			&status, &req.Reason, &req.ExpiresAt, &req.DecidedByAccountID, &req.DecidedAt, &req.DispatchedAt,
			&req.CreatedAt, &req.UpdatedAt, &req.IsDeleted, &req.DeletedAt, &total,
		); err != nil {
			return nil, 0, err
		}
		_ = json.Unmarshal(caps, &req.CallerCapabilities)
		req.InvokeKind = doma2a.InvokeKind(invokeKind)
		req.Status = dom.Status(status)
		out = append(out, &req)
	}
	return out, total, rows.Err()
}
