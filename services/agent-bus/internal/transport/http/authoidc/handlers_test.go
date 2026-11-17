package authoidc

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	svcauth "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
)

type loginFixture struct {
	called bool
	admin  bool
}

func (f *loginFixture) StartOIDC(context.Context, svcauth.StartOIDCReq) (*svcauth.StartOIDCResp, error) {
	return &svcauth.StartOIDCResp{State: "browser-state", AuthURL: "https://idp.example.test/authorize"}, nil
}
func (f *loginFixture) LoginOIDC(context.Context, svcauth.AuthContext, svcauth.OIDCCallbackReq) (*svcauth.LoginResp, error) {
	f.called = true
	return &svcauth.LoginResp{Account: svcauth.AccountSummary{ID: 7}, ActScope: svcauth.ScopeOption{IsAdmin: f.admin}}, nil
}

func TestBrowserBoundChallengeAndAdminGate(t *testing.T) {
	for _, tc := range []struct {
		name, cookie string
		admin        bool
		want         int
		called       bool
	}{
		{"missing challenge", "", true, http.StatusUnauthorized, false},
		{"other browser challenge", "another-state", true, http.StatusUnauthorized, false},
		{"ordinary member", "browser-state", false, http.StatusForbidden, true},
		{"authorized admin", "browser-state", true, http.StatusOK, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fixture := &loginFixture{admin: tc.admin}
			mux := http.NewServeMux()
			(&Handlers{Auth: fixture, AdminOnly: true}).Register(mux, "/api/admin/v1/auth")
			req := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login/oidc/callback", strings.NewReader(`{"code":"code","state":"browser-state"}`))
			if tc.cookie != "" {
				req.AddCookie(&http.Cookie{Name: "zhiban_admin_oidc_state", Value: tc.cookie})
			}
			recorder := httptest.NewRecorder()
			mux.ServeHTTP(recorder, req)
			if recorder.Code != tc.want || fixture.called != tc.called {
				t.Fatalf("HTTP %d, exchanged=%v; want %d, %v", recorder.Code, fixture.called, tc.want, tc.called)
			}
		})
	}
}

func TestStartChallengeCookieAndStrictJSON(t *testing.T) {
	mux := http.NewServeMux()
	(&Handlers{Auth: &loginFixture{}, AdminOnly: true}).Register(mux, "/api/admin/v1/auth")
	req := httptest.NewRequest(http.MethodPost, "https://admin.example.test/api/admin/v1/auth/login/oidc/start", strings.NewReader(`{"providerUuid":"idp"}`))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)
	cookies := recorder.Result().Cookies()
	if recorder.Code != http.StatusOK || len(cookies) != 1 {
		t.Fatalf("HTTP %d, cookies=%d", recorder.Code, len(cookies))
	}
	c := cookies[0]
	if c.Name != "zhiban_admin_oidc_state" || c.Value != "browser-state" || !c.Secure || !c.HttpOnly || c.SameSite != http.SameSiteLaxMode || c.Path != "/api/admin/v1/auth/login/oidc" || c.MaxAge != 300 {
		t.Fatalf("invalid challenge cookie: %+v", c)
	}
	for _, body := range []string{`{"providerUuid":"idp","unknown":true}`, `{"providerUuid":"idp"} {}`} {
		recorder = httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login/oidc/start", strings.NewReader(body)))
		if recorder.Code != http.StatusBadRequest || len(recorder.Result().Cookies()) != 0 {
			t.Fatalf("invalid JSON accepted: HTTP %d", recorder.Code)
		}
	}
}
