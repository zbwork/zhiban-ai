package clientchat

import (
	"context"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
)

type HistoryPager interface {
	MessagesAround(context.Context, int64, int64, string, string, int, int) ([]map[string]any, error)
	MessagesNewer(context.Context, int64, int64, string, string, int) ([]map[string]any, error)
}
type PageHandlers struct{ Messages HistoryPager }

func pageInt(value string, fallback int) int {
	n, e := strconv.Atoi(value)
	if e != nil {
		return fallback
	}
	return n
}
func (h *PageHandlers) Around(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	anchor := q.Get("anchor_message_uuid")
	if anchor == "" {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	items, err := h.Messages.MessagesAround(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"), anchor, pageInt(q.Get("before"), 25), pageInt(q.Get("after"), 25))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
func (h *PageHandlers) Newer(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	items, err := h.Messages.MessagesNewer(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"), q.Get("since_message_uuid"), pageInt(q.Get("limit"), 50))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
