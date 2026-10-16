package app

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/diagnostics"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// Contract §2.7.2 "写入失败的错误码与自动重试": a failed config.execute names
// its cause and leaves it in the diagnostics instead of an opaque -32603.
func TestConfigurationWriteFailureReportsAndRecordsTheCause(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name string
		err  error
		want string
	}{
		{"unsafe path", configuration.ErrUnsafePath, "LCT-CODEX_DESKTOP-CONFIG-UNSAFE_PATH"},
		{"file changed after the plan", fmt.Errorf("write config.toml: %w", configuration.ErrPreconditionChanged), "LCT-CODEX_DESKTOP-CONFIG-PRECONDITION_CHANGED"},
		{"plan expired", configuration.ErrPlanExpired, "LCT-CODEX_DESKTOP-CONFIG-PLAN_EXPIRED"},
		{"plan unknown", configuration.ErrPlanNotFound, "LCT-CODEX_DESKTOP-CONFIG-PLAN_EXPIRED"},
		{"probe failed and rollback failed", errors.Join(configuration.ErrValidationFailed, configuration.ErrRollbackFailed), "LCT-CODEX_DESKTOP-CONFIG-ROLLBACK_FAILED"},
		{"probe failed, rolled back", configuration.ErrValidationFailed, "LCT-CODEX_DESKTOP-CONFIG-VALIDATION_FAILED"},
		{"installation changed", configuration.ErrInstallationChanged, "LCT-CODEX_DESKTOP-CONFIG-INSTALLATION_CHANGED"},
		{"not switched", configuration.ErrGlobalNotSwitched, "LCT-CODEX_DESKTOP-CONFIG-NOT_SWITCHED"},
	} {
		recorder := diagnostics.NewRecorder("test", time.Now)
		err := configurationWriteFailure(recorder, "codex_desktop", tc.err)
		var failure *operation.Failure
		if !errors.As(err, &failure) || failure.Code != tc.want {
			t.Errorf("%s: error = %v, want code %s", tc.name, err, tc.want)
			continue
		}
		latest := recorder.Latest("codex_desktop")
		if latest.ErrorCode == nil || *latest.ErrorCode != tc.want || latest.Stage == nil || *latest.Stage != "execute" {
			t.Errorf("%s: recorded = %+v", tc.name, latest)
		}
	}

	// Unclassified errors stay opaque on the wire but are no longer invisible.
	recorder := diagnostics.NewRecorder("test", time.Now)
	boom := errors.New("boom")
	if err := configurationWriteFailure(recorder, "codex_cli", boom); !errors.Is(err, boom) {
		t.Fatalf("unclassified error = %v", err)
	}
	if latest := recorder.Latest("codex_cli"); latest.ErrorCode == nil || *latest.ErrorCode != "LCT-CODEX_CLI-CONFIG-EXECUTE_FAILED" {
		t.Fatalf("unclassified recorded = %+v", latest)
	}

	// An unknown plan has no target: the code names the Bridge instead.
	err := configurationWriteFailure(recorder, "", configuration.ErrPlanNotFound)
	var failure *operation.Failure
	if !errors.As(err, &failure) || failure.Code != "LCT-BRIDGE-CONFIG-PLAN_EXPIRED" {
		t.Fatalf("unknown plan error = %v", err)
	}
}
