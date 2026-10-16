// Package netproxy detects and fixes the system proxy intercepting Codex's
// requests to the Zhiban gateway (contract §2.7 network.*, 2026-09-14).
//
// Codex's HTTP client follows the system proxy (macOS network settings,
// Windows Internet Settings) and only honours NO_PROXY, not the system
// proxy's own exception list. Behind Clash-like proxies its tunnel to the
// relay drops and Codex reconnects forever. The fix is to add the gateway
// hosts — and nothing else — to NO_PROXY wherever new processes read it.
package netproxy

import (
	"context"
	"crypto/tls"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const (
	codeUnsupported       = "LCT-BRIDGE-NETWORK-UNSUPPORTED"
	codeDirectUnreachable = "LCT-BRIDGE-NETWORK-DIRECT_UNREACHABLE"
	codeApplyFailed       = "LCT-BRIDGE-NETWORK-APPLY_FAILED"

	dialTimeout = 3 * time.Second
)

// hostPattern keeps hosts written into shell startup files and launchd plists
// to plain DNS names: they come from compiled profiles, never from input.
var hostPattern = regexp.MustCompile(`^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

// Status is the network.proxy_status result.
type Status struct {
	Supported       bool            `json:"supported"`
	SystemProxy     SystemProxy     `json:"system_proxy"`
	GatewayHosts    []string        `json:"gateway_hosts"`
	Covered         map[string]bool `json:"covered"`
	DirectReachable bool            `json:"direct_reachable"`
	NeedsFix        bool            `json:"needs_fix"`
	// EnvNeedsFix is NeedsFix without the system bypass list: what decides
	// whether a CLI (NO_PROXY readers) is intercepted. The bypass list only
	// matters to clients on the system network stack (Claude Desktop).
	EnvNeedsFix bool `json:"env_needs_fix"`
}

// coveredSystemBypass is the Covered key for the operating system's proxy
// bypass list (Windows ProxyOverride, macOS ExceptionsList). Chromium-based
// clients honour it and ignore NO_PROXY; reqwest and Node are the reverse
// (contract §2.7, 2026-09-18).
const coveredSystemBypass = "system_bypass"

// SystemProxy is the proxy the operating system hands to applications.
type SystemProxy struct {
	Enabled  bool   `json:"enabled"`
	Endpoint string `json:"endpoint,omitempty"`
}

// platform is the per-OS half (netproxy_darwin.go, netproxy_windows.go).
type platform interface {
	supported() bool
	systemProxy(ctx context.Context) SystemProxy
	coverage(ctx context.Context, hosts []string) map[string]bool
	// apply merges hosts into NO_PROXY everywhere new processes read it.
	// There is no revert: the entries only exempt the Zhiban gateway.
	apply(ctx context.Context, hosts []string) error
	// noProxy returns the NO_PROXY value a newly started process gets.
	noProxy(ctx context.Context) string
}

// Config configures a Manager.
type Config struct {
	HomeDir string
	// GatewayURLs are the compiled gateway base URLs of every environment.
	GatewayURLs []string
	Lookup      *shellenv.LoginShellLookup
	// Dial overrides the direct reachability check (tests).
	Dial func(ctx context.Context, host string) bool
}

// Manager implements network.proxy_status / proxy_apply.
type Manager struct {
	hosts     []string
	dialHosts []string
	platform  platform
	dial      func(ctx context.Context, host string) bool
	resolve   func(ctx context.Context, host string) []net.IP
	mu        sync.Mutex
}

// NewManager returns a Manager for this platform.
func NewManager(config Config) *Manager {
	hosts, dialHosts := GatewayHosts(config.GatewayURLs)
	dial := config.Dial
	if dial == nil {
		dial = dialDirect
	}
	return &Manager{
		hosts: hosts, dialHosts: dialHosts,
		platform: newPlatform(config.HomeDir, config.Lookup), dial: dial, resolve: resolveHost,
	}
}

// GatewayHosts turns gateway base URLs into NO_PROXY entries (each host, its
// dotted parent and the parent itself) and the hosts to dial.
func GatewayHosts(urls []string) (entries []string, dialHosts []string) {
	seen := map[string]bool{}
	add := func(list *[]string, value string) {
		if value != "" && hostPattern.MatchString(value) && !seen[value] {
			seen[value] = true
			*list = append(*list, value)
		}
	}
	for _, raw := range urls {
		parsed, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || parsed.Scheme != "https" {
			continue
		}
		host := strings.ToLower(parsed.Hostname())
		if host == "" || net.ParseIP(host) != nil {
			continue
		}
		before := len(entries)
		add(&entries, host)
		if len(entries) > before {
			dialHosts = append(dialHosts, host)
		}
		if labels := strings.Split(host, "."); len(labels) >= 3 {
			parent := strings.Join(labels[1:], ".")
			add(&entries, "."+parent)
			add(&entries, parent)
		}
	}
	return entries, dialHosts
}

// Status reports whether the system proxy intercepts the gateway.
func (m *Manager) Status(ctx context.Context) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statusLocked(ctx), nil
}

// EnvNeedsFix reports whether a CLI's requests to the gateway would go through
// a proxy that has not been told to leave it alone (NO_PROXY not covering it).
func (m *Manager) EnvNeedsFix(ctx context.Context) bool {
	status, _ := m.Status(ctx)
	return status.EnvNeedsFix
}

func (m *Manager) statusLocked(ctx context.Context) Status {
	status := Status{Supported: m.platform.supported(), GatewayHosts: append([]string(nil), m.hosts...), Covered: map[string]bool{}}
	if !status.Supported || len(m.hosts) == 0 {
		status.Supported = false
		return status
	}
	status.SystemProxy = m.platform.systemProxy(ctx)
	status.Covered = m.platform.coverage(ctx, m.hosts)
	if !status.SystemProxy.Enabled {
		return status
	}
	status.DirectReachable = m.reachable(ctx)
	allCovered := true
	for _, covered := range status.Covered {
		allCovered = allCovered && covered
	}
	status.NeedsFix = status.DirectReachable && !allCovered
	status.EnvNeedsFix = status.DirectReachable && !environmentCovered(status.Covered)
	return status
}

// environmentCovered reports that every NO_PROXY source names the gateway.
func environmentCovered(covered map[string]bool) bool {
	all, any := true, false
	for name, value := range covered {
		if name == coveredSystemBypass {
			continue
		}
		any = true
		all = all && value
	}
	return any && all
}

// DirectPathUnreachable reports that a CLI the user starts would connect to
// the gateway without a proxy and that this direct path does not answer: a
// proxy tool in TUN mode, a firewall, no network. The L3 probe then fails fast
// instead of reconnecting for the full timeout (contract §2.7, 2026-09-18).
//
// When the CLI would go through a proxy (system proxy or HTTPS_PROXY /
// ALL_PROXY, gateway not covered by NO_PROXY) a direct handshake says nothing
// about its path, corporate networks routinely block direct egress: report
// false and leave the probe alone.
func (m *Manager) DirectPathUnreachable(ctx context.Context) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.dialHosts) == 0 {
		return false
	}
	status := m.statusLocked(ctx)
	covered := environmentCovered(status.Covered)
	if !covered && (status.SystemProxy.Enabled || environmentProxyConfigured()) {
		return false
	}
	if status.SystemProxy.Enabled {
		// statusLocked already dialed.
		return !status.DirectReachable
	}
	return !m.reachable(ctx)
}

// TrafficDiverted reports the situation a failed L3 probe is most likely
// explained by: proxy software is active on this machine, the Bridge itself
// reaches the gateway directly, and yet the tool's request did not get there.
// Proxy tools route by process name (PROCESS-NAME rules for Codex / Claude) or
// send everything to a node (global mode): the domestic gateway goes abroad
// with it and the connection is closed or never answered. NO_PROXY and the
// bypass list cannot help in TUN mode, only a rule in the proxy tool can, so
// the caller reports it instead of retrying (contract §2.7, 2026-09-18).
func (m *Manager) TrafficDiverted(ctx context.Context) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.dialHosts) == 0 {
		return false
	}
	active := m.platform.systemProxy(ctx).Enabled
	for _, host := range m.dialHosts {
		if active {
			break
		}
		active = fakeAddress(m.resolve(ctx, host))
	}
	return active && m.reachable(ctx)
}

// fakeRange is 198.18.0.0/15, the range Clash / mihomo / Surge hand out in
// fake-IP (TUN, enhanced) mode: a gateway name resolving into it means the
// tool's traffic is being captured at the network layer.
var fakeRange = &net.IPNet{IP: net.IPv4(198, 18, 0, 0), Mask: net.CIDRMask(15, 32)}

func fakeAddress(addresses []net.IP) bool {
	for _, address := range addresses {
		if fakeRange.Contains(address) {
			return true
		}
	}
	return false
}

func resolveHost(ctx context.Context, host string) []net.IP {
	lookupCtx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	records, err := net.DefaultResolver.LookupIPAddr(lookupCtx, host)
	if err != nil {
		return nil
	}
	addresses := make([]net.IP, 0, len(records))
	for _, record := range records {
		addresses = append(addresses, record.IP)
	}
	return addresses
}

// environmentProxyConfigured reports a proxy variable that applies to the
// HTTPS gateway in the environment the CLI inherits.
func environmentProxyConfigured() bool {
	for _, name := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"} {
		if strings.TrimSpace(os.Getenv(name)) != "" {
			return true
		}
	}
	return false
}

func (m *Manager) reachable(ctx context.Context) bool {
	for _, host := range m.dialHosts {
		if m.dial(ctx, host) {
			return true
		}
	}
	return false
}

// Apply adds the gateway hosts to NO_PROXY. It refuses when the gateway is not
// reachable without the proxy (networks that must go through it).
func (m *Manager) Apply(ctx context.Context) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.platform.supported() || len(m.hosts) == 0 {
		return Status{}, operation.Fail(codeUnsupported, nil)
	}
	if !m.reachable(ctx) {
		return Status{}, operation.Fail(codeDirectUnreachable, nil)
	}
	if err := m.platform.apply(ctx, m.hosts); err != nil {
		return Status{}, operation.Fail(codeApplyFailed, err)
	}
	return m.statusLocked(ctx), nil
}

// ProbeEnvironment is what a CLI started by the Bridge must see to behave like
// one the user starts: the proxy variables of the Bridge's own environment,
// with NO_PROXY / no_proxy replaced by the value new processes get now (so a
// fix applied a moment ago counts without restarting the App).
func (m *Manager) ProbeEnvironment(ctx context.Context) []string {
	values := map[string]string{}
	for _, name := range []string{"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"} {
		if value, ok := os.LookupEnv(name); ok {
			values[name] = value
		}
	}
	if current := m.platform.noProxy(ctx); current != "" {
		values["NO_PROXY"] = current
		values["no_proxy"] = current
	}
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	environment := make([]string, 0, len(names))
	for _, name := range names {
		environment = append(environment, name+"="+values[name])
	}
	return environment
}

// plainHosts drops the dotted-parent NO_PROXY entries: the names a bypass
// list has to match.
func plainHosts(hosts []string) []string {
	plain := make([]string, 0, len(hosts))
	for _, host := range hosts {
		if !strings.HasPrefix(host, ".") {
			plain = append(plain, host)
		}
	}
	return plain
}

// bypassEntries turns NO_PROXY entries into the form system bypass lists use:
// ".airick.cn" becomes "*.airick.cn", plain hosts stay.
func bypassEntries(hosts []string) []string {
	entries := make([]string, 0, len(hosts))
	for _, host := range hosts {
		if strings.HasPrefix(host, ".") {
			host = "*" + host
		}
		entries = append(entries, host)
	}
	return entries
}

// bypassCovers reports that every gateway host is matched by an entry of the
// system bypass list: the host itself, a "*.parent" / ".parent" wildcard, or "*".
func bypassCovers(list []string, dialHosts []string) bool {
	if len(dialHosts) == 0 {
		return false
	}
	for _, host := range dialHosts {
		matched := false
		for _, entry := range list {
			entry = strings.ToLower(strings.TrimSpace(entry))
			switch {
			case entry == "":
			case entry == "*" || entry == host:
				matched = true
			case strings.HasPrefix(entry, "*."):
				matched = strings.HasSuffix(host, entry[1:])
			case strings.HasPrefix(entry, "."):
				matched = strings.HasSuffix(host, entry)
			}
			if matched {
				break
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

// mergeBypass appends the entries missing from a system bypass list, keeping
// what is there in place.
func mergeBypass(existing []string, entries []string) (merged []string, added []string) {
	present := map[string]bool{}
	for _, entry := range existing {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		merged = append(merged, entry)
		present[strings.ToLower(entry)] = true
	}
	for _, entry := range entries {
		if !present[strings.ToLower(entry)] {
			present[strings.ToLower(entry)] = true
			merged = append(merged, entry)
			added = append(added, entry)
		}
	}
	return merged, added
}

// mergeList appends the hosts missing from a comma-separated NO_PROXY value.
func mergeList(existing string, hosts []string) (string, []string) {
	present := map[string]bool{}
	var entries []string
	for _, entry := range strings.Split(existing, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		entries = append(entries, entry)
		present[strings.ToLower(entry)] = true
	}
	var added []string
	for _, host := range hosts {
		if !present[host] {
			entries = append(entries, host)
			added = append(added, host)
			present[host] = true
		}
	}
	return strings.Join(entries, ","), added
}

// covers reports whether a NO_PROXY value exempts every host.
func covers(value string, hosts []string) bool {
	present := map[string]bool{}
	for _, entry := range strings.Split(value, ",") {
		entry = strings.ToLower(strings.TrimSpace(entry))
		if entry == "*" {
			return true
		}
		present[entry] = true
	}
	for _, host := range hosts {
		if !present[host] {
			return false
		}
	}
	return true
}

// dialDirect completes a TLS handshake with host:443 without any proxy.
func dialDirect(ctx context.Context, host string) bool {
	dialCtx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	dialer := &tls.Dialer{NetDialer: &net.Dialer{}, Config: &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}}
	connection, err := dialer.DialContext(dialCtx, "tcp", net.JoinHostPort(host, "443"))
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func writeFileAtomic(path string, content []byte, mode os.FileMode) error {
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer func() { _ = os.Remove(name) }()
	if _, err := temporary.Write(content); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
