package clientbuild

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientbuild"
	memory "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/memory/clientbuild"
)

// A real HTTP runner exchange verifies dispatch, authentication, deployment
// environment, incremental logs, and terminal state without starting a build.
func TestBuildLifecycleDispatchesAndCollectsRunnerResult(t *testing.T) {
	var creates atomic.Int32
	runner := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("t", 32) {
			t.Error("runner bearer missing")
			w.WriteHeader(401)
			return
		}
		switch {
		case r.Method == "POST" && r.URL.Path == "/v1/builds":
			var in struct {
				Platform, Environment string
				BuildNumber           string `json:"build_number"`
				RequestID             string `json:"request_id"`
			}
			if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			if in.Platform != "macos" || in.Environment != "prod" || in.BuildNumber != "10000" || in.RequestID == "" {
				t.Errorf("wrong runner input: %+v", in)
			}
			creates.Add(1)
			w.WriteHeader(http.StatusAccepted)
			_ = json.NewEncoder(w).Encode(runnerJob{ID: "remote-build", State: "running"})
		case r.Method == "GET" && r.URL.Path == "/v1/builds/remote-build":
			if r.URL.Query().Get("after_seq") != "0" {
				t.Errorf("wrong log cursor: %s", r.URL.RawQuery)
			}
			_ = json.NewEncoder(w).Encode(runnerJob{ID: "remote-build", State: "succeeded", ClientVersionUUID: "version-id", Logs: []runnerLog{{Seq: 1, Stream: "stdout", Message: "build complete"}}})
		default:
			t.Errorf("unexpected runner request: %s %s", r.Method, r.URL)
			w.WriteHeader(404)
		}
	}))
	defer runner.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	service := New(ctx, memory.New(), Config{Environment: "production", Mac: RunnerConfig{URL: runner.URL, Token: strings.Repeat("t", 32)}})
	job, err := service.Create(ctx, dom.Input{Platform: "macos", Arch: "arm64", Version: "1.0.0", BuildNumber: "10000", Environment: "test"}, 5)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-deadline.C:
			t.Fatal("build did not complete")
		case <-ticker.C:
			current, err := service.Get(ctx, job.UUID)
			if err != nil {
				t.Fatal(err)
			}
			if current.Status == "failed" {
				t.Fatalf("build failed: %s", current.Error)
			}
			if current.Status != "succeeded" {
				continue
			}
			if current.Environment != "prod" || current.CreatedBy != 5 || current.RunnerJobID != "remote-build" || current.ClientVersionUUID != "version-id" || current.FinishedAt == nil || creates.Load() != 1 {
				t.Fatalf("unexpected result: %+v", current)
			}
			logs, err := service.Logs(ctx, job.UUID, 0)
			if err != nil || len(logs) != 1 || logs[0].Message != "build complete" {
				t.Fatalf("logs=%+v err=%v", logs, err)
			}
			logs, err = service.Logs(ctx, job.UUID, 1)
			if err != nil || len(logs) != 0 {
				t.Fatalf("incremental logs=%+v err=%v", logs, err)
			}
			if _, err := service.Retry(ctx, job.UUID, 5); err != dom.ErrNotRetryable {
				t.Fatalf("successful job retry error=%v", err)
			}
			return
		}
	}
}
