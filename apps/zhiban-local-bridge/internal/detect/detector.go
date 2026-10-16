package detect

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

const (
	TargetCodexCLI  = "codex_cli"
	TargetClaudeCLI = "claude_cli"

	UIStateNotInstalled       = "not_installed"
	UIStateInstalledUnmanaged = "installed_unmanaged"
	UIStateRepairable         = "repairable"
	UIStateUnsupported        = "unsupported"
)

type InstallSource string

const (
	SourceOfficial InstallSource = "official"
	SourceHomebrew InstallSource = "homebrew"
	SourceNPM      InstallSource = "npm"
	SourceUnknown  InstallSource = "unknown"
)

var (
	ErrUnsupportedTarget   = errors.New("unsupported local coding target")
	ErrUntrustedSearchPath = errors.New("untrusted executable search path")
	// ErrTargetUnsupportedOnPlatform: the target form exists in the product but
	// is not available on this OS (e.g. the desktop apps on Windows in M2). The
	// detector maps it to an "unsupported" state so the UI shows it as not
	// available rather than offering to install it.
	ErrTargetUnsupportedOnPlatform = errors.New("target not supported on this platform")
	ErrProbeTimeout                = errors.New("version probe timed out")
	ErrProbeFailed                 = errors.New("version probe failed")
	ErrVersionUnrecognized         = errors.New("version output not recognized")
	// ErrLayoutIncomplete: the executable runs, but the rest of the
	// publisher's package is missing beside it (Codex without its Code Mode
	// host). Repairable: a repair installs the whole package.
	ErrLayoutIncomplete    = errors.New("installed layout incomplete")
	ErrInstallationChanged = errors.New("detected installation changed")
)

type Candidate struct {
	Path     string
	RealPath string
	Source   InstallSource
	// Preferred marks the copy the user's own command lookup resolves (macOS:
	// the login shell; Windows: the process PATH). When several copies exist
	// it is the one reported, because it is the one the user actually runs.
	Preferred bool
}

type State struct {
	TargetID       string `json:"target_id"`
	InstallationID string `json:"installation_id,omitempty"`
	Generation     uint64 `json:"generation"`
	// FormFactor is "cli" or "desktop"; SupportsEnable says whether Zhiban can
	// write a third-party inference configuration for this target (M3).
	FormFactor     string `json:"form_factor"`
	SupportsEnable bool   `json:"supports_enable"`
	// MinimumVersion is set with DETECT-VERSION_TOO_OLD: the oldest version
	// that can be switched to Zhiban (catalog.MinimumSwitchVersion).
	MinimumVersion    string        `json:"minimum_version,omitempty"`
	UIState           string        `json:"ui_state"`
	InstalledVersion  string        `json:"installed_version,omitempty"`
	InstallSource     InstallSource `json:"install_source,omitempty"`
	VerificationLevel string        `json:"verification_level"`
	ErrorCode         string        `json:"error_code,omitempty"`
	NextActions       []string      `json:"next_actions"`
	// Components are runtime pieces the installed application needs before it
	// works at all and that Zhiban provisions for it (M3 Task 8: the Claude
	// Code host bundle for Claude Desktop). Only set for the reported, probed
	// installation.
	Components []Component `json:"components,omitempty"`
}

// Component is one provisioned runtime piece; see claudecode.Component.
type Component = claudecode.Component

// ComponentsFunc reports the components of the installation at candidate.
type ComponentsFunc func(ctx context.Context, targetID string, candidate Candidate) []Component

// ResolvedInstallation is Bridge-internal data. It must never be serialized to
// App/UI/log output because RealPath can contain a user name or project data.
type ResolvedInstallation struct {
	TargetID       string
	InstallationID string
	RealPath       string
	Version        string
	Source         InstallSource
}

type DiscoverFunc func(context.Context, string) ([]Candidate, error)
type ProbeFunc func(context.Context, string, Candidate) (string, error)

type Detector struct {
	discover   DiscoverFunc
	probe      ProbeFunc
	components ComponentsFunc
	thirdParty ThirdPartyInferenceFunc
	idKey      []byte
	generation atomic.Uint64
}

// SetComponents installs the component reporter used for installed targets.
func (d *Detector) SetComponents(components ComponentsFunc) {
	d.components = components
}

// ThirdPartyInferenceFunc reports whether an installed desktop application can
// read the third-party inference configuration Zhiban writes; known false
// means it could not tell (never blocks).
type ThirdPartyInferenceFunc func(ctx context.Context, targetID string, candidate Candidate) (supported, known bool)

// SetThirdPartyInference installs the desktop capability check (2026-09-15).
func (d *Detector) SetThirdPartyInference(check ThirdPartyInferenceFunc) {
	d.thirdParty = check
}

func NewDetector(discover DiscoverFunc, probe ProbeFunc, idKey []byte) (*Detector, error) {
	if discover == nil || probe == nil {
		return nil, errors.New("detect: discover and probe are required")
	}
	if len(idKey) != 32 {
		return nil, errors.New("detect: installation id key must contain 32 bytes")
	}
	return &Detector{
		discover: discover,
		probe:    probe,
		idKey:    append([]byte(nil), idKey...),
	}, nil
}

func (d *Detector) Detect(ctx context.Context, targetID string) (State, error) {
	if !validTarget(targetID) {
		return State{}, ErrUnsupportedTarget
	}
	state := State{
		TargetID:          targetID,
		Generation:        d.generation.Add(1),
		FormFactor:        FormFactor(targetID),
		SupportsEnable:    supportsEnable(targetID),
		VerificationLevel: "l0",
		NextActions:       []string{"detect"},
	}
	candidates, err := d.discover(ctx, targetID)
	if err != nil {
		if errors.Is(err, ErrUntrustedSearchPath) {
			state.UIState = UIStateUnsupported
			state.ErrorCode = detectionErrorCode(targetID, "UNTRUSTED_PATH")
			return state, nil
		}
		if errors.Is(err, ErrTargetUnsupportedOnPlatform) {
			state.UIState = UIStateUnsupported
			state.SupportsEnable = false
			state.ErrorCode = detectionErrorCode(targetID, "PLATFORM_UNSUPPORTED")
			return state, nil
		}
		return State{}, fmt.Errorf("discover %s: %w", targetID, err)
	}
	if len(candidates) == 0 {
		state.UIState = UIStateNotInstalled
		return state, nil
	}

	chosen, ok := d.pick(ctx, targetID, candidates)
	if !ok {
		state.UIState = UIStateUnsupported
		state.ErrorCode = detectionErrorCode(targetID, "UNTRUSTED_PATH")
		return state, nil
	}
	candidate, version, err := chosen.candidate, chosen.version, chosen.err
	state.InstallationID = d.installationID(targetID, candidate.RealPath)
	state.InstallSource = candidate.Source
	if err != nil {
		switch {
		case errors.Is(err, ErrProbeTimeout):
			state.UIState = UIStateRepairable
			state.ErrorCode = detectionErrorCode(targetID, "TIMEOUT")
		case errors.Is(err, ErrProbeFailed):
			state.UIState = UIStateRepairable
			state.ErrorCode = detectionErrorCode(targetID, "DAMAGED")
		case errors.Is(err, ErrLayoutIncomplete):
			state.UIState = UIStateRepairable
			state.ErrorCode = detectionErrorCode(targetID, "LAYOUT_INCOMPLETE")
		case errors.Is(err, ErrVersionUnrecognized):
			state.UIState = UIStateUnsupported
			state.ErrorCode = detectionErrorCode(targetID, "VERSION_UNKNOWN")
		default:
			return State{}, fmt.Errorf("probe %s version: %w", targetID, err)
		}
		return state, nil
	}
	if strings.TrimSpace(version) == "" {
		state.UIState = UIStateUnsupported
		state.ErrorCode = detectionErrorCode(targetID, "VERSION_UNKNOWN")
		return state, nil
	}
	state.UIState = UIStateInstalledUnmanaged
	state.InstalledVersion = version
	// 2026-09-15 · Too old to switch: still installed and usable with the
	// official service (open, upgrade), just not switchable.
	if minimum, tooOld := catalog.MinimumSwitchVersion(targetID, version); tooOld {
		state.SupportsEnable = false
		state.MinimumVersion = minimum
		state.ErrorCode = detectionErrorCode(targetID, "VERSION_TOO_OLD")
	}
	if d.components != nil {
		state.Components = d.components(ctx, targetID, candidate)
	}
	// 2026-09-15 · A desktop app too old to read the third-party inference
	// configuration stays usable with the official service but is not
	// switchable (it would ignore what Zhiban writes).
	if d.thirdParty != nil && state.SupportsEnable {
		if supported, known := d.thirdParty(ctx, targetID, candidate); known && !supported {
			state.SupportsEnable = false
			state.ErrorCode = detectionErrorCode(targetID, "THIRD_PARTY_UNSUPPORTED")
		}
	}
	return state, nil
}

// pick chooses the one installation a target is reported as (contract §2.7,
// 2026-09-14). The user's configuration is shared by every copy, so several
// copies are not a question for the user: only trusted copies count; the copy
// the user's own lookup resolves wins when it works; otherwise the highest
// working version, then official > homebrew > npm, then discovery order. When
// no trusted copy works, the preferred copy (else the first) is reported, so
// the card shows what is broken. A broken preferred copy does not hide a
// working one: repairing installs Zhiban's own copy, and reporting the broken
// one again would leave the card stuck on "安装已损坏". ok is false when no
// copy is trusted. Each candidate is probed at most once.
func (d *Detector) pick(ctx context.Context, targetID string, candidates []Candidate) (probedCandidate, bool) {
	trusted := make([]Candidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Source != SourceUnknown {
			trusted = append(trusted, candidate)
		}
	}
	if len(trusted) == 0 {
		return probedCandidate{}, false
	}
	probed := make([]probedCandidate, len(trusted))
	done := make([]bool, len(trusted))
	probeAt := func(index int) probedCandidate {
		if !done[index] {
			version, err := d.probe(ctx, targetID, trusted[index])
			probed[index] = probedCandidate{candidate: trusted[index], version: version, err: err}
			done[index] = true
		}
		return probed[index]
	}
	works := func(result probedCandidate) bool {
		return result.err == nil && strings.TrimSpace(result.version) != ""
	}

	preferred := -1
	for index, candidate := range trusted {
		if candidate.Preferred {
			preferred = index
			break
		}
	}
	if preferred >= 0 && works(probeAt(preferred)) {
		return probed[preferred], true
	}
	best := -1
	for index := range trusted {
		result := probeAt(index)
		if !works(result) {
			continue
		}
		if best < 0 || betterInstallation(result.candidate, result.version, probed[best].candidate, probed[best].version) {
			best = index
		}
	}
	switch {
	case best >= 0:
		return probed[best], true
	case preferred >= 0:
		return probed[preferred], true
	default:
		return probeAt(0), true
	}
}

// probedCandidate is a candidate with the outcome of its version probe.
type probedCandidate struct {
	candidate Candidate
	version   string
	err       error
}

// betterInstallation reports whether a (at version av) outranks b.
func betterInstallation(a Candidate, av string, b Candidate, bv string) bool {
	if order := catalog.CompareVersions(av, bv); order != 0 {
		return order > 0
	}
	return sourceRank(a.Source) > sourceRank(b.Source)
}

func sourceRank(source InstallSource) int {
	switch source {
	case SourceOfficial:
		return 3
	case SourceHomebrew:
		return 2
	case SourceNPM:
		return 1
	default:
		return 0
	}
}

func (d *Detector) installationID(targetID, realPath string) string {
	digest := hmac.New(sha256.New, d.idKey)
	_, _ = digest.Write([]byte(targetID))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(realPath))
	return base64.RawURLEncoding.EncodeToString(digest.Sum(nil))
}

// ResolveInstallation repeats discovery and version probing, then binds the
// result to an opaque ID created by this Detector session. Write/launch plans
// call this immediately before acting so a stale App snapshot cannot select a
// different executable. When several installations coexist, the ID selects
// exactly one of them (the user's explicit choice).
func (d *Detector) ResolveInstallation(ctx context.Context, targetID, installationID string) (ResolvedInstallation, error) {
	if !validTarget(targetID) || installationID == "" || len(installationID) > 128 {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	candidates, err := d.discover(ctx, targetID)
	if err != nil {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	var selected *Candidate
	for index := range candidates {
		candidate := candidates[index]
		if subtle.ConstantTimeCompare([]byte(d.installationID(targetID, candidate.RealPath)), []byte(installationID)) == 1 {
			if selected != nil {
				return ResolvedInstallation{}, ErrInstallationChanged
			}
			selected = &candidate
		}
	}
	if selected == nil || selected.Source == SourceUnknown {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	version, err := d.probe(ctx, targetID, *selected)
	if err != nil || strings.TrimSpace(version) == "" {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	return ResolvedInstallation{
		TargetID:       targetID,
		InstallationID: installationID,
		RealPath:       selected.RealPath,
		Version:        version,
		Source:         selected.Source,
	}, nil
}

// ResolveCurrentInstallations returns every trusted installation that still
// answers a version probe. A fresh Bridge process (the launch ticket consumer)
// uses it to find the one whose fingerprint the ticket recorded.
func (d *Detector) ResolveCurrentInstallations(ctx context.Context, targetID string) ([]ResolvedInstallation, error) {
	if !validTarget(targetID) {
		return nil, ErrInstallationChanged
	}
	candidates, err := d.discover(ctx, targetID)
	if err != nil {
		return nil, ErrInstallationChanged
	}
	result := make([]ResolvedInstallation, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Source == SourceUnknown {
			continue
		}
		version, err := d.probe(ctx, targetID, candidate)
		if err != nil || strings.TrimSpace(version) == "" {
			continue
		}
		result = append(result, ResolvedInstallation{
			TargetID:       targetID,
			InstallationID: d.installationID(targetID, candidate.RealPath),
			RealPath:       candidate.RealPath,
			Version:        version,
			Source:         candidate.Source,
		})
	}
	if len(result) == 0 {
		return nil, ErrInstallationChanged
	}
	return result, nil
}

// TrustedExecutables lists the real paths of every trusted installation
// without probing versions (desktop probes run codesign). The configuration
// manager uses it to notice that the Codex executables sharing
// ~/.codex/config.toml changed since the model catalog was validated.
func (d *Detector) TrustedExecutables(ctx context.Context, targetID string) ([]string, error) {
	if !validTarget(targetID) {
		return nil, ErrInstallationChanged
	}
	candidates, err := d.discover(ctx, targetID)
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Source != SourceUnknown && candidate.RealPath != "" {
			result = append(result, candidate.RealPath)
		}
	}
	return result, nil
}

// ResolveCurrentInstallation is used by a one-time launch ticket consumer.
// Installation IDs are intentionally process-local, so a fresh Bridge process
// must rediscover the single trusted installation and compare a separate
// launch fingerprint instead of accepting an old process's opaque ID.
func (d *Detector) ResolveCurrentInstallation(ctx context.Context, targetID string) (ResolvedInstallation, error) {
	if !validTarget(targetID) {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	candidates, err := d.discover(ctx, targetID)
	if err != nil || len(candidates) != 1 || candidates[0].Source == SourceUnknown {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	candidate := candidates[0]
	version, err := d.probe(ctx, targetID, candidate)
	if err != nil || strings.TrimSpace(version) == "" {
		return ResolvedInstallation{}, ErrInstallationChanged
	}
	return ResolvedInstallation{
		TargetID:       targetID,
		InstallationID: d.installationID(targetID, candidate.RealPath),
		RealPath:       candidate.RealPath,
		Version:        version,
		Source:         candidate.Source,
	}, nil
}

func detectionErrorCode(targetID, reason string) string {
	return "LCT-" + strings.ToUpper(targetID) + "-DETECT-" + reason
}
