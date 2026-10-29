// probe_ssrf.go: SSRF 守卫
//
// ZAP probe 直接拿用户填的 base/ws/agent_card URL 发 HTTP 请求, 是典型 SSRF 出口。
// 必须在 dial 之前过一遍:
//   - scheme 仅允许 https; dev 模式可放开 http (cfg.AllowHTTP=true)。
//   - host 解析后所有 IP 必须是公网可路由; 命中以下网段直接 fail:
//     127.0.0.0/8       (loopback)
//     ::1/128           (loopback v6)
//     10/8              (RFC1918 private)
//     172.16/12         (RFC1918 private)
//     192.168/16        (RFC1918 private)
//     169.254.0.0/16    (link-local + AWS/GCP metadata 169.254.169.254)
//     fe80::/10         (IPv6 link-local)
//     multicast / reserved / unspecified
//   - DNS 解析后的所有 IP 都校验, 任一不合规 → 拒绝。
//   - HTTP redirect 禁用 (Client.CheckRedirect 返 ErrUseLastResponse), 避免 302 → 内网。
//
// 留 AllowedHosts 白名单接口给 dev/test 用 (e.g. 测试 stub server 必须放行)。
package runtime

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// SSRFGuard 配置 + 校验。零值不允许 http、按默认私网拒绝表生效。
type SSRFGuard struct {
	AllowHTTP       bool         // 开发模式 dev/local; 生产必须为 false
	AllowedHosts    []string     // 显式白名单 host (单测 / 测试 stub 用); 命中即放行 IP 检查
	AllowedCIDRNets []*net.IPNet // 允许探测的目标网段 (如本地/dev/test K8s Pod/Service CIDR); 不能绕过 loopback/link-local/metadata 绝对禁止项
	Resolver        Resolver     // nil → net.DefaultResolver
}

// ParseAllowedCIDRs 解析 CIDR 字符串列表为 []*net.IPNet。非法 CIDR 立即返回错误, 不静默忽略。
func ParseAllowedCIDRs(cidrs []string) ([]*net.IPNet, error) {
	var nets []*net.IPNet
	for _, s := range cidrs {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		_, n, err := net.ParseCIDR(s)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %q: %w", s, err)
		}
		nets = append(nets, n)
	}
	return nets, nil
}

// Resolver 抽象 net.Resolver, 便于单测注入。
type Resolver interface {
	LookupIP(ctx context.Context, network, host string) ([]net.IP, error)
}

type defaultResolver struct{}

func (defaultResolver) LookupIP(ctx context.Context, network, host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(ctx, network, host)
}

// privateNets 私网/保留段; 任一命中 IP 即拒。
var privateNets []*net.IPNet

func init() {
	for _, s := range []string{
		"127.0.0.0/8",
		"10." + "0.0.0/8",
		"172." + "16.0.0/12",
		"192." + "168.0.0/16",
		"169.254.0.0/16",
		"100.64.0.0/10", // CGNAT
		"192.0.0.0/24",  // IETF assignments
		"198.18.0.0/15", // Benchmarking
		"::1/128",
		"fe80::/10",
		"fc00::/7",
	} {
		_, n, _ := net.ParseCIDR(s)
		if n != nil {
			privateNets = append(privateNets, n)
		}
	}
}

// Validate 解析 raw URL, scheme + host 检查, DNS 解析后逐 IP 检查。
//
// 错误码: runtime.unreachable 包装具体原因, 不暴露内部 CIDR 列表。
func (g *SSRFGuard) Validate(ctx context.Context, raw string) error {
	if strings.TrimSpace(raw) == "" {
		return errors.New("empty url")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("invalid url: %w", err)
	}
	scheme := strings.ToLower(u.Scheme)
	switch scheme {
	case "https":
		// ok
	case "http":
		if !g.AllowHTTP {
			return errors.New("https required (http disabled by SSRF guard)")
		}
	default:
		return fmt.Errorf("scheme %q not allowed", u.Scheme)
	}
	host := u.Hostname()
	if host == "" {
		return errors.New("empty host")
	}
	// 显式白名单 host 直接放行 (单测 stub 用 127.0.0.1)。
	for _, h := range g.AllowedHosts {
		if strings.EqualFold(h, host) {
			return nil
		}
	}
	// 字面 IP 直接走 IP 检查 (含 AllowedCIDRNets)。
	if ip := net.ParseIP(host); ip != nil {
		return g.checkIPAllowed(ip)
	}
	// 阻断显式 metadata / localhost 域名 (即便 DNS 把它指向公网)。
	lower := strings.ToLower(host)
	if lower == "localhost" || strings.HasSuffix(lower, ".localhost") {
		return errors.New("host 'localhost' not allowed")
	}
	if lower == "metadata.google"+".internal" || lower == "metadata" {
		return errors.New("metadata hostname not allowed")
	}
	r := g.Resolver
	if r == nil {
		r = defaultResolver{}
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	ips, err := r.LookupIP(lookupCtx, "ip", host)
	if err != nil {
		return fmt.Errorf("dns lookup failed: %w", err)
	}
	if len(ips) == 0 {
		return errors.New("dns returned no records")
	}
	for _, ip := range ips {
		if err := g.checkIPAllowed(ip); err != nil {
			return err
		}
	}
	return nil
}

func checkIP(ip net.IP) error {
	if ip == nil {
		return errors.New("nil ip")
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() {
		return fmt.Errorf("ip %s is private/reserved", ip)
	}
	if v4 := ip.To4(); v4 != nil {
		if v4[0] == 0 || v4[0] == 240 { // 0.0.0.0/8 / 240.0.0.0/4 reserved
			return fmt.Errorf("ip %s is reserved", v4)
		}
	}
	for _, n := range privateNets {
		if n.Contains(ip) {
			return fmt.Errorf("ip %s is in blocked range %s", ip, n)
		}
	}
	return nil
}

// checkIPAllowed 检查 IP 是否允许, 尊重 AllowedCIDRNets 白名单。
//
// 顺序: 绝对禁止项 (loopback/link-local/multicast/reserved) → AllowedCIDRNets 放行 → 默认黑名单。
// AllowedCIDRNets 不能绕过绝对禁止项 (127.0.0.0/8, ::1, 169.254.0.0/16, fe80::/10 等)。
func (g *SSRFGuard) checkIPAllowed(ip net.IP) error {
	if ip == nil {
		return errors.New("nil ip")
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() {
		return fmt.Errorf("ip %s is private/reserved", ip)
	}
	if v4 := ip.To4(); v4 != nil {
		if v4[0] == 0 || v4[0] == 240 {
			return fmt.Errorf("ip %s is reserved", v4)
		}
	}
	for _, n := range g.AllowedCIDRNets {
		if n.Contains(ip) {
			return nil
		}
	}
	for _, n := range privateNets {
		if n.Contains(ip) {
			return fmt.Errorf("ip %s is in blocked range %s", ip, n)
		}
	}
	return nil
}

// noRedirect 给 http.Client.CheckRedirect 用; 禁用 redirect 防止 302→内网。
func noRedirect(_ *http.Request, _ []*http.Request) error {
	return http.ErrUseLastResponse
}
