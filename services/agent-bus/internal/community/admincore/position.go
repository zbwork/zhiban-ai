// F01 §1 tenant position CRUD + member assignment endpoints.
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcpos "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
)

func (h *Handlers) listPositions(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	list, total, err := h.Position.List(r.Context(), tid, r.URL.Query().Get("q"), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": total, "limit": limit, "offset": offset})
}

func (h *Handlers) getPosition(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	p, err := h.Position.Get(r.Context(), tid, id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

func (h *Handlers) createPosition(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	var body svcpos.CreateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	p, err := h.Position.Create(r.Context(), tid, actorID, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

func (h *Handlers) updatePosition(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcpos.UpdateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	p, err := h.Position.Update(r.Context(), tid, actorID, id, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

func (h *Handlers) deletePosition(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err := h.Position.Delete(r.Context(), tid, actorID, id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) listMemberPositions(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	mid, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	list, err := h.Position.ListMemberPositions(r.Context(), tid, mid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list})
}

func (h *Handlers) assignMemberPositions(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	mid, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcpos.AssignMemberInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.Position.AssignMember(r.Context(), tid, actorID, mid, body); err != nil {
		encode.JSONError(w, err)
		return
	}
	list, err := h.Position.ListMemberPositions(r.Context(), tid, mid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list})
}

func (h *Handlers) listAgentPositions(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	aid, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	list, err := h.Position.ListAgentPositions(r.Context(), tid, aid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list})
}

func (h *Handlers) assignAgentPositions(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	aid, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcpos.AssignAgentInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.Position.AssignAgent(r.Context(), tid, actorID, aid, body); err != nil {
		encode.JSONError(w, err)
		return
	}
	list, err := h.Position.ListAgentPositions(r.Context(), tid, aid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list})
}
