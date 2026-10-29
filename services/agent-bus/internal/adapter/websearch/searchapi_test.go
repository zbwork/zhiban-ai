package websearch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/websearch"
)

func fixture(t *testing.T, handler http.HandlerFunc) *SearchAPI {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	s := New(server.URL+"/v1/serapi/search", "server-only-key")
	s.client.Transport = server.Client().Transport
	return s
}

func TestSearchAPINormalization(t *testing.T) {
	s := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/v1/serapi/search" || r.Header.Get("Authorization") != "Bearer server-only-key" {
			t.Error("unexpected upstream request")
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || len(body) != 5 || body["q"] != "公开新闻" || body["engine"] != "google" || body["no_cache"] != true || body["num"] != float64(10) {
			t.Errorf("unexpected public search arguments: keys=%v", len(body))
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"search_metadata": map[string]string{"status": "Success", "json_endpoint": "http://internal.example/secret"},
			"organic_results": []map[string]string{
				{"title": "bad", "link": "javascript:alert(1)"},
				{"title": "userinfo", "link": "https:" + "//key:secret@example.com"},
				{"title": strings.Repeat("新", 250), "link": "https://example.com/a", "snippet": strings.Repeat("闻", 1100), "date": "2小时前"},
				{"title": "duplicate", "link": "https://example.com/a"},
				{"title": "B", "link": "https://example.com/b"},
				{"title": "C", "link": "https://example.com/c"},
			},
		})
	})
	out, err := s.Search(context.Background(), dom.Request{Query: "公开新闻", Limit: 2})
	if err != nil || len(out.Results) != 2 || out.TimeFilterSupported {
		t.Fatalf("unexpected normalized result: %v", err)
	}
	if len([]rune(out.Results[0].Title)) != 200 || len([]rune(out.Results[0].Snippet)) != 1000 || out.Results[0].Date != "2小时前" || out.Results[1].Date != "" {
		t.Fatal("date or text bounds changed")
	}
	encoded, _ := json.Marshal(out)
	if strings.Contains(string(encoded), "internal.example") || strings.Contains(string(encoded), "secret") {
		t.Fatal("upstream metadata leaked")
	}
}

func TestSearchAPIErrorsAndEmptyResults(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   error
	}{
		{"empty", 200, `{"search_metadata":{"status":"Success"},"organic_results":[]}`, nil},
		{"provider empty 400", 400, `{"code":400,"message":"Google didn't return any results.","object":"error"}`, nil},
		{"other 400", 400, `{"code":400,"message":"Invalid search parameters"}`, dom.ErrUnavailable},
		{"empty message without code", 400, `{"message":"Google didn't return any results."}`, dom.ErrUnavailable},
		{"empty message on server error", 500, `{"code":400,"message":"Google didn't return any results."}`, dom.ErrUnavailable},
		{"auth", 401, `secret upstream diagnostics`, dom.ErrUnavailable},
		{"quota", 429, `secret upstream diagnostics`, dom.ErrLimited},
		{"error status", 200, `{"search_metadata":{"status":"Error"},"organic_results":[]}`, dom.ErrUnavailable},
		{"error body", 200, `{"search_metadata":{"status":"Success"},"organic_results":[],"error":"secret"}`, dom.ErrUnavailable},
		{"missing results", 200, `{"search_metadata":{"status":"Success"},"search_information":{"query_displayed":"no matching news"}}`, nil},
		{"null results", 200, `{"search_metadata":{"status":"Success"},"organic_results":null}`, nil},
		{"wrong result type", 200, `{"search_metadata":{"status":"Success"},"organic_results":{}}`, dom.ErrUnavailable},
		{"missing results with error", 200, `{"search_metadata":{"status":"Success"},"error":"upstream failed"}`, dom.ErrUnavailable},
		{"invalid results", 200, `{"search_metadata":{"status":"Success"},"organic_results":[{"link":"file:///private/file"}]}`, dom.ErrUnavailable},
		{"invalid JSON", 200, `<html>captcha</html>`, dom.ErrUnavailable},
		{"oversized", 200, strings.Repeat("x", (1<<20)+1), dom.ErrUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			})
			out, err := s.Search(context.Background(), dom.Request{Query: "test", Limit: 5})
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v want %v", err, tc.want)
			}
			if tc.want == nil && (out.Results == nil || len(out.Results) != 0) {
				t.Fatal("empty success must serialize as []")
			}
		})
	}
}

func TestSearchAPINeverFollowsRedirectOrSendsMissingConfiguration(t *testing.T) {
	var hits atomic.Int32
	s := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Location", "https://example.com/steal")
		w.WriteHeader(307)
	})
	_, err := s.Search(context.Background(), dom.Request{Query: "test", Limit: 5})
	if !errors.Is(err, dom.ErrUnavailable) || hits.Load() != 1 {
		t.Fatal("redirect was not rejected")
	}
	for _, c := range []*SearchAPI{New("http://example.com/search", "key"), New("https://example.com/search?api_key=secret", "key"), New("https:"+"//user:pass@example.com/search", "key"), New("https://example.com/search", "")} {
		if _, err := c.Search(context.Background(), dom.Request{Query: "test", Limit: 5}); !errors.Is(err, dom.ErrUnavailable) {
			t.Fatal("invalid config accepted")
		}
	}
}

func TestSearchAPICancellationReachesUpstream(t *testing.T) {
	started, stopped := make(chan struct{}), make(chan struct{})
	s := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		select {
		case <-r.Context().Done():
			close(stopped)
		case <-time.After(3 * time.Second):
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := s.Search(ctx, dom.Request{Query: "test", Limit: 5}); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("upstream did not start")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("caller did not cancel")
	}
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("upstream was not cancelled")
	}
}

func TestSearchAPITimeoutIsSafe(t *testing.T) {
	s := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	})
	s.client.Timeout = 20 * time.Millisecond
	_, err := s.Search(context.Background(), dom.Request{Query: "test", Limit: 5})
	if !errors.Is(err, dom.ErrTimeout) || strings.Contains(fmt.Sprint(err), "server-only-key") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSearchAPIExplicitInternalEndpointIsDirect(t *testing.T) {
	const approved = "http://search.intranet.example/v1/serapi/search"
	s := New(approved, "test-key", approved)
	if s.endpoint == "" || s.client.Transport.(*http.Transport).Proxy != nil {
		t.Fatal("approved intranet endpoint must be direct")
	}
	for _, endpoint := range []string{"http://search.intranet.example/other", "http://search.intranet.example.evil.example/v1/serapi/search", "http://search.intranet.example/v1/serapi/search?redirect=1"} {
		if New(endpoint, "test-key", approved).endpoint != "" {
			t.Fatal("HTTP exception expanded beyond configured company API")
		}
	}
	if New(approved, "test-key").endpoint != "" {
		t.Fatal("HTTP endpoint accepted without explicit approval")
	}
}
