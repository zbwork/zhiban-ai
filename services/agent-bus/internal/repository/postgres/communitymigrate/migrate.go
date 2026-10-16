// Package communitymigrate applies the independent community database baseline.
package communitymigrate

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io/fs"

	"github.com/jackc/pgx/v5/pgxpool"
	migrations "github.com/zbwork/zhiban-ai/services/agent-bus/sql/community"
)

// Apply serializes migrations and commits schema, seeds and checksums atomically.
// Existing commercial schemas and modified previously applied migrations are rejected.
func Apply(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(780143220)"); err != nil {
		return err
	}
	var schema, ledger bool
	if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='agent_bus'), to_regclass('agent_bus.community_schema_migrations') IS NOT NULL").Scan(&schema, &ledger); err != nil {
		return err
	}
	if schema && !ledger {
		return fmt.Errorf("existing unmanaged agent_bus schema: use an empty database")
	}
	names, err := fs.Glob(migrations.Files, "*.up.sql")
	if err != nil {
		return err
	}
	for _, name := range names {
		data, err := migrations.Files.ReadFile(name)
		if err != nil {
			return err
		}
		checksum := fmt.Sprintf("%x", sha256.Sum256(data))
		if ledger {
			var previous string
			if err = tx.QueryRow(ctx, "SELECT COALESCE((SELECT checksum FROM agent_bus.community_schema_migrations WHERE version=$1),'')", name).Scan(&previous); err != nil {
				return err
			}
			if previous != "" {
				if previous != checksum {
					return fmt.Errorf("migration checksum mismatch: %s", name)
				}
				continue
			}
		}
		if _, err = tx.Exec(ctx, string(data)); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		if !ledger {
			if _, err = tx.Exec(ctx, "CREATE TABLE agent_bus.community_schema_migrations(version text PRIMARY KEY, checksum text NOT NULL CHECK(length(checksum)=64), applied_at timestamptz NOT NULL DEFAULT now()); COMMENT ON TABLE agent_bus.community_schema_migrations IS 'Community migration checksums; managed by community-migrate'"); err != nil {
				return err
			}
			ledger = true
		}
		if _, err = tx.Exec(ctx, "INSERT INTO agent_bus.community_schema_migrations(version,checksum) VALUES($1,$2)", name, checksum); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
