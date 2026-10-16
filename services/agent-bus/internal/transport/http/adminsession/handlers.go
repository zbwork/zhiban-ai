// Package adminsession implements administrator sessions. Protected routes require RequireAdmin middleware.
package adminsession

import (
	"context"
	"encoding/json"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcauth "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	"net"
	"net/http"
)

type AuthService interface {
	GenerateCaptcha(context.Context) (*captcha.Result, error)
	LoginPassword(context.Context, svcauth.AuthContext, svcauth.PasswordLoginReq) (*svcauth.LoginResp, error)
	Refresh(context.Context, svcauth.RefreshReq) (*svcauth.LoginResp, error)
	Logout(context.Context, string) error
	Me(context.Context, int64, int64) (*svcauth.MeResp, error)
	SwitchScope(context.Context, int64, string, svcauth.ScopeSwitchReq) (*svcauth.LoginResp, error)
	ChangePassword(context.Context, int64, svcauth.ChangePasswordReq) error
}
type RBACService interface {
	MenusFor(context.Context, int64, string, int64) ([]rbac.Menu, error)
	PermissionsFor(context.Context, int64, int64) ([]string, error)
}
type Handlers struct {
	Auth AuthService
	RBAC RBACService
}

func stripPort(s string) string {
	if host, _, err := net.SplitHostPort(s); err == nil {
		return host
	}
	return s
}
func (h *Handlers) Captcha(w http.ResponseWriter, r *http.Request) {
	res, err := h.Auth.GenerateCaptcha(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) Refresh(w http.ResponseWriter, r *http.Request) {
	var req svcauth.RefreshReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.Auth.Refresh(r.Context(), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := GateAdmin(res); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) Logout(w http.ResponseWriter, r *http.Request) {
	if err := h.Auth.Logout(r.Context(), middleware.SessionUUID(r.Context())); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) ChangePassword(w http.ResponseWriter, r *http.Request) {
	var req svcauth.ChangePasswordReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	if accID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	if err := h.Auth.ChangePassword(r.Context(), accID, req); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) SwitchScope(w http.ResponseWriter, r *http.Request) {
	var req svcauth.ScopeSwitchReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.Auth.SwitchScope(r.Context(),
		middleware.MustAccountID(r.Context()),
		middleware.SessionUUID(r.Context()), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) LoginPassword(w http.ResponseWriter, r *http.Request) {
	var req svcauth.PasswordLoginReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	ac := svcauth.AuthContext{IP: stripPort(r.RemoteAddr), UserAgent: r.UserAgent()}
	resp, err := h.Auth.LoginPassword(r.Context(), ac, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := GateAdmin(resp); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Me(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	// round-6 P2-1: admin /me 也透传 tenant scope (platform admin → 0, tenant admin → tid).
	tid := middleware.MustTenantID(r.Context())
	out, err := h.Auth.Me(r.Context(), accID, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"account": out.Account,
		"scopes":  out.Scopes,
		"actScope": map[string]any{
			"kind":        middleware.ActScope(r.Context()),
			"tenantId":    middleware.MustTenantID(r.Context()),
			"workspaceId": middleware.WorkspaceID(r.Context()),
		},
	})
}

func (h *Handlers) Menus(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	scope := middleware.ActScope(r.Context())
	menus, err := h.RBAC.MenusFor(r.Context(), accID, scope, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, menus)
}

func (h *Handlers) Permissions(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	codes, err := h.RBAC.PermissionsFor(r.Context(), accID, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, codes)
}

func GateAdmin(resp *svcauth.LoginResp) error {
	if resp == nil || resp.Account.ID <= 0 {
		return apperr.ErrUnauthorized
	}
	if !resp.ActScope.IsAdmin {
		return apperr.ErrForbidden.Withf("账号无后台管理权限")
	}
	return nil
}
