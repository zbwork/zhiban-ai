package message

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/convstate"
)

// ----- Messages around / newer -----

func (m *Repo) MessagesAround(ctx context.Context, accountID, tenantID int64, conversationUUID, anchorUUID string, before, after int) ([]map[string]any, error) {
	if before <= 0 || before > 200 {
		before = 25
	}
	if after <= 0 || after > 200 {
		after = 25
	}
	if err := assertConversationOwnedByCaller(ctx, m.pool, accountID, tenantID, conversationUUID); err != nil {
		return nil, err
	}
	clearedAt, err := convstate.New(m.pool).ClearedAt(ctx, accountID, tenantID, conversationUUID)
	if err != nil {
		return nil, err
	}
	// anchor id + conversation_id check
	var convID, anchorID int64
	err = m.pool.QueryRow(ctx,
		`SELECT m.id, m.conversation_id FROM messages m
		 JOIN conversations c ON c.id = m.conversation_id
		 WHERE m.uuid=$1::uuid AND c.uuid=$2::uuid AND ($3::timestamptz IS NULL OR m.created_at > $3)`,
		anchorUUID, conversationUUID, clearedAt,
	).Scan(&anchorID, &convID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("anchor message not found in conversation")
		}
		return nil, err
	}
	rows, err := m.pool.Query(ctx,
		`SELECT uuid, role, status, blocks, COALESCE(metadata,'{}'::jsonb), created_at, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,'')
		 FROM (
		   (SELECT id, uuid, role, status, CASE WHEN status='cancelled' THEN '[]'::jsonb ELSE blocks END AS blocks, metadata, created_at, stream_id, final, error_code, error_message
		      FROM messages WHERE conversation_id=$1 AND id <= $2 AND ($5::timestamptz IS NULL OR created_at > $5)
		      ORDER BY id DESC LIMIT $3)
		   UNION ALL
		   (SELECT id, uuid, role, status, CASE WHEN status='cancelled' THEN '[]'::jsonb ELSE blocks END AS blocks, metadata, created_at, stream_id, final, error_code, error_message
		      FROM messages WHERE conversation_id=$1 AND id > $2 AND ($5::timestamptz IS NULL OR created_at > $5)
		      ORDER BY id ASC LIMIT $4)
		 ) t ORDER BY created_at ASC, id ASC`,
		convID, anchorID, before, after, clearedAt,
	)
	if err != nil {
		return nil, err
	}
	return scanMessageRows(rows)
}

func (m *Repo) MessagesNewer(ctx context.Context, accountID, tenantID int64, conversationUUID, sinceUUID string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	if err := assertConversationOwnedByCaller(ctx, m.pool, accountID, tenantID, conversationUUID); err != nil {
		return nil, err
	}
	clearedAt, err := convstate.New(m.pool).ClearedAt(ctx, accountID, tenantID, conversationUUID)
	if err != nil {
		return nil, err
	}
	var convID int64
	if err := m.pool.QueryRow(ctx, `SELECT id FROM conversations WHERE uuid=$1::uuid`, conversationUUID).Scan(&convID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	var rows pgx.Rows
	if sinceUUID == "" {
		rows, err = m.pool.Query(ctx,
			`SELECT uuid, role, status, CASE WHEN status='cancelled' THEN '[]'::jsonb ELSE blocks END AS blocks, COALESCE(metadata,'{}'::jsonb), created_at, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,'')
			 FROM messages WHERE conversation_id=$1 AND ($3::timestamptz IS NULL OR created_at > $3) ORDER BY created_at DESC, id DESC LIMIT $2`,
			convID, limit, clearedAt,
		)
	} else {
		var sinceID int64
		err = m.pool.QueryRow(ctx,
			`SELECT id FROM messages WHERE conversation_id=$1 AND uuid=$2::uuid AND ($3::timestamptz IS NULL OR created_at > $3)`,
			convID, sinceUUID, clearedAt,
		).Scan(&sinceID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, apperr.ErrNotFound.Withf("since message not in conversation")
			}
			return nil, err
		}
		rows, err = m.pool.Query(ctx,
			`SELECT uuid, role, status, CASE WHEN status='cancelled' THEN '[]'::jsonb ELSE blocks END AS blocks, COALESCE(metadata,'{}'::jsonb), created_at, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,'')
			 FROM messages WHERE conversation_id=$1 AND id > $2 AND ($4::timestamptz IS NULL OR created_at > $4) ORDER BY id ASC LIMIT $3`,
			convID, sinceID, limit, clearedAt,
		)
	}
	if err != nil {
		return nil, err
	}
	return scanMessageRows(rows)
}

func scanMessageRows(rows pgx.Rows) ([]map[string]any, error) {
	defer rows.Close()
	out := make([]map[string]any, 0)
	for rows.Next() {
		var uuid, role, status, streamID, errorCode, errorMessage string
		var final bool
		var blocks, meta []byte
		var createdAt time.Time
		if err := rows.Scan(&uuid, &role, &status, &blocks, &meta, &createdAt, &streamID, &final, &errorCode, &errorMessage); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"uuid":       uuid,
			"role":       role,
			"status":     status,
			"blocks":     historyRawJSON(blocks),
			"metadata":   historyRawJSON(meta),
			"created_at": createdAt.Format(time.RFC3339Nano),
			"stream_id":  streamID, "final": final, "error_code": errorCode, "error_message": errorMessage,
		})
	}
	return out, rows.Err()
}

func historyRawJSON(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	// 返回 []byte 以便 encode 包 fall back 到 base64? 不; 这里返回 string 让 chat client 自己解.
	// 优先 json.RawMessage 让 encoding/json 直接透传.
	return jsonRawMessage(b)
}

type jsonRawMessage []byte

func (m jsonRawMessage) MarshalJSON() ([]byte, error) {
	if len(m) == 0 {
		return []byte("null"), nil
	}
	return m, nil
}

// assertConversationOwnedByCaller · single-chat 必须 account_id 匹配; group 必须 caller 是 active human participant.
func assertConversationOwnedByCaller(ctx context.Context, pool *pgxpool.Pool, accountID, tenantID int64, conversationUUID string) error {
	var (
		convID       int64
		ownAccountID int64
		roomID       *int64
		convTenant   int64
	)
	err := pool.QueryRow(ctx,
		`SELECT id, account_id, room_id, tenant_id FROM conversations WHERE uuid=$1::uuid AND deleted_at IS NULL`,
		conversationUUID,
	).Scan(&convID, &ownAccountID, &roomID, &convTenant)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound.Withf("conversation not found")
		}
		return err
	}
	if convTenant != tenantID {
		return apperr.ErrForbidden.Withf("conversation tenant mismatch")
	}
	if roomID == nil {
		if ownAccountID != accountID {
			return apperr.ErrForbidden.Withf("conversation account mismatch")
		}
		return nil
	}
	// group: 检查 caller 是 active human participant.
	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM room_participants WHERE room_id=$1 AND kind='human' AND account_id=$2 AND left_at IS NULL`,
		*roomID, accountID,
	).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return apperr.ErrForbidden.Withf("caller not active participant in room")
	}
	return nil
}
