package admincore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientbuild"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (h *Handlers) listClientBuildJobs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	items, total, err := h.ClientBuild.List(r.Context(), dom.Filter{Platform: q.Get("platform"), Status: q.Get("status"), Limit: limit, Offset: offset})
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}
func (h *Handlers) getClientBuildJob(w http.ResponseWriter, r *http.Request) {
	item, err := h.ClientBuild.Get(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}
func (h *Handlers) createClientBuildJob(w http.ResponseWriter, r *http.Request) {
	var in dom.Input
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.ClientBuild.Create(r.Context(), in, middleware.MustAccountID(r.Context()))
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSONStatus(w, http.StatusAccepted, map[string]any{"item": item})
}
func (h *Handlers) retryClientBuildJob(w http.ResponseWriter, r *http.Request) {
	item, err := h.ClientBuild.Retry(r.Context(), r.PathValue("uuid"), middleware.MustAccountID(r.Context()))
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSONStatus(w, http.StatusAccepted, map[string]any{"item": item})
}
func (h *Handlers) stopClientBuildJob(w http.ResponseWriter, r *http.Request) {
	item, err := h.ClientBuild.Stop(r.Context(), r.PathValue("uuid"), middleware.MustAccountID(r.Context()))
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}
func (h *Handlers) listClientBuildJobLogs(w http.ResponseWriter, r *http.Request) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after_seq"), 10, 64)
	logs, err := h.ClientBuild.Logs(r.Context(), r.PathValue("uuid"), after)
	if err != nil {
		encode.JSONError(w, mapClientBuildError(err))
		return
	}
	encode.JSON(w, map[string]any{"items": logs})
}
func mapClientBuildError(err error) error {
	switch {
	case errors.Is(err, dom.ErrInvalidInput):
		return apperr.ErrInvalidParams.Withf("client_build.invalid_input")
	case errors.Is(err, dom.ErrRunnerMissing):
		return apperr.ErrUpstreamUnavailable.Withf("client_build.runner_not_configured")
	case errors.Is(err, dom.ErrNotRetryable):
		return apperr.ErrConflict.Withf("client_build.not_retryable")
	case errors.Is(err, dom.ErrNotStoppable):
		return apperr.ErrConflict.Withf("client_build.not_stoppable")
	default:
		return err
	}
}
