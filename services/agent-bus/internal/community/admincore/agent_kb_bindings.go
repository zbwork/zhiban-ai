// agent_kb_bindings.go — F07 D5 数字员工 KB 绑定 admin CRUD。
//
// 路由 (租户 scope):
//
//	GET    /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings
//	POST   /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings
//	DELETE /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings/{kb_uuid}
//
// 权限: tenant.agent.update (跟数字员工能力装配同权限)。
package admincore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

// AgentKBBindingsHandler 用 Pool 直查 (避免引 service/agentkb 间接层)。
type AgentKBBindingsHandler struct {
	Pool      *pgxpool.Pool
	Knowledge svckb.Service
}

type agentKBBindingDTO struct {
	AgentUUID   string `json:"agent_uuid"`
	KBUUID      string `json:"kb_uuid"`
	KBName      string `json:"kb_name"`
	BindingKind string `json:"binding_kind"`
	Priority    int    `json:"priority"`
	Note        string `json:"note,omitempty"`
	CreatedAt   string `json:"created_at"`
	SpaceKind   string `json:"space_kind"`
	ManagedBy   string `json:"managed_by"`
	Editable    bool   `json:"editable"`
	KBStatus    string `json:"kb_status"`
}

// resolveAgentID 给 agent_uuid + tenant_id 反查 digital_employees.id; 校验同租户。
func (h *AgentKBBindingsHandler) resolveAgentID(r *http.Request, tenantID int64, agentUUID string) (int64, error) {
	var id int64
	err := h.Pool.QueryRow(r.Context(),
		`SELECT id FROM digital_employees WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`, agentUUID, tenantID).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.New(apperr.NotFound, "agent.not_found").Withf("agent %s not in tenant", agentUUID)
		}
		return 0, apperr.ErrInternal.Wrap(err)
	}
	return id, nil
}

// resolveKBID 给 kb_uuid + tenant_id 反查 knowledge_bases.id; 校验同租户。
func (h *AgentKBBindingsHandler) resolveKBID(r *http.Request, tenantID int64, kbUUID string) (int64, error) {
	if h.Knowledge != nil {
		if err := h.Knowledge.AssertKBAttachable(r.Context(), tenantID, kbUUID); err != nil {
			return 0, err
		}
	}
	var id int64
	err := h.Pool.QueryRow(r.Context(),
		`SELECT id FROM knowledge_bases
		  WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL
		    AND space_kind='tenant' AND visibility='tenant'`, kbUUID, tenantID).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.New(apperr.NotFound, "kb.not_found").Withf("kb %s not in tenant", kbUUID)
		}
		return 0, apperr.ErrInternal.Wrap(err)
	}
	return id, nil
}

// List GET /tenant/agents/{agent_uuid}/kb-bindings。
func (h *AgentKBBindingsHandler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	agentID, err := h.resolveAgentID(r, tenantID, agentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	rows, err := h.Pool.Query(r.Context(), `
SELECT k.uuid, k.name, b.binding_kind, b.priority, COALESCE(b.note,''), b.created_at::text,
       k.space_kind, k.status, k.provision_status
FROM agent_kb_bindings b
JOIN knowledge_bases k ON k.id=b.kb_id AND k.deleted_at IS NULL
WHERE b.agent_id=$1 AND b.deleted_at IS NULL
ORDER BY b.priority DESC, b.id ASC`, agentID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	items := make([]agentKBBindingDTO, 0)
	for rows.Next() {
		var dto agentKBBindingDTO
		var provisionStatus string
		dto.AgentUUID = agentUUID
		if err := rows.Scan(&dto.KBUUID, &dto.KBName, &dto.BindingKind, &dto.Priority, &dto.Note, &dto.CreatedAt, &dto.SpaceKind, &dto.KBStatus, &provisionStatus); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		dto.ManagedBy = "tenant"
		dto.Editable = dto.SpaceKind == "tenant"
		if dto.SpaceKind == "platform" {
			dto.ManagedBy = "platform"
		}
		if provisionStatus != "active" {
			dto.KBStatus = provisionStatus
		}
		items = append(items, dto)
	}
	encode.JSON(w, map[string]any{"items": items})
}

type attachBody struct {
	KBUUID      string `json:"kb_uuid"`
	BindingKind string `json:"binding_kind,omitempty"`
	Priority    int    `json:"priority,omitempty"`
	Note        string `json:"note,omitempty"`
}

type replacePlatformBindingsBody struct {
	KBUUIDs                []string `json:"kb_uuids"`
	ExpectedAgentUpdatedAt string   `json:"expected_agent_updated_at"`
}

// ListPlatformPreset lists only platform-owned bindings for a platform preset.
// Tenant/client callers never use this path, so the response can be safely
// submitted back without mixing ownership domains.
func (h *AgentKBBindingsHandler) ListPlatformPreset(w http.ResponseWriter, r *http.Request) {
	agentUUID := strings.TrimSpace(r.PathValue("uuid"))
	rows, err := h.Pool.Query(r.Context(), `
SELECT k.uuid, k.name, b.binding_kind, b.priority, COALESCE(b.note,''), b.created_at::text,
       k.space_kind, k.status, k.provision_status
FROM digital_employees a
JOIN agent_kb_bindings b ON b.agent_id=a.id AND b.deleted_at IS NULL
JOIN knowledge_bases k ON k.id=b.kb_id AND k.deleted_at IS NULL
WHERE a.uuid=$1 AND a.source='platform' AND a.tenant_id IS NULL AND a.deleted_at IS NULL
  AND k.space_kind='platform' AND k.tenant_id IS NULL
ORDER BY b.priority DESC, b.id ASC`, agentUUID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	items := make([]agentKBBindingDTO, 0)
	for rows.Next() {
		var dto agentKBBindingDTO
		var provisionStatus string
		dto.AgentUUID = agentUUID
		if err := rows.Scan(&dto.KBUUID, &dto.KBName, &dto.BindingKind, &dto.Priority, &dto.Note, &dto.CreatedAt, &dto.SpaceKind, &dto.KBStatus, &provisionStatus); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		dto.ManagedBy = "platform"
		dto.Editable = true
		if provisionStatus != "active" {
			dto.KBStatus = provisionStatus
		}
		items = append(items, dto)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

// ReplacePlatformPreset atomically replaces the platform-owned binding subset.
// The UUID list is validated inside the transaction; a tenant/private KB can
// therefore never be smuggled into a platform template.
func (h *AgentKBBindingsHandler) ReplacePlatformPreset(w http.ResponseWriter, r *http.Request) {
	accountID := middleware.MustAccountID(r.Context())
	if accountID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	var body replacePlatformBindingsBody
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body.KBUUIDs = dedupeNonEmptyStrings(body.KBUUIDs)
	expectedUpdatedAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(body.ExpectedAgentUpdatedAt))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("expected_agent_updated_at must be RFC3339"))
		return
	}
	tx, err := h.Pool.Begin(r.Context())
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer func() { _ = tx.Rollback(r.Context()) }()
	var (
		agentID        int64
		agentUpdatedAt time.Time
	)
	if err := tx.QueryRow(r.Context(), `
SELECT id, updated_at FROM digital_employees
WHERE uuid=$1 AND source='platform' AND tenant_id IS NULL AND deleted_at IS NULL
FOR UPDATE`, r.PathValue("uuid")).Scan(&agentID, &agentUpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "agent.not_found").Withf("platform preset not found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if !agentUpdatedAt.Equal(expectedUpdatedAt) {
		encode.JSONError(w, apperr.New(apperr.Conflict, "agent.version_conflict").Withf("platform preset was updated by another administrator"))
		return
	}
	kbIDs := make([]int64, 0, len(body.KBUUIDs))
	for _, kbUUID := range body.KBUUIDs {
		var kbID int64
		if err := tx.QueryRow(r.Context(), `
SELECT id FROM knowledge_bases
WHERE uuid=$1 AND tenant_id IS NULL AND space_kind='platform'
  AND access_mode='agent_only' AND status='active' AND provision_status='active'
  AND deleted_at IS NULL
FOR SHARE`, kbUUID).Scan(&kbID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				encode.JSONError(w, apperr.New(apperr.Conflict, "kb.not_attachable").Withf("platform knowledge base %s is unavailable", kbUUID))
				return
			}
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		kbIDs = append(kbIDs, kbID)
	}
	if _, err := tx.Exec(r.Context(), `
UPDATE agent_kb_bindings b SET deleted_at=now(), updated_at=now()
FROM knowledge_bases k
WHERE b.agent_id=$1 AND b.kb_id=k.id AND b.deleted_at IS NULL
  AND k.space_kind='platform' AND k.tenant_id IS NULL`, agentID); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	for i, kbID := range kbIDs {
		if _, err := tx.Exec(r.Context(), `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, created_by)
VALUES ($1,$2,'attached',$3,$4)
ON CONFLICT (agent_id,kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind='attached', priority=EXCLUDED.priority, updated_at=now()`,
			agentID, kbID, len(kbIDs)-i, accountID); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
	}
	var newUpdatedAt time.Time
	if err := tx.QueryRow(r.Context(), `
UPDATE digital_employees SET updated_at=now() WHERE id=$1 RETURNING updated_at`, agentID).Scan(&newUpdatedAt); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{
		"agent_uuid": r.PathValue("uuid"), "kb_uuids": body.KBUUIDs,
		"agent_updated_at": newUpdatedAt,
	})
}

// Attach POST /tenant/agents/{agent_uuid}/kb-bindings — 绑 KB。
func (h *AgentKBBindingsHandler) Attach(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	accountID := middleware.MustAccountID(r.Context())
	if tenantID <= 0 || accountID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	var body attachBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body.KBUUID = strings.TrimSpace(body.KBUUID)
	if body.KBUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("kb_uuid required"))
		return
	}
	if body.BindingKind == "" {
		body.BindingKind = "attached"
	}
	switch body.BindingKind {
	case "attached", "required", "optional":
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("binding_kind must be attached|required|optional"))
		return
	}
	agentID, err := h.resolveAgentID(r, tenantID, agentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	kbID, err := h.resolveKBID(r, tenantID, body.KBUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	_, err = h.Pool.Exec(r.Context(), `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, note, created_by)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind=EXCLUDED.binding_kind, priority=EXCLUDED.priority, note=EXCLUDED.note, updated_at=now()`,
		agentID, kbID, body.BindingKind, body.Priority, body.Note, accountID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{
		"agent_uuid":   agentUUID,
		"kb_uuid":      body.KBUUID,
		"binding_kind": body.BindingKind,
		"priority":     body.Priority,
	})
}

// Detach DELETE /tenant/agents/{agent_uuid}/kb-bindings/{kb_uuid}。
func (h *AgentKBBindingsHandler) Detach(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	kbUUID := r.PathValue("kb_uuid")
	agentID, err := h.resolveAgentID(r, tenantID, agentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	kbID, err := h.resolveKBID(r, tenantID, kbUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	tag, err := h.Pool.Exec(r.Context(),
		`UPDATE agent_kb_bindings SET deleted_at=now(), updated_at=now()
		 WHERE agent_id=$1 AND kb_id=$2 AND deleted_at IS NULL`, agentID, kbID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if tag.RowsAffected() == 0 {
		encode.JSONError(w, apperr.New(apperr.NotFound, "agent_kb_binding.not_found").Withf("binding not found"))
		return
	}
	encode.JSON(w, map[string]any{"detached": true})
}

func dedupeNonEmptyStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}
