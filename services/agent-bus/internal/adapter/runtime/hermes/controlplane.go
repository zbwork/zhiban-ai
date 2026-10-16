// Package hermes implements controlplane.RuntimeControlPlane for the Hermes
// runtime framework. It follows the same option-wiring pattern as the OpenClaw
// adapter: capabilities are derived from which writers/fetchers are wired at
// construction time.
package hermes

import (
	"context"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/controlplane"
)

// Framework is the canonical framework identifier for Hermes runtimes.
const Framework = "hermes"

// HermesControlPlane satisfies controlplane.RuntimeControlPlane for Hermes.
type HermesControlPlane struct {
	workspace    controlplane.WorkspaceWriter
	remover      controlplane.WorkspaceRemover
	fetchPackage func(ctx context.Context, packageKey string) ([]byte, error)
	execPolicy   func(controlplane.ExecEnv) bool
}

// CPOption configures an HermesControlPlane.
type CPOption func(*HermesControlPlane)

// WithExecutablePolicy sets the policy that decides whether a given ExecEnv
// is eligible for agent sync execution.
func WithExecutablePolicy(p func(controlplane.ExecEnv) bool) CPOption {
	return func(cp *HermesControlPlane) { cp.execPolicy = p }
}

// WithWorkspaceWriter wires the writer used for agent identity files and
// skill package installation.
func WithWorkspaceWriter(w controlplane.WorkspaceWriter) CPOption {
	return func(cp *HermesControlPlane) { cp.workspace = w }
}

// WithWorkspaceRemover wires the remover used for skill uninstallation.
func WithWorkspaceRemover(r controlplane.WorkspaceRemover) CPOption {
	return func(cp *HermesControlPlane) { cp.remover = r }
}

// WithPackageFetcher wires the controlled fetcher (OSS key -> bytes) for
// skill package installation. Nil values are ignored.
func WithPackageFetcher(f func(ctx context.Context, packageKey string) ([]byte, error)) CPOption {
	return func(cp *HermesControlPlane) {
		if f != nil {
			cp.fetchPackage = f
		}
	}
}

// NewHermesControlPlane creates an HermesControlPlane with the given options.
func NewHermesControlPlane(opts ...CPOption) *HermesControlPlane {
	p := &HermesControlPlane{}
	for _, o := range opts {
		o(p)
	}
	return p
}

// Framework returns "hermes".
func (p *HermesControlPlane) Framework() string { return Framework }

// skillInstallable returns true when both workspace writer and package fetcher
// are wired (install requires both).
func (p *HermesControlPlane) skillInstallable() bool {
	return p.workspace != nil && p.fetchPackage != nil
}

// skillUninstallable returns true when the remover is wired (uninstall only
// needs the remover, not the fetcher).
func (p *HermesControlPlane) skillUninstallable() bool { return p.remover != nil }

// Capabilities returns the static capability upper bound derived from wiring.
// CapAgentCreate is always present; skill capabilities depend on wiring.
func (p *HermesControlPlane) Capabilities() controlplane.CapabilitySet {
	caps := controlplane.With(controlplane.CapAgentCreate)
	if p.skillInstallable() {
		caps[controlplane.CapSkillInstall] = true
	}
	if p.skillUninstallable() {
		caps[controlplane.CapSkillUninstall] = true
	}
	return caps
}

// AgentSyncExecutable returns whether the given env is eligible for agent sync
// execution according to the wired policy. Returns false when no policy is set.
func (p *HermesControlPlane) AgentSyncExecutable(env controlplane.ExecEnv) bool {
	if p.execPolicy == nil {
		return false
	}
	return p.execPolicy(env)
}

// AgentSyncer returns an AgentSyncer if a workspace writer is wired, nil otherwise.
func (p *HermesControlPlane) AgentSyncer() controlplane.AgentSyncer {
	if p.workspace == nil {
		return nil
	}
	return &hermesAgentSyncer{workspace: p.workspace}
}

// SkillSyncer returns a SkillSyncer if install or uninstall wiring is present,
// nil otherwise.
func (p *HermesControlPlane) SkillSyncer() controlplane.SkillSyncer {
	if !p.skillInstallable() && !p.skillUninstallable() {
		return nil
	}
	return &hermesSkillSyncer{
		workspace:    p.workspace,
		remover:      p.remover,
		fetchPackage: p.fetchPackage,
	}
}

// isSyncError returns true if err is a *controlplane.SyncError.
func isSyncError(err error) bool {
	_, ok := err.(*controlplane.SyncError)
	return ok
}
