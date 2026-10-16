package install

import (
	"context"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"hash"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	downloadIdleTimeout  = 90 * time.Second
	downloadTotalTimeout = 45 * time.Minute
	maxRedirects         = 5
	copyChunkBytes       = 256 << 10
)

var (
	errDownloadFailed = errors.New("install: download failed")
	errSizeMismatch   = errors.New("install: size mismatch")
	errHashMismatch   = errors.New("install: hash mismatch")
	errHostDenied     = errors.New("install: download host denied")
)

type downloadClient struct {
	client       *http.Client
	allowedHosts map[string]struct{}
	userAgent    string
	// probeWindow bounds rankSources; zero means defaultProbeWindow.
	probeWindow time.Duration

	// catalogHosts are the hosts a verified catalog additionally allows.
	// They only apply to catalog sources (SourceKindZhibanPackage) and to
	// the redirects such a download follows; built-in sources never gain
	// from them. Replaced whole on every catalog.apply.
	mu           sync.RWMutex
	catalogHosts map[string]struct{}
}

// catalogSourceKey marks a request context as belonging to a catalog source
// so CheckRedirect applies the catalog allow-list to its redirects.
type catalogSourceKey struct{}

func withCatalogSource(ctx context.Context, catalog bool) context.Context {
	if !catalog {
		return ctx
	}
	return context.WithValue(ctx, catalogSourceKey{}, true)
}

func isCatalogSource(ctx context.Context) bool {
	value, _ := ctx.Value(catalogSourceKey{}).(bool)
	return value
}

func hostSet(hosts []string) map[string]struct{} {
	set := make(map[string]struct{}, len(hosts))
	for _, host := range hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host != "" {
			set[host] = struct{}{}
		}
	}
	return set
}

// setCatalogHosts replaces the catalog allow-list; nil clears it.
func (d *downloadClient) setCatalogHosts(hosts []string) {
	set := hostSet(hosts)
	d.mu.Lock()
	d.catalogHosts = set
	d.mu.Unlock()
}

func newDownloadClient(transport http.RoundTripper, allowedHosts []string, userAgent string) *downloadClient {
	if transport == nil {
		// The App starts the Bridge with a minimal environment, so environment
		// proxy variables are never consulted; the user's macOS system HTTPS
		// proxy is honoured because official download hosts may only be
		// reachable through it on some networks. Integrity still rests on the
		// fixed size and SHA-256, not on the transport.
		transport = &http.Transport{
			Proxy: func(*http.Request) (*url.URL, error) {
				return systemHTTPSProxy(), nil
			},
			// Short connect/handshake budgets keep the source fallback chain
			// responsive when a host is silently blocked.
			DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
			TLSHandshakeTimeout:   15 * time.Second,
			ResponseHeaderTimeout: 30 * time.Second,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          4,
			IdleConnTimeout:       30 * time.Second,
		}
	}
	client := &downloadClient{allowedHosts: hostSet(allowedHosts), userAgent: userAgent}
	client.client = &http.Client{
		Transport: transport,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= maxRedirects {
				return errDownloadFailed
			}
			if err := client.validateURL(request.URL, isCatalogSource(request.Context())); err != nil {
				return err
			}
			request.Header.Del("Authorization")
			request.Header.Del("Cookie")
			return nil
		},
	}
	return client
}

// validateURL admits only https URLs on an allowed host: the built-in list
// always, plus the verified catalog's hosts when the download is a catalog
// source. A host with an explicit port matches the catalog entry with that
// port (the Bus lists hosts as they appear in the URLs it hands out).
func (d *downloadClient) validateURL(target *url.URL, catalog bool) error {
	if target == nil || target.Scheme != "https" || target.User != nil || target.Fragment != "" {
		return errHostDenied
	}
	hostname := strings.ToLower(target.Hostname())
	if _, ok := d.allowedHosts[hostname]; ok {
		return nil
	}
	if !catalog {
		return errHostDenied
	}
	d.mu.RLock()
	defer d.mu.RUnlock()
	if _, ok := d.catalogHosts[hostname]; ok {
		return nil
	}
	if _, ok := d.catalogHosts[strings.ToLower(target.Host)]; ok {
		return nil
	}
	return errHostDenied
}

// fetch streams asset into destination, enforcing the fixed size and SHA-256
// while reporting whole-percent progress. It returns the parent context error
// unchanged so the operation registry can classify a cancellation.
func (d *downloadClient) fetch(ctx context.Context, asset Source, destination *os.File, progress func(int)) error {
	parsed, err := url.Parse(asset.URL)
	if err != nil {
		return errHostDenied
	}
	fromCatalog := asset.Kind == SourceKindZhibanPackage
	if err := d.validateURL(parsed, fromCatalog); err != nil {
		return err
	}
	requestCtx, cancel := context.WithTimeout(withCatalogSource(ctx, fromCatalog), downloadTotalTimeout)
	defer cancel()
	idle := time.AfterFunc(downloadIdleTimeout, cancel)
	defer idle.Stop()

	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, asset.URL, nil)
	if err != nil {
		return errDownloadFailed
	}
	request.Header.Set("User-Agent", d.userAgent)
	request.Header.Set("Accept", "application/octet-stream")
	response, err := d.client.Do(request)
	if err != nil {
		return classifyTransport(ctx, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errDownloadFailed
	}
	if response.ContentLength != asset.Size {
		return errSizeMismatch
	}
	if err := d.validateURL(response.Request.URL, fromCatalog); err != nil {
		return err
	}

	hashers := newSourceHashers(asset)
	buffer := make([]byte, copyChunkBytes)
	var received int64
	lastPercent := -1
	if progress != nil {
		progress(0)
		lastPercent = 0
	}
	for {
		read, readErr := response.Body.Read(buffer)
		if read > 0 {
			idle.Reset(downloadIdleTimeout)
			received += int64(read)
			if received > asset.Size {
				return errSizeMismatch
			}
			if _, err := destination.Write(buffer[:read]); err != nil {
				return errDownloadFailed
			}
			hashers.write(buffer[:read])
			if progress != nil {
				percent := int(received * 100 / asset.Size)
				if percent != lastPercent {
					lastPercent = percent
					progress(percent)
				}
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return classifyTransport(ctx, readErr)
		}
	}
	if received != asset.Size {
		return errSizeMismatch
	}
	if !hashers.matches(asset) {
		return errHashMismatch
	}
	if err := destination.Sync(); err != nil {
		return errDownloadFailed
	}
	return nil
}

func classifyTransport(parent context.Context, err error) error {
	if parent.Err() != nil {
		return parent.Err()
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) && errors.Is(urlErr.Err, errHostDenied) {
		return errHostDenied
	}
	if errors.Is(err, errHostDenied) {
		return errHostDenied
	}
	return errDownloadFailed
}

// verifyFile re-reads a downloaded file and compares its digest, guarding
// against on-disk corruption between download and placement.
func verifyFile(ctx context.Context, file *os.File, asset Source) error {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return errHashMismatch
	}
	hashers := newSourceHashers(asset)
	buffer := make([]byte, copyChunkBytes)
	var total int64
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		read, err := file.Read(buffer)
		if read > 0 {
			total += int64(read)
			hashers.write(buffer[:read])
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return errHashMismatch
		}
	}
	if total != asset.Size {
		return errSizeMismatch
	}
	if !hashers.matches(asset) {
		return errHashMismatch
	}
	_, err := file.Seek(0, io.SeekStart)
	return err
}

// sourceHashers computes the digests a source declares: SHA-256 always, and
// SHA-512 when the source carries one (registry-signed host tarballs). A
// digest the source leaves empty is not compared; Source.Validate guarantees
// at least one is set.
type sourceHashers struct {
	sha256 hash.Hash
	sha512 hash.Hash
}

func newSourceHashers(asset Source) sourceHashers {
	hashers := sourceHashers{sha256: sha256.New()}
	if asset.SHA512 != "" {
		hashers.sha512 = sha512.New()
	}
	return hashers
}

func (h sourceHashers) write(data []byte) {
	_, _ = h.sha256.Write(data)
	if h.sha512 != nil {
		_, _ = h.sha512.Write(data)
	}
}

func (h sourceHashers) matches(asset Source) bool {
	if asset.SHA256 == "" && asset.SHA512 == "" {
		return false
	}
	if asset.SHA256 != "" && hex.EncodeToString(h.sha256.Sum(nil)) != asset.SHA256 {
		return false
	}
	if asset.SHA512 != "" && (h.sha512 == nil || hex.EncodeToString(h.sha512.Sum(nil)) != asset.SHA512) {
		return false
	}
	return true
}
