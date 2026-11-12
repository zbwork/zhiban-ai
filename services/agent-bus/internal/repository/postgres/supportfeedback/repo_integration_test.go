//go:build integration

package supportfeedback_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/supportfeedback"
)

func setupPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("AGBUS_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("AGBUS_POSTGRES_DSN not set")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	return pool
}

func TestSupportFeedbackAssignee_UpdateAndClear(t *testing.T) {
	pool := setupPool(t)
	ctx := context.Background()
	r := repo.New(pool)

	tenantID := firstTenantID(t, ctx, pool)
	assigneeID := firstPlatformAssigneeID(t, ctx, pool)

	item, err := r.Create(ctx, dom.CreateInput{
		TenantID:    tenantID,
		AccountID:   &assigneeID,
		Source:      dom.SourceAgentChat,
		Category:    dom.CategoryBug,
		Priority:    dom.PriorityNormal,
		Status:      dom.StatusOpen,
		Title:       "integration support feedback assignee",
		Description: "integration test feedback created by repo_integration_test",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM support_feedback WHERE uuid=$1`, item.UUID)
	})

	updated, err := r.UpdatePlatform(ctx, item.UUID, assigneeID, dom.UpdateInput{
		Status:        dom.StatusInProgress,
		AssignedTo:    &assigneeID,
		AssignedToSet: true,
	})
	if err != nil {
		t.Fatalf("UpdatePlatform assign: %v", err)
	}
	if updated.Status != dom.StatusInProgress {
		t.Fatalf("status got %q, want %q", updated.Status, dom.StatusInProgress)
	}
	if updated.AssignedTo == nil || *updated.AssignedTo != assigneeID {
		t.Fatalf("assigned_to got %v, want %d", updated.AssignedTo, assigneeID)
	}
	if updated.AssignedAt == nil {
		t.Fatalf("assigned_at should be set")
	}
	if updated.HandledBy == nil || *updated.HandledBy != assigneeID {
		t.Fatalf("handled_by got %v, want %d", updated.HandledBy, assigneeID)
	}

	cleared, err := r.UpdatePlatform(ctx, item.UUID, assigneeID, dom.UpdateInput{
		Status:        dom.StatusResolved,
		AssignedToSet: true,
	})
	if err != nil {
		t.Fatalf("UpdatePlatform clear: %v", err)
	}
	if cleared.Status != dom.StatusResolved {
		t.Fatalf("status got %q, want %q", cleared.Status, dom.StatusResolved)
	}
	if cleared.AssignedTo != nil {
		t.Fatalf("assigned_to got %v, want nil after clear", cleared.AssignedTo)
	}
}

func firstTenantID(t *testing.T, ctx context.Context, pool *pgxpool.Pool) int64 {
	t.Helper()
	var id int64
	err := pool.QueryRow(ctx, `
SELECT id
  FROM tenants
 WHERE deleted_at IS NULL
 ORDER BY id
 LIMIT 1`).Scan(&id)
	if err != nil {
		if err == pgx.ErrNoRows {
			t.Skip("no tenant seed found")
		}
		t.Fatalf("query tenant: %v", err)
	}
	return id
}

func firstPlatformAssigneeID(t *testing.T, ctx context.Context, pool *pgxpool.Pool) int64 {
	t.Helper()
	var id int64
	err := pool.QueryRow(ctx, `
SELECT aa.account_id
  FROM admin_accounts aa
  JOIN accounts a ON a.id = aa.account_id
 WHERE aa.deleted_at IS NULL
   AND a.deleted_at IS NULL
   AND a.status = 'active'
   AND (
     aa.is_platform = true
     OR EXISTS (
       SELECT 1
         FROM role_assignments pra
        WHERE pra.account_id = a.id
          AND pra.scope_kind = 'platform'
          AND pra.deleted_at IS NULL
     )
     OR (
       NOT EXISTS (
         SELECT 1
           FROM tenant_memberships tm
          WHERE tm.account_id = a.id
            AND tm.deleted_at IS NULL
       )
       AND NOT EXISTS (
         SELECT 1
           FROM role_assignments tra
          WHERE tra.account_id = a.id
            AND tra.scope_kind = 'tenant'
            AND tra.deleted_at IS NULL
       )
     )
   )
 ORDER BY aa.account_id
 LIMIT 1`).Scan(&id)
	if err != nil {
		if err == pgx.ErrNoRows {
			t.Skip("no active platform sys user found")
		}
		t.Fatalf("query platform sys user: %v", err)
	}
	return id
}
