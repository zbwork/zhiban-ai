package runtime

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

// SafeHTTPSModelTransport opts HTTPS model calls into the operator's egress
// proxy. Keep Transport.Proxy nil: CONNECT must use the IP checked here, while
// Transport retains the original URL hostname for TLS verification and Host.
// Other runtime probes continue to use SafeTransport (direct connections).
func (g *SSRFGuard) SafeHTTPSModelTransport() *http.Transport {
	return g.httpsModelTransport(http.ProxyFromEnvironment)
}

func (g *SSRFGuard) httpsModelTransport(proxyFor func(*http.Request) (*url.URL, error)) *http.Transport {
	if g == nil {
		g = &SSRFGuard{}
	}
	tr := g.SafeTransport()
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		proxy, err := proxyFor(&http.Request{URL: &url.URL{Scheme: "https", Host: addr}})
		if err != nil {
			return nil, errors.New("invalid model egress proxy")
		}
		if proxy == nil {
			return g.safeDialContext(ctx, network, addr)
		}
		if (proxy.Scheme != "http" && proxy.Scheme != "https") || proxy.Hostname() == "" || proxy.RawQuery != "" || proxy.Fragment != "" || (proxy.Path != "" && proxy.Path != "/") {
			return nil, errors.New("unsupported model egress proxy")
		}
		return g.safeDialWith(ctx, network, addr, func(ctx context.Context, _, pinned string) (net.Conn, error) {
			return dialModelProxy(ctx, proxy, pinned)
		})
	}
	return tr
}

func dialModelProxy(ctx context.Context, proxy *url.URL, pinned string) (conn net.Conn, err error) {
	port := proxy.Port()
	if port == "" {
		port = "80"
		if proxy.Scheme == "https" {
			port = "443"
		}
	}
	var d net.Dialer
	conn, err = d.DialContext(ctx, "tcp", net.JoinHostPort(proxy.Hostname(), port))
	if err != nil {
		return nil, err
	}
	// Bound CONNECT (including headers) and close promptly on request cancellation.
	raw := conn
	stop := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer func() {
		stop()
		if err != nil {
			_ = raw.Close()
		}
	}()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	if proxy.Scheme == "https" {
		secure := tls.Client(conn, &tls.Config{ServerName: proxy.Hostname(), MinVersion: tls.VersionTLS12})
		if err = secure.HandshakeContext(ctx); err != nil {
			return nil, err
		}
		conn = secure
	}
	req := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: pinned}, Host: pinned, Header: make(http.Header)}
	if proxy.User != nil {
		password, _ := proxy.User.Password()
		req.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(proxy.User.Username()+":"+password)))
	}
	if err = req.Write(conn); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, req)
	if err != nil {
		return nil, errors.New("invalid model proxy CONNECT response")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("model proxy CONNECT status %d", resp.StatusCode)
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return &modelProxyConn{Conn: conn, reader: reader}, nil
}

type modelProxyConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *modelProxyConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
