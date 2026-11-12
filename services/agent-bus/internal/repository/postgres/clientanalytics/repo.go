package clientanalytics

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

func (r *Repo) InsertBatch(ctx context.Context, tenantID, accountID int64, events []dom.Event) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, e := range events {
		props, err := json.Marshal(e.Properties)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO client_analytics_events
			(event_id, tenant_id, account_id, event_name, schema_version, session_id, platform, app_version, properties, occurred_at)
			VALUES ($1::uuid,$2,$3,$4,$5,$6::uuid,$7,$8,$9::jsonb,$10) ON CONFLICT DO NOTHING`,
			e.EventID, tenantID, accountID, e.Name, e.SchemaVersion, e.SessionID, e.Platform, e.AppVersion, props, e.OccurredAt)
		if err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
