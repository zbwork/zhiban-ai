// org.go — /api/external/v1/org/* 外部组织架构同步 CRUD 端点。
//
// 鉴权: GET 支持 ek_ tenant.org.read 或 st_ org.read; 写接口仅支持 ek_ tenant.org.write。
// 对外 ID 使用 id 语义并兼容历史 uuid alias，不暴露 int64 id。
package external

import (
	"net/http"
	"strconv"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcextorg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/externalorg"
)

// ── Departments ──

func (h *Handlers) orgListDepartments(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	cursor := r.URL.Query().Get("cursor")
	limit := queryInt(r, "limit", 50)
	var updatedSince *time.Time
	if s := r.URL.Query().Get("updated_since"); s != "" {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid updated_since: %v", err))
			return
		}
		updatedSince = &t
	}
	page, err := h.ExternalOrg.ListDepartments(r.Context(), tenantID, cursor, limit, updatedSince)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, page)
}

func (h *Handlers) orgGetDepartment(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	departmentID := r.PathValue("department_id")
	d, err := h.ExternalOrg.GetDepartment(r.Context(), tenantID, departmentID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, d)
}

func (h *Handlers) orgCreateDepartment(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	var in svcextorg.CreateDepartmentInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	d, err := h.ExternalOrg.CreateDepartment(r.Context(), tenantID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
	encode.JSON(w, d)
}

func (h *Handlers) orgUpdateDepartment(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	departmentID := r.PathValue("department_id")
	var in svcextorg.UpdateDepartmentInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	d, err := h.ExternalOrg.UpdateDepartment(r.Context(), tenantID, departmentID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, d)
}

func (h *Handlers) orgDeleteDepartment(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	departmentID := r.PathValue("department_id")
	if err := h.ExternalOrg.DeleteDepartment(r.Context(), tenantID, departmentID); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Members ──

func (h *Handlers) orgListMembers(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	cursor := r.URL.Query().Get("cursor")
	limit := queryInt(r, "limit", 50)
	var updatedSince *time.Time
	if s := r.URL.Query().Get("updated_since"); s != "" {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid updated_since: %v", err))
			return
		}
		updatedSince = &t
	}
	page, err := h.ExternalOrg.ListMembers(r.Context(), tenantID, cursor, limit, updatedSince)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, page)
}

func (h *Handlers) orgGetMember(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	accountID := r.PathValue("account_id")
	m, err := h.ExternalOrg.GetMember(r.Context(), tenantID, accountID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, m)
}

func (h *Handlers) orgCreateMember(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	var in svcextorg.CreateMemberInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	m, err := h.ExternalOrg.CreateMember(r.Context(), tenantID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
	encode.JSON(w, m)
}

func (h *Handlers) orgUpdateMember(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	accountID := r.PathValue("account_id")
	var in svcextorg.UpdateMemberInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	m, err := h.ExternalOrg.UpdateMember(r.Context(), tenantID, accountID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, m)
}

func (h *Handlers) orgDeleteMember(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	accountID := r.PathValue("account_id")
	if err := h.ExternalOrg.DeleteMember(r.Context(), tenantID, accountID); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Positions ──

func (h *Handlers) orgListPositions(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	cursor := r.URL.Query().Get("cursor")
	limit := queryInt(r, "limit", 50)
	var updatedSince *time.Time
	if s := r.URL.Query().Get("updated_since"); s != "" {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid updated_since: %v", err))
			return
		}
		updatedSince = &t
	}
	page, err := h.ExternalOrg.ListPositions(r.Context(), tenantID, cursor, limit, updatedSince)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, page)
}

func (h *Handlers) orgGetPosition(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	positionID := r.PathValue("position_id")
	p, err := h.ExternalOrg.GetPosition(r.Context(), tenantID, positionID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

func (h *Handlers) orgCreatePosition(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	var in svcextorg.CreatePositionInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	p, err := h.ExternalOrg.CreatePosition(r.Context(), tenantID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
	encode.JSON(w, p)
}

func (h *Handlers) orgUpdatePosition(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	positionID := r.PathValue("position_id")
	var in svcextorg.UpdatePositionInput
	if err := decodeStrictJSON(r.Body, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid body: %v", err))
		return
	}
	p, err := h.ExternalOrg.UpdatePosition(r.Context(), tenantID, positionID, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

func (h *Handlers) orgDeletePosition(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	positionID := r.PathValue("position_id")
	if err := h.ExternalOrg.DeletePosition(r.Context(), tenantID, positionID); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func queryInt(r *http.Request, key string, def int) int {
	s := r.URL.Query().Get(key)
	if s == "" {
		return def
	}
	v, err := strconv.Atoi(s)
	if err != nil || v <= 0 {
		return def
	}
	return v
}
