package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	zap "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
)

func SetLocalRuntimeOnService(service Service, local *svclocal.Service) {
	if impl, ok := service.(*impl); ok {
		impl.localRuntime = local
	}
}

// Local execution retains the ordinary message stream, EMP mapping, task recorder and stop path.
// PostgreSQL transports the ZAP frames across Bus replicas; no cloud runtime environment is invented.
func (s *impl) runLocalChat(ctx context.Context, in ZapDispatchInput, d *zapDispatcherImpl) {
	// Local skills live in a host-managed directory, not cloud workspaces.
	// Forward original business text; DesktopContext loads selected skill blocks.
	prompt := localPromptText(in)
	get := func(key string) string { value, _ := in.UserMetadata[key].(string); return value }
	engine := in.Agent.LocalEngine
	if engine == "" {
		engine = domlocal.EngineDSH
	}
	runtimeKind := domrun.RuntimeDSH
	if engine == domlocal.EngineCodex {
		runtimeKind = domrun.RuntimeCodexAppServer
	}
	recorder := s.startRunRecorder(ctx, RunSpec{TenantID: in.TenantID, AccountID: in.AccountID, DigitalEmployeeID: in.Agent.ID, ConversationUUID: in.Conversation.UUID, MessageUUID: in.AgentMessageUUID, StreamID: in.StreamID, RuntimeKind: runtimeKind, ExecutionLocus: domrun.ExecutionLocusLocal, RequestedModel: selectedConversationModel(in.UserMetadata), TriggerSource: localTriggerSource(in.UserMetadata), AgentVersion: in.Agent.CurrentVersion})
	finish := func(blocks []map[string]any, status, code, message string, usage map[string]any) {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, blocks, status, code, message, usage)
	}
	scope := domlocal.Scope{TenantID: in.TenantID, AccountID: in.AccountID, SessionUUID: get("local_login_session_id")}
	if s.localRuntime == nil || scope.SessionUUID == "" || in.RoomUUID != "" || !canRunOnCallersComputer(in.Agent, in.AccountID) {
		finish(nil, "failed", "local_runtime.unavailable", "本机执行上下文不可用，请确认桌面已登录在线；定时任务持续失败时请联系管理员检查调度服务版本", nil)
		return
	}
	version, err := s.agents.GetVersion(ctx, in.Agent.ID, in.Agent.CurrentVersion)
	if err != nil || version == nil {
		finish(nil, "failed", "local_runtime.config_unavailable", "数字员工发布配置不可用", nil)
		return
	}
	persona, _ := version.Snapshot["system_prompt"].(string)
	history, err := s.messages.History(ctx, dommsg.HistoryFilter{ConversationID: in.Conversation.ID, Limit: 40})
	if err != nil {
		finish(nil, "failed", "local_runtime.history_unavailable", "会话记录暂不可用", nil)
		return
	}
	sort.Slice(history, func(i, j int) bool { return history[i].CreatedAt.Before(history[j].CreatedAt) })
	past := localHistoryTranscript(history, in.AgentMessageUUID, firstNonEmpty(get("cron_trigger_message_uuid"), in.UserMessageUUID), in.TenantID)

	blocks, err := s.prepareZapRuntimeFileBlocks(ctx, in.AccountID, in.TenantID, cloneZapOutboundBlocks(in.UserBlocks))
	if err != nil {
		finish(nil, "failed", "local_runtime.attachments_unavailable", "附件暂不可用", nil)
		return
	}
	kc := s.prepareRuntimeKnowledgeContext(ctx, ChatRAGRequest{TenantID: in.TenantID, AccountID: in.AccountID, Agent: in.Agent, Conversation: in.Conversation, MessageUUID: in.AgentMessageUUID, QueryOriginal: prompt, QueryRewritten: prompt, InvocationSource: "pre_retrieve"})
	contextID := get("local_context_id")
	if contextID == "" {
		saved, stateErr := s.localRuntime.ConversationState(ctx, scope, in.Conversation.UUID)
		if stateErr != nil {
			finish(nil, "failed", "local_runtime.context_unavailable", "会话工作目录暂不可用", nil)
			return
		}
		contextID = saved["context_id"]
	}
	if contextID == "" {
		// Retain a previous desktop mapping when the phone continues that same conversation.
		for i := len(history) - 1; i >= 0; i-- {
			if value, ok := history[i].Metadata["local_context_id"].(string); ok && value != "" {
				contextID = value
				break
			}
		}
	}
	if contextID == "" {
		contextID = in.Conversation.UUID
	}
	payload, err := json.Marshal(map[string]any{"local_context_id": contextID, "task_source": localTaskSource(get("local_task_source")), "employee_name": in.Agent.Name, "text": prompt, "persona": persona, "history": past, "blocks": blocks, "skills": d.buildZapSessionSkills(ctx, in), "knowledge_context": zapKnowledgeContextMetadata(kc), "metadata": mergeZapForwardedUserMetadata(nil, in.UserMetadata)})
	if err != nil {
		finish(nil, "failed", "local_runtime.config_unavailable", "本机任务配置无效", nil)
		return
	}
	task, err := s.localRuntime.Create(ctx, domlocal.Task{LocalEngine: engine, Scope: scope, RequesterSessionUUID: get("local_requester_session_id"), DeviceUUID: get("local_device_id"), EmployeeID: in.Agent.ID, ConversationUUID: in.Conversation.UUID, MessageUUID: in.AgentMessageUUID, StreamID: in.StreamID, Model: get("local_model_hint"), Payload: payload})
	if err != nil {
		if errors.Is(err, domlocal.ErrUpgradeRequired) {
			finish(nil, "failed", "local_runtime.upgrade_required", "当前电脑未提供所选引擎，请更新电脑客户端并检查本地引擎状态", nil)
			return
		}
		logpkg.Default().Warn(ctx, "local_chat.task_create_failed", "account_id", in.AccountID, "tenant_id", in.TenantID, "employee_id", in.Agent.ID, "message_uuid", in.AgentMessageUUID, "stream_id", in.StreamID, "requested_model", boundedChatModel(get("conversation_model")), "task_model", boundedChatModel(get("local_model_hint")), "error", boundedChatModel(err.Error()))
		finish(nil, "failed", "local_runtime.device_unavailable", "电脑已离线、授权已失效或当前会话已有任务", nil)
		return
	}
	logpkg.Default().Info(ctx, "local_chat.task_dispatched", "account_id", in.AccountID, "tenant_id", in.TenantID, "employee_id", in.Agent.ID, "message_uuid", in.AgentMessageUUID, "stream_id", in.StreamID, "run_uuid", task.UUID, "requested_model", boundedChatModel(get("conversation_model")), "task_model", boundedChatModel(task.Model))
	// RequestedModel above is the user's own selection (conversation_model).
	// local_model_hint is already server-resolved, and task.Model is the final
	// arbitration — that last one is what usage must be attributed to.
	recorder.OnExecutedModel(firstNonEmpty(task.Model, get("local_model_hint")))
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = s.localRuntime.Cancel(cleanup, scope, task.UUID)
	}()
	var seq int64
	var snapshot string
	var artifacts []map[string]any
	archiveStarted := false
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			finish(localPartialBlocks(snapshot, artifacts), "cancelled", "", "任务已停止", nil)
			return
		case <-ticker.C:
		}
		events, err := s.localRuntime.Events(ctx, scope, task.UUID, seq)
		if err != nil {
			finish(localPartialBlocks(snapshot, artifacts), "failed", "local_runtime.transport_failed", "本机任务通道中断", nil)
			return
		}
		for _, event := range events {
			if event.Name == "message.failed" || event.Name == "message.completed" || event.Name == "message.cancelled" {
				logpkg.Default().Info(ctx, "local_chat.terminal_event", "run_uuid", task.UUID, "message_uuid", in.AgentMessageUUID, "stream_id", in.StreamID, "event", event.Name, "seq", event.Seq)
			}
			if event.Name == "message.block.delta" {
				if text, ok := localArchiveProgressText(event.Data); ok {
					archiveStarted = true
					_ = s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, StreamEvent{Kind: EventMessageStage, ConversationUUID: in.Conversation.UUID, MessageUUID: in.AgentMessageUUID, StageID: "local-archive", StageText: text, Timestamp: time.Now()})
					seq = event.Seq
					continue
				}
				var progress struct {
					Block struct {
						Type string `json:"type"`
						Text string `json:"text"`
						// Structured recovery telemetry. Controlled enums only — the runtime
						// never forwards upstream error text here.
						RetryIndex    int    `json:"retry_index"`
						RetryReason   string `json:"retry_reason"`
						FallbackChain []struct {
							Slot   int    `json:"slot"`
							Reason string `json:"reason"`
						} `json:"fallback_chain"`
					} `json:"block_delta"`
				}
				if json.Unmarshal(event.Data, &progress) == nil && progress.Block.Type == "local_model_recovery" {
					if len(progress.Block.Text) <= 1024 {
						_ = s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, StreamEvent{Kind: EventMessageStage, ConversationUUID: in.Conversation.UUID, MessageUUID: in.AgentMessageUUID, StageID: "local-model-recovery", StageText: progress.Block.Text, Timestamp: time.Now()})
					}
					// Record the newest step only: the runtime reports the whole chain each
					// time, and the recorder counts attempts itself.
					if n := len(progress.Block.FallbackChain); n > 0 && progress.Block.RetryIndex > recorder.RetryIndex() {
						step := progress.Block.FallbackChain[n-1]
						recorder.OnModelRetry(step.Slot, task.Model, localRetryReason(step.Reason))
					}
					seq = event.Seq
					continue
				}
			}
			ev, err := zap.DecodeBusinessEvent(event.Name, event.Data)
			if err != nil {
				finish(nil, "failed", "local_runtime.invalid_event", "本机任务返回了无效事件", nil)
				return
			}
			seq = event.Seq
			if archiveStarted && (ev.Kind == zap.SSECompleted || ev.Kind == zap.SSEFailed || ev.Kind == zap.SSECancelled) {
				for _, stage := range localArchiveTerminalStages(ev.Blocks) {
					stage.ConversationUUID, stage.MessageUUID, stage.Timestamp = in.Conversation.UUID, in.AgentMessageUUID, time.Now()
					_ = s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, stage)
				}
			}
			switch ev.Kind {
			case zap.SSEBlockDelta:
				if ev.BlockDelta["type"] == "local_artifacts" {
					// Append validates these references against the authenticated task/device.
					encoded, _ := json.Marshal(ev.BlockDelta["blocks"])
					var next []map[string]any
					if json.Unmarshal(encoded, &next) == nil {
						artifacts = next
						s.publishLocalSnapshot(ctx, in, snapshot, artifacts)
					}
					continue
				}
				delta, kind := extractZapBlockDeltaText(ev.BlockDelta)
				if delta != "" && (kind == "" || kind == "markdown" || kind == "plain") {
					snapshot = applyMarkdownDelta(snapshot, delta)
					recorder.OnOutput(time.Now())
					s.publishLocalSnapshot(ctx, in, snapshot, artifacts)
				}
			case zap.SSEReasoning:
				recorder.OnReasoning(time.Now())
				s.publishZapReasoning(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, ev)
			case zap.SSEToolCall, zap.SSEToolResult:
				if ev.Kind == zap.SSEToolCall {
					recorder.OnToolCall(ev.ToolCallID, ev.ToolName, time.Now())
				} else {
					recorder.OnToolResult(ev.ToolCallID, !zapToolStatusFailed(ev.ToolStatus), "", time.Now())
				}
				s.publishZapTool(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, ev)
			case zap.SSECompleted:
				// Execution and archival have independent outcomes. The local terminal is authoritative;
				// the host owns the final execution/archive outcome; preserve its failure and file cards.
				finish(finalBlocksWithKnowledgeContextSources(canonicalMapBlocks(ev.Blocks), kc), "final", "", "", ev.Usage)
				return
			case zap.SSEFailed:
				finish(localPartialBlocks(snapshot, ev.Blocks), "failed", sanitizeRuntimeErrorCode(ev.ErrorCode, ev.ErrorMessage), sanitizeRuntimeError(ev.ErrorCode, ev.ErrorMessage), nil)
				return
			case zap.SSECancelled:
				finish(localPartialBlocks(snapshot, ev.Blocks), "cancelled", "", "任务已停止", nil)
				return
			}
		}
		current, err := s.localRuntime.Task(ctx, scope, task.UUID)
		// A terminal frame may commit between Events and Task. Drain it before
		// deriving interruption from the task row, preserving its actual result.
		if err == nil && current.LastSeq > seq {
			continue
		}
		if err != nil || current.Status == "failed" || current.Status == "cancelled" || !current.ExpiresAt.After(time.Now()) {
			finish(localPartialBlocks(snapshot, artifacts), "failed", "local_runtime.interrupted", "本机任务中断，请检查电脑状态和部分结果后续跑", nil)
			return
		}
	}
}

func canRunOnCallersComputer(agent *domagent.DigitalEmployee, accountID int64) bool {
	return agent != nil && (agent.Source == "platform" || agent.Source == "enterprise" || agent.CreatorID == accountID)
}

func (s *impl) publishLocalSnapshot(ctx context.Context, in ZapDispatchInput, snapshot string, artifacts []map[string]any) {
	_ = s.fanout.Publish(ctx, in.StreamID, in.AccountID, in.TenantID, StreamEvent{
		Kind: EventMessageBlockDelta, ConversationUUID: in.Conversation.UUID,
		MessageUUID: in.AgentMessageUUID, Text: snapshot, LocalArtifacts: true,
		Blocks: localPartialBlocks(snapshot, artifacts), Timestamp: time.Now(),
	})
}

func boundedChatModel(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 200 {
		return value[:200]
	}
	return value
}

// Prefer the terminal's confirmed text; use streamed text only when it is absent.
func localPartialBlocks(snapshot string, blocks []map[string]any) []map[string]any {
	for _, block := range blocks {
		text, _ := block["text"].(string)
		if (block["type"] == "markdown" || block["type"] == "plain") && text != "" {
			return blocks
		}
	}
	if snapshot == "" {
		return blocks
	}
	return append([]map[string]any{{"type": "markdown", "text": snapshot}}, blocks...)
}

func localTaskSource(value string) string {
	if value == "mobile" {
		return "mobile"
	}
	return "desktop"
}

// localRetryReason maps the runtime's controlled enum onto the run-record enum,
// refusing anything unrecognized so upstream text can never reach the column.
func localRetryReason(reason string) string {
	switch reason {
	case domrun.RetryReasonUpstreamUnavailable, domrun.RetryReasonHeaderTimeout, domrun.RetryReasonTransportError:
		return reason
	default:
		return domrun.RetryReasonUpstreamUnavailable
	}
}

// Preserve execution/delivery facts in history, never turn old promises into new instructions.
func localHistoryTranscript(history []dommsg.Message, answerID, questionID string, tenantID int64) string {
	var transcript strings.Builder
	for _, message := range history {
		if message.UUID == answerID || message.UUID == questionID || message.TenantID != tenantID {
			continue
		}
		files := []string{}
		for _, block := range message.Blocks {
			if block["local_artifact"] != nil {
				if name, ok := block["name"].(string); ok {
					files = append(files, name)
				}
			}
		}
		row := map[string]any{"role": message.Role, "status": message.Status, "text": extractText(message.Blocks), "generated_files": files}
		encoded, err := json.Marshal(row)
		if err == nil {
			transcript.Write(encoded)
			transcript.WriteByte('\n')
		}
	}
	past := transcript.String()
	if len(past) > 24000 {
		// Drop the oldest partial row too; never inject broken JSON or UTF-8.
		past = past[len(past)-24000:]
		if end := strings.IndexByte(past, '\n'); end >= 0 {
			past = past[end+1:]
		}
	}
	return past
}

// Count processed files, not successful uploads. Never display runtime-provided text/paths.
func localArchiveProgressText(data []byte) (string, bool) {
	var event struct {
		Block struct {
			Type      string `json:"type"`
			Completed *int   `json:"completed"`
			Total     *int   `json:"total"`
		} `json:"block_delta"`
	}
	if json.Unmarshal(data, &event) != nil || event.Block.Type != "local_archive_progress" {
		return "", false
	}
	b := event.Block
	if b.Completed == nil || b.Total == nil || *b.Total <= 0 || *b.Completed < 0 || *b.Completed > *b.Total {
		return "", false
	}
	return fmt.Sprintf("正在保存到云盘（已处理 %d/%d）", *b.Completed, *b.Total), true
}

// Finish the archive step independently of the model's terminal status.
func localArchiveTerminalStages(blocks []map[string]any) []StreamEvent {
	count, synced := 0, true
	for _, block := range blocks {
		if _, ok := block["local_artifact"]; !ok {
			continue
		}
		count++
		if block["archive_status"] != "synced" {
			synced = false
		}
	}
	text := "云盘保存未完成"
	if count > 0 && synced {
		text = "云盘保存完成"
	}
	events := []StreamEvent{{Kind: EventMessageStage, StageID: "local-archive", StageText: text}}
	if count > 0 && synced {
		events = append(events, StreamEvent{Kind: EventMessageStageDone})
	}
	return events
}

func localPromptText(in ZapDispatchInput) string {
	if len(in.UserBlocks) > 0 {
		return strings.TrimSpace(extractPromptText(in.UserBlocks))
	}
	return in.PromptText
}
