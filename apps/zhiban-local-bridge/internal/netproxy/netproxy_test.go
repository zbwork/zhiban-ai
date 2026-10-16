package netproxy

import (
	"context"
	"net"
	"reflect"
	"testing"
)

func TestGatewayHostsAddsParentAndSkipsNonHTTPS(t *testing.T) {
	entries, dial := GatewayHosts([]string{
		"https://api.airick.cn/v1",
		"https://API.airick.cn/other",
		"http://plain.example.com",
		"https://192.0.2.1", // RFC 5737 documentation address; IP literals are excluded.
		"https://localhost:8443",
	})
	if want := []string{"api.airick.cn", ".airick.cn", "airick.cn", "localhost"}; !reflect.DeepEqual(entries, want) {
		t.Fatalf("entries = %v, want %v", entries, want)
	}
	if want := []string{"api.airick.cn", "localhost"}; !reflect.DeepEqual(dial, want) {
		t.Fatalf("dial = %v, want %v", dial, want)
	}
}

func TestMergeAndCoverKeepUserEntries(t *testing.T) {
	hosts := []string{"api.airick.cn", ".airick.cn", "airick.cn"}
	merged, added := mergeList(" localhost, AIRICK.cn ,,", hosts)
	if merged != "localhost,AIRICK.cn,api.airick.cn,.airick.cn" {
		t.Fatalf("merged = %q", merged)
	}
	if want := []string{"api.airick.cn", ".airick.cn"}; !reflect.DeepEqual(added, want) {
		t.Fatalf("added = %v, want %v", added, want)
	}
	if !covers(merged, hosts) || covers("localhost", hosts) || !covers("*", hosts) {
		t.Fatal("covers mismatch")
	}
}

type fakePlatform struct {
	proxy   SystemProxy
	covered bool
}

func (fakePlatform) supported() bool                           { return true }
func (p fakePlatform) systemProxy(context.Context) SystemProxy { return p.proxy }
func (p fakePlatform) coverage(_ context.Context, hosts []string) map[string]bool {
	covered := map[string]bool{}
	for _, host := range hosts {
		covered[host] = p.covered
	}
	return covered
}
func (fakePlatform) apply(context.Context, []string) error { return nil }
func (fakePlatform) noProxy(context.Context) string        { return "" }

// 契约 §2.7「直连预检与快速失败」(2026-09-18):只有命令行会直连、而直连又不通时
// 才报 true;命令行要走代理时直连结果不说明问题。
func TestDirectPathUnreachableOnlyWhenTheCLIWouldConnectDirectly(t *testing.T) {
	for _, name := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"} {
		t.Setenv(name, "")
	}
	cases := []struct {
		name       string
		platform   fakePlatform
		envProxy   string
		dialAnswer bool
		want       bool
		wantDials  int
	}{
		{name: "no proxy anywhere, gateway answers", dialAnswer: true, want: false, wantDials: 1},
		{name: "no proxy anywhere, direct path dead (TUN / firewall / offline)", dialAnswer: false, want: true, wantDials: 1},
		{name: "system proxy on but NO_PROXY covers the gateway, direct path dead (Clash TUN)",
			platform: fakePlatform{proxy: SystemProxy{Enabled: true}, covered: true}, dialAnswer: false, want: true, wantDials: 1},
		{name: "system proxy on and covered, gateway answers",
			platform: fakePlatform{proxy: SystemProxy{Enabled: true}, covered: true}, dialAnswer: true, want: false, wantDials: 1},
		{name: "system proxy on and not covered: the CLI goes through it, a dead direct path says nothing",
			platform: fakePlatform{proxy: SystemProxy{Enabled: true}}, dialAnswer: false, want: false, wantDials: 1},
		{name: "HTTPS_PROXY set and not covered: corporate egress, direct is blocked by design",
			envProxy: "http://proxy.example.com:3128", dialAnswer: false, want: false, wantDials: 0},
		{name: "HTTPS_PROXY set but NO_PROXY covers the gateway, direct path dead",
			platform: fakePlatform{covered: true}, envProxy: "http://proxy.example.com:3128", dialAnswer: false, want: true, wantDials: 1},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("HTTPS_PROXY", test.envProxy)
			dials := 0
			hosts, dialHosts := GatewayHosts([]string{"https://api.example-relay.cn/v1"})
			manager := &Manager{hosts: hosts, dialHosts: dialHosts, platform: test.platform,
				dial: func(context.Context, string) bool { dials++; return test.dialAnswer }}
			if got := manager.DirectPathUnreachable(context.Background()); got != test.want {
				t.Fatalf("DirectPathUnreachable = %v, want %v", got, test.want)
			}
			if dials != test.wantDials {
				t.Fatalf("dials = %d, want %d", dials, test.wantDials)
			}
		})
	}
	// No gateway configured: nothing to check.
	if (&Manager{platform: fakePlatform{}, dial: func(context.Context, string) bool { return false }}).DirectPathUnreachable(context.Background()) {
		t.Fatal("no gateway hosts must report false")
	}
}

// 契约 §2.7「系统绕过名单也一并写」(2026-09-18):Chromium 系客户端只认系统绕过名单。
func TestBypassListHelpers(t *testing.T) {
	hosts, _ := GatewayHosts([]string{"https://api.airick.cn/v1"})
	if got := bypassEntries(hosts); !reflect.DeepEqual(got, []string{"api.airick.cn", "*.airick.cn", "airick.cn"}) {
		t.Fatalf("bypassEntries = %v", got)
	}
	names := plainHosts(hosts)
	for _, test := range []struct {
		name string
		list []string
		want bool
	}{
		{"clash default list", []string{"127.0.0.1", "localhost", "*.local", "<local>"}, false},
		{"what zhiban writes", []string{"<local>", "api.airick.cn", "*.airick.cn", "airick.cn"}, true},
		{"hand-added wildcard plus parent (the dev Mac)", []string{"*.airick.cn", "airick.cn"}, true},
		{"wildcard alone misses the parent", []string{"*.airick.cn"}, false},
		{"dotted suffix form", []string{".airick.cn", "AIRICK.CN"}, true},
		{"bypass everything", []string{"*"}, true},
		{"look-alike domain does not count", []string{"*.notairick.cn", "xairick.cn"}, false},
		{"empty", nil, false},
	} {
		if got := bypassCovers(test.list, names); got != test.want {
			t.Fatalf("%s: bypassCovers = %v, want %v", test.name, got, test.want)
		}
	}
	merged, added := mergeBypass([]string{"localhost", " 127.* ", "", "*.AIRICK.cn"}, bypassEntries(hosts))
	if !reflect.DeepEqual(merged, []string{"localhost", "127.*", "*.AIRICK.cn", "api.airick.cn", "airick.cn"}) ||
		!reflect.DeepEqual(added, []string{"api.airick.cn", "airick.cn"}) {
		t.Fatalf("mergeBypass = %v added %v", merged, added)
	}
	if _, again := mergeBypass(merged, bypassEntries(hosts)); len(again) != 0 {
		t.Fatalf("mergeBypass is not idempotent: %v", again)
	}
}

type keyedPlatform struct {
	fakePlatform
	keys map[string]bool
}

func (p keyedPlatform) coverage(context.Context, []string) map[string]bool { return p.keys }

// 绕过名单没覆盖要提示一键修复(needs_fix),但不能让命令行探针走"被系统代理拦截"
// 的快速失败(env_needs_fix):命令行读的是 NO_PROXY。
func TestStatusSeparatesTheBypassListFromTheEnvironment(t *testing.T) {
	hosts, dialHosts := GatewayHosts([]string{"https://api.airick.cn"})
	build := func(keys map[string]bool) Status {
		manager := &Manager{hosts: hosts, dialHosts: dialHosts,
			platform: keyedPlatform{fakePlatform: fakePlatform{proxy: SystemProxy{Enabled: true}}, keys: keys},
			dial:     func(context.Context, string) bool { return true }}
		status, _ := manager.Status(context.Background())
		return status
	}
	if s := build(map[string]bool{"user_env": true, coveredSystemBypass: false}); !s.NeedsFix || s.EnvNeedsFix {
		t.Fatalf("bypass list missing: needs_fix=%v env_needs_fix=%v, want true/false", s.NeedsFix, s.EnvNeedsFix)
	}
	if s := build(map[string]bool{"user_env": false, coveredSystemBypass: true}); !s.NeedsFix || !s.EnvNeedsFix {
		t.Fatalf("NO_PROXY missing: needs_fix=%v env_needs_fix=%v, want true/true", s.NeedsFix, s.EnvNeedsFix)
	}
	if s := build(map[string]bool{"user_env": true, coveredSystemBypass: true}); s.NeedsFix || s.EnvNeedsFix {
		t.Fatalf("all covered: needs_fix=%v env_needs_fix=%v, want false/false", s.NeedsFix, s.EnvNeedsFix)
	}
	// 命令行会不会直连只看 NO_PROXY:绕过名单没覆盖不影响直连预检。
	manager := &Manager{hosts: hosts, dialHosts: dialHosts,
		platform: keyedPlatform{fakePlatform: fakePlatform{proxy: SystemProxy{Enabled: true}}, keys: map[string]bool{"user_env": true, coveredSystemBypass: false}},
		dial:     func(context.Context, string) bool { return false }}
	for _, name := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"} {
		t.Setenv(name, "")
	}
	if !manager.DirectPathUnreachable(context.Background()) {
		t.Fatal("NO_PROXY covers the gateway: the CLI connects directly, a dead direct path must be reported")
	}
}

// 契约 §2.7「被代理软件转走」(2026-09-18):本机有代理软件在起作用、Bridge 自己直连又
// 是通的,工具的请求却没到——按进程名分流 / 全局模式 / TUN 把它带去了代理节点。
func TestTrafficDivertedNeedsAnActiveProxyToolAndAReachableGateway(t *testing.T) {
	hosts, dialHosts := GatewayHosts([]string{"https://api.airick.cn"})
	fake := []net.IP{net.ParseIP("198.18.0.42")}
	real := []net.IP{net.ParseIP("47.96.1.2")}
	for _, test := range []struct {
		name      string
		proxy     bool
		addresses []net.IP
		reachable bool
		want      bool
	}{
		{"system proxy on, bridge reaches the gateway", true, real, true, true},
		{"TUN fake-IP, system proxy off, bridge reaches the gateway", false, fake, true, true},
		{"edge of the fake range", false, []net.IP{net.ParseIP("198.19.255.254")}, true, true},
		{"no proxy tool in play: an ordinary network failure", false, real, true, false},
		{"just outside the fake range", false, []net.IP{net.ParseIP("198.20.0.1")}, true, false},
		{"proxy tool active but the bridge cannot reach it either: not a routing split", true, fake, false, false},
	} {
		manager := &Manager{hosts: hosts, dialHosts: dialHosts,
			platform: fakePlatform{proxy: SystemProxy{Enabled: test.proxy}},
			dial:     func(context.Context, string) bool { return test.reachable },
			resolve:  func(context.Context, string) []net.IP { return test.addresses }}
		if got := manager.TrafficDiverted(context.Background()); got != test.want {
			t.Fatalf("%s: TrafficDiverted = %v, want %v", test.name, got, test.want)
		}
	}
}
