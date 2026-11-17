package external

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
)

type agentKnowledgeRetrieveReq struct {
	AgentID string `json:"agent_id"`
	Query   string `json:"query"`
}

type externalAgentKnowledgeItem struct {
	ReferenceID     string  `json:"reference_id"`
	KnowledgeBaseID string  `json:"knowledge_base_id"`
	KBName          string  `json:"kb_name,omitempty"`
	DocumentID      string  `json:"document_id,omitempty"`
	Score           float64 `json:"score,omitempty"`
	Content         string  `json:"content"`
}

type externalAgentKnowledgeResult struct {
	ToolName      string                       `json:"tool_name"`
	Query         string                       `json:"query"`
	Items         []externalAgentKnowledgeItem `json:"items"`
	Sources       []map[string]any             `json:"sources"`
	AuditRef      string                       `json:"audit_ref,omitempty"`
	ResultQuality string                       `json:"result_quality"`
	Metadata      map[string]any               `json:"metadata,omitempty"`
}

func (h *Handlers) agentKnowledgeRetrieve(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.SessionTokenTenantID(r.Context())
	runtimeID := middleware.SessionTokenRuntimeEnvironmentID(r.Context())
	if middleware.SessionTokenID(r.Context()) <= 0 || tenantID <= 0 || runtimeID <= 0 {
		encode.JSONError(w, apperr.ErrForbidden.Withf("runtime access token required"))
		return
	}
	var req agentKnowledgeRetrieveReq
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			err = io.ErrUnexpectedEOF
		}
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if strings.TrimSpace(req.Query) == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("query required"))
		return
	}
	agentID, err := h.AgentSDK.ResolveRuntimeAccessAgent(r.Context(), req.AgentID, tenantID, runtimeID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if boundAgentID := middleware.SessionTokenAgentID(r.Context()); boundAgentID > 0 && boundAgentID != agentID {
		encode.JSONError(w, apperr.ErrForbidden.Withf("agent not allowed"))
		return
	}
	out, err := h.AgentKnowledge.SearchKnowledgeTool(r.Context(), svcchat.ToolSearchInput{
		TenantID:                 tenantID,
		AgentID:                  agentID,
		AccountID:                middleware.SessionTokenAccountID(r.Context()),
		Query:                    req.Query,
		AgentBindingPrevalidated: true,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]externalAgentKnowledgeItem, 0, len(out.Items))
	for _, item := range out.Items {
		items = append(items, externalAgentKnowledgeItem{
			ReferenceID:     item.ReferenceID,
			KnowledgeBaseID: item.KBUUID,
			KBName:          item.KBName,
			DocumentID:      item.DocumentUUID,
			Score:           item.Score,
			Content:         item.Content,
		})
	}
	sources := make([]map[string]any, 0, len(out.Sources))
	for _, source := range out.Sources {
		copySource := make(map[string]any, len(source)+2)
		for key, value := range source {
			copySource[key] = value
		}
		if value, ok := copySource["kb_uuid"]; ok {
			copySource["knowledge_base_id"] = value
		}
		if value, ok := copySource["document_uuid"]; ok {
			copySource["document_id"] = value
		}
		sources = append(sources, copySource)
	}
	encode.JSON(w, externalAgentKnowledgeResult{
		ToolName:      out.ToolName,
		Query:         out.Query,
		Items:         items,
		Sources:       sources,
		AuditRef:      out.AuditRef,
		ResultQuality: out.ResultQuality,
		Metadata:      out.Metadata,
	})
}
