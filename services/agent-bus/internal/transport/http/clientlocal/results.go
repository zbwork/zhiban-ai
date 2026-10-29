package clientlocal

import (
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	"net/http"
	"strconv"
)

// App JWT and the current desktop generation authorize result recovery, never lrt_ execution tokens.
func (h *Handlers) localResults(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	scope := localScope(r)
	generation, e1 := strconv.ParseInt(r.Header.Get("X-Local-Generation"), 10, 64)
	fence, e2 := strconv.ParseInt(r.Header.Get("X-Local-Fence"), 10, 64)
	device := r.Header.Get("X-Local-Device")
	if e1 != nil || e2 != nil || generation < 1 || fence < 1 {
		localError(w, dom.ErrDenied)
		return
	}
	task, err := h.Local.ResultTask(r.Context(), scope, device, generation, r.PathValue("run"), fence)
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128*1024))
	decoder.DisallowUnknownFields()
	operation := r.PathValue("operation")
	if operation == "" {
		var input struct {
			Blocks []map[string]any `json:"blocks"`
		}
		if decoder.Decode(&input) != nil {
			localError(w, dom.ErrDenied)
			return
		}
		if err = h.Local.SaveResults(r.Context(), scope, device, generation, task.UUID, fence, input.Blocks); err != nil {
			localError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"saved": true, "can_archive": task.Status != "cancelled"})
		return
	}
	if h.Outputs == nil {
		localError(w, dom.ErrOffline)
		return
	}
	var input svcdrive.LocalOutputReq
	if decoder.Decode(&input) != nil || !svclocal.ResultMatches(task, input.ArtifactID, input.SHA256, input.FileName, input.MimeType, input.FileSize) {
		localError(w, dom.ErrDenied)
		return
	}
	switch operation {
	case "sign":
		result, err := h.Outputs.SignLocalOutput(r.Context(), task, input)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, result)
	case "confirm":
		result, err := h.Outputs.ConfirmLocalOutput(r.Context(), task, input)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, result)
	default:
		localError(w, dom.ErrDenied)
	}
}
