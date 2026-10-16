package launch

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	TargetCodexCLI      = "codex_cli"
	TargetClaudeCLI     = "claude_cli"
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	// ModeManaged launches with the Zhiban managed profile/overlay; ModeOfficial
	// ("open the original tool") launches the CLI as installed, still with a
	// sanitized environment and no Zhiban arguments.
	ModeManaged  = "managed"
	ModeOfficial = "official"

	projectGrantTTL  = 5 * time.Minute
	launchPlanTTL    = 2 * time.Minute
	maxBookmarkBytes = 64 << 10
)

var (
	ErrInvalidInput            = errors.New("launch: invalid input")
	ErrProjectPermissionDenied = errors.New("launch: project permission denied")
	ErrProjectChanged          = errors.New("launch: project changed")
	ErrGrantNotFound           = errors.New("launch: project grant not found")
	ErrGrantExpired            = errors.New("launch: project grant expired")
	ErrPlanNotFound            = errors.New("launch: plan not found")
	ErrPlanExpired             = errors.New("launch: plan expired")
	ErrInstallationChanged     = errors.New("launch: installation changed")
	ErrConfigurationChanged    = errors.New("launch: configuration changed")
	ErrTicketNotFound          = errors.New("launch: ticket not found")
	ErrTicketExpired           = errors.New("launch: ticket expired")
	ErrTicketStoreFailed       = errors.New("launch: ticket store failed")
	ErrTerminalLaunchFailed    = errors.New("launch: terminal launch failed")
	ErrProcessLaunchFailed     = errors.New("launch: process launch failed")

	safeValuePattern = regexp.MustCompile(`^[0-9A-Za-z._+-]{1,128}$`)
)

type BookmarkResolution struct {
	Path  string
	Stale bool
}

type Installation struct {
	TargetID       string
	InstallationID string
	Executable     string
	Version        string
}

type Configuration struct {
	TargetID       string
	ProfileVersion string
	Arguments      []string
}

type ResolveBookmarkFunc func(context.Context, []byte) (BookmarkResolution, error)
type ResolveInstallationFunc func(context.Context, string, string) (Installation, error)
type ResolveConfigurationFunc func(context.Context, string, string) (Configuration, error)

// ResolveCurrentInstallationFunc returns every trusted installation a fresh
// process can see; the ticket consumer picks the one matching the recorded
// fingerprint.
type ResolveCurrentInstallationFunc func(context.Context, string) ([]Installation, error)
type TerminalOpener func(context.Context, string) error
type ExecuteFunc func(context.Context, Execution) error

// ApplicationOpener opens an application bundle the way Finder does ("打开桌面端",
// M3): no terminal, no working directory, no arguments.
type ApplicationOpener func(context.Context, string) error

type TicketStore interface {
	Create(launchTicket) (string, error)
	Claim(string) (launchTicket, error)
	Remove(string) error
}

type ManagerConfig struct {
	HomeDir                    string
	SupportedVersions          map[string]string
	ResolveBookmark            ResolveBookmarkFunc
	ResolveInstallation        ResolveInstallationFunc
	ResolveCurrentInstallation ResolveCurrentInstallationFunc
	ResolveConfiguration       ResolveConfigurationFunc
	Tickets                    TicketStore
	OpenTerminal               TerminalOpener
	Execute                    ExecuteFunc
	OpenApplication            ApplicationOpener
	Now                        func() time.Time
	Random                     io.Reader
}

type ProjectGrant struct {
	ProjectGrantID string `json:"project_grant_id"`
	DisplayName    string `json:"display_name"`
	ExpiresAt      string `json:"expires_at"`
}

type PlanRequest struct {
	TargetID       string
	InstallationID string
	ProjectGrantID string
	ProfileVersion string
	Mode           string
}

type Plan struct {
	LaunchPlanID string `json:"launch_plan_id"`
	TargetID     string `json:"target_id"`
	ProjectName  string `json:"project_name"`
	ExpiresAt    string `json:"expires_at"`
}

type ExecuteResult struct {
	State       string `json:"state"`
	TargetID    string `json:"target_id"`
	ProjectName string `json:"project_name"`
}

type Execution struct {
	Executable  string
	Arguments   []string
	ProjectPath string
	Environment []string
	Identity    projectIdentity
}

type projectIdentity struct {
	Device uint64
	Inode  uint64
}

type pendingGrant struct {
	Bookmark    []byte
	ProjectPath string
	DisplayName string
	Identity    projectIdentity
	ExpiresAt   time.Time
}

type pendingPlan struct {
	Public        Plan
	Mode          string
	Bookmark      []byte
	ProjectPath   string
	Identity      projectIdentity
	Installation  Installation
	Configuration Configuration
	ExpiresAt     time.Time
	// Desktop marks an application-bundle plan: executed by opening the
	// bundle, never through a terminal ticket.
	Desktop bool
}

type launchTicket struct {
	SchemaVersion           int             `json:"schema_version"`
	ID                      string          `json:"id"`
	Bookmark                []byte          `json:"bookmark"`
	ProjectIdentity         projectIdentity `json:"project_identity"`
	TargetID                string          `json:"target_id"`
	InstallationFingerprint string          `json:"installation_fingerprint"`
	InstallationVersion     string          `json:"installation_version"`
	ProfileVersion          string          `json:"profile_version"`
	Mode                    string          `json:"mode,omitempty"`
	CreatedAt               time.Time       `json:"created_at"`
	ExpiresAt               time.Time       `json:"expires_at"`
}

type Manager struct {
	homeDir                    string
	supportedVersions          map[string]string
	resolveBookmark            ResolveBookmarkFunc
	resolveInstallation        ResolveInstallationFunc
	resolveCurrentInstallation ResolveCurrentInstallationFunc
	resolveConfiguration       ResolveConfigurationFunc
	tickets                    TicketStore
	openTerminal               TerminalOpener
	execute                    ExecuteFunc
	openApplication            ApplicationOpener
	now                        func() time.Time
	random                     io.Reader

	mu     sync.Mutex
	grants map[string]pendingGrant
	plans  map[string]pendingPlan
}

func NewManager(config ManagerConfig) (*Manager, error) {
	home := filepath.Clean(strings.TrimSpace(config.HomeDir))
	if !filepath.IsAbs(home) || home == string(filepath.Separator) || config.ResolveBookmark == nil ||
		config.ResolveInstallation == nil || config.ResolveCurrentInstallation == nil || config.ResolveConfiguration == nil ||
		len(config.SupportedVersions) < 2 || !safeValuePattern.MatchString(config.SupportedVersions[TargetCodexCLI]) ||
		!safeValuePattern.MatchString(config.SupportedVersions[TargetClaudeCLI]) {
		return nil, ErrInvalidInput
	}
	supportedVersions := make(map[string]string, len(config.SupportedVersions))
	for targetID, version := range config.SupportedVersions {
		if !validTarget(targetID) || !safeValuePattern.MatchString(version) {
			return nil, ErrInvalidInput
		}
		supportedVersions[targetID] = version
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	randomReader := config.Random
	if randomReader == nil {
		randomReader = rand.Reader
	}
	return &Manager{
		homeDir: home, supportedVersions: supportedVersions, resolveBookmark: config.ResolveBookmark,
		resolveInstallation: config.ResolveInstallation, resolveCurrentInstallation: config.ResolveCurrentInstallation,
		resolveConfiguration: config.ResolveConfiguration, tickets: config.Tickets,
		openTerminal: config.OpenTerminal, execute: config.Execute, openApplication: config.OpenApplication,
		now: now, random: randomReader, grants: make(map[string]pendingGrant), plans: make(map[string]pendingPlan),
	}, nil
}

func (m *Manager) Execute(ctx context.Context, planID string) (ExecuteResult, error) {
	plan, err := m.consumePlan(planID)
	if err != nil {
		return ExecuteResult{}, err
	}
	if plan.Desktop {
		return m.executeDesktop(ctx, plan)
	}
	if m.tickets == nil || m.openTerminal == nil {
		return ExecuteResult{}, ErrTicketStoreFailed
	}
	var identity projectIdentity
	if len(plan.Bookmark) == 0 {
		_, homeIdentity, err := m.inspectHome()
		if err != nil || homeIdentity != plan.Identity {
			return ExecuteResult{}, ErrProjectChanged
		}
		identity = homeIdentity
	} else {
		resolution, err := m.resolveBookmark(ctx, plan.Bookmark)
		if err != nil || resolution.Stale {
			return ExecuteResult{}, ErrProjectChanged
		}
		projectPath, resolvedIdentity, err := m.inspectProject(resolution.Path)
		if err != nil || !samePath(projectPath, plan.ProjectPath) || resolvedIdentity != plan.Identity {
			return ExecuteResult{}, ErrProjectChanged
		}
		identity = resolvedIdentity
	}
	installation, err := m.resolveInstallation(ctx, plan.Public.TargetID, plan.Installation.InstallationID)
	if err != nil || validateInstallation(installation, plan.Public.TargetID, plan.Installation.InstallationID) != nil ||
		(plan.Mode == ModeManaged && !m.supportsInstallation(installation)) ||
		installationFingerprint(installation) != installationFingerprint(plan.Installation) {
		return ExecuteResult{}, ErrInstallationChanged
	}
	var configuration Configuration
	if plan.Mode == ModeManaged {
		configuration, err = m.resolveConfiguration(ctx, plan.Public.TargetID, plan.Configuration.ProfileVersion)
		if err != nil || validateConfiguration(configuration, plan.Public.TargetID, plan.Configuration.ProfileVersion) != nil ||
			!sameArguments(configuration.Arguments, plan.Configuration.Arguments) {
			return ExecuteResult{}, ErrConfigurationChanged
		}
	}

	ticketID, err := m.newRandomID()
	if err != nil {
		return ExecuteResult{}, err
	}
	now := m.now().UTC()
	ticket := launchTicket{
		SchemaVersion: 1, ID: ticketID, Bookmark: append([]byte(nil), plan.Bookmark...),
		ProjectIdentity: identity, TargetID: plan.Public.TargetID,
		InstallationFingerprint: installationFingerprint(installation), InstallationVersion: installation.Version,
		ProfileVersion: configuration.ProfileVersion, Mode: plan.Mode, CreatedAt: now, ExpiresAt: now.Add(launchPlanTTL),
	}
	scriptPath, err := m.tickets.Create(ticket)
	if err != nil {
		return ExecuteResult{}, ErrTicketStoreFailed
	}
	if err := m.openTerminal(ctx, scriptPath); err != nil {
		_ = m.tickets.Remove(ticketID)
		return ExecuteResult{}, ErrTerminalLaunchFailed
	}
	return ExecuteResult{State: "launched", TargetID: plan.Public.TargetID, ProjectName: plan.Public.ProjectName}, nil
}

func (m *Manager) Consume(ctx context.Context, ticketID string, environment []string) error {
	if !validOpaqueID(ticketID) || m.tickets == nil || m.execute == nil {
		return ErrInvalidInput
	}
	ticket, err := m.tickets.Claim(ticketID)
	if err != nil {
		if errors.Is(err, ErrTicketNotFound) {
			return ErrTicketNotFound
		}
		return ErrTicketStoreFailed
	}
	mode := normalizeMode(ticket.Mode)
	if ticket.SchemaVersion != 1 || ticket.ID != ticketID || !validTarget(ticket.TargetID) || !validMode(mode) ||
		!safeValuePattern.MatchString(ticket.InstallationVersion) ||
		(mode == ModeManaged && !safeValuePattern.MatchString(ticket.ProfileVersion)) ||
		(mode == ModeOfficial && ticket.ProfileVersion != "") ||
		ticket.CreatedAt.After(ticket.ExpiresAt) || m.now().Before(ticket.CreatedAt.Add(-time.Minute)) || m.now().After(ticket.ExpiresAt) {
		return ErrTicketExpired
	}
	var projectPath string
	var identity projectIdentity
	if len(ticket.Bookmark) == 0 {
		if mode != ModeOfficial {
			return ErrTicketExpired
		}
		path, homeIdentity, err := m.inspectHome()
		if err != nil || homeIdentity != ticket.ProjectIdentity {
			return ErrProjectChanged
		}
		projectPath, identity = path, homeIdentity
	} else {
		resolution, err := m.resolveBookmark(ctx, ticket.Bookmark)
		if err != nil || resolution.Stale {
			return ErrProjectChanged
		}
		path, resolvedIdentity, err := m.inspectProject(resolution.Path)
		if err != nil || resolvedIdentity != ticket.ProjectIdentity {
			return ErrProjectChanged
		}
		projectPath, identity = path, resolvedIdentity
	}
	installations, err := m.resolveCurrentInstallation(ctx, ticket.TargetID)
	if err != nil {
		return ErrInstallationChanged
	}
	var installation Installation
	matched := false
	for _, candidate := range installations {
		if subtle.ConstantTimeCompare([]byte(installationFingerprint(candidate)), []byte(ticket.InstallationFingerprint)) == 1 {
			if matched {
				return ErrInstallationChanged
			}
			installation = candidate
			matched = true
		}
	}
	if !matched || validateCurrentInstallation(installation, ticket.TargetID) != nil ||
		(mode == ModeManaged && !m.supportsInstallation(installation)) ||
		installation.Version != ticket.InstallationVersion {
		return ErrInstallationChanged
	}
	var configuration Configuration
	if mode == ModeManaged {
		configuration, err = m.resolveConfiguration(ctx, ticket.TargetID, ticket.ProfileVersion)
		if err != nil || validateConfiguration(configuration, ticket.TargetID, ticket.ProfileVersion) != nil {
			return ErrConfigurationChanged
		}
	}
	execution := Execution{
		Executable: installation.Executable, Arguments: append([]string(nil), configuration.Arguments...),
		ProjectPath: projectPath, Environment: sanitizedEnvironment(ticket.TargetID, environment, m.homeDir), Identity: identity,
	}
	if err := m.execute(ctx, execution); err != nil {
		return ErrProcessLaunchFailed
	}
	return nil
}

func (m *Manager) CreateProjectGrant(ctx context.Context, encodedBookmark string) (ProjectGrant, error) {
	if encodedBookmark == "" || len(encodedBookmark) > base64.StdEncoding.EncodedLen(maxBookmarkBytes)+4 {
		return ProjectGrant{}, ErrInvalidInput
	}
	bookmark, err := base64.StdEncoding.Strict().DecodeString(encodedBookmark)
	if err != nil || len(bookmark) == 0 || len(bookmark) > maxBookmarkBytes {
		return ProjectGrant{}, ErrInvalidInput
	}
	resolution, err := m.resolveBookmark(ctx, bookmark)
	if err != nil || resolution.Stale {
		return ProjectGrant{}, ErrProjectPermissionDenied
	}
	path, identity, err := m.inspectProject(resolution.Path)
	if err != nil {
		return ProjectGrant{}, err
	}
	displayName := sanitizeDisplayName(filepath.Base(path))
	if displayName == "" {
		return ProjectGrant{}, ErrProjectPermissionDenied
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked()
	grantID, err := m.newIDLocked(m.grants)
	if err != nil {
		return ProjectGrant{}, err
	}
	expiresAt := m.now().UTC().Add(projectGrantTTL)
	m.grants[grantID] = pendingGrant{
		Bookmark: append([]byte(nil), bookmark...), ProjectPath: path, DisplayName: displayName,
		Identity: identity, ExpiresAt: expiresAt,
	}
	return ProjectGrant{ProjectGrantID: grantID, DisplayName: displayName, ExpiresAt: expiresAt.Format(time.RFC3339)}, nil
}

func (m *Manager) Plan(ctx context.Context, request PlanRequest) (Plan, error) {
	mode := normalizeMode(request.Mode)
	homeLaunch := mode == ModeOfficial && request.ProjectGrantID == ""
	if !validTarget(request.TargetID) || !validOpaqueID(request.InstallationID) ||
		(!homeLaunch && !validOpaqueID(request.ProjectGrantID)) || !validMode(mode) ||
		(mode == ModeManaged && !safeValuePattern.MatchString(request.ProfileVersion)) ||
		(mode == ModeOfficial && request.ProfileVersion != "") {
		return Plan{}, ErrInvalidInput
	}
	if IsDesktopTarget(request.TargetID) {
		return m.planDesktop(ctx, request, mode, homeLaunch)
	}

	var grant pendingGrant
	var projectPath string
	var identity projectIdentity
	if homeLaunch {
		// "打开应用" without a project: the CLI starts in the user's home
		// directory exactly as it would from their own terminal.
		path, homeIdentity, err := m.inspectHome()
		if err != nil {
			return Plan{}, err
		}
		grant = pendingGrant{ProjectPath: path, DisplayName: "~", Identity: homeIdentity}
		projectPath, identity = path, homeIdentity
	} else {
		m.mu.Lock()
		stored, ok := m.grants[request.ProjectGrantID]
		if ok {
			delete(m.grants, request.ProjectGrantID)
		}
		m.mu.Unlock()
		if !ok {
			return Plan{}, ErrGrantNotFound
		}
		if m.now().After(stored.ExpiresAt) {
			return Plan{}, ErrGrantExpired
		}
		resolution, err := m.resolveBookmark(ctx, stored.Bookmark)
		if err != nil || resolution.Stale {
			return Plan{}, ErrProjectChanged
		}
		path, resolvedIdentity, err := m.inspectProject(resolution.Path)
		if err != nil || !samePath(path, stored.ProjectPath) || resolvedIdentity != stored.Identity {
			return Plan{}, ErrProjectChanged
		}
		grant, projectPath, identity = stored, path, resolvedIdentity
	}

	installation, err := m.resolveInstallation(ctx, request.TargetID, request.InstallationID)
	if err != nil || validateInstallation(installation, request.TargetID, request.InstallationID) != nil ||
		(mode == ModeManaged && !m.supportsInstallation(installation)) {
		return Plan{}, ErrInstallationChanged
	}
	var configuration Configuration
	if mode == ModeManaged {
		configuration, err = m.resolveConfiguration(ctx, request.TargetID, request.ProfileVersion)
		if err != nil || validateConfiguration(configuration, request.TargetID, request.ProfileVersion) != nil {
			return Plan{}, ErrConfigurationChanged
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked()
	planID, err := m.newIDLocked(m.plans)
	if err != nil {
		return Plan{}, err
	}
	expiresAt := m.now().UTC().Add(launchPlanTTL)
	public := Plan{
		LaunchPlanID: planID, TargetID: request.TargetID, ProjectName: grant.DisplayName,
		ExpiresAt: expiresAt.Format(time.RFC3339),
	}
	m.plans[planID] = pendingPlan{
		Public: public, Mode: mode, Bookmark: append([]byte(nil), grant.Bookmark...), ProjectPath: projectPath,
		Identity: identity, Installation: installation, Configuration: configuration, ExpiresAt: expiresAt,
	}
	return public, nil
}

func (m *Manager) supportsInstallation(installation Installation) bool {
	expected, ok := m.supportedVersions[installation.TargetID]
	return ok && installation.Version == expected
}

func (m *Manager) consumePlan(planID string) (pendingPlan, error) {
	if !validOpaqueID(planID) {
		return pendingPlan{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	plan, ok := m.plans[planID]
	if ok {
		delete(m.plans, planID)
	}
	if !ok {
		return pendingPlan{}, ErrPlanNotFound
	}
	if m.now().After(plan.ExpiresAt) {
		return pendingPlan{}, ErrPlanExpired
	}
	return plan, nil
}

// inspectHome is the "no project" launch root: the user's home directory.
func (m *Manager) inspectHome() (string, projectIdentity, error) {
	directory, err := os.Open(m.homeDir)
	if err != nil {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	defer directory.Close()
	info, err := directory.Stat()
	if err != nil || !info.IsDir() {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	identity, ok := fileIdentity(directory, info)
	if !ok {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	return m.homeDir, identity, nil
}

func (m *Manager) inspectProject(rawPath string) (string, projectIdentity, error) {
	path := filepath.Clean(strings.TrimSpace(rawPath))
	if !filepath.IsAbs(path) || isProtectedProjectPath(path) || samePath(path, m.homeDir) {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || !samePath(resolved, path) {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	directory, err := os.Open(path)
	if err != nil {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	defer directory.Close()
	opened, err := directory.Stat()
	if err != nil || !opened.IsDir() || !os.SameFile(info, opened) {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	identity, ok := fileIdentity(directory, opened)
	if !ok {
		return "", projectIdentity{}, ErrProjectPermissionDenied
	}
	return path, identity, nil
}

func validateInstallation(value Installation, targetID, installationID string) error {
	if value.TargetID != targetID || subtle.ConstantTimeCompare([]byte(value.InstallationID), []byte(installationID)) != 1 ||
		!safeValuePattern.MatchString(value.Version) || !filepath.IsAbs(value.Executable) {
		return ErrInstallationChanged
	}
	return validateExecutablePath(value.Executable)
}

func validateExecutablePath(executable string) error {
	path := filepath.Clean(executable)
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || execBitMissing(info.Mode()) {
		return ErrInstallationChanged
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || !samePath(resolved, path) {
		return ErrInstallationChanged
	}
	return nil
}

func validateCurrentInstallation(value Installation, targetID string) error {
	if value.TargetID != targetID || !validOpaqueID(value.InstallationID) {
		return ErrInstallationChanged
	}
	return validateInstallation(value, targetID, value.InstallationID)
}

func validateConfiguration(value Configuration, targetID, profileVersion string) error {
	if value.TargetID != targetID || value.ProfileVersion != profileVersion {
		return ErrConfigurationChanged
	}
	switch targetID {
	case TargetCodexCLI:
		if len(value.Arguments) != 2 || value.Arguments[0] != "--profile" || value.Arguments[1] != "zhiban-ai-managed" {
			return ErrConfigurationChanged
		}
	case TargetClaudeCLI:
		if len(value.Arguments) != 2 || value.Arguments[0] != "--settings" || !filepath.IsAbs(value.Arguments[1]) {
			return ErrConfigurationChanged
		}
	default:
		return ErrConfigurationChanged
	}
	return nil
}

func isProtectedProjectPath(path string) bool {
	for _, root := range []string{
		"/", "/Applications", "/Library", "/System", "/bin", "/sbin", "/usr",
		"/private/etc", "/private/var/db", "/private/var/root", "/private/var/run", "/private/var/vm",
	} {
		if samePath(path, root) || (root != "/" && strings.HasPrefix(path, root+string(filepath.Separator))) {
			return true
		}
	}
	return samePath(path, "/private") || samePath(path, "/private/var")
}

func samePath(left, right string) bool {
	return filepath.Clean(left) == filepath.Clean(right)
}

func sameArguments(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func installationFingerprint(value Installation) string {
	digest := sha256.Sum256([]byte(value.TargetID + "\x00" + filepath.Clean(value.Executable) + "\x00" + value.Version))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

func sanitizedEnvironment(targetID string, environment []string, homeDir string) []string {
	blocked := map[string]struct{}{
		"HOME": {}, "CODEX_HOME": {}, "CLAUDE_CONFIG_DIR": {},
		"OPENAI_API_KEY": {}, "CODEX_API_KEY": {}, "OPENAI_BASE_URL": {},
		"ANTHROPIC_API_KEY": {}, "ANTHROPIC_AUTH_TOKEN": {}, "ANTHROPIC_BASE_URL": {}, "CLAUDE_CODE_OAUTH_TOKEN": {},
		"CLAUDE_CODE_USE_BEDROCK": {}, "CLAUDE_CODE_USE_VERTEX": {}, "CLAUDE_CODE_USE_FOUNDRY": {},
	}
	result := make([]string, 0, len(environment)+2)
	for _, item := range environment {
		name, _, ok := strings.Cut(item, "=")
		if !ok || name == "" || strings.HasPrefix(name, "DYLD_") || strings.HasPrefix(name, "LD_") {
			continue
		}
		if _, denied := blocked[name]; denied {
			continue
		}
		result = append(result, item)
	}
	result = append(result, "HOME="+homeDir)
	if targetID == TargetCodexCLI {
		result = append(result, "CODEX_HOME="+filepath.Join(homeDir, ".codex"))
	}
	return result
}

func sanitizeDisplayName(value string) string {
	var builder strings.Builder
	for _, character := range []rune(strings.TrimSpace(value)) {
		if builder.Len() >= 240 {
			break
		}
		if unicode.IsControl(character) || character == '/' || character == '\\' {
			builder.WriteRune('_')
			continue
		}
		builder.WriteRune(character)
	}
	return strings.TrimSpace(builder.String())
}

func validTarget(targetID string) bool {
	return targetID == TargetCodexCLI || targetID == TargetClaudeCLI || IsDesktopTarget(targetID)
}

// IsDesktopTarget reports whether the target is an application bundle (M3).
func IsDesktopTarget(targetID string) bool {
	return targetID == TargetCodexDesktop || targetID == TargetClaudeDesktop
}

// planDesktop prepares "打开桌面端": only the official mode without a project
// applies, and the installation must still be the bundle the App saw.
func (m *Manager) planDesktop(ctx context.Context, request PlanRequest, mode string, homeLaunch bool) (Plan, error) {
	if mode != ModeOfficial || !homeLaunch {
		return Plan{}, ErrInvalidInput
	}
	installation, err := m.resolveInstallation(ctx, request.TargetID, request.InstallationID)
	if err != nil || validateBundleInstallation(installation, request.TargetID, request.InstallationID) != nil {
		return Plan{}, ErrInstallationChanged
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked()
	planID, err := m.newIDLocked(m.plans)
	if err != nil {
		return Plan{}, err
	}
	expiresAt := m.now().UTC().Add(launchPlanTTL)
	public := Plan{LaunchPlanID: planID, TargetID: request.TargetID, ProjectName: "", ExpiresAt: expiresAt.Format(time.RFC3339)}
	m.plans[planID] = pendingPlan{Public: public, Mode: mode, Installation: installation, ExpiresAt: expiresAt, Desktop: true}
	return public, nil
}

// executeDesktop opens the bundle after re-resolving it; there is no ticket,
// no terminal and no working directory involved.
func (m *Manager) executeDesktop(ctx context.Context, plan pendingPlan) (ExecuteResult, error) {
	if m.openApplication == nil {
		return ExecuteResult{}, ErrProcessLaunchFailed
	}
	installation, err := m.resolveInstallation(ctx, plan.Public.TargetID, plan.Installation.InstallationID)
	if err != nil || validateBundleInstallation(installation, plan.Public.TargetID, plan.Installation.InstallationID) != nil ||
		installationFingerprint(installation) != installationFingerprint(plan.Installation) {
		return ExecuteResult{}, ErrInstallationChanged
	}
	if err := m.openApplication(ctx, installation.Executable); err != nil {
		return ExecuteResult{}, ErrProcessLaunchFailed
	}
	return ExecuteResult{State: "launched", TargetID: plan.Public.TargetID, ProjectName: plan.Public.ProjectName}, nil
}

// validateBundleInstallation accepts the installation directory of a desktop
// target: an application bundle on macOS, a registered package folder on
// Windows (bundle_unix.go / bundle_windows.go do the platform part).
func validateBundleInstallation(value Installation, targetID, installationID string) error {
	if value.TargetID != targetID || subtle.ConstantTimeCompare([]byte(value.InstallationID), []byte(installationID)) != 1 ||
		!safeValuePattern.MatchString(value.Version) || !filepath.IsAbs(value.Executable) {
		return ErrInstallationChanged
	}
	return validateDesktopDirectory(filepath.Clean(value.Executable))
}

func normalizeMode(mode string) string {
	if mode == "" {
		return ModeManaged
	}
	return mode
}

func validMode(mode string) bool {
	return mode == ModeManaged || mode == ModeOfficial
}

func validOpaqueID(value string) bool {
	return value != "" && len(value) <= 128 && safeValuePattern.MatchString(value)
}

func (m *Manager) pruneLocked() {
	now := m.now()
	for id, grant := range m.grants {
		if now.After(grant.ExpiresAt) {
			delete(m.grants, id)
		}
	}
	for id, plan := range m.plans {
		if now.After(plan.ExpiresAt) {
			delete(m.plans, id)
		}
	}
}

func (m *Manager) newIDLocked(existing any) (string, error) {
	contains := func(id string) bool {
		switch values := existing.(type) {
		case map[string]pendingGrant:
			_, ok := values[id]
			return ok
		case map[string]pendingPlan:
			_, ok := values[id]
			return ok
		default:
			return true
		}
	}
	for attempt := 0; attempt < 4; attempt++ {
		value := make([]byte, 32)
		if _, err := io.ReadFull(m.random, value); err != nil {
			return "", fmt.Errorf("launch: generate opaque id: %w", err)
		}
		id := base64.RawURLEncoding.EncodeToString(value)
		if !contains(id) {
			return id, nil
		}
	}
	return "", ErrInvalidInput
}

func (m *Manager) newRandomID() (string, error) {
	value := make([]byte, 32)
	if _, err := io.ReadFull(m.random, value); err != nil {
		return "", fmt.Errorf("launch: generate ticket id: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}
