package launch

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestManagerCreatesOpaqueGrantAndSingleUseLaunchPlan(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "private-project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	executable := filepath.Join(home, "bin", "codex")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(_ context.Context, value []byte) (BookmarkResolution, error) {
			if string(value) != "bookmark" {
				t.Fatalf("bookmark bytes = %q", value)
			}
			return BookmarkResolution{Path: project}, nil
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "0.153.4"}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--profile", "zhiban-ai-managed"}}, nil
		},
		Now:    func() time.Time { return now },
		Random: bytes.NewReader(bytes.Repeat([]byte{0x42}, 96)),
	})

	grant, err := manager.CreateProjectGrant(context.Background(), base64.StdEncoding.EncodeToString([]byte("bookmark")))
	if err != nil {
		t.Fatal(err)
	}
	if grant.ProjectGrantID == "" || grant.DisplayName != "private-project" || grant.ExpiresAt != now.Add(projectGrantTTL).Format(time.RFC3339) {
		t.Fatalf("grant = %+v", grant)
	}
	encodedGrant, err := json.Marshal(grant)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedGrant), project) || strings.Contains(string(encodedGrant), "bookmark") {
		t.Fatalf("grant leaked private data: %s", encodedGrant)
	}

	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID:       TargetCodexCLI,
		InstallationID: "opaque-installation",
		ProjectGrantID: grant.ProjectGrantID,
		ProfileVersion: "2026.09.07.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.LaunchPlanID == "" || plan.TargetID != TargetCodexCLI || plan.ProjectName != "private-project" || plan.ExpiresAt != now.Add(launchPlanTTL).Format(time.RFC3339) {
		t.Fatalf("plan = %+v", plan)
	}
	encodedPlan, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedPlan), project) || strings.Contains(string(encodedPlan), executable) || strings.Contains(string(encodedPlan), "--profile") {
		t.Fatalf("plan leaked execution details: %s", encodedPlan)
	}

	_, err = manager.Plan(context.Background(), PlanRequest{
		TargetID:       TargetCodexCLI,
		InstallationID: "opaque-installation",
		ProjectGrantID: grant.ProjectGrantID,
		ProfileVersion: "2026.09.07.1",
	})
	if !errors.Is(err, ErrGrantNotFound) {
		t.Fatalf("reused grant error = %v, want ErrGrantNotFound", err)
	}

	pending, err := manager.consumePlan(plan.LaunchPlanID)
	if err != nil {
		t.Fatal(err)
	}
	if pending.ProjectPath != project || pending.Installation.Executable != executable || strings.Join(pending.Configuration.Arguments, " ") != "--profile zhiban-ai-managed" {
		t.Fatalf("pending plan = %+v", pending)
	}
	if _, err := manager.consumePlan(plan.LaunchPlanID); !errors.Is(err, ErrPlanNotFound) {
		t.Fatalf("reused plan error = %v, want ErrPlanNotFound", err)
	}
}

func TestManagerRejectsUnsafeBookmarkAndProjectRoots(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	tests := []struct {
		name     string
		bookmark string
		resolve  BookmarkResolution
		wantErr  error
	}{
		{name: "malformed base64", bookmark: "%%%", wantErr: ErrInvalidInput},
		{name: "oversized", bookmark: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("x"), maxBookmarkBytes+1)), wantErr: ErrInvalidInput},
		{name: "stale", bookmark: encodedBookmark(), resolve: BookmarkResolution{Path: home, Stale: true}, wantErr: ErrProjectPermissionDenied},
		{name: "filesystem root", bookmark: encodedBookmark(), resolve: BookmarkResolution{Path: "/"}, wantErr: ErrProjectPermissionDenied},
		{name: "home root", bookmark: encodedBookmark(), resolve: BookmarkResolution{Path: home}, wantErr: ErrProjectPermissionDenied},
		{name: "protected system tree", bookmark: encodedBookmark(), resolve: BookmarkResolution{Path: "/System/Library"}, wantErr: ErrProjectPermissionDenied},
		{name: "relative", bookmark: encodedBookmark(), resolve: BookmarkResolution{Path: "project"}, wantErr: ErrProjectPermissionDenied},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			manager := mustManager(t, ManagerConfig{
				HomeDir: home,
				ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
					return tt.resolve, nil
				},
			})
			_, err := manager.CreateProjectGrant(context.Background(), tt.bookmark)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestManagerRejectsSymlinkAndDirectoryIdentityChange(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	first := filepath.Join(home, "first")
	second := filepath.Join(home, "second")
	mustMkdir(t, first)
	mustMkdir(t, second)
	first = mustRealPath(t, first)
	second = mustRealPath(t, second)
	link := filepath.Join(home, "link")
	if err := os.Symlink(first, link); err != nil {
		t.Fatal(err)
	}
	resolvedPath := link
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: resolvedPath}, nil
		},
	})
	if _, err := manager.CreateProjectGrant(context.Background(), encodedBookmark()); !errors.Is(err, ErrProjectPermissionDenied) {
		t.Fatalf("symlink grant error = %v", err)
	}

	resolvedPath = first
	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	resolvedPath = second
	_, err = manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "install", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	})
	if !errors.Is(err, ErrProjectChanged) {
		t.Fatalf("identity change error = %v, want ErrProjectChanged", err)
	}
}

func TestManagerExpiresGrantAndStrictlyValidatesPlanRequest(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: project}, nil
		},
		Now:    func() time.Time { return now },
		Random: bytes.NewReader(bytes.Repeat([]byte{0x33}, 96)),
	})
	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(projectGrantTTL + time.Second)
	_, err = manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "install", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	})
	if !errors.Is(err, ErrGrantExpired) {
		t.Fatalf("expired grant error = %v, want ErrGrantExpired", err)
	}

	invalid := []PlanRequest{
		{TargetID: "other", InstallationID: "install", ProjectGrantID: "grant", ProfileVersion: "v1"},
		{TargetID: TargetCodexCLI, InstallationID: "", ProjectGrantID: "grant", ProfileVersion: "v1"},
		{TargetID: TargetCodexCLI, InstallationID: "install", ProjectGrantID: "", ProfileVersion: "v1"},
		{TargetID: TargetCodexCLI, InstallationID: "install", ProjectGrantID: "grant", ProfileVersion: "bad value"},
	}
	for _, request := range invalid {
		if _, err := manager.Plan(context.Background(), request); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("request %+v error = %v", request, err)
		}
	}
}

func TestManagerRejectsInstalledVersionOutsideTheLaunchLock(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	executable := filepath.Join(home, "bin", "claude")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		SupportedVersions: map[string]string{
			TargetCodexCLI:  "0.153.4",
			TargetClaudeCLI: "2.1.263",
		},
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: project}, nil
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "2.1.262"}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--settings", "managed.json"}}, nil
		},
	})
	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	_, err = manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetClaudeCLI, InstallationID: "install", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	})
	if !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("Plan error = %v, want ErrInstallationChanged", err)
	}
}

func TestManagerExecutesPlanThroughOneTimeTicketAndRevalidatesOnConsume(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	executable := filepath.Join(home, "bin", "claude")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	settings := filepath.Join(home, "Library", "Application Support", "cn.qkfintech.zhiban", "settings.json")
	store := newMemoryTicketStore()
	openedScript := ""
	var executed Execution
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: project}, nil
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "2.1.263"}, nil
		},
		ResolveCurrentInstallation: func(_ context.Context, targetID string) ([]Installation, error) {
			// A second trusted install coexists; the ticket fingerprint must pick the right one.
			return []Installation{
				{TargetID: targetID, InstallationID: "other-process-id", Executable: filepath.Join(home, "bin", "other-claude"), Version: "2.1.263"},
				{TargetID: targetID, InstallationID: "new-process-id", Executable: executable, Version: "2.1.263"},
			}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--settings", settings}}, nil
		},
		Tickets: store,
		OpenTerminal: func(_ context.Context, scriptPath string) error {
			openedScript = scriptPath
			return nil
		},
		Execute: func(_ context.Context, value Execution) error {
			executed = value
			return nil
		},
		Random: bytes.NewReader(bytes.Repeat([]byte{0x54}, 160)),
	})
	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetClaudeCLI, InstallationID: "old-process-id", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := manager.Execute(context.Background(), plan.LaunchPlanID)
	if err != nil {
		t.Fatal(err)
	}
	if result.State != "launched" || result.TargetID != TargetClaudeCLI || result.ProjectName != "project" || openedScript == "" {
		t.Fatalf("result=%+v script=%q", result, openedScript)
	}
	if len(store.tickets) != 1 {
		t.Fatalf("tickets = %d, want 1", len(store.tickets))
	}
	var ticketID string
	for id, ticket := range store.tickets {
		ticketID = id
		encoded, marshalErr := json.Marshal(ticket)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		if strings.Contains(string(encoded), project) || strings.Contains(string(encoded), executable) || strings.Contains(string(encoded), settings) {
			t.Fatalf("ticket leaked local paths: %s", encoded)
		}
	}
	environment := []string{
		"TERM=xterm-256color", "LANG=zh_CN.UTF-8", "ANTHROPIC_API_KEY=secret",
		"ANTHROPIC_AUTH_TOKEN=secret", "ANTHROPIC_BASE_URL=https://override.invalid",
		"CLAUDE_CONFIG_DIR=/tmp/override", "CLAUDE_CODE_USE_BEDROCK=1",
		"HOME=/tmp/override", "DYLD_INSERT_LIBRARIES=/tmp/inject.dylib",
	}
	if err := manager.Consume(context.Background(), ticketID, environment); err != nil {
		t.Fatal(err)
	}
	if executed.Executable != executable || executed.ProjectPath != project || strings.Join(executed.Arguments, " ") != "--settings "+settings {
		t.Fatalf("execution = %+v", executed)
	}
	joinedEnv := strings.Join(executed.Environment, "\n")
	for _, forbidden := range []string{
		"ANTHROPIC_API_KEY=", "ANTHROPIC_AUTH_TOKEN=", "ANTHROPIC_BASE_URL=", "CLAUDE_CONFIG_DIR=",
		"CLAUDE_CODE_USE_BEDROCK=", "DYLD_INSERT_LIBRARIES=", "HOME=/tmp/override",
	} {
		if strings.Contains(joinedEnv, forbidden) {
			t.Fatalf("environment retained %q: %v", forbidden, executed.Environment)
		}
	}
	if !strings.Contains(joinedEnv, "HOME="+home) || !strings.Contains(joinedEnv, "TERM=xterm-256color") || !strings.Contains(joinedEnv, "LANG=zh_CN.UTF-8") {
		t.Fatalf("interactive environment was lost: %v", executed.Environment)
	}
	if err := manager.Consume(context.Background(), ticketID, environment); !errors.Is(err, ErrTicketNotFound) {
		t.Fatalf("replayed ticket error = %v, want ErrTicketNotFound", err)
	}
}

func TestSanitizedEnvironmentPinsCodexHomeAndDropsGatewayOverrides(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	result := sanitizedEnvironment(TargetCodexCLI, []string{
		"HOME=/tmp/other", "CODEX_HOME=/tmp/codex", "OPENAI_API_KEY=secret",
		"CODEX_API_KEY=secret", "OPENAI_BASE_URL=https://override.invalid", "TERM=xterm-256color",
	}, home)
	joined := strings.Join(result, "\n")
	for _, forbidden := range []string{"HOME=/tmp/other", "CODEX_HOME=/tmp/codex", "OPENAI_API_KEY=", "CODEX_API_KEY=", "OPENAI_BASE_URL="} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("environment retained %q: %v", forbidden, result)
		}
	}
	if !strings.Contains(joined, "HOME="+home) || !strings.Contains(joined, "CODEX_HOME="+filepath.Join(home, ".codex")) || !strings.Contains(joined, "TERM=xterm-256color") {
		t.Fatalf("pinned environment = %v", result)
	}
}

func TestManagerRemovesTicketWhenTerminalOpenFails(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	executable := filepath.Join(home, "codex")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	store := newMemoryTicketStore()
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: project}, nil
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "0.153.4"}, nil
		},
		ResolveCurrentInstallation: func(context.Context, string) ([]Installation, error) {
			return nil, ErrInstallationChanged
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--profile", "zhiban-ai-managed"}}, nil
		},
		Tickets: store,
		OpenTerminal: func(context.Context, string) error {
			return errors.New("terminal unavailable")
		},
		Random: bytes.NewReader(bytes.Repeat([]byte{0x46}, 160)),
	})
	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "install", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.LaunchPlanID); !errors.Is(err, ErrTerminalLaunchFailed) {
		t.Fatalf("Execute error = %v, want ErrTerminalLaunchFailed", err)
	}
	if len(store.tickets) != 0 {
		t.Fatalf("failed launch retained tickets: %v", store.tickets)
	}
	if _, err := manager.Execute(context.Background(), plan.LaunchPlanID); !errors.Is(err, ErrPlanNotFound) {
		t.Fatalf("replayed plan error = %v, want ErrPlanNotFound", err)
	}
}

func mustManager(t *testing.T, config ManagerConfig) *Manager {
	t.Helper()
	if config.SupportedVersions == nil {
		config.SupportedVersions = map[string]string{
			TargetCodexCLI:  "0.153.4",
			TargetClaudeCLI: "2.1.263",
		}
	}
	if config.ResolveInstallation == nil {
		config.ResolveInstallation = func(context.Context, string, string) (Installation, error) {
			return Installation{}, ErrInstallationChanged
		}
	}
	if config.ResolveConfiguration == nil {
		config.ResolveConfiguration = func(context.Context, string, string) (Configuration, error) {
			return Configuration{}, ErrConfigurationChanged
		}
	}
	if config.ResolveCurrentInstallation == nil {
		config.ResolveCurrentInstallation = func(context.Context, string) ([]Installation, error) {
			return nil, ErrInstallationChanged
		}
	}
	manager, err := NewManager(config)
	if err != nil {
		t.Fatal(err)
	}
	return manager
}

type memoryTicketStore struct {
	tickets map[string]launchTicket
}

func newMemoryTicketStore() *memoryTicketStore {
	return &memoryTicketStore{tickets: make(map[string]launchTicket)}
}

func (s *memoryTicketStore) Create(ticket launchTicket) (string, error) {
	if _, exists := s.tickets[ticket.ID]; exists {
		return "", errors.New("duplicate ticket")
	}
	s.tickets[ticket.ID] = ticket
	return "/protected/" + ticket.ID + ".command", nil
}

func (s *memoryTicketStore) Claim(ticketID string) (launchTicket, error) {
	ticket, exists := s.tickets[ticketID]
	if !exists {
		return launchTicket{}, ErrTicketNotFound
	}
	delete(s.tickets, ticketID)
	return ticket, nil
}

func (s *memoryTicketStore) Remove(ticketID string) error {
	delete(s.tickets, ticketID)
	return nil
}

func encodedBookmark() string {
	return base64.StdEncoding.EncodeToString([]byte("bookmark"))
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustExecutable(t *testing.T, path string) {
	t.Helper()
	mustMkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustRealPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}
