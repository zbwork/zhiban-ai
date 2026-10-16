package log

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Logger 简单包装 slog.Logger，统一字段命名。
type Logger struct {
	l *slog.Logger
}

var (
	defaultOnce sync.Once
	defaultLog  *Logger
)

// Default 返回全局默认 logger。
func Default() *Logger {
	defaultOnce.Do(func() {
		h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
		defaultLog = &Logger{l: slog.New(h)}
	})
	return defaultLog
}

// New 构造新 logger。format 取 "json"/"text"，level 取 debug/info/warn/error。
// 配置了 outputPath 时同时写 stdout 和文件，便于 PaaS 服务日志采集文件。
func New(format, level string, output ...string) *Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lvl}
	writer := logWriter(output...)
	var h slog.Handler
	if format == "text" {
		h = slog.NewTextHandler(writer, opts)
	} else {
		h = slog.NewJSONHandler(writer, opts)
	}
	logger := slog.New(h)
	slog.SetDefault(logger)
	return &Logger{l: logger}
}

func logWriter(output ...string) io.Writer {
	path := ""
	name := ""
	if len(output) > 0 {
		path = strings.TrimSpace(output[0])
	}
	if len(output) > 1 {
		name = strings.TrimSpace(output[1])
	}
	if path == "" {
		return os.Stdout
	}
	if name == "" {
		name = "agent-bus.log"
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "[agent-bus/log] WARN: create log path %q failed: %v\n", path, err)
		return os.Stdout
	}
	filePath := filepath.Join(path, name)
	f, err := os.OpenFile(filePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[agent-bus/log] WARN: open log file %q failed: %v\n", filePath, err)
		return os.Stdout
	}
	return io.MultiWriter(os.Stdout, f)
}

func (l *Logger) With(args ...any) *Logger { return &Logger{l: l.l.With(args...)} }

func (l *Logger) Debug(ctx context.Context, msg string, args ...any) {
	l.l.DebugContext(ctx, msg, args...)
}
func (l *Logger) Info(ctx context.Context, msg string, args ...any) {
	l.l.InfoContext(ctx, msg, args...)
}
func (l *Logger) Warn(ctx context.Context, msg string, args ...any) {
	l.l.WarnContext(ctx, msg, args...)
}
func (l *Logger) Error(ctx context.Context, msg string, args ...any) {
	l.l.ErrorContext(ctx, msg, args...)
}
