package clientlocal

import (
	"encoding/json"
	"errors"
	"net/http"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (h *Handlers) localDesktopStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.Local == nil {
		encode.JSON(w, map[string]any{"online": false, "available": false})
		return
	}
	device, err := h.Local.ResolveDesktop(r.Context(), localScope(r), "")
	if errors.Is(err, dom.ErrUpgradeRequired) {
		encode.JSON(w, map[string]any{"online": true, "available": false, "reason": "upgrade_required"})
		return
	}
	if errors.Is(err, dom.ErrOffline) {
		encode.JSON(w, map[string]any{"online": false, "available": false})
		return
	}
	if err != nil {
		localError(w, err)
		return
	}
	// No device credential, session UUID or filesystem path is exposed to the phone.
	encode.JSON(w, map[string]any{"online": true, "available": true, "platform": device.Platform, "seen_at": device.SeenAt})
}

func (h *Handlers) localConversationState(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	out, err := h.Local.ConversationState(r.Context(), localScope(r), r.PathValue("conversation"))
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, out)
}
func (h *Handlers) localApprovals(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	out, err := h.Local.ListApprovals(r.Context(), localScope(r), r.URL.Query().Get("conversation_id"))
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, map[string]any{"items": out})
}
func (h *Handlers) localDecideApproval(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	var input struct {
		Revision int    `json:"revision"`
		Hash     string `json:"intent_hash"`
		Approved *bool  `json:"approved"`
		Scope    string `json:"scope"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || input.Approved == nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	if input.Scope == "" {
		input.Scope = "once"
	}
	out, err := h.Local.DecideApproval(r.Context(), localScope(r), r.PathValue("id"), input.Revision, input.Hash, *input.Approved, input.Scope)
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, out)
}
func (h *Handlers) localRunApproval(w http.ResponseWriter, r *http.Request) {
	task, _, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	id := r.PathValue("id")
	if r.Method == http.MethodGet {
		out, err := h.Local.GetApproval(r.Context(), task, id)
		if err != nil {
			localError(w, err)
			return
		}
		encode.JSON(w, out)
		return
	}
	if r.Method == http.MethodDelete {
		if err := h.Local.ExpireApproval(r.Context(), task, id); err != nil {
			localError(w, err)
			return
		}
		encode.JSON(w, map[string]bool{"ok": true})
		return
	}
	var input dom.Approval
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	out, err := h.Local.RegisterApproval(r.Context(), task, input)
	if err != nil {
		localError(w, err)
		return
	}
	encode.JSON(w, out)
}
