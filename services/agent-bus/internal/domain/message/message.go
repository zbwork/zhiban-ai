package message

import (
	"context"
	"time"
)

// Message 一条消息，content 用 EMP Block 数组。
type Message struct {
	ID              int64
	UUID            string
	TenantID        int64
	ConversationID  int64
	RoomID          *int64
	Role            string // user / agent / system / tool
	SenderAccountID *int64
	SenderAgentID   *int64
	Blocks          []map[string]any // EMP Block 数组
	Status          string           // streaming/final/cancelled/failed
	StreamID        string
	Final           bool
	ErrorCode       string
	ErrorMessage    string
	ParentMessageID *int64
	TraceID         string
	Metadata        map[string]any
	EventLogs       []map[string]any
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// HistoryFilter 列表过滤。
type HistoryFilter struct {
	ConversationID int64
	Limit          int
	After          *time.Time
	Before         *time.Time
}

type Repository interface {
	Append(ctx context.Context, m *Message) (*Message, error)

	// UpdateStream Batch 2D T2D.4: 终态 / 错误态写入。
	// blocks 为终态累计 blocks; status ∈ {final, failed, cancelled, awaiting_user};
	// metadata 含 usage 等终结性元数据 (nil 表示不更新 metadata)。
	UpdateStream(ctx context.Context, streamID string, blocks []map[string]any, status string, final bool, errCode, errMsg string, metadata map[string]any) error

	// UpdateStreamBlocks Batch 2D T2D.4: streaming 期间逐 delta 写入 blocks 快照,
	// **不**改 status / final / error_*; 用于 SSE delta 与 DB blocks 保持一致 (T2D.4 §3)。
	UpdateStreamBlocks(ctx context.Context, streamID string, blocks []map[string]any) error

	GetByStreamID(ctx context.Context, streamID string) (*Message, error)
	History(ctx context.Context, f HistoryFilter) ([]Message, error)

	// GetByUUID Batch 2E T2E.7: 群消息历史按 before_uuid 分页时, 需要先查 cursor message 的
	// created_at 再查更早的; 不存在 → ErrNotFound (不区分跨 conversation 透露)。
	GetByUUID(ctx context.Context, uuid string) (*Message, error)

	// ClaimAwaitingUserAndCreateNextRun (ADR-0028 §4.3) — /chat/respond 专用单 PG transaction:
	//
	//   1) SELECT ... FOR UPDATE 锁旧 awaiting_user agent message
	//      + JOIN conversations 校验 tenant/account/uuid/room_id IS NULL/deleted_at IS NULL;
	//      + 校验 message.tenant_id/role='agent'/status='awaiting_user';
	//      命中 0 行 → 整 tx ROLLBACK, 返 apperr.ErrNotFound (统一不泄漏 conv/msg/role 存在性)。
	//   2) INSERT message_streams (newStreamID, state='active', 全部 NOT NULL 列对齐 schema);
	//   3) INSERT 新 messages (uuid=newAgentMessageUUID, role='agent', status='streaming',
	//      stream_id=newStreamID, final=false, parent_message_id=oldMsgID, blocks=[], metadata={});
	//   4) UPDATE 旧 message → status='final', final=true,
	//      metadata 合并 responded_at / responded_by_account_id / response_kind /
	//      next_stream_id=newStreamID / next_agent_message_uuid=newAgentMessageUUID。
	//
	// tx commit 成功 → 旧 message metadata 里的 next ids 必然指向同事务 INSERT 的真实行,
	// **不悬空**。tx 失败 → ROLLBACK, 旧 message 保持 awaiting_user, 无新 stream/message 行。
	ClaimAwaitingUserAndCreateNextRun(ctx context.Context, args ClaimAndCreateNextRunArgs) (*ClaimAndCreateNextRunResult, error)
}

// ClaimAndCreateNextRunArgs ADR-0028 §4.3 helper 入参。
type ClaimAndCreateNextRunArgs struct {
	TenantID             int64
	AccountID            int64  // caller; SQL JOIN conversations.account_id 守卫 + 写 message_streams.account_id
	ConversationUUID     string // SQL JOIN conversations.uuid 守卫
	OldAgentMessageUUID  string // 即将 claim 的 awaiting_user message uuid
	RespondedByAccountID int64  // = AccountID; 留参数显式以便审计
	ResponseKind         string // approval | confirm | form | action

	NewStreamID         string // service 层 RandomHex 生成, helper 内 INSERT (UNIQUE)
	NewAgentMessageUUID string // service 层 uuid.New 生成, helper 内 INSERT 至
	// messages.uuid 与 message_streams.message_uuid (1:1, 因
	// message_streams_message_uuid_key UNIQUE 约束)
	CancelToken string // service 层 RandomHex 生成; 写 message_streams.cancel_token
	BusNodeID   string // = chat.Service.NodeID(); 写 message_streams.bus_node_id

	// 新 agent message 的辅助字段。NewAgentID 对齐 messages.sender_agent_id (即 digital_employees.id),
	// 由 service 层从 conv.DigitalEmployeeID / dispatcher 入参解析后传入; 为 0 时写 NULL。
	NewAgentID int64
}

// ClaimAndCreateNextRunResult ADR-0028 §4.3 helper 返回值。
type ClaimAndCreateNextRunResult struct {
	OldClaimed     *Message // 旧 awaiting_user message, 转 final 后的最新行
	NewRun         *Message // 新创建的 agent 预留行, status='streaming'
	ConversationID int64    // step A SELECT FOR UPDATE 返回的 conv.id, 供 service 层透给 dispatcher
}
