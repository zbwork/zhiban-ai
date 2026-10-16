package diagnostics

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

func TestRecorderKeepsLatestFailurePerTarget(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 8, 9, 0, 0, 0, time.UTC)
	recorder := NewRecorder("0.3.0-test", func() time.Time { return clock })

	empty := recorder.Latest("codex_cli")
	if empty.TargetID != "codex_cli" || empty.BridgeVersion != "0.3.0-test" || empty.OccurredAt != nil || empty.Kind != nil ||
		empty.Stage != nil || empty.ErrorCode != nil || len(empty.Suggestions) != 0 {
		t.Fatalf("empty latest = %+v", empty)
	}

	recorder.Record("codex_cli", KindDetect, "detect", "LCT-CODEX_CLI-DETECT-MULTIPLE_INSTALLS")
	recorder.Record("codex_cli", KindConfig, "plan", "")
	recorder.Record("codex_cli", KindConfig, "plan", "not a code")
	latest := recorder.Latest("codex_cli")
	if latest.ErrorCode == nil || *latest.ErrorCode != "LCT-CODEX_CLI-DETECT-MULTIPLE_INSTALLS" || *latest.Kind != KindDetect ||
		*latest.OccurredAt != "2026-09-08T09:00:00Z" || len(latest.Suggestions) == 0 {
		t.Fatalf("latest after detect = %+v", latest)
	}

	clock = clock.Add(time.Minute)
	code := "LCT-CODEX_CLI-INSTALL-HASH_MISMATCH"
	recorder.Observe(operation.Event{Envelope: operation.Envelope{TargetID: "codex_cli", Kind: operation.KindInstall, State: operation.StateFailed, Stage: "verifying", ErrorCode: &code}})
	recorder.Observe(operation.Event{Envelope: operation.Envelope{TargetID: "claude_cli", Kind: operation.KindInstall, State: operation.StateSucceeded}})
	latest = recorder.Latest("codex_cli")
	if *latest.ErrorCode != code || *latest.Stage != "verifying" || *latest.Kind != KindInstall || *latest.OccurredAt != "2026-09-08T09:01:00Z" {
		t.Fatalf("latest after install failure = %+v", latest)
	}
	if other := recorder.Latest("claude_cli"); other.ErrorCode != nil {
		t.Fatalf("succeeded operation recorded: %+v", other)
	}
	// A later success for the same target clears its stale failure.
	recorder.Observe(operation.Event{Envelope: operation.Envelope{TargetID: "codex_cli", Kind: operation.KindInstall, State: operation.StateSucceeded}})
	if cleared := recorder.Latest("codex_cli"); cleared.ErrorCode != nil {
		t.Fatalf("success must clear the record: %+v", cleared)
	}
	if suggestions := Suggestions("LCT-CLAUDE_CLI-GATEWAY-MODEL_DENIED"); len(suggestions) != 2 {
		t.Fatalf("suggestions = %v", suggestions)
	}
	if suggestions := Suggestions("garbage"); len(suggestions) != 2 {
		t.Fatalf("default suggestions = %v", suggestions)
	}
}

func TestPersistentRecorderSurvivesAnotherProcess(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 9, 18, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "state", "diagnostics.json")

	// Process 1: an operation fails and is recorded.
	first := NewPersistentRecorder("0.4.0-test", func() time.Time { return clock }, path)
	first.Record("claude_desktop", KindInstall, "installing", "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH")
	if info, err := os.Stat(path); err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("diagnostics file = %v, %v", info, err)
	}
	if entries, err := os.ReadDir(filepath.Dir(path)); err != nil || len(entries) != 1 {
		t.Fatalf("temp files left behind: %v, %v", entries, err)
	}

	// Process 2 (the one the App starts to read 诊断详情) sees it.
	second := NewPersistentRecorder("0.4.0-test", nil, path)
	latest := second.Latest("claude_desktop")
	if latest.ErrorCode == nil || *latest.ErrorCode != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" ||
		latest.Kind == nil || *latest.Kind != KindInstall || latest.Stage == nil || *latest.Stage != "installing" ||
		latest.OccurredAt == nil || *latest.OccurredAt != "2026-09-09T18:00:00Z" || len(latest.Suggestions) == 0 {
		t.Fatalf("latest after restart = %+v", latest)
	}
	if other := second.Latest("codex_cli"); other.ErrorCode != nil {
		t.Fatalf("unrelated target must stay empty: %+v", other)
	}

	// A newer failure replaces the record and is what a third process sees.
	second.Record("claude_desktop", KindVerify, "l2", "LCT-CLAUDE_DESKTOP-VERIFY-COMPONENT_MISSING")
	third := NewPersistentRecorder("0.4.0-test", nil, path)
	if latest := third.Latest("claude_desktop"); latest.ErrorCode == nil || *latest.ErrorCode != "LCT-CLAUDE_DESKTOP-VERIFY-COMPONENT_MISSING" {
		t.Fatalf("latest after second failure = %+v", latest)
	}

	// A success in yet another process clears the record on disk too.
	third.Clear("claude_desktop")
	if latest := NewPersistentRecorder("0.4.0-test", nil, path).Latest("claude_desktop"); latest.ErrorCode != nil {
		t.Fatalf("cleared record survived on disk: %+v", latest)
	}

	// A failed verification keeps the gateway's answer across processes.
	detail, upstreamCode := "HTTP 503 · auth_unavailable: no auth available", "LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE"
	third.Observe(operation.Event{Envelope: operation.Envelope{
		TargetID: "codex_cli", Kind: KindVerify, Stage: "l3", State: operation.StateFailed,
		ErrorCode: &upstreamCode, ErrorDetail: &detail,
	}})
	latest = NewPersistentRecorder("0.4.0-test", nil, path).Latest("codex_cli")
	if latest.ErrorDetail == nil || *latest.ErrorDetail != detail || len(latest.Suggestions) == 0 ||
		!strings.Contains(latest.Suggestions[0], "中转站") {
		t.Fatalf("verify failure after restart = %+v", latest)
	}

	// Corrupt or foreign files start empty instead of failing.
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if latest := NewPersistentRecorder("0.4.0-test", nil, path).Latest("claude_desktop"); latest.ErrorCode != nil {
		t.Fatalf("corrupt file must start empty: %+v", latest)
	}
	// Memory-only recorders keep working without a path.
	if NewRecorder("0.4.0-test", nil).Path() != "" {
		t.Fatal("memory-only recorder must have no path")
	}
}
