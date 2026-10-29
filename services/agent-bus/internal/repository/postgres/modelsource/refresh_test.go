package modelsource

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"os"
	"testing"
)

// Uses connection-local temporary tables only, never shared application rows.
func TestCatalogCompareAndSwap(t *testing.T) {
	dsn := os.Getenv("MODEL_SOURCE_TEST_DSN")
	if dsn == "" {
		t.Skip("MODEL_SOURCE_TEST_DSN not set")
	}
	ctx := context.Background()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test DSN")
	}
	cfg.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal("connect test database")
	}
	defer pool.Close()
	_, err = pool.Exec(ctx, `CREATE TEMP TABLE tenants(id bigint,status text); CREATE TEMP TABLE accounts(id bigint,status text,deleted_at timestamptz);CREATE TEMP TABLE tenant_memberships(tenant_id bigint,account_id bigint,status text,deleted_at timestamptz);CREATE TEMP TABLE member_model_sources(uuid uuid DEFAULT gen_random_uuid(),tenant_id bigint,account_id bigint,source_id text,fingerprint text,enabled boolean,config_ciphertext bytea,version bigint DEFAULT 1,updated_at timestamptz DEFAULT now(),UNIQUE(tenant_id,account_id,source_id));INSERT INTO tenants VALUES(9223372036854770000,'active');INSERT INTO accounts VALUES(9223372036854770001,'active',NULL);INSERT INTO tenant_memberships VALUES(9223372036854770000,9223372036854770001,'active',NULL)`)
	if err != nil {
		t.Fatal(err)
	}
	repo := New(pool)
	scope := dom.Scope{TenantID: 9223372036854770000, AccountID: 9223372036854770001}
	v := dom.Stored{SourceID: "managed:beebridge", Fingerprint: "v1", Enabled: true, Ciphertext: []byte("fixture")}
	if ok, e := repo.UpdateCatalog(ctx, scope, nil, v); e != nil || !ok {
		t.Fatal(ok, e)
	}
	rows, e := repo.List(ctx, scope)
	if e != nil || len(rows) != 1 {
		t.Fatal(e)
	}
	original := rows[0]
	if ok, e := repo.UpdateCatalog(ctx, scope, nil, v); e != nil || ok {
		t.Fatal("creation race", ok, e)
	}
	v.Fingerprint = "v2"
	if ok, e := repo.UpdateCatalog(ctx, scope, &original, v); e != nil || !ok {
		t.Fatal("update", ok, e)
	}
	if ok, e := repo.UpdateCatalog(ctx, scope, &original, v); e != nil || ok {
		t.Fatal("stale update accepted", ok, e)
	}
	rows, e = repo.List(ctx, scope)
	if e != nil || rows[0].Version != 2 || rows[0].UUID != original.UUID {
		t.Fatal("identity/version", rows, e)
	}
	current := rows[0]
	v.Ciphertext = []byte("same config with new encryption nonce")
	if ok, e := repo.UpdateCatalog(ctx, scope, &current, v); e != nil || !ok {
		t.Fatal("unchanged refresh", ok, e)
	}
	rows, e = repo.List(ctx, scope)
	if e != nil || rows[0].Version != current.Version || string(rows[0].Ciphertext) != string(current.Ciphertext) {
		t.Fatal("unchanged refresh changed stored config", e)
	}
	if ok, e := repo.UpdateCatalog(ctx, dom.Scope{TenantID: 1, AccountID: 2}, nil, v); e == nil || ok {
		t.Fatal("cross-scope accepted")
	}
	// Simulate two pre-canonical sources and exercise the locked write path.
	if _, e = pool.Exec(ctx, `UPDATE member_model_sources SET source_id='legacy-latest'`); e != nil {
		t.Fatal(e)
	}
	if _, e = pool.Exec(ctx, `INSERT INTO member_model_sources(tenant_id,account_id,source_id,fingerprint,enabled,config_ciphertext,updated_at) VALUES($1,$2,'legacy-old','old',true,'old',now()-interval '1 day')`, scope.TenantID, scope.AccountID); e != nil {
		t.Fatal(e)
	}
	rows, e = repo.Reconcile(ctx, scope, func(rows []dom.Stored) ([]dom.Stored, error) {
		if len(rows) != 2 || rows[0].SourceID != "legacy-old" {
			t.Fatal("unexpected lock snapshot", rows)
		}
		rows[0].Enabled = false
		rows[1].SourceID = "managed:beebridge"
		return rows, nil
	})
	if e != nil || len(rows) != 2 || rows[0].Enabled || rows[1].UUID != original.UUID || rows[1].SourceID != "managed:beebridge" {
		t.Fatal("reconcile identity/retirement", rows, e)
	}
	version := rows[1].Version
	rows, e = repo.Reconcile(ctx, scope, func([]dom.Stored) ([]dom.Stored, error) { return nil, nil })
	if e != nil {
		t.Fatal(e)
	}
	for _, row := range rows {
		if row.UUID == original.UUID && row.Version != version {
			t.Fatal("no-op changed version")
		}
	}
	if _, e = repo.Reconcile(ctx, scope, func([]dom.Stored) ([]dom.Stored, error) { return nil, errors.New("decode failure") }); e == nil {
		t.Fatal("transform error swallowed")
	}
	// A later invalid row rolls back earlier writes in the same transaction.
	if _, e = repo.Reconcile(ctx, scope, func(rows []dom.Stored) ([]dom.Stored, error) {
		rows[0].Enabled = true
		return []dom.Stored{rows[0], {UUID: "missing"}}, nil
	}); e == nil {
		t.Fatal("invalid update accepted")
	}
	rows, e = repo.List(ctx, scope)
	if e != nil {
		t.Fatal(e)
	}
	for _, row := range rows {
		if row.SourceID == "legacy-old" && row.Enabled {
			t.Fatal("partial transaction committed")
		}
	}
	if _, e = repo.Reconcile(ctx, dom.Scope{TenantID: 1, AccountID: 2}, func([]dom.Stored) ([]dom.Stored, error) { t.Fatal("cross-scope callback invoked"); return nil, nil }); e == nil {
		t.Fatal("cross-scope reconcile accepted")
	}
}
