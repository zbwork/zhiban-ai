package operation

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestRegistryRunsOperationAndRetainsResult(t *testing.T) {
	t.Parallel()

	var events []Event
	registry := NewRegistry(WithObserver(func(event Event) { events = append(events, event) }))
	release := make(chan struct{})
	envelope, err := registry.Start(Spec{
		TargetID: "codex_cli", Kind: KindInstall, InitialStage: "preflight", Cancellable: true,
		CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
		Run: func(ctx context.Context, report *Reporter) (any, error) {
			report.Progress("downloading", 40, true)
			<-release
			report.Stage("installing", false)
			return map[string]string{"tool_state": "installed"}, nil
		},
	})
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if envelope.OperationID == "" || envelope.State != StateRunning || envelope.Stage != "preflight" ||
		envelope.ProgressKind != ProgressIndeterminate || envelope.ProgressValue != nil || !envelope.Cancellable ||
		len(envelope.NextActions) != 1 || envelope.NextActions[0] != "cancel" || envelope.Result != nil {
		t.Fatalf("initial envelope = %+v", envelope)
	}

	waitFor(t, func() bool {
		current, _ := registry.Get(envelope.OperationID)
		return current.Stage == "downloading"
	})
	current, err := registry.Get(envelope.OperationID)
	if err != nil || current.ProgressKind != ProgressDeterminate || current.ProgressValue == nil || *current.ProgressValue != 40 {
		t.Fatalf("progress envelope = %+v, %v", current, err)
	}
	if !registry.Running("codex_cli") {
		t.Fatal("Running() = false while operation is in flight")
	}
	close(release)

	final, err := registry.Wait(context.Background(), envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	if final.State != StateSucceeded || final.Cancellable || final.ProgressValue != nil || final.ErrorCode != nil ||
		len(final.NextActions) != 1 || final.NextActions[0] != "detect" {
		t.Fatalf("final envelope = %+v", final)
	}
	result, ok := final.Result.(map[string]string)
	if !ok || result["tool_state"] != "installed" {
		t.Fatalf("result = %#v", final.Result)
	}
	again, err := registry.Get(envelope.OperationID)
	if err != nil || again.State != StateSucceeded || again.Result == nil {
		t.Fatalf("result not retained: %+v, %v", again, err)
	}
	if registry.Running("codex_cli") {
		t.Fatal("Running() = true after completion")
	}
	if len(events) != 1 || events[0].Envelope.State != StateSucceeded {
		t.Fatalf("events = %+v", events)
	}
	latest, ok := registry.Latest("codex_cli")
	if !ok || latest.OperationID != envelope.OperationID {
		t.Fatalf("Latest() = %+v, %t", latest, ok)
	}
}

func TestRegistryRejectsConcurrentOperationsPerTarget(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	release := make(chan struct{})
	spec := Spec{
		TargetID: "claude_cli", Kind: KindVerify, InitialStage: "l1", Cancellable: true,
		CancelCode: "LCT-CLAUDE_CLI-LAUNCH-SYSTEM_CANCELLED", FailureCode: "LCT-CLAUDE_CLI-GATEWAY-PROTOCOL_MISMATCH",
		Run: func(ctx context.Context, _ *Reporter) (any, error) {
			<-release
			return nil, nil
		},
	}
	first, err := registry.Start(spec)
	if err != nil {
		t.Fatalf("first Start() error = %v", err)
	}
	if _, err := registry.Start(spec); !errors.Is(err, ErrBusy) {
		t.Fatalf("second Start() error = %v, want ErrBusy", err)
	}
	other := spec
	other.TargetID = "codex_cli"
	if _, err := registry.Start(other); err != nil {
		t.Fatalf("Start() for other target error = %v", err)
	}
	close(release)
	if _, err := registry.Wait(context.Background(), first.OperationID); err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	if _, err := registry.Start(spec); err != nil {
		t.Fatalf("Start() after completion error = %v", err)
	}
}

func TestRegistryCancelsOnlyWhileCancellable(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	cleaned := false
	entered := make(chan struct{})
	envelope, err := registry.Start(Spec{
		TargetID: "codex_cli", Kind: KindInstall, InitialStage: "preflight", Cancellable: true,
		CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
		Cleanup: func() { cleaned = true },
		Run: func(ctx context.Context, report *Reporter) (any, error) {
			close(entered)
			<-ctx.Done()
			if !report.Cancelled() {
				return nil, errors.New("cancel flag missing")
			}
			return nil, ctx.Err()
		},
	})
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	<-entered
	cancelled, err := registry.Cancel(envelope.OperationID)
	if err != nil {
		t.Fatalf("Cancel() error = %v", err)
	}
	if cancelled.OperationID != envelope.OperationID {
		t.Fatalf("Cancel() envelope = %+v", cancelled)
	}
	final, err := registry.Wait(context.Background(), envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	if final.State != StateCancelled || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED" ||
		len(final.NextActions) != 1 || final.NextActions[0] != "retry" || !cleaned {
		t.Fatalf("cancelled envelope = %+v cleaned=%t", final, cleaned)
	}
	if again, err := registry.Cancel(envelope.OperationID); err != nil || again.State != StateCancelled {
		t.Fatalf("Cancel() on terminal = %+v, %v", again, err)
	}

	locked := make(chan struct{})
	release := make(chan struct{})
	uncancellable, err := registry.Start(Spec{
		TargetID: "codex_cli", Kind: KindInstall, InitialStage: "installing", Cancellable: false,
		CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
		Run: func(ctx context.Context, _ *Reporter) (any, error) {
			close(locked)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-release:
				return "done", nil
			}
		},
	})
	if err != nil {
		t.Fatalf("Start() uncancellable error = %v", err)
	}
	<-locked
	if current, err := registry.Cancel(uncancellable.OperationID); err != nil || current.State != StateRunning {
		t.Fatalf("Cancel() on uncancellable = %+v, %v", current, err)
	}
	close(release)
	final, err = registry.Wait(context.Background(), uncancellable.OperationID)
	if err != nil || final.State != StateSucceeded {
		t.Fatalf("uncancellable final = %+v, %v", final, err)
	}
}

func TestRegistryMapsFailuresToErrorCodes(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	tests := []struct {
		name   string
		err    error
		want   string
		detail string
	}{
		{name: "typed failure", err: Fail("LCT-CODEX_CLI-INSTALL-HASH_MISMATCH", errors.New("digest differs")), want: "LCT-CODEX_CLI-INSTALL-HASH_MISMATCH"},
		{name: "wrapped failure", err: errors.Join(errors.New("outer"), Fail("LCT-CODEX_CLI-INSTALL-SIZE_MISMATCH", nil)), want: "LCT-CODEX_CLI-INSTALL-SIZE_MISMATCH"},
		{name: "plain error", err: errors.New("boom"), want: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED"},
		{name: "unsafe code", err: Fail("LCT-CODEX_CLI-INSTALL-BAD CODE", nil), want: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED"},
		{name: "context cancelled without request", err: context.Canceled, want: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED"},
		{name: "failure with detail", err: FailDetail("LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED", "HTTP 503 · overloaded", nil), want: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED", detail: "HTTP 503 · overloaded"},
		{name: "oversized detail dropped", err: FailDetail("LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED", strings.Repeat("x", 2048), nil), want: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED"},
	}
	for _, test := range tests {
		runErr := test.err
		envelope, err := registry.Start(Spec{
			TargetID: "codex_cli", Kind: KindInstall, InitialStage: "preflight", Cancellable: true,
			CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
			Run: func(context.Context, *Reporter) (any, error) { return nil, runErr },
		})
		if err != nil {
			t.Fatalf("%s: Start() error = %v", test.name, err)
		}
		final, err := registry.Wait(context.Background(), envelope.OperationID)
		if err != nil || final.State != StateFailed || final.ErrorCode == nil || *final.ErrorCode != test.want ||
			len(final.NextActions) != 2 || final.NextActions[0] != "retry" {
			t.Fatalf("%s: final = %+v, %v", test.name, final, err)
		}
		if got := ""; final.ErrorDetail != nil || test.detail != "" {
			if final.ErrorDetail != nil {
				got = *final.ErrorDetail
			}
			if got != test.detail {
				t.Fatalf("%s: error_detail = %q, want %q", test.name, got, test.detail)
			}
		}
	}
}

func TestRegistryRecoversFromPanicAndValidatesInput(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	envelope, err := registry.Start(Spec{
		TargetID: "codex_cli", Kind: KindInstall, InitialStage: "preflight", Cancellable: true,
		CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
		Run: func(context.Context, *Reporter) (any, error) { panic("boom") },
	})
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	final, err := registry.Wait(context.Background(), envelope.OperationID)
	if err != nil || final.State != StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED" {
		t.Fatalf("panic final = %+v, %v", final, err)
	}

	if _, err := registry.Start(Spec{TargetID: "bad target", Kind: KindInstall, InitialStage: "x", CancelCode: "a", FailureCode: "b", Run: func(context.Context, *Reporter) (any, error) { return nil, nil }}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Start() with unsafe target error = %v", err)
	}
	if _, err := registry.Get("missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(missing) error = %v", err)
	}
	if _, err := registry.Get("../etc"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Get(unsafe) error = %v", err)
	}
	if _, err := registry.Cancel("missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Cancel(missing) error = %v", err)
	}
	if _, ok := registry.Latest("claude_cli"); ok {
		t.Fatal("Latest() found an operation for an idle target")
	}
}

func TestRegistryShutdownCancelsRunningOperations(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	var cleanupMu sync.Mutex
	cleanups := 0
	started := make(chan struct{}, 2)
	for _, target := range []string{"codex_cli", "claude_cli"} {
		_, err := registry.Start(Spec{
			TargetID: target, Kind: KindInstall, InitialStage: "downloading", Cancellable: true,
			CancelCode: "LCT-" + target + "-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-" + target + "-INSTALL-DOWNLOAD_FAILED",
			Cleanup: func() {
				cleanupMu.Lock()
				cleanups++
				cleanupMu.Unlock()
			},
			Run: func(ctx context.Context, _ *Reporter) (any, error) {
				started <- struct{}{}
				<-ctx.Done()
				return nil, ctx.Err()
			},
		})
		if err != nil {
			t.Fatalf("Start(%s) error = %v", target, err)
		}
	}
	<-started
	<-started
	if !registry.Shutdown(5 * time.Second) {
		t.Fatal("Shutdown() timed out")
	}
	cleanupMu.Lock()
	defer cleanupMu.Unlock()
	if cleanups != 2 {
		t.Fatalf("cleanups = %d, want 2", cleanups)
	}
	for _, target := range []string{"codex_cli", "claude_cli"} {
		latest, ok := registry.Latest(target)
		if !ok || latest.State != StateCancelled {
			t.Fatalf("Latest(%s) = %+v, %t", target, latest, ok)
		}
	}
	if _, err := registry.Start(Spec{TargetID: "codex_cli", Kind: KindInstall, InitialStage: "x", CancelCode: "a", FailureCode: "b", Run: func(context.Context, *Reporter) (any, error) { return nil, nil }}); !errors.Is(err, ErrClosed) {
		t.Fatalf("Start() after Shutdown error = %v", err)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not met in time")
}
