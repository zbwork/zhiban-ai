// controlplane.go — ZAP 的 controlplane.RuntimeControlPlane 实现 (doc-12 §3.1 / Task D)。
//
// ZAP runtime 自管 workspace/人格化, agent 同步 = 纯 HTTP `/zap/v1/agents`, 无 exec / 无 workspace 文件落地,
// 故 AgentSyncExecutable() 恒 true (不依赖 per-pod exec)。静态能力上界 = agent.*(协议实现的操作);
// skill.* 不在上界 (ZAP skill 协议未实现)。
//
// 是否真正生成/调用由生效能力 (静态上界 ∩ runtime_card/probe 声明) 决定 —— 见 buildPlan
// (PlanAgentRegister) 与 UpsertConfig 保存校验。本 control plane 仅声明"能调用的上界"+ 执行 HTTP。
package zap

import (
	"context"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/controlplane"
)

// Framework 标识 (与 runtime_environments.framework 取值一致)。
const Framework = "zap"

// ZAPControlPlane 实现 controlplane.RuntimeControlPlane + controlplane.AgentSyncer。
type ZAPControlPlane struct {
	// newClient 按 target 现场构造绑定 endpoint+token 的 Client (便于单测注入)。
	newClient func(target controlplane.InstanceTarget) *Client
	callLog   *CallLogWriter
}

// CPOption 调整构造。
type CPOption func(*ZAPControlPlane)

// WithClientFactory 注入自定义 Client 工厂 (单测指向 httptest server)。
func WithClientFactory(f func(target controlplane.InstanceTarget) *Client) CPOption {
	return func(p *ZAPControlPlane) {
		if f != nil {
			p.newClient = f
		}
	}
}

// WithControlPlaneCallLog 启用 ZAP control-plane 出站调用日志。
func WithControlPlaneCallLog(w *CallLogWriter) CPOption {
	return func(p *ZAPControlPlane) {
		p.callLog = w
	}
}

// NewZAPControlPlane 构造。
func NewZAPControlPlane(opts ...CPOption) *ZAPControlPlane {
	p := &ZAPControlPlane{
		newClient: func(t controlplane.InstanceTarget) *Client { return NewClient(t.EndpointURL, t.GatewayToken) },
	}
	for _, o := range opts {
		o(p)
	}
	return p
}

func (p *ZAPControlPlane) Framework() string { return Framework }

// Capabilities 静态能力上界 (doc-12 §4.2 第 1 层): ZAP 标准 profile 已实现 agent.* 协议; skill.* 未实现。
func (p *ZAPControlPlane) Capabilities() controlplane.CapabilitySet {
	return controlplane.With(
		controlplane.CapAgentCreate,
		controlplane.CapAgentRead,
		controlplane.CapAgentUpdate,
		controlplane.CapAgentDelete,
		controlplane.CapAgentList,
	)
}

func (p *ZAPControlPlane) AgentSyncer() controlplane.AgentSyncer { return p }

// SkillSyncer: ZAP runtime 自管技能 (无 Bus-driven skill.install) → 返回 nil → PlanSkillRegister 永为 false,
// 故 external/ZAP 环境**永不生成 skill_register** (doc-12 §11.5 Task B)。
func (p *ZAPControlPlane) SkillSyncer() controlplane.SkillSyncer { return nil }

// AgentSyncExecutable: ZAP agent 同步是纯 HTTP, 不依赖 per-pod exec / k8s 凭证 → 恒可执行 (忽略 env)。
func (p *ZAPControlPlane) AgentSyncExecutable(_ controlplane.ExecEnv) bool { return true }

// SyncAgent 幂等地把 spec 注册/更新进 ZAP runtime。
// 已存在的 agent_key 走 PATCH, 不把 POST 409 当作正常日志留在后台。
// canonical 字段 = agent_key (按 spec.AgentKey 创建); 成功后校验返回 key 一致, 不一致视为终态错误 (不标成功)。
// ZAP runtime 自管 workspace, 故**不写 workspace 文件** (忽略 spec.WorkspaceFiles)。
func (p *ZAPControlPlane) SyncAgent(ctx context.Context, target controlplane.InstanceTarget, spec controlplane.AgentSpec) error {
	cli := p.newClient(target)
	p.attachCallLog(cli, target, spec)
	// 默认只发 canonical agent_key (不带 agentId alias) —— 避免严格 ZAP runtime 因多余字段拒绝。
	req := &CreateAgentRequest{AgentKey: spec.AgentKey, Name: spec.Name, SystemPrompt: spec.SystemPrompt}
	if len(spec.Metadata) > 0 {
		req.Metadata = spec.Metadata // ADR-0037 dsh 消费端: model_service 三元组随注册下发 (无密钥)
	}
	if spec.ModelPrimary != "" || len(spec.ModelFallbacks) > 0 {
		req.Model = &AgentModelConfig{Primary: spec.ModelPrimary, Fallbacks: spec.ModelFallbacks}
	}
	if len(spec.ToolAllow) > 0 || len(spec.ToolDeny) > 0 {
		req.Tools = &AgentToolsConfig{Allow: spec.ToolAllow, Deny: spec.ToolDeny}
	}
	exists, err := agentExists(ctx, cli, spec.AgentKey)
	if err != nil {
		return mapSyncErr(err, "zap_list_agents")
	}
	if exists {
		return p.updateAgent(ctx, cli, spec, req)
	}
	resp, err := cli.CreateAgent(ctx, req)
	if err != nil {
		if apiErr, ok := err.(*APIError); ok && apiErr.IsConflict() {
			// 并发或 runtime 预置 agent 导致的已存在: 收敛为更新, 让远端状态与 Bus 期望一致。
			return p.updateAgent(ctx, cli, spec, req)
		}
		if mapped := mapSyncErr(err, "zap_create_agent"); mapped != nil {
			return mapped
		}
		return nil
	}
	return validateSyncedAgentKey(resp.Key(), spec.AgentKey)
}

func agentExists(ctx context.Context, cli *Client, agentKey string) (bool, error) {
	resp, err := cli.ListAgents(ctx, nil)
	if err != nil {
		return false, err
	}
	for _, agent := range resp.Agents {
		if agent.AgentKey == agentKey {
			return true, nil
		}
	}
	return false, nil
}

func (p *ZAPControlPlane) updateAgent(ctx context.Context, cli *Client, spec controlplane.AgentSpec, req *CreateAgentRequest) error {
	update := &UpdateAgentRequest{Name: req.Name, Model: req.Model, Tools: req.Tools, SystemPrompt: req.SystemPrompt, Metadata: req.Metadata}
	resp, err := cli.UpdateAgent(ctx, spec.AgentKey, update)
	if err != nil {
		if mapped := mapSyncErr(err, "zap_update_agent"); mapped != nil {
			return mapped
		}
		return nil
	}
	return validateSyncedAgentKey(resp.Key(), spec.AgentKey)
}

func validateSyncedAgentKey(got, want string) error {
	// 严格 key 一致性: runtime 必须**明确回显**与请求一致的 agent_key 才算注册成功。
	//   - 缺 agent_key (如只回 {"ok":true}) → 无法确认注册到正确 agent → 终态失败, 不标成功。
	//   - 回了别的 key → 注册到错误 agent → 终态失败。
	if got == "" {
		return &controlplane.SyncError{Retryable: false, Reason: "zap_agent_key_missing"}
	}
	if got != want {
		return &controlplane.SyncError{Retryable: false, Reason: "zap_agent_key_mismatch"}
	}
	return nil
}

// RemoveAgent 幂等地从 ZAP runtime 删除 agent (不存在视为成功)。
func (p *ZAPControlPlane) RemoveAgent(ctx context.Context, target controlplane.InstanceTarget, agentKey string) error {
	cli := p.newClient(target)
	p.attachCallLog(cli, target, controlplane.AgentSpec{AgentKey: agentKey})
	_, err := cli.DeleteAgent(ctx, agentKey)
	if apiErr, ok := err.(*APIError); ok && apiErr.IsNotFound() {
		return nil
	}
	return mapSyncErr(err, "zap_delete_agent")
}

func (p *ZAPControlPlane) attachCallLog(cli *Client, target controlplane.InstanceTarget, spec controlplane.AgentSpec) {
	if p == nil || p.callLog == nil || cli == nil {
		return
	}
	var accountID *int64
	if target.AccountID > 0 {
		accountID = &target.AccountID
	}
	var runtimeEnvID *int64
	if target.RuntimeEnvironmentID > 0 {
		runtimeEnvID = &target.RuntimeEnvironmentID
	}
	WithCallLog(p.callLog, &CallMetadata{
		TenantID:             target.TenantID,
		AccountID:            accountID,
		RuntimeEnvironmentID: runtimeEnvID,
		AgentKey:             spec.AgentKey,
	})(cli)
}

// mapSyncErr 把 *APIError 归一成 controlplane.SyncError (吞冲突为成功); reason 为内部码, 不下发客户端。
func mapSyncErr(err error, stage string) error {
	if err == nil {
		return nil
	}
	apiErr, ok := err.(*APIError)
	if !ok {
		return &controlplane.SyncError{Retryable: true, Reason: stage + "_unknown", Cause: err}
	}
	if apiErr.IsConflict() {
		return nil
	}
	reason := stage
	switch {
	case apiErr.StatusCode == 0:
		reason = stage + "_transport"
	case apiErr.StatusCode == 401 || apiErr.StatusCode == 403:
		reason = stage + "_unauthorized"
	case apiErr.StatusCode >= 500:
		reason = stage + "_5xx"
	default:
		reason = stage + "_http_" + itoa(apiErr.StatusCode)
	}
	return &controlplane.SyncError{Retryable: apiErr.IsRetryable(), Reason: reason, Cause: apiErr}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

var (
	_ controlplane.RuntimeControlPlane = (*ZAPControlPlane)(nil)
	_ controlplane.AgentSyncer         = (*ZAPControlPlane)(nil)
)
