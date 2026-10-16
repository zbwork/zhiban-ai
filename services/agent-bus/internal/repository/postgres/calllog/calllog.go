package calllog

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Entry struct {
	TenantID             int64
	AccountID            *int64
	TraceID              string
	SpanID               string
	Direction            string
	TargetService        string
	Operation            string
	RuntimeEnvironmentID *int64
	DigitalEmployeeID    *int64
	ConversationUUID     string
	MessageUUID          string
	StreamID             string
	Method               string
	Path                 string
	HTTPStatus           *int
	GRPCCode             *int
	LatencyMS            int
	RequestBodyJSON      json.RawMessage
	ResponseBodyJSON     json.RawMessage
	BodyTruncated        bool
	ErrorMessage         string
	Tags                 map[string]any
}

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const insertSQL = `
INSERT INTO runtime_call_logs
  (tenant_id, account_id, trace_id, span_id,
   direction, target_service, operation,
   runtime_environment_id, digital_employee_id, conversation_uuid, message_uuid, stream_id,
   method, path,
   http_status, grpc_code, latency_ms,
   request_body_json, response_body_json, body_truncated,
   error_message, tags)
VALUES ($1, $2, $3, $4,
        $5, $6, $7,
        $8, $9, $10, $11, $12,
        $13, $14,
        $15, $16, $17,
        $18::jsonb, $19::jsonb, $20,
        $21, $22::jsonb)`

func (r *Repo) Insert(ctx context.Context, e *Entry) error {
	reqBody := coalesceJSON(e.RequestBodyJSON)
	respBody := coalesceJSON(e.ResponseBodyJSON)
	tags := "{}"
	if e.Tags != nil {
		if b, err := json.Marshal(e.Tags); err == nil {
			tags = string(b)
		}
	}
	errMsg := e.ErrorMessage
	if len(errMsg) > 500 {
		errMsg = errMsg[:500]
	}

	_, err := r.pool.Exec(ctx, insertSQL,
		e.TenantID, e.AccountID, nilIfEmpty(e.TraceID), nilIfEmpty(e.SpanID),
		coalesceDir(e.Direction), e.TargetService, nilIfEmpty(e.Operation),
		e.RuntimeEnvironmentID, e.DigitalEmployeeID, nilIfEmpty(e.ConversationUUID), nilIfEmpty(e.MessageUUID), nilIfEmpty(e.StreamID),
		e.Method, e.Path,
		e.HTTPStatus, e.GRPCCode, e.LatencyMS,
		reqBody, respBody, e.BodyTruncated,
		nilIfEmpty(errMsg), tags,
	)
	return err
}

func coalesceJSON(b json.RawMessage) string {
	if len(b) == 0 {
		return "{}"
	}
	return string(b)
}

func coalesceDir(d string) string {
	if d == "" {
		return "outbound"
	}
	return d
}

func nilIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
