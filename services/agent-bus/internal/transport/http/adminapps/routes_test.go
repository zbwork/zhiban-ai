package adminapps

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCatalogWithoutIssuerKeepsScopePermissionsAndNoWrites(t *testing.T) {
	mux := http.NewServeMux()
	guard := func(scope string) func(string, http.Handler) http.Handler {
		return func(code string, _ http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Guard", scope+":"+code)
				w.WriteHeader(http.StatusForbidden)
			})
		}
	}
	(&Handlers{}).RegisterReadOnly(mux, guard("tenant"), guard("platform"))
	for _, scope := range []string{"tenant", "platform"} {
		for _, suffix := range []string{"apps", "apps/example", "app-categories"} {
			path := "/api/admin/v1/" + scope + "/" + suffix
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
			expected := scope + ":" + scope + ".app.read"
			if scope == "platform" && suffix == "app-categories" {
				expected = "platform:platform.app_category.read"
			}
			if w.Code != http.StatusForbidden || w.Header().Get("Guard") != expected {
				t.Fatalf("%s status=%d guard=%s", path, w.Code, w.Header().Get("Guard"))
			}
			w = httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("POST", path, nil))
			expectedStatus := http.StatusForbidden
			if suffix == "apps/example" {
				expectedStatus = http.StatusMethodNotAllowed
			}
			if w.Code != expectedStatus {
				t.Fatalf("issuer-less write %s status=%d", path, w.Code)
			}
		}
	}
}

func TestUnconfiguredAppWriteReturnsConfigurationErrorAfterAuthorization(t *testing.T) {
	mux := http.NewServeMux()
	allow := func(_ string, h http.Handler) http.Handler { return h }
	(&Handlers{}).RegisterReadOnly(mux, allow, allow)
	for _, scope := range []string{"tenant", "platform"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/admin/v1/"+scope+"/apps", nil))
		if w.Code != http.StatusPreconditionFailed || !strings.Contains(w.Body.String(), "COMMUNITY_APP_ISSUER") {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
	}
}
