// dispatch.go — Plan 16 Phase 2: framework dispatch (Send + queue worker)。
//
// 现状口径 (Phase 2 落地后):
//   - runtime_environments.framework='openclaw'  → 原 resolveOpenClawV3Endpoint + runAgentGoroutine 路径 (T2D.1)
//   - runtime_environments.framework='zap'       → 走 runZapChatGoroutine (本文件 §runZapDispatch)
//   - runtime_environments.framework='hermes'    → Phase 3B: 走 runHermesChatGoroutine (/v1/chat/completions SSE)
//   - 其它                                        → fail-closed errProtocolUnsupported
//
// 设计目的:
//   - 把 framework 分流提到 chat 服务上层, 不在 OpenClaw resolver 里兼容 ZAP
//     (避免 docs/pitfalls/zap-chat-not-wired.md §6 禁止的"在 OpenClaw resolver 里兼容 ZAP")。
//   - Send 同步路径 + 队列 worker executeQueuedTask 都用同一个 dispatch, 保证两条路径
//     口径完全一致 (失败码 / metadata 副作用 / SSE event 顺序)。
//   - 单测可 mock ZapDispatcher 不需要拉真实 HTTP runtime。

package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	dommstream "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/messagestream"
)

const (
	FrameworkGeneric        = "generic"
	FrameworkOpenClaw       = "openclaw"
	FrameworkZap            = "zap"
	FrameworkDSH            = "dsh" // 平台自营 dsh 运行时: ZAP 线 + 平台策略 (ADR-0035 修订)
	FrameworkHermes         = "hermes"
	FrameworkSupportBuiltin = "support_builtin"
)

// RuntimeEnvFrameworkLookup chat 服务对 runtime_environments 仓库的窄接口:
// 只读 framework 字段。装配走 reporuntimeenv.New(pool) 的 GetByID 适配器。
type RuntimeEnvFrameworkLookup interface {
	GetFrameworkByID(ctx context.Context, id int64) (framework string, err error)
}

// ZapDispatchInput Send / queue worker 调 ZAP 路径时传给 dispatcher 的归一化入参。
//
// 不直接复用 runAgentInternalIn / runAgentGoroutine 的整套参数, 因为 ZAP 路径:
//   - 不需要 verParams (snapshot model / system prompt 由 runtime 自管)
//   - endpoint/bearer 现场从 runtime_environments 解析 (不走 openclaw resolver)
//   - prompt/text 与原始 user blocks 分开传, ZAP 出站保留多模态 block 元数据
type ZapDispatchInput struct {
	StreamID         string
	AccountID        int64
	TenantID         int64
	Conversation     *domconv.Conversation
	RoomUUID         string
	Agent            *domagent.DigitalEmployee
	PromptText       string
	UserBlocks       []map[string]any
	AgentMessageUUID string
	UserMessageUUID  string
	InputMessageUUID string
	// UserMetadata 已落库 user 消息的 metadata (含 F03 active_skill_* / skill_params); 出站只透传白名单键。
	UserMetadata map[string]any
}

// ZapRespondInput ADR-0028 §4.4 — `/chat/respond` 二次入口入参。
//
// service 层在 §4.6 步骤 4 生成 NewStreamID + NewAgentMessageUUID, 在 §4.6 步骤 6 通过
// transactional helper 把 message_streams + messages 行 INSERT 到 DB (commit 成功), 然后
// 把这一对 id 透给 dispatcher; dispatcher 直接复用 conversation.metadata.zap_session_id
// 发送 typed reply block, 不重新 EnsureSession (session 已在原轮次成功创建)。
type ZapRespondInput struct {
	NewStreamID         string // 新 stream_id (RandomHex; tx 已 commit, 真实存在)
	NewAgentMessageUUID string // 新 agent message uuid (uuid.New; tx 已 commit, 真实存在)
	AccountID           int64
	TenantID            int64
	Conversation        *domconv.Conversation // 含 metadata.zap_session_id
	RoomUUID            string                // single-chat = "" (HITL 当前只支持 single-chat)
	Agent               *domagent.DigitalEmployee
	AwaitingMessageUUID string // 之前 awaiting_user 的旧 message uuid (claim 后已转 final;
	// 仅供 reply block 的 in_reply_to_message_id 字段引用)
	ResponseKind string         // "approval" / "form" / "action" / "confirm"
	ReplyBlock   map[string]any // service 层组装好的 typed block (见 ADR §4.5)
}

// ZapDispatcher chat 服务对 ZAP 数据面 adapter 的窄接口。
//
// 单一职责: 拿到上面 In, 完成: EnsureSession / SendMessage / 消费 SSE /
// 调 finalize(...) 出 message.completed|failed|cancelled。返回值仅用于错误诊断
// (典型实现总返 nil, 失败已在 finalize 出 SSE failed)。
//
// CancelStream (Stage 3): 给 chat.Stop 路径调; best-effort 调 runtime `/sessions/:id/cancel`。
// 该方法**不**写客户端 SSE / 不动 messages 行 / 不动 fanout (那些由 stopLocalStream + finalize 收尾);
// 仅负责"通知 ZAP runtime 这个 session 停止生产"。返回 nil 也可能是"没有 ZAP 状态可 cancel" (例如
// streamID 对应的是 OpenClaw stream, 或 dispatcher 已清理), 调用方按 noop 处理。
//
// RespondToAwaitingMessage (ADR-0028 §4.4) — HITL `/chat/respond` 二次入口。复用现有
// session_id 把 typed reply block 发回 ZAP, 消费 SSE → finalize 新 stream 终态。session_token
// 仍**不**出站, 只用 runtime API key (Authorization)。
type ZapDispatcher interface {
	Send(ctx context.Context, in ZapDispatchInput) error
	CancelStream(ctx context.Context, streamID string)
	RespondToAwaitingMessage(ctx context.Context, in ZapRespondInput) error
}

// errZapDispatcherMissing 装配遗漏 sentinel; dispatchByFramework 据此包成 protocol_unsupported。
var errZapDispatcherMissing = errors.New("chat: zap dispatcher not wired")

// dispatchSend Send 同步路径 (queueEnabled=false) 走的分流。返回:
//   - nil → 已成功启动 (goroutine spawn / SSE 已订阅); caller 不再做额外 publish
//   - err → 装配错 / framework 不支持; caller 转 errProtocolUnsupported
//
// 注意: dispatchSend **不再**做 resolveOpenClawV3Endpoint —— OpenClaw 路径的 endpoint
// 解析仍由现有 Send (line 700+) 同步完成, 这里只决定"接下来是单体 runtime 还是 ZAP"。
//
// 因此当前 Send 函数对 ZAP framework 的实际改造点是: 在调用 resolveOpenClawV3Endpoint 之前
// 先查 framework, framework='zap' → 跳过 OpenClaw 解析, 走 runZapChatGoroutine。
//
// (本 dispatcher 接口面向未来扩展 hermes / 第三种 runtime 时不动 Send 主体。)

// frameworkForAgent 查 agent 绑定的 runtime_environments.framework。
//
// 兼容口径:
//   - runtimeEnvs 未装 (legacy 测试路径) → 回退 "openclaw" (保留 Plan 16 Phase 2 之前的行为,
//     现有所有单测不感知 framework dispatch)。生产 cmd/bus 必装 lookup, 此回退仅供单测。
//   - 仓库错误 / framework 为空 / agent 缺 runtime_environment_id → errProtocolUnsupported。
func (s *impl) frameworkForAgent(ctx context.Context, ag *domagent.DigitalEmployee, runtimeEnvs RuntimeEnvFrameworkLookup) (string, error) {
	if ag == nil {
		return "", fmt.Errorf("%w: agent nil", errProtocolUnsupported)
	}
	if ag.ExecutionLocus == "local" {
		return FrameworkDSH, nil
	}
	if isSupportBuiltinAgent(ag) {
		return FrameworkSupportBuiltin, nil
	}
	if runtimeEnvs == nil {
		// legacy 测试 / 未装 ZAP dispatch 的部署: 默认 openclaw。openclaw 路径自带 runtime_environment_id
		// 守卫 (resolveOpenClawV3Endpoint 内对 nil 已 fail-closed), 这里不重复校验。
		return FrameworkOpenClaw, nil
	}
	if ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID <= 0 {
		return "", fmt.Errorf("%w: agent has no runtime_environment_id", errProtocolUnsupported)
	}
	fw, err := runtimeEnvs.GetFrameworkByID(ctx, *ag.RuntimeEnvironmentID)
	if err != nil {
		return "", err
	}
	fw = strings.ToLower(strings.TrimSpace(fw))
	if fw == "" {
		return "", fmt.Errorf("%w: runtime_environments.framework empty for id=%d", errProtocolUnsupported, *ag.RuntimeEnvironmentID)
	}
	return fw, nil
}

// dispatchZapSend 把当前 stream 转交给 ZAP dispatcher。在 Send / queue worker 收尾路径外
// 不写消息 / 不 publish — 假定 caller 已经发完 message.created 并把 streamID
// register 到 fanout。
func (s *impl) dispatchZapSend(ctx context.Context, in ZapDispatchInput) error {
	if s.zapDispatcher == nil {
		return errZapDispatcherMissing
	}
	if s.identityResolver == nil {
		return fmt.Errorf("%w: identity resolver not wired", errProtocolUnsupported)
	}
	return s.zapDispatcher.Send(ctx, in)
}

// runtimeEnvFrameworkLookup chat 服务持有的 runtime_env framework lookup; nil → 当前 framework
// 分流不可用, dispatchByFramework 把所有非 openclaw 都 fail-closed (旧行为)。
// 暴露为字段供 setter 注入 (避免改 NewWithStopRetry 签名)。
func (s *impl) runtimeEnvFrameworkLookup() RuntimeEnvFrameworkLookup { return s.runtimeEnvFW }

// SetRuntimeEnvFrameworkLookup chat 服务装配 setter。cmd/bus 注入 reporuntimeenv 适配器。
func (s *impl) SetRuntimeEnvFrameworkLookup(l RuntimeEnvFrameworkLookup) { s.runtimeEnvFW = l }

// SetRuntimeEnvFrameworkLookupOnService 公开 helper。
func SetRuntimeEnvFrameworkLookupOnService(svc Service, l RuntimeEnvFrameworkLookup) {
	if im, ok := svc.(*impl); ok {
		im.SetRuntimeEnvFrameworkLookup(l)
	}
}

// SetZapDispatcher chat 服务装配 setter。cmd/bus 注入 newZapDispatcher(...)。
func (s *impl) SetZapDispatcher(d ZapDispatcher) { s.zapDispatcher = d }

// SetZapDispatcherOnService 公开 helper。
func SetZapDispatcherOnService(svc Service, d ZapDispatcher) {
	if im, ok := svc.(*impl); ok {
		im.SetZapDispatcher(d)
	}
}

// SetStreamStoreOnService 单测装配 helper — Backend Phase 1 /chat/respond 要求装齐
// streamStore (与 Send 路径对齐)。生产装配走 NewWithStopRetry 总会装上, 这个 setter 仅给
// 不便走 NewWithStopRetry 的单测用。
func SetStreamStoreOnService(svc Service, store dommstream.Repository) {
	if im, ok := svc.(*impl); ok {
		im.streamStore = store
	}
}

// isZapWireFramework ZAP 线协议分支 (zap 外部自定义 / dsh 平台自营) —— 派发器、会话、技能、identity 共用。
func isZapWireFramework(framework string) bool {
	switch strings.ToLower(strings.TrimSpace(framework)) {
	case FrameworkZap, FrameworkDSH:
		return true
	}
	return false
}

// isDSHFramework 平台自营 dsh 运行时专属策略分支 (KB 预检索 / 用户 key 必注入)。
func isDSHFramework(framework string) bool {
	return strings.EqualFold(strings.TrimSpace(framework), FrameworkDSH)
}
