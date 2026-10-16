// hermes_chat.go — Phase 3B: Hermes framework chat dispatch (service layer).
//
// Parallel to zap_chat.go: this file is the chat service's wrapper for Hermes
// /v1/chat/completions (OpenAI-compatible SSE).
//
// Design:
//   - Agent Bus manages conversation history; Hermes is stateless per turn.
//   - Does not use Hermes Session API, Runs API, or webhook.
//   - Endpoint + bearer resolved via HermesEndpointResolver (hosting_kind branching);
//     external_endpoint reads runtime_environments, clawmanager/k8s_native reads runtime_instances.
//   - API_SERVER_KEY never logged.
//   - SSE delta → EventMessageBlockDelta (markdown snapshot); finish_reason=stop → finalize.

package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	hermesadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/hermes"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domagentrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
)

// HermesEndpointResolver resolves Hermes endpoint + bearer by hosting_kind.
// agentUUID: 非 nil 时按该数字员工的专属 pod 解析 (BYOK); nil 走共享 pod。
type HermesEndpointResolver interface {
	Resolve(ctx context.Context, runtimeEnvID, tenantID, accountID int64, agentUUID *string) (hermesadapter.HermesEndpoint, error)
}

// HermesChatClientFactory constructs a ChatClient; tests can inject a fake.
type HermesChatClientFactory func(timeout time.Duration) HermesChatClient

// HermesChatClient narrow interface for the Hermes chat HTTP client.
type HermesChatClient interface {
	ChatStream(ctx context.Context, req hermesadapter.ChatRequest, handler func(hermesadapter.StreamEvent) bool) error
}

// HermesDispatchInput Send / queue worker pass to the Hermes dispatcher.
type HermesDispatchInput struct {
	SelectedModel    string
	StreamID         string
	AccountID        int64
	RuntimeAccountID int64
	TenantID         int64
	Conversation     *domconv.Conversation
	RoomUUID         string
	Agent            *domagent.DigitalEmployee
	PromptText       string
	AgentMessageUUID string
	UserMessageUUID  string
	InputMessageUUID string
	// WaitForRuntime is enabled only for an already accepted non-queue chat
	// stream. Queue workers keep their own deferred/retry lifecycle.
	WaitForRuntime bool
}

// HermesDispatcher chat service's narrow interface for Hermes data plane.
type HermesDispatcher interface {
	Send(ctx context.Context, in HermesDispatchInput) error
}

// hermesDispatcherImpl implements HermesDispatcher.
type hermesDispatcherImpl struct {
	resolver   HermesEndpointResolver
	clientFact HermesChatClientFactory
	parent     *impl
}

// NewHermesDispatcher constructs the Hermes dispatcher; cmd/bus injects into chat.Service.
func NewHermesDispatcher(resolver HermesEndpointResolver, fact HermesChatClientFactory) HermesDispatcher {
	if fact == nil {
		fact = func(timeout time.Duration) HermesChatClient {
			return hermesadapter.NewChatClient(timeout)
		}
	}
	return &hermesDispatcherImpl{
		resolver:   resolver,
		clientFact: fact,
	}
}

// AttachToService sets the parent reference for finalize/publish access.
func (d *hermesDispatcherImpl) AttachToService(svc Service) {
	if im, ok := svc.(*impl); ok {
		d.parent = im
	}
}

// AttachHermesDispatcherToService public helper for cmd/bus wiring.
func AttachHermesDispatcherToService(svc Service, d HermesDispatcher) {
	if impl, ok := d.(*hermesDispatcherImpl); ok {
		impl.AttachToService(svc)
	}
}

// Send implements HermesDispatcher.
func (d *hermesDispatcherImpl) Send(ctx context.Context, in HermesDispatchInput) error {
	if d.parent == nil {
		return errors.New("hermes dispatcher not attached to chat service")
	}
	if in.Agent == nil || in.Conversation == nil {
		convUUID := ""
		if in.Conversation != nil {
			convUUID = in.Conversation.UUID
		}
		d.parent.finalize(ctx, in.StreamID, in.AccountID, in.TenantID,
			convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatch missing agent/conversation", nil)
		return nil
	}
	return d.parent.runHermesChatInline(ctx, in, d)
}

// runHermesChatGoroutine runs Hermes stream in a detached goroutine (queue=off path).
func (s *impl) runHermesChatGoroutine(
	ctx context.Context,
	streamID string,
	accountID, runtimeAccountID, tenantID int64,
	conv *domconv.Conversation,
	roomUUID string,
	ag *domagent.DigitalEmployee,
	promptText string,
	agentMsgUUID string,
	userMsgUUID string,
	inputMessageUUID string,
	model ...string,
) {
	defer s.fanout.Close(ctx, streamID)
	in := HermesDispatchInput{
		StreamID:         streamID,
		AccountID:        accountID,
		RuntimeAccountID: runtimeAccountID,
		TenantID:         tenantID,
		Conversation:     conv,
		RoomUUID:         roomUUID,
		Agent:            ag,
		PromptText:       promptText,
		AgentMessageUUID: agentMsgUUID,
		UserMessageUUID:  userMsgUUID,
		InputMessageUUID: inputMessageUUID,
		WaitForRuntime:   true,
	}
	if len(model) > 0 {
		in.SelectedModel = model[0]
	}
	if s.hermesDispatcher == nil {
		s.finalize(ctx, streamID, accountID, tenantID, conv.UUID, roomUUID, agentMsgUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatcher not wired", nil)
		return
	}
	if err := s.hermesDispatcher.Send(ctx, in); err != nil {
		if errors.Is(err, ErrHermesRuntimeWarming) {
			s.finalize(ctx, streamID, accountID, tenantID, conv.UUID, roomUUID, agentMsgUUID,
				nil, "failed", ErrCodeRuntimeWarming, "hermes runtime instance not ready", nil)
			return
		}
		s.logger.Warn(ctx, "chat hermes dispatcher returned error", "stream_id", streamID, "err", err.Error())
	}
}

// runHermesChatInline dispatcher.Send's real implementation.
//
// Returns ErrHermesRuntimeWarming when resolver reports instance not ready (caller decides
// whether to finalize or retry). All other error/success paths finalize internally and return nil.
func (s *impl) runHermesChatInline(ctx context.Context, in HermesDispatchInput, d *hermesDispatcherImpl) error {
	convUUID := in.Conversation.UUID
	if in.RuntimeAccountID <= 0 {
		var err error
		in.RuntimeAccountID, err = runtimeAccountIDForAgent(in.AccountID, in.Agent)
		if err != nil {
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
				nil, "failed", ErrCodeProtocolUnsupported, err.Error(), nil)
			return nil
		}
	}

	// F24: run recorder (nil-safe). Opened before guards so dispatch failures
	// also land as failed runs; finalize flushes by streamID.
	rec := s.startRunRecorder(ctx, RunSpec{
		// Cloud paths state the locus explicitly: relying on a default would let a
		// future local path mislabel itself silently, which is the defect this column exists for.
		ExecutionLocus:       domagentrun.ExecutionLocusCloud,
		TenantID:             in.TenantID,
		AccountID:            in.AccountID,
		DigitalEmployeeID:    in.Agent.ID,
		ConversationUUID:     convUUID,
		MessageUUID:          in.AgentMessageUUID,
		StreamID:             in.StreamID,
		RoomID:               in.Conversation.RoomID,
		RuntimeKind:          domagentrun.RuntimeHermes,
		RuntimeEnvironmentID: in.Agent.RuntimeEnvironmentID,
		TriggerSource:        zapTriggerSource(in.RoomUUID),
		AgentVersion:         in.Agent.CurrentVersion,
	})
	_ = rec

	if d.resolver == nil || d.clientFact == nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatcher dependencies missing", nil)
		return nil
	}
	if in.Agent.RuntimeEnvironmentID == nil || *in.Agent.RuntimeEnvironmentID <= 0 {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatch: agent has no runtime_environment_id", nil)
		return nil
	}

	// ADR-0037 Phase 1 任务组 5 之后, BYOK 数字员工在 clawmanager/k8s_native 上有专属
	// pod (跟共享 pod 用同一张 runtime_instances 表, 按 agent_uuid 区分)。这里必须按
	// model_source 传对应的 agentUUID, 否则会解析到共享 pod, 聊天请求根本到不了这个
	// 数字员工自己配的 BYOK 网关 (今天联调实测踩过的坑: 表现为 pod 日志零请求、回复内容
	// 明显是另一个 pod 的默认身份/模型)。
	var hermesAgentUUID *string
	if in.Agent.ModelSource == "byok" {
		hermesAgentUUID = &in.Agent.UUID
	}
	ep, err := resolveHermesEndpointWithRetry(
		ctx,
		d.resolver,
		*in.Agent.RuntimeEnvironmentID,
		in.TenantID,
		in.RuntimeAccountID,
		hermesAgentUUID,
		in.WaitForRuntime,
		hermesRuntimeWarmMaxWait,
		hermesRuntimeWarmRetryDelay,
	)
	if err != nil {
		if errors.Is(err, hermesadapter.ErrHermesInstanceNotReady) {
			return ErrHermesRuntimeWarming
		}
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil
		}
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkHermes,
			FailureStage:     "endpoint_resolve",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: convUUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeProtocolUnsupported,
			Diagnostic:       err.Error(),
		})
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatch: endpoint resolve failed", nil)
		return nil
	}

	ragQuery := s.chatRAGQueryText(
		ctx,
		in.PromptText,
		firstNonEmpty(in.InputMessageUUID, in.UserMessageUUID),
		safeAgentName(in.Agent),
	)
	if s.hermesInputs != nil {
		inputMessageUUID := strings.TrimSpace(in.InputMessageUUID)
		if inputMessageUUID == "" {
			inputMessageUUID = strings.TrimSpace(in.UserMessageUUID)
		}
		if inputMessageUUID != "" {
			inputs, err := s.hermesInputs.PrepareHermesInputs(ctx, in.TenantID, in.AccountID, in.Agent, convUUID, inputMessageUUID)
			if err != nil {
				s.logger.Error(ctx, "chat hermes input prepare failed",
					"agent", in.Agent.UUID, "stream_id", in.StreamID, "conversation_uuid", convUUID,
					"input_message_uuid", inputMessageUUID, "err", err)
				s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
					nil, "failed", ErrCodeRuntimeInputPrepareFailed, "hermes input prepare failed", nil)
				return nil
			}
			in.PromptText = promptTextWithHermesInputs(in.PromptText, inputs)
		}
	}
	if kc := s.prepareRuntimeKnowledgeContext(ctx, ChatRAGRequest{
		TenantID:         in.TenantID,
		AccountID:        in.AccountID,
		Agent:            in.Agent,
		Conversation:     in.Conversation,
		RoomUUID:         in.RoomUUID,
		MessageUUID:      in.AgentMessageUUID,
		QueryOriginal:    ragQuery,
		QueryRewritten:   ragQuery,
		InvocationSource: "pre_retrieve",
	}); kc != nil {
		in.PromptText = promptTextWithKnowledgeContext(in.PromptText, kc)
	}

	messages, err := s.buildHermesMessages(ctx, in)
	if err != nil {
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkHermes,
			FailureStage:     "build_messages",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: convUUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeProtocolUnsupported,
			Diagnostic:       err.Error(),
		})
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes dispatch: build messages failed", nil)
		return nil
	}

	client := d.clientFact(hermesChatTimeout)

	chatReq := hermesadapter.ChatRequest{
		Endpoint:   ep.URL,
		APIKey:     ep.Bearer,
		Model:      hermesChatModel(in.Agent),
		Messages:   messages,
		SessionKey: "agent:" + in.Agent.UUID + ":" + in.Conversation.UUID,
	}

	if in.SelectedModel != "" {
		chatReq.Model = in.SelectedModel
		chatReq.RequireModelOverride = true
	}
	binding, bindingErr := s.prepareConversationModel(ctx, in.AccountID, in.TenantID, in.Agent, in.AgentMessageUUID, in.SelectedModel)
	if bindingErr != nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID, nil, "failed", "model.platform_unavailable", "所选模型平台不可用，请重新选择", nil)
		return nil
	}
	if binding != nil {
		chatReq.ModelService = binding
		chatReq.Model = binding.Model
	}
	var (
		snapshot      string
		gotFinish     bool
		finishReason  string
		gotDone       bool
		streamErr     error
		streamErrCode string
		toolsByID     = make(map[string]*hermesToolState)
		toolOrder     []string
		textPublisher hermesTextDeltaPublisher
		usage         map[string]any // F24 §3.3-a: runtime 上报 usage, 透传 finalize
	)

	transportErr := client.ChatStream(ctx, chatReq, func(ev hermesadapter.StreamEvent) bool {
		if ev.Usage != nil {
			usage = ev.Usage
		}
		switch ev.Type {
		case "delta":
			if ev.Delta != "" {
				snapshot += ev.Delta
				rec.OnOutput(time.Now())
				if textPublisher.shouldPublish(time.Now(), snapshot, false) {
					s.publishHermesTextDelta(ctx, in, snapshot)
				}
			}
			if ev.FinishReason != "" {
				gotFinish = true
				finishReason = ev.FinishReason
			}
		case "done":
			gotDone = true
			return true
		case "error":
			streamErr = ev.Err
			var apiErr *hermesadapter.ChatAPIError
			if errors.As(ev.Err, &apiErr) {
				streamErrCode = apiErr.Code
			}
			return true
		case "tool_progress":
			switch strings.ToLower(strings.TrimSpace(ev.ToolStatus)) {
			case "completed", "succeeded", "done", "ok":
				rec.OnToolResult(ev.ToolCallID, true, "", time.Now())
			case "failed", "error":
				rec.OnToolResult(ev.ToolCallID, false, "", time.Now())
			default: // started / running / progress
				rec.OnToolCall(ev.ToolCallID, ev.ToolName, time.Now())
			}
			st := upsertHermesTool(toolsByID, &toolOrder, ev)
			s.publishHermesToolProgress(ctx, in, st)
		case "ignore":
		}
		return false
	})
	if transportErr != nil {
		streamErr = transportErr
	}
	if textPublisher.shouldPublish(time.Now(), snapshot, true) {
		s.publishHermesTextDelta(ctx, in, snapshot)
	}

	if streamErr != nil {
		errorCode := hermesErrorToCode(streamErr, streamErrCode)
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkHermes,
			FailureStage:     "stream_error",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: convUUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        errorCode,
			RawErrorCode:     streamErrCode,
			Diagnostic:       streamErr.Error(),
		})
		failureMessage := sanitizedHermesFailureMessage
		if errors.Is(streamErr, hermesadapter.ErrModelOverrideUnsupported) {
			errorCode = "model.runtime_upgrade_required"
			failureMessage = "运行环境尚不支持所选模型，请更新运行环境后重试"
		}
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			hermesFinalBlocks(toolOrder, toolsByID, snapshot), "failed", errorCode,
			failureMessage, usage)
		return nil
	}

	if !gotFinish && !gotDone {
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkHermes,
			FailureStage:     "no_terminal_event",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: convUUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeProtocolUnsupported,
			Diagnostic:       "hermes stream ended without finish_reason or done event",
		})
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "hermes_no_terminal_event", nil)
		return nil
	}

	if snapshot == "" {
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkHermes,
			FailureStage:     "empty_response",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: convUUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeHermesEmptyResponse,
			Diagnostic:       "hermes stream completed without assistant content",
		})
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeHermesEmptyResponse, sanitizedHermesFailureMessage, usage)
		return nil
	}

	var outputAttachments []messageblocks.Attachment
	if s.hermesOutputs != nil {
		pctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), openClawOutputPublishTimeout)
		published, publishErr := s.hermesOutputs.PublishHermesOutputs(pctx, HermesOutputPublishInput{
			TenantID:             in.TenantID,
			AccountID:            in.AccountID,
			AgentUUID:            in.Agent.UUID,
			RuntimeEnvironmentID: *in.Agent.RuntimeEnvironmentID,
			ConversationUUID:     convUUID,
			MessageUUID:          in.AgentMessageUUID,
			Text:                 snapshot,
		})
		if publishErr != nil {
			s.logger.Warn(pctx, "chat hermes output publish failed",
				"stream_id", in.StreamID,
				"conversation_uuid", convUUID,
				"message_uuid", in.AgentMessageUUID,
				"agent_uuid", in.Agent.UUID,
				"err", publishErr,
			)
		} else {
			if strings.TrimSpace(published.Text) != "" {
				snapshot = published.Text
			}
			outputAttachments = published.Attachments
		}
		cancel()
	}

	_ = finishReason
	finalBlocks := hermesFinalBlocks(toolOrder, toolsByID, snapshot)
	finalBlocks = messageblocks.AppendAttachments(finalBlocks, outputAttachments)
	s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, convUUID, in.RoomUUID, in.AgentMessageUUID,
		finalBlocks, "final", "", "", usage)
	return nil
}

const hermesChatTimeout = 180 * time.Second

const hermesRuntimeWarmMaxWait = 90 * time.Second

func hermesRuntimeWarmRetryDelay(attempt int) time.Duration {
	switch {
	case attempt <= 0:
		return time.Second
	case attempt == 1:
		return 2 * time.Second
	default:
		return 5 * time.Second
	}
}

// resolveHermesEndpointWithRetry keeps an already accepted non-queue message
// streaming across the short starting window caused by a workload rolling
// restart. Queue workers deliberately pass wait=false and retain their own
// deferred/backoff semantics.
func resolveHermesEndpointWithRetry(
	ctx context.Context,
	resolver HermesEndpointResolver,
	runtimeEnvID, tenantID, accountID int64,
	agentUUID *string,
	wait bool,
	maxWait time.Duration,
	retryDelay func(attempt int) time.Duration,
) (hermesadapter.HermesEndpoint, error) {
	startedAt := time.Now()
	for attempt := 0; ; attempt++ {
		ep, err := resolver.Resolve(ctx, runtimeEnvID, tenantID, accountID, agentUUID)
		if !errors.Is(err, hermesadapter.ErrHermesInstanceNotReady) || !wait {
			return ep, err
		}
		remaining := maxWait - time.Since(startedAt)
		if remaining <= 0 {
			return hermesadapter.HermesEndpoint{}, err
		}
		delay := retryDelay(attempt)
		if delay <= 0 {
			delay = time.Second
		}
		if delay > remaining {
			delay = remaining
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return hermesadapter.HermesEndpoint{}, ctx.Err()
		case <-timer.C:
		}
	}
}

const maxHermesHistoryMessages = 20
const hermesDeltaInitialMinBytes = 72
const hermesDeltaMinInterval = 900 * time.Millisecond
const hermesDeltaMinBytes = 180

type hermesToolState struct {
	ID     string
	Name   string
	Status string
}

type hermesTextDeltaPublisher struct {
	lastSnapshot string
	lastAt       time.Time
}

func (p *hermesTextDeltaPublisher) shouldPublish(now time.Time, snapshot string, force bool) bool {
	if snapshot == "" || snapshot == p.lastSnapshot {
		return false
	}
	if force {
		p.lastSnapshot = snapshot
		p.lastAt = now
		return true
	}
	if p.lastSnapshot == "" {
		if len(snapshot) < hermesDeltaInitialMinBytes {
			return false
		}
		p.lastSnapshot = snapshot
		p.lastAt = now
		return true
	}
	if len(snapshot)-len(p.lastSnapshot) >= hermesDeltaMinBytes ||
		(!p.lastAt.IsZero() && now.Sub(p.lastAt) >= hermesDeltaMinInterval) {
		p.lastSnapshot = snapshot
		p.lastAt = now
		return true
	}
	return false
}

// buildHermesMessages constructs the OpenAI messages array with full conversation history.
//
// Layout: [system?] + [history (oldest→newest, max 20)] + [current user]
//
// History read error → fail-closed (return error, do not degrade to current-turn-only).
// System prompt: prefer agent_versions.snapshot.system_prompt; fall back to agent.Description.
func (s *impl) buildHermesMessages(ctx context.Context, in HermesDispatchInput) ([]hermesadapter.ChatMessage, error) {
	var msgs []hermesadapter.ChatMessage

	systemPrompt := s.hermesSystemPrompt(ctx, in.Agent)
	if toolCtx := s.hermesToolContextBlock(in); toolCtx != "" {
		if systemPrompt != "" {
			systemPrompt += "\n\n"
		}
		systemPrompt += toolCtx
	}
	if systemPrompt != "" {
		msgs = append(msgs, hermesadapter.ChatMessage{Role: "system", Content: systemPrompt})
	}

	if in.Conversation != nil && in.Conversation.ID > 0 {
		history, err := s.messages.History(ctx, dommsg.HistoryFilter{
			ConversationID: in.Conversation.ID,
			Limit:          maxHermesHistoryMessages * 2,
		})
		if err != nil {
			return nil, fmt.Errorf("hermes history query: %w", err)
		}

		var filtered []hermesadapter.ChatMessage
		for _, m := range history {
			if m.Status != "final" {
				continue
			}
			if m.Role != "user" && m.Role != "agent" {
				continue
			}
			if m.UUID == in.AgentMessageUUID {
				continue
			}
			if in.UserMessageUUID != "" && m.UUID == in.UserMessageUUID {
				continue
			}
			text := hermesExtractText(m.Blocks)
			if text == "" {
				continue
			}
			role := m.Role
			if role == "agent" {
				role = "assistant"
			}
			filtered = append(filtered, hermesadapter.ChatMessage{Role: role, Content: text})
		}
		if len(filtered) > maxHermesHistoryMessages {
			filtered = filtered[len(filtered)-maxHermesHistoryMessages:]
		}
		msgs = append(msgs, filtered...)
	}

	if in.PromptText != "" {
		msgs = append(msgs, hermesadapter.ChatMessage{Role: "user", Content: in.PromptText})
	}

	return msgs, nil
}

// hermesToolContextBlock provides tool-routing guidance only. The trusted
// session key is sent in X-Hermes-Session-Key and injected by Hermes from its
// task-local runtime context; it must never be copied by the model.
func (s *impl) hermesToolContextBlock(in HermesDispatchInput) string {
	if !s.hermesMCPTools || in.Agent == nil || in.Conversation == nil ||
		in.Agent.UUID == "" || in.Conversation.UUID == "" {
		return ""
	}
	return `## 平台工具使用规则

- 当用户询问"知识库"、"文档"、"资料库"、"绑定了哪些资料"或"知识库都有啥"时, 必须先调用 mcp_zhiban_zhiban_kb_search 检索平台知识库, 不要用 session_search、skills_list 或本地会话/技能列表代替知识库查询。`
}

// hermesChatModel 决定发给 Hermes /v1/chat/completions 的 model 字段。
//
// ADR-0037 Phase 1 任务组 5 (今天联调实测发现的第二个 Hermes BYOK 缺口, 跟
// renderHermesConfigYaml 那个是两处独立漏网): BYOK 数字员工 model_primary 本来就是空
// (设计如此, 见 domain/agent/agent.go ModelSource 注释), 之前这里直接把空字符串塞进
// chatReq.Model 发给 dashscope, 必然被拒。这里改成 BYOK 时解出 model_service_config.model_id
// 原样透传——不能套 OpenClaw 那套 "openai/"+modelID 前缀 (那是 OpenClaw 自己的
// provider/model 选择器约定); Hermes 这边 provider 恒为 custom, model 字段是直接转发给
// base_url 指向的第三方网关的原始模型名, 不能带这个前缀。
func hermesChatModel(ag *domagent.DigitalEmployee) string {
	if ag == nil {
		return ""
	}
	if ag.ModelSource == "byok" {
		var cfg struct {
			ModelID string `json:"model_id"`
		}
		if ag.ModelServiceConfigJSON != "" {
			_ = json.Unmarshal([]byte(ag.ModelServiceConfigJSON), &cfg)
		}
		return strings.TrimSpace(cfg.ModelID)
	}
	return strings.TrimSpace(ag.ModelPrimary)
}

func (s *impl) hermesSystemPrompt(ctx context.Context, ag *domagent.DigitalEmployee) string {
	if ag == nil {
		return ""
	}
	if ag.CurrentVersion > 0 {
		v, err := s.agents.GetVersion(ctx, ag.ID, ag.CurrentVersion)
		if err == nil && v != nil && v.Snapshot != nil {
			if sp, ok := v.Snapshot["system_prompt"].(string); ok && sp != "" {
				return sp
			}
		}
	}
	return ag.Description
}

func hermesExtractText(blocks []map[string]any) string {
	var parts []string
	for _, b := range blocks {
		typ, _ := b["type"].(string)
		text, _ := b["text"].(string)
		if text == "" {
			continue
		}
		if typ == "plain" || typ == "markdown" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

// publishHermesTextDelta publishes accumulated snapshot to fanout.
func (s *impl) publishHermesTextDelta(ctx context.Context, in HermesDispatchInput, snapshot string) {
	if snapshot == "" {
		return
	}
	convUUID := ""
	if in.Conversation != nil {
		convUUID = in.Conversation.UUID
	}
	ev := StreamEvent{
		Kind:             EventMessageBlockDelta,
		ConversationUUID: convUUID,
		RoomUUID:         in.RoomUUID,
		MessageUUID:      in.AgentMessageUUID,
		Blocks:           []map[string]any{{"type": "markdown", "text": snapshot}},
		Text:             snapshot,
		Timestamp:        time.Now(),
	}
	if err := s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, ev); err != nil {
		s.logger.Warn(ctx, "chat hermes publish block.delta failed",
			"stream_id", in.StreamID, "err", err.Error())
	}
}

func upsertHermesTool(tools map[string]*hermesToolState, order *[]string, ev hermesadapter.StreamEvent) *hermesToolState {
	id := strings.TrimSpace(ev.ToolCallID)
	if id == "" {
		return nil
	}
	st := tools[id]
	if st == nil {
		st = &hermesToolState{ID: id}
		tools[id] = st
		*order = append(*order, id)
	}
	if ev.ToolName != "" {
		st.Name = ev.ToolName
	}
	if ev.ToolStatus != "" {
		st.Status = ev.ToolStatus
	}
	return st
}

func (s *impl) publishHermesToolProgress(ctx context.Context, in HermesDispatchInput, st *hermesToolState) {
	if st == nil || st.ID == "" {
		return
	}
	convUUID := ""
	if in.Conversation != nil {
		convUUID = in.Conversation.UUID
	}
	ev := StreamEvent{
		Kind:             EventMessageToolCall,
		ConversationUUID: convUUID,
		RoomUUID:         in.RoomUUID,
		MessageUUID:      in.AgentMessageUUID,
		ToolCallID:       st.ID,
		ToolName:         st.Name,
		ToolStatus:       st.Status,
		Timestamp:        time.Now(),
	}
	if err := s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, ev); err != nil {
		s.logger.Warn(ctx, "chat hermes publish tool progress failed",
			"stream_id", in.StreamID, "tool_call_id", st.ID, "err", err.Error())
	}
}

func hermesFinalBlocks(order []string, tools map[string]*hermesToolState, text string) []map[string]any {
	blocks := make([]map[string]any, 0, len(order)+1)
	for _, id := range order {
		st := tools[id]
		if st == nil || st.ID == "" {
			continue
		}
		toolName := st.Name
		if toolName == "" {
			toolName = "工具"
		}
		status := st.Status
		if status == "" {
			status = "done"
		}
		blocks = append(blocks, map[string]any{
			"type":         "tool_call",
			"tool_call_id": st.ID,
			"tool":         toolName,
			"status":       status,
		})
	}
	if text != "" {
		blocks = append(blocks, map[string]any{"type": "markdown", "text": text})
	}
	if len(blocks) == 0 {
		return nil
	}
	return blocks
}

// hermesErrorToCode maps Hermes API errors to chat error codes.
func hermesErrorToCode(err error, sseCode string) string {
	var apiErr *hermesadapter.ChatAPIError
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.StatusCode == 401 || apiErr.StatusCode == 403:
			return ErrCodeProtocolUnsupported
		case apiErr.StatusCode >= 500:
			return fmt.Sprintf("hermes_upstream_%d", apiErr.StatusCode)
		case apiErr.StatusCode >= 400:
			return ErrCodeProtocolUnsupported
		}
	}
	if sseCode != "" {
		return "hermes_" + sseCode
	}
	return ErrCodeProtocolUnsupported
}

const sanitizedHermesFailureMessage = "agent runtime returned an error"

const ErrCodeHermesEmptyResponse = "hermes_empty_response"

// SetHermesDispatcher chat service setter for wiring.
func (s *impl) SetHermesDispatcher(d HermesDispatcher) { s.hermesDispatcher = d }

// SetHermesDispatcherOnService public helper.
func SetHermesDispatcherOnService(svc Service, d HermesDispatcher) {
	if im, ok := svc.(*impl); ok {
		im.SetHermesDispatcher(d)
	}
}

// SetHermesMCPToolsOnService enables the zhiban MCP tool context block (session_key)
// in the Hermes system prompt. Wire true only when the bus MCP endpoint is reachable
// from pods (runtime.self_base_url configured), matching the config.yaml render gate.
func SetHermesMCPToolsOnService(svc Service, enabled bool) {
	if im, ok := svc.(*impl); ok {
		im.hermesMCPTools = enabled
	}
}

var errHermesDispatcherMissing = errors.New("chat: hermes dispatcher not wired")

var ErrHermesRuntimeWarming = errors.New("hermes: runtime warming, retry later")
