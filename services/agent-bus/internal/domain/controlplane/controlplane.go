// Package controlplane 定义 doc-12 的 runtime control-plane 抽象 (S5a):
// 把数字员工 Agent 写入指定 per-user runtime 实例的窄接口 + capability 模型。
//
// 本包是**纯类型 / 纯逻辑**, 不做任何 I/O。各 framework 的真实实现是 adapter:
//   - OpenClaw: internal/adapter/runtime/openclaw/agentapi (HTTP /v1/agents 逻辑注册 + workspace 写入 + skill.install)。
//   - ZAP: internal/adapter/runtime/zap (HTTP /zap/v1/agents; 无 skill.install, 运行端自管技能)。
//   - Hermes / 自定义: 后续分片接入。
//
// 生效能力模型 (doc-12 §4.2) = adapter/profile 静态上界 ∩ runtime_card/probe 声明。
// 内置 OpenClaw/Hermes 由系统根据 adapter wiring 与环境配置推导；外部 ZAP/custom 由 runtime_card
// 声明，metadata.control_plane_capabilities 仅作为历史缓存兼容。
package controlplane

import (
	"context"
	"errors"
)

// Capability 控制面能力标识 (doc-12 §4.1)。
type Capability string

const (
	// agent.* —— 本片 OpenClaw HTTP /v1/agents 真实实现。
	CapAgentRead   Capability = "agent.read"
	CapAgentCreate Capability = "agent.create"
	CapAgentUpdate Capability = "agent.update"
	CapAgentDelete Capability = "agent.delete"
	CapAgentList   Capability = "agent.list"

	// skill.* —— OpenClaw 真实语义 = 把绑定技能 install/uninstall 进/出 agent workspace (Task B/C-2 已实现):
	//   skill.install   生效 → buildPlan 生成 skill_register、worker 真实安装 (见 agentapi.InstallSkill + skillpkg.Fetcher);
	//   skill.uninstall 生效 → 解绑生成 skill_unregister、worker 真实删除 (见 agentapi.UninstallSkill + WorkspaceRemover)。
	// 二者能力上界 wiring-aware (install 需 writer+fetcher, uninstall 需 remover)。
	// skill.list 仍未实现 → 不在 OpenClaw 上界 (即便声明也不生效)。skill.create/update/delete 为未来"平台原生技能 CRUD"预留, 不枚举。
	CapSkillInstall   Capability = "skill.install"
	CapSkillUninstall Capability = "skill.uninstall"
	CapSkillList      Capability = "skill.list"
)

// knownCapabilities 是解析 metadata 时的能力白名单: 只承认这些键, 防止把未知/垃圾键当能力。
var knownCapabilities = map[Capability]bool{
	CapAgentRead: true, CapAgentCreate: true, CapAgentUpdate: true, CapAgentDelete: true, CapAgentList: true,
	CapSkillInstall: true, CapSkillUninstall: true, CapSkillList: true,
}

// KnownCapability 报告 c 是否为受支持的 capability 键 (admin 声明白名单, S5e)。
// 未知键应被拒绝 (admin API 返回 400) 或丢弃, 不得当作能力存储。
func KnownCapability(c Capability) bool { return knownCapabilities[c] }

// CapabilitySet 是一组启用的能力 (集合语义)。nil / 空 = 无任何能力 (最小权限默认, §4.1)。
type CapabilitySet map[Capability]bool

// Has 报告是否启用某能力 (nil-safe)。
func (s CapabilitySet) Has(c Capability) bool { return s != nil && s[c] }

// With 返回追加了若干能力的**新副本** (不改原集; 便于在 adapter 静态上界里声明)。
func With(caps ...Capability) CapabilitySet {
	out := make(CapabilitySet, len(caps))
	for _, c := range caps {
		out[c] = true
	}
	return out
}

// Intersect 取交集 (doc-12 §4.2: 生效能力 = 静态上界 ∩ 声明)。nil-safe; 结果只含两边都为 true 的能力。
func (s CapabilitySet) Intersect(other CapabilitySet) CapabilitySet {
	out := CapabilitySet{}
	for c := range s {
		if s[c] && other.Has(c) {
			out[c] = true
		}
	}
	return out
}

// metadataCapabilitiesKey 是 runtime_environments.metadata 下缓存控制面能力的键 (doc-12 §5.1)。
const metadataCapabilitiesKey = "control_plane_capabilities"

// ParseDeclared 从 runtime_environments.metadata 解析 runtime 声明的控制面能力:
//
//	metadata["runtime_card"]["control_plane_capabilities"] = ["agent.create", ...] // 优先
//	metadata["control_plane_capabilities"] = {"agent.create": true, ...}           // 历史缓存
//
// 规则: 缺省 / 类型不符 / 未知键 → 忽略 (最小权限, 默认空集); runtime_card 明确出现该字段时,
// 即使为空也以 runtime_card 为准。
func ParseDeclared(metadata map[string]any) CapabilitySet {
	if metadata == nil {
		return CapabilitySet{}
	}
	if card, _ := metadata["runtime_card"].(map[string]any); card != nil {
		if raw, ok := card[metadataCapabilitiesKey]; ok {
			return parseCapabilityValue(raw)
		}
	}
	if raw, ok := metadata[metadataCapabilitiesKey]; ok {
		return parseCapabilityValue(raw)
	}
	return CapabilitySet{}
}

func parseCapabilityValue(raw any) CapabilitySet {
	out := CapabilitySet{}
	switch v := raw.(type) {
	case map[string]any:
		for k, enabled := range v {
			cap := Capability(k)
			if !knownCapabilities[cap] {
				continue
			}
			if b, ok := enabled.(bool); ok && b {
				out[cap] = true
			}
		}
	case []any:
		for _, item := range v {
			k, _ := item.(string)
			cap := Capability(k)
			if knownCapabilities[cap] {
				out[cap] = true
			}
		}
	}
	return out
}

// InstanceTarget 是一个具体 per-user 运行实例的寻址 + 凭证 (doc-12 §3)。
//
// 安全: EndpointURL (pod 内网地址) 与 GatewayToken (解出的明文 bearer) **永不下发客户端、不落日志**
// (doc-10 §8.4 / doc-12 §9)。GatewayToken 由调用方 (cmd resolver) 用 SecretResolver 解出后填入。
//
// exec/fs 定位字段 (S5c, doc-12 §11 S5c): WorkspaceWriter 据此定位写 workspace 文件的目标。诚实口径:
//   - ContainerName: **当前仅 local/dev shared-container wiring 使用** (来自配置注入, 由 resolver 填; adapter 不写死)。
//     它是开发共享容器, **不是 per-user pod 目标**。
//   - Namespace + WorkloadName (k8s_namespace / k8s_deployment): 真正 per-user pod 写入/删除靠这两项 +
//     K8sWorkspaceWriter (client-go remotecommand SPDY pod exec, Task A 已实现)。clawmanager 托管的 exec 端点仍待接通。
type InstanceTarget struct {
	TenantID             int64
	AccountID            int64
	RuntimeEnvironmentID int64
	RuntimeInstanceUUID  string
	Framework            string
	HostingKind          string
	EndpointURL          string
	GatewayToken         string
	// exec/fs 目标定位 (S5c):
	Namespace     string // k8s_namespace (k8s 模式)
	WorkloadName  string // k8s_deployment (k8s 模式; 由此解析当前 pod)
	ContainerName string // 本地 docker exec 的容器名 (来自配置, 非 adapter 硬编码); k8s 留空则 adapter 解析 (优先 openclaw)
	// k8s 集群访问凭证 (Task A; per-env, 来自 runtime_environments.k8s_api_server_url / k8s_token_secret_ref)。
	// K8sToken 是解出的明文 SA token, **不下发客户端、不落日志**。clawmanager 托管无这些 → K8sWorkspaceWriter fail closed。
	K8sAPIServer string
	K8sToken     string
	K8sInsecure  bool
}

// WorkspaceFile 一份要写入目标实例文件系统的文件 (容器内绝对路径 + 内容)。
// 中立类型 (不依赖 adapter/fs), 由 resolver 用 BuildAgentWorkspaceFiles 投影而来。
type WorkspaceFile struct {
	AbsPath string
	Data    []byte
}

// AgentSpec 从 digital_employee 投影出的"期望状态" (doc-12 §3)。
type AgentSpec struct {
	AgentKey      string // 运行端 agent id (doc-12 §11.7: = digital_employee.uuid, canonical; 见 cpresolver)
	Name          string
	WorkspacePath string // = agentctl.WorkspacePath(AgentKey); `openclaw agents add --workspace`
	// AgentDirPath (doc-12 §11.8): = agentctl.AgentDirPath(AgentKey); `openclaw agents add --agent-dir`
	// (OpenClaw 从此目录读 CLAUDE.md 等)。CLI 注册需要; REST 路径不用。
	AgentDirPath   string
	ModelPrimary   string
	ModelFallbacks []string
	// ModelSource ADR-0037: ""(默认)/"platform_whitelist" = ModelPrimary 是产品模型名,
	// 经 agentctl.OpenClawModelID 映射成 provider/model id (aigc 合成前缀转发内部网关);
	// "byok" = ModelPrimary 已由 resolver 直接解析成最终 OpenClaw provider/model id
	// (`openai/<model_id>`), agentctl.ResolveModel 原样透传, 不再走那层映射。
	ModelSource string
	// Metadata ZAP §2.1 注册体的 metadata 扩展位 (nil = 不发)。ADR-0037 dsh 消费端: byok 员工带
	// model_service{endpoint_type, base_url, model_id} (不含密钥; 密钥走 /instances)。
	Metadata  map[string]any
	ToolAllow []string
	ToolDeny  []string
	// SystemPrompt 数字员工人设 (digital_employees.metadata.system_prompt)。ZAP 运行端按协议 §2.1 `system_prompt`
	// 随 POST/PATCH /zap/v1/agents 下发 (dsh-runtime 据此装配); OpenClaw/Hermes 不用本字段 (人设走 WorkspaceFiles)。
	SystemPrompt string
	// WorkspaceFiles (S5c): agent workspace 文件 (SOUL/IDENTITY/CLAUDE.md...), 由 resolver 用
	// BuildAgentWorkspaceFiles 渲染。非空时 OpenClaw SyncAgent 在 CLI 注册后经 WorkspaceWriter 写入目标实例。
	WorkspaceFiles []WorkspaceFile
}

// AgentCLIRegistrar 用 OpenClaw **CLI** (`openclaw agents add ... --non-interactive`) 经 exec 在目标实例注册 agent
// (doc-12 §11.8)。真实 OpenClaw pod **没有** REST `POST /v1/agents`, 故 clawmanager/k8s 注册走 CLI exec
// (K8sWorkspaceWriter via k8sexec.ExecInPod / LocalWorkspaceWriter via docker exec)。already-exists 视为幂等成功。
// 实现按部署: 缺凭证/目标 → 终态 SyncError; exec/网络 → 可重试。
type AgentCLIRegistrar interface {
	RegisterAgentCLI(ctx context.Context, target InstanceTarget, spec AgentSpec) error
}

// WorkspaceWriter 把 workspace 文件写进**指定**实例的文件系统 (S5c, doc-12 §3.1)。
// 实现按 hosting/部署模式: 本地 docker exec (LocalWorkspaceWriter) / k8s pod exec
// (Task A 已实现, K8sWorkspaceWriter via client-go remotecommand SPDY)。skill.install 复用同一 writer。
type WorkspaceWriter interface {
	// WriteWorkspace 把 files 写入 target 实例; 目标由 target 字段定位, 不回落共享容器。
	WriteWorkspace(ctx context.Context, target InstanceTarget, files []WorkspaceFile) error
}

// AgentSyncer 把 Agent 写入 / 移出指定实例 (doc-12 §3)。
// OpenClaw 实现 (S5c) = HTTP /v1/agents 逻辑注册 + WorkspaceWriter 写 workspace 文件。
type AgentSyncer interface {
	// SyncAgent 幂等地把 spec 注册进 target 实例 (已存在视为成功); 含 workspace 文件落地。
	SyncAgent(ctx context.Context, target InstanceTarget, spec AgentSpec) error
	// RemoveAgent 幂等地从 target 实例移除 agent (不存在视为成功)。
	RemoveAgent(ctx context.Context, target InstanceTarget, agentKey string) error
}

// SkillSpec 从 agent_skill_bindings + skill_versions 投影出的"要安装的技能" (doc-12 §11.5 Task B / S5d)。
//
// 安装目标 = <WorkspacePath>/skills/<Slug>/; 安装包来源 = PackageKey。
//
// **PackageKey 是对象存储 key (skill_versions.package_url 列存的就是 OSS key, 形如 `skill/<uuid>/<ver>.zip`),
// 不是 HTTP URL**。SkillSyncer 必须经受控 fetcher (校验前缀 + 对象存储 presign/get) 读取, **严禁**把它当任意
// URL 直接 http.Get (SSRF + 正常包安装失败, doc-12 §11.5 / docs/pitfalls)。EasyO 无 SkillHub。
// SHA256 非空时安装前必须校验 (不符 → 终态, 不装半包)。
type SkillSpec struct {
	AgentKey      string // 运行端 agent id (workspace 归属; 与 AgentSpec.AgentKey 同口径)
	Slug          string // skills.code (skills/<slug>/ 目录名)
	WorkspacePath string // agent workspace 绝对根 (= agentctl.WorkspacePath(agentKey)); 技能装到 <WorkspacePath>/skills/<Slug>/
	PackageKey    string // 安装包**对象存储 key** (skill_versions.package_url; 非 HTTP URL)
	SHA256        string // 期望 sha256 (skill_versions.package_sha256; 空=不校验)
	// RequiredRuntimes 来自已发布 skill_versions.agent_compat_snapshot。
	// 空表示不限制；非空由 framework-aware resolver 在安装前 fail-closed 校验。
	RequiredRuntimes []string
}

// SkillUninstallSpec 从 agent_skill_bindings 解绑投影出的"要卸载的技能" (doc-12 §11.5 Task C-2)。
// 删除目标 = <WorkspacePath>/skills/<Slug>/。**只删运行端文件, 不改历史会话** (见 docs/pitfalls)。
type SkillUninstallSpec struct {
	AgentKey      string // 运行端 agent id (workspace 归属)
	Slug          string // skills.code (skills/<slug>/ 目录名; 安装/卸载同一安全单段校验)
	WorkspacePath string // agent workspace 绝对根; 删除 <WorkspacePath>/skills/<Slug>/
}

// WorkspaceRemover 删除**指定**实例文件系统下的目录 (doc-12 §11.5 Task C-2)。
// 与 WorkspaceWriter 分开: 删除是独立高危能力, 不能用写空文件假装删除。
// 实现 (workspacewriter): local docker exec `rm -rf` / k8s pod exec `rm -rf`; 路径受 /data/.openclaw/ 前缀约束。
type WorkspaceRemover interface {
	// RemoveDir 删除 target 实例内 absPath 目录 (幂等: 不存在视为成功)。absPath 必须在安全前缀下, 否则终态。
	RemoveDir(ctx context.Context, target InstanceTarget, absPath string) error
}

// SkillSyncer 把绑定技能 install/uninstall 进指定实例的 agent workspace (doc-12 §11.5 Task B/C-2)。
// OpenClaw 实现: install = 拉包→校验→解 zip→WorkspaceWriter 写 <ws>/skills/<slug>/; uninstall = WorkspaceRemover 删 <ws>/skills/<slug>/。
type SkillSyncer interface {
	// InstallSkill 幂等地把 spec 指向的技能包安装进 target 实例 (覆盖写, 重复安装视为成功)。
	InstallSkill(ctx context.Context, target InstanceTarget, spec SkillSpec) error
	// UninstallSkill 幂等地删除 target 实例内 <ws>/skills/<slug>/ (目录不存在视为成功)。slug 受安全单段校验。
	UninstallSkill(ctx context.Context, target InstanceTarget, spec SkillUninstallSpec) error
}

// ExecEnv 是判定"某 runtime 环境能否真正执行 agent 同步"所需的 per-env 上下文 (Codex P1: env 级 gate)。
// AgentSyncExecutable 据此按环境判定, 而非全局假 true —— 避免 clawmanager 这类无凭证环境先生成 agent_register 再隐藏失败。
type ExecEnv struct {
	HostingKind string // clawmanager | k8s_native | external_endpoint
	HasK8sCreds bool   // env 是否配了 k8s 集群凭证 (k8s_api_server_url + k8s_token_secret_ref); k8s pod exec 必需
}

// RuntimeControlPlane 按 framework 聚合 (doc-12 §3): 声明静态能力上界 + 是否可执行 + AgentSyncer。
type RuntimeControlPlane interface {
	// Framework 该实现服务的 framework (openclaw / zap / hermes / ...)。
	Framework() string
	// Capabilities adapter 静态能力上界 (与管理员声明取交集得生效能力, §4.2)。
	Capabilities() CapabilitySet
	// AgentSyncer 不支持时返回 nil。
	AgentSyncer() AgentSyncer
	// SkillSyncer 把绑定技能 install/uninstall 进/出 agent workspace (doc-12 §11.5 Task B/C-2); 不支持返回 nil (如 ZAP)。
	SkillSyncer() SkillSyncer
	// AgentSyncExecutable 报告以当前部署 wiring, SyncAgent 能否对**该具体环境**真正完成 (doc-12 §3.1/§6.1; env 级 gate)。
	//   - OpenClaw: local 模式 → true (dev 共享容器); k8s 模式 → 仅 hosting_kind=k8s_native 且 HasK8sCreds (有集群凭证可 SPDY exec);
	//     clawmanager (无直连凭证/exec 端点) → false, 不生成、不假成功。
	//   - ZAP: 纯 HTTP, 恒 true。
	// false 时 buildPlan 不生成该环境的 agent_register。
	AgentSyncExecutable(env ExecEnv) bool
}

// Effective 生效能力 = 静态上界 ∩ 声明 (doc-12 §4.2)。
func Effective(staticUpper, declared CapabilitySet) CapabilitySet {
	return staticUpper.Intersect(declared)
}

// capabilitiesSystemDerived 报告该 framework 的生效能力是否由**系统推导**(doc-12 §11.8.2):
//   - openclaw / hermes 等**内置 runtime**: 能力由 adapter 静态上界 + hosting_kind + 配置完整 + 可执行推导。
//   - zap / custom 等**外部 endpoint**: 外部服务可能实现也可能没实现, 仍需 runtime_card/probe 声明取交集。
func capabilitiesSystemDerived(framework string) bool {
	switch framework {
	case "openclaw", "hermes":
		return true
	default:
		return false
	}
}

// effectiveForPlan 生效能力 (doc-12 §11.8.2): 内置 runtime = adapter 静态上界 (系统推导);
// 外部 endpoint = 静态上界 ∩ runtime_card/probe 声明。adapter 已只暴露真实实现的能力。
func effectiveForPlan(cp RuntimeControlPlane, declared CapabilitySet) CapabilitySet {
	if capabilitiesSystemDerived(cp.Framework()) {
		return cp.Capabilities()
	}
	return Effective(cp.Capabilities(), declared)
}

// PlanAgentRegister 纯判定 (doc-12 §6.1/§11.8.2 buildPlan 门槛 + worker 防御校验):
// 仅当 control plane 存在、提供 AgentSyncer、该环境可执行、且生效能力含 agent.create 时为 true。
// 内置 runtime (openclaw/hermes) 生效能力系统推导; 外部 endpoint 仍 ∩ runtime_card/probe 声明。
// nil-safe (cp==nil → false)。
func PlanAgentRegister(cp RuntimeControlPlane, declared CapabilitySet, env ExecEnv) bool {
	if cp == nil || cp.AgentSyncer() == nil || !cp.AgentSyncExecutable(env) {
		return false
	}
	return effectiveForPlan(cp, declared).Has(CapAgentCreate)
}

// PlanAgentUnregister 纯判定: 删除数字员工时是否可以生成 agent_unregister。
// OpenClaw 当前真实注册只暴露 agent.create（CLI add），但同一个 AgentSyncer 已提供 RemoveAgent；
// 因此内置 runtime 允许 agent.create 或 agent.delete 任一生效。外部 endpoint 保持声明驱动。
func PlanAgentUnregister(cp RuntimeControlPlane, declared CapabilitySet, env ExecEnv) bool {
	if cp == nil || cp.AgentSyncer() == nil || !cp.AgentSyncExecutable(env) {
		return false
	}
	effective := effectiveForPlan(cp, declared)
	return effective.Has(CapAgentDelete) || effective.Has(CapAgentCreate)
}

// PlanSkillRegister 纯判定 (doc-12 §6.1/§11.5 buildPlan 门槛 + worker 防御校验):
// 仅当 control plane 存在、提供 SkillSyncer、该环境可执行 (复用 agent 同步的 env gate)、且生效能力含 skill.install 时为 true。
// nil-safe (cp==nil / SkillSyncer()==nil → false; 如 ZAP 无 SkillSyncer → 永不生成 skill_register)。
func PlanSkillRegister(cp RuntimeControlPlane, declared CapabilitySet, env ExecEnv) bool {
	if cp == nil || cp.SkillSyncer() == nil || !cp.AgentSyncExecutable(env) {
		return false
	}
	return effectiveForPlan(cp, declared).Has(CapSkillInstall)
}

// PlanSkillUnregister 纯判定 (doc-12 §11.5 Task C-2): 仅当 cp 提供 SkillSyncer、该环境可执行、且生效能力含 skill.uninstall 时为 true。
// nil-safe。skill 解绑后才生成 skill_unregister; 不可执行 / 未声明 skill.uninstall → 不生成。
func PlanSkillUnregister(cp RuntimeControlPlane, declared CapabilitySet, env ExecEnv) bool {
	if cp == nil || cp.SkillSyncer() == nil || !cp.AgentSyncExecutable(env) {
		return false
	}
	return effectiveForPlan(cp, declared).Has(CapSkillUninstall)
}

// Registry framework → RuntimeControlPlane 查找表。
type Registry struct {
	byFramework map[string]RuntimeControlPlane
}

// NewRegistry 用若干 control plane 构造注册表 (按各自 Framework() 索引; 空 framework 忽略)。
func NewRegistry(cps ...RuntimeControlPlane) *Registry {
	r := &Registry{byFramework: map[string]RuntimeControlPlane{}}
	for _, cp := range cps {
		if cp == nil || cp.Framework() == "" {
			continue
		}
		r.byFramework[cp.Framework()] = cp
	}
	return r
}

// For 返回 framework 对应的 control plane; 不存在返回 nil (nil-safe receiver)。
func (r *Registry) For(framework string) RuntimeControlPlane {
	if r == nil {
		return nil
	}
	return r.byFramework[framework]
}

// SyncError 是 AgentSyncer 的归一化错误: 让 worker 不依赖具体 adapter 即可区分"可重试 vs 终态"。
//
// Reason 是**内部**原因码 / 消息 (用于落 last_error + 日志), 绝不下发客户端 (doc-12 §6.2/§9)。
type SyncError struct {
	Retryable bool   // true: 网络 / 5xx / 未就绪 → worker 走 retry/backoff; false: 4xx / 鉴权 / 能力 → 终态 failed
	Reason    string // 内部原因码, e.g. "openclaw_5xx" / "openclaw_unauthorized"
	Cause     error
}

func (e *SyncError) Error() string {
	if e == nil {
		return ""
	}
	if e.Cause != nil {
		return e.Reason + ": " + e.Cause.Error()
	}
	return e.Reason
}

func (e *SyncError) Unwrap() error { return e.Cause }

// IsRetryable 报告 err 是否为可重试的 SyncError。
func IsRetryable(err error) bool {
	var se *SyncError
	return errors.As(err, &se) && se.Retryable
}

// ReasonOf 抽取归一化错误的内部原因码 (供 worker 落 last_error); 非 SyncError 时返回 err.Error()。
func ReasonOf(err error) string {
	if err == nil {
		return ""
	}
	var se *SyncError
	if errors.As(err, &se) {
		return se.Reason
	}
	return err.Error()
}
