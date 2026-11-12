// Reused from the original admin RBAC handlers; role IDs are checked against the active scope.
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"

	domrbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ===================== permissions =====================

func (h *Handlers) listPermissions(w http.ResponseWriter, r *http.Request) {
	scope := r.URL.Query().Get("scope")
	list, err := h.RBAC.ListPermissions(r.Context(), scope)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": len(list)})
}

// ===================== roles =====================

type roleBody struct {
	Code          string  `json:"code"`
	Name          string  `json:"name"`
	Description   string  `json:"description"`
	PermissionIDs []int64 `json:"permissionIds"`
}

func (h *Handlers) listPlatformRoles(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	list, total, err := h.RBAC.ListRoles(r.Context(), domrbac.RoleFilter{
		ScopeKind: "platform",
		Keyword:   r.URL.Query().Get("q"),
		Limit:     limit, Offset: offset,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": total})
}

func (h *Handlers) listTenantRoles(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	list, total, err := h.RBAC.ListRoles(r.Context(), domrbac.RoleFilter{
		ScopeKind: "tenant",
		TenantID:  &tid,
		Keyword:   r.URL.Query().Get("q"),
		Limit:     limit, Offset: offset,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": total})
}

func (h *Handlers) getRole(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if !h.requireRoleScope(w, r, id) {
		return
	}
	res, err := h.RBAC.GetRole(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) createPlatformRole(w http.ResponseWriter, r *http.Request) {
	var body roleBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.RBAC.CreateRole(r.Context(), domrbac.RoleInput{
		ScopeKind:     "platform",
		Code:          body.Code,
		Name:          body.Name,
		Description:   body.Description,
		PermissionIDs: body.PermissionIDs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) createTenantRole(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	var body roleBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.RBAC.CreateRole(r.Context(), domrbac.RoleInput{
		ScopeKind:     "tenant",
		TenantID:      &tid,
		Code:          body.Code,
		Name:          body.Name,
		Description:   body.Description,
		PermissionIDs: body.PermissionIDs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) updateRole(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if !h.requireRoleScope(w, r, id) {
		return
	}
	var body roleBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.RBAC.UpdateRole(r.Context(), id, domrbac.RoleInput{
		Name:          body.Name,
		Description:   body.Description,
		PermissionIDs: body.PermissionIDs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) deleteRole(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if !h.requireRoleScope(w, r, id) {
		return
	}
	if err := h.RBAC.DeleteRole(r.Context(), id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// ===================== menus =====================

type menuBody struct {
	ParentID      *int64         `json:"parentId"`
	Name          string         `json:"name"`
	Icon          string         `json:"icon"`
	Route         string         `json:"route"`
	SortOrder     int            `json:"sortOrder"`
	ScopeKind     string         `json:"scopeKind"`
	IsVisible     bool           `json:"isVisible"`
	Metadata      map[string]any `json:"metadata"`
	PermissionIDs []int64        `json:"permissionIds"`
}

func (h *Handlers) listAllMenus(w http.ResponseWriter, r *http.Request) {
	all := r.URL.Query().Get("includeHidden") == "true"
	list, err := h.RBAC.ListMenus(r.Context(), all)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": len(list)})
}

func (h *Handlers) getMenu(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	res, err := h.RBAC.GetMenu(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) createMenu(w http.ResponseWriter, r *http.Request) {
	var body menuBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.RBAC.CreateMenu(r.Context(), domrbac.MenuInput{
		ParentID:      body.ParentID,
		Name:          body.Name,
		Icon:          body.Icon,
		Route:         body.Route,
		SortOrder:     body.SortOrder,
		ScopeKind:     body.ScopeKind,
		IsVisible:     body.IsVisible,
		Metadata:      body.Metadata,
		PermissionIDs: body.PermissionIDs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) updateMenu(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body menuBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.RBAC.UpdateMenu(r.Context(), id, domrbac.MenuInput{
		ParentID:      body.ParentID,
		Name:          body.Name,
		Icon:          body.Icon,
		Route:         body.Route,
		SortOrder:     body.SortOrder,
		ScopeKind:     body.ScopeKind,
		IsVisible:     body.IsVisible,
		Metadata:      body.Metadata,
		PermissionIDs: body.PermissionIDs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) deleteMenu(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err := h.RBAC.DeleteMenu(r.Context(), id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
