package busrouter

import (
	"context"
	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcontacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/session"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type memberReader struct{}

func (memberReader) GetMembership(context.Context, int64, int64) (*domaccount.Membership, error) {
	return &domaccount.Membership{Status: "active"}, nil
}
func TestTemporaryPasswordCannotReachBusinessOrSwitchScope(t *testing.T) {
	mux := http.NewServeMux()
	h := Handlers{Session: &session.Handlers{}, Contacts: &clientcontacts.Handlers{}, Catalog: &clientcatalog.Handlers{}}
	auth := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			next.ServeHTTP(w, r.WithContext(middleware.ContextWithClaimsForTest(r.Context(), &jwt.Claims{AccountID: 7, ActTenantID: 11, ActScope: "tenant", MustChange: true})))
		})
	}
	h.Register(mux, auth, memberReader{})
	for _, tc := range []struct {
		method, path string
		want         int
	}{
		{"GET", "/contacts", 403}, {"GET", "/contacts/tree", 403}, {"GET", "/skills", 403}, {"POST", "/auth/scope/switch", 403},
		// Empty body reaches decoding (400), rather than being blocked by must-change or tenant gates.
		{"POST", "/auth/password/change", 400},
	} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(tc.method, "/api/agent-bus/v1"+tc.path, strings.NewReader(""))
		mux.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Errorf("%s got %d want %d", tc.path, w.Code, tc.want)
		}
	}
}
