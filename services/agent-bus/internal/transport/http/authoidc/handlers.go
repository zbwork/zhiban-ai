// Package authoidc exposes public login endpoints separately for Bus and Admin.
package authoidc

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	domidentity "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/identity"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcauth "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminsession"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type Auth interface {
	StartOIDC(context.Context, svcauth.StartOIDCReq) (*svcauth.StartOIDCResp, error)
	LoginOIDC(context.Context, svcauth.AuthContext, svcauth.OIDCCallbackReq) (*svcauth.LoginResp, error)
}
type Catalog interface {
	ListPublic(context.Context) ([]domidentity.PublicProvider, error)
}
type Handlers struct {
	Auth       Auth
	Catalog    Catalog
	AdminOnly  bool
	cookieName string
	cookiePath string
}

func (h *Handlers) Register(mux *http.ServeMux, prefix string) {
	h.cookieName = "zhiban_oidc_state"
	if h.AdminOnly {
		h.cookieName = "zhiban_admin_oidc_state"
	}
	h.cookiePath = prefix + "/login/oidc"
	mux.HandleFunc("GET "+prefix+"/identity-providers/public", h.List)
	mux.HandleFunc("POST "+prefix+"/login/oidc/start", h.Start)
	mux.HandleFunc("POST "+prefix+"/login/oidc/callback", h.Callback)
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(v); err != nil {
		return err
	}
	var tail any
	if err := decoder.Decode(&tail); err != io.EOF {
		return apperr.ErrInvalidParams
	}
	return nil
}
func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.Catalog.ListPublic(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
func (h *Handlers) Start(w http.ResponseWriter, r *http.Request) {
	var in svcauth.StartOIDCReq
	if err := decode(w, r, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	out, err := h.Auth.StartOIDC(ctx, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: h.cookieName, Value: out.State, Path: h.cookiePath, MaxAge: 300, HttpOnly: true, Secure: r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"), SameSite: http.SameSiteLaxMode})
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, out)
}
func (h *Handlers) Callback(w http.ResponseWriter, r *http.Request) {
	var in svcauth.OIDCCallbackReq
	if err := decode(w, r, &in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	cookie, err := r.Cookie(h.cookieName)
	if err != nil || in.State == "" || subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(in.State)) != 1 {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("登录验证已失效，请重新发起企业登录"))
		return
	}
	http.SetCookie(w, &http.Cookie{Name: h.cookieName, Value: "", Path: h.cookiePath, MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	out, err := h.Auth.LoginOIDC(ctx, svcauth.AuthContext{IP: ip, UserAgent: r.UserAgent(), Device: in.Device}, in)
	if err == nil && h.AdminOnly {
		err = adminsession.GateAdmin(out)
	}
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, out)
}
