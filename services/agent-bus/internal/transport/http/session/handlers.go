package session

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcauth "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
)

type Service interface {
	GenerateCaptcha(context.Context) (*captcha.Result, error)
	LoginPassword(context.Context, svcauth.AuthContext, svcauth.PasswordLoginReq) (*svcauth.LoginResp, error)
	Refresh(context.Context, svcauth.RefreshReq) (*svcauth.LoginResp, error)
	Logout(context.Context, string) error
	Me(context.Context, int64, int64) (*svcauth.MeResp, error)
	SwitchScope(context.Context, int64, string, svcauth.ScopeSwitchReq) (*svcauth.LoginResp, error)
	ListMenu(context.Context, int64, string, int64) ([]rbac.Menu, error)
	ChangePassword(context.Context, int64, svcauth.ChangePasswordReq) error
}

type Handlers struct {
	Auth Service
}

func (h *Handlers) Captcha(w http.ResponseWriter, r *http.Request) {
	res, err := h.Auth.GenerateCaptcha(r.Context())
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
	resp, err := h.Auth.LoginPassword(r.Context(), AuthContext(r, req.Device), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Refresh(w http.ResponseWriter, r *http.Request) {
	var req svcauth.RefreshReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	resp, err := h.Auth.Refresh(r.Context(), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Logout(w http.ResponseWriter, r *http.Request) {
	if err := h.Auth.Logout(r.Context(), middleware.SessionUUID(r.Context())); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) Me(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	res, err := h.Auth.Me(r.Context(), middleware.MustAccountID(r.Context()), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
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

func (h *Handlers) Menu(w http.ResponseWriter, r *http.Request) {
	res, err := h.Auth.ListMenu(r.Context(),
		middleware.MustAccountID(r.Context()),
		middleware.ActScope(r.Context()),
		middleware.MustTenantID(r.Context()))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) ChangePassword(w http.ResponseWriter, r *http.Request) {
	var req svcauth.ChangePasswordReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.Auth.ChangePassword(r.Context(), middleware.MustAccountID(r.Context()), req); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func AuthContext(r *http.Request, device svcauth.DeviceInfo) svcauth.AuthContext {
	return svcauth.AuthContext{IP: ClientIP(r), UserAgent: r.UserAgent(), Device: device}
}

func ClientIP(r *http.Request) string {
	if x := r.Header.Get("X-Forwarded-For"); x != "" {
		if i := strings.Index(x, ","); i > 0 {
			return strings.TrimSpace(x[:i])
		}
		return strings.TrimSpace(x)
	}
	if x := r.Header.Get("X-Real-IP"); x != "" {
		return x
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}
