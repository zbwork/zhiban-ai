// A2A v1a/v1b (plans/2026-07-06 §13.1 / §14.1): a2a_invoke 发起 capability 最小后端开关。
//
// 路由:
//   GET /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability   → {enabled}
//   PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability   body {enabled} → {enabled}
//
// 权限: tenant.agent.read / tenant.agent.update (与 callable-by-agents 对齐)。
//
// 语义 (v1b 拍板, boundaries §3.4 / database-design §5.3): a2a_invoke 是**非版本化运行时开关**,
// 唯一合法形态 = 哨兵行 (agent_version_id IS NULL + capability_uuid=uuid_nil + source='borrow')。
// 本开关 GET/PUT **只读写哨兵行**:
//   - GET: 只有哨兵行存在才算 enabled (versioned 残留行不算);
//   - PUT enabled=true: WHERE NOT EXISTS 幂等插入哨兵行 (UNIQUE 在 version NULL 时不去重);
//   - PUT enabled=false: 只删哨兵行, **不**触碰 versioned 行与其它 capability_kind
//     (历史 versioned a2a_invoke 脏数据由发布路径排除复制后自然停增, 存量清理见 PR10 follow-up)。
//
// 本文件只做布尔开关, 不做 outbound policy (可调用对象/scope) —— 那是独立 schema 设计 (v2)。
// audit: PUT 成功后写 tenant.agent.a2a_invoke_capability.update, 只记录开关摘要。

package admincore

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// 三条 SQL 提为常量供单测断言哨兵谓词 (仓库无 live-DB 测试基建)。
//
// 哨兵行三条件齐 (v1b review 返修): version NULL + uuid_nil + source='borrow', 与文档定义一致。
// GET / enable-NOT-EXISTS / disable 都严格按三条件 —— 异常 source 的行 (不合法哨兵) 读不算
// enabled、关不被删, 全程惰性存在, 物理清理随 PR10 follow-up 的脏数据清理一并处理;
// enable 在存在异常行时仍会插入合法 borrow 哨兵行 (UNIQUE 对 version NULL 不去重, 共存无害)。
const (
	a2aInvokeGetSentinelSQL = `
		SELECT EXISTS(
			SELECT 1 FROM agent_capability_bindings
			 WHERE digital_employee_id=$1 AND capability_kind='a2a_invoke'
			   AND agent_version_id IS NULL AND capability_uuid=$2::uuid
			   AND source='borrow'
		)`
	a2aInvokeEnableSentinelSQL = `
		INSERT INTO agent_capability_bindings
			(digital_employee_id, agent_version_id, capability_kind, capability_uuid, source)
		SELECT $1, NULL, 'a2a_invoke', $2::uuid, 'borrow'
		 WHERE NOT EXISTS (
			SELECT 1 FROM agent_capability_bindings
			 WHERE digital_employee_id=$1 AND capability_kind='a2a_invoke'
			   AND agent_version_id IS NULL AND capability_uuid=$2::uuid
			   AND source='borrow'
		 )`
	a2aInvokeDisableSentinelSQL = `
		DELETE FROM agent_capability_bindings
		 WHERE digital_employee_id=$1 AND capability_kind='a2a_invoke'
		   AND agent_version_id IS NULL AND capability_uuid=$2::uuid
		   AND source='borrow'`
)

// AdminAgentA2AInvokeHandler · A2A v1a/v1b 发起 capability 开关。
type AdminAgentA2AInvokeHandler struct {
	Pool  *pgxpool.Pool
	Audit domaudit.Store
}

type a2aInvokeCapabilityDTO struct {
	Enabled bool `json:"enabled"`
}

// resolveAgentID agent_id → digital_employees.id (本租户, 未软删); 不存在 → NotFound。
func (h *AdminAgentA2AInvokeHandler) resolveAgentID(r *http.Request, tenantID int64) (int64, error) {
	agentUUID := r.PathValue("agent_id")
	if agentUUID == "" {
		return 0, apperr.ErrInvalidParams.Withf("agent_id required")
	}
	var id int64
	err := h.Pool.QueryRow(r.Context(),
		`SELECT id FROM digital_employees
		  WHERE uuid=$1 AND tenant_id=$2 AND is_deleted=false`,
		agentUUID, tenantID).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.New(apperr.NotFound, "agent.not_found")
		}
		return 0, apperr.ErrInternal.Wrap(err)
	}
	return id, nil
}

// Get GET /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability
func (h *AdminAgentA2AInvokeHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentID, err := h.resolveAgentID(r, tenantID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var enabled bool
	if err := h.Pool.QueryRow(r.Context(), a2aInvokeGetSentinelSQL,
		agentID, domagent.A2AInvokeSentinelUUID).Scan(&enabled); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, a2aInvokeCapabilityDTO{Enabled: enabled})
}

// Update PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability  body {enabled}
func (h *AdminAgentA2AInvokeHandler) Update(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentID, err := h.resolveAgentID(r, tenantID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var in a2aInvokeCapabilityDTO
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if in.Enabled {
		_, err = h.Pool.Exec(r.Context(), a2aInvokeEnableSentinelSQL, agentID, domagent.A2AInvokeSentinelUUID)
	} else {
		_, err = h.Pool.Exec(r.Context(), a2aInvokeDisableSentinelSQL, agentID, domagent.A2AInvokeSentinelUUID)
	}
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	fireAgentCollaborationAudit(r.Context(), h.Audit, tenantID, middleware.MustAccountID(r.Context()), r.PathValue("agent_id"),
		"tenant.agent.a2a_invoke_capability.update", map[string]any{"enabled": in.Enabled})
	encode.JSON(w, in)
}
