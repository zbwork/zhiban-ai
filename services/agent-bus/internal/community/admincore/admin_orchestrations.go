// F09 Phase B.4 / PR8 (B4-02): Orchestration 治理 admin API (租户 scope).
//
// 路由 (router.go 挂):
//
//	GET /api/admin/v1/tenant/orchestrations         — 列表 (status/master_agent_id/room_id/time window)
//	GET /api/admin/v1/tenant/orchestrations/{uuid}  — 详情 (含 steps + edges 计数)
//
// 权限: tenant.agent.read.

package admincore

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AdminOrchestrationsHandler · F09-B4-02.
type AdminOrchestrationsHandler struct {
	Pool *pgxpool.Pool
}

type orchSummary struct {
	UUID            string `json:"uuid"`
	CreatedAt       string `json:"created_at"`
	Status          string `json:"status"`
	MasterAgentID   int64  `json:"master_agent_id"`
	MasterAgentName string `json:"master_agent_name,omitempty"`
	RoomID          *int64 `json:"room_id,omitempty"`
	PlanSummary     string `json:"plan_summary,omitempty"`
	DepthLimit      int16  `json:"depth_limit"`
	TokenBudget     int32  `json:"token_budget"`
	TimeBudgetMs    int32  `json:"time_budget_ms"`
	TokensInTotal   int32  `json:"tokens_in_total"`
	TokensOutTotal  int32  `json:"tokens_out_total"`
	EdgesCount      int32  `json:"edges_count"`
	MaxDepthReached int16  `json:"max_depth_reached"`
	StartedAt       string `json:"started_at,omitempty"`
	CompletedAt     string `json:"completed_at,omitempty"`
}

type orchListResp struct {
	Items    []orchSummary `json:"items"`
	Total    int           `json:"total"`
	Page     int           `json:"page"`
	PageSize int           `json:"page_size"`
}

type orchStep struct {
	UUID          string `json:"uuid"`
	StepIndex     int16  `json:"step_index"`
	Role          string `json:"role"`
	Status        string `json:"status"`
	WorkerAgentID *int64 `json:"worker_agent_id,omitempty"`
	WorkerName    string `json:"worker_name,omitempty"`
	CallEdgeID    *int64 `json:"call_edge_id,omitempty"`
	InputSummary  string `json:"input_summary,omitempty"`
	OutputSummary string `json:"output_summary,omitempty"`
	ErrorMessage  string `json:"error_message,omitempty"`
	TokensIn      int32  `json:"tokens_in"`
	TokensOut     int32  `json:"tokens_out"`
	StartedAt     string `json:"started_at,omitempty"`
	CompletedAt   string `json:"completed_at,omitempty"`
	CreatedAt     string `json:"created_at"`
}

type orchDetail struct {
	orchSummary
	FinalSummary string     `json:"final_summary,omitempty"`
	ErrorMessage string     `json:"error_message,omitempty"`
	TriggerMsgID *int64     `json:"trigger_msg_id,omitempty"`
	Steps        []orchStep `json:"steps"`
}

// List GET /api/admin/v1/tenant/orchestrations
func (h *AdminOrchestrationsHandler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	q := r.URL.Query()
	page, pageSize := parsePagination(q)
	offset := (page - 1) * pageSize

	conds := "WHERE o.tenant_id=$1 AND o.is_deleted=false"
	args := []any{tenantID}
	idx := 2

	if v := getQ(q, "status"); v != "" {
		statuses := splitCSV(v)
		if len(statuses) > 0 {
			conds += " AND o.status = ANY($" + strconv.Itoa(idx) + ")"
			args = append(args, statuses)
			idx++
		}
	}
	if v := getQ(q, "master_agent_id"); v != "" {
		if n, e := strconv.ParseInt(v, 10, 64); e == nil && n > 0 {
			conds += " AND o.master_agent_id=$" + strconv.Itoa(idx)
			args = append(args, n)
			idx++
		}
	}
	if v := getQ(q, "room_id"); v != "" {
		if n, e := strconv.ParseInt(v, 10, 64); e == nil && n > 0 {
			conds += " AND o.room_id=$" + strconv.Itoa(idx)
			args = append(args, n)
			idx++
		}
	}
	if v := getQ(q, "from"); v != "" {
		if t, e := time.Parse(time.RFC3339, v); e == nil {
			conds += " AND o.created_at >= $" + strconv.Itoa(idx)
			args = append(args, t)
			idx++
		}
	}
	if v := getQ(q, "to"); v != "" {
		if t, e := time.Parse(time.RFC3339, v); e == nil {
			conds += " AND o.created_at < $" + strconv.Itoa(idx)
			args = append(args, t)
			idx++
		}
	}

	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM agent_orchestrations o `+conds, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, pageSize, offset)
	rows, err := h.Pool.Query(r.Context(), `
		SELECT o.uuid, o.created_at, o.status,
		       o.master_agent_id, COALESCE(de.name,''),
		       o.room_id, COALESCE(o.plan_summary,''),
		       o.depth_limit, o.token_budget, o.time_budget_ms,
		       o.tokens_in_total, o.tokens_out_total, o.edges_count, o.max_depth_reached,
		       o.started_at, o.completed_at
		  FROM agent_orchestrations o
		  LEFT JOIN digital_employees de ON de.id = o.master_agent_id
		`+conds+`
		 ORDER BY o.created_at DESC
		 LIMIT $`+strconv.Itoa(idx)+` OFFSET $`+strconv.Itoa(idx+1),
		args...,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]orchSummary, 0)
	for rows.Next() {
		var (
			s         orchSummary
			roomID    *int64
			createdAt time.Time
			started   *time.Time
			completed *time.Time
		)
		if err := rows.Scan(&s.UUID, &createdAt, &s.Status,
			&s.MasterAgentID, &s.MasterAgentName,
			&roomID, &s.PlanSummary,
			&s.DepthLimit, &s.TokenBudget, &s.TimeBudgetMs,
			&s.TokensInTotal, &s.TokensOutTotal, &s.EdgesCount, &s.MaxDepthReached,
			&started, &completed,
		); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		s.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		s.RoomID = roomID
		if started != nil {
			s.StartedAt = started.UTC().Format(time.RFC3339)
		}
		if completed != nil {
			s.CompletedAt = completed.UTC().Format(time.RFC3339)
		}
		items = append(items, s)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, orchListResp{Items: items, Total: total, Page: page, PageSize: pageSize})
}

// Get GET /api/admin/v1/tenant/orchestrations/{uuid}
// 返 orchestration + steps; edges 数量通过 orchestrations.edges_count 字段直出 (PR5 计数器).
func (h *AdminOrchestrationsHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}

	var (
		d            orchDetail
		orchID       int64
		roomID       *int64
		triggerMsgID *int64
		createdAt    time.Time
		started      *time.Time
		completed    *time.Time
	)
	err := h.Pool.QueryRow(r.Context(), `
		SELECT o.id, o.uuid, o.created_at, o.status,
		       o.master_agent_id, COALESCE(de.name,''),
		       o.room_id, o.trigger_msg_id,
		       COALESCE(o.plan_summary,''), COALESCE(o.final_summary,''), COALESCE(o.error_message,''),
		       o.depth_limit, o.token_budget, o.time_budget_ms,
		       o.tokens_in_total, o.tokens_out_total, o.edges_count, o.max_depth_reached,
		       o.started_at, o.completed_at
		  FROM agent_orchestrations o
		  LEFT JOIN digital_employees de ON de.id = o.master_agent_id
		 WHERE o.tenant_id=$1 AND o.uuid=$2 AND o.is_deleted=false`,
		tenantID, uuid,
	).Scan(&orchID, &d.UUID, &createdAt, &d.Status,
		&d.MasterAgentID, &d.MasterAgentName,
		&roomID, &triggerMsgID,
		&d.PlanSummary, &d.FinalSummary, &d.ErrorMessage,
		&d.DepthLimit, &d.TokenBudget, &d.TimeBudgetMs,
		&d.TokensInTotal, &d.TokensOutTotal, &d.EdgesCount, &d.MaxDepthReached,
		&started, &completed,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "orchestration.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	d.CreatedAt = createdAt.UTC().Format(time.RFC3339)
	d.RoomID = roomID
	d.TriggerMsgID = triggerMsgID
	if started != nil {
		d.StartedAt = started.UTC().Format(time.RFC3339)
	}
	if completed != nil {
		d.CompletedAt = completed.UTC().Format(time.RFC3339)
	}

	// steps
	stepRows, err := h.Pool.Query(r.Context(), `
		SELECT s.uuid, s.step_index, s.role, s.status,
		       s.worker_agent_id, COALESCE(wa.name,''),
		       s.call_edge_id,
		       COALESCE(s.input_summary,''), COALESCE(s.output_summary,''),
		       COALESCE(s.error_message,''),
		       s.tokens_in, s.tokens_out,
		       s.started_at, s.completed_at, s.created_at
		  FROM agent_orchestration_steps s
		  LEFT JOIN digital_employees wa ON wa.id = s.worker_agent_id
		 WHERE s.orchestration_id=$1 AND s.is_deleted=false
		 ORDER BY s.step_index ASC, s.id ASC`,
		orchID,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer stepRows.Close()
	d.Steps = make([]orchStep, 0)
	for stepRows.Next() {
		var (
			st        orchStep
			workerID  *int64
			callEdge  *int64
			stStart   *time.Time
			stEnd     *time.Time
			stCreated time.Time
		)
		if err := stepRows.Scan(&st.UUID, &st.StepIndex, &st.Role, &st.Status,
			&workerID, &st.WorkerName,
			&callEdge,
			&st.InputSummary, &st.OutputSummary,
			&st.ErrorMessage,
			&st.TokensIn, &st.TokensOut,
			&stStart, &stEnd, &stCreated,
		); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		st.WorkerAgentID = workerID
		st.CallEdgeID = callEdge
		st.CreatedAt = stCreated.UTC().Format(time.RFC3339)
		if stStart != nil {
			st.StartedAt = stStart.UTC().Format(time.RFC3339)
		}
		if stEnd != nil {
			st.CompletedAt = stEnd.UTC().Format(time.RFC3339)
		}
		d.Steps = append(d.Steps, st)
	}
	if err := stepRows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, d)
}
