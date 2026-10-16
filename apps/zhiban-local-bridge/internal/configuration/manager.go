package configuration

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const (
	TargetCodexCLI      = "codex_cli"
	TargetClaudeCLI     = "claude_cli"
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	CodexProfileName     = "zhiban-ai-managed"
	CodexProfileFileName = CodexProfileName + ".config.toml"
	applicationSupportID = "cn.qkfintech.zhiban"

	StateNotConfigured = "not_configured"
	StateConfigured    = "configured"
	StateConflict      = "conflict"

	ActionCreate   = "create"
	ActionUpdate   = "update"
	ActionNone     = "none"
	ActionConflict = "conflict"
	// ActionRepair rewrites a conflicted managed file after the user confirmed
	// the deterministic repair plan (v1.7 §12 一键修复 → 确认修复).
	ActionRepair = "repair"

	PlanTypeEnable = "enable"
	PlanTypeRepair = "repair"

	planTTL             = 2 * time.Minute
	probeTimeout        = 5 * time.Second
	maxManagedFileBytes = 64 << 10
	maxPolicyFileBytes  = 256 << 10

	// DefaultClaudeManagedPolicyPath is the enterprise managed settings file
	// Claude Code applies above every user or session setting (v1.7 §7.3).
	DefaultClaudeManagedPolicyPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
	manifestSchemaV1               = 1
	manifestSchemaV2               = 2

	VerificationL0 = "l0"
	VerificationL1 = "l1"
	VerificationL2 = "l2"
	VerificationL3 = "l3"
)

var (
	ErrInvalidInput         = errors.New("configuration: invalid input")
	ErrAuthorizationMissing = errors.New("configuration: authorization missing")
	ErrProfileUnavailable   = errors.New("configuration: profile unavailable")
	ErrInstallationChanged  = errors.New("configuration: installation changed")
	ErrUnsupportedVersion   = errors.New("configuration: unsupported version")
	// ErrVersionTooOld refuses a global switch for an installation older than
	// catalog.MinimumSwitchVersion.
	ErrVersionTooOld       = errors.New("configuration: installed version too old to switch")
	ErrConflict            = errors.New("configuration: conflict")
	ErrPlanNotFound        = errors.New("configuration: plan not found")
	ErrPlanExpired         = errors.New("configuration: plan expired")
	ErrPreconditionChanged = errors.New("configuration: precondition changed")
	ErrUnsafePath          = errors.New("configuration: unsafe path")
	ErrValidationFailed    = errors.New("configuration: validation failed")
	ErrRollbackFailed      = errors.New("configuration: rollback failed")
	// ErrPolicyConflict means an enterprise managed policy already pins the
	// keys the Zhiban overlay would set; the Bridge fails closed instead of
	// trying to bypass it.
	ErrPolicyConflict = errors.New("configuration: managed policy conflict")
)

type Environment string

const (
	EnvironmentDev  Environment = "dev"
	EnvironmentTest Environment = "test"
	EnvironmentProd Environment = "prod"
)

// GatewayProfile is the build-time gateway profile for one target. Model is
// the alias the managed configuration pins so the CLI never falls back to a
// publisher default the gateway does not serve.
type GatewayProfile struct {
	Version string
	BaseURL string
	Model   string
}

type AuthorizationProfile struct {
	Environment    Environment
	ProfileVersion string
}

type Installation struct {
	TargetID       string
	InstallationID string
	Executable     string
	Version        string
}

type ResolveInstallationFunc func(context.Context, string, string) (Installation, error)
type ResolveAuthorizationFunc func(context.Context, string) (AuthorizationProfile, error)
type ProbeFunc func(context.Context, Installation, string) error

type ManagerConfig struct {
	HomeDir              string
	CodexHome            string
	HelperExecutable     string
	Profiles             map[Environment]map[string]GatewayProfile
	SupportedVersions    map[string]string
	ResolveInstallation  ResolveInstallationFunc
	ResolveAuthorization ResolveAuthorizationFunc
	Probe                ProbeFunc
	Now                  func() time.Time
	Random               io.Reader
	// ClaudeManagedPolicyPath overrides DefaultClaudeManagedPolicyPath (tests).
	ClaudeManagedPolicyPath string
	// ProbeGlobal overrides the global-switch probe (tests).
	ProbeGlobal func(context.Context, Installation) error
	// NodeLookup finds the Node runtime an npm-installed CLI needs when node
	// is not beside the package. Optional: the Node prefix the package lives
	// under is always tried first.
	NodeLookup *shellenv.LoginShellLookup
	// CodexExecutables and GatewayModelIDs enable the Codex model catalog
	// (codex_catalog.go); without both the switch never writes one.
	CodexExecutables CodexExecutablesFunc
	GatewayModelIDs  GatewayModelIDsFunc
	// CodexCommand overrides how Codex is run for the model catalog (tests).
	CodexCommand CodexCommandFunc
}

type Status struct {
	TargetID          string   `json:"target_id"`
	State             string   `json:"state"`
	ProfileVersion    string   `json:"profile_version,omitempty"`
	VerificationLevel string   `json:"verification_level"`
	LastVerifiedAt    string   `json:"last_verified_at,omitempty"`
	ErrorCode         string   `json:"error_code,omitempty"`
	NextActions       []string `json:"next_actions"`
	// PolicyConflict is set when an enterprise managed policy overrides the
	// managed overlay; enable/repair/managed launch are refused while it holds.
	PolicyConflict bool `json:"policy_conflict,omitempty"`
	// Global switch view ("当前服务", global.go).
	CurrentService          string `json:"current_service"`
	GlobalSwitched          bool   `json:"global_switched,omitempty"`
	GlobalBackupAvailable   bool   `json:"global_backup_available,omitempty"`
	GlobalDrifted           bool   `json:"global_drifted,omitempty"`
	GlobalVerificationLevel string `json:"global_verification_level,omitempty"`
	GlobalLastVerifiedAt    string `json:"global_last_verified_at,omitempty"`
	GlobalUpgradeAvailable  bool   `json:"global_upgrade_available,omitempty"`
	// Codex threads re-pointed at the restored provider by restore_global
	// (codex_sessions.go); only set on that execute's result. Indexed is
	// the index-database rows (what thread/resume reads), Remapped the
	// rollout files, Skipped the rollouts left alone as still being written.
	CodexSessionsIndexed  int      `json:"codex_sessions_indexed,omitempty"`
	CodexSessionsRemapped int      `json:"codex_sessions_remapped,omitempty"`
	CodexSessionsSkipped  int      `json:"codex_sessions_skipped,omitempty"`
	CodexSessionsErrors   []string `json:"codex_sessions_errors,omitempty"`
}

type Plan struct {
	PlanID         string `json:"plan_id,omitempty"`
	TargetID       string `json:"target_id"`
	Action         string `json:"action"`
	ProfileVersion string `json:"profile_version,omitempty"`
	ExpiresAt      string `json:"expires_at,omitempty"`
}

// LaunchConfiguration is Bridge-internal data. It may contain a local managed
// settings path and must never be serialized to App/UI/log output.
type LaunchConfiguration struct {
	TargetID       string
	ProfileVersion string
	Arguments      []string
}

// manifest is the Zhiban-side state file. Schema 2 adds the L3 verification
// record; schema 1 files are still read and upgraded on the next write.
type manifest struct {
	SchemaVersion        int    `json:"schema_version"`
	TargetID             string `json:"target_id"`
	ProfileVersion       string `json:"profile_version"`
	FileKind             string `json:"file_kind"`
	AppliedSHA256        string `json:"applied_sha256"`
	VerifiedAt           string `json:"verified_at,omitempty"`
	VerificationLevel    string `json:"verification_level,omitempty"`
	VerifiedVersion      string `json:"verified_version,omitempty"`
	VerifiedConfigSHA256 string `json:"verified_config_sha256,omitempty"`
}

type claudeManagedSettings struct {
	Schema       string `json:"$schema"`
	APIKeyHelper string `json:"apiKeyHelper"`
	Model        string `json:"model,omitempty"`
	Env          struct {
		AnthropicBaseURL   string `json:"ANTHROPIC_BASE_URL"`
		DisableAutoupdater string `json:"DISABLE_AUTOUPDATER,omitempty"`
	} `json:"env"`
}

type fileSnapshot struct {
	Exists bool
	Bytes  []byte
	Mode   os.FileMode
	SHA256 string
}

type pendingPlan struct {
	Public         Plan
	ExpiresAt      time.Time
	Installation   Installation
	Authorization  AuthorizationProfile
	HelperInfo     os.FileInfo
	ConfigPath     string
	ManifestPath   string
	Desired        []byte
	ConfigBefore   fileSnapshot
	ManifestBefore fileSnapshot
	// Global switch plans (global.go).
	Global             bool
	GlobalOriginal     json.RawMessage
	RestoreRemovesFile bool
	// AdoptedOriginal is the pre-switch file recorded when a switch takes over
	// a Zhiban-routed file that has no record (B3): the file minus Zhiban's
	// region. BackupBeforeRestore makes such a restore back the file up first.
	AdoptedOriginal     *fileSnapshot
	BackupBeforeRestore bool
	// Extra is a second managed file written after the main one (Claude
	// Desktop's _meta.json, desktop_claude.go).
	Extra *extraFile
	// CodexCatalog is the model catalog decision a Codex switch applies, and
	// CatalogBefore the catalog file it expects to find (codex_catalog.go).
	CodexCatalog  *codexCatalogResult
	CatalogBefore fileSnapshot
}

// extraFile is a secondary file a global plan writes (or removes) together
// with the main configuration file, under the same CAS discipline.
type extraFile struct {
	Path    string
	Before  fileSnapshot
	Desired []byte
	Remove  bool
}

type Manager struct {
	homeDir              string
	codexHome            string
	helperExecutable     string
	profiles             map[Environment]map[string]GatewayProfile
	supportedVersions    map[string]string
	resolveInstallation  ResolveInstallationFunc
	resolveAuthorization ResolveAuthorizationFunc
	probe                ProbeFunc
	probeGlobalFunc      func(context.Context, Installation) error
	nodeLookup           *shellenv.LoginShellLookup
	codexExecutables     CodexExecutablesFunc
	gatewayModelIDs      GatewayModelIDsFunc
	codexCommand         CodexCommandFunc
	// codexExecutablesCache avoids resolving the executables on every status;
	// catalogMu guards it because catalogs are built outside mu.
	catalogMu                sync.Mutex
	catalogPlanBudget        time.Duration // codexCatalogPlanBudget; tests shorten it
	codexExecutablesCache    []codexCatalogExecutable
	codexExecutablesCachedAt time.Time
	now                      func() time.Time
	random                   io.Reader
	policyPath               string
	// systemCABundle is the root bundle a Claude settings.json is pointed at
	// (claude_extraca.go); "" where the platform has none. Tests replace it.
	systemCABundle string

	mu    sync.Mutex
	plans map[string]pendingPlan
}

func NewManager(config ManagerConfig) (*Manager, error) {
	homeDir := filepath.Clean(strings.TrimSpace(config.HomeDir))
	if homeDir == "." || !filepath.IsAbs(homeDir) || config.ResolveInstallation == nil || config.ResolveAuthorization == nil {
		return nil, ErrInvalidInput
	}
	codexHome := filepath.Clean(strings.TrimSpace(config.CodexHome))
	if config.CodexHome == "" {
		codexHome = filepath.Join(homeDir, ".codex")
	}
	if !pathInsideOrEqual(codexHome, homeDir) {
		return nil, ErrInvalidInput
	}
	helper := filepath.Clean(strings.TrimSpace(config.HelperExecutable))
	if !filepath.IsAbs(helper) {
		return nil, ErrInvalidInput
	}
	profiles := cloneProfiles(config.Profiles)
	profileCount := 0
	for environment, byTarget := range profiles {
		if !validEnvironment(environment) {
			return nil, ErrInvalidInput
		}
		for target, profile := range byTarget {
			if !validTarget(target) || !validSafeValue(profile.Version) || validateGatewayURL(environment, profile.BaseURL) != nil ||
				(profile.Model != "" && !validSafeValue(profile.Model)) {
				return nil, ErrInvalidInput
			}
			profileCount++
		}
	}
	if profileCount == 0 {
		return nil, ErrInvalidInput
	}
	versions := make(map[string]string, len(config.SupportedVersions))
	for target, version := range config.SupportedVersions {
		if !validTarget(target) || !validSafeValue(version) {
			return nil, ErrInvalidInput
		}
		versions[target] = version
	}
	// Both CLI targets are mandatory; desktop targets (M3) are optional extras.
	if len(versions) < 2 || versions[TargetCodexCLI] == "" || versions[TargetClaudeCLI] == "" {
		return nil, ErrInvalidInput
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	randomReader := config.Random
	if randomReader == nil {
		randomReader = rand.Reader
	}
	manager := &Manager{
		homeDir:              homeDir,
		codexHome:            codexHome,
		helperExecutable:     helper,
		profiles:             profiles,
		supportedVersions:    versions,
		resolveInstallation:  config.ResolveInstallation,
		resolveAuthorization: config.ResolveAuthorization,
		probe:                config.Probe,
		now:                  now,
		random:               randomReader,
		policyPath:           config.ClaudeManagedPolicyPath,
		probeGlobalFunc:      config.ProbeGlobal,
		nodeLookup:           config.NodeLookup,
		codexExecutables:     config.CodexExecutables,
		gatewayModelIDs:      config.GatewayModelIDs,
		codexCommand:         config.CodexCommand,
		plans:                make(map[string]pendingPlan),
	}
	manager.systemCABundle = detectSystemCABundle()
	if manager.policyPath == "" {
		manager.policyPath = DefaultClaudeManagedPolicyPath
	}
	if manager.probe == nil {
		manager.probe = manager.runProbe
	}
	return manager, nil
}

func (m *Manager) Status(_ context.Context, targetID string) (Status, error) {
	if !validTarget(targetID) {
		return Status{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	status, err := m.fullStatusLocked(targetID)
	if errors.Is(err, ErrUnsafePath) {
		return Status{
			TargetID: targetID, State: StateConflict, CurrentService: ServiceUnknown,
			VerificationLevel: VerificationL0, ErrorCode: errorCode(targetID, "UNSAFE_PATH"),
			NextActions: []string{"inspect"},
		}, nil
	}
	return status, err
}

// fullStatusLocked is the overlay status merged with the policy-conflict and
// global-switch views; it is what config.status returns.
func (m *Manager) fullStatusLocked(targetID string) (Status, error) {
	status, err := m.statusLocked(targetID)
	if err != nil {
		return Status{}, err
	}
	if m.policyConflict(targetID) {
		status.PolicyConflict = true
		status.ErrorCode = errorCode(targetID, "POLICY_CONFLICT")
		status.NextActions = []string{"inspect"}
	}
	global, err := m.globalStatusLocked(targetID)
	if err != nil {
		return Status{}, err
	}
	status.CurrentService = global.CurrentService
	status.GlobalSwitched = global.SwitchedByZhiban
	status.GlobalBackupAvailable = global.BackupAvailable
	status.GlobalDrifted = global.Drifted
	status.GlobalUpgradeAvailable = global.UpgradeAvailable
	if global.SwitchedByZhiban {
		status.GlobalVerificationLevel = global.VerificationLevel
		status.GlobalLastVerifiedAt = global.LastVerifiedAt
	}
	return status, nil
}

// policyConflict reports whether an enterprise managed policy pins the keys
// the Zhiban overlay relies on. Only Claude Code has a documented managed
// policy file; Codex has none to check.
func (m *Manager) policyConflict(targetID string) bool {
	if targetID != TargetClaudeCLI {
		return false
	}
	info, err := os.Stat(m.policyPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPolicyFileBytes {
		return false
	}
	content, err := os.ReadFile(m.policyPath)
	if err != nil {
		return false
	}
	var policy struct {
		APIKeyHelper *string           `json:"apiKeyHelper"`
		Env          map[string]string `json:"env"`
	}
	if json.Unmarshal(content, &policy) != nil {
		return false
	}
	if policy.APIKeyHelper != nil {
		return true
	}
	for _, key := range []string{
		"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
		"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
	} {
		if _, pinned := policy.Env[key]; pinned {
			return true
		}
	}
	return false
}

func (m *Manager) ResolveLaunchConfiguration(ctx context.Context, targetID, profileVersion string) (LaunchConfiguration, error) {
	if !validTarget(targetID) || !validSafeValue(profileVersion) {
		return LaunchConfiguration{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	status, err := m.statusLocked(targetID)
	if err != nil || status.State != StateConfigured || status.ProfileVersion != profileVersion {
		return LaunchConfiguration{}, ErrPreconditionChanged
	}
	if m.policyConflict(targetID) {
		return LaunchConfiguration{}, ErrPolicyConflict
	}
	authorization, err := m.resolveAuthorization(ctx, targetID)
	if err != nil || authorization.ProfileVersion != profileVersion || !validEnvironment(authorization.Environment) {
		return LaunchConfiguration{}, ErrPreconditionChanged
	}
	profile, ok := m.profiles[authorization.Environment][targetID]
	if !ok || profile.Version != profileVersion {
		return LaunchConfiguration{}, ErrPreconditionChanged
	}
	if err := validateExecutable(m.helperExecutable); err != nil {
		return LaunchConfiguration{}, ErrPreconditionChanged
	}

	arguments := []string{"--profile", CodexProfileName}
	if targetID == TargetClaudeCLI {
		arguments = []string{"--settings", m.configPath(targetID)}
	}
	return LaunchConfiguration{
		TargetID: targetID, ProfileVersion: profileVersion, Arguments: arguments,
	}, nil
}

func (m *Manager) Plan(ctx context.Context, targetID, installationID string) (Plan, error) {
	return m.PlanWithType(ctx, targetID, installationID, PlanTypeEnable)
}

// PlanWithType is Plan with an explicit plan type. PlanTypeRepair is the only
// way to obtain a write plan while the managed file is in the conflict state;
// it still snapshots the current bytes so Execute can roll back.
func (m *Manager) PlanWithType(ctx context.Context, targetID, installationID, planType string) (Plan, error) {
	if planType == "" {
		planType = PlanTypeEnable
	}
	if !validTarget(targetID) || len(installationID) > 128 ||
		(planType != PlanTypeEnable && planType != PlanTypeRepair && planType != PlanTypeSwitchGlobal && planType != PlanTypeRestoreGlobal) ||
		(planType != PlanTypeRestoreGlobal && strings.TrimSpace(installationID) == "") ||
		(IsDesktopTarget(targetID) && planType != PlanTypeSwitchGlobal && planType != PlanTypeRestoreGlobal) {
		return Plan{}, ErrInvalidInput
	}
	if m.policyConflict(targetID) {
		return Plan{}, ErrPolicyConflict
	}
	// The Codex model catalog runs every local Codex and asks the gateway:
	// build it before taking mu so status calls are not held up, within a
	// budget that keeps config.plan under the App's RPC timeout (a catalog
	// that does not finish in time is decided again by verify.execute).
	codexCatalog := m.prebuildCodexCatalog(ctx, targetID, planType)
	m.mu.Lock()
	defer m.mu.Unlock()
	if planType == PlanTypeSwitchGlobal || planType == PlanTypeRestoreGlobal {
		return m.planGlobalLocked(ctx, targetID, installationID, planType, codexCatalog)
	}

	installation, err := m.resolveInstallation(ctx, targetID, installationID)
	if err != nil || installation.TargetID != targetID || installation.InstallationID != installationID {
		return Plan{}, ErrInstallationChanged
	}
	if installation.Version != m.supportedVersions[targetID] {
		return Plan{}, ErrUnsupportedVersion
	}
	if err := validateExecutable(installation.Executable); err != nil {
		return Plan{}, ErrInstallationChanged
	}
	if err := validateExecutable(m.helperExecutable); err != nil {
		return Plan{}, err
	}
	helperInfo, err := os.Stat(m.helperExecutable)
	if err != nil {
		return Plan{}, ErrUnsafePath
	}

	authorization, err := m.resolveAuthorization(ctx, targetID)
	if err != nil {
		if errors.Is(err, ErrAuthorizationMissing) {
			return Plan{}, err
		}
		return Plan{}, ErrAuthorizationMissing
	}
	profile, ok := m.profiles[authorization.Environment][targetID]
	if !ok || profile.Version != authorization.ProfileVersion || !validSafeValue(profile.Version) ||
		validateGatewayURL(authorization.Environment, profile.BaseURL) != nil {
		return Plan{}, ErrProfileUnavailable
	}

	configPath := m.configPath(targetID)
	manifestPath := m.manifestPath(targetID)
	configBefore, err := m.snapshot(configPath, false)
	if err != nil {
		return Plan{}, err
	}
	manifestBefore, err := m.snapshot(manifestPath, false)
	if err != nil {
		return Plan{}, err
	}
	currentStatus, err := m.statusFromSnapshots(targetID, configBefore, manifestBefore)
	if err != nil {
		return Plan{}, err
	}
	if currentStatus.State == StateConflict && planType != PlanTypeRepair {
		return Plan{TargetID: targetID, Action: ActionConflict, ProfileVersion: authorization.ProfileVersion}, nil
	}
	desired, err := m.render(targetID, profile)
	if err != nil {
		return Plan{}, err
	}
	action := ActionCreate
	switch {
	case currentStatus.State == StateConflict:
		action = ActionRepair
	case configBefore.Exists:
		action = ActionUpdate
		if bytes.Equal(configBefore.Bytes, desired) && currentStatus.ProfileVersion == authorization.ProfileVersion {
			action = ActionNone
		}
	}
	expiresAt := m.now().UTC().Add(planTTL)
	planID, err := m.newPlanID()
	if err != nil {
		return Plan{}, err
	}
	public := Plan{
		PlanID:         planID,
		TargetID:       targetID,
		Action:         action,
		ProfileVersion: authorization.ProfileVersion,
		ExpiresAt:      expiresAt.Format(time.RFC3339),
	}
	m.plans[planID] = pendingPlan{
		Public:         public,
		ExpiresAt:      expiresAt,
		Installation:   installation,
		Authorization:  authorization,
		HelperInfo:     helperInfo,
		ConfigPath:     configPath,
		ManifestPath:   manifestPath,
		Desired:        desired,
		ConfigBefore:   configBefore,
		ManifestBefore: manifestBefore,
	}
	return public, nil
}

func (m *Manager) Execute(ctx context.Context, planID string) (status Status, err error) {
	if strings.TrimSpace(planID) == "" || len(planID) > 128 {
		return Status{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	plan, ok := m.plans[planID]
	if !ok {
		return Status{}, ErrPlanNotFound
	}
	// A failed execute still names its target so the caller can report and
	// record a target-specific code.
	defer func() {
		if err != nil {
			status = Status{TargetID: plan.Public.TargetID}
		}
	}()
	delete(m.plans, planID)
	if m.now().After(plan.ExpiresAt) {
		return Status{}, ErrPlanExpired
	}
	if plan.Global {
		return m.executeGlobalLocked(ctx, plan)
	}
	configNow, err := m.snapshot(plan.ConfigPath, false)
	if err != nil {
		return Status{}, err
	}
	manifestNow, err := m.snapshot(plan.ManifestPath, false)
	if err != nil {
		return Status{}, err
	}
	if !sameSnapshot(configNow, plan.ConfigBefore) || !sameSnapshot(manifestNow, plan.ManifestBefore) {
		return Status{}, ErrPreconditionChanged
	}
	installation, err := m.resolveInstallation(ctx, plan.Public.TargetID, plan.Installation.InstallationID)
	if err != nil || installation.Executable != plan.Installation.Executable || installation.Version != plan.Installation.Version {
		return Status{}, ErrInstallationChanged
	}
	authorization, err := m.resolveAuthorization(ctx, plan.Public.TargetID)
	if err != nil || authorization != plan.Authorization {
		return Status{}, ErrPreconditionChanged
	}
	if err := validateExecutable(m.helperExecutable); err != nil {
		return Status{}, ErrPreconditionChanged
	}
	helperInfo, err := os.Stat(m.helperExecutable)
	if err != nil || !sameFileInfo(plan.HelperInfo, helperInfo) {
		return Status{}, ErrPreconditionChanged
	}
	if plan.Public.Action == ActionNone {
		return m.statusLocked(plan.Public.TargetID)
	}
	if plan.Public.Action != ActionCreate && plan.Public.Action != ActionUpdate && plan.Public.Action != ActionRepair {
		return Status{}, ErrInvalidInput
	}

	desiredConfig := snapshotForContent(plan.Desired, 0o600)
	if err := m.atomicWriteCAS(plan.ConfigPath, plan.Desired, 0o600, plan.ConfigBefore); err != nil {
		if !errors.Is(err, ErrPreconditionChanged) && !errors.Is(err, ErrUnsafePath) {
			if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, desiredConfig, plan.ConfigBefore); rollbackErr != nil {
				return Status{}, errors.Join(err, ErrRollbackFailed)
			}
		}
		return Status{}, err
	}
	written, err := m.snapshot(plan.ConfigPath, false)
	if err != nil || !written.Exists || !bytes.Equal(written.Bytes, plan.Desired) || validateManagedContent(plan.Public.TargetID, written.Bytes) != nil {
		if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, desiredConfig, plan.ConfigBefore); rollbackErr != nil {
			return Status{}, errors.Join(ErrValidationFailed, ErrRollbackFailed)
		}
		return Status{}, ErrValidationFailed
	}
	if err := m.probe(ctx, installation, plan.ConfigPath); err != nil {
		if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore); rollbackErr != nil {
			return Status{}, errors.Join(ErrValidationFailed, ErrRollbackFailed)
		}
		return Status{}, ErrValidationFailed
	}
	verified, err := m.snapshot(plan.ConfigPath, false)
	if err != nil || !sameSnapshot(verified, written) {
		return Status{}, ErrPreconditionChanged
	}
	manifestBytes, err := json.Marshal(manifest{
		SchemaVersion:  manifestSchemaV2,
		TargetID:       plan.Public.TargetID,
		ProfileVersion: plan.Public.ProfileVersion,
		FileKind:       fileKind(plan.Public.TargetID),
		AppliedSHA256:  digest(plan.Desired),
	})
	if err != nil {
		if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore); rollbackErr != nil {
			return Status{}, errors.Join(ErrValidationFailed, ErrRollbackFailed)
		}
		return Status{}, ErrValidationFailed
	}
	manifestBytes = append(manifestBytes, '\n')
	desiredManifest := snapshotForContent(manifestBytes, 0o600)
	if err := m.atomicWriteCAS(plan.ManifestPath, manifestBytes, 0o600, plan.ManifestBefore); err != nil {
		configRollback := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore)
		var manifestRollback error
		if !errors.Is(err, ErrPreconditionChanged) && !errors.Is(err, ErrUnsafePath) {
			manifestRollback = m.restoreSnapshotCAS(plan.ManifestPath, desiredManifest, plan.ManifestBefore)
		}
		if configRollback != nil || manifestRollback != nil {
			return Status{}, errors.Join(err, ErrRollbackFailed)
		}
		return Status{}, err
	}
	configAfter, configErr := m.snapshot(plan.ConfigPath, false)
	manifestAfter, manifestErr := m.snapshot(plan.ManifestPath, false)
	if configErr != nil || manifestErr != nil || !sameSnapshot(configAfter, written) || !sameSnapshot(manifestAfter, desiredManifest) {
		var rollbackErrors []error
		if manifestErr == nil && sameSnapshot(manifestAfter, desiredManifest) {
			rollbackErrors = append(rollbackErrors, m.restoreSnapshotCAS(plan.ManifestPath, desiredManifest, plan.ManifestBefore))
		}
		if configErr == nil && sameSnapshot(configAfter, written) {
			rollbackErrors = append(rollbackErrors, m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore))
		}
		for _, rollbackErr := range rollbackErrors {
			if rollbackErr != nil {
				return Status{}, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
			}
		}
		return Status{}, ErrPreconditionChanged
	}
	return m.statusLocked(plan.Public.TargetID)
}

func (m *Manager) Restore(_ context.Context, targetID string) (Status, error) {
	if !validTarget(targetID) {
		return Status{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	configPath := m.configPath(targetID)
	manifestPath := m.manifestPath(targetID)
	configBefore, err := m.snapshot(configPath, false)
	if err != nil {
		return Status{}, err
	}
	manifestBefore, err := m.snapshot(manifestPath, false)
	if err != nil {
		return Status{}, err
	}
	status, err := m.statusFromSnapshots(targetID, configBefore, manifestBefore)
	if err != nil {
		return Status{}, err
	}
	if status.State == StateNotConfigured {
		return status, nil
	}
	if status.State != StateConfigured {
		return Status{}, ErrConflict
	}
	if err := m.removeSnapshotCAS(manifestPath, manifestBefore); err != nil {
		return Status{}, err
	}
	if err := m.removeSnapshotCAS(configPath, configBefore); err != nil {
		if rollbackErr := m.atomicWriteCAS(manifestPath, manifestBefore.Bytes, manifestBefore.Mode, fileSnapshot{}); rollbackErr != nil {
			return Status{}, errors.Join(err, ErrRollbackFailed)
		}
		return Status{}, err
	}
	return notConfiguredStatus(targetID), nil
}

func (m *Manager) statusLocked(targetID string) (Status, error) {
	if IsDesktopTarget(targetID) {
		// Desktop applications have no Zhiban overlay; only the global switch
		// applies to them.
		return Status{
			TargetID: targetID, State: StateNotConfigured, VerificationLevel: VerificationL0,
			NextActions: []string{"switch_global"},
		}, nil
	}
	config, err := m.snapshot(m.configPath(targetID), false)
	if err != nil {
		return Status{}, err
	}
	state, err := m.snapshot(m.manifestPath(targetID), false)
	if err != nil {
		return Status{}, err
	}
	return m.statusFromSnapshots(targetID, config, state)
}

func (m *Manager) statusFromSnapshots(targetID string, config, state fileSnapshot) (Status, error) {
	return statusFromSnapshotsFor(targetID, m.supportedVersions[targetID], config, state)
}

func statusFromSnapshotsFor(targetID, lockedVersion string, config, state fileSnapshot) (Status, error) {
	if !config.Exists && !state.Exists {
		return notConfiguredStatus(targetID), nil
	}
	conflict := Status{
		TargetID:          targetID,
		State:             StateConflict,
		VerificationLevel: VerificationL0,
		ErrorCode:         errorCode(targetID, "CONFLICT"),
		NextActions:       []string{"inspect"},
	}
	if !config.Exists || !state.Exists {
		return conflict, nil
	}
	item, ok := decodeManifest(targetID, config, state)
	if !ok {
		return conflict, nil
	}
	status := Status{
		TargetID:          targetID,
		State:             StateConfigured,
		ProfileVersion:    item.ProfileVersion,
		VerificationLevel: VerificationL1,
		NextActions:       []string{"launch", "restore"},
	}
	if item.SchemaVersion == manifestSchemaV2 && item.VerificationLevel == VerificationL3 &&
		item.VerifiedConfigSHA256 == config.SHA256 && item.VerifiedVersion != "" && item.VerifiedVersion == lockedVersion &&
		validTimestamp(item.VerifiedAt) {
		status.VerificationLevel = VerificationL3
		status.LastVerifiedAt = item.VerifiedAt
	}
	return status, nil
}

// decodeManifest parses the state file and checks it still describes the
// managed file on disk. Any mismatch is reported as a conflict by callers.
func decodeManifest(targetID string, config, state fileSnapshot) (manifest, bool) {
	var item manifest
	decoder := json.NewDecoder(bytes.NewReader(state.Bytes))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&item) != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		(item.SchemaVersion != manifestSchemaV1 && item.SchemaVersion != manifestSchemaV2) ||
		item.TargetID != targetID || item.FileKind != fileKind(targetID) ||
		!validSafeValue(item.ProfileVersion) || !validDigest(item.AppliedSHA256) || item.AppliedSHA256 != config.SHA256 {
		return manifest{}, false
	}
	if item.SchemaVersion == manifestSchemaV2 && item.VerificationLevel != "" {
		if item.VerificationLevel != VerificationL3 || !validDigest(item.VerifiedConfigSHA256) ||
			!validSafeValue(item.VerifiedVersion) || !validTimestamp(item.VerifiedAt) {
			return manifest{}, false
		}
	}
	return item, true
}

// RecordVerification stores a successful L3 verification for the currently
// applied managed configuration. It fails closed when the configuration is
// not in the configured state.
func (m *Manager) RecordVerification(_ context.Context, targetID, installedVersion string) (Status, error) {
	if !validTarget(targetID) || !validSafeValue(installedVersion) {
		return Status{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	configPath := m.configPath(targetID)
	manifestPath := m.manifestPath(targetID)
	config, err := m.snapshot(configPath, false)
	if err != nil {
		return Status{}, err
	}
	state, err := m.snapshot(manifestPath, false)
	if err != nil {
		return Status{}, err
	}
	status, err := m.statusFromSnapshots(targetID, config, state)
	if err != nil {
		return Status{}, err
	}
	if status.State != StateConfigured {
		return Status{}, ErrPreconditionChanged
	}
	item, ok := decodeManifest(targetID, config, state)
	if !ok {
		return Status{}, ErrPreconditionChanged
	}
	item.SchemaVersion = manifestSchemaV2
	item.VerifiedAt = m.now().UTC().Format(time.RFC3339)
	item.VerificationLevel = VerificationL3
	item.VerifiedVersion = installedVersion
	item.VerifiedConfigSHA256 = config.SHA256
	encoded, err := json.Marshal(item)
	if err != nil {
		return Status{}, ErrInvalidInput
	}
	encoded = append(encoded, '\n')
	if err := m.atomicWriteCAS(manifestPath, encoded, 0o600, state); err != nil {
		return Status{}, err
	}
	return m.statusLocked(targetID)
}

func notConfiguredStatus(targetID string) Status {
	return Status{
		TargetID:          targetID,
		State:             StateNotConfigured,
		VerificationLevel: VerificationL0,
		NextActions:       []string{"configure"},
	}
}

func validateManagedContent(targetID string, content []byte) error {
	switch targetID {
	case TargetCodexCLI:
		// The fixed `mcp list` probe below is the parser for the Codex TOML layer.
		return nil
	case TargetClaudeCLI:
		var settings claudeManagedSettings
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&settings) != nil || decoder.Decode(&struct{}{}) != io.EOF ||
			settings.Schema != "https://json.schemastore.org/claude-code-settings.json" ||
			(settings.Model != "" && !validSafeValue(settings.Model)) ||
			(settings.Env.DisableAutoupdater != "" && settings.Env.DisableAutoupdater != "1") ||
			settings.APIKeyHelper == "" || len(settings.APIKeyHelper) > 4096 ||
			strings.ContainsAny(settings.APIKeyHelper, "\r\n\x00") ||
			!strings.HasSuffix(settings.APIKeyHelper, " credential get --target claude_cli") ||
			validateGatewayURL(EnvironmentDev, settings.Env.AnthropicBaseURL) != nil {
			return ErrValidationFailed
		}
		return nil
	default:
		return ErrValidationFailed
	}
}

func (m *Manager) render(targetID string, profile GatewayProfile) ([]byte, error) {
	gatewayBaseURL := profile.BaseURL
	switch targetID {
	case TargetCodexCLI:
		modelLine := ""
		if profile.Model != "" {
			modelLine = "model = " + strconv.Quote(profile.Model) + "\n"
		}
		content := "# Managed by Zhiban AI. Changes are detected and never overwritten silently.\n" +
			"model_provider = \"zhiban_ai_managed\"\n" + modelLine + "\n" +
			"[model_providers.zhiban_ai_managed]\n" +
			"name = \"Zhiban AI\"\n" +
			"base_url = " + strconv.Quote(gatewayBaseURL) + "\n" +
			"wire_api = \"responses\"\n\n" +
			"[model_providers.zhiban_ai_managed.auth]\n" +
			"command = " + strconv.Quote(m.helperExecutable) + "\n" +
			"args = [\"credential\", \"get\", \"--target\", \"codex_cli\"]\n" +
			"timeout_ms = 5000\n" +
			"refresh_interval_ms = 300000\n"
		return []byte(content), nil
	case TargetClaudeCLI:
		quotedHelper, err := shellQuote(m.helperExecutable)
		if err != nil {
			return nil, err
		}
		environment := map[string]string{
			"ANTHROPIC_BASE_URL":  gatewayBaseURL,
			"DISABLE_AUTOUPDATER": "1",
		}
		content := map[string]any{
			"$schema":      "https://json.schemastore.org/claude-code-settings.json",
			"apiKeyHelper": quotedHelper + " credential get --target claude_cli",
			"env":          environment,
		}
		if profile.Model != "" {
			content["model"] = profile.Model
		}
		encoded, err := json.MarshalIndent(content, "", "  ")
		if err != nil {
			return nil, ErrInvalidInput
		}
		return append(encoded, '\n'), nil
	default:
		return nil, ErrInvalidInput
	}
}

func (m *Manager) configPath(targetID string) string {
	if targetID == TargetCodexCLI {
		return filepath.Join(m.codexHome, CodexProfileFileName)
	}
	return filepath.Join(m.homeDir, "Library", "Application Support", applicationSupportID, "local-coding-tools", "claude", "settings.json")
}

func (m *Manager) manifestPath(targetID string) string {
	return filepath.Join(m.homeDir, "Library", "Application Support", applicationSupportID, "local-coding-tools", "state", targetID+".json")
}

func (m *Manager) runProbe(ctx context.Context, installation Installation, managedPath string) error {
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var arguments []string
	switch installation.TargetID {
	case TargetCodexCLI:
		// `--version` exits before loading the selected profile. `mcp list` is a
		// local, non-interactive command that parses the effective configuration
		// without starting MCP servers or making a model request.
		arguments = []string{"--profile", CodexProfileName, "mcp", "list"}
	case TargetClaudeCLI:
		arguments = []string{"--settings", managedPath, "--version"}
	default:
		return ErrInvalidInput
	}
	return m.runQuietProbe(probeCtx, installation.Executable, arguments)
}

func (m *Manager) runQuietProbe(ctx context.Context, executable string, arguments []string) error {
	command := quietProbeCommand(ctx, m.homeDir, m.codexHome, executable, arguments)
	// An npm launcher is `#!/usr/bin/env node`: without node on PATH the
	// post-switch probe fails and a good switch is rolled back as
	// "切换未完成，原有配置已保留" (2026-09-14).
	command.Env = shellenv.PrependPath(command.Env, shellenv.NodeDirs(ctx, executable, m.nodeLookup))
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return ErrValidationFailed
	}
	return nil
}

func (m *Manager) newPlanID() (string, error) {
	for attempt := 0; attempt < 4; attempt++ {
		value := make([]byte, 32)
		if _, err := io.ReadFull(m.random, value); err != nil {
			return "", fmt.Errorf("configuration: generate plan id: %w", err)
		}
		planID := base64.RawURLEncoding.EncodeToString(value)
		if _, exists := m.plans[planID]; !exists {
			return planID, nil
		}
	}
	return "", ErrInvalidInput
}

func cloneProfiles(input map[Environment]map[string]GatewayProfile) map[Environment]map[string]GatewayProfile {
	result := make(map[Environment]map[string]GatewayProfile, len(input))
	for environment, byTarget := range input {
		copyByTarget := make(map[string]GatewayProfile, len(byTarget))
		for target, profile := range byTarget {
			copyByTarget[target] = profile
		}
		result[environment] = copyByTarget
	}
	return result
}

func validateExecutable(path string) error {
	if !filepath.IsAbs(path) {
		return ErrUnsafePath
	}
	info, err := os.Lstat(filepath.Clean(path))
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || notExecutablePerm(info.Mode()) || unsafeFilePerm(info.Mode()) {
		return ErrUnsafePath
	}
	return nil
}

func validateGatewayURL(environment Environment, raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || strings.TrimSpace(raw) != raw {
		return ErrProfileUnavailable
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if environment == EnvironmentDev && parsed.Scheme == "http" && (host == "localhost" || (net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback())) {
		return nil
	}
	return ErrProfileUnavailable
}

// shellQuote quotes the helper executable for the shell the CLI runs
// apiKeyHelper through: /bin/sh on Unix, cmd.exe on Windows (platform_*.go).
// unsafeHelperPath is the shared part: empty paths and control characters are
// never quotable.
func unsafeHelperPath(value string) bool {
	if value == "" || strings.ContainsRune(value, 0) {
		return true
	}
	for _, char := range value {
		if char < 0x20 || char == 0x7f {
			return true
		}
	}
	return false
}

func validTarget(value string) bool {
	return value == TargetCodexCLI || value == TargetClaudeCLI || IsDesktopTarget(value)
}

// IsDesktopTarget reports whether the target is an application bundle (M3).
func IsDesktopTarget(value string) bool {
	return value == TargetCodexDesktop || value == TargetClaudeDesktop
}

// Global-configuration families. Codex Desktop shares ~/.codex/config.toml
// with the Codex CLI (spike S1), so both are one family with one manifest;
// Claude Desktop has its own config library.
const (
	familyCodex         = "codex"
	familyClaudeCLI     = "claude_cli"
	familyClaudeDesktop = "claude_desktop"
)

func globalFamily(targetID string) string {
	switch targetID {
	case TargetCodexCLI, TargetCodexDesktop:
		return familyCodex
	case TargetClaudeDesktop:
		return familyClaudeDesktop
	default:
		return familyClaudeCLI
	}
}

// manifestOwner is the target whose name the shared global manifest carries.
func manifestOwner(targetID string) string {
	if targetID == TargetCodexDesktop {
		return TargetCodexCLI
	}
	return targetID
}

// profileTarget is the gateway profile a target's global switch renders.
func profileTarget(targetID string) string {
	if targetID == TargetCodexDesktop {
		return TargetCodexCLI
	}
	return targetID
}

// desktopProbeInstallation maps a desktop bundle to the executable the global
// switch probes: Codex Desktop bundles the same core as the CLI under
// one of the supported bundle paths; Claude Desktop has nothing to run, so its
// executable is left empty and no probe is made.
func desktopProbeInstallation(installation Installation) (Installation, error) {
	switch installation.TargetID {
	case TargetCodexDesktop:
		core, required := desktopCodexCore(installation.Executable)
		if core == "" {
			if required {
				return Installation{}, ErrInstallationChanged
			}
			installation.Executable = "" // nothing runnable: skip the probe
			return installation, nil
		}
		if err := validateExecutable(core); err != nil {
			if required {
				return Installation{}, ErrInstallationChanged
			}
			installation.Executable = ""
			return installation, nil
		}
		installation.Executable = core
	case TargetClaudeDesktop:
		info, err := os.Lstat(installation.Executable)
		if err != nil || !info.IsDir() {
			return Installation{}, ErrInstallationChanged
		}
		installation.Executable = ""
	}
	return installation, nil
}

func validEnvironment(value Environment) bool {
	return value == EnvironmentDev || value == EnvironmentTest || value == EnvironmentProd
}

func validSafeValue(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || strings.ContainsRune("-_.+", char) {
			continue
		}
		return false
	}
	return true
}

func fileKind(targetID string) string {
	if targetID == TargetCodexCLI {
		return "codex_profile"
	}
	return "claude_settings_overlay"
}

func errorCode(targetID, reason string) string {
	return "LCT-" + strings.ToUpper(targetID) + "-CONFIG-" + reason
}

func digest(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func validTimestamp(value string) bool {
	if value == "" || len(value) > 40 {
		return false
	}
	_, err := time.Parse(time.RFC3339, value)
	return err == nil
}

func validDigest(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && value == strings.ToLower(value)
}

func sameSnapshot(left, right fileSnapshot) bool {
	return left.Exists == right.Exists && left.SHA256 == right.SHA256 && left.Mode == right.Mode
}

func snapshotForContent(content []byte, mode os.FileMode) fileSnapshot {
	return fileSnapshot{
		Exists: true,
		Bytes:  append([]byte(nil), content...),
		Mode:   mode.Perm(),
		SHA256: digest(content),
	}
}

func sameFileInfo(left, right os.FileInfo) bool {
	return left != nil && right != nil &&
		os.SameFile(left, right) &&
		left.Mode() == right.Mode() &&
		left.Size() == right.Size() &&
		left.ModTime() == right.ModTime()
}

func pathInsideOrEqual(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}
