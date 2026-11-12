package admincore

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type AuditAdminHandler struct {
	Pool *pgxpool.Pool
}

type auditEventDTO struct {
	ID                 int64           `json:"id"`
	OccurredAt         string          `json:"occurredAt"`
	TenantID           *int64          `json:"tenantId,omitempty"`
	TenantName         string          `json:"tenantName,omitempty"`
	AccountID          *int64          `json:"accountId,omitempty"`
	AccountName        string          `json:"accountName,omitempty"`
	AccountUsername    string          `json:"accountUsername,omitempty"`
	ActorKind          string          `json:"actorKind"`
	ActingAs           string          `json:"actingAs,omitempty"`
	Domain             string          `json:"domain"`
	EventKind          string          `json:"eventKind"`
	Severity           string          `json:"severity"`
	ResourceKind       string          `json:"resourceKind,omitempty"`
	ResourceUUID       string          `json:"resourceUuid,omitempty"`
	BusinessObject     string          `json:"businessObject,omitempty"`
	ExecutorName       string          `json:"executorName,omitempty"`
	TargetAccountID    *int64          `json:"targetAccountId,omitempty"`
	TargetAccountName  string          `json:"targetAccountName,omitempty"`
	TargetResourceUUID string          `json:"targetResourceUuid,omitempty"`
	TraceID            string          `json:"traceId,omitempty"`
	IP                 string          `json:"ip,omitempty"`
	UserAgent          string          `json:"userAgent,omitempty"`
	Payload            json.RawMessage `json:"payload"`
	DurationMS         int32           `json:"durationMs"`
}

type auditDLQDTO struct {
	ID             int64           `json:"id"`
	Topic          string          `json:"topic"`
	TenantID       *int64          `json:"tenantId,omitempty"`
	TraceID        string          `json:"traceId,omitempty"`
	Payload        json.RawMessage `json:"payload"`
	Attempts       int16           `json:"attempts"`
	LastError      string          `json:"lastError,omitempty"`
	CreatedAt      string          `json:"createdAt"`
	DoneAt         string          `json:"doneAt,omitempty"`
	DLQAt          string          `json:"dlqAt,omitempty"`
	DLQReason      string          `json:"dlqReason,omitempty"`
	IdempotencyKey string          `json:"idempotencyKey,omitempty"`
}

type auditSummaryDTO struct {
	TodayTotal   int    `json:"todayTotal"`
	RiskTotal    int    `json:"riskTotal"`
	DLQTotal     int    `json:"dlqTotal"`
	PendingTotal int    `json:"pendingTotal"`
	FailedTotal  int    `json:"failedTotal"`
	LastAuditAt  string `json:"lastAuditAt,omitempty"`
}

var auditSystemEventKinds = []string{
	"audit.cron.run_started",
	"audit.cron.run_finished",
	"audit.cron.run_failed",
	"audit.cron.catchup_last_merged",
	"audit.cron.openclaw_run_finished",
}

func (h *AuditAdminHandler) getPlatformAuditSummary(w http.ResponseWriter, r *http.Request) {
	h.getAuditSummary(w, r, nil, true)
}

func (h *AuditAdminHandler) getTenantAuditSummary(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getAuditSummary(w, r, &tid, false)
}

func (h *AuditAdminHandler) getAuditSummary(w http.ResponseWriter, r *http.Request, fixedTenantID *int64, includeOutbox bool) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit admin not wired"))
		return
	}
	where := "WHERE occurred_at >= current_date"
	args := make([]any, 0, 1)
	if fixedTenantID != nil {
		args = append(args, *fixedTenantID)
		where += " AND tenant_id=$1"
	}

	var out auditSummaryDTO
	var last sql.NullTime
	if err := h.Pool.QueryRow(r.Context(), `
SELECT
  count(*)::int AS today_total,
  count(*) FILTER (WHERE severity IN ('warning','error','critical'))::int AS risk_total,
  max(occurred_at) AS last_audit_at
FROM audit_events
`+where, args...).Scan(&out.TodayTotal, &out.RiskTotal, &last); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if last.Valid {
		out.LastAuditAt = last.Time.UTC().Format(time.RFC3339)
	}
	if includeOutbox {
		if err := h.Pool.QueryRow(r.Context(), `
SELECT
  count(*) FILTER (WHERE status='dlq')::int AS dlq_total,
  count(*) FILTER (WHERE status='pending')::int AS pending_total,
  count(*) FILTER (WHERE status='failed')::int AS failed_total
FROM events_outbox
WHERE topic LIKE 'audit.%'`).Scan(&out.DLQTotal, &out.PendingTotal, &out.FailedTotal); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
	}
	encode.JSON(w, out)
}

func (h *AuditAdminHandler) listPlatformAuditEvents(w http.ResponseWriter, r *http.Request) {
	h.listAuditEvents(w, r, nil)
}

func (h *AuditAdminHandler) listTenantAuditEvents(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.listAuditEvents(w, r, &tid)
}

func (h *AuditAdminHandler) listAuditEvents(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit admin not wired"))
		return
	}
	q := r.URL.Query()
	limit, offset := auditLimitOffset(q.Get("limit"), q.Get("offset"))

	where := make([]string, 0, 10)
	args := make([]any, 0, 12)
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	if fixedTenantID != nil {
		add("ae.tenant_id =", *fixedTenantID)
	} else if v := strings.TrimSpace(q.Get("tenant_id")); v != "" {
		tid, err := strconv.ParseInt(v, 10, 64)
		if err != nil || tid <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id must be positive integer"))
			return
		}
		add("ae.tenant_id =", tid)
	}
	for _, f := range []struct {
		key string
		col string
	}{
		{"actor_kind", "ae.actor_kind ="},
		{"domain", "ae.domain ="},
		{"event_kind", "ae.event_kind ="},
		{"severity", "ae.severity ="},
		{"trace_id", "ae.trace_id ="},
	} {
		if v := strings.TrimSpace(q.Get(f.key)); v != "" {
			add(f.col, v)
		}
	}
	if v := strings.TrimSpace(q.Get("account_id")); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil || id <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("account_id must be positive integer"))
			return
		}
		add("ae.account_id =", id)
	}
	if v := strings.TrimSpace(q.Get("occurred_from")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("occurred_from: %v", err))
			return
		}
		add("ae.occurred_at >=", t.UTC())
	}
	if v := strings.TrimSpace(q.Get("occurred_to")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("occurred_to: %v", err))
			return
		}
		add("ae.occurred_at <=", t.UTC())
	}
	switch strings.TrimSpace(q.Get("category")) {
	case "", "all":
	case "operation":
		where = append(where, auditSystemEventPredicate("ae", false))
	case "system":
		where = append(where, auditSystemEventPredicate("ae", true))
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("category must be operation, system or all"))
		return
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		args = append(args, "%"+v+"%")
		n := "$" + strconv.Itoa(len(args))
		where = append(where, "(ae.domain ILIKE "+n+" OR ae.event_kind ILIKE "+n+" OR ae.resource_uuid ILIKE "+n+" OR ae.target_resource_uuid ILIKE "+n+" OR ae.trace_id ILIKE "+n+" OR ae.payload::text ILIKE "+n+" OR COALESCE(NULLIF(am.nickname,''), a.display_name, '') ILIKE "+n+" OR COALESCE(NULLIF(tam.nickname,''), ta.display_name, '') ILIKE "+n+" OR COALESCE(t.name,'') ILIKE "+n+" OR COALESCE(t.display_name,'') ILIKE "+n+" OR COALESCE(cj.name,'') ILIKE "+n+" OR COALESCE(de.name,'') ILIKE "+n+")")
	}

	whereSQL := ""
	if len(where) > 0 {
		whereSQL = "WHERE " + strings.Join(where, " AND ")
	}

	fromSQL := `
FROM audit_events ae
LEFT JOIN tenants t ON t.id = ae.tenant_id AND t.deleted_at IS NULL
LEFT JOIN accounts a ON a.id = ae.account_id AND a.deleted_at IS NULL
LEFT JOIN tenant_memberships am ON am.tenant_id = ae.tenant_id AND am.account_id = ae.account_id AND am.deleted_at IS NULL
LEFT JOIN accounts ta ON ta.id = ae.target_account_id AND ta.deleted_at IS NULL
LEFT JOIN tenant_memberships tam ON tam.tenant_id = ae.tenant_id AND tam.account_id = ae.target_account_id AND tam.deleted_at IS NULL
LEFT JOIN agent_cron_runs cr ON ae.resource_kind='agent_cron_run' AND cr.uuid::text = ae.resource_uuid
LEFT JOIN agent_cron_jobs cj ON (
  (ae.resource_kind='agent_cron_job' AND cj.uuid::text = ae.resource_uuid)
  OR cj.id = cr.job_id
  OR cj.uuid::text = ae.payload->>'job_uuid'
) AND cj.deleted_at IS NULL
LEFT JOIN digital_employees de ON de.id = COALESCE(cr.agent_id, cj.agent_id) AND de.deleted_at IS NULL
`
	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) `+fromSQL+whereSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, limit, offset)
	rows, err := h.Pool.Query(r.Context(), `
SELECT ae.id, ae.occurred_at, ae.tenant_id, COALESCE(NULLIF(t.display_name,''), t.name, '') AS tenant_name,
       ae.account_id, COALESCE(NULLIF(am.nickname,''), a.display_name, '') AS account_name, COALESCE(a.username, '') AS account_username,
       ae.actor_kind, ae.acting_as,
       ae.domain, ae.event_kind, ae.severity, ae.resource_kind, ae.resource_uuid,
       COALESCE(cj.name, '') AS business_object,
       COALESCE(de.name, '') AS executor_name,
       ae.target_account_id, COALESCE(NULLIF(tam.nickname,''), ta.display_name, '') AS target_account_name,
       ae.target_resource_uuid, ae.trace_id, ae.ip::text, ae.ua,
       ae.payload, ae.duration_ms
FROM audit_events ae
LEFT JOIN tenants t ON t.id = ae.tenant_id AND t.deleted_at IS NULL
LEFT JOIN accounts a ON a.id = ae.account_id AND a.deleted_at IS NULL
LEFT JOIN tenant_memberships am ON am.tenant_id = ae.tenant_id AND am.account_id = ae.account_id AND am.deleted_at IS NULL
LEFT JOIN accounts ta ON ta.id = ae.target_account_id AND ta.deleted_at IS NULL
LEFT JOIN tenant_memberships tam ON tam.tenant_id = ae.tenant_id AND tam.account_id = ae.target_account_id AND tam.deleted_at IS NULL
LEFT JOIN agent_cron_runs cr ON ae.resource_kind='agent_cron_run' AND cr.uuid::text = ae.resource_uuid
LEFT JOIN agent_cron_jobs cj ON (
  (ae.resource_kind='agent_cron_job' AND cj.uuid::text = ae.resource_uuid)
  OR cj.id = cr.job_id
  OR cj.uuid::text = ae.payload->>'job_uuid'
) AND cj.deleted_at IS NULL
LEFT JOIN digital_employees de ON de.id = COALESCE(cr.agent_id, cj.agent_id) AND de.deleted_at IS NULL
`+whereSQL+`
ORDER BY ae.occurred_at DESC, ae.id DESC
LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]auditEventDTO, 0, limit)
	for rows.Next() {
		var (
			item                            auditEventDTO
			occurredAt                      time.Time
			tenantID, accountID             sql.NullInt64
			targetAccountID                 sql.NullInt64
			tenantName, accountName         sql.NullString
			accountUsername, actingAs       sql.NullString
			resourceKind                    sql.NullString
			resourceUUID, businessObject    sql.NullString
			executorName, targetAccountName sql.NullString
			targetResource                  sql.NullString
			traceID, ip, ua                 sql.NullString
			payload                         []byte
		)
		if err := rows.Scan(&item.ID, &occurredAt, &tenantID, &tenantName, &accountID, &accountName, &accountUsername, &item.ActorKind, &actingAs,
			&item.Domain, &item.EventKind, &item.Severity, &resourceKind, &resourceUUID,
			&businessObject, &executorName,
			&targetAccountID, &targetAccountName, &targetResource, &traceID, &ip, &ua, &payload, &item.DurationMS); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		item.OccurredAt = occurredAt.UTC().Format(time.RFC3339)
		item.TenantID = ptrInt64(tenantID)
		item.TenantName = tenantName.String
		item.AccountID = ptrInt64(accountID)
		item.AccountName = auditCleanDisplayName(accountName.String)
		item.AccountUsername = accountUsername.String
		item.TargetAccountID = ptrInt64(targetAccountID)
		item.TargetAccountName = auditCleanDisplayName(targetAccountName.String)
		item.ActingAs = actingAs.String
		item.ResourceKind = resourceKind.String
		item.ResourceUUID = resourceUUID.String
		item.BusinessObject = businessObject.String
		item.ExecutorName = executorName.String
		item.TargetResourceUUID = targetResource.String
		item.TraceID = traceID.String
		item.IP = ip.String
		item.UserAgent = ua.String
		item.Payload = rawJSONOrObject(payload)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func auditCleanDisplayName(name string) string {
	n := strings.TrimSpace(name)
	if n == "" || strings.Contains(n, "的组织 管理员") || strings.HasPrefix(n, "预热优化") {
		return ""
	}
	return n
}

func (h *AuditAdminHandler) listAuditDLQ(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit admin not wired"))
		return
	}
	q := r.URL.Query()
	limit, offset := auditLimitOffset(q.Get("limit"), q.Get("offset"))
	where := []string{"o.status='dlq'"}
	args := make([]any, 0, 8)
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	if v := strings.TrimSpace(q.Get("topic")); v != "" {
		add("o.topic =", v)
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		args = append(args, "%"+v+"%")
		n := strconv.Itoa(len(args))
		where = append(where, "(o.topic ILIKE $"+n+" OR o.trace_id ILIKE $"+n+" OR o.last_error ILIKE $"+n+" OR o.payload::text ILIKE $"+n+")")
	}
	whereSQL := "WHERE " + strings.Join(where, " AND ")

	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM events_outbox o `+whereSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, limit, offset)
	rows, err := h.Pool.Query(r.Context(), `
SELECT o.id, o.topic, o.tenant_id, o.trace_id, o.payload, o.attempts,
       o.last_error, o.idempotency_key, o.created_at, o.done_at,
       d.dlq_at, d.dlq_reason
FROM events_outbox o
LEFT JOIN LATERAL (
  SELECT dlq_at, dlq_reason
  FROM events_outbox_dlq d
  WHERE d.outbox_id=o.id
  ORDER BY d.dlq_at DESC, d.id DESC
  LIMIT 1
) d ON true
`+whereSQL+`
ORDER BY COALESCE(d.dlq_at, o.done_at, o.created_at) DESC, o.id DESC
LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]auditDLQDTO, 0, limit)
	for rows.Next() {
		var (
			item                   auditDLQDTO
			tenantID               sql.NullInt64
			traceID, lastErr, idem sql.NullString
			payload                []byte
			createdAt              time.Time
			doneAt, dlqAt          sql.NullTime
			dlqReason              sql.NullString
		)
		if err := rows.Scan(&item.ID, &item.Topic, &tenantID, &traceID, &payload, &item.Attempts,
			&lastErr, &idem, &createdAt, &doneAt, &dlqAt, &dlqReason); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		item.TenantID = ptrInt64(tenantID)
		item.TraceID = traceID.String
		item.Payload = rawJSONOrObject(payload)
		item.LastError = lastErr.String
		item.IdempotencyKey = idem.String
		item.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		if doneAt.Valid {
			item.DoneAt = doneAt.Time.UTC().Format(time.RFC3339)
		}
		if dlqAt.Valid {
			item.DLQAt = dlqAt.Time.UTC().Format(time.RFC3339)
		}
		item.DLQReason = dlqReason.String
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (h *AuditAdminHandler) retryAuditDLQ(w http.ResponseWriter, r *http.Request) {
	h.updateAuditDLQ(w, r, "retry")
}

func (h *AuditAdminHandler) ignoreAuditDLQ(w http.ResponseWriter, r *http.Request) {
	h.updateAuditDLQ(w, r, "ignore")
}

func (h *AuditAdminHandler) updateAuditDLQ(w http.ResponseWriter, r *http.Request, action string) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit admin not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id must be positive integer"))
		return
	}
	tx, err := h.Pool.Begin(r.Context())
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer func() { _ = tx.Rollback(r.Context()) }()

	var topic string
	var payload []byte
	if err := tx.QueryRow(r.Context(), `SELECT topic, payload FROM events_outbox WHERE id=$1 AND status='dlq' FOR UPDATE`, id).Scan(&topic, &payload); err != nil {
		if err == pgx.ErrNoRows {
			encode.JSONError(w, apperr.ErrNotFound.Withf("dlq outbox not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	switch action {
	case "retry":
		_, err = tx.Exec(r.Context(), `
UPDATE events_outbox
SET status='pending', attempts=0, last_error=NULL, picked_at=NULL, done_at=NULL,
    next_retry_at=NULL, locked_by=NULL, locked_until=NULL
WHERE id=$1`, id)
	case "ignore":
		_, err = tx.Exec(r.Context(), `
UPDATE events_outbox
SET status='done', done_at=now(), locked_by=NULL, locked_until=NULL
WHERE id=$1`, id)
	default:
		err = apperr.ErrInvalidParams.Withf("unsupported action")
	}
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	if err := insertAuditDLQAdminEvent(r.Context(), tx, middleware.MustAccountID(r.Context()), action, id, topic, payload); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"id": id, "action": action, "ok": true})
}

func insertAuditDLQAdminEvent(ctx context.Context, tx pgx.Tx, actorID int64, action string, outboxID int64, topic string, payload []byte) error {
	eventKind := "audit.outbox." + action
	body, _ := json.Marshal(map[string]any{
		"outbox_id": outboxID,
		"topic":     topic,
		"action":    action,
		"payload":   json.RawMessage(rawJSONOrObject(payload)),
	})
	_, err := tx.Exec(ctx, `
INSERT INTO audit_events
  (occurred_at, account_id, actor_kind, domain, event_kind, severity,
   resource_kind, resource_uuid, payload, duration_ms)
VALUES
  (now(), $1, 'platform_admin', 'audit', $2, 'warning',
   'events_outbox', $3, $4::jsonb, 0)`,
		actorID, eventKind, strconv.FormatInt(outboxID, 10), string(body))
	return err
}

func auditLimitOffset(rawLimit, rawOffset string) (int, int) {
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

func auditSystemEventPredicate(alias string, positive bool) string {
	values := make([]string, 0, len(auditSystemEventKinds))
	for _, kind := range auditSystemEventKinds {
		values = append(values, "'"+strings.ReplaceAll(kind, "'", "''")+"'")
	}
	predicate := alias + ".event_kind IN (" + strings.Join(values, ",") + ")"
	if positive {
		return predicate
	}
	return "NOT (" + predicate + ")"
}

func ptrInt64(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

func rawJSONOrObject(b []byte) json.RawMessage {
	if len(b) == 0 || !json.Valid(b) {
		return json.RawMessage(`{}`)
	}
	return json.RawMessage(b)
}
