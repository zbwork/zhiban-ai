package message

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

func (r *Repo) Append(ctx context.Context, m *dom.Message) (*dom.Message, error) {
	blocks, _ := json.Marshal(emptySliceIfNil(m.Blocks))
	meta, _ := json.Marshal(emptyMapIfNil(m.Metadata))
	logs, _ := json.Marshal(emptySliceIfNil(m.EventLogs))
	row := r.pool.QueryRow(ctx, `
		INSERT INTO messages (uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
		    blocks, status, stream_id, final, error_code, error_message, parent_message_id, trace_id, metadata, event_logs)
		VALUES (COALESCE(NULLIF($1,'')::uuid, gen_random_uuid()),$2,$3,$4,$5,$6,$7,$8::jsonb,
		    COALESCE(NULLIF($9,''),'final'), NULLIF($10,''), $11, NULLIF($12,''), NULLIF($13,''), $14, NULLIF($15,''), $16::jsonb, $17::jsonb)
		RETURNING id, uuid, created_at, updated_at`,
		m.UUID, m.TenantID, m.ConversationID, m.RoomID, m.Role, m.SenderAccountID, m.SenderAgentID,
		string(blocks), m.Status, m.StreamID, m.Final, m.ErrorCode, m.ErrorMessage, m.ParentMessageID, m.TraceID,
		string(meta), string(logs))
	if err := row.Scan(&m.ID, &m.UUID, &m.CreatedAt, &m.UpdatedAt); err != nil {
		return nil, err
	}
	return m, nil
}

// HasSupportWelcomeMessage 用于新用户空会话列表欢迎语的幂等检查。
// welcome seed 是一条持久化 agent final message; metadata 标记避免并发首次拉列表时重复写。
func (r *Repo) HasSupportWelcomeMessage(ctx context.Context, conversationID int64) (bool, error) {
	var ok bool
	err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			  FROM messages
			 WHERE conversation_id=$1
			   AND role='agent'
			   AND status='final'
			   AND final=true
			   AND metadata->>'system_seed'='support_welcome'
		)`, conversationID).Scan(&ok)
	return ok, err
}

// PatchMetadata 按 uuid 浅合并 messages.metadata (jsonb ||)。
// F08 run 终态回写: cron trigger 消息的 cron_run_status 由 running → succeeded/failed,
// 客户端卡片状态据此与历史执行结果保持一致。
func (r *Repo) PatchMetadata(ctx context.Context, uuid string, patch map[string]any) error {
	if len(patch) == 0 {
		return nil
	}
	b, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx,
		`UPDATE messages SET metadata = COALESCE(metadata,'{}'::jsonb) || $2::jsonb, updated_at = now()
		  WHERE uuid = $1::uuid`, uuid, string(b))
	return err
}

// UpdateStream T2D.4 终态写入: blocks + status + final + error_* + metadata。
// metadata=nil 时不动 messages.metadata 列 (避免覆盖之前流式收集的 token usage 等)。
func (r *Repo) UpdateStream(ctx context.Context, streamID string, blocks []map[string]any, status string, final bool, errCode, errMsg string, metadata map[string]any) error {
	b, _ := json.Marshal(emptySliceIfNil(blocks))
	if metadata == nil {
		_, err := r.pool.Exec(ctx, `
			UPDATE messages
			   SET blocks=(
			       SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb)
			         FROM jsonb_array_elements(COALESCE(messages.blocks, '[]'::jsonb)) AS elem
			        WHERE elem->>'x_source' IN ('a2a_timeline','local_result')
			        ) || (SELECT COALESCE(jsonb_agg(incoming),'[]'::jsonb)
                   FROM jsonb_array_elements($1::jsonb) incoming
                   WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(messages.blocks,'[]'::jsonb)) saved
                     WHERE saved->>'x_source'='local_result' AND saved->'local_artifact'=incoming->'local_artifact')),
			       status=$2, final=$3,
			    error_code=NULLIF($4,''), error_message=NULLIF($5,''), updated_at=now()
			WHERE stream_id=$6`, string(b), status, final, errCode, errMsg, streamID)
		return err
	}
	meta, _ := json.Marshal(metadata)
	_, err := r.pool.Exec(ctx, `
		UPDATE messages
		   SET blocks=(
		       SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb)
		         FROM jsonb_array_elements(COALESCE(messages.blocks, '[]'::jsonb)) AS elem
		        WHERE elem->>'x_source' IN ('a2a_timeline','local_result')
		        ) || (SELECT COALESCE(jsonb_agg(incoming),'[]'::jsonb)
                   FROM jsonb_array_elements($1::jsonb) incoming
                   WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(messages.blocks,'[]'::jsonb)) saved
                     WHERE saved->>'x_source'='local_result' AND saved->'local_artifact'=incoming->'local_artifact')),
		       status=$2, final=$3,
		       error_code=NULLIF($4,''), error_message=NULLIF($5,''),
		       metadata=$6::jsonb, updated_at=now()
		WHERE stream_id=$7`, string(b), status, final, errCode, errMsg, string(meta), streamID)
	return err
}

// UpdateStreamBlocks T2D.4 流式期间累计 blocks 写入; 不动 status/final/error_*。
func (r *Repo) UpdateStreamBlocks(ctx context.Context, streamID string, blocks []map[string]any) error {
	b, _ := json.Marshal(emptySliceIfNil(blocks))
	_, err := r.pool.Exec(ctx, `
		UPDATE messages
		   SET blocks=(
		       SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb)
		         FROM jsonb_array_elements(COALESCE(messages.blocks, '[]'::jsonb)) AS elem
		        WHERE elem->>'x_source' IN ('a2a_timeline','local_result')
		        ) || (SELECT COALESCE(jsonb_agg(incoming),'[]'::jsonb)
                   FROM jsonb_array_elements($1::jsonb) incoming
                   WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(messages.blocks,'[]'::jsonb)) saved
                     WHERE saved->>'x_source'='local_result' AND saved->'local_artifact'=incoming->'local_artifact')),
		       updated_at=now()
		WHERE stream_id=$2`, string(b), streamID)
	return err
}

func (r *Repo) GetByStreamID(ctx context.Context, streamID string) (*dom.Message, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
		       blocks, status, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,''),
		       parent_message_id, COALESCE(trace_id,''), metadata, event_logs, created_at, updated_at
		FROM messages WHERE stream_id=$1`, streamID)
	return scanRow(row)
}

// GetByUUID Batch 2E T2E.7: 群消息 before_uuid 分页用; 不存在 → apperr.ErrNotFound。
func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Message, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
		       blocks, status, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,''),
		       parent_message_id, COALESCE(trace_id,''), metadata, event_logs, created_at, updated_at
		FROM messages WHERE uuid=$1`, uuid)
	m, err := scanRow(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return m, nil
}

// ClaimAwaitingUserAndCreateNextRun ADR-0028 §4.3 — /chat/respond 专用单 PG transaction:
// SELECT ... FOR UPDATE 锁旧 awaiting_user message → INSERT 新 message_streams (state='active')
// → INSERT 新 messages (status='streaming') → UPDATE 旧 message 转 final + 合并 next ids metadata。
//
// 任一步 affected==0 / DB 抖动 → tx ROLLBACK + ErrNotFound (锁 0 行) 或 ErrInternal。
//
// 全部 INSERT/UPDATE 走同一 tx, 保证旧 message metadata 里的 next_stream_id /
// next_agent_message_uuid 必然指向真实存在的新 stream/新 message 行 (不悬空)。
func (r *Repo) ClaimAwaitingUserAndCreateNextRun(ctx context.Context, args dom.ClaimAndCreateNextRunArgs) (*dom.ClaimAndCreateNextRunResult, error) {
	if r == nil || r.pool == nil {
		return nil, apperr.ErrInternal.Withf("messages repo: pool nil")
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(context.Background())
		}
	}()

	// step A: SELECT FOR UPDATE 锁旧 awaiting_user message + JOIN conversations 校验。
	// 命中 0 行 → ErrNotFound (统一不泄漏)。
	var (
		oldMsgID   int64
		convID     int64
		convRoomID sql.NullInt64
	)
	err = tx.QueryRow(ctx, `
		SELECT m.id, conv.id, conv.room_id
		  FROM agent_bus.conversations conv
		  JOIN agent_bus.messages       m  ON m.conversation_id = conv.id
		 WHERE conv.tenant_id       = $1
		   AND conv.account_id      = $2
		   AND conv.uuid            = $3
		   AND conv.deleted_at IS NULL
		   AND m.tenant_id          = $1
		   AND m.uuid               = $4::uuid
		   AND m.role               = 'agent'
		   AND m.status             = 'awaiting_user'
		 FOR UPDATE OF m
	`, args.TenantID, args.AccountID, args.ConversationUUID, args.OldAgentMessageUUID).Scan(&oldMsgID, &convID, &convRoomID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// step B: INSERT 新 message_streams (state='active'; 字段对齐 schema 全部 NOT NULL 列)。
	if _, err := tx.Exec(ctx, `
		INSERT INTO agent_bus.message_streams (
		    stream_id, tenant_id, account_id, conversation_id, message_uuid,
		    cancel_token, bus_node_id, state, started_at, last_event_at
		) VALUES ($1, $2, $3, $4, $5::uuid, $6, $7, 'active', now(), now())
	`, args.NewStreamID, args.TenantID, args.AccountID, convID, args.NewAgentMessageUUID,
		args.CancelToken, args.BusNodeID); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// step C: INSERT 新 messages (status='streaming', stream_id=newStreamID, final=false)。
	// blocks/metadata/event_logs 初始空; sender_agent_id 来自 args.NewAgentID (0 → NULL)。
	var (
		newMsgID int64
		newUUID  string
	)
	{
		var senderAgentID any
		if args.NewAgentID > 0 {
			senderAgentID = args.NewAgentID
		}
		var roomID any
		if convRoomID.Valid {
			roomID = convRoomID.Int64
		}
		err = tx.QueryRow(ctx, `
			INSERT INTO agent_bus.messages (
			    uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
			    blocks, status, stream_id, final, parent_message_id, metadata, event_logs
			) VALUES (
			    $1::uuid, $2, $3, $7, 'agent', NULL, $4,
			    '[]'::jsonb, 'streaming', $5, false, $6, '{}'::jsonb, '[]'::jsonb
			)
			RETURNING id, uuid::text
		`, args.NewAgentMessageUUID, args.TenantID, convID, senderAgentID,
			args.NewStreamID, oldMsgID, roomID).Scan(&newMsgID, &newUUID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}

	// step D: UPDATE 旧 message → final + metadata 合并 next ids。 affected 必为 1 (已 FOR UPDATE)。
	if _, err := tx.Exec(ctx, `
		UPDATE agent_bus.messages
		   SET status     = 'final',
		       final      = true,
		       updated_at = now(),
		       metadata   = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
		           'responded_at',             to_jsonb(now()),
		           'responded_by_account_id',  to_jsonb($1::bigint),
		           'response_kind',            to_jsonb($2::text),
		           'next_stream_id',           to_jsonb($3::text),
		           'next_agent_message_uuid',  to_jsonb($4::text)
		       )
		 WHERE id = $5
	`, args.RespondedByAccountID, args.ResponseKind, args.NewStreamID, args.NewAgentMessageUUID, oldMsgID); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// commit; defer rollback 仅在 commit 失败时兜底。
	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed = true

	// commit 之后回读两行 (pool, 不依赖 tx); 失败仅返回部分信息, 不让 caller 误以为没 claim 成功。
	oldClaimed, _ := r.getByIDWithPool(ctx, oldMsgID)
	newRun, _ := r.getByIDWithPool(ctx, newMsgID)
	if newRun == nil {
		// 兜底: 至少把 caller 必需的标识填满。
		newRun = &dom.Message{
			ID:             newMsgID,
			UUID:           strings.TrimSpace(newUUID),
			TenantID:       args.TenantID,
			ConversationID: convID,
			RoomID: func() *int64 {
				if !convRoomID.Valid {
					return nil
				}
				v := convRoomID.Int64
				return &v
			}(),
			Role:     "agent",
			Status:   "streaming",
			StreamID: args.NewStreamID,
			Final:    false,
		}
	}
	return &dom.ClaimAndCreateNextRunResult{
		OldClaimed:     oldClaimed,
		NewRun:         newRun,
		ConversationID: convID,
	}, nil
}

// getByIDWithPool helper: 用 pool (不在 tx 内) 按 id 查; 单条 message claim helper commit
// 后回读用。失败返回 nil 不报错 (caller 已经认定 claim 成功; 回读失败不能否决)。
func (r *Repo) getByIDWithPool(ctx context.Context, id int64) (*dom.Message, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
		       blocks, status, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,''),
		       parent_message_id, COALESCE(trace_id,''), metadata, event_logs, created_at, updated_at
		FROM agent_bus.messages WHERE id = $1`, id)
	return scanRow(row)
}

func scanRow(row interface {
	Scan(dest ...any) error
}) (*dom.Message, error) {
	var m dom.Message
	var blocks, meta, logs []byte
	if err := row.Scan(&m.ID, &m.UUID, &m.TenantID, &m.ConversationID, &m.RoomID, &m.Role, &m.SenderAccountID, &m.SenderAgentID,
		&blocks, &m.Status, &m.StreamID, &m.Final, &m.ErrorCode, &m.ErrorMessage,
		&m.ParentMessageID, &m.TraceID, &meta, &logs, &m.CreatedAt, &m.UpdatedAt); err != nil {
		return nil, err
	}
	if len(blocks) > 0 {
		_ = json.Unmarshal(blocks, &m.Blocks)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &m.Metadata)
	}
	if len(logs) > 0 {
		_ = json.Unmarshal(logs, &m.EventLogs)
	}
	return &m, nil
}

func (r *Repo) History(ctx context.Context, f dom.HistoryFilter) ([]dom.Message, error) {
	limit := f.Limit
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	q := `SELECT id, uuid, tenant_id, conversation_id, room_id, role, sender_account_id, sender_agent_id,
	             blocks, status, COALESCE(stream_id,''), final, COALESCE(error_code,''), COALESCE(error_message,''),
	             parent_message_id, COALESCE(trace_id,''), metadata, event_logs, created_at, updated_at
		  FROM messages WHERE conversation_id=$1`
	args := []any{f.ConversationID}
	if f.After != nil {
		args = append(args, *f.After)
		q += ` AND created_at > $` + itoa(len(args))
	}
	if f.Before != nil {
		args = append(args, *f.Before)
		q += ` AND created_at < $` + itoa(len(args))
	}
	q += ` ORDER BY created_at DESC LIMIT ` + itoa(limit)
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Message
	for rows.Next() {
		m, err := scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *m)
	}
	// reverse to chronological
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, rows.Err()
}

func emptySliceIfNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func emptyMapIfNil(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	negative := false
	if n < 0 {
		negative = true
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if negative {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
