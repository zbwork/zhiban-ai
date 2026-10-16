// openclaw_files.go - Batch 2C T2C.3: 给 publish 时同步 OpenClaw workspace 用的 7 文件渲染器。
//
// 移植来源 (字段映射, 内容精简):
//
//	legacy ai-office/internal/pkg/openclawagentapp/service_prompts.go::agentInitFiles
//
// 7 个 md + CLAUDE.md 镜像 (与 legacy 一致):
//
//	AGENTS.md      操作手册 (workspace/agent-dir 各一份, agent-dir 下额外镜像为 CLAUDE.md)
//	SOUL.md        价值观 / 反 AI Slop (本批用极简模板)
//	IDENTITY.md    身份卡片 (name / role)
//	BOOTSTRAP.md   首次入海 (no-op 预留, 与 legacy 同款引导文案)
//	MEMORY.md      本地长期记忆禁用说明 (长期记忆由 Agent Bus + MemMachine 管理)
//	TOOLS.md       工具索引模板
//	HEARTBEAT.md   心跳模板
//
// 内容刻意精简, 仅含必备字段; M6 真技能装载 / Batch 2D 真对话上线再扩展。
package agent

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/fs"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/llmmetadata"
)

// AgentWorkspaceKBBinding 是写入 OpenClaw workspace 的授权 KB 摘要（仅名称，不含凭证）。
type AgentWorkspaceKBBinding struct {
	UUID string
	Name string
}

type WorkspaceRuntimeContext struct {
	TenantID             int64
	AccountID            int64
	RuntimeEnvironmentID int64
	RuntimeInstanceUUID  string
}

type AgentWorkspaceOptions struct {
	LLMMetadata llmmetadata.Context
}

const openClawWorkspaceStatePath = ".openclaw/workspace-state.json"

// BuildAgentWorkspaceFiles 渲染 7 md + CLAUDE.md 镜像 -> []FileWrite,
// 准备同时写 workspace 路径 (root) 和 agent-dir 路径 (agentDirPath)。
//
// 调用方传 workspacePath (含 agent_uuid 子目录) 与 agentDirPath。
// 返回 FileWrite 数组覆盖以下路径:
//
//	<workspace>/<7 个 md>
//	<workspace>/.openclaw/workspace-state.json
//	<agent-dir>/<7 个 md>
//	<agent-dir>/CLAUDE.md   (= AGENTS.md 镜像)
func BuildAgentWorkspaceFiles(agent *domagent.DigitalEmployee, workspacePath, agentDirPath string) []fs.FileWrite {
	return BuildAgentWorkspaceFilesWithKBBindings(agent, nil, workspacePath, agentDirPath)
}

// BuildAgentWorkspaceFilesWithKBBindings 渲染 workspace 文件，并将授权 KB 名称清单写入 AGENTS.md。
func BuildAgentWorkspaceFilesWithKBBindings(agent *domagent.DigitalEmployee, kbBindings []AgentWorkspaceKBBinding, workspacePath, agentDirPath string) []fs.FileWrite {
	return BuildAgentWorkspaceFilesWithOptions(agent, kbBindings, workspacePath, agentDirPath, AgentWorkspaceOptions{})
}

func BuildAgentWorkspaceFilesWithOptions(agent *domagent.DigitalEmployee, kbBindings []AgentWorkspaceKBBinding, workspacePath, agentDirPath string, opts AgentWorkspaceOptions) []fs.FileWrite {
	return buildAgentWorkspaceFiles(agent, kbBindings, workspacePath, agentDirPath, opts, time.Now().UTC())
}

func buildAgentWorkspaceFiles(agent *domagent.DigitalEmployee, kbBindings []AgentWorkspaceKBBinding, workspacePath, agentDirPath string, opts AgentWorkspaceOptions, now time.Time) []fs.FileWrite {
	files := agentInitFiles(agent, kbBindings, opts)
	out := make([]fs.FileWrite, 0, len(files)*2+2)
	for _, f := range files {
		out = append(out, fs.FileWrite{AbsPath: workspacePath + "/" + f.Name, Data: f.Body})
		out = append(out, fs.FileWrite{AbsPath: agentDirPath + "/" + f.Name, Data: f.Body})
		// agent-dir 下额外把 AGENTS.md 镜像为 CLAUDE.md (OpenClaw 主指令文件约定)
		if f.Name == "AGENTS.md" {
			out = append(out, fs.FileWrite{AbsPath: agentDirPath + "/CLAUDE.md", Data: f.Body})
		}
	}
	// OpenClaw 以 workspace 根目录下 BOOTSTRAP.md 存在且 setupCompletedAt 缺失判定为
	// bootstrap pending。Bus 已一次性写好 ready-to-use 的 Agent workspace, 因此必须同步标记完成,
	// 否则每条用户消息都会被 OpenClaw 注入 bootstrap-pending 指令。
	out = append(out, fs.FileWrite{
		AbsPath: workspacePath + "/" + openClawWorkspaceStatePath,
		Data:    []byte(renderWorkspaceState(now)),
	})
	return out
}

func renderWorkspaceState(now time.Time) string {
	ts := now.UTC().Format(time.RFC3339)
	return fmt.Sprintf(`{
  "version": 1,
  "bootstrapSeededAt": %q,
  "setupCompletedAt": %q
}
`, ts, ts)
}

// agentMdFile 模板渲染产物。
type agentMdFile struct {
	Name string
	Body []byte
}

// agentInitFiles 与 legacy agentInitFiles 同名同语义, 返回 7 个 md。
func agentInitFiles(a *domagent.DigitalEmployee, kbBindings []AgentWorkspaceKBBinding, opts AgentWorkspaceOptions) []agentMdFile {
	return []agentMdFile{
		{Name: "AGENTS.md", Body: []byte(renderAgentsMd(a, kbBindings, opts))},
		{Name: "SOUL.md", Body: []byte(renderSoulMd(a))},
		{Name: "IDENTITY.md", Body: []byte(renderIdentityMd(a))},
		{Name: "BOOTSTRAP.md", Body: []byte(renderBootstrapMd(a))},
		{Name: "MEMORY.md", Body: []byte(renderMemoryMd(a))},
		{Name: "TOOLS.md", Body: []byte(renderToolsMd(a))},
		{Name: "HEARTBEAT.md", Body: []byte(renderHeartbeatMd(a))},
	}
}

func agentDisplayName(a *domagent.DigitalEmployee) string {
	if a == nil || a.Name == "" {
		return "Agent"
	}
	return a.Name
}

func agentIntro(a *domagent.DigitalEmployee) string {
	if a == nil {
		return ""
	}
	if a.Intro != "" {
		return a.Intro
	}
	if a.Description != "" {
		return a.Description
	}
	return ""
}

func agentPositionLabel(a *domagent.DigitalEmployee) string {
	if a == nil {
		return ""
	}
	if a.PositionLabel != "" {
		return a.PositionLabel
	}
	// metadata.position_label 兼容 legacy 字段
	if a.Metadata != nil {
		if v, ok := a.Metadata["position_label"].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

func renderAgentsMd(a *domagent.DigitalEmployee, kbBindings []AgentWorkspaceKBBinding, opts AgentWorkspaceOptions) string {
	return fmt.Sprintf(`# AGENTS.md - 你的工作空间

> 此文件由 知办AI Agent Bus 自动生成, 标识 Agent 在 OpenClaw 容器内的身份与基本约定。
> 不要把 "已读取 AGENTS.md / 初始化完成" 等元信息汇报给用户; bootstrap 对用户透明。

## 你是谁

- 名字: %s
- 角色: %s
- 介绍: %s

## 工作目录约定

- 当前工作目录由 OpenClaw 注入 (workspace + agent-dir).
- 不要假设可访问 /etc /home /root 等系统目录; 仅在 /data 下读写。
- 文件操作走 OpenClaw 内置 Read/Write/Bash 工具, 不要自创新协议.

## 文件产物交付

- 所有要交给用户的本地文件都必须在最终回复中带真实 /data/... 绝对路径；不得只写文件名。
- 图片使用 ![名称](</data/.../image.png>)，其他文件使用 [名称](</data/.../file.ext>)；URL 外层尖括号不能省略。
- 平台会把这些本地路径转换为可鉴权的预览/下载地址并登记结果文件；不要自行调用上传脚本、S3 或自造 URL。
- OpenClaw 若把结构化媒体规范化为独占一行的 MEDIA:/data/...，保持该真实路径，不要改写成 /media/...、sandbox: 或只剩文件名。

## 记忆边界

- 长期记忆由知办 AI 平台在 OpenClaw 外层处理: 你只能通过平台工具 zhiban_memory_recall / zhiban_memory_write 读写 MemMachine。
- 不要调用 OpenClaw 自带 memory_search / memory_get / memory_write 获取或保存用户长期记忆。
- 不要读取、写入、创建或提交 USER.md、MEMORY.md、memory/ 目录、memory/YYYY-MM-DD.md、memory/learnings/。
- 用户明确要求"记住"、纠正稳定事实、表达长期偏好或形成群共享事实时, 调用 zhiban_memory_write。
- 需要回忆用户信息、偏好、历史决定或当前会话上下文时, 调用 zhiban_memory_recall; 不要从本地文件补读。

%s

## 行为准则

参考 SOUL.md (价值观) 与 IDENTITY.md (身份).
`,
		agentDisplayName(a),
		agentPositionLabel(a),
		agentIntro(a),
		renderKnowledgePolicySection(kbBindings),
	)
}

func LLMMetadataContextFromWorkspace(a *domagent.DigitalEmployee, rt WorkspaceRuntimeContext) llmmetadata.Context {
	agentUUID := ""
	runtimeEnvID := rt.RuntimeEnvironmentID
	if a != nil {
		agentUUID = a.UUID
		if runtimeEnvID <= 0 && a.RuntimeEnvironmentID != nil {
			runtimeEnvID = *a.RuntimeEnvironmentID
		}
	}
	return llmmetadata.Context{
		UsageScene:        "chat",
		TenantID:          rt.TenantID,
		AccountID:         rt.AccountID,
		AgentID:           agentUUID,
		RuntimeEnvID:      runtimeEnvID,
		RuntimeInstanceID: rt.RuntimeInstanceUUID,
	}
}

func renderKnowledgePolicySection(kbBindings []AgentWorkspaceKBBinding) string {
	var b strings.Builder
	b.WriteString("## 授权知识库\n\n")
	names := make([]string, 0, len(kbBindings))
	for _, kb := range kbBindings {
		name := strings.TrimSpace(kb.Name)
		if name == "" {
			continue
		}
		names = append(names, name)
	}
	if len(names) > 0 {
		b.WriteString("平台已为当前数字员工绑定以下知识库（工具 zhiban_kb_search，逻辑名 zhiban.kb.search）：\n\n")
		for _, name := range names {
			fmt.Fprintf(&b, "- %s\n", name)
		}
		b.WriteString("\n")
	} else {
		b.WriteString("当前数字员工尚未绑定平台知识库；若后续绑定，本段会随 runtime resync 自动更新。\n\n")
	}
	b.WriteString(`## 知识检索策略

- 平台会在每条用户消息进入推理前自动预检索授权知识库，结果以 [Authorized Knowledge Context] 注入。
- 优先基于预检索结果回答；引用 reference_id，勿凭常识或历史印象编造来源。
- 若预检索未找到足够依据、需要对比或多轮深挖，且运行时暴露了 zhiban_kb_search，可调用该工具补充检索。
- 工具不可用或调用失败时如实说明，勿伪装已检索。

## 平台数字员工协作策略

- 用户要求协作调用、调用某个数字员工、找某个岗位员工、让某某处理，或询问"你能和哪些数字员工/同事/岗位一起处理任务"、"有哪些可协作员工"时，必须先调用 zhiban_a2a_discover。
- 可协作对象清单只能来自 zhiban_a2a_discover 的返回值；回答时使用工具返回的真实 name / 岗位信息。
- 不要从知识库、原型文档、历史对话或常识里编造可协作数字员工，不要把原型角色名当成真实员工名。
- 不要使用 OpenClaw 自带 sessions_list、sessions_spawn、sessions_yield、session_search 或本地 session 来联系知办平台数字员工；这些只能代表 OpenClaw 内部子会话，不是平台 A2A 协作。
- 需要委派任务时，先从 discover 返回候选里选择目标，再调用 zhiban_a2a_invoke；若返回 pending/running，继续用 zhiban_a2a_get_edge 等到 done/failed/cancelled/rejected/expired/dropped_* 或 awaiting_approval 后再总结。
`)
	return b.String()
}

func renderSoulMd(a *domagent.DigitalEmployee) string {
	return fmt.Sprintf(`# SOUL.md - 价值观

> %s 的工作信条。

## 反 AI Slop

- 不输出"作为 AI 助手, 我..."等套话开头。
- 不在回答里复述用户的问题。
- 不主动推销自己的能力; 用户问什么答什么。

## 诚实

- 不知道就说不知道; 不编造工具调用结果。
- 工具失败如实反馈错误, 不掩盖。
`,
		agentDisplayName(a),
	)
}

func renderIdentityMd(a *domagent.DigitalEmployee) string {
	return fmt.Sprintf(`# IDENTITY.md - 身份卡片

- **名字**: %s
- **岗位**: %s
- **介绍**: %s
- **主模型**: %s
- **欢迎语**: %s
`,
		agentDisplayName(a),
		agentPositionLabel(a),
		agentIntro(a),
		agentModel(a),
		agentWelcome(a),
	)
}

func agentModel(a *domagent.DigitalEmployee) string {
	if a == nil {
		return "(由 OpenClaw 默认配置)"
	}
	// ADR-0037 Phase 3 G3: BYOK 数字员工渲染成"自建模型服务"文案, 不暴露内部
	// aigc/openai/<id> 这类合成 provider 命名规则进 IDENTITY.md。
	if a.ModelSource == "byok" {
		if label := byokModelLabel(a.ModelServiceConfigJSON); label != "" {
			return label
		}
	}
	if a.ModelPrimary == "" {
		return "(由 OpenClaw 默认配置)"
	}
	return a.ModelPrimary
}

// byokModelLabel 把 model_service_config 渲染成 "自建模型服务：<endpoint_type> / <model_id>"。
// 解析失败/字段缺失 → 空字符串 (调用方回落默认文案), 不是内部错误。
func byokModelLabel(modelServiceConfigJSON string) string {
	var cfg struct {
		EndpointType string `json:"endpoint_type"`
		ModelID      string `json:"model_id"`
	}
	if err := json.Unmarshal([]byte(modelServiceConfigJSON), &cfg); err != nil {
		return ""
	}
	endpointType := strings.TrimSpace(cfg.EndpointType)
	modelID := strings.TrimSpace(cfg.ModelID)
	if endpointType == "" || modelID == "" {
		return ""
	}
	return "自建模型服务：" + endpointType + " / " + modelID
}

func agentWelcome(a *domagent.DigitalEmployee) string {
	if a == nil || a.WelcomeMsg == "" {
		return ""
	}
	return a.WelcomeMsg
}

func renderBootstrapMd(a *domagent.DigitalEmployee) string {
	return `# BOOTSTRAP.md - 初始化

> 这是一份 no-op bootstrap。OpenClaw 启动时读它, 不需要执行任何外部命令。
> 不要把 "BOOTSTRAP 已处理" 这件事汇报给用户。

## 检查清单

1. 当前工作空间已就绪 (AGENTS.md / SOUL.md / IDENTITY.md 已写入)
2. 工具白名单已加载
3. 准备接收用户消息
`
}

func renderMemoryMd(a *domagent.DigitalEmployee) string {
	return `# MEMORY.md - 本地记忆已禁用

OpenClaw runtime 不再使用本文件保存或读取长期记忆。

长期记忆由 EasyO Agent Bus 在 OpenClaw 外层写入并召回 MemMachine。

不要向本文件、USER.md 或 memory/ 目录写入用户偏好、事实、会话总结、业务背景或自我学习内容。
`
}

func renderToolsMd(a *domagent.DigitalEmployee) string {
	return fmt.Sprintf(`# TOOLS.md - 工具索引

> %s 当前可用工具的索引。技能在 skills/<slug>/ 下安装, 工具白名单见 OpenClaw 配置。
> 本文件首次创建时为空模板, 由 Agent 自行追加使用心得 / 失败案例。
`,
		agentDisplayName(a),
	)
}

func renderHeartbeatMd(a *domagent.DigitalEmployee) string {
	return fmt.Sprintf(`# HEARTBEAT.md - 心跳

> %s 的运行状态记录, 由 Agent 自行更新; 首次为空模板。
`,
		agentDisplayName(a),
	)
}
