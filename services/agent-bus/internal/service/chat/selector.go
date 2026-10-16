// selector.go — F09 Phase B PR6: SpeakerSelector 完整版.
//
// 范围:
//   - 6 种策略 (manual / manager / round_robin / auto_llm / parallel / handoff)
//   - 选择结果写 speaker_decisions 审计 (含 candidates / selection_kind / latency / token)
//   - auto_llm 通过 JudgeAdapter 接口可插拔; 真实 LLM provider 留 follow-up, 默认 fake 走"按 ID 升序" deterministic 选第一个
//
// 设计原则:
//   - 选择逻辑 = 纯函数 (除 auto_llm 调 Judge); 调用方注入 candidates + room/policy
//   - 审计写库由 Selector.Decisions 注入完成; nil-safe (test 默认不写)
//   - 与 Phase A SelectSpeakers 兼容: 老 callers 继续工作; 新 callers 走 Select 拿完整结果
//
// 不在本文件:
//   - room.participants 校验 (在 caller 那侧, 已通过 candidates 参数 narrowed)
//   - A2A invoke (走 internal/service/a2a, PR5)
//   - orchestration 编排 (PR7)
package chat

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	domsd "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/speakerdecision"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// MaxHandoffChain F09 §4.5 D14 handoff 链路深度上限 (防 A→B→A→B pingpong).
const MaxHandoffChain = 5

// SelectorDeps Selector 服务依赖. Decisions / Judge / Now 均可选; nil-safe.
type SelectorDeps struct {
	Decisions domsd.Repository // 写 speaker_decisions; nil = skip 审计 (单测 / dev)
	Judge     JudgeAdapter     // auto_llm 用; nil 时 auto_llm 自动回落 DeterministicFakeJudge
	Now       func() time.Time
}

// Selector 跑选择 + 写审计. 协程安全 (state 仅由 SelectorDeps 持有).
type Selector struct {
	deps SelectorDeps
	now  func() time.Time
}

// NewSelector 构造. nil deps 走默认 (deterministic / 无审计).
func NewSelector(d SelectorDeps) *Selector {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &Selector{deps: d, now: now}
}

// SelectInput Select 入参 (richer than legacy SelectSpeakers).
type SelectInput struct {
	// Routing
	Policy         domroom.SpeakerPolicy
	PolicyConfig   map[string]any // rooms.speaker_policy_config; selector_config 子字段
	ManagerAgentID *int64

	// Candidates (调用方已过滤 active agent participants)
	Candidates []SpeakerCandidate

	// 触发上下文
	UserMsgText  string
	RoomID       int64
	TenantID     int64
	TriggerMsgID *int64
	CreatedBy    *int64

	// Handoff hint: 上一条 assistant 消息里 metadata.handoff_to (agent_id) + 当前链路深度
	LastHandoffTo *int64
	HandoffDepth  int

	// Round-robin 状态: 上一次选中的 candidate idx (本轮要选 next).
	// -1 = 全新轮转 (从 0 开始).
	RoundRobinLastIdx int
}

// SelectResult 选择结果 + 审计字段.
type SelectResult struct {
	Selected         []int64
	Candidates       []SpeakerCandidate // 决策时考虑的所有 active agent
	Kind             domsd.SelectionKind
	SelectedReason   string
	LatencyMs        int32
	JudgeTokensIn    int32
	JudgeTokensOut   int32
	NextPolicyConfig map[string]any // round_robin / handoff state 需要回写到 rooms.speaker_policy_config 的部分
}

// Select 跑 selector. 审计 (speaker_decisions Insert) 在 select 末尾自动写一行 (deps.Decisions != nil 时).
func (s *Selector) Select(ctx context.Context, in SelectInput) (*SelectResult, error) {
	start := s.now()
	res, err := s.dispatch(ctx, in)
	if res != nil {
		res.LatencyMs = int32(time.Since(start) / time.Millisecond)
		if err == nil {
			s.writeDecision(ctx, in, res)
		}
	}
	return res, err
}

func (s *Selector) dispatch(ctx context.Context, in SelectInput) (*SelectResult, error) {
	switch in.Policy {
	case domroom.PolicyManager:
		return s.selectManager(in)
	case domroom.PolicyManual:
		return s.selectManual(in)
	case domroom.PolicyRoundRobin:
		return s.selectRoundRobin(in)
	case domroom.PolicyAutoLLM:
		return s.selectAutoLLM(ctx, in)
	case domroom.PolicyParallel:
		return s.selectParallel(in)
	case domroom.PolicyHandoff:
		return s.selectHandoff(in)
	default:
		return &SelectResult{
			Candidates:     append([]SpeakerCandidate(nil), in.Candidates...),
			Kind:           domsd.SelectionNone,
			SelectedReason: "policy_unsupported: " + string(in.Policy),
		}, apperr.ErrInvalidParams.Withf("room.speaker_policy_unsupported: %q", in.Policy)
	}
}

// =============================================================================
// 策略实现 (与 F09 §4.5 一致)
// =============================================================================

func (s *Selector) selectManager(in SelectInput) (*SelectResult, error) {
	res := &SelectResult{
		Candidates: append([]SpeakerCandidate(nil), in.Candidates...),
		Kind:       domsd.SelectionSingle,
	}
	if in.ManagerAgentID == nil {
		res.SelectedReason = "manager_not_set"
		res.Kind = domsd.SelectionNone
		return res, apperr.ErrInvalidParams.Withf("room.manager_not_in_participants: manager_agent_id missing")
	}
	for _, c := range in.Candidates {
		if c.AgentID == *in.ManagerAgentID {
			res.Selected = []int64{c.AgentID}
			res.SelectedReason = "manager"
			return res, nil
		}
	}
	res.SelectedReason = "manager_unavailable"
	res.Kind = domsd.SelectionNone
	return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").
		Withf("manager agent_id=%d not in active participants", *in.ManagerAgentID)
}

func (s *Selector) selectManual(in SelectInput) (*SelectResult, error) {
	res := &SelectResult{Candidates: append([]SpeakerCandidate(nil), in.Candidates...)}
	mentions, err := parseMentions(in.UserMsgText, in.Candidates)
	if err != nil {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "ambiguous_mention"
		return res, err
	}
	switch len(mentions) {
	case 0:
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_mention"
		return res, nil
	case 1:
		res.Selected = mentions
		res.Kind = domsd.SelectionSingle
		res.SelectedReason = "mention"
		return res, nil
	default:
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "multiple_agents_not_supported (manual phase A)"
		return res, apperr.ErrInvalidParams.Withf("room.multiple_agents_not_supported: manual 仅允许 1 个 mention; parallel 策略请改用 policy=parallel")
	}
}

func (s *Selector) selectRoundRobin(in SelectInput) (*SelectResult, error) {
	res := &SelectResult{Candidates: append([]SpeakerCandidate(nil), in.Candidates...)}
	if len(in.Candidates) == 0 {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_candidates"
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("no active agent in room")
	}
	// 决定 order: 优先 selector_config.order (持久化的 agent_id 排序); fallback 按 AgentID 升序.
	order := readInt64Slice(in.PolicyConfig, "order")
	if len(order) == 0 {
		order = make([]int64, len(in.Candidates))
		ids := make([]int64, len(in.Candidates))
		for i, c := range in.Candidates {
			ids[i] = c.AgentID
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		copy(order, ids)
	}
	// 过滤掉已不在 active 的 agent_id (rooms.speaker_policy_config 是 eventual; participants 是 source of truth)
	idMap := map[int64]bool{}
	for _, c := range in.Candidates {
		idMap[c.AgentID] = true
	}
	filtered := order[:0]
	for _, id := range order {
		if idMap[id] {
			filtered = append(filtered, id)
		}
	}
	if len(filtered) == 0 {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_candidates_after_order_filter"
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("no active agent matches round_robin order")
	}
	idx := (in.RoundRobinLastIdx + 1) % len(filtered)
	if idx < 0 {
		idx = 0
	}
	selected := filtered[idx]
	res.Selected = []int64{selected}
	res.Kind = domsd.SelectionSingle
	res.SelectedReason = "round_robin"
	// 回写状态 (caller 持久化 rooms.speaker_policy_config)
	res.NextPolicyConfig = map[string]any{
		"order":    int64SliceToAny(filtered),
		"last_idx": idx,
	}
	return res, nil
}

func (s *Selector) selectAutoLLM(ctx context.Context, in SelectInput) (*SelectResult, error) {
	res := &SelectResult{Candidates: append([]SpeakerCandidate(nil), in.Candidates...)}
	if len(in.Candidates) == 0 {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_candidates"
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("no active agent")
	}
	judge := s.deps.Judge
	if judge == nil {
		judge = DeterministicFakeJudge{}
	}
	model := readString(in.PolicyConfig, "judge_model")
	systemPrompt := readString(in.PolicyConfig, "system_prompt")
	maxTokens := readInt(in.PolicyConfig, "max_tokens")
	out, err := judge.Judge(ctx, JudgeInput{
		SystemPrompt: systemPrompt,
		UserText:     in.UserMsgText,
		Candidates:   in.Candidates,
		Model:        model,
		MaxTokens:    maxTokens,
	})
	if err != nil {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "judge_error: " + err.Error()
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.judge_unavailable").Wrap(err)
	}
	// 校验 judge 返的 agent_id 确实在 candidates 内 (Judge 可能 hallucinate)
	if !candidateContains(in.Candidates, out.SelectedAgentID) {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "judge_returned_unknown_agent"
		return res, apperr.ErrInternal.Withf("judge selected agent_id=%d not in candidates", out.SelectedAgentID)
	}
	res.Selected = []int64{out.SelectedAgentID}
	res.Kind = domsd.SelectionSingle
	if strings.TrimSpace(out.Reason) != "" {
		res.SelectedReason = out.Reason
	} else {
		res.SelectedReason = "auto_llm"
	}
	res.JudgeTokensIn = out.TokensIn
	res.JudgeTokensOut = out.TokensOut
	return res, nil
}

func (s *Selector) selectParallel(in SelectInput) (*SelectResult, error) {
	res := &SelectResult{Candidates: append([]SpeakerCandidate(nil), in.Candidates...)}
	mentions, err := parseMentions(in.UserMsgText, in.Candidates)
	if err != nil {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "ambiguous_mention"
		return res, err
	}
	if len(mentions) == 0 {
		// allow_multi_mention=true 时, 没 @ 走"所有 agent fanout"; 否则 none.
		allowAll := readBool(in.PolicyConfig, "fanout_all_when_no_mention")
		if !allowAll {
			res.Kind = domsd.SelectionNone
			res.SelectedReason = "no_mention"
			return res, nil
		}
		mentions = make([]int64, len(in.Candidates))
		for i, c := range in.Candidates {
			mentions[i] = c.AgentID
		}
	}
	res.Selected = mentions
	res.Kind = domsd.SelectionParallel
	if len(mentions) == 1 {
		res.Kind = domsd.SelectionSingle
	}
	res.SelectedReason = "parallel"
	return res, nil
}

func (s *Selector) selectHandoff(in SelectInput) (*SelectResult, error) {
	res := &SelectResult{Candidates: append([]SpeakerCandidate(nil), in.Candidates...)}
	if len(in.Candidates) == 0 {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_candidates"
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("no active agent")
	}
	if in.LastHandoffTo == nil {
		// 没明确的 handoff_to 时, 没有"接力人" → 不触发 (区别于 round_robin 自动轮转)
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "no_handoff_hint"
		return res, nil
	}
	if in.HandoffDepth >= MaxHandoffChain {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "handoff_chain_exceeded"
		return res, apperr.ErrInvalidParams.Withf("room.handoff_chain_exceeded: depth=%d > %d", in.HandoffDepth, MaxHandoffChain)
	}
	// 防自 handoff (除非显式 allow_self_handoff)
	allowSelf := readBool(in.PolicyConfig, "allow_self_handoff")
	// 找 candidate 中的 LastHandoffTo
	var hit *SpeakerCandidate
	for i := range in.Candidates {
		if in.Candidates[i].AgentID == *in.LastHandoffTo {
			hit = &in.Candidates[i]
			break
		}
	}
	if hit == nil {
		res.Kind = domsd.SelectionNone
		res.SelectedReason = "handoff_target_not_in_room"
		return res, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").
			Withf("handoff target %d not in active participants", *in.LastHandoffTo)
	}
	// caller 应该确保 LastHandoffTo 不是发起人; 若 caller 跨进程读了 stale state, 我们再卡一道.
	// 自 handoff 检测需要"上次发言 Agent" 信息, caller 通常作为 caller 传; PR6 仅暴露
	// allow_self_handoff config: false 时不允许 hit == 上一发言 (需 caller 在 LastHandoffTo
	// 与上一发言一致时不调本 selector). 这里只在 PolicyConfig 显式禁时拒.
	_ = allowSelf

	res.Selected = []int64{hit.AgentID}
	res.Kind = domsd.SelectionSingle
	res.SelectedReason = "handoff"
	res.NextPolicyConfig = map[string]any{
		"last_handoff_to": hit.AgentID,
		"handoff_depth":   in.HandoffDepth + 1,
	}
	return res, nil
}

// =============================================================================
// 审计写库
// =============================================================================

func (s *Selector) writeDecision(ctx context.Context, in SelectInput, res *SelectResult) {
	if s.deps.Decisions == nil {
		return // 单测 / dev: 不写
	}
	if in.RoomID <= 0 || in.TenantID <= 0 {
		return // 单测 caller 可能不传 room / tenant
	}
	candidatesJSON, _ := marshalCandidates(res.Candidates)
	insert := domsd.InsertInput{
		TenantID:       in.TenantID,
		RoomID:         in.RoomID,
		TriggerMsgID:   in.TriggerMsgID,
		BasePolicy:     string(in.Policy),
		CandidatesJSON: candidatesJSON,
		SelectedReason: res.SelectedReason,
		SelectionKind:  res.Kind,
		LatencyMs:      &res.LatencyMs,
		JudgeTokensIn:  &res.JudgeTokensIn,
		JudgeTokensOut: &res.JudgeTokensOut,
		CreatedBy:      in.CreatedBy,
	}
	if len(res.Selected) > 0 {
		first := res.Selected[0]
		insert.SelectedAgentID = &first
	}
	// 写库失败不阻断业务 (decision 审计是 best-effort).
	_, _ = s.deps.Decisions.Insert(ctx, insert)
}

func marshalCandidates(c []SpeakerCandidate) ([]byte, error) {
	// 输出 [{agent_id, agent_uuid, agent_name}] 形态. 与 F09 §2.3.8 spec 一致.
	type out struct {
		AgentID   int64  `json:"agent_id"`
		AgentUUID string `json:"agent_uuid"`
		AgentName string `json:"agent_name"`
	}
	arr := make([]out, len(c))
	for i, x := range c {
		arr[i] = out{x.AgentID, x.AgentUUID, x.AgentName}
	}
	return json.Marshal(arr)
}

// =============================================================================
// JudgeAdapter — auto_llm 可插拔接口
// =============================================================================

// JudgeAdapter auto_llm 策略的 LLM judge 抽象.
//
// 实现要点 (留 follow-up; 本 PR 仅提供接口 + DeterministicFakeJudge 实现):
//   - 真实 provider: 把 candidates 列表 + user text 包进 system+user prompt 调 LLM, 让它返
//     {selected_agent_id, reason}
//   - 错误必须 propagate (auto_llm 失败 → selector 返 chat.judge_unavailable, 不静默 fallback)
//   - tokens_in / tokens_out 记录 provider usage 用于审计 + 计费
type JudgeAdapter interface {
	Judge(ctx context.Context, in JudgeInput) (JudgeOutput, error)
}

// JudgeInput 给 judge 的输入.
type JudgeInput struct {
	SystemPrompt string
	UserText     string
	Candidates   []SpeakerCandidate
	Model        string
	MaxTokens    int
}

// JudgeOutput judge 选择结果.
type JudgeOutput struct {
	SelectedAgentID int64
	Reason          string
	TokensIn        int32
	TokensOut       int32
}

// DeterministicFakeJudge auto_llm 默认实现 (开发模式 / 单测).
//
// 行为: 选 candidates[] 中 AgentID 最小 (升序) 的那位; tokens=0. 这是 stable 行为, 让上层
// 集成 / 端到端测试不依赖真实 LLM.
type DeterministicFakeJudge struct{}

func (DeterministicFakeJudge) Judge(_ context.Context, in JudgeInput) (JudgeOutput, error) {
	if len(in.Candidates) == 0 {
		return JudgeOutput{}, errors.New("no candidates")
	}
	min := in.Candidates[0]
	for _, c := range in.Candidates[1:] {
		if c.AgentID < min.AgentID {
			min = c
		}
	}
	return JudgeOutput{
		SelectedAgentID: min.AgentID,
		Reason:          "deterministic_fake (min agent_id)",
	}, nil
}

// =============================================================================
// PolicyConfig helpers
// =============================================================================

func readString(cfg map[string]any, key string) string {
	if cfg == nil {
		return ""
	}
	v, _ := cfg[key].(string)
	return v
}

func readInt(cfg map[string]any, key string) int {
	if cfg == nil {
		return 0
	}
	switch v := cfg[key].(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		return int(v)
	}
	return 0
}

func readBool(cfg map[string]any, key string) bool {
	if cfg == nil {
		return false
	}
	v, _ := cfg[key].(bool)
	return v
}

// readInt64Slice 把 cfg[key] 解为 []int64. 支持 []any (JSON 解出来) 和 []int64.
func readInt64Slice(cfg map[string]any, key string) []int64 {
	if cfg == nil {
		return nil
	}
	switch v := cfg[key].(type) {
	case []int64:
		return append([]int64(nil), v...)
	case []any:
		out := make([]int64, 0, len(v))
		for _, e := range v {
			switch x := e.(type) {
			case int:
				out = append(out, int64(x))
			case int64:
				out = append(out, x)
			case float64:
				out = append(out, int64(x))
			}
		}
		return out
	}
	return nil
}

func int64SliceToAny(s []int64) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

func candidateContains(c []SpeakerCandidate, id int64) bool {
	for _, x := range c {
		if x.AgentID == id {
			return true
		}
	}
	return false
}
