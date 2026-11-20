package a2aapproval

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	localrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/localruntime"
)

// Run against a disposable PostgreSQL database with the community migrations applied.
func TestRecoverLocalClaims(t *testing.T) {
	dsn := os.Getenv("AGBUS_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("set AGBUS_TEST_PG_DSN to a disposable migrated community database")
	}
	ctx, stop := context.WithTimeout(context.Background(), 20*time.Second)
	defer stop()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	repo, runtime := New(pool), localrepo.New(pool)
	exec := func(t *testing.T, sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	read := func(t *testing.T, dest any, sql string, args ...any) {
		t.Helper()
		if err := pool.QueryRow(ctx, sql, args...).Scan(dest); err != nil {
			t.Fatal(err)
		}
	}
	var scope domlocal.Scope
	var department, from, to int64
	var device, fromConversation, toConversation string
	read(t, &scope.AccountID, "INSERT INTO accounts(display_name) VALUES ('Local approval recovery') RETURNING id")
	label := "local-recovery-" + uuid.NewString()
	read(t, &scope.TenantID, "INSERT INTO tenants(name,slug,status) VALUES ($1,$1,'active') RETURNING id", label)
	read(t, &department, "INSERT INTO departments(tenant_id,path,name) VALUES ($1,'/','Test') RETURNING id", scope.TenantID)
	exec(t, "INSERT INTO tenant_memberships(tenant_id,account_id,department_id) VALUES ($1,$2,$3)", scope.TenantID, scope.AccountID, department)
	read(t, &scope.SessionUUID, `
		INSERT INTO login_sessions(account_id,act_tenant_id,act_scope_kind,device_type,refresh_token_hash,expires_at)
		VALUES ($1,$2,'tenant','macos',$3,now()+interval '1 hour') RETURNING uuid`, scope.AccountID, scope.TenantID, uuid.NewString())
	read(t, &device, `
		INSERT INTO local_runtime_devices(tenant_id,account_id,login_session_uuid,platform,generation,seen_at)
		VALUES ($1,$2,$3,'darwin',1,now()) RETURNING uuid`, scope.TenantID, scope.AccountID, scope.SessionUUID)
	for _, employee := range []struct {
		name string
		id   *int64
		conv *string
	}{{"Source", &from, &fromConversation}, {"Target", &to, &toConversation}} {
		read(t, employee.id, `
			INSERT INTO digital_employees(tenant_id,creator_id,name,source,visibility,status,execution_locus,local_engine,metadata)
			VALUES ($1,$2,$3,'enterprise','tenant','published','local','dsh',jsonb_build_object('agent_key',$4::text)) RETURNING id`,
			scope.TenantID, scope.AccountID, employee.name, uuid.NewString())
		read(t, employee.conv, `
			INSERT INTO conversations(tenant_id,account_id,digital_employee_id)
			VALUES ($1,$2,$3) RETURNING uuid`, scope.TenantID, scope.AccountID, *employee.id)
	}

	for _, tc := range []struct {
		name, targetStatus, wantStatus, wantError string
	}{
		{"claim lost before dispatch", "", "failed", "a2a.local_execution_interrupted"},
		{"target completed before finalization", "completed", "done", ""},
		{"target cancelled", "cancelled", "cancelled", "a2a.local_execution_cancelled"},
		{"target already failed", "failed", "failed", "a2a.local_execution_failed"},
		{"unfinished target reached its deadline", "accepted", "failed", "a2a.local_execution_interrupted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			sourceID, sourceMsg := uuid.NewString(), uuid.NewString()
			exec(t, `UPDATE local_runtime_devices SET seen_at=now() WHERE uuid=$1`, device)
			exec(t, `INSERT INTO local_runtime_tasks(uuid,device_uuid,tenant_id,account_id,login_session_uuid,digital_employee_id,
				conversation_uuid,message_uuid,stream_id,model,payload,token_hash,expires_at,status,settled_at)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'model','{}',repeat('a',64),now()+interval '15 minutes','completed',now())`,
				sourceID, device, scope.TenantID, scope.AccountID, scope.SessionUUID, from, fromConversation, sourceMsg, uuid.NewString())
			request, err := repo.RequestLocal(ctx, &domlocal.Task{
				UUID: sourceID, Scope: scope, EmployeeID: from, ConversationUUID: fromConversation, ExpiresAt: time.Now().Add(10 * time.Minute),
			}, to, "task text")
			if err != nil {
				t.Fatal(err)
			}
			if err := repo.ApproveLocal(ctx, scope.TenantID, request, scope.AccountID); err != nil {
				t.Fatal(err)
			}
			job, err := repo.ClaimLocal(ctx)
			if err != nil || job == nil || job.SourceRun != sourceID {
				t.Fatalf("unexpected claim %+v, %v", job, err)
			}
			target := &domlocal.Task{
				UUID: job.EdgeUUID, CollaborationEdgeUUID: job.EdgeUUID, DeviceUUID: device, Scope: scope, EmployeeID: to,
				ConversationUUID: toConversation, MessageUUID: uuid.NewString(), StreamID: uuid.NewString(),
				Model: "model", Payload: []byte("{}"), ExpiresAt: time.Now().Add(time.Minute),
			}
			if tc.targetStatus != "" {
				if _, err := runtime.CreateTask(ctx, target); err != nil {
					t.Fatalf("create target: %v", err)
				}
				if tc.targetStatus == "completed" {
					// Simulate an unsuccessful write of the terminal state. Clearing the job must roll back too.
					if err := repo.FinishLocal(ctx, job, "invalid_status_for_test", "", nil); err == nil {
						t.Fatal("expected terminal-write error")
					}
				}
			}
			exec(t, "UPDATE local_a2a_jobs SET started_at=now()-interval '8 minutes' WHERE approval_id=$1", job.ApprovalID)
			if tc.targetStatus == "accepted" {
				if err := repo.RecoverLocal(ctx); err != nil {
					t.Fatal(err)
				}
				var state string
				read(t, &state, "SELECT status FROM a2a_call_edges WHERE uuid=$1", job.EdgeUUID)
				if state != "running" {
					t.Fatalf("target can still complete, got %q", state)
				}
				exec(t, "UPDATE local_runtime_tasks SET status='accepted',expires_at=now()-interval '2 minutes' WHERE uuid=$1", target.UUID)
			} else if tc.targetStatus != "" {
				exec(t, "UPDATE local_runtime_tasks SET status=$2,settled_at=now() WHERE uuid=$1", target.UUID, tc.targetStatus)
			}

			if err := repo.RecoverLocal(ctx); err != nil {
				t.Fatal(err)
			}
			if err := repo.FinishLocal(ctx, job, "failed", "late_worker_write", nil); err != nil {
				t.Fatal(err)
			}
			var state, code, taskText, messageID string
			var finished bool
			err = pool.QueryRow(ctx, `SELECT e.status,coalesce(e.error_message,''),j.task_text,j.finished_at IS NOT NULL,
				coalesce(e.response_payload->>'target_message_uuid','') FROM a2a_call_edges e
				JOIN local_a2a_jobs j ON j.approval_id=$2 WHERE e.uuid=$1`, job.EdgeUUID, job.ApprovalID).
				Scan(&state, &code, &taskText, &finished, &messageID)
			if err != nil || state != tc.wantStatus || code != tc.wantError || taskText != "[cleared]" || !finished {
				t.Fatalf("unexpected recovery: state=%q code=%q cleared=%v finished=%v err=%v", state, code, taskText == "[cleared]", finished, err)
			}
			if state == "done" && messageID != target.MessageUUID {
				t.Fatalf("wrong target message: %q", messageID)
			}
			if next, err := repo.ClaimLocal(ctx); err != nil || next != nil {
				t.Fatalf("finished claim must not be retried: %+v, %v", next, err)
			}
			if tc.targetStatus == "" {
				if _, err := runtime.CreateTask(ctx, target); !errors.Is(err, domlocal.ErrDenied) {
					t.Fatalf("settled job must not start a target: %v", err)
				}
			}
		})
	}
}
