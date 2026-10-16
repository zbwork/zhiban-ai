// speaker.go — SpeakerSelector 解析层 (mention parser + 兼容签名).
//
// 历史:
//   - Phase A (2E): 仅 manual + manager, 是本文件原 SelectSpeakers 实现.
//   - PR6 (Phase B): 6 策略完整版搬到 selector.go (Selector 结构 + 审计).
//
// 本文件保留:
//   - SpeakerCandidate 数据类型
//   - parseMentions / mentionToken / uuidLike 正则 (selector.go 也用)
//   - SelectSpeakers 老签名 backward-compat shim, 内部委托给 Selector.Select (无审计 / 无 judge).
//     业务调用方 (room/service.go, wukong_agent_trigger.go) 仍可用老签名; 想走 round_robin /
//     auto_llm / parallel / handoff / 审计 / judge 时, 用 NewSelector(...) + Selector.Select.
package chat

import (
	"context"
	"regexp"
	"strings"

	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// SpeakerCandidate 描述群内一个 active agent participant, 供 selector mention 匹配。
//
// AgentID/UUID 取自 digital_employees; Name 取自 digital_employees.name; 不带 alias / nick (M5)。
type SpeakerCandidate struct {
	AgentID   int64
	AgentUUID string
	AgentName string
}

// SelectSpeakers Phase A 老签名 backward-compat shim.
//
// 内部走 Selector (无审计 / 无 judge), 仅返 selected []int64 + error.
// 老 callers (room.SendUserMessage + wukong_agent_trigger) 无需改动即可工作.
//
// 新 callers (需要 round_robin / auto_llm / parallel / handoff / 审计) 应直接调
// NewSelector(...) + Selector.Select.
//
// 返回:
//   - nil, nil          → 不触发任何 Agent (manual 策略 + 无 mention; 群成纯人对话)
//   - [agentID], nil    → 触发该 1 个 agent
//   - [agentIDs], nil   → parallel 策略时多 agent
//   - nil, apperr.Err*  → 拒绝触发 (multi / ambiguous / unavailable / depth / ...)
func SelectSpeakers(
	policy domroom.SpeakerPolicy,
	managerAgentID *int64,
	candidates []SpeakerCandidate,
	userMsgText string,
) ([]int64, error) {
	s := NewSelector(SelectorDeps{}) // 无审计 / 无 judge
	res, err := s.Select(context.Background(), SelectInput{
		Policy:            policy,
		ManagerAgentID:    managerAgentID,
		Candidates:        candidates,
		UserMsgText:       userMsgText,
		RoundRobinLastIdx: -1,
	})
	if err != nil {
		return nil, err
	}
	if res == nil {
		return nil, nil
	}
	return res.Selected, nil
}

// HasMentionToken 判断文本是否含至少一个 @mention token (复用 mentionToken 正则)。
// 与 parseMentions 的前缀规则一致: 行首 / 空白 / 中英文标点 (，,。.；;) 后的 @ 才算;
// email 形态 a@b 不算。供 WuKong trigger 区分"@了某人" vs "纯文本", 取代
// strings.Contains(text, "@") 的粗判。
func HasMentionToken(text string) bool {
	return mentionToken.MatchString(text)
}

// mentionToken 匹配 @<token>, token 不含空白 / 控制字符 / @。
//
// 例:
//
//	"@AgentX 帮我 review"   → ["AgentX"]
//	"@uuid-aaaa @uuid-bbbb" → ["uuid-aaaa","uuid-bbbb"]
//	"test@example.com"       → 不匹配 (开头必须是 @ 或前缀是空白)
//
// 用 lookbehind 模拟: 匹配 `(^|\s|[，,。.;;])@(token)`, token 字符集排除空白与 @。
var mentionToken = regexp.MustCompile(`(?:^|[\s，,。.；;])@([^\s@，,。.；;]+)`)

// uuidLike 粗判一个 token 是不是 UUID (32~36 hex+dash)。
//
// agent uuid 是 gen_random_uuid() 格式 (8-4-4-4-12, 36 字符含 4 个 dash); 兼容客户端
// 可能传纯 hex (32 字符) 或大小写。不引入完整 UUID 解析, 性能/复杂度都不必要。
var uuidLike = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// parseMentions 解析 userMsgText 中 @ 提到的 agent, 去重保留首次出现顺序。
//
// 命中规则:
//  1. token 命中某 candidate.AgentUUID (大小写不敏感) → 选中
//  2. fallback: token 命中某 candidate.AgentName (大小写不敏感, 精确等于) → 选中
//     如果 name 匹配多个 candidate → ambiguous_mention
//  3. 既不匹配 uuid 也不匹配 name → 静默忽略 (可能是 @人名 / @everyone 等)
//
// 返回 (mentionedAgentIDs, error); 错误仅 ambiguous_mention。
func parseMentions(text string, candidates []SpeakerCandidate) ([]int64, error) {
	matches := mentionToken.FindAllStringSubmatch(text, -1)
	if len(matches) == 0 {
		return nil, nil
	}
	out := make([]int64, 0, 1)
	seen := map[int64]bool{}
	for _, m := range matches {
		token := strings.TrimSpace(m[1])
		if token == "" {
			continue
		}
		lo := strings.ToLower(token)
		// 1) UUID 精确匹配
		if uuidLike.MatchString(token) {
			matched := false
			for _, c := range candidates {
				if strings.ToLower(c.AgentUUID) == lo {
					if !seen[c.AgentID] {
						seen[c.AgentID] = true
						out = append(out, c.AgentID)
					}
					matched = true
					break
				}
			}
			// uuid 形态但不匹配任何 candidate: 视为非选中 (前端打错可视为 typo)
			_ = matched
			continue
		}
		// 2) name 精确匹配 (大小写不敏感)
		nameMatches := []int64{}
		for _, c := range candidates {
			if strings.ToLower(c.AgentName) == lo {
				nameMatches = append(nameMatches, c.AgentID)
			}
		}
		switch len(nameMatches) {
		case 0:
			continue
		case 1:
			if !seen[nameMatches[0]] {
				seen[nameMatches[0]] = true
				out = append(out, nameMatches[0])
			}
		default:
			return nil, apperr.ErrInvalidParams.Withf("room.ambiguous_mention: @%s matches %d agents in this room; please use @<agent_uuid>", token, len(nameMatches))
		}
	}
	return out, nil
}
