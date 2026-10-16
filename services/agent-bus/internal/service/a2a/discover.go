// discover.go — A2A v1b Agent 发现 (plans/2026-07-06 §9 / ZAP-1.1 §12.4)。
//
// 定位: caller-scoped 的候选查询。**发现只是候选提示, 不是授权** —— invoke 仍全量重校验,
// 本方法与 invoke 共享同一套静态准入实现 (HasA2AInvokeCapability / ParseCallablePolicy /
// EvaluateWhitelist), SQL 侧过滤见 repository/postgres/a2adiscovery。
//
// query 先尝试 pgvector 语义召回; 失败时降级到 keyset 候选内的 embedding/LLM/确定性排序。
// 发现不检查 quota/depth/cycle (运行时维度只在 invoke 查)。A2A 是否可被调用由发起方
// a2a_invoke capability + 被调方 callable_by_agents 决定; 客户端通讯录 visibility 不作为
// A2A 候选过滤条件, 避免把已允许同租户协作的 private/workspace agent 隐掉。
package a2a

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"unicode"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/metrics"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// DiscoverSource 候选查询仓储 (实现: repository/postgres/a2adiscovery; interface segregation
// 同 AgentLookup 模式 —— 接口在 service, 实现只依赖 domain 类型)。
//
// SQL 侧保证: 同租户、排除 excludeAgentID、published、未软删、
// runtime enabled+active+egress approved、id > afterID 升序、≤ limit 行。
// 返回的 DigitalEmployee 为**部分填充** (ID/UUID/Name/Tags/WorkspaceID/CallableByAgentsJSON/
// A2ACardJSON), 其中 ID 仅作 keyset 游标, 绝不出现在响应。
type DiscoverSource interface {
	ListCandidates(ctx context.Context, tenantID, excludeAgentID, afterID int64, limit int) ([]*domagent.DigitalEmployee, error)
}

// SemanticDiscoverSource 用 embedding 向量召回首屏候选。它只是排序/召回来源, 不替代
// discoverCandidateAllowed / invoke 的硬鉴权。
type SemanticDiscoverSource interface {
	ListSemanticCandidates(ctx context.Context, tenantID, excludeAgentID int64, queryVector []float64, embeddingModel string, embeddingDims, limit, offset int) ([]*domagent.DigitalEmployee, map[string]float64, error)
}

// DiscoverInput 业务入参 (transport 从 st_ 注入身份)。
type DiscoverInput struct {
	FromAgentID int64
	TenantID    int64

	Tags   []string
	Mode   string // "" / sync / async
	Query  string // 可选; v1c 硬过滤后的轻量确定性排序
	Limit  int    // 默认 20, clamp [1,50]
	Cursor string // 不透明 keyset 游标 ("" = 从头)
}

// DiscoverRanker 在硬过滤后的候选集内做语义重排。它不是授权来源, 不能新增候选,
// 只能给已有 DiscoverEntry 返回 0..1 分数; 失败时 Discover 降级到确定性词项排序。
type DiscoverRanker interface {
	RankDiscover(ctx context.Context, query string, entries []DiscoverEntry) (map[string]float64, error)
}

// DiscoverEntry 响应条目 —— 只含对外安全字段 (无内部 id / endpoint / runtime key)。
type DiscoverEntry struct {
	AgentUUID        string                    `json:"agent_id"`
	Name             string                    `json:"name"`
	Summary          string                    `json:"summary"`
	WhenToUse        []string                  `json:"when_to_use"`
	WhenNotToUse     []string                  `json:"when_not_to_use"`
	Examples         []domagent.A2ACardExample `json:"examples"`
	Tags             []string                  `json:"tags"`
	InputSchema      map[string]any            `json:"input_schema"`
	SupportedModes   []string                  `json:"supported_modes"`
	RiskLevel        string                    `json:"risk_level"`
	RequiresApproval bool                      `json:"requires_approval"`
	MatchScore       *float64                  `json:"match_score"` // query 为空时 null; query 非空时 0..1
}

// DiscoverResult 响应。
type DiscoverResult struct {
	Agents          []DiscoverEntry `json:"agents"`
	NextCursor      string          `json:"next_cursor"`
	Confidence      *float64        `json:"confidence,omitempty"`
	ShouldClarify   bool            `json:"should_clarify,omitempty"`
	ClarifyQuestion string          `json:"clarify_question,omitempty"`
}

const (
	discoverDefaultLimit = 20
	discoverMaxLimit     = 50
	discoverMaxTags      = 10
	// discoverBatchSize 单次 SQL 批量 (≥ maxLimit, Go 侧 whitelist/tags/mode 过滤有折损余量)。
	discoverBatchSize = 200
	// discoverMaxBatches 单请求扫描上限 (200×5=1000 行), 防租户超大 + 过滤命中率极低时打满 DB;
	// 到达上限即带 cursor 返回部分结果, 调用方可续翻。
	discoverMaxBatches = 5
	// discoverClarifyMinScore / discoverClarifyMinGap 是“是否值得先问用户”的轻量阈值。
	// 它只影响响应提示，不改变候选、不扩大授权集。
	discoverClarifyMinScore = 0.55
	discoverClarifyMinGap   = 0.12
)

// Discover A2A v1b 发现主入口。
func (s *Service) Discover(ctx context.Context, in DiscoverInput) (*DiscoverResult, error) {
	if s.deps.Discover == nil {
		return nil, apperr.ErrInternal.Withf("a2a discover source not wired")
	}
	s.logInfo(ctx, "a2a.discover.start",
		"tenant_id", in.TenantID,
		"from_agent_id", in.FromAgentID,
		"query", clipA2AText(in.Query, 120),
		"tags", in.Tags,
		"mode", in.Mode,
		"limit", in.Limit,
		"cursor_set", strings.TrimSpace(in.Cursor) != "",
	)
	if in.FromAgentID <= 0 || in.TenantID <= 0 {
		s.logWarn(ctx, "a2a.discover.reject",
			"reason", "missing_identity",
			"tenant_id", in.TenantID,
			"from_agent_id", in.FromAgentID,
		)
		return nil, apperr.ErrUnauthorized.Withf("a2a.session_invalid: missing identity")
	}
	switch in.Mode {
	case "", "sync", "async":
	default:
		return nil, apperr.ErrInvalidParams.Withf("mode must be sync|async")
	}
	if len(in.Tags) > discoverMaxTags {
		return nil, apperr.ErrInvalidParams.Withf("tags exceeds %d items", discoverMaxTags)
	}
	in.Query = strings.TrimSpace(in.Query)
	if len([]rune(in.Query)) > 200 {
		return nil, apperr.ErrInvalidParams.Withf("query exceeds 200 runes")
	}
	limit := in.Limit
	if limit <= 0 {
		limit = discoverDefaultLimit
	}
	if limit > discoverMaxLimit {
		limit = discoverMaxLimit
	}
	cursorState, err := parseDiscoverCursor(in.Cursor, in.Query)
	if err != nil {
		return nil, err
	}

	// from_agent 校验: 存在、同租户、published、未删除 (与 invoke 同口径, 统一模糊 401)。
	fromAgent, err := s.deps.Agents.GetByID(ctx, in.FromAgentID)
	if err != nil || fromAgent == nil || fromAgent.IsDeleted ||
		fromAgent.TenantID != in.TenantID || fromAgent.Status != "published" {
		s.logWarn(ctx, "a2a.discover.reject",
			"reason", "from_agent_invalid",
			"tenant_id", in.TenantID,
			"from_agent_id", in.FromAgentID,
			"err", errString(err),
		)
		return nil, apperr.ErrUnauthorized.Withf("from_agent not found")
	}
	// a2a_invoke 哨兵 capability (能调才有必要发现, plans/2026-07-06 §18.7)。
	ok, err := s.deps.CapabilityRepo.HasA2AInvokeCapability(ctx, fromAgent.ID)
	if err != nil {
		s.logWarn(ctx, "a2a.discover.reject",
			"reason", "capability_check_error",
			"from_agent", agentLogFields(fromAgent),
			"err", err.Error(),
		)
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !ok {
		metrics.IncA2AReject("capability")
		s.logWarn(ctx, "a2a.discover.reject",
			"reason", "missing_a2a_invoke_capability",
			"from_agent", agentLogFields(fromAgent),
		)
		return nil, ErrMissingCapability
	}

	out := &DiscoverResult{Agents: []DiscoverEntry{}}
	seenIDs := map[int64]bool{}
	if in.Query != "" && (cursorState.Kind == discoverCursorEmpty || cursorState.Kind == discoverCursorSemantic) {
		nextOffset, exhausted, used := s.appendSemanticDiscoverCandidates(ctx, fromAgent, in, out, limit, seenIDs, cursorState.SemanticOffset)
		if cursorState.Kind == discoverCursorSemantic && !used {
			return nil, apperr.ErrInternal.Withf("a2a semantic discover unavailable")
		}
		if len(out.Agents) >= limit {
			if !exhausted {
				out.NextCursor = formatSemanticDiscoverCursor(nextOffset, in.Query)
			}
			s.finalizeDiscover(ctx, fromAgent, in, out)
			return out, nil
		}
		if cursorState.Kind == discoverCursorSemantic {
			if !exhausted {
				out.NextCursor = formatSemanticDiscoverCursor(nextOffset, in.Query)
			}
			s.finalizeDiscover(ctx, fromAgent, in, out)
			return out, nil
		}
		if used && !exhausted && len(out.Agents) > 0 {
			out.NextCursor = formatSemanticDiscoverCursor(nextOffset, in.Query)
			s.finalizeDiscover(ctx, fromAgent, in, out)
			return out, nil
		}
	}
	cursor := cursorState.KeysetAfterID
	for batch := 0; batch < discoverMaxBatches; batch++ {
		rows, err := s.deps.Discover.ListCandidates(ctx, in.TenantID, fromAgent.ID, cursor, discoverBatchSize)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		exhausted := len(rows) < discoverBatchSize
		for _, cand := range rows {
			cursor = cand.ID
			if seenIDs[cand.ID] {
				continue
			}
			if !discoverCandidateAllowed(fromAgent, cand, in.Tags, in.Mode) {
				continue
			}
			out.Agents = append(out.Agents, buildDiscoverEntry(cand, in.Query))
			seenIDs[cand.ID] = true
			if len(out.Agents) >= limit {
				// 页满: 无论 SQL 是否扫尽, 都给续翻游标 (下一页可能为空页, 由调用方按空结果收敛)。
				out.NextCursor = formatDiscoverCursor(cursor)
				s.finalizeDiscover(ctx, fromAgent, in, out)
				return out, nil
			}
		}
		if exhausted {
			out.NextCursor = ""
			s.finalizeDiscover(ctx, fromAgent, in, out)
			return out, nil
		}
	}
	// 扫描上限截断: 带游标返回部分结果。
	out.NextCursor = formatDiscoverCursor(cursor)
	s.finalizeDiscover(ctx, fromAgent, in, out)
	return out, nil
}

func (s *Service) finalizeDiscover(ctx context.Context, fromAgent *domagent.DigitalEmployee, in DiscoverInput, out *DiscoverResult) {
	s.applyDiscoverRanking(ctx, in.Query, out.Agents)
	applyDiscoverClarification(in.Query, out)
	s.fireDiscoverAudit(ctx, fromAgent, in, out)
	top := make([]map[string]any, 0, 10)
	for i := 0; i < len(out.Agents) && i < 10; i++ {
		top = append(top, map[string]any{
			"agent_id":    shortA2AID(out.Agents[i].AgentUUID),
			"name":        out.Agents[i].Name,
			"match_score": out.Agents[i].MatchScore,
		})
	}
	s.logInfo(ctx, "a2a.discover.finish",
		"tenant_id", in.TenantID,
		"from_agent", agentLogFields(fromAgent),
		"query", clipA2AText(in.Query, 120),
		"result_count", len(out.Agents),
		"next_cursor_set", strings.TrimSpace(out.NextCursor) != "",
		"should_clarify", out.ShouldClarify,
		"top", top,
	)
}

func (s *Service) applyDiscoverRanking(ctx context.Context, query string, entries []DiscoverEntry) {
	query = strings.TrimSpace(query)
	if query != "" && s.deps.DiscoverRanker != nil && len(entries) > 1 {
		if scores, err := s.deps.DiscoverRanker.RankDiscover(ctx, query, entries); err == nil {
			known := map[string]bool{}
			for i := range entries {
				known[entries[i].AgentUUID] = true
			}
			applied := false
			for i := range entries {
				score, ok := scores[entries[i].AgentUUID]
				if !ok || !known[entries[i].AgentUUID] {
					continue
				}
				score = clampDiscoverScore(score)
				entries[i].MatchScore = &score
				applied = true
			}
			if applied {
				sortDiscoverEntries(entries)
				return
			}
		}
	}
	sortDiscoverEntries(entries)
}

// discoverCandidateAllowed Go 侧过滤: whitelist (与 invoke 同一实现) + tags + mode。
func discoverCandidateAllowed(from, cand *domagent.DigitalEmployee, tags []string, mode string) bool {
	policy := ParseCallablePolicy(cand.CallableByAgentsJSON)
	if !EvaluateWhitelist(WhitelistInput{
		FromAgentID:      from.UUID,
		FromAgentWorkspc: from.WorkspaceID,
		ToAgentID:        cand.UUID,
		ToAgentWorkspc:   cand.WorkspaceID,
		ToCallable:       policy,
	}) {
		return false
	}
	if len(tags) > 0 && !tagsIntersect(cand.Tags, tags) {
		return false
	}
	if mode != "" {
		card := domagent.ParseA2ACardLenient(cand.A2ACardJSON)
		if !card.SupportsMode(mode) {
			return false
		}
	}
	return true
}

func buildDiscoverEntry(cand *domagent.DigitalEmployee, query string) DiscoverEntry {
	card := domagent.ParseA2ACardLenient(cand.A2ACardJSON) // 非法卡片 → 空卡默认值, 不 panic 不剔除
	tags := cand.Tags
	if tags == nil {
		tags = []string{}
	}
	entry := DiscoverEntry{
		AgentUUID:        cand.UUID,
		Name:             cand.Name,
		Summary:          card.Summary,
		WhenToUse:        card.WhenToUse,
		WhenNotToUse:     card.WhenNotToUse,
		Examples:         card.Examples,
		Tags:             tags,
		InputSchema:      card.InputSchema,
		SupportedModes:   card.SupportedModes,
		RiskLevel:        card.RiskLevel,
		RequiresApproval: card.RequiresApproval,
		MatchScore:       nil,
	}
	if strings.TrimSpace(query) != "" {
		score := discoverMatchScore(entry, query)
		entry.MatchScore = &score
	}
	return entry
}

func sortDiscoverEntries(entries []DiscoverEntry) {
	hasScore := false
	for i := range entries {
		if entries[i].MatchScore != nil {
			hasScore = true
			break
		}
	}
	if !hasScore {
		return
	}
	sort.SliceStable(entries, func(i, j int) bool {
		li, lj := entries[i].MatchScore, entries[j].MatchScore
		if li != nil || lj != nil {
			var si, sj float64
			if li != nil {
				si = *li
			}
			if lj != nil {
				sj = *lj
			}
			if si != sj {
				return si > sj
			}
		}
		return entries[i].AgentUUID < entries[j].AgentUUID
	})
}

func applyDiscoverClarification(query string, out *DiscoverResult) {
	if out == nil || strings.TrimSpace(query) == "" {
		return
	}
	confidence := 0.0
	if len(out.Agents) > 0 && out.Agents[0].MatchScore != nil {
		confidence = clampDiscoverScore(*out.Agents[0].MatchScore)
	}
	out.Confidence = &confidence
	ambiguous := false
	if len(out.Agents) == 0 {
		ambiguous = true
	} else if confidence < discoverClarifyMinScore {
		ambiguous = true
	} else if len(out.Agents) > 1 && out.Agents[1].MatchScore != nil {
		second := clampDiscoverScore(*out.Agents[1].MatchScore)
		if confidence-second < discoverClarifyMinGap {
			ambiguous = true
		}
	}
	if !ambiguous {
		return
	}
	out.ShouldClarify = true
	out.ClarifyQuestion = buildDiscoverClarifyQuestion(out.Agents)
}

func buildDiscoverClarifyQuestion(entries []DiscoverEntry) string {
	if len(entries) == 0 {
		return "没有找到足够匹配的协作对象。可以补充任务目标、业务场景或希望哪个数字员工协助吗？"
	}
	names := []string{}
	for i := 0; i < len(entries) && i < 3; i++ {
		if name := strings.TrimSpace(entries[i].Name); name != "" {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return "候选协作对象不够明确。可以补充任务目标、业务场景或期望输出吗？"
	}
	return "当前可能适合 " + strings.Join(names, "、") + "。你希望哪一个来协助，或补充一下任务目标？"
}

func discoverMatchScore(entry DiscoverEntry, query string) float64 {
	tokens := discoverQueryTokens(query)
	if len(tokens) == 0 {
		return 0
	}
	name := strings.ToLower(entry.Name)
	summary := strings.ToLower(entry.Summary)
	tags := strings.ToLower(strings.Join(entry.Tags, " "))
	when := strings.ToLower(strings.Join(append(append([]string{}, entry.WhenToUse...), entry.WhenNotToUse...), " "))
	examples := make([]string, 0, len(entry.Examples)*2)
	for _, ex := range entry.Examples {
		examples = append(examples, ex.Input, ex.Expect)
	}
	exampleText := strings.ToLower(strings.Join(examples, " "))
	queryLower := strings.ToLower(strings.TrimSpace(query))

	score := 0.0
	if queryLower != "" {
		if strings.Contains(name, queryLower) {
			score += 0.45
		}
		if strings.Contains(summary, queryLower) {
			score += 0.35
		}
		if strings.Contains(when, queryLower) || strings.Contains(exampleText, queryLower) {
			score += 0.2
		}
	}
	for _, tok := range tokens {
		switch {
		case strings.Contains(name, tok):
			score += 0.18
		case strings.Contains(tags, tok):
			score += 0.16
		case strings.Contains(summary, tok):
			score += 0.12
		case strings.Contains(when, tok):
			score += 0.08
		case strings.Contains(exampleText, tok):
			score += 0.05
		}
	}
	if score > 1 {
		return 1
	}
	return score
}

func clampDiscoverScore(score float64) float64 {
	if score < 0 {
		return 0
	}
	if score > 1 {
		return 1
	}
	return score
}

func discoverQueryTokens(query string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, part := range strings.FieldsFunc(strings.ToLower(query), func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r)
	}) {
		part = strings.TrimSpace(part)
		if part == "" || seen[part] {
			continue
		}
		seen[part] = true
		out = append(out, part)
	}
	return out
}

func tagsIntersect(candTags, want []string) bool {
	for _, w := range want {
		for _, t := range candTags {
			if t == w {
				return true
			}
		}
	}
	return false
}

type discoverCursorKind int

const (
	discoverCursorEmpty discoverCursorKind = iota
	discoverCursorKeyset
	discoverCursorSemantic
)

type discoverCursorState struct {
	Kind           discoverCursorKind
	KeysetAfterID  int64
	SemanticOffset int
}

// cursor 编解码:
//   - v1b keyset = "v1:<lastID>" 十进制
//   - v1s semantic = "s1:<offset>:<queryHash>"
//
// 对调用方不透明 (契约禁止解析), 服务端可随时换编码。
func parseDiscoverCursor(c, query string) (discoverCursorState, error) {
	c = strings.TrimSpace(c)
	if c == "" {
		return discoverCursorState{Kind: discoverCursorEmpty}, nil
	}
	if raw, ok := strings.CutPrefix(c, "v1:"); ok {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id < 0 {
			return discoverCursorState{}, apperr.ErrInvalidParams.Withf("invalid cursor")
		}
		return discoverCursorState{Kind: discoverCursorKeyset, KeysetAfterID: id}, nil
	}
	if raw, ok := strings.CutPrefix(c, "s1:"); ok {
		parts := strings.Split(raw, ":")
		if len(parts) != 2 {
			return discoverCursorState{}, apperr.ErrInvalidParams.Withf("invalid cursor")
		}
		offset, err := strconv.Atoi(parts[0])
		if err != nil || offset < 0 {
			return discoverCursorState{}, apperr.ErrInvalidParams.Withf("invalid cursor")
		}
		if strings.TrimSpace(query) == "" || parts[1] != discoverQueryHash(query) {
			return discoverCursorState{}, apperr.ErrInvalidParams.Withf("invalid cursor")
		}
		return discoverCursorState{Kind: discoverCursorSemantic, SemanticOffset: offset}, nil
	}
	return discoverCursorState{}, apperr.ErrInvalidParams.Withf("invalid cursor")
}

func formatDiscoverCursor(lastID int64) string {
	return "v1:" + strconv.FormatInt(lastID, 10)
}

func formatSemanticDiscoverCursor(offset int, query string) string {
	if offset < 0 {
		offset = 0
	}
	return "s1:" + strconv.Itoa(offset) + ":" + discoverQueryHash(query)
}

func discoverQueryHash(query string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(query)))
	return hex.EncodeToString(sum[:8])
}

// fireDiscoverAudit plans/2026-07-06 §14.3: 每次 discover 落审计 (from + 过滤参数 + 返回 uuid)。
// 事后可回答「当时它看到了什么候选」。失败 fire-and-forget。
func (s *Service) fireDiscoverAudit(ctx context.Context, from *domagent.DigitalEmployee, in DiscoverInput, out *DiscoverResult) {
	if s.deps.Audit == nil {
		return
	}
	uuids := make([]string, 0, len(out.Agents))
	for _, a := range out.Agents {
		uuids = append(uuids, a.AgentUUID)
	}
	raw, _ := json.Marshal(map[string]any{
		"from_agent_id":  from.UUID,
		"tags":           in.Tags,
		"mode":           in.Mode,
		"query":          in.Query,
		"limit":          in.Limit,
		"returned_count": len(out.Agents),
		"returned_uuids": uuids,
	})
	_ = s.deps.Audit.Insert(ctx, domaudit.Event{
		OccurredAt:   s.deps.Now(),
		TenantID:     from.TenantID,
		ActorKind:    domaudit.ActorAgent,
		Domain:       "a2a",
		EventKind:    "a2a.discover",
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "digital_employee",
		ResourceUUID: from.UUID,
		Payload:      raw,
	})
}
