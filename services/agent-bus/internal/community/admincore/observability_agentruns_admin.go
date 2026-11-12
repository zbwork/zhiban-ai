// observability_agentruns_admin.go — F24 P0: Agent 运行监测 admin API (L2 轨迹层)。
//
// 路由 (platform 可跨租户 + 可选 tenant_id 过滤; tenant 强制 MustTenantID):
//
//	GET {scope}/observability/agent-runs                 列表
//	GET {scope}/observability/agent-runs/stats           聚合统计 (窗口 ≤92 天)
//	GET {scope}/observability/agent-runs/{uuid}          详情 (含 steps + 计费口径参考)
//	GET {scope}/observability/agent-runs/{uuid}/chain    A2A 链路树 (include_payloads=true 需 L3 权限 + 留痕)
//
// L2 出参是**封闭字段集合** (F24 §6.3a): 绝不 SELECT * 直出, error_message 落库前已
// redact, attrs/tags 白名单在写入侧保证 — 本层再不透传 attrs 原文之外的任何自由字段。
package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
	repoevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// ObservabilityAgentRunsHandler serves F24 agent-run observability admin APIs.
type ObservabilityAgentRunsHandler struct {
	Pool     *pgxpool.Pool
	EventPub domevent.Publisher // content_viewed 审计 (fail-closed; nil → L3 接口 503)
	Redactor *redact.Redactor   // L3 blocks 渲染前兜底脱敏
}

const agentRunMaxWindow = 92 * 24 * time.Hour

// ---- DTOs (closed field set) ----

type agentRunListItemDTO struct {
	UUID              string `json:"uuid"`
	StartedAt         string `json:"startedAt"`
	TenantID          int64  `json:"tenantId"`
	TenantName        string `json:"tenantName,omitempty"` // platform scope only
	DigitalEmployeeID int64  `json:"digitalEmployeeId"`
	AgentName         string `json:"agentName"`
	AccountID         *int64 `json:"accountId,omitempty"`
	AccountName       string `json:"accountName,omitempty"`
	RuntimeKind       string `json:"runtimeKind"`
	TriggerSource     string `json:"triggerSource"`
	Status            string `json:"status"`
	DurationMS        *int   `json:"durationMs,omitempty"`
	FirstOutputMS     *int   `json:"firstOutputMs,omitempty"`
	ThinkingMS        *int   `json:"thinkingMs,omitempty"`
	HITLWaitMS        *int   `json:"hitlWaitMs,omitempty"`
	ToolCallCount     int    `json:"toolCallCount"`
	ToolErrorCount    int    `json:"toolErrorCount"`
	A2AEdgeCount      int    `json:"a2aEdgeCount"`
	TotalTokens       *int64 `json:"totalTokens,omitempty"`
	UsageSource       string `json:"usageSource"`
	Model             string `json:"model,omitempty"`
	AgentVersion      *int   `json:"agentVersion,omitempty"`
	ErrorCode         string `json:"errorCode,omitempty"`
	ConversationUUID  string `json:"conversationUuid,omitempty"`
	MessageUUID       string `json:"messageUuid"`
	TraceID           string `json:"traceId,omitempty"`
	Backfilled        bool   `json:"backfilled,omitempty"`
}

type agentRunStepDTO struct {
	Seq          int    `json:"seq"`
	Kind         string `json:"stepKind"`
	Name         string `json:"name,omitempty"`
	Status       string `json:"status"`
	StartedAt    string `json:"startedAt"`
	DurationMS   *int   `json:"durationMs,omitempty"`
	RefKind      string `json:"refKind,omitempty"`
	RefUUID      string `json:"refUuid,omitempty"`
	ErrorMessage string `json:"errorMessage,omitempty"`
}

type agentRunDetailDTO struct {
	Run          agentRunListItemDTO `json:"run"`
	InputTokens  *int64              `json:"inputTokens,omitempty"`
	OutputTokens *int64              `json:"outputTokens,omitempty"`
	ErrorMessage string              `json:"errorMessage,omitempty"`
	RoomID       *int64              `json:"roomId,omitempty"`
	Steps        []agentRunStepDTO   `json:"steps"`
	BillingUsage *billingUsageDTO    `json:"billingUsage,omitempty"`
	Links        agentRunLinksDTO    `json:"links"`
}

type billingUsageDTO struct {
	MatchedLevel string `json:"matchedLevel"` // message / agent_day
	TotalTokens  int64  `json:"totalTokens"`
	Credits      int64  `json:"credits"`
}

type agentRunLinksDTO struct {
	ConversationUUID string   `json:"conversationUuid,omitempty"`
	TraceID          string   `json:"traceId,omitempty"`
	A2AEdges         []string `json:"a2aEdges"`
	ContentAvailable bool     `json:"contentAvailable"`
	RootA2AEdgeUUID  string   `json:"rootA2aEdgeUuid,omitempty"`
}

// ---- helpers ----

func adminHasPerm(r *http.Request, code string) bool {
	claims, ok := middleware.Claims(r.Context())
	if !ok || claims == nil {
		return false
	}
	for _, p := range claims.Perms {
		if p == code {
			return true
		}
	}
	return false
}

// parseRunWindow parses from/to with defaults (last 24h) and the 92-day cap
// (F24 §4.3 聚合性能策略).
func parseRunWindow(q map[string][]string) (time.Time, time.Time, error) {
	get := func(k string) string {
		if v, ok := q[k]; ok && len(v) > 0 {
			return strings.TrimSpace(v[0])
		}
		return ""
	}
	now := time.Now()
	from, to := now.Add(-24*time.Hour), now
	if v := get("from"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return from, to, apperr.ErrInvalidParams.Withf("from: %v", err)
		}
		from = t
	}
	if v := get("to"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return from, to, apperr.ErrInvalidParams.Withf("to: %v", err)
		}
		to = t
	}
	if !to.After(from) {
		return from, to, apperr.ErrInvalidParams.Withf("to must be after from")
	}
	if to.Sub(from) > agentRunMaxWindow {
		return from, to, apperr.ErrInvalidParams.Withf("window exceeds 92 days (F24 §4.3)")
	}
	return from, to, nil
}

func runTagsVersion(tags []byte) *int {
	if len(tags) == 0 {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(tags, &m) != nil {
		return nil
	}
	if v, ok := m["agent_version"].(float64); ok && v > 0 {
		n := int(v)
		return &n
	}
	return nil
}

func runTagsBackfilled(tags []byte) bool {
	if len(tags) == 0 {
		return false
	}
	var m map[string]any
	if json.Unmarshal(tags, &m) != nil {
		return false
	}
	b, _ := m["backfilled"].(bool)
	return b
}

// ---- list ----

func (h *ObservabilityAgentRunsHandler) listPlatformRuns(w http.ResponseWriter, r *http.Request) {
	h.listRuns(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) listTenantRuns(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.listRuns(w, r, &tid)
}

const agentRunSelectCols = `
ar.uuid, ar.tenant_id, t.name,
ar.digital_employee_id, COALESCE(de.name, '已删除员工'),
ar.account_id, COALESCE(NULLIF(acc.display_name,''), acc.username, acc.email, ''),
ar.runtime_kind, ar.trigger_source, ar.status,
ar.started_at, ar.duration_ms, ar.first_output_ms, ar.thinking_ms, ar.hitl_wait_ms,
ar.tool_call_count, ar.tool_error_count, ar.a2a_edge_count,
ar.total_tokens, ar.usage_source, COALESCE(ar.model, ''),
COALESCE(ar.error_code, ''), COALESCE(ar.conversation_uuid::text, ''), ar.message_uuid::text,
COALESCE(ar.trace_id, ''), ar.tags`

const agentRunFromJoin = `
FROM agent_runs ar
JOIN tenants t ON t.id = ar.tenant_id
LEFT JOIN digital_employees de ON de.id = ar.digital_employee_id
LEFT JOIN accounts acc ON acc.id = ar.account_id`

func scanRunListItem(row pgx.Row, platformScope bool) (*agentRunListItemDTO, error) {
	var it agentRunListItemDTO
	var startedAt time.Time
	var tags []byte
	if err := row.Scan(
		&it.UUID, &it.TenantID, &it.TenantName,
		&it.DigitalEmployeeID, &it.AgentName,
		&it.AccountID, &it.AccountName,
		&it.RuntimeKind, &it.TriggerSource, &it.Status,
		&startedAt, &it.DurationMS, &it.FirstOutputMS, &it.ThinkingMS, &it.HITLWaitMS,
		&it.ToolCallCount, &it.ToolErrorCount, &it.A2AEdgeCount,
		&it.TotalTokens, &it.UsageSource, &it.Model,
		&it.ErrorCode, &it.ConversationUUID, &it.MessageUUID,
		&it.TraceID, &tags,
	); err != nil {
		return nil, err
	}
	it.StartedAt = startedAt.Format(time.RFC3339)
	it.AgentVersion = runTagsVersion(tags)
	it.Backfilled = runTagsBackfilled(tags)
	if !platformScope {
		it.TenantName = ""
	}
	return &it, nil
}

func (h *ObservabilityAgentRunsHandler) listRuns(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	q := r.URL.Query()
	from, to, err := parseRunWindow(q)
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	where := []string{}
	args := []any{}
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	add("ar.started_at >=", from)
	add("ar.started_at <", to)
	if fixedTenantID != nil {
		add("ar.tenant_id =", *fixedTenantID)
	} else if v := strings.TrimSpace(q.Get("tenant_id")); v != "" {
		tid, perr := strconv.ParseInt(v, 10, 64)
		if perr != nil || tid <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id invalid"))
			return
		}
		add("ar.tenant_id =", tid)
	}
	if v := strings.TrimSpace(q.Get("digital_employee_id")); v != "" {
		id, perr := strconv.ParseInt(v, 10, 64)
		if perr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("digital_employee_id invalid"))
			return
		}
		add("ar.digital_employee_id =", id)
	}
	if v := strings.TrimSpace(q.Get("account_id")); v != "" {
		id, perr := strconv.ParseInt(v, 10, 64)
		if perr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("account_id invalid"))
			return
		}
		add("ar.account_id =", id)
	}
	for param, col := range map[string]string{
		"runtime_kind":   "ar.runtime_kind =",
		"trigger_source": "ar.trigger_source =",
		"status":         "ar.status =",
		"model":          "ar.model =",
	} {
		if v := strings.TrimSpace(q.Get(param)); v != "" {
			add(col, v)
		}
	}
	if v := strings.TrimSpace(q.Get("conversation_uuid")); v != "" {
		add("ar.conversation_uuid =", v)
	}
	if v := strings.TrimSpace(q.Get("min_duration_ms")); v != "" {
		n, perr := strconv.Atoi(v)
		if perr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("min_duration_ms invalid"))
			return
		}
		add("ar.duration_ms >=", n)
	}
	if q.Get("errors_only") == "true" {
		where = append(where, "ar.status = 'failed'")
	}
	if q.Get("has_tool_error") == "true" {
		where = append(where, "ar.tool_error_count > 0")
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		add("de.name ILIKE", "%"+v+"%")
	}

	limit := 50
	if v, perr := strconv.Atoi(q.Get("limit")); perr == nil && v > 0 && v <= 200 {
		limit = v
	}
	offset := 0
	if v, perr := strconv.Atoi(q.Get("offset")); perr == nil && v > 0 {
		offset = v
	}

	whereSQL := " WHERE " + strings.Join(where, " AND ")
	ctx := r.Context()

	var total int64
	if err := h.Pool.QueryRow(ctx, "SELECT count(*) "+agentRunFromJoin+whereSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("count runs: %v", err))
		return
	}

	args = append(args, limit, offset)
	rows, err := h.Pool.Query(ctx,
		"SELECT "+agentRunSelectCols+agentRunFromJoin+whereSQL+
			" ORDER BY ar.started_at DESC LIMIT $"+strconv.Itoa(len(args)-1)+" OFFSET $"+strconv.Itoa(len(args)),
		args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("list runs: %v", err))
		return
	}
	defer rows.Close()

	items := make([]agentRunListItemDTO, 0, limit)
	for rows.Next() {
		it, serr := scanRunListItem(rows, fixedTenantID == nil)
		if serr != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan run: %v", serr))
			return
		}
		items = append(items, *it)
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}

// ---- detail ----

func (h *ObservabilityAgentRunsHandler) getPlatformRunDetail(w http.ResponseWriter, r *http.Request) {
	h.getRunDetail(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) getTenantRunDetail(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getRunDetail(w, r, &tid)
}

func (h *ObservabilityAgentRunsHandler) getRunDetail(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	uuid := strings.TrimSpace(r.PathValue("uuid"))
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	ctx := r.Context()

	where := " WHERE ar.uuid = $1"
	args := []any{uuid}
	if fixedTenantID != nil {
		where += " AND ar.tenant_id = $2"
		args = append(args, *fixedTenantID)
	}
	row := h.Pool.QueryRow(ctx,
		"SELECT "+agentRunSelectCols+", ar.input_tokens, ar.output_tokens, COALESCE(ar.error_message,''), ar.room_id, COALESCE(ar.root_a2a_edge_uuid::text,''), ar.created_at "+
			agentRunFromJoin+where, args...)

	var it agentRunListItemDTO
	var startedAt, createdAt time.Time
	var tags []byte
	var inputTokens, outputTokens *int64
	var errMsg string
	var roomID *int64
	var rootEdge string
	if err := row.Scan(
		&it.UUID, &it.TenantID, &it.TenantName,
		&it.DigitalEmployeeID, &it.AgentName,
		&it.AccountID, &it.AccountName,
		&it.RuntimeKind, &it.TriggerSource, &it.Status,
		&startedAt, &it.DurationMS, &it.FirstOutputMS, &it.ThinkingMS, &it.HITLWaitMS,
		&it.ToolCallCount, &it.ToolErrorCount, &it.A2AEdgeCount,
		&it.TotalTokens, &it.UsageSource, &it.Model,
		&it.ErrorCode, &it.ConversationUUID, &it.MessageUUID,
		&it.TraceID, &tags,
		&inputTokens, &outputTokens, &errMsg, &roomID, &rootEdge, &createdAt,
	); err != nil {
		if err == pgx.ErrNoRows {
			encode.JSONError(w, apperr.ErrNotFound.Withf("run not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Withf("get run: %v", err))
		return
	}
	it.StartedAt = startedAt.Format(time.RFC3339)
	it.AgentVersion = runTagsVersion(tags)
	it.Backfilled = runTagsBackfilled(tags)
	if fixedTenantID != nil {
		it.TenantName = ""
	}

	// steps
	steps, edges, err := h.loadSteps(ctx, it.TenantID, it.UUID, createdAt)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("load steps: %v", err))
		return
	}

	// 计费口径参考 (F24 §2.5 双口径; message 级优先, 查不到落 agent_day)
	billing := h.loadBillingUsage(ctx, it.TenantID, it.DigitalEmployeeID, it.MessageUUID, startedAt)

	contentPerm := "tenant.observability.content.read"
	if fixedTenantID == nil {
		contentPerm = "platform.observability.content.read"
	}
	detail := agentRunDetailDTO{
		Run:          it,
		InputTokens:  inputTokens,
		OutputTokens: outputTokens,
		ErrorMessage: errMsg,
		RoomID:       roomID,
		Steps:        steps,
		BillingUsage: billing,
		Links: agentRunLinksDTO{
			ConversationUUID: it.ConversationUUID,
			TraceID:          it.TraceID,
			A2AEdges:         edges,
			ContentAvailable: adminHasPerm(r, contentPerm) && it.ConversationUUID != "",
			RootA2AEdgeUUID:  rootEdge,
		},
	}
	encode.JSON(w, detail)
}

func (h *ObservabilityAgentRunsHandler) loadSteps(ctx context.Context, tenantID int64, runUUID string, runCreatedAt time.Time) ([]agentRunStepDTO, []string, error) {
	rows, err := h.Pool.Query(ctx, `
SELECT seq, step_kind, name, status, started_at, duration_ms,
       COALESCE(ref_kind,''), COALESCE(ref_uuid,''), COALESCE(error_message,'')
FROM agent_run_steps
WHERE tenant_id = $1 AND run_uuid = $2 AND created_at = $3
ORDER BY seq`, tenantID, runUUID, runCreatedAt)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	steps := []agentRunStepDTO{}
	edges := []string{}
	for rows.Next() {
		var st agentRunStepDTO
		var startedAt time.Time
		if err := rows.Scan(&st.Seq, &st.Kind, &st.Name, &st.Status, &startedAt, &st.DurationMS,
			&st.RefKind, &st.RefUUID, &st.ErrorMessage); err != nil {
			return nil, nil, err
		}
		st.StartedAt = startedAt.Format(time.RFC3339)
		steps = append(steps, st)
		if st.RefKind == "a2a_edge" && st.RefUUID != "" {
			edges = append(edges, st.RefUUID)
		}
	}
	return steps, edges, rows.Err()
}

// loadBillingUsage best-effort joins usage_events: message 级精确归因优先
// (F24 P0 提取列, 仅新数据), 否则该 agent 当日汇总。查询失败返回 nil (展示层显示 "—")。
func (h *ObservabilityAgentRunsHandler) loadBillingUsage(ctx context.Context, tenantID, agentID int64, messageUUID string, startedAt time.Time) *billingUsageDTO {
	var tokens, credits int64
	err := h.Pool.QueryRow(ctx, `
SELECT COALESCE(SUM(amount),0), COALESCE(SUM(credits_cost),0)
FROM usage_events
WHERE tenant_id = $1 AND message_uuid = $2 AND resource_type = 'llm_tokens'`,
		tenantID, messageUUID).Scan(&tokens, &credits)
	if err == nil && tokens > 0 {
		return &billingUsageDTO{MatchedLevel: "message", TotalTokens: tokens, Credits: credits}
	}
	dayStart := startedAt.Truncate(24 * time.Hour)
	err = h.Pool.QueryRow(ctx, `
SELECT COALESCE(SUM(amount),0), COALESCE(SUM(credits_cost),0)
FROM usage_events
WHERE tenant_id = $1 AND agent_id = $2 AND resource_type = 'llm_tokens'
  AND created_at >= $3 AND created_at < $4`,
		tenantID, agentID, dayStart, dayStart.Add(24*time.Hour)).Scan(&tokens, &credits)
	if err != nil || tokens == 0 {
		return nil
	}
	return &billingUsageDTO{MatchedLevel: "agent_day", TotalTokens: tokens, Credits: credits}
}

// ---- stats ----

func (h *ObservabilityAgentRunsHandler) getPlatformRunStats(w http.ResponseWriter, r *http.Request) {
	h.getRunStats(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) getTenantRunStats(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getRunStats(w, r, &tid)
}

type runStatsTotalsDTO struct {
	Runs             int64    `json:"runs"`
	Completed        int64    `json:"completed"`
	Failed           int64    `json:"failed"`
	Cancelled        int64    `json:"cancelled"`
	AwaitingUser     int64    `json:"awaitingUser"`
	SuccessRate      *float64 `json:"successRate"`
	Conversations    int64    `json:"conversations"`
	P50DurationMS    *int     `json:"p50DurationMs"`
	P95DurationMS    *int     `json:"p95DurationMs"`
	AvgThinkingMS    *int     `json:"avgThinkingMs"`
	ThinkingCoverage *float64 `json:"thinkingCoverage"` // F24 覆盖度披露 (codex P2)
	TotalTokens      int64    `json:"totalTokens"`
	TokenCoverage    *float64 `json:"tokenCoverage"`
}

type runStatsBucketDTO struct {
	Key         string `json:"key"`
	Runs        int64  `json:"runs"`
	Completed   int64  `json:"completed"`
	Failed      int64  `json:"failed"`
	TotalTokens int64  `json:"totalTokens"`
}

type slowestToolDTO struct {
	Name          string `json:"name"`
	Calls         int64  `json:"calls"`
	AvgDurationMS int    `json:"avgDurationMs"`
	ErrorCount    int64  `json:"errorCount"`
}

func (h *ObservabilityAgentRunsHandler) getRunStats(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	q := r.URL.Query()
	from, to, err := parseRunWindow(q)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	groupBy := strings.TrimSpace(q.Get("group_by"))
	if groupBy == "" {
		groupBy = "day"
	}
	if groupBy != "day" && groupBy != "digital_employee" && groupBy != "runtime_kind" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("group_by must be day|digital_employee|runtime_kind"))
		return
	}

	where := "WHERE ar.started_at >= $1 AND ar.started_at < $2"
	args := []any{from, to}
	var tenantID *int64
	if fixedTenantID != nil {
		tenantID = fixedTenantID
	} else if v := strings.TrimSpace(q.Get("tenant_id")); v != "" {
		tid, perr := strconv.ParseInt(v, 10, 64)
		if perr != nil || tid <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id invalid"))
			return
		}
		tenantID = &tid
	}
	if tenantID != nil {
		args = append(args, *tenantID)
		where += " AND ar.tenant_id = $" + strconv.Itoa(len(args))
	}
	if fixedTenantID == nil && groupBy == "digital_employee" && tenantID == nil {
		// F24 §4.3: 平台侧按数字员工分组必须先选定租户 (跨租户 agent 排行走 P1 日聚合)。
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("group_by=digital_employee requires tenant_id on platform scope"))
		return
	}
	if v := strings.TrimSpace(q.Get("digital_employee_id")); v != "" {
		id, perr := strconv.ParseInt(v, 10, 64)
		if perr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("digital_employee_id invalid"))
			return
		}
		args = append(args, id)
		where += " AND ar.digital_employee_id = $" + strconv.Itoa(len(args))
	}

	ctx := r.Context()
	totals := runStatsTotalsDTO{}
	var p50, p95, avgThink *float64
	var thinkCnt, tokenCnt int64
	err = h.Pool.QueryRow(ctx, `
SELECT count(*),
       count(*) FILTER (WHERE status = 'completed'),
       count(*) FILTER (WHERE status = 'failed'),
       count(*) FILTER (WHERE status = 'cancelled'),
       count(*) FILTER (WHERE status = 'awaiting_user'),
       count(DISTINCT conversation_uuid),
       percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms),
       percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms),
       avg(thinking_ms),
       count(thinking_ms),
       COALESCE(SUM(total_tokens),0),
       count(total_tokens)
FROM agent_runs ar `+where, args...).Scan(
		&totals.Runs, &totals.Completed, &totals.Failed, &totals.Cancelled, &totals.AwaitingUser,
		&totals.Conversations, &p50, &p95, &avgThink, &thinkCnt, &totals.TotalTokens, &tokenCnt)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("stats totals: %v", err))
		return
	}
	if totals.Runs > 0 {
		sr := float64(totals.Completed) / float64(totals.Runs) * 100
		totals.SuccessRate = &sr
		tc := float64(thinkCnt) / float64(totals.Runs)
		totals.ThinkingCoverage = &tc
		tk := float64(tokenCnt) / float64(totals.Runs)
		totals.TokenCoverage = &tk
	}
	toIntPtr := func(f *float64) *int {
		if f == nil {
			return nil
		}
		n := int(*f)
		return &n
	}
	totals.P50DurationMS, totals.P95DurationMS, totals.AvgThinkingMS = toIntPtr(p50), toIntPtr(p95), toIntPtr(avgThink)

	groupExpr := "to_char(ar.started_at, 'MM-DD')"
	switch groupBy {
	case "digital_employee":
		groupExpr = "COALESCE(de.name, '已删除员工')"
	case "runtime_kind":
		groupExpr = "ar.runtime_kind"
	}
	join := ""
	if groupBy == "digital_employee" {
		join = " LEFT JOIN digital_employees de ON de.id = ar.digital_employee_id"
	}
	rows, err := h.Pool.Query(ctx, `
SELECT `+groupExpr+` AS k,
       count(*),
       count(*) FILTER (WHERE ar.status = 'completed'),
       count(*) FILTER (WHERE ar.status = 'failed'),
       COALESCE(SUM(ar.total_tokens),0)
FROM agent_runs ar`+join+" "+where+`
GROUP BY k ORDER BY k`, args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("stats buckets: %v", err))
		return
	}
	defer rows.Close()
	buckets := []runStatsBucketDTO{}
	for rows.Next() {
		var b runStatsBucketDTO
		if err := rows.Scan(&b.Key, &b.Runs, &b.Completed, &b.Failed, &b.TotalTokens); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan bucket: %v", err))
			return
		}
		buckets = append(buckets, b)
	}

	// 最慢工具 Top5 (窗口内 tool_call steps 聚合)
	toolWhere := "WHERE s.step_kind = 'tool_call' AND s.started_at >= $1 AND s.started_at < $2 AND s.name <> ''"
	toolArgs := []any{from, to}
	if tenantID != nil {
		toolArgs = append(toolArgs, *tenantID)
		toolWhere += " AND s.tenant_id = $" + strconv.Itoa(len(toolArgs))
	}
	toolRows, err := h.Pool.Query(ctx, `
SELECT s.name, count(*), COALESCE(avg(s.duration_ms),0)::int,
       count(*) FILTER (WHERE s.status = 'error')
FROM agent_run_steps s `+toolWhere+`
GROUP BY s.name ORDER BY avg(s.duration_ms) DESC NULLS LAST LIMIT 5`, toolArgs...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("slowest tools: %v", err))
		return
	}
	defer toolRows.Close()
	slowest := []slowestToolDTO{}
	for toolRows.Next() {
		var s slowestToolDTO
		if err := toolRows.Scan(&s.Name, &s.Calls, &s.AvgDurationMS, &s.ErrorCount); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan tool: %v", err))
			return
		}
		slowest = append(slowest, s)
	}

	encode.JSON(w, map[string]any{
		"totals":        totals,
		"buckets":       buckets,
		"slowest_tools": slowest,
	})
}

// ---- chain (F24 §4.2.1) ----

type chainNodeDTO struct {
	RunUUID           string `json:"runUuid"`
	DigitalEmployeeID int64  `json:"digitalEmployeeId"`
	AgentName         string `json:"agentName"`
	RuntimeKind       string `json:"runtimeKind"`
	Status            string `json:"status"`
	DurationMS        *int   `json:"durationMs,omitempty"`
	TotalTokens       *int64 `json:"totalTokens,omitempty"`
	Depth             int    `json:"depth"`
}

type chainEdgeDTO struct {
	EdgeUUID        string          `json:"edgeUuid"`
	FromAgentID     int64           `json:"fromAgentId"`
	FromAgentName   string          `json:"fromAgentName"`
	ToAgentID       int64           `json:"toAgentId"`
	ToAgentName     string          `json:"toAgentName"`
	Status          string          `json:"status"`
	InvokeKind      string          `json:"invokeKind"`
	Depth           int             `json:"depth"`
	LatencyMS       *int            `json:"latencyMs,omitempty"`
	TokensIn        *int64          `json:"tokensIn,omitempty"`
	TokensOut       *int64          `json:"tokensOut,omitempty"`
	CreatedAt       string          `json:"createdAt"`
	RequestPayload  json.RawMessage `json:"requestPayload,omitempty"`  // L3 + include_payloads
	ResponsePayload json.RawMessage `json:"responsePayload,omitempty"` // L3 + include_payloads
	ErrorMessage    string          `json:"errorMessage,omitempty"`
}

func (h *ObservabilityAgentRunsHandler) getPlatformRunChain(w http.ResponseWriter, r *http.Request) {
	h.getRunChain(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) getTenantRunChain(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getRunChain(w, r, &tid)
}

func (h *ObservabilityAgentRunsHandler) getRunChain(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	uuid := strings.TrimSpace(r.PathValue("uuid"))
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	includePayloads := r.URL.Query().Get("include_payloads") == "true"
	contentPerm := "tenant.observability.content.read"
	scope := "tenant"
	if fixedTenantID == nil {
		contentPerm = "platform.observability.content.read"
		scope = "platform"
	}
	if includePayloads && !adminHasPerm(r, contentPerm) {
		encode.JSONError(w, apperr.ErrForbidden.Withf("include_payloads requires %s", contentPerm))
		return
	}
	ctx := r.Context()

	// 入口 run (租户隔离在此闸口)
	var runTenantID int64
	var runCreatedAt time.Time
	var rootEdgeUUID *string
	args := []any{uuid}
	where := "WHERE uuid = $1"
	if fixedTenantID != nil {
		args = append(args, *fixedTenantID)
		where += " AND tenant_id = $2"
	}
	err := h.Pool.QueryRow(ctx,
		"SELECT tenant_id, created_at, root_a2a_edge_uuid::text FROM agent_runs "+where, args...).
		Scan(&runTenantID, &runCreatedAt, &rootEdgeUUID)
	if err != nil {
		if err == pgx.ErrNoRows {
			encode.JSONError(w, apperr.ErrNotFound.Withf("run not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Withf("chain entry: %v", err))
		return
	}

	// 找 root edge id: 入口 run 自己发出的边 ∪ 触发入口 run 的边, 任取其 root。
	var rootEdgeID *int64
	seedUUIDs := []string{}
	if rootEdgeUUID != nil && *rootEdgeUUID != "" {
		seedUUIDs = append(seedUUIDs, *rootEdgeUUID)
	}
	stepEdges, err := h.stepEdgeUUIDs(ctx, runTenantID, uuid, runCreatedAt)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("chain step edges: %v", err))
		return
	}
	seedUUIDs = append(seedUUIDs, stepEdges...)
	if len(seedUUIDs) > 0 {
		err = h.Pool.QueryRow(ctx, `
SELECT COALESCE(root_edge_id, id) FROM a2a_call_edges
WHERE tenant_id = $1 AND uuid = ANY($2) LIMIT 1`, runTenantID, seedUUIDs).Scan(&rootEdgeID)
		if err != nil && err != pgx.ErrNoRows {
			encode.JSONError(w, apperr.ErrInternal.Withf("chain root: %v", err))
			return
		}
	}

	edges := []chainEdgeDTO{}
	edgeUUIDs := []string{}
	if rootEdgeID != nil {
		sel := `
SELECT e.uuid, e.from_agent_id, COALESCE(fa.name,'已删除员工'), e.to_agent_id, COALESCE(ta.name,'已删除员工'),
       e.status, COALESCE(e.invoke_kind,''), e.depth, e.latency_ms, e.tokens_in, e.tokens_out,
       e.created_at, COALESCE(e.error_message,'')`
		if includePayloads {
			sel += `, e.request_payload, e.response_payload`
		}
		rows, qerr := h.Pool.Query(ctx, sel+`
FROM a2a_call_edges e
LEFT JOIN digital_employees fa ON fa.id = e.from_agent_id
LEFT JOIN digital_employees ta ON ta.id = e.to_agent_id
WHERE e.tenant_id = $1 AND (e.root_edge_id = $2 OR e.id = $2)
ORDER BY e.depth, e.created_at LIMIT 200`, runTenantID, *rootEdgeID)
		if qerr != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("chain edges: %v", qerr))
			return
		}
		defer rows.Close()
		for rows.Next() {
			var e chainEdgeDTO
			var createdAt time.Time
			dest := []any{&e.EdgeUUID, &e.FromAgentID, &e.FromAgentName, &e.ToAgentID, &e.ToAgentName,
				&e.Status, &e.InvokeKind, &e.Depth, &e.LatencyMS, &e.TokensIn, &e.TokensOut,
				&createdAt, &e.ErrorMessage}
			if includePayloads {
				dest = append(dest, &e.RequestPayload, &e.ResponsePayload)
			}
			if serr := rows.Scan(dest...); serr != nil {
				encode.JSONError(w, apperr.ErrInternal.Withf("scan edge: %v", serr))
				return
			}
			e.CreatedAt = createdAt.Format(time.RFC3339)
			edges = append(edges, e)
			edgeUUIDs = append(edgeUUIDs, e.EdgeUUID)
		}
	}

	// nodes: 入口 run + 链上其它 run (调用方经 step ref, 被调方经 root_a2a_edge_uuid — P0
	// A2A 直连会话无消息锚点时无被调 run, 树上以边呈现, 见 F24 §3.5)。
	nodes := []chainNodeDTO{}
	nodeArgs := []any{runTenantID, uuid}
	nodeSQL := `
SELECT DISTINCT ar.uuid, ar.digital_employee_id, COALESCE(de.name,'已删除员工'), ar.runtime_kind,
       ar.status, ar.duration_ms, ar.total_tokens,
       COALESCE(e.depth, 0)
FROM agent_runs ar
LEFT JOIN digital_employees de ON de.id = ar.digital_employee_id
LEFT JOIN a2a_call_edges e ON e.uuid::text = ar.root_a2a_edge_uuid::text AND e.tenant_id = ar.tenant_id
WHERE ar.tenant_id = $1 AND (ar.uuid = $2`
	if len(edgeUUIDs) > 0 {
		nodeArgs = append(nodeArgs, edgeUUIDs)
		nodeSQL += ` OR ar.root_a2a_edge_uuid::text = ANY($3)
       OR ar.uuid IN (
           SELECT s.run_uuid FROM agent_run_steps s
           WHERE s.tenant_id = $1 AND s.ref_kind = 'a2a_edge' AND s.ref_uuid = ANY($3))`
	}
	nodeSQL += ") LIMIT 200"
	nodeRows, err := h.Pool.Query(ctx, nodeSQL, nodeArgs...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("chain nodes: %v", err))
		return
	}
	defer nodeRows.Close()
	for nodeRows.Next() {
		var n chainNodeDTO
		if serr := nodeRows.Scan(&n.RunUUID, &n.DigitalEmployeeID, &n.AgentName, &n.RuntimeKind,
			&n.Status, &n.DurationMS, &n.TotalTokens, &n.Depth); serr != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan node: %v", serr))
			return
		}
		nodes = append(nodes, n)
	}

	// L3 payload 展开必须留痕 (fail-closed, F24 §4.4)
	if includePayloads {
		if err := emitContentViewedAudit(ctx, h.Pool, h.EventPub, runTenantID, scope,
			"agent_run_chain_payloads", uuid, map[string]any{"edge_count": len(edges)}); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("audit content access: %v", err))
			return
		}
	}

	encode.JSON(w, map[string]any{
		"root_run_uuid": uuid,
		"nodes":         nodes,
		"edges":         edges,
		"truncated":     len(edges) >= 200,
	})
}

func (h *ObservabilityAgentRunsHandler) stepEdgeUUIDs(ctx context.Context, tenantID int64, runUUID string, runCreatedAt time.Time) ([]string, error) {
	rows, err := h.Pool.Query(ctx, `
SELECT ref_uuid FROM agent_run_steps
WHERE tenant_id = $1 AND run_uuid = $2 AND created_at = $3 AND ref_kind = 'a2a_edge' AND ref_uuid IS NOT NULL`,
		tenantID, runUUID, runCreatedAt)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// emitContentViewedAudit writes the mandatory L3 access-trail event
// (audit.observability.content_viewed → audit-writer → audit_events).
// Fail-closed: callers must refuse to serve content when this errors.
func emitContentViewedAudit(ctx context.Context, pool *pgxpool.Pool, pub domevent.Publisher, targetTenantID int64, scope, action, resourceUUID string, extra map[string]any) error {
	if pub == nil || pool == nil {
		return apperr.ErrInternal.Withf("content audit not wired")
	}
	actorID := middleware.MustAccountID(ctx)
	// 字段名对齐 auditwriter payload shape (loop.go): account_id/actor_kind/acting_as
	// 直接映射 audit_events 列, "谁看过谁的会话" 可按列查询而非翻 data json。
	payload := map[string]any{
		"account_id":    actorID,
		"actor_kind":    "admin",
		"acting_as":     scope,
		"domain":        "observability",
		"event_kind":    "content_viewed",
		"resource_kind": "conversation",
		"resource_uuid": resourceUUID,
		"data":          map[string]any{"action": action, "acting_scope": scope, "detail": extra},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := pub.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
		Topic:    "audit.observability.content_viewed",
		TenantID: targetTenantID,
		Payload:  body,
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
