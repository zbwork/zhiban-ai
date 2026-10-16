// queue.go — doc-12 Task D chat 消息队列 worker 侧 (MVP, feature-flag)。
//
// Send 把"预建消息 + stream + message.created"落好后入队 chat_message_tasks; 本文件的 worker 异步消费:
// RequeueExpired(lease 恢复) → ClaimNext(FOR UPDATE SKIP LOCKED + 同会话串行 + lease) → ExecuteQueuedTask
// (现场重解析 endpoint/version + 取 stream 归属到本节点 + 复用 runAgentGoroutine 真实执行) → 终态。
//
// 集群: 每个 bus 进程跑本 worker (多副本天然并行); 同 conversation 串行由 DB partial unique 硬保证 (见 migration 000023)。
// 安全: 任务行不含 token/endpoint/pod path; 现场按 agent_uuid 重解析, 不下发客户端、不落敏感日志。
package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	domchattask "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/chattask"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
)

// ChatTaskWorkerConfig chat 队列 worker 行为 (cmd 注入; 零值用默认)。
type ChatTaskWorkerConfig struct {
	Concurrency int           // 进程内并发消费 goroutine 数 (默认 4; 跨会话并行, 同会话仍串行)
	Interval    time.Duration // 空轮等待 (默认 2s)
	LeaseTTL    time.Duration // claim 持锁时长; **须覆盖最长流式时长** (默认 10min)
	MaxAttempts int           // 超过 → dlq (默认 5; 与表 max_attempts 对齐)
}

func (c *ChatTaskWorkerConfig) withDefaults() {
	if c.Concurrency <= 0 {
		c.Concurrency = 4
	}
	if c.Interval <= 0 {
		c.Interval = 2 * time.Second
	}
	if c.LeaseTTL <= 0 {
		c.LeaseTTL = 10 * time.Minute
	}
	if c.MaxAttempts <= 0 {
		c.MaxAttempts = 5
	}
}

// taskOutcome ExecuteQueuedTask 的结果分类。
type taskOutcome int

const (
	outcomeDone     taskOutcome = iota // 已执行 (runAgentGoroutine 跑完, 消息已 finalize) → MarkDone
	outcomeDeferred                    // 实例/Agent 未就绪正常等待 → MarkDeferred (不消耗 attempts)
	outcomeRetry                       // 可重试瞬时错误 (resolve endpoint 等) → retry/dlq
	outcomeFailed                      // 不可恢复 (agent 不存在/跨租户/version 缺失) → MarkFailed + 预建消息标 failed
)

// StartChatTaskWorker 启动 chat 队列 worker (cmd/bus 后台 goroutine; ctx cancel 干净停)。未装任务仓储则 no-op。
// worker 始终启动以消费群聊 ForceQueue 任务；普通 /chat/send 是否入队仍由 queueEnabled 控制。
// readyChecker 此刻注入 (runtimehosting.Service 构造晚于 chat.Service; 在 worker goroutine 启动前赋值, 天然 happens-before)。
func (s *impl) StartChatTaskWorker(ctx context.Context, readyChecker RuntimeReadyChecker, cfg ChatTaskWorkerConfig) {
	if s.chatTasks == nil {
		return
	}
	s.readyChecker = readyChecker
	cfg.withDefaults()
	s.logger.Info(ctx, "chat task worker start", "concurrency", cfg.Concurrency, "lease_ttl", cfg.LeaseTTL.String(), "node", s.nodeID)
	for i := 0; i < cfg.Concurrency; i++ {
		go s.chatTaskLoop(ctx, cfg, i)
	}
}

func (s *impl) chatTaskLoop(ctx context.Context, cfg ChatTaskWorkerConfig, idx int) {
	defer func() {
		if rec := recover(); rec != nil {
			s.logger.Error(ctx, "chat task worker panic", "idx", idx, "recover", rec)
		}
	}()
	workerID := fmt.Sprintf("%s#%d", s.nodeID, idx)
	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		// 仅 idx==0 负责 lease 恢复 (避免每个 goroutine 都扫)。
		if idx == 0 {
			if n, err := s.chatTasks.RequeueExpired(ctx, time.Now().Add(s.chatBackoff(0)), 50); err != nil {
				s.logger.Warn(ctx, "chat task requeue expired failed", "err", err.Error())
			} else if n > 0 {
				s.logger.Info(ctx, "chat task requeued (lease expired)", "count", n)
			}
		}
		t, err := s.chatTasks.ClaimNext(ctx, workerID, cfg.LeaseTTL)
		if err != nil {
			s.logger.Warn(ctx, "chat task claim failed", "err", err.Error())
			s.sleep(ctx, ticker)
			continue
		}
		if t == nil {
			s.sleep(ctx, ticker) // 无可抢 → 等下一 tick
			continue
		}
		s.processChatTask(ctx, t, cfg)
		// 抢到就紧接着再抢 (积压尽快消费); 无积压时回到 sleep。
	}
}

func (s *impl) sleep(ctx context.Context, ticker *time.Ticker) {
	select {
	case <-ctx.Done():
	case <-ticker.C:
	}
}

func (s *impl) processChatTask(ctx context.Context, t *domchattask.Task, cfg ChatTaskWorkerConfig) {
	outcome, reason := s.executeQueuedTask(ctx, t)
	switch outcome {
	case outcomeDone:
		if err := s.chatTasks.MarkDone(ctx, t.ID); err != nil {
			s.logger.Warn(ctx, "chat task mark done failed", "id", t.ID, "err", err.Error())
		}
	case outcomeDeferred:
		// 实例/Agent 未就绪: 退避重试, 不消耗 attempts (MarkDeferred 内部还原 claim 的 ++)。
		_ = s.chatTasks.MarkDeferred(ctx, t.ID, reason, time.Now().Add(s.chatBackoff(t.Attempts)))
	case outcomeFailed:
		// 不可恢复: 终态 + 预建消息标 failed (不留 streaming 僵尸)。
		_ = s.chatTasks.MarkFailed(ctx, t.ID, reason)
		s.failQueuedAgentMessage(ctx, t, reason)
	case outcomeRetry:
		if t.Attempts >= cfg.MaxAttempts {
			_ = s.chatTasks.MarkDLQ(ctx, t.ID, reason)
			s.failQueuedAgentMessage(ctx, t, reason)
		} else {
			_ = s.chatTasks.MarkRetry(ctx, t.ID, reason, time.Now().Add(s.chatBackoff(t.Attempts)))
		}
	}
}

// failQueuedAgentMessage 把仍 streaming 的预留 agent 消息收尾为 failed (终态任务时, 防客户端永远转圈)。
// finalize 幂等 (UpdateTerminalStateByStreamID race-gated): 若 runOpenClawV3 已收尾则此调用无副作用。
// 内部错误码不下发客户端 (finalize → transport sanitize)。
func (s *impl) failQueuedAgentMessage(ctx context.Context, t *domchattask.Task, reason string) {
	s.finalize(ctx, t.StreamID, t.AccountID, t.TenantID, t.ConversationUUID, t.RoomUUID, t.AgentMessageUUID,
		[]map[string]any{}, "failed", "chat.task_failed", reason, nil)
}

// executeQueuedTask 现场重解析 + 取 stream 归属 + 复用 runAgentGoroutine 真实执行 (阻塞至流结束)。
func (s *impl) executeQueuedTask(ctx context.Context, t *domchattask.Task) (taskOutcome, string) {
	// 1) 重解析 agent (tenant fail-closed: 必须本租户或平台)。
	ag, err := s.agents.GetByUUID(ctx, t.AgentUUID)
	if err != nil || ag == nil {
		return outcomeFailed, "agent_not_found"
	}
	if ag.TenantID != t.TenantID && ag.Source != "platform" {
		return outcomeFailed, "agent_cross_tenant"
	}
	runtimeAccountID, err := runtimeAccountIDForAgent(t.AccountID, ag)
	if err != nil {
		return outcomeFailed, "runtime_owner_invalid"
	}

	// 2) 实例就绪检查 (未就绪 → defer + 触发预热, 不消耗 attempts; 先于回读正文, warming 时不做无谓查询)。
	if s.readyChecker != nil && ag.RuntimeEnvironmentID != nil && *ag.RuntimeEnvironmentID > 0 {
		// ADR-0037 Phase 3/5: BYOK 数字员工查/建的是自己的专属 pod。
		var readyAgentUUID *string
		if ag.ModelSource == "byok" {
			readyAgentUUID = &ag.UUID
		}
		ready, status, _, cerr := s.readyChecker.CheckReady(ctx, t.TenantID, runtimeAccountID, *ag.RuntimeEnvironmentID, readyAgentUUID)
		if cerr != nil {
			return outcomeRetry, "check_ready_error"
		}
		if !ready {
			return outcomeDeferred, "runtime_warming:" + status
		}
	}

	// 2.5) 回读 user 消息取 prompt (任务表不复制正文; messages 是正文事实源)。
	// **fail-closed**: 任一防御校验不过 → 终态失败, 不调用 Agent (避免用错误/越权消息驱动 Agent)。
	//   不存在 / 跨租户 / 跨会话 / 非 user 角色 / 非 final 终态 / 发送账号不匹配。
	userMsg, err := s.messages.GetByUUID(ctx, t.UserMessageUUID)
	if err != nil || userMsg == nil {
		return outcomeFailed, "user_message_not_found"
	}
	if userMsg.TenantID != t.TenantID {
		return outcomeFailed, "user_message_cross_tenant"
	}
	if userMsg.ConversationID != t.ConversationID {
		return outcomeFailed, "user_message_cross_conversation"
	}
	if userMsg.Role != "user" {
		return outcomeFailed, "user_message_not_user"
	}
	if userMsg.Status != "final" {
		return outcomeFailed, "user_message_not_final"
	}
	if userMsg.SenderAccountID == nil || *userMsg.SenderAccountID != t.AccountID {
		return outcomeFailed, "user_message_cross_account"
	}
	promptText := promptTextWithSkillSlugs(
		extractPromptText(userMsg.Blocks),
		skillSlugsFromBlocks(userMsg.Blocks),
	)

	// 3) framework 分流 (Plan 16 Phase 2): openclaw → 现场解析 endpoint + version 快照;
	// zap → 跳过 endpoint/version, 由 ZAP dispatcher 现场 EnsureSession + SSE 自闭环。
	// 其它 framework → 终态 failed (与 Send 同步路径一致, 不重试)。
	framework, ferr := s.frameworkForAgent(ctx, ag, s.runtimeEnvFW)
	if ferr != nil {
		return outcomeFailed, "framework_lookup_failed"
	}
	selectedModel := selectedConversationModel(userMsg.Metadata)
	if err := s.validateConversationModel(ctx, t.AccountID, t.TenantID, ag, framework, selectedModel); err != nil {
		return outcomeFailed, "model_unavailable"
	}
	if isZapWireFramework(framework) {
		if s.zapDispatcher == nil || s.identityResolver == nil {
			return outcomeFailed, "zap_dispatch_not_wired"
		}
		// 取 stream 归属到本执行节点 (与 openclaw 同步路径口径一致)。
		if err := s.fanout.Register(ctx, t.StreamID, t.AccountID, t.TenantID, s.nodeID); err != nil {
			return outcomeRetry, "fanout_register"
		}
		if s.streamStore != nil {
			if err := s.streamStore.UpdateOwnerNode(ctx, t.StreamID, s.nodeID); err != nil {
				s.logger.Warn(ctx, "chat task update stream owner failed", "stream_id", t.StreamID, "err", err.Error())
			}
		}
		streamCtx, streamCancel := context.WithCancelCause(context.Background())
		defer streamCancel(nil)
		if s.activeStreams != nil {
			s.activeStreams.put(t.StreamID, activeStreamEntry{
				cancel:      streamCancel,
				messageUUID: t.AgentMessageUUID,
				tenantID:    t.TenantID,
				accountID:   t.AccountID,
			})
		}
		// Stage 2 (session 复用): 拉 metadata 一次 — dispatcher 优先复用 metadata.zap_session_id;
		// fail-closed: 找不到 conv 行 / 跨租户跨账号 → 直接 outcomeFailed (不能用错误 conv 驱动 Agent)。
		conv, err := s.convs.GetByID(ctx, t.ConversationID)
		if err != nil || conv == nil {
			return outcomeFailed, "conversation_not_found"
		}
		if !queuedConversationMatches(t, conv) {
			return outcomeFailed, "conversation_cross_tenant"
		}
		// dispatcher.Send 同步跑到终态 (内部已 finalize message + fanout.Close); 出错 (返非 nil) =
		// 装配错或 ctx 异常, 仍算"已消费", 由 finalize 写入 message failed。worker 标 Done。
		if err := s.zapDispatcher.Send(streamCtx, ZapDispatchInput{
			StreamID:         t.StreamID,
			AccountID:        t.AccountID,
			TenantID:         t.TenantID,
			Conversation:     conv,
			RoomUUID:         t.RoomUUID,
			Agent:            ag,
			PromptText:       promptText,
			UserBlocks:       cloneZapOutboundBlocks(userMsg.Blocks),
			AgentMessageUUID: t.AgentMessageUUID,
			UserMessageUUID:  t.UserMessageUUID,
			InputMessageUUID: t.UserMessageUUID,
			UserMetadata:     userMsg.Metadata,
		}); err != nil {
			s.logger.Warn(ctx, "chat zap dispatcher returned error", "stream_id", t.StreamID, "err", err.Error())
		}
		return outcomeDone, ""
	}
	if framework == FrameworkHermes {
		if s.hermesDispatcher == nil {
			return outcomeFailed, "hermes_dispatch_not_wired"
		}
		if err := s.fanout.Register(ctx, t.StreamID, t.AccountID, t.TenantID, s.nodeID); err != nil {
			return outcomeRetry, "fanout_register"
		}
		if s.streamStore != nil {
			if err := s.streamStore.UpdateOwnerNode(ctx, t.StreamID, s.nodeID); err != nil {
				s.logger.Warn(ctx, "chat task update stream owner failed", "stream_id", t.StreamID, "err", err.Error())
			}
		}
		streamCtx, streamCancel := context.WithCancelCause(context.Background())
		defer streamCancel(nil)
		if s.activeStreams != nil {
			s.activeStreams.put(t.StreamID, activeStreamEntry{
				cancel:      streamCancel,
				messageUUID: t.AgentMessageUUID,
				tenantID:    t.TenantID,
				accountID:   t.AccountID,
			})
		}
		conv, err := s.convs.GetByID(ctx, t.ConversationID)
		if err != nil || conv == nil {
			return outcomeFailed, "conversation_not_found"
		}
		if !queuedConversationMatches(t, conv) {
			return outcomeFailed, "conversation_cross_tenant"
		}
		if err := s.hermesDispatcher.Send(streamCtx, HermesDispatchInput{
			SelectedModel:    selectedModel,
			StreamID:         t.StreamID,
			AccountID:        t.AccountID,
			RuntimeAccountID: runtimeAccountID,
			TenantID:         t.TenantID,
			Conversation:     conv,
			RoomUUID:         t.RoomUUID,
			Agent:            ag,
			PromptText:       promptText,
			AgentMessageUUID: t.AgentMessageUUID,
			UserMessageUUID:  t.UserMessageUUID,
			InputMessageUUID: t.UserMessageUUID,
		}); err != nil {
			if errors.Is(err, ErrHermesRuntimeWarming) {
				s.fanout.Close(ctx, t.StreamID)
				if s.activeStreams != nil {
					s.activeStreams.remove(t.StreamID)
				}
				return outcomeRetry, "runtime_warming"
			}
			s.logger.Warn(ctx, "chat hermes dispatcher returned error", "stream_id", t.StreamID, "err", err.Error())
		}
		return outcomeDone, ""
	}
	if framework == FrameworkGeneric {
		if s.genericRuntime == nil {
			return outcomeFailed, "generic_runtime_not_wired"
		}
		if err := s.fanout.Register(ctx, t.StreamID, t.AccountID, t.TenantID, s.nodeID); err != nil {
			return outcomeRetry, "fanout_register"
		}
		if s.streamStore != nil {
			if err := s.streamStore.UpdateOwnerNode(ctx, t.StreamID, s.nodeID); err != nil {
				s.logger.Warn(ctx, "chat task update stream owner failed", "stream_id", t.StreamID, "err", err.Error())
			}
		}
		streamCtx, streamCancel := context.WithCancelCause(ctx)
		defer streamCancel(nil)
		if s.activeStreams != nil {
			s.activeStreams.put(t.StreamID, activeStreamEntry{
				cancel:      streamCancel,
				messageUUID: t.AgentMessageUUID,
				tenantID:    t.TenantID,
				accountID:   t.AccountID,
			})
		}
		conv, err := s.convs.GetByID(ctx, t.ConversationID)
		if err != nil || conv == nil {
			return outcomeFailed, "conversation_not_found"
		}
		if !queuedConversationMatches(t, conv) {
			return outcomeFailed, "conversation_cross_tenant"
		}
		s.runGenericRuntime(streamCtx, t.StreamID, runAgentInternalIn{
			AccountID:        t.AccountID,
			TenantID:         t.TenantID,
			Conversation:     conv,
			RoomUUID:         t.RoomUUID,
			Agent:            ag,
			PromptText:       promptText,
			Framework:        FrameworkGeneric,
			UserMessageUUID:  t.UserMessageUUID,
			InputMessageUUID: t.UserMessageUUID,
			UserMetadata:     userMsg.Metadata,
			UserBlocks:       cloneZapOutboundBlocks(userMsg.Blocks),
		}, t.AgentMessageUUID)
		return outcomeDone, ""
	}
	if framework == FrameworkSupportBuiltin {
		if err := s.fanout.Register(ctx, t.StreamID, t.AccountID, t.TenantID, s.nodeID); err != nil {
			return outcomeRetry, "fanout_register"
		}
		if s.streamStore != nil {
			if err := s.streamStore.UpdateOwnerNode(ctx, t.StreamID, s.nodeID); err != nil {
				s.logger.Warn(ctx, "chat task update stream owner failed", "stream_id", t.StreamID, "err", err.Error())
			}
		}
		streamCtx, streamCancel := context.WithCancelCause(context.Background())
		defer streamCancel(nil)
		if s.activeStreams != nil {
			s.activeStreams.put(t.StreamID, activeStreamEntry{
				cancel:      streamCancel,
				messageUUID: t.AgentMessageUUID,
				tenantID:    t.TenantID,
				accountID:   t.AccountID,
			})
		}
		conv, err := s.convs.GetByID(ctx, t.ConversationID)
		if err != nil || conv == nil {
			return outcomeFailed, "conversation_not_found"
		}
		if !queuedConversationMatches(t, conv) {
			return outcomeFailed, "conversation_cross_tenant"
		}
		s.runSupportResponderGoroutine(streamCtx, t.StreamID, runAgentInternalIn{
			AccountID:        t.AccountID,
			TenantID:         t.TenantID,
			Conversation:     conv,
			RoomUUID:         t.RoomUUID,
			Agent:            ag,
			PromptText:       promptText,
			Framework:        FrameworkSupportBuiltin,
			UserMessageUUID:  t.UserMessageUUID,
			InputMessageUUID: t.UserMessageUUID,
		}, t.AgentMessageUUID)
		return outcomeDone, ""
	}
	if framework != FrameworkOpenClaw {
		return outcomeFailed, "framework_unsupported"
	}

	// per-user runtime 解析使用 runtimeAccountID：private agent 取 creator，其它取任务 caller。
	// runtime.warming (errRuntimeNotReady) 是瞬时态 → retry; protocol_unsupported / 配置
	// 错 / runtime row 不在 → 终态 failed (不要无限重试堆积队列)。
	ep, _, err := s.resolveOpenClawV3Endpoint(ctx, t.TenantID, runtimeAccountID, ag)
	if err != nil {
		if errors.Is(err, errRuntimeNotReady) {
			return outcomeRetry, "runtime_warming"
		}
		return outcomeFailed, "resolve_endpoint"
	}
	verParams, err := s.loadVersionParams(ctx, ag)
	if err != nil {
		return outcomeFailed, "version_params_missing" // 版本快照缺失 = 配置问题, 不重试
	}

	verParams.SelectedModel = selectedModel
	// 4) 取 stream 归属到**本执行节点** (Send 节点创建时 owner=Send; running cancel 须路由到执行节点)。
	if err := s.fanout.Register(ctx, t.StreamID, t.AccountID, t.TenantID, s.nodeID); err != nil {
		return outcomeRetry, "fanout_register"
	}
	if s.streamStore != nil {
		if err := s.streamStore.UpdateOwnerNode(ctx, t.StreamID, s.nodeID); err != nil {
			s.logger.Warn(ctx, "chat task update stream owner failed", "stream_id", t.StreamID, "err", err.Error())
		}
	}

	// 5) 本节点 in-process cancel 注册 + 同步执行 (阻塞至流结束; runAgentGoroutine 内部 finalize + fanout.Close)。
	// 与 runAgentInternal 的 detached goroutine 不同: 这里同步跑, 用 defer 在跑完后释放 ctx;
	// 运行期间 stop 仍能通过 activeStreams 拿到 streamCancel 中断 (cause=ErrStopByUser 先到先赢, defer 退化为 no-op)。
	streamCtx, streamCancel := context.WithCancelCause(context.Background())
	defer streamCancel(nil)
	if s.activeStreams != nil {
		s.activeStreams.put(t.StreamID, activeStreamEntry{
			cancel:      streamCancel,
			messageUUID: t.AgentMessageUUID,
			tenantID:    t.TenantID,
			accountID:   t.AccountID,
		})
	}
	s.runAgentGoroutine(streamCtx, t.StreamID, t.AccountID, runtimeAccountID, t.TenantID, ep, ag,
		promptText, t.ConversationUUID, t.RoomUUID, t.AgentMessageUUID, verParams, t.UserMessageUUID)
	// runAgentGoroutine 已跑完并 finalize 消息 (final/failed/cancelled); 任务视为已消费。
	return outcomeDone, ""
}

func queuedConversationMatches(t *domchattask.Task, conv *domconv.Conversation) bool {
	if t == nil || conv == nil || conv.TenantID != t.TenantID {
		return false
	}
	// A non-empty room UUID is produced only by the trusted group trigger after
	// membership/agent-participant checks. Group conversations are shared rows,
	// so their AccountID is not the per-message caller and must not be compared.
	if strings.TrimSpace(t.RoomUUID) != "" && conv.RoomID != nil {
		return true
	}
	return conv.AccountID == t.AccountID
}

// extractPromptText 从 user 消息 blocks 复原 prompt。`plain` 是旧 /chat/send
// 形态，`text/markdown` 来自 WuKong mixed / 富输入降级；队列必须兼容三者，
// 否则持久化了 skill block 的 mixed 消息会在 worker 中只剩技能指令而丢正文。
func extractPromptText(blocks []map[string]any) string {
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		bt, _ := b["type"].(string)
		if bt != "plain" && bt != "text" && bt != "markdown" {
			continue
		}
		txt, _ := b["text"].(string)
		if txt == "" && bt == "markdown" {
			txt, _ = b["markdown"].(string)
		}
		if txt != "" {
			parts = append(parts, txt)
		}
	}
	return strings.Join(parts, "\n")
}

// chatBackoff 任务退避 (capped 2s/5s/15s/30s)。
func (s *impl) chatBackoff(attempts int) time.Duration {
	switch {
	case attempts <= 0:
		return 2 * time.Second
	case attempts == 1:
		return 5 * time.Second
	case attempts == 2:
		return 15 * time.Second
	default:
		return 30 * time.Second
	}
}
