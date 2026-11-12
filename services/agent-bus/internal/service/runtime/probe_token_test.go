package runtime

import (
	"strings"
	"testing"
	"time"
)

func TestProbeTokenIssueAndVerify(t *testing.T) {
	iss := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 5*time.Minute)
	claims := ProbeTokenClaims{
		CallerAccountID:    11,
		CallerTenantID:     22,
		EndpointsSHA256:    "abc",
		Scope:              "tenant",
		ProtocolVersion:    "zap-1.1",
		RuntimeCardSummary: "xyz",
	}
	tok, err := iss.Issue(claims)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if !strings.Contains(tok, ".") {
		t.Fatalf("token shape wrong: %s", tok)
	}
	got, err := iss.Verify(tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if got.CallerAccountID != 11 || got.CallerTenantID != 22 || got.EndpointsSHA256 != "abc" || got.Scope != "tenant" {
		t.Fatalf("claims mismatch: %+v", got)
	}
	if got.ExpiresAt == 0 {
		t.Fatal("exp not stamped")
	}
}

func TestProbeTokenRejectBadSignature(t *testing.T) {
	iss := NewProbeTokenIssuer([]byte("secret-a-secret-a-secret-a-secret"), time.Minute)
	tok, _ := iss.Issue(ProbeTokenClaims{Scope: "personal"})
	// 替换签名一位字符
	parts := strings.SplitN(tok, ".", 2)
	tampered := parts[0] + "." + flipChar(parts[1])
	if _, err := iss.Verify(tampered); err == nil {
		t.Fatal("expected verify to fail on bad signature")
	}
}

func TestProbeTokenRejectDifferentSecret(t *testing.T) {
	a := NewProbeTokenIssuer([]byte("secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaa"), time.Minute)
	b := NewProbeTokenIssuer([]byte("secret-bbbbbbbbbbbbbbbbbbbbbbbbbbbb"), time.Minute)
	tok, _ := a.Issue(ProbeTokenClaims{Scope: "tenant"})
	if _, err := b.Verify(tok); err == nil {
		t.Fatal("expected cross-issuer verify to fail")
	}
}

func TestProbeTokenExpired(t *testing.T) {
	iss := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), time.Minute)
	base := time.Now()
	iss.now = func() time.Time { return base }
	tok, err := iss.Issue(ProbeTokenClaims{Scope: "tenant"})
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	// 把时间跳到 token 过期之后
	iss.now = func() time.Time { return base.Add(2 * time.Minute) }
	if _, err := iss.Verify(tok); err == nil {
		t.Fatal("expected expired token to fail")
	}
}

func TestEndpointsSHA256Stable(t *testing.T) {
	a := EndpointsSHA256(map[string]string{"base": "https://x", "ws": "wss://y"})
	b := EndpointsSHA256(map[string]string{"ws": "wss://y", "base": "https://x"})
	if a != b {
		t.Fatalf("hash not deterministic under map order: %s vs %s", a, b)
	}
	c := EndpointsSHA256(map[string]string{"base": "https://other"})
	if a == c {
		t.Fatal("hash collided on different inputs")
	}
}

func TestProbeTokenEndpointsHashMismatchExample(t *testing.T) {
	// 模拟 create 阶段校验: 不一致的 endpoints 必拒。
	iss := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), time.Minute)
	originalHash := EndpointsSHA256(map[string]string{"base": "https://a.example.com"})
	tok, err := iss.Issue(ProbeTokenClaims{Scope: "tenant", EndpointsSHA256: originalHash})
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	got, err := iss.Verify(tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	newBodyHash := EndpointsSHA256(map[string]string{"base": "https://b.example.com"})
	if got.EndpointsSHA256 == newBodyHash {
		t.Fatal("endpoints hash should not match for different endpoints")
	}
}

func TestIsProbeSecretFallbackAllowed(t *testing.T) {
	cases := map[string]bool{
		"local":       true,
		"LOCAL":       true,
		"dev":         true,
		"development": true,
		"":            false,
		"test":        false,
		"staging":     false,
		"prod":        false,
		"production":  false,
		"unknown":     false,
	}
	for env, want := range cases {
		got := IsProbeSecretFallbackAllowed(env)
		if got != want {
			t.Fatalf("env=%q: got %v, want %v", env, got, want)
		}
	}
}

func TestAuthConfigSHA256BindsKindAndSecret(t *testing.T) {
	// 同 kind 不同 secret 必不同
	a := AuthConfigSHA256("bearer", "tok-A")
	b := AuthConfigSHA256("bearer", "tok-B")
	if a == b {
		t.Fatal("AuthConfigSHA256 must differ for different secret")
	}
	// 不同 kind 同 secret 必不同
	c := AuthConfigSHA256("mTLS", "tok-A")
	if a == c {
		t.Fatal("AuthConfigSHA256 must differ for different kind")
	}
	// 稳定性
	a2 := AuthConfigSHA256("bearer", "tok-A")
	if a != a2 {
		t.Fatalf("AuthConfigSHA256 not stable: %s vs %s", a, a2)
	}
}

func TestProbeTokenAuthConfigSHA256RoundTrip(t *testing.T) {
	iss := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), time.Minute)
	tok, err := iss.Issue(ProbeTokenClaims{
		Scope:            "tenant",
		AuthConfigSHA256: AuthConfigSHA256("bearer", "secret-A"),
	})
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	got, err := iss.Verify(tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	want := AuthConfigSHA256("bearer", "secret-A")
	if got.AuthConfigSHA256 != want {
		t.Fatalf("auth_config_sha256 mismatch: %s vs %s", got.AuthConfigSHA256, want)
	}
	// create 阶段如换了 secret_ref, 比对必须失败 (caller 在 service 层重算后对比)。
	tampered := AuthConfigSHA256("bearer", "env://NEW_SECRET")
	if got.AuthConfigSHA256 == tampered {
		t.Fatal("hash should not match for replaced secret")
	}
}

func flipChar(s string) string {
	if s == "" {
		return s
	}
	b := []byte(s)
	if b[0] == 'a' {
		b[0] = 'b'
	} else {
		b[0] = 'a'
	}
	return string(b)
}
