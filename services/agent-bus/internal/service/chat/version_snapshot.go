// version_snapshot.go — Batch 2D T2D.3-B: 真实版本快照 fail-closed 校验 + 诊断。
//
// chat.Send 不再读 digital_employees 上的临时字段拼 prompt; 一律走
// digital_employees.current_version → agent_versions.snapshot 加载并校验关键字段。
//
// **运行时职责** (T2D.11 smoke 暴露 Gateway v3 strict schema 后定稿):
//   1. fail-closed 校验:
//      - current_version <= 0                       → chat.agent_no_version
//      - GetVersion 返回错误                        → chat.version_snapshot_invalid
//      - snapshot 缺 model_primary 或为空           → chat.llm_model_missing
//      不 mock, 不 fallback, 不写 user/agent message, 不启动 stream goroutine
//      (Send 在持久化之前调本函数, 失败直接 return; 所以 message 自然不写)。
//   2. 诊断日志: runAgent 头部 Info 日志带 agent_version + model 字段。
//
// **不在 chat.send wire 上传递 snapshot 字段** (T2D.11 smoke 实测 Gateway v3 strict
// schema 拒未知顶层字段, 例如 'metadata' → "invalid chat.send params: at root:
// unexpected property 'metadata'"):
//
//   - chat.send mainParams **只允许** sessionKey / message / idempotencyKey 三字段
//   - system prompt / model / temperature / context_window 等 snapshot 衍生配置
//     **由 2C publish 时 syncer.Sync 写入 OpenClaw Agent Card / workspace 7 md 生效**
//     (LLM 实际跑哪个模型 / 怎么响应, 完全由容器侧 Agent 配置决定)
//   - chat 服务读 snapshot 是为了 (a) 校验配置完整 + (b) 关联日志, 不是为了运行时覆盖
//
// 因此 versionParams 不向 mainParams 注入任何字段; 单测直接断言 mainParams 顶层只有
// sessionKey/message/idempotencyKey, 防 schema 回归。
//
// 详见 docs/tasks/batch-2d-main-flow-1v1-chat.md §10 R6 "Gateway v3 strict schema 最终决策"。

package chat

import (
	"context"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// chat.Send 写到 messages.error_code / SSE event.error 的 T2D.3-B 错误码。
const (
	ErrCodeAgentNoVersion         = "chat.agent_no_version"
	ErrCodeVersionSnapshotInvalid = "chat.version_snapshot_invalid"
	ErrCodeLLMModelMissing        = "chat.llm_model_missing"
)

// versionParams 是从 agent_versions.snapshot 抽出的 chat 路径所需字段集。
//
// Temperature / ContextWindow 用指针表达 "snapshot 没有这一项" 与 "snapshot 有但是 0"
// 的区别 —— 0 也是合法值, 不该被默认值蒙混。
type versionParams struct {
	Version       int
	SelectedModel string // validated per-message selection; never persisted into the employee
	Model         string
	SystemPrompt  string
	Temperature   *float64
	ContextWindow *int
	AgentName     string
}

// loadVersionParams 按 ag.CurrentVersion 取 agent_versions.snapshot, 抽出 chat 路径
// 所需字段并校验 model 必填。任何缺失返回 *apperr.Error (UpstreamUnavailable + 明确 code)。
func (s *impl) loadVersionParams(ctx context.Context, ag *domagent.DigitalEmployee) (*versionParams, error) {
	if ag == nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeAgentNoVersion).Withf("nil agent")
	}
	if ag.CurrentVersion <= 0 {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeAgentNoVersion).
			Withf("agent has no published version (de_id=%d current_version=%d)", ag.ID, ag.CurrentVersion)
	}
	v, err := s.agents.GetVersion(ctx, ag.ID, ag.CurrentVersion)
	if err != nil {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeVersionSnapshotInvalid).Wrap(err).
			Withf("load agent_versions de_id=%d version=%d", ag.ID, ag.CurrentVersion)
	}
	if v == nil || v.Snapshot == nil || len(v.Snapshot) == 0 {
		return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeVersionSnapshotInvalid).
			Withf("agent_versions snapshot empty (de_id=%d version=%d)", ag.ID, ag.CurrentVersion)
	}

	p := &versionParams{Version: ag.CurrentVersion}

	// ADR-0037: model_source=byok 的快照里 model_primary 本来就是空的 (设计如此,
	// 真正的模型信息在 model_service_config 里)——这个校验只是"发布配置完整性"
	// 的 fail-closed 兜底 + 诊断日志用 (p.Model 从不上 chat.send wire, 见文件头
	// 注释), 换成校验 model_service_config.model_id, 不能沿用 model_primary 必填。
	if modelSource, _ := v.Snapshot["model_source"].(string); modelSource == "byok" {
		modelID := ""
		if cfg, ok := v.Snapshot["model_service_config"].(map[string]any); ok {
			if id, ok := cfg["model_id"].(string); ok {
				modelID = id
			}
		}
		if modelID == "" {
			return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLLMModelMissing).
				Withf("snapshot.model_service_config.model_id missing or empty (de_id=%d version=%d)", ag.ID, ag.CurrentVersion)
		}
		p.Model = "byok:" + modelID
	} else {
		// model_primary 必填: 没有模型 OpenClaw 跑不了。
		switch m := v.Snapshot["model_primary"].(type) {
		case string:
			p.Model = m
		}
		if p.Model == "" {
			return nil, apperr.New(apperr.UpstreamUnavailable, ErrCodeLLMModelMissing).
				Withf("snapshot.model_primary missing or empty (de_id=%d version=%d)", ag.ID, ag.CurrentVersion)
		}
	}

	if sp, ok := v.Snapshot["system_prompt"].(string); ok {
		p.SystemPrompt = sp
	}
	// temperature: BuildSnapshot 写 float32 → JSON round-trip 后变 float64。
	if t, ok := v.Snapshot["temperature"].(float64); ok {
		p.Temperature = &t
	}
	// context_window: 同上 int → float64 (JSON 数字)。
	if cw, ok := v.Snapshot["context_window"].(float64); ok {
		n := int(cw)
		p.ContextWindow = &n
	}
	if name, ok := v.Snapshot["name"].(string); ok {
		p.AgentName = name
	}
	return p, nil
}

// 设计说明: Gateway v3 chat.send schema 为 strict-additionalProperties (实测拒任何未知顶层字段,
// 含 'metadata'); snapshot 衍生的 system prompt / model / temperature 实际**由 2C publish
// 写入 OpenClaw 的 Agent Card / workspace 7 md 生效**, 不需要在 chat.send 时二次传递。
//
// 因此 versionParams 在 T2D.3-B 的运行时职责仅为:
//   (a) Send 同步阶段强校验 model_primary 等 fail-closed 字段 (loadVersionParams)
//   (b) runAgent 头部诊断日志 (agent_version + model)
//
// 不再向 mainParams 注入 metadata; 单测直接断言 mainParams 顶层只有 sessionKey/message/
// idempotencyKey, 防回归。详见 docs/tasks/batch-2d-main-flow-1v1-chat.md §10 R6
// (T2D.11 smoke 暴露的 Gateway v3 schema 现实)。
