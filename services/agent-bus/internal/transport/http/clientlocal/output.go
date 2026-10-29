package clientlocal

import (
	"context"
	"encoding/json"
	"net/http"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// localOutput shares the run capability boundary with model calls; no client/admin upload privilege.
func (h *Handlers) localOutput(w http.ResponseWriter, r *http.Request) {
	task, _, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	if h.Outputs == nil {
		localError(w, dom.ErrOffline)
		return
	}
	var input svcdrive.LocalOutputReq
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), task.ExpiresAt)
	defer cancel()
	w.Header().Set("Cache-Control", "no-store")
	switch r.PathValue("operation") {
	case "sign":
		result, err := h.Outputs.SignLocalOutput(ctx, task, input)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, result)
	case "confirm":
		result, err := h.Outputs.ConfirmLocalOutput(ctx, task, input)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, result)
	default:
		encode.JSONError(w, apperr.ErrInvalidParams)
	}
}
