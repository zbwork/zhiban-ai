package clientanalytics

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

func (r *Repo) ErrorDetail(ctx context.Context, fingerprint string) (*dom.ErrorDetail, error) {
	var d dom.ErrorDetail
	var props json.RawMessage
	err := r.pool.QueryRow(ctx, `
		SELECT properties->>'error_type', properties->>'error_message', properties->>'stacktrace',
		       properties->>'mechanism', properties->>'severity', platform, app_version, properties
		FROM client_analytics_events
		WHERE event_name = 'app_error' AND properties->>'fingerprint' = $1
		ORDER BY occurred_at DESC
		LIMIT 1`, fingerprint,
	).Scan(&d.ErrorType, &d.ErrorMessage, &d.Stacktrace, &d.Mechanism, &d.Severity, &d.Platform, &d.AppVersion, &props)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, dom.ErrFingerprintNotFound
		}
		return nil, err
	}
	if err := json.Unmarshal(props, &d.Properties); err != nil {
		return nil, err
	}
	d.Fingerprint = fingerprint

	if err := r.pool.QueryRow(ctx, `
		SELECT count(*), count(DISTINCT account_id), min(occurred_at), max(occurred_at)
		FROM client_analytics_events
		WHERE event_name = 'app_error' AND properties->>'fingerprint' = $1`, fingerprint,
	).Scan(&d.Occurrences, &d.AffectedUsers, &d.FirstSeenAt, &d.LastSeenAt); err != nil {
		return nil, err
	}

	if err := r.pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM client_analytics_error_archive WHERE fingerprint = $1)`, fingerprint,
	).Scan(&d.Archived); err != nil {
		return nil, err
	}

	accounts, err := r.affectedAccounts(ctx, fingerprint)
	if err != nil {
		return nil, err
	}
	d.AffectedAccounts = accounts
	return &d, nil
}

// affectedAccounts 按账号聚合某个错误指纹的命中次数，按次数降序。
func (r *Repo) affectedAccounts(ctx context.Context, fingerprint string) ([]dom.AffectedAccount, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT e.account_id, a.uuid, a.display_name, e.tenant_id, t.name, count(*), max(e.occurred_at)
		FROM client_analytics_events e
		JOIN accounts a ON a.id = e.account_id
		JOIN tenants t ON t.id = e.tenant_id
		WHERE e.event_name = 'app_error' AND e.properties->>'fingerprint' = $1
		GROUP BY e.account_id, a.uuid, a.display_name, e.tenant_id, t.name
		ORDER BY count(*) DESC, max(e.occurred_at) DESC`, fingerprint)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]dom.AffectedAccount, 0)
	for rows.Next() {
		var a dom.AffectedAccount
		if err := rows.Scan(&a.AccountID, &a.AccountUUID, &a.DisplayName, &a.TenantID, &a.TenantName, &a.Occurrences, &a.LastSeenAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (r *Repo) ArchiveError(ctx context.Context, fingerprint string, accountID int64) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO client_analytics_error_archive (fingerprint, archived_by)
		VALUES ($1, $2)
		ON CONFLICT (fingerprint) DO UPDATE SET archived_by = EXCLUDED.archived_by, archived_at = now()`,
		fingerprint, accountID)
	return err
}

func (r *Repo) UnarchiveError(ctx context.Context, fingerprint string) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM client_analytics_error_archive WHERE fingerprint = $1`, fingerprint)
	return err
}
