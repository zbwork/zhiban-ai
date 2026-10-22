package clientapps

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTokenRejectsMalformedAndUnsupportedRequests(t *testing.T) {
	h := &Handlers{}
	for _, body := range []string{"{}", "{", "{\"grant_type\":\"password\"}", "{\"unknown\":1}", "{} {}", strings.Repeat("x", 5000)} {
		r := httptest.NewRequest("POST", "/api/external/v1/oauth/token", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.Token(w, r)
		if w.Code < 400 {
			t.Fatalf("accepted malformed/unsupported body status=%d", w.Code)
		}
		if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Pragma") != "no-cache" {
			t.Fatal("missing cache isolation")
		}
	}
}
