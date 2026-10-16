package zap

import (
	"context"
	"encoding/json"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
	repocalllog "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/calllog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// CallLogWriter writes runtime call log entries to the database.
type CallLogWriter struct {
	repo     *repocalllog.Repo
	redactor *redact.Redactor
}

// NewCallLogWriter creates a CallLogWriter backed by calllog.Repo + redact.Redactor.
func NewCallLogWriter(repo *repocalllog.Repo, redactor *redact.Redactor) *CallLogWriter {
	if repo == nil || redactor == nil {
		return nil
	}
	return &CallLogWriter{repo: repo, redactor: redactor}
}

// WriteHTTPCall records one HTTP call. It is intended for ZAP-related call sites
// that do not use Client/ChatClient directly (for example runtime_card probes).
func (w *CallLogWriter) WriteHTTPCall(
	ctx context.Context,
	meta *CallMetadata,
	targetService string,
	operation string,
	method string,
	path string,
	reqBody []byte,
	respBody []byte,
	httpStatus int,
	latencyMS int,
	errMsg string,
	tags map[string]any,
) {
	w.writeCallLog(ctx, meta, targetService, operation, method, path, reqBody, respBody, httpStatus, latencyMS, errMsg, tags)
}

// CallMetadata holds tenant/account context for log entries.
type CallMetadata struct {
	TenantID             int64
	AccountID            *int64
	RuntimeEnvironmentID *int64
	DigitalEmployeeID    *int64
	AgentUUID            string
	AgentKey             string
	SessionID            string
	ConversationUUID     string
	MessageUUID          string
	StreamID             string
}

// writeCallLog fires-and-forgets a call log entry. Never blocks the request path.
func (w *CallLogWriter) writeCallLog(
	ctx context.Context,
	meta *CallMetadata,
	targetService string,
	operation string,
	method string,
	path string,
	reqBody []byte,
	respBody []byte,
	httpStatus int,
	latencyMS int,
	errMsg string,
	tags map[string]any,
) {
	if w == nil || w.repo == nil || meta == nil {
		return
	}

	redactedReq, truncReq := w.redactor.RedactJSON(reqBody)
	redactedResp, truncResp := w.redactor.RedactJSON(respBody)

	traceID, spanID := traceIDs(ctx)
	logTags := map[string]any{}
	for k, v := range tags {
		logTags[k] = v
	}
	if meta.AgentUUID != "" {
		logTags["agent_id"] = meta.AgentUUID
	}
	if meta.AgentKey != "" {
		logTags["agent_key"] = meta.AgentKey
	}
	if meta.SessionID != "" {
		logTags["session_id"] = meta.SessionID
	}

	entry := &repocalllog.Entry{
		TenantID:             meta.TenantID,
		AccountID:            meta.AccountID,
		TraceID:              traceID,
		SpanID:               spanID,
		Direction:            "outbound",
		TargetService:        targetService,
		Operation:            operation,
		RuntimeEnvironmentID: meta.RuntimeEnvironmentID,
		DigitalEmployeeID:    meta.DigitalEmployeeID,
		ConversationUUID:     meta.ConversationUUID,
		MessageUUID:          meta.MessageUUID,
		StreamID:             meta.StreamID,
		Method:               method,
		Path:                 path,
		HTTPStatus:           intPtr(httpStatus),
		LatencyMS:            latencyMS,
		RequestBodyJSON:      json.RawMessage(redactedReq),
		ResponseBodyJSON:     json.RawMessage(redactedResp),
		BodyTruncated:        truncReq || truncResp,
		ErrorMessage:         errMsg,
		Tags:                 logTags,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	go func() {
		defer cancel()
		_ = w.repo.Insert(ctx, entry)
	}()
}

func startRuntimeHTTPSpan(ctx context.Context, targetService, operation, method, path string) (context.Context, trace.Span) {
	attrs := []attribute.KeyValue{
		attribute.String("http.request.method", method),
		attribute.String("url.path", path),
		attribute.String("agent_bus.target_service", targetService),
	}
	if operation != "" {
		attrs = append(attrs, attribute.String("agent_bus.operation", operation))
	}
	return otel.Tracer("agent-bus/runtime/"+targetService).Start(
		ctx,
		targetService+" "+method+" "+path,
		trace.WithAttributes(attrs...),
	)
}

func finishRuntimeHTTPSpan(span trace.Span, status int, errMsg string) {
	if span == nil {
		return
	}
	if status > 0 {
		span.SetAttributes(attribute.Int("http.response.status_code", status))
	}
	if errMsg != "" {
		span.RecordError(&runtimeCallError{msg: errMsg})
		span.SetStatus(codes.Error, errMsg)
	} else if status >= 400 {
		span.SetStatus(codes.Error, "http error")
	} else {
		span.SetStatus(codes.Ok, "")
	}
	span.End()
}

func traceIDs(ctx context.Context) (string, string) {
	if ctx == nil {
		return "", ""
	}
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return "", ""
	}
	return sc.TraceID().String(), sc.SpanID().String()
}

type runtimeCallError struct{ msg string }

func (e *runtimeCallError) Error() string { return e.msg }

func intPtr(v int) *int {
	if v == 0 {
		return nil
	}
	return &v
}
