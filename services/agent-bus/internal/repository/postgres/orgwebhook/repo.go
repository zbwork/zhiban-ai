// Package orgwebhook implements tenant org-sync webhook repositories.
package orgwebhook

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orgwebhook"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const configCols = `id, uuid, tenant_id, COALESCE(name, ''), callback_url, signing_secret,
    enabled, COALESCE(event_types, '{}'::varchar[]), COALESCE(description, ''),
    created_at, updated_at, deleted_at`

const configColsC = `c.id, c.uuid, c.tenant_id, COALESCE(c.name, ''), c.callback_url, c.signing_secret,
    c.enabled, COALESCE(c.event_types, '{}'::varchar[]), COALESCE(c.description, ''),
    c.created_at, c.updated_at, c.deleted_at`

func scanConfig(row pgx.Row) (*dom.Config, error) {
	var x dom.Config
	if err := row.Scan(
		&x.ID,
		&x.UUID,
		&x.TenantID,
		&x.Name,
		&x.CallbackURL,
		&x.SigningSecret,
		&x.Enabled,
		&x.EventTypes,
		&x.Description,
		&x.CreatedAt,
		&x.UpdatedAt,
		&x.DeletedAt,
	); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *Repo) List(ctx context.Context, tenantID int64) ([]dom.Config, error) {
	rows, err := r.pool.Query(ctx, `
SELECT `+configColsC+`,
       ld.id, COALESCE(ld.outbox_id, 0), COALESCE(ld.webhook_config_id, 0), COALESCE(e.topic, ''),
       COALESCE(ld.callback_url, ''), COALESCE(ld.status, ''), COALESCE(ld.attempts, 0), ld.next_retry_at, COALESCE(ld.last_error, ''),
       ld.done_at, COALESCE(ld.created_at, 'epoch'::timestamptz)
FROM tenant_webhook_configs c
LEFT JOIN LATERAL (
    SELECT *
    FROM tenant_webhook_deliveries d
    WHERE d.webhook_config_id = c.id
    ORDER BY d.created_at DESC, d.id DESC
    LIMIT 1
) ld ON true
LEFT JOIN events_outbox e ON e.id = ld.outbox_id
WHERE c.tenant_id=$1 AND c.deleted_at IS NULL
ORDER BY c.created_at DESC, c.id DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []dom.Config
	for rows.Next() {
		var x dom.Config
		var d dom.Delivery
		var deliveryID *int64
		if err := rows.Scan(
			&x.ID,
			&x.UUID,
			&x.TenantID,
			&x.Name,
			&x.CallbackURL,
			&x.SigningSecret,
			&x.Enabled,
			&x.EventTypes,
			&x.Description,
			&x.CreatedAt,
			&x.UpdatedAt,
			&x.DeletedAt,
			&deliveryID,
			&d.OutboxID,
			&d.WebhookConfigID,
			&d.EventType,
			&d.CallbackURL,
			&d.Status,
			&d.Attempts,
			&d.NextRetryAt,
			&d.LastError,
			&d.DoneAt,
			&d.CreatedAt,
		); err != nil {
			return nil, err
		}
		if deliveryID != nil {
			d.ID = *deliveryID
			x.LatestDelivery = &d
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

func (r *Repo) Get(ctx context.Context, tenantID int64, uuid string) (*dom.Config, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+configCols+`
FROM tenant_webhook_configs
WHERE tenant_id=$1 AND uuid=$2 AND deleted_at IS NULL`, tenantID, uuid)
	x, err := scanConfig(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *Repo) Insert(ctx context.Context, c *dom.Config) error {
	row := r.pool.QueryRow(ctx, `
INSERT INTO tenant_webhook_configs
    (tenant_id, name, callback_url, signing_secret, enabled, event_types, description)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING `+configCols,
		c.TenantID, c.Name, c.CallbackURL, c.SigningSecret, c.Enabled, c.EventTypes, c.Description)
	got, err := scanConfig(row)
	if err != nil {
		return err
	}
	*c = *got
	return nil
}

func (r *Repo) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.Config, error) {
	if len(fields) == 0 {
		return r.Get(ctx, tenantID, uuid)
	}
	colMap := map[string]string{
		"name":           "name",
		"callback_url":   "callback_url",
		"signing_secret": "signing_secret",
		"enabled":        "enabled",
		"event_types":    "event_types",
		"description":    "description",
	}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, col+" = $"+strconv.Itoa(idx))
		idx++
	}
	if len(sets) == 0 {
		return r.Get(ctx, tenantID, uuid)
	}
	args = append(args, tenantID, uuid)
	q := "UPDATE tenant_webhook_configs SET " + strings.Join(sets, ", ") +
		", updated_at=now() WHERE tenant_id=$" + strconv.Itoa(idx) +
		" AND uuid=$" + strconv.Itoa(idx+1) +
		" AND deleted_at IS NULL RETURNING " + configCols
	row := r.pool.QueryRow(ctx, q, args...)
	x, err := scanConfig(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *Repo) SoftDelete(ctx context.Context, tenantID int64, uuid string) error {
	tag, err := r.pool.Exec(ctx, `
UPDATE tenant_webhook_configs
SET deleted_at=now(), enabled=false, updated_at=now()
WHERE tenant_id=$1 AND uuid=$2 AND deleted_at IS NULL`, tenantID, uuid)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		if _, gerr := r.Get(ctx, tenantID, uuid); gerr != nil {
			return gerr
		}
	}
	return nil
}

func (r *Repo) ListDeliveries(ctx context.Context, tenantID int64, configUUID string, limit int) ([]dom.Delivery, error) {
	rows, err := r.pool.Query(ctx, `
SELECT d.id, d.outbox_id, d.webhook_config_id, COALESCE(e.topic, ''), d.callback_url,
       d.status, d.attempts, d.next_retry_at, COALESCE(d.last_error, ''),
       d.done_at, d.created_at
FROM tenant_webhook_deliveries d
JOIN tenant_webhook_configs c ON c.id = d.webhook_config_id
LEFT JOIN events_outbox e ON e.id = d.outbox_id
WHERE c.tenant_id=$1 AND c.uuid=$2 AND c.deleted_at IS NULL
ORDER BY d.created_at DESC, d.id DESC
LIMIT $3`, tenantID, configUUID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []dom.Delivery
	for rows.Next() {
		var d dom.Delivery
		if err := rows.Scan(
			&d.ID,
			&d.OutboxID,
			&d.WebhookConfigID,
			&d.EventType,
			&d.CallbackURL,
			&d.Status,
			&d.Attempts,
			&d.NextRetryAt,
			&d.LastError,
			&d.DoneAt,
			&d.CreatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
