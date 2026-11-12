// F09-A6-05: 群聊治理 admin API (租户 scope).
//
// 路由 (在 router.go 注册):
//
//	GET    /api/admin/v1/tenant/rooms                          列表 (room_kind / status / q / page / page_size)
//	GET    /api/admin/v1/tenant/rooms/{uuid}                   详情 (含 wukong channel + 24h trigger 计数)
//	GET    /api/admin/v1/tenant/rooms/{uuid}/triggers          agent_trigger_log 分页 (按 received_at DESC)
//	GET    /api/admin/v1/tenant/rooms/{uuid}/participants      active 成员列表
//	POST   /api/admin/v1/tenant/rooms/{uuid}/freeze            UPDATE rooms.metadata->>'frozen'='true'
//	POST   /api/admin/v1/tenant/rooms/{uuid}/unfreeze          UPDATE rooms.metadata->>'frozen'='false'
//
// 权限: tenant.agent.read (list/get) / tenant.agent.update (freeze/unfreeze) — 跟数字员工同权限组复用,
// 等 F10 / F11 引入专用 tenant.room.* 权限点后单独 PR 切换.
//
// 直接 Pool 查询 (避免引 service 层间接) — 跟 agent_kb_bindings.go 同 pattern.
package admincore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AdminRoomsHandler · F09-A6-05.
type AdminRoomsHandler struct {
	Pool *pgxpool.Pool
	// Audit F25 阶段 G: 冻结/解冻写审计入口（nil 时静默跳过）。
	Audit domaudit.Store
}

type roomSummary struct {
	UUID              string `json:"uuid"`
	Title             string `json:"title"`
	RoomKind          string `json:"room_kind"`
	Status            string `json:"status"`
	SpeakerPolicy     string `json:"speaker_policy"`
	ManagerAgentUUID  string `json:"manager_agent_uuid,omitempty"`
	HumanCount        int    `json:"human_count"`
	AgentCount        int    `json:"agent_count"`
	Frozen            bool   `json:"frozen"`
	Triggers24h       int    `json:"triggers_24h"`
	WuKongChannelID   string `json:"wukong_channel_id,omitempty"`
	WuKongChannelType int    `json:"wukong_channel_type,omitempty"`
	CreatedAt         string `json:"created_at"`
}

type roomListResp struct {
	Items    []roomSummary `json:"items"`
	Total    int           `json:"total"`
	Page     int           `json:"page"`
	PageSize int           `json:"page_size"`
}

// List GET /api/admin/v1/tenant/rooms.
func (h *AdminRoomsHandler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	q := r.URL.Query()
	roomKind := q.Get("room_kind")
	status := q.Get("status")
	search := q.Get("q")
	page, pageSize := parsePagination(q)
	offset := (page - 1) * pageSize

	conds := "WHERE r.tenant_id=$1 AND r.deleted_at IS NULL"
	args := []any{tenantID}
	idx := 2
	if roomKind != "" {
		conds += " AND r.room_kind=$" + strconv.Itoa(idx)
		args = append(args, roomKind)
		idx++
	}
	if status != "" {
		conds += " AND r.status=$" + strconv.Itoa(idx)
		args = append(args, status)
		idx++
	}
	if search != "" {
		conds += " AND r.title ILIKE $" + strconv.Itoa(idx)
		args = append(args, "%"+search+"%")
		idx++
	}

	// 总数
	var total int
	countSQL := "SELECT count(*) FROM rooms r " + conds
	if err := h.Pool.QueryRow(r.Context(), countSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	listSQL := `SELECT r.uuid, r.title, r.room_kind, r.status, r.speaker_policy,
       COALESCE((SELECT de.uuid::text FROM digital_employees de WHERE de.id = r.manager_agent_id), ''),
       COALESCE((SELECT count(*) FROM room_participants p WHERE p.room_id=r.id AND p.kind='human' AND p.left_at IS NULL), 0),
       COALESCE((SELECT count(*) FROM room_participants p WHERE p.room_id=r.id AND p.kind='agent' AND p.left_at IS NULL), 0),
       COALESCE((r.metadata->>'frozen')::boolean, false),
       COALESCE((SELECT count(*) FROM agent_trigger_log atl WHERE atl.room_id=r.id AND atl.received_at > now() - interval '24 hours'), 0),
       COALESCE(r.wukong_channel_id, ''), COALESCE(r.wukong_channel_type, 0),
       to_char(r.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  FROM rooms r ` + conds + ` ORDER BY r.created_at DESC LIMIT $` + strconv.Itoa(idx) + ` OFFSET $` + strconv.Itoa(idx+1)
	args = append(args, pageSize, offset)

	rows, err := h.Pool.Query(r.Context(), listSQL, args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	items := make([]roomSummary, 0)
	for rows.Next() {
		var rs roomSummary
		if err := rows.Scan(&rs.UUID, &rs.Title, &rs.RoomKind, &rs.Status, &rs.SpeakerPolicy,
			&rs.ManagerAgentUUID, &rs.HumanCount, &rs.AgentCount, &rs.Frozen, &rs.Triggers24h,
			&rs.WuKongChannelID, &rs.WuKongChannelType, &rs.CreatedAt); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		items = append(items, rs)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, roomListResp{Items: items, Total: total, Page: page, PageSize: pageSize})
}

// Get GET /api/admin/v1/tenant/rooms/{uuid}.
func (h *AdminRoomsHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	roomUUID := r.PathValue("uuid")
	var rs roomSummary
	const q = `SELECT r.uuid, r.title, r.room_kind, r.status, r.speaker_policy,
       COALESCE((SELECT de.uuid::text FROM digital_employees de WHERE de.id = r.manager_agent_id), ''),
       COALESCE((SELECT count(*) FROM room_participants p WHERE p.room_id=r.id AND p.kind='human' AND p.left_at IS NULL), 0),
       COALESCE((SELECT count(*) FROM room_participants p WHERE p.room_id=r.id AND p.kind='agent' AND p.left_at IS NULL), 0),
       COALESCE((r.metadata->>'frozen')::boolean, false),
       COALESCE((SELECT count(*) FROM agent_trigger_log atl WHERE atl.room_id=r.id AND atl.received_at > now() - interval '24 hours'), 0),
       COALESCE(r.wukong_channel_id, ''), COALESCE(r.wukong_channel_type, 0),
       to_char(r.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  FROM rooms r WHERE r.uuid=$1 AND r.tenant_id=$2 AND r.deleted_at IS NULL`
	err := h.Pool.QueryRow(r.Context(), q, roomUUID, tenantID).Scan(
		&rs.UUID, &rs.Title, &rs.RoomKind, &rs.Status, &rs.SpeakerPolicy,
		&rs.ManagerAgentUUID, &rs.HumanCount, &rs.AgentCount, &rs.Frozen,
		&rs.Triggers24h, &rs.WuKongChannelID, &rs.WuKongChannelType, &rs.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "room.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, rs)
}

type triggerRow struct {
	UUID            string `json:"uuid"`
	SenderAccountID *int64 `json:"sender_account_id,omitempty"`
	AgentID         *int64 `json:"agent_id,omitempty"`
	Decision        string `json:"decision"`
	RejectReason    string `json:"reject_reason,omitempty"`
	IMMessageID     string `json:"im_message_id"`
	ReceivedAt      string `json:"received_at"`
}

type triggerListResp struct {
	Items    []triggerRow `json:"items"`
	Total    int          `json:"total"`
	Page     int          `json:"page"`
	PageSize int          `json:"page_size"`
}

// Triggers GET /api/admin/v1/tenant/rooms/{uuid}/triggers.
func (h *AdminRoomsHandler) Triggers(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	roomUUID := r.PathValue("uuid")
	roomID, err := h.resolveRoomID(r, tenantID, roomUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	page, pageSize := parsePagination(r.URL.Query())
	offset := (page - 1) * pageSize

	var total int
	if err := h.Pool.QueryRow(r.Context(),
		`SELECT count(*) FROM agent_trigger_log WHERE tenant_id=$1 AND room_id=$2`,
		tenantID, roomID).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	rows, err := h.Pool.Query(r.Context(),
		`SELECT uuid, sender_account_id, agent_id, decision, COALESCE(reject_reason,''),
                openim_client_msg_id, to_char(received_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
           FROM agent_trigger_log
          WHERE tenant_id=$1 AND room_id=$2
          ORDER BY received_at DESC LIMIT $3 OFFSET $4`,
		tenantID, roomID, pageSize, offset)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	items := make([]triggerRow, 0)
	for rows.Next() {
		var t triggerRow
		if err := rows.Scan(&t.UUID, &t.SenderAccountID, &t.AgentID, &t.Decision, &t.RejectReason, &t.IMMessageID, &t.ReceivedAt); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		items = append(items, t)
	}
	encode.JSON(w, triggerListResp{Items: items, Total: total, Page: page, PageSize: pageSize})
}

// Freeze POST /api/admin/v1/tenant/rooms/{uuid}/freeze.
func (h *AdminRoomsHandler) Freeze(w http.ResponseWriter, r *http.Request) {
	h.toggleFrozen(w, r, true)
}

// Unfreeze POST /api/admin/v1/tenant/rooms/{uuid}/unfreeze.
func (h *AdminRoomsHandler) Unfreeze(w http.ResponseWriter, r *http.Request) {
	h.toggleFrozen(w, r, false)
}

func (h *AdminRoomsHandler) toggleFrozen(w http.ResponseWriter, r *http.Request, frozen bool) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	roomUUID := r.PathValue("uuid")
	res, err := h.Pool.Exec(r.Context(),
		`UPDATE rooms SET metadata = jsonb_set(COALESCE(metadata,'{}'::jsonb), '{frozen}', to_jsonb($3::boolean), true)
		  WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		roomUUID, tenantID, frozen)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if res.RowsAffected() == 0 {
		encode.JSONError(w, apperr.New(apperr.NotFound, "room.not_found"))
		return
	}
	// F25 阶段 G: 冻结/解冻是群聊治理高风险写操作，补审计（存量缺口，2026-07-11 盘点确认）。
	if h.Audit != nil {
		eventKind := "room.freeze"
		if !frozen {
			eventKind = "room.unfreeze"
		}
		payload, _ := json.Marshal(map[string]any{"frozen": frozen})
		_ = h.Audit.Insert(r.Context(), domaudit.Event{
			OccurredAt:   time.Now(),
			TenantID:     tenantID,
			AccountID:    middleware.MustAccountID(r.Context()),
			ActorKind:    domaudit.ActorAdmin,
			Domain:       "room",
			EventKind:    eventKind,
			Severity:     domaudit.SeverityWarning,
			ResourceKind: "room",
			ResourceUUID: roomUUID,
			Payload:      payload,
		})
	}
	encode.JSON(w, map[string]any{"uuid": roomUUID, "frozen": frozen})
}

func (h *AdminRoomsHandler) resolveRoomID(r *http.Request, tenantID int64, roomUUID string) (int64, error) {
	var id int64
	err := h.Pool.QueryRow(r.Context(),
		`SELECT id FROM rooms WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		roomUUID, tenantID).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.New(apperr.NotFound, "room.not_found")
		}
		return 0, apperr.ErrInternal.Wrap(err)
	}
	return id, nil
}

// parsePagination · query 中 page / page_size; 默认 page=1 page_size=20 clamp [1,100].
func parsePagination(q map[string][]string) (page, pageSize int) {
	page = 1
	pageSize = 20
	if v := getQ(q, "page"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			page = n
		}
	}
	if v := getQ(q, "page_size"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			pageSize = n
		}
	}
	if pageSize > 100 {
		pageSize = 100
	}
	return page, pageSize
}

func getQ(q map[string][]string, key string) string {
	if v, ok := q[key]; ok && len(v) > 0 {
		return v[0]
	}
	return ""
}

// Compile-time: 防止意外把 encoding/json 引入但没用.
var _ = json.RawMessage(nil)
