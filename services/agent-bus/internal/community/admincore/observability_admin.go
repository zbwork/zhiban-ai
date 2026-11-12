package admincore

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type ObservabilityCallLogsHandler struct {
	Pool *pgxpool.Pool
}

type callLogDTO struct {
	ID                   int64           `json:"id"`
	UUID                 string          `json:"uuid"`
	TenantID             *int64          `json:"tenantId,omitempty"`
	AccountID            *int64          `json:"accountId,omitempty"`
	TraceID              string          `json:"traceId,omitempty"`
	SpanID               string          `json:"spanId,omitempty"`
	Direction            string          `json:"direction"`
	TargetService        string          `json:"targetService"`
	Operation            string          `json:"operation,omitempty"`
	RuntimeEnvironmentID *int64          `json:"runtimeEnvironmentId,omitempty"`
	AgentID              *int64          `json:"agentId,omitempty"`
	AgentName            string          `json:"agentName,omitempty"`
	DigitalEmployeeID    *int64          `json:"digitalEmployeeId,omitempty"`
	DigitalEmployeeName  string          `json:"digitalEmployeeName,omitempty"`
	ConversationUUID     string          `json:"conversationUuid,omitempty"`
	MessageUUID          string          `json:"messageUuid,omitempty"`
	StreamID             string          `json:"streamId,omitempty"`
	Method               string          `json:"method"`
	Path                 string          `json:"path"`
	HTTPStatus           *int            `json:"httpStatus,omitempty"`
	GRPCCode             *int            `json:"grpcCode,omitempty"`
	LatencyMS            int             `json:"latencyMs"`
	RequestBodyJSON      json.RawMessage `json:"requestBodyJson"`
	ResponseBodyJSON     json.RawMessage `json:"responseBodyJson"`
	BodyTruncated        bool            `json:"bodyTruncated"`
	ErrorMessage         string          `json:"errorMessage,omitempty"`
	Tags                 json.RawMessage `json:"tags"`
	CreatedAt            string          `json:"createdAt"`
}

func (h *ObservabilityCallLogsHandler) listPlatformCallLogs(w http.ResponseWriter, r *http.Request) {
	h.listCallLogs(w, r, nil)
}

func (h *ObservabilityCallLogsHandler) listTenantCallLogs(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.listCallLogs(w, r, &tid)
}

func (h *ObservabilityCallLogsHandler) listCallLogs(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("observability not wired"))
		return
	}
	q := r.URL.Query()
	limit, offset := callLogLimitOffset(q.Get("limit"), q.Get("offset"))

	where := make([]string, 0, 8)
	args := make([]any, 0, 10)
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	if fixedTenantID != nil {
		add("cl.tenant_id =", *fixedTenantID)
	} else if v := strings.TrimSpace(q.Get("tenant_id")); v != "" {
		tid, err := strconv.ParseInt(v, 10, 64)
		if err != nil || tid <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id must be positive integer"))
			return
		}
		add("cl.tenant_id =", tid)
	}
	for _, f := range []struct {
		key string
		col string
	}{
		{"target_service", "cl.target_service ="},
		{"method", "cl.method ="},
		{"direction", "cl.direction ="},
		{"trace_id", "cl.trace_id ="},
		{"operation", "cl.operation ="},
		{"conversation_uuid", "cl.conversation_uuid ="},
		{"message_uuid", "cl.message_uuid ="},
		{"stream_id", "cl.stream_id ="},
	} {
		if v := strings.TrimSpace(q.Get(f.key)); v != "" {
			add(f.col, v)
		}
	}
	for _, f := range []struct {
		key string
		col string
	}{
		{"runtime_environment_id", "cl.runtime_environment_id ="},
		{"agent_id", "cl.digital_employee_id ="},
	} {
		if v := strings.TrimSpace(q.Get(f.key)); v != "" {
			id, err := strconv.ParseInt(v, 10, 64)
			if err != nil || id <= 0 {
				encode.JSONError(w, apperr.ErrInvalidParams.Withf("%s must be positive integer", f.key))
				return
			}
			add(f.col, id)
		}
	}
	if v := strings.TrimSpace(q.Get("digital_employee_id")); v != "" && strings.TrimSpace(q.Get("agent_id")) == "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil || id <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("digital_employee_id must be positive integer"))
			return
		}
		add("cl.digital_employee_id =", id)
	}
	if v := firstNonBlank(q.Get("agent_name"), q.Get("digital_employee_name")); v != "" {
		args = append(args, "%"+v+"%")
		where = append(where, "de.name ILIKE $"+strconv.Itoa(len(args)))
	}
	if v := strings.TrimSpace(q.Get("http_status")); v != "" {
		status, err := strconv.Atoi(v)
		if err != nil || status < 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("http_status must be non-negative integer"))
			return
		}
		add("cl.http_status =", status)
	}
	if v := strings.TrimSpace(q.Get("from")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("from: %v", err))
			return
		}
		add("cl.created_at >=", t.UTC())
	}
	if v := strings.TrimSpace(q.Get("to")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("to: %v", err))
			return
		}
		add("cl.created_at <=", t.UTC())
	}
	if v := strings.TrimSpace(q.Get("errors_only")); v == "true" || v == "1" {
		where = append(where, "cl.error_message IS NOT NULL AND cl.error_message != ''")
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		args = append(args, "%"+v+"%")
		n := "$" + strconv.Itoa(len(args))
		where = append(where, "(cl.path ILIKE "+n+" OR cl.target_service ILIKE "+n+" OR cl.operation ILIKE "+n+" OR cl.error_message ILIKE "+n+" OR cl.trace_id ILIKE "+n+" OR cl.digital_employee_id::text ILIKE "+n+" OR de.name ILIKE "+n+" OR cl.message_uuid::text ILIKE "+n+" OR cl.stream_id ILIKE "+n+")")
	}

	whereSQL := ""
	if len(where) > 0 {
		whereSQL = "WHERE " + strings.Join(where, " AND ")
	}
	joinSQL := "LEFT JOIN digital_employees de ON de.id = cl.digital_employee_id"

	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM runtime_call_logs cl `+joinSQL+` `+whereSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, limit, offset)
	rows, err := h.Pool.Query(r.Context(), `
SELECT cl.id, cl.uuid, cl.tenant_id, cl.account_id,
       cl.trace_id, cl.span_id, cl.direction, cl.target_service,
       cl.operation, cl.runtime_environment_id, cl.digital_employee_id,
       COALESCE(de.name, ''),
       cl.conversation_uuid, cl.message_uuid, cl.stream_id,
       cl.method, cl.path, cl.http_status, cl.grpc_code, cl.latency_ms,
       cl.request_body_json, cl.response_body_json, cl.body_truncated,
       cl.error_message, cl.tags, cl.created_at
FROM runtime_call_logs cl `+joinSQL+` `+whereSQL+`
ORDER BY cl.created_at DESC, cl.id DESC
LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]callLogDTO, 0, limit)
	for rows.Next() {
		item, err := scanCallLogRow(rows)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (h *ObservabilityCallLogsHandler) getPlatformCallLogDetail(w http.ResponseWriter, r *http.Request) {
	h.getCallLogDetail(w, r, nil)
}

func (h *ObservabilityCallLogsHandler) getTenantCallLogDetail(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getCallLogDetail(w, r, &tid)
}

func (h *ObservabilityCallLogsHandler) getCallLogDetail(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("observability not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	args := []any{uuid}
	tenantFilter := ""
	if fixedTenantID != nil {
		args = append(args, *fixedTenantID)
		tenantFilter = " AND cl.tenant_id = $2"
	}
	row := h.Pool.QueryRow(r.Context(), `
SELECT cl.id, cl.uuid, cl.tenant_id, cl.account_id,
       cl.trace_id, cl.span_id, cl.direction, cl.target_service,
       cl.operation, cl.runtime_environment_id, cl.digital_employee_id,
       COALESCE(de.name, ''),
       cl.conversation_uuid, cl.message_uuid, cl.stream_id,
       cl.method, cl.path, cl.http_status, cl.grpc_code, cl.latency_ms,
       cl.request_body_json, cl.response_body_json, cl.body_truncated,
       cl.error_message, cl.tags, cl.created_at
FROM runtime_call_logs cl
LEFT JOIN digital_employees de ON de.id = cl.digital_employee_id
WHERE cl.uuid = $1`+tenantFilter, args...)
	item, err := scanCallLogSingleRow(row)
	if err != nil {
		encode.JSONError(w, apperr.ErrNotFound.Withf("call log not found"))
		return
	}
	encode.JSON(w, item)
}

func (h *ObservabilityCallLogsHandler) getPlatformCallLogTimeline(w http.ResponseWriter, r *http.Request) {
	h.getCallLogTimeline(w, r, nil)
}

func (h *ObservabilityCallLogsHandler) getTenantCallLogTimeline(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getCallLogTimeline(w, r, &tid)
}

func (h *ObservabilityCallLogsHandler) getCallLogTimeline(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("observability not wired"))
		return
	}
	q := r.URL.Query()
	args := make([]any, 0, 4)
	where := make([]string, 0, 3)
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	switch {
	case strings.TrimSpace(q.Get("trace_id")) != "":
		add("cl.trace_id =", strings.TrimSpace(q.Get("trace_id")))
	case strings.TrimSpace(q.Get("message_uuid")) != "":
		add("cl.message_uuid =", strings.TrimSpace(q.Get("message_uuid")))
	case strings.TrimSpace(q.Get("stream_id")) != "":
		add("cl.stream_id =", strings.TrimSpace(q.Get("stream_id")))
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("trace_id/message_uuid/stream_id required"))
		return
	}
	if fixedTenantID != nil {
		add("cl.tenant_id =", *fixedTenantID)
	}
	rows, err := h.Pool.Query(r.Context(), `
SELECT cl.id, cl.uuid, cl.tenant_id, cl.account_id,
       cl.trace_id, cl.span_id, cl.direction, cl.target_service,
       cl.operation, cl.runtime_environment_id, cl.digital_employee_id,
       COALESCE(de.name, ''),
       cl.conversation_uuid, cl.message_uuid, cl.stream_id,
       cl.method, cl.path, cl.http_status, cl.grpc_code, cl.latency_ms,
       cl.request_body_json, cl.response_body_json, cl.body_truncated,
       cl.error_message, cl.tags, cl.created_at
FROM runtime_call_logs cl
LEFT JOIN digital_employees de ON de.id = cl.digital_employee_id
WHERE `+strings.Join(where, " AND ")+`
ORDER BY cl.created_at ASC, cl.id ASC
LIMIT 200`, args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]callLogDTO, 0, 20)
	for rows.Next() {
		item, err := scanCallLogRow(rows)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

type callLogScanner interface {
	Scan(dest ...any) error
}

func scanCallLogFields(s callLogScanner) (callLogDTO, error) {
	var (
		item                                    callLogDTO
		tenantID, accountID                     sql.NullInt64
		traceID, spanID                         sql.NullString
		operation                               sql.NullString
		runtimeEnvID, digitalEmployeeID         sql.NullInt64
		digitalEmployeeName                     sql.NullString
		conversationUUID, messageUUID, streamID sql.NullString
		httpStatus, grpcCode                    sql.NullInt32
		errMsg                                  sql.NullString
		reqBody, respBody                       []byte
		tags                                    []byte
		createdAt                               time.Time
	)
	if err := s.Scan(
		&item.ID, &item.UUID, &tenantID, &accountID,
		&traceID, &spanID, &item.Direction, &item.TargetService,
		&operation, &runtimeEnvID, &digitalEmployeeID,
		&digitalEmployeeName,
		&conversationUUID, &messageUUID, &streamID,
		&item.Method, &item.Path, &httpStatus, &grpcCode, &item.LatencyMS,
		&reqBody, &respBody, &item.BodyTruncated,
		&errMsg, &tags, &createdAt,
	); err != nil {
		return callLogDTO{}, err
	}
	item.TenantID = ptrInt64(tenantID)
	item.AccountID = ptrInt64(accountID)
	item.TraceID = traceID.String
	item.SpanID = spanID.String
	item.Operation = operation.String
	item.RuntimeEnvironmentID = ptrInt64(runtimeEnvID)
	item.DigitalEmployeeID = ptrInt64(digitalEmployeeID)
	item.AgentID = item.DigitalEmployeeID
	item.DigitalEmployeeName = digitalEmployeeName.String
	item.AgentName = item.DigitalEmployeeName
	item.ConversationUUID = conversationUUID.String
	item.MessageUUID = messageUUID.String
	item.StreamID = streamID.String
	if httpStatus.Valid {
		v := int(httpStatus.Int32)
		item.HTTPStatus = &v
	}
	if grpcCode.Valid {
		v := int(grpcCode.Int32)
		item.GRPCCode = &v
	}
	item.ErrorMessage = errMsg.String
	item.RequestBodyJSON = rawJSONOrObject(reqBody)
	item.ResponseBodyJSON = rawJSONOrObject(respBody)
	item.Tags = rawJSONOrObject(tags)
	item.CreatedAt = createdAt.UTC().Format(time.RFC3339)
	return item, nil
}

type pgxRows interface {
	Scan(dest ...any) error
}

func scanCallLogRow(rows pgxRows) (callLogDTO, error) {
	return scanCallLogFields(rows)
}

func scanCallLogSingleRow(row pgxRows) (callLogDTO, error) {
	return scanCallLogFields(row)
}

func callLogLimitOffset(rawLimit, rawOffset string) (int, int) {
	limit, _ := strconv.Atoi(rawLimit)
	offset, _ := strconv.Atoi(rawOffset)
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	return limit, offset
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}
