// Member role handlers reused from the original admin package.
package admincore

import (
	"encoding/json"
	domrbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
)

// ===================== member × role =====================

type assignRoleBody struct {
	RoleID      int64  `json:"roleId"`
	WorkspaceID *int64 `json:"workspaceId,omitempty"`
}

// listMemberRoles 当前租户视角下, 该 membership 关联的所有 role assignments。
func (h *Handlers) listMemberRoles(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	memID, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	mem, err := h.Membership.Get(r.Context(), tid, memID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	list, err := h.RBAC.ListMemberAssignments(r.Context(), mem.AccountID, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": len(list)})
}

func (h *Handlers) assignMemberRole(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	memID, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	mem, err := h.Membership.Get(r.Context(), tid, memID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var body assignRoleBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	role, err := h.RBAC.GetRole(r.Context(), body.RoleID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 必须属于本租户 (或 workspace 隶属本租户)
	scopeKind := role.Role.ScopeKind
	var tidPtr, widPtr *int64
	switch scopeKind {
	case "tenant":
		if role.Role.TenantID == nil || *role.Role.TenantID != tid {
			encode.JSONError(w, apperr.ErrForbidden.Withf("角色不属于当前租户"))
			return
		}
		t := tid
		tidPtr = &t
	case "workspace":
		if role.Role.TenantID == nil || *role.Role.TenantID != tid {
			encode.JSONError(w, apperr.ErrForbidden.Withf("角色不属于当前租户"))
			return
		}
		if body.WorkspaceID == nil || *body.WorkspaceID == 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("workspace 角色必须指定 workspaceId"))
			return
		}
		t := tid
		tidPtr = &t
		widPtr = body.WorkspaceID
	default:
		encode.JSONError(w, apperr.ErrForbidden.Withf("不允许给租户成员指派 platform 角色"))
		return
	}
	if err := h.RBAC.AssignRole(r.Context(), &domrbac.RoleAssignment{
		AccountID:   mem.AccountID,
		RoleID:      body.RoleID,
		ScopeKind:   scopeKind,
		TenantID:    tidPtr,
		WorkspaceID: widPtr,
	}); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) revokeMemberRole(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	memID, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	roleID, _ := strconv.ParseInt(r.PathValue("roleId"), 10, 64)
	mem, err := h.Membership.Get(r.Context(), tid, memID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	role, err := h.RBAC.GetRole(r.Context(), roleID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if role.Role.TenantID == nil || *role.Role.TenantID != tid || (role.Role.ScopeKind != "tenant" && role.Role.ScopeKind != "workspace") {
		encode.JSONError(w, apperr.ErrForbidden.Withf("角色不属于当前租户"))
		return
	}
	t := tid
	if err := h.RBAC.RevokeAssignmentByTuple(r.Context(), mem.AccountID, roleID, role.Role.ScopeKind, &t, nil); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
