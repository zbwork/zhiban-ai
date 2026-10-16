// respond.go — ADR-0028 ZAP HITL `/chat/respond` 实装 (Backend Phase 1)。
//
// 流程 (与 ADR §4.6 八步严格一致):
//
//  1. **不副作用校验** convs.AccessibleByAccount + convs.GetByUUID (含 metadata / RoomID)
//     → 任一不符 直接 ErrNotFound (旧 message 不动, 没碰 DB 写)。
//  2. **session 可用守卫** reuseZapSessionID(conv) == "" → Conflict
//     chat.session_expired_for_respond。
//  3. **生成** newStreamID + newAgentMessageUUID + cancelToken (RandomHex / uuid.New)。
//  4. **fanout.Register(newStreamID)**; 失败 → ErrInternal, 旧 message 不动 (还没碰 DB)。
//  5. **原子 PG transaction** ClaimAwaitingUserAndCreateNextRun (helper) 同时完成:
//        SELECT FOR UPDATE 旧 message → INSERT message_streams → INSERT 新 messages
//        → UPDATE 旧 message final + metadata next ids。
//     任一阶段失败 → fanout.Unregister(newStreamID) 兜底 + ErrNotFound / ErrInternal。
//  6. **dispatcher** zapDispatcher.RespondToAwaitingMessage(in); 失败时 finalize 新 stream
//     为 failed (旧 message metadata 不回滚 — 它指向的新行真实存在)。
//  7. **返回** RespondResp{StreamID: newStreamID, NewAgentMessageUUID, ConversationUUID}。
//
// **核心不变量**: 旧 message metadata 一旦写入 next_stream_id/next_agent_message_uuid,
// 这两个 id 必然指向 DB 内已存在的 message_streams + messages 行 (单 tx 保证)。
//
// **安全口径** (ADR §4.8):
//   - session_token 不出站 (dispatcher 内已强制);
//   - runtime raw error_message 不透传 — dispatcher finalize 内已 sanitize 成固定文案;
//   - tenant/account 显式参数, 不读 ctx.Value (与现有 Send 同款);
//   - response_payload 不沉淀到 messages.metadata (含敏感数据, 见 ADR §4.3 末段;
//     Backend Phase 1 暂不做 events_outbox audit, 留 待补项 见下方注释)。

package chat

import (
	"context"
	"strings"

	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
)

// ErrCodeRespond* — ADR-0028 §4.8 安全矩阵: 暴露给客户端的业务码 (透到 apperr.Message)。
const (
	// ErrCodeSessionExpiredForRespond ADR §4.6 步骤 3: conv.metadata.zap_session_id 缺失
	// (从未创建 / 已过期 / 已被 cancel)。客户端可走"重开会话"提示, 不重发原 message。
	ErrCodeSessionExpiredForRespond = "chat.session_expired_for_respond"

	// ErrCodeRespondConflict ADR §4.6 步骤 3 备用 (本 Phase 1 暂未用 — 单 tx helper 把
	// "重复提交"也归到 ErrNotFound 统一不泄漏存在性; 留常量供未来精细错误码扩展)。
	ErrCodeRespondConflict = "chat.respond_conflict"
)

// RespondReq /chat/respond 请求体。
type RespondReq struct {
	ConversationUUID string         `json:"conversation_uuid"`
	AgentMessageUUID string         `json:"agent_message_uuid"` // 原 awaiting_user agent msg uuid
	ResponseKind     string         `json:"response_kind"`      // approval | confirm | form | action
	ResponsePayload  map[string]any `json:"response_payload"`
}

// RespondResp /chat/respond 响应体。
type RespondResp struct {
	StreamID            string `json:"stream_id"` // **新** stream_id; 客户端按 send 同款订阅 SSE
	ConversationUUID    string `json:"conversation_uuid"`
	NewAgentMessageUUID string `json:"new_agent_message_uuid"` // **新** agent 预留消息 uuid
}

// allowedRespondKinds — ADR §4.5 限定 4 种 typed reply block 来源。
var allowedRespondKinds = map[string]bool{
	"approval": true,
	"confirm":  true,
	"form":     true,
	"action":   true,
}

// Respond ADR-0028 §4.6 — HITL /chat/respond 服务方法。
//
// 入参由 transport 层从 middleware.MustAccountID / MustTenantID 显式取 + 透传, 不读 ctx.Value。
//
// 错误码语义 (与 ADR §4.8 安全矩阵一致):
//   - apperr.ErrInvalidParams: 必填字段缺 / response_kind 非法 (transport 也会先做基础校验)。
//   - apperr.ErrNotFound: 任一资源不属于 caller (conv 不存在 / 跨租户 / msg 不属于 conv /
//     msg 不是 awaiting_user / 已被同 user 二次提交) — 统一不区分子原因, 不泄漏存在性。
//   - apperr.Conflict + ErrCodeSessionExpiredForRespond: conv 属于 caller, 但 zap_session_id
//     缺失 / 过期 — 客户端可暴露"重开会话"; 旧 message 仍 awaiting_user 不动。
//   - apperr.ErrInternal: 装配缺 / fanout / DB 抖动 — 调用方 retry。
func (s *impl) Respond(ctx context.Context, accountID, tenantID int64, req RespondReq) (*RespondResp, error) {
	// transport 也会校验, 这里 service 自治再守一次。
	convUUID := strings.TrimSpace(req.ConversationUUID)
	msgUUID := strings.TrimSpace(req.AgentMessageUUID)
	kind := strings.ToLower(strings.TrimSpace(req.ResponseKind))
	if convUUID == "" || msgUUID == "" || kind == "" {
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid / agent_message_uuid / response_kind required")
	}
	// **UUID 格式校验** (Fix 4): repo 层 SQL 把 conv.uuid / m.uuid 当 PG `uuid` 列查, 乱字符串
	// 会触发 22P02 invalid_text_representation, 被 Wrap 成 500。在 service 入口先把非法 UUID
	// 收成 InvalidParams (400), 客户端能拿到清晰的"参数格式错"反馈, 不污染 500 错误率。
	if !id.IsValidUUID(convUUID) {
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid is not a valid uuid")
	}
	if !id.IsValidUUID(msgUUID) {
		return nil, apperr.ErrInvalidParams.Withf("agent_message_uuid is not a valid uuid")
	}
	if !allowedRespondKinds[kind] {
		return nil, apperr.ErrInvalidParams.Withf("response_kind must be one of approval|confirm|form|action")
	}

	// 装配守卫 — ZAP HITL 必须装齐 dispatcher / fanout / streamStore (与 Send 路径一致)。
	if s.zapDispatcher == nil {
		return nil, apperr.ErrInternal.Withf("chat respond: zap dispatcher not wired")
	}
	if s.fanout == nil {
		return nil, apperr.ErrInternal.Withf("chat respond: fanout not wired")
	}
	if s.streamStore == nil {
		// 没装 streamStore 时, helper 会 INSERT message_streams 行但没人会 finalize state,
		// 不构成立即数据损坏, 但偏离 Send 路径约定; fail-closed 防止 dev/test 漏装。
		return nil, apperr.ErrInternal.Withf("chat respond: message stream store not wired")
	}

	// ===== 步骤 1: 不副作用校验 — conv 归属 =====
	// AccessibleByAccount 内部 SQL 即 (tenant_id=? AND account_id=? AND uuid=? AND deleted_at IS NULL);
	// 失败统一 ErrNotFound (不区分跨租户 / 不存在)。
	if s.convs == nil {
		return nil, apperr.ErrInternal.Withf("chat respond: conversations repo not wired")
	}
	ok, err := s.convs.AccessibleByAccount(ctx, tenantID, accountID, convUUID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !ok {
		return nil, apperr.ErrNotFound
	}
	conv, err := s.convs.GetByUUID(ctx, convUUID)
	if err != nil {
		// AccessibleByAccount 已 ok=true; GetByUUID 仍可能 race 失败 (并发删除) — 统一 ErrNotFound。
		return nil, apperr.ErrNotFound
	}

	// ===== 步骤 2: session 可用守卫 =====
	// zhiban-app 当前数字员工单聊可走 agent-direct/WuKong 双通道, conversation
	// 可能是 room-backed。只要 conv 归属 caller 且旧 agent message 是 awaiting_user,
	// 仍允许 respond; helper 会让新 agent message 继承 conv.room_id。
	sessionID := reuseZapSessionID(conv)
	if strings.TrimSpace(sessionID) == "" {
		return nil, apperr.New(apperr.Conflict, ErrCodeSessionExpiredForRespond)
	}

	// agent 解析必须在 claim 之前完成: 如果 agent-direct room-backed conversation
	// 缺依赖或数据不一致, 不应先消费旧 awaiting_user message。
	agentID, err := s.respondAgentID(ctx, conv, msgUUID)
	if err != nil {
		return nil, err
	}
	ag, err := s.agents.GetByID(ctx, agentID)
	if err != nil || ag == nil {
		if err == nil {
			err = apperr.ErrNotFound
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// ===== 步骤 3: 生成 newStreamID + newAgentMessageUUID + cancelToken (仅内存值, 不落库) =====
	newStreamID, _ := id.RandomHex(16)
	cancelToken, _ := id.RandomHex(16)
	newAgentMessageUUID := id.NewUUID()
	if newStreamID == "" || cancelToken == "" || newAgentMessageUUID == "" {
		return nil, apperr.ErrInternal.Withf("chat respond: id generation failed")
	}

	// ===== 步骤 4: fanout.Register(newStreamID); 失败旧 message 不动 =====
	if err := s.fanout.Register(ctx, newStreamID, accountID, tenantID, s.nodeID); err != nil {
		s.logger.Warn(ctx, "chat respond: fanout register failed", "stream_id", newStreamID, "err", err)
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// ===== 步骤 5: 原子 PG transaction (helper 内 BEGIN…COMMIT) =====
	claim, err := s.messages.ClaimAwaitingUserAndCreateNextRun(ctx, dommsg.ClaimAndCreateNextRunArgs{
		TenantID:             tenantID,
		AccountID:            accountID,
		ConversationUUID:     convUUID,
		OldAgentMessageUUID:  msgUUID,
		RespondedByAccountID: accountID,
		ResponseKind:         kind,
		NewStreamID:          newStreamID,
		NewAgentMessageUUID:  newAgentMessageUUID,
		CancelToken:          cancelToken,
		BusNodeID:            s.nodeID,
		NewAgentID:           agentID,
	})
	if err != nil {
		// tx ROLLBACK / FOR UPDATE 锁 0 行 → 旧 message 保持 awaiting_user, 无新 stream/message。
		// fanout entry (步骤 5 已 register) 必须 Unregister, 防 in-memory 泄漏。
		s.fanout.Close(context.Background(), newStreamID)
		// helper 返 apperr.ErrNotFound (statement 0 rows) 或 apperr.ErrInternal (DB 抖动)。
		return nil, err
	}

	if s.respondObserver != nil {
		s.respondObserver.OnRespondStream(context.WithoutCancel(ctx), RespondStreamInfo{
			StreamID:         newStreamID,
			AgentMessageUUID: newAgentMessageUUID,
			AccountID:        accountID,
			TenantID:         tenantID,
			Conversation:     conv,
			Agent:            ag,
		})
	}

	// ===== 步骤 6: dispatcher (复用 conv.metadata.zap_session_id 发 typed reply block) =====
	// 组装 typed reply block (ADR §4.5 shape)。
	replyBlock := buildRespondReplyBlock(kind, msgUUID, req.ResponsePayload)

	// 注: response_payload 故意**不**写 messages.metadata (ADR §4.3 末段)。
	// 待补项(audit): 待补 events_outbox topic 'audit.chat.hitl.respond' 写一条事件, 包含
	// response_payload + responded_by_account_id 用于审计。Backend Phase 1 暂不实装审计;
	// 留给后续 PR (与 docs/pitfalls/zap-chat-not-wired.md 状态同步)。

	// dispatcher 同步入口 (内部跑 SSE 消费 + finalize/awaitFinalize); 返非 nil = 装配错
	// (dispatcher 未 attach 到 chat service / 必填资源缺失等), 此时 dispatcher **没有**
	// finalize 新 stream。如果这里直接 return RespondResp{...}, 客户端会拿到 200 + stream_id
	// 但永远收不到任何 SSE 终态 — 假成功 / 空气流。
	//
	// 正确处理: service 层兜底 finalize 新 stream 为 failed (固定文案; 不透 dispatchErr.Error()),
	// 然后返 ErrInternal。tx 已 commit, 旧 message metadata 指向的新 stream/新 message 是真实行,
	// 终态 failed 让客户端按 message.failed 处理 (不悬空)。
	if dispatchErr := s.zapDispatcher.RespondToAwaitingMessage(ctx, ZapRespondInput{
		NewStreamID:         newStreamID,
		NewAgentMessageUUID: newAgentMessageUUID,
		AccountID:           accountID,
		TenantID:            tenantID,
		Conversation:        conv,
		RoomUUID:            "",
		Agent:               ag,
		AwaitingMessageUUID: msgUUID,
		ResponseKind:        kind,
		ReplyBlock:          replyBlock,
	}); dispatchErr != nil {
		// 不打 raw error string (可能含 runtime URL / token / 内部细节); 只记 stream_id 供运维诊断。
		s.logger.Warn(ctx, "chat respond: dispatcher returned wiring/装配级错, finalize new stream as failed",
			"stream_id", newStreamID)
		s.finalize(ctx, newStreamID, accountID, tenantID, conv.UUID, "", newAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, sanitizedRuntimeFailureMessage, nil)
		return nil, apperr.ErrInternal.Withf("chat respond: dispatcher wiring failed")
	}

	// ===== 步骤 7: 返新 stream_id + new agent message uuid =====
	convUUIDOut := conv.UUID
	if claim != nil && claim.NewRun != nil {
		// claim.NewRun.UUID 在 helper 回读成功时与 newAgentMessageUUID 一致; 防御性兜底。
		if strings.TrimSpace(claim.NewRun.UUID) != "" {
			newAgentMessageUUID = claim.NewRun.UUID
		}
	}
	return &RespondResp{
		StreamID:            newStreamID,
		ConversationUUID:    convUUIDOut,
		NewAgentMessageUUID: newAgentMessageUUID,
	}, nil
}

func (s *impl) respondAgentID(ctx context.Context, conv *domconv.Conversation, agentMessageUUID string) (int64, error) {
	if conv == nil {
		return 0, apperr.ErrNotFound
	}
	if s.messages == nil {
		return 0, apperr.ErrInternal.Withf("chat respond: messages repo not wired")
	}
	oldMsg, err := s.messages.GetByUUID(ctx, agentMessageUUID)
	if err != nil {
		return 0, err
	}
	if oldMsg == nil ||
		oldMsg.TenantID != conv.TenantID ||
		oldMsg.ConversationID != conv.ID ||
		oldMsg.Role != "agent" ||
		oldMsg.Status != "awaiting_user" {
		return 0, apperr.ErrNotFound
	}
	if oldMsg.SenderAgentID != nil && *oldMsg.SenderAgentID > 0 {
		return *oldMsg.SenderAgentID, nil
	}
	if conv.DigitalEmployeeID != nil && *conv.DigitalEmployeeID > 0 {
		return *conv.DigitalEmployeeID, nil
	}
	if conv.RoomID == nil || *conv.RoomID <= 0 {
		return 0, apperr.ErrInternal.Withf("chat respond: conversation missing digital_employee_id")
	}
	if s.agentParticipants == nil {
		return 0, apperr.ErrInternal.Withf("chat respond: room participant lookup not wired")
	}
	parts, err := s.agentParticipants.ListParticipants(ctx, *conv.RoomID)
	if err != nil {
		return 0, apperr.ErrInternal.Wrap(err)
	}
	var agentID int64
	for _, p := range parts {
		if p.Kind != "agent" || p.AgentID == nil || *p.AgentID <= 0 {
			continue
		}
		if agentID != 0 && agentID != *p.AgentID {
			return 0, apperr.ErrInternal.Withf("chat respond: multiple active agent participants")
		}
		agentID = *p.AgentID
	}
	if agentID == 0 {
		return 0, apperr.ErrInternal.Withf("chat respond: no active agent participant")
	}
	return agentID, nil
}

// buildRespondReplyBlock ADR §4.5 — 把 (kind, payload) 翻译成 ZAP runtime 期望的 typed
// reply block (role:"user" 消息内的一个 block)。in_reply_to_message_id 始终带上,
// 帮助 ZAP runtime 关联到原 awaiting_user。in_reply_to_block_index **不**带 (Bus 不存,
// 不伪造)。
//
// 字段透传:
//   - approval → {type:"approval_response", decision, reason?, in_reply_to_message_id}
//   - confirm  → {type:"approval_response", confirmed, in_reply_to_message_id}
//   - form     → {type:"form_response", fields, in_reply_to_message_id}
//   - action   → {type:"action_callback", action_id, params, in_reply_to_message_id}
//
// payload 可能含敏感字段 (form 表单数据): runtime 自己校验/解析 — Bus 不解释字段含义。
func buildRespondReplyBlock(kind, awaitingMessageUUID string, payload map[string]any) map[string]any {
	block := map[string]any{
		"in_reply_to_message_id": awaitingMessageUUID,
	}
	switch kind {
	case "approval":
		block["type"] = "approval_response"
		if v, ok := payload["decision"]; ok {
			block["decision"] = v
		}
		if v, ok := payload["reason"]; ok {
			block["reason"] = v
		}
	case "confirm":
		block["type"] = "approval_response"
		if v, ok := payload["confirmed"]; ok {
			block["confirmed"] = v
		}
	case "form":
		block["type"] = "form_response"
		if v, ok := payload["fields"]; ok {
			block["fields"] = v
		}
	case "action":
		block["type"] = "action_callback"
		if v, ok := payload["action_id"]; ok {
			block["action_id"] = v
		}
		if v, ok := payload["params"]; ok {
			block["params"] = v
		}
	}
	return block
}
