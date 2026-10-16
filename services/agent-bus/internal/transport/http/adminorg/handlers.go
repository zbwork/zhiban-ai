// Package adminorg provides shared organization handlers. Callers must apply tenant RBAC middleware.
package adminorg

import (
	"context"
	"encoding/json"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdept "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/department"
	svcmem "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	"net/http"
	"strconv"
)

type MembershipService interface {
	List(context.Context, int64, int64, string, int, int) ([]svcmem.Member, int64, error)
	Get(context.Context, int64, int64) (*svcmem.Member, error)
	Update(context.Context, int64, int64, int64, svcmem.UpdateInput) (*svcmem.Member, error)
	Remove(context.Context, int64, int64, int64) error
	UpdateContactFields(context.Context, int64, int64, svcmem.ContactFieldsInput) error
}
type Handlers struct {
	Department svcdept.Service
	Membership MembershipService
}

func (h *Handlers) GetDepartment(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	d, err := h.Department.Get(r.Context(), tid, id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, d)
}

func (h *Handlers) CreateDepartment(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	var body svcdept.CreateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	d, err := h.Department.Create(r.Context(), tid, actorID, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, d)
}

func (h *Handlers) UpdateDepartment(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcdept.UpdateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	d, err := h.Department.Update(r.Context(), tid, actorID, id, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, d)
}

func (h *Handlers) DeleteDepartment(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err := h.Department.Delete(r.Context(), tid, actorID, id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) ListDepartments(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	if h.Department == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("department service not wired"))
		return
	}
	items, err := h.Department.List(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

func (h *Handlers) GetMember(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	m, err := h.Membership.Get(r.Context(), tid, id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, m)
}

func (h *Handlers) UpdateMember(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcmem.UpdateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	m, err := h.Membership.Update(r.Context(), tid, actorID, id, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, m)
}

func (h *Handlers) RemoveMember(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	actorID := middleware.MustAccountID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err := h.Membership.Remove(r.Context(), tid, actorID, id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) PatchMemberContactFields(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcmem.ContactFieldsInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.Membership.UpdateContactFields(r.Context(), tid, id, body); err != nil {
		encode.JSONError(w, err)
		return
	}
	m, err := h.Membership.Get(r.Context(), tid, id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, m)
}

func (h *Handlers) ListMembers(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	deptID, _ := strconv.ParseInt(r.URL.Query().Get("department_id"), 10, 64)
	kw := r.URL.Query().Get("q")
	if h.Membership == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("membership service not wired"))
		return
	}
	items, total, err := h.Membership.List(r.Context(), tid, deptID, kw, limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}
