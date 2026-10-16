package a2a

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

const (
	defaultDiscoverRankTimeout       = 3 * time.Second
	defaultDiscoverRankMaxCandidates = 20
)

// FallbackDiscoverRanker 按顺序尝试多种语义重排。前一个失败时尝试后一个;
// 所有 ranker 都失败时由 Discover 降级到确定性词项排序。
type FallbackDiscoverRanker struct {
	rankers []DiscoverRanker
}

func NewFallbackDiscoverRanker(rankers ...DiscoverRanker) *FallbackDiscoverRanker {
	out := &FallbackDiscoverRanker{}
	for _, r := range rankers {
		if r != nil {
			out.rankers = append(out.rankers, r)
		}
	}
	return out
}

func (r *FallbackDiscoverRanker) RankDiscover(ctx context.Context, query string, entries []DiscoverEntry) (map[string]float64, error) {
	if r == nil || len(r.rankers) == 0 {
		return nil, errors.New("discover ranker not configured")
	}
	var last error
	for _, ranker := range r.rankers {
		scores, err := ranker.RankDiscover(ctx, query, entries)
		if err == nil && len(scores) > 0 {
			return scores, nil
		}
		if err != nil {
			last = err
		}
	}
	if last != nil {
		return nil, last
	}
	return nil, errors.New("discover rankers returned no scores")
}

// EmbeddingDiscoverRanker 用 AIGC embedding 在已授权候选内做语义重排。它不做 DB/ANN 召回,
// 只消费 Discover 响应本来会暴露的卡片字段, 因此不能新增候选或绕过权限边界。
type EmbeddingDiscoverRanker struct {
	embedder      model.Embedder
	timeout       time.Duration
	maxCandidates int
}

func NewEmbeddingDiscoverRanker(embedder model.Embedder) *EmbeddingDiscoverRanker {
	return &EmbeddingDiscoverRanker{
		embedder:      embedder,
		timeout:       defaultDiscoverRankTimeout,
		maxCandidates: defaultDiscoverRankMaxCandidates,
	}
}

func (s *Service) appendSemanticDiscoverCandidates(ctx context.Context, fromAgent *domagent.DigitalEmployee, in DiscoverInput, out *DiscoverResult, limit int, seenIDs map[int64]bool, offset int) (nextOffset int, exhausted bool, used bool) {
	nextOffset = offset
	if s == nil || s.deps.DiscoverSemantic == nil || s.deps.DiscoverEmbedder == nil ||
		strings.TrimSpace(s.deps.DiscoverEmbeddingModel) == "" || s.deps.DiscoverEmbeddingDims <= 0 ||
		out == nil || len(out.Agents) >= limit {
		return nextOffset, false, false
	}
	query := strings.TrimSpace(in.Query)
	if query == "" {
		return nextOffset, false, false
	}
	resp, err := s.deps.DiscoverEmbedder.Embed(ctx, model.EmbeddingRequest{
		Model: s.deps.DiscoverEmbeddingModel,
		Input: []string{query},
		Metadata: map[string]any{
			"usageScene": "a2a_discover_vector_recall",
		},
	})
	if err != nil || resp == nil || len(resp.Embeddings) != 1 || len(resp.Embeddings[0]) != s.deps.DiscoverEmbeddingDims {
		return nextOffset, false, false
	}
	fetchLimit := limit * 4
	if fetchLimit < limit {
		fetchLimit = limit
	}
	if fetchLimit <= 0 {
		fetchLimit = discoverDefaultLimit * 4
	}
	for batch := 0; batch < discoverMaxBatches && len(out.Agents) < limit; batch++ {
		rows, scores, err := s.deps.DiscoverSemantic.ListSemanticCandidates(
			ctx, in.TenantID, fromAgent.ID, resp.Embeddings[0], s.deps.DiscoverEmbeddingModel, s.deps.DiscoverEmbeddingDims, fetchLimit, nextOffset)
		if err != nil {
			return nextOffset, false, false
		}
		used = true
		batchExhausted := len(rows) < fetchLimit
		for i, cand := range rows {
			nextOffset++
			if cand == nil || seenIDs[cand.ID] {
				continue
			}
			if !discoverCandidateAllowed(fromAgent, cand, in.Tags, in.Mode) {
				continue
			}
			entry := buildDiscoverEntry(cand, query)
			if score, ok := scores[cand.UUID]; ok {
				score = clampDiscoverScore(score)
				entry.MatchScore = &score
			}
			out.Agents = append(out.Agents, entry)
			seenIDs[cand.ID] = true
			if len(out.Agents) >= limit {
				return nextOffset, batchExhausted && i == len(rows)-1, true
			}
		}
		if batchExhausted {
			return nextOffset, true, true
		}
	}
	return nextOffset, exhausted, used
}

func (r *EmbeddingDiscoverRanker) RankDiscover(ctx context.Context, query string, entries []DiscoverEntry) (map[string]float64, error) {
	if r == nil || r.embedder == nil {
		return nil, errors.New("discover embedding provider not configured")
	}
	query = strings.TrimSpace(query)
	if query == "" || len(entries) == 0 {
		return nil, nil
	}
	maxCandidates := r.maxCandidates
	if maxCandidates <= 0 || maxCandidates > defaultDiscoverRankMaxCandidates {
		maxCandidates = defaultDiscoverRankMaxCandidates
	}
	if len(entries) > maxCandidates {
		entries = entries[:maxCandidates]
	}
	timeout := r.timeout
	if timeout <= 0 {
		timeout = defaultDiscoverRankTimeout
	}
	rankCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	inputs := make([]string, 0, len(entries)+1)
	inputs = append(inputs, query)
	for _, e := range entries {
		inputs = append(inputs, discoverEmbeddingText(e))
	}
	resp, err := r.embedder.Embed(rankCtx, model.EmbeddingRequest{
		Input: inputs,
		Metadata: map[string]any{
			"usageScene": "a2a_discover_embedding_rank",
		},
	})
	if err != nil {
		return nil, err
	}
	if resp == nil || len(resp.Embeddings) != len(inputs) {
		return nil, errors.New("discover embedding response size mismatch")
	}
	queryVec := resp.Embeddings[0]
	out := map[string]float64{}
	for i, e := range entries {
		score, ok := cosineDiscoverScore(queryVec, resp.Embeddings[i+1])
		if !ok {
			continue
		}
		out[e.AgentUUID] = score
	}
	if len(out) == 0 {
		return nil, errors.New("discover embedding response contains no usable scores")
	}
	return out, nil
}

// LLMDiscoverRanker 用平台 LLM 在已授权候选内做语义重排。它不查询 DB、不扩大候选集;
// LLM 故障由调用方降级到确定性排序。
type LLMDiscoverRanker struct {
	provider      model.Provider
	timeout       time.Duration
	maxCandidates int
}

func NewLLMDiscoverRanker(provider model.Provider) *LLMDiscoverRanker {
	return &LLMDiscoverRanker{
		provider:      provider,
		timeout:       defaultDiscoverRankTimeout,
		maxCandidates: defaultDiscoverRankMaxCandidates,
	}
}

func discoverEmbeddingText(e DiscoverEntry) string {
	examples := make([]domagent.A2ACardExample, 0, len(e.Examples))
	for _, ex := range e.Examples {
		examples = append(examples, domagent.A2ACardExample{
			Input:  ex.Input,
			Expect: ex.Expect,
		})
	}
	return domagent.A2ACardEmbeddingText(e.Name, e.Tags, domagent.A2ACard{
		Summary:   e.Summary,
		WhenToUse: e.WhenToUse,
		Examples:  examples,
	})
}

func cosineDiscoverScore(a, b []float64) (float64, bool) {
	if len(a) == 0 || len(a) != len(b) {
		return 0, false
	}
	var dot, aa, bb float64
	for i := range a {
		dot += a[i] * b[i]
		aa += a[i] * a[i]
		bb += b[i] * b[i]
	}
	if aa == 0 || bb == 0 {
		return 0, false
	}
	cos := dot / (math.Sqrt(aa) * math.Sqrt(bb))
	if math.IsNaN(cos) || math.IsInf(cos, 0) {
		return 0, false
	}
	return clampDiscoverScore((cos + 1) / 2), true
}

func (r *LLMDiscoverRanker) RankDiscover(ctx context.Context, query string, entries []DiscoverEntry) (map[string]float64, error) {
	if r == nil || r.provider == nil {
		return nil, errors.New("discover ranker provider not configured")
	}
	query = strings.TrimSpace(query)
	if query == "" || len(entries) == 0 {
		return nil, nil
	}
	maxCandidates := r.maxCandidates
	if maxCandidates <= 0 || maxCandidates > defaultDiscoverRankMaxCandidates {
		maxCandidates = defaultDiscoverRankMaxCandidates
	}
	if len(entries) > maxCandidates {
		entries = entries[:maxCandidates]
	}
	timeout := r.timeout
	if timeout <= 0 {
		timeout = defaultDiscoverRankTimeout
	}
	rankCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	stream, err := r.provider.StreamChat(rankCtx, model.ChatRequest{
		Messages: []model.ChatMessage{
			{Role: "system", Content: discoverRankSystemPrompt()},
			{Role: "user", Content: discoverRankUserPrompt(query, entries)},
		},
		Metadata: map[string]any{
			"usageScene": "a2a_discover_rank",
		},
	})
	if err != nil {
		return nil, err
	}
	defer stream.Close()

	var b strings.Builder
	for {
		ch, err := stream.Recv()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, err
		}
		if ch.Err != nil {
			return nil, ch.Err
		}
		b.WriteString(ch.Delta)
		if ch.Done {
			break
		}
	}
	return parseDiscoverRankScores(b.String(), entries)
}

func discoverRankSystemPrompt() string {
	return "你是知办AI的数字员工协作路由器。只根据给定候选判断相关性。必须只输出JSON,格式为{\"scores\":[{\"agent_id\":\"...\",\"score\":0.0}]}。score必须在0到1之间。不要新增候选。"
}

func discoverRankUserPrompt(query string, entries []DiscoverEntry) string {
	type candidate struct {
		AgentUUID      string   `json:"agent_id"`
		Name           string   `json:"name"`
		Summary        string   `json:"summary,omitempty"`
		WhenToUse      []string `json:"when_to_use,omitempty"`
		WhenNotToUse   []string `json:"when_not_to_use,omitempty"`
		Tags           []string `json:"tags,omitempty"`
		SupportedModes []string `json:"supported_modes,omitempty"`
		RiskLevel      string   `json:"risk_level,omitempty"`
	}
	candidates := make([]candidate, 0, len(entries))
	for _, e := range entries {
		candidates = append(candidates, candidate{
			AgentUUID:      e.AgentUUID,
			Name:           e.Name,
			Summary:        e.Summary,
			WhenToUse:      e.WhenToUse,
			WhenNotToUse:   e.WhenNotToUse,
			Tags:           e.Tags,
			SupportedModes: e.SupportedModes,
			RiskLevel:      e.RiskLevel,
		})
	}
	raw, _ := json.Marshal(candidates)
	return fmt.Sprintf("用户任务:%s\n候选:%s\n请为每个候选返回0到1的相关性分数。", query, string(raw))
}

func parseDiscoverRankScores(raw string, entries []DiscoverEntry) (map[string]float64, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("empty rank response")
	}
	raw = extractJSONObject(raw)
	known := map[string]bool{}
	for _, e := range entries {
		known[e.AgentUUID] = true
	}
	var resp struct {
		Scores []struct {
			AgentUUID string  `json:"agent_id"`
			Score     float64 `json:"score"`
		} `json:"scores"`
	}
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, err
	}
	out := map[string]float64{}
	for _, item := range resp.Scores {
		uuid := strings.TrimSpace(item.AgentUUID)
		if uuid == "" || !known[uuid] {
			continue
		}
		out[uuid] = clampDiscoverScore(item.Score)
	}
	if len(out) == 0 {
		return nil, errors.New("rank response contains no known candidates")
	}
	return out, nil
}

func extractJSONObject(raw string) string {
	start := strings.Index(raw, "{")
	end := strings.LastIndex(raw, "}")
	if start >= 0 && end >= start {
		return raw[start : end+1]
	}
	return raw
}
