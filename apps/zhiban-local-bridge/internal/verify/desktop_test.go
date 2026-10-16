package verify

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// Desktop targets are verified up to L2: the switch is in place and the
// credential exchange works. No process is run and L3 is never claimed.
func TestVerifyDesktopTargetsStopAtL2(t *testing.T) {
	var globalRecorded []string
	for _, targetID := range []string{TargetCodexDesktop, TargetClaudeDesktop} {
		bundleVersion := map[string]string{TargetCodexDesktop: "26.623.141536", TargetClaudeDesktop: "1.46388.4"}[targetID]
		f := newFixture(t, successScript, func(config *ManagerConfig) {
			bundle := filepath.Join(config.HomeDir, "Applications", "Desktop.app")
			if err := os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755); err != nil {
				t.Fatal(err)
			}
			config.ResolveInstallation = func(_ context.Context, target, installationID string) (Installation, error) {
				return Installation{TargetID: target, InstallationID: installationID, Executable: bundle, Version: bundleVersion}, nil
			}
			config.RecordGlobal = func(_ context.Context, target, version string) (configuration.GlobalStatus, error) {
				globalRecorded = append(globalRecorded, target+"@"+version)
				return configuration.GlobalStatus{TargetID: target, CurrentService: configuration.ServiceZhiban, VerificationLevel: configuration.VerificationL2, LastVerifiedAt: "2026-09-09T12:00:00Z"}, nil
			}
		})
		f.status = configuration.Status{TargetID: targetID, State: configuration.StateNotConfigured, CurrentService: configuration.ServiceZhiban, GlobalSwitched: true}

		envelope, err := f.manager.Execute(context.Background(), targetID, "install-1", ScopeGlobal)
		if err != nil {
			t.Fatalf("Execute(%s) error = %v", targetID, err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		final, err := f.registry.Wait(ctx, envelope.OperationID)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if final.State != operation.StateSucceeded {
			t.Fatalf("%s final = %+v", targetID, final)
		}
		result, ok := final.Result.(Result)
		if !ok || result.VerificationLevel != configuration.VerificationL2 || result.VerifiedAt != "2026-09-09T12:00:00Z" {
			t.Fatalf("%s result = %#v", targetID, final.Result)
		}
		if f.invocation != nil {
			t.Fatalf("%s must not run a process: %+v", targetID, f.invocation)
		}
		if len(f.recorded) != 0 {
			t.Fatalf("%s overlay verification recorded: %v", targetID, f.recorded)
		}

		// Overlay scope and a drifted switch are refused before any exchange.
		for name, mutate := range map[string]func(){
			"overlay scope": func() {},
			"drifted":       func() { f.status.GlobalDrifted = true },
		} {
			mutate()
			scope := ScopeGlobal
			if name == "overlay scope" {
				scope = ScopeOverlay
			}
			envelope, err := f.manager.Execute(context.Background(), targetID, "install-1", scope)
			if err != nil {
				t.Fatalf("%s/%s Execute error = %v", targetID, name, err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			final, err := f.registry.Wait(ctx, envelope.OperationID)
			cancel()
			if err != nil {
				t.Fatal(err)
			}
			if final.State != operation.StateFailed || final.ErrorCode == nil || !strings.HasSuffix(*final.ErrorCode, "-VERIFY-NOT_CONFIGURED") {
				t.Fatalf("%s/%s final = %+v", targetID, name, final)
			}
			f.status.GlobalDrifted = false
		}
	}
	if strings.Join(globalRecorded, ",") != "codex_desktop@26.623.141536,claude_desktop@1.46388.4" {
		t.Fatalf("global recorded = %v", globalRecorded)
	}
}

// M3 Task 8 · A desktop target whose provisioned runtime component is missing
// fails L1 with VERIFY-COMPONENT_MISSING before anything is recorded; a
// target with all components present proceeds to L2.
func TestVerifyDesktopRequiresProvisionedComponents(t *testing.T) {
	var recorded []string
	f := newFixture(t, successScript, func(config *ManagerConfig) {
		bundle := filepath.Join(config.HomeDir, "Applications", "Desktop.app")
		if err := os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755); err != nil {
			t.Fatal(err)
		}
		config.ResolveInstallation = func(_ context.Context, target, installationID string) (Installation, error) {
			return Installation{TargetID: target, InstallationID: installationID, Executable: bundle, Version: "1.46388.4"}, nil
		}
		config.RecordGlobal = func(_ context.Context, target, version string) (configuration.GlobalStatus, error) {
			recorded = append(recorded, target)
			return configuration.GlobalStatus{TargetID: target, CurrentService: configuration.ServiceZhiban, VerificationLevel: configuration.VerificationL2, LastVerifiedAt: "2026-09-09T12:00:00Z"}, nil
		}
		config.ComponentsReady = func(_ context.Context, target string) error {
			if target == TargetClaudeDesktop {
				return errors.New("component claude_code_host is missing")
			}
			return nil
		}
	})
	for _, targetID := range []string{TargetClaudeDesktop, TargetCodexDesktop} {
		f.status = configuration.Status{TargetID: targetID, State: configuration.StateNotConfigured, CurrentService: configuration.ServiceZhiban, GlobalSwitched: true}
		envelope, err := f.manager.Execute(context.Background(), targetID, "install-1", ScopeGlobal)
		if err != nil {
			t.Fatalf("Execute(%s) error = %v", targetID, err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		final, err := f.registry.Wait(ctx, envelope.OperationID)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if targetID == TargetClaudeDesktop {
			if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CLAUDE_DESKTOP-VERIFY-COMPONENT_MISSING" {
				t.Fatalf("claude_desktop final = %+v", final)
			}
			if len(recorded) != 0 {
				t.Fatalf("nothing may be recorded when a component is missing: %v", recorded)
			}
			continue
		}
		if final.State != operation.StateSucceeded || len(recorded) != 1 || recorded[0] != TargetCodexDesktop {
			t.Fatalf("codex_desktop final = %+v recorded=%v", final, recorded)
		}
	}
}
