// F09 Phase B.4 / PR8 (B4-01 + B4-04): A2A 治理 admin API (租户 scope).
//
// 路由 (router.go 挂):
//
//	GET /api/admin/v1/tenant/a2a            — A2A edges 列表 (时间窗 + agent/room/orch 过滤)
//	GET /api/admin/v1/tenant/a2a/{edge_id}  — edge 详情 (含 redact 后 payload)
//	GET /api/admin/v1/tenant/a2a/agents     — 涉及的 agent 节点列表 (Graph 视图用; 出/入度统计)
//
// 权限: tenant.agent.read (与 rooms_admin.go 一致; 等 F11 引入 tenant.room.* 后再切).
//
// payload redaction: edge 详情返回 request_payload / response_payload 时, 跟 service/a2a 写入时
// 已经被 4 类 PII regex (手机/邮箱/身份证/API key) 替换为 [REDACTED:*] marker; admin **无权解
// redact**. 这里仅 passthrough.
//
// 直接 Pool 查询 (跟 rooms_admin.go 同 pattern, 不引 service).

package admincore

import (
	"encoding/json"
	"errors"
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

// AdminA2AHandler · F09-B4-01.
type AdminA2AHandler struct {
	Pool *pgxpool.Pool
}

type a2aEdgeSummary struct {
	ID              string  `json:"id"`
	CreatedAt       string  `json:"created_at"`
	Status          string  `json:"status"`
	FromAgentID     string  `json:"from_agent_id"`
	FromAgentName   string  `json:"from_agent_name,omitempty"`
	ToAgentID       string  `json:"to_agent_id"`
	ToAgentName     string  `json:"to_agent_name,omitempty"`
	Depth           int16   `json:"depth"`
	InvokeKind      string  `json:"invoke_kind"`
	OrchestrationID *string `json:"orchestration_id,omitempty"`
	RoomID          *string `json:"room_id,omitempty"`
	TokensIn        int32   `json:"tokens_in"`
	TokensOut       int32   `json:"tokens_out"`
	LatencyMs       *int32  `json:"latency_ms,omitempty"`
	ErrorMessage    string  `json:"error_message,omitempty"`
}

type a2aEdgeDetail struct {
	a2aEdgeSummary
	IdemKey         string          `json:"idem_key"`
	ParentEdgeID    *string         `json:"parent_edge_id,omitempty"`
	StartedAt       string          `json:"started_at,omitempty"`
	CompletedAt     string          `json:"completed_at,omitempty"`
	RequestPayload  json.RawMessage `json:"request_payload,omitempty"`
	ResponsePayload json.RawMessage `json:"response_payload,omitempty"`
}

type a2aListResp struct {
	Items    []a2aEdgeSummary `json:"items"`
	Total    int              `json:"total"`
	Page     int              `json:"page"`
	PageSize int              `json:"page_size"`
}

type a2aAgentNode struct {
	AgentID   string `json:"agent_id"`
	AgentName string `json:"agent_name"`
	OutDegree int    `json:"out_degree"`
	InDegree  int    `json:"in_degree"`
	FailedOut int    `json:"failed_out"`
}

type a2aAgentNodesResp struct {
	Items []a2aAgentNode `json:"items"`
	From  string         `json:"from"`
	To    string         `json:"to"`
}

// List GET /api/admin/v1/tenant/a2a
// query: from(RFC3339)? / to(RFC3339)? / from_agent_id? / to_agent_id? / room_id? / orchestration_id? / status (csv)? / page / page_size
// 默认时间窗: 最近 24h (避免全分区扫).
func (h *AdminA2AHandler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	q := r.URL.Query()
	page, pageSize := parsePagination(q)
	offset := (page - 1) * pageSize

	from, to, err := parseTimeWindow(q, 24*time.Hour)
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	conds := "WHERE e.tenant_id=$1 AND e.is_deleted=false AND e.created_at >= $2 AND e.created_at < $3"
	args := []any{tenantID, from, to}
	idx := 4
	if v := getQ(q, "from_agent_id"); v != "" {
		conds += " AND e.from_agent_id=(SELECT id FROM digital_employees WHERE tenant_id=$1 AND uuid::text=$" + strconv.Itoa(idx) + " AND is_deleted=false)"
		args = append(args, v)
		idx++
	}
	if v := getQ(q, "to_agent_id"); v != "" {
		conds += " AND e.to_agent_id=(SELECT id FROM digital_employees WHERE tenant_id=$1 AND uuid::text=$" + strconv.Itoa(idx) + " AND is_deleted=false)"
		args = append(args, v)
		idx++
	}
	if v := getQ(q, "room_id"); v != "" {
		conds += " AND e.room_id=(SELECT id FROM rooms WHERE tenant_id=$1 AND uuid::text=$" + strconv.Itoa(idx) + " AND is_deleted=false)"
		args = append(args, v)
		idx++
	}
	if v := getQ(q, "orchestration_id"); v != "" {
		conds += " AND e.orchestration_id=(SELECT id FROM agent_orchestrations WHERE tenant_id=$1 AND uuid::text=$" + strconv.Itoa(idx) + " AND is_deleted=false)"
		args = append(args, v)
		idx++
	}
	if v := getQ(q, "status"); v != "" {
		statuses := splitCSV(v)
		if len(statuses) > 0 {
			conds += " AND e.status = ANY($" + strconv.Itoa(idx) + ")"
			args = append(args, statuses)
			idx++
		}
	}

	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM a2a_call_edges e `+conds, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, pageSize, offset)
	limOff := " ORDER BY e.created_at DESC LIMIT $" + strconv.Itoa(idx) + " OFFSET $" + strconv.Itoa(idx+1)
	rows, err := h.Pool.Query(r.Context(), `
		SELECT e.uuid, e.created_at, e.status,
		       COALESCE(fa.uuid::text,''), COALESCE(fa.name,''),
		       COALESCE(ta.uuid::text,''), COALESCE(ta.name,''),
		       e.depth, e.invoke_kind,
		       o.uuid::text, rm.uuid::text,
		       e.tokens_in, e.tokens_out, e.latency_ms,
		       COALESCE(e.error_message,'')
		  FROM a2a_call_edges e
		  LEFT JOIN digital_employees fa ON fa.id = e.from_agent_id AND fa.tenant_id = e.tenant_id
		  LEFT JOIN digital_employees ta ON ta.id = e.to_agent_id AND ta.tenant_id = e.tenant_id
		  LEFT JOIN agent_orchestrations o ON o.id = e.orchestration_id AND o.tenant_id = e.tenant_id
		  LEFT JOIN rooms rm ON rm.id = e.room_id AND rm.tenant_id = e.tenant_id
		`+conds+limOff,
		args...,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]a2aEdgeSummary, 0)
	for rows.Next() {
		var (
			e         a2aEdgeSummary
			orchID    *string
			roomID    *string
			latencyMs *int32
			createdAt time.Time
		)
		if err := rows.Scan(&e.ID, &createdAt, &e.Status,
			&e.FromAgentID, &e.FromAgentName,
			&e.ToAgentID, &e.ToAgentName,
			&e.Depth, &e.InvokeKind,
			&orchID, &roomID,
			&e.TokensIn, &e.TokensOut, &latencyMs,
			&e.ErrorMessage,
		); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		e.CreatedAt = createdAt.UTC().Format(time.RFC3339Nano)
		e.OrchestrationID = orchID
		e.RoomID = roomID
		e.LatencyMs = latencyMs
		items = append(items, e)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, a2aListResp{Items: items, Total: total, Page: page, PageSize: pageSize})
}

// Get GET /api/admin/v1/tenant/a2a/{edge_id}?created_at=RFC3339
// created_at 必填 (分区表裁剪).
func (h *AdminA2AHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	edgeID := r.PathValue("edge_id")
	if edgeID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("edge_id required"))
		return
	}
	createdAtRaw := r.URL.Query().Get("created_at")
	if createdAtRaw == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("created_at query param required (RFC3339)"))
		return
	}
	createdAt, err := time.Parse(time.RFC3339, createdAtRaw)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("created_at: %v", err))
		return
	}

	var (
		d            a2aEdgeDetail
		orchID       *string
		roomID       *string
		latencyMs    *int32
		startedAt    *time.Time
		completedAt  *time.Time
		parentEdgeID *string
		createdAtRet time.Time
		reqPayload   []byte
		respPayload  []byte
	)
	err = h.Pool.QueryRow(r.Context(), `
		SELECT e.uuid, e.created_at, e.status,
		       COALESCE(fa.uuid::text,''), COALESCE(fa.name,''),
		       COALESCE(ta.uuid::text,''), COALESCE(ta.name,''),
		       e.depth, e.invoke_kind,
		       o.uuid::text, rm.uuid::text,
		       e.tokens_in, e.tokens_out, e.latency_ms,
		       COALESCE(e.error_message,''),
		       e.idem_key, (SELECT pe.uuid::text FROM a2a_call_edges pe WHERE pe.id=e.parent_edge_id AND pe.tenant_id=e.tenant_id LIMIT 1),
		       e.started_at, e.completed_at,
		       e.request_payload, e.response_payload
		  FROM a2a_call_edges e
		  LEFT JOIN digital_employees fa ON fa.id = e.from_agent_id AND fa.tenant_id = e.tenant_id
		  LEFT JOIN digital_employees ta ON ta.id = e.to_agent_id AND ta.tenant_id = e.tenant_id
		  LEFT JOIN agent_orchestrations o ON o.id = e.orchestration_id AND o.tenant_id = e.tenant_id
		  LEFT JOIN rooms rm ON rm.id = e.room_id AND rm.tenant_id = e.tenant_id
		 WHERE e.tenant_id=$1 AND e.uuid=$2 AND e.created_at=$3 AND e.is_deleted=false`,
		tenantID, edgeID, createdAt,
	).Scan(&d.ID, &createdAtRet, &d.Status,
		&d.FromAgentID, &d.FromAgentName,
		&d.ToAgentID, &d.ToAgentName,
		&d.Depth, &d.InvokeKind,
		&orchID, &roomID,
		&d.TokensIn, &d.TokensOut, &latencyMs,
		&d.ErrorMessage,
		&d.IdemKey, &parentEdgeID,
		&startedAt, &completedAt,
		&reqPayload, &respPayload,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "a2a.edge.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	d.CreatedAt = createdAtRet.UTC().Format(time.RFC3339Nano)
	d.OrchestrationID = orchID
	d.RoomID = roomID
	d.LatencyMs = latencyMs
	d.ParentEdgeID = parentEdgeID
	if startedAt != nil {
		d.StartedAt = startedAt.UTC().Format(time.RFC3339)
	}
	if completedAt != nil {
		d.CompletedAt = completedAt.UTC().Format(time.RFC3339)
	}
	if len(reqPayload) > 0 {
		d.RequestPayload = reqPayload
	}
	if len(respPayload) > 0 {
		d.ResponsePayload = respPayload
	}
	encode.JSON(w, d)
}

// AgentNodes GET /api/admin/v1/tenant/a2a/agents
// 给前端 Graph 视图: 按时间窗汇总 from/to agent 出/入度 + 失败数.
// 限制 nodes ≤ 100 (F09 B4-01 验收: 50 节点流畅, 上限 100 兜底).
func (h *AdminA2AHandler) AgentNodes(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	from, to, err := parseTimeWindow(r.URL.Query(), 24*time.Hour)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	rows, err := h.Pool.Query(r.Context(), `
		WITH involved AS (
		  SELECT from_agent_id AS aid, 'from' AS dir, status FROM a2a_call_edges
		   WHERE tenant_id=$1 AND created_at >= $2 AND created_at < $3 AND is_deleted=false
		  UNION ALL
		  SELECT to_agent_id   AS aid, 'to'   AS dir, status FROM a2a_call_edges
		   WHERE tenant_id=$1 AND created_at >= $2 AND created_at < $3 AND is_deleted=false
		),
		agg AS (
		  SELECT aid,
		         SUM(CASE WHEN dir='from' THEN 1 ELSE 0 END)::int AS out_degree,
		         SUM(CASE WHEN dir='to'   THEN 1 ELSE 0 END)::int AS in_degree,
		         SUM(CASE WHEN dir='from' AND status IN ('failed','cancelled','dropped_whitelist','dropped_budget','dropped_loop')
		                  THEN 1 ELSE 0 END)::int                        AS failed_out
		    FROM involved GROUP BY aid
		)
		SELECT COALESCE(de.uuid::text,''), COALESCE(de.name,''),
		       a.out_degree, a.in_degree, a.failed_out
		  FROM agg a
		  LEFT JOIN digital_employees de ON de.id = a.aid
		 ORDER BY (a.out_degree + a.in_degree) DESC
		 LIMIT 100`,
		tenantID, from, to,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	items := make([]a2aAgentNode, 0)
	for rows.Next() {
		var n a2aAgentNode
		if err := rows.Scan(&n.AgentID, &n.AgentName, &n.OutDegree, &n.InDegree, &n.FailedOut); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		items = append(items, n)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, a2aAgentNodesResp{
		Items: items,
		From:  from.UTC().Format(time.RFC3339),
		To:    to.UTC().Format(time.RFC3339),
	})
}

// parseTimeWindow 从 query 取 from / to (RFC3339); 缺 from → now - defaultWindow; 缺 to → now.
func parseTimeWindow(q map[string][]string, defaultWindow time.Duration) (time.Time, time.Time, error) {
	now := time.Now().UTC()
	from := now.Add(-defaultWindow)
	to := now
	if v := getQ(q, "from"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return from, to, apperr.ErrInvalidParams.Withf("from: %v", err)
		}
		from = t.UTC()
	}
	if v := getQ(q, "to"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return from, to, apperr.ErrInvalidParams.Withf("to: %v", err)
		}
		to = t.UTC()
	}
	if !to.After(from) {
		return from, to, apperr.ErrInvalidParams.Withf("to must be after from")
	}
	// 强制不大于 30 天 (避免全表扫).
	if to.Sub(from) > 30*24*time.Hour {
		return from, to, apperr.ErrInvalidParams.Withf("time window must be ≤ 30d")
	}
	return from, to, nil
}

// splitCSV "running,done" → ["running","done"].
func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
