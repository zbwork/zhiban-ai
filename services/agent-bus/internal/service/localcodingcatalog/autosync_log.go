package localcodingcatalog

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
)

// AutoSyncLogger is implemented by the shared application logger.
type AutoSyncLogger interface {
	Info(context.Context, string, ...any)
	Warn(context.Context, string, ...any)
	Error(context.Context, string, ...any)
}

type autoSyncLogKey struct{}
type autoSyncLogState struct {
	runID, trigger, target, platform, arch, version, stage string
	started                                                time.Time
}

var autoSyncLogURLs = regexp.MustCompile(`(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+`)
var autoSyncLogSecrets = regexp.MustCompile(`(?i)\b(password|passwd|pwd|token|secret|authorization|api[_-]?key|access[_-]?key(?:[_-]?id)?|secret[_-]?access[_-]?key)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;&]+)`)
var autoSyncRedactor = redact.New()

func safeAutoSyncDetail(s string) string {
	s = autoSyncLogURLs.ReplaceAllString(s, "[URL redacted]")
	s = autoSyncLogSecrets.ReplaceAllString(s, "$1=[REDACTED]")
	s = autoSyncRedactor.RedactText(s)
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " ")
	runes := []rune(s)
	if len(runes) > 2048 {
		s = string(runes[:2048]) + "…"
	}
	return s
}

func autoSyncLogContext(ctx context.Context, trigger string) context.Context {
	return context.WithValue(ctx, autoSyncLogKey{}, &autoSyncLogState{runID: uuid.NewString(), trigger: trigger, stage: "acquire_lock", started: time.Now()})
}

func autoSyncItemContext(ctx context.Context, target, platform, arch, version string) context.Context {
	state := autoSyncLogState{started: time.Now()}
	if parent, ok := ctx.Value(autoSyncLogKey{}).(*autoSyncLogState); ok {
		state.runID, state.trigger = parent.runID, parent.trigger
	}
	state.target, state.platform, state.arch, state.version = target, platform, arch, version
	return context.WithValue(ctx, autoSyncLogKey{}, &state)
}

func (s *impl) autoSyncLog(ctx context.Context, level, event string, fields ...any) {
	if s.logger == nil {
		return
	}
	args := []any{"component", "local_coding_autosync", "event", event}
	if state, ok := ctx.Value(autoSyncLogKey{}).(*autoSyncLogState); ok {
		args = append(args, "run_id", state.runID, "trigger", state.trigger, "stage", state.stage,
			"target", state.target, "platform", state.platform, "arch", state.arch, "version", safeAutoSyncDetail(state.version),
			"duration_ms", time.Since(state.started).Milliseconds())
	}
	args = append(args, fields...)
	switch level {
	case "error":
		s.logger.Error(ctx, "local coding auto sync", args...)
	case "warn":
		s.logger.Warn(ctx, "local coding auto sync", args...)
	default:
		s.logger.Info(ctx, "local coding auto sync", args...)
	}
}

func (s *impl) autoSyncStage(ctx context.Context, stage string) {
	if state, ok := ctx.Value(autoSyncLogKey{}).(*autoSyncLogState); ok {
		state.stage = stage
	}
	s.autoSyncLog(ctx, "info", "stage_started")
}

func (s *impl) autoSyncLogResult(ctx context.Context, result AutoSyncResult) {
	level := "info"
	if result.Outcome == AutoSyncFailed {
		level = "error"
	} else if result.Outcome == AutoSyncPublishedCurrent && result.Detail != "" {
		level = "warn"
	}
	s.autoSyncLog(ctx, level, "item_finished", "outcome", result.Outcome, "detail", safeAutoSyncDetail(result.Detail))
}

func (s *impl) autoSyncLogRound(ctx context.Context, report *AutoSyncReport, err error) {
	failed, published, skipped := 0, 0, 0
	if report != nil {
		for _, r := range report.Results {
			switch r.Outcome {
			case AutoSyncFailed:
				failed++
			case AutoSyncPublishedCurrent:
				published++
			default:
				skipped++
			}
		}
	}
	level, outcome, detail := "info", "completed", ""
	if err != nil {
		detail = safeAutoSyncDetail(err.Error())
		if errors.Is(err, dom.ErrAutoSyncRunning) || errors.Is(err, dom.ErrAutoSyncDisabled) {
			outcome = "skipped"
		} else {
			level, outcome = "error", "failed"
		}
	} else if failed > 0 {
		level, outcome = "error", "partial_failure"
	}
	if err == nil {
		if state, ok := ctx.Value(autoSyncLogKey{}).(*autoSyncLogState); ok {
			state.stage = "complete"
		}
	}
	s.autoSyncLog(ctx, level, "round_finished", "outcome", outcome, "failed", failed, "published", published, "skipped", skipped, "detail", detail)
}
