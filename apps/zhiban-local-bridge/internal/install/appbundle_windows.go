//go:build windows

package install

// Windows desktop applications (M3-W). Windows has no bundle to unpack: a
// desktop asset is a signed MSIX the OS registers. The tools here answer the
// two questions the shared pipeline asks about an app on this platform —
// "does this file carry the publisher's Authenticode signature" and "is the
// app running" — through PowerShell, the way macOS delegates to codesign,
// spctl and ps. Every argument is a literal or a path the Bridge computed
// itself, and the child never gets a console window.

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var fmtSprintf = fmt.Sprintf

const (
	bundleVerifyTimeout = 2 * time.Minute
	bundleInUseTimeout  = 20 * time.Second
	maxToolOutputBytes  = 64 << 10

	createNoWindow = 0x08000000
	// tokenElevationType (TOKEN_INFORMATION_CLASS) and its three values.
	tokenElevationType        = 18
	tokenElevationTypeDefault = 1
	tokenElevationTypeFull    = 2
	tokenElevationTypeLimited = 3
)

// defaultBundleTools: signature and in-use checks are real, the macOS
// unpack/assess steps have no Windows counterpart and must never be reached.
func defaultBundleTools() BundleTools {
	return BundleTools{
		ExtractZip:   func(context.Context, string, string) error { return syscall.ENOTSUP },
		ExtractDMG:   func(context.Context, string, string, []string) error { return syscall.ENOTSUP },
		VerifyBundle: authenticodeVerify,
		AssessBundle: func(context.Context, string) error { return nil },
		BundleInUse:  processRunsUnder,
	}
}

func powershellPath() string {
	root := strings.TrimSpace(os.Getenv("SystemRoot"))
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
}

// runPowerShell runs one script with no profile, no prompts and no window,
// keeping at most maxToolOutputBytes of its combined output.
func runPowerShell(ctx context.Context, timeout time.Duration, script string) ([]byte, int, error) {
	toolContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command := exec.CommandContext(toolContext, powershellPath(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	command.Stdin = nil
	output := &limitedBuffer{}
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return output.Bytes(), -1, err
		}
	}
	return output.Bytes(), exitCode, nil
}

// psQuote wraps a value for a single-quoted PowerShell string literal.
func psQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

// debugLog appends one line to the file named by ZHIBAN_BRIDGE_DEBUG_LOG when
// that variable is set (never by the App; a diagnosis aid for a test machine).
// Values are never secrets: tool exit codes, statuses and subjects.
func debugLog(format string, arguments ...any) {
	path := strings.TrimSpace(os.Getenv("ZHIBAN_BRIDGE_DEBUG_LOG"))
	if path == "" {
		return
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = file.WriteString(time.Now().UTC().Format(time.RFC3339) + " " + strings.TrimSpace(strings.ReplaceAll(fmtSprintf(format, arguments...), "\r\n", " | ")) + "\n")
}

// authenticodeVerify accepts a file whose Authenticode signature chains to a
// trusted root (Get-AuthenticodeSignature Status Valid) and whose signer
// certificate subject CN equals requirement.
func authenticodeVerify(ctx context.Context, path, requirement string) error {
	if !filepath.IsAbs(path) || strings.TrimSpace(requirement) == "" {
		return errPublisherMismatch
	}
	script := "$s = Get-AuthenticodeSignature -LiteralPath " + psQuote(path) + "; " +
		"Write-Output ('STATUS=' + $s.Status); " +
		"if ($s.SignerCertificate) { Write-Output ('SUBJECT=' + $s.SignerCertificate.Subject) }; " +
		"if ($s.Status -eq 'Valid') { exit 0 } else { exit 2 }"
	output, code, err := runPowerShell(ctx, bundleVerifyTimeout, script)
	debugLog("authenticode %s: code=%d err=%v output=%q", filepath.Base(path), code, err, string(output))
	if err != nil {
		return err
	}
	status, subject := "", ""
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch {
		case strings.HasPrefix(line, "STATUS="):
			status = strings.TrimPrefix(line, "STATUS=")
		case strings.HasPrefix(line, "SUBJECT="):
			subject = strings.TrimPrefix(line, "SUBJECT=")
		}
	}
	if code != 0 || status != "Valid" || subjectCommonName(subject) != requirement {
		return errPublisherMismatch
	}
	return nil
}

// subjectCommonName extracts the CN attribute of an X.500 subject as
// PowerShell prints it: `CN="Anthropic, PBC", O=…` or `CN=50BDFD77-…`.
func subjectCommonName(subject string) string {
	offset := 0
	for {
		index := strings.Index(subject[offset:], "CN=")
		if index < 0 {
			return ""
		}
		index += offset
		offset = index + 3
		// Only a CN attribute, not the tail of another attribute name.
		if index > 0 && subject[index-1] != ' ' && subject[index-1] != ',' {
			continue
		}
		rest := subject[index+3:]
		if strings.HasPrefix(rest, "\"") {
			end := strings.Index(rest[1:], "\"")
			if end < 0 {
				return ""
			}
			return rest[1 : 1+end]
		}
		if end := strings.Index(rest, ","); end >= 0 {
			return strings.TrimSpace(rest[:end])
		}
		return strings.TrimSpace(rest)
	}
}

// processRunsUnder reports whether any process executes from inside root
// (a registered package's folder). Processes whose image path cannot be read
// (other users, elevated) are not counted.
func processRunsUnder(root string) (bool, error) {
	if !filepath.IsAbs(root) {
		return false, errUnsafePath
	}
	prefix := strings.TrimRight(filepath.Clean(root), `\`) + `\`
	script := "$root = " + psQuote(prefix) + "; $n = 0; " +
		"foreach ($p in Get-Process) { $path = $null; try { $path = $p.Path } catch { $path = $null }; " +
		"if ($path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $n++ } }; Write-Output $n"
	output, code, err := runPowerShell(context.Background(), bundleInUseTimeout, script)
	if err != nil {
		return false, err
	}
	if code != 0 {
		return false, errors.New("install: process enumeration failed")
	}
	count, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil {
		return false, errors.New("install: process enumeration output not recognized")
	}
	return count > 0, nil
}

// canElevate reports whether this account can satisfy a UAC prompt on its
// own: a member of Administrators runs with a split (limited) token that
// elevates to full on consent, or is already elevated, or — in a logon that
// UAC does not split, such as SSH — simply carries the Administrators group.
// A standard account has none of these and would be asked for someone else's
// password.
func canElevate() bool {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return false
	}
	defer token.Close()
	var elevationType uint32
	var returned uint32
	if err := syscall.GetTokenInformation(token, tokenElevationType, (*byte)(unsafe.Pointer(&elevationType)), uint32(unsafe.Sizeof(elevationType)), &returned); err == nil &&
		(elevationType == tokenElevationTypeFull || elevationType == tokenElevationTypeLimited) {
		return true
	}
	return tokenHasAdministrators(token)
}

// tokenHasAdministrators reports whether the token lists BUILTIN\Administrators
// (S-1-5-32-544), whether enabled or filtered to deny-only by UAC.
func tokenHasAdministrators(token syscall.Token) bool {
	var needed uint32
	_ = syscall.GetTokenInformation(token, syscall.TokenGroups, nil, 0, &needed)
	if needed == 0 {
		return false
	}
	buffer := make([]byte, needed)
	if err := syscall.GetTokenInformation(token, syscall.TokenGroups, &buffer[0], needed, &needed); err != nil {
		return false
	}
	groups := (*tokenGroupsInfo)(unsafe.Pointer(&buffer[0]))
	entries := unsafe.Slice(&groups.Groups[0], int(groups.GroupCount))
	for _, entry := range entries {
		if entry.Sid == nil {
			continue
		}
		if sid, err := entry.Sid.String(); err == nil && sid == "S-1-5-32-544" {
			return true
		}
	}
	return false
}

// sidAndAttributes / tokenGroupsInfo mirror SID_AND_ATTRIBUTES / TOKEN_GROUPS,
// which package syscall does not declare.
type sidAndAttributes struct {
	Sid        *syscall.SID
	Attributes uint32
}

type tokenGroupsInfo struct {
	GroupCount uint32
	Groups     [1]sidAndAttributes
}

// limitedBuffer keeps at most maxToolOutputBytes of a tool's output.
type limitedBuffer struct {
	buffer bytes.Buffer
}

func (b *limitedBuffer) Write(data []byte) (int, error) {
	remaining := maxToolOutputBytes - b.buffer.Len()
	if remaining > 0 {
		if len(data) > remaining {
			b.buffer.Write(data[:remaining])
		} else {
			b.buffer.Write(data)
		}
	}
	return len(data), nil
}

func (b *limitedBuffer) Bytes() []byte { return b.buffer.Bytes() }
