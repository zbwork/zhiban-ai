package clientlocal

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	media "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svcmedia "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localmedia"
)

func imageError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code}})
}
func (h *Handlers) localImage(w http.ResponseWriter, r *http.Request) {
	task, token, err := h.localRun(r)
	if err != nil {
		imageError(w, 403, "local.lease_invalid")
		return
	}
	if h.Images == nil {
		imageError(w, 503, "local.image_unavailable")
		return
	}
	var in media.Request
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 20000))
	dec.DisallowUnknownFields()
	if dec.Decode(&in) != nil || dec.Decode(&struct{}{}) != io.EOF {
		imageError(w, 400, "local.image_invalid")
		return
	}
	deadline := time.Now().Add(svcmedia.Timeout)
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
	// Community has no platform credits; the member's own model platform bills the call.
	data, err := h.Images.Generate(ctx, task, in, func(context.Context) error { return nil })
	if err != nil {
		code := "local.media_reconcile_required"
		status := 409
		switch {
		case errors.Is(err, media.ErrCredits):
			code = "local.image_credit_unavailable"
			status = 403
		case errors.Is(err, media.ErrInvalid):
			code = "local.image_invalid"
			status = 400
		case errors.Is(err, media.ErrRejected):
			code = "local.image_rejected"
			status = 422
		case errors.Is(err, local.ErrDenied):
			code = "local.lease_invalid"
			status = 403
		case errors.Is(err, media.ErrConflict):
			code = "local.media_conflict"
		case errors.Is(err, media.ErrUnavailable):
			code = "local.image_unavailable"
			status = 503
		}
		logpkg.Default().Warn(ctx, "local_runtime.image_failed", "run", task.UUID, "code", code)
		imageError(w, status, code)
		return
	}
	if _, err = h.Local.AuthorizeRun(ctx, token, task.UUID, task.Fence); err != nil {
		imageError(w, 403, "local.lease_invalid")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	_, _ = w.Write(data)
}
