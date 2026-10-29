package modelsource

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

func TestManagedModelProtocolBindingAndProxy(t *testing.T) {
	for _, tc := range []struct{ model, protocol, path string }{
		{"claude-opus-5", "anthropic-messages", "messages"},
		{"anthropic/claude-sonnet-4-6", "anthropic-messages", "messages"},
		{"gpt-5.6-sol", "openai-compatible", "chat/completions"},
		{"gemini-3-flash", "openai-compatible", "chat/completions"},
	} {
		t.Run(tc.model, func(t *testing.T) {
			ctx := context.Background()
			s, repo, cfg := fixture(t)
			cfg.CatalogID = "beebridge"
			cfg.Models = []dom.Model{{ID: tc.model, Enabled: true, ToolUse: true}}
			items, err := s.Sync(ctx, repo.scope, []dom.Config{cfg})
			if err != nil || len(items) != 1 {
				t.Fatalf("sync: %v", err)
			}
			stored, err := s.decode(repo.scope, repo.rows[0])
			if err != nil || stored.Protocol != "openai-compatible" {
				t.Fatalf("source default must remain OpenAI compatible: %v", err)
			}
			binding, err := s.Mint(ctx, repo.scope, 4, "message", items[0].ID)
			if err != nil || binding.Protocol != tc.protocol || binding.Model != tc.model {
				t.Fatalf("cloud binding: %+v %v", binding, err)
			}
			bound, err := s.BindSelection(ctx, repo.scope, items[0].ID)
			if err != nil {
				t.Fatal(err)
			}
			route, err := s.Resolve(ctx, repo.scope, bound)
			if err != nil || route.Protocol != tc.protocol {
				t.Fatalf("local binding protocol: %s %v", route.Protocol, err)
			}
			body := json.RawMessage(`{"model":"` + tc.model + `","max_tokens":128,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"created.docx"}]}],"stream":true}`)
			if tc.path != "messages" {
				body = json.RawMessage(`{"model":"` + tc.model + `","messages":[{"role":"tool","tool_call_id":"tool-1","content":"created.docx"}],"stream":true}`)
			}
			var want map[string]any
			if err := json.Unmarshal(body, &want); err != nil {
				t.Fatal(err)
			}
			calls := 0
			s.memberClient = &http.Client{Transport: transport(func(req *http.Request) (*http.Response, error) {
				calls++
				if req.Method != http.MethodPost || req.URL.String() != "https://member.example/v1/"+tc.path {
					t.Errorf("wrong endpoint: %s %s", req.Method, req.URL)
				}
				if tc.path == "messages" {
					if req.Header.Get("x-api-key") != "member-key" || req.Header.Get("anthropic-version") != "2023-06-01" || req.Header.Get("Authorization") != "" {
						t.Error("incorrect Messages headers")
					}
				} else if req.Header.Get("Authorization") != "Bearer member-key" || req.Header.Get("anthropic-version") != "" {
					t.Error("incorrect OpenAI headers")
				}
				var got map[string]any
				if err := json.NewDecoder(req.Body).Decode(&got); err != nil || !reflect.DeepEqual(got, want) {
					t.Errorf("model/messages changed: %v", err)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("ok")), Header: http.Header{}}, nil
			})}
			resp, err := s.ProxyToken(ctx, binding.APIKey, tc.path, body)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			for _, wrong := range []string{"messages", "chat/completions", "responses"} {
				if wrong != tc.path {
					if _, err := s.ProxyToken(ctx, binding.APIKey, wrong, body); err == nil {
						t.Errorf("accepted protocol %s", wrong)
					}
				}
			}
			if tc.path == "messages" {
				if _, err := s.ProxyLocalResponses(ctx, repo.scope, bound, body); err == nil {
					t.Fatal("Claude accepted Responses")
				}
				// Reconstruct a pre-change OpenAI binding for the same stored source.
				raw, _ := json.Marshal([]any{"model-route-v1", repo.scope, repo.rows[0].UUID, tc.model, "openai-compatible", route.BaseURL, route.APIKey, route.Headers, route.ToolUse, route.ProviderID})
				old := strings.Replace(bound, route.Fingerprint, hex.EncodeToString(s.mac(raw)), 1)
				if _, err := s.Resolve(ctx, repo.scope, old); err == nil {
					t.Fatal("old protocol binding silently upgraded")
				}
			}
			if calls != 1 {
				t.Fatalf("rejected requests reached upstream: %d", calls)
			}
		})
	}
}

func TestCustomClaudeKeepsConfiguredProtocol(t *testing.T) {
	for _, protocol := range []string{"openai-compatible", "anthropic-messages"} {
		s, repo, cfg := fixture(t)
		cfg.Protocol = protocol
		cfg.Models = []dom.Model{{ID: "claude-opus-5", Enabled: true}}
		items, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
		if err != nil {
			t.Fatal(err)
		}
		route, err := s.Resolve(context.Background(), repo.scope, items[0].ID)
		if err != nil || route.Protocol != protocol {
			t.Fatalf("custom protocol changed: %s %v", route.Protocol, err)
		}
	}
}

func TestManagedRecoveryDoesNotCrossProtocols(t *testing.T) {
	s, repo, cfg := fixture(t)
	cfg.CatalogID = "beebridge"
	cfg.Models = []dom.Model{{ID: "claude-opus-5", Enabled: true, ToolUse: true}, {ID: "gpt-backup", Enabled: true, ToolUse: true}, {ID: "claude-sonnet-4-6", Enabled: true, ToolUse: true}}
	items, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		candidates, err := s.RecoveryCandidates(context.Background(), repo.scope, item.ID)
		if err != nil {
			t.Fatal(err)
		}
		if item.ModelID == "claude-opus-5" && candidates[0].ModelID != "claude-sonnet-4-6" {
			t.Fatalf("Claude backup: %+v", candidates)
		}
		if item.ModelID == "gpt-backup" && candidates[0].ID != "" {
			t.Fatalf("OpenAI recovered onto Claude: %+v", candidates)
		}
	}
}
