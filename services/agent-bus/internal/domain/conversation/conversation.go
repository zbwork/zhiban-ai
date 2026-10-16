package conversation

import (
	"context"
	"time"
)

// Conversation 一个用户与一个 Agent（或群）的会话。
type Conversation struct {
	ID                int64
	UUID              string
	TenantID          int64
	AccountID         int64
	DigitalEmployeeID *int64
	RoomID            *int64
	Title             string
	Source            string
	LastMessageAt     *time.Time
	UnreadCount       int
	Metadata          map[string]any
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// Filter 列表过滤。
type Filter struct {
	AccountID int64
	TenantID  int64
	Limit     int
	Offset    int
}

// ListItem Batch 2E T2E.7B: 单聊行 + 群行混排, 按 COALESCE(last_message_at, created_at) DESC 统一排序。
//
// Kind 指明该行类型 ("single" / "group"); group 行携带 room_uuid / room_kind / room_title。
//
// Round-7 P2-2: 增 CAS (conversation_account_state) 字段, 由 repo SQL LEFT JOIN 填充.
// 这样 SQL 层就能直接基于 hidden_at 过滤 / 计 total, 不再走"先分页再内存过滤".
type ListItem struct {
	Conversation
	Kind                string // 统一会话 kind: "human_direct" / "agent_direct" / "group" / "single"(legacy 无 room)
	RoomUUID            string
	RoomKind            string // "direct" / "group"; 仅 room-bound 时非空
	RoomTitle           string
	CanRenameGroup      bool // caller 是否具备群改名能力;当前仅 active creator 为 true
	Hidden              bool // round-7 P2-2: caller 是否对该 conversation 设了 hidden_at
	ClearedAt           *time.Time
	LastReadMessageUUID string // round-7 P2-2: caller last_read_message_uuid; 空串=未读过
	LastReadAt          *time.Time
	UnreadSnapshot      int // round-7 P2-2: CAS 持久化 unread_snapshot (与 unread_count 区分)
	// F09 P2 「会话列表操作菜单 v2」 (migration 000035) -- per-account 视图态:
	Pinned       bool       // pinned_at IS NOT NULL: 该 account 把该 conversation 置顶
	PinnedAt     *time.Time // 用于 ORDER BY pinned_at DESC tie-break
	Muted        bool       // muted_at IS NOT NULL: 该 account 对该 conversation 免打扰
	MarkedUnread bool       // marked_unread_at IS NOT NULL: 人工标为未读 (与 unread_count 独立)

	// P2.1(ADR-0026)统一会话索引扩展:
	WuKongChannelID   string        // rooms.wukong_channel_id;direct/group 1:1;human_direct 客户端用它进 WuKong pane
	WuKongChannelType int           // 恒 2(group)
	Participants      []Participant // 从 room_participants 聚合(成员/标题/头像/可见性真理,非 room_direct_pairs)
	Avatar            string        // 会话展示头像:direct=对端(非自己)头像;agent_direct=agent 头像;group 暂空。从 room_participants 取
	AgentUUID         string        // legacy single 数字员工会话: conversations.digital_employee_id -> digital_employees.uuid
	AgentName         string        // legacy single 数字员工会话: canonical agent name, 覆盖旧 title 占位
	AgentAvatar       string        // legacy single 数字员工会话: canonical agent avatar
	AgentPosition     string        // legacy single 数字员工会话: position_label
	AgentDepartment   string        // legacy single 数字员工会话: workspace_id -> departments.name
	AgentDeleted      bool          // 数字员工单聊目标已软删; 历史身份仍保留, 客户端据此只读
	LastMessageText   string        // 本地 messages 表最近一条有文本消息; room/WuKong 同步失败时作为回退
	LastMessageTS     *time.Time    // LastMessageText 对应消息时间
}

// Participant · 会话成员(P2.1;从 room_participants 聚合)。
type Participant struct {
	Kind        string `json:"kind"`         // "human" / "agent"
	AccountUUID string `json:"account_uuid"` // human
	AgentUUID   string `json:"agent_uuid"`   // agent
	DisplayName string `json:"display_name"`
	Avatar      string `json:"avatar"`
	Email       string `json:"email,omitempty"`
	CompanyName string `json:"company_name,omitempty"`
	// DepartmentName 客户端聊天顶栏副标题展示。
	// 人:tenant_memberships.department_id → departments.name; agent:digital_employees.workspace_id → departments.name。
	DepartmentName string `json:"department_name,omitempty"`
}

type Repository interface {
	GetByID(ctx context.Context, id int64) (*Conversation, error)
	GetByUUID(ctx context.Context, uuid string) (*Conversation, error)
	AccessibleByAccount(ctx context.Context, tenantID, accountID int64, uuid string) (bool, error)
	Create(ctx context.Context, c *Conversation) (*Conversation, error)
	UpdateTitle(ctx context.Context, id int64, title string) error
	BumpLastMessage(ctx context.Context, id int64, ts time.Time) error
	List(ctx context.Context, f Filter) ([]Conversation, int64, error)
	Delete(ctx context.Context, id int64) error

	// FindActiveSingle Batch 2D T2D.2: 查 (tenant, account, digital_employee) 复合维度下唯一活跃 single-chat
	// (room_id IS NULL AND digital_employee_id IS NOT NULL AND deleted_at IS NULL)。
	//
	// 用于 chat.Send 不带 conversation_uuid 时复用语义 (plan §4.5):
	//   - 找到 → 复用同一 conversation, 客户端"再开一次对话"自动落到老会话上
	//   - 找不到 (apperr.ErrNotFound) → 调用方走 Create
	//
	// 排序: last_message_at DESC NULLS LAST → created_at DESC; LIMIT 1。Batch 2D 不引入
	// pinned_at / archived_at, 唯一性靠应用层 + T2D.9 的 partial unique index 加固。
	FindActiveSingle(ctx context.Context, tenantID, accountID, digitalEmployeeID int64) (*Conversation, error)

	// UpdateMetadataKeys (Plan 16 Phase 2 / ZAP chat MVP):
	// metadata JSONB 合并 patch 已通过白名单的 keys。SQL 守卫:
	//   tenant_id=$1 AND account_id=$2 AND id=$3 AND deleted_at IS NULL AND room_id IS NULL
	// 仅 single-chat (room_id IS NULL) 用; 群聊会话不允许走该 helper。
	// 白名单 (禁止写 session_token / runtime_api_key / authorization 等敏感字段) 由
	// chat service 层包一层 wrapper 强制, 本接口默认信任 keys。
	UpdateMetadataKeys(ctx context.Context, tenantID, accountID, conversationID int64, keys map[string]any) error

	// ListForAccount Batch 2E T2E.7B: 单聊 + active-参与的 group room conversations 混排。
	//
	// 单聊 row: c.account_id = $accountID AND c.room_id IS NULL (caller 自己的 single-chat)
	// 群 row : c.room_id IS NOT NULL AND EXISTS active human room_participant 是 caller
	// 排序: COALESCE(last_message_at, created_at) DESC
	//
	// Round-7 P2-2:
	//   - LEFT JOIN conversation_account_state 填充 ListItem.Hidden / LastReadMessageUUID / UnreadSnapshot.
	//   - includeHidden=false (默认) → SQL WHERE 过滤 cas.hidden_at IS NOT NULL, total 也是过滤后的 count.
	//   - includeHidden=true  → 全量返回 (含 hidden), client query `?include_hidden=1` 使用.
	ListForAccount(ctx context.Context, tenantID, accountID int64, limit, offset int, includeHidden bool) ([]ListItem, int64, error)
}

// ZapLiveSession 一条仍在有效期内的 ZAP runtime 会话 (metadata.zap_session_id / zap_session_expires_at),
// 供 ZAP-1.1 §11.3 技能 resync 定位要推送的会话。不含 token。
type ZapLiveSession struct {
	ConversationID int64
	AccountID      int64
	SessionID      string
}
