// Package convstate · conversation_account_state per-account 视图态.
//
// v1 (000037): hidden_at / last_read_* / unread_snapshot.
// v3 (000040): cleared_at 清空本端历史水位. 行为:
//   - DELETE /chat/conversations/{uuid} → upsert cleared_at=now(), hidden_at=now();
//   - POST /chat/conversations/{uuid}/read → upsert last_read_message_uuid / last_read_at + 清 marked_unread_at.
//
// v2 (000035): pinned_at / muted_at / marked_unread_at. 见 docs/contracts §「会话列表操作菜单 v2」.
//
// 不在本包: list join (聚合在 repository/postgres/conversation 的 ListForAccount).
package convstate

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// SetHidden 上传 caller 对该 conversation 的 hidden_at=now(); 后续收到新消息可再
// upsert hidden_at=NULL (由 chat fanout 处理; Phase A 不实现自动恢复).
func (r *Repo) SetHidden(ctx context.Context, accountID, tenantID int64, conversationUUID string) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id, hidden_at, unread_snapshot, updated_at)
		 VALUES ($1, $2::uuid, $3, now(), 0, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET hidden_at = now(), unread_snapshot = 0, tenant_id = EXCLUDED.tenant_id, updated_at = now()`,
		accountID, conversationUUID, tenantID,
	)
	return err
}

// ClearHistory 清空 caller 本端历史并隐藏会话列表项。
//
// 只写 conversation_account_state.cleared_at/hidden_at, 不删除全局 messages/conversations/rooms,
// 不影响其他参与者。重新从通讯录/数字员工入口打开时 ClearHidden 只清 hidden_at, 保留 cleared_at。
func (r *Repo) ClearHistory(ctx context.Context, accountID, tenantID int64, conversationUUID string) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state
		     (account_id, conversation_uuid, tenant_id, hidden_at, cleared_at, unread_snapshot, marked_unread_at, updated_at)
		 VALUES ($1, $2::uuid, $3, now(), now(), 0, NULL, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET hidden_at = now(),
		     cleared_at = now(),
		     unread_snapshot = 0,
		     marked_unread_at = NULL,
		     tenant_id = EXCLUDED.tenant_id,
		     updated_at = now()`,
		accountID, conversationUUID, tenantID,
	)
	return err
}

// ClearHidden 清 caller 对该 conversation 的 hidden_at。
// 用于「不显示」后从通讯录 / 搜索重新打开同一会话时恢复左侧列表可见性。
func (r *Repo) ClearHidden(ctx context.Context, accountID, tenantID int64, conversationUUID string) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id, hidden_at, unread_snapshot, updated_at)
		 VALUES ($1, $2::uuid, $3, NULL, 0, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET hidden_at = NULL, tenant_id = EXCLUDED.tenant_id, updated_at = now()`,
		accountID, conversationUUID, tenantID,
	)
	return err
}

// AccountConvState · LEFT JOIN payload for conv list (v1 + v2).
type AccountConvState struct {
	ConversationUUID    string
	HiddenAt            *time.Time
	ClearedAt           *time.Time
	LastReadMessageUUID string
	LastReadAt          *time.Time
	UnreadSnapshot      int
	PinnedAt            *time.Time
	MutedAt             *time.Time
	MarkedUnreadAt      *time.Time
}

// ListForAccount · 拉 caller 名下所有 conversation_account_state 行, 让 chat list handler
// 做 LEFT JOIN (in-memory) 合并 hidden / last_read / unread / pinned / muted / marked_unread.
//
// 不做按 conversation_uuid 列过滤 (列表 ≤ 20 条/分页, account 自己的行通常 < 1000).
func (r *Repo) ListForAccount(ctx context.Context, accountID, tenantID int64) ([]AccountConvState, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT conversation_uuid::text, hidden_at, cleared_at,
		        COALESCE(last_read_message_uuid::text, ''), last_read_at, unread_snapshot,
		        pinned_at, muted_at, marked_unread_at
		   FROM conversation_account_state
		  WHERE account_id=$1 AND tenant_id=$2`,
		accountID, tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AccountConvState, 0)
	for rows.Next() {
		var s AccountConvState
		var hidden, cleared, lastRead, pinned, muted, markedUnread *time.Time
		var lastReadMsg string
		if err := rows.Scan(&s.ConversationUUID, &hidden, &cleared, &lastReadMsg, &lastRead, &s.UnreadSnapshot,
			&pinned, &muted, &markedUnread); err != nil {
			return nil, err
		}
		s.HiddenAt = hidden
		s.ClearedAt = cleared
		s.LastReadAt = lastRead
		s.LastReadMessageUUID = lastReadMsg
		s.PinnedAt = pinned
		s.MutedAt = muted
		s.MarkedUnreadAt = markedUnread
		out = append(out, s)
	}
	return out, rows.Err()
}

// ClearedAt 返回 caller 对某会话的清空历史水位。无 CAS 行或未清空时返回 nil。
func (r *Repo) ClearedAt(ctx context.Context, accountID, tenantID int64, conversationUUID string) (*time.Time, error) {
	var clearedAt *time.Time
	err := r.pool.QueryRow(ctx,
		`SELECT cleared_at
		   FROM conversation_account_state
		  WHERE account_id=$1 AND tenant_id=$2 AND conversation_uuid=$3::uuid`,
		accountID, tenantID, conversationUUID,
	).Scan(&clearedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return clearedAt, nil
}

// MarkRead 写 last_read_message_uuid + last_read_at + 清 unread_snapshot + 清 marked_unread_at.
//
// v2: 标为未读与已读互斥, 故 markRead 同时清 marked_unread_at.
// v3 (000036): 同时收 lastReadMessageSeq, 写 last_read_message_seq 水位 (多端取较大者).
//   - lastReadMessageSeq <= 0 → 不动列, 兼容只用 uuid 的旧调用 / 客户端尚未 ack 的 seq=0.
//   - 现有列 last_read_message_seq IS NULL 或 < 新值 → 写新值; 否则保留旧值 (防回退).
func (r *Repo) MarkRead(ctx context.Context, accountID, tenantID int64, conversationUUID string, lastReadMessageUUID string, lastReadMessageSeq int64) error {
	var msgArg any
	if lastReadMessageUUID != "" {
		msgArg = lastReadMessageUUID
	}
	var seqArg any
	if lastReadMessageSeq > 0 {
		seqArg = lastReadMessageSeq
	}
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id,
		     last_read_message_uuid, last_read_at, last_read_message_seq, unread_snapshot, marked_unread_at, updated_at)
		 VALUES ($1, $2::uuid, $3, $4::uuid, now(), $5, 0, NULL, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET last_read_message_uuid = COALESCE($4::uuid, conversation_account_state.last_read_message_uuid),
		     last_read_at = now(),
		     last_read_message_seq = GREATEST(
		         COALESCE(conversation_account_state.last_read_message_seq, 0),
		         COALESCE($5::bigint, 0)
		     ),
		     unread_snapshot = 0,
		     marked_unread_at = NULL,
		     tenant_id = EXCLUDED.tenant_id,
		     updated_at = now()`,
		accountID, conversationUUID, tenantID, msgArg, seqArg,
	)
	_ = time.Now // ensure time import is used (unread_snapshot reset placeholder)
	return err
}

// IsRecentlyRead 判断 account 是否在 within 时间窗口内标过该会话已读——用作
// "正在看这个会话"的近似信号(2026-08-10,见 wukongwh.RecentReadChecker)。
// 无 CAS 行 / 从未标过已读 → false, 不报错(未读跟"读得太久以前"同等对待)。
func (r *Repo) IsRecentlyRead(ctx context.Context, tenantID, accountID int64, conversationUUID string, within time.Duration) (bool, error) {
	var recent bool
	err := r.pool.QueryRow(ctx,
		`SELECT last_read_at IS NOT NULL AND last_read_at >= now() - make_interval(secs => $4::double precision)
		   FROM conversation_account_state
		  WHERE account_id=$1 AND tenant_id=$2 AND conversation_uuid=$3::uuid`,
		accountID, tenantID, conversationUUID, within.Seconds(),
	).Scan(&recent)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return recent, nil
}

// MemberLastReadSeq · F09 P1 read-receipts: 单个 account 在某 conversation 上的 last_read_message_seq.
// 0 = NULL / 未上报过.
type MemberLastReadSeq struct {
	AccountID          int64
	LastReadMessageSeq int64
}

// ListReadSeqsByConversation 拉 conversation 上所有有 CAS 行的 account 的 last_read_message_seq.
//
// 用于 GET /chat/conversations/{uuid}/read-receipts: service 拿到 active human participants
// 列表后, 用本方法批量拿全员水位, 比对目标 message_seq 算 read / unread.
//
// 注意: 没有 CAS 行的 participant (从未打开过会话) → 默认水位 0, 永远算未读, service 层兜底,
// 本方法只返已落库的行.
func (r *Repo) ListReadSeqsByConversation(ctx context.Context, tenantID int64, conversationUUID string) ([]MemberLastReadSeq, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT account_id, COALESCE(last_read_message_seq, 0)
		   FROM conversation_account_state
		  WHERE tenant_id=$1 AND conversation_uuid=$2::uuid`,
		tenantID, conversationUUID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MemberLastReadSeq, 0)
	for rows.Next() {
		var m MemberLastReadSeq
		if err := rows.Scan(&m.AccountID, &m.LastReadMessageSeq); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListActiveHumanParticipantAccountIDs 返回某会话当前 active human 成员账号 ID。
//
// 用于已读水位变更后的账号级 SSE fanout:读者上报 read watermark 后,Bus 通知同会话其它
// human 端重新拉自己的 sent message receipts。这里不返回 agent/BOT,也不返回 left_at 已离开成员。
func (r *Repo) ListActiveHumanParticipantAccountIDs(ctx context.Context, tenantID int64, conversationUUID string) ([]int64, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT rp.account_id
		  FROM conversations c
		  JOIN rooms r ON r.id = c.room_id AND r.deleted_at IS NULL
		  JOIN room_participants rp ON rp.room_id = r.id
		                           AND rp.kind = 'human'
		                           AND rp.left_at IS NULL
		                           AND rp.account_id IS NOT NULL
		 WHERE c.uuid = $1::uuid
		   AND c.tenant_id = $2
		   AND c.deleted_at IS NULL
		   AND c.room_id IS NOT NULL`,
		conversationUUID, tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]int64, 0)
	for rows.Next() {
		var accountID int64
		if err := rows.Scan(&accountID); err != nil {
			return nil, err
		}
		out = append(out, accountID)
	}
	return out, rows.Err()
}

// SetPinned · v2: 置顶 / 取消置顶. pinned=true 写 now(); false 清 NULL.
func (r *Repo) SetPinned(ctx context.Context, accountID, tenantID int64, conversationUUID string, pinned bool) error {
	var pinArg any
	if pinned {
		pinArg = time.Now().UTC()
	}
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id, pinned_at, updated_at)
		 VALUES ($1, $2::uuid, $3, $4, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET pinned_at = $4,
		     tenant_id = EXCLUDED.tenant_id,
		     updated_at = now()`,
		accountID, conversationUUID, tenantID, pinArg,
	)
	return err
}

// SetMuted · v2: 免打扰 / 取消免打扰. muted=true 写 now(); false 清 NULL.
func (r *Repo) SetMuted(ctx context.Context, accountID, tenantID int64, conversationUUID string, muted bool) error {
	var muteArg any
	if muted {
		muteArg = time.Now().UTC()
	}
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id, muted_at, updated_at)
		 VALUES ($1, $2::uuid, $3, $4, now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET muted_at = $4,
		     tenant_id = EXCLUDED.tenant_id,
		     updated_at = now()`,
		accountID, conversationUUID, tenantID, muteArg,
	)
	return err
}

// SetMarkedUnread · v2: 人工标为未读 (无 toggle false; 取消由 markRead / 新消息自动清).
// 与 markRead 互斥; 调用方应在 markRead 前/后逻辑里不会同时 set marked_unread.
func (r *Repo) SetMarkedUnread(ctx context.Context, accountID, tenantID int64, conversationUUID string) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO conversation_account_state (account_id, conversation_uuid, tenant_id, marked_unread_at, updated_at)
		 VALUES ($1, $2::uuid, $3, now(), now())
		 ON CONFLICT (account_id, conversation_uuid) DO UPDATE
		 SET marked_unread_at = now(),
		     tenant_id = EXCLUDED.tenant_id,
		     updated_at = now()`,
		accountID, conversationUUID, tenantID,
	)
	return err
}
