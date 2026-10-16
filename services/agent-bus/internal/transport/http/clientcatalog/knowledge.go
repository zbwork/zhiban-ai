package clientcatalog

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communitycatalog"
	"net/http"
)

type KnowledgeHandler struct{ Service *communitycatalog.Knowledge }

func (h *KnowledgeHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.Service.List(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
