// Package room 定义群聊 room / room_participants 的领域模型与仓储接口 (Batch 2E)。
//
// 范围:
//   - 仅暴露 group room 所需字段; direct (人 1v1) room 留 M5 完整版
//   - role_in_room 仅 'member' / 'manager' / 'observer' (现有 schema CHECK)
//   - "owner" 概念由 rooms.creator_id 承担, 不写 role_in_room='owner'
//   - speaker_policy 在 service 层校验 ('manual' / 'manager'); DB CHECK 仍允许 6 值
//     (避免 M5 完整版反向 migration)
package room

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// MaxParticipants Batch 2E §4.3 / Q11: 群成员上限默认 50, 包含 caller。
//
// 强制点:
//   - service.resolveParticipants 在 Create / AddParticipant 入口先做"caller + 入参 ≤ MaxParticipants"
//     级别校验, 给前端清晰错误
//   - repo.AddParticipant tx 内 SELECT FOR UPDATE 后再次 count active participants;
//     新插入 (非幂等命中) 时若 count >= MaxParticipants 拒绝, 防止并发 invite 绕过
//
// future: 接 AGBUS_ROOM_MAX_PARTICIPANTS env override 时, 把这个 const 改为 service 层注入参数。
const MaxParticipants = 50

// Kind room_kind 取值。
type Kind string

const (
	KindGroup  Kind = "group"
	KindDirect Kind = "direct" // 留 M5 完整版; 2E service 层拒绝
)

// SpeakerPolicy 与 DB rooms.speaker_policy CHECK 取值对齐.
//
// Phase A (2E) 仅 manual / manager; F09 Phase B PR6 起补 round_robin / auto_llm /
// parallel / handoff 共 6 策略 (F09 v1.1 §4.5 + D14).
type SpeakerPolicy string

const (
	PolicyManual     SpeakerPolicy = "manual"
	PolicyManager    SpeakerPolicy = "manager"
	PolicyRoundRobin SpeakerPolicy = "round_robin"
	PolicyAutoLLM    SpeakerPolicy = "auto_llm"
	PolicyParallel   SpeakerPolicy = "parallel"
	PolicyHandoff    SpeakerPolicy = "handoff"
)

// ParticipantKind room_participants.kind 取值。
type ParticipantKind string

const (
	ParticipantHuman ParticipantKind = "human"
	ParticipantAgent ParticipantKind = "agent"
)

// RoleInRoom role_in_room CHECK 三值 (member / manager / observer);
// 不含 owner: 创建者权限走 rooms.creator_id 字段。
type RoleInRoom string

const (
	RoleMember   RoleInRoom = "member"
	RoleManager  RoleInRoom = "manager"
	RoleObserver RoleInRoom = "observer"
)

// Room 群聊房间领域对象。
type Room struct {
	ID                  int64
	UUID                string
	TenantID            int64
	CreatorID           int64
	RoomKind            Kind
	Title               string
	Goal                string
	SpeakerPolicy       SpeakerPolicy
	SpeakerPolicyConfig map[string]any
	ManagerAgentID      *int64
	MaxRoundCount       int
	MaxA2ADepth         int
	RoundCount          int
	Status              string // 'active' / 'paused' / 'completed' / 'archived'
	Metadata            map[string]any
	CreatedAt           time.Time
	UpdatedAt           time.Time
	DeletedAt           *time.Time

	// ADR-0026: WuKong channel link (direct/group 1:1)。空串 / 0 = 未链接。
	WuKongChannelID   string
	WuKongChannelType int
}

// Participant 群成员; (kind=human → AccountID 必填) 与 (kind=agent → AgentID 必填) 二选一,
// schema CHECK 已强制。
type Participant struct {
	ID         int64
	UUID       string
	RoomID     int64
	Kind       ParticipantKind
	AccountID  *int64
	AgentID    *int64
	RoleInRoom RoleInRoom
	JoinedAt   time.Time
	LeftAt     *time.Time
}

// CreateInput 创建 room 的最小入参 (Batch 2E 仅支持 KindGroup; direct 留 M5)。
type CreateInput struct {
	TenantID            int64
	CreatorID           int64
	RoomKind            Kind
	Title               string
	Goal                string
	SpeakerPolicy       SpeakerPolicy
	ManagerAgentID      *int64
	MaxRoundCount       int                // 0 → 走 schema default 100
	Participants        []ParticipantInput // 不含 caller, repo 内自动追加 caller 行
	SpeakerPolicyConfig map[string]any

	// P2.3a(ADR-0026):WuKong group channel link。RoomUUID 可由 service 预生成
	// (provision-after-auth:校验通过后、写库前先 EnsureForGroup 派生 channel),
	// 空则走 schema 默认 gen_random_uuid();WuKongChannelID 空则不写 link 列。
	RoomUUID          string
	WuKongChannelID   string
	WuKongChannelType int
}

// ParticipantInput 入参 (从 service 层组装, 已经过 CanCreateGroup 预检 / DB 复查)。
type ParticipantInput struct {
	Kind       ParticipantKind
	AccountID  *int64
	AgentID    *int64
	RoleInRoom RoleInRoom // 留空则 repo 默认 'member'
}

// Repository 仓储接口 (Batch 2E)。
type Repository interface {
	// CreateGroup 在事务内一次性写: rooms 行 + 全部 participants 行 + 1 条 conversation;
	// 返回 (room, conversationID, error)。conversationID 由 conversations.id 出, service 层
	// 再自己 GetByUUID 拿 UUID。任意一步失败整事务回滚。
	//
	// caller (in.CreatorID) 自动追加为 participant (kind='human', role='member')。
	CreateGroup(ctx context.Context, in CreateInput) (*Room, int64, error)

	// GetByUUID 取 room 详情 (含未删除); 不带 participants (单独走 ListParticipants)。
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*Room, error)

	// GetByID · 按 ID 取 room 详情 (含未删除, 不带 tenant 约束).
	// 用于内部触发/audit 读取 room 状态;调用方需自行做租户校验。
	GetByID(ctx context.Context, roomID int64) (*Room, error)

	// ListParticipants 列当前 room 的 active (left_at IS NULL) participants。
	ListParticipants(ctx context.Context, roomID int64) ([]Participant, error)

	// AddParticipant 加一行 active participant:
	//   - 如果 (room_id, kind, account_id|agent_id) 已有 active 行 (left_at IS NULL) → 幂等成功返已有 row
	//   - 如果 source row (account / agent) 在 tx 内 FOR SHARE 失活 → ErrConflict
	//   - 否则 INSERT 新行
	AddParticipant(ctx context.Context, roomID int64, tenantID int64, p ParticipantInput) (*Participant, error)

	// MarkParticipantLeft 通过 participant_uuid 标 left_at=now() (UPDATE, 不 DELETE 行,
	// 留审计); active-only unique 释放后允许重邀。
	MarkParticipantLeft(ctx context.Context, roomID int64, participantUUID string) error

	// CreateGroupWithHook · 业务 TX 内 INSERT rooms+participants+conversation
	// 后 commit 前调 hook. hook 返 err → 整 TX 回滚.
	// 与 CreateGroup 同等业务效果但允许在同一原子事务内注入额外写入. hook=nil 视为等价 CreateGroup.
	CreateGroupWithHook(ctx context.Context, in CreateInput, hook CreateGroupHook) (*Room, int64, error)

	// AddParticipantWithHook · 同 AddParticipant 但 commit 前调 hook.
	AddParticipantWithHook(ctx context.Context, roomID int64, tenantID int64, p ParticipantInput, hook AddParticipantHook) (*Participant, error)

	// MarkParticipantLeftWithHook · 同 MarkParticipantLeft 但 commit 前调 hook.
	// hook 接收已加载的 *Participant (left_at 已被本方法 SET, 但仍能拿到 kind / account_id / agent_id).
	MarkParticipantLeftWithHook(ctx context.Context, roomID int64, participantUUID string, hook MarkParticipantLeftHook) error

	// ConversationUUIDByRoomID 取 room 对应的活跃 conversation UUID。
	// idx_conv_room_active_v2e 保证一个 room 仅一条活跃 conversation, LIMIT 1 总是确定结果。
	// 找不到 → ErrNotFound (软删 conversation 后才会出现, 业务流程不会触发)。
	ConversationUUIDByRoomID(ctx context.Context, roomID int64) (string, error)

	// UpdateTitle · F09 P2 「会话列表操作菜单 v2」: 群改名.
	// 仅 service 层校验 caller=creator 后调; 这里只写 SQL.
	// title 必须已 trim 且 1 <= len(rune) <= 64; repo 也再次 enforce.
	// 找不到 / 已软删 / 已 archived → ErrNotFound. UPDATE 影响 0 行同样返 ErrNotFound.
	UpdateTitle(ctx context.Context, tenantID, roomID int64, title string) error

	// UpdateSpeakerPolicyConfig · F09 PR7-E (NextPolicyConfig 持久化):
	// 把 SpeakerSelector 返的 NextPolicyConfig (round_robin last_idx / handoff_depth / last_handoff_to)
	// merge 回 rooms.speaker_policy_config (JSONB || merge); patch 为空 → no-op.
	// 找不到 (room 已软删) → ErrNotFound. 调用方决定吞错还是传播 (selector 状态持久化失败不应阻塞消息发送).
	UpdateSpeakerPolicyConfig(ctx context.Context, roomID int64, patch map[string]any) error

	// SendUserMessageTx Batch 2E rework #1: 把 SendMessage 的"复查 + 写 user message + bump
	// last_message_at" 三步装进一个 tx, 防 TOCTOU (预检通过后 agent 被 unpublish / caller leave /
	// room archive 时 user message 不应当落库)。
	//
	// tx 内顺序:
	//  1. SELECT rooms FOR UPDATE (room 仍 active + 未删 + 同租户) → 序列化并发 SendMessage
	//  2. SELECT room_participants FOR SHARE (caller 仍 active human participant)
	//  3. 若 SelectedAgentID != nil: SELECT room_participants FOR SHARE (agent 仍 active)
	//                                + SELECT digital_employees FOR SHARE (status='published'
	//                                + allow_invite_to_group + current_version > 0)
	//  4. INSERT messages (含 room_id + metadata.mentions)
	//  5. UPDATE conversations.last_message_at = now()
	//  6. COMMIT
	//
	// 任意复查失败 → ErrConflict / ErrForbidden / chat.agent_unavailable, user message 绝不写。
	SendUserMessageTx(ctx context.Context, in SendUserMessageInput) (*SendUserMessageOutput, error)

	// UpgradeDirectToGroup 把一个 human-human direct room 原地升级成 group room：
	// 翻转 room_kind='group'，并软删对应 room_direct_pairs 行——否则原两人后续再找
	// "1v1" 仍会命中这个已经变成群的房间。room_kind 已是 'group'（并发重复调用）
	// 时幂等 no-op；找不到 / 已软删 → ErrNotFound。
	// 调用方 (service.AddParticipant) 负责校验只对 direct_room_kind='human-human'
	// 调用，不对 human-agent direct room 调用。
	UpgradeDirectToGroup(ctx context.Context, tenantID, roomID int64) error
}

// SendUserMessageInput 群消息事务入参 (rework #1)。
//
// M6 Phase A: ExtraMetadata 让 service 层把 composer_skill_uuid / composer_skill_code /
// composer_params 等额外 key 合并进 user message metadata (与 mentions 合并). nil 时仅
// 写 mentions.
type SendUserMessageInput struct {
	TenantID        int64
	RoomID          int64
	CallerAccountID int64
	ConversationID  int64
	SelectedAgentID *int64 // selector 选中的 agent (nil = 不触发 agent 回复)
	Text            string
	Blocks          []map[string]any
	FileUUIDs       []string
	Mentions        []string // metadata.mentions = agent_uuid 列表
	ExtraMetadata   map[string]any
}

// =====================================================================
// F09-A6-04 commit-2: WithHook 回调签名
// =====================================================================

// CreateGroupHook · CreateGroupWithHook 调用方注入的回调.
// 在 rooms+participants+conversation INSERT 完, commit 前调用.
// participants 是本次 INSERT 的全部 active 成员快照 (含 caller).
// 返 err → 整 TX 回滚.
type CreateGroupHook func(ctx context.Context, tx pgx.Tx, room *Room, participants []Participant) error

// AddParticipantHook · AddParticipantWithHook 调用方注入的回调.
// 在 INSERT/UPSERT participant 后, commit 前调用.
// participant 是本次写入的 active 行 (含幂等命中情况下的已有行).
// 返 err → 整 TX 回滚.
type AddParticipantHook func(ctx context.Context, tx pgx.Tx, roomID int64, participant *Participant) error

// MarkParticipantLeftHook · MarkParticipantLeftWithHook 调用方注入的回调.
// 在 UPDATE participants.left_at 之后, commit 前调用.
// participant 已经 left (left_at IS NOT NULL); 字段含 kind/account_id/agent_id 可用.
// 返 err → 整 TX 回滚.
type MarkParticipantLeftHook func(ctx context.Context, tx pgx.Tx, roomID int64, participant *Participant) error

// SendUserMessageOutput 写好的 user message 元数据。
type SendUserMessageOutput struct {
	UserMessageID   int64
	UserMessageUUID string
}
