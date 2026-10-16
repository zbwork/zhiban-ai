// invoker_zap.go — A2A 真实 AgentInvoker (F09 §3.5 / ZAP-1.1 §12)。
//
// 支持三类被调方: external ZAP runtime、OpenClaw Gateway v3、Hermes chat
// stream。未注册适配器的 framework 仍 fail-closed 返 a2a.runtime_protocol_unsupported,
// **不**硬塞进 ZAP adapter。wire 契约见 docs/contracts/zhiban-agent-protocol-v1-1.md §12。
//
// 安全口径:
//   - Agent A 永远拿不到 Agent B 的 endpoint / runtime api key / child token —— 三者只在本文件
//     和 zapadapter 内流转, 不写 edge、不入 A 可见的 error_message。
//   - Bus → Agent B 出站鉴权 = runtime API key (Authorization); child st_ 走 body
//     bus_backchannel_token 字段 (与 runtime 自颁 session_token 语义严格区分)。
//   - B 侧任何错误对 A 归一化 (Result.ErrorMessage = a2a.* 稳定码); 原始错误只进
//     Result.InternalError → audit/log。
package a2a

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	hermesadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/hermes"
	openclawadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/gatewayws"
	zapadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
)

// 归一化错误码 (写入 edge.error_message, Agent A 可见; 均为稳定 a2a.* 码, 不含内部细节)。
const (
	errRuntimeNotBound      = "a2a.runtime_not_bound"
	errRuntimeUnsupported   = "a2a.runtime_protocol_unsupported"
	errRuntimeUnavailable   = "a2a.runtime_unavailable"
	errAgentKeyMissing      = "a2a.agent_key_missing"
	errAgentRuntimeError    = "a2a.agent_runtime_error"
	errInvokeTimeout        = "a2a.invoke_timeout"
	errInvokerMisconfigured = "a2a.invoker_misconfigured"
	errRuntimeEmptyResponse = "a2a.agent_runtime_empty_response"
	// errReentrantRuntimeUnsupported (Phase5): openclaw/hermes 同 pod 不支持并发重入。
	errReentrantRuntimeUnsupported = "a2a.reentrant_runtime_unsupported"
)

// A2ARuntimeEnv 是 invoker 需要的 runtime_environments 字段子集 (cmd/bus 适配 reporuntimeenv)。
type A2ARuntimeEnv struct {
	Framework             string // openclaw / hermes / zap
	HostingKind           string // clawmanager / k8s_native / external_endpoint
	PrimaryEndpoint       string
	APIKeySecretRef       string
	ExternalEnvironmentID string
	Status                string // active / disabled / archived
	Enabled               bool
	EgressAuditStatus     string // approved / ...
}

// RuntimeEnvSource 按 id 取被调方 runtime env 事实。
type RuntimeEnvSource interface {
	GetA2ARuntimeEnv(ctx context.Context, id int64) (*A2ARuntimeEnv, error)
}

// SecretResolver 解 api_key_secret_ref (env:// / value://) 为明文 token。
type SecretResolver interface {
	Resolve(ref string) (string, error)
}

// TenantUUIDLookup tenant_id → tenants.uuid (ZAP session body 只发 UUID, 不发内部 bigint)。
type TenantUUIDLookup interface {
	TenantUUID(ctx context.Context, tenantID int64) (string, error)
}

// AccountUUIDLookup account_id → accounts.uuid (ZAP session body 只发 UUID, 不发内部 bigint)。
type AccountUUIDLookup interface {
	AccountUUID(ctx context.Context, accountID int64) (string, error)
}

// ZapA2ASessionClient 是对 zapadapter.ChatClient 的窄接口 (单测注入 fake)。
type ZapA2ASessionClient interface {
	EnsureSession(ctx context.Context, req *zapadapter.CreateSessionRequest) (*zapadapter.CreateSessionResponse, error)
	SendMessage(ctx context.Context, sessionID string, req *zapadapter.SendMessageRequest, h zapadapter.SSEEventHandler) error
	Cancel(ctx context.Context, sessionID string) error
	Delete(ctx context.Context, sessionID string) error
}

// ZapA2AClientFactory 把 (baseURL, runtimeAPIKey) 构造成 client; nil → 默认 zapadapter.NewChatClient。
type ZapA2AClientFactory func(baseURL, token string) ZapA2ASessionClient

// OpenClawA2AEndpointResolver 解析 OpenClaw runtime endpoint。托管实例按
// (tenant_id, account_id, runtime_environment_id) 查 ready runtime_instances。
type OpenClawA2AEndpointResolver interface {
	Resolve(ctx context.Context, runtimeEnvID, tenantID, accountID int64, agentUUID *string) (openclawadapter.Endpoint, error)
}

// OpenClawA2AGatewayClient 是 gatewayws.Client 的窄接口。
type OpenClawA2AGatewayClient interface {
	CallStream(ctx context.Context, ep gatewayws.Endpoint, pre []gatewayws.Request, method string, params interface{}) (<-chan gatewayws.Frame, context.CancelFunc, error)
}

// HermesA2AEndpointResolver 解析 Hermes endpoint。
// agentUUID: 非 nil 时按该数字员工的专属 pod 解析 (BYOK); nil 走共享 pod。
type HermesA2AEndpointResolver interface {
	Resolve(ctx context.Context, runtimeEnvID, tenantID, accountID int64, agentUUID *string) (hermesadapter.HermesEndpoint, error)
}

type HermesA2AChatClient interface {
	ChatStream(ctx context.Context, req hermesadapter.ChatRequest, handler func(hermesadapter.StreamEvent) bool) error
}

type HermesA2AClientFactory func(timeout time.Duration) HermesA2AChatClient

// ZapAgentInvokerDeps 显式依赖。
type ZapAgentInvokerDeps struct {
	Envs          RuntimeEnvSource
	Secrets       SecretResolver
	Tenants       TenantUUIDLookup
	Accounts      AccountUUIDLookup
	ClientFactory ZapA2AClientFactory
	OpenClaw      OpenClawA2AEndpointResolver
	Gateway       OpenClawA2AGatewayClient
	Hermes        HermesA2AEndpointResolver
	HermesClient  HermesA2AClientFactory
	Logger        a2aLogger
	// CallTimeout 单次派发 (EnsureSession + SendMessage) 上限; 0 → 120s (F09 §3.5)。
	CallTimeout time.Duration
}

// ZapAgentInvoker 实现 AgentInvoker。
type ZapAgentInvoker struct {
	deps ZapAgentInvokerDeps

	mu     sync.Mutex
	active map[string]*activeA2AZapSession
	tasks  map[string]*activeA2ARuntimeTask
}

type activeA2AZapSession struct {
	client    ZapA2ASessionClient
	sessionID string
}

type activeA2ARuntimeTask struct {
	cancel      context.CancelFunc
	runtimeKind string
}

// NewZapAgentInvoker 构造; Envs/Secrets/Tenants 缺失 → panic (启动期发现)。
func NewZapAgentInvoker(d ZapAgentInvokerDeps) *ZapAgentInvoker {
	if d.Envs == nil {
		panic("a2a.NewZapAgentInvoker: Envs required")
	}
	if d.Secrets == nil {
		panic("a2a.NewZapAgentInvoker: Secrets required")
	}
	if d.Tenants == nil {
		panic("a2a.NewZapAgentInvoker: Tenants required")
	}
	if d.ClientFactory == nil {
		d.ClientFactory = func(baseURL, token string) ZapA2ASessionClient {
			return zapadapter.NewChatClient(baseURL, token)
		}
	}
	if d.Gateway == nil {
		d.Gateway = gatewayws.New()
	}
	if d.HermesClient == nil {
		d.HermesClient = func(timeout time.Duration) HermesA2AChatClient {
			return hermesadapter.NewChatClient(timeout)
		}
	}
	if d.CallTimeout <= 0 {
		d.CallTimeout = 120 * time.Second
	}
	return &ZapAgentInvoker{
		deps:   d,
		active: map[string]*activeA2AZapSession{},
		tasks:  map[string]*activeA2ARuntimeTask{},
	}
}

// failed 构造 fail-closed 结果: ErrorMessage = 归一化码 (A 可见), internal 只进审计/日志。
func failed(code, internal string) (AgentInvocationResult, error) {
	return AgentInvocationResult{
		Status:        doma2a.StatusFailed,
		ErrorMessage:  code,
		InternalError: internal,
	}, nil
}

// Invoke 派发一次 A2A 调用到 Agent B 的 external ZAP runtime。
//
// 约定: 业务/治理层失败一律返回 (Result{Status:failed, ErrorMessage:<a2a.* 码>}, nil),
// 不用 error 通道 —— caller (fireAgentInvoke) 的 err 分支同样会归一化, 这里保持单一出口。
func (z *ZapAgentInvoker) Invoke(ctx context.Context, in AgentInvocation) (AgentInvocationResult, error) {
	started := time.Now()
	to := in.ToAgent
	if to == nil {
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "to_agent_nil",
			"edge_id", shortA2AID(in.EdgeUUID),
		)
		return failed(errInvokerMisconfigured, "to_agent nil")
	}
	z.logInfo(ctx, "a2a.invoker.start",
		"edge_id", shortA2AID(in.EdgeUUID),
		"from_agent", agentLogFields(in.FromAgent),
		"to_agent", agentLogFields(to),
		"parent_account_id", in.ParentAccountID,
		"invoke_kind", string(in.InvokeKind),
		"payload", summarizeA2APayload(in.RequestPayload),
	)
	if to.RuntimeEnvironmentID == nil || *to.RuntimeEnvironmentID <= 0 {
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "runtime_not_bound",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeNotBound, "to_agent has no runtime_environment binding")
	}
	env, err := z.deps.Envs.GetA2ARuntimeEnv(ctx, *to.RuntimeEnvironmentID)
	if err != nil || env == nil {
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "runtime_env_lookup_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"runtime_env_id", *to.RuntimeEnvironmentID,
			"err", errString(err),
		)
		return failed(errRuntimeUnavailable, "runtime env lookup failed: "+errString(err))
	}
	z.logInfo(ctx, "a2a.invoker.env_resolved",
		"edge_id", shortA2AID(in.EdgeUUID),
		"runtime_env_id", *to.RuntimeEnvironmentID,
		"framework", env.Framework,
		"hosting_kind", env.HostingKind,
		"status", env.Status,
		"enabled", env.Enabled,
		"egress_audit_status", env.EgressAuditStatus,
	)
	if strings.TrimSpace(env.Status) != "active" || !env.Enabled {
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "runtime_env_inactive",
			"edge_id", shortA2AID(in.EdgeUUID),
			"framework", env.Framework,
			"hosting_kind", env.HostingKind,
			"status", env.Status,
			"enabled", env.Enabled,
		)
		return failed(errRuntimeUnavailable, "runtime env disabled or inactive")
	}
	if strings.TrimSpace(env.EgressAuditStatus) != "approved" {
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "runtime_egress_not_approved",
			"edge_id", shortA2AID(in.EdgeUUID),
			"framework", env.Framework,
			"egress_audit_status", env.EgressAuditStatus,
		)
		return failed(errRuntimeUnavailable, "runtime env egress not approved")
	}
	framework := strings.ToLower(strings.TrimSpace(env.Framework))
	hosting := strings.ToLower(strings.TrimSpace(env.HostingKind))
	var res AgentInvocationResult
	switch framework {
	case "zap", "dsh":
		if hosting != "external_endpoint" {
			z.logWarn(ctx, "a2a.invoker.reject",
				"reason", "zap_hosting_unsupported",
				"edge_id", shortA2AID(in.EdgeUUID),
				"framework", env.Framework,
				"hosting_kind", env.HostingKind,
			)
			return failed(errRuntimeUnsupported, "framework="+env.Framework+" hosting_kind="+env.HostingKind)
		}
		res, err = z.invokeZap(ctx, in, env)
	case "openclaw":
		res, err = z.invokeOpenClaw(ctx, in, env, hosting)
	case "hermes":
		res, err = z.invokeHermes(ctx, in, env, hosting)
	default:
		z.logWarn(ctx, "a2a.invoker.reject",
			"reason", "framework_unsupported",
			"edge_id", shortA2AID(in.EdgeUUID),
			"framework", env.Framework,
			"hosting_kind", env.HostingKind,
		)
		return failed(errRuntimeUnsupported, "framework="+env.Framework+" hosting_kind="+env.HostingKind)
	}
	z.logInfo(ctx, "a2a.invoker.finish",
		"edge_id", shortA2AID(in.EdgeUUID),
		"framework", framework,
		"hosting_kind", hosting,
		"status", string(res.Status),
		"error_code", res.ErrorMessage,
		"response", summarizeA2APayload(res.ResponsePayload),
		"elapsed_ms", int64(time.Since(started)/time.Millisecond),
	)
	return res, err
}

func (z *ZapAgentInvoker) invokeZap(ctx context.Context, in AgentInvocation, env *A2ARuntimeEnv) (AgentInvocationResult, error) {
	to := in.ToAgent
	if strings.TrimSpace(env.PrimaryEndpoint) == "" {
		z.logWarn(ctx, "a2a.invoker.zap.reject",
			"reason", "primary_endpoint_empty",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeUnavailable, "runtime env primary_endpoint empty")
	}
	// agent_key 权威字段 = digital_employees.metadata.agent_key; 不 fallback UUID (chat 同款纪律)。
	agentKey, _ := to.Metadata["agent_key"].(string)
	agentKey = strings.TrimSpace(agentKey)
	if agentKey == "" {
		z.logWarn(ctx, "a2a.invoker.zap.reject",
			"reason", "agent_key_missing",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errAgentKeyMissing, "to_agent metadata.agent_key empty")
	}
	apiKey, err := z.deps.Secrets.Resolve(env.APIKeySecretRef)
	if err != nil || strings.TrimSpace(apiKey) == "" {
		z.logWarn(ctx, "a2a.invoker.zap.reject",
			"reason", "runtime_api_key_resolve_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"err", errString(err),
		)
		return failed(errRuntimeUnavailable, "resolve runtime api key: "+errString(err))
	}
	tenantUUID, err := z.deps.Tenants.TenantUUID(ctx, to.TenantID)
	if err != nil || strings.TrimSpace(tenantUUID) == "" {
		z.logWarn(ctx, "a2a.invoker.zap.reject",
			"reason", "tenant_uuid_resolve_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"tenant_id", to.TenantID,
			"err", errString(err),
		)
		return failed(errRuntimeUnavailable, "resolve tenant uuid: "+errString(err))
	}
	accountUUID := ""
	if in.ParentAccountID > 0 {
		if z.deps.Accounts == nil {
			return failed(errRuntimeUnavailable, "account uuid resolver not wired")
		}
		accountUUID, err = z.deps.Accounts.AccountUUID(ctx, in.ParentAccountID)
		if err != nil || strings.TrimSpace(accountUUID) == "" {
			z.logWarn(ctx, "a2a.invoker.zap.reject",
				"reason", "account_uuid_resolve_failed",
				"edge_id", shortA2AID(in.EdgeUUID),
				"parent_account_id", in.ParentAccountID,
				"err", errString(err),
			)
			return failed(errRuntimeUnavailable, "resolve account uuid: "+errString(err))
		}
	}

	callCtx, cancel := context.WithTimeout(ctx, z.deps.CallTimeout)
	defer cancel()

	client := z.deps.ClientFactory(env.PrimaryEndpoint, apiKey)
	var initiator *zapadapter.SessionInitiator
	if in.FromAgent != nil {
		initiator = &zapadapter.SessionInitiator{
			Kind:       "agent",
			AgentUUID:  in.FromAgent.UUID,
			TenantUUID: tenantUUID,
		}
	}
	sess, err := client.EnsureSession(callCtx, &zapadapter.CreateSessionRequest{
		AgentKey: agentKey,
		Agent: &zapadapter.IdentityAgentContext{
			DigitalEmployeeUUID: strings.TrimSpace(to.UUID),
			AgentKey:            agentKey,
		},
		SessionKind: "a2a",
		User:        zapadapter.SessionUser{TenantUUID: tenantUUID, AccountUUID: accountUUID},
		ConversationContextHint: zapadapter.ConversationContextHint{
			TenantID:    tenantUUID,
			AccountID:   accountUUID,
			Purpose:     "a2a",
			A2AEdgeUUID: in.EdgeUUID,
		},
		Initiator:           initiator,
		BusBackchannelToken: in.ChildSessionToken,
		Metadata:            zapadapter.MergeRuntimeEnvironmentMetadata(nil, env.ExternalEnvironmentID),
	})
	if err != nil {
		z.logWarn(ctx, "a2a.invoker.zap.ensure_session_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"agent_key_set", agentKey != "",
			"err", errString(err),
		)
		return failed(normalizeZapCode(callCtx, err), "ensure session: "+errString(err))
	}
	z.logInfo(ctx, "a2a.invoker.zap.session_ready",
		"edge_id", shortA2AID(in.EdgeUUID),
		"session_id", shortA2AID(sess.SessionID),
		"to_agent", agentLogFields(to),
		"tenant_id", shortA2AID(tenantUUID),
		"user_id", shortA2AID(accountUUID),
	)
	z.registerActive(in.EdgeUUID, in.EdgeCreatedAt, client, sess.SessionID)
	defer z.unregisterActive(in.EdgeUUID, in.EdgeCreatedAt)
	// best-effort 清理; 与 SendMessage 生命周期解耦, 用独立短 ctx (callCtx 可能已超时)。
	defer func() {
		delCtx, delCancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer delCancel()
		_ = client.Delete(delCtx, sess.SessionID)
	}()

	msgReq := buildA2AMessage(in.RequestPayload)
	z.logInfo(ctx, "a2a.invoker.zap.send_message",
		"edge_id", shortA2AID(in.EdgeUUID),
		"session_id", shortA2AID(sess.SessionID),
		"to_agent", agentLogFields(to),
		"text", clipA2AText(msgReq.Text, 180),
		"text_len", len([]rune(msgReq.Text)),
		"raw_block_count", len(msgReq.RawBlocks),
	)
	var (
		completed *zapadapter.SSEEvent
		bFailed   *zapadapter.SSEEvent
		awaiting  *zapadapter.SSEEvent
	)
	err = client.SendMessage(callCtx, sess.SessionID, msgReq, func(ev zapadapter.SSEEvent) (bool, error) {
		switch ev.Kind {
		case zapadapter.SSEBlockDelta:
			publishZapStreamDelta(in.StreamSink, ev)
			return false, nil
		case zapadapter.SSEAwaitingUser:
			cp := ev
			awaiting = &cp
			return true, nil
		case zapadapter.SSECompleted:
			cp := ev
			completed = &cp
			return true, nil
		case zapadapter.SSEFailed, zapadapter.SSECancelled:
			cp := ev
			bFailed = &cp
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		z.logWarn(ctx, "a2a.invoker.zap.send_message_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"session_id", shortA2AID(sess.SessionID),
			"err", errString(err),
		)
		return failed(normalizeZapCode(callCtx, err), "send message: "+errString(err))
	}
	if bFailed != nil {
		z.logWarn(ctx, "a2a.invoker.zap.runtime_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"session_id", shortA2AID(sess.SessionID),
			"kind", string(bFailed.Kind),
			"error_code", bFailed.ErrorCode,
			"error_message", clipA2AText(bFailed.ErrorMessage, 160),
		)
		return failed(errAgentRuntimeError,
			"runtime message."+string(bFailed.Kind)+" code="+bFailed.ErrorCode+" msg="+bFailed.ErrorMessage)
	}
	if awaiting != nil {
		if res, ok := approvalRequiredResultFromBlocks(awaiting.Blocks, awaiting.AwaitingBlockID); ok {
			return res, nil
		}
		return failed(errAgentRuntimeError, "runtime message.awaiting_user without approval/form block")
	}
	if completed == nil {
		z.logWarn(ctx, "a2a.invoker.zap.empty_response",
			"edge_id", shortA2AID(in.EdgeUUID),
			"session_id", shortA2AID(sess.SessionID),
		)
		return failed(errRuntimeEmptyResponse, "sse ended without terminal event")
	}

	envelope := map[string]any{
		"kind":           "result",
		"message_blocks": completed.Blocks,
	}
	if completed.Usage != nil {
		envelope["usage"] = completed.Usage
	}
	raw, merr := json.Marshal(envelope)
	if merr != nil {
		return failed(errAgentRuntimeError, "marshal response envelope: "+merr.Error())
	}
	tokensIn, tokensOut := usageTokens(completed.Usage)
	z.logInfo(ctx, "a2a.invoker.zap.completed",
		"edge_id", shortA2AID(in.EdgeUUID),
		"session_id", shortA2AID(sess.SessionID),
		"block_count", len(completed.Blocks),
		"tokens_in", tokensIn,
		"tokens_out", tokensOut,
	)
	return AgentInvocationResult{
		Status:          doma2a.StatusDone,
		ResponsePayload: raw,
		TokensIn:        tokensIn,
		TokensOut:       tokensOut,
	}, nil
}

func (z *ZapAgentInvoker) logInfo(ctx context.Context, msg string, args ...any) {
	if z == nil || z.deps.Logger == nil {
		return
	}
	z.deps.Logger.Info(ctx, msg, args...)
}

func (z *ZapAgentInvoker) logWarn(ctx context.Context, msg string, args ...any) {
	if z == nil || z.deps.Logger == nil {
		return
	}
	z.deps.Logger.Warn(ctx, msg, args...)
}

func (z *ZapAgentInvoker) invokeOpenClaw(ctx context.Context, in AgentInvocation, _ *A2ARuntimeEnv, hosting string) (AgentInvocationResult, error) {
	to := in.ToAgent
	// Phase5: openclaw 同 pod 不支持并发; 候选命中链上活跃祖先 → 快速失败, 不等长超时。
	if in.CandidateInActiveChain {
		z.logWarn(ctx, "a2a.invoker.openclaw.reject",
			"reason", "reentrant_same_pod",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errReentrantRuntimeUnsupported, "openclaw reentrant same-pod invoke")
	}
	if z.deps.OpenClaw == nil || z.deps.Gateway == nil {
		z.logWarn(ctx, "a2a.invoker.openclaw.reject",
			"reason", "resolver_not_wired",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeUnsupported, "openclaw a2a resolver not wired")
	}
	if hosting != "external_endpoint" && in.ParentAccountID <= 0 {
		z.logWarn(ctx, "a2a.invoker.openclaw.reject",
			"reason", "missing_parent_account_scope",
			"edge_id", shortA2AID(in.EdgeUUID),
			"hosting_kind", hosting,
		)
		return failed(errRuntimeUnavailable, "openclaw hosted a2a requires parent account scope")
	}
	callCtx, cancel := context.WithTimeout(ctx, z.deps.CallTimeout)
	defer cancel()
	z.registerTask(in.EdgeUUID, in.EdgeCreatedAt, "openclaw_gateway", cancel)
	defer z.unregisterTask(in.EdgeUUID, in.EdgeCreatedAt)
	// agentUUID 固定传 nil: ADR-0037 BYOK 专属 pod 尚未接入被调方数字员工的解析
	// 路径, 见 docs/plans/22 Phase 1 任务组 3 / Phase 2。
	ep, err := z.deps.OpenClaw.Resolve(callCtx, *to.RuntimeEnvironmentID, to.TenantID, in.ParentAccountID, nil)
	if err != nil {
		z.logWarn(ctx, "a2a.invoker.openclaw.resolve_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"parent_account_id", in.ParentAccountID,
			"err", errString(err),
		)
		return failed(errRuntimeUnavailable, "resolve openclaw endpoint: "+errString(err))
	}
	if strings.TrimSpace(ep.URL) == "" {
		z.logWarn(ctx, "a2a.invoker.openclaw.reject",
			"reason", "endpoint_empty",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeUnavailable, "openclaw endpoint empty")
	}
	logicalSessionKey := "a2a:" + to.UUID + ":" + in.EdgeUUID
	sessionKey := "agent:" + to.UUID + ":" + logicalSessionKey
	prompt := a2aPromptFromPayload(in.RequestPayload)
	z.logInfo(ctx, "a2a.invoker.openclaw.send",
		"edge_id", shortA2AID(in.EdgeUUID),
		"to_agent", agentLogFields(to),
		"session_key", shortA2AID(sessionKey),
		"message", clipA2AText(prompt, 180),
		"message_len", len([]rune(prompt)),
	)
	pre := []gatewayws.Request{
		{Method: "sessions.create", Params: map[string]any{
			"key":     sessionKey,
			"agentId": to.UUID,
		}},
		{Method: "sessions.messages.subscribe", Params: map[string]any{
			"key": sessionKey,
		}},
	}
	frames, streamCancel, err := z.deps.Gateway.CallStream(callCtx, gatewayws.Endpoint{HTTPURL: ep.URL, Bearer: ep.Bearer}, pre, "chat.send", map[string]any{
		"sessionKey":     sessionKey,
		"message":        prompt,
		"idempotencyKey": a2aIdempotencyKey(in.EdgeUUID),
	})
	if err != nil {
		z.logWarn(ctx, "a2a.invoker.openclaw.send_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"err", errString(err),
		)
		return failed(normalizeZapCode(callCtx, err), "openclaw chat.send: "+errString(err))
	}
	defer streamCancel()
	var snapshot string
	for {
		select {
		case <-callCtx.Done():
			z.logWarn(ctx, "a2a.invoker.openclaw.timeout",
				"edge_id", shortA2AID(in.EdgeUUID),
				"snapshot_len", len([]rune(snapshot)),
			)
			return failed(errInvokeTimeout, "openclaw invoke timeout")
		case f, ok := <-frames:
			if !ok {
				if strings.TrimSpace(snapshot) == "" {
					z.logWarn(ctx, "a2a.invoker.openclaw.empty_response",
						"edge_id", shortA2AID(in.EdgeUUID),
					)
					return failed(errRuntimeEmptyResponse, "openclaw frames closed without assistant text")
				}
				z.logInfo(ctx, "a2a.invoker.openclaw.completed",
					"edge_id", shortA2AID(in.EdgeUUID),
					"response", clipA2AText(snapshot, 180),
					"response_len", len([]rune(snapshot)),
				)
				return resultEnvelopeFromText(snapshot)
			}
			if f.Reply {
				if !f.OK {
					z.logWarn(ctx, "a2a.invoker.openclaw.rpc_failed",
						"edge_id", shortA2AID(in.EdgeUUID),
						"error", clipA2AText(string(f.Error), 160),
					)
					return failed(errAgentRuntimeError, "openclaw rpc failed: "+string(f.Error))
				}
				continue
			}
			if f.Event == "agent" || f.Event == "session.message" {
				if key := extractA2AOpenClawSessionKey(f.Payload); key != "" && !matchA2AOpenClawSessionKey(key, sessionKey) {
					continue
				}
			}
			if f.Event != "agent" {
				continue
			}
			kind, text, phase := parseA2AOpenClawAgentFrame(f.Payload)
			if kind == "assistant" && text != "" {
				snapshot = text
				publishTextStreamDelta(in.StreamSink, text)
				continue
			}
			if kind == "lifecycle" {
				switch phase {
				case "end":
					if strings.TrimSpace(snapshot) == "" {
						z.logWarn(ctx, "a2a.invoker.openclaw.empty_response",
							"edge_id", shortA2AID(in.EdgeUUID),
							"phase", "end",
						)
						return failed(errRuntimeEmptyResponse, "openclaw lifecycle end without assistant text")
					}
					z.logInfo(ctx, "a2a.invoker.openclaw.completed",
						"edge_id", shortA2AID(in.EdgeUUID),
						"response", clipA2AText(snapshot, 180),
						"response_len", len([]rune(snapshot)),
					)
					return resultEnvelopeFromText(snapshot)
				case "error":
					z.logWarn(ctx, "a2a.invoker.openclaw.lifecycle_error",
						"edge_id", shortA2AID(in.EdgeUUID),
					)
					return failed(errAgentRuntimeError, "openclaw lifecycle error")
				}
			}
		}
	}
}

func (z *ZapAgentInvoker) invokeHermes(ctx context.Context, in AgentInvocation, _ *A2ARuntimeEnv, hosting string) (AgentInvocationResult, error) {
	to := in.ToAgent
	// Phase5: hermes 同 pod 不支持并发; 候选命中链上活跃祖先 → 快速失败, 不等长超时。
	if in.CandidateInActiveChain {
		z.logWarn(ctx, "a2a.invoker.hermes.reject",
			"reason", "reentrant_same_pod",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errReentrantRuntimeUnsupported, "hermes reentrant same-pod invoke")
	}
	if z.deps.Hermes == nil || z.deps.HermesClient == nil {
		z.logWarn(ctx, "a2a.invoker.hermes.reject",
			"reason", "resolver_not_wired",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeUnsupported, "hermes a2a resolver not wired")
	}
	if hosting != "external_endpoint" && in.ParentAccountID <= 0 {
		z.logWarn(ctx, "a2a.invoker.hermes.reject",
			"reason", "missing_parent_account_scope",
			"edge_id", shortA2AID(in.EdgeUUID),
			"hosting_kind", hosting,
		)
		return failed(errRuntimeUnavailable, "hermes hosted a2a requires parent account scope")
	}
	callCtx, cancel := context.WithTimeout(ctx, z.deps.CallTimeout)
	defer cancel()
	z.registerTask(in.EdgeUUID, in.EdgeCreatedAt, "hermes_http", cancel)
	defer z.unregisterTask(in.EdgeUUID, in.EdgeCreatedAt)
	// BYOK 数字员工 (A2A 被调方) 有专属 pod, 必须按 agentUUID 解析, 否则会解析到共享 pod。
	var hermesAgentUUID *string
	if to.ModelSource == "byok" {
		hermesAgentUUID = &to.UUID
	}
	ep, err := z.deps.Hermes.Resolve(callCtx, *to.RuntimeEnvironmentID, to.TenantID, in.ParentAccountID, hermesAgentUUID)
	if err != nil {
		z.logWarn(ctx, "a2a.invoker.hermes.resolve_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"parent_account_id", in.ParentAccountID,
			"err", errString(err),
		)
		return failed(errRuntimeUnavailable, "resolve hermes endpoint: "+errString(err))
	}
	sessionKey := "a2a:" + to.UUID + ":" + in.EdgeUUID
	prompt := a2aPromptFromPayload(in.RequestPayload)
	messages := make([]hermesadapter.ChatMessage, 0, 2)
	sys := strings.TrimSpace(to.Intro)
	if sys == "" {
		sys = strings.TrimSpace(to.Description)
	}
	if sys != "" {
		messages = append(messages, hermesadapter.ChatMessage{Role: "system", Content: sys})
	}
	messages = append(messages, hermesadapter.ChatMessage{Role: "user", Content: prompt})
	z.logInfo(ctx, "a2a.invoker.hermes.send",
		"edge_id", shortA2AID(in.EdgeUUID),
		"to_agent", agentLogFields(to),
		"session_key", shortA2AID(sessionKey),
		"model", strings.TrimSpace(to.ModelPrimary),
		"message_count", len(messages),
		"user_message", clipA2AText(prompt, 180),
		"user_message_len", len([]rune(prompt)),
	)
	var (
		snapshot  string
		streamErr error
	)
	err = z.deps.HermesClient(z.deps.CallTimeout).ChatStream(callCtx, hermesadapter.ChatRequest{
		Endpoint:   ep.URL,
		APIKey:     ep.Bearer,
		Model:      strings.TrimSpace(to.ModelPrimary),
		Messages:   messages,
		SessionKey: sessionKey,
	}, func(ev hermesadapter.StreamEvent) bool {
		switch ev.Type {
		case "delta":
			snapshot += ev.Delta
			publishTextStreamDelta(in.StreamSink, ev.Delta)
			if ev.FinishReason != "" {
				return true
			}
		case "done":
			return true
		case "error":
			streamErr = ev.Err
			return true
		}
		return false
	})
	if err != nil {
		streamErr = err
	}
	if streamErr != nil {
		z.logWarn(ctx, "a2a.invoker.hermes.stream_failed",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
			"err", errString(streamErr),
		)
		return failed(normalizeZapCode(callCtx, streamErr), "hermes chat stream: "+errString(streamErr))
	}
	if strings.TrimSpace(snapshot) == "" {
		z.logWarn(ctx, "a2a.invoker.hermes.empty_response",
			"edge_id", shortA2AID(in.EdgeUUID),
			"to_agent", agentLogFields(to),
		)
		return failed(errRuntimeEmptyResponse, "hermes empty response")
	}
	z.logInfo(ctx, "a2a.invoker.hermes.completed",
		"edge_id", shortA2AID(in.EdgeUUID),
		"to_agent", agentLogFields(to),
		"response", clipA2AText(snapshot, 180),
		"response_len", len([]rune(snapshot)),
	)
	return resultEnvelopeFromText(snapshot)
}

// Cancel best-effort 投递 external ZAP runtime cancel。仅同进程已建立 session 的运行中 edge
// 能命中; 未命中表示 Bus 侧已取消但 runtime 可能仍在执行, 由 audit 记录 cancel_delivered=false。
func (z *ZapAgentInvoker) Cancel(ctx context.Context, in AgentCancellation) (AgentCancellationResult, error) {
	if z == nil {
		return AgentCancellationResult{Delivered: false, RuntimeKind: "zap_external", ErrorMessage: "a2a.cancel_best_effort"}, nil
	}
	sess := z.popActive(in.EdgeUUID, in.EdgeCreatedAt)
	if sess == nil {
		task := z.popTask(in.EdgeUUID, in.EdgeCreatedAt)
		if task == nil {
			return AgentCancellationResult{Delivered: false, RuntimeKind: "unknown", ErrorMessage: "a2a.cancel_best_effort"}, nil
		}
		task.cancel()
		return AgentCancellationResult{Delivered: true, RuntimeKind: task.runtimeKind}, nil
	}
	if err := sess.client.Cancel(ctx, sess.sessionID); err != nil {
		return AgentCancellationResult{
			Delivered:     false,
			RuntimeKind:   "zap_external",
			ErrorMessage:  "a2a.cancel_best_effort",
			InternalError: errString(err),
		}, nil
	}
	return AgentCancellationResult{Delivered: true, RuntimeKind: "zap_external"}, nil
}

func (z *ZapAgentInvoker) registerActive(edgeUUID string, edgeCreatedAt time.Time, client ZapA2ASessionClient, sessionID string) {
	if z == nil || strings.TrimSpace(edgeUUID) == "" || strings.TrimSpace(sessionID) == "" || client == nil {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.active == nil {
		z.active = map[string]*activeA2AZapSession{}
	}
	z.active[activeA2AKey(edgeUUID, edgeCreatedAt)] = &activeA2AZapSession{client: client, sessionID: sessionID}
}

func (z *ZapAgentInvoker) unregisterActive(edgeUUID string, edgeCreatedAt time.Time) {
	if z == nil || strings.TrimSpace(edgeUUID) == "" {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	delete(z.active, activeA2AKey(edgeUUID, edgeCreatedAt))
}

func (z *ZapAgentInvoker) popActive(edgeUUID string, edgeCreatedAt time.Time) *activeA2AZapSession {
	if z == nil || strings.TrimSpace(edgeUUID) == "" {
		return nil
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	key := activeA2AKey(edgeUUID, edgeCreatedAt)
	sess := z.active[key]
	if sess != nil {
		delete(z.active, key)
	}
	return sess
}

func (z *ZapAgentInvoker) registerTask(edgeUUID string, edgeCreatedAt time.Time, runtimeKind string, cancel context.CancelFunc) {
	if z == nil || strings.TrimSpace(edgeUUID) == "" || cancel == nil {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.tasks == nil {
		z.tasks = map[string]*activeA2ARuntimeTask{}
	}
	z.tasks[activeA2AKey(edgeUUID, edgeCreatedAt)] = &activeA2ARuntimeTask{cancel: cancel, runtimeKind: runtimeKind}
}

func (z *ZapAgentInvoker) unregisterTask(edgeUUID string, edgeCreatedAt time.Time) {
	if z == nil || strings.TrimSpace(edgeUUID) == "" {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	delete(z.tasks, activeA2AKey(edgeUUID, edgeCreatedAt))
}

func (z *ZapAgentInvoker) popTask(edgeUUID string, edgeCreatedAt time.Time) *activeA2ARuntimeTask {
	if z == nil || strings.TrimSpace(edgeUUID) == "" {
		return nil
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	key := activeA2AKey(edgeUUID, edgeCreatedAt)
	task := z.tasks[key]
	if task != nil {
		delete(z.tasks, key)
	}
	return task
}

func activeA2AKey(edgeUUID string, edgeCreatedAt time.Time) string {
	return edgeUUID + "|" + edgeCreatedAt.UTC().Format(time.RFC3339Nano)
}

// buildA2AMessage 把 request_payload (原文) 映射为 ZAP messages body (契约 §12.2):
//   - F09 §3.5 约定形状 {user_text, context_blocks} → text + RawBlocks;
//   - 其余任意 JSON → 压缩为 text (JSON 字符串), runtime 自行解析。
func buildA2AMessage(payload []byte) *zapadapter.SendMessageRequest {
	req := &zapadapter.SendMessageRequest{Role: "user"}
	if approvalBlock, ok := a2aApprovalResponseBlock(payload); ok {
		req.Text = "A2A approval approved"
		req.RawBlocks = []map[string]any{approvalBlock}
		return req
	}
	var shaped struct {
		UserText      string           `json:"user_text"`
		ContextBlocks []map[string]any `json:"context_blocks"`
	}
	if len(payload) > 0 && json.Unmarshal(payload, &shaped) == nil &&
		(strings.TrimSpace(shaped.UserText) != "" || len(shaped.ContextBlocks) > 0) {
		req.Text = shaped.UserText
		req.RawBlocks = shaped.ContextBlocks
		return req
	}
	text := strings.TrimSpace(string(payload))
	if text == "" {
		text = "{}"
	}
	req.Text = text
	return req
}

func a2aApprovalResponseBlock(payload []byte) (map[string]any, bool) {
	var shaped struct {
		Approval struct {
			ApprovalRequestUUID string         `json:"approval_request_id"`
			Status              string         `json:"status"`
			Result              map[string]any `json:"result"`
		} `json:"approval"`
	}
	if len(payload) == 0 || json.Unmarshal(payload, &shaped) != nil {
		return nil, false
	}
	if strings.TrimSpace(shaped.Approval.ApprovalRequestUUID) == "" || strings.TrimSpace(shaped.Approval.Status) != "approved" {
		return nil, false
	}
	result := shaped.Approval.Result
	decision := "approve"
	if v, ok := result["approved"].(bool); ok && !v {
		decision = "reject"
	}
	block := map[string]any{
		"type":                   "approval_response",
		"decision":               decision,
		"approval_request_id":    shaped.Approval.ApprovalRequestUUID,
		"in_reply_to_message_id": shaped.Approval.ApprovalRequestUUID,
	}
	if reason := firstNonEmptyMapString(result, "reason", "comment"); reason != "" {
		block["reason"] = reason
	}
	return block, true
}

func firstNonEmptyMapString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if v := mapString(m, key); v != "" {
			return v
		}
	}
	return ""
}

func a2aPromptFromPayload(payload []byte) string {
	var shaped struct {
		UserText      string           `json:"user_text"`
		ContextBlocks []map[string]any `json:"context_blocks"`
	}
	if len(payload) > 0 && json.Unmarshal(payload, &shaped) == nil &&
		(strings.TrimSpace(shaped.UserText) != "" || len(shaped.ContextBlocks) > 0) {
		if len(shaped.ContextBlocks) == 0 {
			return strings.TrimSpace(shaped.UserText)
		}
		raw, _ := json.Marshal(shaped.ContextBlocks)
		return strings.TrimSpace(shaped.UserText) + "\n\n上下文:\n" + string(raw)
	}
	text := strings.TrimSpace(string(payload))
	if text == "" {
		return "{}"
	}
	return text
}

func resultEnvelopeFromText(text string) (AgentInvocationResult, error) {
	raw, err := json.Marshal(map[string]any{
		"kind": "result",
		"message_blocks": []map[string]any{{
			"type": "markdown",
			"text": text,
		}},
	})
	if err != nil {
		return failed(errAgentRuntimeError, "marshal text response envelope: "+err.Error())
	}
	return AgentInvocationResult{Status: doma2a.StatusDone, ResponsePayload: raw}, nil
}

func approvalRequiredResultFromBlocks(blocks []map[string]any, awaitingBlockID string) (AgentInvocationResult, bool) {
	block, ok := firstApprovalBlock(blocks)
	if !ok {
		return AgentInvocationResult{}, false
	}
	return AgentInvocationResult{
		Status:             doma2a.StatusAwaitingApproval,
		ApprovalRequired:   true,
		ApprovalFormSchema: runtimeApprovalFormSchema(block, awaitingBlockID),
		ApprovalBlocks:     []map[string]any{cloneMap(block)},
		ErrorMessage:       "a2a.awaiting_approval",
	}, true
}

func firstApprovalBlock(blocks []map[string]any) (map[string]any, bool) {
	for _, block := range blocks {
		t := strings.ToLower(strings.TrimSpace(mapString(block, "type")))
		if t == "approval" || t == "form" {
			return block, true
		}
	}
	return nil, false
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func runtimeApprovalFormSchema(block map[string]any, awaitingBlockID string) []byte {
	for _, key := range []string{"schema", "form_schema"} {
		if raw, ok := marshalJSONField(block[key]); ok {
			return raw
		}
	}
	title := mapString(block, "title")
	if title == "" {
		title = "A2A 协作审批"
	}
	description := mapString(block, "description")
	if description == "" {
		description = mapString(block, "text")
	}
	if description == "" {
		description = "被调数字员工需要人工确认后才能继续处理本次协作请求。"
	}
	form := map[string]any{
		"type":               "object",
		"title":              title,
		"description":        description,
		"runtime_block_type": mapString(block, "type"),
		"awaiting_block_id":  awaitingBlockID,
		"properties": map[string]any{
			"approved": map[string]any{"type": "boolean", "title": "同意协作"},
			"comment":  map[string]any{"type": "string", "title": "审批说明"},
		},
		"required": []string{"approved"},
	}
	raw, _ := json.Marshal(form)
	return raw
}

func marshalJSONField(v any) ([]byte, bool) {
	if v == nil {
		return nil, false
	}
	switch t := v.(type) {
	case map[string]any, []any:
		raw, err := json.Marshal(t)
		return raw, err == nil && len(raw) > 0
	case json.RawMessage:
		if json.Valid(t) {
			return t, true
		}
	case string:
		s := strings.TrimSpace(t)
		if s != "" && json.Valid([]byte(s)) {
			return []byte(s), true
		}
	}
	return nil, false
}

func mapString(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case fmt.Stringer:
		return strings.TrimSpace(t.String())
	default:
		return strings.TrimSpace(fmt.Sprint(t))
	}
}

func publishZapStreamDelta(sink func(A2AStreamEvent), ev zapadapter.SSEEvent) {
	if sink == nil {
		return
	}
	delta := ""
	if ev.BlockDelta != nil {
		if s, ok := ev.BlockDelta["text"].(string); ok {
			delta = s
		}
	}
	sink(A2AStreamEvent{
		Event:      "a2a.delta",
		Delta:      delta,
		BlockDelta: ev.BlockDelta,
	})
}

func publishTextStreamDelta(sink func(A2AStreamEvent), delta string) {
	if sink == nil || strings.TrimSpace(delta) == "" {
		return
	}
	sink(A2AStreamEvent{Event: "a2a.delta", Delta: delta})
}

func a2aIdempotencyKey(edgeUUID string) string {
	raw := strings.TrimSpace(edgeUUID)
	if raw == "" {
		raw = time.Now().UTC().Format(time.RFC3339Nano)
	}
	sum := sha1.Sum([]byte("a2a:" + raw))
	return "idmp-" + hex.EncodeToString(sum[:])
}

type a2aOpenClawAgentFrame struct {
	Stream     string          `json:"stream"`
	SessionKey string          `json:"sessionKey"`
	Data       json.RawMessage `json:"data"`
}

type a2aOpenClawAgentData struct {
	Text       string `json:"text"`
	Delta      string `json:"delta"`
	Phase      string `json:"phase"`
	SessionKey string `json:"sessionKey"`
}

func parseA2AOpenClawAgentFrame(payload []byte) (stream string, snapshot string, phase string) {
	var p a2aOpenClawAgentFrame
	if len(payload) == 0 || json.Unmarshal(payload, &p) != nil {
		return "", "", ""
	}
	stream = p.Stream
	if len(p.Data) == 0 {
		return stream, "", ""
	}
	var d a2aOpenClawAgentData
	if json.Unmarshal(p.Data, &d) != nil {
		return stream, "", ""
	}
	switch stream {
	case "assistant":
		if d.Text != "" {
			snapshot = d.Text
		} else {
			snapshot = d.Delta
		}
	case "lifecycle":
		phase = d.Phase
	}
	return stream, snapshot, phase
}

func extractA2AOpenClawSessionKey(payload []byte) string {
	var p a2aOpenClawAgentFrame
	if len(payload) == 0 || json.Unmarshal(payload, &p) != nil {
		return ""
	}
	if strings.TrimSpace(p.SessionKey) != "" {
		return strings.TrimSpace(p.SessionKey)
	}
	if len(p.Data) == 0 {
		return ""
	}
	var d a2aOpenClawAgentData
	if json.Unmarshal(p.Data, &d) != nil {
		return ""
	}
	return strings.TrimSpace(d.SessionKey)
}

func matchA2AOpenClawSessionKey(actual, expected string) bool {
	actual = strings.TrimSpace(actual)
	expected = strings.TrimSpace(expected)
	if actual == "" || expected == "" {
		return false
	}
	return actual == expected
}

// normalizeZapCode HTTP/SSE 层错误 → 归一化码: 超时单列, 其余统一 agent_runtime_error。
func normalizeZapCode(ctx context.Context, err error) string {
	if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) {
		return errInvokeTimeout
	}
	return errAgentRuntimeError
}

// usageTokens 容错解析 usage 计量 (runtime 命名差异: tokens_in/out 或 input/output_tokens)。
func usageTokens(usage map[string]any) (int32, int32) {
	get := func(keys ...string) int32 {
		for _, k := range keys {
			if v, ok := usage[k]; ok {
				switch n := v.(type) {
				case float64:
					return int32(n)
				case int:
					return int32(n)
				}
			}
		}
		return 0
	}
	if usage == nil {
		return 0, 0
	}
	return get("tokens_in", "input_tokens"), get("tokens_out", "output_tokens")
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	sanitized, _ := sanitizeA2ADispatchString(fmt.Sprint(err))
	return sanitized
}
