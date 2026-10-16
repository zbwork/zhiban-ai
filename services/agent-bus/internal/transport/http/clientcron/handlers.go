package clientcron

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	svccron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	"net/http"
	"strconv"
)

type Handlers struct{ Cron svccron.Service }

func (h *Handlers) ListJobs(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Cron.ListJobs(r.Context(), accID, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) ListRuns(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	before := r.URL.Query().Get("before_uuid")
	items, err := h.Cron.ListRuns(r.Context(), accID, tid, before, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
