package clientlocal

import (
	"encoding/json"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (h *Handlers) localCollaborate(w http.ResponseWriter, r *http.Request) {
	task, _, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 20000)
	var in struct {
		Employee string `json:"employee"`
		Text     string `json:"text"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	id, err := h.Collaboration.Request(r.Context(), task, in.Employee, in.Text)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]string{"approval_id": id, "status": "awaiting_approval"})
}
