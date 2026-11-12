// Original admin read handlers; billing wallet enrichment is not wired here.
package admincore

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	"net/http"
	"strconv"
)

func (h *Handlers) platformStats(w http.ResponseWriter, r *http.Request) {
	s, err := h.Platform.PlatformStats(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, s)
}

// platformOverview F25 平台首页聚合。

func (h *Handlers) platformOverview(w http.ResponseWriter, r *http.Request) {
	s, err := h.Platform.PlatformOverview(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, s)
}

func (h *Handlers) tenantStats(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	s, err := h.Platform.TenantStats(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, s)
}

// tenantOverview 概览页单接口聚合 (F23)。

func (h *Handlers) tenantOverview(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	o, err := h.Platform.TenantOverview(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, o)
}

func (h *Handlers) recentConvos(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit == 0 {
		limit = 10
	}
	items, err := h.Platform.RecentConversations(r.Context(), tid, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}
