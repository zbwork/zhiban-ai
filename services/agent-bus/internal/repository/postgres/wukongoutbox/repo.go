// Package wukongoutbox 是 ADR-0026 P0 前置 — wukong_send_outbox 的 PG 仓储。
// 仅本包碰 SQL;worker / 调用方经 domain.Repository 接口使用。
package wukongoutbox

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo {
	if pool == nil {
		panic("wukongoutbox.Repo: pool required")
	}
	return &Repo{pool: pool}
}

const cols = `id, tenant_id, channel_id, channel_type, from_uid, msg_type, payload,
	dedup_key, source, status, retry_count, max_retries, next_attempt_at, sent_at,
	last_error, locked_by, lock_expires_at, created_at, updated_at`

const colsO = `o.id, o.tenant_id, o.channel_id, o.channel_type, o.from_uid, o.msg_type, o.payload,
	o.dedup_key, o.source, o.status, o.retry_count, o.max_retries, o.next_attempt_at, o.sent_at,
	o.last_error, o.locked_by, o.lock_expires_at, o.created_at, o.updated_at`

const errMaxLen = 1024

func scan(row pgx.Row) (dom.Message, error) {
	var m dom.Message
	var sentAt sql.NullTime
	var lastErr sql.NullString
	var lockedBy sql.NullString
	var lockExpiresAt sql.NullTime
	err := row.Scan(
		&m.ID, &m.TenantID, &m.ChannelID, &m.ChannelType, &m.FromUID, &m.MsgType, &m.Payload,
		&m.DedupKey, &m.Source, &m.Status, &m.RetryCount, &m.MaxRetries, &m.NextAttemptAt, &sentAt,
		&lastErr, &lockedBy, &lockExpiresAt, &m.CreatedAt, &m.UpdatedAt,
	)
	if err != nil {
		return dom.Message{}, err
	}
	if sentAt.Valid {
		t := sentAt.Time
		m.SentAt = &t
	}
	m.LastError = lastErr.String
	m.LockedBy = lockedBy.String
	if lockExpiresAt.Valid {
		t := lockExpiresAt.Time
		m.LockExpiresAt = &t
	}
	return m, nil
}

func truncErr(s string) string {
	if len(s) > errMaxLen {
		return s[:errMaxLen]
	}
	return s
}

// Enqueue 幂等插入:(tenant_id, dedup_key) 冲突 → 不插入,回查现有行,inserted=false。
func (r *Repo) Enqueue(ctx context.Context, m dom.Message) (dom.Message, bool, error) {
	maxRetries := m.MaxRetries
	if maxRetries <= 0 {
		maxRetries = dom.DefaultMaxRetries
	}
	source := m.Source
	if source == "" {
		source = dom.SourceGeneric
	}
	row := r.pool.QueryRow(ctx, `
INSERT INTO wukong_send_outbox
	(tenant_id, channel_id, channel_type, from_uid, msg_type, payload, dedup_key, source, max_retries)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
ON CONFLICT (tenant_id, dedup_key) DO NOTHING
RETURNING `+cols,
		m.TenantID, m.ChannelID, m.ChannelType, m.FromUID, m.MsgType, m.Payload, m.DedupKey, source, maxRetries)
	stored, err := scan(row)
	if err == nil {
		return stored, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return dom.Message{}, false, err
	}
	// 冲突(已存在同 tenant+dedup_key)→ 回查现有行。
	existing, gerr := r.GetByDedupKey(ctx, m.TenantID, m.DedupKey)
	if gerr != nil {
		return dom.Message{}, false, gerr
	}
	return existing, false, nil
}

// ClaimDue 单 query 完成 SELECT FOR UPDATE SKIP LOCKED + UPDATE status='sending' + 打 lease + RETURNING。
// 取两类(均 retry_count<max_retries):正常待办((pending/failed)且 next_attempt_at<=now)、
// lease 超时(sending 且 lock_expires_at<=now,worker 崩溃后重投)。未超时的 sending 不取。
func (r *Repo) ClaimDue(ctx context.Context, workerID string, lease time.Duration, limit int, now time.Time) ([]dom.Message, error) {
	if limit <= 0 {
		limit = 20
	}
	if lease <= 0 {
		lease = dom.DefaultLease
	}
	lockExpires := now.Add(lease)
	rows, err := r.pool.Query(ctx, `
WITH picked AS (
	SELECT id FROM wukong_send_outbox
	WHERE retry_count < max_retries
	  AND (
	        (status IN ('pending','failed') AND next_attempt_at <= $2)
	     OR (status = 'sending' AND lock_expires_at IS NOT NULL AND lock_expires_at <= $2)
	  )
	ORDER BY next_attempt_at ASC
	LIMIT $1
	FOR UPDATE SKIP LOCKED
)
UPDATE wukong_send_outbox o
SET status='sending', locked_by=$3, lock_expires_at=$4, updated_at=now()
FROM picked
WHERE o.id = picked.id
RETURNING `+colsO, limit, now, workerID, lockExpires)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]dom.Message, 0, limit)
	for rows.Next() {
		m, serr := scan(rows)
		if serr != nil {
			return nil, serr
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (r *Repo) MarkSent(ctx context.Context, id string, sentAt time.Time) error {
	tag, err := r.pool.Exec(ctx, `
UPDATE wukong_send_outbox
SET status='sent', sent_at=$2, last_error=NULL, locked_by=NULL, lock_expires_at=NULL, updated_at=now()
WHERE id=$1`, id, sentAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *Repo) MarkRetry(ctx context.Context, id, errMsg string, nextAttemptAt time.Time) error {
	tag, err := r.pool.Exec(ctx, `
UPDATE wukong_send_outbox
SET status='failed', retry_count=retry_count+1, last_error=$2, next_attempt_at=$3,
	locked_by=NULL, lock_expires_at=NULL, updated_at=now()
WHERE id=$1`, id, truncErr(errMsg), nextAttemptAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *Repo) MarkFailed(ctx context.Context, id, errMsg string) error {
	// 终态:retry_count+1 使其 >= max_retries → ClaimDue 不再取(status 仍记 failed 便于排障)。
	tag, err := r.pool.Exec(ctx, `
UPDATE wukong_send_outbox
SET status='failed', retry_count=retry_count+1, last_error=$2,
	locked_by=NULL, lock_expires_at=NULL, updated_at=now()
WHERE id=$1`, id, truncErr(errMsg))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *Repo) GetByDedupKey(ctx context.Context, tenantID, dedupKey string) (dom.Message, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+cols+` FROM wukong_send_outbox WHERE tenant_id=$1 AND dedup_key=$2`, tenantID, dedupKey)
	m, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return dom.Message{}, apperr.ErrNotFound
	}
	return m, err
}
