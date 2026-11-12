package localcodingcatalog

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

type capturedAutoSyncLog struct {
	mu       sync.Mutex
	events   []map[string]any
	finished chan map[string]any
}

func (l *capturedAutoSyncLog) capture(level string, fields ...any) {
	event := map[string]any{"level": level}
	for i := 0; i+1 < len(fields); i += 2 {
		event[fields[i].(string)] = fields[i+1]
	}
	l.mu.Lock()
	l.events = append(l.events, event)
	l.mu.Unlock()
	if event["event"] == "round_finished" && l.finished != nil {
		l.finished <- event
	}
}
func (l *capturedAutoSyncLog) Info(_ context.Context, _ string, fields ...any) {
	l.capture("info", fields...)
}
func (l *capturedAutoSyncLog) Warn(_ context.Context, _ string, fields ...any) {
	l.capture("warn", fields...)
}
func (l *capturedAutoSyncLog) Error(_ context.Context, _ string, fields ...any) {
	l.capture("error", fields...)
}

func TestAutoSyncLogsEachFailureImmediatelyAndSummarizesRound(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	logs := &capturedAutoSyncLog{}
	s.logger = logs
	u := codexDesktopBase + "ChatGPT-darwin-arm64-26.924.22138.zip"
	f.blobs[u] = []byte(strings.Repeat("x", len(f.blobs[u])))
	report, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Results) != 12 {
		t.Fatal(report)
	}
	first := logs.events[0]
	if first["event"] != "round_started" || first["trigger"] != "scheduled" || first["run_id"] == "" {
		t.Fatal(first)
	}
	failure, laterSuccess := -1, -1
	stages := map[string]bool{}
	for i, e := range logs.events {
		if e["run_id"] != first["run_id"] || e["component"] != "local_coding_autosync" {
			t.Fatal(e)
		}
		if e["duration_ms"].(int64) < 0 {
			t.Fatal(e)
		}
		if e["event"] == "stage_started" {
			stages[e["stage"].(string)] = true
		}
		if e["event"] != "item_finished" {
			continue
		}
		if e["target"] == dom.TargetCodexDesktop && e["platform"] == dom.PlatformMacOS && e["arch"] == dom.ArchArm64 {
			failure = i
			if e["level"] != "error" || e["stage"] != "verify" || e["outcome"] != AutoSyncFailed || e["detail"] == "" {
				t.Fatal(e)
			}
		}
		if e["target"] == dom.TargetCodexDesktop && e["arch"] == dom.ArchX64 {
			laterSuccess = i
		}
	}
	if failure < 0 || laterSuccess < failure {
		t.Fatal("failure was not logged before the next item completed")
	}
	for _, stage := range []string{"discover", "catalog", "download", "verify", "record", "upload", "publish", "cleanup"} {
		if !stages[stage] {
			t.Fatal("missing stage", stage)
		}
	}
	last := logs.events[len(logs.events)-1]
	if last["event"] != "round_finished" || last["level"] != "error" || last["failed"] != 1 || last["published"] != 11 {
		t.Fatal(last)
	}
}

type autoSyncLockFailureRepo struct {
	dom.Repository
	lockErr error
}

func (r autoSyncLockFailureRepo) TryAutoSyncLock(context.Context) (func(), bool, error) {
	return nil, false, r.lockErr
}

func TestManualAutoSyncLogsBackgroundLockFailureAndBusySkip(t *testing.T) {
	for _, failed := range []bool{true, false} {
		t.Run(fmt.Sprint(failed), func(t *testing.T) {
			f := newAutoSyncFixture(t)
			s := f.svc.(*impl)
			logs := &capturedAutoSyncLog{finished: make(chan map[string]any, 1)}
			s.logger = logs
			var lockErr error
			if failed {
				lockErr = errors.New("database unavailable password=supersecret postgres://" + "user:dbpassword" + "@db/test")
			}
			s.repo = autoSyncLockFailureRepo{Repository: f.repo, lockErr: lockErr}
			if err := s.StartAutoSync(context.Background()); err != nil {
				t.Fatal(err)
			}
			select {
			case e := <-logs.finished:
				if e["trigger"] != "manual" || e["stage"] != "acquire_lock" {
					t.Fatal(e)
				}
				if failed && (e["level"] != "error" || e["outcome"] != "failed") {
					t.Fatal(e)
				}
				if !failed && (e["level"] != "info" || e["outcome"] != "skipped") {
					t.Fatal(e)
				}
				if strings.Contains(e["detail"].(string), "supersecret") || strings.Contains(e["detail"].(string), "dbpassword") {
					t.Fatal("credentials leaked")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("manual background failure was not logged")
			}
		})
	}
}

func TestAutoSyncLogsUploadAndPublishFailuresAtCorrectStage(t *testing.T) {
	for _, stage := range []string{"upload", "publish"} {
		t.Run(stage, func(t *testing.T) {
			f := newDesktopFixture(t)
			s := f.svc.(*impl)
			logs := &capturedAutoSyncLog{}
			s.logger = logs
			if stage == "upload" {
				f.store.putErr = errors.New("HTTP 503 token=sensitive-token https://cdn.test/a?Signature=private-signature")
			} else {
				s.repo = &autoPublishFailureRepo{Repository: f.repo, fail: true}
			}
			_, err := s.AutoSync(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			failures := 0
			for _, e := range logs.events {
				if e["event"] != "item_finished" {
					continue
				}
				failures++
				if e["level"] != "error" || e["stage"] != stage {
					t.Fatal(e)
				}
				text := e["detail"].(string)
				if strings.Contains(text, "sensitive-token") || strings.Contains(text, "private-signature") {
					t.Fatal("credential leaked")
				}
				if stage == "upload" && !strings.Contains(text, "503") {
					t.Fatal("diagnostic status lost")
				}
			}
			if failures != 12 {
				t.Fatal(failures)
			}
		})
	}
}

func TestAutoSyncLogsUnchangedVersionsAsNormalSkips(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	if _, err := s.AutoSync(context.Background()); err != nil {
		t.Fatal(err)
	}
	logs := &capturedAutoSyncLog{}
	s.logger = logs
	if _, err := s.AutoSync(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, e := range logs.events {
		if e["level"] != "info" {
			t.Fatal(e)
		}
	}
	e := logs.events[len(logs.events)-1]
	if e["skipped"] != 12 || e["failed"] != 0 || e["published"] != 0 {
		t.Fatal(e)
	}
}

// Synthetic credentials are joined at runtime; source scanners still reject literal credential URLs.
func TestAutoSyncDetailRedactionAndLength(t *testing.T) {
	raw := `HTTP 403 password="two secret words" Authorization=privatecredential ` + "https://" + "user:proxysecret" + "@cdn.test/file?X-Amz-Signature=signaturevalue api_key=keyvalue" + "\n" + strings.Repeat("长", 3000)
	clean := safeAutoSyncDetail(raw)
	for _, secret := range []string{"two secret words", "privatecredential", "proxysecret", "signaturevalue", "keyvalue", "\n"} {
		if strings.Contains(clean, secret) {
			t.Fatal("unsafe log", secret)
		}
	}
	if !strings.Contains(clean, "403") || len([]rune(clean)) > 2049 {
		t.Fatal("lost status or length limit")
	}
}
