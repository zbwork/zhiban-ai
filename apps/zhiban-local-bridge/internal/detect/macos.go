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
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

type MacOSDiscoverer struct {
	HomeDir          string
	LookPath         func(string) (string, error)
	EvalSymlinks     func(string) (string, error)
	Stat             func(string) (os.FileInfo, error)
	Glob             func(string) ([]string, error)
	SystemCandidates map[string][]string
	// ShellLookup answers "what does the user's own shell run for this
	// command" (contract §2.7, 2026-09-14). The App's PATH is not the user's:
	// copies under nvm / fnm / asdf / a custom npm prefix are only visible to
	// the login shell. Its answer joins the search first and is marked
	// Preferred. nil disables it (tests, and the discoverer on its own).
	ShellLookup func(ctx context.Context, binaryName string) (string, bool)
	// Desktop targets (M3): the two Applications folders that are searched,
	// how they are listed, and the code-signature reader that classifies what
	// is found there.
	SystemApplicationsDir string
	UserApplicationsDir   string
	ReadDir               func(string) ([]os.DirEntry, error)
	BundleSignature       BundleSignatureFunc
}

func NewMacOSDiscoverer(homeDir string) *MacOSDiscoverer {
	cleanHomeDir := filepath.Clean(homeDir)
	if realHomeDir, err := filepath.EvalSymlinks(cleanHomeDir); err == nil {
		cleanHomeDir = realHomeDir
	}
	return &MacOSDiscoverer{
		HomeDir:      cleanHomeDir,
		LookPath:     exec.LookPath,
		EvalSymlinks: filepath.EvalSymlinks,
		Stat:         os.Stat,
		Glob:         filepath.Glob,
		SystemCandidates: map[string][]string{
			TargetCodexCLI:  {"/opt/homebrew/bin/codex", "/usr/local/bin/codex"},
			TargetClaudeCLI: {"/opt/homebrew/bin/claude", "/usr/local/bin/claude"},
		},
		SystemApplicationsDir: "/Applications",
		UserApplicationsDir:   filepath.Join(cleanHomeDir, "Applications"),
		ReadDir:               os.ReadDir,
		BundleSignature:       codesignSignature,
	}
}

func NewMacOSDetector(homeDir string) (*Detector, error) {
	discoverer := NewMacOSDiscoverer(homeDir)
	// One login-shell lookup serves discovery (which copy the user runs) and
	// the version probe (where that copy's Node runtime is).
	lookup := shellenv.NewLoginShellLookup(homeDir)
	cliProber := VersionProber{Timeout: 2 * time.Second, HomeDir: homeDir, NodeLookup: lookup}
	bundleProber := BundleProber{Timeout: bundleProbeTimeout}
	probe := func(ctx context.Context, targetID string, candidate Candidate) (string, error) {
		if IsDesktopTarget(targetID) {
			return bundleProber.Probe(ctx, targetID, candidate)
		}
		return cliProber.Probe(ctx, targetID, candidate)
	}
	idKey := make([]byte, 32)
	if _, err := rand.Read(idKey); err != nil {
		return nil, fmt.Errorf("detect: generate installation id key: %w", err)
	}
	if lookup != nil {
		discoverer.ShellLookup = lookup.Lookup
	}
	detector, err := NewDetector(discoverer.Discover, probe, idKey)
	if err != nil {
		return nil, err
	}
	// M3 Task 8: Claude Desktop reports whether its Claude Code host bundle is
	// provisioned; other targets have no components.
	detector.SetComponents(ClaudeDesktopComponents(homeDir, HostArch()))
	detector.SetThirdPartyInference(ClaudeDesktopThirdPartyInference())
	return detector, nil
}

func (d *MacOSDiscoverer) Discover(ctx context.Context, targetID string) ([]Candidate, error) {
	if IsDesktopTarget(targetID) {
		return d.discoverBundles(ctx, targetID)
	}
	binaryName, err := targetBinaryName(targetID)
	if err != nil {
		return nil, err
	}

	paths := make([]string, 0, 24)
	preferredPath := ""
	if d.ShellLookup != nil {
		if resolved, ok := d.ShellLookup(ctx, binaryName); ok && filepath.IsAbs(resolved) {
			preferredPath = filepath.Clean(resolved)
			paths = append(paths, preferredPath)
		}
	}
	pathCandidate, err := d.LookPath(binaryName)
	if err == nil {
		paths = append(paths, pathCandidate)
	} else if errors.Is(err, exec.ErrDot) {
		return nil, ErrUntrustedSearchPath
	} else {
		var execError *exec.Error
		if !errors.As(err, &execError) {
			return nil, fmt.Errorf("look up %s: %w", targetID, err)
		}
	}
	paths = append(paths, d.SystemCandidates[targetID]...)
	paths = append(paths,
		filepath.Join(d.HomeDir, ".local", "bin", binaryName),
		filepath.Join(d.HomeDir, ".npm-global", "bin", binaryName),
		filepath.Join(d.HomeDir, ".volta", "bin", binaryName),
		filepath.Join(d.HomeDir, "Library", "pnpm", binaryName),
		filepath.Join(d.HomeDir, ".bun", "bin", binaryName),
		filepath.Join(d.HomeDir, ".yarn", "bin", binaryName),
	)
	if targetID == TargetClaudeCLI {
		// Claude Code's older "local installer" keeps its own npm tree.
		paths = append(paths, filepath.Join(d.HomeDir, ".claude", "local", "node_modules", ".bin", binaryName))
	}
	// Node version managers each keep one global bin per installed Node.
	for _, pattern := range []string{
		filepath.Join(d.HomeDir, ".nvm", "versions", "node", "*", "bin", binaryName),
		filepath.Join(d.HomeDir, ".asdf", "installs", "nodejs", "*", "bin", binaryName),
		filepath.Join(d.HomeDir, ".local", "share", "mise", "installs", "node", "*", "bin", binaryName),
		filepath.Join(d.HomeDir, "Library", "Application Support", "fnm", "node-versions", "*", "installation", "bin", binaryName),
		filepath.Join(d.HomeDir, ".fnm", "node-versions", "*", "installation", "bin", binaryName),
		filepath.Join(d.HomeDir, ".local", "share", "fnm", "node-versions", "*", "installation", "bin", binaryName),
		filepath.Join(d.HomeDir, ".volta", "tools", "image", "packages", npmPackageName(targetID), "bin", binaryName),
	} {
		matches, err := d.Glob(pattern)
		if err != nil {
			return nil, fmt.Errorf("find %s candidates: %w", targetID, err)
		}
		paths = append(paths, matches...)
	}

	seen := make(map[string]struct{}, len(paths))
	candidates := make([]Candidate, 0, len(paths))
	for _, candidatePath := range paths {
		candidate, ok := d.resolveCandidate(targetID, candidatePath)
		if !ok {
			continue
		}
		if _, duplicate := seen[candidate.RealPath]; duplicate {
			continue
		}
		seen[candidate.RealPath] = struct{}{}
		candidate.Preferred = preferredPath != "" && candidate.Path == preferredPath
		candidates = append(candidates, candidate)
	}
	return candidates, nil
}

// npmPackageName is the target's npm package, as a relative path.
func npmPackageName(targetID string) string {
	if targetID == TargetClaudeCLI {
		return filepath.Join("@anthropic-ai", "claude-code")
	}
	return filepath.Join("@openai", "codex")
}

func (d *MacOSDiscoverer) resolveCandidate(targetID, candidatePath string) (Candidate, bool) {
	if strings.TrimSpace(candidatePath) == "" || !filepath.IsAbs(candidatePath) {
		return Candidate{}, false
	}
	realPath, err := d.EvalSymlinks(filepath.Clean(candidatePath))
	if err != nil || !filepath.IsAbs(realPath) {
		return Candidate{}, false
	}
	info, err := d.Stat(realPath)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 || info.Mode().Perm()&0o002 != 0 {
		return Candidate{}, false
	}
	return Candidate{
		Path:     filepath.Clean(candidatePath),
		RealPath: filepath.Clean(realPath),
		Source:   classifyMacOSSource(targetID, candidatePath, realPath, d.HomeDir),
	}, true
}

func classifyMacOSSource(targetID, _ string, realPath, homeDir string) InstallSource {
	realPath = filepath.Clean(realPath)
	homeDir = filepath.Clean(homeDir)

	if targetID == TargetClaudeCLI && pathWithin(realPath, filepath.Join(homeDir, ".local", "share", "claude", "versions")) {
		return SourceOfficial
	}
	if targetID == TargetCodexCLI && pathWithin(realPath, filepath.Join(homeDir, ".codex", "packages", "standalone")) {
		return SourceOfficial
	}
	packagePath := ""
	switch targetID {
	case TargetCodexCLI:
		packagePath = filepath.Join("node_modules", "@openai", "codex")
	case TargetClaudeCLI:
		packagePath = filepath.Join("node_modules", "@anthropic-ai", "claude-code")
	}
	if strings.Contains(realPath, string(filepath.Separator)+packagePath+string(filepath.Separator)) {
		return SourceNPM
	}
	if pathWithin(realPath, "/opt/homebrew") ||
		pathWithin(realPath, "/usr/local/Cellar") || pathWithin(realPath, "/usr/local/Caskroom") {
		return SourceHomebrew
	}
	return SourceUnknown
}

func pathWithin(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	if path == root {
		return true
	}
	return strings.HasPrefix(path, root+string(filepath.Separator))
}

func targetBinaryName(targetID string) (string, error) {
	switch targetID {
	case TargetCodexCLI:
		return "codex", nil
	case TargetClaudeCLI:
		return "claude", nil
	default:
		return "", ErrUnsupportedTarget
	}
}
