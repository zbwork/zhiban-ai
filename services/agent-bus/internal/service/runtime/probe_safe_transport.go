// probe_safe_transport.go: 防 DNS rebinding 的专用 HTTP transport (P1 SSRF TOCTOU)。
//
// 仅做请求前 SSRFGuard.Validate 不够: Go http.Client 在 Dial 阶段会重新解析 DNS,
// 攻击者用 short-TTL DNS 让 Validate 解析到公网、Dial 解析到内网 (DNS rebinding)。
//
// 这里把 dial 流程接管:
//  1. SplitHostPort 拆 address;
//  2. AllowedHosts 命中直接放行 (单测 stub);
//  3. 字面 IP 走 checkIP;
//  4. 域名走 SSRFGuard.Resolver 解析 → 逐 IP checkIP → 仅 dial 第一个通过的;
//  5. HTTPS SNI/cert 验证仍按 URL.Host 走 (TLS hostname verification 不破)。
//
// redirect 仍走 http.Client.CheckRedirect=noRedirect, 防 302→内网。
package runtime

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"
)

// SafeTransport 返回 *http.Transport, 把 DialContext 接到 SSRFGuard 校验链。
//
// 通用 transport 不能用: 标准 transport 不知道我们的 IP 黑名单, 也无法在 dial
// 时拒绝。生产/单测都建议通过 NewProbeServiceWithOptions 间接构造。
func (g *SSRFGuard) SafeTransport() *http.Transport {
	if g == nil {
		g = &SSRFGuard{}
	}
	return &http.Transport{
		DialContext:           g.safeDialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
}

// safeDialContext 是 Transport.DialContext 实现。
//
// 关键点 (vs Validate):
//   - 这里是 dial 真正发生前最后一次校验, 之前的 Validate 只是早期失败提示;
//   - 重新解析 DNS, 防 Validate ↔ Dial 之间 DNS 改变;
//   - 解析后用其中一个 IP 直连, 不再走 OS resolver。
func (g *SSRFGuard) safeDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	var d net.Dialer
	return g.safeDialWith(ctx, network, addr, d.DialContext)
}

// safeDialWith pins the checked address before either a direct dial or a CONNECT.
func (g *SSRFGuard) safeDialWith(ctx context.Context, network, addr string, dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	// AllowedHosts 显式白名单旁路 (测试 stub 用 127.0.0.1)。
	for _, h := range g.AllowedHosts {
		if strings.EqualFold(h, host) {
			return dial(ctx, network, addr)
		}
	}
	// 字面 IP 直接检查 (含 AllowedCIDRNets)。
	if ip := net.ParseIP(host); ip != nil {
		if err := g.checkIPAllowed(ip); err != nil {
			return nil, &SSRFBlockedError{Reason: err.Error()}
		}
		return dial(ctx, network, addr)
	}
	// 阻断 localhost / metadata hostname (Validate 已挡过, Dial 这层兜底)。
	lower := strings.ToLower(host)
	if lower == "localhost" || strings.HasSuffix(lower, ".localhost") ||
		lower == "metadata" || lower == "metadata.google"+".internal" {
		return nil, &SSRFBlockedError{Reason: "host " + host + " not allowed"}
	}
	// 重新解析 DNS, 锁定本次 dial 用的 IP, 防 Validate→Dial 之间 rebind。
	r := g.Resolver
	if r == nil {
		r = defaultResolver{}
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	ips, err := r.LookupIP(lookupCtx, "ip", host)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, errors.New("ssrf: dns returned no records")
	}
	// 全部 IP 必须通过; 任一不合规直接拒绝 (不挑选, 防 split-horizon 攻击)。
	for _, ip := range ips {
		if err := g.checkIPAllowed(ip); err != nil {
			return nil, &SSRFBlockedError{Reason: err.Error()}
		}
	}
	// 走第一个 IP 直 dial; HTTPS 保留 Host header / SNI 由 Transport 用 URL.Host 设置, 不破证书校验。
	return dial(ctx, network, net.JoinHostPort(ips[0].String(), port))
}

// SSRFBlockedError 在 dial 阶段被 SSRF 守卫拒绝时返回; transport 包装它给 http.Client.Do 的调用方。
type SSRFBlockedError struct {
	Reason string
}

func (e *SSRFBlockedError) Error() string { return "ssrf blocked: " + e.Reason }
