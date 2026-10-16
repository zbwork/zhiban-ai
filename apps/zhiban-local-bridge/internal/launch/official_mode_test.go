package launch

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestOfficialModeLaunchesInstalledToolWithoutManagedArguments(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	project := filepath.Join(home, "project")
	mustMkdir(t, project)
	project = mustRealPath(t, project)
	executable := filepath.Join(home, "bin", "codex")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	store := newMemoryTicketStore()
	configurationCalls := 0
	var executed Execution
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{Path: project}, nil
		},
		// The user's own install is older than the launch lock: official mode
		// must still open it, managed mode must still refuse it.
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "0.144.1"}, nil
		},
		ResolveCurrentInstallation: func(_ context.Context, targetID string) ([]Installation, error) {
			return []Installation{{TargetID: targetID, InstallationID: "fresh-id", Executable: executable, Version: "0.144.1"}}, nil
		},
		ResolveConfiguration: func(_ context.Context, targetID, profileVersion string) (Configuration, error) {
			configurationCalls++
			return Configuration{TargetID: targetID, ProfileVersion: profileVersion, Arguments: []string{"--profile", "zhiban-ai-managed"}}, nil
		},
		Tickets:      store,
		OpenTerminal: func(context.Context, string) error { return nil },
		Execute: func(_ context.Context, value Execution) error {
			executed = value
			return nil
		},
		Random: bytes.NewReader(bytes.Repeat([]byte{0x31}, 320)),
	})

	grant, err := manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "user-install", ProjectGrantID: grant.ProjectGrantID, ProfileVersion: "2026.09.07.1",
	}); !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("managed Plan() with unsupported version error = %v, want ErrInstallationChanged", err)
	}

	grant, err = manager.CreateProjectGrant(context.Background(), encodedBookmark())
	if err != nil {
		t.Fatal(err)
	}
	for _, request := range []PlanRequest{
		{TargetID: TargetCodexCLI, InstallationID: "user-install", ProjectGrantID: grant.ProjectGrantID, Mode: "official", ProfileVersion: "2026.09.07.1"},
		{TargetID: TargetCodexCLI, InstallationID: "user-install", ProjectGrantID: grant.ProjectGrantID, Mode: "debug"},
	} {
		if _, err := manager.Plan(context.Background(), request); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("Plan(%+v) error = %v, want ErrInvalidInput", request, err)
		}
	}
	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "user-install", ProjectGrantID: grant.ProjectGrantID, Mode: ModeOfficial,
	})
	if err != nil {
		t.Fatalf("official Plan() error = %v", err)
	}
	result, err := manager.Execute(context.Background(), plan.LaunchPlanID)
	if err != nil || result.State != "launched" {
		t.Fatalf("official Execute() = %+v, %v", result, err)
	}
	if configurationCalls != 0 {
		t.Fatalf("official mode resolved the managed configuration %d times", configurationCalls)
	}
	var ticketID string
	for id, ticket := range store.tickets {
		ticketID = id
		if ticket.Mode != ModeOfficial || ticket.ProfileVersion != "" {
			t.Fatalf("ticket = %+v", ticket)
		}
	}
	environment := []string{"TERM=xterm", "OPENAI_API_KEY=secret", "CODEX_HOME=/tmp/override", "DYLD_INSERT_LIBRARIES=/tmp/x"}
	if err := manager.Consume(context.Background(), ticketID, environment); err != nil {
		t.Fatalf("official Consume() error = %v", err)
	}
	if executed.Executable != executable || len(executed.Arguments) != 0 || executed.ProjectPath != project {
		t.Fatalf("official execution = %+v", executed)
	}
	joined := strings.Join(executed.Environment, "\n")
	if strings.Contains(joined, "OPENAI_API_KEY=") || strings.Contains(joined, "DYLD_") || strings.Contains(joined, "CODEX_HOME=/tmp/override") ||
		!strings.Contains(joined, "CODEX_HOME="+filepath.Join(home, ".codex")) || !strings.Contains(joined, "TERM=xterm") {
		t.Fatalf("official environment = %v", executed.Environment)
	}
	if configurationCalls != 0 {
		t.Fatalf("official consume resolved the managed configuration %d times", configurationCalls)
	}
}
