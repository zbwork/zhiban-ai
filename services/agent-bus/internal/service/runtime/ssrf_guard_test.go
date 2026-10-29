package runtime

import (
	"context"
	"net"
	"testing"
)

type stubResolver struct{ ip net.IP }

func (s stubResolver) LookupIP(_ context.Context, _, _ string) ([]net.IP, error) {
	if s.ip == nil {
		return nil, nil
	}
	return []net.IP{s.ip}, nil
}

func TestSSRFGuard_DefaultDenyHTTP(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "http://example.com/x"); err == nil {
		t.Fatal("default guard must reject http://")
	}
}

func TestSSRFGuard_AllowHTTPInDev(t *testing.T) {
	g := &SSRFGuard{AllowHTTP: true, Resolver: stubResolver{ip: net.ParseIP("93.184.216.34")}}
	if err := g.Validate(context.Background(), "http://example.com/x"); err != nil {
		t.Fatalf("AllowHTTP=true should accept http: %v", err)
	}
}

func TestSSRFGuard_RejectLocalhost(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://localhost/x"); err == nil {
		t.Fatal("expected localhost rejected")
	}
}

func TestSSRFGuard_Reject127(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://127.0.0.1/x"); err == nil {
		t.Fatal("expected 127.0.0.1 rejected")
	}
}

func TestSSRFGuard_RejectMetadataIP(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://169.254.169.254/latest/meta-data"); err == nil {
		t.Fatal("expected 169.254.169.254 (cloud metadata) rejected")
	}
}

func TestSSRFGuard_RejectMetadataHostname(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://metadata.google"+".internal/x"); err == nil {
		t.Fatal("expected cloud metadata hostname rejected")
	}
}

func TestSSRFGuard_RejectPrivateCIDR(t *testing.T) {
	cases := []string{
		"https://10." + "1.2.3/x",
		"https://172." + "20.0.5/x",
		"https://192." + "168.0.10/x",
	}
	g := &SSRFGuard{}
	for _, raw := range cases {
		if err := g.Validate(context.Background(), raw); err == nil {
			t.Fatalf("expected %s rejected as private CIDR", raw)
		}
	}
}

func TestSSRFGuard_RejectIPv6Loopback(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://[::1]/x"); err == nil {
		t.Fatal("expected ::1 rejected")
	}
}

func TestSSRFGuard_AcceptPublicIP(t *testing.T) {
	g := &SSRFGuard{Resolver: stubResolver{ip: net.ParseIP("8.8.8.8")}}
	if err := g.Validate(context.Background(), "https://dns.google/x"); err != nil {
		t.Fatalf("expected public ip accepted: %v", err)
	}
}

func TestSSRFGuard_RejectDNSResolvedToPrivate(t *testing.T) {
	// 即便 host 是 evil.example.com, DNS 解析到 127.0.0.1, 也要拒。
	g := &SSRFGuard{Resolver: stubResolver{ip: net.ParseIP("127.0.0.1")}}
	if err := g.Validate(context.Background(), "https://evil.example.com/x"); err == nil {
		t.Fatal("expected DNS-rebind-to-127 rejected")
	}
}

func TestSSRFGuard_AllowedHostsBypass(t *testing.T) {
	// 单测 / dev stub 用; 显式 host 白名单跳过 IP 校验。
	g := &SSRFGuard{AllowedHosts: []string{"127.0.0.1"}}
	if err := g.Validate(context.Background(), "https://127.0.0.1:8443/x"); err != nil {
		t.Fatalf("AllowedHosts should bypass: %v", err)
	}
}

func TestParseAllowedCIDRs_Valid(t *testing.T) {
	nets, err := ParseAllowedCIDRs([]string{"10." + "20.30.0/24", " 10." + "21.0.0/16 ", ""})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(nets) != 2 {
		t.Fatalf("expected 2 nets, got %d", len(nets))
	}
}

func TestParseAllowedCIDRs_Invalid(t *testing.T) {
	_, err := ParseAllowedCIDRs([]string{"not-a-cidr"})
	if err == nil {
		t.Fatal("expected error for invalid CIDR")
	}
}

func TestSSRFGuard_AllowedCIDRNets_AllowPrivate(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"10." + "20.30.0/24"})
	g := &SSRFGuard{AllowHTTP: true, AllowedCIDRNets: nets}
	if err := g.Validate(context.Background(), "http://10."+"20.30.160:8200/x"); err != nil {
		t.Fatalf("AllowedCIDRNets should allow an address inside the allowed subnet: %v", err)
	}
}

func TestSSRFGuard_AllowedCIDRNets_StillBlockOutOfRange(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"10." + "20.30.0/24"})
	g := &SSRFGuard{AllowHTTP: true, AllowedCIDRNets: nets}
	if err := g.Validate(context.Background(), "http://10."+"20.31.1/x"); err == nil {
		t.Fatal("expected an address outside AllowedCIDRs rejected")
	}
}

func TestSSRFGuard_AllowedCIDRNets_CannotBypassLoopback(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"127.0.0.0/8"})
	g := &SSRFGuard{AllowedCIDRNets: nets}
	if err := g.Validate(context.Background(), "https://127.0.0.1/x"); err == nil {
		t.Fatal("AllowedCIDRNets must not bypass loopback rejection")
	}
}

func TestSSRFGuard_AllowedCIDRNets_CannotBypassLinkLocal(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"169.254.0.0/16"})
	g := &SSRFGuard{AllowedCIDRNets: nets}
	if err := g.Validate(context.Background(), "https://169.254.169.254/latest/meta-data"); err == nil {
		t.Fatal("AllowedCIDRNets must not bypass link-local/metadata rejection")
	}
}

func TestSSRFGuard_AllowedCIDRNets_DNSResolvesToAllowed(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"10." + "20.30.0/24"})
	g := &SSRFGuard{AllowHTTP: true, AllowedCIDRNets: nets, Resolver: stubResolver{ip: net.ParseIP("10." + "20.30.160")}}
	if err := g.Validate(context.Background(), "http://my-runtime"+".internal:8200/x"); err != nil {
		t.Fatalf("DNS resolving to AllowedCIDR should pass: %v", err)
	}
}

func TestSSRFGuard_DefaultGuard_StillRejectsPrivate(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "https://10."+"1.2.3/x"); err == nil {
		t.Fatal("default guard (no AllowedCIDRNets) must still reject RFC1918")
	}
}

func TestSafeDial_AllowedCIDRNets_Respected(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"10." + "20.30.0/24"})
	guard := &SSRFGuard{AllowedCIDRNets: nets, Resolver: stubResolver{ip: net.ParseIP("10." + "20.30.160")}}
	called := false
	_, err := guard.safeDialWith(context.Background(), "tcp", "my-runtime"+".internal:443", func(_ context.Context, network, addr string) (net.Conn, error) {
		called = true
		if network != "tcp" || addr != "10."+"20.30.160:443" {
			t.Fatalf("unexpected pinned destination: %s %s", network, addr)
		}
		return nil, nil
	})
	if err != nil || !called {
		t.Fatalf("allowed CIDR must reach dial: called=%v err=%v", called, err)
	}
}

func TestSafeTransport_AllowedCIDRNets_CannotBypassLoopback(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{"127.0.0.0/8"})
	rr := stubResolver{ip: net.ParseIP("127.0.0.1")}
	guard := &SSRFGuard{AllowedCIDRNets: nets, Resolver: rr}
	tr := guard.SafeTransport()
	_, err := tr.DialContext(context.Background(), "tcp", "evil.example.com:443")
	if err == nil {
		t.Fatal("SafeTransport must reject loopback even with AllowedCIDRNets")
	}
	var blocked *SSRFBlockedError
	if !errorsAs(err, &blocked) {
		t.Fatalf("expected SSRFBlockedError, got %T %v", err, err)
	}
}

func TestSSRFGuard_RejectFileScheme(t *testing.T) {
	g := &SSRFGuard{}
	if err := g.Validate(context.Background(), "file:///etc/passwd"); err == nil {
		t.Fatal("expected file:// rejected")
	}
}

type rebindResolver struct {
	calls         int
	public        net.IP
	private       net.IP
	lastQueryHost string
}

func (r *rebindResolver) LookupIP(_ context.Context, _, host string) ([]net.IP, error) {
	r.calls++
	r.lastQueryHost = host
	if r.calls == 1 {
		return []net.IP{r.public}, nil
	}
	return []net.IP{r.private}, nil
}

func TestSafeTransport_RejectsRebindToPrivate(t *testing.T) {
	// SafeTransport 独立验证: 即便用户域名看似无害, 只要 dial-time DNS 返私网就拒。
	// 用纯私网 resolver 来等价模拟"Validate 后 DNS 改成内网"的状态。
	rr := stubResolver{ip: net.ParseIP("127.0.0.1")}
	guard := &SSRFGuard{Resolver: rr}
	tr := guard.SafeTransport()
	_, err := tr.DialContext(context.Background(), "tcp", "rebind.example.com:443")
	if err == nil {
		t.Fatal("expected DialContext to reject DNS resolving to 127.0.0.1")
	}
	var blocked *SSRFBlockedError
	if !errorsAs(err, &blocked) {
		t.Fatalf("expected SSRFBlockedError, got %T %v", err, err)
	}
}

func errorsAs(err error, target any) bool {
	tgt, ok := target.(**SSRFBlockedError)
	if !ok {
		return false
	}
	for cur := err; cur != nil; {
		if b, ok := cur.(*SSRFBlockedError); ok {
			*tgt = b
			return true
		}
		// 简易 unwrap
		type unwrapper interface{ Unwrap() error }
		u, ok := cur.(unwrapper)
		if !ok {
			break
		}
		cur = u.Unwrap()
	}
	return false
}
