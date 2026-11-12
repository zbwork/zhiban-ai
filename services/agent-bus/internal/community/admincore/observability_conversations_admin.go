// observability_conversations_admin.go — F24 P0: 会话检索 admin API (L3 内容层)。
//
// 权限: platform/tenant.observability.content.read (常驻授予 admin/auditor, D10)。
// 每次调用强制写 audit.observability.content_viewed (fail-closed: 审计写不进就
// 不出正文, F24 §4.4)。正文渲染前过 redact 兜底脱敏 (§6.3 双保险)。
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type obsConversationDTO struct {
	UUID              string `json:"uuid"`
	TenantID          int64  `json:"tenantId"`
	TenantName        string `json:"tenantName,omitempty"` // platform scope only
	Title             string `json:"title"`
	AccountID         int64  `json:"accountId"`
	AccountName       string `json:"accountName,omitempty"`
	DigitalEmployeeID *int64 `json:"digitalEmployeeId,omitempty"`
	AgentName         string `json:"agentName,omitempty"`
	RoomID            *int64 `json:"roomId,omitempty"`
	Source            string `json:"source,omitempty"`
	MessageCount      int64  `json:"messageCount"`
	LastMessageAt     string `json:"lastMessageAt,omitempty"`
	CreatedAt         string `json:"createdAt"`
}

type obsMessageDTO struct {
	UUID            string          `json:"uuid"`
	Role            string          `json:"role"`
	SenderAccountID *int64          `json:"senderAccountId,omitempty"`
	SenderAgentID   *int64          `json:"senderAgentId,omitempty"`
	Status          string          `json:"status"`
	Blocks          json.RawMessage `json:"blocks"` // redact 兜底脱敏后的 EMP blocks
	ErrorCode       string          `json:"errorCode,omitempty"`
	CreatedAt       string          `json:"createdAt"`
}

func (h *ObservabilityAgentRunsHandler) listPlatformConversations(w http.ResponseWriter, r *http.Request) {
	h.listConversations(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) listTenantConversations(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.listConversations(w, r, &tid)
}

func (h *ObservabilityAgentRunsHandler) listConversations(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	q := r.URL.Query()
	scope := "tenant"
	if fixedTenantID == nil {
		scope = "platform"
	}

	where := []string{"c.deleted_at IS NULL"}
	args := []any{}
	add := func(cond string, v any) {
		args = append(args, v)
		where = append(where, cond+" $"+strconv.Itoa(len(args)))
	}
	auditTenant := int64(0)
	if fixedTenantID != nil {
		add("c.tenant_id =", *fixedTenantID)
		auditTenant = *fixedTenantID
	} else if v := strings.TrimSpace(q.Get("tenant_id")); v != "" {
		tid, err := strconv.ParseInt(v, 10, 64)
		if err != nil || tid <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id invalid"))
			return
		}
		add("c.tenant_id =", tid)
		auditTenant = tid
	}
	if v := strings.TrimSpace(q.Get("account_id")); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("account_id invalid"))
			return
		}
		add("c.account_id =", id)
	}
	if v := strings.TrimSpace(q.Get("digital_employee_id")); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("digital_employee_id invalid"))
			return
		}
		add("c.digital_employee_id =", id)
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		add("c.title ILIKE", "%"+v+"%")
	}
	if v := strings.TrimSpace(q.Get("from")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("from: %v", err))
			return
		}
		add("COALESCE(c.last_message_at, c.created_at) >=", t)
	}
	if v := strings.TrimSpace(q.Get("to")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("to: %v", err))
			return
		}
		add("COALESCE(c.last_message_at, c.created_at) <", t)
	}

	limit := 50
	if v, err := strconv.Atoi(q.Get("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	offset := 0
	if v, err := strconv.Atoi(q.Get("offset")); err == nil && v > 0 {
		offset = v
	}

	// L3 访问留痕 (fail-closed) — 检索行为本身即内容访问 (标题=成员首句)。
	if err := emitContentViewedAudit(r.Context(), h.Pool, h.EventPub, auditTenant, scope,
		"conversation_search", "", map[string]any{
			"filters": map[string]any{
				"account_id":          q.Get("account_id"),
				"digital_employee_id": q.Get("digital_employee_id"),
				"q_set":               strings.TrimSpace(q.Get("q")) != "",
			},
		}); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit content access: %v", err))
		return
	}

	whereSQL := " WHERE " + strings.Join(where, " AND ")
	ctx := r.Context()
	var total int64
	if err := h.Pool.QueryRow(ctx, "SELECT count(*) FROM conversations c"+whereSQL, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("count conversations: %v", err))
		return
	}

	args = append(args, limit, offset)
	rows, err := h.Pool.Query(ctx, `
SELECT c.id, c.uuid, c.tenant_id, t.name, COALESCE(c.title, ''),
       c.account_id, COALESCE(NULLIF(acc.display_name,''), acc.username, acc.email, ''),
       c.digital_employee_id, COALESCE(de.name, ''),
       c.room_id, COALESCE(c.source, ''),
       c.last_message_at, c.created_at
FROM conversations c
JOIN tenants t ON t.id = c.tenant_id
LEFT JOIN accounts acc ON acc.id = c.account_id
LEFT JOIN digital_employees de ON de.id = c.digital_employee_id`+whereSQL+`
ORDER BY COALESCE(c.last_message_at, c.created_at) DESC
LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("list conversations: %v", err))
		return
	}
	defer rows.Close()

	items := []obsConversationDTO{}
	convIDs := []int64{}
	idxByConvID := map[int64]int{}
	for rows.Next() {
		var it obsConversationDTO
		var convID int64
		var lastAt *time.Time
		var createdAt time.Time
		if err := rows.Scan(&convID, &it.UUID, &it.TenantID, &it.TenantName, &it.Title,
			&it.AccountID, &it.AccountName,
			&it.DigitalEmployeeID, &it.AgentName,
			&it.RoomID, &it.Source,
			&lastAt, &createdAt); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan conversation: %v", err))
			return
		}
		if lastAt != nil {
			it.LastMessageAt = lastAt.Format(time.RFC3339)
		}
		it.CreatedAt = createdAt.Format(time.RFC3339)
		if fixedTenantID != nil {
			it.TenantName = ""
		}
		idxByConvID[convID] = len(items)
		convIDs = append(convIDs, convID)
		items = append(items, it)
	}
	rows.Close()

	// 消息数批量聚合 (review C18: 每行相关子查询 = 一页 50 次分区表 count 扫描)
	if len(convIDs) > 0 {
		cntRows, cerr := h.Pool.Query(ctx,
			`SELECT conversation_id, count(*) FROM messages WHERE conversation_id = ANY($1) GROUP BY conversation_id`, convIDs)
		if cerr != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("count messages: %v", cerr))
			return
		}
		defer cntRows.Close()
		for cntRows.Next() {
			var id, cnt int64
			if err := cntRows.Scan(&id, &cnt); err != nil {
				encode.JSONError(w, apperr.ErrInternal.Withf("scan message count: %v", err))
				return
			}
			if i, ok := idxByConvID[id]; ok {
				items[i].MessageCount = cnt
			}
		}
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}

func (h *ObservabilityAgentRunsHandler) getPlatformConversationMessages(w http.ResponseWriter, r *http.Request) {
	h.getConversationMessages(w, r, nil)
}

func (h *ObservabilityAgentRunsHandler) getTenantConversationMessages(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	h.getConversationMessages(w, r, &tid)
}

func (h *ObservabilityAgentRunsHandler) getConversationMessages(w http.ResponseWriter, r *http.Request, fixedTenantID *int64) {
	if h == nil || h.Pool == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent-run observability not wired"))
		return
	}
	convUUID := strings.TrimSpace(r.PathValue("uuid"))
	if convUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	scope := "tenant"
	if fixedTenantID == nil {
		scope = "platform"
	}
	ctx := r.Context()

	// 会话闸口: 租户侧跨租户 UUID → 404 (不泄漏存在性, F24 §13 场景 21)。
	var convID, convTenantID int64
	args := []any{convUUID}
	where := "WHERE uuid = $1 AND deleted_at IS NULL"
	if fixedTenantID != nil {
		args = append(args, *fixedTenantID)
		where += " AND tenant_id = $2"
	}
	err := h.Pool.QueryRow(ctx, "SELECT id, tenant_id FROM conversations "+where, args...).Scan(&convID, &convTenantID)
	if err != nil {
		if err == pgx.ErrNoRows {
			encode.JSONError(w, apperr.ErrNotFound.Withf("conversation not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Withf("get conversation: %v", err))
		return
	}

	limit := 100
	if v, perr := strconv.Atoi(r.URL.Query().Get("limit")); perr == nil && v > 0 && v <= 500 {
		limit = v
	}
	offset := 0
	if v, perr := strconv.Atoi(r.URL.Query().Get("offset")); perr == nil && v > 0 {
		offset = v
	}

	// L3 访问留痕 (fail-closed)
	if err := emitContentViewedAudit(ctx, h.Pool, h.EventPub, convTenantID, scope,
		"conversation_messages", convUUID, map[string]any{"limit": limit, "offset": offset}); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("audit content access: %v", err))
		return
	}

	var total int64
	if err := h.Pool.QueryRow(ctx, "SELECT count(*) FROM messages WHERE conversation_id = $1", convID).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("count messages: %v", err))
		return
	}
	rows, err := h.Pool.Query(ctx, `
SELECT uuid, role, sender_account_id, sender_agent_id, status, blocks,
       COALESCE(error_code, ''), created_at
FROM messages
WHERE conversation_id = $1
ORDER BY created_at, id
LIMIT $2 OFFSET $3`, convID, limit, offset)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("list messages: %v", err))
		return
	}
	defer rows.Close()

	items := []obsMessageDTO{}
	for rows.Next() {
		var m obsMessageDTO
		var blocks []byte
		var createdAt time.Time
		if err := rows.Scan(&m.UUID, &m.Role, &m.SenderAccountID, &m.SenderAgentID,
			&m.Status, &blocks, &m.ErrorCode, &createdAt); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("scan message: %v", err))
			return
		}
		m.CreatedAt = createdAt.Format(time.RFC3339)
		// §6.3 双保险: 渲染前兜底脱敏 (token/密钥/手机号/邮箱模式)。
		if h.Redactor != nil && len(blocks) > 0 {
			red, _ := h.Redactor.RedactJSON(blocks)
			m.Blocks = json.RawMessage(red)
		} else {
			m.Blocks = json.RawMessage(blocks)
		}
		items = append(items, m)
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "conversation_uuid": convUUID})
}
