package a2aapproval

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type LocalJob struct {
	ApprovalID, TenantID, AccountID, SourceAgentID, TargetAgentID int64
	EdgeUUID, SourceRun, Session, Device, Prompt                  string
	EdgeCreatedAt                                                 time.Time
}

func (r *Repo) RequestLocal(ctx context.Context, task *domlocal.Task, targetID int64, text string) (string, error) {
	var approvalUUID string
	err := pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		var edgeID int64
		var edgeUUID string
		var createdAt time.Time
		payload, _ := json.Marshal(map[string]any{"kind": "local_collaboration", "task_length": len([]rune(text))})
		err := tx.QueryRow(ctx, `
		    INSERT INTO a2a_call_edges(tenant_id,from_agent_id,to_agent_id,idem_key,invoke_kind,status,request_payload,origin_conversation_id)
		    VALUES($1,$2,$3,$4,'async','awaiting_approval',$5::jsonb,(SELECT id FROM conversations WHERE uuid=$6 AND tenant_id=$1))
		    RETURNING id,uuid,created_at
		`, task.Scope.TenantID, task.EmployeeID, targetID, "local:"+task.UUID, string(payload), task.ConversationUUID).Scan(&edgeID, &edgeUUID, &createdAt)
		if err != nil {
			return err
		}
		var approvalID int64
		err = tx.QueryRow(ctx, `
		    INSERT INTO a2a_approval_requests(tenant_id,edge_id,edge_uuid,edge_created_at,from_agent_id,to_agent_id,parent_account_id,invoke_kind,request_payload_redacted,expires_at)
		    VALUES($1,$2,$3,$4,$5,$6,$7,'async',$8::jsonb,least($9::timestamptz,now()+interval '10 minutes'))
		    RETURNING id,uuid
		`, task.Scope.TenantID, edgeID, edgeUUID, createdAt, task.EmployeeID, targetID, task.Scope.AccountID, string(payload), task.ExpiresAt).Scan(&approvalID, &approvalUUID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO local_a2a_jobs(approval_id,source_run_uuid,task_text) VALUES($1,$2,$3)`, approvalID, task.UUID, text)
		return err
	})
	return approvalUUID, err
}

func (r *Repo) ApproveLocal(ctx context.Context, tenantID int64, request string, actorID int64) error {
	return pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		var id int64
		err := tx.QueryRow(ctx, `
		    UPDATE a2a_approval_requests a SET status='approved',decided_by_account_id=$3,decided_at=now(),updated_at=now()
		    FROM local_a2a_jobs j JOIN local_runtime_tasks t ON t.uuid=j.source_run_uuid
		    JOIN local_runtime_devices d ON d.uuid=t.device_uuid AND d.account_id=t.account_id AND d.tenant_id=t.tenant_id AND d.login_session_uuid=t.login_session_uuid
		    JOIN login_sessions s ON s.uuid=t.login_session_uuid AND s.account_id=t.account_id AND s.act_tenant_id=t.tenant_id
		    WHERE a.id=j.approval_id AND a.tenant_id=$1 AND a.uuid=$2 AND a.status='pending' AND a.expires_at>now() AND NOT a.is_deleted
		      AND t.tenant_id=a.tenant_id AND t.account_id=a.parent_account_id AND t.status IN ('accepted','completed')
		      AND d.revoked_at IS NULL AND d.seen_at>now()-interval '15 seconds' AND s.revoked_at IS NULL AND s.expires_at>now()
		      AND EXISTS (SELECT 1 FROM a2a_call_edges e WHERE e.tenant_id=a.tenant_id AND e.uuid=a.edge_uuid AND e.created_at=a.edge_created_at AND e.status='awaiting_approval' AND NOT e.is_deleted)
		    RETURNING a.id
		`, tenantID, request, actorID).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			var status string
			var expired bool
			err = tx.QueryRow(ctx, `SELECT a.status, a.expires_at <= now() FROM a2a_approval_requests a
				JOIN local_a2a_jobs j ON j.approval_id=a.id WHERE a.tenant_id=$1 AND a.uuid=$2 AND NOT a.is_deleted`,
				tenantID, request).Scan(&status, &expired)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.ErrNotFound
			}
			if err != nil {
				return err
			}
			switch {
			case expired || status == "expired":
				return apperr.New(apperr.PreconditionFailed, "协作申请已过期，请从桌面重新发起")
			case status != "pending":
				return apperr.New(apperr.Conflict, "协作申请已处理")
			default:
				return apperr.New(apperr.PreconditionFailed, "发起电脑不在线或原任务已失效")
			}
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE local_a2a_jobs SET queued_at=now() WHERE approval_id=$1`, id)
		return err
	})
}

// SweepLocal expires pending requests and clears tasks that can no longer execute.
func (r *Repo) SweepLocal(ctx context.Context) error {
	_, err := r.pool.Exec(ctx, `
		WITH due AS (
			SELECT a.id FROM a2a_approval_requests a JOIN local_a2a_jobs j ON j.approval_id=a.id
			WHERE a.status='pending' AND a.expires_at<=now() AND NOT a.is_deleted
			ORDER BY a.expires_at LIMIT 100 FOR UPDATE OF a SKIP LOCKED
		), expired AS (
			UPDATE a2a_approval_requests a SET status='expired',decided_at=now(),updated_at=now()
			FROM due WHERE a.id=due.id RETURNING a.tenant_id,a.edge_uuid,a.edge_created_at
		), edges AS (
			UPDATE a2a_call_edges e SET status='expired',error_message='a2a.approval_expired',completed_at=now(),updated_at=now()
			FROM expired x WHERE e.tenant_id=x.tenant_id AND e.uuid=x.edge_uuid AND e.created_at=x.edge_created_at
			  AND e.status='awaiting_approval'
		)
		UPDATE local_a2a_jobs j SET finished_at=now(),task_text='[cleared]'
		FROM a2a_approval_requests a
		WHERE a.id=j.approval_id AND j.started_at IS NULL AND j.finished_at IS NULL
		  AND (a.status IN ('expired','rejected','cancelled') OR a.is_deleted)
	`)
	return err
}

// RecoverLocal settles abandoned claims from the durable target run. It never dispatches a job.
func (r *Repo) RecoverLocal(ctx context.Context) error {
	const grace = time.Minute
	_, err := r.pool.Exec(ctx, `
		WITH due AS (
			SELECT j.approval_id,a.tenant_id,a.edge_uuid,a.edge_created_at,t.status,t.message_uuid,t.conversation_uuid,
			       COALESCE(t.settled_at,now()) AS completed_at
			FROM local_a2a_jobs j JOIN a2a_approval_requests a ON a.id=j.approval_id
			LEFT JOIN local_runtime_tasks source ON source.uuid=j.source_run_uuid AND source.tenant_id=a.tenant_id AND source.account_id=a.parent_account_id
			LEFT JOIN local_runtime_tasks t ON t.uuid=a.edge_uuid AND t.tenant_id=a.tenant_id AND t.account_id=a.parent_account_id
			     AND t.digital_employee_id=a.to_agent_id AND t.device_uuid=source.device_uuid AND t.login_session_uuid=source.login_session_uuid
			WHERE j.started_at <= now()-make_interval(secs => $1) AND j.finished_at IS NULL
			  AND (t.uuid IS NULL OR t.status IN ('completed','failed','cancelled') OR t.expires_at <= now()-make_interval(secs => $2))
			ORDER BY j.started_at, j.approval_id LIMIT 100 FOR UPDATE OF j SKIP LOCKED
		), edges AS (
			UPDATE a2a_call_edges e SET
			    status=CASE d.status WHEN 'completed' THEN 'done' WHEN 'cancelled' THEN 'cancelled' ELSE 'failed' END,
			    error_message=CASE d.status WHEN 'completed' THEN NULL WHEN 'cancelled' THEN 'a2a.local_execution_cancelled'
			                    WHEN 'failed' THEN 'a2a.local_execution_failed' ELSE 'a2a.local_execution_interrupted' END,
			    response_payload=CASE WHEN d.status='completed' THEN jsonb_build_object(
			        'target_message_uuid',d.message_uuid,'target_conversation_uuid',d.conversation_uuid) ELSE '{}'::jsonb END,
			    completed_at=d.completed_at,updated_at=now()
			FROM due d WHERE e.tenant_id=d.tenant_id AND e.uuid=d.edge_uuid AND e.created_at=d.edge_created_at AND e.status='running'
		)
		UPDATE local_a2a_jobs j SET finished_at=now(),task_text='[cleared]' FROM due d WHERE j.approval_id=d.approval_id
	`, (domlocal.CollaborationObservationTimeout + grace).Seconds(), grace.Seconds())
	return err
}

func (r *Repo) ClaimLocal(ctx context.Context) (*LocalJob, error) {
	job := new(LocalJob)
	err := pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `
		    SELECT j.approval_id,a.tenant_id,a.parent_account_id,a.from_agent_id,a.to_agent_id,a.edge_uuid,a.edge_created_at,
		           j.source_run_uuid,COALESCE(t.login_session_uuid::text,''),COALESCE(t.device_uuid::text,''),j.task_text
		    FROM local_a2a_jobs j JOIN a2a_approval_requests a ON a.id=j.approval_id
		    LEFT JOIN local_runtime_tasks t ON t.uuid=j.source_run_uuid AND t.tenant_id=a.tenant_id AND t.account_id=a.parent_account_id
		    WHERE j.queued_at IS NOT NULL AND j.started_at IS NULL AND j.finished_at IS NULL AND a.status='approved' AND NOT a.is_deleted
		    ORDER BY j.queued_at, j.approval_id LIMIT 1 FOR UPDATE OF j SKIP LOCKED
		`).Scan(&job.ApprovalID, &job.TenantID, &job.AccountID, &job.SourceAgentID, &job.TargetAgentID, &job.EdgeUUID, &job.EdgeCreatedAt,
			&job.SourceRun, &job.Session, &job.Device, &job.Prompt); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE local_a2a_jobs SET started_at=now() WHERE approval_id=$1`, job.ApprovalID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE a2a_call_edges SET status='running',started_at=now(),updated_at=now()
		 WHERE tenant_id=$1 AND uuid=$2 AND created_at=$3 AND status='awaiting_approval'`, job.TenantID, job.EdgeUUID, job.EdgeCreatedAt)
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return job, nil
}

func (r *Repo) FinishLocal(ctx context.Context, job *LocalJob, status doma2a.Status, code string, result []byte) error {
	return pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		updated, err := tx.Exec(ctx, `UPDATE local_a2a_jobs SET finished_at=now(),task_text='[cleared]' WHERE approval_id=$1 AND finished_at IS NULL`, job.ApprovalID)
		if err != nil || updated.RowsAffected() == 0 {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE a2a_call_edges SET status=$4,error_message=NULLIF($5,''),response_payload=$6::jsonb,
		    completed_at=now(),updated_at=now() WHERE tenant_id=$1 AND uuid=$2 AND created_at=$3 AND status='running'`,
			job.TenantID, job.EdgeUUID, job.EdgeCreatedAt, string(status), code, jsonOrDefault(result, "{}"))
		return err
	})
}

func (r *Repo) LocalTargetByName(ctx context.Context, tenant int64, name string) (int64, error) {
	rows, err := r.pool.Query(ctx, `SELECT id FROM digital_employees WHERE tenant_id=$1 AND name=$2 AND execution_locus='local' AND
		status='published' AND NOT is_deleted AND deleted_at IS NULL ORDER BY id LIMIT 2`, tenant, name)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(ids) != 1 {
		return 0, apperr.New(apperr.InvalidParams, "请提供本租户唯一的本机数字员工名称")
	}
	return ids[0], nil
}

func (r *Repo) LocalJobStillValid(ctx context.Context, job *LocalJob) (bool, error) {
	var valid bool
	err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
		 SELECT 1 FROM local_a2a_jobs j JOIN a2a_approval_requests a ON a.id=j.approval_id
		 JOIN local_runtime_tasks t ON t.uuid=j.source_run_uuid AND t.tenant_id=a.tenant_id AND t.account_id=a.parent_account_id
		 WHERE j.approval_id=$1 AND a.tenant_id=$2 AND a.status='approved' AND a.expires_at>now() AND NOT a.is_deleted
		   AND t.login_session_uuid=$3 AND t.device_uuid=$4 AND t.status NOT IN ('failed','cancelled')
		)`, job.ApprovalID, job.TenantID, job.Session, job.Device).Scan(&valid)
	return valid, err
}
