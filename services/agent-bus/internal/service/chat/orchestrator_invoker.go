// orchestrator_invoker.go — doc-14 Objective E5: chat.impl 作为 deorch.AgentInvoker 的真实实现。
//
// 编排型数字员工运行期 (deorch.Executor) 通过本接口同步调用一个 child 数字员工:
// 复用现有 OpenClaw Gateway v3 chat.send 链路 (resolveOpenClawV3Endpoint + CallStream +
// parseAgentFrame), 排空帧取 child 的最终 assistant 文本。**不写**任何用户可见 conversation/message;
// child 输出只回给编排器进 orchestration/a2a trace (不污染用户历史)。tenant fail-closed。
package chat

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/gatewayws"
	zapadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/deorch"
)

// chatAgentInvoker 把 *impl 适配成 deorch.AgentInvoker (避免给 impl 加泛化 Invoke 方法)。
type chatAgentInvoker struct{ svc *impl }

var _ deorch.AgentInvoker = chatAgentInvoker{}

func (a chatAgentInvoker) Invoke(ctx context.Context, in deorch.InvokeInput) (deorch.InvokeResult, error) {
	return a.svc.invokeChildAgent(ctx, in)
}

// AgentInvoker 暴露给 cmd/bus 装配 deorch.Executor。
func (s *impl) AgentInvoker() deorch.AgentInvoker { return chatAgentInvoker{svc: s} }

// childInvokeTimeout 单个 child 同步调用上限 (编排器另有总 time budget)。
const childInvokeTimeout = 5 * time.Minute

// invokeChildAgent 同步调用 child 数字员工, 返回其最终 assistant 文本。
func (s *impl) invokeChildAgent(ctx context.Context, in deorch.InvokeInput) (deorch.InvokeResult, error) {
	ag, err := s.agents.GetByUUID(ctx, in.Agent.UUID)
	if err != nil || ag == nil {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: child agent not found")
	}
	// tenant fail-closed: child 必须本租户或平台 agent。
	if ag.TenantID != in.TenantID && ag.Source != "platform" {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: child cross-tenant")
	}
	fw, err := s.frameworkForAgent(ctx, ag, s.runtimeEnvFW)
	if err != nil {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: resolve framework: %w", err)
	}
	if isZapWireFramework(fw) {
		text, err := s.drainZapAgentSync(ctx, in, ag)
		if err != nil {
			return deorch.InvokeResult{}, err
		}
		return deorch.InvokeResult{Text: text}, nil
	}
	if fw != FrameworkOpenClaw {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: runtime protocol unsupported: %s", fw)
	}

	// per-user k8s pod 解析: child 调用按发起编排的用户 accountID 解析端点 (不再硬编码 0)。
	ep, _, err := s.resolveOpenClawV3Endpoint(ctx, in.TenantID, in.AccountID, ag)
	if err != nil {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: resolve endpoint: %w", err)
	}
	// 版本快照 fail-closed (model 必填); 不向 wire 注入 (与 runOpenClawV3 一致)。
	if _, err := s.loadVersionParams(ctx, ag); err != nil {
		return deorch.InvokeResult{}, fmt.Errorf("deorch invoke: version: %w", err)
	}
	text, err := s.drainAgentSync(ctx, ep, ag, in.Prompt)
	if err != nil {
		return deorch.InvokeResult{}, err
	}
	return deorch.InvokeResult{Text: text}, nil
}

// drainZapAgentSync 给编排子调用走 ZAP 数据面同步派发。
//
// 与普通 ZAP 单聊不同:
//   - 不创建/复用用户可见 conversation, 也不 publish 客户端 SSE;
//   - 每次 child 调用创建独立 session_kind=a2a 会话, edge_id 写入 hint 方便 runtime trace;
//   - 只返回 completed blocks 的可读文本给 deorch reducer, trace 仍由 a2a_call_edges / orchestration_steps 承载。
func (s *impl) drainZapAgentSync(ctx context.Context, in deorch.InvokeInput, ag *domagent.DigitalEmployee) (string, error) {
	d, ok := s.zapDispatcher.(*zapDispatcherImpl)
	if !ok || d == nil {
		return "", fmt.Errorf("deorch invoke: zap dispatcher sync not wired")
	}
	if d.envs == nil || d.secret == nil || d.agentKeys == nil || d.clientFact == nil {
		return "", fmt.Errorf("deorch invoke: zap dispatcher dependencies missing")
	}
	if ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID <= 0 {
		return "", fmt.Errorf("deorch invoke: zap child has no runtime_environment_id")
	}

	env, err := d.envs.GetByID(ctx, *ag.RuntimeEnvironmentID)
	if err != nil || env == nil {
		return "", fmt.Errorf("deorch invoke: zap runtime env lookup failed")
	}
	if !isZapWireFramework(env.Framework) {
		return "", fmt.Errorf("deorch invoke: zap runtime framework mismatch")
	}
	if err := validateZapRuntimeEnvReady(env); err != nil {
		return "", fmt.Errorf("deorch invoke: zap runtime not ready: %w", err)
	}
	baseURL := strings.TrimSpace(env.PrimaryEndpoint)
	if baseURL == "" {
		return "", fmt.Errorf("deorch invoke: zap primary_endpoint empty")
	}
	if _, err := url.Parse(baseURL); err != nil {
		return "", fmt.Errorf("deorch invoke: zap primary_endpoint invalid")
	}
	if strings.TrimSpace(env.APIKeySecretRef) == "" {
		return "", fmt.Errorf("deorch invoke: zap api_key_secret_ref empty")
	}
	apiKey, err := d.secret.Resolve(env.APIKeySecretRef)
	if err != nil || strings.TrimSpace(apiKey) == "" {
		return "", fmt.Errorf("deorch invoke: zap api key resolve failed")
	}
	agentKey, err := resolveZapAgentKeyForDispatch(ctx, d.agentKeys, ag)
	if err != nil || strings.TrimSpace(agentKey) == "" {
		return "", fmt.Errorf("deorch invoke: zap agent_key not synced to runtime")
	}
	identityProfile, err := s.resolveZapIdentityProfile(ctx, in.TenantID, in.AccountID)
	if err != nil {
		return "", fmt.Errorf("deorch invoke: zap identity resolve failed")
	}

	callCtx, cancel := context.WithTimeout(ctx, childInvokeTimeout)
	defer cancel()

	client := d.clientFact(baseURL, apiKey)
	agentIdentity := zapIdentityAgentContext(ag, agentKey)
	createReq := &zapadapter.CreateSessionRequest{
		AgentKey: agentKey,
		Agent:    agentIdentity,
		User: zapadapter.SessionUser{
			TenantUUID:  identityProfile.TenantUUID,
			AccountUUID: identityProfile.AccountUUID,
		},
		SessionKind: "a2a",
		ConversationContextHint: zapadapter.ConversationContextHint{
			TenantID:    identityProfile.TenantUUID,
			AccountID:   identityProfile.AccountUUID,
			Purpose:     "a2a",
			A2AEdgeUUID: strings.TrimSpace(in.EdgeUUID),
		},
		Initiator: &zapadapter.SessionInitiator{
			Kind:       "agent",
			AgentUUID:  strings.TrimSpace(in.FromAgentUUID),
			TenantUUID: identityProfile.TenantUUID,
		},
		Identity: zapSessionIdentityFromProfile(identityProfile),
		Profile:  zapSessionProfileMap(identityProfile),
		Metadata: zapadapter.MergeRuntimeEnvironmentMetadata(
			zapLLMContextEnvelope(in.TenantID, in.AccountID, ag, nil, "", strings.TrimSpace(in.EdgeUUID)),
			env.ExternalEnvironmentID,
		),
	}
	if zapAgentInstanceInitializationEnabled(env.Metadata) {
		runtimeIdentity, identityErr := d.ensureZapAgentInstance(callCtx, client, in.TenantID, in.AccountID, *ag.RuntimeEnvironmentID, env.ExternalEnvironmentID, identityProfile, ag, agentIdentity)
		if identityErr != nil {
			s.logger.Warn(ctx, "chat orchestrator zap identity initialize failed",
				"agent", ag.UUID,
				"runtime_env_id", *ag.RuntimeEnvironmentID,
				"edge_id", in.EdgeUUID,
				"err", safeDiagnosticString(identityErr))
			return "", fmt.Errorf("deorch invoke: zap identity initialize failed")
		}
		createReq.RuntimeIdentity = runtimeIdentity
	}
	sess, err := client.EnsureSession(callCtx, createReq)
	if err != nil || sess == nil || strings.TrimSpace(sess.SessionID) == "" {
		return "", fmt.Errorf("deorch invoke: zap session create failed")
	}

	var (
		gotCompleted bool
		finalBlocks  []map[string]any
		snapshot     string
	)
	handler := func(ev zapadapter.SSEEvent) (bool, error) {
		switch ev.Kind {
		case zapadapter.SSEBlockDelta:
			delta, kind := extractZapBlockDeltaText(ev.BlockDelta)
			if delta != "" && (kind == "" || kind == "markdown" || kind == "plain") {
				snapshot = applyMarkdownDelta(snapshot, delta)
			}
			return false, nil
		case zapadapter.SSECompleted:
			gotCompleted = true
			finalBlocks = canonicalMapBlocks(ev.Blocks)
			return true, nil
		case zapadapter.SSEFailed:
			code := sanitizeRuntimeErrorCode(ev.ErrorCode, ev.ErrorMessage)
			if code == "" {
				code = ErrCodeRuntimeUpstreamFailure
			}
			return true, fmt.Errorf("zap runtime failed: %s", code)
		case zapadapter.SSECancelled:
			return true, fmt.Errorf("zap runtime cancelled")
		case zapadapter.SSEAwaitingUser:
			return true, fmt.Errorf("zap runtime awaiting_user is not supported in orchestrator child invoke")
		default:
			return false, nil
		}
	}
	if err := client.SendMessage(callCtx, strings.TrimSpace(sess.SessionID), &zapadapter.SendMessageRequest{
		Role:     "user",
		Text:     in.Prompt,
		Metadata: zapLLMContextEnvelope(in.TenantID, in.AccountID, ag, nil, "", strings.TrimSpace(in.EdgeUUID)),
	}, handler); err != nil {
		return "", fmt.Errorf("deorch invoke: zap send message failed: %w", err)
	}
	if !gotCompleted {
		if strings.TrimSpace(snapshot) != "" {
			return strings.TrimSpace(snapshot), nil
		}
		return "", fmt.Errorf("deorch invoke: zap no terminal event")
	}
	text := strings.TrimSpace(messageblocks.ReadableText(finalBlocks))
	if text == "" {
		text = strings.TrimSpace(snapshot)
	}
	if text == "" {
		return "", fmt.Errorf("deorch invoke: zap completed with empty output")
	}
	return text, nil
}

// drainAgentSync 发一次 chat.send 并同步排空帧, 返回累计 assistant 文本 (snapshot 语义)。
// 退出: lifecycle end → 成功; lifecycle error → 错误; frames closed → 用已累计文本收尾;
// ctx 超时 → 有文本则返回, 否则错误。**不**写任何 message/conversation 行。
func (s *impl) drainAgentSync(ctx context.Context, ep gatewayws.Endpoint, ag *domagent.DigitalEmployee, prompt string) (string, error) {
	if s.openclawClient == nil {
		return "", fmt.Errorf("deorch invoke: openclaw gateway not wired")
	}
	suffix, _ := id.RandomHex(8)
	// agent-scoped session key; orch 子调用独立于任何用户会话。
	sessionKey := "agent:" + ag.UUID + ":orch:" + suffix
	pre := []gatewayws.Request{
		{Method: "sessions.create", Params: map[string]any{"key": sessionKey, "agentId": ag.UUID}},
		{Method: "sessions.messages.subscribe", Params: map[string]any{"key": sessionKey}},
	}
	mainParams := map[string]any{
		"sessionKey":     sessionKey,
		"message":        prompt,
		"idempotencyKey": idempotencyKeyFor(sessionKey),
	}
	callCtx, cancel := context.WithTimeout(ctx, childInvokeTimeout)
	defer cancel()

	frames, streamCancel, err := s.openclawClient.CallStream(callCtx, ep, pre, "chat.send", mainParams)
	if err != nil {
		return "", fmt.Errorf("deorch invoke: upstream call failed: %w", err)
	}
	defer streamCancel()

	snapshot := ""
	for {
		select {
		case <-callCtx.Done():
			if snapshot != "" {
				return snapshot, nil
			}
			return "", fmt.Errorf("deorch invoke: timeout before any output")
		case f, ok := <-frames:
			if !ok {
				return snapshot, nil // 流自然结束 → 用已累计文本收尾
			}
			if f.Event != "agent" {
				continue
			}
			// 串台防御: 丢掉非本 session 的 agent 帧 (与 processFramesV3 同款)。
			if fk := extractFrameSessionKey(f.Payload); fk != "" && fk != sessionKey {
				continue
			}
			kind, snap, phase := parseAgentFrame(f.Payload)
			switch kind {
			case "assistant":
				if snap != "" {
					snapshot = snap
				}
			case "lifecycle":
				if phase == "error" {
					return snapshot, fmt.Errorf("deorch invoke: child runtime error")
				}
				if phase == "end" {
					return snapshot, nil
				}
			}
		}
	}
}

// sendOrchestrator doc-14 Objective E / P1: 编排型数字员工的 /chat/send 入口。
//
// 与单体 agent 的区别: 编排主控自身不解析 endpoint/version (它只委派 child), 而是解析 + 校验
// 成员 child, 复用 single-chat 的 conversation/user-message 写入, 然后经 runAgentInternal 把
// Step 4 切到 runOrchestratorGoroutine 跑 deorch.Executor。客户端只看到唯一一条编排回复
// (master 的 agent message), child 的输出只进 orchestration/a2a trace, 不写用户可见会话/消息。
//
// 口径: 这里复用的是 **EasyO 内部** A2A 准入 (callable_by_agents 白名单, fail-closed default-deny)
// + 编排 trace, 不是官方开源 A2A Protocol 的 wire-compatible 实现。
func (s *impl) sendOrchestrator(ctx context.Context, accountID, tenantID int64, ag *domagent.DigitalEmployee, req SendReq) (*SendResp, error) {
	// fail-closed: 编排执行器未装齐 (cmd/bus 没注入 orchestration/a2a 仓储) → 不把编排型 agent
	// 当单体跑, 直接返错 (诚实失败, 不静默降级)。
	if s.orchExecutor == nil {
		return nil, apperr.ErrInternal.Withf("chat: orchestrator runtime not wired")
	}

	cfg, children, err := s.resolveOrchestratorChildren(ctx, accountID, tenantID, ag)
	if err != nil {
		return nil, err
	}

	// 复用单聊的 conversation 选取/创建 (digital_employee_id = 编排主控)。
	conv, err := s.resolveOrCreateConversation(ctx, accountID, tenantID, ag, req)
	if err != nil {
		return nil, err
	}
	userBlocks := req.Blocks
	if len(userBlocks) == 0 && req.Text != "" {
		userBlocks = []map[string]any{{"type": "plain", "text": req.Text}}
	}
	userMsg, err := s.messages.Append(ctx, &dommsg.Message{
		TenantID:        tenantID,
		ConversationID:  conv.ID,
		Role:            "user",
		SenderAccountID: &accountID,
		Blocks:          userBlocks,
		Status:          "final",
		Final:           true,
	})
	if err != nil {
		return nil, err
	}

	// 走 runAgentInternal 的预建消息 + register stream + message.created;
	// OrchestratorStrategy 非空 → Step 4 spawn runOrchestratorGoroutine 跑 deorch.Executor。
	out, err := s.runAgentInternal(ctx, runAgentInternalIn{
		AccountID:            accountID,
		TenantID:             tenantID,
		Conversation:         conv,
		RoomUUID:             "", // single-chat 入口
		Agent:                ag,
		PromptText:           orchPromptText(req.Text, userBlocks),
		UserMessageUUID:      userMsg.UUID,
		BudgetChecked:        true, // 编排不入队, 不做 backlog 预算检查
		OrchestratorChildren: children,
		OrchestratorStrategy: cfg.Strategy,
	})
	if err != nil {
		return nil, err
	}
	return &SendResp{
		ConversationUUID: conv.UUID,
		StreamID:         out.StreamID,
		UserMessageUUID:  userMsg.UUID,
		AgentMessageUUID: out.AgentMessageUUID,
	}, nil
}

func (s *impl) resolveOrchestratorChildren(ctx context.Context, accountID, tenantID int64, ag *domagent.DigitalEmployee) (deorch.Config, []deorch.ChildAgent, error) {
	cfg, err := deorch.ParseConfig(ag.Metadata)
	if err != nil {
		// 编排配置非法 (无 children / 未知 strategy 等) → 参数错, 不写任何 message。
		return deorch.Config{}, nil, apperr.ErrInvalidParams.Wrap(err)
	}

	// 解析 + 校验 child 数字员工。master→child 的**授权**由 deorch.Executor 内的完整 EasyO 内部
	// A2A 准入裁决 (deorch.A2AAdmission: 防自调 + tenant isolation + a2a_invoke capability + callable
	// 白名单 + quota, fail-closed)。这里做 **双闸的第一闸 + 预过滤**:
	//   - 存在 + 已发布 + 属于当前租户，或是当前租户可见的平台员工；平台员工在本次调用中
	//     使用 caller tenant 作为有效运行租户 + 非嵌套编排;
	//   - **Task 2: 终端用户可见性闸 (contacts.AssertAgentVisible)** —— orchestrator 配了 child
	//     不代表当前用户一定能调; 不可见 child 不进 children 列表。
	// 无效 / 不可见 child 丢弃并日志; 一个可用 child 都没有 → fail-closed 参数错。
	children := make([]deorch.ChildAgent, 0, len(cfg.ChildUUIDs))
	for _, cu := range cfg.ChildUUIDs {
		child, gerr := s.agents.GetByUUID(ctx, cu)
		if gerr != nil || child == nil {
			s.logger.Warn(ctx, "orchestrator child not found; dropping", "master", ag.UUID, "child", cu)
			continue
		}
		if child.Status != "published" {
			s.logger.Warn(ctx, "orchestrator child not published; dropping", "master", ag.UUID, "child", cu, "status", child.Status)
			continue
		}
		effectiveChildTenantID := effectiveAgentTenantID(child, tenantID)
		if effectiveChildTenantID != tenantID {
			s.logger.Warn(ctx, "orchestrator child not in caller tenant; dropping", "master", ag.UUID, "child", cu)
			continue
		}
		if deorch.IsOrchestrator(child.Metadata) {
			// MVP 不支持编排嵌套 (避免环 / 深度爆炸); 编排型 child 丢弃。
			s.logger.Warn(ctx, "orchestrator child is itself an orchestrator; nesting unsupported, dropping", "master", ag.UUID, "child", cu)
			continue
		}
		// Task 2: contacts 可见性闸 (与单聊 Send 同一裁决器, 覆盖 contact_enabled / workspace 域 /
		// platform hidden / visibility_override hidden)。visibility 在 Send 入口已 nil-check。
		if verr := s.visibility.AssertAgentVisible(ctx, accountID, tenantID, child.UUID); verr != nil {
			s.logger.Warn(ctx, "orchestrator child not visible to caller; dropping", "master", ag.UUID, "child", cu)
			continue
		}
		children = append(children, deorch.ChildAgent{
			ID:                   child.ID,
			UUID:                 child.UUID,
			Name:                 child.Name,
			TenantID:             effectiveChildTenantID,
			WorkspaceID:          child.WorkspaceID,
			CallableByAgentsJSON: child.CallableByAgentsJSON,
		})
	}
	if len(children) == 0 {
		return deorch.Config{}, nil, apperr.ErrInvalidParams.Withf("orchestrator has no usable child agents")
	}
	return cfg, children, nil
}

func effectiveAgentTenantID(agent *domagent.DigitalEmployee, callerTenantID int64) int64 {
	if agent != nil && agent.Source == "platform" && agent.TenantID == 0 {
		return callerTenantID
	}
	if agent == nil {
		return 0
	}
	return agent.TenantID
}

// runOrchestratorGoroutine detached 跑一次编排 run, 完成后把唯一一条 master agent message finalize。
// 诚实失败: run failed / 出错 / 无最终文本 → 通用收尾消息 (message.failed), 不下发内部码或 child 细节。
func (s *impl) runOrchestratorGoroutine(ctx context.Context, streamID string, in runAgentInternalIn, agentMsgUUID string) {
	defer s.fanout.Close(ctx, streamID)
	s.logger.Info(ctx, "chat orchestrator run open",
		"agent", in.Agent.UUID, "stream_id", streamID,
		"strategy", string(in.OrchestratorStrategy), "children", len(in.OrchestratorChildren),
		"room_uuid", in.RoomUUID, "node_id", s.nodeID)

	res, err := s.orchExecutor.Run(ctx, deorch.RunInput{
		TenantID:  in.TenantID,
		AccountID: in.AccountID,
		Master:    deorch.MasterAgent{ID: in.Agent.ID, UUID: in.Agent.UUID, TenantID: in.TenantID, WorkspaceID: in.Agent.WorkspaceID},
		Children:  in.OrchestratorChildren,
		Strategy:  in.OrchestratorStrategy,
		Prompt:    in.PromptText,
	})
	if err != nil || string(res.Status) != "done" || strings.TrimSpace(res.FinalText) == "" {
		s.logger.Warn(ctx, "chat orchestrator run failed",
			"agent", in.Agent.UUID, "stream_id", streamID,
			"orch_uuid", res.OrchestrationUUID, "status", string(res.Status), "err", errString(err))
		blocks := orchestratorFinalBlocks(in.Agent, in.PromptText, res.FinalText, res.Calls)
		if len(res.Calls) == 0 && strings.TrimSpace(res.FinalText) == "" {
			blocks = nil
		}
		s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
			blocks, "failed", "chat.orchestration_failed", "编排执行未能完成，请稍后重试。", nil)
		return
	}
	blocks := orchestratorFinalBlocks(in.Agent, in.PromptText, res.FinalText, res.Calls)
	s.logger.Info(ctx, "chat orchestrator completed",
		"agent", in.Agent.UUID, "stream_id", streamID,
		"orch_uuid", res.OrchestrationUUID, "status", string(res.Status),
		"calls", len(res.Calls), "blocks", len(blocks))
	s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
		blocks, "final", "", "", nil)
}

func orchestratorFinalBlocks(master *domagent.DigitalEmployee, prompt, childText string, calls []deorch.CallTrace) []map[string]any {
	blocks := make([]map[string]any, 0, len(calls)*2+1)
	for _, c := range calls {
		if strings.TrimSpace(c.EdgeUUID) == "" {
			continue
		}
		name := strings.TrimSpace(c.AgentName)
		if name == "" {
			name = "协作数字员工"
		}
		status := a2aTimelineStatus(string(c.Status))
		toolCallID := "a2a:" + c.EdgeUUID
		summary := map[string]any{
			"edge_id":       c.EdgeUUID,
			"to_agent_id":   c.AgentUUID,
			"to_agent_name": name,
			"status":        string(c.Status),
		}
		if c.Attempts > 0 {
			summary["attempts"] = c.Attempts
		}
		if strings.TrimSpace(c.ErrorSummary) != "" {
			summary["error_summary"] = c.ErrorSummary
		}
		blocks = append(blocks, map[string]any{
			"type":         "tool_call",
			"x_source":     "a2a_timeline",
			"tool_call_id": toolCallID,
			"tool":         name,
			"name":         name,
			"input":        summary,
			"status":       status,
		})
		blocks = append(blocks, map[string]any{
			"type":         "tool_result",
			"x_source":     "a2a_timeline",
			"tool_call_id": toolCallID,
			"tool":         name,
			"name":         name,
			"result":       a2aTimelineResultText(name, string(c.Status), c.ErrorSummary, c.Attempts),
			"status":       status,
		})
	}
	blocks = append(blocks, map[string]any{
		"type": "markdown",
		"text": orchestratorFinalText(master, prompt, childText),
	})
	return blocks
}

func a2aTimelineStatus(status string) string {
	switch status {
	case "done", "completed", "succeeded":
		return "completed"
	case "cancelled":
		return "cancelled"
	case "failed", "dropped_whitelist", "dropped_budget", "dropped_cycle":
		return "failed"
	default:
		return status
	}
}

func a2aTimelineResultText(agentName, status, errorSummary string, attempts int) string {
	switch status {
	case "done", "completed", "succeeded":
		if attempts > 1 {
			return fmt.Sprintf("%s已完成协作（重试 %d 次后成功）。", agentName, attempts-1)
		}
		return agentName + "已完成协作。"
	case "cancelled":
		return agentName + "的协作已取消。"
	case "dropped_whitelist":
		return agentName + "未通过协作权限校验，未发起调用。"
	case "dropped_budget":
		return agentName + "因协作调用额度或并发限制，本次未发起调用。"
	default:
		errorSummary = strings.TrimSpace(errorSummary)
		if errorSummary == "" {
			errorSummary = "请稍后重试或检查运行环境"
		}
		return agentName + "本次协作未完成：" + errorSummary + "。"
	}
}

func orchestratorFinalText(master *domagent.DigitalEmployee, prompt, childText string) string {
	childText = strings.TrimSpace(childText)
	if childText != "" {
		return childText
	}
	return "协作处理已完成。"
}

// orchPromptText 编排 run 的输入文本: 优先 req.Text, 否则拼接 plain blocks 文本。
func orchPromptText(text string, blocks []map[string]any) string {
	if strings.TrimSpace(text) != "" {
		return text
	}
	var b strings.Builder
	for _, bl := range blocks {
		if bl["type"] != "plain" {
			continue
		}
		if t, ok := bl["text"].(string); ok && t != "" {
			if b.Len() > 0 {
				b.WriteString("\n")
			}
			b.WriteString(t)
		}
	}
	return b.String()
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func safeDiagnosticString(err error) string {
	if err == nil {
		return ""
	}
	s := strings.TrimSpace(err.Error())
	s = redactBearerText(s)
	if len([]rune(s)) > 500 {
		rs := []rune(s)
		s = string(rs[:500]) + "..."
	}
	return s
}

func redactBearerText(s string) string {
	fields := strings.Fields(s)
	for i := 0; i < len(fields)-1; i++ {
		if strings.EqualFold(fields[i], "Bearer") {
			fields[i+1] = "[REDACTED]"
		}
	}
	return strings.Join(fields, " ")
}
