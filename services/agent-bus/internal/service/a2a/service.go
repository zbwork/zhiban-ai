package a2a

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	domapproval "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2aapproval"
	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	domorch "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orchestration"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/metrics"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Service F09 §3.5 / §4.7 A2A invoke 主入口.
type Service struct {
	deps            Deps
	streamRedactMu  sync.Mutex
	streamRedactors map[string]*a2aStreamDeltaRedactor
}

type a2aLogger interface {
	Info(ctx context.Context, msg string, args ...any)
	Warn(ctx context.Context, msg string, args ...any)
}

// AgentLookup 是 svca2a 用到的最小 Agent 仓储能力 (interface segregation).
// 真实实现复用 internal/repository/postgres/agent.Repo, 测试用 fake.
type AgentLookup interface {
	GetByID(ctx context.Context, id int64) (*domagent.DigitalEmployee, error)
	GetByUUID(ctx context.Context, uuid string) (*domagent.DigitalEmployee, error)
}

// RoomLookup 是 svca2a 解析 room_uuid 所需的最小 room 仓储能力。
type RoomLookup interface {
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*domroom.Room, error)
}

// Deps 显式依赖 (无单例 / 无全局).
type Deps struct {
	Edges                  doma2a.Repository
	Orchestrations         domorch.Repository
	Agents                 AgentLookup
	Rooms                  RoomLookup
	CapabilityRepo         CapabilityRepo
	SessionDeriver         SessionDeriver
	Quota                  QuotaChecker
	Cycle                  CycleDetector
	Audit                  domaudit.Store         // 可选; nil = skip audit
	AgentInvoker           AgentInvoker           // 可选; nil = stub (edge → status=failed reason=invoker_not_wired)
	Discover               DiscoverSource         // 可选 (A2A v1b); nil = Discover 返 500 not wired
	DiscoverRanker         DiscoverRanker         // 可选; query 非空时在已授权候选内做语义重排, 失败降级到确定性排序
	DiscoverSemantic       SemanticDiscoverSource // 可选; query 首屏 pgvector/ANN 召回候选, 仍需 Go 侧 whitelist/tags/mode 过滤
	DiscoverEmbedder       model.Embedder         // 可选; DiscoverSemantic 的 query embedding provider
	DiscoverEmbeddingModel string
	DiscoverEmbeddingDims  int
	StreamHub              A2AStreamHub   // 可选; nil = 进程内 stream hub
	StreamStore            A2AStreamStore // 可选; nil = 仅进程内 stream, 无重启/跨节点续接
	Approvals              domapproval.Repository
	ChatTimeline           ChatTimelinePublisher // 可选; 将 A2A invoke 投影到当前聊天执行过程
	RunHooks               RunStepNotifier       // 可选; F24 运行轨迹: 边终态时收敛调用方 run 的 a2a_invoke step
	Logger                 a2aLogger             // 可选; 只记录低敏链路诊断字段, 不记录 token/endpoint/raw payload
	Now                    func() time.Time
	// Governance Phase5 长链路预算治理参数 (cmd 从 config.A2A.Governance 映射; 零值在 New() 补默认)。
	Governance GovernanceConfig
}

// GovernanceConfig Phase5 长链路预算治理参数 (§12.4.1)。零值字段由 New() 补默认。
type GovernanceConfig struct {
	MaxDepth              int           // 默认 5; 链路深度硬上限
	ChainMaxCalls         int           // 默认 20; 同一 root chain 总调用数
	ChainTimeout          time.Duration // 默认 10min; 同一 root chain 墙钟上限
	RepeatedCallHardLimit int           // 默认 0 = 只 warn/计数; >0 时同指纹到阈值硬拒
}

// CapabilityRepo 提供 from_agent 是否有 a2a_invoke binding 的查询.
//
// 接口最小; 单测可塞 fake. 真实实现在 internal/repository/postgres/a2a/capability.go (本 PR 提供).
type CapabilityRepo interface {
	HasA2AInvokeCapability(ctx context.Context, agentID int64) (bool, error)
}

// SessionDeriver 是 F01 §3.6.3 IssueDerivedSessionToken 的最小接口.
// 实际实现见 svcagentsdk.Service.
type SessionDeriver interface {
	IssueDerivedSessionToken(ctx context.Context, parentSessionTokenID int64, targetAgentID int64, capabilities []string, ttl time.Duration) (*domagentsdk.SessionToken, string, error)
}

// AgentInvoker 是"调 Agent B ZAP endpoint" 的抽象, 给 PR5 留 stub, PR6 接真实 HTTP adapter.
//
// 实现要点 (PR6):
//   - 反查 to_agent.runtime_environment_id → runtime_environments.endpoint_url + api_key_secret_ref
//   - POST <endpoint>/zap/v1/sessions/{session_id}/messages 带 Bearer <child_session_token_plain>
//   - 把 Agent 端响应 ({status, tokens_in/out, response_payload}) 写回 edge.UpdateStatus
type AgentInvoker interface {
	Invoke(ctx context.Context, in AgentInvocation) (AgentInvocationResult, error)
	Cancel(ctx context.Context, in AgentCancellation) (AgentCancellationResult, error)
}

// AgentInvocation 是 AgentInvoker.Invoke 入参.
type AgentInvocation struct {
	EdgeUUID      string
	EdgeCreatedAt time.Time
	// ParentAccountID 是 parent session token 绑定账号; 托管 OpenClaw/Hermes A2A 用它解析
	// account-scoped ready runtime instance。0 = 无账号上下文, 托管 runtime fail-closed。
	ParentAccountID int64
	// FromAgent 发起方 (v1a: 用于 ZAP session body 的 initiator 只读事实; 不下发任何凭证)。
	FromAgent           *domagent.DigitalEmployee
	ToAgent             *domagent.DigitalEmployee
	ChildSessionToken   string // plaintext, 仅传给 Agent B 一次性使用
	ChildSessionExpires time.Time
	// RequestPayload 传输用**原文** (F09 §4.7.4 redaction 只作用于入库副本, 不能破坏 B 的执行输入;
	// plans/2026-07-06 §13.4)。edge 落库仍是脱敏版。
	RequestPayload []byte
	InvokeKind     doma2a.InvokeKind
	// StreamSink 接收 runtime 增量输出; 仅 invoke_kind=stream 时装配。实现不得阻塞 runtime。
	StreamSink func(A2AStreamEvent)
	// CandidateInActiveChain (Phase5): 候选命中链上仍活跃的同一 Agent。openclaw/hermes 同 pod
	// 不支持并发, invoker 据此在派发前快速失败 a2a.reentrant_runtime_unsupported; 外部 ZAP 忽略。
	CandidateInActiveChain bool
}

// AgentInvocationResult Agent B 调用结果.
type AgentInvocationResult struct {
	Status          doma2a.Status
	ResponsePayload []byte
	// ApprovalRequired 表示被调 runtime 在执行中请求人工审批 (例如 ZAP message.awaiting_user)。
	// service 会把当前 edge 挂起为 awaiting_approval, 创建审批单, 审批通过后重新派发。
	ApprovalRequired   bool
	ApprovalFormSchema []byte
	ApprovalBlocks     []map[string]any
	TokensIn           int32
	TokensOut          int32
	LatencyMs          int32
	// ErrorMessage 写入 edge.error_message (Agent A 可见) —— 必须是归一化 a2a.* 稳定码,
	// 禁止携带 endpoint / runtime 原始错误等内部细节。
	ErrorMessage string
	// InternalError 仅入 audit/log 的原始错误细节; 不写 edge。
	InternalError string
}

// AgentCancellation 是 AgentInvoker.Cancel 入参. v1d 只要求 external ZAP 在同进程运行中任务
// 能投递 runtime cancel; 未命中 active session 时仍允许 Bus 侧 cancelled 成功。
type AgentCancellation struct {
	EdgeUUID      string
	EdgeCreatedAt time.Time
	TenantID      int64
	FromAgentID   int64
	ToAgentID     int64
}

// AgentCancellationResult 只进 audit/log, 不写 edge, 不暴露 runtime 内部细节给 Agent A。
type AgentCancellationResult struct {
	Delivered     bool
	RuntimeKind   string
	ErrorMessage  string
	InternalError string
}

// ChatTimelineEvent 是 A2A → chat 执行过程投影的低敏事件。
// 实现方只能把 edge/agent/status 摘要投给客户端, 不得携带 payload、endpoint、token。
type ChatTimelineEvent struct {
	ParentSessionTokenID int64
	Edge                 *doma2a.Edge
	FromAgent            *domagent.DigitalEmployee
	ToAgent              *domagent.DigitalEmployee
	Status               doma2a.Status
	ErrorCode            string
	ApprovalRequestUUID  string
	ApprovalFormSchema   []byte
	ApprovalBlocks       []map[string]any
}

// ChatTimelinePublisher 是 A2A service 对聊天 timeline 的窄依赖。
// publish 失败不能影响 A2A 调用本身, 所以接口不返回 error。
type ChatTimelinePublisher interface {
	PublishA2AStarted(ctx context.Context, ev ChatTimelineEvent)
	PublishA2AFinished(ctx context.Context, ev ChatTimelineEvent)
}

// NoopAgentInvoker 是未装配真实 invoker 时的 stub: 立刻把 edge 标 failed("agent_invoker_not_wired").
// 真实实现 = ZapAgentInvoker (invoker_zap.go, A2A v1a); cmd/bus 显式装配。
type NoopAgentInvoker struct{}

func (NoopAgentInvoker) Invoke(_ context.Context, in AgentInvocation) (AgentInvocationResult, error) {
	return AgentInvocationResult{
		Status:       doma2a.StatusFailed,
		ErrorMessage: "agent_invoker_not_wired (PR6)",
	}, nil
}

func (NoopAgentInvoker) Cancel(_ context.Context, _ AgentCancellation) (AgentCancellationResult, error) {
	return AgentCancellationResult{
		Delivered:    false,
		RuntimeKind:  "noop",
		ErrorMessage: "a2a.cancel_best_effort",
	}, nil
}

// New 构造服务. 任一必填 dep 缺失 → panic (启动期就发现).
func New(d Deps) *Service {
	if d.Edges == nil {
		panic("a2a.New: Edges repo required")
	}
	if d.Agents == nil {
		panic("a2a.New: Agents repo required")
	}
	if d.CapabilityRepo == nil {
		panic("a2a.New: CapabilityRepo required")
	}
	if d.SessionDeriver == nil {
		panic("a2a.New: SessionDeriver required")
	}
	if d.Cycle == nil {
		d.Cycle = NewEdgeRepoCycleDetector(d.Edges)
	}
	if d.AgentInvoker == nil {
		d.AgentInvoker = NoopAgentInvoker{}
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.StreamHub == nil {
		d.StreamHub = NewLocalA2AStreamHub()
	}
	// Phase5 预算治理默认 (与 config.withDefaults 对齐; 单测直接 New 也有安全默认)。
	if d.Governance.MaxDepth <= 0 {
		d.Governance.MaxDepth = 5
	}
	if d.Governance.ChainMaxCalls <= 0 {
		d.Governance.ChainMaxCalls = 20
	}
	if d.Governance.ChainTimeout <= 0 {
		d.Governance.ChainTimeout = 10 * time.Minute
	}
	return &Service{deps: d}
}

// IssueInput POST /zap/v1/internal/a2a/invoke 业务入参.
type IssueInput struct {
	// 鉴权上下文 (middleware 注入)
	FromSessionTokenID int64
	FromAccountID      int64 // parent session token 绑定账号; 0 = tenant-scoped/runtime token
	FromAgentID        int64
	TenantID           int64
	CallerCapabilities []string // session_token.capability_bindings; 用作 child caps subset 上限

	// Request body
	ToAgentUUID          string
	ParentEdgeUUID       string // 空 = root 调用
	ParentEdgeCreated    time.Time
	RoomUUID             string // 传输层接收 room_id；service 内部按稳定 UUID 解析成 RoomID 写 edge。
	RoomID               *int64
	OriginConversationID *int64
	OrchestrationID      *int64
	StepIndex            int
	IdempotencyKey       string // 可选: 同一 runtime tool_call 的稳定 key; 用于网络重试幂等, 不跨用户消息复用
	InvokeKind           doma2a.InvokeKind
	RequestPayload       []byte
}

// IssueResult invoke 响应.
type IssueResult struct {
	EdgeUUID            string
	EdgeCreatedAt       time.Time
	IdemKey             string
	Status              doma2a.Status
	ApprovalRequestUUID string
	HTTPStatus          int    // 202 / 429 / etc.
	RetryAfterSeconds   int    // 仅当 status=rate_limited 时非 0
	ErrorCode           string // edge 写入时未填 (仅 transport 转 HTTP error 用)
}

type ApprovalDecisionInput struct {
	TenantID       int64
	ApprovalUUID   string
	ActorAccountID int64
	Decision       domapproval.Status
	FormResult     []byte
	Reason         string
	// AdminOverride=true 表示租户后台 RBAC 已授权的代审批入口。
	// 客户端入口必须保持 false, 由 parent_account_id 收窄到原始会话用户。
	AdminOverride bool
}

type ApprovalDecisionResult struct {
	ApprovalUUID   string
	EdgeUUID       string
	EdgeCreatedAt  time.Time
	ApprovalStatus domapproval.Status
	EdgeStatus     doma2a.Status
}

type ApprovalView struct {
	Request       *domapproval.Request
	FromAgentUUID string
	FromAgentName string
	ToAgentUUID   string
	ToAgentName   string
}

// 业务错误哨兵 (transport 层 map → HTTP code).
var (
	ErrSelfInvoke        = errors.New("a2a.self_invoke_forbidden")
	ErrCrossTenant       = errors.New("a2a.cross_tenant_forbidden")
	ErrMissingCapability = errors.New("a2a.missing_capability")
	ErrNotInWhitelist    = errors.New("a2a.not_in_whitelist")
	ErrDepthExceeded     = errors.New("a2a.depth_exceeded")
	// ErrCycleDetected legacy (Phase5 起不再由「祖先命中」触发; 保留供旧数据/审计与 transport 兼容)。
	ErrCycleDetected = errors.New("a2a.cycle_detected")
	// Phase5 预算治理错误码 (§12.4.1)。
	ErrBudgetExceeded              = errors.New("a2a.budget_exceeded")
	ErrChainTimeout                = errors.New("a2a.chain_timeout")
	ErrRepeatedCall                = errors.New("a2a.repeated_call_detected")
	ErrReentrantRuntimeUnsupported = errors.New("a2a.reentrant_runtime_unsupported")
	ErrRateLimited                 = errors.New("a2a.rate_limited")
	ErrInvalidInvoke               = errors.New("a2a.invalid_invoke")
	ErrToAgentNotFound             = errors.New("a2a.to_agent_not_found")
	ErrToAgentNotPublished         = errors.New("a2a.to_agent_not_published")
	ErrRoomNotFound                = errors.New("a2a.room_not_found")
	ErrStreamNotSupported          = errors.New("a2a.stream_not_supported_phase_b")
	// ErrApprovalRequired 仅在 Approvals 未接线时 fail-closed; 正常 v1e 会创建 awaiting_approval edge。
	ErrApprovalRequired   = errors.New("a2a.approval_required")
	ErrEdgeCancelled      = errors.New("a2a.cancelled")
	ErrApprovalNotPending = errors.New("a2a.approval_not_pending")
)

const defaultA2AApprovalTTL = 24 * time.Hour

// Invoke F09 §3.5 完整处理逻辑.
//
// 6 重校验顺序 (按 §4.7.2):
//
//	step 1  session_token 鉴权 → (middleware 已做, IssueInput.FromAgentID + caps)
//	step 2  tenant isolation
//	step 3  防自调
//	step 4  capability check (a2a_invoke binding)
//	step 5  callable whitelist
//	step 6  payload redaction + size cap
//	step 7  cycle 检测 + depth 计算
//	step 8  quota (per-agent RPM + per-tenant RPD)
//	step 9  idem_key 算 + INSERT a2a_call_edges (status=pending)
//	step 10 IssueDerivedSessionToken (parent → child for to_agent)
//	step 11 异步 fire AgentInvoker.Invoke (sync: 立即 fire goroutine; async: 同 sync 但 caller 不轮询)
//	step 12 audit_events: a2a.invoke
//
// 返 IssueResult; transport 层根据错误转 HTTP code.
func (s *Service) Invoke(ctx context.Context, in IssueInput) (*IssueResult, error) {
	metrics.IncA2AInvoke()
	started := s.deps.Now()
	dispatchPayload := sanitizeA2ADispatchPayload(in.RequestPayload)
	s.logInfo(ctx, "a2a.invoke.start",
		"tenant_id", in.TenantID,
		"account_id", in.FromAccountID,
		"from_agent_id", in.FromAgentID,
		"to_agent_id", shortA2AID(in.ToAgentUUID),
		"parent_edge_id", shortA2AID(in.ParentEdgeUUID),
		"origin_conversation_id", ptrInt64Value(in.OriginConversationID),
		"invoke_kind", string(in.InvokeKind),
		"idem_key_in", strings.TrimSpace(in.IdempotencyKey) != "",
		"payload", summarizeA2APayload(dispatchPayload),
	)
	// step 0: schema 层兜底
	if in.FromAgentID <= 0 || in.FromSessionTokenID <= 0 || in.TenantID <= 0 || in.ToAgentUUID == "" {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "required_fields_missing",
			"tenant_id", in.TenantID,
			"from_agent_id", in.FromAgentID,
			"to_agent_id", shortA2AID(in.ToAgentUUID),
		)
		return nil, apperr.ErrInvalidParams.Withf("a2a.invoke: required fields missing")
	}
	if in.InvokeKind == "" {
		in.InvokeKind = doma2a.InvokeSync
	}
	switch in.InvokeKind {
	case doma2a.InvokeSync, doma2a.InvokeAsync, doma2a.InvokeStream:
		// ok
	default:
		return nil, apperr.ErrInvalidParams.Withf("invalid invoke_kind: %s", in.InvokeKind)
	}

	// step 0.5: 拉 from_agent + to_agent
	fromAgent, err := s.deps.Agents.GetByID(ctx, in.FromAgentID)
	if err != nil {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "from_agent_not_found",
			"tenant_id", in.TenantID,
			"from_agent_id", in.FromAgentID,
			"err", err.Error(),
		)
		return nil, apperr.ErrUnauthorized.Withf("from_agent not found")
	}
	toAgent, err := s.deps.Agents.GetByUUID(ctx, in.ToAgentUUID)
	if err != nil {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "to_agent_not_found",
			"tenant_id", in.TenantID,
			"from_agent", agentLogFields(fromAgent),
			"to_agent_id", shortA2AID(in.ToAgentUUID),
			"err", err.Error(),
		)
		return nil, ErrToAgentNotFound
	}
	s.logInfo(ctx, "a2a.invoke.agents_resolved",
		"tenant_id", in.TenantID,
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"to_status", toAgent.Status,
		"to_callable_policy", compactA2ACallablePolicy(toAgent.CallableByAgentsJSON),
	)

	// step 2: tenant isolation
	if fromAgent.TenantID != toAgent.TenantID {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "cross_tenant_agents",
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
		)
		return nil, ErrCrossTenant
	}
	if fromAgent.TenantID != in.TenantID {
		// session_token.tenant_id 和 from_agent.tenant_id 不一致, 防御深度
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "session_tenant_mismatch",
			"input_tenant_id", in.TenantID,
			"from_agent_tenant_id", fromAgent.TenantID,
			"from_agent", agentLogFields(fromAgent),
		)
		return nil, ErrCrossTenant
	}
	if toAgent.Status != "published" {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "to_agent_not_published",
			"to_agent", agentLogFields(toAgent),
			"to_status", toAgent.Status,
		)
		return nil, ErrToAgentNotPublished
	}

	// step 3: 防自调
	if fromAgent.ID == toAgent.ID {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "self_invoke",
			"agent", agentLogFields(fromAgent),
		)
		return nil, ErrSelfInvoke
	}

	// step 4: capability check (a2a_invoke binding)
	ok, err := s.deps.CapabilityRepo.HasA2AInvokeCapability(ctx, fromAgent.ID)
	if err != nil {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "capability_check_error",
			"from_agent", agentLogFields(fromAgent),
			"err", err.Error(),
		)
		return nil, fmt.Errorf("a2a.invoke: capability check: %w", err)
	}
	if !ok {
		metrics.IncA2AReject("capability")
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "missing_a2a_invoke_capability",
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
		)
		return nil, ErrMissingCapability
	}

	// step 5: callable whitelist
	policy := ParseCallablePolicy(toAgent.CallableByAgentsJSON)
	if !EvaluateWhitelist(WhitelistInput{
		FromAgentID:      fromAgent.UUID,
		FromAgentWorkspc: fromAgent.WorkspaceID,
		ToAgentID:        toAgent.UUID,
		ToAgentWorkspc:   toAgent.WorkspaceID,
		ToCallable:       policy,
	}) {
		// 业务上记录 dropped_whitelist 而不是 not_in_whitelist (audit 区分)
		s.fireAudit(ctx, fromAgent, toAgent, "a2a.dropped_whitelist", nil, nil)
		metrics.IncA2AReject("not_in_whitelist")
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "not_in_whitelist",
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"to_callable_policy", compactA2ACallablePolicy(toAgent.CallableByAgentsJSON),
		)
		return nil, ErrNotInWhitelist
	}

	card := domagent.ParseA2ACardLenient(toAgent.A2ACardJSON)
	roomID, err := s.resolveInvokeRoomID(ctx, in)
	if err != nil {
		return nil, err
	}

	// step 6: payload redaction + size cap
	redacted, redactHit, truncated := RedactJSON(in.RequestPayload)
	_ = redactHit
	_ = truncated

	// step 7: cycle 检测 + depth
	var parentID *int64
	var parentCreated *time.Time
	originConversationID := in.OriginConversationID
	if in.ParentEdgeUUID != "" {
		// 拉 parent edge 校验存在 + tenant + createdAt
		// parentCreated 是 caller 传的 (用作分区裁剪)
		if !in.ParentEdgeCreated.IsZero() {
			pc := in.ParentEdgeCreated
			parentCreated = &pc
		}
		parentEdge, err := s.deps.Edges.GetByUUID(ctx, in.TenantID, in.ParentEdgeUUID, in.ParentEdgeCreated)
		if err != nil {
			return nil, apperr.ErrInvalidParams.Withf("parent edge not found")
		}
		parentID = &parentEdge.ID
		originConversationID = parentEdge.OriginConversationID
	}
	// Phase5 (§12.4.1): 不再「祖先命中即 cycle_detected」。链路分析 → 预算治理综合放行。
	chain, err := s.deps.Cycle.AnalyzeChain(ctx, in.TenantID, parentID, parentCreated, toAgent.ID)
	if err != nil {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "chain_analyze_error",
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"err", err.Error(),
		)
		return nil, fmt.Errorf("a2a.invoke: chain analyze: %w", err)
	}
	depth := chain.Depth
	s.logInfo(ctx, "a2a.invoke.chain_checked",
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"depth", depth,
		"root_edge_id", chain.RootEdgeID,
		"reentry_candidate", chain.ReentryCandidate,
	)
	if int(depth) > s.deps.Governance.MaxDepth {
		metrics.IncA2AReject("depth")
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "depth_exceeded",
			"depth", depth,
			"max_depth", s.deps.Governance.MaxDepth,
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
		)
		return nil, ErrDepthExceeded
	}
	// orchestration depth_limit 软上限 (保留既有行为)。
	if in.OrchestrationID != nil {
		orch, oerr := s.deps.Orchestrations.GetByID(ctx, *in.OrchestrationID)
		if oerr == nil && orch != nil && depth > orch.DepthLimit {
			metrics.IncA2AReject("budget")
			return nil, ErrDepthExceeded
		}
	}
	// 规范化调用指纹 (随 edge 落库; 供同链 total_calls / repeated 复算)。
	fingerprint := ComputeRequestFingerprint(in.TenantID, fromAgent.ID, toAgent.ID, string(in.InvokeKind), redacted)
	// Phase5 链级预算: 仅当处于已有 root chain (非本次即根) 时聚合并治理。
	if chain.RootEdgeID != 0 {
		stats, serr := s.deps.Edges.ChainStats(ctx, in.TenantID, chain.RootEdgeID, chain.RootEdgeCreatedAt, fingerprint)
		if serr != nil {
			return nil, fmt.Errorf("a2a.invoke: chain stats: %w", serr)
		}
		if s.deps.Governance.ChainMaxCalls > 0 && stats.TotalCalls >= s.deps.Governance.ChainMaxCalls {
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.dropped_budget", nil, map[string]any{"total_calls": stats.TotalCalls})
			metrics.IncA2AReject("budget")
			s.logWarn(ctx, "a2a.invoke.reject",
				"reason", "chain_budget_exceeded",
				"total_calls", stats.TotalCalls,
				"chain_max_calls", s.deps.Governance.ChainMaxCalls,
				"root_edge_id", chain.RootEdgeID,
			)
			return nil, ErrBudgetExceeded
		}
		if s.deps.Governance.ChainTimeout > 0 && !chain.RootEdgeCreatedAt.IsZero() &&
			s.deps.Now().Sub(chain.RootEdgeCreatedAt) > s.deps.Governance.ChainTimeout {
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.chain_timeout", nil, nil)
			metrics.IncA2AReject("chain_timeout")
			s.logWarn(ctx, "a2a.invoke.reject",
				"reason", "chain_timeout",
				"root_edge_id", chain.RootEdgeID,
				"root_age_ms", int64(s.deps.Now().Sub(chain.RootEdgeCreatedAt)/time.Millisecond),
			)
			return nil, ErrChainTimeout
		}
		if s.deps.Governance.RepeatedCallHardLimit > 0 && stats.SameFingerprint >= s.deps.Governance.RepeatedCallHardLimit {
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.repeated_call_detected", nil, map[string]any{"same_fingerprint": stats.SameFingerprint})
			metrics.IncA2AReject("repeated")
			s.logWarn(ctx, "a2a.invoke.reject",
				"reason", "repeated_call_detected",
				"same_fingerprint", stats.SameFingerprint,
				"hard_limit", s.deps.Governance.RepeatedCallHardLimit,
			)
			return nil, ErrRepeatedCall
		}
		if stats.SameFingerprint > 0 {
			// 默认只 warn/计数 (硬拒阈值未开或未达)。
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.repeated_call_warn", nil, map[string]any{"same_fingerprint": stats.SameFingerprint})
		}
	}

	// step 8: quota
	if s.deps.Quota != nil {
		allowed, retryAfter, qerr := s.deps.Quota.CheckAndIncr(ctx, in.TenantID, fromAgent.ID)
		if qerr != nil {
			return nil, fmt.Errorf("a2a.invoke: quota: %w", qerr)
		}
		if !allowed {
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.rate_limited", nil, nil)
			metrics.IncA2AReject("quota")
			s.logWarn(ctx, "a2a.invoke.reject",
				"reason", "quota_rate_limited",
				"tenant_id", in.TenantID,
				"from_agent", agentLogFields(fromAgent),
				"retry_after_seconds", retryAfter,
			)
			return &IssueResult{
				HTTPStatus:        429,
				Status:            doma2a.StatusCancelled, // 没插 edge
				RetryAfterSeconds: retryAfter,
				ErrorCode:         "a2a.rate_limited",
			}, ErrRateLimited
		}
	}

	// step 9: idem_key + INSERT edge
	// v1f: idem_key 只表示「同一 tool_call 重试」。有调用方 idempotency_key 时优先使用;
	// 未传时用 request_fingerprint 兜底, 至少避免不同 payload / 不同用户请求复用旧 edge。
	idemScope := strings.TrimSpace(in.IdempotencyKey)
	if idemScope != "" {
		idemScope = "client:" + idemScope
	} else {
		idemScope = "fp:" + fingerprint
	}
	idemKey := ComputeScopedIdemKey(parentID, in.StepIndex, fromAgent.ID, toAgent.ID, idemScope)
	// 幂等: 已有 row → 直接返
	if exist, ferr := s.deps.Edges.FindByIdemKey(ctx, in.TenantID, idemKey); ferr == nil && exist != nil {
		s.logInfo(ctx, "a2a.invoke.idempotent_hit",
			"tenant_id", in.TenantID,
			"edge_id", shortA2AID(exist.UUID),
			"status", string(exist.Status),
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"elapsed_ms", int64(s.deps.Now().Sub(started)/time.Millisecond),
		)
		return &IssueResult{
			EdgeUUID:      exist.UUID,
			EdgeCreatedAt: exist.CreatedAt,
			IdemKey:       exist.IdemKey,
			Status:        exist.Status,
			HTTPStatus:    202,
		}, nil
	}

	insertIn := doma2a.InsertInput{
		TenantID:             in.TenantID,
		RoomID:               roomID,
		FromAgentID:          fromAgent.ID,
		ToAgentID:            toAgent.ID,
		OrchestrationID:      in.OrchestrationID,
		ParentEdgeID:         parentID,
		OriginConversationID: originConversationID,
		Depth:                depth,
		IdemKey:              idemKey,
		InvokeKind:           in.InvokeKind,
		RequestPayload:       redacted,
		RequestFingerprint:   fingerprint,
	}
	// Phase5: 子调用继承 root chain 锚点; root 调用留 nil (DB NULL, 以自身 id 为根)。
	if chain.RootEdgeID != 0 {
		rootID := chain.RootEdgeID
		rootCreated := chain.RootEdgeCreatedAt
		insertIn.RootEdgeID = &rootID
		insertIn.RootEdgeCreatedAt = &rootCreated
	}
	if in.FromAccountID > 0 {
		insertIn.CreatedBy = &in.FromAccountID
	}
	edge, err := s.deps.Edges.Insert(ctx, insertIn)
	if err != nil {
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "insert_edge_failed",
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"err", err.Error(),
		)
		return nil, fmt.Errorf("a2a.invoke: insert edge: %w", err)
	}
	s.logInfo(ctx, "a2a.invoke.edge_created",
		"tenant_id", in.TenantID,
		"edge_id", shortA2AID(edge.UUID),
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"depth", edge.Depth,
		"invoke_kind", string(edge.InvokeKind),
		"origin_conversation_id", ptrInt64Value(edge.OriginConversationID),
		"payload", summarizeA2APayload(dispatchPayload),
	)

	if card.RequiresApproval {
		if s.deps.Approvals == nil {
			failed, _ := s.deps.Edges.UpdateStatus(ctx, in.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
				Status:       statusPtr(doma2a.StatusFailed),
				ErrorMessage: strPtr("a2a.approval_not_wired"),
				CompletedAt:  timePtr(s.deps.Now()),
			})
			s.publishChatA2AFinished(ctx, in.FromSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.approval_not_wired")
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_required", edge, map[string]any{"error_code": "a2a.approval_not_wired"})
			return nil, ErrApprovalRequired
		}
		expiresAt := s.deps.Now().Add(defaultA2AApprovalTTL)
		formSchema := approvalFormSchema(card)
		approval, err := s.deps.Approvals.Create(ctx, domapproval.CreateInput{
			TenantID:               in.TenantID,
			EdgeID:                 edge.ID,
			EdgeUUID:               edge.UUID,
			EdgeCreatedAt:          edge.CreatedAt,
			FromAgentID:            fromAgent.ID,
			ToAgentID:              toAgent.ID,
			ParentSessionTokenID:   in.FromSessionTokenID,
			ParentAccountID:        in.FromAccountID,
			CallerCapabilities:     in.CallerCapabilities,
			InvokeKind:             in.InvokeKind,
			RequestPayload:         dispatchPayload,
			RequestPayloadRedacted: redacted,
			FormSchema:             formSchema,
			ExpiresAt:              &expiresAt,
		})
		if err != nil {
			failed, _ := s.deps.Edges.UpdateStatus(ctx, in.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
				Status:       statusPtr(doma2a.StatusFailed),
				ErrorMessage: strPtr("a2a.approval_create_failed"),
				CompletedAt:  timePtr(s.deps.Now()),
			})
			s.publishChatA2AFinished(ctx, in.FromSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.approval_create_failed")
			return nil, fmt.Errorf("a2a.invoke: create approval: %w", err)
		}
		awaiting, err := s.deps.Edges.UpdateStatus(ctx, in.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusAwaitingApproval),
			ErrorMessage:   strPtr("a2a.awaiting_approval"),
			ExpectStatuses: []doma2a.Status{doma2a.StatusPending},
		})
		if err != nil {
			return nil, fmt.Errorf("a2a.invoke: mark awaiting approval: %w", err)
		}
		s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_created", awaiting, map[string]any{
			"approval_request_id": approval.UUID,
			"requires_approval":   true,
		})
		s.publishChatA2AApprovalRequested(ctx, in.FromSessionTokenID, awaiting, fromAgent, toAgent, approval.UUID, formSchema, nil)
		return &IssueResult{
			EdgeUUID:            awaiting.UUID,
			EdgeCreatedAt:       awaiting.CreatedAt,
			IdemKey:             awaiting.IdemKey,
			Status:              awaiting.Status,
			ApprovalRequestUUID: approval.UUID,
			HTTPStatus:          202,
		}, nil
	}

	// step 10: IssueDerivedSessionToken
	// child caps = caller session caps (subset 自动校验在 svcagentsdk 内部完成)
	childTok, childPlain, err := s.deps.SessionDeriver.IssueDerivedSessionToken(
		ctx,
		in.FromSessionTokenID,
		toAgent.ID,
		in.CallerCapabilities, // nil = 继承 parent 全集; 显式传 = 收窄
		0,                     // ttl=0 → 服务端 clamp parent 剩余 / 默认 60min
	)
	if err != nil {
		// 派生失败 → edge 标 failed (cancelled)
		failed, _ := s.deps.Edges.UpdateStatus(ctx, in.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:       statusPtr(doma2a.StatusFailed),
			ErrorMessage: strPtr("session derive failed: " + err.Error()),
			CompletedAt:  timePtr(s.deps.Now()),
		})
		s.publishChatA2AFinished(ctx, in.FromSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.session_derive_failed")
		s.logWarn(ctx, "a2a.invoke.reject",
			"reason", "session_derive_failed",
			"edge_id", shortA2AID(edge.UUID),
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"err", err.Error(),
		)
		return nil, fmt.Errorf("a2a.invoke: derive session: %w", err)
	}

	// step 11: 异步 fire AgentInvoker
	// 传输给 B 的是业务 payload; Bus 仅做 token/session/endpoint 等泄露项防御性清洗,
	// 不清路由词、不生成任务. redacted 只用于上面 edge 落库 (审计副本)。
	s.publishChatA2AStarted(ctx, in.FromSessionTokenID, edge, fromAgent, toAgent, edge.Status)
	go s.fireAgentInvoke(edge, fromAgent, toAgent, in.FromSessionTokenID, in.FromAccountID, in.CallerCapabilities, childPlain, childTok, dispatchPayload, in.InvokeKind, chain.ReentryCandidate)
	s.logInfo(ctx, "a2a.invoke.dispatch_scheduled",
		"tenant_id", in.TenantID,
		"edge_id", shortA2AID(edge.UUID),
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"child_token_id", childTok.ID,
		"child_expires_at", childTok.ExpiresAt.UTC().Format(time.RFC3339),
		"elapsed_ms", int64(s.deps.Now().Sub(started)/time.Millisecond),
	)

	// step 12: audit a2a.invoke (info)
	s.fireAudit(ctx, fromAgent, toAgent, "a2a.invoke", edge, nil)

	return &IssueResult{
		EdgeUUID:      edge.UUID,
		EdgeCreatedAt: edge.CreatedAt,
		IdemKey:       edge.IdemKey,
		Status:        edge.Status,
		HTTPStatus:    202,
	}, nil
}

func (s *Service) resolveInvokeRoomID(ctx context.Context, in IssueInput) (*int64, error) {
	roomUUID := strings.TrimSpace(in.RoomUUID)
	if roomUUID == "" {
		return in.RoomID, nil
	}
	if s.deps.Rooms == nil {
		return nil, apperr.ErrInternal.Withf("a2a.invoke: room resolver not wired")
	}
	room, err := s.deps.Rooms.GetByUUID(ctx, in.TenantID, roomUUID)
	if err != nil {
		return nil, ErrRoomNotFound
	}
	if room.TenantID != in.TenantID || room.ID <= 0 {
		return nil, ErrRoomNotFound
	}
	if in.RoomID != nil && *in.RoomID > 0 && *in.RoomID != room.ID {
		return nil, ErrInvalidInvoke
	}
	id := room.ID
	return &id, nil
}

// GetEdge F09 §3.5 GET /zap/v1/internal/a2a/edges/{uuid}.
// 校验 caller (from 或 to agent) 一致, 否则 403.
func (s *Service) GetEdge(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, callerAgentID int64) (*doma2a.Edge, error) {
	edge, err := s.deps.Edges.GetByUUID(ctx, tenantID, edgeUUID, edgeCreatedAt)
	if err != nil {
		return nil, err
	}
	if edge.FromAgentID != callerAgentID && edge.ToAgentID != callerAgentID {
		return nil, apperr.ErrForbidden.Withf("not your edge")
	}
	return edge, nil
}

// ResolveRuntimeParentEdge 解析托管 runtime 的 A2A session_key="a2a:<agent_id>:<edge_id>"。
// 只允许当前 runtime agent 作为该 edge 的被调方继承 parent, 防止任意 agent 伪造别人的调用链。
func (s *Service) ResolveRuntimeParentEdge(ctx context.Context, tenantID, runtimeAgentID int64, edgeUUID string) (*doma2a.Edge, error) {
	if tenantID <= 0 || runtimeAgentID <= 0 || strings.TrimSpace(edgeUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("a2a runtime parent edge required")
	}
	edge, err := s.deps.Edges.FindLatestByUUID(ctx, tenantID, strings.TrimSpace(edgeUUID))
	if err != nil {
		return nil, err
	}
	if edge.TenantID != tenantID || edge.ToAgentID != runtimeAgentID {
		return nil, apperr.ErrForbidden.Withf("a2a runtime parent edge mismatch")
	}
	return edge, nil
}

// CancelEdge best-effort 取消 pending/running edge。状态推进用 ExpectStatuses 做条件 UPDATE, 让
// cancelled/done/failed 这些终态在并发写回下不会被静默覆盖。v1d 对 external ZAP 运行中任务会
// 额外尝试投递 runtime cancel; 未命中 active session 仍以 Bus 侧 cancelled 为准。
func (s *Service) CancelEdge(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, callerAgentID int64) (*doma2a.Edge, error) {
	if tenantID <= 0 || edgeUUID == "" || edgeCreatedAt.IsZero() || callerAgentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.cancel: required fields missing")
	}
	edge, err := s.GetEdge(ctx, tenantID, edgeUUID, edgeCreatedAt, callerAgentID)
	if err != nil {
		return nil, err
	}
	switch edge.Status {
	case doma2a.StatusPending, doma2a.StatusAwaitingApproval, doma2a.StatusRunning:
		now := s.deps.Now()
		expect := []doma2a.Status{doma2a.StatusPending, doma2a.StatusAwaitingApproval, doma2a.StatusRunning}
		cancelled, uerr := s.deps.Edges.UpdateStatus(ctx, tenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusCancelled),
			ErrorMessage:   strPtr("a2a.cancelled"),
			CompletedAt:    timePtr(now),
			ExpectStatuses: expect,
		})
		if uerr != nil {
			if current, gerr := s.GetEdge(ctx, tenantID, edgeUUID, edgeCreatedAt, callerAgentID); gerr == nil {
				return current, nil
			}
			return nil, uerr
		}
		if edge.Status == doma2a.StatusAwaitingApproval && s.deps.Approvals != nil {
			_ = s.deps.Approvals.CancelPendingByEdge(ctx, tenantID, edge.UUID, edge.CreatedAt, now)
		}
		cancelRes := s.cancelRuntimeBestEffort(ctx, cancelled)
		s.fireCancelAudit(ctx, cancelled, cancelRes)
		s.closeStream(ctx, cancelled)
		return cancelled, nil
	default:
		return edge, nil
	}
}

func (s *Service) cancelRuntimeBestEffort(ctx context.Context, edge *doma2a.Edge) AgentCancellationResult {
	if edge == nil || s.deps.AgentInvoker == nil {
		return AgentCancellationResult{Delivered: false, RuntimeKind: "none", ErrorMessage: "a2a.cancel_best_effort"}
	}
	cancelCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	res, err := s.deps.AgentInvoker.Cancel(cancelCtx, AgentCancellation{
		EdgeUUID:      edge.UUID,
		EdgeCreatedAt: edge.CreatedAt,
		TenantID:      edge.TenantID,
		FromAgentID:   edge.FromAgentID,
		ToAgentID:     edge.ToAgentID,
	})
	if err != nil {
		res.Delivered = false
		if res.RuntimeKind == "" {
			res.RuntimeKind = "unknown"
		}
		if res.ErrorMessage == "" {
			res.ErrorMessage = "a2a.cancel_best_effort"
		}
		res.InternalError = truncateDetail(err.Error())
	}
	return res
}

func (s *Service) DecideApproval(ctx context.Context, in ApprovalDecisionInput) (*ApprovalDecisionResult, error) {
	if s.deps.Approvals == nil {
		return nil, apperr.ErrInternal.Withf("a2a approvals not wired")
	}
	if in.TenantID <= 0 || in.ApprovalUUID == "" || in.ActorAccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.approval: required fields missing")
	}
	if in.Decision != domapproval.StatusApproved && in.Decision != domapproval.StatusRejected {
		return nil, apperr.ErrInvalidParams.Withf("decision must be approved|rejected")
	}
	now := s.deps.Now()
	parentAccountID := in.ActorAccountID
	if in.AdminOverride {
		parentAccountID = 0
	}
	approval, err := s.deps.Approvals.DecidePending(ctx, domapproval.DecisionInput{
		TenantID:        in.TenantID,
		ApprovalUUID:    in.ApprovalUUID,
		ParentAccountID: parentAccountID,
		Decision:        in.Decision,
		FormResult:      in.FormResult,
		Reason:          in.Reason,
		ActorAccountID:  in.ActorAccountID,
		DecidedAt:       now,
	})
	if err != nil {
		if e, ok := apperr.AsError(err); ok && e.Code == apperr.Conflict {
			current, gerr := s.deps.Approvals.GetByUUID(ctx, in.TenantID, in.ApprovalUUID)
			if gerr != nil {
				return nil, gerr
			}
			if !in.AdminOverride && current.ParentAccountID != in.ActorAccountID {
				return nil, apperr.ErrNotFound
			}
			edge, gerr := s.deps.Edges.GetByUUID(ctx, in.TenantID, current.EdgeUUID, current.EdgeCreatedAt)
			if gerr != nil {
				return nil, gerr
			}
			return &ApprovalDecisionResult{
				ApprovalUUID:   current.UUID,
				EdgeUUID:       current.EdgeUUID,
				EdgeCreatedAt:  current.EdgeCreatedAt,
				ApprovalStatus: current.Status,
				EdgeStatus:     edge.Status,
			}, nil
		}
		return nil, err
	}
	edge, err := s.deps.Edges.GetByUUID(ctx, in.TenantID, approval.EdgeUUID, approval.EdgeCreatedAt)
	if err != nil {
		return nil, err
	}
	fromAgent, err := s.deps.Agents.GetByID(ctx, approval.FromAgentID)
	if err != nil {
		return nil, fmt.Errorf("a2a.approval: from agent: %w", err)
	}
	toAgent, err := s.deps.Agents.GetByID(ctx, approval.ToAgentID)
	if err != nil {
		return nil, fmt.Errorf("a2a.approval: to agent: %w", err)
	}
	if in.Decision == domapproval.StatusRejected {
		rejected, uerr := s.deps.Edges.UpdateStatus(ctx, in.TenantID, approval.EdgeUUID, approval.EdgeCreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusRejected),
			ErrorMessage:   strPtr("a2a.approval_rejected"),
			CompletedAt:    timePtr(now),
			ExpectStatuses: []doma2a.Status{doma2a.StatusAwaitingApproval},
		})
		if uerr == nil {
			edge = rejected
		}
		s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_rejected", edge, map[string]any{
			"approval_request_id": approval.UUID,
		})
		s.publishChatA2AFinished(ctx, approval.ParentSessionTokenID, edge, fromAgent, toAgent, doma2a.StatusRejected, "a2a.approval_rejected")
		return &ApprovalDecisionResult{
			ApprovalUUID:   approval.UUID,
			EdgeUUID:       approval.EdgeUUID,
			EdgeCreatedAt:  approval.EdgeCreatedAt,
			ApprovalStatus: approval.Status,
			EdgeStatus:     edge.Status,
		}, nil
	}
	childTok, childPlain, err := s.deps.SessionDeriver.IssueDerivedSessionToken(
		ctx,
		approval.ParentSessionTokenID,
		approval.ToAgentID,
		approval.CallerCapabilities,
		0,
	)
	if err != nil {
		failed, _ := s.deps.Edges.UpdateStatus(ctx, in.TenantID, approval.EdgeUUID, approval.EdgeCreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusFailed),
			ErrorMessage:   strPtr("a2a.approval_resume_token_failed"),
			CompletedAt:    timePtr(now),
			ExpectStatuses: []doma2a.Status{doma2a.StatusAwaitingApproval},
		})
		if failed != nil {
			edge = failed
		}
		s.publishChatA2AFinished(ctx, approval.ParentSessionTokenID, edge, fromAgent, toAgent, doma2a.StatusFailed, "a2a.approval_resume_token_failed")
		return nil, fmt.Errorf("a2a.approval: derive session: %w", err)
	}
	payload := appendApprovalResult(approval.RequestPayload, approval.FormResult, approval.UUID)
	_ = s.deps.Approvals.MarkDispatchedAndClear(ctx, in.TenantID, approval.UUID, now)
	s.publishChatA2AStarted(ctx, approval.ParentSessionTokenID, edge, fromAgent, toAgent, doma2a.StatusRunning)
	// 审批 resume 走原链, 不重复 reentrant 治理 (chain 分析在初次 invoke 已做)。
	go s.fireAgentInvokeFrom(edge, fromAgent, toAgent, approval.ParentSessionTokenID, approval.ParentAccountID, approval.CallerCapabilities, childPlain, childTok, payload, approval.InvokeKind, []doma2a.Status{doma2a.StatusAwaitingApproval}, false)
	s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_approved", edge, map[string]any{
		"approval_request_id": approval.UUID,
	})
	return &ApprovalDecisionResult{
		ApprovalUUID:   approval.UUID,
		EdgeUUID:       approval.EdgeUUID,
		EdgeCreatedAt:  approval.EdgeCreatedAt,
		ApprovalStatus: approval.Status,
		EdgeStatus:     doma2a.StatusAwaitingApproval,
	}, nil
}

func (s *Service) ListApprovals(ctx context.Context, tenantID, parentAccountID int64, status domapproval.Status, limit, offset int) ([]*domapproval.Request, int, error) {
	if s.deps.Approvals == nil {
		return nil, 0, apperr.ErrInternal.Withf("a2a approvals not wired")
	}
	if tenantID <= 0 || parentAccountID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("a2a.approval: tenant_id and account_id required")
	}
	return s.deps.Approvals.List(ctx, domapproval.ListFilter{
		TenantID:        tenantID,
		ParentAccountID: parentAccountID,
		Status:          status,
		Limit:           limit,
		Offset:          offset,
	})
}

func (s *Service) ListApprovalViews(ctx context.Context, tenantID, parentAccountID int64, status domapproval.Status, limit, offset int) ([]ApprovalView, int, error) {
	items, total, err := s.ListApprovals(ctx, tenantID, parentAccountID, status, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	views := make([]ApprovalView, 0, len(items))
	for _, item := range items {
		view := ApprovalView{Request: item}
		s.fillApprovalAgentNames(ctx, &view)
		views = append(views, view)
	}
	return views, total, nil
}

func (s *Service) ListApprovalViewsForAdmin(ctx context.Context, tenantID int64, status domapproval.Status, limit, offset int) ([]ApprovalView, int, error) {
	if s.deps.Approvals == nil {
		return nil, 0, apperr.ErrInternal.Withf("a2a approvals not wired")
	}
	if tenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("a2a.approval: tenant_id required")
	}
	items, total, err := s.deps.Approvals.List(ctx, domapproval.ListFilter{
		TenantID: tenantID,
		Status:   status,
		Limit:    limit,
		Offset:   offset,
	})
	if err != nil {
		return nil, 0, err
	}
	views := make([]ApprovalView, 0, len(items))
	for _, item := range items {
		view := ApprovalView{Request: item}
		s.fillApprovalAgentNames(ctx, &view)
		views = append(views, view)
	}
	return views, total, nil
}

func (s *Service) GetApproval(ctx context.Context, tenantID, parentAccountID int64, approvalUUID string) (*domapproval.Request, error) {
	if s.deps.Approvals == nil {
		return nil, apperr.ErrInternal.Withf("a2a approvals not wired")
	}
	if tenantID <= 0 || parentAccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.approval: tenant_id and account_id required")
	}
	item, err := s.deps.Approvals.GetByUUID(ctx, tenantID, approvalUUID)
	if err != nil {
		return nil, err
	}
	if item.ParentAccountID != parentAccountID {
		return nil, apperr.ErrNotFound
	}
	return item, nil
}

func (s *Service) GetApprovalView(ctx context.Context, tenantID, parentAccountID int64, approvalUUID string) (*ApprovalView, error) {
	item, err := s.GetApproval(ctx, tenantID, parentAccountID, approvalUUID)
	if err != nil {
		return nil, err
	}
	view := &ApprovalView{Request: item}
	s.fillApprovalAgentNames(ctx, view)
	return view, nil
}

func (s *Service) GetApprovalViewForAdmin(ctx context.Context, tenantID int64, approvalUUID string) (*ApprovalView, error) {
	if s.deps.Approvals == nil {
		return nil, apperr.ErrInternal.Withf("a2a approvals not wired")
	}
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.approval: tenant_id required")
	}
	item, err := s.deps.Approvals.GetByUUID(ctx, tenantID, approvalUUID)
	if err != nil {
		return nil, err
	}
	view := &ApprovalView{Request: item}
	s.fillApprovalAgentNames(ctx, view)
	return view, nil
}

func (s *Service) fillApprovalAgentNames(ctx context.Context, view *ApprovalView) {
	if view == nil || view.Request == nil || s.deps.Agents == nil {
		return
	}
	if from, err := s.deps.Agents.GetByID(ctx, view.Request.FromAgentID); err == nil && from != nil {
		view.FromAgentUUID = from.UUID
		view.FromAgentName = from.Name
	}
	if to, err := s.deps.Agents.GetByID(ctx, view.Request.ToAgentID); err == nil && to != nil {
		view.ToAgentUUID = to.UUID
		view.ToAgentName = to.Name
	}
}

// fireAgentInvoke goroutine: 调 AgentInvoker, 完成后 update edge status + 写终态 audit.
//
// 在 goroutine 内用 background context (不绑 caller 请求生命周期).
// 错误归一化纪律 (v1a): edge.error_message 只写 a2a.* 稳定码 (Agent A 经 GetEdge 可见);
// invoker 的原始错误细节只进 audit payload (error_detail, 截断) —— 防跨 Agent 信息泄漏。
func (s *Service) fireAgentInvoke(edge *doma2a.Edge, fromAgent, toAgent *domagent.DigitalEmployee, parentSessionTokenID, parentAccountID int64, callerCapabilities []string, childPlain string, childTok *domagentsdk.SessionToken, payload []byte, kind doma2a.InvokeKind, reentryCandidate bool) {
	s.fireAgentInvokeFrom(edge, fromAgent, toAgent, parentSessionTokenID, parentAccountID, callerCapabilities, childPlain, childTok, payload, kind, []doma2a.Status{doma2a.StatusPending}, reentryCandidate)
}

func (s *Service) fireAgentInvokeFrom(edge *doma2a.Edge, fromAgent, toAgent *domagent.DigitalEmployee, parentSessionTokenID, parentAccountID int64, callerCapabilities []string, childPlain string, childTok *domagentsdk.SessionToken, payload []byte, kind doma2a.InvokeKind, expect []doma2a.Status, reentryCandidate bool) {
	bg, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	start := s.deps.Now()
	s.logInfo(bg, "a2a.dispatch.start",
		"tenant_id", edge.TenantID,
		"edge_id", shortA2AID(edge.UUID),
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"parent_session_token_id", parentSessionTokenID,
		"parent_account_id", parentAccountID,
		"invoke_kind", string(kind),
		"reentry_candidate", reentryCandidate,
		"payload", summarizeA2APayload(payload),
	)
	runningEdge, uerr := s.deps.Edges.UpdateStatus(bg, edge.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
		Status:         statusPtr(doma2a.StatusRunning),
		StartedAt:      timePtr(start),
		ExpectStatuses: expect,
	})
	if uerr != nil {
		s.logWarn(bg, "a2a.dispatch.status_update_failed",
			"stage", "mark_running",
			"edge_id", shortA2AID(edge.UUID),
			"err", uerr.Error(),
		)
		return
	}
	s.publishChatA2AStarted(bg, parentSessionTokenID, edgeOr(runningEdge, edge), fromAgent, toAgent, doma2a.StatusRunning)
	s.logInfo(bg, "a2a.dispatch.running",
		"edge_id", shortA2AID(edge.UUID),
		"status", string(doma2a.StatusRunning),
	)

	res, err := s.deps.AgentInvoker.Invoke(bg, AgentInvocation{
		EdgeUUID:               edge.UUID,
		EdgeCreatedAt:          edge.CreatedAt,
		ParentAccountID:        parentAccountID,
		FromAgent:              fromAgent,
		ToAgent:                toAgent,
		ChildSessionToken:      childPlain,
		ChildSessionExpires:    childTok.ExpiresAt,
		RequestPayload:         payload,
		InvokeKind:             kind,
		StreamSink:             s.streamSink(bg, edge, kind),
		CandidateInActiveChain: reentryCandidate,
	})
	if current, gerr := s.deps.Edges.GetByUUID(bg, edge.TenantID, edge.UUID, edge.CreatedAt); gerr == nil && current.Status == doma2a.StatusCancelled {
		s.logInfo(bg, "a2a.dispatch.cancelled_before_finalize",
			"edge_id", shortA2AID(edge.UUID),
			"status", string(current.Status),
		)
		s.closeStream(bg, edgeOr(current, edge))
		return
	}
	if err != nil {
		// invoker 用 error 通道抛错 (预期外): edge 只落归一化码, 细节进 audit。
		s.logWarn(bg, "a2a.dispatch.invoker_error",
			"edge_id", shortA2AID(edge.UUID),
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"error_code", "a2a.invoker_error",
			"err", truncateDetail(err.Error()),
			"elapsed_ms", int64(s.deps.Now().Sub(start)/time.Millisecond),
		)
		failed, uerr := s.deps.Edges.UpdateStatus(bg, edge.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusFailed),
			ErrorMessage:   strPtr("a2a.invoker_error"),
			CompletedAt:    timePtr(s.deps.Now()),
			ExpectStatuses: []doma2a.Status{doma2a.StatusRunning},
		})
		if uerr != nil {
			s.logWarn(bg, "a2a.dispatch.status_update_failed",
				"stage", "mark_failed_invoker_error",
				"edge_id", shortA2AID(edge.UUID),
				"err", uerr.Error(),
			)
			return
		}
		s.publishChatA2AFinished(bg, parentSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.invoker_error")
		s.closeStream(bg, edgeOr(failed, edge))
		s.fireAudit(bg, fromAgent, toAgent, "a2a.failed", edge, map[string]any{
			"error_code":   "a2a.invoker_error",
			"error_detail": truncateDetail(err.Error()),
		})
		return
	}
	if res.ApprovalRequired || res.Status == doma2a.StatusAwaitingApproval {
		s.logInfo(bg, "a2a.dispatch.awaiting_approval",
			"edge_id", shortA2AID(edge.UUID),
			"from_agent", agentLogFields(fromAgent),
			"to_agent", agentLogFields(toAgent),
			"error_code", res.ErrorMessage,
			"elapsed_ms", int64(s.deps.Now().Sub(start)/time.Millisecond),
		)
		s.handleRuntimeApprovalRequired(bg, runningEdge, fromAgent, toAgent, parentSessionTokenID, parentAccountID, callerCapabilities, payload, kind, res)
		return
	}
	end := s.deps.Now()
	latency := int32(end.Sub(start) / time.Millisecond)
	upd := doma2a.UpdateStatusInput{
		Status:         statusPtr(res.Status),
		CompletedAt:    timePtr(end),
		LatencyMs:      &latency,
		ExpectStatuses: []doma2a.Status{doma2a.StatusRunning},
	}
	if len(res.ResponsePayload) > 0 {
		redactedResp, _, _ := RedactJSON(res.ResponsePayload)
		upd.ResponsePayload = redactedResp
	}
	if res.ErrorMessage != "" {
		upd.ErrorMessage = &res.ErrorMessage
	} else if res.Status == doma2a.StatusDone {
		upd.ErrorMessage = strPtr("")
	}
	if res.TokensIn > 0 {
		upd.TokensIn = &res.TokensIn
	}
	if res.TokensOut > 0 {
		upd.TokensOut = &res.TokensOut
	}
	finalEdge, uerr := s.deps.Edges.UpdateStatus(bg, edge.TenantID, edge.UUID, edge.CreatedAt, upd)
	if uerr != nil {
		s.logWarn(bg, "a2a.dispatch.status_update_failed",
			"stage", "mark_terminal",
			"edge_id", shortA2AID(edge.UUID),
			"target_status", string(res.Status),
			"err", uerr.Error(),
		)
		return
	}
	s.logInfo(bg, "a2a.dispatch.finish",
		"edge_id", shortA2AID(edge.UUID),
		"from_agent", agentLogFields(fromAgent),
		"to_agent", agentLogFields(toAgent),
		"status", string(res.Status),
		"error_code", res.ErrorMessage,
		"response", summarizeA2APayload(res.ResponsePayload),
		"tokens_in", res.TokensIn,
		"tokens_out", res.TokensOut,
		"latency_ms", latency,
	)
	s.publishChatA2AFinished(bg, parentSessionTokenID, edgeOr(finalEdge, edge), fromAgent, toAgent, res.Status, res.ErrorMessage)
	s.closeStream(bg, edgeOr(finalEdge, edge))

	// 终态 audit (F09 §4.7.6): completed / failed 各一条; detail 只进审计不进 edge。
	extra := map[string]any{
		"latency_ms": latency,
		"tokens_in":  res.TokensIn,
		"tokens_out": res.TokensOut,
	}
	kindEvt := "a2a.completed"
	if res.Status != doma2a.StatusDone {
		kindEvt = "a2a.failed"
		extra["error_code"] = res.ErrorMessage
		if res.InternalError != "" {
			extra["error_detail"] = truncateDetail(res.InternalError)
		}
	}
	s.fireAudit(bg, fromAgent, toAgent, kindEvt, edge, extra)
}

func (s *Service) handleRuntimeApprovalRequired(
	ctx context.Context,
	edge *doma2a.Edge,
	fromAgent, toAgent *domagent.DigitalEmployee,
	parentSessionTokenID, parentAccountID int64,
	callerCapabilities []string,
	payload []byte,
	kind doma2a.InvokeKind,
	res AgentInvocationResult,
) {
	if edge == nil {
		return
	}
	if s.deps.Approvals == nil {
		failed, uerr := s.deps.Edges.UpdateStatus(ctx, edge.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusFailed),
			ErrorMessage:   strPtr("a2a.approval_not_wired"),
			CompletedAt:    timePtr(s.deps.Now()),
			ExpectStatuses: []doma2a.Status{doma2a.StatusRunning},
		})
		if uerr == nil {
			s.publishChatA2AFinished(ctx, parentSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.approval_not_wired")
			s.closeStream(ctx, edgeOr(failed, edge))
		}
		s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_required", edge, map[string]any{"error_code": "a2a.approval_not_wired"})
		return
	}
	formSchema := res.ApprovalFormSchema
	if len(formSchema) == 0 {
		formSchema = approvalFormSchema(domagent.ParseA2ACardLenient(toAgent.A2ACardJSON))
	}
	redacted, _, _ := RedactJSON(payload)
	expiresAt := s.deps.Now().Add(defaultA2AApprovalTTL)
	approval, err := s.deps.Approvals.Create(ctx, domapproval.CreateInput{
		TenantID:               edge.TenantID,
		EdgeID:                 edge.ID,
		EdgeUUID:               edge.UUID,
		EdgeCreatedAt:          edge.CreatedAt,
		FromAgentID:            fromAgent.ID,
		ToAgentID:              toAgent.ID,
		ParentSessionTokenID:   parentSessionTokenID,
		ParentAccountID:        parentAccountID,
		CallerCapabilities:     callerCapabilities,
		InvokeKind:             kind,
		RequestPayload:         payload,
		RequestPayloadRedacted: redacted,
		FormSchema:             formSchema,
		ExpiresAt:              &expiresAt,
	})
	if err != nil {
		failed, uerr := s.deps.Edges.UpdateStatus(ctx, edge.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusFailed),
			ErrorMessage:   strPtr("a2a.approval_create_failed"),
			CompletedAt:    timePtr(s.deps.Now()),
			ExpectStatuses: []doma2a.Status{doma2a.StatusRunning},
		})
		if uerr == nil {
			s.publishChatA2AFinished(ctx, parentSessionTokenID, edgeOr(failed, edge), fromAgent, toAgent, doma2a.StatusFailed, "a2a.approval_create_failed")
			s.closeStream(ctx, edgeOr(failed, edge))
		}
		s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_required", edge, map[string]any{"error_code": "a2a.approval_create_failed"})
		return
	}
	awaiting, err := s.deps.Edges.UpdateStatus(ctx, edge.TenantID, edge.UUID, edge.CreatedAt, doma2a.UpdateStatusInput{
		Status:         statusPtr(doma2a.StatusAwaitingApproval),
		ErrorMessage:   strPtr("a2a.awaiting_approval"),
		ExpectStatuses: []doma2a.Status{doma2a.StatusRunning},
	})
	if err != nil {
		return
	}
	s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_created", awaiting, map[string]any{
		"approval_request_id": approval.UUID,
		"runtime_driven":      true,
	})
	s.publishChatA2AApprovalRequested(ctx, parentSessionTokenID, awaiting, fromAgent, toAgent, approval.UUID, formSchema, res.ApprovalBlocks)
	if kind == doma2a.InvokeStream {
		s.closeStreamWithEvent(ctx, awaiting, A2AStreamEvent{
			Event:         "a2a.awaiting_approval",
			EdgeUUID:      awaiting.UUID,
			EdgeCreatedAt: awaiting.CreatedAt,
			Status:        awaiting.Status,
			ErrorMessage:  awaiting.ErrorMessage,
		})
	}
}

func (s *Service) streamSink(ctx context.Context, edge *doma2a.Edge, kind doma2a.InvokeKind) func(A2AStreamEvent) {
	if kind != doma2a.InvokeStream || s.deps.StreamHub == nil || edge == nil {
		return nil
	}
	redactor := s.streamRedactorFor(edge)
	return func(ev A2AStreamEvent) {
		if ev.Event == "" {
			ev.Event = "a2a.delta"
		}
		if redactor != nil {
			redacted, ok := redactor.Redact(ev)
			if !ok {
				return
			}
			ev = redacted
		}
		s.publishStreamEvent(ctx, edge, ev)
	}
}

func (s *Service) closeStream(ctx context.Context, edge *doma2a.Edge) {
	if edge == nil || edge.InvokeKind != doma2a.InvokeStream || s.deps.StreamHub == nil {
		return
	}
	if redactor := s.popStreamRedactor(edge); redactor != nil {
		if ev, ok := redactor.Flush(); ok {
			s.publishStreamEvent(ctx, edge, ev)
		}
	}
	ev := terminalStreamEvent(edge)
	s.closeStreamWithEvent(ctx, edge, ev)
}

func (s *Service) publishStreamEvent(ctx context.Context, edge *doma2a.Edge, ev A2AStreamEvent) {
	if edge == nil || s.deps.StreamHub == nil {
		return
	}
	if s.deps.StreamStore != nil {
		stored, err := s.deps.StreamStore.Append(ctx, edge.TenantID, edge.UUID, edge.CreatedAt, ev)
		if err == nil {
			ev = stored
		}
	}
	s.deps.StreamHub.Publish(edge.UUID, edge.CreatedAt, ev)
}

func (s *Service) closeStreamWithEvent(ctx context.Context, edge *doma2a.Edge, ev A2AStreamEvent) {
	if edge == nil || s.deps.StreamHub == nil {
		return
	}
	if s.deps.StreamStore != nil {
		stored, err := s.deps.StreamStore.Append(ctx, edge.TenantID, edge.UUID, edge.CreatedAt, ev)
		if err == nil {
			ev = stored
		}
	}
	s.deps.StreamHub.Close(edge.UUID, edge.CreatedAt, ev)
}

func (s *Service) streamRedactorFor(edge *doma2a.Edge) *a2aStreamDeltaRedactor {
	if s == nil || edge == nil {
		return nil
	}
	key := a2aStreamKey(edge.UUID, edge.CreatedAt)
	s.streamRedactMu.Lock()
	defer s.streamRedactMu.Unlock()
	if s.streamRedactors == nil {
		s.streamRedactors = map[string]*a2aStreamDeltaRedactor{}
	}
	r := s.streamRedactors[key]
	if r == nil {
		r = newA2AStreamDeltaRedactor()
		s.streamRedactors[key] = r
	}
	return r
}

func (s *Service) popStreamRedactor(edge *doma2a.Edge) *a2aStreamDeltaRedactor {
	if s == nil || edge == nil {
		return nil
	}
	key := a2aStreamKey(edge.UUID, edge.CreatedAt)
	s.streamRedactMu.Lock()
	defer s.streamRedactMu.Unlock()
	r := s.streamRedactors[key]
	delete(s.streamRedactors, key)
	return r
}

func (s *Service) publishChatA2AStarted(ctx context.Context, parentSessionTokenID int64, edge *doma2a.Edge, fromAgent, toAgent *domagent.DigitalEmployee, status doma2a.Status) {
	if s.deps.ChatTimeline == nil || edge == nil || fromAgent == nil || toAgent == nil || parentSessionTokenID <= 0 {
		return
	}
	s.deps.ChatTimeline.PublishA2AStarted(ctx, ChatTimelineEvent{
		ParentSessionTokenID: parentSessionTokenID,
		Edge:                 edge,
		FromAgent:            fromAgent,
		ToAgent:              toAgent,
		Status:               status,
	})
}

func (s *Service) publishChatA2AApprovalRequested(ctx context.Context, parentSessionTokenID int64, edge *doma2a.Edge, fromAgent, toAgent *domagent.DigitalEmployee, approvalUUID string, formSchema []byte, blocks []map[string]any) {
	if s.deps.ChatTimeline == nil || edge == nil || fromAgent == nil || toAgent == nil || parentSessionTokenID <= 0 {
		return
	}
	s.deps.ChatTimeline.PublishA2AStarted(ctx, ChatTimelineEvent{
		ParentSessionTokenID: parentSessionTokenID,
		Edge:                 edge,
		FromAgent:            fromAgent,
		ToAgent:              toAgent,
		Status:               doma2a.StatusAwaitingApproval,
		ApprovalRequestUUID:  approvalUUID,
		ApprovalFormSchema:   formSchema,
		ApprovalBlocks:       blocks,
	})
}

// RunStepNotifier F24: 运行轨迹对 A2A 边终态的收敛回调 (chat.AgentRunHooks 实现)。
// 必须幂等且不可失败传播 (实现内部 fire-and-forget)。
type RunStepNotifier interface {
	OnA2AEdgeTerminal(tenantID int64, edgeUUID string, ok bool, errMsg string)
}

func (s *Service) publishChatA2AFinished(ctx context.Context, parentSessionTokenID int64, edge *doma2a.Edge, fromAgent, toAgent *domagent.DigitalEmployee, status doma2a.Status, errorCode string) {
	// F24: 所有终态路径都经过本函数; RunHooks 的 nil/幂等语义在实现侧保证。
	// 注意这一段必须在 ChatTimeline guard 之前 — timeline 未接线不代表运行轨迹不收敛。
	if s.deps.RunHooks != nil && edge != nil {
		s.deps.RunHooks.OnA2AEdgeTerminal(edge.TenantID, edge.UUID, status == doma2a.StatusDone, errorCode)
	}
	if s.deps.ChatTimeline == nil || edge == nil || fromAgent == nil || toAgent == nil || parentSessionTokenID <= 0 {
		return
	}
	s.deps.ChatTimeline.PublishA2AFinished(ctx, ChatTimelineEvent{
		ParentSessionTokenID: parentSessionTokenID,
		Edge:                 edge,
		FromAgent:            fromAgent,
		ToAgent:              toAgent,
		Status:               status,
		ErrorCode:            errorCode,
	})
}

func edgeOr(primary, fallback *doma2a.Edge) *doma2a.Edge {
	if primary != nil {
		return primary
	}
	return fallback
}

// truncateDetail audit 细节先脱敏再截断，防 runtime 错误携带凭证或内部地址。
func truncateDetail(s string) string {
	s, _ = sanitizeA2ADispatchString(s)
	const max = 500
	if len(s) <= max {
		return s
	}
	return s[:max] + "...(truncated)"
}

func approvalFormSchema(card domagent.A2ACard) []byte {
	form := map[string]any{
		"type":        "object",
		"title":       "A2A 协作审批",
		"description": "请确认是否允许该数字员工处理本次协作请求。",
		"properties": map[string]any{
			"approved": map[string]any{"type": "boolean", "title": "同意协作"},
			"comment":  map[string]any{"type": "string", "title": "审批说明"},
		},
		"required": []string{"approved"},
	}
	if card.Summary != "" {
		form["agent_summary"] = card.Summary
	}
	raw, _ := json.Marshal(form)
	return raw
}

func appendApprovalResult(payload []byte, formResult []byte, approvalUUID string) []byte {
	var root map[string]any
	if len(payload) > 0 && json.Unmarshal(payload, &root) == nil && root != nil {
		root["approval"] = approvalEnvelope(formResult, approvalUUID)
		raw, err := json.Marshal(root)
		if err == nil {
			return raw
		}
	}
	var original any = map[string]any{}
	if len(payload) > 0 {
		if err := json.Unmarshal(payload, &original); err != nil {
			original = string(payload)
		}
	}
	raw, _ := json.Marshal(map[string]any{
		"request_payload": original,
		"approval":        approvalEnvelope(formResult, approvalUUID),
	})
	return raw
}

func approvalEnvelope(formResult []byte, approvalUUID string) map[string]any {
	var result any = map[string]any{}
	if len(formResult) > 0 {
		_ = json.Unmarshal(formResult, &result)
	}
	return map[string]any{
		"approval_request_id": approvalUUID,
		"status":              "approved",
		"result":              result,
	}
}

// SweepStaleEdges (A2A v1a 悬挂兜底): 把创建时间早于 olderThan 且仍停留在 pending/running 的
// edge 批量标 failed (pending → invoker_orphaned; running → invoker_timeout)。
//
// 场景: 派发是进程内 goroutine, bus 重启 / crash 会留下悬挂 edge。cmd/bus 启动即扫一次 +
// 定时扫描。幂等: 条件 UPDATE, 多实例并发安全 (后到者影响 0 行), 无需分布式锁。
func (s *Service) SweepStaleEdges(ctx context.Context, olderThan time.Duration) (int64, error) {
	if olderThan <= 0 {
		olderThan = 10 * time.Minute
	}
	cutoff := s.deps.Now().Add(-olderThan)
	return s.deps.Edges.FailStale(ctx, cutoff, "invoker_orphaned", "invoker_timeout")
}

func (s *Service) SweepExpiredApprovals(ctx context.Context, limit int) (int64, error) {
	if s.deps.Approvals == nil {
		return 0, nil
	}
	now := s.deps.Now()
	expired, err := s.deps.Approvals.ExpirePending(ctx, now, limit)
	if err != nil {
		return 0, err
	}
	var n int64
	for _, approval := range expired {
		if approval == nil {
			continue
		}
		edge, err := s.deps.Edges.UpdateStatus(ctx, approval.TenantID, approval.EdgeUUID, approval.EdgeCreatedAt, doma2a.UpdateStatusInput{
			Status:         statusPtr(doma2a.StatusExpired),
			ErrorMessage:   strPtr("a2a.approval_expired"),
			CompletedAt:    timePtr(now),
			ExpectStatuses: []doma2a.Status{doma2a.StatusAwaitingApproval},
		})
		if err != nil {
			continue
		}
		n++
		fromAgent, ferr := s.deps.Agents.GetByID(ctx, approval.FromAgentID)
		toAgent, terr := s.deps.Agents.GetByID(ctx, approval.ToAgentID)
		if ferr == nil && terr == nil && fromAgent != nil && toAgent != nil {
			s.fireAudit(ctx, fromAgent, toAgent, "a2a.approval_expired", edge, map[string]any{
				"approval_request_id": approval.UUID,
			})
			s.publishChatA2AFinished(ctx, approval.ParentSessionTokenID, edge, fromAgent, toAgent, doma2a.StatusExpired, "a2a.approval_expired")
		}
	}
	return n, nil
}

func (s *Service) fireAudit(ctx context.Context, from, to *domagent.DigitalEmployee, kind string, edge *doma2a.Edge, extra map[string]any) {
	if s.deps.Audit == nil {
		return
	}
	payload := map[string]any{
		"from_agent_id": from.UUID,
		"to_agent_id":   to.UUID,
	}
	if edge != nil {
		payload["edge_id"] = edge.UUID
		payload["depth"] = edge.Depth
		payload["invoke_kind"] = string(edge.InvokeKind)
	}
	for k, v := range extra {
		payload[k] = v
	}
	raw, _ := json.Marshal(payload)
	ev := domaudit.Event{
		OccurredAt:   s.deps.Now(),
		TenantID:     from.TenantID,
		ActorKind:    domaudit.ActorAgent,
		Domain:       "a2a",
		EventKind:    kind,
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "a2a_call_edge",
	}
	if edge != nil {
		ev.ResourceUUID = edge.UUID
	}
	ev.Payload = raw
	_ = s.deps.Audit.Insert(ctx, ev)
}

func (s *Service) fireCancelAudit(ctx context.Context, edge *doma2a.Edge, cancelRes AgentCancellationResult) {
	if s.deps.Audit == nil || edge == nil {
		return
	}
	from, ferr := s.deps.Agents.GetByID(ctx, edge.FromAgentID)
	to, terr := s.deps.Agents.GetByID(ctx, edge.ToAgentID)
	if ferr != nil || terr != nil || from == nil || to == nil {
		return
	}
	payload := map[string]any{
		"error_code":       "a2a.cancelled",
		"cancel_delivered": cancelRes.Delivered,
	}
	if cancelRes.RuntimeKind != "" {
		payload["runtime_kind"] = cancelRes.RuntimeKind
	}
	if cancelRes.ErrorMessage != "" {
		payload["cancel_error_code"] = cancelRes.ErrorMessage
	}
	if cancelRes.InternalError != "" {
		payload["cancel_error_detail"] = truncateDetail(cancelRes.InternalError)
	}
	s.fireAudit(ctx, from, to, "a2a.cancelled", edge, payload)
}

func (s *Service) logInfo(ctx context.Context, msg string, args ...any) {
	if s == nil || s.deps.Logger == nil {
		return
	}
	s.deps.Logger.Info(ctx, msg, args...)
}

func (s *Service) logWarn(ctx context.Context, msg string, args ...any) {
	if s == nil || s.deps.Logger == nil {
		return
	}
	s.deps.Logger.Warn(ctx, msg, args...)
}

func shortA2AID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= 8 {
		return value
	}
	return value[:8]
}

func clipA2AText(value string, max int) string {
	value = strings.Join(strings.Fields(value), " ")
	if max <= 0 || len([]rune(value)) <= max {
		return value
	}
	runes := []rune(value)
	return string(runes[:max]) + "..."
}

func agentLogFields(agent *domagent.DigitalEmployee) map[string]any {
	if agent == nil {
		return map[string]any{}
	}
	return map[string]any{
		"internal_id":  agent.ID,
		"agent_id":     shortA2AID(agent.UUID),
		"name":         agent.Name,
		"tenant_id":    agent.TenantID,
		"workspace_id": ptrInt64Value(agent.WorkspaceID),
		"runtime_env":  ptrInt64Value(agent.RuntimeEnvironmentID),
	}
}

func ptrInt64Value(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}

func compactA2ACallablePolicy(raw string) map[string]any {
	p := ParseCallablePolicy(raw)
	return map[string]any{
		"mode":        p.Mode,
		"agent_count": len(p.AgentIDs),
	}
}

func summarizeA2APayload(payload []byte) map[string]any {
	out := map[string]any{
		"bytes": len(payload),
	}
	if len(payload) == 0 {
		return out
	}
	var shaped struct {
		UserText      string           `json:"user_text"`
		ContextBlocks []map[string]any `json:"context_blocks"`
		MessageBlocks []map[string]any `json:"message_blocks"`
		Blocks        []map[string]any `json:"blocks"`
		Kind          string           `json:"kind"`
	}
	if err := json.Unmarshal(payload, &shaped); err != nil {
		out["json"] = false
		return out
	}
	out["json"] = true
	if shaped.Kind != "" {
		out["kind"] = shaped.Kind
	}
	if text := strings.TrimSpace(shaped.UserText); text != "" {
		out["user_text_len"] = len([]rune(text))
	}
	blocks := shaped.ContextBlocks
	blockField := "context_blocks"
	if len(blocks) == 0 && len(shaped.MessageBlocks) > 0 {
		blocks = shaped.MessageBlocks
		blockField = "message_blocks"
	}
	if len(blocks) == 0 && len(shaped.Blocks) > 0 {
		blocks = shaped.Blocks
		blockField = "blocks"
	}
	if len(blocks) > 0 {
		types := make([]string, 0, len(blocks))
		firstText := ""
		for _, block := range blocks {
			typ := strings.TrimSpace(mapString(block, "type"))
			if typ == "" {
				typ = "(empty)"
			}
			types = append(types, typ)
			if firstText == "" {
				firstText = firstNonEmptyMapString(block, "text", "markdown", "summary")
			}
		}
		out["block_field"] = blockField
		out["block_count"] = len(blocks)
		out["block_types"] = types
		if firstText != "" {
			out["first_block_text_len"] = len([]rune(firstText))
		}
	}
	return out
}

var (
	a2aDispatchBearerRE   = regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+`)
	a2aDispatchKeyValueRE = regexp.MustCompile(`(?i)\b(session[_-]?key|bearer|token|api[_-]?key|client[_-]?secret|secret|endpoint|internal[_-]?(?:id|numeric[_-]?id)|numeric[_-]?id)\s*[:=：]\s*([^\s,;，；]+)`)
	a2aDispatchSKRE       = regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{8,}\b`)
	a2aDispatchValueRE    = regexp.MustCompile(`(?i)\bvalue://[^\s,;，；]+`)
	a2aDispatchURLRE      = regexp.MustCompile(`https?://[^\s"'<>，。；;]+`)
)

func sanitizeA2ADispatchPayload(payload []byte) []byte {
	if len(payload) == 0 {
		return payload
	}
	var data any
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.UseNumber()
	if err := dec.Decode(&data); err != nil {
		sanitized, changed := sanitizeA2ADispatchString(string(payload))
		if !changed {
			return payload
		}
		return []byte(sanitized)
	}
	changed := sanitizeA2ADispatchValue(data)
	if !changed {
		return payload
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(data); err != nil {
		return payload
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
}

func sanitizeA2ADispatchValue(v any) bool {
	changed := false
	switch val := v.(type) {
	case map[string]any:
		for k, child := range val {
			if isA2ADispatchSensitiveKey(k) {
				val[k] = "[REDACTED]"
				changed = true
				continue
			}
			if s, ok := child.(string); ok {
				cleaned, ok := sanitizeA2ADispatchString(s)
				if ok {
					val[k] = cleaned
					changed = true
				}
				continue
			}
			if sanitizeA2ADispatchValue(child) {
				changed = true
			}
		}
	case []any:
		for i, item := range val {
			if s, ok := item.(string); ok {
				cleaned, ok := sanitizeA2ADispatchString(s)
				if ok {
					val[i] = cleaned
					changed = true
				}
				continue
			}
			if sanitizeA2ADispatchValue(item) {
				changed = true
			}
		}
	}
	return changed
}

func isA2ADispatchSensitiveKey(key string) bool {
	k := strings.ToLower(strings.TrimSpace(key))
	k = strings.ReplaceAll(k, "-", "_")
	switch k {
	case "session_key", "sessionkey", "bearer", "token", "api_key", "apikey",
		"client_secret", "clientsecret", "secret", "endpoint",
		"internal_id", "internal_numeric_id", "numeric_id":
		return true
	default:
		return false
	}
}

func sanitizeA2ADispatchString(s string) (string, bool) {
	original := s
	s = a2aDispatchBearerRE.ReplaceAllString(s, "Bearer [REDACTED]")
	s = a2aDispatchKeyValueRE.ReplaceAllString(s, "$1=[REDACTED]")
	s = a2aDispatchSKRE.ReplaceAllString(s, "[REDACTED]")
	s = a2aDispatchValueRE.ReplaceAllString(s, "value://[REDACTED]")
	s = a2aDispatchURLRE.ReplaceAllStringFunc(s, func(raw string) string {
		if shouldRedactA2ADispatchURL(raw) {
			return "[REDACTED:url]"
		}
		return raw
	})
	return s, s != original
}

func shouldRedactA2ADispatchURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := strings.ToLower(strings.TrimSpace(u.Hostname()))
	if host == "" {
		return false
	}
	if host == "localhost" || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") || strings.HasSuffix(host, ".test") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast()
	}
	return false
}

func statusPtr(s doma2a.Status) *doma2a.Status { return &s }
func strPtr(s string) *string                  { return &s }
func timePtr(t time.Time) *time.Time           { return &t }
