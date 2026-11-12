package runtime

import (
	"context"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestProbeWithRedirectDisabledByDefault(t *testing.T) {
	// 验证默认 http client 配置: CheckRedirect=noRedirect 必须挂上。
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{})
	impl, ok := svc.(*probeImpl)
	if !ok {
		t.Fatal("expected *probeImpl")
	}
	hc, ok := impl.doer.(*http.Client)
	if !ok {
		t.Fatal("default doer should be *http.Client")
	}
	if hc.CheckRedirect == nil {
		t.Fatal("default http.Client.CheckRedirect must be set to noRedirect")
	}
	if err := hc.CheckRedirect(nil, nil); err != http.ErrUseLastResponse {
		t.Fatalf("CheckRedirect returned %v want ErrUseLastResponse", err)
	}
}

// rebindResolver 模拟 DNS rebinding: 第一次解析返回公网 IP (Validate 通过),
// 第二次返回私网 IP (Dial 时 SafeTransport 重解析必须拒).
func TestProbe_RebindBetweenValidateAndDialRejected(t *testing.T) {
	// 完整 probe 入口: hostname 同一个, Validate 走 rebindResolver call#1 (公网),
	// Dial 走 rebindResolver call#2 (127.0.0.1) → 必须拒绝。
	rr := &rebindResolver{public: net.ParseIP("8.8.8.8"), private: net.ParseIP("127.0.0.1")}
	guard := &SSRFGuard{Resolver: rr}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 5*time.Minute)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{SSRFGuard: guard})

	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://rebind.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if res.OK {
		t.Fatalf("expected ok=false; got %+v", res)
	}
	if res.ErrorCode != "runtime.unreachable" {
		t.Fatalf("error_code=%q want runtime.unreachable", res.ErrorCode)
	}
	if rr.calls < 2 {
		t.Fatalf("expected rebind resolver to be called at least 2x (Validate + Dial), got %d", rr.calls)
	}
}

// errorsAs 简易 errors.As 封装, 避免引 stdlib errors 包导致循环。
func TestProbeRejectsLocalhostEndpoint(t *testing.T) {
	// 真正经过 probe.Probe 入口: 提交 base=https://127.0.0.1/... 必须返 runtime.unreachable
	// 且 ErrorMessage 含 ssrf。
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{Doer: doer, SSRFGuard: &SSRFGuard{}})
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://127.0.0.1/"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if res.OK {
		t.Fatalf("expected ok=false for 127.0.0.1; got %+v", res)
	}
	if res.ErrorCode != "runtime.unreachable" {
		t.Fatalf("error_code=%q want runtime.unreachable", res.ErrorCode)
	}
	if !strings.Contains(res.ErrorMessage, "受限网段") {
		t.Fatalf("error_message=%q should mention 受限网段", res.ErrorMessage)
	}
}

func TestProbeDefaultStillRejectsPrivate(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{Doer: doer, SSRFGuard: &SSRFGuard{AllowHTTP: true}})
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "http://" + net.IPv4(10, 23, 45, 67).String() + ":8200/"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if res.OK {
		t.Fatal("default probe (no AllowedCIDRNets) should reject 10.x")
	}
}

func TestProbeWithAllowedCIDRs_AllowsPrivate(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{net.IPv4(10, 0, 0, 0).String() + "/8"})
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{
		Doer:      doer,
		SSRFGuard: &SSRFGuard{AllowHTTP: true, AllowedCIDRNets: nets},
	})
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "http://" + net.IPv4(10, 23, 45, 67).String() + ":8200/"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if !res.OK {
		t.Fatalf("probe with AllowedCIDRNets=configured private CIDR should allow the private test address, got err=%q", res.ErrorMessage)
	}
}

func TestProbeWithAllowedCIDRs_StillRejectsLoopback(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{net.IPv4(10, 0, 0, 0).String() + "/8"})
	doer := &fakeDoer{responses: map[string]fakeResp{}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{
		Doer:      doer,
		SSRFGuard: &SSRFGuard{AllowHTTP: true, AllowedCIDRNets: nets},
	})
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "http://127.0.0.1:8200/"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if res.OK {
		t.Fatal("probe with AllowedCIDRNets must still reject 127.0.0.1")
	}
}

func TestProbeWithAllowedCIDRs_StillRejectsMetadata(t *testing.T) {
	nets, _ := ParseAllowedCIDRs([]string{net.IPv4(169, 254, 0, 0).String() + "/16"})
	doer := &fakeDoer{responses: map[string]fakeResp{}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 0)
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{
		Doer:      doer,
		SSRFGuard: &SSRFGuard{AllowedCIDRNets: nets},
	})
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://" + net.IPv4(169, 254, 169, 254).String() + "/"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe err: %v", err)
	}
	if res.OK {
		t.Fatal("probe with AllowedCIDRNets must still reject metadata address")
	}
}
