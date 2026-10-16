// Package chat — stop_retry.go
//
// Batch 3B T3.5 / T3.6: stop / retry 流程.
//
// 设计要点:
//
//  1. stop / retry HTTP 入口都按 message_uuid 反查 message_streams; ownership 校验:
//     caller (account_id, tenant_id) 必须等于 stream 行 → 否则 chat.forbidden.
//
//  2. stop 流程:
//     a. state != 'active' → chat.stream_not_active
//     b. owner_node == self → 本进程查 in-process cancel funcs map, 调它; 紧接着
//     UPDATE state='cancelled' (WHERE state='active'), 最后通过 Fanout.Publish 发
//     message.cancelled SSE.
//     c. owner_node != self → Fanout.PublishCancel(owner_node, CancelCommand{...});
//     真实 cancel + state update + SSE 由 owner 节点 cancel listener 干. caller 节点
//     仅返回 202-like 语义 (Stop 返回 nil 表示 "命令已下发").
//     d. PublishCancel 失败 → 兜底 (UPDATE state='cancelled' + SSE message.cancelled),
//     并把错误日志记下来; 客户端看到一致的"已取消"语义而不会卡在 streaming 态.
//     这一步是 best-effort 兜底, 不阻塞 stop API 返回.
//
//  3. cancel listener: chat.Service.StartCancelListener(ctx) 在 cmd/bus 启动时调一次.
//     SubscribeCancel 拉 Redis 订阅, 收到 CancelCommand → 调 stopLocalStream
//     (与 stop 的 owner == self 路径合一).
//
//  4. retry 流程:
//     a. 仅在 messages.role='agent' 且 status ∈ {final, failed, cancelled} 时允许;
//     其它状态 (streaming, awaiting_user) → chat.message_not_retryable.
//     b. ownership: 消息所在 conversation.account_id == caller.account_id (单聊场景);
//     群聊 retry 留 M5 完整版, 这里直接 chat.retry_not_supported_for_groups.
//     c. metadata.retried = true 写回旧 agent message (best-effort).
//     d. 反查触发它的 user message (按 conversation 内最近一条 created_at <= old agent
//     的 user message); 没找到 → chat.retry_user_message_missing.
//     e. 调 RunAgentForConversation 跑新 stream; 复用 versionParams / runtime 解析.
//     f. SSE message.created 在 runAgentInternal 内部 publish; 上层不重复.
//
//  5. 失败路径错误码 (写入 apperr.Error.Message; transport 层 JSON 输出):
//     chat.stream_not_found / chat.stream_not_active / chat.forbidden /
//     chat.message_not_retryable / chat.retry_not_supported_for_groups /
//     chat.retry_user_message_missing.

package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	dombusnode "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/busnode"
	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	dommstream "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/messagestream"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// 3B 错误码 (Message 字段值; 与 docs/modules/m4-conversations-and-messages.md §4.5 对齐).
const (
	ErrCodeStreamNotFound          = "chat.stream_not_found"
	ErrCodeStreamNotActive         = "chat.stream_not_active"
	ErrCodeRetryNotSupportedGroup  = "chat.retry_not_supported_for_groups"
	ErrCodeMessageNotRetryable     = "chat.message_not_retryable"
	ErrCodeRetryUserMessageMissing = "chat.retry_user_message_missing"
)

// ErrStopByUser (3B 返修 #1) 是 stop / cancel listener 触发 ctx.WithCancelCause 时传入的
// sentinel; runAgentGoroutine / processFramesV3 读 context.Cause(ctx) 判断这一来源后
// 走 finalize "cancelled" 而不是 "final", 防止 user stop 后客户端仍收到 message.completed.
//
// 注: ctx 自然超时 (callCtx 10min) / 上游正常结束 (frames closed) / WS error 都不会标这个
// cause, finalize 正常走 final/failed.
var ErrStopByUser = errors.New("chat: stop by user")

// activeStreamRegistry 是 chat.Service 本进程内的 streamID → cancelFunc 映射 (3B T3.5).
//
// 与 fanout 内部的 "stream owner" HASH 不同, 这里只关心 *本节点在跑的 stream*: spawn
// runAgentGoroutine 时注册, stream 终态 (success / fail / cancel) 时注销. stop 路径
// (本地 cancel) 与 cancel listener (Redis 跨节点 cancel) 都通过它找 cancel 函数.
//
// 锁粒度: 一个 sync.Mutex 够用 (chat 单节点典型 active stream 数 ~10², stop 调用频率低).
type activeStreamRegistry struct {
	mu      sync.Mutex
	streams map[string]activeStreamEntry
}

type activeStreamEntry struct {
	// cancel 用 CancelCauseFunc 而不是普通 CancelFunc; 3B 返修 #1 起调用时必须传 cause
	// (Stop / cancel listener 路径传 ErrStopByUser; 进程关闭路径无 cause).
	cancel      context.CancelCauseFunc
	messageUUID string
	tenantID    int64
	accountID   int64
}

func newActiveStreamRegistry() *activeStreamRegistry {
	return &activeStreamRegistry{streams: map[string]activeStreamEntry{}}
}

func (r *activeStreamRegistry) put(streamID string, entry activeStreamEntry) {
	r.mu.Lock()
	r.streams[streamID] = entry
	r.mu.Unlock()
}

// remove 删并返回原 entry; 不存在 → ok=false.
func (r *activeStreamRegistry) remove(streamID string) (activeStreamEntry, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.streams[streamID]
	if ok {
		delete(r.streams, streamID)
	}
	return e, ok
}

// peek 仅取不删 (cancel listener 用; 真正的 cancel + remove 由 finalize 收尾).
func (r *activeStreamRegistry) peek(streamID string) (activeStreamEntry, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.streams[streamID]
	return e, ok
}

// StopReq stop API 入参 (transport 层填).
type StopReq struct {
	MessageUUID string
	Reason      string // 可选; 写到 audit 与 cross-node payload
}

// StopResp stop API 出参.
type StopResp struct {
	StreamID  string `json:"stream_id"`
	OwnerNode string `json:"owner_node_id"`
	Dispatch  string `json:"dispatch"` // "local" / "cross_node" / "fallback"
}

// Stop 取消正在跑的 chat agent stream (Batch 3B T3.5).
//
// 调用契约见文件头. 错误码使用 apperr.Error.Message 字段携带 (与 boundaries.md
// §4.5 chat.* 错误命名风格一致).
//
// stop 不删 message_streams 行 (留观察性); finalize 时已写 finished_at.
func (s *impl) Stop(ctx context.Context, accountID, tenantID int64, req StopReq) (*StopResp, error) {
	if req.MessageUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("message_uuid required")
	}
	if s.streamStore == nil {
		return nil, apperr.ErrInternal.Withf("message_streams store not wired")
	}
	st, err := s.streamStore.GetByMessageUUID(ctx, req.MessageUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf(ErrCodeStreamNotFound)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if st.TenantID != tenantID || st.AccountID != accountID {
		return nil, apperr.ErrForbidden.Withf("chat.forbidden")
	}

	// doc-12 Task D 队列: 若该消息仍是**排队中**任务 (worker 尚未 claim), 原子取消任务并 finalize 预建消息为
	// cancelled —— 不走下面的 running-stream cancel (queued 态没有任何节点在跑 goroutine, 跨节点 cancel 无意义)。
	// CancelQueuedByAgentMessage 用 RETURNING 原子判定: 返回非 nil = 我们抢在 worker claim 之前取消成功;
	// 返回 nil = 已被 claim 成 running 或已终态 → 继续走下面的 running cancel。
	if s.queueEnabled && s.chatTasks != nil {
		if t, err := s.chatTasks.CancelQueuedByAgentMessage(ctx, tenantID, req.MessageUUID); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		} else if t != nil {
			s.finalize(ctx, st.StreamID, accountID, tenantID, t.ConversationUUID, t.RoomUUID, req.MessageUUID,
				[]map[string]any{}, "cancelled", "", "", nil)
			return &StopResp{StreamID: st.StreamID, OwnerNode: st.BusNodeID, Dispatch: "queued_cancelled"}, nil
		}
	}

	if st.State != "active" {
		// 已收尾 (done / cancelled / failed) → 显式错误码, 不静默 idempotent;
		// 客户端看到该错误可以认为最终状态稳定.
		return nil, apperr.ErrConflict.Withf(ErrCodeStreamNotActive)
	}

	reason := req.Reason
	if reason == "" {
		reason = "user_stop"
	}
	resp := &StopResp{StreamID: st.StreamID, OwnerNode: st.BusNodeID}

	// owner == self: 本地 cancel; 不依赖 Redis.
	if st.BusNodeID == s.nodeID {
		s.stopLocalStream(ctx, st, reason, "stop_api")
		resp.Dispatch = "local"
		s.publishStopAudit(ctx, st, accountID, reason, "local")
		return resp, nil
	}

	// owner != self: 跨节点; PublishCancel 让对端 cancel.
	cmd := CancelCommand{
		StreamID:    st.StreamID,
		MessageUUID: st.MessageUUID,
		TenantID:    st.TenantID,
		AccountID:   st.AccountID,
		CancelToken: st.CancelToken,
		Reason:      reason,
	}
	subs, err := s.fanout.PublishCancel(ctx, st.BusNodeID, cmd)
	if err != nil {
		// wire-level 错误 (Redis 抖动 / 序列化失败) → 兜底.
		s.logger.Warn(ctx, "chat stop cross-node publish failed; falling back to optimistic cancel",
			"stream_id", st.StreamID, "owner_node", st.BusNodeID, "err", err)
		s.optimisticCancel(ctx, st, reason)
		resp.Dispatch = "fallback"
		s.publishStopAudit(ctx, st, accountID, reason, "fallback")
		return resp, nil
	}
	// 3B 返修 #3: dead-owner fallback. PUBLISH 投递 0 个订阅者意味着 owner 节点已退出
	// (terminated / crashed) 或还没起 SubscribeCancel. 直接兜底, 不要让客户端卡 streaming.
	if subs == 0 {
		s.logger.Warn(ctx, "chat stop cross-node: 0 subscribers (dead owner); falling back to optimistic cancel",
			"stream_id", st.StreamID, "owner_node", st.BusNodeID)
		s.optimisticCancel(ctx, st, reason)
		resp.Dispatch = "fallback"
		s.publishStopAudit(ctx, st, accountID, reason, "fallback")
		return resp, nil
	}
	resp.Dispatch = "cross_node"
	s.publishStopAudit(ctx, st, accountID, reason, "cross_node")
	return resp, nil
}

// stopLocalStream 在本节点取消 streamID 对应的 chat goroutine + 原子翻 active→cancelled +
// emit message.cancelled. 同时被 Stop (owner == self) 和 cancel listener (跨节点) 调用.
//
// 流程 (3B 返修 #2):
//  1. 从 activeStreams 拿 cancelFunc; 调它传 ErrStopByUser; goroutine 后续 finalize
//     会走 chooseFinalStatus → 'cancelled'.
//  2. 调 streamStore.CancelActiveByStreamID 原子 active→cancelled, 拿到 changed bool:
//     a. changed=true  → 我们真的 cancel 成功了; 主动 publish message.cancelled.
//     b. changed=false → goroutine 已经自然 finalize (done / failed / 或被并发 cancel
//     抢先翻成 cancelled); 重新读 message_streams 拿当前 state 打日志, 但**不要**
//     再 publish 一个矛盾的 message.cancelled (finalize 已经发过对应的 final/failed/cancelled).
//
// 注: 调用方 Stop 已经做过 state=='active' 的预检查; 但 read-then-update 之间存在窄窗口
// 让 finalize 抢先收尾 → CancelActiveByStreamID 的 affected-rows 守卫覆盖该 race, 防止
// 客户端先收 message.completed 再收伪造的 message.cancelled.
func (s *impl) stopLocalStream(ctx context.Context, st *dommstream.Stream, reason, source string) {
	entry, ok := s.activeStreams.remove(st.StreamID)
	if ok && entry.cancel != nil {
		// 3B 返修 #1: 传 ErrStopByUser 给 cancel cause; processFramesV3 据此 finalize 'cancelled'.
		entry.cancel(ErrStopByUser)
	} else {
		s.logger.Info(ctx, "chat stop: no in-process cancel func; finalize may have already run",
			"stream_id", st.StreamID, "source", source, "owner_node", s.nodeID)
	}
	// Stage 3: ZAP best-effort runtime cancel — 仅当 dispatcher 内有 active ZAP session 注册时生效;
	// OpenClaw 路径 / 没拿到 session_id / dispatcher 未装 → noop, 不 panic, 不影响主收尾流程。
	if s.zapDispatcher != nil {
		s.zapDispatcher.CancelStream(ctx, st.StreamID)
	}
	// finalize 的 UpdateStream 走 messages.stream_id (动 messages 表), 不动 message_streams;
	// 这里专门收尾 message_streams 行. 用 CancelActiveByStreamID 拿 affected rows,
	// 跑赢 finalize 才 publish message.cancelled (3B 返修 #2).
	changed, err := s.streamStore.CancelActiveByStreamID(context.Background(), st.StreamID)
	if err != nil {
		s.logger.Warn(ctx, "chat stop: cancel active failed",
			"stream_id", st.StreamID, "err", err)
		// DB 抖动: 既无法保证翻成 cancelled, 也无法判断是否 finalize 已收尾.
		// 安全做法: 不要 publish 冒充的 message.cancelled, 客户端可走 SSE 重连 + GET history 兜底.
		_ = reason
		return
	}
	if !changed {
		// finalize 先赢: 重新读一份 state 落日志, 不 publish 矛盾事件.
		cur, lookupErr := s.streamStore.GetByStreamID(context.Background(), st.StreamID)
		curState := ""
		if lookupErr == nil && cur != nil {
			curState = cur.State
		}
		s.logger.Info(ctx, "chat stop: stream already finished by finalize; skipping spurious cancelled publish",
			"stream_id", st.StreamID, "current_state", curState, "source", source)
		_ = reason
		return
	}
	if err := s.fanout.Publish(context.Background(), st.StreamID, st.AccountID, st.TenantID, StreamEvent{
		Kind:             EventMessageCancelled,
		ConversationUUID: lookupConversationUUID(ctx, s, st.ConversationID),
		MessageUUID:      st.MessageUUID,
		Final:            true,
		Timestamp:        time.Now(),
	}); err != nil {
		s.logger.Warn(ctx, "chat stop: fanout publish cancelled failed",
			"stream_id", st.StreamID, "err", err)
	}
	_ = reason // reason 当前仅用于审计 (publishStopAudit), stopLocalStream 不消费.
}

// optimisticCancel cross-node Stop 在 PublishCancel 失败或 dead-owner 时的本地兜底.
//
// 与 stopLocalStream 区别: 我们 *不在* owner 节点, 所以不调 cancelFunc (没有 entry).
// 仍然走 CancelActiveByStreamID 原子翻 (3B 返修 #2): 真正翻成 cancelled 时才 publish
// message.cancelled; 否则说明 owner 节点的 finalize 已经先收尾, 不要伪造 SSE.
//
// 3B 返修 final patch (已收口): owner 节点在 caller 节点 PublishCancel 失败的情况下 chat
// goroutine 仍可能跑到自然完成, finalize 调入. 但 finalize 现在通过
// UpdateTerminalStateByStreamID 读到 currentState='cancelled' 后会 suppress 掉
// messages.status / SSE publish (见 service.go::finalize 返修注释); 所以客户端不会再收到
// 紧跟 cancelled 之后的 message.completed, messages.status 也不会被反写成 final.
func (s *impl) optimisticCancel(ctx context.Context, st *dommstream.Stream, reason string) {
	changed, err := s.streamStore.CancelActiveByStreamID(context.Background(), st.StreamID)
	if err != nil {
		s.logger.Warn(ctx, "chat stop optimistic: cancel active failed",
			"stream_id", st.StreamID, "err", err)
		_ = reason
		return
	}
	if !changed {
		cur, lookupErr := s.streamStore.GetByStreamID(context.Background(), st.StreamID)
		curState := ""
		if lookupErr == nil && cur != nil {
			curState = cur.State
		}
		s.logger.Info(ctx, "chat stop optimistic: stream already finished by remote finalize; skipping spurious cancelled publish",
			"stream_id", st.StreamID, "current_state", curState)
		_ = reason
		return
	}
	if err := s.fanout.Publish(context.Background(), st.StreamID, st.AccountID, st.TenantID, StreamEvent{
		Kind:             EventMessageCancelled,
		ConversationUUID: lookupConversationUUID(ctx, s, st.ConversationID),
		MessageUUID:      st.MessageUUID,
		Final:            true,
		Timestamp:        time.Now(),
	}); err != nil {
		s.logger.Warn(ctx, "chat stop optimistic: fanout publish cancelled failed",
			"stream_id", st.StreamID, "err", err)
	}
	_ = reason
}

// lookupConversationUUID 反查 conversation_uuid (为了 message.cancelled SSE payload).
// 失败时返回空串, 客户端按 message_uuid 路由仍可定位.
func lookupConversationUUID(ctx context.Context, s *impl, convID int64) string {
	if s.convs == nil {
		return ""
	}
	c, err := s.convs.GetByID(ctx, convID)
	if err != nil {
		return ""
	}
	return c.UUID
}

// StartCancelListener cmd/bus 启动后调一次 (Batch 3B T3.5). 订阅
// bus:cmd:cancel:<self_node_id>, 阻塞地把收到的 CancelCommand 翻译成本地 stop.
//
// 重复调用幂等 (sync.Once); ctx 取消时 listener 退出, 通过 returned cancel 显式解订阅.
func (s *impl) StartCancelListener(ctx context.Context) {
	s.cancelListenerOnce.Do(func() {
		ch, unsub, err := s.fanout.SubscribeCancel(ctx, s.nodeID)
		if err != nil {
			s.logger.Error(ctx, "chat cancel listener subscribe failed", "node_id", s.nodeID, "err", err)
			return
		}
		s.cancelListenerStop = unsub
		go s.cancelListenerLoop(ctx, ch)
	})
}

// StopCancelListener cmd/bus shutdown 调; 关 Redis 订阅.
func (s *impl) StopCancelListener() {
	if s.cancelListenerStop != nil {
		s.cancelListenerStop()
	}
}

func (s *impl) cancelListenerLoop(ctx context.Context, ch <-chan CancelCommand) {
	for {
		select {
		case <-ctx.Done():
			return
		case cmd, ok := <-ch:
			if !ok {
				return
			}
			s.handleRemoteCancel(ctx, cmd)
		}
	}
}

// handleRemoteCancel cancel listener 收到跨节点 CancelCommand 后的本地处理.
//
// 校验顺序:
//  1. message_streams 行存在且 BusNodeID == self (防御性, 防错路由)
//  2. tenant / account 一致 (防御性)
//  3. state == 'active'
//
// 任一不通过 → 日志后丢弃 (跨节点 cancel 是单向 fire-and-forget; caller 节点不等回 ack).
func (s *impl) handleRemoteCancel(ctx context.Context, cmd CancelCommand) {
	if s.streamStore == nil {
		s.logger.Warn(ctx, "chat remote cancel: stream store not wired", "stream_id", cmd.StreamID)
		return
	}
	st, err := s.streamStore.GetByStreamID(ctx, cmd.StreamID)
	if err != nil {
		s.logger.Warn(ctx, "chat remote cancel: stream not found",
			"stream_id", cmd.StreamID, "err", err)
		return
	}
	if st.BusNodeID != s.nodeID {
		s.logger.Warn(ctx, "chat remote cancel: stream owner mismatch (stale routing)",
			"stream_id", cmd.StreamID, "expected_node", s.nodeID, "actual_node", st.BusNodeID)
		return
	}
	if st.TenantID != cmd.TenantID || st.AccountID != cmd.AccountID {
		s.logger.Warn(ctx, "chat remote cancel: tenant/account mismatch (defense in depth)",
			"stream_id", cmd.StreamID,
			"local_tenant", st.TenantID, "cmd_tenant", cmd.TenantID,
			"local_account", st.AccountID, "cmd_account", cmd.AccountID)
		return
	}
	if st.State != "active" {
		s.logger.Info(ctx, "chat remote cancel: stream already finished; nothing to do",
			"stream_id", cmd.StreamID, "state", st.State)
		return
	}
	s.logger.Info(ctx, "chat remote cancel: dispatching local stop",
		"stream_id", cmd.StreamID, "reason", cmd.Reason)
	s.stopLocalStream(ctx, st, cmd.Reason, "remote_cancel")
}

// ----- retry -----

// RetryReq retry API 入参.
type RetryReq struct {
	MessageUUID string
}

// RetryResp retry API 出参.
type RetryResp struct {
	StreamID         string `json:"stream_id"`
	AgentMessageUUID string `json:"agent_message_uuid"`
	OldMessageUUID   string `json:"old_message_uuid"`
}

// Retry 触发 retry; 仅在单聊 (conversations.room_id IS NULL) + agent 消息为终态时允许.
func (s *impl) Retry(ctx context.Context, accountID, tenantID int64, req RetryReq) (*RetryResp, error) {
	if req.MessageUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("message_uuid required")
	}
	oldMsg, err := s.messages.GetByUUID(ctx, req.MessageUUID)
	if err != nil {
		return nil, err
	}
	conv, err := s.convs.GetByID(ctx, oldMsg.ConversationID)
	if err != nil {
		return nil, err
	}
	if conv.TenantID != tenantID || conv.AccountID != accountID {
		return nil, apperr.ErrForbidden.Withf("chat.forbidden")
	}
	if conv.RoomID != nil {
		return nil, apperr.ErrInvalidParams.Withf(ErrCodeRetryNotSupportedGroup)
	}
	if oldMsg.Role != "agent" {
		return nil, apperr.ErrInvalidParams.Withf("chat.retry_only_agent_messages")
	}
	// 仅在终态可 retry; streaming / awaiting_user 都不行.
	switch oldMsg.Status {
	case "final", "failed", "cancelled":
		// ok
	default:
		return nil, apperr.ErrConflict.Withf(ErrCodeMessageNotRetryable)
	}
	if conv.DigitalEmployeeID == nil {
		// 不应该发生; 单聊 conversation 必有 digital_employee_id.
		return nil, apperr.ErrInternal.Withf("single-chat conversation missing digital_employee_id")
	}

	// 找触发该 agent 消息的 user message: conversation 内最近一条 role='user' 且 created_at <= oldMsg.created_at.
	userMsg, err := s.findUserTrigger(ctx, conv.ID, oldMsg.CreatedAt)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrConflict.Withf(ErrCodeRetryUserMessageMissing)
		}
		return nil, err
	}
	userText := extractText(userMsg.Blocks)
	if userText == "" {
		// 极少数情况 user message 无文本 (纯附件等); 3B 单聊不做附件, 视为不可重试.
		return nil, apperr.ErrConflict.Withf(ErrCodeRetryUserMessageMissing)
	}

	// 3B 返修 #2: Retry 必须重新过 contacts visibility 闸口 (与 Send 同源裁决).
	// agent 可能被隐藏 / contact_enabled=false / workspace 不可见 / 已 archive → 即使
	// 历史会话存在也不允许 retry. visibility 为 nil 时 fail-closed.
	if s.visibility == nil {
		return nil, apperr.ErrInternal.Withf("chat service missing visibility dep")
	}
	ag, err := s.agents.GetByID(ctx, *conv.DigitalEmployeeID)
	if err != nil {
		// agent 已删 / GetByID 找不到 → contacts visibility 通常也会返 NotFound,
		// 但这里先于 visibility 一次显式查, 失败时直接 fail-closed.
		return nil, err
	}
	if err := s.visibility.AssertAgentVisible(ctx, accountID, tenantID, ag.UUID); err != nil {
		return nil, err
	}

	// 3B 返修 #4: 先尝试跑新 stream, 成功后再标旧 metadata.retried.
	// 这样如果 RunAgentForConversation 失败 (runtime 不可达 / 守卫拒 / DB 错), 旧消息保持
	// 原貌, 客户端可以重试. markRetried 失败也不回滚新 stream (best-effort, 仅日志).
	out, err := s.RunAgentForConversation(ctx, RunAgentInput{
		AccountID:    accountID,
		TenantID:     tenantID,
		Conversation: conv,
		RoomUUID:     "",
		Agent:        ag,
		PromptText:   userText,
	})
	if err != nil {
		return nil, err
	}
	s.markRetried(ctx, oldMsg)
	s.publishRetryAudit(ctx, conv.UUID, oldMsg.UUID, out.AgentMessageUUID, accountID, tenantID)
	return &RetryResp{
		StreamID:         out.StreamID,
		AgentMessageUUID: out.AgentMessageUUID,
		OldMessageUUID:   oldMsg.UUID,
	}, nil
}

// findUserTrigger 找 conversation 内最近一条 user message; 没找到 → apperr.ErrNotFound.
//
// 实现走 messages.History (按 created_at DESC), 取第一条 role='user' 且 created_at <= boundary.
// 简单实现, 3B 单聊场景一次 50 条够用. 若历史很长需要分页, 后续再加 repo 方法.
func (s *impl) findUserTrigger(ctx context.Context, conversationID int64, boundary time.Time) (*dommsg.Message, error) {
	// 多取一些 (200) 兜底, 仍然在 message repo 的 limit 上限内.
	hist, err := s.messages.History(ctx, dommsg.HistoryFilter{ConversationID: conversationID, Limit: 200})
	if err != nil {
		return nil, err
	}
	// History 返回是 chronological asc; 倒着找最后一条 user message (created_at <= boundary).
	for i := len(hist) - 1; i >= 0; i-- {
		m := hist[i]
		if m.Role == "user" && !m.CreatedAt.After(boundary) {
			return &m, nil
		}
	}
	return nil, apperr.ErrNotFound
}

// extractText 把 message.blocks 拼成一段文本; 仅识别 plain / markdown text; 其它类型忽略.
// 3B 单聊 retry 仅支持纯文本消息; 附件留 3C.
func extractText(blocks []map[string]any) string {
	if len(blocks) == 0 {
		return ""
	}
	out := ""
	for _, b := range blocks {
		t, _ := b["type"].(string)
		switch t {
		case "plain", "markdown", "text":
			if v, ok := b["text"].(string); ok {
				if out != "" {
					out += "\n"
				}
				out += v
			}
		}
	}
	return out
}

// markRetried 把 metadata.retried=true 写回旧 agent message (best-effort).
// 我们用 message repo 的 UpdateStream (终态写入) 路径会把 metadata 整段覆盖; 这里改用一个
// 轻量 SQL 直更, 但当前 message repo 没有方法; 临时方案: 直接走 UpdateStream 把 metadata
// 与旧字段一起拼回. 失败 → 仅日志, 不阻塞 retry.
func (s *impl) markRetried(ctx context.Context, m *dommsg.Message) {
	if m == nil || m.Status == "streaming" {
		return
	}
	meta := map[string]any{}
	for k, v := range m.Metadata {
		meta[k] = v
	}
	meta["retried"] = true
	if err := s.messages.UpdateStream(context.Background(), m.StreamID, m.Blocks, m.Status, m.Final, m.ErrorCode, m.ErrorMessage, meta); err != nil {
		s.logger.Warn(ctx, "chat retry: mark old metadata.retried failed",
			"message_uuid", m.UUID, "err", err)
	}
}

// ----- audit -----

// publishStopAudit best-effort 写 audit.message.stopped 到 events_outbox.
// pub / pool 为 nil 时静默跳过 (chat.New 走传统 wiring 时 pub 为 nil; 单测使用).
func (s *impl) publishStopAudit(ctx context.Context, st *dommstream.Stream, callerAccountID int64, reason, dispatch string) {
	if s.eventPub == nil || s.txBegin == nil {
		return
	}
	convUUID := lookupConversationUUID(ctx, s, st.ConversationID)
	payload, _ := json.Marshal(map[string]any{
		"severity":      "info",
		"resource_kind": "message",
		"resource_uuid": st.MessageUUID,
		"account_id":    callerAccountID,
		"data": map[string]any{
			"stream_id":         st.StreamID,
			"conversation_uuid": convUUID,
			"owner_node_id":     st.BusNodeID,
			"reason":            reason,
			"dispatch":          dispatch,
		},
	})
	s.writeOutboxBestEffort(ctx, "audit.message.stopped", st.TenantID, payload)
}

// publishEMPFallbackAudit (Batch 3D T3.10) 写 audit.emp.block.fallback 到 events_outbox.
//
// 每个 fallback 事件 (一条 message 多个 block fallback 时 fbs 长度>1) 单独写一行,
// 让 admin 报表能按 (original_type, reason) 维度聚合统计 (M8 起接 prometheus).
//
// eventPub/txBegin nil 时静默跳过 (单测 / dev 模式).
func (s *impl) publishEMPFallbackAudit(ctx context.Context, streamID string, tenantID int64, msgUUID string, fbs []EMPFallbackEvent) {
	if s.eventPub == nil || s.txBegin == nil || len(fbs) == 0 {
		return
	}
	for _, ev := range fbs {
		payload, _ := json.Marshal(map[string]any{
			"severity":      "info",
			"resource_kind": "message",
			"resource_uuid": msgUUID,
			"data": map[string]any{
				"stream_id":     streamID,
				"original_type": ev.OriginalType,
				"fallback_type": ev.FallbackType,
				"reason":        ev.Reason,
				"index":         ev.Index,
			},
		})
		s.writeOutboxBestEffort(ctx, "audit.emp.block.fallback", tenantID, payload)
	}
}

func (s *impl) publishRetryAudit(ctx context.Context, convUUID, oldMessageUUID, newMessageUUID string, callerAccountID, tenantID int64) {
	if s.eventPub == nil || s.txBegin == nil {
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"severity":      "info",
		"resource_kind": "message",
		"resource_uuid": newMessageUUID,
		"account_id":    callerAccountID,
		"data": map[string]any{
			"old_message_uuid":  oldMessageUUID,
			"conversation_uuid": convUUID,
		},
	})
	s.writeOutboxBestEffort(ctx, "audit.message.retried", tenantID, payload)
}

// writeOutboxBestEffort 开短 tx + Publish; 任一错误仅日志.
func (s *impl) writeOutboxBestEffort(ctx context.Context, topic string, tenantID int64, payload []byte) {
	tx, err := s.txBegin(ctx)
	if err != nil {
		s.logger.Warn(ctx, "chat audit publish: begin tx failed", "topic", topic, "err", err)
		return
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := s.eventPub.Publish(ctx, tx.Wrap(), domevent.Event{
		Topic:    topic,
		TenantID: tenantID,
		Payload:  payload,
	}); err != nil {
		s.logger.Warn(ctx, "chat audit publish failed", "topic", topic, "err", err)
		return
	}
	if err := tx.Commit(ctx); err != nil {
		s.logger.Warn(ctx, "chat audit publish: commit tx failed", "topic", topic, "err", err)
	}
}

// nodeWatch helper — 未来如果要做"节点最后心跳已老"判断, 这里挂接; 3B 不消费.
var _ = (*dombusnode.Node)(nil)

// errStopFallbackDispatched sentinel 给单测断言 cross-node fallback 路径 (3B 暂留空).
var errStopFallbackDispatched = fmt.Errorf("stop dispatched via fallback")

var _ = errStopFallbackDispatched
