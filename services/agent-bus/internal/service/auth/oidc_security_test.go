package auth

import (
	"context"
	"errors"
	adapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/session"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	identitysvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/identity"
	"testing"
	"time"
)

type oidcRegistryFixture struct {
	profile      adapter.Profile
	nonceFailure bool
}

func (f *oidcRegistryFixture) ResolveByUUID(context.Context, string) (*adapter.LeasedProvider, error) {
	return &adapter.LeasedProvider{Cfg: adapter.Config{TenantID: 11, Issuer: "https://idp.example.test"}, Provider: f}, nil
}
func (f *oidcRegistryFixture) ResolveByIssuer(ctx context.Context, s string) (*adapter.LeasedProvider, error) {
	return f.ResolveByUUID(ctx, s)
}
func (f *oidcRegistryFixture) Kind() adapter.ProviderKind { return adapter.KindOIDC }
func (f *oidcRegistryFixture) ExchangeCode(context.Context, string, string) (*adapter.Profile, error) {
	panic("nonce verification must be used")
}
func (f *oidcRegistryFixture) ExchangeCodeWithNonce(_ context.Context, _, _, nonce string) (*adapter.Profile, error) {
	if f.nonceFailure || nonce != "expected" {
		return nil, errors.New("nonce mismatch")
	}
	return &f.profile, nil
}

type oidcStateFixture struct {
	missing      bool
	desktopProof string
}

func (f oidcStateFixture) Save(context.Context, string, identitysvc.StatePayload) error { return nil }
func (f oidcStateFixture) Pop(context.Context, string) (*identitysvc.StatePayload, error) {
	if f.missing {
		return nil, apperr.ErrUnauthorized
	}
	return &identitysvc.StatePayload{ProviderUUID: "idp", Nonce: "expected", DesktopProof: f.desktopProof}, nil
}

type oidcAccountFixture struct {
	account.Repository
	lookupCalled bool
	member       bool
}

func (f *oidcAccountFixture) FindByProviderUID(context.Context, string, string) (*account.Account, error) {
	return nil, apperr.ErrNotFound
}
func (f *oidcAccountFixture) GetByEmail(context.Context, string) (*account.Account, error) {
	f.lookupCalled = true
	return &account.Account{ID: 7, Status: "active"}, nil
}
func (f *oidcAccountFixture) GetMembership(_ context.Context, aid, tid int64) (*account.Membership, error) {
	if !f.member || aid != 7 || tid != 11 {
		return nil, apperr.ErrNotFound
	}
	return &account.Membership{AccountID: aid, TenantID: tid, Status: "active"}, nil
}
func TestOIDCRejectsUnverifiedEmailAndForeignMembership(t *testing.T) {
	for _, tc := range []struct {
		name                             string
		verified, member, missing, nonce bool
		want                             error
		lookup                           bool
	}{
		{"unverified email", false, true, false, false, apperr.ErrForbidden, false},
		{"not a tenant member", true, false, false, false, apperr.ErrForbidden, true},
		{"expired or replayed state", true, true, true, false, apperr.ErrUnauthorized, false},
		{"nonce mismatch", true, true, false, true, apperr.ErrUnauthorized, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			accounts := &oidcAccountFixture{member: tc.member}
			provider := &oidcRegistryFixture{profile: adapter.Profile{Subject: "subject", Email: "member@example.test", EmailVerified: tc.verified}, nonceFailure: tc.nonce}
			s := &impl{d: Deps{Accounts: accounts, IdentityRegistry: provider, OIDCStateStore: oidcStateFixture{missing: tc.missing}}}
			_, err := s.LoginOIDC(context.Background(), AuthContext{}, OIDCCallbackReq{Code: "code", State: "state"})
			var actual *apperr.Error
			expected := tc.want.(*apperr.Error)
			if !errors.As(err, &actual) || actual.Code != expected.Code {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
			if accounts.lookupCalled != tc.lookup {
				t.Fatalf("email lookup=%v", accounts.lookupCalled)
			}
		})
	}
}

type boundSessionFixture struct {
	session.Repository
	value session.LoginSession
}

func (f boundSessionFixture) GetByUUID(context.Context, string) (*session.LoginSession, error) {
	return &f.value, nil
}
func TestOIDCSessionCannotSwitchToPlatformOrOtherTenant(t *testing.T) {
	tid := int64(11)
	for _, req := range []ScopeSwitchReq{{Kind: "platform"}, {Kind: "tenant", TenantID: 12}, {Kind: "workspace", TenantID: 11, WorkspaceID: 2}} {
		s := &impl{d: Deps{Sessions: boundSessionFixture{value: session.LoginSession{AccountID: 7, AuthTenantID: &tid, ActScopeKind: "tenant", ActTenantID: &tid, ExpiresAt: time.Now().Add(time.Hour)}}}}
		_, err := s.SwitchScope(context.Background(), 7, "session", req)
		var actual *apperr.Error
		if !errors.As(err, &actual) || actual.Code != apperr.Forbidden {
			t.Fatalf("%+v: got %v", req, err)
		}
	}
}

func TestDesktopOIDCRedirectIsFixedToLoopbackCallback(t *testing.T) {
	if !validDesktopRedirect("http://127.0.0.1:43877/oauth/callback") {
		t.Fatal("valid desktop callback refused")
	}
	for _, redirect := range []string{
		"https://example.test:43877/oauth/callback",
		"http://127.0.0.1.example.test:43877/oauth/callback",
		"http://127.0.0.1:43877/another/path",
		"http://127.0.0.1:43877/oauth/callback?state=x",
		"http://name@127.0.0.1:43877/oauth/callback",
	} {
		if validDesktopRedirect(redirect) {
			t.Fatalf("accepted invalid desktop callback %q", redirect)
		}
	}
}

func TestDesktopOIDCCallbackNeedsPrivateAttemptProof(t *testing.T) {
	accounts := &oidcAccountFixture{member: true}
	provider := &oidcRegistryFixture{profile: adapter.Profile{Subject: "subject", Email: "member@example.test", EmailVerified: true}}
	svc := &impl{d: Deps{Accounts: accounts, IdentityRegistry: provider, OIDCStateStore: oidcStateFixture{desktopProof: "private-attempt-proof"}}}
	_, err := svc.LoginOIDC(context.Background(), AuthContext{}, OIDCCallbackReq{Code: "code", State: "browser-visible-state"})
	actual, ok := apperr.AsError(err)
	if !ok || actual.Code != apperr.Unauthorized || accounts.lookupCalled {
		t.Fatalf("expected callback to fail before account lookup, got %v", err)
	}
}
