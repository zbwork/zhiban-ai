package drive

// cmf.go — F06 Phase 2.3 / F09 §3 conversation_message_files domain types.
//
// cmf 是 chat 消息 ↔ drive 文件的中间表 (每条 chat message 内 0..N 附件 → 0..N cmf 行).
// 详 sql/postgres/000116_f09_conversation_message_files.up.sql.

import "time"

// CMFRole 与 conversation_message_files.role CHECK 对齐.
type CMFRole string

const (
	CMFRoleUserInput           CMFRole = "user_input"
	CMFRoleAssistantAttachment CMFRole = "assistant_attachment"
	CMFRoleSystem              CMFRole = "system"
	CMFRoleAgentOutput         CMFRole = "agent_output"
)

// CMFRow F09 §3 conversation_message_files 一行的领域表征.
type CMFRow struct {
	ID               int64
	UUID             string
	TenantID         int64
	ConversationUUID string
	MessageUUID      string
	AccountID        int64
	Role             CMFRole
	DriveFileUUID    string

	CreatedAt time.Time
	CreatedBy *int64
	UpdatedAt time.Time
	UpdatedBy *int64
	IsDeleted bool
	DeletedAt *time.Time
}

// CreateCMFInput F09 §3: chat client 上传完 drive 文件后 INSERT cmf 行的入参.
// 本 phase 不直接对外暴露 endpoint 用此结构, 但保留供后续 chat upload integration 用.
type CreateCMFInput struct {
	TenantID         int64
	ConversationUUID string
	MessageUUID      string
	AccountID        int64
	Role             CMFRole
	DriveFileUUID    string
	CreatedBy        int64
}
