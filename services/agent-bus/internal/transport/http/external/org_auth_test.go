package external

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	pkgjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
	svcagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agentsdk"
	svcextorg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/externalorg"
)

type orgAuthAPIKeyValidator struct {
	identity *domapikey.Identity
	raw      string
}

func (v *orgAuthAPIKeyValidator) Validate(_ context.Context, raw string) (*domapikey.Identity, error) {
	v.raw = raw
	return v.identity, nil
}

type orgAuthService struct {
	listDepartmentsCalled  int
	createDepartmentCalled int
	lastTenantID           int64
}

func (s *orgAuthService) ListDepartments(_ context.Context, tenantID int64, _ string, _ int, _ *time.Time) (*svcextorg.CursorPage[svcextorg.ExternalDepartment], error) {
	s.listDepartmentsCalled++
	s.lastTenantID = tenantID
	return &svcextorg.CursorPage[svcextorg.ExternalDepartment]{Items: []svcextorg.ExternalDepartment{}}, nil
}

func (*orgAuthService) GetDepartment(context.Context, int64, string) (*svcextorg.ExternalDepartment, error) {
	return &svcextorg.ExternalDepartment{}, nil
}
func (s *orgAuthService) CreateDepartment(context.Context, int64, svcextorg.CreateDepartmentInput) (*svcextorg.ExternalDepartment, error) {
	s.createDepartmentCalled++
	return &svcextorg.ExternalDepartment{}, nil
}
func (*orgAuthService) UpdateDepartment(context.Context, int64, string, svcextorg.UpdateDepartmentInput) (*svcextorg.ExternalDepartment, error) {
	return &svcextorg.ExternalDepartment{}, nil
}
func (*orgAuthService) DeleteDepartment(context.Context, int64, string) error { return nil }
func (*orgAuthService) ListMembers(context.Context, int64, string, int, *time.Time) (*svcextorg.CursorPage[svcextorg.ExternalMember], error) {
	return &svcextorg.CursorPage[svcextorg.ExternalMember]{}, nil
}
func (*orgAuthService) GetMember(context.Context, int64, string) (*svcextorg.ExternalMember, error) {
	return &svcextorg.ExternalMember{}, nil
}
func (*orgAuthService) CreateMember(context.Context, int64, svcextorg.CreateMemberInput) (*svcextorg.ExternalMember, error) {
	return &svcextorg.ExternalMember{}, nil
}
func (*orgAuthService) UpdateMember(context.Context, int64, string, svcextorg.UpdateMemberInput) (*svcextorg.ExternalMember, error) {
	return &svcextorg.ExternalMember{}, nil
}
func (*orgAuthService) DeleteMember(context.Context, int64, string) error { return nil }
func (*orgAuthService) ListPositions(context.Context, int64, string, int, *time.Time) (*svcextorg.CursorPage[svcextorg.ExternalPosition], error) {
	return &svcextorg.CursorPage[svcextorg.ExternalPosition]{}, nil
}
func (*orgAuthService) GetPosition(context.Context, int64, string) (*svcextorg.ExternalPosition, error) {
	return &svcextorg.ExternalPosition{}, nil
}
func (*orgAuthService) CreatePosition(context.Context, int64, svcextorg.CreatePositionInput) (*svcextorg.ExternalPosition, error) {
	return &svcextorg.ExternalPosition{}, nil
}
func (*orgAuthService) UpdatePosition(context.Context, int64, string, svcextorg.UpdatePositionInput) (*svcextorg.ExternalPosition, error) {
	return &svcextorg.ExternalPosition{}, nil
}
func (*orgAuthService) DeletePosition(context.Context, int64, string) error { return nil }

func TestOrgRoutesRequireAPIKeyBearer(t *testing.T) {
	apiKeys := &orgAuthAPIKeyValidator{identity: &domapikey.Identity{
		APIKeyID: 1,
		TenantID: 42,
		Scopes:   []string{domapikey.ScopeTenantOrgRead},
	}}
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{APIKeys: apiKeys, ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer ek_test_secret")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("ek_ API key should reach org handler, got %d body=%s", rr.Code, rr.Body.String())
	}
	if apiKeys.raw != "ek_test_secret" {
		t.Fatalf("validator raw token = %q", apiKeys.raw)
	}
	if orgSvc.listDepartmentsCalled != 1 {
		t.Fatalf("org service should be called once, got %d", orgSvc.listDepartmentsCalled)
	}
}

func TestOrgRoutesRejectSessionTokenBearerWhenAgentSDKDisabled(t *testing.T) {
	apiKeys := &orgAuthAPIKeyValidator{identity: &domapikey.Identity{
		APIKeyID: 1,
		TenantID: 42,
		Scopes:   []string{domapikey.ScopeTenantOrgRead},
	}}
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{APIKeys: apiKeys, ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer st_session_token")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("st_ session token must be rejected, got %d body=%s", rr.Code, rr.Body.String())
	}
	if apiKeys.raw != "" {
		t.Fatalf("API key validator must not see st_ tokens, got %q", apiKeys.raw)
	}
	if orgSvc.listDepartmentsCalled != 0 {
		t.Fatalf("org service must not be called for st_, got %d", orgSvc.listDepartmentsCalled)
	}
}

func TestOrgReadRoutesAcceptSessionTokenBearer(t *testing.T) {
	apiKeys := &orgAuthAPIKeyValidator{identity: &domapikey.Identity{
		APIKeyID: 1,
		TenantID: 42,
		Scopes:   []string{domapikey.ScopeTenantOrgRead},
	}}
	agentSDK := newOrgAuthAgentSDK(t)
	token := issueOrgReadSessionToken(t, agentSDK)
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{APIKeys: apiKeys, AgentSDK: agentSDK, ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("st_ session token with org.read should reach org GET handler, got %d body=%s", rr.Code, rr.Body.String())
	}
	if apiKeys.raw != "" {
		t.Fatalf("API key validator must not see st_ tokens, got %q", apiKeys.raw)
	}
	if orgSvc.listDepartmentsCalled != 1 {
		t.Fatalf("org service should be called once, got %d", orgSvc.listDepartmentsCalled)
	}
}

func TestOrgWriteRoutesRejectSessionTokenBearer(t *testing.T) {
	apiKeys := &orgAuthAPIKeyValidator{identity: &domapikey.Identity{
		APIKeyID: 1,
		TenantID: 42,
		Scopes:   []string{domapikey.ScopeTenantOrgWrite},
	}}
	agentSDK := newOrgAuthAgentSDK(t)
	token := issueOrgReadSessionToken(t, agentSDK)
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{APIKeys: apiKeys, AgentSDK: agentSDK, ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodPost, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("st_ session token must be rejected for org write, got %d body=%s", rr.Code, rr.Body.String())
	}
	if orgSvc.createDepartmentCalled != 0 {
		t.Fatalf("org write service must not be called for st_, got %d", orgSvc.createDepartmentCalled)
	}
}

type orgAuthJWTVerifier struct {
	claims *pkgjwt.AccessTokenClaims
}

func (v *orgAuthJWTVerifier) VerifyAccessToken(context.Context, string, string) (*pkgjwt.AccessTokenClaims, error) {
	return v.claims, nil
}

func TestOrgReadRoutesAcceptAppJWTContactsRead(t *testing.T) {
	jwtVerifier := &orgAuthJWTVerifier{claims: &pkgjwt.AccessTokenClaims{
		Subject: "acc_test", ClientID: "app_test", TenantID: 84, Scopes: []string{"contacts.read"}, Kind: "app_oauth",
	}}
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{JWTVerifier: jwtVerifier, Issuer: "https://issuer.example", ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer eyJapp")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("app JWT with contacts.read should reach org GET handler, got %d body=%s", rr.Code, rr.Body.String())
	}
	if orgSvc.lastTenantID != 84 {
		t.Fatalf("org service tenant=%d, want JWT tenant 84", orgSvc.lastTenantID)
	}
}

func TestOrgReadRoutesRejectAppJWTWithoutContactsRead(t *testing.T) {
	jwtVerifier := &orgAuthJWTVerifier{claims: &pkgjwt.AccessTokenClaims{
		Subject: "acc_test", ClientID: "app_test", TenantID: 84, Scopes: []string{"kb.read"}, Kind: "app_oauth",
	}}
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{JWTVerifier: jwtVerifier, Issuer: "https://issuer.example", ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer eyJapp")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Fatalf("app JWT without contacts.read should be forbidden, got %d body=%s", rr.Code, rr.Body.String())
	}
	if orgSvc.listDepartmentsCalled != 0 {
		t.Fatalf("org service called without contacts.read: %d", orgSvc.listDepartmentsCalled)
	}
}

func TestOrgWriteRoutesRejectAppJWT(t *testing.T) {
	apiKeys := &orgAuthAPIKeyValidator{identity: &domapikey.Identity{
		APIKeyID: 1, TenantID: 42, Scopes: []string{domapikey.ScopeTenantOrgWrite},
	}}
	jwtVerifier := &orgAuthJWTVerifier{claims: &pkgjwt.AccessTokenClaims{
		Subject: "acc_test", ClientID: "app_test", TenantID: 84, Scopes: []string{"contacts.read"}, Kind: "app_oauth",
	}}
	orgSvc := &orgAuthService{}
	mux := http.NewServeMux()
	(&Handlers{APIKeys: apiKeys, JWTVerifier: jwtVerifier, Issuer: "https://issuer.example", ExternalOrg: orgSvc}).Register(mux)

	req := httptest.NewRequest(http.MethodPost, "/api/external/v1/org/departments", nil)
	req.Header.Set("Authorization", "Bearer eyJapp")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("app JWT must be rejected for org writes, got %d body=%s", rr.Code, rr.Body.String())
	}
	if orgSvc.createDepartmentCalled != 0 {
		t.Fatalf("org write service called for app JWT: %d", orgSvc.createDepartmentCalled)
	}
}

func newOrgAuthAgentSDK(t *testing.T) *svcagentsdk.Service {
	t.Helper()
	credRepo := &orgAuthCredentialRepo{byID: map[int64]*domagentsdk.Credential{
		1: {
			ID:                 1,
			TenantID:           42,
			CreatorID:          7,
			Name:               "test",
			ClientID:           "agentsdk_test",
			CapabilityBindings: []string{"org.read", "kb.read"},
			Scope:              domagentsdk.CredentialScopeTenant,
			Status:             "active",
		},
	}}
	return svcagentsdk.New(svcagentsdk.Deps{
		CredRepo:    credRepo,
		SessionRepo: &orgAuthSessionRepo{byID: map[int64]*domagentsdk.SessionToken{}, byPrefix: map[string]*domagentsdk.SessionToken{}},
		Now:         func() time.Time { return time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC) },
	})
}

func issueOrgReadSessionToken(t *testing.T, svc *svcagentsdk.Service) string {
	t.Helper()
	_, token, err := svc.IssueSessionToken(context.Background(), 1, nil, nil, []string{"org.read"}, time.Hour)
	if err != nil {
		t.Fatalf("issue session token: %v", err)
	}
	return token
}

type orgAuthCredentialRepo struct {
	byID map[int64]*domagentsdk.Credential
}

func (r *orgAuthCredentialRepo) Insert(context.Context, *domagentsdk.Credential) error { return nil }
func (r *orgAuthCredentialRepo) SetTenantGrants(context.Context, int64, string, []int64) error {
	return nil
}
func (r *orgAuthCredentialRepo) FindByClientID(context.Context, string) (*domagentsdk.Credential, error) {
	return nil, errors.New("not found")
}
func (r *orgAuthCredentialRepo) GetByUUID(context.Context, int64, string) (*domagentsdk.Credential, error) {
	return nil, errors.New("not found")
}
func (r *orgAuthCredentialRepo) GetPlatformByUUID(context.Context, string) (*domagentsdk.Credential, error) {
	return nil, errors.New("not found")
}
func (r *orgAuthCredentialRepo) GetByID(_ context.Context, id int64) (*domagentsdk.Credential, error) {
	if c, ok := r.byID[id]; ok {
		cp := *c
		return &cp, nil
	}
	return nil, errors.New("not found")
}
func (r *orgAuthCredentialRepo) ListByTenant(context.Context, int64) ([]domagentsdk.Credential, error) {
	return nil, nil
}
func (r *orgAuthCredentialRepo) ListPlatform(context.Context) ([]domagentsdk.Credential, error) {
	return nil, nil
}
func (r *orgAuthCredentialRepo) IsTenantAllowedForPlatformCredential(context.Context, int64, int64) (bool, string, error) {
	return false, "", nil
}
func (r *orgAuthCredentialRepo) Patch(context.Context, int64, string, map[string]any) (*domagentsdk.Credential, error) {
	return nil, errors.New("not found")
}
func (r *orgAuthCredentialRepo) Revoke(context.Context, int64, string) error           { return nil }
func (r *orgAuthCredentialRepo) RevokePlatform(context.Context, string) error          { return nil }
func (r *orgAuthCredentialRepo) TouchLastUsed(context.Context, int64, time.Time) error { return nil }

type orgAuthSessionRepo struct {
	nextID   int64
	byID     map[int64]*domagentsdk.SessionToken
	byPrefix map[string]*domagentsdk.SessionToken
}

func (r *orgAuthSessionRepo) Insert(_ context.Context, s *domagentsdk.SessionToken) error {
	r.nextID++
	cp := *s
	cp.ID = r.nextID
	cp.UUID = "session-token-uuid"
	r.byID[cp.ID] = &cp
	r.byPrefix[cp.TokenPrefix] = &cp
	s.ID = cp.ID
	s.UUID = cp.UUID
	return nil
}
func (r *orgAuthSessionRepo) FindByPrefix(_ context.Context, prefix string) (*domagentsdk.SessionToken, error) {
	if s, ok := r.byPrefix[prefix]; ok {
		cp := *s
		return &cp, nil
	}
	return nil, errors.New("not found")
}
func (r *orgAuthSessionRepo) GetByID(_ context.Context, id int64) (*domagentsdk.SessionToken, error) {
	if s, ok := r.byID[id]; ok {
		cp := *s
		return &cp, nil
	}
	return nil, errors.New("not found")
}
func (r *orgAuthSessionRepo) Revoke(context.Context, string) error                     { return nil }
func (r *orgAuthSessionRepo) RevokeByCredential(context.Context, int64) (int64, error) { return 0, nil }
func (r *orgAuthSessionRepo) RevokeByRuntimeEnvironment(context.Context, int64) (int64, error) {
	return 0, nil
}
func (r *orgAuthSessionRepo) RevokeChain(context.Context, int64) (int64, error) { return 0, nil }
func (r *orgAuthSessionRepo) RevokeChainByUUID(context.Context, string) (int64, error) {
	return 0, nil
}
func (r *orgAuthSessionRepo) CleanupExpired(context.Context) (int64, error)         { return 0, nil }
func (r *orgAuthSessionRepo) TouchLastUsed(context.Context, int64, time.Time) error { return nil }
