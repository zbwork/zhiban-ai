// Package room 客户端面 Bus API: rooms / room_participants / 群消息桥接 (Batch 2E)。
//
// 关键约束:
//   - 不读 ctx 身份: caller (account_id, tenant_id) 全部显式参数 (CLAUDE.md 硬规则)
//   - SendMessage 走 预检 → 事务 (SELECT FOR UPDATE + INSERT user message + bump
//     last_message_at) → commit → chat.RunAgentForConversation
//   - 群消息 fan-out 仅 caller 持有 stream_id; 其他成员看 history
package room

import "time"

// CallerCtx 调用方身份 (从 transport 层提取后显式传入)。
//
// DepartmentID + IsTenantAdmin 由 transport 层 (走 contacts.Service.IsTenantAdmin /
// ResolveCallerDepartment) 解析后填入, 用于 CanCreateGroup 预检 (T2E.2)。
type CallerCtx struct {
	AccountID     int64
	TenantID      int64
	DepartmentID  int64
	IsTenantAdmin bool
}

// CreateReq POST /api/agent-bus/v1/rooms 入参。
//
// 字段命名按 docs/contracts/agent-bus-client-contract.md §3 (camelCase, 与 2D `agent_uuid` 风格一致)。
// snake_case backend struct 用 json tag 显式标注。
type CreateReq struct {
	RoomKind         string             `json:"roomKind"` // 2E 仅接受 "group"
	Title            string             `json:"title"`
	Goal             string             `json:"goal,omitempty"`
	SpeakerPolicy    string             `json:"speakerPolicy"` // 2E 仅 "manual" / "manager"
	ManagerAgentUUID string             `json:"manager_agent_uuid,omitempty"`
	MaxRoundCount    int                `json:"max_round_count,omitempty"`
	Participants     []ParticipantInput `json:"participants"`
}

// ParticipantInput 入参中的一个 participant; id 是 account_uuid 或 digital_employee_uuid。
type ParticipantInput struct {
	Kind string `json:"kind"` // "human" / "agent"
	ID   string `json:"id"`   // uuid (account_uuid 或 digital_employee_uuid)
}

// RoomDTO 详情 / 创建响应里的 room 部分。
type RoomDTO struct {
	UUID             string           `json:"uuid"`
	ConversationUUID string           `json:"conversation_uuid"` // 与 room 一对一
	RoomKind         string           `json:"roomKind"`
	Title            string           `json:"title"`
	Goal             string           `json:"goal,omitempty"`
	SpeakerPolicy    string           `json:"speakerPolicy"`
	ManagerAgentUUID string           `json:"manager_agent_uuid,omitempty"`
	MaxRoundCount    int              `json:"max_round_count"`
	RoundCount       int              `json:"round_count"`
	Status           string           `json:"status"`
	Participants     []ParticipantDTO `json:"participants"`
	CreatedAt        time.Time        `json:"created_at"`

	// P2.3a (ADR-0026): WuKong group channel link; 客户端按 kind=group 用它打开 WuKong 群 pane。
	WuKongChannelID   string `json:"wukong_channel_id,omitempty"`
	WuKongChannelType int    `json:"wukong_channel_type,omitempty"`

	// P2.3a: 群主(创建者)account uuid; 客户端群成员面板据此标「群主」。
	CreatorAccountUUID string `json:"creator_account_uuid,omitempty"`
}

// ParticipantDTO 详情中的 participant; 对外只暴露 participant_uuid (不暴露 BIGINT id)。
type ParticipantDTO struct {
	ParticipantUUID string              `json:"participant_uuid"`
	Kind            string              `json:"kind"` // "human" / "agent"
	ID              string              `json:"id"`   // human → account_uuid; agent → digital_employee_uuid
	DisplayName     string              `json:"displayName,omitempty"`
	Avatar          string              `json:"avatar,omitempty"` // P2.3a: 群成员面板 / 九宫格头像
	Email           string              `json:"email,omitempty"`
	DepartmentName  string              `json:"department_name,omitempty"`
	CompanyName     string              `json:"company_name,omitempty"`
	RoleInRoom      string              `json:"role_in_room"`
	CanDirectChat   bool                `json:"can_direct_chat,omitempty"`
	Skills          []AgentSkillSummary `json:"skills,omitempty"`
}

// AgentSkillSummary is the display-only subset exposed to members of the same active room.
type AgentSkillSummary struct {
	Name string `json:"name"`
	Slug string `json:"slug,omitempty"`
}

// AddParticipantsReq POST /rooms/{uuid}/participants 入参。
type AddParticipantsReq struct {
	Participants []ParticipantInput `json:"participants"`
}

// SendMessageReq POST /rooms/{uuid}/messages 入参。
//
// M6 Phase A 新增 ComposerSkillUUID + ComposerParams: 与 chat.SendReq 同款语义.
// 群聊场景的 Skill 协同 (转交 / A2A) 留 M5 完整版; Phase A 仅透传到 user message
// metadata, agent 自己消费.
type SendMessageReq struct {
	Blocks            []map[string]any `json:"blocks,omitempty"`
	ModelHint         string           `json:"model_hint,omitempty"`
	Text              string           `json:"text"`
	ComposerSkillUUID string           `json:"composer_skill_uuid,omitempty"`
	ComposerParams    map[string]any   `json:"composer_params,omitempty"`
	FileUUIDs         []string         `json:"file_uuids,omitempty"`
}

// SendMessageResp 响应。
type SendMessageResp struct {
	ConversationUUID string   `json:"conversation_uuid"`
	UserMessageUUID  string   `json:"user_message_uuid"`
	StreamIDs        []string `json:"stream_ids"`
}

// ListMessagesReq GET /rooms/{uuid}/messages query。
type ListMessagesReq struct {
	Limit      int    `json:"limit"`
	BeforeUUID string `json:"before_uuid"`
}

// MessageDTO 群消息历史响应单条。
type MessageDTO struct {
	UUID            string         `json:"uuid"`
	Role            string         `json:"role"`
	Status          string         `json:"status"`
	Blocks          []any          `json:"blocks"`
	Metadata        map[string]any `json:"metadata,omitempty"`
	CreatedAt       time.Time      `json:"created_at"`
	SenderAccountID *int64         `json:"-"`
	SenderAgentID   *int64         `json:"-"`
}
