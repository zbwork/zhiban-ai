// Package agentctl 对外暴露 OpenClaw 容器内 `openclaw agents <subcmd>` CLI 的薄封装,
// 供 Bus 在 Agent publish / unpublish / rename 时同步实例侧状态。
//
// 本批 2C 移植自 legacy `openclawagentapp.execOpenClawCLI` / `dockerOpenClawAgentsDelete`,
// 走 docker exec (local 模式) / kubectl exec (K8s 模式) —— OpenClaw v3 协议没有
// "在容器里跑任意 shell" 的 RPC, 也没有 fs.* 文件系统 RPC, 必须直接进容器跑 CLI。
//
// 路径约定 (与 legacy 完全一致, 见 plan §5 T2C.1.C):
//
//	local 模式:
//	  workspace : /data/.openclaw/workspace/<agent_uuid>
//	  agent-dir : /data/.openclaw/agents/<agent_uuid>/agent
//	K8s 模式 (本批 stub):
//	  workspace : /data/.openclaw/workspace-<agent_uuid>
//	  agent-dir : /data/.openclaw/agentdir-<agent_uuid>
//
// default agent 不在 Batch 2C 范围 (那个用 workspace 根, 不走 agents add)。
package agentctl

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/controlplane"
)

// AgentCtl 是 OpenClaw 容器内 agent 生命周期 RPC 的抽象。
//
// **本批 2C 走 CLI exec** (legacy 同款); 后续 batch 可平替为 v3 WS
// agents.create/agents.update/agents.delete RPC, 接口签名不变。
type AgentCtl interface {
	// Add 注册一个新 agent 到 OpenClaw。幂等吞 "already exists"。
	// workspacePath / agentDirPath 应是绝对路径, 由 caller 用 WorkspacePath/AgentDirPath 拼好。
	Add(ctx context.Context, agentKey, workspacePath, agentDirPath string) error

	// SetIdentity 热更 agent 的 name/avatar/emoji 等 identity 字段 (不重启 gateway)。
	// 本批 2C **不主动调** (published agent 关键字段禁改, 见 plan §5 T2C.3);
	// 接口保留给 Batch 2D 后接 Agent 改名同步用。
	SetIdentity(ctx context.Context, agentKey, name string) error

	// Delete 删除 agent (unpublish / agent 删除时调)。
	// 不存在视为成功 (idempotent)。
	Delete(ctx context.Context, agentKey string) error
}

// ErrNotImplementedK8sExec K8s 模式 CLI exec 在 Batch 2C 未实现。
var ErrNotImplementedK8sExec = errors.New("openclaw agentctl: K8s exec not implemented in Batch 2C")

// WorkspacePath 返回 local 模式下 agent 的 workspace 绝对路径。
// 与 legacy openclawagentapp.agentWorkspaceLocalPath (localGateway 分支) 对齐。
func WorkspacePath(agentKey string) string {
	return filepath.Join("/data", ".openclaw", "workspace", agentKey)
}

// AgentDirPath 返回 local 模式下 agent 的 --agent-dir 绝对路径。
// 与 legacy openclawagentapp.agentDirLocalPath (localGateway 分支) 对齐。
func AgentDirPath(agentKey string) string {
	return filepath.Join("/data", ".openclaw", "agents", agentKey, "agent")
}

// K8sWorkspacePath K8s 模式 workspace 路径 (留接口给后续 batch)。
func K8sWorkspacePath(agentKey string) string {
	return filepath.Join("/data", ".openclaw", "workspace-"+agentKey)
}

// K8sAgentDirPath K8s 模式 agent-dir 路径 (留接口给后续 batch)。
func K8sAgentDirPath(agentKey string) string {
	return filepath.Join("/data", ".openclaw", "agentdir-"+agentKey)
}

// OpenClawModelID adds the local provider name without rewriting the wire ID.
// BeeBridge's model catalog is the authority for the full model identifier.
func OpenClawModelID(model string) string {
	model = strings.TrimSpace(model)
	if model == "" || strings.HasPrefix(model, "beebridge/") {
		return model
	}
	return "beebridge/" + model
}

// ResolveModel ADR-0037 Phase 3 G2: BYOK 数字员工不走 OpenClawModelID 的 beebridge/
// 合成前缀映射 (那层映射专为平台白名单模型转发内部 BeeBridge 网关而存在)。BYOK 的
// resolver (cpresolver.go) 已经把 spec.ModelPrimary 直接解析成最终 OpenClaw
// provider/model id (`openai/<model_service_config.model_id>`, 复用
// openclaw.json 里已有的 openai provider 条目——它现在跟 beebridge 条目一样指向被
// buildPodEnv 覆盖过的 LLM_BASE_URL/LLM_API_KEY), 这里原样透传即可。
//
// 非 BYOK (spec.ModelSource != "byok") 走原有 OpenClawModelID 映射, 行为不变。
func ResolveModel(spec controlplane.AgentSpec) string {
	if spec.ModelSource == "byok" {
		return strings.TrimSpace(spec.ModelPrimary)
	}
	return OpenClawModelID(spec.ModelPrimary)
}

// LocalCtl 是本机 docker exec 实现 (Batch 2C 主路径)。
type LocalCtl struct {
	ContainerName string // 容器名, 默认 "openclaw" (与 deploy/openclaw-deploy/local-test/dev-run.sh 对齐)
}

// NewLocalCtl 构造 local 模式 AgentCtl。containerName 为空时默认 "openclaw"。
func NewLocalCtl(containerName string) *LocalCtl {
	c := strings.TrimSpace(containerName)
	if c == "" {
		c = "openclaw"
	}
	return &LocalCtl{ContainerName: c}
}

// Add 调 `docker exec <container> openclaw agents add <agentKey> --workspace <ws> --agent-dir <agent-dir> --non-interactive`。
// 幂等: stderr 含 "already exists" -> nil (legacy 经验: agents add 自身写 config.json, OpenClaw 内部已 lock)。
func (c *LocalCtl) Add(ctx context.Context, agentKey, workspacePath, agentDirPath string) error {
	if strings.TrimSpace(agentKey) == "" {
		return fmt.Errorf("agentctl.Add: agentKey required")
	}
	if workspacePath == "" || agentDirPath == "" {
		return fmt.Errorf("agentctl.Add: workspacePath/agentDirPath required")
	}
	stdout, stderr, err := c.runCLI(ctx,
		"agents", "add", agentKey,
		"--workspace", workspacePath,
		"--agent-dir", agentDirPath,
		"--non-interactive",
	)
	if err == nil {
		return nil
	}
	// already exists 视为成功 (与 legacy 行为对齐)
	if strings.Contains(stderr, "already exists") || strings.Contains(stdout, "already exists") {
		return nil
	}
	return fmt.Errorf("agentctl.Add %s: %w (stderr=%s)", agentKey, err, strings.TrimSpace(stderr))
}

// SetIdentity 调 `docker exec <container> openclaw agents set-identity --agent <id> --name <name>`。
// 不会触发 gateway 重启 (legacy 经验)。
func (c *LocalCtl) SetIdentity(ctx context.Context, agentKey, name string) error {
	if strings.TrimSpace(agentKey) == "" {
		return fmt.Errorf("agentctl.SetIdentity: agentKey required")
	}
	if strings.TrimSpace(name) == "" {
		return nil // legacy 同款: 空 name no-op
	}
	_, stderr, err := c.runCLI(ctx, "agents", "set-identity", "--agent", agentKey, "--name", name)
	if err != nil {
		return fmt.Errorf("agentctl.SetIdentity %s: %w (stderr=%s)", agentKey, err, strings.TrimSpace(stderr))
	}
	return nil
}

// Delete 调 `docker exec <container> openclaw agents delete <agentKey> --force --json`。
// 不存在视为成功 (idempotent)。
//
// **--force 必须**: OpenClaw v3 CLI 在非交互 session 下要求显式 --force, 否则报
// "Non-interactive session. Re-run with --force.". 与 legacy ai-office
// `dockerOpenClawAgentsDelete` 一致。
//
// --json 让输出可机器解析 (本批不解析, 但显式标 json 可避免未来 TTY-aware 行为变更)。
func (c *LocalCtl) Delete(ctx context.Context, agentKey string) error {
	if strings.TrimSpace(agentKey) == "" {
		return fmt.Errorf("agentctl.Delete: agentKey required")
	}
	stdout, stderr, err := c.runCLI(ctx, "agents", "delete", agentKey, "--force", "--json")
	if err == nil {
		return nil
	}
	// "not found" / "does not exist" 视为成功
	lower := strings.ToLower(stderr + " " + stdout)
	if strings.Contains(lower, "not found") || strings.Contains(lower, "does not exist") || strings.Contains(lower, "no such") {
		return nil
	}
	return fmt.Errorf("agentctl.Delete %s: %w (stderr=%s)", agentKey, err, strings.TrimSpace(stderr))
}

// runCLI 内部执行 `docker exec <container> openclaw <args...>` 并捕获 stdout/stderr。
func (c *LocalCtl) runCLI(ctx context.Context, args ...string) (string, string, error) {
	dockerArgs := append([]string{"exec", c.ContainerName, "openclaw"}, args...)
	cmd := exec.CommandContext(ctx, "docker", dockerArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

// K8sCtl 是 K8s 模式预留 (本批 2C 未实现)。
type K8sCtl struct{}

// NewK8sCtl 构造 K8s 预留实现。
func NewK8sCtl() *K8sCtl { return &K8sCtl{} }

func (K8sCtl) Add(ctx context.Context, agentKey, workspacePath, agentDirPath string) error {
	return ErrNotImplementedK8sExec
}
func (K8sCtl) SetIdentity(ctx context.Context, agentKey, name string) error {
	return ErrNotImplementedK8sExec
}
func (K8sCtl) Delete(ctx context.Context, agentKey string) error {
	return ErrNotImplementedK8sExec
}
