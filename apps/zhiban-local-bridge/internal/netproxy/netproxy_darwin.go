//go:build darwin

package netproxy

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const (
	agentLabel  = "cn.qkfintech.zhiban.no-proxy"
	blockBegin  = "# >>> zhiban-ai no_proxy >>>"
	blockEnd    = "# <<< zhiban-ai no_proxy <<<"
	commandWait = 5 * time.Second
)

type darwinPlatform struct {
	homeDir string
	lookup  *shellenv.LoginShellLookup
}

func newPlatform(homeDir string, lookup *shellenv.LoginShellLookup) platform {
	return &darwinPlatform{homeDir: homeDir, lookup: lookup}
}

func (p *darwinPlatform) supported() bool { return p.homeDir != "" }

// systemProxy reads `scutil --proxy`: any of HTTP / HTTPS / SOCKS enabled.
func (p *darwinPlatform) systemProxy(ctx context.Context) SystemProxy {
	output, err := runCommand(ctx, "/usr/sbin/scutil", "--proxy")
	if err != nil {
		return SystemProxy{}
	}
	return parseScutilProxy(output)
}

func parseScutilProxy(output []byte) SystemProxy {
	values := map[string]string{}
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), " : ")
		if found {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	for _, kind := range []string{"HTTPS", "HTTP", "SOCKS"} {
		if values[kind+"Enable"] == "1" && values[kind+"Proxy"] != "" {
			endpoint := values[kind+"Proxy"]
			if port := values[kind+"Port"]; port != "" {
				endpoint += ":" + port
			}
			return SystemProxy{Enabled: true, Endpoint: endpoint}
		}
	}
	return SystemProxy{}
}

func (p *darwinPlatform) coverage(ctx context.Context, hosts []string) map[string]bool {
	shellValue := p.lookup.Variable(ctx, "NO_PROXY")
	if shellValue == "" {
		shellValue = p.lookup.Variable(ctx, "no_proxy")
	}
	shellCovered := p.lookup == nil || covers(shellValue, hosts)
	if !shellCovered && !p.lookup.VariablesKnown(ctx) {
		// The login shell never answered (slow startup files): "could not
		// read" must not become "not exempted", or the card keeps asking for
		// a fix that is already in place. The block Zhiban wrote is the
		// evidence that remains.
		shellCovered = p.shellBlockPresent(hosts)
	}
	_, agentErr := os.Stat(p.agentPath())
	bypass := false
	if output, err := runCommand(ctx, "/usr/sbin/scutil", "--proxy"); err == nil {
		bypass = bypassCovers(parseScutilExceptions(output), plainHosts(hosts))
	}
	return map[string]bool{
		"launchd":           covers(p.noProxy(ctx), hosts),
		"shell":             shellCovered,
		"agent":             agentErr == nil,
		coveredSystemBypass: bypass,
	}
}

// parseScutilExceptions reads the effective proxy bypass list out of
// `scutil --proxy` ("ExceptionsList : <array> { 0 : host … }"): what clients
// on the system network stack (Chromium, so Claude Desktop) honour.
func parseScutilExceptions(output []byte) []string {
	var exceptions []string
	inside := false
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch {
		case strings.HasPrefix(line, "ExceptionsList"):
			inside = true
		case inside && line == "}":
			return exceptions
		case inside:
			if _, value, found := strings.Cut(line, " : "); found {
				exceptions = append(exceptions, strings.TrimSpace(value))
			}
		}
	}
	return exceptions
}

// parseNetworkServices lists the enabled services of
// `networksetup -listallnetworkservices` (first line is a legend, a leading
// asterisk marks a disabled service).
func parseNetworkServices(output []byte) []string {
	var services []string
	for index, line := range strings.Split(strings.ReplaceAll(string(output), "\r", ""), "\n") {
		line = strings.TrimSpace(line)
		if index == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	return services
}

// parseBypassDomains reads `networksetup -getproxybypassdomains`: one domain
// per line, or a sentence when there are none.
func parseBypassDomains(output []byte) []string {
	var domains []string
	for _, line := range strings.Split(strings.ReplaceAll(string(output), "\r", ""), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.Contains(line, " ") {
			continue
		}
		domains = append(domains, line)
	}
	return domains
}

// applyBypassDomains adds the gateway to the bypass list of every network
// service that has a proxy switched on, for clients on the system network
// stack. Best effort: networksetup refuses without admin rights, the status
// then keeps reporting the list as not covering and NO_PROXY still serves
// the CLIs (contract §2.7, 2026-09-18).
func (p *darwinPlatform) applyBypassDomains(ctx context.Context, hosts []string) {
	const tool = "/usr/sbin/networksetup"
	listing, err := runCommand(ctx, tool, "-listallnetworkservices")
	if err != nil {
		return
	}
	for _, service := range parseNetworkServices(listing) {
		proxied := false
		for _, query := range []string{"-getsecurewebproxy", "-getwebproxy", "-getsocksfirewallproxy"} {
			if output, err := runCommand(ctx, tool, query, service); err == nil && strings.Contains(string(output), "Enabled: Yes") {
				proxied = true
				break
			}
		}
		if !proxied {
			continue
		}
		current, err := runCommand(ctx, tool, "-getproxybypassdomains", service)
		if err != nil {
			continue
		}
		merged, added := mergeBypass(parseBypassDomains(current), bypassEntries(hosts))
		if len(added) == 0 {
			continue
		}
		_, _ = runCommand(ctx, tool, append([]string{"-setproxybypassdomains", service}, merged...)...)
	}
}

// shellBlockPresent reports whether the login shell's startup file carries
// Zhiban's marked block naming every host.
func (p *darwinPlatform) shellBlockPresent(hosts []string) bool {
	path := ""
	switch filepath.Base(p.lookup.Shell) {
	case "zsh":
		path = filepath.Join(p.homeDir, ".zshrc")
	case "bash":
		path = filepath.Join(p.homeDir, ".bash_profile")
	case "fish":
		path = p.fishPath()
	default:
		return false
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	text := string(content)
	start := strings.Index(text, blockBegin)
	if start < 0 {
		return false
	}
	end := strings.Index(text[start:], blockEnd)
	if end < 0 {
		return false
	}
	block := text[start : start+end]
	for _, host := range hosts {
		if !strings.Contains(block, host) {
			return false
		}
	}
	return true
}

func (p *darwinPlatform) noProxy(ctx context.Context) string {
	for _, name := range []string{"NO_PROXY", "no_proxy"} {
		if value := launchctlGetenv(ctx, name); value != "" {
			return value
		}
	}
	return ""
}

func (p *darwinPlatform) apply(ctx context.Context, hosts []string) error {
	for _, name := range []string{"NO_PROXY", "no_proxy"} {
		merged, _ := mergeList(launchctlGetenv(ctx, name), hosts)
		if _, err := runCommand(ctx, "/bin/launchctl", "setenv", name, merged); err != nil {
			return err
		}
	}
	if err := p.writeAgent(hosts); err != nil {
		return err
	}
	if err := p.writeShellBlock(hosts); err != nil {
		return err
	}
	p.lookup.Invalidate()
	p.applyBypassDomains(ctx, hosts)
	return nil
}

func (p *darwinPlatform) agentPath() string {
	return filepath.Join(p.homeDir, "Library", "LaunchAgents", agentLabel+".plist")
}

func (p *darwinPlatform) fishPath() string {
	return filepath.Join(p.homeDir, ".config", "fish", "conf.d", "zhiban-no-proxy.fish")
}

// writeAgent installs a login item that merges the hosts into launchd's
// NO_PROXY at every login: launchctl setenv alone is lost on restart.
func (p *darwinPlatform) writeAgent(hosts []string) error {
	var script strings.Builder
	for _, name := range []string{"NO_PROXY", "no_proxy"} {
		script.WriteString("v=$(/bin/launchctl getenv " + name + "); for h in " + strings.Join(hosts, " ") +
			`; do case ",$v," in *",$h,"*) ;; *) v="${v:+$v,}$h" ;; esac; done; /bin/launchctl setenv ` + name + ` "$v"; `)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + agentLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>` + xmlEscape(script.String()) + `</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
`
	if err := os.MkdirAll(filepath.Dir(p.agentPath()), 0o755); err != nil {
		return err
	}
	return writeFileAtomic(p.agentPath(), []byte(plist), 0o644)
}

// writeShellBlock appends (or replaces) a marked block in the login shell's
// startup file so terminals opened later exempt the gateway too.
func (p *darwinPlatform) writeShellBlock(hosts []string) error {
	shell := ""
	if p.lookup != nil {
		shell = filepath.Base(p.lookup.Shell)
	}
	switch shell {
	case "zsh":
		return replaceBlock(filepath.Join(p.homeDir, ".zshrc"), posixBlock(hosts))
	case "bash":
		return replaceBlock(filepath.Join(p.homeDir, ".bash_profile"), posixBlock(hosts))
	case "fish":
		if err := os.MkdirAll(filepath.Dir(p.fishPath()), 0o755); err != nil {
			return err
		}
		return writeFileAtomic(p.fishPath(), []byte(fishBlock(hosts)), 0o644)
	default:
		// sh / tcsh / others: launchd + the login item still cover GUI apps.
		return nil
	}
}

func posixBlock(hosts []string) string {
	return blockBegin + `
# 知办 AI：让 Codex 等工具直连知办中转站、不走系统代理（整段由知办写入，删掉即还原）
for __zb_h in ` + strings.Join(hosts, " ") + `; do
  case ",${NO_PROXY}," in *",${__zb_h},"*) ;; *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${__zb_h}" ;; esac
  case ",${no_proxy}," in *",${__zb_h},"*) ;; *) no_proxy="${no_proxy:+${no_proxy},}${__zb_h}" ;; esac
done
unset __zb_h
export NO_PROXY no_proxy
` + blockEnd + "\n"
}

func fishBlock(hosts []string) string {
	return blockBegin + `
# 知办 AI：让 Codex 等工具直连知办中转站、不走系统代理（整段由知办写入，删掉即还原）
for __zb_h in ` + strings.Join(hosts, " ") + `
    if not contains -- $__zb_h (string split -n , -- "$NO_PROXY")
        set -gx NO_PROXY (string join , -- (string split -n , -- "$NO_PROXY") $__zb_h)
    end
    if not contains -- $__zb_h (string split -n , -- "$no_proxy")
        set -gx no_proxy (string join , -- (string split -n , -- "$no_proxy") $__zb_h)
    end
end
` + blockEnd + "\n"
}

// replaceBlock rewrites path with the marked block removed and block
// appended, following a symlinked dotfile to its target so the link survives.
func replaceBlock(path, block string) error {
	target, mode, content, err := readStartupFile(path)
	if err != nil {
		return err
	}
	text := stripBlock(string(content))
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	if text != "" {
		text += "\n"
	}
	return writeFileAtomic(target, []byte(text+block), mode)
}

func readStartupFile(path string) (string, os.FileMode, []byte, error) {
	target := path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		target = resolved
	}
	info, err := os.Stat(target)
	if errors.Is(err, os.ErrNotExist) {
		return target, 0o644, nil, nil
	}
	if err != nil {
		return "", 0, nil, err
	}
	if !info.Mode().IsRegular() {
		return "", 0, nil, errors.New("netproxy: startup file is not a regular file")
	}
	content, err := os.ReadFile(target)
	return target, info.Mode().Perm(), content, err
}

// stripBlock removes every marked block (and one blank line before it).
func stripBlock(text string) string {
	for {
		start := strings.Index(text, blockBegin)
		if start < 0 {
			return text
		}
		end := strings.Index(text[start:], blockEnd)
		if end < 0 {
			return text
		}
		end = start + end + len(blockEnd)
		if end < len(text) && text[end] == '\n' {
			end++
		}
		prefix := text[:start]
		if strings.HasSuffix(prefix, "\n\n") {
			prefix = prefix[:len(prefix)-1]
		}
		text = prefix + text[end:]
	}
}

func launchctlGetenv(ctx context.Context, name string) string {
	output, err := runCommand(ctx, "/bin/launchctl", "getenv", name)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func runCommand(ctx context.Context, name string, arguments ...string) ([]byte, error) {
	commandCtx, cancel := context.WithTimeout(ctx, commandWait)
	defer cancel()
	command := exec.CommandContext(commandCtx, name, arguments...)
	command.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C"}
	return command.Output()
}

func xmlEscape(value string) string {
	replacer := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&apos;")
	return replacer.Replace(value)
}
