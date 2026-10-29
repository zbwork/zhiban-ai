//go:build integration

package localmedia

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestImagePersistentClaimAndIsolation(t *testing.T) {
	dsn := os.Getenv("LOCAL_MEDIA_TEST_DSN")
	if dsn == "" {
		t.Skip("LOCAL_MEDIA_TEST_DSN not set")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid dedicated DSN")
	}
	if cfg.ConnConfig.Database != "local_media_test" || !strings.HasPrefix(cfg.ConnConfig.Host, "/tmp/local-media-test-") {
		t.Fatal("requires isolated temporary cluster")
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = "agent_bus,public"
	ctx := context.Background()
	p, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	_, err = p.Exec(ctx, `CREATE SCHEMA agent_bus;CREATE TABLE agent_bus.local_runtime_tasks(uuid uuid PRIMARY KEY,tenant_id bigint,account_id bigint,fence bigint,status text,expires_at timestamptz);`)
	if err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile(filepath.Join("../../../../sql/postgres/000149_local_runtime_media.up.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = p.Exec(ctx, string(migration)); err != nil {
		t.Fatal(err)
	}
	task := &local.Task{UUID: uuid.NewString(), Scope: local.Scope{TenantID: 1, AccountID: 2}, Fence: 3}
	_, err = p.Exec(ctx, `INSERT INTO local_runtime_tasks VALUES($1,1,2,3,'accepted',now()+interval '15 minutes')`, task.UUID)
	if err != nil {
		t.Fatal(err)
	}
	id, digest := strings.Repeat("a", 64), strings.Repeat("b", 64)
	var won atomic.Int32
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, fresh, e := New(p).Claim(ctx, task, id, digest)
			if e != nil {
				t.Error(e)
			}
			if fresh {
				won.Add(1)
			}
		}()
	}
	wg.Wait()
	if won.Load() != 1 {
		t.Fatal("claim race", won.Load())
	}
	r := New(p)
	if _, _, err = r.Claim(ctx, task, id, strings.Repeat("c", 64)); !errors.Is(err, dom.ErrConflict) {
		t.Fatal("same ID changed input", err)
	}
	if _, fresh, err := r.Claim(ctx, task, strings.Repeat("d", 64), digest); err != nil || fresh {
		t.Fatal("new ID recharged identical input", err)
	}
	other := *task
	other.Scope.AccountID = 88
	if _, _, err = r.Claim(ctx, &other, id, digest); !errors.Is(err, local.ErrDenied) {
		t.Fatal("cross-account read", err)
	}
	other = *task
	other.Fence = 4
	if _, _, err = r.Claim(ctx, &other, id, digest); !errors.Is(err, local.ErrDenied) {
		t.Fatal("stale fence", err)
	}
	if err = r.Complete(ctx, task, id, []byte("bounded-result")); err != nil {
		t.Fatal(err)
	}
	result, fresh, err := New(p).Claim(ctx, task, id, digest)
	if err != nil || fresh || string(result.Image) != "bounded-result" {
		t.Fatal("durable replay", err)
	}
	_, err = p.Exec(ctx, `UPDATE local_runtime_media SET result_expires_at=now()-interval '1 second'`)
	if err != nil {
		t.Fatal(err)
	}
	if err = r.ExpireResults(ctx); err != nil {
		t.Fatal(err)
	}
	result, fresh, err = r.Claim(ctx, task, id, digest)
	if err != nil || fresh || result.Image != nil || result.State != "completed" {
		t.Fatal("expiry removed submission tombstone", err)
	}
	rejectedID, rejectedDigest := strings.Repeat("e", 64), strings.Repeat("f", 64)
	if _, fresh, err := r.Claim(ctx, task, rejectedID, rejectedDigest); err != nil || !fresh {
		t.Fatal(err)
	}
	if err = r.Reject(ctx, &other, rejectedID); !errors.Is(err, dom.ErrConflict) {
		t.Fatal("stale fence rejected another task", err)
	}
	if err = r.Reject(ctx, task, rejectedID); err != nil {
		t.Fatal(err)
	}
	result, fresh, err = New(p).Claim(ctx, task, rejectedID, rejectedDigest)
	if err != nil || fresh || result.State != "failed" {
		t.Fatal("rejection not durable", err)
	}
}
