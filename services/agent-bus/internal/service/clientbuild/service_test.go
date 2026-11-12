package clientbuild

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientbuild"
	repomemory "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/memory/clientbuild"
)

func TestCallTreatsNgrokOfflineResponseAsTransportError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Ngrok-Error-Code", "ERR_NGROK_3200")
		http.Error(w, "endpoint offline", http.StatusNotFound)
	}))
	defer server.Close()

	service := &impl{client: server.Client()}
	status, err := service.call(context.Background(), RunnerConfig{URL: server.URL, Token: strings.Repeat("a", 32)}, http.MethodPost, "/v1/builds", []byte(`{}`), nil)
	if status != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", status, http.StatusNotFound)
	}
	if err == nil || !strings.Contains(err.Error(), "ERR_NGROK_3200") {
		t.Fatalf("error = %v, want ngrok offline error", err)
	}
}

func TestStopForwardsToRunnerAndFinishesCancelled(t *testing.T) {
	var deletes int
	runner := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete || r.URL.Path != "/v1/builds/remote-1" {
			t.Fatalf("unexpected runner request: %s %s", r.Method, r.URL.Path)
		}
		deletes++
		_ = json.NewEncoder(w).Encode(runnerJob{ID: "remote-1", State: "cancelled"})
	}))
	defer runner.Close()

	repo := repomemory.New()
	job, err := repo.Create(context.Background(), dom.Input{Platform: "windows", Arch: "x64", Environment: "test", Channel: "stable", Version: "1.2.9", BuildNumber: "12900"}, 1, 1, "", "request-0123456789")
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.UpdateRemote(context.Background(), job.UUID, "running", "remote-1"); err != nil {
		t.Fatal(err)
	}
	service := &impl{repo: repo, client: runner.Client(), cfg: Config{Windows: RunnerConfig{URL: runner.URL, Token: strings.Repeat("a", 32)}}}
	stopped, err := service.Stop(context.Background(), job.UUID, 1)
	if err != nil {
		t.Fatal(err)
	}
	if stopped.Status != "cancelled" || deletes != 1 {
		t.Fatalf("stopped = %+v, delete calls = %d", stopped, deletes)
	}
	if _, err := service.Stop(context.Background(), job.UUID, 1); err != nil {
		t.Fatalf("idempotent stop failed: %v", err)
	}
}

func TestDeploymentEnvironment(t *testing.T) {
	tests := map[string]string{
		"prod":       "prod",
		"production": "prod",
		"test":       "test",
		"dev":        "test",
		"local":      "test",
		"":           "test",
	}
	for input, want := range tests {
		if got := deploymentEnvironment(input); got != want {
			t.Errorf("deploymentEnvironment(%q) = %q, want %q", input, got, want)
		}
	}
}
