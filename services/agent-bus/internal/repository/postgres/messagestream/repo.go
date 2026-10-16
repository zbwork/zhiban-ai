// Package messagestream 是 internal/domain/messagestream 的 PG 实现 (Batch 3B T3.5).
package messagestream

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/messagestream"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

func (r *Repo) Insert(ctx context.Context, in dom.CreateInput) (*dom.Stream, error) {
	row := r.pool.QueryRow(ctx, `
INSERT INTO message_streams (
    stream_id, tenant_id, account_id, conversation_id, message_uuid,
    cancel_token, bus_node_id
) VALUES ($1, $2, $3, $4, $5::uuid, $6, $7)
RETURNING id, stream_id, tenant_id, account_id, conversation_id, message_uuid::text,
          COALESCE(runtime_session,''), cancel_token, bus_node_id, state,
          started_at, last_event_at, finished_at`,
		in.StreamID, in.TenantID, in.AccountID, in.ConversationID, in.MessageUUID,
		in.CancelToken, in.BusNodeID)
	var s dom.Stream
	if err := row.Scan(
		&s.ID, &s.StreamID, &s.TenantID, &s.AccountID, &s.ConversationID, &s.MessageUUID,
		&s.RuntimeSession, &s.CancelToken, &s.BusNodeID, &s.State,
		&s.StartedAt, &s.LastEventAt, &s.FinishedAt,
	); err != nil {
		return nil, err
	}
	return &s, nil
}

func (r *Repo) GetByMessageUUID(ctx context.Context, messageUUID string) (*dom.Stream, error) {
	row := r.pool.QueryRow(ctx, selectStreamSQL+` WHERE message_uuid = $1::uuid`, messageUUID)
	return scanStream(row)
}

func (r *Repo) GetByStreamID(ctx context.Context, streamID string) (*dom.Stream, error) {
	row := r.pool.QueryRow(ctx, selectStreamSQL+` WHERE stream_id = $1`, streamID)
	return scanStream(row)
}

func (r *Repo) UpdateStateByStreamID(ctx context.Context, streamID, state string, fromActive bool) error {
	// 显式 ::text 类型标注: $1 在 SET 与 CASE 内都使用, PG planner 无法独立推断类型
	// (报 SQLSTATE 42P08 inconsistent types deduced); 显式标注让两处都按 text 走.
	q := `UPDATE message_streams
            SET state = $1::text,
                finished_at = CASE WHEN $1::text IN ('done','cancelled','failed') THEN now() ELSE finished_at END,
                last_event_at = now()
          WHERE stream_id = $2`
	args := []any{state, streamID}
	if fromActive {
		q += ` AND state = 'active'`
	}
	_, err := r.pool.Exec(ctx, q, args...)
	return err
}

// CancelActiveByStreamID 3B 返修 #2: 原子地把 'active' 行翻成 'cancelled' 并显式返回
// 是否真的命中了一行 (用于让 stop 路径区分"真把流取消了" vs "被 finalize 抢先收尾").
func (r *Repo) CancelActiveByStreamID(ctx context.Context, streamID string) (bool, error) {
	tag, err := r.pool.Exec(ctx, `UPDATE message_streams
            SET state = 'cancelled',
                finished_at = now(),
                last_event_at = now()
          WHERE stream_id = $1 AND state = 'active'`, streamID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// UpdateTerminalStateByStreamID 3B 返修 final patch: finalize 的终态写入 + race 自检.
// UPDATE WHERE state='active' 再 SELECT state 回读, 一起返给 caller. 走 CTE 单次 round-trip
// 同时保证: state 一旦终态 (done/cancelled/failed) 就再无 writer (schema + 代码不变量),
// SELECT 读到的值与 UPDATE 一致.
func (r *Repo) UpdateTerminalStateByStreamID(ctx context.Context, streamID, newState string) (bool, string, error) {
	var (
		changed      bool
		currentState string
	)
	err := r.pool.QueryRow(ctx, `
WITH upd AS (
    UPDATE message_streams
       SET state = $1::text,
           finished_at = CASE WHEN $1::text IN ('done','cancelled','failed') THEN now() ELSE finished_at END,
           last_event_at = now()
     WHERE stream_id = $2 AND state = 'active'
    RETURNING state
)
SELECT (SELECT count(*) FROM upd) > 0,
       COALESCE((SELECT state FROM upd LIMIT 1),
                (SELECT state FROM message_streams WHERE stream_id = $2),
                '')
`, newState, streamID).Scan(&changed, &currentState)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, "", nil
		}
		return false, "", err
	}
	return changed, currentState, nil
}

func (r *Repo) TouchLastEventByStreamID(ctx context.Context, streamID string) error {
	_, err := r.pool.Exec(ctx, `UPDATE message_streams SET last_event_at = now() WHERE stream_id = $1`, streamID)
	return err
}

// UpdateOwnerNode (doc-12 Task D 队列): 把仍 active 的 stream 归属切到执行节点 (worker 消费时调)。
func (r *Repo) UpdateOwnerNode(ctx context.Context, streamID, busNodeID string) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE message_streams SET bus_node_id = $2 WHERE stream_id = $1 AND state = 'active'`, streamID, busNodeID)
	return err
}

const selectStreamSQL = `SELECT id, stream_id, tenant_id, account_id, conversation_id,
                                message_uuid::text, COALESCE(runtime_session,''), cancel_token,
                                bus_node_id, state, started_at, last_event_at, finished_at
                           FROM message_streams`

func scanStream(row pgx.Row) (*dom.Stream, error) {
	var s dom.Stream
	if err := row.Scan(
		&s.ID, &s.StreamID, &s.TenantID, &s.AccountID, &s.ConversationID, &s.MessageUUID,
		&s.RuntimeSession, &s.CancelToken, &s.BusNodeID, &s.State,
		&s.StartedAt, &s.LastEventAt, &s.FinishedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return &s, nil
}

// ensure pgxpool kept (imported but only via constructor — keep linter happy).
var _ = (*pgxpool.Pool)(nil)
