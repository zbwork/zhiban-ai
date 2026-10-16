package launch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func writeFakeBundle(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(path, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	return mustRealPath(t, path)
}

func TestDesktopOfficialLaunchOpensTheBundleWithoutATicket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	home := t.TempDir()
	bundle := writeFakeBundle(t, filepath.Join(home, "Applications", "Claude.app"))
	var opened []string
	terminalOpened := false
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{}, errors.New("no bookmark for desktop launches")
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			if installationID != "claude-desktop-install" {
				return Installation{}, ErrInstallationChanged
			}
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: bundle, Version: "1.46388.4"}, nil
		},
		OpenTerminal:    func(context.Context, string) error { terminalOpened = true; return nil },
		OpenApplication: func(_ context.Context, path string) error { opened = append(opened, path); return nil },
		Now:             func() time.Time { return time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC) },
	})

	plan, err := manager.Plan(context.Background(), PlanRequest{TargetID: TargetClaudeDesktop, InstallationID: "claude-desktop-install", Mode: ModeOfficial})
	if err != nil || plan.LaunchPlanID == "" || plan.TargetID != TargetClaudeDesktop || plan.ProjectName != "" {
		t.Fatalf("Plan(desktop official) = %+v, %v", plan, err)
	}
	result, err := manager.Execute(context.Background(), plan.LaunchPlanID)
	if err != nil || result.State != "launched" || result.TargetID != TargetClaudeDesktop {
		t.Fatalf("Execute() = %+v, %v", result, err)
	}
	if len(opened) != 1 || opened[0] != bundle || terminalOpened {
		t.Fatalf("opened=%v terminal=%v", opened, terminalOpened)
	}
	if _, err := manager.Execute(context.Background(), plan.LaunchPlanID); !errors.Is(err, ErrPlanNotFound) {
		t.Fatalf("second Execute error = %v", err)
	}

	// Desktop targets have no managed mode and no project launch.
	if _, err := manager.Plan(context.Background(), PlanRequest{TargetID: TargetClaudeDesktop, InstallationID: "claude-desktop-install", Mode: ModeManaged, ProfileVersion: "2026.09.07.1"}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Plan(desktop managed) error = %v", err)
	}
	if _, err := manager.Plan(context.Background(), PlanRequest{TargetID: TargetClaudeDesktop, InstallationID: "claude-desktop-install", Mode: ModeOfficial, ProjectGrantID: "grant"}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Plan(desktop with project) error = %v", err)
	}

	// The bundle must still be a bundle when the plan runs.
	plan, err = manager.Plan(context.Background(), PlanRequest{TargetID: TargetClaudeDesktop, InstallationID: "claude-desktop-install", Mode: ModeOfficial})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(bundle, "Contents", "MacOS")); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.LaunchPlanID); !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("Execute() on a broken bundle error = %v", err)
	}
}

func TestDesktopLaunchFailsClosedWithoutAnOpener(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	home := t.TempDir()
	bundle := writeFakeBundle(t, filepath.Join(home, "Applications", "Codex.app"))
	manager := mustManager(t, ManagerConfig{
		HomeDir: home,
		ResolveBookmark: func(context.Context, []byte) (BookmarkResolution, error) {
			return BookmarkResolution{}, errors.New("unused")
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: bundle, Version: "26.623.141536"}, nil
		},
		SupportedVersions: map[string]string{TargetCodexCLI: "0.153.4", TargetClaudeCLI: "2.1.263", TargetCodexDesktop: "26.623.141536"},
	})
	plan, err := manager.Plan(context.Background(), PlanRequest{TargetID: TargetCodexDesktop, InstallationID: "codex-desktop-install", Mode: ModeOfficial})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.LaunchPlanID); !errors.Is(err, ErrProcessLaunchFailed) {
		t.Fatalf("Execute() without opener error = %v", err)
	}
	if _, err := NewManager(ManagerConfig{HomeDir: home, SupportedVersions: map[string]string{TargetCodexCLI: "0.153.4", TargetClaudeCLI: "2.1.263", "codex_web": "1"},
		ResolveBookmark:            func(context.Context, []byte) (BookmarkResolution, error) { return BookmarkResolution{}, nil },
		ResolveInstallation:        func(context.Context, string, string) (Installation, error) { return Installation{}, nil },
		ResolveCurrentInstallation: func(context.Context, string) ([]Installation, error) { return nil, nil },
		ResolveConfiguration:       func(context.Context, string, string) (Configuration, error) { return Configuration{}, nil },
	}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("NewManager with an unknown supported target error = %v", err)
	}
}
