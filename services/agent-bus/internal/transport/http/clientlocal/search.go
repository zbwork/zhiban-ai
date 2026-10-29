package clientlocal

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/websearch"
	svcsearch "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/websearch"
)

func searchError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code}})
}

func (h *Handlers) localSearch(w http.ResponseWriter, r *http.Request) {
	task, token, err := h.localRun(r)
	if err != nil {
		searchError(w, 403, "local.lease_invalid")
		return
	}
	if h.Search == nil {
		searchError(w, 503, "local.web_search_unavailable")
		return
	}
	in := dom.Request{Limit: 5}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	dec.DisallowUnknownFields()
	if dec.Decode(&in) != nil || dec.Decode(&struct{}{}) != io.EOF {
		searchError(w, 400, "local.web_search_invalid")
		return
	}
	deadline := time.Now().Add(svcsearch.Timeout)
	if task.ExpiresAt.Before(deadline) {
		deadline = task.ExpiresAt
	}
	ctx, cancel := context.WithDeadline(r.Context(), deadline)
	defer cancel()
	go func() {
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				if _, err := h.Local.AuthorizeRun(ctx, token, task.UUID, task.Fence); err != nil {
					cancel()
					return
				}
			}
		}
	}()
	out, err := h.Search.Search(ctx, in)
	if err != nil {
		status, code := 503, "local.web_search_unavailable"
		switch {
		case errors.Is(err, context.Canceled):
			status, code = 403, "local.lease_invalid"
		case errors.Is(err, dom.ErrInvalid):
			status, code = 400, "local.web_search_invalid"
		case errors.Is(err, dom.ErrLimited):
			status, code = 429, "local.web_search_limited"
		case errors.Is(err, dom.ErrTimeout), errors.Is(err, context.DeadlineExceeded):
			status, code = 504, "local.web_search_timeout"
		}
		searchError(w, status, code)
		return
	}
	if _, err := h.Local.AuthorizeRun(ctx, token, task.UUID, task.Fence); err != nil {
		searchError(w, 403, "local.lease_invalid")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(out)
}
