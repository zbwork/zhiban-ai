package chat

import (
	"context"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

const ToolNameKBSearch = "zhiban.kb.search"

type ToolSearchInput struct {
	TenantID          int64
	AgentID           int64
	AccountID         int64
	ConversationID    int64
	Query             string
	TopK              int
	ContinuationToken string
	// AgentBindingPrevalidated is set only by trusted transports after deriving
	// AgentID from an authenticated session token or validated runtime context.
	// It allows stateless External API retrieval without a conversation row.
	AgentBindingPrevalidated bool
	// AnchorOnly means the caller is an A2A delegated task. RAG may use the
	// conversation only as an authorization/audit anchor and must not load or
	// inject the origin chat transcript.
	AnchorOnly bool
}

type ToolSearchResult struct {
	ToolName      string           `json:"tool_name"`
	Query         string           `json:"query"`
	Items         []ToolSearchItem `json:"items"`
	Sources       []map[string]any `json:"sources"`
	AuditRef      string           `json:"audit_ref,omitempty"`
	ResultQuality string           `json:"result_quality"`
	Metadata      map[string]any   `json:"metadata,omitempty"`
}

type ToolSearchItem struct {
	ReferenceID  string  `json:"reference_id"`
	KBUUID       string  `json:"kb_uuid"`
	KBName       string  `json:"kb_name,omitempty"`
	DocumentUUID string  `json:"document_uuid,omitempty"`
	Score        float64 `json:"score,omitempty"`
	Content      string  `json:"content"`
}

type ToolSearchService interface {
	SearchKnowledgeTool(ctx context.Context, in ToolSearchInput) (*ToolSearchResult, error)
}

type ToolSearchDeps struct {
	Logger *logpkg.Logger
	Agents interface {
		GetByID(ctx context.Context, id int64) (*domagent.DigitalEmployee, error)
	}
	Conversations interface {
		GetByID(ctx context.Context, id int64) (*domconv.Conversation, error)
	}
	RAG ChatRAGRetriever
}

type toolSearchService struct {
	logger *logpkg.Logger
	agents interface {
		GetByID(ctx context.Context, id int64) (*domagent.DigitalEmployee, error)
	}
	convs interface {
		GetByID(ctx context.Context, id int64) (*domconv.Conversation, error)
	}
	rag ChatRAGRetriever
}

func NewToolSearchService(d ToolSearchDeps) ToolSearchService {
	return &toolSearchService{
		logger: d.Logger,
		agents: d.Agents,
		convs:  d.Conversations,
		rag:    d.RAG,
	}
}

func (s *toolSearchService) SearchKnowledgeTool(ctx context.Context, in ToolSearchInput) (*ToolSearchResult, error) {
	query := strings.TrimSpace(in.Query)
	if query == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	if in.TenantID <= 0 || in.AgentID <= 0 || (in.ConversationID <= 0 && !in.AgentBindingPrevalidated) {
		return nil, apperr.ErrForbidden.Withf("tool delegate context incomplete")
	}
	if s.rag == nil || s.agents == nil || (in.ConversationID > 0 && s.convs == nil) {
		return nil, apperr.ErrInternal.Withf("tool search service not wired")
	}

	var conv *domconv.Conversation
	accountID := in.AccountID
	if in.ConversationID > 0 {
		var err error
		conv, err = s.convs.GetByID(ctx, in.ConversationID)
		if err != nil {
			return nil, err
		}
		if conv.TenantID != in.TenantID {
			return nil, apperr.ErrForbidden.Withf("tool delegate tenant mismatch")
		}
		if conv.AccountID <= 0 {
			return nil, apperr.ErrForbidden.Withf("tool delegate account missing")
		}
		accountID = conv.AccountID
		if (conv.DigitalEmployeeID == nil || *conv.DigitalEmployeeID != in.AgentID) && !in.AgentBindingPrevalidated {
			return nil, apperr.ErrForbidden.Withf("tool delegate agent mismatch")
		}
	} else if !in.AgentBindingPrevalidated {
		return nil, apperr.ErrForbidden.Withf("tool delegate conversation missing")
	}

	ag, err := s.agents.GetByID(ctx, in.AgentID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != in.TenantID && ag.Source != "platform" {
		return nil, apperr.ErrForbidden.Withf("tool delegate agent tenant mismatch")
	}

	kc, err := s.rag.RetrieveForChat(ctx, ChatRAGRequest{
		TenantID:         in.TenantID,
		AccountID:        accountID,
		Agent:            ag,
		Conversation:     conv,
		QueryOriginal:    query,
		QueryRewritten:   query,
		InvocationSource: "tool:" + ToolNameKBSearch,
		AnchorOnly:       in.AnchorOnly,
	})
	if err != nil {
		return nil, err
	}
	out := &ToolSearchResult{
		ToolName:      ToolNameKBSearch,
		Query:         query,
		Items:         []ToolSearchItem{},
		Sources:       []map[string]any{},
		ResultQuality: "empty",
	}
	if kc == nil || len(kc.Items) == 0 {
		return out, nil
	}
	out.Query = firstNonEmpty(kc.QueryRewritten, kc.QueryOriginal, query)
	out.Items = make([]ToolSearchItem, 0, len(kc.Items))
	out.Sources = make([]map[string]any, 0, len(kc.Items))
	for _, item := range kc.Items {
		content := strings.TrimSpace(item.Content)
		if content == "" {
			continue
		}
		out.Items = append(out.Items, ToolSearchItem{
			ReferenceID:  item.ReferenceID,
			KBUUID:       item.KBUUID,
			KBName:       item.KBName,
			DocumentUUID: item.DocumentUUID,
			Score:        item.Score,
			Content:      content,
		})
		out.Sources = append(out.Sources, map[string]any{
			"reference_id":  item.ReferenceID,
			"kb_uuid":       item.KBUUID,
			"kb_name":       item.KBName,
			"document_uuid": item.DocumentUUID,
			"score":         item.Score,
		})
	}
	if len(out.Items) > 0 {
		out.ResultQuality = "hit"
		out.Metadata = knowledgeContextMetadata(kc)
	}
	return out, nil
}
