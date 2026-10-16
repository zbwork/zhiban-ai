//go:build windows

package detect

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellpath"
)

// WindowsDiscoverer finds the Codex / Claude CLIs on Windows. It mirrors
// MacOSDiscoverer but with Windows realities: executables are found on PATH as
// .cmd/.exe shims (PATHEXT), Unix permission bits do not apply, and the npm
// global bin (%APPDATA%\npm) is the trust signal for an npm install rather
// than a node_modules path (the .cmd shim itself lives in that bin dir).
type WindowsDiscoverer struct {
	HomeDir      string
	LookPath     func(string) (string, error)
	EvalSymlinks func(string) (string, error)
	Stat         func(string) (os.FileInfo, error)
	Glob         func(string) ([]string, error)
	// NpmPrefix is the npm global prefix (default %APPDATA%\npm); its bin dir
	// holds the codex.cmd / claude.cmd shims for a global npm install.
	NpmPrefix string
	// AppData / LocalAppData anchor the candidate search and source
	// classification.
	AppData      string
	LocalAppData string
}

// registryResolve answers what a terminal opened from now on runs for a
// command (shellpath.LookPath: the registry's machine + user PATH). Tests
// replace it.
var registryResolve = shellpath.LookPath

// registryLookPath is the discoverer's LookPath. This process's own PATH is
// the snapshot Zhiban started with: after an adopt put ~\.local\bin first in
// the user PATH (shellpath), exec.LookPath kept resolving `codex` to the npm
// copy for the rest of the App's life, so the detection that followed the
// adopt reported the old copy as too old and the next attempt hit its own
// version directory (2026-09-18 Windows 12800). The registry is asked first;
// the process PATH only answers when the registry names nothing.
func registryLookPath(name string) (string, error) {
	if resolved, ok := registryResolve(name); ok {
		return resolved, nil
	}
	return exec.LookPath(name)
}

func windowsEnv(name, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return fallback
}

func NewWindowsDiscoverer(homeDir string) *WindowsDiscoverer {
	cleanHome := filepath.Clean(homeDir)
	if real, err := filepath.EvalSymlinks(cleanHome); err == nil {
		cleanHome = real
	}
	appData := windowsEnv("APPDATA", filepath.Join(cleanHome, "AppData", "Roaming"))
	localAppData := windowsEnv("LOCALAPPDATA", filepath.Join(cleanHome, "AppData", "Local"))
	return &WindowsDiscoverer{
		HomeDir:      cleanHome,
		LookPath:     registryLookPath,
		EvalSymlinks: filepath.EvalSymlinks,
		Stat:         os.Stat,
		Glob:         filepath.Glob,
		NpmPrefix:    filepath.Join(appData, "npm"),
		AppData:      appData,
		LocalAppData: localAppData,
	}
}

// executableExtensions are the Windows launcher/binary extensions we accept for
// a CLI candidate, lower-cased. .cmd/.bat are npm shims; .exe a native binary;
// .ps1 a PowerShell launcher some installers drop.
var executableExtensions = map[string]struct{}{
	".exe": {}, ".cmd": {}, ".bat": {}, ".ps1": {},
}

func (d *WindowsDiscoverer) Discover(ctx context.Context, targetID string) ([]Candidate, error) {
	if IsDesktopTarget(targetID) {
		// Desktop targets are registered app packages (desktop_windows.go).
		return d.discoverPackages(targetID)
	}
	binaryName, err := targetBinaryName(targetID)
	if err != nil {
		return nil, err
	}

	paths := make([]string, 0, 16)
	// A Windows GUI process inherits the user's PATH, so LookPath answers what
	// the user runs; that copy is Preferred (contract §2.7, 2026-09-14).
	preferredPath := ""
	if p, err := d.LookPath(binaryName); err == nil {
		preferredPath = filepath.Clean(p)
		paths = append(paths, p)
	} else if errors.Is(err, exec.ErrDot) {
		return nil, ErrUntrustedSearchPath
	} else {
		var execError *exec.Error
		if !errors.As(err, &execError) {
			return nil, fmt.Errorf("look up %s: %w", targetID, err)
		}
	}

	// Known Windows install locations for both CLIs. %USERPROFILE%\.local\bin
	// is where the publishers' native installers and the Bridge put the
	// launcher (the Bridge's is a batch shim into the versions layout,
	// launcher_windows.go).
	for _, ext := range []string{".cmd", ".exe", ".ps1"} {
		paths = append(paths,
			filepath.Join(d.NpmPrefix, binaryName+ext), // npm -g
			filepath.Join(d.HomeDir, ".local", "bin", binaryName+ext),
			filepath.Join(d.LocalAppData, "Programs", binaryName, binaryName+ext),
		)
	}
	// pnpm global and fnm/nvm-windows node shims.
	paths = append(paths, filepath.Join(d.LocalAppData, "pnpm", binaryName+".cmd"))
	if fnm, err := d.Glob(filepath.Join(d.AppData, "npm", "node_modules", "*", "bin", binaryName)); err == nil {
		paths = append(paths, fnm...)
	}

	seen := make(map[string]struct{}, len(paths))
	candidates := make([]Candidate, 0, len(paths))
	for _, candidatePath := range paths {
		candidate, ok := d.resolveCandidate(targetID, candidatePath)
		if !ok {
			continue
		}
		// npm installs three shims for one CLI in the same directory
		// (codex.cmd, codex.ps1 and an extensionless script). They are one
		// installation, so dedupe by directory + base name (extension
		// stripped) rather than by full real path. Two genuinely different
		// installs live in different directories and stay distinct. The
		// candidate order (.cmd before .ps1) makes the runnable .cmd win.
		realBase := strings.TrimSuffix(filepath.Base(candidate.RealPath), filepath.Ext(candidate.RealPath))
		key := strings.ToLower(filepath.Dir(candidate.RealPath)) + "\x00" + strings.ToLower(realBase)
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		candidate.Preferred = preferredPath != "" && strings.EqualFold(candidate.Path, preferredPath)
		candidates = append(candidates, candidate)
	}
	return candidates, nil
}

func (d *WindowsDiscoverer) resolveCandidate(targetID, candidatePath string) (Candidate, bool) {
	if strings.TrimSpace(candidatePath) == "" || !filepath.IsAbs(candidatePath) {
		return Candidate{}, false
	}
	realPath, err := d.EvalSymlinks(filepath.Clean(candidatePath))
	if err != nil || !filepath.IsAbs(realPath) {
		return Candidate{}, false
	}
	info, err := d.Stat(realPath)
	if err != nil || !info.Mode().IsRegular() {
		return Candidate{}, false
	}
	// Windows has no Unix executable bit; trust is by extension + location.
	if _, ok := executableExtensions[strings.ToLower(filepath.Ext(realPath))]; !ok {
		return Candidate{}, false
	}
	// The Bridge's own launcher shim resolves to the version file it runs,
	// as EvalSymlinks resolves the macOS symlink launcher: the probe, the
	// Codex layout check, the source rule and the managed launch all see the
	// executable inside the versions layout. A shim whose version file is
	// gone runs nothing and is not an installation.
	if strings.EqualFold(filepath.Ext(realPath), ".cmd") {
		if target, ok := LauncherShimTarget(realPath); ok {
			targetInfo, err := d.Stat(target)
			if err != nil || !targetInfo.Mode().IsRegular() || !strings.EqualFold(filepath.Ext(target), ".exe") {
				return Candidate{}, false
			}
			realPath = target
		}
	}
	return Candidate{
		Path:     filepath.Clean(candidatePath),
		RealPath: filepath.Clean(realPath),
		Source:   d.classifySource(targetID, realPath),
	}, true
}

func (d *WindowsDiscoverer) classifySource(targetID, realPath string) InstallSource {
	real := strings.ToLower(filepath.Clean(realPath))
	// npm global install: the shim lives in %APPDATA%\npm, or the resolved
	// path runs out of the package's own node_modules directory.
	if d.NpmPrefix != "" && pathWithin(real, strings.ToLower(filepath.Clean(d.NpmPrefix))) {
		return SourceNPM
	}
	pkg := ""
	switch targetID {
	case TargetCodexCLI:
		pkg = filepath.Join("node_modules", "@openai", "codex")
	case TargetClaudeCLI:
		pkg = filepath.Join("node_modules", "@anthropic-ai", "claude-code")
	}
	if pkg != "" && strings.Contains(real, string(filepath.Separator)+strings.ToLower(pkg)+string(filepath.Separator)) {
		return SourceNPM
	}
	// Official standalone installs: the native installers' (and the Bridge's)
	// launcher in ~\.local\bin and their versions layouts, plus the
	// per-user Programs folders.
	if pathWithin(real, strings.ToLower(filepath.Join(d.HomeDir, ".local", "bin"))) {
		return SourceOfficial
	}
	if targetID == TargetClaudeCLI && pathWithin(real, strings.ToLower(filepath.Join(d.HomeDir, ".local", "share", "claude"))) {
		return SourceOfficial
	}
	if targetID == TargetCodexCLI && pathWithin(real, strings.ToLower(filepath.Join(d.HomeDir, ".codex", "packages", "standalone"))) {
		return SourceOfficial
	}
	if targetID == TargetClaudeCLI && pathWithin(real, strings.ToLower(filepath.Join(d.LocalAppData, "Programs", "claude"))) {
		return SourceOfficial
	}
	if targetID == TargetCodexCLI && pathWithin(real, strings.ToLower(filepath.Join(d.LocalAppData, "Programs", "codex"))) {
		return SourceOfficial
	}
	return SourceUnknown
}

// NewWindowsDetector wires the Windows discoverer and a Windows-aware version
// prober into a Detector. Desktop components are not provisioned on Windows yet.
func NewWindowsDetector(homeDir string) (*Detector, error) {
	discoverer := NewWindowsDiscoverer(homeDir)
	prober := WindowsVersionProber{Timeout: windowsProbeTimeout, HomeDir: discoverer.HomeDir}
	packageProber := WindowsPackageProber{}
	probe := func(ctx context.Context, targetID string, candidate Candidate) (string, error) {
		if IsDesktopTarget(targetID) {
			return packageProber.Probe(ctx, targetID, candidate)
		}
		return prober.Probe(ctx, targetID, candidate)
	}
	idKey := make([]byte, 32)
	if _, err := rand.Read(idKey); err != nil {
		return nil, fmt.Errorf("detect: generate installation id key: %w", err)
	}
	detector, err := NewDetector(discoverer.Discover, probe, idKey)
	if err != nil {
		return nil, err
	}
	// Claude Desktop reports whether its Claude Code host executable is
	// provisioned (M3 Task 8 on Windows: claudecode host_windows.go).
	detector.SetComponents(ClaudeDesktopComponents(homeDir, HostArch()))
	detector.SetThirdPartyInference(ClaudeDesktopThirdPartyInference())
	return detector, nil
}
