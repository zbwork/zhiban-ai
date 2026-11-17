package openai

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/modelerror"
)

func TestGatewayFailureIsClassifiedWithoutVendorDetails(t *testing.T) {
	for _, tc := range []struct {
		status int
		code   string
	}{
		{302, "model.redirect_not_allowed"}, {400, "model.request_invalid"}, {401, "model.authentication_failed"}, {403, "model.authentication_failed"}, {404, "model.unavailable"}, {408, "model.timeout"}, {429, "model.rate_limited"}, {500, "model.upstream_failure"}, {504, "model.timeout"},
	} {
		t.Run(tc.code, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", "http://never-follow.invalid")
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(`{"error":"vendor secret-sk-fixture prompt body"}`))
			}))
			defer server.Close()
			p := New(server.URL, "test-credential", "test-model", 1)
			_, err := p.StreamChat(context.Background(), model.ChatRequest{Messages: []model.ChatMessage{{Role: "user", Content: "private fixture"}}})
			code, detail, status := modelerror.Details(err)
			if code != tc.code || status != tc.status || detail == "" {
				t.Fatalf("code=%q status=%d error=%v", code, status, err)
			}
			for _, secret := range []string{"vendor", "secret-sk", "private fixture", "test-credential", server.URL} {
				if strings.Contains(err.Error(), secret) {
					t.Fatalf("failure exposed %q", secret)
				}
			}
		})
	}
}

type failingTransport struct{ err error }

func (f failingTransport) RoundTrip(*http.Request) (*http.Response, error) { return nil, f.err }

func TestNetworkFailureAndCancelledRequestRemainDistinct(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code string
	}{{context.DeadlineExceeded, "model.timeout"}, {errors.New("credential and URL must not escape"), "model.connection_failed"}, {context.Canceled, ""}} {
		p := New("https://fixture.invalid", "private-test-key", "test", 1)
		p.client.Transport = failingTransport{tc.err}
		_, err := p.StreamChat(context.Background(), model.ChatRequest{})
		code, _, _ := modelerror.Details(err)
		if code != tc.code {
			t.Fatalf("code=%q want=%q", code, tc.code)
		}
		if tc.code == "" && !errors.Is(err, context.Canceled) {
			t.Fatal("cancellation lost")
		}
	}
}

func TestStreamFailuresKeepSafeReason(t *testing.T) {
	for _, tc := range []struct{ data, code string }{
		{"data: {bad-json}\n\n", "model.response_failed"},
		{"data: {\"error\":{\"message\":\"secret vendor body\"}}\n\n", "model.response_failed"},
		{"data: {\"choices\":[{\"finish_reason\":\"length\"}]}\n\n", "model.response_incomplete"},
		{"data: {\"choices\":[{\"finish_reason\":\"content_filter\"}]}\n\n", "model.refused"},
		{"data: {\"choices\":[{\"finish_reason\":\"tool_calls\"}]}\n\n", "model.tools_invalid"},
		{"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", "model.response_incomplete"},
	} {
		t.Run(tc.code, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = w.Write([]byte(tc.data))
			}))
			defer server.Close()
			stream, err := New(server.URL, "key", "test", 1).StreamChat(context.Background(), model.ChatRequest{})
			if err != nil {
				t.Fatal(err)
			}
			defer stream.Close()
			var failure error
			for i := 0; i < 3; i++ {
				chunk, err := stream.Recv()
				if err != nil {
					failure = err
					break
				}
				if chunk.Err != nil {
					failure = chunk.Err
					break
				}
			}
			code, detail, _ := modelerror.Details(failure)
			if code != tc.code || strings.Contains(detail, "secret") {
				t.Fatalf("code=%q detail=%q", code, detail)
			}
		})
	}
}
