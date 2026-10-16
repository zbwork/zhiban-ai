// chat.go — ZAP-1.1 data-plane chat client (Plan 16 Phase 2, ZAP §3 / §5)。
//
// 与 client.go (control-plane agent CRUD) 平行: 本文件**仅**负责会话/消息数据面,
// 协议路径 `/zap/v1/sessions*` 及 SSE。控制面与数据面共用 runtime API key
// (Authorization: Bearer <runtime_api_key>); session_token 由 runtime 在
// POST /sessions 响应中返回, Phase 2 MVP **不持久化、不入日志、不下发客户端**。
//
// 安全口径:
//   - runtime API key / session_token 仅设头, 绝不放进 error string / log / SSE。
//   - error_message 来自 runtime 的字段透传上层后由 finalize/transport sanitize;
//     本层不直接抛 runtime 字符串到 chat goroutine 之外。
//   - SSE 行原始字节不入 log; 只透 event 名 + 业务字段。
package zap

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DefaultChatTimeout 单条 ZAP chat session SSE 上限 (~10 min, 与 OpenClaw v3 chat 路径一致)。
const DefaultChatTimeout = 10 * time.Minute

// DefaultEnsureTimeout EnsureSession / Cancel / Delete 单次 RPC 超时。
const DefaultEnsureTimeout = 15 * time.Second

// ChatClient 是 ZAP runtime 数据面客户端 (sessions + messages SSE)。
//
// 与 control-plane *Client 解耦: chat 必须按 runtime API key 装一份独立的
// http.Client (timeout 不同 — control-plane 15s; data-plane SSE 10 min); 共用一个
// Client 会让 SSE 被 15s 超时打断。
type ChatClient struct {
	baseURL  string // 必须是 runtime 根地址; 内部拼 /zap/v1/sessions...
	token    string // runtime API key; 只设头, 不入日志
	httpc    *http.Client
	callLog  *CallLogWriter // F19: nil = no call logging
	callMeta *CallMetadata  // F19: tenant/account context for call logs
	// routingKey 多副本 runtime 的会话亲和键 (X-ZAP-Routing-Key, 如 "t1056:a2214"); ingress 按它一致性哈希,
	// 让同一用户落同一副本 (热进程 + 工作区本地缓存)。空 = 不带头。
	routingKey string
}

// RoutingHeader 多副本会话亲和头名 (与 dsh-runtime runbook / ingress 配置对齐)。
const RoutingHeader = "X-ZAP-Routing-Key"

// RoutingKeyFor 统一的亲和键: 租户 + 账号 (数字 id, 所有调用点都拿得到)。
func RoutingKeyFor(tenantID, accountID int64) string {
	return "t" + strconv.FormatInt(tenantID, 10) + ":a" + strconv.FormatInt(accountID, 10)
}

// WithChatRoutingKey 设置会话亲和键 (每次派发按 (tenant, account) 设)。
func WithChatRoutingKey(key string) ChatOption {
	return func(c *ChatClient) { c.routingKey = strings.TrimSpace(key) }
}

// ChatOption 调整构造。
type ChatOption func(*ChatClient)

// WithChatHTTPClient 单测注入 httptest server 时用。
func WithChatHTTPClient(h *http.Client) ChatOption {
	return func(c *ChatClient) {
		if h != nil {
			c.httpc = h
		}
	}
}

// WithChatCallLog F19: 启用 runtime 调用日志。
func WithChatCallLog(w *CallLogWriter, meta *CallMetadata) ChatOption {
	return func(c *ChatClient) {
		c.callLog = w
		c.callMeta = meta
	}
}

// NewChatClient 构造绑定到单 runtime 的 chat client。
//
// 注意: 这里给 httpc 设 0 timeout, 真实超时由调用方在 ctx 上控制 (EnsureSession /
// Cancel / Delete 内部用 DefaultEnsureTimeout 包 ctx; SendMessage 由 caller 用
// DefaultChatTimeout 包)。这样 SSE 不会被 http.Client.Timeout 提前打断。
func NewChatClient(baseURL, token string, opts ...ChatOption) *ChatClient {
	c := &ChatClient{
		baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		token:   token,
		httpc:   &http.Client{}, // 无 timeout; 由 ctx 控制
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// ----- 请求/响应类型 (ZAP v1.1 §3) -----

// SessionUser 创建 session 时透传给 runtime 的用户标识 (UUID-only; 绝不写 account_id 数字主键)。
type SessionUser struct {
	TenantUUID  string `json:"tenant_id"`
	AccountUUID string `json:"user_id"`
}

// ConversationContextHint ZAP v1.1 §3.1 — runtime 用于业务侧关联会话上下文。
// purpose 默认 "production"; debug 路径 Phase 2 MVP 不开放。
type ConversationContextHint struct {
	TenantID         string `json:"tenant_id,omitempty"`
	AccountID        string `json:"user_id,omitempty"`
	ConversationUUID string `json:"conversation_id,omitempty"`
	Purpose          string `json:"purpose,omitempty"`
	// A2AEdgeUUID (ZAP-1.1 §12, A2A v1a): purpose="a2a" 时关联 a2a_call_edges.uuid, runtime 可写 trace label。
	A2AEdgeUUID string `json:"a2a_edge_id,omitempty"`
}

// SessionInitiator (ZAP-1.1 §12, A2A v1a) A2A 派发会话的发起方 Agent 身份 (只读事实)。
type SessionInitiator struct {
	Kind       string `json:"kind"` // 固定 "agent"
	AgentUUID  string `json:"agent_id"`
	TenantUUID string `json:"tenant_id,omitempty"`
}

// SessionIdentity 是 ZAP identity provisioning 的轻量 session-side hint。
// Bus 当前至少传平台稳定 UUID; 若会话前已完成 /identity resolve, 可同时传 RuntimeIdentity。
type SessionIdentity struct {
	Source           string            `json:"source,omitempty"`
	TenantUUID       string            `json:"tenant_id,omitempty"`
	AccountUUID      string            `json:"user_id,omitempty"`
	ProviderIssuer   string            `json:"provider_issuer,omitempty"`
	ProviderSubject  string            `json:"provider_subject,omitempty"`
	ProviderSubjects map[string]string `json:"provider_subjects,omitempty"`
}

// SessionUserMapping 是早期协议里的匹配提示字段。Bus 新路径不再发送, 仅保留解码兼容。
type SessionUserMapping struct {
	MatchKeyKind      string `json:"match_key_kind,omitempty"`
	MatchKeyValue     string `json:"match_key_value,omitempty"`
	UnmatchedStrategy string `json:"unmatched_strategy,omitempty"`
}

// RuntimeIdentity 是 runtime /identity resolve 后的本地租户、用户和可选 Agent 实例 ID。
type RuntimeIdentity struct {
	TenantID        string `json:"tenant_id,omitempty"`
	UserID          string `json:"user_id,omitempty"`
	AgentInstanceID string `json:"agent_instance_id,omitempty"`
	MappingStatus   string `json:"mapping_status,omitempty"`
}

// IdentityAgentContext 描述本次身份初始化对应的知办AI数字员工。
// runtime 可用它创建或解析"租户 + 用户 + 数字员工"维度的本地 Agent 实例。
type IdentityAgentContext struct {
	DigitalEmployeeUUID string `json:"agent_id,omitempty"`
	AgentKey            string `json:"agent_key,omitempty"`
}

// IdentityMappingPolicy 是早期协议里的匹配策略字段。Bus 新路径不再发送, 仅保留兼容。
type IdentityMappingPolicy struct {
	IdentitySource    string `json:"identity_source,omitempty"`
	MatchKeyKind      string `json:"match_key_kind,omitempty"`
	MatchKeyValue     string `json:"match_key_value,omitempty"`
	UnmatchedStrategy string `json:"unmatched_strategy,omitempty"`
}

// LLMCredentials carries the per-(tenant, account) model gateway credentials
// that Bus may grant to a trusted external ZAP runtime during instance
// initialization. The api_key is a server-side secret: runtimes must not log it
// or forward it to browsers/mobile clients.
type LLMCredentials struct {
	BaseURL string `json:"base_url,omitempty"`
	APIKey  string `json:"api_key,omitempty"`
	Model   string `json:"model,omitempty"`
	Source  string `json:"source,omitempty"`
	Scope   string `json:"scope,omitempty"`
}

// IdentityTenantUpsertRequest PUT /zap/v1/identity/tenants/{tenant_id} body。
type IdentityTenantUpsertRequest struct {
	Tenant        map[string]any         `json:"tenant"`
	MappingPolicy *IdentityMappingPolicy `json:"mapping_policy,omitempty"`
	Metadata      map[string]any         `json:"metadata,omitempty"`
}

type IdentityTenantUpsertResponse struct {
	OK              bool             `json:"ok"`
	RuntimeIdentity *RuntimeIdentity `json:"runtime_identity,omitempty"`
	Status          string           `json:"status,omitempty"`
	// Deprecated: use runtime_identity.tenant_id.
	ExternalTenantID string `json:"external_tenant_id,omitempty"`
}

// IdentityUserProfile 是外部系统可用的用户资料。email/phone 只有在平台字段存在时才发送。
type IdentityUserProfile struct {
	AccountUUID   string `json:"user_id"`
	DisplayName   string `json:"display_name,omitempty"`
	Email         string `json:"email,omitempty"`
	EmailVerified bool   `json:"email_verified,omitempty"`
	Phone         string `json:"phone,omitempty"`
	PhoneVerified bool   `json:"phone_verified,omitempty"`
	Username      string `json:"username,omitempty"`
}

// IdentityUserUpsertRequest PUT /zap/v1/identity/users/{user_id} body。
type IdentityUserUpsertRequest struct {
	TenantUUID    string                 `json:"tenant_id"`
	User          *IdentityUserProfile   `json:"user,omitempty"`
	Identity      *SessionIdentity       `json:"identity,omitempty"`
	MappingPolicy *IdentityMappingPolicy `json:"mapping_policy,omitempty"`
}

type IdentityUserUpsertResponse struct {
	OK              bool             `json:"ok"`
	RuntimeIdentity *RuntimeIdentity `json:"runtime_identity,omitempty"`
	Status          string           `json:"status,omitempty"`
	// Deprecated: use runtime_identity.tenant_id / user_id.
	ExternalTenantID string `json:"external_tenant_id,omitempty"`
	ExternalUserID   string `json:"external_user_id,omitempty"`
}

// IdentityProvisionRequest POST /zap/v1/identity/provision body。
//
// Deprecated: new integrations should use AgentInstanceInitializeRequest with
// POST /zap/v1/instances.
type IdentityProvisionRequest struct {
	Tenant        map[string]any         `json:"tenant"`
	User          *IdentityUserProfile   `json:"user,omitempty"`
	Agent         *IdentityAgentContext  `json:"agent,omitempty"`
	Identity      *SessionIdentity       `json:"identity,omitempty"`
	LLM           *LLMCredentials        `json:"llm,omitempty"`
	Metadata      map[string]any         `json:"metadata,omitempty"`
	MappingPolicy *IdentityMappingPolicy `json:"mapping_policy,omitempty"`
}

type IdentityProvisionResponse struct {
	OK              bool             `json:"ok"`
	RuntimeIdentity *RuntimeIdentity `json:"runtime_identity,omitempty"`
	MappingStatus   string           `json:"mapping_status,omitempty"`
	MatchedBy       string           `json:"matched_by,omitempty"`
	Message         string           `json:"message,omitempty"`
	// Deprecated: use runtime_identity.
	ExternalTenantID        string `json:"external_tenant_id,omitempty"`
	ExternalUserID          string `json:"external_user_id,omitempty"`
	ExternalAgentInstanceID string `json:"external_agent_instance_id,omitempty"`
}

// AgentInstanceInitializeRequest POST /zap/v1/instances body。
// It initializes/resolves the runtime-local tenant, user, and optional
// per-user per-agent instance in one idempotent call.
type AgentInstanceInitializeRequest = IdentityProvisionRequest

// AgentInstanceInitializeResponse POST /zap/v1/instances response。
type AgentInstanceInitializeResponse = IdentityProvisionResponse

// IdentityResolveRequest POST /zap/v1/identity/users/resolve body。
type IdentityResolveRequest struct {
	TenantUUID        string                `json:"tenant_id"`
	AccountUUID       string                `json:"user_id"`
	Agent             *IdentityAgentContext `json:"agent,omitempty"`
	ProviderSubject   string                `json:"provider_subject,omitempty"`
	ProviderSubjects  map[string]string     `json:"provider_subjects,omitempty"`
	Email             string                `json:"email,omitempty"`
	EmailVerified     bool                  `json:"email_verified,omitempty"`
	Phone             string                `json:"phone,omitempty"`
	PhoneVerified     bool                  `json:"phone_verified,omitempty"`
	Username          string                `json:"username,omitempty"`
	MatchKeyKind      string                `json:"match_key_kind,omitempty"`
	MatchKeyValue     string                `json:"match_key_value,omitempty"`
	UnmatchedStrategy string                `json:"unmatched_strategy,omitempty"`
}

type IdentityResolveResponse struct {
	OK              bool             `json:"ok"`
	RuntimeIdentity *RuntimeIdentity `json:"runtime_identity,omitempty"`
	MappingStatus   string           `json:"mapping_status,omitempty"`
	ConflictReason  string           `json:"conflict_reason,omitempty"`
	// Deprecated: use runtime_identity.
	ExternalTenantID        string `json:"external_tenant_id,omitempty"`
	ExternalUserID          string `json:"external_user_id,omitempty"`
	ExternalAgentInstanceID string `json:"external_agent_instance_id,omitempty"`
}

func (r *IdentityProvisionResponse) EffectiveRuntimeIdentity() *RuntimeIdentity {
	if r == nil {
		return nil
	}
	return effectiveRuntimeIdentity(r.RuntimeIdentity, r.ExternalTenantID, r.ExternalUserID, r.ExternalAgentInstanceID, r.MappingStatus)
}

func (r *IdentityResolveResponse) EffectiveRuntimeIdentity() *RuntimeIdentity {
	if r == nil {
		return nil
	}
	return effectiveRuntimeIdentity(r.RuntimeIdentity, r.ExternalTenantID, r.ExternalUserID, r.ExternalAgentInstanceID, r.MappingStatus)
}

func effectiveRuntimeIdentity(identity *RuntimeIdentity, legacyTenantID, legacyUserID, legacyAgentInstanceID, mappingStatus string) *RuntimeIdentity {
	if identity == nil {
		identity = &RuntimeIdentity{}
	} else {
		clone := *identity
		identity = &clone
	}
	if strings.TrimSpace(identity.TenantID) == "" {
		identity.TenantID = strings.TrimSpace(legacyTenantID)
	}
	if strings.TrimSpace(identity.UserID) == "" {
		identity.UserID = strings.TrimSpace(legacyUserID)
	}
	if strings.TrimSpace(identity.AgentInstanceID) == "" {
		identity.AgentInstanceID = strings.TrimSpace(legacyAgentInstanceID)
	}
	if strings.TrimSpace(identity.MappingStatus) == "" {
		identity.MappingStatus = strings.TrimSpace(mappingStatus)
	}
	if strings.TrimSpace(identity.TenantID) == "" && strings.TrimSpace(identity.UserID) == "" &&
		strings.TrimSpace(identity.AgentInstanceID) == "" && strings.TrimSpace(identity.MappingStatus) == "" {
		return nil
	}
	return identity
}

// CreateSessionRequest POST /zap/v1/sessions body。
type CreateSessionRequest struct {
	AgentKey                string                  `json:"agent_key"`
	Agent                   *IdentityAgentContext   `json:"agent,omitempty"`
	User                    SessionUser             `json:"user"`
	SessionKind             string                  `json:"session_kind,omitempty"` // "single" / "group" / "a2a" (ZAP-1.1 §12)
	ConversationContextHint ConversationContextHint `json:"conversation_context_hint"`
	Identity                *SessionIdentity        `json:"identity,omitempty"`
	Profile                 map[string]any          `json:"profile,omitempty"`
	UserMapping             *SessionUserMapping     `json:"user_mapping,omitempty"`
	RuntimeIdentity         *RuntimeIdentity        `json:"runtime_identity,omitempty"`
	Metadata                map[string]any          `json:"metadata,omitempty"`
	// Skills ZAP-1.1 §11.1: Bus 过滤后的该数字员工技能集 (service/skill.SkillsCarrier 序列化;
	// agent_skills 带签名包 URL + builtin_skills read-only 视图)。nil = 不带该节 (runtime 视作无技能)。
	Skills any `json:"skills,omitempty"`

	// ===== A2A 派发会话字段 (ZAP-1.1 §12, A2A v1a; chat 路径不使用, 全部 omitempty) =====

	// Initiator A2A 发起方 Agent 身份; 仅 session_kind="a2a" 时填。
	Initiator *SessionInitiator `json:"initiator,omitempty"`
	// BusBackchannelToken Bus 派生的 child session token 明文 (F01 §3.6.3), 下发给被调 Agent
	// 做反向 backchannel。**字段名刻意区分** runtime 自颁的 session_token (§2.2/§5, Bus 丢弃不消费):
	// 方向相反、来源相反, 不复用旧名避免语义混淆。只随本次 body 下发一次, 不入日志。
	BusBackchannelToken string `json:"bus_backchannel_token,omitempty"`
}

// MergeRuntimeEnvironmentMetadata adds the operator-defined external runtime
// reference under a reserved namespace without mutating or replacing other
// system metadata such as llm_context.
func MergeRuntimeEnvironmentMetadata(base map[string]any, externalEnvironmentID string) map[string]any {
	externalEnvironmentID = strings.TrimSpace(externalEnvironmentID)
	if externalEnvironmentID == "" {
		return base
	}
	out := make(map[string]any, len(base)+1)
	for k, v := range base {
		out[k] = v
	}
	out["runtime_environment"] = map[string]any{"external_id": externalEnvironmentID}
	return out
}

// CreateSessionResponse runtime 返回。
//
// 安全口径 (Plan 16 §I.E + §B.2 收口):
//   - runtime 在 `POST /sessions` 响应内会带 `session_token`, 用途**仅限**未来 ZAP runtime → Bus
//     backchannel (kb.recall / mcp.invoke 等); Phase 2 MVP **不消费**, 不持久化, 不下发客户端,
//     不作为出站 header。本结构里**故意不暴露 SessionToken 字段**, 让上层 service 在编译期就
//     无法误用; raw JSON 里若出现该字段, EnsureSession 解码后立即丢弃 (见实现)。
type CreateSessionResponse struct {
	OK        bool   `json:"ok"`
	SessionID string `json:"session_id"`
	ExpiresAt string `json:"expires_at"`
	AgentKey  string `json:"agent_key"`
}

// MessageBlock 发送给 runtime 的 user message 块 (markdown/plain 文本即可)。
//
// 仅适用于"普通 text/markdown/plain"出站; 富 typed block (approval_response /
// form_response / action_callback) 必须走 SendMessageRequest.RawBlocks (map 形式),
// 否则会被强行塞进 `text` 字符串里丢失结构。
type MessageBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// SendMessageRequest POST /zap/v1/sessions/{id}/messages body。
//
// 出站 blocks 三选一 (优先级 RawBlocks > Blocks > Text):
//
//   - **Text**: `{role:"user", text:"<markdown>"}` — Send 路径默认形态 (用户文本输入);
//   - **Blocks** (`[]MessageBlock`): `{role:"user", blocks:[{type,text}]}` — 普通 typed text
//     block (markdown / plain), Send 路径在显式带 blocks 时使用;
//   - **RawBlocks** (`[]map[string]any`): `{role:"user", blocks:[{...任意 typed 富字段...}]}`
//     — ADR-0028 §4.5 HITL `/chat/respond` 专用, runtime 端要求拿到完整 typed reply block
//     (含 decision / fields / action_id / params / in_reply_to_message_id), **不允许**把富字段
//     JSON.Marshal 后塞进 `text` 字符串 (那会让 runtime 看到 `{type:"approval_response",
//     text:"{...}"}` 而非 `{type:"approval_response", decision:"approve", ...}`)。
//     非 nil 时**覆盖** Blocks 字段, 走自定义 marshal 路径 (见 SendMessage 实现)。
type SendMessageRequest struct {
	ModelService *domsource.RuntimeBinding `json:"model_service_override,omitempty"`
	Role         string                    `json:"role"` // "user"
	Text         string                    `json:"text,omitempty"`
	Blocks       []MessageBlock            `json:"blocks,omitempty"` // 普通 markdown/plain 出站; RawBlocks != nil 时被忽略
	RawBlocks    []map[string]any          `json:"-"`                // ADR-0028 §4.5 typed reply block; 不走结构体 tag (自定义 marshal)
	Metadata     map[string]any            `json:"metadata,omitempty"`
}

// ----- SSE 事件抽象 -----

// SSEEventKind ZAP v1.1 §4.5 SSE 事件名 (Phase 2 MVP completed-first)。
type SSEEventKind string

const (
	SSECreated   SSEEventKind = "message.created"
	SSECompleted SSEEventKind = "message.completed"
	SSEFailed    SSEEventKind = "message.failed"
	SSECancelled SSEEventKind = "message.cancelled"
	// SSEBlockDelta Phase 2.5: 增量流式 (markdown/plain 文本累积成 snapshot, 透出 EventMessageBlockDelta);
	// typed block (chart/form/...) 透传但不累积成可见 UI, 由 completed-first 兜底。
	SSEBlockDelta SSEEventKind = "message.block.delta"
	// SSEAwaitingUser ADR-0028 — HITL pause 事件。runtime 透出后, Bus 走 awaitFinalize:
	// messages.status='awaiting_user' + final=true, SSE 发 message.awaiting_user, 本轮 stream
	// 终态 done; 后续 ZAP 输出由 /chat/respond 起的新 stream 承接。
	SSEAwaitingUser SSEEventKind = "message.awaiting_user"

	// Round-8: tool_call / tool_result / reasoning 中间过程事件。
	// 与 OpenClaw v3 client 已有的 fanout 路径同款语义, Bus 端 zap_chat handler 直接
	// 透传给 `chat.fanout` 走 EventMessageToolCall / EventMessageToolResult /
	// EventMessageReasoning, 客户端复用现有 timeline UI 渲染。
	// 这三类都是**中间帧**, 不是终态; handler 必须返回 stop=false。
	SSEToolCall   SSEEventKind = "message.tool_call"
	SSEToolResult SSEEventKind = "message.tool_result"
	SSEReasoning  SSEEventKind = "message.reasoning"
)

// SSEEvent 反序列化后的事件数据。Blocks / Usage / ErrorCode 字段按事件类型部分填充。
// Raw 字段不出现 (data 字符串只在解析期使用, 不留到结构体里)。
type SSEEvent struct {
	Kind         SSEEventKind
	MessageID    string
	Role         string           // assistant / user
	Status       string           // "streaming" / "completed" 等
	Blocks       []map[string]any // completed 时填充; raw runtime blocks (上层 canonical mapping)
	Usage        map[string]any   // 可选
	ErrorCode    string           // failed 时填充 — runtime 给的业务码 (本层不下发客户端)
	ErrorMessage string           // failed 时填充 — runtime 给的描述 (本层 sanitize 后透上层)

	// block.delta 字段 (ZAP-1.1 §4.5)。仅 Kind=message.block.delta 时填充。
	//   - BlockIndex: runtime 给的 block 序号 (>=0; 缺省 0); 多 block 场景区分流到第几个 block。
	//   - BlockDelta: runtime 给的"增量负载"原始 map。约定:
	//       * text/markdown/plain 流式 → 至少含 {type:"markdown"|"plain", text:"<delta>"} 或
	//         {text:"<delta>"} (省略 type 时上层默认 markdown);
	//       * typed block 也可能透出 (chart/form/...), 但 Phase 2 MVP **不**累积成可见 UI,
	//         由上层 canonical mapping + completed-first 兜底, 这里仅透传。
	BlockIndex int
	BlockDelta map[string]any

	// AwaitingBlockID ADR-0028 / ZAP §5 — message.awaiting_user 事件可选字段, 标示具体哪条
	// awaiting block (approval / form / action) 在等待用户响应。客户端按此聚焦对应富组件。
	AwaitingBlockID string

	// Round-8: tool_call / tool_result / reasoning 字段 (与 OpenClaw v3 透出形态对齐)。
	//   - tool_call_id / tool_name / tool_status: SSEToolCall + SSEToolResult 共用;
	//   - tool_args / tool_args_delta: SSEToolCall;
	//   - tool_result / tool_result_delta: SSEToolResult;
	//   - reasoning: SSEReasoning (单个 delta 文本, 客户端累积渲染)。
	ToolCallID      string
	ToolName        string
	ToolStatus      string
	ToolArgs        string
	ToolArgsDelta   string
	ToolResult      string
	ToolResultDelta string
	Reasoning       string
}

// SSEEventHandler 由上层 (chat/zap_chat.go) 实现; 返回 stop=true 时立刻终止读循环。
// 错误返回向上抛, 由 caller finalize 成 message.failed。
type SSEEventHandler func(ev SSEEvent) (stop bool, err error)

// ----- 错误类型 -----

// ChatAPIError ZAP 数据面调用归一化错误 (与 control-plane APIError 一致语义; 不含 token)。
type ChatAPIError struct {
	StatusCode int
	Code       string
	Message    string
}

func (e *ChatAPIError) Error() string {
	if e == nil {
		return ""
	}
	if e.Code != "" {
		return fmt.Sprintf("zap chat http %d [%s]: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("zap chat http %d: %s", e.StatusCode, e.Message)
}

// IsRetryable 网络层 (StatusCode==0) 或 5xx → 可重试; 4xx 终态。
func (e *ChatAPIError) IsRetryable() bool {
	if e == nil {
		return false
	}
	return e.StatusCode == 0 || e.StatusCode >= 500
}

// IsNotFound runtime 返 404 (session 不存在/过期)。
func (e *ChatAPIError) IsNotFound() bool {
	if e == nil {
		return false
	}
	if e.StatusCode == http.StatusNotFound {
		return true
	}
	low := strings.ToLower(e.Code)
	return strings.Contains(low, "session_not_found") || strings.Contains(low, "not_found")
}

// IsCancelled runtime 返 409 zap.session_cancelled。
func (e *ChatAPIError) IsCancelled() bool {
	if e == nil {
		return false
	}
	low := strings.ToLower(e.Code)
	return strings.Contains(low, "session_cancelled")
}

// ----- 方法 -----

// EnsureSession 创建一个 ZAP session。caller 若有可复用的 session_id 应优先调
// SendMessage; 失败 (404/409) 再回退 EnsureSession 重建。
// ctx 推荐 DefaultEnsureTimeout。
//
// 安全 (Plan 16 §I.E):
//   - runtime 响应 body 里可能含 `session_token` 字段; CreateSessionResponse 结构**故意**
//     不映射该字段 → json.Unmarshal 自然丢弃, 既不入返回值也不入内存。
//   - 调用方拿不到 session_token, 因此**无法**误用作出站 header / DB 写入 / 日志参数。
func (c *ChatClient) EnsureSession(ctx context.Context, req *CreateSessionRequest) (*CreateSessionResponse, error) {
	if req == nil || strings.TrimSpace(req.AgentKey) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "EnsureSession: empty agent_key"}
	}
	if req.SessionKind == "" {
		req.SessionKind = "single"
	}
	if req.ConversationContextHint.Purpose == "" {
		req.ConversationContextHint.Purpose = "production"
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out CreateSessionResponse
	if err := c.doJSON(callCtx, http.MethodPost, "/zap/v1/sessions", req, &out); err != nil {
		return nil, err
	}
	if !out.OK || out.SessionID == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "EnsureSession: runtime returned ok=false or empty session_id"}
	}
	return &out, nil
}

// InitializeAgentInstance 登录预热/会话兜底时一次性初始化当前用户的外部数字员工实例。
func (c *ChatClient) InitializeAgentInstance(ctx context.Context, req *AgentInstanceInitializeRequest) (*AgentInstanceInitializeResponse, error) {
	if req == nil || req.User == nil || strings.TrimSpace(req.User.AccountUUID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "InitializeAgentInstance: missing user"}
	}
	if req.Agent == nil || strings.TrimSpace(req.Agent.DigitalEmployeeUUID) == "" && strings.TrimSpace(req.Agent.AgentKey) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "InitializeAgentInstance: missing agent"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out AgentInstanceInitializeResponse
	if err := c.doJSON(callCtx, http.MethodPost, "/zap/v1/instances", req, &out); err != nil {
		return nil, err
	}
	identity := out.EffectiveRuntimeIdentity()
	if !out.OK || identity == nil || strings.TrimSpace(identity.UserID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "InitializeAgentInstance: runtime returned empty runtime_identity.user_id"}
	}
	return &out, nil
}

// ProvisionIdentity 会话前一次性初始化/解析租户与用户。
//
// Deprecated: use InitializeAgentInstance.
func (c *ChatClient) ProvisionIdentity(ctx context.Context, req *IdentityProvisionRequest) (*IdentityProvisionResponse, error) {
	if req == nil || req.User == nil || strings.TrimSpace(req.User.AccountUUID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "ProvisionIdentity: missing user"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out IdentityProvisionResponse
	if err := c.doJSON(callCtx, http.MethodPost, "/zap/v1/identity/provision", req, &out); err != nil {
		return nil, err
	}
	identity := out.EffectiveRuntimeIdentity()
	if !out.OK || identity == nil || strings.TrimSpace(identity.UserID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "ProvisionIdentity: runtime returned empty runtime_identity.user_id"}
	}
	return &out, nil
}

// UpsertIdentityTenant 会话前同步租户影子记录。
func (c *ChatClient) UpsertIdentityTenant(ctx context.Context, tenantID string, req *IdentityTenantUpsertRequest) (*IdentityTenantUpsertResponse, error) {
	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "UpsertIdentityTenant: empty tenant_id"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out IdentityTenantUpsertResponse
	path := "/zap/v1/identity/tenants/" + url.PathEscape(tenantID)
	if err := c.doJSON(callCtx, http.MethodPut, path, req, &out); err != nil {
		return nil, err
	}
	if !out.OK {
		return nil, &ChatAPIError{StatusCode: 0, Message: "UpsertIdentityTenant: runtime returned ok=false"}
	}
	return &out, nil
}

// UpsertIdentityUser 会话前同步用户影子记录。
func (c *ChatClient) UpsertIdentityUser(ctx context.Context, userID string, req *IdentityUserUpsertRequest) (*IdentityUserUpsertResponse, error) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "UpsertIdentityUser: empty user_id"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out IdentityUserUpsertResponse
	path := "/zap/v1/identity/users/" + url.PathEscape(userID)
	if err := c.doJSON(callCtx, http.MethodPut, path, req, &out); err != nil {
		return nil, err
	}
	if !out.OK {
		return nil, &ChatAPIError{StatusCode: 0, Message: "UpsertIdentityUser: runtime returned ok=false"}
	}
	return &out, nil
}

// ResolveIdentityUser 会话前把平台身份事实交给 runtime, 由 runtime 解析自己的本地用户。
func (c *ChatClient) ResolveIdentityUser(ctx context.Context, req *IdentityResolveRequest) (*IdentityResolveResponse, error) {
	if req == nil || strings.TrimSpace(req.TenantUUID) == "" || strings.TrimSpace(req.AccountUUID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "ResolveIdentityUser: missing required identity fields"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	var out IdentityResolveResponse
	if err := c.doJSON(callCtx, http.MethodPost, "/zap/v1/identity/users/resolve", req, &out); err != nil {
		return nil, err
	}
	identity := out.EffectiveRuntimeIdentity()
	if !out.OK || identity == nil || strings.TrimSpace(identity.UserID) == "" {
		return nil, &ChatAPIError{StatusCode: 0, Message: "ResolveIdentityUser: runtime returned empty runtime_identity.user_id"}
	}
	return &out, nil
}

// SendMessage POST /zap/v1/sessions/{id}/messages, 消费 SSE 直到 handler 返回 stop=true,
// 或流自然 EOF, 或 ctx cancel/timeout。SSE 上限由 caller 用 DefaultChatTimeout 包 ctx。
//
// 安全口径 (Plan 16 §B.2 / §I.E):
//   - 出站头**只**有 `Authorization: Bearer <runtime API key>`;
//   - **绝不** 设置 `X-ZAP-Session-Token` 或任何 session_token 形式 header;
//   - Phase 2 MVP 不消费 session_token, 因此没有 sessionToken 参数, 编译期阻止 caller 误传。
//   - runtime 反向 backchannel 用 session_token 是 Phase 3/4 设计, 留在那时再加单独头。
func (c *ChatClient) SendMessage(ctx context.Context, sessionID string, req *SendMessageRequest, h SSEEventHandler) error {
	if strings.TrimSpace(sessionID) == "" {
		return &ChatAPIError{StatusCode: 0, Message: "SendMessage: empty session_id"}
	}
	if req == nil || (strings.TrimSpace(req.Text) == "" && len(req.Blocks) == 0 && len(req.RawBlocks) == 0) {
		return &ChatAPIError{StatusCode: 0, Message: "SendMessage: empty user message"}
	}
	if req.Role == "" {
		req.Role = "user"
	}
	start := time.Now()
	path := "/zap/v1/sessions/" + url.PathEscape(sessionID) + "/messages"
	operation := "zap.dispatch"
	ctx, span := startRuntimeHTTPSpan(ctx, "zap", operation, http.MethodPost, path)
	statusForSpan := 0
	errForSpan := ""
	defer func() { finishRuntimeHTTPSpan(span, statusForSpan, errForSpan) }()
	// 富 typed reply block (ADR-0028 §4.5) 走 RawBlocks: 用 map 自定义 marshal, 而**不**塞到 Blocks
	// 结构体 (后者只支持 {type,text})。普通 text/markdown 路径仍走原 struct marshal。
	var (
		buf []byte
		err error
	)
	if len(req.RawBlocks) > 0 {
		body := map[string]any{
			"role":   req.Role,
			"blocks": req.RawBlocks,
		}
		if strings.TrimSpace(req.Text) != "" {
			body["text"] = req.Text
		}
		if len(req.Metadata) > 0 {
			body["metadata"] = req.Metadata
		}
		if req.ModelService != nil {
			body["model_service_override"] = req.ModelService
		}
		buf, err = json.Marshal(body)
	} else {
		buf, err = json.Marshal(req)
	}
	if err != nil {
		return &ChatAPIError{StatusCode: 0, Message: "marshal SendMessage body"}
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(buf))
	if err != nil {
		return &ChatAPIError{StatusCode: 0, Message: "build request POST " + path}
	}
	httpReq.Header.Set("Content-Type", "application/json; charset=utf-8")
	httpReq.Header.Set("Accept", "text/event-stream")
	if c.token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.httpc.Do(httpReq)
	if err != nil {
		errForSpan = "transport error"
		c.logCall(ctx, operation, http.MethodPost, path, buf, nil, 0, start, errForSpan, map[string]any{"session_id": sessionID})
		return &ChatAPIError{StatusCode: 0, Message: "transport error"}
	}
	statusForSpan = resp.StatusCode
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		zapErr := readZapError(resp)
		errForSpan = zapErr.Error()
		c.logCall(ctx, operation, http.MethodPost, path, buf, nil, resp.StatusCode, start, errForSpan, map[string]any{"session_id": sessionID})
		return zapErr
	}
	recorder := newSSECallLogRecorder()
	sseErr := parseSSE(resp.Body, recorder.wrap(h))
	// F19: log SSE call as ONE aggregated entry (status from initial response, latency = full stream duration)
	sseErrMsg := ""
	if sseErr != nil && !errors.Is(sseErr, ErrSSEStopByHandler) {
		sseErrMsg = sseErr.Error()
	}
	errForSpan = sseErrMsg
	c.logCall(ctx, operation, http.MethodPost, path, buf, recorder.body(), resp.StatusCode, start, sseErrMsg, map[string]any{"session_id": sessionID})
	if sseErr != nil {
		// handler 返回 stop=true 是 graceful 终止信号, 不算错; 内部 sentinel 不外抛。
		if errors.Is(sseErr, ErrSSEStopByHandler) {
			return nil
		}
		return sseErr
	}
	return nil
}

// Cancel 标记 session 为 cancelled。runtime 收到后下一次 SendMessage 立刻返 409。
func (c *ChatClient) Cancel(ctx context.Context, sessionID string) error {
	if strings.TrimSpace(sessionID) == "" {
		return &ChatAPIError{StatusCode: 0, Message: "Cancel: empty session_id"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	path := "/zap/v1/sessions/" + url.PathEscape(sessionID) + "/cancel"
	return c.doJSON(callCtx, http.MethodPost, path, nil, nil)
}

// Delete 删除 session。runtime 应清掉 in-memory state。
func (c *ChatClient) Delete(ctx context.Context, sessionID string) error {
	if strings.TrimSpace(sessionID) == "" {
		return &ChatAPIError{StatusCode: 0, Message: "Delete: empty session_id"}
	}
	callCtx, cancel := context.WithTimeout(ctx, DefaultEnsureTimeout)
	defer cancel()
	path := "/zap/v1/sessions/" + url.PathEscape(sessionID)
	return c.doJSON(callCtx, http.MethodDelete, path, nil, nil)
}

// ----- 内部 -----

// doJSON 通用 JSON RPC; 4xx/5xx → *ChatAPIError (不含 token)。
func (c *ChatClient) doJSON(ctx context.Context, method, path string, body any, out any) error {
	start := time.Now()
	operation := zapOperation(path)
	ctx, span := startRuntimeHTTPSpan(ctx, "zap", operation, method, path)
	statusForSpan := 0
	errForSpan := ""
	defer func() { finishRuntimeHTTPSpan(span, statusForSpan, errForSpan) }()
	var reqBodyBytes []byte
	var reqBody io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return &ChatAPIError{StatusCode: 0, Message: "marshal request"}
		}
		reqBodyBytes = buf
		reqBody = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, reqBody)
	if err != nil {
		return &ChatAPIError{StatusCode: 0, Message: "build request " + method + " " + path}
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if c.routingKey != "" {
		req.Header.Set(RoutingHeader, c.routingKey)
	}
	resp, err := c.httpc.Do(req)
	if err != nil {
		errForSpan = "transport error"
		c.logCall(ctx, operation, method, path, reqBodyBytes, nil, 0, start, errForSpan, nil)
		return &ChatAPIError{StatusCode: 0, Message: "transport error"}
	}
	statusForSpan = resp.StatusCode
	defer resp.Body.Close()
	raw, readCode := readJSONResponse(resp)
	if readCode != "" {
		errForSpan = readCode
		c.logCall(ctx, operation, method, path, reqBodyBytes, nil, resp.StatusCode, start, errForSpan, nil)
		return &ChatAPIError{StatusCode: resp.StatusCode, Code: readCode, Message: readCode}
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		apiErr := &ChatAPIError{StatusCode: resp.StatusCode, Message: truncate(string(raw), 200)}
		var er zapErrorResponse
		if json.Unmarshal(raw, &er) == nil && er.Error.Code != "" {
			apiErr.Code = er.Error.Code
			apiErr.Message = er.Error.Message
		}
		errForSpan = apiErr.Message
		c.logCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, errForSpan, nil)
		return apiErr
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			errForSpan = "decode response"
			c.logCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, errForSpan, nil)
			return &ChatAPIError{StatusCode: resp.StatusCode, Message: "decode response"}
		}
	}
	c.logCall(ctx, operation, method, path, reqBodyBytes, raw, resp.StatusCode, start, "", nil)
	return nil
}

func (c *ChatClient) logCall(ctx context.Context, operation, method, path string, reqBody, respBody []byte, status int, start time.Time, errMsg string, tags map[string]any) {
	if c.callLog == nil {
		return
	}
	c.callLog.writeCallLog(ctx, c.callMeta, "zap", operation, method, path, reqBody, respBody, status, int(time.Since(start).Milliseconds()), errMsg, tags)
}

type sseCallLogRecorder struct {
	counts   map[string]int
	terminal map[string]any
}

func newSSECallLogRecorder() *sseCallLogRecorder {
	return &sseCallLogRecorder{counts: make(map[string]int)}
}

func (r *sseCallLogRecorder) wrap(next SSEEventHandler) SSEEventHandler {
	return func(ev SSEEvent) (bool, error) {
		r.counts[string(ev.Kind)]++
		if isTerminalSSE(ev.Kind) {
			r.terminal = sseEventLogPayload(ev)
		}
		if next == nil {
			return false, nil
		}
		return next(ev)
	}
}

func (r *sseCallLogRecorder) body() []byte {
	payload := map[string]any{"sse": map[string]any{"event_counts": r.counts}}
	if r.terminal != nil {
		payload["sse"].(map[string]any)["terminal_event"] = r.terminal
	}
	out, _ := json.Marshal(payload)
	return out
}

func isTerminalSSE(kind SSEEventKind) bool {
	switch kind {
	case SSECompleted, SSEFailed, SSECancelled, SSEAwaitingUser:
		return true
	default:
		return false
	}
}

func sseEventLogPayload(ev SSEEvent) map[string]any {
	return map[string]any{
		"kind":              ev.Kind,
		"message_id":        ev.MessageID,
		"role":              ev.Role,
		"status":            ev.Status,
		"blocks":            ev.Blocks,
		"usage":             ev.Usage,
		"error_code":        ev.ErrorCode,
		"error_message":     ev.ErrorMessage,
		"awaiting_block_id": ev.AwaitingBlockID,
	}
}

func zapOperation(path string) string {
	switch {
	case path == "/zap/v1/sessions":
		return "zap.session_create"
	case strings.HasPrefix(path, "/zap/v1/sessions/") && strings.HasSuffix(path, "/messages"):
		return "zap.dispatch"
	case strings.HasPrefix(path, "/zap/v1/sessions/") && strings.HasSuffix(path, "/cancel"):
		return "zap.session_cancel"
	case strings.HasPrefix(path, "/zap/v1/sessions/"):
		return "zap.session_delete"
	case path == "/zap/v1/instances":
		return "zap.instance_initialize"
	case path == "/zap/v1/runtime_card":
		return "zap.runtime_card"
	case path == "/zap/v1/agents":
		return "zap.agent_collection"
	case strings.HasPrefix(path, "/zap/v1/agents/"):
		return "zap.agent"
	case strings.HasPrefix(path, "/zap/v1/tenants/"):
		return "zap.tenant_upsert"
	case path == "/zap/v1/identity/provision":
		return "zap.identity_provision"
	case path == "/zap/v1/identity/users/resolve":
		return "zap.identity_resolve"
	case strings.HasPrefix(path, "/zap/v1/identity/tenants/"):
		return "zap.identity_tenant_upsert"
	case strings.HasPrefix(path, "/zap/v1/identity/users/"):
		return "zap.identity_user_upsert"
	default:
		return "zap.http"
	}
}

// readZapError 读取非 2xx 响应正文并归一化为 *ChatAPIError。
func readZapError(resp *http.Response) error {
	raw, readCode := readJSONResponse(resp)
	if readCode != "" {
		return &ChatAPIError{StatusCode: resp.StatusCode, Code: readCode, Message: readCode}
	}
	apiErr := &ChatAPIError{StatusCode: resp.StatusCode, Message: truncate(string(raw), 200)}
	var er zapErrorResponse
	if json.Unmarshal(raw, &er) == nil && er.Error.Code != "" {
		apiErr.Code = er.Error.Code
		apiErr.Message = er.Error.Message
	}
	return apiErr
}

// ErrSSEStopByHandler 是哨兵: handler 返回 stop=true 时 parseSSE 用它结束读循环。
// caller (SendMessage / 上层) 检测到这个 err 应静默吞掉。
var ErrSSEStopByHandler = errors.New("zap: sse stopped by handler")

// parseSSE 按 W3C SSE 简化规则读 event/data 行; 每个 event block 由空行结束;
// 解码后调 handler。handler 返回 (stop=true, nil) → 静默结束。
// 解析行单条最大 1 MiB; 单次 data 累积上限 4 MiB (防内存爆)。
func parseSSE(body io.Reader, h SSEEventHandler) error {
	const (
		maxLineSize = 1 << 20 // 1 MiB
		maxDataSize = 4 << 20 // 4 MiB per event
	)
	r := bufio.NewReaderSize(body, 1<<16)
	var (
		eventName string
		dataBuf   bytes.Buffer
	)
	dispatch := func() error {
		if eventName == "" && dataBuf.Len() == 0 {
			return nil
		}
		raw := dataBuf.Bytes()
		dataBuf.Reset()
		name := eventName
		eventName = ""
		if name == "" {
			// 默认 event 名 (W3C) = "message"; ZAP 不用, 视为忽略。
			return nil
		}
		ev := SSEEvent{Kind: SSEEventKind(name)}
		// data 行可能多次累积 → 试 JSON; 解码失败 → 上层透为 zap_sse_decode_failed。
		var payload map[string]any
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &payload); err != nil {
				return &ChatAPIError{StatusCode: 0, Code: "zap.sse_decode_failed", Message: "decode SSE data"}
			}
		}
		if v, ok := payload["message_id"].(string); ok {
			ev.MessageID = v
		}
		if v, ok := payload["role"].(string); ok {
			ev.Role = v
		}
		if v, ok := payload["status"].(string); ok {
			ev.Status = v
		}
		if v, ok := payload["error_code"].(string); ok {
			ev.ErrorCode = v
		}
		if v, ok := payload["error_message"].(string); ok {
			ev.ErrorMessage = v
		}
		if blocks, ok := payload["blocks"].([]any); ok {
			ev.Blocks = make([]map[string]any, 0, len(blocks))
			for _, b := range blocks {
				if bm, ok := b.(map[string]any); ok {
					ev.Blocks = append(ev.Blocks, bm)
				}
			}
		}
		if usage, ok := payload["usage"].(map[string]any); ok {
			ev.Usage = usage
		}
		// block.delta 字段 (ZAP-1.1 §4.5: `{message_id, block_index, block_delta}`)。
		if bi, ok := payload["block_index"].(float64); ok {
			ev.BlockIndex = int(bi)
		}
		if bd, ok := payload["block_delta"].(map[string]any); ok {
			ev.BlockDelta = bd
		}
		// message.awaiting_user 字段 (ADR-0028 / ZAP §5):
		//   - awaiting_block_id (optional): 等待响应的具体 block id。
		if abid, ok := payload["awaiting_block_id"].(string); ok {
			ev.AwaitingBlockID = abid
		}
		// Round-8: tool_call / tool_result / reasoning 字段 — 与 OpenClaw v3 fanout 对齐;
		// runtime 透出的 SSE payload 直接 map 到 SSEEvent 字段, Bus 层不做语义改写。
		if v, ok := payload["tool_call_id"].(string); ok {
			ev.ToolCallID = v
		}
		if v, ok := payload["tool_name"].(string); ok {
			ev.ToolName = v
		}
		if v, ok := payload["tool_status"].(string); ok {
			ev.ToolStatus = v
		}
		if v, ok := payload["tool_args"].(string); ok {
			ev.ToolArgs = v
		}
		if v, ok := payload["tool_args_delta"].(string); ok {
			ev.ToolArgsDelta = v
		}
		if v, ok := payload["tool_result"].(string); ok {
			ev.ToolResult = v
		}
		if v, ok := payload["tool_result_delta"].(string); ok {
			ev.ToolResultDelta = v
		}
		if v, ok := payload["reasoning"].(string); ok {
			ev.Reasoning = v
		} else if v, ok := payload["text"].(string); ok && ev.Kind == SSEReasoning {
			// reasoning 事件的 "text" 字段也接收 (runtime 命名差异容错)
			ev.Reasoning = v
		}
		stop, herr := h(ev)
		if herr != nil {
			return herr
		}
		if stop {
			return ErrSSEStopByHandler
		}
		return nil
	}
	for {
		line, err := r.ReadString('\n')
		if len(line) > maxLineSize {
			return &ChatAPIError{StatusCode: 0, Code: "zap.sse_line_too_large", Message: "sse line exceeds limit"}
		}
		// 处理行内容 (即使遇到 EOF, 上一段 line 已读到也要 dispatch)
		trimmed := strings.TrimRight(line, "\r\n")
		if trimmed == "" {
			if derr := dispatch(); derr != nil {
				return derr
			}
		} else if strings.HasPrefix(trimmed, ":") {
			// comment line, 忽略
		} else if strings.HasPrefix(trimmed, "event:") {
			eventName = strings.TrimSpace(trimmed[len("event:"):])
		} else if strings.HasPrefix(trimmed, "data:") {
			payload := strings.TrimPrefix(trimmed[len("data:"):], " ")
			if dataBuf.Len()+len(payload)+1 > maxDataSize {
				return &ChatAPIError{StatusCode: 0, Code: "zap.sse_data_too_large", Message: "sse data exceeds limit"}
			}
			if dataBuf.Len() > 0 {
				dataBuf.WriteByte('\n')
			}
			dataBuf.WriteString(payload)
		}
		// 其它字段 (id: / retry:) 不消费, 按 W3C 忽略即可。
		if err != nil {
			if errors.Is(err, io.EOF) {
				_ = dispatch() // 最后一段; 错误吞掉, 上层按 EOF 自然结束
				return nil
			}
			return &ChatAPIError{StatusCode: 0, Code: "zap.sse_read_failed", Message: "sse read"}
		}
	}
}

// (与 control-plane client 共用 zapErrorResponse / truncate; 它们定义在 client.go)
// 这里复用同包符号, 不再重复声明。
