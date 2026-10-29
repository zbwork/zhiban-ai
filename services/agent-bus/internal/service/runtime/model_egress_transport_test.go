package runtime

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestModelEgressProxyPinsIPPreservesTLSHostAndCredentials(t *testing.T) {
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "example.com" || r.TLS.ServerName != "example.com" {
			t.Errorf("lost original TLS/Host: %q %q", r.Host, r.TLS.ServerName)
		}
		if r.Header.Get("Authorization") != "Bearer synthetic-model-key" || r.Header.Get("Proxy-Authorization") != "" {
			t.Error("target credentials mixed with proxy credentials")
		}
		_, _ = io.WriteString(w, "reply")
	}))
	defer target.Close()
	var connects atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connects.Add(1)
		if r.Method != "CONNECT" || r.Host != "93.184.216.34:443" {
			t.Errorf("un-pinned CONNECT: %s %s", r.Method, r.Host)
		}
		if r.Header.Get("Authorization") != "" || r.Header.Get("Proxy-Authorization") != "Basic dXNlcjpwYXNz" {
			t.Error("proxy credentials wrong")
		}
		upstream, err := net.Dial("tcp", strings.TrimPrefix(target.URL, "https://"))
		if err != nil {
			t.Error(err)
			return
		}
		defer upstream.Close()
		downstream, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer downstream.Close()
		_, _ = io.WriteString(downstream, "HTTP/1.1 200 Connection Established\r\n\r\n")
		done := make(chan struct{})
		go func() { _, _ = io.Copy(upstream, downstream); close(done) }()
		_, _ = io.Copy(downstream, upstream)
		_ = downstream.Close()
		<-done
	}))
	defer proxy.Close()
	p, _ := url.Parse(proxy.URL)
	p.User = url.UserPassword("user", "pass")
	g := &SSRFGuard{Resolver: stubResolver{ip: net.ParseIP("93.184.216.34")}}
	tr := g.httpsModelTransport(http.ProxyURL(p))
	defer tr.CloseIdleConnections()
	roots := x509.NewCertPool()
	roots.AddCert(target.Certificate())
	tr.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	req, _ := http.NewRequest(http.MethodPost, "https://example.com/v1/chat/completions", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer synthetic-model-key")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "reply" || connects.Load() != 1 {
		t.Fatalf("reply=%q CONNECTs=%d", body, connects.Load())
	}
}

func TestModelEgressProxyRejectsPrivateAndReboundTargets(t *testing.T) {
	var connects atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { connects.Add(1); w.WriteHeader(502) }))
	defer proxy.Close()
	p, _ := url.Parse(proxy.URL)
	for _, ip := range []string{"127.0.0.1", "10.0.0" + ".1", "169.254.169.254", "::1"} {
		t.Run(ip, func(t *testing.T) {
			g := &SSRFGuard{Resolver: stubResolver{ip: net.ParseIP("93.184.216.34")}}
			if err := g.Validate(context.Background(), "https://example.com"); err != nil {
				t.Fatal(err)
			}
			g.Resolver = stubResolver{ip: net.ParseIP(ip)}
			tr := g.httpsModelTransport(http.ProxyURL(p))
			defer tr.CloseIdleConnections()
			c, err := tr.DialContext(context.Background(), "tcp", "example.com:443")
			if c != nil {
				c.Close()
			}
			if err == nil {
				t.Fatal("private target accepted")
			}
		})
	}
	if connects.Load() != 0 {
		t.Fatal("blocked target reached proxy")
	}
}

func TestModelEgressProxyCancellationAndFailure(t *testing.T) {
	for _, status := range []int{0, 407} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if status != 0 {
					w.WriteHeader(status)
					_, _ = io.WriteString(w, "sensitive upstream body")
					return
				}
				<-r.Context().Done()
			}))
			defer proxy.Close()
			p, _ := url.Parse(proxy.URL)
			g := &SSRFGuard{Resolver: stubResolver{ip: net.ParseIP("93.184.216.34")}}
			tr := g.httpsModelTransport(http.ProxyURL(p))
			defer tr.CloseIdleConnections()
			ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
			defer cancel()
			start := time.Now()
			conn, err := tr.DialContext(ctx, "tcp", "example.com:443")
			if conn != nil {
				conn.Close()
			}
			if err == nil || strings.Contains(err.Error(), "sensitive") || time.Since(start) > 2*time.Second {
				t.Fatalf("unbounded/unsafe CONNECT error: %v", err)
			}
		})
	}
}

func TestModelEgressNoProxyUsesDirectDial(t *testing.T) {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	g := &SSRFGuard{AllowedHosts: []string{"127.0.0.1"}}
	tr := g.httpsModelTransport(func(r *http.Request) (*url.URL, error) {
		if r.URL.Scheme != "https" || r.URL.Host != target.Addr().String() {
			t.Error("wrong NO_PROXY lookup")
		}
		return nil, nil
	})
	defer tr.CloseIdleConnections()
	conn, err := tr.DialContext(context.Background(), "tcp", target.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
}
