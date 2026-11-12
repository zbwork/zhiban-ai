package im

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/busrouter"
	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/directroom"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcontacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientfiles"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientpositions"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientrooms"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/session"
)

type testMembership struct{}

func (testMembership) GetMembership(_ context.Context, accountID, tenantID int64) (*domaccount.Membership, error) {
	if accountID == 7 && tenantID == 10 {
		return &domaccount.Membership{Status: "active"}, nil
	}
	return nil, nil
}

// Guard restored routes with the same auth/tenant/membership chain as the entrypoint.
// Dynamic employee routes must not absorb the literal positions route.
func TestClientRoutesRejectAnonymousWrongScopeAndInactiveMembership(t *testing.T) {
	private, _, err := jwt.GenerateDevKeypair()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := jwt.New(private, "", "client-routes", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	auth := middleware.Auth(issuer, nil, false)
	membership := testMembership{}
	mux := http.NewServeMux()
	busrouter.Handlers{Session: &session.Handlers{}, Contacts: &clientcontacts.Handlers{}, Agents: &clientcatalog.AgentHandlers{}, Catalog: &clientcatalog.Handlers{}, Files: &clientfiles.Handlers{}, Positions: &clientpositions.Handlers{}}.Register(mux, auth, membership)
	authT := func(h http.Handler) http.Handler {
		return auth(middleware.RequireTenant(middleware.RequireActiveTenantMembership(membership)(h)))
	}
	(&clientrooms.Handlers{DirectRoom: struct{ directroom.Service }{}}).Register(mux, authT)
	for _, route := range []struct{ method, path string }{
		{"POST", "/message-files/upload"}, {"POST", "/message-files/presign"}, {"POST", "/message-files/confirm"},
		{"GET", "/message-files/example/download"}, {"GET", "/message-files/example/preview"},
		{"POST", "/chat/media"}, {"GET", "/chat/media/example/download"}, {"GET", "/chat/media/example/preview"},
		{"GET", "/agents/positions"}, {"POST", "/rooms"}, {"GET", "/rooms/example"}, {"PATCH", "/rooms/example"},
		{"POST", "/rooms/example/participants"}, {"DELETE", "/rooms/example/participants/example"}, {"POST", "/direct-rooms"},
		{"GET", "/conversations/example/skill-rail-config"}, {"POST", "/agents/example/skill-overrides"},
		{"DELETE", "/agents/example/skill-overrides/example"}, {"POST", "/builtin-skills/handshake"},
	} {
		t.Run(route.method+route.path, func(t *testing.T) {
			for _, mode := range []string{"anonymous", "platform", "inactive"} {
				req := httptest.NewRequest(route.method, "/api/agent-bus/v1"+route.path, strings.NewReader("{}"))
				want := 403
				if mode == "anonymous" {
					want = 401
				} else {
					scope := "tenant"
					tenant := int64(11)
					if mode == "platform" {
						scope = "platform"
						tenant = 10
					}
					token, err := issuer.Issue(jwt.IssueOptions{AccountID: 7, ActScope: scope, ActTenantID: tenant})
					if err != nil {
						t.Fatal(err)
					}
					req.Header.Set("Authorization", "Bearer "+token)
				}
				response := httptest.NewRecorder()
				mux.ServeHTTP(response, req)
				if response.Code != want {
					t.Fatalf("%s status=%d want=%d", mode, response.Code, want)
				}
			}
		})
	}
}
