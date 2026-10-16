package launch

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
)

func TestManagerLaunchesOfficialModeInHomeWithoutProject(t *testing.T) {
	t.Parallel()
	home := mustRealPath(t, t.TempDir())
	executable := filepath.Join(home, "bin", "codex")
	mustExecutable(t, executable)
	executable = mustRealPath(t, executable)
	store := newMemoryTicketStore()
	var executed Execution
	bookmarkResolved := false
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			bookmarkResolved = true
			return BookmarkResolution{}, errors.New("must not be called")
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: executable, Version: "0.153.4"}, nil
		},
		ResolveCurrentInstallation: func(_ context.Context, targetID string) ([]Installation, error) {
			return []Installation{{TargetID: targetID, InstallationID: "install", Executable: executable, Version: "0.153.4"}}, nil
		},
		Tickets:      store,
		OpenTerminal: func(context.Context, string) error { return nil },
		Execute: func(_ context.Context, value Execution) error {
			executed = value
			return nil
		},
		Random: bytes.NewReader(bytes.Repeat([]byte{0x33}, 160)),
	})

	// Managed mode still needs a project grant.
	if _, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "install", Mode: ModeManaged, ProfileVersion: "2026.09.07.1",
	}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("managed plan without grant error = %v, want ErrInvalidInput", err)
	}

	plan, err := manager.Plan(context.Background(), PlanRequest{
		TargetID: TargetCodexCLI, InstallationID: "install", Mode: ModeOfficial,
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.ProjectName != "~" || plan.TargetID != TargetCodexCLI {
		t.Fatalf("plan = %+v", plan)
	}
	result, err := manager.Execute(context.Background(), plan.LaunchPlanID)
	if err != nil {
		t.Fatal(err)
	}
	if result.State != "launched" || result.ProjectName != "~" {
		t.Fatalf("result = %+v", result)
	}
	var ticketID string
	for id, ticket := range store.tickets {
		ticketID = id
		if len(ticket.Bookmark) != 0 || ticket.Mode != ModeOfficial {
			t.Fatalf("ticket = %+v", ticket)
		}
	}
	if err := manager.Consume(context.Background(), ticketID, []string{"TERM=xterm"}); err != nil {
		t.Fatal(err)
	}
	if bookmarkResolved {
		t.Fatal("bookmark resolver must not run for a home launch")
	}
	if executed.ProjectPath != home || executed.Executable != executable || len(executed.Arguments) != 0 {
		t.Fatalf("execution = %+v", executed)
	}
}
