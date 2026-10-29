package modelsource

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

func TestProxyFailureDetailsNeverEchoSensitiveErrors(t *testing.T) {
	secret := "https://secret.example/?api_key=private-key"
	for _, tc := range []struct {
		err    error
		kind   string
		status int
	}{
		{errors.New(secret), "internal", 0},
		{&TransportError{Kind: secret}, "connection", 0},
		{&TransportError{Kind: "timeout"}, "timeout", 0},
		{&UpstreamError{Status: 502, Kind: secret}, "upstream", 502},
		{&UpstreamError{Status: 429, Kind: "quota"}, "upstream_quota", 429},
		{&UpstreamError{Status: -1, Kind: "authentication"}, "upstream_authentication", 0},
		{dom.ErrConfiguration, "configuration", 0},
		{context.Canceled, "cancelled", 0},
	} {
		kind, status := ProxyFailureDetails(tc.err)
		if kind != tc.kind || status != tc.status {
			t.Fatalf("got %q/%d, want %q/%d", kind, status, tc.kind, tc.status)
		}
	}
}

func TestProxyDiagnosticsRejectWrongBackendAndInactiveRun(t *testing.T) {
	s, repo, config := fixture(t)
	ctx := context.Background()
	options, err := s.Sync(ctx, repo.scope, []dom.Config{config})
	if err != nil {
		t.Fatal(err)
	}
	binding, err := s.Mint(ctx, repo.scope, 4, "message", options[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if binding.BaseURL != "https://bus.example/api/agent-bus/v1/runtime-model-proxy/v1" {
		t.Fatal("wrong advertised Bus")
	}
	body := json.RawMessage(`{"model":"gemini-3-flash","messages":[]}`)
	// A different signing backend must reject, rather than route using its keys.
	other, _, _ := fixture(t)
	other.secret = bytes.Repeat([]byte{3}, 32)
	_, err = other.ProxyToken(ctx, binding.APIKey, "chat/completions", body)
	kind, _ := ProxyFailureDetails(err)
	if kind != "authorization" || !errors.Is(err, dom.ErrDenied) {
		t.Fatal("wrong backend not rejected")
	}
	if strings.Contains(err.Error(), binding.APIKey) {
		t.Fatal("credential leaked")
	}
	repo.active = false
	_, err = s.ProxyToken(ctx, binding.APIKey, "chat/completions", body)
	kind, _ = ProxyFailureDetails(err)
	if kind != "run_inactive" || !errors.Is(err, dom.ErrDenied) {
		t.Fatal("inactive run not rejected")
	}
	repo.active = true
	_, err = s.ProxyToken(ctx, binding.APIKey, "messages", body)
	kind, _ = ProxyFailureDetails(err)
	if kind != "binding_unavailable" || !errors.Is(err, dom.ErrDenied) {
		t.Fatal("protocol binding not rejected")
	}
}
