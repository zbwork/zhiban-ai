package clientlocal

import (
	"context"
	"net/http"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// No App JWT: the independently signed, short-lived upload header is the only
// authority, matching desktop fetch's existing credential-free PUT contract.
func (h *Handlers) localUpload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.Outputs == nil {
		encode.JSONError(w, apperr.ErrForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(2 * time.Minute))
	r.Body = http.MaxBytesReader(w, r.Body, svcdrive.LocalUploadMaxBytes+1)
	defer r.Body.Close()
	if err := h.Outputs.UploadLocalOutput(ctx, r.Header.Get(svcdrive.LocalUploadHeader), r.Header.Get("Content-Type"), r.ContentLength, r.Body); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
