// Package deorch 是「编排型数字员工」运行期 MVP (doc-14 Objective E)。
//
// 一个 agent_kind=orchestrator 的数字员工对外是**单一入口**(一个 agent_uuid),
// 内部按 metadata.orchestration.strategy 调度若干成员 (child) 数字员工:
//   - manager    主控调度 (MVP: Planner 选全部, 预留 LLM planner 接口)
//   - sequential 顺序协作 (上一个输出喂下一个)
//   - parallel   并行协作 (并发调用 + reducer 合并)
//
// 本包只做**编排逻辑 + run/step/edge 建模 + A2A 准入 fail-closed**; 真实 child 调用经
// AgentInvoker 接口注入 (chat 包提供复用现有 OpenClaw 链路的实现; 单测用 fake)。
// 不写用户可见的 child 会话/消息; 子 agent 输出只进 orchestration/a2a trace。
package deorch

import (
	"errors"
	"fmt"
	"strings"
)

// 数字员工类型 (digital_employees.metadata.agent_kind)。
const (
	AgentKindSingle       = "single"
	AgentKindOrchestrator = "orchestrator"
)

// Strategy 协作方式 (digital_employees.metadata.orchestration.strategy)。
type Strategy string

const (
	StrategyManager    Strategy = "manager"    // 主控调度
	StrategySequential Strategy = "sequential" // 顺序协作
	StrategyParallel   Strategy = "parallel"   // 并行协作
)

func (s Strategy) valid() bool {
	switch s {
	case StrategyManager, StrategySequential, StrategyParallel:
		return true
	}
	return false
}

var (
	// ErrNotOrchestrator metadata.agent_kind != orchestrator (调用方应走单体路径)。
	ErrNotOrchestrator = errors.New("deorch: not an orchestrator agent")
	// ErrNoChildren orchestration.child_agent_uuids 为空。
	ErrNoChildren = errors.New("deorch: orchestrator has no child agents")
	// ErrBadStrategy strategy 非法 (非 manager/sequential/parallel)。
	ErrBadStrategy = errors.New("deorch: invalid orchestration strategy")
)

// Config 是从 digital_employees.metadata 解析出的编排配置。
type Config struct {
	Strategy   Strategy
	ChildUUIDs []string // 去重、去空, 保序
}

// IsOrchestrator 判定 metadata.agent_kind 是否为 orchestrator。nil/缺省 → false (单体)。
func IsOrchestrator(metadata map[string]any) bool {
	if metadata == nil {
		return false
	}
	kind, _ := metadata["agent_kind"].(string)
	return kind == AgentKindOrchestrator
}

// ParseConfig 解析编排配置。非 orchestrator → ErrNotOrchestrator; 无 child → ErrNoChildren;
// strategy 非法 → ErrBadStrategy。child_agent_uuids 去重去空保序。
func ParseConfig(metadata map[string]any) (Config, error) {
	if !IsOrchestrator(metadata) {
		return Config{}, ErrNotOrchestrator
	}
	orchRaw, _ := metadata["orchestration"].(map[string]any)
	if orchRaw == nil {
		return Config{}, ErrNoChildren
	}
	strategy := Strategy(strings.TrimSpace(asString(orchRaw["strategy"])))
	if !strategy.valid() {
		return Config{}, fmt.Errorf("%w: %q", ErrBadStrategy, strategy)
	}
	childUUIDs := parseChildUUIDs(orchRaw["child_agent_uuids"])
	if len(childUUIDs) == 0 {
		return Config{}, ErrNoChildren
	}
	return Config{Strategy: strategy, ChildUUIDs: childUUIDs}, nil
}

// parseChildUUIDs 把 jsonb 数组 (来自 admin 写入) 解析为去重去空保序的 uuid 列表。
func parseChildUUIDs(v any) []string {
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		u := strings.TrimSpace(asString(item))
		if u == "" {
			continue
		}
		if _, dup := seen[u]; dup {
			continue
		}
		seen[u] = struct{}{}
		out = append(out, u)
	}
	return out
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
