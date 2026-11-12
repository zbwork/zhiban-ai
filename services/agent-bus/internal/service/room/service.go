// Package room service 层 (Batch 2E)。
//
// 落地能力: Create / Get / AddParticipant / RemoveParticipant / SendMessage / ListMessages。
// 包含 M2 CanCreateGroup 业务预检 + tx 内 FOR SHARE 复查 + speaker selector + audit。
//
// 严格遵守:
//   - 不读 ctx.Value 取身份: caller (account_id, tenant_id) 全部显式参数 (CLAUDE.md)
//   - 跨表写入用同一事务 (CreateGroup / AddParticipant / SendUserMessageTx); commit 后再做 IO 长任务
//   - selector 错时 user message 绝不写
//   - apperr 统一错误码: 路由层 mapping 由 Withf 后透传
package room

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
	accountrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svccontacts "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contacts"
)

// Service 群聊 / 群消息服务接口。
type Service interface {
	Create(ctx context.Context, caller CallerCtx, in CreateReq) (*RoomDTO, error)
	Get(ctx context.Context, caller CallerCtx, roomUUID string) (*RoomDTO, error)
	AddParticipant(ctx context.Context, caller CallerCtx, roomUUID string, in AddParticipantsReq) ([]ParticipantDTO, error)
	RemoveParticipant(ctx context.Context, caller CallerCtx, roomUUID, participantUUID string) error
	SendMessage(ctx context.Context, caller CallerCtx, roomUUID string, in SendMessageReq) (*SendMessageResp, error)
	ListMessages(ctx context.Context, caller CallerCtx, roomUUID string, in ListMessagesReq) ([]MessageDTO, error)

	// RenameGroup F09 P2 「会话列表操作菜单 v2」 群改名 (仅 group, 仅 creator).
	// 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」.
	// 校验: room_kind='group', caller.AccountID==rooms.creator_id, title trim 后 1-64 rune.
	// 不同步 WuKong 频道, 不写系统消息. 成功返回最新 RoomDTO.
	RenameGroup(ctx context.Context, caller CallerCtx, roomUUID, title string) (*RoomDTO, error)
}

// New 构造默认 service 实现。
//
// 依赖说明:
//   - rooms / accounts / agents / conversations / messages: 持久化层
//   - contacts: T2E.2 CanCreateGroup 预检 (生产 nil 拒)
//   - chat: T2E.4 SendMessage 桥接 chat.RunAgentForConversation (生产 nil 时 SendMessage 拒)
//   - pool + pub: T2E.8 audit 写 events_outbox (短 tx best-effort, nil 时跳过)
func New(
	rr domroom.Repository,
	ar *accountrepo.Repo,
	gr *agentrepo.Repo,
	cr domconv.Repository,
	mr dommsg.Repository,
	contacts svccontacts.Service,
	chat svcchat.Service,
	pool *pgxpool.Pool,
	pub domevt.Publisher,
) Service {
	return &impl{
		rooms:         rr,
		accounts:      ar,
		agents:        gr,
		conversations: cr,
		messages:      mr,
		contacts:      contacts,
		chat:          chat,
		pool:          pool,
		pub:           pub,
	}
}

type impl struct {
	conversationModels svcchat.ConversationModelSelector
	rooms              domroom.Repository
	accounts           *accountrepo.Repo
	agents             *agentrepo.Repo
	conversations      domconv.Repository
	messages           dommsg.Repository
	contacts           svccontacts.Service
	chat               svcchat.Service
	pool               *pgxpool.Pool
	pub                domevt.Publisher

	// M6 Phase A: composer guard 复用 chat.ComposerGuard 接口 (svcchat 已定义,
	// 同款语义). room.SendMessage 收到 composer_skill_uuid 时调它做装配命中校验.
	// nil → composer_skill_uuid 非空时 SendMessage ErrInternal.
	composerGuard svcchat.ComposerGuard

	// F11: 群聊 @Agent / human-agent direct 触发 Agent 前先检查租户积分。
	// nil → 单测或未接线环境保持原行为。
	creditPrechecker creditPrechecker

	// F09 Phase B PR6: SpeakerSelector 完整版 (round_robin / auto_llm / parallel / handoff)
	// + speaker_decisions 审计写库. nil → 退化为 svcchat.SelectSpeakers 老签名 (无审计 / 无 judge).
	speakerSelector *svcchat.Selector

	// P2.3a (ADR-0026): WuKong group channel 同步. nil → 不做 WuKong 群同步 (单测).
	wukongGroup WuKongGroupProvisioner

	// 2026-06-12: 群成员/群消息头像同款坑 — digital_employees.avatar_url 的
	// oss://agent-avatars/... 原样下发时客户端全部加载失败 (机器人兜底图标)。
	// 与 contacts/chat 同源 (cmd/bus 注入 busMediaSvc.ResolveURL); nil → 原样透传。
	avatarURLResolver AvatarURLResolver
}

func SetConversationModelSelector(svc Service, selector svcchat.ConversationModelSelector) {
	if s, ok := svc.(*impl); ok {
		s.conversationModels = selector
	}
}

// AvatarURLResolver 把持久化头像引用 (oss://...) 解析成客户端可加载 URL。
type AvatarURLResolver func(ctx context.Context, tenantID int64, raw string) string

// SetAvatarURLResolverOnService 装配 helper (cmd/bus 注入)。
func SetAvatarURLResolverOnService(svc Service, r AvatarURLResolver) {
	if im, ok := svc.(*impl); ok {
		im.avatarURLResolver = r
	}
}

// WuKongGroupProvisioner · P2.3a (ADR-0026): room.Service 在校验通过后同步 WuKong group
// channel (type=2). 实现见 internal/im/wukong.GroupRoomMapper.
//
// ⚠ 有副作用 (subscriber_add/remove): 必在 Bus 校验 (成员存在 / 同租户 / active) 之后调,
// 避免对非法成员产生 WuKong 副作用. 本轮只同步 human 成员 (agent 虚拟用户订阅留 @Agent 阶段).
//
// nil → 不做 WuKong 群同步 (WuKong disabled / 单测).
type WuKongGroupProvisioner interface {
	// EnsureForGroup 派生 group channel_id 并订阅全部 human 成员. 返回 (channel_id, channel_type=2).
	EnsureForGroup(ctx context.Context, tenantID int64, roomUUID string, humanAccountIDs []int64) (channelID string, channelType int, err error)
	// AddMember / RemoveMember 单成员订阅同步 (subscriber_add / subscriber_remove).
	AddMember(ctx context.Context, tenantID int64, roomUUID string, humanAccountID int64) error
	RemoveMember(ctx context.Context, tenantID int64, roomUUID string, humanAccountID int64) error
}

// SetWuKongGroupProvisioner P2.3a wiring; cmd/bus 在 WuKong 启用后调.
func (s *impl) SetWuKongGroupProvisioner(p WuKongGroupProvisioner) { s.wukongGroup = p }

// SetWuKongGroupProvisionerOnService 装配 helper.
func SetWuKongGroupProvisionerOnService(svc Service, p WuKongGroupProvisioner) {
	if im, ok := svc.(*impl); ok {
		im.SetWuKongGroupProvisioner(p)
	}
}

// SetComposerGuard M6 Phase A wiring; cmd/bus 构造 composer service 后调.
func (s *impl) SetComposerGuard(g svcchat.ComposerGuard) { s.composerGuard = g }

// SetComposerGuardOnService 装配 helper.
func SetComposerGuardOnService(svc Service, g svcchat.ComposerGuard) {
	if im, ok := svc.(*impl); ok {
		im.SetComposerGuard(g)
	}
}

type creditPrechecker interface {
	EnsureCreditsAvailable(ctx context.Context, tenantID, accountID int64, source string) error
}

// SetCreditPrecheckerOnService 装配 F11 积分前置检查。
func SetCreditPrecheckerOnService(svc Service, p creditPrechecker) {
	if im, ok := svc.(*impl); ok {
		im.creditPrechecker = p
	}
}

// SetSpeakerSelector F09 PR6 wiring: 用 Phase B 6-策略 + audit selector 替代老 SelectSpeakers.
// nil → 退化为老签名 (无 round_robin / auto_llm / parallel / handoff / 审计).
func (s *impl) SetSpeakerSelector(sel *svcchat.Selector) { s.speakerSelector = sel }

// SetSpeakerSelectorOnService 装配 helper.
func SetSpeakerSelectorOnService(svc Service, sel *svcchat.Selector) {
	if im, ok := svc.(*impl); ok {
		im.SetSpeakerSelector(sel)
	}
}

const composerParamsMaxBytes = 16 * 1024

// buildComposerMetadata M6 Phase A: 校验 + 组装 user message metadata.
//
// 群聊上下文:
//   - composer_skill_uuid 必须指向 selector 选中的 agent 已装配的 skill (group 内多 agent
//     时, composer_skill 只能作用于发言的那一个; 没选中 agent 时 → 400).
//   - params 上限 16KB.
func (s *impl) buildComposerMetadata(ctx context.Context, selectedAgentID *int64, req SendMessageReq) (map[string]any, error) {
	if req.ComposerSkillUUID == "" && len(req.ComposerParams) == 0 {
		return nil, nil
	}
	if s.composerGuard == nil {
		return nil, apperr.ErrInternal.Withf("room service missing composer guard; cannot validate composer_skill_uuid")
	}
	if req.ComposerSkillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("composer_params requires composer_skill_uuid")
	}
	if selectedAgentID == nil {
		return nil, apperr.ErrInvalidParams.Withf("composer_skill_uuid requires speaker selector to choose an agent")
	}
	if len(req.ComposerParams) > 0 {
		body, err := json.Marshal(req.ComposerParams)
		if err != nil {
			return nil, apperr.ErrInvalidParams.Withf("composer_params not json serializable: %v", err)
		}
		if len(body) > composerParamsMaxBytes {
			return nil, apperr.ErrInvalidParams.Withf("chat.composer_params_too_large: %d bytes > max %d",
				len(body), composerParamsMaxBytes)
		}
	}
	sk, err := s.composerGuard.AssertSkillAttached(ctx, *selectedAgentID, req.ComposerSkillUUID)
	if err != nil {
		return nil, err
	}
	meta := map[string]any{
		"composer_skill_uuid": sk.UUID,
		"composer_skill_code": sk.Code,
	}
	if len(req.ComposerParams) > 0 {
		meta["composer_params"] = req.ComposerParams
	}
	return meta, nil
}

// publishAudit best-effort 短 tx 写 events_outbox; 失败仅日志, 不影响业务路径。
//
// pub / pool 任一 nil → no-op (单测便利)。topic 形如 audit.room.created。
func (s *impl) publishAudit(ctx context.Context, topic string, tenantID, actorAccountID int64, resourceUUID string, data map[string]any) {
	if s.pub == nil || s.pool == nil {
		return
	}
	if data == nil {
		data = map[string]any{}
	}
	dataB, _ := json.Marshal(data)
	payload, _ := json.Marshal(map[string]any{
		"severity":      "info",
		"resource_kind": "room",
		"resource_uuid": resourceUUID,
		"account_id":    actorAccountID,
		"data":          json.RawMessage(dataB),
	})
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return
	}
	defer func() { _ = tx.Rollback(ctx) }()
	_ = s.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:    topic,
		TenantID: tenantID,
		Payload:  payload,
	})
	_ = tx.Commit(ctx)
}

// Create 同事务建 room + participants + conversation。
//
// Create 流程: 入参校验 → CanCreateGroup 业务预检 → resolveParticipants 解析 ID → 范围校验
// (resolve/去重后至少 2 个非 caller participant，caller 自动入群后总数 ≥3) → repo.CreateGroup (一个 tx 内 FOR SHARE 复查 +
// 写 rooms + room_participants + conversation) → audit.room.created。
func (s *impl) Create(ctx context.Context, caller CallerCtx, in CreateReq) (*RoomDTO, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}

	// 1) 入参校验
	roomKind := strings.TrimSpace(in.RoomKind)
	if roomKind == "" {
		roomKind = string(domroom.KindGroup)
	}
	if roomKind != string(domroom.KindGroup) {
		return nil, apperr.ErrInvalidParams.Withf("room.kind_unsupported: 2E only allows roomKind='group'")
	}

	policy := domroom.SpeakerPolicy(strings.TrimSpace(in.SpeakerPolicy))
	if policy == "" {
		policy = domroom.PolicyManual
	}
	if policy != domroom.PolicyManual && policy != domroom.PolicyManager {
		return nil, apperr.ErrInvalidParams.Withf("room.speaker_policy_unsupported: 2E only allows manual/manager")
	}

	if strings.TrimSpace(in.Title) == "" {
		return nil, apperr.ErrInvalidParams.Withf("room.title_required")
	}

	// 2) T2E.2 pre-check: CanCreateGroup (M2 业务可见性 + allow_invite_to_group +
	//    contact_policies 三层判定); 任一阻断 → 整个 create 拒绝, 不进事务
	if err := s.precheckCanCreateGroup(ctx, caller, in.Participants); err != nil {
		return nil, err
	}

	// 3) 解析 participants → 内部 ID; 同时校验同租户 (跨租户硬拒由 resolveParticipants 兜底)
	participants, managerAgentID, err := s.resolveParticipants(ctx, caller, in.Participants, in.ManagerAgentUUID, policy)
	if err != nil {
		return nil, err
	}

	// 3.5) 群总 participant 必须 ≥3。participants 已解析、去重且排除自动入群的 caller；
	// human / agent 等价计数，因此这里至少需要 2 个受邀参与者。
	if err := validateGroupParticipantCount(participants); err != nil {
		return nil, err
	}

	// 3) repo CreateGroup (业务 TX 内 INSERT rooms + participants + conversation).
	createInput := domroom.CreateInput{
		TenantID:       caller.TenantID,
		CreatorID:      caller.AccountID,
		RoomKind:       domroom.Kind(roomKind),
		Title:          in.Title,
		Goal:           in.Goal,
		SpeakerPolicy:  policy,
		ManagerAgentID: managerAgentID,
		MaxRoundCount:  in.MaxRoundCount,
		Participants:   participants,
	}
	// P2.3a (ADR-0026): WuKong group provisioning (provision-after-auth)。
	//   - 校验已通过 (CanCreateGroup + resolveParticipants 同租户/active + 范围校验);
	//     写库前预生成 room uuid → 派生 GroupChannelID → subscriber_add 全部 human 成员。
	//   - 非法 / 跨租户成员在校验阶段已被拒, 不会到这一步, 故不产生 WuKong 副作用。
	//   - 失败 fail-closed (不写库)。
	if s.wukongGroup != nil {
		roomUUID := id.NewUUID()
		humanIDs := make([]int64, 0, len(participants)+1)
		humanIDs = append(humanIDs, caller.AccountID)
		for _, p := range participants {
			if p.Kind == domroom.ParticipantHuman && p.AccountID != nil {
				humanIDs = append(humanIDs, *p.AccountID)
			}
		}
		chID, chType, werr := s.wukongGroup.EnsureForGroup(ctx, caller.TenantID, roomUUID, humanIDs)
		if werr != nil {
			return nil, apperr.New(apperr.UpstreamUnavailable, "room.wukong_ensure_failed").Wrap(werr)
		}
		createInput.RoomUUID = roomUUID
		createInput.WuKongChannelID = chID
		createInput.WuKongChannelType = chType
	}

	rm, convID, err := s.rooms.CreateGroup(ctx, createInput)
	if err != nil {
		return nil, err
	}

	// 4) 取 conversation_uuid
	conv, err := s.conversations.GetByID(ctx, convID)
	if err != nil {
		return nil, err
	}

	// 5) 拉 participants 列表 → DTO
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	dto := s.buildRoomDTO(ctx, rm, conv.UUID, parts, in.ManagerAgentUUID, caller.AccountID)

	// T2E.8: audit.room.created
	humanCount, agentCount := 0, 0
	for _, p := range parts {
		switch p.Kind {
		case domroom.ParticipantHuman:
			humanCount++
		case domroom.ParticipantAgent:
			agentCount++
		}
	}
	s.publishAudit(ctx, "audit.room.created", caller.TenantID, caller.AccountID, rm.UUID, map[string]any{
		"room_kind":          string(rm.RoomKind),
		"speaker_policy":     string(rm.SpeakerPolicy),
		"manager_agent_uuid": in.ManagerAgentUUID,
		"participants_count": len(parts),
		"human_count":        humanCount,
		"agent_count":        agentCount,
	})
	// WuKong 群 channel 已在写库前完成派生和订阅同步。
	return dto, nil
}

func validateGroupParticipantCount(participants []domroom.ParticipantInput) error {
	if len(participants) < 2 {
		return apperr.ErrInvalidParams.Withf("room.too_few_participants: group needs at least 3 participants including caller")
	}
	return nil
}

// Get 详情。
func (s *impl) Get(ctx context.Context, caller CallerCtx, roomUUID string) (*RoomDTO, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return nil, err
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller not participant")
	}

	convUUID, err := s.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
	if err != nil {
		return nil, err
	}

	managerUUID := ""
	if rm.ManagerAgentID != nil {
		if ag, err := s.agents.GetByID(ctx, *rm.ManagerAgentID); err == nil {
			managerUUID = ag.UUID
		}
	}

	return s.buildRoomDTO(ctx, rm, convUUID, parts, managerUUID, caller.AccountID), nil
}

// RenameGroup F09 P2 「会话列表操作菜单 v2」: 群改名 (仅 group, 仅 creator).
//
// 校验链:
//  1. caller.TenantID > 0
//  2. room 存在 / 未软删 / room_kind='group'
//  3. caller.AccountID == rooms.creator_id   (本轮严格 creator-only; admin 角色后续)
//  4. caller 仍是 active human participant   (creator 退群后不应再改名)
//  5. title trim + utf8 rune 1-64
//
// 不写 WuKong / 不写系统消息. 成功后写 audit room.title.changed.
// 返回最新 RoomDTO (反映新 title).
func (s *impl) RenameGroup(ctx context.Context, caller CallerCtx, roomUUID, title string) (*RoomDTO, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}
	t := strings.TrimSpace(title)
	if t == "" {
		return nil, apperr.ErrInvalidParams.Withf("title required")
	}
	// rune len 校验 (utf8 安全) -- repo 层也再校验一遍.
	if n := len([]rune(t)); n > 64 {
		return nil, apperr.ErrInvalidParams.Withf("title too long (max 64 chars), got %d", n)
	}
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return nil, err
	}
	if rm.RoomKind != domroom.KindGroup {
		return nil, apperr.ErrInvalidParams.Withf("rename only allowed for group room (kind=%s)", rm.RoomKind)
	}
	if rm.CreatorID != caller.AccountID {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: only creator can rename group")
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller not active participant")
	}
	if rm.Title == t {
		// 同名无变化, 视为幂等成功 (不写 audit, 不动 updated_at).
		convUUID, _ := s.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
		managerUUID := ""
		if rm.ManagerAgentID != nil {
			if ag, err := s.agents.GetByID(ctx, *rm.ManagerAgentID); err == nil {
				managerUUID = ag.UUID
			}
		}
		return s.buildRoomDTO(ctx, rm, convUUID, parts, managerUUID, caller.AccountID), nil
	}
	// CR4: 在 UpdateTitle 前缓存真实旧值, 用于 audit; UpdateTitle 后 rm.Title 已不可信.
	oldTitle := rm.Title
	if err := s.rooms.UpdateTitle(ctx, caller.TenantID, rm.ID, t); err != nil {
		return nil, err
	}
	// 重新读 (拿最新 updated_at / title); 失败 → 继续返当前结构 (best-effort).
	updated, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err == nil {
		rm = updated
	}
	convUUID, _ := s.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
	managerUUID := ""
	if rm.ManagerAgentID != nil {
		if ag, err := s.agents.GetByID(ctx, *rm.ManagerAgentID); err == nil {
			managerUUID = ag.UUID
		}
	}
	s.publishAudit(ctx, "room.title.changed", caller.TenantID, caller.AccountID, rm.UUID, map[string]any{
		"old_title": oldTitle,
		"new_title": t,
	})
	return s.buildRoomDTO(ctx, rm, convUUID, parts, managerUUID, caller.AccountID), nil
}

// AddParticipant 流程: caller 必须是当前 active participant → CanCreateGroup 预检 →
// resolveParticipants → repo.AddParticipant (tx 内 FOR SHARE 复查 + 幂等返已有行 / leave 后重邀
// 走新行) → audit.room.member.added (幂等命中也发, 让 audit 记录每次 invite 动作)。
func (s *impl) AddParticipant(ctx context.Context, caller CallerCtx, roomUUID string, in AddParticipantsReq) ([]ParticipantDTO, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return nil, err
	}
	if rm.RoomKind != domroom.KindGroup {
		// human-human 1v1 通话中拉新人 = 原地把这个 direct room 升级成 group
		// (docs/features 邀请加入两人会议; 产品选定「原地升级」而非另开临时群)。
		// human-agent direct room 不允许——那是数字员工单聊,不该被拉进多人群。
		if rm.RoomKind != domroom.KindDirect || metadataString(rm.Metadata, "direct_room_kind") != "human-human" {
			return nil, apperr.ErrInvalidParams.Withf("room.add_participants_requires_group")
		}
		if err := s.rooms.UpgradeDirectToGroup(ctx, caller.TenantID, rm.ID); err != nil {
			return nil, err
		}
		rm.RoomKind = domroom.KindGroup
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller not participant")
	}

	// T2E.2 pre-check
	if err := s.precheckCanCreateGroup(ctx, caller, in.Participants); err != nil {
		return nil, err
	}

	resolved, _, err := s.resolveParticipants(ctx, caller, in.Participants, "", domroom.PolicyManual)
	if err != nil {
		return nil, err
	}

	out := make([]ParticipantDTO, 0, len(resolved))
	companyName := s.tenantCompanyName(ctx, rm.TenantID)
	for _, p := range resolved {
		added, err := s.rooms.AddParticipant(ctx, rm.ID, caller.TenantID, p)
		if err != nil {
			return nil, err
		}
		// P2.3a: group + 已有 WuKong link 时同步 subscriber_add (human 成员; commit 后 IO)。
		// room_participants 为成员真理已落库; WuKong 订阅为派生。失败返错 (上游不可用),
		// add 幂等可重试。
		if s.wukongGroup != nil && rm.RoomKind == domroom.KindGroup && rm.WuKongChannelID != "" &&
			added.Kind == domroom.ParticipantHuman && added.AccountID != nil {
			if werr := s.wukongGroup.AddMember(ctx, caller.TenantID, rm.UUID, *added.AccountID); werr != nil {
				return nil, apperr.New(apperr.UpstreamUnavailable, "room.wukong_sync_failed").Wrap(werr)
			}
		}
		dto := s.participantToDTO(ctx, *added, rm.TenantID, companyName, caller.AccountID)
		out = append(out, dto)
		// T2E.8: audit.room.member.added (幂等命中也发, 让 audit 看到所有 invite 动作)
		s.publishAudit(ctx, "audit.room.member.added", caller.TenantID, caller.AccountID, rm.UUID, map[string]any{
			"participant_uuid": dto.ParticipantUUID,
			"kind":             dto.Kind,
			"member_uuid":      dto.ID,
		})
	}
	return out, nil
}

// precheckCanCreateGroup 调 contacts.CanCreateGroup 做业务可见性预检。
//
// T2E.2 关键纪律: 这是事务外预检, 给前端清晰错误; 不替代事务内 FOR SHARE 复查 (那段在
// repo.CreateGroup / repo.AddParticipant / repo.SendUserMessageTx 里跑)。
//
// **fail-closed**: contacts==nil 直接拒, 防止生产路径漏装依赖时静默放行 (T2E rework #3)。
// 单测如要绕过预检, 必须装 fakeContacts (而非传 nil)。
func (s *impl) precheckCanCreateGroup(ctx context.Context, caller CallerCtx, participants []ParticipantInput) error {
	if s.contacts == nil {
		return apperr.ErrInternal.Withf("room service missing contacts dep (precheck would fail-open); refusing to proceed")
	}
	if len(participants) == 0 {
		return nil // 让上层范围校验抛 too_few_participants
	}
	parts := make([]svccontacts.GroupParticipant, 0, len(participants))
	for _, p := range participants {
		parts = append(parts, svccontacts.GroupParticipant{Kind: p.Kind, ID: p.ID})
	}
	resp, err := s.contacts.CanCreateGroup(ctx, svccontacts.CallerCtx{
		AccountID:     caller.AccountID,
		TenantID:      caller.TenantID,
		DepartmentID:  caller.DepartmentID,
		IsTenantAdmin: caller.IsTenantAdmin,
	}, svccontacts.CanCreateGroupReq{Participants: parts})
	if err != nil {
		return err
	}
	if !resp.Allowed {
		return apperr.ErrForbidden.Withf("room.member_not_invitable: %s (blocked=%d)", resp.ReasonCode, len(resp.BlockedParticipants))
	}
	return nil
}

// RemoveParticipant 通过 participant_uuid 标 left_at=now()。
//
// 权限边界:
//   - caller 移除自己 = leave，allow
//   - caller 移除其他 participant：仅 rooms.creator_id == caller 时 allow
//   - manager 是否可踢人留 M5 完整版（不在 2E 开放）
//   - caller 不是该群 active participant：先 forbid，避免越权探测
func (s *impl) RemoveParticipant(ctx context.Context, caller CallerCtx, roomUUID, participantUUID string) error {
	if caller.TenantID == 0 {
		return apperr.ErrForbidden.Withf("missing tenant scope")
	}
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return err
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return apperr.ErrForbidden.Withf("room.permission_denied: caller not participant")
	}
	target := findParticipantByUUID(parts, participantUUID)
	if target == nil {
		return apperr.ErrNotFound.Withf("room.participant_not_found: uuid=%s", participantUUID)
	}

	isSelf := target.Kind == domroom.ParticipantHuman &&
		target.AccountID != nil && *target.AccountID == caller.AccountID
	if !isSelf && rm.CreatorID != caller.AccountID {
		return apperr.ErrForbidden.Withf("room.permission_denied: only creator can remove other participants (manager kick is M5)")
	}
	if err := s.rooms.MarkParticipantLeft(ctx, rm.ID, participantUUID); err != nil {
		return err
	}
	// P2.3a: group + 已有 WuKong link 时同步 subscriber_remove (human 成员; commit 后 IO)。
	// 移除后该成员 room_participants left_at 已落库 (列表不可见 + 历史闸生效); WuKong 取消订阅
	// 使其不再实时收发。失败返错 (上游不可用); 注: DB 移除已生效, 安全属性 (不可见/不可拉历史)
	// 由 room_participants + messagesync 闸保证, 仅实时收发可能滞后一拍。
	if s.wukongGroup != nil && rm.RoomKind == domroom.KindGroup && rm.WuKongChannelID != "" &&
		target.Kind == domroom.ParticipantHuman && target.AccountID != nil {
		if werr := s.wukongGroup.RemoveMember(ctx, caller.TenantID, rm.UUID, *target.AccountID); werr != nil {
			return apperr.New(apperr.UpstreamUnavailable, "room.wukong_sync_failed").Wrap(werr)
		}
	}
	// T2E.8: audit.room.member.removed
	reason := "kick"
	if isSelf {
		reason = "leave"
	}
	s.publishAudit(ctx, "audit.room.member.removed", caller.TenantID, caller.AccountID, rm.UUID, map[string]any{
		"participant_uuid": target.UUID,
		"kind":             string(target.Kind),
		"reason":           reason,
	})
	return nil
}

// SendMessage 流程: 预检 → 事务 → commit → run。
//
// 关键纪律:
//   - selector 错 (multi / ambiguous / unavailable) 时 user message 绝**不**写
//   - chat dep nil 时也不写 (fail-closed)
//   - 复查 + INSERT user message + UPDATE last_message_at 装在一个 tx 里 (rework #1)
//   - OpenClaw 调用在 commit 后才发起 (IO 长任务不进 PG tx)
//   - 群其他成员 fan-out 不做 (caller 自己拿 stream_id; 其他成员看 history)
func (s *impl) SendMessage(ctx context.Context, caller CallerCtx, roomUUID string, in SendMessageReq) (*SendMessageResp, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}
	text := strings.TrimSpace(in.Text)
	if text == "" {
		return nil, apperr.ErrInvalidParams.Withf("room.send.text_required")
	}

	if len(in.Blocks) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("消息内容过多")
	}
	if body, err := json.Marshal(in.Blocks); err != nil || len(body) > 256*1024 {
		return nil, apperr.ErrInvalidParams.Withf("消息内容过大")
	}
	for _, block := range in.Blocks {
		kind, _ := block["type"].(string)
		if kind != "plain" && kind != "text" && kind != "markdown" && kind != "skill" {
			return nil, apperr.ErrInvalidParams.Withf("附件请通过 file_uuids 发送")
		}
	}

	// 1) 预加载 room + active participants
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return nil, err
	}
	if rm.Status != "active" {
		return nil, apperr.ErrConflict.Withf("room.not_active: status=%s", rm.Status)
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller not participant")
	}
	// 1v1 human-human 场景(唯一对方是 human 且已不在会话本租户里活跃)必须提前拦，
	// 否则消息会发进一个对方已经收不到、也回不了的死会话，发送方毫无感知。
	// 群聊不做这个拦截:任意一个成员离开不该挡住其余人正常聊天。
	if otherAccountID, ok := soleOtherHumanParticipant(caller.AccountID, parts); ok {
		mem, merr := s.accounts.GetMembership(ctx, otherAccountID, caller.TenantID)
		if merr != nil && !errors.Is(merr, apperr.ErrNotFound) {
			return nil, merr
		}
		if mem == nil || mem.Status != "active" {
			return nil, apperr.ErrConflict.Withf("room.peer_left_tenant: 对方已离开该组织，无法发送消息")
		}
	}

	// 2) 预校验 selector — 选中的 agent 必须在 active participants 中.
	// PR6: 优先用 Selector (Phase B 6 策略 + audit); nil 时退化到老 SelectSpeakers.
	candidates := s.buildSpeakerCandidates(ctx, parts)
	var selected []int64
	if s.speakerSelector != nil {
		// PolicyConfig / RoundRobinLastIdx / LastHandoffTo 从 room.SpeakerPolicyConfig 解 (selector 知道字段名).
		rrLastIdx := -1
		if v, ok := rm.SpeakerPolicyConfig["last_idx"]; ok {
			switch x := v.(type) {
			case int:
				rrLastIdx = x
			case int64:
				rrLastIdx = int(x)
			case float64:
				rrLastIdx = int(x)
			}
		}
		var lastHandoffTo *int64
		if v, ok := rm.SpeakerPolicyConfig["last_handoff_to"]; ok {
			switch x := v.(type) {
			case int:
				idv := int64(x)
				lastHandoffTo = &idv
			case int64:
				lastHandoffTo = &x
			case float64:
				idv := int64(x)
				lastHandoffTo = &idv
			}
		}
		handoffDepth := 0
		if v, ok := rm.SpeakerPolicyConfig["handoff_depth"]; ok {
			switch x := v.(type) {
			case int:
				handoffDepth = x
			case int64:
				handoffDepth = int(x)
			case float64:
				handoffDepth = int(x)
			}
		}
		res, serr := s.speakerSelector.Select(ctx, svcchat.SelectInput{
			Policy:            rm.SpeakerPolicy,
			PolicyConfig:      rm.SpeakerPolicyConfig,
			ManagerAgentID:    rm.ManagerAgentID,
			Candidates:        candidates,
			UserMsgText:       text,
			RoomID:            rm.ID,
			TenantID:          caller.TenantID,
			CreatedBy:         &caller.AccountID,
			LastHandoffTo:     lastHandoffTo,
			HandoffDepth:      handoffDepth,
			RoundRobinLastIdx: rrLastIdx,
		})
		if serr != nil {
			return nil, serr // user message **不**写
		}
		if res != nil {
			selected = res.Selected
			// PR7-E: NextPolicyConfig (round_robin last_idx / handoff_depth / last_handoff_to) 持久化.
			// 写回失败"silently" 吞掉 (impl 没有 logger 字段; 加 logger 会引发 New 签名级联),
			// 不阻塞当前消息发送. 失败最坏后果 = selector 状态丢一拍, 下一轮 round_robin 重新从 0
			// 开始 / handoff 深度归零; 不影响业务正确性.
			if len(res.NextPolicyConfig) > 0 {
				_ = s.rooms.UpdateSpeakerPolicyConfig(ctx, rm.ID, res.NextPolicyConfig)
			}
		}
	} else {
		var serr error
		selected, serr = svcchat.SelectSpeakers(rm.SpeakerPolicy, rm.ManagerAgentID, candidates, text)
		if serr != nil {
			return nil, serr
		}
	}
	if len(selected) == 0 {
		if agentID := directHumanAgentSelectedAgentID(rm, parts); agentID != nil {
			selected = []int64{*agentID}
		}
	}

	if target := directHumanAgentSelectedAgentID(rm, parts); target != nil {
		ag, err := s.agents.GetByID(ctx, *target)
		if err != nil {
			return nil, err
		}
		if s.contacts == nil {
			return nil, apperr.ErrForbidden.Withf("数字员工可见性服务不可用")
		}
		if err := s.contacts.AssertAgentVisible(ctx, caller.AccountID, caller.TenantID, ag.UUID); err != nil {
			return nil, err
		}
	}

	// 3) 取 conversation (room 唯一活跃 conv)
	convUUID, err := s.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	conv, err := s.conversations.GetByUUID(ctx, convUUID)
	if err != nil {
		return nil, err
	}

	// 4) selector 命中 agent 时 fail-closed 检查 chat dep (放在事务前, 让 user message 不落库)
	var selectedAgentID *int64
	if len(selected) == 1 {
		id := selected[0]
		selectedAgentID = &id
		if s.chat == nil {
			return nil, apperr.ErrInternal.Withf("room service missing chat dep; selector chose agent but cannot run")
		}
		if s.creditPrechecker != nil {
			source := "group_agent_trigger"
			if rm.RoomKind == domroom.KindDirect {
				source = "agent_direct_send"
			}
			if err := s.creditPrechecker.EnsureCreditsAvailable(ctx, caller.TenantID, caller.AccountID, source); err != nil {
				return nil, err
			}
		}
	}

	// 5) 一个 tx 完成: SELECT rooms FOR UPDATE → 复查 caller / agent → INSERT user message
	//    → UPDATE last_message_at (rework #1)
	mentions := []string{}
	for _, aid := range selected {
		for _, c := range candidates {
			if c.AgentID == aid {
				mentions = append(mentions, c.AgentUUID)
			}
		}
	}
	// M6 Phase A: 校验 composer_skill 装配命中 + params 上限 (与 chat.Send 同款).
	// 校验放在 tx 之前; 失败时 user message 不写.
	composerMeta, err := s.buildComposerMetadata(ctx, selectedAgentID, in)
	if err != nil {
		return nil, err
	}
	if model := strings.TrimSpace(in.ModelHint); model != "" {
		target := directHumanAgentSelectedAgentID(rm, parts)
		if target == nil || selectedAgentID == nil || *target != *selectedAgentID || s.conversationModels == nil {
			return nil, apperr.ErrInvalidParams.Withf("仅数字员工单聊支持会话模型选择")
		}
		ag, err := s.agents.GetByID(ctx, *target)
		if err != nil {
			return nil, err
		}
		if err := s.conversationModels.ValidateConversationModel(ctx, caller.AccountID, caller.TenantID, ag, model); err != nil {
			return nil, err
		}
		if composerMeta == nil {
			composerMeta = map[string]any{}
		}
		composerMeta["conversation_model"] = model
	}
	userOut, err := s.rooms.SendUserMessageTx(ctx, domroom.SendUserMessageInput{
		TenantID:        caller.TenantID,
		RoomID:          rm.ID,
		CallerAccountID: caller.AccountID,
		ConversationID:  conv.ID,
		SelectedAgentID: selectedAgentID,
		Text:            text,
		Blocks:          in.Blocks,
		FileUUIDs:       in.FileUUIDs,
		Mentions:        mentions,
		ExtraMetadata:   composerMeta,
	})
	if err != nil {
		return nil, err
	}

	// 6) selector 空集 → 不触发 Agent (user message 已落库, last_message_at 已 bump)
	if selectedAgentID == nil {
		return &SendMessageResp{
			ConversationUUID: conv.UUID,
			UserMessageUUID:  userOut.UserMessageUUID,
			StreamIDs:        []string{},
		}, nil
	}

	// 7) commit 后调 chat.RunAgentForConversation (IO 长任务必须在 tx 外)
	ag, err := s.agents.GetByID(ctx, *selectedAgentID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("room.agent_lookup_failed: %v", err)
	}
	prompt := s.composeGroupPrompt(ctx, rm, conv.ID, text)
	out, err := s.chat.RunAgentForConversation(ctx, svcchat.RunAgentInput{
		AccountID:        caller.AccountID,
		TenantID:         caller.TenantID,
		Conversation:     conv,
		RoomUUID:         rm.UUID,
		Agent:            ag,
		PromptText:       prompt,
		UserMessageUUID:  userOut.UserMessageUUID,
		InputMessageUUID: userOut.UserMessageUUID,
	})
	if err != nil {
		return nil, err
	}

	return &SendMessageResp{
		ConversationUUID: conv.UUID,
		UserMessageUUID:  userOut.UserMessageUUID,
		StreamIDs:        []string{out.StreamID},
	}, nil
}

// buildSpeakerCandidates 把 active agent participants 转成 selector 入参 (含 name + uuid)。
func (s *impl) buildSpeakerCandidates(ctx context.Context, parts []domroom.Participant) []svcchat.SpeakerCandidate {
	out := make([]svcchat.SpeakerCandidate, 0)
	for _, p := range parts {
		if p.Kind != domroom.ParticipantAgent || p.AgentID == nil || p.LeftAt != nil {
			continue
		}
		ag, err := s.agents.GetByID(ctx, *p.AgentID)
		if err != nil {
			continue
		}
		out = append(out, svcchat.SpeakerCandidate{
			AgentID:   ag.ID,
			AgentUUID: ag.UUID,
			AgentName: ag.Name,
		})
	}
	return out
}

func directHumanAgentSelectedAgentID(rm *domroom.Room, parts []domroom.Participant) *int64 {
	if rm == nil || rm.RoomKind != domroom.KindDirect {
		return nil
	}
	if strings.TrimSpace(metadataString(rm.Metadata, "direct_room_kind")) != "human-agent" {
		return nil
	}
	var selected *int64
	for _, p := range parts {
		if p.Kind != domroom.ParticipantAgent || p.AgentID == nil || p.LeftAt != nil {
			continue
		}
		if selected != nil {
			return nil
		}
		id := *p.AgentID
		selected = &id
	}
	return selected
}

func metadataString(meta map[string]any, key string) string {
	if meta == nil {
		return ""
	}
	switch v := meta[key].(type) {
	case string:
		return v
	default:
		return ""
	}
}

// composeGroupPrompt 组装 OpenClaw 的 message 字段:
// "<user_text>\n\n[群上下文：标题=..., 目标=..., 最近 N 轮发言: ...]"
//
// 群上下文摘要拉最近 N 条 messages (N=AGBUS_CHAT_CONTEXT_RECENT_N hard cap, 沿用 2D);
// 简化展示: "[role/sender] text" 一行一条; 内容过长 (>500 字) 截断 + "…"。
func (s *impl) composeGroupPrompt(ctx context.Context, rm *domroom.Room, convID int64, userText string) string {
	const recentN = 20
	var sb strings.Builder
	sb.WriteString(userText)
	sb.WriteString("\n\n[群上下文：标题=")
	sb.WriteString(rm.Title)
	if rm.Goal != "" {
		sb.WriteString("，目标=")
		sb.WriteString(rm.Goal)
	}
	sb.WriteString("，最近发言：")
	hist, err := s.messages.History(ctx, dommsg.HistoryFilter{ConversationID: convID, Limit: recentN})
	if err == nil && len(hist) > 0 {
		// history 按 created_at DESC 返回, 翻转成时间序
		for i := len(hist) - 1; i >= 0; i-- {
			m := hist[i]
			line := messageOneLine(m)
			if line == "" {
				continue
			}
			line = truncateRunes(line, 200)
			sb.WriteString("\n- ")
			sb.WriteString(line)
		}
	}
	sb.WriteString("]")
	return sb.String()
}

func messageOneLine(m dommsg.Message) string {
	for _, b := range m.Blocks {
		if t, _ := b["text"].(string); t != "" {
			return "[" + m.Role + "] " + t
		}
	}
	return ""
}

func truncateRunes(s string, max int) string {
	s = strings.ToValidUTF8(s, "")
	if max <= 0 {
		return ""
	}
	rs := []rune(s)
	if len(rs) <= max {
		return s
	}
	return string(rs[:max]) + "…"
}

// ListMessages T2E.7 群消息历史分页。
//
// 参数:
//   - limit: 默认 50, 上限 200; <=0 取默认
//   - before_uuid: 可选游标; 指向某条已知 message, 返回**早于**该 message 的历史
//
// 排序: created_at ASC (与 chat.History 一致, 便于客户端追加渲染)
//
// 复用 idx_messages_room (000004 已建); 不新增索引。
func (s *impl) ListMessages(ctx context.Context, caller CallerCtx, roomUUID string, in ListMessagesReq) ([]MessageDTO, error) {
	if caller.TenantID == 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant scope")
	}
	rm, err := s.rooms.GetByUUID(ctx, caller.TenantID, roomUUID)
	if err != nil {
		return nil, err
	}
	parts, err := s.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	if !callerInParticipants(caller.AccountID, parts) {
		return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller not participant")
	}
	convUUID, err := s.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
	if err != nil {
		return nil, err
	}
	conv, err := s.conversations.GetByUUID(ctx, convUUID)
	if err != nil {
		return nil, err
	}

	limit := in.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	filter := dommsg.HistoryFilter{ConversationID: conv.ID, Limit: limit}
	if in.BeforeUUID != "" {
		cursor, err := s.messages.GetByUUID(ctx, in.BeforeUUID)
		if err != nil {
			return nil, err
		}
		// 防越权: cursor 必须属于同一 room conversation
		if cursor.ConversationID != conv.ID {
			return nil, apperr.ErrForbidden.Withf("room.cursor_mismatch: before_uuid not in this room")
		}
		t := cursor.CreatedAt
		filter.Before = &t
	}

	rows, err := s.messages.History(ctx, filter)
	if err != nil {
		return nil, err
	}

	out := make([]MessageDTO, 0, len(rows))
	for _, m := range rows {
		out = append(out, MessageDTO{
			UUID:            m.UUID,
			Role:            m.Role,
			Status:          m.Status,
			Blocks:          blocksToAny(m.Blocks),
			Metadata:        m.Metadata,
			CreatedAt:       m.CreatedAt,
			SenderAccountID: m.SenderAccountID,
			SenderAgentID:   m.SenderAgentID,
		})
	}
	return out, nil
}

func blocksToAny(in []map[string]any) []any {
	out := make([]any, 0, len(in))
	for _, b := range in {
		out = append(out, b)
	}
	return out
}

// resolveParticipants 把 (kind, uuid) 列表解析成 domain ParticipantInput;
// 同时校验同租户。返回 (participants, manager_agent_id, error)。
//
// 业务可见性 / allow_invite_to_group / contact_policies 三层判定由 precheckCanCreateGroup
// (调 contacts.Service.CanCreateGroup) 完成; 本函数只做:
//   - kind ∈ {human, agent}
//   - account 属于同 tenant; agent 同租户或 platform (tenant_id IS NULL)
//   - manager_agent_uuid 必须在 participants 里 (manager 策略下)
//   - 群成员上限 50 (含 caller, 去重后)
func (s *impl) resolveParticipants(
	ctx context.Context,
	caller CallerCtx,
	in []ParticipantInput,
	managerAgentUUID string,
	policy domroom.SpeakerPolicy,
) ([]domroom.ParticipantInput, *int64, error) {
	out := make([]domroom.ParticipantInput, 0, len(in))
	seenAccount := map[int64]bool{caller.AccountID: true}
	seenAgent := map[int64]bool{}
	var managerAgentID *int64

	for _, p := range in {
		switch strings.ToLower(strings.TrimSpace(p.Kind)) {
		case "human":
			acc, err := s.accounts.GetByUUID(ctx, p.ID)
			if err != nil {
				return nil, nil, apperr.ErrInvalidParams.Withf("room.member_not_invitable: human uuid=%s not found", p.ID)
			}
			// 校验目标 human 在同租户内是 active member
			mem, err := s.accounts.GetMembership(ctx, acc.ID, caller.TenantID)
			if err != nil || mem == nil || mem.Status != "active" {
				return nil, nil, apperr.ErrForbidden.Withf("room.cross_tenant_forbidden: human uuid=%s not active in tenant", p.ID)
			}
			if seenAccount[acc.ID] {
				continue // 去重
			}
			seenAccount[acc.ID] = true
			id := acc.ID
			out = append(out, domroom.ParticipantInput{
				Kind:       domroom.ParticipantHuman,
				AccountID:  &id,
				RoleInRoom: domroom.RoleMember,
			})

		case "agent":
			ag, err := s.agents.GetByUUID(ctx, p.ID)
			if err != nil {
				return nil, nil, apperr.ErrInvalidParams.Withf("room.member_not_invitable: agent uuid=%s not found", p.ID)
			}
			// 同租户校验: agent.TenantID == 0 表示 platform 预置, 所有租户可见
			if ag.TenantID != 0 && ag.TenantID != caller.TenantID {
				return nil, nil, apperr.ErrForbidden.Withf("room.cross_tenant_forbidden: agent uuid=%s belongs to another tenant", p.ID)
			}
			if seenAgent[ag.ID] {
				continue
			}
			seenAgent[ag.ID] = true
			role := domroom.RoleMember
			if managerAgentUUID != "" && p.ID == managerAgentUUID {
				role = domroom.RoleManager
				id := ag.ID
				managerAgentID = &id
			}
			id := ag.ID
			out = append(out, domroom.ParticipantInput{
				Kind:       domroom.ParticipantAgent,
				AgentID:    &id,
				RoleInRoom: role,
			})

		default:
			return nil, nil, apperr.ErrInvalidParams.Withf("room.member_not_invitable: unknown kind=%q", p.Kind)
		}
	}

	if policy == domroom.PolicyManager {
		if managerAgentUUID == "" {
			return nil, nil, apperr.ErrInvalidParams.Withf("room.manager_not_in_participants: speakerPolicy=manager requires manager_agent_uuid")
		}
		if managerAgentID == nil {
			return nil, nil, apperr.ErrInvalidParams.Withf("room.manager_not_in_participants: manager_agent_uuid not in participants[]")
		}
	}

	// 群成员上限: caller + participants 去重后 ≤ MaxParticipants。caller 已在 seenAccount。
	// 这是事务外预检, 给前端清晰错误; AddParticipant 路径漏算 room 已有成员的 race 由
	// repo.AddParticipant tx 内 count + cap 检查兜底 (rework #5)。
	total := len(seenAccount) + len(seenAgent)
	if total > domroom.MaxParticipants {
		return nil, nil, apperr.ErrInvalidParams.Withf("room.max_participants_exceeded: total=%d > %d", total, domroom.MaxParticipants)
	}

	return out, managerAgentID, nil
}

func (s *impl) buildRoomDTO(
	ctx context.Context,
	rm *domroom.Room,
	convUUID string,
	parts []domroom.Participant,
	managerAgentUUID string,
	callerAccountID int64,
) *RoomDTO {
	dto := &RoomDTO{
		UUID:              rm.UUID,
		ConversationUUID:  convUUID,
		RoomKind:          string(rm.RoomKind),
		Title:             rm.Title,
		Goal:              rm.Goal,
		SpeakerPolicy:     string(rm.SpeakerPolicy),
		ManagerAgentUUID:  managerAgentUUID,
		MaxRoundCount:     rm.MaxRoundCount,
		RoundCount:        rm.RoundCount,
		Status:            rm.Status,
		CreatedAt:         rm.CreatedAt,
		WuKongChannelID:   rm.WuKongChannelID,
		WuKongChannelType: rm.WuKongChannelType,
	}
	// P2.3a 群成员面板:暴露群主(creator)account uuid,客户端据此标「群主」。
	if creator, err := s.accounts.GetByID(ctx, rm.CreatorID); err == nil {
		dto.CreatorAccountUUID = creator.UUID
	}
	dto.Participants = make([]ParticipantDTO, 0, len(parts))
	companyName := s.tenantCompanyName(ctx, rm.TenantID)
	for _, p := range parts {
		dto.Participants = append(dto.Participants, s.participantToDTO(ctx, p, rm.TenantID, companyName, callerAccountID))
	}
	return dto
}

func (s *impl) participantToDTO(ctx context.Context, p domroom.Participant, tenantID int64, companyName string, callerAccountID int64) ParticipantDTO {
	out := ParticipantDTO{
		ParticipantUUID: p.UUID,
		Kind:            string(p.Kind),
		RoleInRoom:      string(p.RoleInRoom),
		CompanyName:     companyName,
	}
	if p.Kind == domroom.ParticipantHuman && p.AccountID != nil {
		if acc, err := s.accounts.GetByID(ctx, *p.AccountID); err == nil {
			out.ID = acc.UUID
			out.DisplayName = s.tenantMemberDisplayName(ctx, tenantID, *p.AccountID, acc.DisplayName)
			out.Avatar = s.resolveAvatarURL(ctx, tenantID, acc.AvatarURL)
			out.Email = acc.Email
			out.DepartmentName = s.accountDepartmentName(ctx, *p.AccountID, tenantID)
		}
	}
	if p.Kind == domroom.ParticipantAgent && p.AgentID != nil {
		if ag, err := s.agents.GetByID(ctx, *p.AgentID); err == nil {
			out.ID = ag.UUID
			out.DisplayName = ag.Name
			out.Avatar = s.resolveAvatarURL(ctx, tenantID, ag.AvatarURL)
			out.DepartmentName = s.agentDepartmentName(ctx, ag.ID)
			out.CanDirectChat = ag.CreatorID == callerAccountID
			if !out.CanDirectChat && s.contacts != nil {
				out.CanDirectChat = s.contacts.AssertAgentVisible(ctx, callerAccountID, tenantID, ag.UUID) == nil
			}
			if reader, ok := s.contacts.(interface {
				GroupAgentCapabilities(context.Context, int64) ([]svccontacts.AgentCapabilitySummary, error)
			}); ok {
				if skills, err := reader.GroupAgentCapabilities(ctx, ag.ID); err == nil {
					out.Skills = make([]AgentSkillSummary, 0, len(skills))
					for _, skill := range skills {
						out.Skills = append(out.Skills, AgentSkillSummary{Name: skill.Name, Slug: skill.Slug})
					}
				}
			}
		}
	}
	return out
}

func (s *impl) tenantMemberDisplayName(ctx context.Context, tenantID, accountID int64, accountDisplayName string) string {
	if s.pool == nil || tenantID <= 0 || accountID <= 0 {
		return roomHumanDisplayName("", accountDisplayName)
	}
	var nickname string
	_ = s.pool.QueryRow(ctx, `
		SELECT COALESCE(nickname, '')
		  FROM tenant_memberships
		 WHERE account_id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		accountID, tenantID).Scan(&nickname)
	return roomHumanDisplayName(nickname, accountDisplayName)
}

func roomHumanDisplayName(membershipNickname, accountDisplayName string) string {
	if name := strings.TrimSpace(membershipNickname); name != "" {
		return name
	}
	name := strings.TrimSpace(accountDisplayName)
	if name == "" || strings.Contains(name, "的组织 管理员") || strings.HasPrefix(name, "预热优化") {
		return ""
	}
	return name
}

// resolveAvatarURL oss:// 等持久化引用 → 客户端可加载 URL; 解析失败/未注入原样返回。
func (s *impl) resolveAvatarURL(ctx context.Context, tenantID int64, raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || s.avatarURLResolver == nil {
		return raw
	}
	if resolved := strings.TrimSpace(s.avatarURLResolver(ctx, tenantID, raw)); resolved != "" {
		return resolved
	}
	return raw
}

func (s *impl) tenantCompanyName(ctx context.Context, tenantID int64) string {
	if s.pool == nil || tenantID <= 0 {
		return ""
	}
	var name string
	_ = s.pool.QueryRow(ctx, `
		SELECT COALESCE(NULLIF(display_name, ''), name, '')
		  FROM tenants
		 WHERE id=$1 AND deleted_at IS NULL`, tenantID).Scan(&name)
	return strings.TrimSpace(name)
}

func (s *impl) accountDepartmentName(ctx context.Context, accountID, tenantID int64) string {
	if s.pool == nil || accountID <= 0 || tenantID <= 0 {
		return ""
	}
	var name string
	_ = s.pool.QueryRow(ctx, `
		SELECT COALESCE(d.name, '')
		  FROM tenant_memberships tm
		  LEFT JOIN departments d ON d.id = tm.department_id AND d.deleted_at IS NULL
		 WHERE tm.account_id=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL`,
		accountID, tenantID).Scan(&name)
	return strings.TrimSpace(name)
}

func (s *impl) agentDepartmentName(ctx context.Context, agentID int64) string {
	if s.pool == nil || agentID <= 0 {
		return ""
	}
	var name string
	_ = s.pool.QueryRow(ctx, `
		SELECT COALESCE(d.name, '')
		  FROM digital_employees de
		  LEFT JOIN departments d ON d.id = de.workspace_id AND d.deleted_at IS NULL
		 WHERE de.id=$1 AND de.deleted_at IS NULL`,
		agentID).Scan(&name)
	return strings.TrimSpace(name)
}

// callerInParticipants 判断 caller 是否是当前 active participant (Kind=human, AccountID==caller)。
func callerInParticipants(callerAccountID int64, parts []domroom.Participant) bool {
	for _, p := range parts {
		if p.Kind == domroom.ParticipantHuman && p.AccountID != nil && *p.AccountID == callerAccountID && p.LeftAt == nil {
			return true
		}
	}
	return false
}

// soleOtherHumanParticipant 找出"除 caller 外唯一的一个 human 参与者"(1v1 场景)；
// 群聊(2 个以上其他 human)返回 ok=false，不做发送前置校验。
func soleOtherHumanParticipant(callerAccountID int64, parts []domroom.Participant) (int64, bool) {
	other := int64(0)
	count := 0
	for _, p := range parts {
		if p.Kind != domroom.ParticipantHuman || p.AccountID == nil || p.LeftAt != nil {
			continue
		}
		if *p.AccountID == callerAccountID {
			continue
		}
		other = *p.AccountID
		count++
	}
	return other, count == 1
}

// findParticipantByUUID 在 active participants 列表里按 uuid 查; 找不到返 nil。
func findParticipantByUUID(parts []domroom.Participant, uuid string) *domroom.Participant {
	for i := range parts {
		if parts[i].UUID == uuid {
			return &parts[i]
		}
	}
	return nil
}
