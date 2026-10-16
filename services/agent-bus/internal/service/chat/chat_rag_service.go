package chat

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

var ErrChatRAGCacheMiss = errors.New("chat rag cache miss")

type ChatRAGConfig struct {
	Enabled          bool
	TotalTimeout     time.Duration
	CacheTTL         time.Duration
	NegativeCacheTTL time.Duration
	MaxKBFanout      int
	MaxConcurrency   int
}

type ChatRAGKBBinding struct {
	ID               int64
	UUID             string
	Name             string
	SpaceKind        string
	KBUpdatedAt      time.Time
	BindingUpdatedAt time.Time
}

type ChatRAGKBBindingLister interface {
	ListChatRAGKBBindings(ctx context.Context, agentID int64) ([]ChatRAGKBBinding, error)
}

type ChatRAGKnowledgeRetriever interface {
	RetrieveAuthorizedForChat(ctx context.Context, in svckb.ChatRetrieveInput) (*svckb.SearchResp, error)
}

type ChatRAGBatchKnowledgeRetriever interface {
	RetrieveAuthorizedBatchForChat(ctx context.Context, in svckb.ChatRetrieveBatchInput) ([]*svckb.SearchResp, error)
}

type ChatRAGCache interface {
	GetBytes(ctx context.Context, key string) ([]byte, error)
	SetBytes(ctx context.Context, key string, value []byte, ttl time.Duration) error
}

type ChatRAGRecallRecord struct {
	TenantID         int64
	AccountID        int64
	AgentID          int64
	KBID             int64
	KBUUID           string
	ConversationUUID string
	Query            string
	TopK             int
	Threshold        float64
	ChunkHits        int
	ScoreTop         float64
	LatencyMs        int
	ErrorCode        string
	OrchestrationID  string
	InvocationSource string
}

type ChatRAGRecallRecorder interface {
	RecordChatRAGRecall(ctx context.Context, rec ChatRAGRecallRecord) error
}

type chatRAGService struct {
	logger    *logpkg.Logger
	kbs       ChatRAGKBBindingLister
	knowledge ChatRAGKnowledgeRetriever
	cache     ChatRAGCache
	recorder  ChatRAGRecallRecorder
	cfg       ChatRAGConfig
}

func NewChatRAGRetriever(logger *logpkg.Logger, kbs ChatRAGKBBindingLister, knowledge ChatRAGKnowledgeRetriever, cache ChatRAGCache, recorder ChatRAGRecallRecorder, cfg ChatRAGConfig) ChatRAGRetriever {
	return chatRAGService{
		logger:    logger,
		kbs:       kbs,
		knowledge: knowledge,
		cache:     cache,
		recorder:  recorder,
		cfg:       cfg,
	}
}

func (s chatRAGService) RetrieveForChat(ctx context.Context, in ChatRAGRequest) (*KnowledgeContext, error) {
	totalStart := time.Now()
	if !s.cfg.Enabled || s.kbs == nil || s.knowledge == nil || in.Agent == nil {
		return nil, nil
	}
	query := strings.TrimSpace(in.QueryRewritten)
	if query == "" {
		query = strings.TrimSpace(in.QueryOriginal)
	}
	if query == "" {
		return nil, nil
	}
	if skip, reason := ShouldSkipChatRAG(query); skip {
		if s.logger != nil {
			s.logger.Info(ctx, "chat rag skipped by router",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID, "source", in.InvocationSource, "reason", reason)
		}
		return nil, nil
	}
	if s.cfg.TotalTimeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, s.cfg.TotalTimeout)
		defer cancel()
	}
	listStart := time.Now()
	bindings, err := s.kbs.ListChatRAGKBBindings(ctx, in.Agent.ID)
	listLatencyMs := int(time.Since(listStart).Milliseconds())
	if err != nil {
		return nil, err
	}
	if len(bindings) == 0 {
		if s.logger != nil {
			s.logger.Info(ctx, "chat rag no kb bindings",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID)
		}
		return nil, nil
	}
	originalBindingCount := len(bindings)
	bindings = s.selectKBBindings(query, bindings)
	cacheKey := s.cacheKey(in, query, bindings)
	if cacheKey != "" {
		if kc, hit, negative := s.getCached(ctx, cacheKey); hit {
			if s.logger != nil {
				s.logger.Info(ctx, "chat rag cache hit",
					"tenant_id", in.TenantID, "account_id", in.AccountID,
					"agent_uuid", in.Agent.UUID, "negative", negative)
			}
			if negative {
				return nil, nil
			}
			return kc, nil
		}
	}
	const (
		topKPerKB = 3
		maxItems  = 6
	)
	orchestrationID := firstNonEmpty(in.MessageUUID, safeConversationUUID(in.Conversation))
	searchStart := time.Now()
	results := s.retrieveBoundKBs(ctx, in, query, bindings, topKPerKB, orchestrationID)
	searchLatencyMs := int(time.Since(searchStart).Milliseconds())
	out := s.fuseKnowledgeContext(in, query, results, maxItems)
	hadRetrieveError := false
	for _, result := range results {
		if result.err != nil {
			hadRetrieveError = true
			break
		}
	}
	if len(out.Items) == 0 {
		if s.logger != nil {
			s.logger.Info(ctx, "chat rag all kb searches empty",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID,
				"binding_count", len(bindings),
				"binding_total_count", originalBindingCount,
				"binding_list_latency_ms", listLatencyMs,
				"provider_fanout_latency_ms", searchLatencyMs,
				"total_latency_ms", int(time.Since(totalStart).Milliseconds()))
		}
		if !hadRetrieveError {
			emptyKC := finalizeKnowledgeContext(&KnowledgeContext{
				QueryOriginal:  in.QueryOriginal,
				QueryRewritten: query,
			})
			s.setCached(ctx, cacheKey, emptyKC, true)
		}
		return finalizeKnowledgeContext(&KnowledgeContext{
			QueryOriginal:  in.QueryOriginal,
			QueryRewritten: query,
		}), nil
	}
	if !hadRetrieveError {
		s.setCached(ctx, cacheKey, out, false)
	}
	if s.logger != nil {
		s.logger.Info(ctx, "chat rag knowledge context prepared",
			"tenant_id", in.TenantID, "account_id", in.AccountID,
			"agent_uuid", in.Agent.UUID,
			"binding_count", len(bindings),
			"binding_total_count", originalBindingCount,
			"chunk_count", len(out.Items),
			"binding_list_latency_ms", listLatencyMs,
			"provider_fanout_latency_ms", searchLatencyMs,
			"total_latency_ms", int(time.Since(totalStart).Milliseconds()))
	}
	return finalizeKnowledgeContext(out), nil
}

type chatRAGKBResult struct {
	kb        ChatRAGKBBinding
	chunks    []svckb.ChunkDTO
	err       error
	latencyMs int
	cacheHit  bool
}

func (s chatRAGService) retrieveBoundKBs(ctx context.Context, in ChatRAGRequest, query string, bindings []ChatRAGKBBinding, topK int, orchestrationID string) []chatRAGKBResult {
	if len(bindings) == 0 {
		return nil
	}
	// Platform KBs use an isolated provider principal. They must not share the
	// tenant batch credential path, and a sequential mixed-scope fallback can
	// let slow tenant KBs consume the entire total deadline before the platform
	// KB is attempted. Fan out mixed/platform scopes concurrently instead.
	if batcher, ok := s.knowledge.(ChatRAGBatchKnowledgeRetriever); ok && len(bindings) > 1 && !hasPlatformKBBinding(bindings) {
		if results, ok := s.retrieveBoundKBsBatch(ctx, batcher, in, query, bindings, topK, orchestrationID); ok {
			return results
		}
	}
	return s.retrieveBoundKBsConcurrently(ctx, in, query, bindings, topK, orchestrationID)
}

func hasPlatformKBBinding(bindings []ChatRAGKBBinding) bool {
	for _, kb := range bindings {
		if strings.EqualFold(strings.TrimSpace(kb.SpaceKind), "platform") {
			return true
		}
	}
	return false
}

func (s chatRAGService) retrieveBoundKBsConcurrently(ctx context.Context, in ChatRAGRequest, query string, bindings []ChatRAGKBBinding, topK int, orchestrationID string) []chatRAGKBResult {
	if len(bindings) == 0 {
		return nil
	}
	concurrency := s.cfg.MaxConcurrency
	if concurrency <= 0 {
		concurrency = 4
	}
	if concurrency > len(bindings) {
		concurrency = len(bindings)
	}
	sem := make(chan struct{}, concurrency)
	results := make([]chatRAGKBResult, len(bindings))
	var wg sync.WaitGroup
	for i, kb := range bindings {
		wg.Add(1)
		go func(i int, kb ChatRAGKBBinding) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				results[i] = chatRAGKBResult{kb: kb, err: ctx.Err()}
				return
			}
			results[i] = s.retrieveOneKB(ctx, in, query, kb, topK, orchestrationID)
		}(i, kb)
	}
	wg.Wait()
	return results
}

func (s chatRAGService) retrieveBoundKBsBatch(ctx context.Context, batcher ChatRAGBatchKnowledgeRetriever, in ChatRAGRequest, query string, bindings []ChatRAGKBBinding, topK int, orchestrationID string) ([]chatRAGKBResult, bool) {
	results := make([]chatRAGKBResult, len(bindings))
	missBindings := make([]ChatRAGKBBinding, 0, len(bindings))
	missIndexes := make(map[string]int, len(bindings))
	for i, kb := range bindings {
		cacheKey := s.kbCacheKey(in, query, kb, topK)
		start := time.Now()
		if cacheKey != "" {
			if chunks, hit := s.getCachedKBChunks(ctx, cacheKey); hit {
				latencyMs := int(time.Since(start).Milliseconds())
				topScore := topChunkScore(chunks)
				s.recordRecall(ctx, in, kb, query, topK, len(chunks), topScore, latencyMs, "", orchestrationID)
				if s.logger != nil {
					s.logger.Info(ctx, "chat rag kb cache hit",
						"tenant_id", in.TenantID, "account_id", in.AccountID,
						"agent_uuid", in.Agent.UUID, "kb_uuid", kb.UUID,
						"chunk_count", len(chunks), "latency_ms", latencyMs)
				}
				results[i] = chatRAGKBResult{kb: kb, chunks: chunks, latencyMs: latencyMs, cacheHit: true}
				continue
			}
		}
		missIndexes[kb.UUID] = i
		missBindings = append(missBindings, kb)
	}
	if len(missBindings) == 0 {
		return results, true
	}
	if len(missBindings) == 1 {
		i := missIndexes[missBindings[0].UUID]
		results[i] = s.retrieveOneKB(ctx, in, query, missBindings[0], topK, orchestrationID)
		return results, true
	}

	kbUUIDs := make([]string, 0, len(missBindings))
	for _, kb := range missBindings {
		kbUUIDs = append(kbUUIDs, kb.UUID)
	}
	start := time.Now()
	resps, err := batcher.RetrieveAuthorizedBatchForChat(ctx, svckb.ChatRetrieveBatchInput{
		TenantID: in.TenantID, AccountID: in.AccountID, AgentID: in.Agent.ID,
		KBUUIDs: kbUUIDs, Query: query, TopK: topK,
	})
	latencyMs := int(time.Since(start).Milliseconds())
	if err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag batch search failed; fallback to single kb retrieve",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID, "kb_count", len(missBindings),
				"latency_ms", latencyMs, "err", err.Error())
		}
		fallback := s.retrieveBoundKBsConcurrently(ctx, in, query, missBindings, topK, orchestrationID)
		for j, result := range fallback {
			if j >= len(missBindings) {
				break
			}
			i := missIndexes[missBindings[j].UUID]
			results[i] = result
		}
		return results, true
	}
	respByKB := make(map[string]*svckb.SearchResp, len(resps))
	for _, resp := range resps {
		if resp != nil {
			respByKB[resp.KBUUID] = resp
		}
	}
	for _, kb := range missBindings {
		i := missIndexes[kb.UUID]
		resp := respByKB[kb.UUID]
		chunks := []svckb.ChunkDTO(nil)
		if resp != nil {
			chunks = resp.Chunks
		}
		topScore := topChunkScore(chunks)
		s.recordRecall(ctx, in, kb, query, topK, len(chunks), topScore, latencyMs, "", orchestrationID)
		if s.logger != nil {
			s.logger.Info(ctx, "chat rag kb batch search completed",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID, "kb_uuid", kb.UUID,
				"chunk_count", len(chunks), "top_score", topScore, "latency_ms", latencyMs)
		}
		s.setCachedKBChunks(ctx, s.kbCacheKey(in, query, kb, topK), chunks)
		results[i] = chatRAGKBResult{kb: kb, chunks: chunks, latencyMs: latencyMs}
	}
	return results, true
}

func (s chatRAGService) retrieveOneKB(ctx context.Context, in ChatRAGRequest, query string, kb ChatRAGKBBinding, topK int, orchestrationID string) chatRAGKBResult {
	cacheKey := s.kbCacheKey(in, query, kb, topK)
	start := time.Now()
	if cacheKey != "" {
		if chunks, hit := s.getCachedKBChunks(ctx, cacheKey); hit {
			latencyMs := int(time.Since(start).Milliseconds())
			topScore := topChunkScore(chunks)
			s.recordRecall(ctx, in, kb, query, topK, len(chunks), topScore, latencyMs, "", orchestrationID)
			if s.logger != nil {
				s.logger.Info(ctx, "chat rag kb cache hit",
					"tenant_id", in.TenantID, "account_id", in.AccountID,
					"agent_uuid", in.Agent.UUID, "kb_uuid", kb.UUID,
					"chunk_count", len(chunks), "latency_ms", latencyMs)
			}
			return chatRAGKBResult{kb: kb, chunks: chunks, latencyMs: latencyMs, cacheHit: true}
		}
	}
	resp, searchErr := s.knowledge.RetrieveAuthorizedForChat(ctx, svckb.ChatRetrieveInput{
		TenantID:  in.TenantID,
		AccountID: in.AccountID,
		AgentID:   in.Agent.ID,
		KBUUID:    kb.UUID,
		Query:     query,
		TopK:      topK,
	})
	latencyMs := int(time.Since(start).Milliseconds())
	if searchErr != nil {
		errCode := "chat_rag_retrieve_failed"
		if isContextDeadlineError(searchErr) {
			errCode = "chat_rag_retrieve_timeout"
		}
		s.recordRecall(ctx, in, kb, query, topK, 0, 0, latencyMs, errCode, orchestrationID)
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag kb search skipped",
				"tenant_id", in.TenantID, "account_id", in.AccountID,
				"agent_uuid", in.Agent.UUID, "kb_uuid", kb.UUID,
				"latency_ms", latencyMs, "err", searchErr.Error())
		}
		return chatRAGKBResult{kb: kb, err: searchErr, latencyMs: latencyMs}
	}
	chunks := []svckb.ChunkDTO(nil)
	if resp != nil {
		chunks = resp.Chunks
	}
	topScore := topChunkScore(chunks)
	s.recordRecall(ctx, in, kb, query, topK, len(chunks), topScore, latencyMs, "", orchestrationID)
	if s.logger != nil {
		s.logger.Info(ctx, "chat rag kb search completed",
			"tenant_id", in.TenantID, "account_id", in.AccountID,
			"agent_uuid", in.Agent.UUID, "kb_uuid", kb.UUID,
			"chunk_count", len(chunks), "top_score", topScore, "latency_ms", latencyMs)
	}
	s.setCachedKBChunks(ctx, cacheKey, chunks)
	return chatRAGKBResult{kb: kb, chunks: chunks, latencyMs: latencyMs}
}

func isContextDeadlineError(err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), context.DeadlineExceeded.Error())
}

func (s chatRAGService) fuseKnowledgeContext(in ChatRAGRequest, query string, results []chatRAGKBResult, maxItems int) *KnowledgeContext {
	out := &KnowledgeContext{
		QueryOriginal:  in.QueryOriginal,
		QueryRewritten: query,
		Items:          make([]KnowledgeContextItem, 0, maxItems),
	}
	type candidate struct {
		item          KnowledgeContextItem
		fusionRank    float64
		providerScore float64
		bindingOrder  int
	}
	candidates := make([]candidate, 0, maxItems)
	seen := map[string]bool{}
	queryTerms := chatRAGQueryTerms(query)
	const rrfK = 60.0
	for bindingOrder, result := range results {
		if result.err != nil {
			continue
		}
		for rank, ch := range result.chunks {
			content := strings.TrimSpace(ch.Content)
			if content == "" {
				continue
			}
			if !chatRAGChunkMatchesQuery(queryTerms, ch.DocumentTitle, content) {
				continue
			}
			docUUID := fmt.Sprintf("%d", ch.DocumentID)
			dedupeKey := fmt.Sprintf("%s|%s|%d|%x", result.kb.UUID, docUUID, ch.ChunkIndex, sha256.Sum256([]byte(content)))
			if seen[dedupeKey] {
				continue
			}
			seen[dedupeKey] = true
			candidates = append(candidates, candidate{
				item: KnowledgeContextItem{
					ReferenceID:   fmt.Sprintf("kb:%s:%d", result.kb.UUID, rank+1),
					KBUUID:        result.kb.UUID,
					KBName:        result.kb.Name,
					DocumentUUID:  docUUID,
					DocumentTitle: ch.DocumentTitle,
					Score:         ch.Score,
					Content:       trimRAGRunes(content, 1200),
				},
				fusionRank:    1 / (rrfK + float64(rank+1)),
				providerScore: ch.Score,
				bindingOrder:  bindingOrder,
			})
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].fusionRank != candidates[j].fusionRank {
			return candidates[i].fusionRank > candidates[j].fusionRank
		}
		if candidates[i].providerScore != candidates[j].providerScore {
			return candidates[i].providerScore > candidates[j].providerScore
		}
		return candidates[i].bindingOrder < candidates[j].bindingOrder
	})
	for _, c := range candidates {
		if len(out.Items) >= maxItems {
			break
		}
		out.Items = append(out.Items, c.item)
	}
	return out
}

func chatRAGChunkMatchesQuery(terms []string, title, content string) bool {
	if len(terms) == 0 {
		return true
	}
	haystack := strings.ToLower(title + "\n" + content)
	for _, term := range terms {
		if term != "" && strings.Contains(haystack, term) {
			return true
		}
	}
	return false
}

func chatRAGQueryTerms(query string) []string {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" {
		return nil
	}
	q = strings.NewReplacer(
		"介绍一下", " ",
		"帮我", " ",
		"请问", " ",
		"一下", " ",
		"多少", " ",
		"什么", " ",
		"哪些", " ",
		"如何", " ",
		"怎么", " ",
		"一个", " ",
		"一些", " ",
	).Replace(q)
	for _, r := range []rune{'的', '了', '吗', '呢', '啊', '呀', '？', '?', '。', '，', ',', '、', '：', ':', '；', ';', '！', '!', '(', ')', '（', '）', '[', ']', '【', '】', '"', '\'', '\n', '\r', '\t'} {
		q = strings.ReplaceAll(q, string(r), " ")
	}
	fields := strings.Fields(q)
	seen := map[string]bool{}
	terms := make([]string, 0, len(fields)*3)
	add := func(term string) {
		term = strings.TrimSpace(term)
		if len([]rune(term)) < 2 || seen[term] {
			return
		}
		seen[term] = true
		terms = append(terms, term)
	}
	for _, field := range fields {
		add(field)
		rs := []rune(field)
		if len(rs) <= 2 {
			continue
		}
		for n := 2; n <= 4 && n <= len(rs); n++ {
			for i := 0; i+n <= len(rs); i++ {
				add(string(rs[i : i+n]))
			}
		}
	}
	return terms
}

func (s chatRAGService) selectKBBindings(query string, bindings []ChatRAGKBBinding) []ChatRAGKBBinding {
	maxFanout := s.cfg.MaxKBFanout
	if maxFanout <= 0 {
		maxFanout = 8
	}
	if len(bindings) <= maxFanout {
		return bindings
	}
	type scored struct {
		binding ChatRAGKBBinding
		score   int
		order   int
	}
	terms := strings.Fields(strings.ToLower(strings.TrimSpace(query)))
	scoredBindings := make([]scored, 0, len(bindings))
	for i, kb := range bindings {
		score := 0
		name := strings.ToLower(kb.Name)
		for _, term := range terms {
			if term != "" && strings.Contains(name, term) {
				score++
			}
		}
		scoredBindings = append(scoredBindings, scored{binding: kb, score: score, order: i})
	}
	sort.SliceStable(scoredBindings, func(i, j int) bool {
		if scoredBindings[i].score != scoredBindings[j].score {
			return scoredBindings[i].score > scoredBindings[j].score
		}
		return scoredBindings[i].order < scoredBindings[j].order
	})
	out := make([]ChatRAGKBBinding, 0, maxFanout)
	for i := 0; i < len(scoredBindings) && i < maxFanout; i++ {
		out = append(out, scoredBindings[i].binding)
	}
	return out
}

func (s chatRAGService) recordRecall(ctx context.Context, in ChatRAGRequest, kb ChatRAGKBBinding, query string, topK, hits int, topScore float64, latencyMs int, errCode, orchestrationID string) {
	if s.recorder == nil || kb.ID <= 0 {
		return
	}
	writeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	if err := s.recorder.RecordChatRAGRecall(writeCtx, ChatRAGRecallRecord{
		TenantID:         in.TenantID,
		AccountID:        in.AccountID,
		AgentID:          in.Agent.ID,
		KBID:             kb.ID,
		KBUUID:           kb.UUID,
		ConversationUUID: safeConversationUUID(in.Conversation),
		Query:            query,
		TopK:             topK,
		ChunkHits:        hits,
		ScoreTop:         topScore,
		LatencyMs:        latencyMs,
		ErrorCode:        errCode,
		OrchestrationID:  orchestrationID,
		InvocationSource: in.InvocationSource,
	}); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "chat rag recall log failed",
			"tenant_id", in.TenantID, "account_id", in.AccountID,
			"agent_uuid", safeAgentUUID(in.Agent), "kb_uuid", kb.UUID, "err", err.Error())
	}
}

type chatRAGCacheEntry struct {
	Negative bool              `json:"negative"`
	Context  *KnowledgeContext `json:"context,omitempty"`
}

type chatRAGKBCacheEntry struct {
	Chunks []svckb.ChunkDTO `json:"chunks,omitempty"`
}

func (s chatRAGService) cacheKey(in ChatRAGRequest, query string, bindings []ChatRAGKBBinding) string {
	if s.cache == nil || s.cfg.CacheTTL <= 0 || len(bindings) == 0 {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "tenant=%d|account=%d|agent=%d|conversation=%d|room=%s|query=%s|topk=3|max=6|", in.TenantID, in.AccountID, in.Agent.ID, safeConvID(in.Conversation), in.RoomUUID, normalizeChatRAGCacheQuery(query))
	for _, kb := range bindings {
		fmt.Fprintf(&b, "kb=%s:%d:%d|", kb.UUID, kb.KBUpdatedAt.UnixNano(), kb.BindingUpdatedAt.UnixNano())
	}
	sum := sha256.Sum256([]byte(b.String()))
	return fmt.Sprintf("agbus:chat-rag:v1:%x", sum[:])
}

func (s chatRAGService) kbCacheKey(in ChatRAGRequest, query string, kb ChatRAGKBBinding, topK int) string {
	if s.cache == nil || s.cfg.CacheTTL <= 0 || in.TenantID <= 0 || in.AccountID <= 0 || strings.TrimSpace(kb.UUID) == "" {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "tenant=%d|account=%d|kb=%s|query=%s|topk=%d|kb_updated=%d|provider=v1|", in.TenantID, in.AccountID, kb.UUID, normalizeChatRAGCacheQuery(query), topK, kb.KBUpdatedAt.UnixNano())
	sum := sha256.Sum256([]byte(b.String()))
	return fmt.Sprintf("agbus:chat-rag:kb:v1:%x", sum[:])
}

func (s chatRAGService) getCached(ctx context.Context, key string) (*KnowledgeContext, bool, bool) {
	if key == "" || s.cache == nil {
		return nil, false, false
	}
	raw, err := s.cache.GetBytes(ctx, key)
	if errors.Is(err, ErrChatRAGCacheMiss) {
		return nil, false, false
	}
	if err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag cache get failed", "err", err.Error())
		}
		return nil, false, false
	}
	var entry chatRAGCacheEntry
	if err := json.Unmarshal(raw, &entry); err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag cache decode failed", "err", err.Error())
		}
		return nil, false, false
	}
	return entry.Context, true, entry.Negative
}

func (s chatRAGService) getCachedKBChunks(ctx context.Context, key string) ([]svckb.ChunkDTO, bool) {
	if key == "" || s.cache == nil {
		return nil, false
	}
	raw, err := s.cache.GetBytes(ctx, key)
	if errors.Is(err, ErrChatRAGCacheMiss) {
		return nil, false
	}
	if err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag kb cache get failed", "err", err.Error())
		}
		return nil, false
	}
	var entry chatRAGKBCacheEntry
	if err := json.Unmarshal(raw, &entry); err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "chat rag kb cache decode failed", "err", err.Error())
		}
		return nil, false
	}
	return entry.Chunks, true
}

func (s chatRAGService) setCached(ctx context.Context, key string, kc *KnowledgeContext, negative bool) {
	if key == "" || s.cache == nil {
		return
	}
	ttl := s.cfg.CacheTTL
	if negative {
		ttl = s.cfg.NegativeCacheTTL
	}
	if ttl <= 0 {
		return
	}
	raw, err := json.Marshal(chatRAGCacheEntry{Negative: negative, Context: kc})
	if err != nil {
		return
	}
	writeCtx, cancel := cacheWriteContext(ctx)
	defer cancel()
	if err := s.cache.SetBytes(writeCtx, key, raw, ttl); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "chat rag cache set failed", "err", err.Error())
	}
}

func (s chatRAGService) setCachedKBChunks(ctx context.Context, key string, chunks []svckb.ChunkDTO) {
	if key == "" || s.cache == nil || s.cfg.CacheTTL <= 0 {
		return
	}
	raw, err := json.Marshal(chatRAGKBCacheEntry{Chunks: chunks})
	if err != nil {
		return
	}
	writeCtx, cancel := cacheWriteContext(ctx)
	defer cancel()
	if err := s.cache.SetBytes(writeCtx, key, raw, s.cfg.CacheTTL); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "chat rag kb cache set failed", "err", err.Error())
	}
}

func cacheWriteContext(ctx context.Context) (context.Context, context.CancelFunc) {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
}

func topChunkScore(chunks []svckb.ChunkDTO) float64 {
	if len(chunks) == 0 {
		return 0
	}
	return chunks[0].Score
}

func safeConvID(conv *domconv.Conversation) int64 {
	if conv == nil {
		return 0
	}
	return conv.ID
}

func normalizeChatRAGCacheQuery(query string) string {
	return strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(query))), " ")
}

func trimRAGRunes(s string, limit int) string {
	if limit <= 0 {
		return ""
	}
	rs := []rune(s)
	if len(rs) <= limit {
		return s
	}
	return string(rs[:limit]) + "..."
}
