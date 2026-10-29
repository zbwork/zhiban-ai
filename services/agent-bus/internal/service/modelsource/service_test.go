package modelsource

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto/aesgcm"
	"io"
	"net/http"
	"strings"
	"testing"
)

type memoryRepo struct {
	scope  dom.Scope
	rows   []dom.Stored
	active bool
}

func (r *memoryRepo) Replace(_ context.Context, s dom.Scope, rows []dom.Stored) ([]dom.Stored, error) {
	if s != r.scope {
		return nil, dom.ErrDenied
	}
	out := []dom.Stored{}
	for i, v := range rows {
		v.UUID = fmt.Sprint(i)
		v.Version = 1
		for _, old := range r.rows {
			if old.SourceID == v.SourceID {
				v.UUID = old.UUID
				v.Version = old.Version
				if old.Fingerprint != v.Fingerprint {
					v.Version++
				}
			}
		}
		out = append(out, v)
	}
	r.rows = out
	return out, nil
}
func (r *memoryRepo) List(_ context.Context, s dom.Scope) ([]dom.Stored, error) {
	if s != r.scope {
		return nil, dom.ErrDenied
	}
	return r.rows, nil
}
func (r *memoryRepo) Get(_ context.Context, s dom.Scope, id string) (*dom.Stored, error) {
	if s != r.scope {
		return nil, dom.ErrDenied
	}
	for _, row := range r.rows {
		if row.UUID == id {
			return &row, nil
		}
	}
	return nil, dom.ErrDenied
}
func (r *memoryRepo) RunActive(_ context.Context, s dom.Scope, a int64, m string) (bool, error) {
	return r.active && s == r.scope && a == 4 && m == "message", nil
}

type keys struct{}

func TestMissingMemberEndpointIsConfigurationFailure(t *testing.T) {
	s, repo, cfg := fixture(t)
	cfg.CatalogID = "beebridge"
	options, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
	if err != nil || len(options) == 0 {
		t.Fatalf("sync: %v", err)
	}
	for _, address := range []string{"", "  "} {
		s.memberBase = address
		if _, err := s.Resolve(context.Background(), repo.scope, options[0].ID); !errors.Is(err, dom.ErrConfiguration) {
			t.Fatalf("missing data-plane address must be a configuration error: %v", err)
		}
	}
}

func TestManagedBeeBridgeConvergesToOneSourceAndStableVersion(t *testing.T) {
	s, repo, cfg := fixture(t)
	cfg.CatalogID = "beebridge"
	cfg.ID = "random-device-source"
	cfg.Models = []dom.Model{{ID: "gpt-5.6-luna", Enabled: true}}
	first, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
	if err != nil || len(first) != 1 || first[0].SourceID != managedBeeBridgeSourceID {
		t.Fatalf("first sync: items=%+v err=%v", first, err)
	}
	version := repo.rows[0].Version
	cfg.ID = "another-device-source"
	second, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
	if err != nil || len(second) != 1 || second[0].SourceID != managedBeeBridgeSourceID {
		t.Fatalf("second sync: items=%+v err=%v", second, err)
	}
	if len(repo.rows) != 1 || repo.rows[0].Version != version {
		t.Fatalf("unchanged managed refresh changed identity/version: rows=%+v", repo.rows)
	}
	cfg.ID = managedBeeBridgeSourceID
	if _, err = s.Sync(context.Background(), repo.scope, []dom.Config{cfg}); err != nil {
		t.Fatalf("canonical client source must remain idempotent: %v", err)
	}
}

func TestUnmanagedBeeBridgeKeepsMemberKeyAndAddress(t *testing.T) {
	s, repo, cfg := fixture(t)
	s.WithoutManagedBeeBridge()
	cfg.CatalogID, cfg.ID, cfg.BaseURL, cfg.APIKey = "beebridge", "my-beebridge", "https://beebridge.example/v1", "member-own-key"
	options, err := s.Sync(context.Background(), repo.scope, []dom.Config{cfg})
	if err != nil || len(options) == 0 || options[0].SourceID != "my-beebridge" {
		t.Fatalf("sync: items=%+v err=%v", options, err)
	}
	route, err := s.Resolve(context.Background(), repo.scope, options[0].ID)
	if err != nil || route.APIKey != "member-own-key" || route.BaseURL != "https://beebridge.example/v1" || route.Protocol != "openai-compatible" {
		t.Fatalf("unmanaged BeeBridge must keep the member configuration: %+v %v", route, err)
	}
}

func (keys) ModelKey(context.Context, int64, int64) (string, error) { return "member-key", nil }
func fixture(t *testing.T) (*Service, *memoryRepo, dom.Config) {
	t.Helper()
	c, e := aesgcm.New(bytes.Repeat([]byte{1}, 32))
	if e != nil {
		t.Fatal(e)
	}
	r := &memoryRepo{scope: dom.Scope{TenantID: 1, AccountID: 2}, active: true}
	s := New(r, c, keys{}, bytes.Repeat([]byte{2}, 32), "https://member.example/v1", "https://bus.example")
	return s, r, dom.Config{ID: "source", CatalogID: "silicon", Name: "硅基流动", Enabled: true, Protocol: "openai-compatible", BaseURL: "https://vendor.example/v1", APIKey: "vendor-secret", Models: []dom.Model{{ID: "gemini-3-flash", Enabled: true}, {ID: "bge-m3", Enabled: true}, {ID: "gemini-3.1-flash-image", Enabled: true}, {ID: "disabled", Enabled: false}}}
}
func TestReviewModelsExcludedFromConversationChoices(t *testing.T) {
	for _, catalog := range []string{"beebridge", "silicon"} {
		t.Run(catalog, func(t *testing.T) {
			s, r, c := fixture(t)
			ctx := context.Background()
			c.CatalogID = catalog
			c.Models = []dom.Model{
				{ID: "codex-auto-review", Enabled: true, ToolUse: true},
				{ID: "code-auto-review", Enabled: true, ToolUse: true},
				{ID: "provider/CODEX-AUTO-REVIEW", Enabled: true, ToolUse: true},
				{ID: "claude-opus-5", Enabled: true, ToolUse: true},
				{ID: "gpt-5.3-codex", Enabled: true, ToolUse: true},
			}
			check := func(options []Option, err error) {
				t.Helper()
				if err != nil || len(options) != 2 || options[0].ModelID != "claude-opus-5" || options[1].ModelID != "gpt-5.3-codex" || !options[0].Default {
					t.Fatalf("unexpected conversation choices: %+v, err=%v", options, err)
				}
			}
			check(s.Sync(ctx, r.scope, []dom.Config{c}))
			stored, err := s.decode(r.scope, r.rows[0])
			if err != nil || len(stored.Models) != len(c.Models) {
				t.Fatalf("filter must preserve provider configuration: %v", err)
			}
			// A catalogue already containing review models is filtered on read;
			// no client resync or catalogue migration is needed.
			listed, _, err := s.List(ctx, r.scope)
			check(listed, err)
			for _, m := range c.Models[:3] {
				if _, err := s.Resolve(ctx, r.scope, reference(r.rows[0], m.ID)); !errors.Is(err, dom.ErrDenied) {
					t.Fatalf("review selection %q must be unavailable: %v", m.ID, err)
				}
			}
		})
	}
}

func TestSourcesScopeVersionAndFiltering(t *testing.T) {
	s, r, c := fixture(t)
	ctx := context.Background()
	other := c
	other.ID = "second"
	other.CatalogID = "beebridge"
	other.Name = "spoof"
	out, e := s.Sync(ctx, r.scope, []dom.Config{c, other})
	if e != nil || len(out) != 2 {
		t.Fatalf("items=%d err=%v", len(out), e)
	}
	if out[0].ID == out[1].ID || out[1].ProviderName != "BeeBridge" {
		t.Fatal("platform identity lost")
	}
	raw, _ := json.Marshal(out)
	if bytes.Contains(raw, []byte("vendor-secret")) || bytes.Contains(r.rows[0].Ciphertext, []byte("vendor-secret")) {
		t.Fatal("secret disclosed")
	}
	route, e := s.Resolve(ctx, r.scope, out[1].ID)
	if e != nil || route.APIKey != "member-key" || route.BaseURL != "https://member.example/v1" {
		t.Fatal("managed identity replaced")
	}
	if _, e = s.Resolve(ctx, dom.Scope{TenantID: 1, AccountID: 3}, out[0].ID); e == nil {
		t.Fatal("cross-account reference accepted")
	}
	old := out[0].ID
	bound, _ := s.BindSelection(ctx, r.scope, old)
	legacy := "mref:0:1:Z2VtaW5pLTMtZmxhc2g"
	c.APIKey = "rotated"
	out, e = s.Sync(ctx, r.scope, []dom.Config{c})
	if e != nil || out[0].ID != old {
		t.Fatal("rotation changed stable selection")
	}
	if _, e = s.Resolve(ctx, r.scope, bound); e == nil {
		t.Fatal("old binding accepted")
	}
	if _, e = s.Resolve(ctx, r.scope, legacy); e == nil {
		t.Fatal("legacy running reference upgraded")
	}
	if _, e = s.BindSelection(ctx, r.scope, legacy); e != nil {
		t.Fatal("legacy new selection rejected", e)
	}
	c.Enabled = false
	if _, e = s.Sync(ctx, r.scope, []dom.Config{c}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Resolve(ctx, r.scope, out[0].ID); e == nil {
		t.Fatal("disabled source accepted")
	}
}

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestProxyTokenBindsRunModelAndCredentials(t *testing.T) {
	s, r, c := fixture(t)
	c.CatalogID = "beebridge"
	items, e := s.Sync(context.Background(), r.scope, []dom.Config{c})
	if e != nil {
		t.Fatal(e)
	}
	calls := 0
	s.memberClient = &http.Client{Transport: transport(func(req *http.Request) (*http.Response, error) {
		calls++
		raw, _ := io.ReadAll(req.Body)
		if !strings.Contains(string(raw), `"model":"gemini-3-flash"`) || req.Header.Get("Authorization") != "Bearer member-key" || req.URL.String() != "https://member.example/v1/chat/completions" {
			t.Fatal("wrong upstream route")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("ok")), Header: http.Header{}}, nil
	})}
	b, e := s.Mint(context.Background(), r.scope, 4, "message", items[0].ID)
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(b.APIKey, "member-key") {
		t.Fatal("vendor key exposed")
	}
	body := json.RawMessage(`{"model":"gemini-3-flash","messages":[]}`)
	resp, e := s.ProxyToken(context.Background(), b.APIKey, "chat/completions", body)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if _, e = s.ProxyToken(context.Background(), b.APIKey, "messages", body); e == nil {
		t.Fatal("protocol substitution")
	}
	if _, e = s.ProxyToken(context.Background(), b.APIKey, "chat/completions", json.RawMessage(`{"model":"other"}`)); e == nil {
		t.Fatal("model substitution")
	}
	r.active = false
	if _, e = s.ProxyToken(context.Background(), b.APIKey, "chat/completions", body); e == nil {
		t.Fatal("completed run token accepted")
	}
	if calls != 1 {
		t.Fatal("denied call reached upstream")
	}
}
func TestRejectUnsafeConfigAndGoogleCompatibility(t *testing.T) {
	s, r, c := fixture(t)
	c.Headers = map[string]string{"Host": "internal"}
	if _, e := s.Sync(context.Background(), r.scope, []dom.Config{c}); e == nil {
		t.Fatal("unsafe header")
	}
	c.Headers = nil
	c.Protocol = "google-generative-ai"
	c.BaseURL = "https://generativelanguage.googleapis.com/v1beta"
	out, e := s.Sync(context.Background(), r.scope, []dom.Config{c})
	if e != nil {
		t.Fatal(e)
	}
	route, e := s.Resolve(context.Background(), r.scope, out[0].ID)
	if e != nil || route.Protocol != "openai-compatible" || route.BaseURL != "https://generativelanguage.googleapis.com/v1beta/openai" {
		t.Fatal("google compatibility")
	}
	c.Protocol = "custom"
	if _, e = s.Sync(context.Background(), r.scope, []dom.Config{c}); e == nil {
		t.Fatal("unknown protocol silently accepted")
	}
}

func TestAnthropicSDKPathUsesSelectedKey(t *testing.T) {
	s, r, c := fixture(t)
	c.Protocol = "anthropic-messages"
	c.BaseURL = "https://1.1.1.1"
	c.Models = []dom.Model{{ID: "claude-test", Enabled: true}}
	items, e := s.Sync(context.Background(), r.scope, []dom.Config{c})
	if e != nil {
		t.Fatal(e)
	}
	s.client = &http.Client{Transport: transport(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/v1/messages" || req.Header.Get("x-api-key") != "vendor-secret" || req.Header.Get("anthropic-version") == "" {
			t.Fatal("incorrect Anthropic route")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("ok")), Header: http.Header{}}, nil
	})}
	b, e := s.Mint(context.Background(), r.scope, 4, "message", items[0].ID)
	if e != nil {
		t.Fatal(e)
	}
	resp, e := s.ProxyToken(context.Background(), b.APIKey, "v1/messages", json.RawMessage(`{"model":"claude-test","messages":[]}`))
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
}

func TestCatalogRefreshPreservesSelectionAndRunningToken(t *testing.T) {
	s, r, c := fixture(t)
	ctx := context.Background()
	c.CatalogID = "beebridge"
	items, err := s.Sync(ctx, r.scope, []dom.Config{c})
	if err != nil {
		t.Fatal(err)
	}
	stable := items[0].ID
	bound, err := s.BindSelection(ctx, r.scope, stable)
	if err != nil {
		t.Fatal(err)
	}
	token, err := s.Mint(ctx, r.scope, 4, "message", stable)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	s.memberClient = &http.Client{Transport: transport(func(req *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("ok")), Header: http.Header{}}, nil
	})}
	// Display/other-model changes advance the catalog version, not this run.
	c.Models[0].Label = "新名称"
	c.Models = append([]dom.Model{{ID: "new-model", Enabled: true}}, c.Models...)
	next, err := s.Sync(ctx, r.scope, []dom.Config{c})
	if err != nil {
		t.Fatal(err)
	}
	if next[1].ID != stable || r.rows[0].Version < 2 {
		t.Fatal("fixture did not preserve identity across revision")
	}
	if _, err = s.Resolve(ctx, r.scope, bound); err != nil {
		t.Fatal("unrelated catalog update revoked run", err)
	}
	resp, err := s.ProxyToken(ctx, token.APIKey, "chat/completions", json.RawMessage(`{"model":"gemini-3-flash","messages":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	// Removing the selected model invalidates both cached new sends and active calls.
	c.Models = c.Models[:1]
	if _, err = s.Sync(ctx, r.scope, []dom.Config{c}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.BindSelection(ctx, r.scope, stable); err == nil {
		t.Fatal("removed selection accepted")
	}
	if _, err = s.ProxyToken(ctx, token.APIKey, "chat/completions", json.RawMessage(`{"model":"gemini-3-flash"}`)); err == nil {
		t.Fatal("removed model run accepted")
	}
	if calls != 1 {
		t.Fatal("rejected call reached upstream")
	}
}

func TestExecutionBindingRejectsRouteChangesButKeepsIdentity(t *testing.T) {
	for _, change := range []string{"key", "endpoint", "protocol", "headers", "tools"} {
		t.Run(change, func(t *testing.T) {
			s, r, c := fixture(t)
			ctx := context.Background()
			options, _ := s.Sync(ctx, r.scope, []dom.Config{c})
			bound, err := s.BindSelection(ctx, r.scope, options[0].ID)
			if err != nil {
				t.Fatal(err)
			}
			token, err := s.Mint(ctx, r.scope, 4, "message", options[0].ID)
			if err != nil {
				t.Fatal(err)
			}
			switch change {
			case "key":
				c.APIKey = "rotated"
			case "endpoint":
				c.BaseURL = "https://new.example/v1"
			case "protocol":
				c.Protocol = "anthropic-messages"
			case "headers":
				c.Headers = map[string]string{"X-Route": "other"}
			case "tools":
				c.Models[0].ToolUse = true
			}
			next, err := s.Sync(ctx, r.scope, []dom.Config{c})
			if err != nil || next[0].ID != options[0].ID {
				t.Fatal("selection changed", err)
			}
			if _, err = s.Resolve(ctx, r.scope, bound); err == nil {
				t.Fatal("old bound route accepted")
			}
			if _, err = s.ProxyToken(ctx, token.APIKey, "chat/completions", json.RawMessage(`{"model":"gemini-3-flash"}`)); err == nil {
				t.Fatal("old cloud ticket accepted")
			}
			if _, err = s.BindSelection(ctx, r.scope, options[0].ID); err != nil {
				t.Fatal("new task cannot use new config", err)
			}
		})
	}
}

func (r *memoryRepo) Reconcile(_ context.Context, scope dom.Scope, transform func([]dom.Stored) ([]dom.Stored, error)) ([]dom.Stored, error) {
	if scope != r.scope {
		return nil, dom.ErrDenied
	}
	changes, err := transform(append([]dom.Stored(nil), r.rows...))
	if err != nil {
		return nil, err
	}
	for _, change := range changes {
		for i := range r.rows {
			if r.rows[i].UUID == change.UUID {
				change.Version = r.rows[i].Version + 1
				r.rows[i] = change
				break
			}
		}
	}
	return r.rows, nil
}
