package agent

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"regexp"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domrt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const managedAgentKeyMetadata = "agent_key"

var nonAgentKeyChar = regexp.MustCompile(`[^a-z0-9]+`)

func (s *impl) ensureManagedZAPAgentKey(ctx context.Context, e *dom.DigitalEmployee, excludeAgentID int64) (bool, error) {
	if e == nil || e.RuntimeEnvironmentID == nil || *e.RuntimeEnvironmentID <= 0 || isSupportBuiltinAgent(e) {
		return false, nil
	}
	if s.rtRead == nil {
		return false, nil
	}
	reg, err := s.rtRead.Get(ctx, *e.RuntimeEnvironmentID)
	if err != nil {
		return false, err
	}
	if reg == nil || (strings.ToLower(strings.TrimSpace(reg.Framework)) != "zap" && strings.ToLower(strings.TrimSpace(reg.Framework)) != "dsh") {
		return false, nil
	}
	if e.Metadata == nil {
		e.Metadata = map[string]any{}
	}

	current := strings.TrimSpace(metadataString(e.Metadata, managedAgentKeyMetadata))
	if current != "" {
		available, err := s.agentKeyAvailable(ctx, e.TenantID, *e.RuntimeEnvironmentID, current, excludeAgentID)
		if err != nil {
			return false, err
		}
		if available {
			return false, nil
		}
	}

	base := managedAgentKeyBase(e.Name, reg)
	// 共享 runtime (dsh) 上 agent_key 是运行时内的全局身份, 必须跨租户唯一 (见 agentKeyAvailable)。
	// 靠"撞了加后缀"解决不了规模问题: 候选只试 20 个, 而一个平台预置会下发给**全部租户**
	// (2026-08-25 实测一次 112 份), 同模板同名 → 同 base, 第 21 个租户起就建不出员工。
	// 故加租户命名空间, 从构造上互不重叠; 后缀循环退回只处理"同租户内同名员工"这种小规模冲突。
	if s.sharedAgentStoreEnv(ctx, reg) && e.TenantID > 0 {
		base = truncateAgentKey("t"+strconv.FormatInt(e.TenantID, 10)+"-"+base, 64)
	}
	for i := 0; i < 20; i++ {
		candidate := withAgentKeySuffix(base, i)
		available, err := s.agentKeyAvailable(ctx, e.TenantID, *e.RuntimeEnvironmentID, candidate, excludeAgentID)
		if err != nil {
			return false, err
		}
		if available {
			e.Metadata[managedAgentKeyMetadata] = candidate
			return current != candidate, nil
		}
	}
	return false, apperr.ErrConflict.Withf("agent.agent_key_conflict: runtime_environment_id=%d base=%s", *e.RuntimeEnvironmentID, base)
}

// sharedAgentStoreEnv 报告该 runtime 是否"多租户共用一套 agent 存储"——即 agent_key 是运行时内的
// 全局身份。当前只有自营 dsh 满足 (external_endpoint + 按 key 平铺存 agent 卡片); 第三方 ZAP 的存储
// 模型不由我们决定, 且存量已大量跨租户共用同名 key, 不能一刀切 (见 agentKeyAvailable 注释)。
func (s *impl) sharedAgentStoreEnv(ctx context.Context, reg *domrt.Registration) bool {
	if reg == nil || strings.ToLower(strings.TrimSpace(reg.Framework)) != "dsh" || s.pool == nil {
		return false
	}
	var external bool
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(hosting_kind,'') = 'external_endpoint'
		  FROM runtime_environments WHERE id = $1`, reg.ID).Scan(&external); err != nil {
		return false // 解析不出就按"非共享"处理: 退回原有按租户口径, 不影响正确性
	}
	return external
}

func (s *impl) agentKeyAvailable(ctx context.Context, tenantID, runtimeID int64, agentKey string, excludeAgentID int64) (bool, error) {
	if s.pool == nil {
		return true, nil
	}
	// 查重范围取决于该 runtime 是不是"共享一套 agent 存储":
	//   - external_endpoint (ZAP/dsh): 所有租户共用同一个 runtime, 而 ZAP 的 POST /agents 不带租户、
	//     runtime 按 agent_key 平铺存 agent 卡片 (dsh-runtime: <durable>/config/agents/<key>/agent.yml)。
	//     所以 agent_key 是**运行时内的全局身份**, 必须跨租户唯一 —— 否则 A 租户注册会覆盖 B 租户同名
	//     agent 的名字/人设/模型 (2026-08-25 实测: 平台预置下发给 112 个租户, 副本全部拿到同一个 key)。
	//     数据面 (会话/工作区/历史) 仍按租户隔离, 被覆盖的是配置面, 但人设本身就是业务资产。
	//   - clawmanager / k8s_native (OpenClaw 等): 每租户·账号各有自己的 pod, agent 存在各自 workspace,
	//     不存在跨租户覆盖, 维持按租户查重 (否则平白给存量员工加后缀)。
	// 平台模板 (source='platform') 不进 runtime prewarm、永不注册, 不占用全局 key; 但它的**租户副本**
	// 会走本函数拿到各自的 key。
	//
	// **只对自营 dsh 生效**, 第三方 ZAP runtime 明确排除, 原因是实测发现的存量事实 (2026-08-25):
	// 平台预置下发给全部租户后, 每个租户副本都拿到同名 key —— agent-example(env 16) 有 288 个员工共用
	// `main`, 创小融/百工/财税同样如此, 且都在正常注册。对它们启用跨租户唯一会有两个伤害:
	//   1. 存量员工下次编辑时 key 被判"已被他人占用"→ 改名 → 第三方 runtime 那侧的 agent 变孤儿;
	//   2. 候选后缀只试 20 个 (withAgentKeySuffix), 上百租户的下发会直接建不出员工。
	// 第三方 runtime 的 agent 存储模型不由我们决定, 是否也存在覆盖需各自确认后再决策; dsh 是我们自己的,
	// 存储模型确定 (按 key 平铺), 且当前无存量重复, 收敛在这里零爆炸半径。
	var exists bool
	if err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			  FROM digital_employees de
			  JOIN runtime_environments re ON re.id = de.runtime_environment_id
			 WHERE de.runtime_environment_id = $2
			   AND de.is_deleted = false
			   AND de.deleted_at IS NULL
			   AND NULLIF(BTRIM(de.metadata->>'agent_key'), '') IS NOT NULL
			   AND LOWER(BTRIM(de.metadata->>'agent_key')) = LOWER($3)
			   AND ($4::bigint = 0 OR de.id <> $4::bigint)
			   AND (
			         COALESCE(de.tenant_id, 0) = $1
			         OR (
			              COALESCE(re.hosting_kind, '') = 'external_endpoint'
			              AND LOWER(COALESCE(re.framework, '')) = 'dsh'
			              AND de.source <> 'platform'
			            )
			       )
		)`,
		tenantID, runtimeID, strings.TrimSpace(agentKey), excludeAgentID).Scan(&exists); err != nil {
		return false, apperr.ErrInternal.Withf("agent.agent_key_check_failed: %v", err)
	}
	return !exists, nil
}

func managedAgentKeyBase(name string, reg *domrt.Registration) string {
	if reg != nil && !runtimeSupportsMultiAgent(reg) {
		if def := runtimeDefaultAgentKey(reg); def != "" {
			return truncateAgentKey(def, 48)
		}
	}
	slug := strings.Trim(nonAgentKeyChar.ReplaceAllString(strings.ToLower(strings.TrimSpace(name)), "-"), "-")
	if slug == "" {
		slug = "agent-" + shortAgentKeyHash(strings.TrimSpace(name))
	}
	return truncateAgentKey(slug, 48)
}

func withAgentKeySuffix(base string, idx int) string {
	if idx == 0 {
		return base
	}
	suffix := "-" + strconv.Itoa(idx+1)
	return truncateAgentKey(base, 64-len(suffix)) + suffix
}

func truncateAgentKey(v string, max int) string {
	v = strings.Trim(strings.ToLower(strings.TrimSpace(v)), "-")
	if v == "" {
		return "agent"
	}
	if len(v) <= max {
		return v
	}
	return strings.TrimRight(v[:max], "-")
}

func shortAgentKeyHash(s string) string {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	out := strconv.FormatUint(uint64(h.Sum32()), 36)
	if out == "" {
		return "0"
	}
	if len(out) > 6 {
		return out[:6]
	}
	return out
}

func runtimeSupportsMultiAgent(reg *domrt.Registration) bool {
	if reg == nil {
		return false
	}
	if v, ok := boolMetadata(reg.Metadata, "supports_multi_agent"); ok {
		return v
	}
	card := runtimeCardMetadata(reg.Metadata)
	if v, ok := boolMetadata(card, "supports_multi_agent"); ok {
		return v
	}
	if max, ok := intMetadata(reg.Metadata, "max_agents"); ok && max > 1 {
		return true
	}
	if max, ok := intMetadata(card, "max_agents"); ok && max > 1 {
		return true
	}
	return false
}

func runtimeDefaultAgentKey(reg *domrt.Registration) string {
	if reg == nil {
		return ""
	}
	if v := metadataString(reg.Metadata, "default_agent_key"); v != "" {
		return v
	}
	return metadataString(runtimeCardMetadata(reg.Metadata), "default_agent_key")
}

func runtimeCardMetadata(metadata map[string]any) map[string]any {
	raw, ok := metadata["runtime_card"]
	if !ok || raw == nil {
		return nil
	}
	card, _ := raw.(map[string]any)
	return card
}

func metadataString(metadata map[string]any, key string) string {
	if metadata == nil {
		return ""
	}
	v, _ := metadata[key].(string)
	return strings.TrimSpace(v)
}

func boolMetadata(metadata map[string]any, key string) (bool, bool) {
	if metadata == nil {
		return false, false
	}
	v, ok := metadata[key].(bool)
	return v, ok
}

func intMetadata(metadata map[string]any, key string) (int, bool) {
	if metadata == nil {
		return 0, false
	}
	switch v := metadata[key].(type) {
	case int:
		return v, true
	case int64:
		return int(v), true
	case float64:
		return int(v), true
	case json.Number:
		i, err := strconv.Atoi(string(v))
		return i, err == nil
	default:
		return 0, false
	}
}
