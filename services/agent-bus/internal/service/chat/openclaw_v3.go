// openclaw_v3.go — Batch 2D T2D.1: chat 服务直连 OpenClaw Gateway v3 (chat.send WS) 路径。
//
// 本文件实现 chat 服务对 OpenClaw 的**唯一**调用路径; 不再经 runtime.Manager 间接调用
// 旧 OpenResponses HTTP+SSE adapter (`internal/adapter/runtime/openclaw/adapter.go` DEPRECATED)。
//
// 守卫规则 (2026-06-02 Fix2 后权威口径):
//   - 数字员工必须绑 `runtime_environment_id` (digital_employees 列, F02 v0.3),
//     否则 chat.runtime_protocol_unsupported
//   - endpoint 由 RuntimeInstanceResolver 按 (runtime_environment_id, tenant_id, account_id) 解析:
//       * runtime_environments.framework 必须 = "openclaw" (resolver 内部 fail-closed,
//         非 openclaw → ErrFrameworkUnsupported → chat.runtime_protocol_unsupported)
//       * hosting_kind=clawmanager/k8s_native → 查 runtime_instances 中 status='ready' 行的
//         endpoint_url + agent_gateway_token (per-user pod, decrypted via SecretResolver)
//       * hosting_kind=external_endpoint → runtime_environments.primary_endpoint +
//         api_key_secret_ref (decrypted)
//       * 其它 hosting_kind → ErrEndpointNotConfigured (fail-closed, 不回退 env URL)
//   - **解析出的真实 endpoint URL** 不允许包含 "/v1/responses" path (防 admin 把 OpenResponses
//     兼容层 URL 误配进 runtime_environments.primary_endpoint, 让 chat 走回旧 HTTP+SSE)
//   - 旧 runtime_registrations / runtime_registrations.framework / metadata.legacy_endpoints
//     **不再参与** chat endpoint 解析 (F02 v0.3 后底表已 merge 到 runtime_environments,
//     deprecated repository/postgres/runtime/repo.go 仅 legacy mapping shim)。
//
// 协议 (Gateway v3, 与 legacy ai-office chat_runner_ws.go 等价):
//   pre[0] = sessions.create({key, agentId})
//   pre[1] = sessions.messages.subscribe({key})
//   main   = chat.send({sessionKey, message, idempotencyKey})
//
//   sessionKey = "agent:<agentUUID>:<conversationUUID>"
//   (OpenClaw resolveSessionAgentIds() 只能从 sessionKey 解析 agentId; 走错就 fallback
//    到 default agent 导致非 main agent 的 IDENTITY/skill 失效, 详见 legacy chat_runner_ws.go §75)
//
// T2D.1 仅做"路径切换 + 守卫": 帧翻译保留与现有 hub publisher 相同的 delta/final 语义,
// 不改 SSE 事件协议。完整 EMP block 翻译 / token usage / stuck 检测 / tool 事件透出
// 留 T2D.4 / T2D.5 / T2D.7 / T2D.10 (M4 完整版)。

package chat

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/gatewayws"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domagentrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
	domrt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// errProtocolUnsupported 是 chat 守卫触发后返回的稳定 sentinel; 上层
// (Send / runAgent.finalize) 据此把 errCode 写成 "chat.runtime_protocol_unsupported"。
var errProtocolUnsupported = errors.New("chat: runtime protocol unsupported")

// Reclassify only an upstream quota/key-disabled rejection corroborated by the
// current wallet. A later balance change must never overwrite a model or tool error.
func (s *impl) reclassifyRuntimeFailureAsCredits(ctx context.Context, tenantID, accountID int64, code, msg string) (string, string) {
	evidence := strings.ToLower(msg)
	creditRejection := false
	for _, marker := range []string{"insufficient_quota", "quota_exceeded", "billing_hard_limit", "insufficient balance", "额度不足", "余额不足", "token is disabled", "令牌已禁用"} {
		if strings.Contains(evidence, marker) {
			creditRejection = true
			break
		}
	}
	if s.creditStatus == nil || strings.HasPrefix(code, "model.") || !creditRejection {
		return code, msg
	}
	err := s.creditStatus.EnsureCreditsAvailable(ctx, tenantID, accountID, "chat_runtime_failure")
	if err == nil {
		return code, msg
	}
	ae, ok := apperr.AsError(err)
	if !ok || ae.Code != apperr.PaymentRequired {
		return code, msg
	}
	return "billing.insufficient_credits", ae.Message
}

// ErrCodeProtocolUnsupported 是写到 messages.error_code / SSE event.error 的字符串错误码。
const ErrCodeProtocolUnsupported = "chat.runtime_protocol_unsupported"

// errRuntimeNotReady 表示 runtime 已配但**当前 (tenant, account, env) 维度没有 ready
// runtime_instance** (clawmanager / k8s_native: pod 还没起 / 不健康)。与 errProtocolUnsupported
// 是不同诊断: 后者表示 framework / 配置不对 (常态错误); 前者是临时不可达, caller 应回 runtime.warming
// (HTTP 503, code chat.runtime_warming), 或 queue worker 留任务 retry。
//
// 触发源: openclaw.ErrInstanceNotReady (resolver_instance.go), resolveOpenClawV3Endpoint 包成
// 这个 sentinel 透出。
var errRuntimeNotReady = errors.New("chat: runtime instance not ready (warming)")

// ErrCodeRuntimeWarming 写到 SSE event.error / apperr code 时的"实例未就绪"码。
// **不要** 让客户端看到 chat.runtime_protocol_unsupported (那是配置错), 见 doc-11 §4 / 路由
// 503 runtime.warming 协议: 客户端 retry / 显示「环境准备中」。
const ErrCodeRuntimeWarming = "chat.runtime_warming"

// doc-12 §11.8: 上游 "agent no longer exists in configuration" 按**真实注册任务状态**分类, 不一律 warming。
const (
	// ErrCodeAgentRegistrationFailed: 该 DE 的 agent_register 任务终态 failed (注册真的失败, 非瞬时)。
	ErrCodeAgentRegistrationFailed = "chat.agent_registration_failed"
	// ErrCodeControlPlaneNotReady: 根本没有 agent_register 任务 (capability 未声明 / K8S 写入通道缺失 →
	// buildPlan 不生成), 属配置未就绪, 不是瞬时 warming。
	ErrCodeControlPlaneNotReady = "chat.runtime_control_plane_not_ready"
)

const (
	assistantFlushInterval       = 100 * time.Millisecond
	assistantFlushMaxRunes       = 48
	assistantFlushBoundaryRunes  = "\n。！？!?；;"
	assistantDetachedFlushLimit  = 3 * time.Second
	openClawOutputPublishTimeout = 2 * time.Minute
)

var openClawFirstBusinessEventLimit = 120 * time.Second

// AgentRegisterStatusLookup 查某 DE 最近一条 agent_register 任务状态 (注入自 runtimeprewarm.Repo)。
// found=false → 从无该任务。nil → chat 退化为旧行为 (统一 warming)。只读, 不触发注册。
type AgentRegisterStatusLookup interface {
	LatestAgentRegisterStatus(ctx context.Context, tenantID, accountID, runtimeEnvID int64, deUUID string) (status string, found bool, err error)
}

// resolveOpenClawV3Endpoint 是 chat 唯一 endpoint 解析入口。
//
// 输入: ag.RuntimeEnvironmentID (digital_employees.runtime_environment_id, F02 v0.3 FK→runtime_environments.id)
// 输出: gatewayws.Endpoint{HTTPURL, Bearer}, *domrt.Registration **始终为 nil** (留接口签名,
//
//	Send/queue/orchestrator/RunAgentForConversation 所有 caller 都 `_` 忽略它), 错误。
//
// 解析口径 (RuntimeInstanceResolver, 见 internal/adapter/runtime/openclaw/resolver_instance.go):
//   - 按 runtime_environments.hosting_kind 分流: clawmanager/k8s_native → runtime_instances,
//     external_endpoint → runtime_environments.primary_endpoint, unknown → fail-closed
//   - framework 必须 = "openclaw" (resolver fail-closed)
//   - **绝不**回退 cfg.Runtime.LocalEndpointURL / 127.0.0.1 / metadata.legacy_endpoints
//
// accountID 是 service 层已派生的 runtime owner（private agent=creator，其它=caller），透传给 resolver：
// clawmanager/k8s_native per-user pod 必须按
// (runtime_environment_id, tenantID, accountID) 解析到该用户自己的 Pod;
// 早期硬编码 0 会让所有用户解析到同一实例 (per-user 隔离失效)。所有调用点
// (Send 单体 / queue worker / RunAgentForConversation / 编排 child) 都必须透传正确的 runtime owner。
//
// 错误分流 (chat 侧 sentinel):
//   - openclaw.ErrInstanceNotReady (clawmanager/k8s_native: pod 还没起 / 不健康)
//     → errRuntimeNotReady → caller 返 503 chat.runtime_warming; queue worker 留任务 retry。
//   - 其它 (framework 不对 / primary_endpoint 空 / hosting_kind unknown / secret 解不开 /
//     resolved URL 含 /v1/responses) → errProtocolUnsupported → chat.runtime_protocol_unsupported。
func (s *impl) resolveOpenClawV3Endpoint(ctx context.Context, tenantID, accountID int64, ag *domagent.DigitalEmployee) (gatewayws.Endpoint, *domrt.Registration, error) {
	if ag == nil || ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID <= 0 {
		return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: agent has no runtime_environment_id", errProtocolUnsupported)
	}
	if s.openclawResolver == nil {
		return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: openclaw instance resolver not wired", errProtocolUnsupported)
	}
	// 本函数只做: ① nil 校验 + agent 必须绑 runtime_environment_id; ② 翻译 resolver 错误为
	// chat 侧 sentinel (errRuntimeNotReady / errProtocolUnsupported); ③ resolver 返回的真实
	// endpoint URL 上做 /v1/responses 防御 (admin 误把 OpenResponses 兼容层 URL 配进
	// runtime_environments.primary_endpoint 时拦掉, 不让 chat 走回旧 HTTP+SSE)。
	// 解析口径 (framework / hosting_kind / runtime_instances vs primary_endpoint) 全部沉到
	// RuntimeInstanceResolver 内部, 见 internal/adapter/runtime/openclaw/resolver_instance.go 顶注释。
	// ADR-0037 Phase 3/5: BYOK 数字员工连的是自己的专属 pod endpoint, 不是共享 pod。
	var openclawAgentUUID *string
	if ag.ModelSource == "byok" {
		openclawAgentUUID = &ag.UUID
	}
	ep, err := s.openclawResolver.Resolve(ctx, *ag.RuntimeEnvironmentID, tenantID, accountID, openclawAgentUUID)
	if err != nil {
		if errors.Is(err, openclaw.ErrInstanceNotReady) {
			return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: %v", errRuntimeNotReady, err)
		}
		return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: resolve openclaw endpoint: %v", errProtocolUnsupported, err)
	}
	if ep.URL == "" {
		return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: resolved endpoint URL is empty", errProtocolUnsupported)
	}
	if containsResponsesPath(ep.URL) {
		return gatewayws.Endpoint{}, nil, fmt.Errorf("%w: resolved endpoint URL=%q contains /v1/responses (legacy HTTP+SSE compat); chat must use Gateway v3 WS", errProtocolUnsupported, ep.URL)
	}
	// Registration 返回 nil: 所有现有 caller (Send / RunAgentForConversation / orchestrator / queue worker)
	// 都用 `_` 忽略 2nd 返回, 留接口签名以便日后接 4 类 hosting 时不动 caller。
	return gatewayws.Endpoint{HTTPURL: ep.URL, Bearer: ep.Bearer}, nil, nil
}

// containsResponsesPath 判断给定 URL 字符串是否含 OpenResponses HTTP+SSE 路径前缀。
//
// 兼容大小写 / trailing-slash / query string; 不解析完整 URL (开发态 endpoint
// 字段可能本身是裸 host:port, 也可能是带 path 的完整 URL)。
func containsResponsesPath(u string) bool {
	if u == "" {
		return false
	}
	low := strings.ToLower(u)
	return strings.Contains(low, "/v1/responses")
}

// runOpenClawV3 通过 Gateway v3 WS 执行一次 chat.send 并把帧翻译为 Fanout
// 期望的 delta/final 事件 (与现有 SSE 协议一致, T2D.1 不改协议; T3.1 仅把 publish
// 通道从 *publisher.send 改成 s.fanout.Publish, 事件 envelope 不动)。
//
// 退出条件: 见 processFramesV3。
//
// T2D.1 范围内: 只翻译 assistant snapshot 文本 (data.text 累计) → emit cumulative delta;
// tool 事件 / EMP block / token usage 不解释 (留 T2D.4 / T2D.5 / T2D.7)。
func (s *impl) runOpenClawV3(
	ctx context.Context,
	streamID string,
	accountID, runtimeAccountID, tenantID int64,
	ep gatewayws.Endpoint,
	ag *domagent.DigitalEmployee,
	conversationUUID string,
	roomUUID string,
	agentMsgUUID string,
	userMessage string,
	verParams *versionParams,
	kc *KnowledgeContext,
) {
	// F24: run recorder opens before guards so dispatch failures land as
	// failed runs (finalize flushes by streamID; nil-safe when not wired).
	rec := s.startRunRecorder(ctx, RunSpec{
		// Cloud paths state the locus explicitly: relying on a default would let a
		// future local path mislabel itself silently, which is the defect this column exists for.
		ExecutionLocus:       domagentrun.ExecutionLocusCloud,
		TenantID:             tenantID,
		AccountID:            accountID,
		DigitalEmployeeID:    ag.ID,
		ConversationUUID:     conversationUUID,
		MessageUUID:          agentMsgUUID,
		StreamID:             streamID,
		RuntimeKind:          domagentrun.RuntimeOpenClaw,
		RuntimeEnvironmentID: ag.RuntimeEnvironmentID,
		TriggerSource:        zapTriggerSource(roomUUID),
		AgentVersion:         openClawRunVersion(verParams, ag),
	})
	_ = rec

	if s.openclawClient == nil {
		s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, nil, "failed", ErrCodeProtocolUnsupported, "openclaw gateway client not wired", nil)
		return
	}
	if conversationUUID == "" {
		s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, nil, "failed", ErrCodeProtocolUnsupported, "missing conversation uuid", nil)
		return
	}
	if verParams == nil {
		// Send 路径已经 fail-closed; 这里属于编程错误兜底。
		s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, nil, "failed", ErrCodeVersionSnapshotInvalid, "missing version params", nil)
		return
	}

	// sessionKey 必须 OpenClaw v3 的 agent-scoped 格式; 见文件头 protocol 注释。
	sessionKey := "agent:" + ag.UUID + ":" + conversationUUID

	pre := []gatewayws.Request{
		{Method: "sessions.create", Params: map[string]any{
			"key":     sessionKey,
			"agentId": ag.UUID,
		}},
		{Method: "sessions.messages.subscribe", Params: map[string]any{
			"key": sessionKey,
		}},
	}
	binding, bindingErr := s.prepareConversationModel(ctx, accountID, tenantID, ag, agentMsgUUID, verParams.SelectedModel)
	if bindingErr != nil {
		s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, nil, "failed", "model.platform_unavailable", "所选模型平台不可用，请重新选择", nil)
		return
	}
	if binding != nil {
		pre = append(pre, gatewayws.Request{RequireSuccess: true, Method: "zhiban.model.bind", Params: map[string]any{"key": sessionKey, "binding": binding}})
	}
	if verParams.SelectedModel != "" && binding == nil {
		model := "beebridge/" + strings.TrimPrefix(verParams.SelectedModel, "beebridge/")
		if ag.ModelSource == "byok" {
			model = "openai/" + verParams.SelectedModel
		}
		pre = append(pre, gatewayws.Request{RequireSuccess: true, Method: "sessions.patch", Params: map[string]any{"key": sessionKey, "model": model}})
	}
	// chat.send 主参数严格按 Gateway v3 schema (实测 strict, 拒未知顶层字段如 'metadata');
	// snapshot 衍生参数 (system prompt / model / temperature) 由 2C publish 时写入 OpenClaw
	// Agent Card / workspace, **不在 chat.send 时再次传递** —— 否则会被 schema 校验拒。
	// 见 docs/tasks/batch-2d-main-flow-1v1-chat.md §10 R6 (T2D.11 smoke 暴露的 schema 现实)。
	//
	// snapshot 仍由 Send -> loadVersionParams 加载并校验 model 必填 (T2D.3-B 失败前置检查),
	// 这里只把它作为诊断日志带出 (agent_version + model 字段已经在 runAgent 头部 Info 日志里)。
	_ = verParams // 不写到 wire, 仅 Send 阶段做校验 + 日志
	runID := idempotencyKeyFor(streamID)
	mainParams := map[string]any{
		"sessionKey":     sessionKey,
		"message":        userMessage,
		"idempotencyKey": runID,
	}

	// chat.send 整体生命周期: 单条对话最多 10 分钟 (与 legacy ai-office 一致;
	// gatewayws.Client 自身也有 defaultStreamLimit, 这里再加一层显式 ctx 上限便于
	// 调用方 cancel 即收尾)。
	callCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	frames, streamCancel, err := s.openclawClient.CallStream(callCtx, ep, pre, "chat.send", mainParams)
	if err != nil {
		// AUTH_TOKEN_MISMATCH: gateway 亲口拒绝了这个 token, 比 CheckReady 的探活更可信
		// 的"这一行缓存的 endpoint 已经过期/指向别的 pod"信号——别等下次探活凑巧失败,
		// 直接让下一条消息强制走一遍全新 ensure。
		if strings.Contains(err.Error(), "AUTH_TOKEN_MISMATCH") || strings.Contains(err.Error(), "token_mismatch") {
			logpkg.Default().Warn(ctx, "chat: gateway token mismatch; invalidating cached runtime instance",
				"agent_uuid", ag.UUID, "endpoint", ep.HTTPURL)
			if s.readyChecker != nil && ag.RuntimeEnvironmentID != nil && *ag.RuntimeEnvironmentID > 0 {
				var invalidateAgentUUID *string
				if ag.ModelSource == "byok" {
					invalidateAgentUUID = &ag.UUID
				}
				if ierr := s.readyChecker.InvalidateInstance(ctx, tenantID, runtimeAccountID, *ag.RuntimeEnvironmentID, invalidateAgentUUID, "gateway_token_mismatch: "+err.Error()); ierr != nil {
					logpkg.Default().Warn(ctx, "chat: InvalidateInstance after token mismatch failed", "agent_uuid", ag.UUID, "err", ierr.Error())
				}
			}
		}
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkOpenClaw,
			FailureStage:     "call_stream_open",
			StreamID:         streamID,
			MessageUUID:      agentMsgUUID,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			AccountID:        accountID,
			TenantID:         tenantID,
			Agent:            ag,
			ErrorCode:        "chat.upstream_call_failed",
			Diagnostic:       err.Error(),
		})
		code, message := "chat.upstream_call_failed", err.Error()
		if verParams.SelectedModel != "" && errors.Is(err, gatewayws.ErrRequiredRequestRejected) {
			code, message = "model.not_allowed", "运行环境尚未支持所选模型，请同步运行环境的模型配置后重试"
		}
		s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, nil, "failed", code, message, nil)
		return
	}
	defer streamCancel()
	defer s.abortOpenClawRunBestEffort(ep, sessionKey, runID)

	var runtimeEnvID int64
	if ag.RuntimeEnvironmentID != nil {
		runtimeEnvID = *ag.RuntimeEnvironmentID
	}
	s.processFramesV3(callCtx, sessionKey, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, ag.UUID, runtimeEnvID, frames, kc, runtimeAccountID)
}

// processFramesV3 读 gatewayws Frame 流并按 OpenClaw v3 协议翻译为 hub publisher
// 的事件 (T2D.5 命名: message.block.delta / message.completed / message.failed)。
// 同时把累计 blocks 落到 DB (T2D.4 §3 SSE 与 DB 一致), session.message 携带的 usage
// 抓到内存最后跟 final 一起写到 messages.metadata.usage。
//
// 退出条件:
//   - 收到 agent stream=lifecycle phase=end → finalize "final" → message.completed
//   - 收到 agent stream=lifecycle phase=error → finalize "failed" → message.failed
//   - 收到 chat.send / sessions.* reply !ok → finalize "failed" (chat.upstream_call_failed)
//   - frames channel 关闭 / ctx 取消 → 兜底 finalize "final"
//
// 串台防御: agent / session.message 帧若 payload 顶层 sessionKey 非空且 != 本次 sessionKey,
// 直接丢; sessionKey 缺失保留 (兼容老网关帧不带该字段)。详见注释段。
func (s *impl) processFramesV3(
	ctx context.Context,
	sessionKey string,
	streamID string,
	accountID, tenantID int64,
	conversationUUID string,
	roomUUID string,
	agentMsgUUID string,
	agentUUID string, // doc-12 §11.8: 用于 classifyAgentNotRegistered 查 agent_register 任务状态
	runtimeEnvID int64,
	frames <-chan gatewayws.Frame,
	kc *KnowledgeContext,
	runtimeAccountIDs ...int64,
) {
	runtimeAccountID := accountID
	if len(runtimeAccountIDs) > 0 && runtimeAccountIDs[0] > 0 {
		runtimeAccountID = runtimeAccountIDs[0]
	}
	// F24: recorder was opened by runOpenClawV3 (same streamID); nil-safe.
	rec := s.runRecs.lookupStream(streamID)
	var (
		assistantSnapshot string
		emittedLen        int
		lastFlushLen      int
		pendingDirty      bool
		finalized         bool
		startedAt         = time.Now()
		firstDeltaLogged  bool
		finishReason      = "unknown"
		frameCounts       = map[string]int{}
		// usage 是 session.message 带过来的 token 用量 (model + input/output/total tokens 等);
		// 终态 finalize 一次写入 messages.metadata.usage。
		usage map[string]any
		// T2D.7: 一次记一次的 fallback-markdown 日志去重 (避免每条 tool 帧都打日志);
		// key 形如 "agent.tool" / "event.tick"。
		seenFallback = map[string]bool{}
		toolsByID    = map[string]*openClawToolState{}
		toolOrder    []string
		lastToolID   string
	)
	defer func() {
		s.logger.Info(ctx, "chat openclaw v3 stream summary",
			"stream_id", streamID,
			"conversation_uuid", conversationUUID,
			"room_uuid", roomUUID,
			"agent_uuid", agentUUID,
			"finish_reason", finishReason,
			"finalized", finalized,
			"assistant_chars", len([]rune(assistantSnapshot)),
			"emitted_bytes", emittedLen,
			"frame_counts", formatFrameCounts(frameCounts),
			"took_ms", time.Since(startedAt).Milliseconds(),
		)
	}()
	logFallback := func(category, value string, payload []byte) {
		if value == "" {
			return
		}
		key := category + "." + value
		if seenFallback[key] {
			return
		}
		seenFallback[key] = true
		shape := describeOpenClawAgentFrame(payload)
		s.logger.Info(ctx, "chat openclaw v3 fallback markdown for unsupported block type",
			"stream_id", streamID, "category", category, "value", value,
			"payload_bytes", shape.PayloadBytes,
			"data_keys", shape.DataKeys,
			"data_kind", shape.DataKind,
			"data_type", shape.DataType,
			"data_event", shape.DataEvent,
			"data_phase", shape.DataPhase,
			"data_status", shape.DataStatus,
			"has_text", shape.HasText)
	}
	getTool := func(id string) *openClawToolState {
		if id == "" {
			id = fmt.Sprintf("tool-%d", len(toolOrder)+1)
		}
		if st, ok := toolsByID[id]; ok {
			lastToolID = id
			return st
		}
		st := &openClawToolState{ID: id}
		toolsByID[id] = st
		toolOrder = append(toolOrder, id)
		lastToolID = id
		return st
	}
	publishToolCall := func(st *openClawToolState, status, argsDelta, args string) {
		if st == nil || st.ID == "" {
			return
		}
		if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageToolCall,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      agentMsgUUID,
			ToolCallID:       st.ID,
			ToolName:         st.Name,
			ToolStatus:       status,
			ToolArgsDelta:    argsDelta,
			ToolArgs:         args,
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(ctx, "chat fanout publish tool_call failed", "stream_id", streamID, "tool_call_id", st.ID, "err", err)
		}
	}
	publishToolResult := func(st *openClawToolState, status, result, delta string) {
		if st == nil || st.ID == "" {
			return
		}
		if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageToolResult,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      agentMsgUUID,
			ToolCallID:       st.ID,
			ToolName:         st.Name,
			ToolStatus:       status,
			ToolResult:       result,
			ToolResultDelta:  delta,
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(ctx, "chat fanout publish tool_result failed", "stream_id", streamID, "tool_call_id", st.ID, "err", err)
		}
	}
	flushCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), assistantDetachedFlushLimit)
	}
	flushDelta := func(flushCtx context.Context) {
		if !pendingDirty || assistantSnapshot == "" {
			return
		}
		blocks := finalBlocks(assistantSnapshot)
		// T2D.4 §3: SSE delta 累计文本与 DB blocks 一致。OpenClaw 的 assistant
		// snapshot 可能只有 2-3 字一帧；这里按 flush 节奏写 DB，避免每帧一次 UPDATE。
		if err := s.messages.UpdateStreamBlocks(flushCtx, streamID, blocks); err != nil {
			s.logger.Warn(flushCtx, "chat update stream blocks failed", "stream_id", streamID, "err", err)
		}
		if !firstDeltaLogged {
			firstDeltaLogged = true
			s.logger.Info(flushCtx, "chat openclaw v3 first assistant delta",
				"stream_id", streamID,
				"conversation_uuid", conversationUUID,
				"room_uuid", roomUUID,
				"agent_uuid", agentUUID,
				"first_delta_ms", time.Since(startedAt).Milliseconds(),
				"snapshot_chars", len([]rune(assistantSnapshot)),
				"delta_bytes", len(assistantSnapshot)-lastFlushLen)
		}
		if err := s.fanout.Publish(flushCtx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageBlockDelta,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      agentMsgUUID,
			Blocks:           blocks,
			Text:             assistantSnapshot,
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(flushCtx, "chat fanout publish delta failed", "stream_id", streamID, "err", err)
		}
		pendingDirty = false
		lastFlushLen = len(assistantSnapshot)
	}
	flushDetached := func() {
		dctx, cancel := flushCtx()
		defer cancel()
		flushDelta(dctx)
	}
	absorbDelta := func(snapshot string) bool {
		// OpenClaw assistant 帧是 snapshot 语义 (data.text 是累计全文), 做 prefix-diff
		// 还原成增量 delta; 模型编辑回退时 (snapshot 长度比上次短) 重置游标不重发。
		n := len(snapshot)
		if n <= emittedLen {
			emittedLen = n
			if n < lastFlushLen {
				lastFlushLen = n
			}
			return false
		}
		newText := snapshot[emittedLen:]
		assistantSnapshot = snapshot
		emittedLen = n
		pendingDirty = true
		if !firstDeltaLogged {
			return true
		}
		if len([]rune(snapshot[lastFlushLen:])) >= assistantFlushMaxRunes {
			return true
		}
		return strings.ContainsAny(newText, assistantFlushBoundaryRunes)
	}

	// 3B 返修 #1: ctx.Done / frames closed 兜底 finalize 时, 区分 user stop (cause=ErrStopByUser)
	// 与自然结束 (ctx 超时 / 上游正常关 frames). user stop → 'cancelled'; 其它 → 'final'.
	chooseFinalStatus := func() string {
		if errors.Is(context.Cause(ctx), ErrStopByUser) {
			return "cancelled"
		}
		return "final"
	}
	publishedFinal := false
	publishFinalText := func() string {
		if publishedFinal || s.openclawOutputs == nil || strings.TrimSpace(assistantSnapshot) == "" {
			return assistantSnapshot
		}
		publishedFinal = true
		pctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), openClawOutputPublishTimeout)
		defer cancel()
		text, err := s.openclawOutputs.PublishOpenClawOutputs(pctx, OpenClawOutputPublishInput{
			TenantID:             tenantID,
			AccountID:            accountID,
			AgentUUID:            agentUUID,
			RuntimeEnvironmentID: runtimeEnvID,
			ConversationUUID:     conversationUUID,
			MessageUUID:          agentMsgUUID,
			Text:                 assistantSnapshot,
		})
		if err != nil {
			s.logger.Warn(pctx, "chat openclaw output publish failed",
				"stream_id", streamID,
				"conversation_uuid", conversationUUID,
				"message_uuid", agentMsgUUID,
				"agent_uuid", agentUUID,
				"err", err,
			)
			return assistantSnapshot
		}
		if strings.TrimSpace(text) != "" {
			assistantSnapshot = text
		}
		return assistantSnapshot
	}
	finalBlocksForSuccess := func() []map[string]any {
		return finalBlocksWithKnowledgeContextSources(finalBlocksWithProcess(toolOrder, toolsByID, publishFinalText()), kc)
	}
	finalBlocksPlain := func() []map[string]any {
		return finalBlocksWithProcess(toolOrder, toolsByID, assistantSnapshot)
	}
	ragMetadata := func() map[string]any {
		return knowledgeContextMetadata(kc)
	}
	ticker := time.NewTicker(assistantFlushInterval)
	defer ticker.Stop()
	firstBusinessTimer := time.NewTimer(openClawFirstBusinessEventLimit)
	defer firstBusinessTimer.Stop()
	firstBusinessC := firstBusinessTimer.C
	markBusinessEvent := func() {
		if firstBusinessC == nil {
			return
		}
		if !firstBusinessTimer.Stop() {
			select {
			case <-firstBusinessTimer.C:
			default:
			}
		}
		firstBusinessC = nil
	}
	for {
		select {
		case <-ctx.Done():
			finishReason = "ctx_done"
			// ctx 已取消时 fanout.Publish 可能直接失败；先用 detached ctx 把缓存尾段推出去。
			flushDetached()
			if !finalized {
				s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, finalBlocksForSuccess(), chooseFinalStatus(), "", "", usage, ragMetadata())
			}
			return
		case <-ticker.C:
			flushDelta(ctx)
		case <-firstBusinessC:
			finishReason = "first_business_event_timeout"
			firstBusinessC = nil
			s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
				RuntimeKind:          FrameworkOpenClaw,
				FailureStage:         "first_business_event_timeout",
				StreamID:             streamID,
				MessageUUID:          agentMsgUUID,
				ConversationUUID:     conversationUUID,
				RoomUUID:             roomUUID,
				AccountID:            accountID,
				TenantID:             tenantID,
				AgentUUID:            agentUUID,
				RuntimeEnvironmentID: runtimeEnvID,
				ErrorCode:            "chat.upstream_call_failed",
				Diagnostic:           "openclaw session remained queued without assistant or tool progress",
			})
			s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID,
				finalBlocksPlain(), "failed", "chat.upstream_call_failed",
				"openclaw session remained queued without assistant or tool progress", usage, ragMetadata())
			finalized = true
			return
		case f, ok := <-frames:
			if !ok {
				finishReason = "frames_closed"
				flushDelta(ctx)
				if !finalized {
					s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, finalBlocksForSuccess(), chooseFinalStatus(), "", "", usage, ragMetadata())
				}
				return
			}

			// reply 帧: 主要是 sessions.create / sessions.messages.subscribe / chat.send
			// 的同步响应。chat.send !ok 视为致命错误。
			if f.Reply {
				if !f.OK {
					frameCounts["reply.error"]++
					emsg := parseGatewayErrorMessage(f.Error)
					if emsg == "" {
						emsg = "openclaw rpc failed"
					}
					// doc-12 §11.8: 上游报"agent 未注册进配置"时, 按该 DE 的 agent_register **任务状态**分类,
					// 不一律包装成 preparing (避免掩盖永久配置错误)。
					code, m := "chat.upstream_call_failed", emsg
					if isAgentNotRegisteredUpstream(emsg) {
						code, m = s.classifyAgentNotRegistered(ctx, tenantID, runtimeAccountID, runtimeEnvID, agentUUID)
					} else {
						code, m = s.reclassifyRuntimeFailureAsCredits(ctx, tenantID, accountID, code, m)
					}
					s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
						RuntimeKind:          FrameworkOpenClaw,
						FailureStage:         "rpc_reply",
						StreamID:             streamID,
						MessageUUID:          agentMsgUUID,
						ConversationUUID:     conversationUUID,
						RoomUUID:             roomUUID,
						AccountID:            accountID,
						TenantID:             tenantID,
						AgentUUID:            agentUUID,
						RuntimeEnvironmentID: runtimeEnvID,
						ErrorCode:            code,
						Diagnostic:           emsg,
					})
					flushDelta(ctx)
					s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, finalBlocksPlain(), "failed", code, m, usage, ragMetadata())
					finalized = true
					finishReason = "reply_error"
					return
				}
				frameCounts["reply.ok"]++
				continue
			}
			frameEvent := f.Event
			if frameEvent == "" {
				frameEvent = "(empty)"
			}
			frameCounts["event."+frameEvent]++

			// 广播帧。
			//
			// 串台防御 (T2D.1 P1 返修, 移植自 legacy chat_runner_ws.go §381):
			// OpenClaw gateway 的 caps=tool-events 连接是"实例级"广播; 同一个 OpenClaw 实例
			// 上同时跑多个 session (典型: 用户给 A agent 发消息时, B agent 的 cron 任务
			// 正好在 fire), WS 连接会同时收到所有 session 的 agent / session.message 帧。
			// 这些帧 payload 顶层都带 sessionKey, 必须过滤掉与本次 chat sessionKey 不匹配的帧,
			// 避免别的 session 的 assistant 文本被错误累积到当前用户消息上、
			// 最终 finalize 时污染 db 该会话的 output。
			//
			// 只过滤已知带 sessionKey 的事件类型 (agent / chat / session.message);
			// 不识别的 / 没 sessionKey 的 (老版 chat / tick / health / 握手类) 不动, 保原行为。
			//
			// sessionKey 缺失时**不丢帧** (legacy 同款兼容): 极个别老网关帧 envelope
			// 不含 sessionKey 字段, 直接丢会让正常会话也收不到事件。
			if f.Event == "agent" || f.Event == "chat" || f.Event == "session.message" {
				if frameKey := extractFrameSessionKey(f.Payload); frameKey != "" && frameKey != sessionKey {
					s.logger.Debug(ctx, "openclaw v3 drop foreign frame",
						"event", f.Event,
						"frame_session_key", frameKey,
						"my_session_key", sessionKey,
						"stream_id", streamID,
					)
					continue
				}
			}

			switch f.Event {
			case "agent":
				kind, snapshot, lifecyclePhase := parseAgentFrame(f.Payload)
				switch kind {
				case "assistant":
					markBusinessEvent()
					if snapshot != "" {
						rec.OnOutput(time.Now())
						if absorbDelta(snapshot) {
							flushDelta(ctx)
						}
					} else {
						logFallback("agent_stream", "assistant_empty", f.Payload)
					}
				case "lifecycle":
					if lifecyclePhase == "end" || lifecyclePhase == "error" {
						flushDelta(ctx)
						if lifecyclePhase == "error" {
							// 真机 2026-06-10 出现 122.6s/0 字的 lifecycle_error, bus 侧无错误细节可查
							// (runtime pod 日志本机不可达)。error 帧 payload 脱敏截断后落日志,
							// 供复现时定位 runtime 侧根因。
							code, m := s.reclassifyRuntimeFailureAsCredits(ctx, tenantID, accountID,
								"chat.upstream_call_failed", "openclaw lifecycle entered error phase")
							s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
								RuntimeKind:          FrameworkOpenClaw,
								FailureStage:         "lifecycle_error",
								StreamID:             streamID,
								MessageUUID:          agentMsgUUID,
								ConversationUUID:     conversationUUID,
								RoomUUID:             roomUUID,
								AccountID:            accountID,
								TenantID:             tenantID,
								AgentUUID:            agentUUID,
								RuntimeEnvironmentID: runtimeEnvID,
								ErrorCode:            code,
								Diagnostic:           scrubOpenClawFramePayload(f.Payload),
							})
							s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, finalBlocksPlain(), "failed", code, m, usage, ragMetadata())
							finishReason = "lifecycle_error"
						} else {
							// 3B 返修 #1 收尾: lifecycle.end 必须尊重 user stop 的 cancel cause.
							// Stop 已通过 CancelCauseFunc(ErrStopByUser) 取消 ctx; 即便上游还在
							// 这一帧 fire end, 我们也必须 finalize 'cancelled', 防止客户端先收
							// message.cancelled 再收 message.completed 的矛盾终态.
							s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, finalBlocksForSuccess(), chooseFinalStatus(), "", "", usage, ragMetadata())
							finishReason = "lifecycle_end"
						}
						finalized = true
						return
					}
				case "tool":
					markBusinessEvent()
					ev, ok := parseOpenClawToolFrame(f.Payload)
					if !ok {
						logFallback("agent_stream", kind, f.Payload)
						continue
					}
					flushDelta(ctx)
					id := ev.ID
					if id == "" && isToolTerminal(ev.Phase, ev.Status) {
						id = lastToolID
					}
					st := getTool(id)
					if ev.Name != "" {
						st.Name = ev.Name
					}
					if ev.Input != nil {
						st.Input = ev.Input
					}
					if ev.Args != "" {
						st.Args = ev.Args
					}
					if ev.ArgsDelta != "" {
						st.Args += ev.ArgsDelta
					}
					if ev.Status != "" {
						st.Status = ev.Status
					}
					if ev.Result != "" {
						st.Result = ev.Result
					}
					if isToolTerminal(ev.Phase, ev.Status) {
						status := normalizeToolResultStatus(ev.Status)
						if status == "" {
							status = normalizeToolResultStatus(ev.Phase)
						}
						st.Status = status
						rec.OnToolResult(id, status != "error", "", time.Now())
						publishToolResult(st, status, firstNonEmpty(ev.Result, st.Result, st.Output), "")
					} else {
						status := normalizeToolCallStatus(ev.Phase, ev.Status, ev.ArgsDelta, ev.Args, ev.Input)
						rec.OnToolCall(id, st.Name, time.Now())
						publishToolCall(st, status, ev.ArgsDelta, firstNonEmpty(ev.Args, st.Args, stringifyToolInput(st.Input)))
					}
				case "command_output":
					markBusinessEvent()
					ev, ok := parseOpenClawCommandOutputFrame(f.Payload)
					if !ok {
						logFallback("agent_stream", kind, f.Payload)
						continue
					}
					flushDelta(ctx)
					id := ev.ID
					if id == "" {
						id = lastToolID
					}
					st := getTool(id)
					if ev.Output != "" {
						if st.Output != "" {
							st.Output += "\n"
						}
						st.Output += ev.Output
					}
					publishToolResult(st, "running", "", ev.Output)
				case "item":
					markBusinessEvent()
					flushDelta(ctx)
					if !publishOpenClawItemFrame(ctx, s, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID, f.Payload) {
						logFallback("agent_stream", kind, f.Payload)
					}
				default:
					// 未识别 agent stream 只记一次 fallback 日志, 不阻塞 assistant 输出。
					logFallback("agent_stream", kind, f.Payload)
				}
			case "session.message":
				// Persisted assistant stop message is authoritative. OpenClaw can replay
				// hundreds of paced agent snapshots and delay lifecycle.end for minutes
				// after this transcript message is already complete.
				if u := extractSessionMessageUsage(f.Payload); u != nil {
					usage = u
				}
				if text, ok := extractFinalSessionMessageText(f.Payload); ok {
					markBusinessEvent()
					assistantSnapshot = text
					emittedLen = len(text)
					pendingDirty = true
					flushDelta(ctx)
					s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID,
						finalBlocksForSuccess(), chooseFinalStatus(), "", "", usage, ragMetadata())
					finalized = true
					finishReason = "session_message_final"
					return
				}
			case "chat":
				// OpenClaw 2026.4.22 broadcasts the persisted assistant message as
				// chat(state=final). Treat it as authoritative for the same reason as
				// session.message: snapshot replay and lifecycle.end may trail by minutes.
				if u := extractSessionMessageUsage(f.Payload); u != nil {
					usage = u
				}
				if text, ok := extractFinalChatMessageText(f.Payload); ok {
					markBusinessEvent()
					assistantSnapshot = text
					emittedLen = len(text)
					pendingDirty = true
					flushDelta(ctx)
					s.finalize(ctx, streamID, accountID, tenantID, conversationUUID, roomUUID, agentMsgUUID,
						finalBlocksForSuccess(), chooseFinalStatus(), "", "", usage, ragMetadata())
					finalized = true
					finishReason = "chat_final"
					return
				}
			case "":
				// 极个别老网关帧 envelope 不带 event 字段 (parseFrame 走兜底), 忽略。
				continue
			default:
				// tick / health / 其它未知事件: T2D.7 同款 fallback 日志一次, 不阻塞流。
				logFallback("event", f.Event, f.Payload)
			}
		}
	}
}

type openClawRPCCaller interface {
	Call(ctx context.Context, ep gatewayws.Endpoint, method string, params interface{}) (json.RawMessage, error)
}

func (s *impl) abortOpenClawRunBestEffort(ep gatewayws.Endpoint, sessionKey, runID string) {
	caller, ok := s.openclawClient.(openClawRPCCaller)
	if !ok || strings.TrimSpace(sessionKey) == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if _, err := caller.Call(ctx, ep, "chat.abort", map[string]any{
		"sessionKey": sessionKey,
		"runId":      runID,
	}); err != nil {
		s.logger.Warn(ctx, "chat openclaw v3 abort cleanup failed", "has_run_id", strings.TrimSpace(runID) != "", "err", err)
	}
}

// idempotencyKeyFor 把 streamID 折成 OpenClaw chat.send 要求的非空 idempotencyKey。
// 同 streamID 复投 (客户端重试 / 网关重传) 不会让 OpenClaw 重复跑模型。
func idempotencyKeyFor(streamID string) string {
	if strings.TrimSpace(streamID) == "" {
		raw := time.Now().Format(time.RFC3339Nano)
		h := sha1.Sum([]byte(raw))
		return "idmp-" + hex.EncodeToString(h[:])
	}
	h := sha1.Sum([]byte(streamID))
	return "idmp-" + hex.EncodeToString(h[:])
}

// agentFramePayload 是 OpenClaw v3 "event=agent" 广播帧 payload 的最小投影。
//
// 实际 payload (见 legacy chat_runner_ws.go translateWSFrames) 字段繁多 (kind, phase,
// toolCallId, name, arguments, output, status, ...); 这里 T2D.1 只挑 stream + data.text
// + data.delta + data.phase 三类字段, 够 assistant snapshot + lifecycle 收尾即可。
// openClawSecretKVRe lifecycle error 帧诊断日志的脱敏: secret 样式 JSON 字段打码
// (含截断后未闭合的值)。与 bus transport 的 rtcLLMScrubBody 同款正则, 此处独立副本避免跨层 import。
var (
	openClawSecretKVRe   = regexp.MustCompile(`(?i)"(authorization|cookie|api[_-]?key|access[_-]?key|secret|token|password)"\s*:\s*"[^"]*"`)
	openClawSecretOpenRe = regexp.MustCompile(`(?i)"(authorization|cookie|api[_-]?key|access[_-]?key|secret|token|password)"\s*:\s*"[^"]*$`)
)

// scrubOpenClawFramePayload 先 scrub 再截断 (≤600B), 防截断边界露出 secret;
// 末尾截断的多字节 UTF-8 丢弃。仅用于 lifecycle error 帧的诊断日志。
func scrubOpenClawFramePayload(payload []byte) string {
	s := openClawSecretKVRe.ReplaceAllString(string(payload), `"$1":"***"`)
	if len(s) > 600 {
		s = s[:600]
	}
	s = openClawSecretOpenRe.ReplaceAllString(s, `"$1":"***"`)
	return strings.ToValidUTF8(s, "")
}

type agentFramePayload struct {
	Stream string          `json:"stream"`
	Data   json.RawMessage `json:"data"`
}

type agentFrameData struct {
	Text  string `json:"text"`
	Delta string `json:"delta"`
	Phase string `json:"phase"`
}

type openClawToolState struct {
	ID     string
	Name   string
	Input  any
	Args   string
	Output string
	Result string
	Status string
}

type openClawToolFrame struct {
	ID        string
	Name      string
	Phase     string
	Status    string
	Input     any
	Args      string
	ArgsDelta string
	Result    string
}

type openClawCommandOutputFrame struct {
	ID     string
	Output string
}

type openClawFrameShape struct {
	PayloadBytes int
	DataKeys     []string
	DataKind     string
	DataType     string
	DataEvent    string
	DataPhase    string
	DataStatus   string
	HasText      bool
}

func describeOpenClawAgentFrame(payload []byte) openClawFrameShape {
	shape := openClawFrameShape{PayloadBytes: len(payload)}
	data, ok := decodeOpenClawAgentData(payload)
	if !ok {
		return shape
	}
	shape.DataKeys = sortedAnyMapKeys(data)
	shape.DataKind = strings.ToLower(stringValue(data, "kind"))
	shape.DataType = strings.ToLower(stringValue(data, "type"))
	shape.DataEvent = strings.ToLower(stringValue(data, "event"))
	shape.DataPhase = strings.ToLower(stringValue(data, "phase"))
	shape.DataStatus = strings.ToLower(stringValue(data, "status", "state"))
	shape.HasText = stringValue(data, "text", "delta", "message", "content") != ""
	return shape
}

func sortedAnyMapKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func formatFrameCounts(counts map[string]int) string {
	if len(counts) == 0 {
		return ""
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, counts[k]))
	}
	return strings.Join(parts, ",")
}

// parseAgentFrame 解析 event=agent 广播帧, 返回 (stream 子类型, assistant snapshot 文本,
// lifecycle phase)。任意字段缺失返回空串, caller 自行 nil-check。
func parseAgentFrame(payload []byte) (stream string, snapshot string, phase string) {
	if len(payload) == 0 {
		return "", "", ""
	}
	var p agentFramePayload
	if err := json.Unmarshal(payload, &p); err != nil {
		return "", "", ""
	}
	stream = p.Stream
	if len(p.Data) == 0 {
		return stream, "", ""
	}
	var d agentFrameData
	if err := json.Unmarshal(p.Data, &d); err != nil {
		return stream, "", ""
	}
	switch stream {
	case "assistant":
		// 优先用累计 text (snapshot); 退化场景下只有 delta 时拿 delta 当 snapshot
		// (legacy 也是这样 fallback, 见 chat_runner_ws.go §emitSnapshotDelta)。
		if d.Text != "" {
			snapshot = d.Text
		} else if d.Delta != "" {
			snapshot = d.Delta
		}
	case "lifecycle":
		phase = d.Phase
	}
	return stream, snapshot, phase
}

func parseOpenClawToolFrame(payload []byte) (openClawToolFrame, bool) {
	data, ok := decodeOpenClawAgentData(payload)
	if !ok {
		return openClawToolFrame{}, false
	}
	ev := openClawToolFrame{
		ID:        stringValue(data, "toolCallId", "tool_call_id", "callId", "call_id", "id"),
		Name:      stringValue(data, "toolName", "tool_name", "name", "tool"),
		Phase:     strings.ToLower(stringValue(data, "phase", "kind", "event")),
		Status:    strings.ToLower(stringValue(data, "status", "state")),
		Input:     firstAny(data, "input", "arguments", "args"),
		Args:      stringValue(data, "argumentsText", "arguments_text", "args", "arguments"),
		ArgsDelta: stringValue(data, "argumentsDelta", "arguments_delta", "argsDelta", "args_delta", "delta"),
		Result:    stringValue(data, "result", "output", "message", "text"),
	}
	if ev.Phase == "tool" || ev.Phase == "tool_call" {
		ev.Phase = ""
	}
	if ev.ID == "" && ev.Name == "" && ev.Phase == "" && ev.Status == "" && ev.Input == nil && ev.Args == "" && ev.ArgsDelta == "" && ev.Result == "" {
		return openClawToolFrame{}, false
	}
	return ev, true
}

func parseOpenClawCommandOutputFrame(payload []byte) (openClawCommandOutputFrame, bool) {
	data, ok := decodeOpenClawAgentData(payload)
	if !ok {
		return openClawCommandOutputFrame{}, false
	}
	ev := openClawCommandOutputFrame{
		ID:     stringValue(data, "toolCallId", "tool_call_id", "callId", "call_id", "id"),
		Output: stringValue(data, "output", "stdout", "stderr", "text", "message", "delta"),
	}
	if ev.ID == "" && ev.Output == "" {
		return openClawCommandOutputFrame{}, false
	}
	return ev, true
}

func publishOpenClawItemFrame(ctx context.Context, s *impl, streamID string, accountID, tenantID int64, conversationUUID, roomUUID, msgUUID string, payload []byte) bool {
	data, ok := decodeOpenClawAgentData(payload)
	if !ok {
		return false
	}
	kind := strings.ToLower(stringValue(data, "kind", "type", "event"))
	switch kind {
	case "reasoning", "thought", "thinking":
		text := stringValue(data, "text", "delta", "message", "content")
		if text == "" {
			return false
		}
		s.runRecs.lookupStream(streamID).OnReasoning(time.Now())
		if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageReasoning,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      msgUUID,
			Reasoning:        text,
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(ctx, "chat fanout publish reasoning failed", "stream_id", streamID, "err", err)
		}
		return true
	case "stage", "progress", "plan":
		stageID := stringValue(data, "id", "stageId", "stage_id", "key")
		stageText := stringValue(data, "text", "title", "message", "name", "status")
		if stageText == "" {
			return false
		}
		if stageID == "" {
			stageID = kind
		}
		if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageStage,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      msgUUID,
			StageID:          stageID,
			StageText:        stageText,
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(ctx, "chat fanout publish stage failed", "stream_id", streamID, "stage_id", stageID, "err", err)
		}
		return true
	case "tool", "tool_call", "toolcall":
		// OpenClaw 把工具进度作为 item 帧广播 (kind="tool", 含 name/phase/status/toolCallId/title/meta)。
		// 翻译成 EventMessageToolCall **只透传低风险字段** name/status/id —
		// title/meta/args/result 可能含文件路径/命令参数/原始输出, 一律不带
		// (F16 语音桥据 ToolName/ToolStatus 映射白名单短语; 文字端按 tool_call 时间线渲染)。
		name := stringValue(data, "name", "tool", "toolName", "tool_name")
		status := stringValue(data, "status", "phase")
		if name == "" && status == "" {
			return false
		}
		id := stringValue(data, "toolCallId", "tool_call_id", "itemId", "id")
		if rec := s.runRecs.lookupStream(streamID); rec != nil {
			switch strings.ToLower(strings.TrimSpace(status)) {
			case "ok", "success", "succeeded", "completed", "done":
				rec.OnToolResult(id, true, "", time.Now())
			case "error", "failed":
				rec.OnToolResult(id, false, "", time.Now())
			default:
				rec.OnToolCall(id, name, time.Now())
			}
		}
		if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, StreamEvent{
			Kind:             EventMessageToolCall,
			ConversationUUID: conversationUUID,
			RoomUUID:         roomUUID,
			MessageUUID:      msgUUID,
			ToolCallID:       id,
			ToolName:         name,
			ToolStatus:       strings.ToLower(strings.TrimSpace(status)),
			Timestamp:        time.Now(),
		}); err != nil {
			s.logger.Warn(ctx, "chat fanout publish item tool failed", "stream_id", streamID, "tool_call_id", id, "err", err)
		}
		return true
	default:
		return false
	}
}

func decodeOpenClawAgentData(payload []byte) (map[string]any, bool) {
	if len(payload) == 0 {
		return nil, false
	}
	var p agentFramePayload
	if err := json.Unmarshal(payload, &p); err != nil || len(p.Data) == 0 {
		return nil, false
	}
	var data map[string]any
	if err := json.Unmarshal(p.Data, &data); err != nil {
		return nil, false
	}
	return data, true
}

func normalizeToolCallStatus(phase, status, argsDelta, args string, input any) string {
	switch strings.ToLower(firstNonEmpty(status, phase)) {
	case "args_delta", "arguments_delta":
		return "args_delta"
	case "args_done", "arguments_done":
		return "args_done"
	case "start", "started", "running":
		if argsDelta != "" {
			return "args_delta"
		}
		if args != "" || input != nil {
			return "args_done"
		}
		return "started"
	default:
		if argsDelta != "" {
			return "args_delta"
		}
		if args != "" || input != nil {
			return "args_done"
		}
		return "started"
	}
}

func isToolTerminal(phase, status string) bool {
	switch strings.ToLower(phase) {
	case "end", "done", "completed", "failed", "error":
		return true
	}
	switch strings.ToLower(status) {
	case "completed", "complete", "done", "success", "succeeded", "failed", "failure", "error":
		return true
	}
	return false
}

func normalizeToolResultStatus(v string) string {
	switch strings.ToLower(v) {
	case "failed", "failure", "error":
		return "failed"
	case "completed", "complete", "done", "success", "succeeded", "end":
		return "done"
	default:
		return v
	}
}

func finalBlocksWithProcess(order []string, tools map[string]*openClawToolState, text string) []map[string]any {
	blocks := make([]map[string]any, 0, len(order)*2+1)
	for _, id := range order {
		st := tools[id]
		if st == nil {
			continue
		}
		toolName := st.Name
		if toolName == "" {
			toolName = "工具"
		}
		call := map[string]any{
			"type":         "tool_call",
			"tool_call_id": st.ID,
			"tool":         toolName,
			"input":        normalizeToolInput(st.Input, st.Args),
			"status":       firstNonEmpty(st.Status, "done"),
		}
		blocks = append(blocks, call)
		output := firstNonEmpty(st.Result, st.Output)
		if output != "" || st.Status != "" {
			blocks = append(blocks, map[string]any{
				"type":         "tool_result",
				"tool_call_id": st.ID,
				"tool":         toolName,
				"status":       normalizeToolResultStatus(firstNonEmpty(st.Status, "done")),
				"output":       output,
			})
		}
	}
	blocks = append(blocks, finalBlocks(text)...)
	return blocks
}

func normalizeToolInput(input any, args string) map[string]any {
	switch v := input.(type) {
	case map[string]any:
		return v
	case map[string]string:
		out := make(map[string]any, len(v))
		for k, val := range v {
			out[k] = val
		}
		return out
	case string:
		if m := parseJSONObject(v); len(m) > 0 {
			return m
		}
		if v != "" {
			return map[string]any{"text": v}
		}
	}
	if args != "" {
		if m := parseJSONObject(args); len(m) > 0 {
			return m
		}
		return map[string]any{"text": args}
	}
	return map[string]any{}
}

func parseJSONObject(s string) map[string]any {
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return nil
	}
	return m
}

func stringifyToolInput(input any) string {
	if input == nil {
		return ""
	}
	if s, ok := input.(string); ok {
		return s
	}
	b, err := json.Marshal(input)
	if err != nil {
		return ""
	}
	return string(b)
}

func stringValue(data map[string]any, keys ...string) string {
	for _, key := range keys {
		v, ok := data[key]
		if !ok || v == nil {
			continue
		}
		switch t := v.(type) {
		case string:
			return t
		case json.Number:
			return t.String()
		default:
			b, err := json.Marshal(t)
			if err == nil {
				return string(b)
			}
		}
	}
	return ""
}

func firstAny(data map[string]any, keys ...string) any {
	for _, key := range keys {
		if v, ok := data[key]; ok && v != nil {
			return v
		}
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// extractFrameSessionKey 从 OpenClaw v3 广播帧 payload 顶层抽 sessionKey。
//
// agent / session.message 等帧的 envelope 形如:
//
//	{ runId, sessionKey, seq, ts, stream, data: {...} }
//
// 解析失败或字段缺失时返回 "" —— 调用方应当**不过滤** (保持原行为, 避免误丢);
// 仅当返回非空且与本次 chat 的 sessionKey 不一致时才丢帧, 详见
// `runOpenClawV3` 串台防御段。
//
// 与 legacy ai-office chat_runner_ws.go::extractFrameSessionKey 等价。
func extractFrameSessionKey(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}
	var env struct {
		SessionKey string `json:"sessionKey"`
	}
	if err := json.Unmarshal(payload, &env); err != nil {
		return ""
	}
	return env.SessionKey
}

// extractSessionMessageUsage 从 OpenClaw v3 session.message envelope 抽 usage/model。
//
// envelope 形如:
//
//	{ sessionKey, ..., usage: {inputTokens, outputTokens, totalTokens}, model: "..."}
//
// 任意字段缺失返回 nil; 完全缺 usage 返回 nil。caller 据此决定是否覆盖之前值。
//
// 字段命名按 OpenClaw / OpenResponses 通用约定 (camelCase); 我们规范化为 snake_case
// 写入 messages.metadata.usage 以便客户端 / 计费 (M10) 一致解析。
func extractSessionMessageUsage(payload []byte) map[string]any {
	if len(payload) == 0 {
		return nil
	}
	type usageFields struct {
		InputTokens       *int64 `json:"inputTokens"`
		OutputTokens      *int64 `json:"outputTokens"`
		TotalTokens       *int64 `json:"totalTokens"`
		InputTokensSnake  *int64 `json:"input_tokens"`
		OutputTokensSnake *int64 `json:"output_tokens"`
		TotalTokensSnake  *int64 `json:"total_tokens"`
	}
	var env struct {
		Model   string      `json:"model"`
		Usage   usageFields `json:"usage"`
		Message struct {
			Model string      `json:"model"`
			Usage usageFields `json:"usage"`
		} `json:"message"`
	}
	if err := json.Unmarshal(payload, &env); err != nil {
		return nil
	}
	usage := env.Usage
	model := env.Model
	if env.Message.Model != "" {
		model = env.Message.Model
	}
	if env.Message.Usage.InputTokens != nil || env.Message.Usage.InputTokensSnake != nil ||
		env.Message.Usage.OutputTokens != nil || env.Message.Usage.OutputTokensSnake != nil ||
		env.Message.Usage.TotalTokens != nil || env.Message.Usage.TotalTokensSnake != nil {
		usage = env.Message.Usage
	}
	out := map[string]any{}
	if model != "" {
		out["model"] = model
	}
	pickInt := func(camel, snake *int64) (int64, bool) {
		if camel != nil {
			return *camel, true
		}
		if snake != nil {
			return *snake, true
		}
		return 0, false
	}
	if v, ok := pickInt(usage.InputTokens, usage.InputTokensSnake); ok {
		out["input_tokens"] = v
	}
	if v, ok := pickInt(usage.OutputTokens, usage.OutputTokensSnake); ok {
		out["output_tokens"] = v
	}
	if v, ok := pickInt(usage.TotalTokens, usage.TotalTokensSnake); ok {
		out["total_tokens"] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func extractFinalSessionMessageText(payload []byte) (string, bool) {
	if len(payload) == 0 {
		return "", false
	}
	var env struct {
		Message struct {
			Role       string `json:"role"`
			StopReason string `json:"stopReason"`
			Text       string `json:"text"`
			Content    []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(payload, &env); err != nil ||
		!strings.EqualFold(env.Message.Role, "assistant") ||
		!strings.EqualFold(env.Message.StopReason, "stop") {
		return "", false
	}
	if strings.TrimSpace(env.Message.Text) != "" {
		return strings.TrimSpace(env.Message.Text), true
	}
	parts := make([]string, 0, len(env.Message.Content))
	for _, block := range env.Message.Content {
		if block.Type == "text" && block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	text := strings.TrimSpace(strings.Join(parts, ""))
	return text, text != ""
}

func extractFinalChatMessageText(payload []byte) (string, bool) {
	if len(payload) == 0 {
		return "", false
	}
	var env struct {
		State   string `json:"state"`
		Message struct {
			Role    string `json:"role"`
			Text    string `json:"text"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(payload, &env); err != nil ||
		!strings.EqualFold(env.State, "final") ||
		!strings.EqualFold(env.Message.Role, "assistant") {
		return "", false
	}
	if strings.TrimSpace(env.Message.Text) != "" {
		return strings.TrimSpace(env.Message.Text), true
	}
	parts := make([]string, 0, len(env.Message.Content))
	for _, block := range env.Message.Content {
		if block.Type == "text" && block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	text := strings.TrimSpace(strings.Join(parts, ""))
	return text, text != ""
}

// parseGatewayErrorMessage 抽 reply 帧的 error.message 字段, 找不到时返回空串。
func parseGatewayErrorMessage(raw []byte) string {
	if len(raw) == 0 {
		return ""
	}
	var ge struct {
		Code    any    `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &ge); err != nil {
		return ""
	}
	return ge.Message
}

// classifyAgentNotRegistered 把上游 "agent no longer exists" 按该 DE 的 agent_register 任务状态映射成准确
// error_code (doc-12 §11.8)。lookup 未注入或查询失败 → 退化为 runtime_warming (旧行为, 不阻断)。
//   - 无 agent_register 任务 → control_plane_not_ready (capability 未声明 / K8S 写入通道缺失, 配置错)
//   - 终态 failed → agent_registration_failed (注册真失败, 不伪装 preparing)
//   - active (pending/running/waiting_instance/retrying) → runtime_warming (瞬时, 重试)
//   - succeeded 但运行端仍报不存在 → agent_registration_failed (config drift / pod 丢失, 不掩盖)
func (s *impl) classifyAgentNotRegistered(ctx context.Context, tenantID, accountID, runtimeEnvID int64, agentUUID string) (code, msg string) {
	const warmMsg = "运行环境准备中，数字员工正在注册，请稍后重试"
	if s.agentRegStatus == nil || runtimeEnvID <= 0 || agentUUID == "" {
		return ErrCodeRuntimeWarming, warmMsg
	}
	status, found, err := s.agentRegStatus.LatestAgentRegisterStatus(ctx, tenantID, accountID, runtimeEnvID, agentUUID)
	if err != nil {
		return ErrCodeRuntimeWarming, warmMsg // 查询失败不阻断, 保守按准备中
	}
	if !found {
		// OpenClaw 能力系统推导, 不需管理员勾选 (doc-12 §11.8.2); 未生成注册任务通常是 K8S 写入通道未配齐 / 未通过健康检查。
		return ErrCodeControlPlaneNotReady, "数字员工运行环境未就绪：未生成注册任务。请检查该 OpenClaw 运行环境是否已配置 Kubernetes 写入通道并通过健康检查。"
	}
	switch status {
	case "pending", "running", "waiting_instance", "retrying":
		return ErrCodeRuntimeWarming, warmMsg
	case "failed":
		return ErrCodeAgentRegistrationFailed, "数字员工注册失败，请联系管理员检查运行环境配置（K8S 写入通道 / RBAC）"
	default: // succeeded 但运行端仍报不存在 → 不掩盖
		return ErrCodeAgentRegistrationFailed, "数字员工注册状态异常（运行端找不到该数字员工），请联系管理员"
	}
}

// isAgentNotRegisteredUpstream 判定上游 chat.send 错误是否为"agent 未注册进运行端配置"
// (典型 OpenClaw 网关串: `Agent "<id>" no longer exists in configuration`)。命中 → 归类为
// 瞬时"准备中"(chat.runtime_warming) 而非永久失败 (doc-12 §11.8)。大小写不敏感, 关键词匹配。
func isAgentNotRegisteredUpstream(msg string) bool {
	m := strings.ToLower(msg)
	if strings.Contains(m, "no longer exists in configuration") {
		return true
	}
	// 兼容其它"agent 不存在/未找到"措辞 (不同网关版本)。
	if strings.Contains(m, "agent") &&
		(strings.Contains(m, "not found") || strings.Contains(m, "does not exist") ||
			strings.Contains(m, "no longer exists") || strings.Contains(m, "not registered") ||
			strings.Contains(m, "unknown agent")) {
		return true
	}
	return false
}

// finalBlocks 把 assistant 累计文本包成现有 SSE 协议的 markdown block 列表。
//
// 与 legacy openresponses 的 finalBlocks (adapter.go §256) 输出形状一致:
// `[{type: "markdown", text: <累计文本>}]`; 空文本返回空列表。
func finalBlocks(text string) []map[string]any {
	if text == "" {
		return []map[string]any{}
	}
	return []map[string]any{{"type": "markdown", "text": text}}
}

// 显式 unused-import 守卫: openclaw 包用于 InstanceResolver 接口的类型引用,
// 真正的 resolver 注入在 chat.New 时通过 cmd/{bus,admin}/main.go 传入。
var _ openclaw.InstanceResolver = (openclaw.InstanceResolver)(nil)

// openClawRunVersion picks the executing agent version for run tags:
// version snapshot wins (chat executes the snapshot), falling back to the
// agent's current_version.
func openClawRunVersion(vp *versionParams, ag *domagent.DigitalEmployee) int {
	if vp != nil && vp.Version > 0 {
		return vp.Version
	}
	if ag != nil {
		return ag.CurrentVersion
	}
	return 0
}
