//go:build integration

package agentsdk_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agentsdk"
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

// 平台凭据 tenant_id 为 NULL——Patch 传 tenantID=0 必须命中 (2026-09-02 生产实锤:
// 此前恒拼 tenant_id=0 谓词匹配零行, 平台凭据换绑 runtime_environment_id 永远 ErrNotFound,
// bootstrap 卡在凭据步无法自愈)。内存 fake 测不出 NULL 谓词, 真库钉死。
func TestPatch_PlatformCredentialTenantNull(t *testing.T) {
	pool := setupPool(t)
	ctx := context.Background()
	r := repo.NewCredentialRepo(pool)

	var acct int64
	if err := pool.QueryRow(ctx, `INSERT INTO agent_bus.accounts (uuid, display_name, status)
		VALUES (gen_random_uuid(), 'sdk-it', 'active') RETURNING id`).Scan(&acct); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	// scope 约束要求平台凭据始终绑 runtime_environment_id: 取两个环境, 种子绑 A、换绑到 B。
	var envA, envB int64
	if err := pool.QueryRow(ctx, `SELECT min(id), max(id) FROM agent_bus.runtime_environments WHERE is_deleted=false`).Scan(&envA, &envB); err != nil || envA == envB {
		t.Fatalf("need two runtime envs: a=%d b=%d err=%v", envA, envB, err)
	}
	var uuid string
	if err := pool.QueryRow(ctx, `INSERT INTO agent_bus.agent_sdk_credentials
		(creator_id, name, client_id, client_secret_hash, scope, status, tenant_id, runtime_environment_id)
		VALUES ($1, 'sdk-it 平台凭据', 'sdk-it-'||gen_random_uuid(), 'hash', 'platform', 'active', NULL, $2)
		RETURNING uuid`, acct, envA).Scan(&uuid); err != nil {
		t.Fatalf("seed platform credential: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM agent_bus.agent_sdk_credentials WHERE uuid=$1`, uuid)
		_, _ = pool.Exec(ctx, `DELETE FROM agent_bus.accounts WHERE id=$1`, acct)
	})

	got, err := r.Patch(ctx, 0, uuid, map[string]any{"runtime_environment_id": envB})
	if err != nil {
		t.Fatalf("platform patch (tenantID=0) must hit tenant_id IS NULL row: %v", err)
	}
	if got.RuntimeEnvironmentID == nil || *got.RuntimeEnvironmentID != envB {
		t.Fatalf("runtime_environment_id not rebound: %+v", got.RuntimeEnvironmentID)
	}
}
