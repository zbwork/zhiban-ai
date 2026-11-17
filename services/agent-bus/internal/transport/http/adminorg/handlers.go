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
	"net/mail"
	"regexp"
	"strconv"
	"strings"
)

type MembershipService interface {
	List(context.Context, int64, int64, string, int, int) ([]svcmem.Member, int64, error)
	Get(context.Context, int64, int64) (*svcmem.Member, error)
	Update(context.Context, int64, int64, int64, svcmem.UpdateInput) (*svcmem.Member, error)
	Remove(context.Context, int64, int64, int64) error
	UpdateContactFields(context.Context, int64, int64, svcmem.ContactFieldsInput) error
}
type MemberCreator interface {
	Invite(context.Context, int64, int64, svcmem.InviteInput) (*svcmem.InviteResult, error)
}

type Handlers struct {
	MemberCreator MemberCreator
	Department    svcdept.Service
	Membership    MembershipService
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

// CreateMember provisions a normal member; role elevation remains a separate RBAC operation.
func (h *Handlers) CreateMember(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email        string `json:"email"`
		Phone        string `json:"phone"`
		DisplayName  string `json:"display_name"`
		EmployeeID   string `json:"employee_id"`
		Title        string `json:"title"`
		DepartmentID *int64 `json:"department_id"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	if strings.TrimSpace(body.DisplayName) == "" || body.DepartmentID == nil || *body.DepartmentID <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("请填写姓名并选择部门"))
		return
	}
	email, phone := strings.TrimSpace(body.Email), strings.TrimSpace(body.Phone)
	if (email == "") == (phone == "") {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("请填写邮箱或手机号中的一项"))
		return
	}
	if email != "" {
		address, err := mail.ParseAddress(email)
		if err != nil || address.Address != email {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("邮箱格式不正确"))
			return
		}
	}
	if phone != "" && !regexp.MustCompile(`^1[3-9][0-9]{9}$`).MatchString(phone) {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("手机号格式不正确"))
		return
	}
	if h.MemberCreator == nil {
		encode.JSONError(w, apperr.ErrInternal)
		return
	}
	result, err := h.MemberCreator.Invite(r.Context(), middleware.MustTenantID(r.Context()), middleware.MustAccountID(r.Context()), svcmem.InviteInput{Email: email, Phone: phone, DisplayName: strings.TrimSpace(body.DisplayName), EmployeeID: body.EmployeeID, Title: body.Title, DepartmentID: body.DepartmentID, RoleCode: "tenant.member"})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, result)
}
