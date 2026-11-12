package admincore

import (
	"errors"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (h *Handlers) clientAnalyticsOverview(w http.ResponseWriter, r *http.Request) {
	days := 30
	if raw := r.URL.Query().Get("days"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("days must be 7, 30, or 90"))
			return
		}
		days = parsed
	}
	if days != 7 && days != 30 && days != 90 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("days must be 7, 30, or 90"))
		return
	}
	includeArchived := r.URL.Query().Get("status") == "all"
	if h.ClientAnalyticsOverview == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client analytics overview not wired"))
		return
	}
	out, err := h.ClientAnalyticsOverview.Overview(r.Context(), days, includeArchived)
	if err != nil {
		if errors.Is(err, dom.ErrInvalidRange) {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) clientAnalyticsErrorDetail(w http.ResponseWriter, r *http.Request) {
	fingerprint := r.PathValue("fingerprint")
	if h.ClientAnalyticsErrors == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client analytics error admin not wired"))
		return
	}
	out, err := h.ClientAnalyticsErrors.ErrorDetail(r.Context(), fingerprint)
	if err != nil {
		if errors.Is(err, dom.ErrFingerprintNotFound) {
			encode.JSONError(w, apperr.ErrNotFound.Wrap(err))
			return
		}
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) clientAnalyticsArchiveError(w http.ResponseWriter, r *http.Request) {
	fingerprint := r.PathValue("fingerprint")
	if h.ClientAnalyticsErrors == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client analytics error admin not wired"))
		return
	}
	if err := h.ClientAnalyticsErrors.ArchiveError(r.Context(), fingerprint, middleware.MustAccountID(r.Context())); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"archived": true})
}

func (h *Handlers) clientAnalyticsUnarchiveError(w http.ResponseWriter, r *http.Request) {
	fingerprint := r.PathValue("fingerprint")
	if h.ClientAnalyticsErrors == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("client analytics error admin not wired"))
		return
	}
	if err := h.ClientAnalyticsErrors.UnarchiveError(r.Context(), fingerprint); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"archived": false})
}
