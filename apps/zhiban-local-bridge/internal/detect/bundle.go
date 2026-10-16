package detect

// Desktop targets (M3): Codex Desktop and Claude Desktop are macOS application
// bundles rather than executables on PATH. They are discovered only in the two
// fixed Applications folders (Spotlight indexing is not reliable enough to
// drive product state, see the M3 plan spike S4), matched by bundle identifier
// rather than by file name (Codex Desktop renamed itself to ChatGPT.app in a
// Sparkle auto-update on the test Mac, 2026-09-09), classified by their code
// signature (publisher Developer ID Team + bundle identifier) instead of by
// path, and their version is read from Info.plist instead of running them.

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

const (
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	FormFactorCLI     = "cli"
	FormFactorDesktop = "desktop"

	infoPlistRelativePath = "Contents/Info.plist"
	macOSRelativePath     = "Contents/MacOS"
	maxInfoPlistBytes     = 1 << 20
	bundleProbeTimeout    = 8 * time.Second
	bundleSignatureTimout = 5 * time.Second
)

var (
	bundleVersionPattern = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+){1,3}$`)
	binaryPlistMagic     = []byte("bplist")
)

// BundleSpec describes the application bundle that implements a desktop
// target: its name inside an Applications folder, the bundle identifier its
// Info.plist and signature must declare, and the publisher's Developer ID Team.
type BundleSpec struct {
	Name           string
	Identifier     string
	TeamIdentifier string
}

// desktopBundles are build-time facts (M3 plan §2, verified 2026-09-09 with
// `codesign -dv` on the locked releases).
var desktopBundles = map[string]BundleSpec{
	TargetClaudeDesktop: {Name: "Claude.app", Identifier: "com.anthropic.claudefordesktop", TeamIdentifier: "Q6L2SF6YDW"},
	TargetCodexDesktop:  {Name: "Codex.app", Identifier: "com.openai.codex", TeamIdentifier: "2DC432GLL2"},
}

// desktopSupportsEnable says whether Zhiban can write a third-party inference
// configuration for the desktop target. Codex Desktop shares ~/.codex/config.toml
// with the CLI (spike S1); Claude Desktop is configured through its 3P
// configLibrary (spike S2, configuration/desktop_claude.go).
var desktopSupportsEnable = map[string]bool{
	TargetCodexDesktop:  true,
	TargetClaudeDesktop: true,
}

// BundleSpecFor returns the bundle facts for a desktop target.
func BundleSpecFor(targetID string) (BundleSpec, bool) {
	spec, ok := desktopBundles[targetID]
	return spec, ok
}

// HostArch maps the running process architecture onto the Bridge's names.
func HostArch() string {
	switch runtime.GOARCH {
	case "arm64":
		return claudecode.ArchARM64
	case "amd64":
		return claudecode.ArchX64
	default:
		return ""
	}
}

// ClaudeDesktopComponents reports the Claude Code host component for an
// installed Claude Desktop (M3 Task 8): the pinned version is read from the
// bundle itself, and its presence is checked in Claude-3p's storage under home.
// Other targets have no components.
func ClaudeDesktopComponents(homeDir, arch string) ComponentsFunc {
	return func(_ context.Context, targetID string, candidate Candidate) []Component {
		if targetID != TargetClaudeDesktop {
			return nil
		}
		manifest, err := claudecode.ReadEmbeddedManifest(candidate.RealPath)
		if err != nil {
			return []Component{{ID: claudecode.ComponentID, State: claudecode.StateUnknown}}
		}
		return []Component{claudecode.Status(homeDir, manifest, arch)}
	}
}

// ClaudeDesktopThirdPartyInference checks the installed Claude Desktop for the
// third-party inference configuration keys (claudecode.SupportsThirdPartyInference).
func ClaudeDesktopThirdPartyInference() ThirdPartyInferenceFunc {
	return func(_ context.Context, targetID string, candidate Candidate) (bool, bool) {
		if targetID != TargetClaudeDesktop {
			return true, false
		}
		return claudecode.SupportsThirdPartyInference(candidate.RealPath)
	}
}

// IsDesktopTarget reports whether targetID is an application bundle target.
func IsDesktopTarget(targetID string) bool {
	_, ok := desktopBundles[targetID]
	return ok
}

// FormFactor returns "cli" or "desktop" for a valid target.
func FormFactor(targetID string) string {
	if IsDesktopTarget(targetID) {
		return FormFactorDesktop
	}
	return FormFactorCLI
}

func validTarget(targetID string) bool {
	return targetID == TargetCodexCLI || targetID == TargetClaudeCLI || IsDesktopTarget(targetID)
}

func supportsEnable(targetID string) bool {
	if IsDesktopTarget(targetID) {
		return desktopSupportsEnable[targetID]
	}
	return true
}

// BundleSignature is what a code signature declares about a bundle. Reading
// it does not verify the seal; BundleProber does that.
type BundleSignature struct {
	Identifier     string
	TeamIdentifier string
}

// BundleSignatureFunc reads the signature of the bundle at an absolute path.
type BundleSignatureFunc func(context.Context, string) (BundleSignature, error)

// discoverBundles finds the target's bundle in the system and user
// Applications folders. Nothing else is searched on purpose. Within a folder
// every *.app whose Info.plist declares the target's bundle identifier counts,
// whatever it is called: the publisher may rename the bundle in an update.
func (d *MacOSDiscoverer) discoverBundles(ctx context.Context, targetID string) ([]Candidate, error) {
	spec, ok := desktopBundles[targetID]
	if !ok {
		return nil, ErrUnsupportedTarget
	}
	directories := []string{d.SystemApplicationsDir, d.UserApplicationsDir}
	seen := make(map[string]struct{}, len(directories))
	candidates := make([]Candidate, 0, len(directories))
	for _, directory := range directories {
		if strings.TrimSpace(directory) == "" {
			continue
		}
		for _, bundlePath := range d.bundlePathsIn(directory, spec) {
			candidate, ok := d.resolveBundleCandidate(ctx, spec, bundlePath)
			if !ok {
				continue
			}
			if _, duplicate := seen[candidate.RealPath]; duplicate {
				continue
			}
			seen[candidate.RealPath] = struct{}{}
			candidates = append(candidates, candidate)
		}
	}
	return candidates, nil
}

// bundlePathsIn lists the bundles in directory that may implement spec: the
// expected name first, then any other *.app declaring the same identifier.
func (d *MacOSDiscoverer) bundlePathsIn(directory string, spec BundleSpec) []string {
	paths := []string{filepath.Join(directory, spec.Name)}
	readDir := d.ReadDir
	if readDir == nil {
		readDir = os.ReadDir
	}
	entries, err := readDir(directory)
	if err != nil {
		return paths
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == spec.Name || !strings.HasSuffix(name, ".app") || strings.HasPrefix(name, ".") {
			continue
		}
		bundlePath := filepath.Join(directory, name)
		if identifier, err := readBundleIdentifier(bundlePath); err == nil && identifier == spec.Identifier {
			paths = append(paths, bundlePath)
		}
	}
	return paths
}

// resolveBundleCandidate accepts a directory that looks like an application
// bundle. Its source is official only when the code signature names the
// expected publisher Team and bundle identifier; anything else is untrusted,
// whatever folder it sits in.
func (d *MacOSDiscoverer) resolveBundleCandidate(ctx context.Context, spec BundleSpec, bundlePath string) (Candidate, bool) {
	if !filepath.IsAbs(bundlePath) {
		return Candidate{}, false
	}
	realPath, err := d.EvalSymlinks(filepath.Clean(bundlePath))
	if err != nil || !filepath.IsAbs(realPath) {
		return Candidate{}, false
	}
	info, err := d.Stat(realPath)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o002 != 0 {
		return Candidate{}, false
	}
	if plist, err := d.Stat(filepath.Join(realPath, infoPlistRelativePath)); err != nil || !plist.Mode().IsRegular() {
		return Candidate{}, false
	}
	if executables, err := d.Stat(filepath.Join(realPath, macOSRelativePath)); err != nil || !executables.IsDir() {
		return Candidate{}, false
	}
	if identifier, err := readBundleIdentifier(realPath); err != nil || identifier != spec.Identifier {
		return Candidate{}, false
	}
	source := SourceUnknown
	if d.BundleSignature != nil {
		signature, err := d.BundleSignature(ctx, realPath)
		if err == nil && signature.Identifier == spec.Identifier && signature.TeamIdentifier == spec.TeamIdentifier {
			source = SourceOfficial
		}
	}
	return Candidate{Path: filepath.Clean(bundlePath), RealPath: filepath.Clean(realPath), Source: source}, true
}

// BundleProber is the version probe for desktop targets: it reads the
// version from Info.plist and checks the bundle's code seal. A bundle whose
// seal no longer verifies is reported damaged (repairable), like a CLI whose
// --version fails.
type BundleProber struct {
	Timeout     time.Duration
	ReadVersion func(string) (string, error)
	Verify      func(context.Context, string) error
}

// Probe implements ProbeFunc for desktop targets.
func (p BundleProber) Probe(ctx context.Context, targetID string, candidate Candidate) (string, error) {
	if !IsDesktopTarget(targetID) {
		return "", ErrUnsupportedTarget
	}
	readVersion := p.ReadVersion
	if readVersion == nil {
		readVersion = readBundleVersion
	}
	verify := p.Verify
	if verify == nil {
		verify = codesignVerifyBundle
	}
	timeout := p.Timeout
	if timeout <= 0 || timeout > 30*time.Second {
		timeout = bundleProbeTimeout
	}
	version, err := readVersion(candidate.RealPath)
	if err != nil {
		return "", ErrProbeFailed
	}
	version = strings.TrimSpace(version)
	if !bundleVersionPattern.MatchString(version) {
		return "", ErrVersionUnrecognized
	}
	probeContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := verify(probeContext, candidate.RealPath); err != nil {
		if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
			return "", ErrProbeTimeout
		}
		return "", ErrProbeFailed
	}
	return version, nil
}

// readBundleVersion returns CFBundleShortVersionString from the bundle's
// Info.plist. XML property lists are parsed in-process; a binary property
// list is converted with the system plutil first.
func readBundleVersion(bundlePath string) (string, error) {
	return readInfoPlistString(bundlePath, "CFBundleShortVersionString")
}

// readBundleIdentifier returns CFBundleIdentifier from the bundle's Info.plist.
func readBundleIdentifier(bundlePath string) (string, error) {
	return readInfoPlistString(bundlePath, "CFBundleIdentifier")
}

func readInfoPlistString(bundlePath, key string) (string, error) {
	data, err := readInfoPlist(bundlePath)
	if err != nil {
		return "", err
	}
	if bytes.HasPrefix(data, binaryPlistMagic) {
		data, err = convertBinaryPlist(filepath.Join(bundlePath, infoPlistRelativePath))
		if err != nil {
			return "", err
		}
	}
	return plistStringValue(data, key)
}

func readInfoPlist(bundlePath string) ([]byte, error) {
	file, err := os.Open(filepath.Join(bundlePath, infoPlistRelativePath))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxInfoPlistBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxInfoPlistBytes {
		return nil, errors.New("detect: Info.plist too large")
	}
	return data, nil
}

func convertBinaryPlist(path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), bundleSignatureTimout)
	defer cancel()
	command := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", path)
	command.Env = []string{"LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin"}
	var output cappedBuffer
	command.Stdout = &output
	command.Stderr = &cappedBuffer{}
	if err := command.Run(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

type plistElement struct {
	XMLName  xml.Name
	Value    string         `xml:",chardata"`
	Children []plistElement `xml:",any"`
}

// plistStringValue returns the <string> value stored under key in the top-level
// dictionary of an XML property list.
func plistStringValue(data []byte, key string) (string, error) {
	var root plistElement
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = false
	if err := decoder.Decode(&root); err != nil {
		return "", err
	}
	if root.XMLName.Local != "plist" || len(root.Children) == 0 || root.Children[0].XMLName.Local != "dict" {
		return "", errors.New("detect: Info.plist is not a dictionary")
	}
	entries := root.Children[0].Children
	for index := 0; index+1 < len(entries); index += 2 {
		if entries[index].XMLName.Local != "key" {
			return "", errors.New("detect: malformed Info.plist dictionary")
		}
		if strings.TrimSpace(entries[index].Value) != key {
			continue
		}
		value := entries[index+1]
		if value.XMLName.Local != "string" {
			return "", errors.New("detect: Info.plist value is not a string")
		}
		return strings.TrimSpace(value.Value), nil
	}
	return "", errors.New("detect: Info.plist key missing")
}

// codesignSignature reads the identifier and Team of the bundle's code
// signature without validating the seal (fast: no resource hashing).
func codesignSignature(ctx context.Context, bundlePath string) (BundleSignature, error) {
	probeContext, cancel := context.WithTimeout(ctx, bundleSignatureTimout)
	defer cancel()
	command := exec.CommandContext(probeContext, "/usr/bin/codesign", "-dv", "--verbose=2", "--", bundlePath)
	command.Env = []string{"LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin"}
	var output cappedBuffer
	command.Stdout = &cappedBuffer{}
	command.Stderr = &output
	if err := command.Run(); err != nil {
		return BundleSignature{}, err
	}
	return parseCodesignSignature(output.Bytes())
}

func parseCodesignSignature(output []byte) (BundleSignature, error) {
	var signature BundleSignature
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "Identifier="):
			signature.Identifier = strings.TrimPrefix(line, "Identifier=")
		case strings.HasPrefix(line, "TeamIdentifier="):
			signature.TeamIdentifier = strings.TrimPrefix(line, "TeamIdentifier=")
		}
	}
	if signature.Identifier == "" || signature.TeamIdentifier == "" || signature.TeamIdentifier == "not set" {
		return BundleSignature{}, errors.New("detect: bundle is not signed by a Developer ID team")
	}
	return signature, nil
}

// codesignVerifyBundle validates the bundle's code seal (main executable and
// sealed resources). Nested code is checked in full only at install time.
func codesignVerifyBundle(ctx context.Context, bundlePath string) error {
	command := exec.CommandContext(ctx, "/usr/bin/codesign", "--verify", "--strict", "--", bundlePath)
	command.Env = []string{"LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin"}
	command.Stdout = &cappedBuffer{}
	command.Stderr = &cappedBuffer{}
	return command.Run()
}
