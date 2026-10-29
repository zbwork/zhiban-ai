// zap_chat.go — Plan 16 Phase 2: ZAP framework 数字员工聊天 adapter (service 层)。
//
// 与 openclaw_v3.go 平行: 本文件是 chat 服务对 ZAP HTTP+SSE runtime 的封装层。
// 协议层在 internal/adapter/runtime/zap/chat.go (ChatClient)。
//
// 落地纪律 (与设计 §I.A-§I.H 严格对齐):
//   1. tenant/account UUID 由 IdentityResolver 显式解析, **不**从 ctx.Value 取。
//   2. runtime API key 从 runtime_environments.api_key_secret_ref 经 SecretResolverFunc 解;
//      只设头, 不入 log, 不进 SSE, 不进 DB。
//   3. session_token 完全不出现在 service 层: Phase 2 review F1 后, `CreateSessionResponse`
//      故意不暴露 SessionToken 字段; 即便 runtime 在 body 里返回, json.Unmarshal 会直接丢弃,
//      adapter 拿不到, 因此无法写入 PG / Redis / log / 出站 header。
//   4. session_id / expires_at 可以写 conv.metadata (Phase 2 仅做痕迹用, 暂不实装跨 send 复用)。
//      写入路径强制走 chat service 的 white-list helper (拒 session_token / runtime_api_key /
//      authorization 等)。
//   5. SSE 终态 message.completed/.failed/.cancelled 收尾走 finalize(...) ——
//      唯一一处 EMP.ValidateBlocks + audit emission。
//   6. block canonical mapping: action_bar → action; approval_request → approval;
//      citation → source; artifact:<kind> → {type:"artifact", artifact_kind:<kind>}。
//      其它 type 保持原样, 交给 finalize 内 EMPValidator 兜底 fallback。
//
// **本期已实装** (Phase 2 + Stage 1-3 收尾):
//   - 增量流式 message.block.delta: markdown/plain 累积成 snapshot, 透 EventMessageBlockDelta.Text 给客户端 (Stage 1, applyMarkdownDelta);
//   - session_id 跨 Send 复用: 从 conv.metadata.zap_session_id 读, 过期/not_found 自动重建一次 (Stage 2, reuseZapSessionID + isZapSessionStale);
//   - stop → ZAP /sessions/:id/cancel best-effort (Stage 3, registerActive + CancelStream)。
//
// **不实现** (Phase 2.5 + Phase 3 范围, 留单独 PR):
//   - typed block.delta 累积成可见 UI (chart/form/...): 仅 completed-first 兜底; typed delta 不累计;
//   - text-summary transform (富 block 转 markdown 摘要) — 客户端走 Stage 4 只读 fallback;
//   - runtime → Bus backchannel: Phase 2/3 一律**不**向 runtime 出站 session_token (review F1);
//     反向 backchannel (KB recall / MCP invoke / files.sign / quota.check) 仅 Plan 16 §K 设计草案;
//   - A2A backchannel: 单独走 deorch / a2a plan, 不在本范围;
//   - delete session 闭环 (`DELETE /zap/v1/sessions/:id` 自动调用): 暂不实装, 由 runtime TTL 兜底;
//   - HITL / approval / form / action callback 回灌: Plan 16 §J 设计草案, Phase 3 客户端 widget 落地后再开。

package chat

import (
	"context"
	"errors"
	"fmt"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/modelerror"
	"net/url"
	"strings"
	"sync"
	"time"

	zapadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domagentrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/llmmetadata"
)

// ZapRuntimeEnvReader chat 服务对 runtime_environments 仓库的窄接口 (ZAP 路径专用):
// 只读 primary_endpoint + api_key_secret_ref + framework。
type ZapRuntimeEnvReader interface {
	GetByID(ctx context.Context, id int64) (*ZapRuntimeEnvSnapshot, error)
}

// ZapRuntimeEnvSnapshot ZAP 路径需要的 runtime_env 字段子集。
type ZapRuntimeEnvSnapshot struct {
	Framework             string
	PrimaryEndpoint       string
	APIKeySecretRef       string
	ExternalEnvironmentID string
	Metadata              map[string]any
	Availability          *ZapRuntimeEnvAvailability
}

type ZapRuntimeEnvAvailability struct {
	Status            string
	Enabled           bool
	EgressAuditStatus string
	LastProbeStatus   string
}

// ZapSecretResolver chat 服务对 SecretResolverFunc 的窄接口 (按 ref 解明文 token)。
type ZapSecretResolver interface {
	Resolve(ref string) (string, error)
}

func validateZapRuntimeEnvReady(env *ZapRuntimeEnvSnapshot) error {
	if env == nil {
		return fmt.Errorf("运行环境不存在，请在后台检查数字员工绑定的托管环境")
	}
	if env.Availability == nil {
		return fmt.Errorf("运行环境状态缺失，请在后台重新测试连通性后重试")
	}
	av := env.Availability
	if strings.TrimSpace(av.Status) != "active" {
		return fmt.Errorf("运行环境未启用，请在后台启用后重试")
	}
	if !av.Enabled {
		return fmt.Errorf("运行环境未启用，请在后台启用后重试")
	}
	if strings.TrimSpace(av.EgressAuditStatus) != "approved" {
		return fmt.Errorf("运行环境出站审核未通过，请在后台「凭证与接入」完成出站审核后重试")
	}
	if strings.TrimSpace(av.LastProbeStatus) != "ok" {
		return fmt.Errorf("运行环境连通性测试未通过，请在后台「凭证与接入」重新测试连通后重试")
	}
	return nil
}

// ZapAgentKeyLookup chat 服务对 digital_employees 表中"已发布到 ZAP runtime 的 agent_key"的窄接口。
// agent_register 任务行写入; chat 路径只读。空字符串 → ZAP 数字员工注册尚未完成。
type ZapAgentKeyLookup interface {
	ResolveAgentKey(ctx context.Context, ag *domagent.DigitalEmployee) (string, error)
}

// ZapChatClientFactory 把 (baseURL, token) 构造成 ChatClient; 单测可注入 fake。
type ZapChatClientFactory func(baseURL, token string) ZapChatClient

// ZapLLMCredentialProvider 为可信外部 ZAP runtime 的 /instances 请求提供
// 租户用户级模型网关凭证。返回的 api_key 是明文密钥, 只能放在出站 body,
// 不得写入日志、conversation metadata 或客户端事件。
type ZapLLMCredentialProvider interface {
	ResolveLLMCredentials(ctx context.Context, tenantID, accountID, runtimeID int64, agent *domagent.DigitalEmployee) (*zapadapter.LLMCredentials, error)
}

// ZapChatClient 是上层对 internal/adapter/runtime/zap/ChatClient 的窄接口 (便于 mock)。
//
// 安全口径 (Plan 16 §B.2 / §I.E): SendMessage / Cancel **不**接收 sessionToken — Phase 2 MVP
// 不向 ZAP runtime 出站任何 session_token (包括 X-ZAP-Session-Token), 一律只用 runtime API key
// (Authorization)。
type ZapChatClient interface {
	InitializeAgentInstance(ctx context.Context, req *zapadapter.AgentInstanceInitializeRequest) (*zapadapter.AgentInstanceInitializeResponse, error)
	EnsureSession(ctx context.Context, req *zapadapter.CreateSessionRequest) (*zapadapter.CreateSessionResponse, error)
	SendMessage(ctx context.Context, sessionID string, req *zapadapter.SendMessageRequest, h zapadapter.SSEEventHandler) error
	Cancel(ctx context.Context, sessionID string) error
}

func zapLLMContextEnvelope(tenantID, accountID int64, agent *domagent.DigitalEmployee, conv *domconv.Conversation, messageUUID, streamID string) map[string]any {
	if zapAgentIsBYOK(agent) {
		return map[string]any{} // ADR-0037 dsh 消费端: byok 调用不进平台网关, 不带计费信封
	}
	agentUUID := ""
	var runtimeEnvID int64
	if agent != nil {
		agentUUID = agent.UUID
		if agent.RuntimeEnvironmentID != nil {
			runtimeEnvID = *agent.RuntimeEnvironmentID
		}
	}
	conversationUUID := ""
	if conv != nil {
		conversationUUID = conv.UUID
	}
	return map[string]any{
		"llm_context": llmmetadata.Map(llmmetadata.Context{
			UsageScene:     "chat",
			TenantID:       tenantID,
			AccountID:      accountID,
			AgentID:        agentUUID,
			ConversationID: conversationUUID,
			MessageID:      messageUUID,
			StreamID:       streamID,
			RuntimeEnvID:   runtimeEnvID,
		}),
	}
}

// zapAgentIsBYOK 员工自带模型服务 (ADR-0037): 模型调用去第三方服务, 知办内部调用上下文只对平台网关有意义。
func zapAgentIsBYOK(agent *domagent.DigitalEmployee) bool {
	return agent != nil && strings.TrimSpace(agent.ModelSource) == "byok"
}

func zapLLMContextEnvelopeForInstance(tenantID, accountID, runtimeID int64, agent *domagent.DigitalEmployee) map[string]any {
	if zapAgentIsBYOK(agent) {
		return map[string]any{}
	}
	agentUUID := ""
	if agent != nil {
		agentUUID = agent.UUID
	}
	return map[string]any{
		"llm_context": llmmetadata.Map(llmmetadata.Context{
			UsageScene:   "chat",
			TenantID:     tenantID,
			AccountID:    accountID,
			AgentID:      agentUUID,
			RuntimeEnvID: runtimeID,
		}),
	}
}

// zapDispatcherImpl chat 服务装配的 ZAP dispatcher 实现 (调用方在 cmd/bus 装配并注入)。
type zapDispatcherImpl struct {
	envs          ZapRuntimeEnvReader
	secret        ZapSecretResolver
	agentKeys     ZapAgentKeyLookup
	llm           ZapLLMCredentialProvider
	clientFact    ZapChatClientFactory
	callLogWriter *zapadapter.CallLogWriter // F19: nil = no call logging
	skills        ZapSkillsCarrierBuilder   // ZAP-1.1 §11.1: POST /sessions body.skills; nil = 不带
	parent        *impl                     // 反引 chat impl, 调 finalize / convs.UpdateMetadataKeys

	// active Stage 3: 进程内 streamID → 当前 ZAP runtime 调用上下文。runZapChatInline 在
	// EnsureSession 成功后注册, 终态 (completed/failed/cancelled) 后 unregister。CancelStream
	// 据此知道是不是 ZAP stream, 以及调哪个 (baseURL, apiKey, session_id) 的 /cancel。
	//
	// 跨节点 stop (PublishCancel) 不命中这里 — 跨节点 stop 在远端 owner 节点的 stopLocalStream
	// 上跑 (其 dispatcher 自己 cancel ctx), 本节点的 optimisticCancel fallback **不**调 runtime cancel,
	// 由 ZAP runtime 自己 TTL 兜底 (Phase 2.5 边界, 见 §B.2 §I.D.3)。
	mu     sync.Mutex
	active map[string]*activeZapSession
}

type ZapDispatcherOption func(*zapDispatcherImpl)

func WithZapLLMCredentials(provider ZapLLMCredentialProvider) ZapDispatcherOption {
	return func(d *zapDispatcherImpl) { d.llm = provider }
}

// WithZapCallLogWriter F19: 启用 runtime 调用日志。
func WithZapCallLogWriter(w *zapadapter.CallLogWriter) ZapDispatcherOption {
	return func(d *zapDispatcherImpl) { d.callLogWriter = w }
}

// activeZapSession 进程内一条 ZAP 流的"runtime 调用上下文 (无 token)"。
type activeZapSession struct {
	client    ZapChatClient
	sessionID string
}

// NewZapDispatcher 构造 ZAP dispatcher; cmd/bus 注入到 chat.Service 上。
// chatImpl 必须是 chat.Service.(*impl), 调 newZapDispatcher 时由 SetZapDispatcherOnService 自动转。
func NewZapDispatcher(envs ZapRuntimeEnvReader, secret ZapSecretResolver, agentKeys ZapAgentKeyLookup, fact ZapChatClientFactory, opts ...ZapDispatcherOption) ZapDispatcher {
	if fact == nil {
		fact = func(baseURL, token string) ZapChatClient {
			return zapadapter.NewChatClient(baseURL, token)
		}
	}
	d := &zapDispatcherImpl{
		envs:       envs,
		secret:     secret,
		agentKeys:  agentKeys,
		clientFact: fact,
		active:     map[string]*activeZapSession{},
	}
	for _, opt := range opts {
		if opt != nil {
			opt(d)
		}
	}
	return d
}

// registerActive Stage 3: runZapChatInline 在拿到可用 session_id 后调, 让 stopLocalStream 能找到。
func (d *zapDispatcherImpl) registerActive(streamID string, client ZapChatClient, sessionID string) {
	if d == nil || streamID == "" || sessionID == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.active == nil {
		d.active = map[string]*activeZapSession{}
	}
	d.active[streamID] = &activeZapSession{client: client, sessionID: sessionID}
}

// unregisterActive Stage 3: runZapChatInline 终态后调 (completed/failed/cancelled), 防止累积。
func (d *zapDispatcherImpl) unregisterActive(streamID string) {
	if d == nil || streamID == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.active, streamID)
}

// CancelStream Stage 3: chat.Stop 路径 best-effort 调 ZAP runtime /sessions/:id/cancel。
//   - 没有注册的 streamID → noop (OpenClaw 路径 / 已收尾 / dispatcher 还没 EnsureSession 完成);
//   - 调 runtime cancel 失败 → 仅 Warn, **不**抛错给客户端, **不**透传 runtime raw error;
//   - cancel 后 unregisterActive (即便失败, 也不重试; runtime TTL 兜底)。
func (d *zapDispatcherImpl) CancelStream(ctx context.Context, streamID string) {
	if d == nil {
		return
	}
	d.mu.Lock()
	sess := d.active[streamID]
	if sess != nil {
		delete(d.active, streamID)
	}
	d.mu.Unlock()
	if sess == nil {
		return
	}
	if err := sess.client.Cancel(ctx, sess.sessionID); err != nil {
		if d.parent != nil && d.parent.logger != nil {
			// 不打 raw error string (可能含 provider URL); 只打 zap code 字符串 (无 token)。
			d.parent.logger.Warn(ctx, "chat zap cancel best-effort failed",
				"stream_id", streamID, "code", zapErrorCode(err))
		}
	}
}

// AttachToService dispatcher 注入 service 后回写 parent 引用; cmd/bus 装配时调用。
func (d *zapDispatcherImpl) AttachToService(svc Service) {
	if im, ok := svc.(*impl); ok {
		d.parent = im
	}
}

// AttachZapDispatcherToService cmd/bus 公开 helper。
func AttachZapDispatcherToService(svc Service, d ZapDispatcher) {
	if impl, ok := d.(*zapDispatcherImpl); ok {
		impl.AttachToService(svc)
	}
}

// RespondToAwaitingMessage ADR-0028 §4.4 — HITL `/chat/respond` 二次入口。
//
// 前提 (service 层已保证):
//  1. §4.6 步骤 6 transactional helper 已 commit: 新 message_streams + 新 messages 行真实存在;
//  2. in.NewStreamID / in.NewAgentMessageUUID 与 helper 写入的 stream_id / agent_message_uuid 完全一致;
//  3. fanout.Register(in.NewStreamID) 已成功 (§4.6 步骤 5)。
//
// 本方法负责:
//   - 解 ZAP runtime env + api key + agent_key;
//   - 复用 conversation.metadata.zap_session_id (缺失 → finalize failed; **不** EnsureSession,
//     ADR §4 不自动 replay 用户响应到新 session);
//   - 发送 SendMessageRequest{Role:"user", Blocks:[ReplyBlock]}, 消费 SSE → finalize 新 stream 终态;
//   - runtime 失败一律 finalize 'failed' + sanitizedRuntimeFailureMessage (不透传 raw)。
//
// 返非 nil 仅代表"装配级错" (parent 未 attach), 业务失败已 finalize。
func (d *zapDispatcherImpl) RespondToAwaitingMessage(ctx context.Context, in ZapRespondInput) error {
	if d == nil || d.parent == nil {
		return errors.New("zap dispatcher not attached to chat service")
	}
	if in.Conversation == nil || in.Agent == nil {
		convUUID := ""
		if in.Conversation != nil {
			convUUID = in.Conversation.UUID
		}
		d.parent.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID,
			convUUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond missing agent/conversation", nil)
		return nil
	}
	d.parent.runZapRespondInline(ctx, in, d)
	return nil
}

// Send 实现 ZapDispatcher: EnsureSession + SendMessage + SSE 终态 → finalize。
// 返非 nil 仅代表"装配级错"; 业务失败已通过 finalize 写入 message.failed。
func (d *zapDispatcherImpl) Send(ctx context.Context, in ZapDispatchInput) error {
	if d.parent == nil {
		return errors.New("zap dispatcher not attached to chat service")
	}
	// 兜底 (Send / RunAgentForConversation / queue worker 都已在调用前校验, 这里再 fail-closed 一次)。
	// **不**解引用 in.Conversation — caller 可能传 nil (单测路径或编程错误), finalize 入参用空 convUUID。
	if in.Agent == nil || in.Conversation == nil {
		convUUID := ""
		if in.Conversation != nil {
			convUUID = in.Conversation.UUID
		}
		d.parent.finalize(ctx, in.StreamID, in.AccountID, in.TenantID,
			convUUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch missing agent/conversation", nil)
		return nil
	}
	if in.Agent.ExecutionLocus == "local" {
		d.parent.runLocalChat(ctx, in, d)
	} else {
		d.parent.runZapChatInline(ctx, in, d)
	}
	return nil
}

// runZapChatGoroutine 在 detached goroutine 中跑 ZAP 流; Send (queue=off) 用; 内部即时 finalize。
// fanout.Close 在 finalize 之后由本 goroutine 兜底 (与 runAgentGoroutine 同模式)。
func (s *impl) runZapChatGoroutine(
	ctx context.Context,
	streamID string,
	accountID, tenantID int64,
	conv *domconv.Conversation,
	roomUUID string,
	ag *domagent.DigitalEmployee,
	promptText string,
	userBlocks []map[string]any,
	agentMsgUUID string,
	userMsgUUID string,
	inputMessageUUID string,
	userMetadata map[string]any,
) {
	defer s.fanout.Close(ctx, streamID)
	in := ZapDispatchInput{
		StreamID:         streamID,
		AccountID:        accountID,
		TenantID:         tenantID,
		Conversation:     conv,
		RoomUUID:         roomUUID,
		Agent:            ag,
		PromptText:       promptText,
		UserBlocks:       cloneZapOutboundBlocks(userBlocks),
		AgentMessageUUID: agentMsgUUID,
		UserMessageUUID:  userMsgUUID,
		InputMessageUUID: inputMessageUUID,
		UserMetadata:     userMetadata,
	}
	if s.zapDispatcher == nil {
		s.finalize(ctx, streamID, accountID, tenantID, conv.UUID, roomUUID, agentMsgUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatcher not wired", nil)
		return
	}
	if err := s.zapDispatcher.Send(ctx, in); err != nil {
		s.logger.Warn(ctx, "chat zap dispatcher returned error", "stream_id", streamID, "err", err.Error())
		// dispatcher 返非 nil 只在装配错路径; 业务失败已 finalize, 这里不重复写。
	}
}

// runZapChatInline dispatcher.Send 的真正落点; queue worker 也走这里 (synchronous)。
//
// 流程:
//  1. 取 ZAP runtime env (framework/primary_endpoint/api_key_secret_ref) + secret 解 token
//  2. 取 agent_key (digital_employees 同步态)
//  3. 解 tenant/account UUID
//  4. EnsureSession
//  5. (best-effort) UpdateMetadataKeys 持久化 session_id + expires_at (白名单守卫)
//  6. SendMessage 消费 SSE: blocks(completed) / error(failed) / cancelled
//  7. canonical mapping → finalize(终态 status + blocks + usage + errCode/errMsg)
func (s *impl) runZapChatInline(ctx context.Context, in ZapDispatchInput, d *zapDispatcherImpl) {
	// F24: open the run recorder before any early-exit so dispatch failures
	// also land as failed runs (finalize flushes by streamID).
	rec := s.startRunRecorder(ctx, RunSpec{
		// Cloud paths state the locus explicitly: relying on a default would let a
		// future local path mislabel itself silently, which is the defect this column exists for.
		ExecutionLocus:       domagentrun.ExecutionLocusCloud,
		TenantID:             in.TenantID,
		AccountID:            in.AccountID,
		DigitalEmployeeID:    in.Agent.ID,
		ConversationUUID:     in.Conversation.UUID,
		MessageUUID:          in.AgentMessageUUID,
		StreamID:             in.StreamID,
		RoomID:               in.Conversation.RoomID,
		RuntimeKind:          domagentrun.RuntimeZapExt,
		RuntimeEnvironmentID: in.Agent.RuntimeEnvironmentID,
		TriggerSource:        zapTriggerSource(in.RoomUUID),
		AgentVersion:         in.Agent.CurrentVersion,
	})
	if d.envs == nil || d.secret == nil || d.agentKeys == nil || d.clientFact == nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatcher dependencies missing", nil)
		return
	}
	if in.Agent.RuntimeEnvironmentID == nil || *in.Agent.RuntimeEnvironmentID <= 0 {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: agent has no runtime_environment_id", nil)
		return
	}
	env, err := d.envs.GetByID(ctx, *in.Agent.RuntimeEnvironmentID)
	if err != nil || env == nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: runtime env lookup failed", nil)
		return
	}
	if !isZapWireFramework(env.Framework) {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: runtime framework mismatch", nil)
		return
	}
	if err := validateZapRuntimeEnvReady(env); err != nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: "+err.Error(), nil)
		return
	}
	baseURL := strings.TrimSpace(env.PrimaryEndpoint)
	if baseURL == "" {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: primary_endpoint empty", nil)
		return
	}
	if _, err := url.Parse(baseURL); err != nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: primary_endpoint invalid", nil)
		return
	}
	if strings.TrimSpace(env.APIKeySecretRef) == "" {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: api_key_secret_ref empty", nil)
		return
	}
	apiKey, err := d.secret.Resolve(env.APIKeySecretRef)
	if err != nil || strings.TrimSpace(apiKey) == "" {
		// 错误描述不包含 secret_ref 本身(可能含敏感信息), 由 secret resolver 决定 log。
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: api key resolve failed", nil)
		return
	}
	agentKey, err := resolveZapAgentKeyForDispatch(ctx, d.agentKeys, in.Agent)
	if err != nil || strings.TrimSpace(agentKey) == "" {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeControlPlaneNotReady, "zap dispatch: agent_key not synced to runtime", nil)
		return
	}
	identityProfile, err := s.resolveZapIdentityProfile(ctx, in.TenantID, in.AccountID)
	if err != nil {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap dispatch: identity resolve failed", nil)
		return
	}
	client := d.clientFact(baseURL, apiKey)
	// 多副本亲和: 同一 (tenant, account) 落同一 runtime 副本 (X-ZAP-Routing-Key, ingress 一致性哈希)
	if cc, ok := client.(*zapadapter.ChatClient); ok {
		zapadapter.WithChatRoutingKey(zapadapter.RoutingKeyFor(in.TenantID, in.AccountID))(cc)
	}
	// F19: attach call log writer to the chat client (if available)
	if d.callLogWriter != nil {
		if cc, ok := client.(*zapadapter.ChatClient); ok {
			acctID := in.AccountID
			agentID := in.Agent.ID
			zapadapter.WithChatCallLog(d.callLogWriter, &zapadapter.CallMetadata{
				TenantID:             in.TenantID,
				AccountID:            &acctID,
				RuntimeEnvironmentID: in.Agent.RuntimeEnvironmentID,
				DigitalEmployeeID:    &agentID,
				AgentUUID:            in.Agent.UUID,
				AgentKey:             agentKey,
				ConversationUUID:     in.Conversation.UUID,
				MessageUUID:          in.AgentMessageUUID,
				StreamID:             in.StreamID,
			})(cc)
		}
	}
	agentIdentity := zapIdentityAgentContext(in.Agent, agentKey)

	// 平台自营 dsh 运行时 (ADR-0035 修订) 专属策略:
	//  (a) 必须经 /instances 注入 per-user 模型凭据 (否则 runtime 会静默回落服务级 key, 用量无法归账) —— runtime_card
	//      未缓存 (探测未过) 直接拒派发, 不带病运行;
	//  (b) 与 OpenClaw 路径同款 KB 预检索: 命中内容经 metadata.knowledge_context 下发, 回复尾部挂来源块。
	isDSH := isDSHFramework(env.Framework)
	if isDSH && selectedConversationModel(in.UserMetadata) != "" && (!zapConversationModelEnabled(env.Metadata) || domsource.IsReference(selectedConversationModel(in.UserMetadata)) && !zapModelPlatformEnabled(env.Metadata)) {
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", "model.runtime_upgrade_required", "运行环境尚不支持所选模型，请更新运行环境并重新检测后重试", nil)
		return
	}
	if isDSH && !zapAgentInstanceInitializationEnabled(env.Metadata) {
		s.logger.Warn(ctx, "chat dsh dispatch refused: runtime_card not cached (probe required)",
			"stream_id", in.StreamID, "runtime_env_id", *in.Agent.RuntimeEnvironmentID)
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "知办通用运行时未完成连通性探测，请在后台重新测试连通后重试", nil)
		return
	}
	var kc *KnowledgeContext
	if isDSH {
		ragQuery := s.chatRAGQueryText(ctx, in.PromptText, in.InputMessageUUID, safeAgentName(in.Agent))
		kc = s.prepareRuntimeKnowledgeContext(ctx, ChatRAGRequest{
			TenantID:         in.TenantID,
			AccountID:        in.AccountID,
			Agent:            in.Agent,
			Conversation:     in.Conversation,
			RoomUUID:         in.RoomUUID,
			MessageUUID:      in.AgentMessageUUID,
			QueryOriginal:    ragQuery,
			QueryRewritten:   ragQuery,
			InvocationSource: "pre_retrieve",
		})
	}

	createReq := &zapadapter.CreateSessionRequest{
		AgentKey: agentKey,
		Agent:    agentIdentity,
		User: zapadapter.SessionUser{
			TenantUUID:  identityProfile.TenantUUID,
			AccountUUID: identityProfile.AccountUUID,
		},
		SessionKind: "single",
		ConversationContextHint: zapadapter.ConversationContextHint{
			TenantID:         identityProfile.TenantUUID,
			AccountID:        identityProfile.AccountUUID,
			ConversationUUID: in.Conversation.UUID,
			Purpose:          "production",
		},
		Identity: zapSessionIdentityFromProfile(identityProfile),
		Profile:  zapSessionProfileMap(identityProfile),
		Metadata: zapadapter.MergeRuntimeEnvironmentMetadata(
			zapLLMContextEnvelope(in.TenantID, in.AccountID, in.Agent, in.Conversation, in.AgentMessageUUID, in.StreamID),
			env.ExternalEnvironmentID,
		),
		// ZAP-1.1 §11.1: 技能集**只发平台自营 dsh 运行时**。外部 ZAP runtime (talentos/百工/财税) 用严格 schema
		// (DisallowUnknownFields), 见到未知的 skills 字段直接 422 extra_forbidden — 它们自管技能, 不接收本节。
		Skills: dshOnlySkills(isDSH, func() any { return d.buildZapSessionSkills(ctx, in) }),
	}
	if zapAgentInstanceInitializationEnabled(env.Metadata) {
		runtimeIdentity, identityErr := d.ensureZapAgentInstance(ctx, client, in.TenantID, in.AccountID, *in.Agent.RuntimeEnvironmentID, env.ExternalEnvironmentID, identityProfile, in.Agent, agentIdentity)
		if identityErr != nil {
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
				nil, "failed", ErrCodeProtocolUnsupported, "zap_identity_resolve_failed", nil)
			return
		}
		createReq.RuntimeIdentity = runtimeIdentity
	}

	// Stage 2 (session 复用): 优先复用 conv.metadata.zap_session_id (未过期); SendMessage
	// 失败 (404/409 session_not_found/cancelled) 时重建 EnsureSession 重试一次。
	// EnsureSession 成功后才写 zap_session_id / zap_session_expires_at (session_token 立即丢弃)。
	sessionID := reuseZapSessionID(in.Conversation)
	if sessionID == "" {
		newSess, ensureErr := client.EnsureSession(ctx, createReq)
		if ensureErr != nil || newSess == nil || newSess.SessionID == "" {
			s.logger.Warn(ctx, "chat zap EnsureSession failed",
				"stream_id", in.StreamID,
				"runtime_env_id", *in.Agent.RuntimeEnvironmentID,
				"endpoint", baseURL,
				"agent_key", agentKey,
				"err", zapSafeErr(ensureErr, "empty session_id"))
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
				nil, "failed", ErrCodeProtocolUnsupported, "zap_session_create_failed", nil)
			return
		}
		sessionID = newSess.SessionID
		s.persistZapSessionMetadata(ctx, in, newSess.SessionID, newSess.ExpiresAt)
	}

	// Stage 3: 注册 (streamID → client + session_id), chat.Stop 可调 CancelStream 通知 runtime。
	// defer unregisterActive 兜底 (终态后清; CancelStream 内部也会清, 重复 delete 无害)。
	d.registerActive(in.StreamID, client, sessionID)
	defer d.unregisterActive(in.StreamID)

	// SSE 消费: 累积 markdown/plain block.delta 成快照; message.completed 命中即收尾。
	var (
		gotCompleted bool
		finalBlocks  []map[string]any
		usage        map[string]any
		errKind      string // "failed" / "cancelled" / "awaiting_user"
		errCode      string
		errMsg       string
		// snapshot Phase 2.5 增量流式: ZAP 端 block_delta 可能透"增量 text"或直接"snapshot"。
		// 两种形态都规一化到客户端期望的"累计文本快照"语义 (与 OpenClaw EventMessageBlockDelta.Text 同款),
		// 然后通过 fanout publish 一次 EventMessageBlockDelta。typed block 不累积。
		snapshot string
		// awaitingBlockID ADR-0028: ZAP `message.awaiting_user` 事件的可选 awaiting_block_id,
		// 透传给 awaitFinalize 写 messages.metadata.awaiting_block_id。
		awaitingBlockID string
	)
	sendReq := &zapadapter.SendMessageRequest{
		Role: "user",
		Text: in.PromptText,
		// AIGC envelope + 客户端选中的技能 (active_skill_* / skill_params, F03 §4.4 白名单透传)。
		Metadata: mergeZapForwardedUserMetadata(
			zapLLMContextEnvelope(in.TenantID, in.AccountID, in.Agent, in.Conversation, in.AgentMessageUUID, in.StreamID),
			in.UserMetadata),
	}
	if isDSH {
		if model := selectedConversationModel(in.UserMetadata); model != "" {
			if sendReq.Metadata == nil {
				sendReq.Metadata = map[string]any{}
			}
			sendReq.Metadata["conversation_model"] = model
		}
	}
	if isDSH {
		binding, err := s.prepareConversationModel(ctx, in.AccountID, in.TenantID, in.Agent, in.AgentMessageUUID, selectedConversationModel(in.UserMetadata))
		if err != nil {
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, nil, "failed", "model.platform_unavailable", "所选模型平台不可用，请重新选择", nil)
			return
		}
		if binding != nil {
			sendReq.ModelService = binding
			delete(sendReq.Metadata, "conversation_model")
		}
	}
	// External/custom ZAP runtimes own their tool and knowledge strategy. Bus
	// forwards only the user's input; a hybrid runtime that borrows platform KB
	// calls SDK kb.retrieve_associated(agent_id, query) when it decides to search.
	// 平台自营 dsh 例外: 预检索结果经 metadata.knowledge_context 下发 (runtime 拼进提示词, 不改用户原文)。
	if kcMeta := zapKnowledgeContextMetadata(kc); kcMeta != nil {
		if sendReq.Metadata == nil {
			sendReq.Metadata = map[string]any{}
		}
		sendReq.Metadata["knowledge_context"] = kcMeta
	}
	if len(in.UserBlocks) > 0 {
		sendReq.RawBlocks = cloneZapOutboundBlocks(in.UserBlocks)
	}
	if len(sendReq.RawBlocks) > 0 {
		preparedBlocks, prepErr := s.prepareZapRuntimeFileBlocks(ctx, in.AccountID, in.TenantID, sendReq.RawBlocks)
		if prepErr != nil {
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
				nil, "failed", ErrCodeProtocolUnsupported, "zap_prepare_file_blocks_failed", nil)
			return
		}
		sendReq.RawBlocks = preparedBlocks
	}
	handler := func(ev zapadapter.SSEEvent) (bool, error) {
		switch ev.Kind {
		case zapadapter.SSECreated:
			// 上层已经发过 message.created (runAgentInternal Step 3); 不再重复发布。
			return false, nil
		case zapadapter.SSEBlockDelta:
			delta, kind := extractZapBlockDeltaText(ev.BlockDelta)
			if delta == "" || (kind != "" && kind != "markdown" && kind != "plain") {
				// typed block (chart/form/...) 或空 delta → 不累积, 不下发, 等 completed 兜底。
				return false, nil
			}
			snapshot = applyMarkdownDelta(snapshot, delta)
			rec.OnOutput(time.Now())
			s.publishZapTextDelta(ctx, in, snapshot)
			return false, nil
		case zapadapter.SSECompleted:
			gotCompleted = true
			finalBlocks = canonicalMapBlocks(ev.Blocks)
			usage = ev.Usage
			return true, nil
		case zapadapter.SSEFailed:
			errKind = "failed"
			errCode = sanitizeRuntimeErrorCode(ev.ErrorCode, ev.ErrorMessage)
			errMsg = sanitizeRuntimeError(ev.ErrorCode, ev.ErrorMessage)
			s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
				RuntimeKind:      FrameworkZap,
				FailureStage:     "runtime_sse_failed",
				StreamID:         in.StreamID,
				MessageUUID:      in.AgentMessageUUID,
				ConversationUUID: in.Conversation.UUID,
				RoomUUID:         in.RoomUUID,
				AccountID:        in.AccountID,
				TenantID:         in.TenantID,
				Agent:            in.Agent,
				ErrorCode:        errCode,
				RawErrorCode:     ev.ErrorCode,
				Diagnostic:       ev.ErrorMessage,
			})
			return true, nil
		case zapadapter.SSECancelled:
			errKind = "cancelled"
			return true, nil
		case zapadapter.SSEAwaitingUser:
			// ADR-0028 §4.2 — HITL pause; awaiting_user 也是终态 (本轮 stream 不再产事件)。
			// blocks 走与 completed 同款 canonical mapping; awaiting_block_id 透到收尾路径。
			errKind = "awaiting_user"
			finalBlocks = canonicalMapBlocks(ev.Blocks)
			awaitingBlockID = ev.AwaitingBlockID
			return true, nil
		case zapadapter.SSEToolCall, zapadapter.SSEToolResult:
			// Round-8: 中间帧, 透传给 fanout; 不改终态, 不写 DB; 继续读 SSE。
			if ev.Kind == zapadapter.SSEToolCall {
				rec.OnToolCall(ev.ToolCallID, ev.ToolName, time.Now())
			} else {
				rec.OnToolResult(ev.ToolCallID, !zapToolStatusFailed(ev.ToolStatus), "", time.Now())
			}
			s.publishZapTool(ctx, in.StreamID, in.AccountID, in.TenantID,
				in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, ev)
			return false, nil
		case zapadapter.SSEReasoning:
			rec.OnReasoning(time.Now())
			s.publishZapReasoning(ctx, in.StreamID, in.AccountID, in.TenantID,
				in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID, ev)
			return false, nil
		default:
			// 未知 event 名, 忽略 (向前兼容: runtime 升级新事件不应让 Bus 崩)。
			return false, nil
		}
	}
	sendErr := client.SendMessage(ctx, sessionID, sendReq, handler)
	if sendErr != nil && isZapSessionStale(sendErr) {
		// Stage 2: 复用的 session_id 过期 / 被 cancel → 重新 EnsureSession 重试一次。
		s.logger.Info(ctx, "chat zap reused session stale; rebuilding",
			"stream_id", in.StreamID, "old_session_id", sessionID, "code", zapErrorCode(sendErr))
		newSess, ensureErr := client.EnsureSession(ctx, createReq)
		if ensureErr != nil || newSess == nil || newSess.SessionID == "" {
			s.logger.Warn(ctx, "chat zap EnsureSession retry failed",
				"stream_id", in.StreamID,
				"runtime_env_id", *in.Agent.RuntimeEnvironmentID,
				"endpoint", baseURL,
				"agent_key", agentKey,
				"err", zapSafeErr(ensureErr, "empty session_id"))
			s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
				nil, "failed", ErrCodeProtocolUnsupported, "zap_session_create_failed", nil)
			return
		}
		sessionID = newSess.SessionID
		s.persistZapSessionMetadata(ctx, in, newSess.SessionID, newSess.ExpiresAt)
		// Stage 3: 注册指向新 session_id (defer unregisterActive 仍负责清理; 这里 register 覆盖旧值)。
		d.registerActive(in.StreamID, client, sessionID)
		// 重置 SSE 累积 (前次 stale 调用如果在 client 端发了部分 delta, 这里 caller 已经丢; 重试干净)
		snapshot = ""
		gotCompleted = false
		finalBlocks = nil
		usage = nil
		errKind = ""
		errCode = ""
		errMsg = ""
		sendErr = client.SendMessage(ctx, sessionID, sendReq, handler)
	}
	if sendErr != nil {
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkZap,
			FailureStage:     "send_message",
			StreamID:         in.StreamID,
			MessageUUID:      in.AgentMessageUUID,
			ConversationUUID: in.Conversation.UUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeProtocolUnsupported,
			RawErrorCode:     zapErrorCode(sendErr),
			Diagnostic:       zapSafeErr(sendErr, "send message failed"),
		})
		// ChatClient 已经吞掉 ErrSSEStopByHandler; 这里到这是真实 transport / decode / 4xx-5xx 错。
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap_send_message_failed", nil)
		return
	}
	switch errKind {
	case "failed":
		if errCode == "" {
			errCode = ErrCodeRuntimeUpstreamFailure
		}
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", errCode, errMsg, nil)
		return
	case "cancelled":
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "cancelled", "", "", nil)
		return
	case "awaiting_user":
		// ADR-0028 §4.2 — HITL 暂停: 走 awaitFinalize (messages.status='awaiting_user' +
		// final=true; stream state='done'; SSE message.awaiting_user)。**不**走 finalize 路径,
		// 否则会把状态写成 final/failed/cancelled 与 ADR §4.2 设计冲突。
		s.awaitFinalize(ctx, in.StreamID, in.AccountID, in.TenantID,
			in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			finalBlocks, awaitingBlockID)
		return
	}
	if !gotCompleted {
		// SSE 结束但既没拿到 completed, 也没拿到 failed/cancelled → 视为失败。
		s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap_no_terminal_event", nil)
		return
	}
	if kc != nil {
		// dsh: 与 OpenClaw 同款来源块 (检索充分时才挂; 去掉模型自己写的 Sources 尾行)。
		finalBlocks = finalBlocksWithKnowledgeContextSources(finalBlocks, kc)
	}
	s.finalize(ctx, in.StreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.AgentMessageUUID,
		finalBlocks, "final", "", "", usage)
}

// zapKnowledgeContextMetadata 把 Bus 预检索结果压成 ZAP metadata.knowledge_context (平台 dsh runtime 消费;
// 字段与 dsh-runtime src/server/chat.ts 对齐)。nil / 无命中且不建议工具追查 → nil (不下发该键)。
func zapKnowledgeContextMetadata(kc *KnowledgeContext) map[string]any {
	if kc == nil || (len(kc.Items) == 0 && !kc.SuggestToolFollowUp) {
		return nil
	}
	items := make([]map[string]any, 0, len(kc.Items))
	for _, it := range kc.Items {
		content := strings.TrimSpace(it.Content)
		if content == "" {
			continue
		}
		items = append(items, map[string]any{
			"reference_id":   it.ReferenceID,
			"kb_name":        it.KBName,
			"document_title": knowledgeSourceTitle(it),
			"score":          it.Score,
			"content":        content,
		})
	}
	return map[string]any{
		"items":                  items,
		"retrieval_status":       kc.RetrievalStatus,
		"suggest_tool_follow_up": kc.SuggestToolFollowUp,
	}
}

// runZapRespondInline ADR-0028 §4.4 — HITL /chat/respond dispatcher inline 执行:
//
//  1. 复用 conv.metadata.zap_session_id (缺失 → finalize failed; ADR §4.6 步骤 3 守卫已经在
//     service 层挡住, 这里再防御一次);
//  2. 解 ZAP runtime env + api key + agent_key;
//  3. 发送 SendMessageRequest{Role:"user", Blocks:[in.ReplyBlock]} (PromptText 留空);
//  4. SSE 消费同 Send 路径 (block.delta 累积 / completed/failed/cancelled/awaiting_user);
//  5. finalize / awaitFinalize 走与 Send 完全一致的收尾。
//
// 与 runZapChatInline 的差异:
//   - 不调 EnsureSession (强制复用现有 session; 缺失直接 fail-closed, 不自动 replay 用户响应);
//   - Send body 用 Blocks (typed reply block) 替代 Text;
//   - register fanout / message_streams 已由 service 层在 §4.6 步骤 5/6 完成, 这里不再写。
func (s *impl) runZapRespondInline(ctx context.Context, in ZapRespondInput, d *zapDispatcherImpl) {
	// F24: (a) settle the awaiting run (claim → completed + hitl_wait_ms);
	// (b) the respond turn is a NEW stream + message = a new run.
	if s.runRecs != nil {
		s.runRecs.CloseAwaitingRun(in.TenantID, in.AwaitingMessageUUID, time.Now())
	}
	rec := s.startRunRecorder(ctx, RunSpec{
		// Cloud paths state the locus explicitly: relying on a default would let a
		// future local path mislabel itself silently, which is the defect this column exists for.
		ExecutionLocus:       domagentrun.ExecutionLocusCloud,
		TenantID:             in.TenantID,
		AccountID:            in.AccountID,
		DigitalEmployeeID:    in.Agent.ID,
		ConversationUUID:     in.Conversation.UUID,
		MessageUUID:          in.NewAgentMessageUUID,
		StreamID:             in.NewStreamID,
		RoomID:               in.Conversation.RoomID,
		RuntimeKind:          domagentrun.RuntimeZapExt,
		RuntimeEnvironmentID: in.Agent.RuntimeEnvironmentID,
		TriggerSource:        zapTriggerSource(in.RoomUUID),
		AgentVersion:         in.Agent.CurrentVersion,
	})
	if d.envs == nil || d.secret == nil || d.agentKeys == nil || d.clientFact == nil {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond dependencies missing", nil)
		return
	}
	if in.Agent.RuntimeEnvironmentID == nil || *in.Agent.RuntimeEnvironmentID <= 0 {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: agent has no runtime_environment_id", nil)
		return
	}
	env, err := d.envs.GetByID(ctx, *in.Agent.RuntimeEnvironmentID)
	if err != nil || env == nil {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: runtime env lookup failed", nil)
		return
	}
	if !isZapWireFramework(env.Framework) {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: runtime framework mismatch", nil)
		return
	}
	if err := validateZapRuntimeEnvReady(env); err != nil {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: "+err.Error(), nil)
		return
	}
	baseURL := strings.TrimSpace(env.PrimaryEndpoint)
	if baseURL == "" {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: primary_endpoint empty", nil)
		return
	}
	if _, err := url.Parse(baseURL); err != nil {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: primary_endpoint invalid", nil)
		return
	}
	if strings.TrimSpace(env.APIKeySecretRef) == "" {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: api_key_secret_ref empty", nil)
		return
	}
	apiKey, err := d.secret.Resolve(env.APIKeySecretRef)
	if err != nil || strings.TrimSpace(apiKey) == "" {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: api key resolve failed", nil)
		return
	}

	// 强制复用 conv.metadata.zap_session_id; 缺失 → fail-closed (service 层 §4.6 步骤 3
	// 已经挡住, 但 race 条件下 conv metadata 可能被同时修改; 这里再防御一次)。
	sessionID := reuseZapSessionID(in.Conversation)
	if sessionID == "" {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: session reuse missing", nil)
		return
	}

	client := d.clientFact(baseURL, apiKey)
	if d.callLogWriter != nil {
		if cc, ok := client.(*zapadapter.ChatClient); ok {
			acctID := in.AccountID
			agentID := in.Agent.ID
			zapadapter.WithChatCallLog(d.callLogWriter, &zapadapter.CallMetadata{
				TenantID:             in.TenantID,
				AccountID:            &acctID,
				RuntimeEnvironmentID: in.Agent.RuntimeEnvironmentID,
				DigitalEmployeeID:    &agentID,
				AgentUUID:            in.Agent.UUID,
				ConversationUUID:     in.Conversation.UUID,
				MessageUUID:          in.NewAgentMessageUUID,
				StreamID:             in.NewStreamID,
			})(cc)
		}
	}

	// Stage 3 同款: 注册 in-memory activeZapSession, 让 chat.Stop 路径能 best-effort cancel runtime。
	d.registerActive(in.NewStreamID, client, sessionID)
	defer d.unregisterActive(in.NewStreamID)

	// 组装 SendMessageRequest: Role=user; RawBlocks=[typed reply block]; Text 留空。
	if in.ReplyBlock == nil {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: reply block empty", nil)
		return
	}
	if blockType, _ := in.ReplyBlock["type"].(string); strings.TrimSpace(blockType) == "" {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap respond: reply block missing type", nil)
		return
	}
	// ADR-0028 §4.5: typed reply block (含 decision / reason / fields / action_id / params /
	// in_reply_to_message_id) 必须以**结构化 JSON 对象**出站, 而不是塞进 `text` 字符串。
	// zap.SendMessageRequest.RawBlocks 走自定义 marshal 路径, runtime 端直接看到完整 typed block。
	sendReq := &zapadapter.SendMessageRequest{
		Role:      "user",
		RawBlocks: []map[string]any{in.ReplyBlock},
		Metadata:  zapLLMContextEnvelope(in.TenantID, in.AccountID, in.Agent, in.Conversation, in.NewAgentMessageUUID, in.NewStreamID),
	}

	// SSE 消费 (与 Send 路径同款; 复用 finalize / awaitFinalize 收尾)。
	var (
		gotCompleted    bool
		finalBlocks     []map[string]any
		usage           map[string]any
		errKind         string
		errCode         string
		errMsg          string
		snapshot        string
		awaitingBlockID string
	)
	handler := func(ev zapadapter.SSEEvent) (bool, error) {
		switch ev.Kind {
		case zapadapter.SSECreated:
			return false, nil
		case zapadapter.SSEBlockDelta:
			delta, kind := extractZapBlockDeltaText(ev.BlockDelta)
			if delta == "" || (kind != "" && kind != "markdown" && kind != "plain") {
				return false, nil
			}
			snapshot = applyMarkdownDelta(snapshot, delta)
			rec.OnOutput(time.Now())
			s.publishZapTextDeltaForRespond(ctx, in, snapshot)
			return false, nil
		case zapadapter.SSECompleted:
			gotCompleted = true
			finalBlocks = canonicalMapBlocks(ev.Blocks)
			usage = ev.Usage
			return true, nil
		case zapadapter.SSEFailed:
			errKind = "failed"
			errCode = sanitizeRuntimeErrorCode(ev.ErrorCode, ev.ErrorMessage)
			errMsg = sanitizeRuntimeError(ev.ErrorCode, ev.ErrorMessage)
			s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
				RuntimeKind:      FrameworkZap,
				FailureStage:     "respond_sse_failed",
				StreamID:         in.NewStreamID,
				MessageUUID:      in.NewAgentMessageUUID,
				ConversationUUID: in.Conversation.UUID,
				RoomUUID:         in.RoomUUID,
				AccountID:        in.AccountID,
				TenantID:         in.TenantID,
				Agent:            in.Agent,
				ErrorCode:        errCode,
				RawErrorCode:     ev.ErrorCode,
				Diagnostic:       ev.ErrorMessage,
			})
			return true, nil
		case zapadapter.SSECancelled:
			errKind = "cancelled"
			return true, nil
		case zapadapter.SSEAwaitingUser:
			// 又一次 HITL pause: 新 stream 也能再走 awaiting_user 流程, 客户端再次 /chat/respond。
			errKind = "awaiting_user"
			finalBlocks = canonicalMapBlocks(ev.Blocks)
			awaitingBlockID = ev.AwaitingBlockID
			return true, nil
		case zapadapter.SSEToolCall, zapadapter.SSEToolResult:
			// Round-8: HITL respond 路径上 runtime 也可能透出 tool/reasoning 中间帧
			// (例如 agent 在 awaiting_user 之间真的调了工具)。同样透传, 不改终态。
			if ev.Kind == zapadapter.SSEToolCall {
				rec.OnToolCall(ev.ToolCallID, ev.ToolName, time.Now())
			} else {
				rec.OnToolResult(ev.ToolCallID, !zapToolStatusFailed(ev.ToolStatus), "", time.Now())
			}
			s.publishZapTool(ctx, in.NewStreamID, in.AccountID, in.TenantID,
				in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID, ev)
			return false, nil
		case zapadapter.SSEReasoning:
			rec.OnReasoning(time.Now())
			s.publishZapReasoning(ctx, in.NewStreamID, in.AccountID, in.TenantID,
				in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID, ev)
			return false, nil
		default:
			return false, nil
		}
	}
	sendErr := client.SendMessage(ctx, sessionID, sendReq, handler)
	if sendErr != nil {
		s.logRuntimeFailureDiagnostic(ctx, runtimeFailureDiagnosticInput{
			RuntimeKind:      FrameworkZap,
			FailureStage:     "respond_send_message",
			StreamID:         in.NewStreamID,
			MessageUUID:      in.NewAgentMessageUUID,
			ConversationUUID: in.Conversation.UUID,
			RoomUUID:         in.RoomUUID,
			AccountID:        in.AccountID,
			TenantID:         in.TenantID,
			Agent:            in.Agent,
			ErrorCode:        ErrCodeProtocolUnsupported,
			RawErrorCode:     zapErrorCode(sendErr),
			Diagnostic:       zapSafeErr(sendErr, "respond send message failed"),
		})
		// 不重试 — /chat/respond 不像 Send 那样有"session 过期重建" 兜底, 因为重建 session 后
		// runtime 端的 HITL 上下文 (in_reply_to_message_id) 关联不到, replay 用户响应是危险行为
		// (ADR §4.8 / §6 不采用项)。
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap_respond_send_failed", nil)
		return
	}
	switch errKind {
	case "failed":
		if errCode == "" {
			errCode = ErrCodeRuntimeUpstreamFailure
		}
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", errCode, errMsg, nil)
		return
	case "cancelled":
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "cancelled", "", "", nil)
		return
	case "awaiting_user":
		s.awaitFinalize(ctx, in.NewStreamID, in.AccountID, in.TenantID,
			in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			finalBlocks, awaitingBlockID)
		return
	}
	if !gotCompleted {
		s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
			nil, "failed", ErrCodeProtocolUnsupported, "zap_respond_no_terminal_event", nil)
		return
	}
	s.finalize(ctx, in.NewStreamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, in.NewAgentMessageUUID,
		finalBlocks, "final", "", "", usage)
}

// publishZapTextDeltaForRespond — 与 publishZapTextDelta 同款, 但拿 ZapRespondInput 字段。
// 单独一个函数避免给 publishZapTextDelta 增加二选一参数。
func (s *impl) publishZapTextDeltaForRespond(ctx context.Context, in ZapRespondInput, snapshot string) {
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
		MessageUUID:      in.NewAgentMessageUUID,
		Blocks:           []map[string]any{{"type": "markdown", "text": snapshot}},
		Text:             snapshot,
		Timestamp:        time.Now(),
	}
	if err := s.fanout.Publish(ctx, in.NewStreamID, in.AccountID, in.TenantID, ev); err != nil {
		s.logger.Warn(ctx, "chat zap respond publish block.delta failed",
			"stream_id", in.NewStreamID, "err", err.Error())
	}
}

func (s *impl) resolveZapIdentityProfile(ctx context.Context, tenantID, accountID int64) (*IdentityProfile, error) {
	if s.identityResolver == nil {
		return nil, errors.New("chat identity resolver not wired")
	}
	if pr, ok := s.identityResolver.(IdentityProfileResolver); ok {
		return pr.ResolveTenantAccountProfile(ctx, tenantID, accountID)
	}
	tenantUUID, accountUUID, err := s.identityResolver.ResolveTenantAccount(ctx, tenantID, accountID)
	if err != nil {
		return nil, err
	}
	return &IdentityProfile{TenantUUID: tenantUUID, AccountUUID: accountUUID}, nil
}

func resolveZapAgentKeyForDispatch(ctx context.Context, lookup ZapAgentKeyLookup, ag *domagent.DigitalEmployee) (string, error) {
	if lookup == nil {
		return "", errors.New("zap agent key lookup missing")
	}
	key, err := lookup.ResolveAgentKey(ctx, ag)
	if strings.TrimSpace(key) != "" && err == nil {
		return strings.TrimSpace(key), nil
	}
	if err != nil {
		return "", err
	}
	return "", errors.New("zap agent key empty")
}

func zapConversationModelEnabled(meta map[string]any) bool {
	card, _ := meta["runtime_card"].(map[string]any)
	extensions, _ := card["extensions"].(map[string]any)
	capability, _ := extensions["conversation_model"].(map[string]any)
	perTurn, _ := capability["per_turn"].(bool)
	// Metadata comes from JSON, so accept its numeric representation only.
	version, _ := capability["version"].(float64)
	return perTurn && version == 1
}

func zapAgentInstanceInitializationEnabled(meta map[string]any) bool {
	if meta == nil {
		return false
	}
	card, _ := meta["runtime_card"].(map[string]any)
	if card == nil {
		return false
	}
	init, _ := card["agent_instance_initialization"].(map[string]any)
	if init == nil {
		return false
	}
	v, _ := init["supports_initialize"].(bool)
	return v
}

func zapSessionIdentityFromProfile(p *IdentityProfile) *zapadapter.SessionIdentity {
	if p == nil || strings.TrimSpace(p.TenantUUID) == "" || strings.TrimSpace(p.AccountUUID) == "" {
		return nil
	}
	subjects := zapProviderSubjectsFromProfile(p)
	issuer, subject := zapPrimaryProviderSubject(subjects)
	return &zapadapter.SessionIdentity{
		Source:           "easyo",
		TenantUUID:       p.TenantUUID,
		AccountUUID:      p.AccountUUID,
		ProviderIssuer:   issuer,
		ProviderSubject:  subject,
		ProviderSubjects: subjects,
	}
}

func zapProviderSubjectsFromProfile(p *IdentityProfile) map[string]string {
	if p == nil || len(p.ProviderUIDs) == 0 {
		return nil
	}
	out := make(map[string]string, len(p.ProviderUIDs))
	for k, v := range p.ProviderUIDs {
		key := strings.TrimSpace(strings.ToLower(k))
		val := strings.TrimSpace(v)
		if key == "" || val == "" {
			continue
		}
		out[key] = val
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func zapPrimaryProviderSubject(subjects map[string]string) (string, string) {
	for _, key := range []string{"oidc", "ldap"} {
		if v := strings.TrimSpace(subjects[key]); v != "" {
			return key, v
		}
	}
	for k, v := range subjects {
		if strings.TrimSpace(v) != "" {
			return k, strings.TrimSpace(v)
		}
	}
	return "", ""
}

func zapSessionProfileMap(p *IdentityProfile) map[string]any {
	profile := map[string]any{
		"tenant_id": p.TenantUUID,
		"user_id":   p.AccountUUID,
	}
	if strings.TrimSpace(p.TenantName) != "" {
		profile["tenant_name"] = strings.TrimSpace(p.TenantName)
	}
	if strings.TrimSpace(p.DisplayName) != "" {
		profile["display_name"] = strings.TrimSpace(p.DisplayName)
	}
	if strings.TrimSpace(p.Email) != "" {
		profile["email"] = strings.TrimSpace(p.Email)
		profile["email_verified"] = true
	}
	if strings.TrimSpace(p.Phone) != "" {
		profile["phone"] = strings.TrimSpace(p.Phone)
		profile["phone_verified"] = true
	}
	if strings.TrimSpace(p.Username) != "" {
		profile["username"] = strings.TrimSpace(p.Username)
	}
	if subjects := zapProviderSubjectsFromProfile(p); len(subjects) > 0 {
		profile["provider_subjects"] = subjects
	}
	return profile
}

func zapIdentityAgentContext(ag *domagent.DigitalEmployee, agentKey string) *zapadapter.IdentityAgentContext {
	if ag == nil {
		if strings.TrimSpace(agentKey) == "" {
			return nil
		}
		return &zapadapter.IdentityAgentContext{AgentKey: strings.TrimSpace(agentKey)}
	}
	ctx := &zapadapter.IdentityAgentContext{
		DigitalEmployeeUUID: strings.TrimSpace(ag.UUID),
		AgentKey:            strings.TrimSpace(agentKey),
	}
	if ctx.DigitalEmployeeUUID == "" && ctx.AgentKey == "" {
		return nil
	}
	return ctx
}

func (d *zapDispatcherImpl) ensureZapAgentInstance(
	ctx context.Context,
	client ZapChatClient,
	tenantID, accountID, runtimeID int64,
	externalEnvironmentID string,
	profile *IdentityProfile,
	digitalEmployee *domagent.DigitalEmployee,
	agent *zapadapter.IdentityAgentContext,
) (*zapadapter.RuntimeIdentity, error) {
	if client == nil || profile == nil {
		return nil, errors.New("zap agent instance initialization dependencies missing")
	}
	tenantName := profile.TenantName
	if strings.TrimSpace(tenantName) == "" {
		tenantName = profile.TenantUUID
	}
	identity := zapSessionIdentityFromProfile(profile)
	user := &zapadapter.IdentityUserProfile{
		AccountUUID:   profile.AccountUUID,
		DisplayName:   profile.DisplayName,
		Email:         profile.Email,
		EmailVerified: strings.TrimSpace(profile.Email) != "",
		Phone:         profile.Phone,
		PhoneVerified: strings.TrimSpace(profile.Phone) != "",
		Username:      profile.Username,
	}
	var llm *zapadapter.LLMCredentials
	if d.llm != nil {
		resolved, err := d.llm.ResolveLLMCredentials(ctx, tenantID, accountID, runtimeID, digitalEmployee)
		if err != nil {
			return nil, err
		}
		llm = resolved
	}
	initialized, err := client.InitializeAgentInstance(ctx, &zapadapter.AgentInstanceInitializeRequest{
		Tenant: map[string]any{
			"tenant_id": profile.TenantUUID,
			"name":      tenantName,
			"status":    "active",
		},
		User:     user,
		Agent:    agent,
		Identity: identity,
		LLM:      llm,
		Metadata: zapadapter.MergeRuntimeEnvironmentMetadata(
			zapLLMContextEnvelopeForInstance(tenantID, accountID, runtimeID, digitalEmployee),
			externalEnvironmentID,
		),
	})
	if err != nil {
		return nil, err
	}
	status := strings.TrimSpace(initialized.MappingStatus)
	if status == "" {
		status = "matched"
	}
	if status == "conflict" || status == "pending" {
		return nil, fmt.Errorf("zap agent instance init returned %s", status)
	}
	runtimeIdentity := initialized.EffectiveRuntimeIdentity()
	if runtimeIdentity == nil || strings.TrimSpace(runtimeIdentity.UserID) == "" {
		return nil, errors.New("zap agent instance init returned empty runtime_identity.user_id")
	}
	runtimeIdentity.MappingStatus = status
	return runtimeIdentity, nil
}

// canonicalMapBlocks ZAP runtime 原始 blocks → Bus EMP canonical 形态。
//
// 仅做 type 改名 / 字段重命名, 不丢字段:
//   - action_bar → action
//   - approval_request → approval
//   - confirm 保持 confirm (HITL confirm 与 approval 的回调语义不同)
//   - citation → source
//   - artifact:<kind> → {type:"artifact", artifact_kind:<kind>, ...} (拆分复合 type)
//
// 其它 type 保持原样; finalize 内 EMPValidator.ValidateBlocks 兜底 fallback。
func canonicalMapBlocks(in []map[string]any) []map[string]any {
	if len(in) == 0 {
		return nil
	}
	out := make([]map[string]any, 0, len(in))
	for _, b := range in {
		mapped := canonicalMapOneBlock(b)
		if mapped != nil {
			out = append(out, mapped)
		}
	}
	return out
}

func cloneZapOutboundBlocks(in []map[string]any) []map[string]any {
	if len(in) == 0 {
		return nil
	}
	out := make([]map[string]any, 0, len(in))
	for _, b := range in {
		if b == nil {
			continue
		}
		cp := make(map[string]any, len(b))
		for k, v := range b {
			cp[k] = v
		}
		out = append(out, cp)
	}
	return out
}

func (s *impl) prepareZapRuntimeFileBlocks(ctx context.Context, accountID, tenantID int64, blocks []map[string]any) ([]map[string]any, error) {
	out := cloneZapOutboundBlocks(blocks)
	if len(out) == 0 {
		return nil, nil
	}
	var signer RuntimeAttachmentURLSigner
	if s != nil && s.attachments != nil {
		signer, _ = s.attachments.(RuntimeAttachmentURLSigner)
	}
	for _, block := range out {
		if block == nil {
			continue
		}
		kind := strings.ToLower(strings.TrimSpace(firstString(block, "type")))
		if kind != "file" && kind != "image" {
			continue
		}
		fileID := strings.TrimSpace(firstString(block, "file_id"))
		rawURL := strings.TrimSpace(firstString(block, "url", "download_url", "downloadUrl", "preview_url", "previewUrl"))
		if fileID == "" {
			fileID = zapMessageFileIDFromURL(rawURL)
		}
		if fileID == "" {
			if zapURLIsAbsoluteHTTP(rawURL) {
				continue
			}
			return nil, fmt.Errorf("zap runtime file block missing file_id")
		}
		if signer == nil {
			return nil, fmt.Errorf("zap runtime file signer not wired")
		}
		inline := kind == "image" || strings.Contains(strings.ToLower(rawURL), "/preview")
		signedURL, err := signer.ResolveRuntimeURL(ctx, accountID, tenantID, fileID, inline)
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(signedURL) == "" {
			return nil, fmt.Errorf("zap runtime file signer returned empty url")
		}
		block["url"] = signedURL
		if inline {
			block["preview_url"] = signedURL
		} else {
			block["download_url"] = signedURL
		}
		block["file_id"] = fileID
	}
	return out, nil
}

func zapURLIsAbsoluteHTTP(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

func zapMessageFileIDFromURL(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	for i := 0; i < len(parts)-1; i++ {
		if parts[i] == "message-files" && strings.TrimSpace(parts[i+1]) != "" {
			v, err := url.PathUnescape(parts[i+1])
			if err != nil {
				return parts[i+1]
			}
			return v
		}
	}
	return ""
}

func canonicalMapOneBlock(b map[string]any) map[string]any {
	if b == nil {
		return nil
	}
	t, _ := b["type"].(string)
	// 复制一份 (不原地改 runtime 给的 map, 避免 caller 误用)。
	cp := make(map[string]any, len(b))
	for k, v := range b {
		cp[k] = v
	}
	switch {
	case t == "action_bar":
		cp["type"] = "action"
	case t == "approval_request":
		cp["type"] = "approval"
	case t == "citation":
		cp["type"] = "source"
	case strings.HasPrefix(t, "artifact:"):
		kind := strings.TrimPrefix(t, "artifact:")
		cp["type"] = "artifact"
		if _, exists := cp["artifact_kind"]; !exists && kind != "" {
			cp["artifact_kind"] = kind
		}
	}
	return cp
}

// extractZapBlockDeltaText (Phase 2.5 增量流式): 从 ZAP block_delta payload 取增量文本 + block 类型。
//
// 兼容 ZAP-1.1 §4.5 两种现实形态:
//  1. 文本增量 (markdown/plain 推荐):  {"type":"markdown","text":"<delta>"} / {"text":"..."}
//  2. typed block delta (chart/form/...): 不可拼接成可见文本, 返回 ("", typed-kind), 由 caller ignore。
//
// 缺省: type 为空且只有 text → 视为 markdown。
// 返回 (text, kind):
//   - text="" + kind="": 空 delta, 调用方 ignore;
//   - text="" + kind 非 "markdown"/"plain": typed block 流, 调用方 ignore;
//   - text 非空 + kind 是 "" 或 "markdown" / "plain": 累积。
func extractZapBlockDeltaText(d map[string]any) (text, kind string) {
	if len(d) == 0 {
		return "", ""
	}
	if k, ok := d["type"].(string); ok {
		kind = strings.ToLower(strings.TrimSpace(k))
	}
	if t, ok := d["text"].(string); ok {
		text = t
	}
	return text, kind
}

// applyMarkdownDelta 把 runtime 给的"增量 text"或"snapshot text"规一化成累积 snapshot:
//   - 如果 newText 是 prefix-of-snapshot 或与 snapshot 相等 → 视为 snapshot 语义 (覆盖式), 取 newText 即可;
//   - 如果 newText 以当前 snapshot 为前缀 → 视为 snapshot 语义, 取 newText (后写为准);
//   - 否则视为增量, 拼到 snapshot 尾部。
//
// 这条规则与 OpenClaw v3 path 的 prefix-diff 同源 (见 openclaw_v3.go::emitDelta 注释), 让两条路径
// 对客户端发出的 EventMessageBlockDelta.Text 都是"累计快照"语义, 客户端无须区分 OpenClaw / ZAP。
func applyMarkdownDelta(snapshot, newText string) string {
	if newText == "" {
		return snapshot
	}
	if snapshot == "" {
		return newText
	}
	if strings.HasPrefix(newText, snapshot) {
		// snapshot 语义: runtime 给的是累计文本 (长度 >= 当前 snapshot)
		return newText
	}
	if strings.HasPrefix(snapshot, newText) {
		// runtime 给的是较短的"回退到某点" snapshot — 不缩短客户端可见文本, 保持当前 snapshot。
		return snapshot
	}
	// 增量语义: 拼到尾部
	return snapshot + newText
}

// reuseZapSessionID Stage 2: 从 conversation.metadata 取可复用的 zap_session_id。
//
// 复用条件 (全部满足才返回非空):
//   - conv.Metadata 含 zap_session_id, 是非空 string;
//   - 如果 zap_session_expires_at 是合法 RFC3339 时间, 必须 >now+30s (留 30s 安全 margin);
//   - 缺 expires_at 或 expires_at 解析失败 → 视为"乐观可复用" (best-effort, SendMessage 真失败时还有重试一次)。
//
// 旧实现仅 single-chat 使用; 但 zhiban-app 当前数字员工单聊可走 agent-direct/WuKong
// 双通道, conversation 可能是 room-backed。ZAP 群聊 RunAgentForConversation 仍在入口
// fail-closed, 因此这里按 metadata 是否存在决定复用, 不再用 RoomID 一刀切。
func reuseZapSessionID(conv *domconv.Conversation) string {
	if conv == nil {
		return ""
	}
	if len(conv.Metadata) == 0 {
		return ""
	}
	sid, _ := conv.Metadata["zap_session_id"].(string)
	sid = strings.TrimSpace(sid)
	if sid == "" {
		return ""
	}
	if raw, ok := conv.Metadata["zap_session_expires_at"].(string); ok {
		if exp, err := time.Parse(time.RFC3339, strings.TrimSpace(raw)); err == nil {
			if !exp.After(time.Now().Add(30 * time.Second)) {
				return ""
			}
		}
	}
	return sid
}

// persistZapSessionMetadata Stage 2: EnsureSession 成功后写白名单 metadata (best-effort)。
// 失败仅 Warn, 不阻断主流程 (token 反正没存; session_id 丢失下次会再 EnsureSession)。
func (s *impl) persistZapSessionMetadata(ctx context.Context, in ZapDispatchInput, sessionID, expiresAt string) {
	if in.Conversation == nil {
		return
	}
	if err := s.updateConversationZapMetadata(ctx, in.TenantID, in.AccountID, in.Conversation.ID, sessionID, expiresAt); err != nil {
		s.logger.Warn(ctx, "chat zap update conversation metadata failed",
			"stream_id", in.StreamID, "err", err.Error())
	}
}

// isZapSessionStale Stage 2: 判断 SendMessage 的错误是否暗示"session_id 已失效", 应重建。
// 命中 → 重新 EnsureSession 重试一次。其它错误 (transport / 5xx / decode) 直接 finalize failed, 不重试。
//
// 命中条件 (与 zapadapter.ChatAPIError 同源):
//   - HTTP 404 (session 不存在/过期, runtime 返 zap.session_not_found);
//   - HTTP 409 + code "session_cancelled" (上一次 cancel 后再发);
//   - 不命中 4xx (401/403/400 一般是装配错, 重试无用)。
func isZapSessionStale(err error) bool {
	if err == nil {
		return false
	}
	var ae *zapadapter.ChatAPIError
	if !errors.As(err, &ae) {
		return false
	}
	if ae.IsNotFound() {
		return true
	}
	if ae.IsCancelled() {
		return true
	}
	return false
}

// zapErrorCode 安全取 ChatAPIError.Code (无 token; 日志诊断用)。
func zapErrorCode(err error) string {
	var ae *zapadapter.ChatAPIError
	if errors.As(err, &ae) {
		return ae.Code
	}
	return ""
}

// publishZapTextDelta Phase 2.5: ZAP 累计 snapshot 流出客户端 SSE。
//
// 与 OpenClaw v3 path 一致:
//   - Kind = EventMessageBlockDelta
//   - Text = 累计 snapshot
//   - Blocks = [{type:"markdown", text:<snapshot>}] (与终态 completed 同 shape, 客户端可统一渲染)
//
// 不写 messages.blocks (DB 落库由 completed 终态走 finalize 一次性写入; 增量频率高, 不重复写 DB)。
// fanout publish 失败仅 Warn, 不打断流。
func (s *impl) publishZapTextDelta(ctx context.Context, in ZapDispatchInput, snapshot string) {
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
		s.logger.Warn(ctx, "chat zap publish block.delta failed",
			"stream_id", in.StreamID, "err", err.Error())
	}
}

// Round-8: 将 ZAP runtime 的 SSE tool_call / tool_result / reasoning 中间帧透传给
// chat fanout, 用与 OpenClaw v3 path **同款** StreamEvent 字段, 客户端复用现有
// EventMessageToolCall / EventMessageToolResult / EventMessageReasoning timeline UI。
//
// 注意:
//   - 不做语义改写 (tool_call_id / tool_name / tool_status / args / result 透传);
//   - 这三类都是中间帧, **不**改 stream 终态, **不**写 DB;
//   - fanout publish 失败仅 Warn, 与 publishZapTextDelta 同样不打断流;
//   - 这里**故意**用 stream 维度 (streamID + msgUUID) 参数列表, 让 Send / Respond
//     两条路径调同一个 helper, 不绕回 ZapDispatchInput / ZapRespondInput 二选一。
func (s *impl) publishZapTool(
	ctx context.Context,
	streamID string, accountID, tenantID int64,
	conversationUUID, roomUUID, msgUUID string,
	ev zapadapter.SSEEvent,
) {
	if ev.ToolCallID == "" {
		// 没有 tool_call_id 的 tool 事件无法关联 timeline 槽位, 静默丢弃。
		return
	}
	kind := EventMessageToolCall
	if ev.Kind == zapadapter.SSEToolResult {
		kind = EventMessageToolResult
	}
	se := StreamEvent{
		Kind:             kind,
		ConversationUUID: conversationUUID,
		RoomUUID:         roomUUID,
		MessageUUID:      msgUUID,
		ToolCallID:       ev.ToolCallID,
		ToolName:         ev.ToolName,
		ToolStatus:       ev.ToolStatus,
		ToolArgs:         ev.ToolArgs,
		ToolArgsDelta:    ev.ToolArgsDelta,
		ToolResult:       ev.ToolResult,
		ToolResultDelta:  ev.ToolResultDelta,
		Timestamp:        time.Now(),
	}
	if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, se); err != nil {
		s.logger.Warn(ctx, "chat zap publish tool event failed",
			"stream_id", streamID, "kind", string(kind), "tool_call_id", ev.ToolCallID, "err", err.Error())
	}
}

func (s *impl) publishZapReasoning(
	ctx context.Context,
	streamID string, accountID, tenantID int64,
	conversationUUID, roomUUID, msgUUID string,
	ev zapadapter.SSEEvent,
) {
	if ev.Reasoning == "" {
		return
	}
	se := StreamEvent{
		Kind:             EventMessageReasoning,
		ConversationUUID: conversationUUID,
		RoomUUID:         roomUUID,
		MessageUUID:      msgUUID,
		Reasoning:        ev.Reasoning,
		Timestamp:        time.Now(),
	}
	if err := s.fanout.Publish(ctx, streamID, accountID, tenantID, se); err != nil {
		s.logger.Warn(ctx, "chat zap publish reasoning failed",
			"stream_id", streamID, "err", err.Error())
	}
}

// sanitizedRuntimeFailureMessage 是未知 runtime failed 终态的固定安全文案。raw runtime
// error_message 可能含 URL / provider / internal token / stack trace, 不能原样进入客户端、
// messages.err_message 或日志。
const sanitizedRuntimeFailureMessage = "agent runtime returned an error"

// ErrCodeRuntimeUpstreamFailure 表示 runtime/LLM 已返回业务失败, 但不属于允许透出的
// 配置类错误。不要把它伪装成 protocol_unsupported, 否则排查会误判为 Bus/ZAP 协议装配错。
const ErrCodeRuntimeUpstreamFailure = "chat.runtime_upstream_failure"

// Only fixed product text is exposed, never the runtime-provided error body.
func deliverableRuntimeError(code string) (string, string) {
	switch strings.TrimSpace(code) {
	case "zap.approval_denied":
		return "chat.approval_denied", "你已拒绝本次操作，相关操作未执行。已生成的文件仍可查看。"
	case "zap.local_archive_failed":
		return "chat.local_archive_failed", "文件已生成，但云盘保存未完成，可先查看本机文件。"
	case "zap.deliverable_missing":
		return "chat.deliverable_missing", "未生成全部要求的文件。已验证的文件仍可查看。"
	case "zap.deliverable_content_mismatch":
		return "chat.deliverable_content_mismatch", "文件已生成，但内容或大小未满足交付要求。已验证的文件仍可查看。"
	case "zap.deliverable_verification_failed":
		return "chat.deliverable_verification_failed", "部分文件未通过交付校验。已验证的文件仍可查看。"
	default:
		return "", ""
	}
}

func sanitizeRuntimeErrorCode(code, msg string) string {
	if modelerror.Message(strings.TrimSpace(code), 0) != "" {
		return strings.TrimSpace(code)
	}
	if safeCode, _ := deliverableRuntimeError(code); safeCode != "" {
		return safeCode
	}
	code = strings.TrimSpace(code)
	msg = strings.TrimSpace(msg)
	switch {
	case code == "zap.local_model_unavailable":
		return "zap.local_model_unavailable"
	case code == "model.not_allowed" || strings.Contains(msg, "模型不被允许"):
		return "model.not_allowed"
	case code == "model.key_missing" || strings.Contains(msg, "API Key 未配置"):
		return "model.key_missing"
	default:
		return ErrCodeRuntimeUpstreamFailure
	}
}

func sanitizeRuntimeError(code, msg string) string {
	if safe := modelerror.Sanitize(strings.TrimSpace(code), strings.TrimSpace(msg)); safe != "" {
		return safe
	}
	if _, safeMessage := deliverableRuntimeError(code); safeMessage != "" {
		return safeMessage
	}
	code = strings.TrimSpace(code)
	msg = strings.TrimSpace(msg)
	switch {
	case code == "zap.local_model_unavailable":
		return "模型服务调用失败，请切换模型或检查模型服务配置。"
	case code == "model.not_allowed" || strings.Contains(msg, "模型不被允许"):
		return "模型不被允许"
	case code == "model.key_missing" || strings.Contains(msg, "API Key 未配置"):
		return "模型 API Key 未配置"
	default:
		return sanitizedRuntimeFailureMessage
	}
}

func zapSafeErr(err error, fallback string) string {
	if err == nil {
		return fallback
	}
	return err.Error()
}

// updateConversationZapMetadata 经白名单 helper 写 zap_session_id / zap_session_expires_at。
// 任何禁词 (session_token / runtime_api_key / authorization / bearer / secret) 出现在 key 或 value 字符串
// 都 fail-closed 返错 (不写入)。
func (s *impl) updateConversationZapMetadata(ctx context.Context, tenantID, accountID, conversationID int64, sessionID, expiresAt string) error {
	if conversationID <= 0 || strings.TrimSpace(sessionID) == "" {
		return nil
	}
	patch := map[string]any{
		"zap_session_id": sessionID,
	}
	if strings.TrimSpace(expiresAt) != "" {
		patch["zap_session_expires_at"] = expiresAt
	}
	if err := assertZapMetadataWhitelist(patch); err != nil {
		return err
	}
	if s.convs == nil {
		return errors.New("chat conversation repo not wired")
	}
	return s.convs.UpdateMetadataKeys(ctx, tenantID, accountID, conversationID, patch)
}

// assertZapMetadataWhitelist 写 metadata 前 fail-closed 守卫:
//   - keys 只允许 zapMetadataAllowedKeys 集合内
//   - keys 不能包含 zapMetadataForbiddenKeys 任一子串 (case-insensitive)
//   - 不再扫 value 内容 (生产 value 不可避免包含 "session" 字样, 例如 "session_id");
//     语义层守卫已经在 key 一层做完。
//
// 拒绝时直接返错; 不进行 silent 过滤, 防止"半写入" 留 stale 字段。
func assertZapMetadataWhitelist(patch map[string]any) error {
	for k := range patch {
		low := strings.ToLower(strings.TrimSpace(k))
		if !zapMetadataAllowedKeys[low] {
			return fmt.Errorf("zap metadata: key %q not in allowed whitelist", k)
		}
		for _, bad := range zapMetadataForbiddenSubstrings {
			if strings.Contains(low, bad) {
				return fmt.Errorf("zap metadata: key %q contains forbidden substring %q", k, bad)
			}
		}
	}
	return nil
}

// zapMetadataAllowedKeys Phase 2 MVP 允许写入 conversations.metadata 的 ZAP-related key。
//
// 任何不在表内的 key 都 fail-closed; 包括但不限于:
//
//	session_token / zap_session_token / runtime_api_key / authorization / bearer
var zapMetadataAllowedKeys = map[string]bool{
	"zap_session_id":         true,
	"zap_session_expires_at": true,
}

// zapMetadataForbiddenSubstrings key 命中任意一项即 fail-closed (双层防御; 允许 list 之外的 token-like
// 输入即便人为加进 allowed 也会被拒)。
var zapMetadataForbiddenSubstrings = []string{
	"token",
	"api_key",
	"apikey",
	"authorization",
	"bearer",
	"secret",
}

// zapTriggerSource maps room presence to the F24 trigger_source enum.
func zapTriggerSource(roomUUID string) string {
	if roomUUUIDTrim := strings.TrimSpace(roomUUID); roomUUUIDTrim != "" {
		return domagentrun.TriggerRoom
	}
	return domagentrun.TriggerChat
}

// zapToolStatusFailed interprets the Round-8 tool_status vocabulary; unknown
// values count as success so future statuses never inflate error counters.
func zapToolStatusFailed(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "error", "failed":
		return true
	}
	return false
}

func zapModelPlatformEnabled(meta map[string]any) bool {
	card, _ := meta["runtime_card"].(map[string]any)
	ext, _ := card["extensions"].(map[string]any)
	cap, _ := ext["conversation_model"].(map[string]any)
	ok, _ := cap["platform_binding"].(bool)
	return ok
}
