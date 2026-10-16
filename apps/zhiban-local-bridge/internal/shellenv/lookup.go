// Package shellenv answers questions about the user's own command-line
// environment that a GUI app cannot see from its own PATH (contract §2.7,
// 2026-09-14): which copy of a CLI the user's shell runs, and where the Node
// runtime an npm-installed CLI needs lives.
package shellenv

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// nvm / conda / oh-my-zsh 让登录 shell 启动轻松超过 2 秒(2026-09-17 真机 1.7～2.2 秒):
	// 超时既读不到 NO_PROXY,也解析不出 codex / claude / node 的位置。结果按 TTL 缓存,放宽的代价只在首次。
	lookupTimeout = 5 * time.Second
	lookupTTL     = 30 * time.Second
	fallbackShell = "/bin/zsh"
	marker        = "__ZHIBAN_LOOKUP__"
)

// lookupNames are resolved together: one shell start per TTL.
var lookupNames = []string{"codex", "claude", "node"}

// lookupVariables are the environment values the login shell ends up with
// after its startup files (the proxy exemption, contract §2.7 network.*).
var lookupVariables = []string{"NO_PROXY", "no_proxy"}

const variableMarker = "__ZHIBAN_ENV__"

// LoginShellLookup asks the user's login shell which executable a command
// name runs. nvm, fnm, asdf and custom npm prefixes are set up by shell
// startup files, so only the login shell sees them. The shell runs with an
// empty stdin, a minimal environment and a hard timeout that kills its whole
// process group; only absolute paths are accepted (aliases and functions are
// ignored). All names are resolved in one run and cached. A nil lookup answers
// nothing.
type LoginShellLookup struct {
	HomeDir string
	Shell   string
	Timeout time.Duration
	TTL     time.Duration

	mu        sync.Mutex
	cached    map[string]string
	variables map[string]string
	cachedAt  time.Time
}

// NewLoginShellLookup uses $SHELL when /etc/shells lists it, else /bin/zsh.
// It returns nil where there is no login shell to ask (Windows).
func NewLoginShellLookup(homeDir string) *LoginShellLookup {
	if !loginShellSupported {
		return nil
	}
	registered, _ := os.ReadFile("/etc/shells")
	return &LoginShellLookup{
		HomeDir: homeDir,
		Shell:   chooseLoginShell(os.Getenv("SHELL"), string(registered)),
		Timeout: lookupTimeout,
		TTL:     lookupTTL,
	}
}

// chooseLoginShell accepts $SHELL only when it is an absolute path listed in
// /etc/shells; anything else falls back to /bin/zsh.
func chooseLoginShell(value, registered string) string {
	value = strings.TrimSpace(value)
	if value == "" || !filepath.IsAbs(value) || strings.ContainsAny(value, " \t") {
		return fallbackShell
	}
	for _, line := range strings.Split(registered, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") && line == value {
			return value
		}
	}
	return fallbackShell
}

// Lookup returns the absolute path the login shell resolves name to.
func (l *LoginShellLookup) Lookup(ctx context.Context, name string) (string, bool) {
	if l == nil {
		return "", false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refreshLocked(ctx)
	path, ok := l.cached[name]
	return path, ok
}

// Variable returns an environment value the login shell ends up with.
func (l *LoginShellLookup) Variable(ctx context.Context, name string) string {
	if l == nil {
		return ""
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refreshLocked(ctx)
	return l.variables[name]
}

// VariablesKnown reports whether the login shell answered at all. A shell
// killed by the timeout prints nothing: its variables are unknown, which is
// not the same as unset.
func (l *LoginShellLookup) VariablesKnown(ctx context.Context) bool {
	if l == nil {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refreshLocked(ctx)
	return len(l.variables) > 0
}

// Invalidate drops the cached answers, e.g. after a startup file changed.
func (l *LoginShellLookup) Invalidate() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.cached = nil
	l.variables = nil
}

func (l *LoginShellLookup) refreshLocked(ctx context.Context) {
	ttl := l.TTL
	if ttl <= 0 {
		ttl = lookupTTL
	}
	if l.cached == nil || time.Since(l.cachedAt) > ttl {
		output := l.run(ctx)
		l.cached = parseLookup(output)
		l.variables = parseVariables(output)
		l.cachedAt = time.Now()
	}
}

func parseVariables(output []byte) map[string]string {
	result := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		index := strings.Index(line, variableMarker)
		if index < 0 {
			continue
		}
		name, value, found := strings.Cut(line[index+len(variableMarker):], "=")
		if !found {
			continue
		}
		for _, known := range lookupVariables {
			if name == known {
				result[name] = strings.TrimSpace(strings.TrimRight(value, "\r"))
			}
		}
	}
	return result
}

func parseLookup(output []byte) map[string]string {
	result := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		index := strings.Index(line, marker)
		if index < 0 {
			continue
		}
		name, value, found := strings.Cut(line[index+len(marker):], "=")
		value = strings.TrimSpace(strings.TrimRight(value, "\r"))
		if !found || value == "" || !filepath.IsAbs(value) || strings.ContainsRune(value, 0) {
			continue
		}
		for _, known := range lookupNames {
			if name == known {
				result[name] = filepath.Clean(value)
			}
		}
	}
	return result
}
