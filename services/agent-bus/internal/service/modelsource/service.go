package modelsource

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	bee "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/beebridge"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto/aesgcm"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	runtime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
)

type MemberKeys interface {
	ModelKey(context.Context, int64, int64) (string, error)
}
type Service struct {
	repo                  dom.Repository
	cipher                *aesgcm.Cipher
	keys                  MemberKeys
	secret                []byte
	memberBase, proxyBase string
	guard                 *runtime.SSRFGuard
	client, memberClient  *http.Client
	// unmanagedBeeBridge treats the BeeBridge catalog entry as an ordinary member
	// platform with the member's own address and key (deployments without managed keys).
	unmanagedBeeBridge bool
}

const managedBeeBridgeSourceID = "managed:beebridge"

// WithoutManagedBeeBridge is for deployments with no managed member keys: BeeBridge
// keeps the address and key the member entered and goes through the SSRF-guarded client.
func (s *Service) WithoutManagedBeeBridge() *Service {
	s.unmanagedBeeBridge = true
	return s
}

func New(repo dom.Repository, cipher *aesgcm.Cipher, keys MemberKeys, secret []byte, memberBase, proxyBase string) *Service {
	guard := &runtime.SSRFGuard{}
	transport := guard.SafeHTTPSModelTransport()
	transport.ResponseHeaderTimeout = 30 * time.Second
	noRedirect := func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Service{repo: repo, cipher: cipher, keys: keys, secret: secret, memberBase: memberBase, proxyBase: strings.TrimRight(proxyBase, "/") + "/api/agent-bus/v1/runtime-model-proxy/v1", guard: guard,
		client: &http.Client{Transport: transport, CheckRedirect: noRedirect}, memberClient: &http.Client{Timeout: 30 * time.Minute, CheckRedirect: noRedirect}}
}

type Option struct {
	ID           string `json:"id"`
	Label        string `json:"label"`
	ModelID      string `json:"model_id"`
	ProviderID   string `json:"provider_id"`
	ProviderName string `json:"provider_name"`
	SourceID     string `json:"source_id"`
	Default      bool   `json:"default"`
}

// Selection identity is independent of catalog revision. Bound references are
// internal execution snapshots; legacy versioned references remain strict there.
func IsReference(id string) bool {
	return dom.IsReference(id)
}
func reference(s dom.Stored, model string) string {
	return "msel:" + s.UUID + ":" + base64.RawURLEncoding.EncodeToString([]byte(model))
}
func SelectionReference(ref string) string {
	p := strings.Split(ref, ":")
	if len(p) == 4 && (p[0] == "mref" || p[0] == "mbnd") {
		if p[0] == "mref" {
			if v, e := strconv.ParseInt(p[2], 10, 64); e != nil || v < 1 {
				return ref
			}
		}
		return "msel:" + p[1] + ":" + p[3]
	}
	return ref
}

// BindSelection is only for preparing NEW work, never for validating a run.
func (s *Service) BindSelection(ctx context.Context, scope dom.Scope, ref string) (string, error) {
	ref = SelectionReference(ref)
	route, err := s.Resolve(ctx, scope, ref)
	if err != nil {
		return "", err
	}
	p := strings.Split(route.Selection, ":")
	if len(p) != 3 || p[0] != "msel" {
		return "", dom.ErrDenied
	}
	return "mbnd:" + p[1] + ":" + route.Fingerprint + ":" + p[2], nil
}
func (s *Service) mac(raw []byte) []byte {
	m := hmac.New(sha256.New, s.secret)
	m.Write(raw)
	return m.Sum(nil)
}
func chatModel(m dom.Model) bool {
	name := strings.ToLower(m.ID)
	for _, part := range strings.FieldsFunc(name, func(r rune) bool { return r == '/' || r == '-' || r == '_' || r == '.' }) {
		switch part {
		case "image", "images", "flux", "dall", "sdxl", "stable", "video", "wan", "sora", "audio", "speech", "sensevoice", "cosyvoice":
			return false
		}
	}
	switch m.Modality {
	case "embedding", "rerank", "reranking", "image", "audio", "video", "moderation":
		return false
	}
	return m.Enabled && (bee.Model{ID: m.ID}).SupportsChat()
}
func (s *Service) Sync(ctx context.Context, scope dom.Scope, configs []dom.Config, partial ...bool) ([]Option, error) {
	if s.cipher == nil || len(s.secret) < 32 || len(configs) > 100 {
		logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "service_config", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "provider_count", len(configs))
		return nil, dom.ErrDenied
	}
	seen := map[string]bool{}
	managedBeeBridge := false
	values := []dom.Stored{}
	for _, c := range configs {
		if c.ID == "" || len(c.ID) > 128 || seen[c.ID] || len(c.Name) > 100 || len(c.Models) > 2000 || len(c.APIKey) > 16384 {
			logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "provider_shape", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "source_id_present", c.ID != "", "catalog_id", c.CatalogID, "model_count", len(c.Models), "api_key_length", len(c.APIKey))
			return nil, dom.ErrDenied
		}
		seen[c.ID] = true
		if c.CatalogID == "beebridge" && !s.unmanagedBeeBridge {
			if managedBeeBridge {
				return nil, dom.ErrDenied
			}
			managedBeeBridge = true
			c.ID = managedBeeBridgeSourceID
			seen[c.ID] = true
			c.APIKey = ""
			c.Headers = nil
			c.BaseURL = s.memberBase
			c.Protocol = "openai-compatible"
			c.Name = "BeeBridge"
		}
		// Google officially offers the same chat-completions contract. Custom
		// native endpoints are not guessed into a compatible route.
		if c.Protocol == "google-generative-ai" {
			u, e := url.Parse(c.BaseURL)
			if e == nil && u.Hostname() == "generativelanguage.googleapis.com" {
				u.Path = "/v1beta/openai"
				c.BaseURL = u.String()
				c.Protocol = "openai-compatible"
			}
		}
		for k, v := range c.Headers {
			if !validHeader(k, v) {
				logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "header", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "catalog_id", c.CatalogID, "header_name", k)
				return nil, dom.ErrDenied
			}
		}
		if c.Enabled && c.Protocol != "openai-compatible" && c.Protocol != "anthropic-messages" {
			logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "protocol", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "catalog_id", c.CatalogID, "protocol", c.Protocol)
			return nil, dom.ErrDenied
		}
		u, err := url.Parse(c.BaseURL)
		if c.Enabled && (err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "https" && u.Scheme != "http")) {
			logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "base_url", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "catalog_id", c.CatalogID, "enabled", c.Enabled, "parse_error", err != nil, "has_host", u.Host != "")
			return nil, dom.ErrDenied
		}
		ids := map[string]bool{}
		for _, m := range c.Models {
			if strings.TrimSpace(m.ID) == "" || len(m.ID) > 256 || len(m.Label) > 256 || ids[m.ID] {
				logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "model_shape", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "catalog_id", c.CatalogID, "model_count", len(c.Models), "model_id_present", strings.TrimSpace(m.ID) != "")
				return nil, dom.ErrDenied
			}
			ids[m.ID] = true
		}
		raw, _ := json.Marshal(struct {
			Scope  dom.Scope
			Config dom.Config
		}{scope, c})
		ciphertext, err := s.cipher.Encrypt(raw)
		if err != nil {
			logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "encrypt", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "catalog_id", c.CatalogID)
			return nil, dom.ErrDenied
		}
		values = append(values, dom.Stored{SourceID: c.ID, Fingerprint: hex.EncodeToString(s.mac(raw)), Enabled: c.Enabled, Ciphertext: ciphertext})
	}
	if managedBeeBridge {
		if existing, e := s.repo.List(ctx, scope); e == nil {
			for _, old := range existing {
				if old.SourceID == managedBeeBridgeSourceID || !old.Enabled {
					continue
				}
				cfg, e := s.decode(scope, old)
				if e == nil && cfg.CatalogID == "beebridge" {
					old.Enabled = false
					values = append(values, old)
				}
			}
		}
	}
	var rows []dom.Stored
	var err error
	if len(partial) > 0 && partial[0] {
		merger, ok := s.repo.(interface {
			Merge(context.Context, dom.Scope, []dom.Stored) ([]dom.Stored, error)
		})
		if !ok {
			logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "repository_merge", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "provider_count", len(values))
			return nil, dom.ErrDenied
		}
		rows, err = merger.Merge(ctx, scope, values)
	} else {
		rows, err = s.repo.Replace(ctx, scope, values)
	}
	if err != nil {
		logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "repository_write", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "provider_count", len(values), "error", err.Error())
		return nil, err
	}
	options, err := s.options(scope, rows)
	if err != nil {
		logpkg.Default().Warn(ctx, "model_sources.sync_rejected", "stage", "options", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "row_count", len(rows), "error", err.Error())
		return nil, err
	}
	logpkg.Default().Info(ctx, "model_sources.sync_succeeded", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "provider_count", len(values), "row_count", len(rows), "option_count", len(options))
	return options, nil
}
func (s *Service) decode(scope dom.Scope, row dom.Stored) (dom.Config, error) {
	var envelope struct {
		Scope  dom.Scope
		Config dom.Config
	}
	if s.cipher == nil {
		return envelope.Config, dom.ErrDenied
	}
	raw, err := s.cipher.Decrypt(row.Ciphertext)
	if err != nil || json.Unmarshal(raw, &envelope) != nil || envelope.Scope != scope {
		return dom.Config{}, dom.ErrDenied
	}
	return envelope.Config, nil
}
func (s *Service) options(scope dom.Scope, rows []dom.Stored) ([]Option, error) {
	out := []Option{}
	for _, row := range rows {
		if !row.Enabled {
			continue
		}
		c, err := s.decode(scope, row)
		if err != nil {
			return nil, err
		}
		for _, m := range c.Models {
			if chatModel(m) {
				label := m.Label
				if label == "" {
					label = m.ID
				}
				out = append(out, Option{ID: reference(row, m.ID), Label: label, ModelID: m.ID, ProviderID: c.CatalogID, ProviderName: c.Name, SourceID: c.ID, Default: len(out) == 0})
			}
		}
	}
	return out, nil
}
func (s *Service) List(ctx context.Context, scope dom.Scope) ([]Option, bool, error) {
	rows, err := s.reconcileManaged(ctx, scope)
	if err != nil {
		return nil, false, err
	}
	o, e := s.options(scope, rows)
	return o, len(rows) > 0, e
}

type Route struct {
	Selection                                                    string
	ModelID, Protocol, BaseURL, APIKey, ProviderID, ProviderName string
	Fingerprint                                                  string
	ToolUse                                                      bool
	Headers                                                      map[string]string
}

func (s *Service) Resolve(ctx context.Context, scope dom.Scope, ref string) (Route, error) {
	deny := func() (Route, error) { return Route{}, dom.ErrDenied }
	parts := strings.Split(ref, ":")
	version := int64(0)
	bound := ""
	var encoded string
	switch {
	case len(parts) == 3 && parts[0] == "msel":
		encoded = parts[2]
	case len(parts) == 4 && parts[0] == "mref":
		var err error
		version, err = strconv.ParseInt(parts[2], 10, 64)
		if err != nil || version < 1 {
			return deny()
		}
		encoded = parts[3]
	case len(parts) == 4 && parts[0] == "mbnd":
		if len(parts[2]) != 64 {
			return deny()
		}
		bound, encoded = parts[2], parts[3]
	default:
		return deny()
	}
	model, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(model) == 0 {
		return deny()
	}
	if parts[0] == "msel" {
		if _, err := s.reconcileManaged(ctx, scope); err != nil {
			return Route{}, err
		}
	}
	row, err := s.repo.Get(ctx, scope, parts[1])
	if (err != nil || row == nil || !row.Enabled) && len(parts) == 3 && parts[0] == "msel" && !s.unmanagedBeeBridge {
		row, parts[1], err = s.resolveLegacyManagedSelection(ctx, scope, parts[1], string(model))
	}
	if err != nil || row == nil || !row.Enabled || (version != 0 && row.Version != version) {
		return deny()
	}
	c, err := s.decode(scope, *row)
	if err != nil {
		return Route{}, dom.ErrConfiguration
	}
	found := false
	toolUse := false
	for _, m := range c.Models {
		if m.ID == string(model) && chatModel(m) {
			found = true
			toolUse = m.ToolUse
			break
		}
	}
	if !found {
		return deny()
	}
	if c.CatalogID == "beebridge" && !s.unmanagedBeeBridge {
		if s.keys == nil {
			return Route{}, dom.ErrConfiguration
		}
		c.APIKey, err = s.keys.ModelKey(ctx, scope.TenantID, scope.AccountID)
		if err != nil {
			return Route{}, dom.ErrConfiguration
		}
		c.BaseURL = s.memberBase
	}
	if c.APIKey == "" || strings.TrimSpace(c.BaseURL) == "" {
		return Route{}, dom.ErrConfiguration
	}
	if c.CatalogID == "beebridge" && !s.unmanagedBeeBridge {
		c.Protocol = bee.ChatProtocol(string(model))
	}
	// Only fields affecting this model's execution participate. JSON sorts map
	// keys, so header iteration and unrelated model ordering do not revoke a run.
	raw, _ := json.Marshal([]any{"model-route-v1", scope, row.UUID, string(model), c.Protocol, c.BaseURL, c.APIKey, c.Headers, toolUse, c.CatalogID})
	fingerprint := hex.EncodeToString(s.mac(raw))
	if bound != "" && !hmac.Equal([]byte(bound), []byte(fingerprint)) {
		return deny()
	}
	return Route{Selection: reference(*row, string(model)), ModelID: string(model), Protocol: c.Protocol, BaseURL: c.BaseURL, APIKey: c.APIKey, ProviderID: c.CatalogID, ProviderName: c.Name, Headers: c.Headers, ToolUse: toolUse, Fingerprint: fingerprint}, nil
}

func (s *Service) resolveLegacyManagedSelection(ctx context.Context, scope dom.Scope, oldUUID, model string) (*dom.Stored, string, error) {
	rows, err := s.repo.List(ctx, scope)
	if err != nil {
		return nil, oldUUID, err
	}
	oldManaged := false
	for _, row := range rows {
		if row.UUID != oldUUID || row.SourceID == managedBeeBridgeSourceID {
			continue
		}
		cfg, e := s.decode(scope, row)
		if e != nil || cfg.CatalogID != "beebridge" {
			return nil, oldUUID, dom.ErrDenied
		}
		for _, m := range cfg.Models {
			if m.ID == model {
				oldManaged = true
				break
			}
		}
		break
	}
	if !oldManaged {
		return nil, oldUUID, dom.ErrDenied
	}
	for i := range rows {
		if rows[i].SourceID == managedBeeBridgeSourceID && rows[i].Enabled {
			return &rows[i], rows[i].UUID, nil
		}
	}
	return nil, oldUUID, dom.ErrDenied
}

// RuntimeBinding contains only a run-scoped proxy credential, never a provider key.
type RuntimeBinding = dom.RuntimeBinding
type tokenClaims struct {
	Scope              dom.Scope
	Agent              int64
	Message, Reference string
	Expires            int64
}

func (s *Service) Mint(ctx context.Context, scope dom.Scope, agent int64, message, ref string) (*RuntimeBinding, error) {
	var err error
	ref, err = s.BindSelection(ctx, scope, ref)
	if err != nil {
		return nil, err
	}
	route, err := s.Resolve(ctx, scope, ref)
	if err != nil {
		return nil, err
	}
	if agent <= 0 || message == "" || !strings.HasPrefix(s.proxyBase, "http") {
		return nil, dom.ErrDenied
	}
	raw, _ := json.Marshal(tokenClaims{scope, agent, message, ref, time.Now().Add(6 * time.Hour).Unix()})
	token := "ms1." + base64.RawURLEncoding.EncodeToString(raw) + "." + base64.RawURLEncoding.EncodeToString(s.mac(raw))
	return &RuntimeBinding{Model: route.ModelID, Protocol: route.Protocol, BaseURL: s.proxyBase, APIKey: token, ProviderID: route.ProviderID}, nil
}
func (s *Service) ProxyToken(ctx context.Context, token, protocol string, body json.RawMessage) (*http.Response, error) {
	p := strings.Split(token, ".")
	if len(p) != 3 || p[0] != "ms1" || len(token) > 4096 {
		return nil, &proxyFailure{kind: "authorization", cause: dom.ErrDenied}
	}
	raw, e := base64.RawURLEncoding.DecodeString(p[1])
	sig, e2 := base64.RawURLEncoding.DecodeString(p[2])
	var c tokenClaims
	if e != nil || e2 != nil || !hmac.Equal(s.mac(raw), sig) || json.Unmarshal(raw, &c) != nil || c.Expires <= time.Now().Unix() {
		return nil, &proxyFailure{kind: "authorization", cause: dom.ErrDenied}
	}
	active, err := s.repo.RunActive(ctx, c.Scope, c.Agent, c.Message)
	if err != nil {
		return nil, &proxyFailure{kind: "run_check", cause: dom.ErrDenied}
	}
	if !active {
		return nil, &proxyFailure{kind: "run_inactive", cause: dom.ErrDenied}
	}
	resp, err := s.Proxy(ctx, c.Scope, c.Reference, protocol, body)
	if errors.Is(err, dom.ErrDenied) {
		return nil, &proxyFailure{kind: "binding_unavailable", cause: dom.ErrDenied}
	}
	return resp, err
}
func (s *Service) Proxy(ctx context.Context, scope dom.Scope, ref, protocol string, body json.RawMessage) (*http.Response, error) {
	return s.proxy(ctx, scope, ref, protocol, body, false)
}

// ProxyLocalResponses is only used after the local-run capability and fixed engine were verified.
func (s *Service) ProxyLocalResponses(ctx context.Context, scope dom.Scope, ref string, body json.RawMessage) (*http.Response, error) {
	return s.proxy(ctx, scope, ref, "responses", body, true)
}
func (s *Service) proxy(ctx context.Context, scope dom.Scope, ref, protocol string, body json.RawMessage, localResponses bool) (*http.Response, error) {
	route, err := s.Resolve(ctx, scope, ref)
	if err != nil {
		return nil, err
	}
	expected := "chat/completions"
	if route.Protocol == "anthropic-messages" {
		expected = "messages"
	}
	if route.Protocol == "anthropic-messages" && protocol == "v1/messages" {
		protocol = "messages"
	}
	if localResponses && protocol == "responses" && route.Protocol == "openai-compatible" {
		expected = "responses"
	}
	if protocol != expected {
		return nil, dom.ErrDenied
	}
	var input map[string]json.RawMessage
	if json.Unmarshal(body, &input) != nil {
		return nil, dom.ErrDenied
	}
	var model string
	if json.Unmarshal(input["model"], &model) != nil || (model != route.ModelID && model != ref) {
		return nil, dom.ErrDenied
	}
	input["model"], _ = json.Marshal(route.ModelID)
	raw, _ := json.Marshal(input)
	u, e := url.Parse(route.BaseURL)
	if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, dom.ErrDenied
	}
	u.Path = strings.TrimRight(u.Path, "/")
	if u.Path == "" {
		u.Path = "/v1"
	}
	u.Path += "/" + expected
	client := s.client
	if route.ProviderID == "beebridge" && !s.unmanagedBeeBridge {
		client = s.memberClient
	} else if s.guard.Validate(ctx, u.String()) != nil {
		return nil, dom.ErrDenied
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(raw))
	if err != nil {
		return nil, dom.ErrDenied
	}
	for k, v := range route.Headers {
		req.Header.Set(k, v)
	}
	req.Header.Set("Content-Type", "application/json")
	if expected == "messages" {
		req.Header.Set("x-api-key", route.APIKey)
		req.Header.Set("anthropic-version", "2023-06-01")
	} else {
		req.Header.Set("Authorization", "Bearer "+route.APIKey)
	}
	resp, err := client.Do(req)
	if err != nil {
		kind := "connection"
		var network net.Error
		if errors.As(err, &network) && network.Timeout() {
			kind = "timeout"
		}
		return nil, &TransportError{Kind: kind}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		failureBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		return nil, &UpstreamError{Status: resp.StatusCode, Kind: upstreamFailureKind(failureBody), Reason: upstreamFailureReason(failureBody)}
	}
	return resp, nil
}

// Do not forward an upstream body that may echo credentials or request content.
type UpstreamError struct {
	Status int
	Kind   string
	// Reason is an allowlisted, length-limited provider explanation. It must
	// never contain the raw upstream response because providers may echo keys
	// or user prompts.
	Reason string
}

// Fixed categories only: never include upstream URLs, credentials or bodies.
type TransportError struct{ Kind string }

func (e *TransportError) Error() string { return "model_source.transport_" + e.Kind }

func (e *UpstreamError) Error() string {
	return fmt.Sprintf("model_source.upstream_status_%d", e.Status)
}
func validHeader(k, v string) bool {
	if k == "" || len(k) > 128 || len(v) > 8192 || strings.ContainsAny(v, "\r\n") {
		return false
	}
	for _, ch := range k {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
			return false
		}
	}
	switch strings.ToLower(k) {
	case "host", "content-length", "connection", "transfer-encoding", "cookie", "proxy-authorization", "forwarded", "x-forwarded-for":
		return false
	}
	return true
}
