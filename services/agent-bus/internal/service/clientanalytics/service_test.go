package clientanalytics

import (
	"context"
	"errors"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

type fakeRepo struct{ count int }

func (r *fakeRepo) InsertBatch(_ context.Context, _, _ int64, events []dom.Event) error {
	r.count += len(events)
	return nil
}

func TestRecordValidatesClientAnalytics(t *testing.T) {
	repo := &fakeRepo{}
	svc := New(repo)
	valid := dom.Event{EventID: "11111111-1111-4111-8111-111111111111", Name: "app_active", SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222", Platform: "macos", OccurredAt: time.Now(), Properties: map[string]any{"source": "launch"}}
	if err := svc.Record(context.Background(), 1, 2, []dom.Event{valid}); err != nil {
		t.Fatalf("Record() error = %v", err)
	}
	if repo.count != 1 {
		t.Fatalf("inserted=%d want 1", repo.count)
	}

	invalid := valid
	invalid.Properties = map[string]any{"phone": "13800000000"}
	if err := svc.Record(context.Background(), 1, 2, []dom.Event{invalid}); !errors.Is(err, dom.ErrInvalidEvent) {
		t.Fatalf("sensitive property error=%v", err)
	}
	invalid = valid
	invalid.EventID = "not-a-uuid"
	if err := svc.Record(context.Background(), 1, 2, []dom.Event{invalid}); !errors.Is(err, dom.ErrInvalidEvent) {
		t.Fatalf("invalid uuid error=%v", err)
	}
	invalid = valid
	invalid.Properties = map[string]any{"source": "user-provided-high-cardinality-value"}
	if err := svc.Record(context.Background(), 1, 2, []dom.Event{invalid}); !errors.Is(err, dom.ErrInvalidEvent) {
		t.Fatalf("invalid source error=%v", err)
	}
	invalid = valid
	invalid.Properties = map[string]any{}
	if err := svc.Record(context.Background(), 1, 2, []dom.Event{invalid}); !errors.Is(err, dom.ErrInvalidEvent) {
		t.Fatalf("missing source error=%v", err)
	}
}

func TestRecordAcceptsEveryClientPlatform(t *testing.T) {
	for _, platform := range []string{"android", "ios", "macos", "windows"} {
		t.Run(platform, func(t *testing.T) {
			repo := &fakeRepo{}
			err := New(repo).Record(context.Background(), 1, 2, []dom.Event{{
				EventID: "11111111-1111-4111-8111-111111111111",
				Name:    "app_active", SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222", Platform: platform, OccurredAt: time.Now(),
				Properties: map[string]any{"source": "launch"},
			}})
			if err != nil {
				t.Fatalf("Record() error = %v", err)
			}
		})
	}
}

func TestRecordRejectsDisabledPageView(t *testing.T) {
	err := New(&fakeRepo{}).Record(context.Background(), 1, 2, []dom.Event{{
		EventID: "11111111-1111-4111-8111-111111111111", Name: "page_view",
		SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222",
		Platform: "ios", OccurredAt: time.Now(), Properties: map[string]any{"page": "chat"},
	}})
	if !errors.Is(err, dom.ErrInvalidEvent) {
		t.Fatalf("page_view error=%v", err)
	}
}

func TestRecordAcceptsCustomEvent(t *testing.T) {
	repo := &fakeRepo{}
	err := New(repo).Record(context.Background(), 1, 2, []dom.Event{{
		EventID: "11111111-1111-4111-8111-111111111111", Name: "custom_export_completed",
		SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222",
		Platform: "windows", OccurredAt: time.Now(),
		Properties: map[string]any{"format": "pdf", "success": true, "count": float64(2)},
	}})
	if err != nil {
		t.Fatalf("custom event error=%v", err)
	}
	if repo.count != 1 {
		t.Fatalf("inserted=%d want 1", repo.count)
	}
}

func TestRecordRejectsUnsafeCustomEvent(t *testing.T) {
	tests := []struct {
		name       string
		eventName  string
		properties map[string]any
	}{
		{name: "missing namespace", eventName: "export_completed", properties: map[string]any{"format": "pdf"}},
		{name: "sensitive key", eventName: "custom_export_completed", properties: map[string]any{"phone": "redacted"}},
		{name: "sensitive value", eventName: "custom_export_completed", properties: map[string]any{"label": "user@example.com"}},
		{name: "nested value", eventName: "custom_export_completed", properties: map[string]any{"data": map[string]any{"value": 1}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := New(&fakeRepo{}).Record(context.Background(), 1, 2, []dom.Event{{
				EventID: "11111111-1111-4111-8111-111111111111", Name: tt.eventName,
				SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222",
				Platform: "android", OccurredAt: time.Now(), Properties: tt.properties,
			}})
			if !errors.Is(err, dom.ErrInvalidEvent) {
				t.Fatalf("error=%v want invalid event", err)
			}
		})
	}
}

func TestRecordAcceptsSanitizedFlutterError(t *testing.T) {
	err := New(&fakeRepo{}).Record(context.Background(), 1, 2, []dom.Event{{
		EventID: "11111111-1111-4111-8111-111111111111", Name: "app_error",
		SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222",
		Platform: "ios", OccurredAt: time.Now(), Properties: map[string]any{
			"error_type": "StateError", "error_message": "Bad state: failed",
			"stacktrace":  "#0 Foo.run (lib/foo.dart:12:3)",
			"fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"mechanism":   "flutter", "severity": "error",
		},
	}})
	if err != nil {
		t.Fatalf("app error=%v", err)
	}
}

func TestRecordRejectsUnsanitizedFlutterError(t *testing.T) {
	unsafeValues := []string{
		"account 11111111-1111-4111-8111-111111111111 failed",
		"GET https://host/path?access_token=secret",
		"at /Users/alice/app/lib/main.dart:12:3",
	}
	for _, unsafeValue := range unsafeValues {
		t.Run(unsafeValue, func(t *testing.T) {
			err := New(&fakeRepo{}).Record(context.Background(), 1, 2, []dom.Event{{
				EventID: "11111111-1111-4111-8111-111111111111", Name: "app_error",
				SchemaVersion: 1, SessionID: "22222222-2222-4222-8222-222222222222",
				Platform: "macos", OccurredAt: time.Now(), Properties: map[string]any{
					"error_type": "StateError", "error_message": unsafeValue,
					"stacktrace":  "#0 Foo.run (lib/foo.dart:12:3)",
					"fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
					"mechanism":   "flutter", "severity": "error",
				},
			}})
			if !errors.Is(err, dom.ErrInvalidEvent) {
				t.Fatalf("error=%v want invalid event", err)
			}
		})
	}
}
