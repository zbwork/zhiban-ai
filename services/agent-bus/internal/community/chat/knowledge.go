package chat

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	kb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	"time"
)

type bindings struct{ repo *repo.Repo }

func (b bindings) ListChatRAGKBBindings(ctx context.Context, agentID int64) ([]svc.ChatRAGKBBinding, error) {
	rows, err := b.repo.ListAgentKBBindings(ctx, agentID)
	if err != nil {
		return nil, err
	}
	out := make([]svc.ChatRAGKBBinding, 0, len(rows))
	for _, r := range rows {
		out = append(out, svc.ChatRAGKBBinding{ID: r.ID, UUID: r.UUID, Name: r.Name, SpaceKind: r.SpaceKind, KBUpdatedAt: r.KBUpdatedAt, BindingUpdatedAt: r.BindingUpdatedAt})
	}
	return out, nil
}
func WireKnowledge(chat svc.Service, pool *pgxpool.Pool, knowledge kb.Service) {
	svc.SetChatRAGRetrieverOnService(chat, svc.NewChatRAGRetriever(log.Default(), bindings{repo.New(pool)}, knowledge, nil, recallRecorder{repo.New(pool)}, svc.ChatRAGConfig{Enabled: true, TotalTimeout: 3 * time.Second, MaxKBFanout: 8, MaxConcurrency: 4}))
}

type recallRecorder struct{ repo *repo.Repo }

func (r recallRecorder) RecordChatRAGRecall(ctx context.Context, rec svc.ChatRAGRecallRecord) error {
	return r.repo.InsertRecallLog(ctx, dom.RecallLog{TenantID: &rec.TenantID, KBScopeKind: string(dom.ScopeTenant), AccountID: rec.AccountID, AgentID: rec.AgentID, KBID: rec.KBID, CallerKind: dom.CallerAgent, ConversationUUID: rec.ConversationUUID, QueryText: rec.Query, TopK: rec.TopK, Threshold: rec.Threshold, ChunkHits: rec.ChunkHits, ScoreTop: rec.ScoreTop, LatencyMs: rec.LatencyMs, ErrorCode: rec.ErrorCode, Metadata: map[string]any{"mode": "pre_retrieve", "orchestration_id": rec.OrchestrationID, "invocation_source": rec.InvocationSource, "kb_uuid": rec.KBUUID}})
}
