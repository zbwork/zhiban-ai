package contacts

import (
	"context"
	"time"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// PrewarmTarget 是 doc-10 登录预热需要的单条"对该用户可见 + 已绑定 runtime 环境"的数字员工。
//
// 复用本包权威可见性 (IsAgentVisible + 部门 path + contact policy), 让预热集合与
// GET /contacts/agents 100% 一致, 避免在别处重复实现可见性 (安全敏感)。
type PrewarmTarget struct {
	DigitalEmployeeUUID  string
	DigitalEmployeeName  string
	RuntimeEnvironmentID int64
	// RuntimeHostingKind: clawmanager | k8s_native | external_endpoint。
	// 供 buildPlan 判定 agent_register 当前是否可执行 (S5/G3 未接通前 clawmanager/k8s 不生成 agent_register, doc-10 §7.8)。
	RuntimeHostingKind string
	// DigitalEmployeeUpdatedAt / RuntimeEnvUpdatedAt: doc-10 §5b 幂等 ensure 的目标签名源 ——
	// DE 配置 / runtime 环境配置变化时各自 updated_at bump, 据此判定 agent_register / instance_init 是否需重新生成。
	DigitalEmployeeUpdatedAt time.Time
	RuntimeEnvUpdatedAt      time.Time
	// IdentityProvisionEnabled: external/ZAP runtime 登录预热按 tenant/account/env/数字员工生成
	// agent_instance_init 任务；真正调用前由 Bus 再检查 runtime_card 是否声明实例初始化能力。
	// ADR-0037 Phase 1 任务组 5 起, BYOK (ModelSource='byok') 的 clawmanager/k8s_native 数字员工
	// 也为 true——同一个任务类型, 但语义是"建/找它自己专属的 pod", 见 IsBYOK。
	IdentityProvisionEnabled bool
	// ModelSource: digital_employees.model_source ('platform_whitelist' | 'byok')。
	ModelSource string
}

// PrewarmTargets 返回 caller 在其租户下可见、已 published/contact_enabled、且 runtime_environment_id 非空
// 的数字员工 (供 doc-10 登录预热按 runtime 环境分组建任务)。
//
// 与 Agents 同一条可见性路径 (runAgentRows → IsAgentVisible); 仅额外要求 runtime_environment_id IS NOT NULL,
// 并把 runtime 环境 id 透出 (Agents 的 DTO 不带 runtime 信息, 故单列此方法)。
func (s *impl) PrewarmTargets(ctx context.Context, caller CallerCtx) ([]PrewarmTarget, error) {
	if caller.TenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing tenant")
	}
	policy, err := s.policy(ctx, caller.TenantID)
	if err != nil {
		return nil, err
	}
	// 复用 agentsBaseSelect 的可见性列 (含其 SELECT + FROM/JOIN), 末尾 JOIN runtime_environments
	// 取 hosting_kind, 再加 WHERE。注意: 额外的 SELECT 列必须并入 agentsBaseSelect 内部的 SELECT 列表,
	// 不能直接 `agentsBaseSelect + ", col"` (那样列会落到 FROM 之后, 语法错误)。
	// 这里独立写完整 SQL, 列顺序与下方 Scan 对齐。
	const sql = `
		WITH caller_dept AS (
			SELECT COALESCE(d.path, '') AS caller_dept_path
			FROM (
				SELECT COALESCE(NULLIF($2::bigint, 0), tm.department_id) AS department_id
				FROM (SELECT 1) one
				LEFT JOIN tenant_memberships tm
				       ON tm.account_id = $3 AND tm.tenant_id = $1 AND tm.deleted_at IS NULL
			) c
			LEFT JOIN departments d ON d.id = c.department_id AND d.deleted_at IS NULL
		)
		SELECT de.id, de.uuid, de.name, COALESCE(de.avatar_url,''),
		       COALESCE(de.position_label, COALESCE(de.intro,'')),
		       de.badges, de.source, de.status, de.visibility,
		       de.contact_enabled, de.allow_invite_to_group, de.supports_group_chat,
		       de.tenant_id, de.workspace_id, d.path, d.uuid, d.name,
		       de.creator_id,
		       COALESCE(ov.hidden, false) AS override_hidden,
		       de.runtime_environment_id,
		       COALESCE(re.hosting_kind, '') AS hosting_kind,
		       COALESCE(re.framework, '') AS runtime_framework,
		       COALESCE(de.model_source, 'platform_whitelist') AS model_source,
		       de.updated_at,
		       COALESCE(re.updated_at, 'epoch'::timestamptz) AS env_updated_at,
		       cd.caller_dept_path
		FROM digital_employees de
		CROSS JOIN caller_dept cd
		LEFT JOIN departments d ON d.id = de.workspace_id AND d.deleted_at IS NULL
		LEFT JOIN digital_employee_visibility_overrides ov
		       ON ov.digital_employee_id = de.id AND ov.tenant_id = $1
		LEFT JOIN runtime_environments re
		       ON re.id = de.runtime_environment_id AND re.is_deleted = false
		WHERE de.deleted_at IS NULL
		  AND de.status = 'published'
		  AND de.contact_enabled = true
		  -- ADR-0052: 平台数字员工不再复制；云端平台员工按当前租户/账号预热运行实例。
		  AND (de.tenant_id = $1 OR (de.tenant_id IS NULL AND de.source = 'platform' AND de.visibility = 'platform'))
		  AND de.runtime_environment_id IS NOT NULL
		ORDER BY de.runtime_environment_id, de.name`

	rows, err := s.pool.Query(ctx, sql, caller.TenantID, caller.DepartmentID, caller.AccountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []PrewarmTarget{}
	for rows.Next() {
		var r agentRow
		var runtimeEnvID int64
		var hostingKind, runtimeFramework, modelSource string
		var deUpdatedAt, envUpdatedAt time.Time
		var callerDeptPath string
		if err := rows.Scan(&r.ID, &r.UUID, &r.Name, &r.AvatarURL, &r.PositionLabel,
			&r.BadgesJSON, &r.Source, &r.Status, &r.Visibility,
			&r.ContactEnabled, &r.AllowInviteToGroup, &r.SupportsGroupChat,
			&r.TenantID, &r.WorkspaceID, &r.WorkspacePath, &r.WorkspaceUUID, &r.WorkspaceName,
			&r.CreatorID, &r.OverrideHidden, &runtimeEnvID, &hostingKind,
			&runtimeFramework, &modelSource, &deUpdatedAt, &envUpdatedAt, &callerDeptPath); err != nil {
			return nil, err
		}
		callerVis := CallerVisibility{
			AccountID:          caller.AccountID,
			TenantID:           caller.TenantID,
			DepartmentPath:     callerDeptPath,
			ShowPlatformAgents: policy.ShowPlatformAgents,
		}
		in := AgentVisibilityInput{
			Status: r.Status, ContactEnabled: r.ContactEnabled,
			Source: r.Source, Visibility: r.Visibility,
			OverrideHidden: r.OverrideHidden,
		}
		if r.TenantID != nil {
			in.TenantID = *r.TenantID
		}
		if r.WorkspaceID != nil {
			in.WorkspaceID = *r.WorkspaceID
		}
		if r.WorkspacePath != nil {
			in.WorkspacePath = *r.WorkspacePath
		}
		if r.CreatorID != nil {
			in.CreatorID = *r.CreatorID
		}
		visible, _ := IsAgentVisible(in, callerVis)
		if !visible {
			continue
		}
		isBYOK := modelSource == "byok" && hostingKind != "external_endpoint"
		out = append(out, PrewarmTarget{
			DigitalEmployeeUUID:      r.UUID,
			DigitalEmployeeName:      r.Name,
			RuntimeEnvironmentID:     runtimeEnvID,
			RuntimeHostingKind:       hostingKind,
			DigitalEmployeeUpdatedAt: deUpdatedAt,
			RuntimeEnvUpdatedAt:      envUpdatedAt,
			IdentityProvisionEnabled: (hostingKind == "external_endpoint" && (runtimeFramework == "zap" || runtimeFramework == "dsh")) || isBYOK,
			ModelSource:              modelSource,
		})
	}
	return out, rows.Err()
}
