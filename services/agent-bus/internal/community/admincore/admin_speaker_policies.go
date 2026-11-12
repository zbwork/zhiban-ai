// F09 Phase B.4 / PR8 (B4-03): Speaker 策略 admin CRUD (租户 scope).
//
// 路由:
//   GET    /api/admin/v1/tenant/speaker-policies            — 列表
//   POST   /api/admin/v1/tenant/speaker-policies            — 新建
//   GET    /api/admin/v1/tenant/speaker-policies/{uuid}     — 详情
//   PUT    /api/admin/v1/tenant/speaker-policies/{uuid}     — 更新
//   DELETE /api/admin/v1/tenant/speaker-policies/{uuid}     — 软删 (is_deleted=true)
//
// 权限: tenant.agent.read (read) / tenant.agent.update (write).
// 写: 用 manager_agent_uuid (UUID) 接受 admin 输入; 内部转 manager_agent_id.

package admincore

import (
	"context"
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
)

// AdminSpeakerPoliciesHandler · F09-B4-03.
type AdminSpeakerPoliciesHandler struct {
	Pool *pgxpool.Pool
}

type speakerPolicy struct {
	UUID                         string          `json:"uuid"`
	Name                         string          `json:"name"`
	Description                  string          `json:"description,omitempty"`
	IsTemplate                   bool            `json:"is_template"`
	BasePolicy                   string          `json:"base_policy"`
	ManagerAgentID               *int64          `json:"manager_agent_id,omitempty"`
	ManagerAgentUUID             string          `json:"manager_agent_uuid,omitempty"`
	ManagerAgentName             string          `json:"manager_agent_name,omitempty"`
	SelectorConfig               json.RawMessage `json:"selector_config"`
	MaxSpeakerDecisionsPerMinute int32           `json:"max_speaker_decisions_per_minute"`
	CreatedAt                    string          `json:"created_at"`
	UpdatedAt                    string          `json:"updated_at"`
}

type speakerPolicyListResp struct {
	Items    []speakerPolicy `json:"items"`
	Total    int             `json:"total"`
	Page     int             `json:"page"`
	PageSize int             `json:"page_size"`
}

// 合法 base_policy 集合 (与 DB CHECK 一致).
var validBasePolicies = map[string]bool{
	"manual": true, "round_robin": true, "auto_llm": true, "manager": true, "parallel": true, "handoff": true,
}

// List GET /api/admin/v1/tenant/speaker-policies?is_template=&q=&page=&page_size=
func (h *AdminSpeakerPoliciesHandler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	q := r.URL.Query()
	page, pageSize := parsePagination(q)
	offset := (page - 1) * pageSize

	conds := "WHERE p.tenant_id=$1 AND p.is_deleted=false"
	args := []any{tenantID}
	idx := 2
	if v := getQ(q, "is_template"); v == "true" || v == "false" {
		conds += " AND p.is_template=$2"
		args = append(args, v == "true")
		idx++
	}
	if v := getQ(q, "q"); v != "" {
		conds += " AND p.name ILIKE $" + itoa(idx)
		args = append(args, "%"+v+"%")
		idx++
	}

	var total int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM speaker_policies p `+conds, args...).Scan(&total); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	args = append(args, pageSize, offset)
	rows, err := h.Pool.Query(r.Context(), `
		SELECT p.uuid, p.name, COALESCE(p.description,''), p.is_template,
		       p.base_policy, p.manager_agent_id, COALESCE(de.uuid::text,''), COALESCE(de.name,''),
		       p.selector_config, p.max_speaker_decisions_per_minute,
		       p.created_at, p.updated_at
		  FROM speaker_policies p
		  LEFT JOIN digital_employees de ON de.id = p.manager_agent_id
		`+conds+`
		 ORDER BY p.created_at DESC
		 LIMIT $`+itoa(idx)+` OFFSET $`+itoa(idx+1),
		args...,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()

	items := make([]speakerPolicy, 0)
	for rows.Next() {
		var (
			p         speakerPolicy
			managerID *int64
			cfgBytes  []byte
			createdAt time.Time
			updatedAt time.Time
		)
		if err := rows.Scan(&p.UUID, &p.Name, &p.Description, &p.IsTemplate,
			&p.BasePolicy, &managerID, &p.ManagerAgentUUID, &p.ManagerAgentName,
			&cfgBytes, &p.MaxSpeakerDecisionsPerMinute,
			&createdAt, &updatedAt,
		); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		p.ManagerAgentID = managerID
		p.SelectorConfig = json.RawMessage(cfgBytes)
		p.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		p.UpdatedAt = updatedAt.UTC().Format(time.RFC3339)
		items = append(items, p)
	}
	if err := rows.Err(); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, speakerPolicyListResp{Items: items, Total: total, Page: page, PageSize: pageSize})
}

type speakerPolicyUpsert struct {
	Name                         string          `json:"name"`
	Description                  string          `json:"description,omitempty"`
	IsTemplate                   bool            `json:"is_template,omitempty"`
	BasePolicy                   string          `json:"base_policy"`
	ManagerAgentUUID             string          `json:"manager_agent_uuid,omitempty"`
	SelectorConfig               json.RawMessage `json:"selector_config,omitempty"`
	MaxSpeakerDecisionsPerMinute int32           `json:"max_speaker_decisions_per_minute,omitempty"`
}

// Create POST /api/admin/v1/tenant/speaker-policies
func (h *AdminSpeakerPoliciesHandler) Create(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	var in speakerPolicyUpsert
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("name required"))
		return
	}
	if !validBasePolicies[in.BasePolicy] {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("base_policy invalid: %q", in.BasePolicy))
		return
	}

	// manager_agent_uuid → manager_agent_id
	managerID, err := h.resolveAgentUUIDOptional(r.Context(), tenantID, in.ManagerAgentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if in.BasePolicy == "manager" && managerID == nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("base_policy=manager requires manager_agent_uuid"))
		return
	}
	cfg := in.SelectorConfig
	if len(cfg) == 0 {
		cfg = []byte("{}")
	}
	maxRPM := in.MaxSpeakerDecisionsPerMinute
	if maxRPM <= 0 {
		maxRPM = 30
	}
	createdBy := middleware.MustAccountID(r.Context())

	row := h.Pool.QueryRow(r.Context(), `
		INSERT INTO speaker_policies
		  (tenant_id, name, description, is_template, base_policy, manager_agent_id,
		   selector_config, max_speaker_decisions_per_minute, created_by, updated_by)
		VALUES ($1, $2, NULLIF($3,''), $4, $5, $6, $7::jsonb, $8, $9, $9)
		RETURNING uuid`,
		tenantID, in.Name, in.Description, in.IsTemplate, in.BasePolicy, managerID,
		string(cfg), maxRPM, nullableAccountID(createdBy),
	)
	var newUUID string
	if err := row.Scan(&newUUID); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	h.getByUUID(w, r, tenantID, newUUID)
}

// Get GET /api/admin/v1/tenant/speaker-policies/{uuid}
func (h *AdminSpeakerPoliciesHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	h.getByUUID(w, r, tenantID, r.PathValue("uuid"))
}

// Update PUT /api/admin/v1/tenant/speaker-policies/{uuid}
func (h *AdminSpeakerPoliciesHandler) Update(w http.ResponseWriter, r *http.Request) {
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
	var in speakerPolicyUpsert
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("name required"))
		return
	}
	if !validBasePolicies[in.BasePolicy] {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("base_policy invalid"))
		return
	}
	managerID, err := h.resolveAgentUUIDOptional(r.Context(), tenantID, in.ManagerAgentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if in.BasePolicy == "manager" && managerID == nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("base_policy=manager requires manager_agent_uuid"))
		return
	}
	cfg := in.SelectorConfig
	if len(cfg) == 0 {
		cfg = []byte("{}")
	}
	maxRPM := in.MaxSpeakerDecisionsPerMinute
	if maxRPM <= 0 {
		maxRPM = 30
	}
	updatedBy := middleware.MustAccountID(r.Context())

	res, err := h.Pool.Exec(r.Context(), `
		UPDATE speaker_policies
		   SET name=$3, description=NULLIF($4,''), is_template=$5,
		       base_policy=$6, manager_agent_id=$7,
		       selector_config=$8::jsonb,
		       max_speaker_decisions_per_minute=$9,
		       updated_by=$10, updated_at=now()
		 WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false`,
		tenantID, uuid,
		in.Name, in.Description, in.IsTemplate,
		in.BasePolicy, managerID,
		string(cfg), maxRPM,
		nullableAccountID(updatedBy),
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if res.RowsAffected() == 0 {
		encode.JSONError(w, apperr.New(apperr.NotFound, "speaker_policy.not_found"))
		return
	}
	h.getByUUID(w, r, tenantID, uuid)
}

// Delete DELETE /api/admin/v1/tenant/speaker-policies/{uuid}
// 软删: is_deleted=true + deleted_at=now() + updated_by.
func (h *AdminSpeakerPoliciesHandler) Delete(w http.ResponseWriter, r *http.Request) {
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
	updatedBy := middleware.MustAccountID(r.Context())
	res, err := h.Pool.Exec(r.Context(), `
		UPDATE speaker_policies
		   SET is_deleted=true, deleted_at=now(), updated_by=$3, updated_at=now()
		 WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false`,
		tenantID, uuid, nullableAccountID(updatedBy),
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if res.RowsAffected() == 0 {
		encode.JSONError(w, apperr.New(apperr.NotFound, "speaker_policy.not_found"))
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

func (h *AdminSpeakerPoliciesHandler) getByUUID(w http.ResponseWriter, r *http.Request, tenantID int64, uuid string) {
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	var (
		p         speakerPolicy
		managerID *int64
		cfgBytes  []byte
		createdAt time.Time
		updatedAt time.Time
	)
	err := h.Pool.QueryRow(r.Context(), `
		SELECT p.uuid, p.name, COALESCE(p.description,''), p.is_template,
		       p.base_policy, p.manager_agent_id, COALESCE(de.uuid::text,''), COALESCE(de.name,''),
		       p.selector_config, p.max_speaker_decisions_per_minute,
		       p.created_at, p.updated_at
		  FROM speaker_policies p
		  LEFT JOIN digital_employees de ON de.id = p.manager_agent_id
		 WHERE p.tenant_id=$1 AND p.uuid=$2 AND p.is_deleted=false`,
		tenantID, uuid,
	).Scan(&p.UUID, &p.Name, &p.Description, &p.IsTemplate,
		&p.BasePolicy, &managerID, &p.ManagerAgentUUID, &p.ManagerAgentName,
		&cfgBytes, &p.MaxSpeakerDecisionsPerMinute,
		&createdAt, &updatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "speaker_policy.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	p.ManagerAgentID = managerID
	p.SelectorConfig = json.RawMessage(cfgBytes)
	p.CreatedAt = createdAt.UTC().Format(time.RFC3339)
	p.UpdatedAt = updatedAt.UTC().Format(time.RFC3339)
	encode.JSON(w, p)
}

func (h *AdminSpeakerPoliciesHandler) resolveAgentUUIDOptional(ctx context.Context, tenantID int64, agentUUID string) (*int64, error) {
	agentUUID = strings.TrimSpace(agentUUID)
	if agentUUID == "" {
		return nil, nil
	}
	var id int64
	err := h.Pool.QueryRow(ctx,
		`SELECT id FROM digital_employees WHERE uuid=$1 AND tenant_id=$2`,
		agentUUID, tenantID,
	).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrInvalidParams.Withf("manager_agent_uuid not found in tenant")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &id, nil
}

// nullableAccountID — middleware.MustAccountID 返 0 = "无身份"; SQL 写 NULL.
func nullableAccountID(id int64) any {
	if id <= 0 {
		return nil
	}
	return id
}

// itoa — strconv.Itoa 别名 (跟 admin 包内其它 helper 一致避免再 import).
func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	// 简单实现; 单测 / 生产 调用通常 n < 30 (column index)
	out := ""
	for n > 0 {
		out = string(rune('0'+n%10)) + out
		n /= 10
	}
	return out
}
