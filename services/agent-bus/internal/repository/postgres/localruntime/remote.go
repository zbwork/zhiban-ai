package localruntime

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

// Web sessions cannot remotely control a desktop. All callers must be a current member.
const requesterValid = `SELECT 1 FROM login_sessions u
 JOIN accounts ua ON ua.id=u.account_id JOIN tenants ut ON ut.id=u.act_tenant_id
 JOIN tenant_memberships um ON um.account_id=u.account_id AND um.tenant_id=u.act_tenant_id
 WHERE u.uuid=$3 AND u.account_id=$1 AND u.act_tenant_id=$2 AND u.revoked_at IS NULL AND u.expires_at>now()
 AND ua.status='active' AND ua.deleted_at IS NULL AND ut.status='active' AND um.status='active' AND um.deleted_at IS NULL
 AND lower(trim(u.device_type)) IN ('desktop','macos','macosx','darwin','windows','linux','mobile','ios','android')`

func (r *Repo) ValidateRequester(ctx context.Context, scope dom.Scope) error {
	var one int
	err := r.pool.QueryRow(ctx, requesterValid, scope.AccountID, scope.TenantID, scope.SessionUUID).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return dom.ErrDenied
	}
	return err
}

func (r *Repo) ConversationState(ctx context.Context, scope dom.Scope, conversation string) (map[string]string, error) {
	if err := r.ValidateRequester(ctx, scope); err != nil {
		return nil, err
	}
	var model, contextID string
	err := r.pool.QueryRow(ctx, `SELECT coalesce(q.model,''),coalesce(q.payload->>'local_context_id','')
 FROM conversations c JOIN digital_employees e ON e.id=c.digital_employee_id
 LEFT JOIN LATERAL (SELECT model,payload FROM local_runtime_tasks q WHERE q.conversation_uuid=c.uuid AND q.account_id=$1 AND q.tenant_id=$2 ORDER BY created_at DESC LIMIT 1)q ON true
 WHERE c.uuid=$3 AND c.account_id=$1 AND c.tenant_id=$2 AND c.deleted_at IS NULL
	 AND e.execution_locus='local' AND e.status='published' AND NOT e.is_deleted AND e.deleted_at IS NULL
	 AND ((e.source='personal' AND e.visibility='private' AND e.tenant_id=$2 AND e.creator_id=$1)
	   OR (e.source='enterprise' AND e.tenant_id=$2)
	   OR (e.source='platform' AND e.visibility='platform' AND e.tenant_id IS NULL))`, scope.AccountID, scope.TenantID, conversation).Scan(&model, &contextID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	if err != nil {
		return nil, err
	}
	return map[string]string{"model": model, "context_id": contextID}, nil
}

func (r *Repo) ResolveDesktop(ctx context.Context, caller dom.Scope, deviceID string) (*dom.Device, error) {
	if err := r.ValidateRequester(ctx, caller); err != nil {
		return nil, err
	}
	// Exact local device requests remain bound to the caller's desktop session. Remote routing
	// accepts only the current mobile session; it never trusts a client-provided desktop session.
	rows, err := r.pool.Query(ctx, `SELECT d.uuid,d.login_session_uuid,t.uuid,a.uuid,d.platform,d.generation,d.seen_at,d.protocol_version,d.engines
 FROM local_runtime_devices d `+principalJoin+` WHERE d.account_id=$1 AND d.tenant_id=$2 AND `+principalValid+`
 AND d.generation>0 AND d.seen_at>now()-interval '15 seconds'
 AND (($4<>'' AND d.uuid::text=$4 AND d.login_session_uuid=$3) OR ($4='' AND
 (d.login_session_uuid=$3 OR EXISTS(SELECT 1 FROM login_sessions u WHERE u.uuid=$3 AND lower(trim(u.device_type)) IN ('mobile','ios','android'))))) LIMIT 2`, caller.AccountID, caller.TenantID, caller.SessionUUID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out *dom.Device
	for rows.Next() {
		if out != nil {
			return nil, dom.ErrConflict
		}
		var engines []byte
		out = &dom.Device{Scope: dom.Scope{AccountID: caller.AccountID, TenantID: caller.TenantID}}
		if err = rows.Scan(&out.UUID, &out.Scope.SessionUUID, &out.TenantUUID, &out.AccountUUID, &out.Platform, &out.Generation, &out.SeenAt, &out.ProtocolVersion, &engines); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(engines, &out.Engines); err != nil {
			return nil, err
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, dom.ErrOffline
	}
	if out.ProtocolVersion < 2 {
		return out, dom.ErrUpgradeRequired
	}
	return out, nil
}

// Effective expiry keeps disconnected, cancelled, revoked and completed runs out of both UIs.
const approvalValid = `q.status='accepted' AND q.expires_at>now() AND p.expires_at>now() AND p.fence=q.fence
 AND EXISTS(SELECT 1 FROM local_runtime_devices d ` + principalJoin + ` WHERE d.uuid=q.device_uuid AND d.protocol_version>=2 AND d.seen_at>now()-interval '15 seconds' AND ` + principalValid + `)
	 AND EXISTS(SELECT 1 FROM digital_employees e WHERE e.id=q.digital_employee_id AND ` + taskEmployeeValid + `)
 AND (q.requester_session_uuid IS NULL OR EXISTS(SELECT 1 FROM login_sessions u WHERE u.uuid=q.requester_session_uuid AND u.account_id=q.account_id AND u.act_tenant_id=q.tenant_id AND u.revoked_at IS NULL AND u.expires_at>now()))`
const approvalCols = `p.uuid,p.run_uuid,q.conversation_uuid,p.fence,p.revision,p.intent_hash,p.display,
 CASE WHEN p.status='pending' AND NOT (` + approvalValid + `) THEN 'expired' ELSE p.status END,p.decision_scope,p.expires_at,(SELECT name FROM digital_employees WHERE id=q.digital_employee_id)`

func scanApproval(row pgx.Row) (*dom.Approval, error) {
	var out dom.Approval
	var display []byte
	err := row.Scan(&out.ID, &out.Run, &out.Conversation, &out.Fence, &out.Revision, &out.IntentHash, &display, &out.Status, &out.DecisionScope, &out.ExpiresAt, &out.EmployeeName)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	if err != nil {
		return nil, err
	}
	if err = json.Unmarshal(display, &out.Display); err != nil {
		return nil, err
	}
	return &out, nil
}
func (r *Repo) RegisterApproval(ctx context.Context, task *dom.Task, in dom.Approval) (*dom.Approval, error) {
	display, err := json.Marshal(in.Display)
	if err != nil {
		return nil, err
	}
	var id string
	err = r.pool.QueryRow(ctx, `INSERT INTO local_runtime_approvals(uuid,run_uuid,fence,revision,intent_hash,display,expires_at)
 SELECT $1,q.uuid,q.fence,$4,$5,$6,$7 FROM local_runtime_tasks q
 WHERE q.uuid=$2 AND q.fence=$3 AND q.status='accepted' AND q.expires_at>now() AND $7<=q.expires_at
 ON CONFLICT(uuid) DO UPDATE SET uuid=excluded.uuid WHERE local_runtime_approvals.run_uuid=excluded.run_uuid
 AND local_runtime_approvals.fence=excluded.fence AND local_runtime_approvals.revision=excluded.revision
 AND local_runtime_approvals.intent_hash=excluded.intent_hash AND local_runtime_approvals.display=excluded.display
 AND local_runtime_approvals.expires_at=excluded.expires_at RETURNING uuid`, in.ID, task.UUID, task.Fence, in.Revision, in.IntentHash, display, in.ExpiresAt).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrConflict
	}
	if err != nil {
		return nil, err
	}
	return r.GetApproval(ctx, task, id)
}
func (r *Repo) GetApproval(ctx context.Context, task *dom.Task, id string) (*dom.Approval, error) {
	return scanApproval(r.pool.QueryRow(ctx, `SELECT `+approvalCols+` FROM local_runtime_approvals p JOIN local_runtime_tasks q ON q.uuid=p.run_uuid WHERE p.uuid=$1 AND q.uuid=$2 AND q.fence=$3`, id, task.UUID, task.Fence))
}
func (r *Repo) ExpireApproval(ctx context.Context, task *dom.Task, id string) error {
	_, err := r.pool.Exec(ctx, `UPDATE local_runtime_approvals SET status='expired' WHERE uuid=$1 AND run_uuid=$2 AND fence=$3 AND status='pending'`, id, task.UUID, task.Fence)
	return err
}
func (r *Repo) ListApprovals(ctx context.Context, caller dom.Scope, conversation string) ([]dom.Approval, error) {
	if err := r.ValidateRequester(ctx, caller); err != nil {
		return nil, err
	}
	rows, err := r.pool.Query(ctx, `SELECT `+approvalCols+` FROM local_runtime_approvals p JOIN local_runtime_tasks q ON q.uuid=p.run_uuid
 WHERE q.account_id=$1 AND q.tenant_id=$2 AND ($3='' OR q.conversation_uuid::text=$3) AND p.status='pending' AND `+approvalValid+` ORDER BY p.created_at LIMIT 32`, caller.AccountID, caller.TenantID, conversation)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.Approval{}
	for rows.Next() {
		item, err := scanApproval(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *item)
	}
	return out, rows.Err()
}
func (r *Repo) DecideApproval(ctx context.Context, caller dom.Scope, id string, revision int, hash string, approved bool, grant string) (*dom.Approval, error) {
	if err := r.ValidateRequester(ctx, caller); err != nil {
		return nil, err
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// Row locking makes simultaneous contradictory decisions observe one winner.
	var run string
	err = tx.QueryRow(ctx, `SELECT p.run_uuid FROM local_runtime_approvals p JOIN local_runtime_tasks q ON q.uuid=p.run_uuid
 WHERE p.uuid=$1 AND q.account_id=$2 AND q.tenant_id=$3 AND p.revision=$4 AND p.intent_hash=$5 FOR UPDATE OF p`, id, caller.AccountID, caller.TenantID, revision, hash).Scan(&run)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	if err != nil {
		return nil, err
	}
	status := "rejected"
	if approved {
		status = "approved"
	}
	_, err = tx.Exec(ctx, `UPDATE local_runtime_approvals p SET status=$2,decision_scope=CASE WHEN p.display->>'operation'='upload' THEN 'once' ELSE $3 END,decided_by_session=$4,decided_at=now()
 FROM local_runtime_tasks q WHERE p.uuid=$1 AND q.uuid=p.run_uuid AND p.status='pending' AND `+approvalValid+` AND EXISTS(`+ // caller validation is rechecked inside the transaction
		`SELECT 1 FROM login_sessions u WHERE u.uuid=$4 AND u.account_id=q.account_id AND u.act_tenant_id=q.tenant_id AND u.revoked_at IS NULL AND u.expires_at>now())`, id, status, grant, caller.SessionUUID)
	if err != nil {
		return nil, err
	}
	out, err := scanApproval(tx.QueryRow(ctx, `SELECT `+approvalCols+` FROM local_runtime_approvals p JOIN local_runtime_tasks q ON q.uuid=p.run_uuid WHERE p.uuid=$1`, id))
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

func (r *Repo) SetProtocolVersion(ctx context.Context, scope dom.Scope, id string, version int) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_devices SET protocol_version=$5 WHERE uuid=$1 AND account_id=$2 AND tenant_id=$3 AND login_session_uuid=$4 AND revoked_at IS NULL`, id, scope.AccountID, scope.TenantID, scope.SessionUUID, version)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrDenied
	}
	return nil
}
