package agent

import (
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"testing"
)

func TestOrganizationLocalVisibilityAndEngineImmutability(t *testing.T) {
	for _, visibility := range []string{"tenant", "workspace", "private", ""} {
		e := &dom.DigitalEmployee{Source: "enterprise", CreatorID: 5, ExecutionLocus: "local", LocalEngine: "dsh", Visibility: visibility}
		if err := normalizeExecutionLocus(e, nil); err != nil {
			t.Fatal(err)
		}
		expected := visibility
		if expected == "" {
			expected = "tenant"
		}
		if e.Visibility != expected || e.RuntimeEnvironmentID != nil {
			t.Fatalf("organization visibility lost: %s", e.Visibility)
		}
	}
	e := &dom.DigitalEmployee{Source: "personal", CreatorID: 5, ExecutionLocus: "local", LocalEngine: "dsh", Visibility: "tenant"}
	if err := normalizeExecutionLocus(e, nil); err != nil || e.Visibility != "private" {
		t.Fatal("personal employee must remain private")
	}
	next := *e
	next.LocalEngine = "codex_app_server"
	if err := normalizeExecutionLocus(&next, e); err == nil {
		t.Fatal("existing engine changed")
	}
}
