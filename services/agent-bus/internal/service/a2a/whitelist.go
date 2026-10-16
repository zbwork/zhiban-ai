// Package a2a 实现 F09 §3.5 / §4.7 A2A backchannel invoke + 6 重安全校验.
//
// 调用入口: POST /zap/v1/internal/a2a/invoke (Agent A 调 Agent B).
// 链路: transport handler → Service.Invoke → 校验链 → INSERT a2a_call_edges → IssueDerivedSessionToken
//
//	→ AgentInvoker fire (sync 异步发起 / async fire-and-forget)
//	→ 返 202 + edge_id.
//
// 6 重校验 (按顺序):
//  1. session_token 鉴权 (middleware 已做; service 拿 from_agent_id)
//  2. tenant isolation (from.tenant_id == to.tenant_id)
//  3. capability check (from_agent 必须有 agent_capability_bindings.kind='a2a_invoke')
//  4. callable whitelist (to_agent.callable_by_agents 4 mode)
//  5. quota (per-agent RPM + per-tenant RPD; Redis token bucket)
//  6. payload redaction + size cap (4 regex MVP + 16 KB)
//
// 然后才进 DB INSERT.
//
// 注意: Phase B 仅做 sync + async; stream 由 B-DEC-3 推到 Phase C.
package a2a

import (
	"encoding/json"
	"strings"
)

// CallablePolicy 是 digital_employees.callable_by_agents JSONB 的领域投影.
//
// F09 §4.7.3 4 mode:
//   - none      默认 deny, 拒任何 A2A 调用
//   - all       同租户内任意 Agent 可调
//   - workspace 仅同 workspace 内 Agent 可调
//   - explicit  仅 AgentIDs 显式列表内可调
//
// 解析失败 / mode 不识别 → 视为 mode=none (defense-in-depth).
type CallablePolicy struct {
	Mode     string   `json:"mode"`
	AgentIDs []string `json:"agent_ids,omitempty"`
}

const (
	ModeNone      = "none"
	ModeAll       = "all"
	ModeWorkspace = "workspace"
	ModeExplicit  = "explicit"
)

// ParseCallablePolicy 解析 JSON 字符串到 CallablePolicy. nil-safe + 错误回退 mode=none.
func ParseCallablePolicy(raw string) CallablePolicy {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return CallablePolicy{Mode: ModeNone}
	}
	var p CallablePolicy
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		return CallablePolicy{Mode: ModeNone}
	}
	switch p.Mode {
	case ModeNone, ModeAll, ModeWorkspace, ModeExplicit:
		return p
	default:
		// 未识别 mode → safe default deny.
		return CallablePolicy{Mode: ModeNone}
	}
}

// WhitelistInput 是 EvaluateWhitelist 的最小入参.
//   - FromAgentID/WorkspaceID = 调用方 Agent A
//   - ToAgentID/WorkspaceID   = 目标 Agent B
//   - ToCallable                    = B 的 callable_by_agents 解析结果
type WhitelistInput struct {
	FromAgentID      string
	FromAgentWorkspc *int64
	ToAgentID        string
	ToAgentWorkspc   *int64
	ToCallable       CallablePolicy
}

// EvaluateWhitelist F09 §4.7.2 step 4 callable whitelist 校验.
// 返 true = 允许调用; false = 拒.
//
// 纯函数, 全部业务规则在这一处, 方便测试.
func EvaluateWhitelist(in WhitelistInput) bool {
	switch in.ToCallable.Mode {
	case ModeNone:
		return false
	case ModeAll:
		return true
	case ModeWorkspace:
		// 两侧 workspace 必须非 nil 且相等
		if in.FromAgentWorkspc == nil || in.ToAgentWorkspc == nil {
			return false
		}
		return *in.FromAgentWorkspc == *in.ToAgentWorkspc
	case ModeExplicit:
		for _, id := range in.ToCallable.AgentIDs {
			if id == in.FromAgentID {
				return true
			}
		}
		return false
	default:
		return false
	}
}
