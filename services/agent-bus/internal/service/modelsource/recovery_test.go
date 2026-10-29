package modelsource

import (
	"context"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"testing"
)

func TestRecoveryCandidatesRespectSourcesCapabilitiesAndVersion(t *testing.T) {
	s, repo, c := fixture(t)
	c.Models = []dom.Model{{ID: "claude-original", Enabled: true, ToolUse: true}, {ID: "claude-other", Enabled: true, ToolUse: true}, {ID: "gpt-backup", Enabled: true, ToolUse: true}, {ID: "aaa-no-tools", Enabled: true}, {ID: "codex-auto-review", Enabled: true, ToolUse: true}, {ID: "gemini-backup", Enabled: true, ToolUse: true}}
	other := c
	other.ID = "other"
	other.CatalogID = "beebridge"
	other.Models = []dom.Model{{ID: "qwen-backup", Enabled: true, ToolUse: true}}
	wrongProtocol := other
	wrongProtocol.ID = "native"
	wrongProtocol.CatalogID = "anthropic"
	wrongProtocol.Protocol = "anthropic-messages"
	options, err := s.Sync(context.Background(), repo.scope, []dom.Config{c, wrongProtocol, other})
	if err != nil {
		t.Fatal(err)
	}
	plan, err := s.RecoveryCandidates(context.Background(), repo.scope, options[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan) != 2 || plan[0].ModelID != "gpt-backup" || plan[1].ModelID != "qwen-backup" || plan[1].SourceID != managedBeeBridgeSourceID {
		t.Fatalf("wrong plan: %+v", plan)
	}
	if _, err = s.RecoveryCandidates(context.Background(), dom.Scope{TenantID: 1, AccountID: 9}, options[0].ID); err == nil {
		t.Fatal("cross-account accepted")
	}
	old, err := s.BindSelection(context.Background(), repo.scope, plan[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	c.APIKey = "changed"
	if _, err = s.Sync(context.Background(), repo.scope, []dom.Config{c, other}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Resolve(context.Background(), repo.scope, old); err == nil {
		t.Fatal("stale candidate accepted")
	}
}
func TestPortableRecoveryBody(t *testing.T) {
	for _, tc := range []struct {
		body string
		want bool
	}{
		{`{"model":"x","messages":[{"role":"tool","tool_call_id":"id","content":"created"}],"tools":[]}`, true},
		{`{"model":"x","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}`, true},
		{`{"model":"x","messages":[],"store":false}`, true},
		{`{"model":"x","messages":[],"store":true}`, false},
		{`{"model":"x","messages":[],"thinking":{"type":"enabled"}}`, false},
		{`{"model":"x","messages":[{"role":"user","content":[{"type":"image_url"}]}]}`, false},
		{`{"model":"x","messages":[{"role":"assistant","content":"hi","reasoning_content":"opaque"}]}`, false},
	} {
		if got := PortableRecoveryBody(json.RawMessage(tc.body)); got != tc.want {
			t.Fatalf("%s = %v", tc.body, got)
		}
	}
}

func TestRecoveryUpstreamQuotaIsNotRateLimit(t *testing.T) {
	for _, tc := range []struct {
		body, kind string
		retry      bool
	}{
		{`{"error":{"code":"insufficient_quota","message":"private upstream detail"}}`, "quota", false},
		{`{"error":{"code":"rate_limit_exceeded"}}`, "unknown", true},
		{`{"error":{"message":"unsupported temperature, private value"}}`, "temperature", true},
	} {
		kind := upstreamFailureKind([]byte(tc.body))
		e := &UpstreamError{Status: 429, Kind: kind}
		if kind != tc.kind || e.Retryable() != tc.retry {
			t.Fatalf("wrong fixed classification %s", kind)
		}
	}
}

func TestUpstreamFailureReasonIsSpecificButRedacted(t *testing.T) {
	body := []byte(`{"error":{"code":"model_not_found","message":"model claude-opus-4-6-thinking is unavailable; key sk-secret-value"}}`)
	if got := upstreamFailureReason(body); got != "model_not_found: model claude-opus-4-6-thinking is unavailable; key" {
		t.Fatalf("unexpected reason: %q", got)
	}
	if got := upstreamFailureReason([]byte(`{"error":{"message":"bad request"}}`)); got != "bad request" {
		t.Fatalf("unexpected fallback reason: %q", got)
	}
}

func TestRecoveryModelNotFoundCanUseNextEnabledCandidate(t *testing.T) {
	for _, status := range []int{400, 404} {
		if !(&UpstreamError{Status: status, Kind: "model_unavailable"}).Retryable() {
			t.Fatal("unavailable candidate did not allow recovery")
		}
		for _, kind := range []string{"unknown", "authentication", "quota", "tools", "token_limit"} {
			if (&UpstreamError{Status: status, Kind: kind}).Retryable() {
				t.Fatalf("unsafe retry %s", kind)
			}
		}
	}
}

func TestPublicModelFailureClassification(t *testing.T) {
	for _, tc := range []struct {
		body   string
		status int
		code   string
	}{
		{`{"error":{"code":"InvalidParameter","message":"Request body format invalid"}}`, 400, "model.request_invalid"},
		{`{"code":"InvalidParameter","message":"Request body format invalid"}`, 400, "model.request_invalid"},
		{`{"error":{"code":"context_length_exceeded","type":"invalid_request_error"}}`, 400, "model.context_limit"},
		{`{"error":{"code":"insufficient_quota"}}`, 429, "model.upstream_quota"},
		{`{"error":{"code":"rate_limit_exceeded"}}`, 429, "model.rate_limited"},
		{`{}`, 401, "model.authentication_failed"},
		{`{}`, 504, "model.timeout"},
		{`{"error":{"message":"SECRET https://private.` + `internal/?key=private"}}`, 400, "model.upstream_failure"},
	} {
		e := &UpstreamError{Status: tc.status, Kind: upstreamFailureKind([]byte(tc.body))}
		if e.PublicCode() != tc.code {
			t.Fatalf("got %s want %s", e.PublicCode(), tc.code)
		}
	}
}

func TestMissingMessagesIsNotRetriedAsTransientServerFailure(t *testing.T) {
	body := []byte(`{"error":{"code":"new_api_error","message":"field messages is required (request id: private)"}}`)
	e := &UpstreamError{Status: 500, Kind: upstreamFailureKind(body)}
	if e.PublicCode() != "model.messages_required" || e.Retryable() {
		t.Fatalf("incorrect missing-field classification: %+v", e)
	}
}

func TestNumericProviderErrorsKeepSpecificClassification(t *testing.T) {
	for _, tc := range []struct{ body, kind string }{
		{`{"error":{"code":400,"message":"Request contains an invalid argument."}}`, "request_invalid"},
		{`{"error":{"code":400,"message":"contents is not specified"}}`, "request_invalid"},
		{`{"error":{"message":"The free trial quota for the service has been exhausted and postpaid billing is not enabled"}}`, "quota"},
	} {
		if got := upstreamFailureKind([]byte(tc.body)); got != tc.kind {
			t.Fatalf("kind=%s expected=%s", got, tc.kind)
		}
	}
}
