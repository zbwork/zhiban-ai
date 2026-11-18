package external

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	pkgjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/keys"
)

func TestOAuthAuthorizationCodeGrantReturnsTopLevelTokenFields(t *testing.T) {
	mux := http.NewServeMux()
	appSvc := &oauthTokenResponseAppStub{}
	keyMgr := newOAuthTokenResponseKeyManager(t)
	(&Handlers{
		App:         appSvc,
		JWTSigner:   pkgjwt.NewSigner(keyMgr),
		JWTVerifier: pkgjwt.NewVerifier(keyMgr),
		Issuer:      "https://zhiban.test",
	}).Register(mux)

	body := []byte(`{
		"grant_type":"authorization_code",
		"code":"ac_test",
		"client_id":"app_test",
		"client_secret":"secret",
		"redirect_uri":"https://example.test/callback"
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/external/v1/oauth/token", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["data"]; ok {
		t.Fatalf("oauth token response must not use business envelope: %s", rr.Body.String())
	}
	if _, ok := got["success"]; ok {
		t.Fatalf("oauth token response must not include success envelope: %s", rr.Body.String())
	}
	for _, key := range []string{"access_token", "id_token", "refresh_token", "token_type", "expires_in", "scope"} {
		if _, ok := got[key]; !ok {
			t.Fatalf("missing top-level %s in body=%s", key, rr.Body.String())
		}
	}
	if got["token_type"] != "Bearer" {
		t.Fatalf("token_type=%v", got["token_type"])
	}
	if appSvc.consumedCode != "ac_test" || appSvc.consumedRedirectURI != "https://example.test/callback" {
		t.Fatalf("code consume mismatch: code=%q redirect=%q", appSvc.consumedCode, appSvc.consumedRedirectURI)
	}
	if appSvc.claimsConversationID == nil || *appSvc.claimsConversationID != 88 {
		t.Fatalf("claims conversation id=%v, want 88", appSvc.claimsConversationID)
	}
	parts := strings.Split(got["id_token"].(string), ".")
	if len(parts) != 3 {
		t.Fatalf("invalid id_token shape")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	contextClaim := claims["zhiban_context"].(map[string]any)
	peer := contextClaim["peer"].(map[string]any)
	if peer["name"] != "研发工程师" {
		t.Fatalf("peer name=%v", peer["name"])
	}
	if claims["email_verified"] != true {
		t.Fatalf("email_verified=%v, want true", claims["email_verified"])
	}
	if _, ok := claims["auth_time"]; ok {
		t.Fatalf("auth_time must not be emitted: %v", claims["auth_time"])
	}
}

func TestOAuthAuthorizationCodeGrantAcceptsFormEncodedRequest(t *testing.T) {
	mux := http.NewServeMux()
	appSvc := &oauthTokenResponseAppStub{}
	keyMgr := newOAuthTokenResponseKeyManager(t)
	(&Handlers{
		App:         appSvc,
		JWTSigner:   pkgjwt.NewSigner(keyMgr),
		JWTVerifier: pkgjwt.NewVerifier(keyMgr),
		Issuer:      "https://zhiban.test",
	}).Register(mux)

	body := strings.NewReader("grant_type=authorization_code&code=ac_form&client_id=app_form&client_secret=secret&redirect_uri=https%3A%2F%2Fexample.test%2Fcallback")
	req := httptest.NewRequest(http.MethodPost, "/api/external/v1/oauth/token", body)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if appSvc.consumedCode != "ac_form" || appSvc.consumedRedirectURI != "https://example.test/callback" {
		t.Fatalf("form request mismatch: code=%q redirect=%q", appSvc.consumedCode, appSvc.consumedRedirectURI)
	}
}

func TestOAuthRuntimeAccessRequestAcceptsNumericTenantID(t *testing.T) {
	var req oauthTokenReq
	if err := json.Unmarshal([]byte(`{
		"grant_type":"runtime_access",
		"client_id":"agentsdk_platform",
		"client_secret":"secret",
		"tenant_id":617
	}`), &req); err != nil {
		t.Fatal(err)
	}
	if got := req.TenantID.String(); got != "617" {
		t.Fatalf("tenant_id=%q, want 617", got)
	}
}

func TestOAuthRuntimeAccessRequestRejectsRemovedIdentifiers(t *testing.T) {
	var canonical oauthTokenReq
	if err := decodeStrictJSON(strings.NewReader(`{
		"grant_type":"runtime_access",
		"tenant_id":"617",
		"agent_id":"agent-id",
		"account_id":"account-id"
	}`), &canonical); err != nil {
		t.Fatal(err)
	}
	if canonical.AgentID != "agent-id" || canonical.AccountID != "account-id" {
		t.Fatalf("canonical identifiers not decoded: %+v", canonical)
	}
	var legacy oauthTokenReq
	if err := decodeStrictJSON(strings.NewReader(`{"grant_type":"runtime_access","tenant_id":"617","agent_uuid":"agent-id"}`), &legacy); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("removed agent_uuid must be rejected, got %v", err)
	}
}

type oauthTokenResponseAppStub struct {
	consumedCode         string
	consumedRedirectURI  string
	claimsConversationID *int64
}

func (s *oauthTokenResponseAppStub) CreateApp(context.Context, int64, int64, domapp.CreateAppInput) (*domapp.CreatedAppResult, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) GetApp(context.Context, int64, string) (*domapp.App, *domapp.OAuthClient, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) ListApps(context.Context, int64, domapp.AppListFilter) ([]domapp.App, int64, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) PatchApp(context.Context, int64, int64, string, map[string]any) (*domapp.App, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) DeleteApp(context.Context, int64, int64, string) error {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) RotateSecret(context.Context, int64, int64, string) (string, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) SetUniversal(context.Context, int64, string, bool, int) error {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) SetEnabled(context.Context, int64, string, bool) error {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) BindAgentApps(context.Context, int64, int64, []string) error {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) ListAgentApps(context.Context, int64, int64) ([]domapp.App, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) ListCategories(context.Context, int64, int, int) ([]domapp.Category, int64, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) CreateCategory(context.Context, int64, string, string, int) (*domapp.Category, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) PatchCategory(context.Context, int64, string, map[string]any) (*domapp.Category, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) DeleteCategory(context.Context, int64, string) error {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) ListConversationApps(context.Context, domapp.ConversationAppListInput) ([]domapp.ConversationAppItem, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) Launch(context.Context, domapp.LaunchInput) (*domapp.LaunchResult, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) ConsumeAuthorizationCode(_ context.Context, code, redirectURI string, oauthClientID int64) (*domapp.OAuthCode, error) {
	s.consumedCode = code
	s.consumedRedirectURI = redirectURI
	conversationID := int64(88)
	return &domapp.OAuthCode{
		OAuthClientID:  oauthClientID,
		TenantID:       42,
		AccountID:      7,
		RedirectURI:    redirectURI,
		Scopes:         []string{"openid", "profile"},
		Nonce:          "nonce-1",
		ConversationID: &conversationID,
	}, nil
}
func (s *oauthTokenResponseAppStub) ValidateClientCredentials(context.Context, string, string) (*domapp.OAuthClient, error) {
	return &domapp.OAuthClient{
		ID:                     9,
		ClientID:               "app_test",
		Status:                 "active",
		AccessTokenTTLSeconds:  7200,
		RefreshTokenTTLSeconds: 2592000,
	}, nil
}
func (s *oauthTokenResponseAppStub) IssueRefreshToken(context.Context, int64, int64, int64, []string, time.Duration) (string, error) {
	return "rt_test", nil
}
func (s *oauthTokenResponseAppStub) ConsumeRefreshToken(context.Context, string) (*domapp.RefreshToken, error) {
	panic("not implemented")
}
func (s *oauthTokenResponseAppStub) IDTokenUserClaims(_ context.Context, _ int64, _ int64, conversationID *int64) (*domapp.IDTokenUserClaims, error) {
	s.claimsConversationID = conversationID
	return &domapp.IDTokenUserClaims{
		AccountUUID:      "acc_test",
		Email:            "alice@example.test",
		EmailVerified:    true,
		Name:             "Alice",
		TenantUUID:       "tenant_test",
		TenantName:       "Test Tenant",
		ConversationID:   "conv_test",
		ConversationKind: "agent_chat",
		PeerKind:         "agent",
		PeerUUID:         "agent_test",
		PeerName:         "研发工程师",
	}, nil
}

type oauthTokenResponseKeyManager struct {
	mu     sync.Mutex
	active *keys.SigningKey
}

func newOAuthTokenResponseKeyManager(t *testing.T) *oauthTokenResponseKeyManager {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return &oauthTokenResponseKeyManager{active: &keys.SigningKey{
		ID:         1,
		Kid:        "k-test-token-response",
		Algorithm:  keys.AlgRS256,
		Status:     keys.StatusActive,
		PrivateKey: priv,
		PublicJWK: map[string]any{
			"kty": "RSA",
			"use": "sig",
			"alg": "RS256",
			"kid": "k-test-token-response",
			"n":   base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
			"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
		},
	}}
}

func (m *oauthTokenResponseKeyManager) ActiveSigner(context.Context) (*keys.SigningKey, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.active, nil
}
func (m *oauthTokenResponseKeyManager) VerifierByKid(context.Context, string) (*keys.SigningKey, error) {
	return m.active, nil
}
func (m *oauthTokenResponseKeyManager) JWKSKeys(context.Context) ([]map[string]any, error) {
	return []map[string]any{m.active.PublicJWK}, nil
}
func (m *oauthTokenResponseKeyManager) Refresh(context.Context) error           { return nil }
func (m *oauthTokenResponseKeyManager) Bootstrap(context.Context) (bool, error) { return false, nil }
func (m *oauthTokenResponseKeyManager) Rotate(context.Context) (string, error)  { return "", nil }
