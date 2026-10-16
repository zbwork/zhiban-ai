package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/auditpg"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// F02 v0.3: integration_mode 列已删 (migration 000060); runtime_registration_id 改 runtime_environment_id;
// 加 created_by/updated_by/is_deleted 8 字段审计字段。
// 注意: 末尾列 model_service_api_key_prefix (ADR-0037, migration 000132) 之后
// 才是各查询自行追加的 deptCol / COUNT(*) 等尾列; 增删列必须同步 scanInto +
// List/listTenantWithPlatformPresets 两处内联 scan。
const baseCols = `id, uuid, COALESCE(tenant_id, 0), COALESCE(creator_id, 0), name, COALESCE(avatar_url,''), COALESCE(intro,''),
    COALESCE(description,''), COALESCE(welcome_msg,''), recommended_questions, tags,
    visibility, workspace_id, is_default_for_creator, runtime_environment_id,
    COALESCE(model_primary,''), model_fallbacks, temperature, context_window,
    tool_allow, tool_deny, capabilities_declared, status, current_version,
    callable_by_agents, supports_group_chat, is_system, metadata,
    created_at, created_by, updated_at, updated_by, is_deleted, deleted_at,
    COALESCE(position_label,''), badges, source, contact_enabled, allow_invite_to_group,
    a2a_card, model_source, model_service_config, COALESCE(model_service_api_key_prefix,''), execution_locus, COALESCE(local_engine,'')`

const deBaseCols = `de.id, de.uuid, COALESCE(de.tenant_id, 0), COALESCE(de.creator_id, 0), de.name, COALESCE(de.avatar_url,''), COALESCE(de.intro,''),
    COALESCE(de.description,''), COALESCE(de.welcome_msg,''), de.recommended_questions, de.tags,
    de.visibility, de.workspace_id, de.is_default_for_creator, de.runtime_environment_id,
    COALESCE(de.model_primary,''), de.model_fallbacks, de.temperature, de.context_window,
    de.tool_allow, de.tool_deny, de.capabilities_declared, de.status, de.current_version,
    de.callable_by_agents, de.supports_group_chat, de.is_system, de.metadata,
    de.created_at, de.created_by, de.updated_at, de.updated_by, de.is_deleted, de.deleted_at,
    COALESCE(de.position_label,''), de.badges, de.source, de.contact_enabled, de.allow_invite_to_group,
    de.a2a_card, de.model_source, de.model_service_config, COALESCE(de.model_service_api_key_prefix,''), de.execution_locus, COALESCE(de.local_engine,'')`

const creatorCol = `, COALESCE(NULLIF(tm_creator.nickname,''), NULLIF(a_creator.display_name,''), NULLIF(a_creator.username,''), NULLIF(a_creator.phone,''), NULLIF(a_creator.email,''), '') AS creator_name`
const creatorJoin = ` LEFT JOIN accounts a_creator ON a_creator.id = de.creator_id AND a_creator.deleted_at IS NULL
	LEFT JOIN tenant_memberships tm_creator
		ON tm_creator.tenant_id = de.tenant_id
		AND tm_creator.account_id = de.creator_id
		AND tm_creator.deleted_at IS NULL`

// creatorCol / creatorJoin + deptCol / deptJoin: 管理后台需要创建人展示名, 客户端聊天顶栏需要数字员工归属部门名。读路径 (GetByID / GetByUUID /
// List / listTenantWithPlatformPresets) 都已对 digital_employees 起别名 `de`, 直接附加 join +
// 末尾 SELECT 尾列, 由 scanWithDept 一并扫到 DigitalEmployee.CreatorName / DepartmentName。
// Create / Update / Archive / Restore 的 RETURNING **不带**部门 (RETURNING 不支持 JOIN),
// 由调用方按需 refetch。
const deptCol = `, COALESCE(d.name, '') AS department_name`
const deptJoin = ` LEFT JOIN departments d ON d.id = de.workspace_id AND d.deleted_at IS NULL`

func scan(row pgx.Row) (*dom.DigitalEmployee, error) {
	return scanInto(row, false)
}

// scanWithDept 读路径专用: 比 baseCols 末尾多 creator_name / department_name。
func scanWithDept(row pgx.Row) (*dom.DigitalEmployee, error) {
	return scanInto(row, true)
}

func scanInto(row pgx.Row, withDept bool) (*dom.DigitalEmployee, error) {
	var e dom.DigitalEmployee
	var rq []byte
	var tags, mf, allow, deny []string
	var caps, meta, badges []byte
	dest := []any{&e.ID, &e.UUID, &e.TenantID, &e.CreatorID, &e.Name, &e.AvatarURL, &e.Intro,
		&e.Description, &e.WelcomeMsg, &rq, &tags,
		&e.Visibility, &e.WorkspaceID, &e.IsDefaultForCreator, &e.RuntimeEnvironmentID,
		&e.ModelPrimary, &mf, &e.Temperature, &e.ContextWindow,
		&allow, &deny, &caps, &e.Status, &e.CurrentVersion,
		&e.CallableByAgentsJSON, &e.SupportsGroupChat, &e.IsSystem, &meta,
		&e.CreatedAt, &e.CreatedBy, &e.UpdatedAt, &e.UpdatedBy, &e.IsDeleted, &e.DeletedAt,
		&e.PositionLabel, &badges, &e.Source, &e.ContactEnabled, &e.AllowInviteToGroup,
		&e.A2ACardJSON, &e.ModelSource, &e.ModelServiceConfigJSON, &e.ModelServiceAPIKeyPrefix, &e.ExecutionLocus, &e.LocalEngine}
	if withDept {
		dest = append(dest, &e.CreatorName, &e.DepartmentName)
	}
	if err := row.Scan(dest...); err != nil {
		return nil, err
	}
	if len(rq) > 0 {
		_ = json.Unmarshal(rq, &e.RecommendedQuestions)
	}
	e.Tags = tags
	e.ModelFallbacks = mf
	e.ToolAllow = allow
	e.ToolDeny = deny
	if len(caps) > 0 {
		_ = json.Unmarshal(caps, &e.CapabilitiesDeclared)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &e.Metadata)
	}
	if len(badges) > 0 {
		_ = json.Unmarshal(badges, &e.Badges)
	}
	if e.Badges == nil {
		e.Badges = []string{}
	}
	return &e, nil
}

// parsePgTextArray 解析 Postgres text[] 文本形式 `{a,b,c}`。
func parsePgTextArray(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	s := string(b)
	s = strings.TrimPrefix(s, "{")
	s = strings.TrimSuffix(s, "}")
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		p = strings.Trim(p, `"`)
		out = append(out, p)
	}
	return out
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+deBaseCols+creatorCol+deptCol+` FROM digital_employees de`+creatorJoin+deptJoin+` WHERE de.id=$1 AND de.deleted_at IS NULL`, id)
	e, err := scanWithDept(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return e, nil
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+deBaseCols+creatorCol+deptCol+` FROM digital_employees de`+creatorJoin+deptJoin+` WHERE de.uuid=$1 AND de.deleted_at IS NULL`, uuid)
	e, err := scanWithDept(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return e, nil
}

// NamesByUUIDs 批量解析数字员工名称, 供客户端 DTO 组装避免 N+1 查询。
func (r *Repo) NamesByUUIDs(ctx context.Context, uuids []string) (map[string]string, error) {
	out := map[string]string{}
	if len(uuids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
SELECT uuid::text, name
FROM digital_employees
WHERE uuid::text = ANY($1::text[]) AND deleted_at IS NULL`, uuids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uuid, name string
		if err := rows.Scan(&uuid, &name); err != nil {
			return nil, err
		}
		out[uuid] = name
	}
	return out, rows.Err()
}

// FindByTemplateSource (doc-15 P2) 幂等查找：该租户是否已有指向某平台模板的副本。
// 按 tenant_id + metadata->>'template_source_uuid' 精确命中未删除副本（不分页扫描、不漏数据）。
// 无命中 → apperr.ErrNotFound。
func (r *Repo) FindByTemplateSource(ctx context.Context, tenantID int64, templateUUID string) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+deBaseCols+creatorCol+deptCol+` FROM digital_employees de`+creatorJoin+deptJoin+`
		WHERE de.tenant_id=$1 AND de.source='enterprise' AND de.metadata->>'template_source_uuid'=$2 AND de.deleted_at IS NULL
		ORDER BY de.id LIMIT 1`, tenantID, templateUUID)
	e, err := scanWithDept(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return e, nil
}

func (r *Repo) CountCustom(ctx context.Context, tenantID int64) (int64, error) {
	const q = `SELECT count(*)
	FROM digital_employees
	WHERE tenant_id=$1
	  AND COALESCE(is_deleted, false)=false
	  AND deleted_at IS NULL
	  AND source IN ('enterprise','personal')
	  AND COALESCE(metadata->>'tenant_init_seed', 'false') <> 'true'`
	var n int64
	if err := r.pool.QueryRow(ctx, q, tenantID).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

func (r *Repo) CreatorDistribution(ctx context.Context, tenantID int64) ([]dom.CreatorDistributionItem, error) {
	const q = `
SELECT COALESCE(de.creator_id, 0) AS creator_id,
       COALESCE(NULLIF(tm_creator.nickname,''), NULLIF(a_creator.display_name,''), NULLIF(a_creator.username,''), NULLIF(a_creator.phone,''), NULLIF(a_creator.email,''), '') AS creator_name,
       count(*) AS agent_count
  FROM digital_employees de
  LEFT JOIN accounts a_creator ON a_creator.id = de.creator_id AND a_creator.deleted_at IS NULL
  LEFT JOIN tenant_memberships tm_creator
    ON tm_creator.tenant_id = de.tenant_id
   AND tm_creator.account_id = de.creator_id
   AND tm_creator.deleted_at IS NULL
 WHERE de.tenant_id = $1
   AND COALESCE(de.is_deleted, false) = false
   AND de.deleted_at IS NULL
   AND de.source IN ('enterprise','personal')
   AND COALESCE(de.metadata->>'tenant_init_seed', 'false') <> 'true'
 GROUP BY COALESCE(de.creator_id, 0), creator_name
 ORDER BY agent_count DESC, creator_name, creator_id`
	rows, err := r.pool.Query(ctx, q, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.CreatorDistributionItem
	for rows.Next() {
		var item dom.CreatorDistributionItem
		if err := rows.Scan(&item.CreatorID, &item.CreatorName, &item.Count); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

// FindZhibanSupportAgent 返回共享的已发布「知办客服」平台员工。
// ADR-0052 后平台行直接服务所有可见租户；历史租户副本只作为回滚兼容兜底。
func (r *Repo) FindZhibanSupportAgent(ctx context.Context, tenantID int64) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+deBaseCols+creatorCol+deptCol+` FROM digital_employees de`+creatorJoin+deptJoin+`
		WHERE (de.tenant_id=$1 OR (de.tenant_id IS NULL AND de.source='platform' AND de.visibility='platform'))
		  AND de.metadata->>'agent_key'='zhiban-support'
		  AND de.status='published'
		  AND de.contact_enabled=true
		  AND de.deleted_at IS NULL
		  AND COALESCE(de.is_deleted, false)=false
		ORDER BY CASE WHEN de.source='platform' AND de.tenant_id IS NULL THEN 0 ELSE 1 END, de.id
		LIMIT 1`, tenantID)
	e, err := scanWithDept(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return e, nil
}

func (r *Repo) Create(ctx context.Context, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	rq, _ := json.Marshal(emptySliceIfNil(e.RecommendedQuestions))
	caps, _ := json.Marshal(emptyMapIfNil(e.CapabilitiesDeclared))
	meta, _ := json.Marshal(emptyMapIfNil(e.Metadata))
	badges, _ := json.Marshal(emptySliceIfNil(e.Badges))
	a2aCard := strings.TrimSpace(e.A2ACardJSON)
	if a2aCard == "" {
		a2aCard = "{}"
	}
	callableByAgents := strings.TrimSpace(e.CallableByAgentsJSON)
	if callableByAgents == "" {
		callableByAgents = `{"mode":"all","agent_ids":[]}`
	}
	modelServiceConfig := strings.TrimSpace(e.ModelServiceConfigJSON)
	if modelServiceConfig == "" {
		modelServiceConfig = "{}"
	}
	// platform 预置: tenant_id/creator_id 允许 NULL (见 000016 ALTER)
	var tenantArg, creatorArg any
	if e.TenantID > 0 {
		tenantArg = e.TenantID
	}
	if e.CreatorID > 0 {
		creatorArg = e.CreatorID
	}
	// ADR-0011 audit: created_by/updated_by 由 ctx_account_id 派生; 系统/cron 行 NULL。
	actor := auditpg.Actor(ctx)
	row := r.pool.QueryRow(ctx, `
		WITH inserted AS (
		INSERT INTO digital_employees (tenant_id, creator_id, name, avatar_url, intro, description, welcome_msg,
			recommended_questions, tags, visibility, workspace_id, runtime_environment_id,
			model_primary, model_fallbacks, temperature, context_window, capabilities_declared,
			status, supports_group_chat, metadata,
			position_label, badges, source, contact_enabled, allow_invite_to_group,
			created_by, updated_by, callable_by_agents, a2a_card, tool_allow, tool_deny,
			model_source, model_service_config, execution_locus, local_engine)
		VALUES ($1,$2,$3,NULLIF($4,''),NULLIF($5,''),NULLIF($6,''),NULLIF($7,''),
			$8::jsonb, $9, COALESCE(NULLIF($10,''),'private'), $11, $12,
			NULLIF($13,''), $14, $15, $16, $17::jsonb,
			COALESCE(NULLIF($18,''),'draft'), $19, $20::jsonb,
			NULLIF($21,''), $22::jsonb, COALESCE(NULLIF($23,''),'enterprise'), $24, $25,
			$26, $26, $27::jsonb, $28::jsonb,
			COALESCE($30::varchar[],'{}'), COALESCE($31::varchar[],'{}'),
			COALESCE(NULLIF($32,''),'platform_whitelist'), $33::jsonb, COALESCE(NULLIF($34,''),'cloud'), NULLIF($35,''))
		RETURNING *
		), a2a_invoke AS (
			INSERT INTO agent_capability_bindings
				(digital_employee_id, agent_version_id, capability_kind, capability_uuid, source)
			SELECT id, NULL, 'a2a_invoke', $29::uuid, 'borrow'
			  FROM inserted
			ON CONFLICT DO NOTHING
			RETURNING 1
		)
		SELECT `+baseCols+` FROM inserted`,
		tenantArg, creatorArg, e.Name, e.AvatarURL, e.Intro, e.Description, e.WelcomeMsg,
		string(rq), emptyStringSlice(e.Tags), e.Visibility, e.WorkspaceID, e.RuntimeEnvironmentID,
		e.ModelPrimary, emptyStringSlice(e.ModelFallbacks), float32OrDefault(e.Temperature, 0.7), intOrDefault(e.ContextWindow, 32768), string(caps),
		e.Status, e.SupportsGroupChat, string(meta),
		e.PositionLabel, string(badges), e.Source, e.ContactEnabled, e.AllowInviteToGroup,
		actor, callableByAgents, a2aCard, dom.A2AInvokeSentinelUUID, e.ToolAllow, e.ToolDeny,
		e.ModelSource, modelServiceConfig, e.ExecutionLocus, e.LocalEngine)
	return scan(row)
}

func emptyStringSlice(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func (r *Repo) Update(ctx context.Context, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	rq, _ := json.Marshal(emptySliceIfNil(e.RecommendedQuestions))
	caps, _ := json.Marshal(emptyMapIfNil(e.CapabilitiesDeclared))
	meta, _ := json.Marshal(emptyMapIfNil(e.Metadata))
	badges, _ := json.Marshal(emptySliceIfNil(e.Badges))
	modelServiceConfig := strings.TrimSpace(e.ModelServiceConfigJSON)
	if modelServiceConfig == "" {
		modelServiceConfig = "{}"
	}
	// ADR-0011 audit: updated_by 由 ctx_account_id 派生; updated_at 由触发器 touch_updated_at 刷。
	actor := auditpg.Actor(ctx)
	row := r.pool.QueryRow(ctx, `
		UPDATE digital_employees SET
			name = COALESCE(NULLIF($1,''), name),
			avatar_url = NULLIF($2,''),
			intro = NULLIF($3,''),
			description = NULLIF($4,''),
			welcome_msg = NULLIF($5,''),
			recommended_questions = $6::jsonb,
			tags = $7,
			visibility = COALESCE(NULLIF($8,''), visibility),
			workspace_id = $9,
			runtime_environment_id = $10,
			model_primary = NULLIF($11,''),
			model_fallbacks = $12,
			temperature = COALESCE($13, temperature),
			context_window = COALESCE($14, context_window),
			capabilities_declared = $15::jsonb,
			status = COALESCE(NULLIF($16,''), status),
			supports_group_chat = $17,
			metadata = $18::jsonb,
			position_label = NULLIF($19,''),
			badges = $20::jsonb,
			source = COALESCE(NULLIF($21,''), source),
			contact_enabled = $22,
			allow_invite_to_group = $23,
			updated_by = $25,
			tool_allow = COALESCE($26::varchar[], tool_allow),
			tool_deny = COALESCE($27::varchar[], tool_deny),
			model_source = COALESCE(NULLIF($28,''), model_source),
			model_service_config = $29::jsonb,
			execution_locus = COALESCE(NULLIF($30,''), execution_locus),
			local_engine = NULLIF($31,'')
		WHERE id = $24 AND is_deleted=false
		RETURNING `+baseCols,
		e.Name, e.AvatarURL, e.Intro, e.Description, e.WelcomeMsg, string(rq), emptyStringSlice(e.Tags),
		e.Visibility, e.WorkspaceID, e.RuntimeEnvironmentID,
		e.ModelPrimary, emptyStringSlice(e.ModelFallbacks), e.Temperature, e.ContextWindow, string(caps),
		e.Status, e.SupportsGroupChat, string(meta),
		e.PositionLabel, string(badges), e.Source, e.ContactEnabled, e.AllowInviteToGroup, e.ID, actor,
		// nil = 请求未携带 → 保留现值 (COALESCE); 非 nil (含空数组) = 覆盖。
		// 客户端 bus 路径从 existing 拷贝起步恒为非 nil 原值; admin 路径显式携带才变更。
		e.ToolAllow, e.ToolDeny,
		e.ModelSource, modelServiceConfig, e.ExecutionLocus, e.LocalEngine)
	return scan(row)
}

// SetModelServiceAPIKey 写入/轮转 ADR-0037 BYOK api_key 密文; 单独一条 UPDATE,
// 不经过通用 Update (调用方不传密钥字段时不会误清空)。
func (r *Repo) SetModelServiceAPIKey(ctx context.Context, id int64, ciphertext []byte, prefix string, version int) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE digital_employees SET
			model_service_api_key_ciphertext = $1,
			model_service_api_key_prefix = $2,
			model_service_api_key_version = $3
		WHERE id = $4 AND is_deleted=false`,
		ciphertext, prefix, version, id)
	return err
}

// ClearModelServiceAPIKey 清空 BYOK api_key 密文三列。
func (r *Repo) ClearModelServiceAPIKey(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE digital_employees SET
			model_service_api_key_ciphertext = NULL,
			model_service_api_key_prefix = NULL,
			model_service_api_key_version = NULL
		WHERE id = $1 AND is_deleted=false`,
		id)
	return err
}

func (r *Repo) Delete(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE digital_employees
		   SET is_deleted=true,
		       deleted_at=COALESCE(deleted_at, now()),
		       updated_at=now()
		 WHERE id=$1`, id)
	return err
}

// Publish 把数字员工状态切到 published, 仅当当前状态为 draft 时生效;
// 已 published 视为 idempotent (不报错), 其它状态返回 nil 但不改值。
func (r *Repo) Publish(ctx context.Context, id int64) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `
		UPDATE digital_employees
		SET status = 'published', updated_at = now()
		WHERE id = $1 AND deleted_at IS NULL AND status IN ('draft','published')
		RETURNING `+baseCols, id)
	return scan(row)
}

// Archive 把数字员工状态切到 archived (Batch 2C T2C.3 unpublish 路径),
// 仅当当前状态为 published/grayed 时生效;
// 已 archived 视为 idempotent (返回当前行); 其它状态 (draft) -> 调用方应在 service 层拒。
func (r *Repo) Archive(ctx context.Context, id int64) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `
		UPDATE digital_employees
		SET status = 'archived', updated_at = now()
		WHERE id = $1 AND deleted_at IS NULL AND status IN ('published','grayed','archived')
		RETURNING `+baseCols, id)
	return scan(row)
}

// SetPublishedFromDraft Batch 2C T2C.3 publish 阶段 3 乐观锁: 把 draft 切 published
// 且要求 current_version 等于 expectedVersion (防多 bus 实例并发 publish 撞库)。
// 返回更新后行; 0 行 (status 已变 / current_version 不等) -> 调用方走补偿。
func (r *Repo) SetPublishedFromDraft(ctx context.Context, id int64, expectedVersion int) (*dom.DigitalEmployee, error) {
	row := r.pool.QueryRow(ctx, `
		UPDATE digital_employees
		SET status = 'published', updated_at = now()
		WHERE id = $1 AND deleted_at IS NULL
		  AND status = 'draft'
		  AND current_version = $2
		RETURNING `+baseCols, id, expectedVersion)
	return scan(row)
}

// Notify 转发 PG pg_notify; 失败返回 error, 调用方决定是否吞掉。
func (r *Repo) Notify(ctx context.Context, channel, payload string) error {
	_, err := r.pool.Exec(ctx, `SELECT pg_notify($1, $2)`, channel, payload)
	return err
}

// SetDefaultForCreator · B-5-1: 把 (creator=accountID, tenant=tenantID, uuid=agentUUID) 设为
// caller 的默认 agent. 同 tenant 同 creator 的其它 agent is_default_for_creator 全部清掉.
//
// 校验:
//   - agent.tenant_id == tenantID
//   - agent.creator_id == accountID (B-5-1 仅 caller 自己创建的 agent 可设默认; 平台预置不支持)
//   - agent.status='published'
func (r *Repo) SetDefaultForCreator(ctx context.Context, accountID, tenantID int64, agentUUID string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var agentID, creatorID, agTenantID int64
	var status string
	err = tx.QueryRow(ctx,
		`SELECT id, creator_id, tenant_id, status FROM digital_employees WHERE uuid=$1 AND deleted_at IS NULL`,
		agentUUID,
	).Scan(&agentID, &creatorID, &agTenantID, &status)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound.Withf("agent %s not found", agentUUID)
		}
		return err
	}
	if agTenantID != tenantID {
		return apperr.ErrForbidden.Withf("agent tenant mismatch")
	}
	if creatorID != accountID {
		return apperr.ErrForbidden.Withf("only the creator can set this agent as default")
	}
	if status != "published" {
		return apperr.ErrConflict.Withf("agent not published (status=%s)", status)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE digital_employees SET is_default_for_creator=false, updated_at=now()
		 WHERE tenant_id=$1 AND creator_id=$2 AND is_default_for_creator=true`,
		tenantID, accountID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE digital_employees SET is_default_for_creator=true, updated_at=now() WHERE id=$1`,
		agentID,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// UpsertVisibilityOverride 对 source='platform' 的 Agent 设置/更新本租户级别的隐藏与排序。
//
// 调用方负责校验 agent 是 platform 来源 (业务约束在 service 层)。
func (r *Repo) UpsertVisibilityOverride(ctx context.Context, tenantID, agentID int64, hidden bool, sortOrder int) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO digital_employee_visibility_overrides (tenant_id, digital_employee_id, hidden, sort_order)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (tenant_id, digital_employee_id)
		DO UPDATE SET hidden = EXCLUDED.hidden, sort_order = EXCLUDED.sort_order, updated_at = now()`,
		tenantID, agentID, hidden, sortOrder)
	return err
}

func (r *Repo) List(ctx context.Context, f dom.Filter) ([]dom.DigitalEmployee, int64, error) {
	if f.IncludePlatformPresets && f.TenantID > 0 && f.Source == "" {
		return r.listTenantWithPlatformPresets(ctx, f)
	}
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	args := []any{}
	// 所有 where 字段都加 `de.` 前缀, 否则与 LEFT JOIN departments d 之后的
	// d.tenant_id / d.name / d.deleted_at 列名冲突 ambiguous。
	where := `de.deleted_at IS NULL`
	if f.Source == "platform" {
		where += " AND de.tenant_id IS NULL AND de.source='platform'"
	} else {
		args = append(args, f.TenantID)
		where += " AND de.tenant_id=$" + itoa(len(args))
		if f.Source != "" {
			args = append(args, f.Source)
			where += " AND de.source=$" + itoa(len(args))
		}
	}
	if f.CreatorID > 0 {
		args = append(args, f.CreatorID)
		where += " AND de.creator_id=$" + itoa(len(args))
	}
	if f.Status != "" {
		args = append(args, f.Status)
		where += " AND de.status=$" + itoa(len(args))
	}
	if f.Visibility != "" {
		args = append(args, f.Visibility)
		where += " AND de.visibility=$" + itoa(len(args))
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		where += " AND de.name ILIKE $" + itoa(len(args))
	}
	if f.ExecutionLocus != "" {
		args = append(args, f.ExecutionLocus)
		where += " AND de.execution_locus=$" + itoa(len(args))
	}
	if f.AgentKind != "" {
		args = append(args, f.AgentKind)
		where += " AND COALESCE(NULLIF(de.metadata->>'agent_kind',''),'single')=$" + itoa(len(args))
	}
	if f.ExcludeTenantInitSeeds {
		where += " AND COALESCE(de.metadata->>'tenant_init_seed','false') <> 'true'"
	}
	if f.TemplateTenantID > 0 {
		args = append(args, f.TemplateTenantID)
		where += ` AND de.source='platform' AND de.tenant_id IS NULL AND de.visibility='platform' AND de.status='published'
          AND COALESCE(de.is_deleted,false)=false
          AND COALESCE(de.metadata->>'runtime_kind','') <> 'support_builtin'
          AND COALESCE(de.metadata->>'agent_key','') <> 'zhiban-support'
          AND (de.execution_locus='local' OR EXISTS (
            SELECT 1 FROM runtime_environments re
            JOIN tenant_runtime_enablements tre ON tre.runtime_environment_id=re.id
            WHERE re.id=de.runtime_environment_id AND re.scope='platform'
              AND re.is_deleted=false AND re.enabled AND re.open_to_tenants AND re.status='active'
              AND re.last_probe_status='ok' AND re.egress_audit_status='approved'
              AND tre.is_deleted=false AND tre.tenant_id=$` + itoa(len(args)) + `))`
	}
	args = append(args, limit, f.Offset)
	rows, err := r.pool.Query(ctx, `SELECT `+deBaseCols+creatorCol+deptCol+`, COUNT(*) OVER() FROM digital_employees de`+creatorJoin+deptJoin+` WHERE `+where+` ORDER BY de.id DESC LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.DigitalEmployee
	var total int64
	for rows.Next() {
		var e dom.DigitalEmployee
		var rq []byte
		var tags, mf, allow, deny []string
		var caps, meta, badges []byte
		if err := rows.Scan(&e.ID, &e.UUID, &e.TenantID, &e.CreatorID, &e.Name, &e.AvatarURL, &e.Intro,
			&e.Description, &e.WelcomeMsg, &rq, &tags,
			&e.Visibility, &e.WorkspaceID, &e.IsDefaultForCreator, &e.RuntimeEnvironmentID,
			&e.ModelPrimary, &mf, &e.Temperature, &e.ContextWindow,
			&allow, &deny, &caps, &e.Status, &e.CurrentVersion,
			&e.CallableByAgentsJSON, &e.SupportsGroupChat, &e.IsSystem, &meta,
			&e.CreatedAt, &e.CreatedBy, &e.UpdatedAt, &e.UpdatedBy, &e.IsDeleted, &e.DeletedAt,
			&e.PositionLabel, &badges, &e.Source, &e.ContactEnabled, &e.AllowInviteToGroup,
			&e.A2ACardJSON, &e.ModelSource, &e.ModelServiceConfigJSON, &e.ModelServiceAPIKeyPrefix, &e.ExecutionLocus, &e.LocalEngine,
			&e.CreatorName, &e.DepartmentName, &total); err != nil {
			return nil, 0, err
		}
		if len(rq) > 0 {
			_ = json.Unmarshal(rq, &e.RecommendedQuestions)
		}
		e.Tags = tags
		e.ModelFallbacks = mf
		e.ToolAllow = allow
		e.ToolDeny = deny
		if len(caps) > 0 {
			_ = json.Unmarshal(caps, &e.CapabilitiesDeclared)
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &e.Metadata)
		}
		if len(badges) > 0 {
			_ = json.Unmarshal(badges, &e.Badges)
		}
		if e.Badges == nil {
			e.Badges = []string{}
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && f.Offset > 0 {
		if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM digital_employees de WHERE `+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

// listTenantWithPlatformPresets 返回租户后台数字员工列表:
//   - 本租户创建/管理的 digital_employees
//   - 平台已发布模板 (tenant_id IS NULL, source='platform', visibility='platform', status='published')
//
// 平台模板不会复制为租户行; 租户启用/禁用读取 digital_employee_visibility_overrides.hidden。
func (r *Repo) listTenantWithPlatformPresets(ctx context.Context, f dom.Filter) ([]dom.DigitalEmployee, int64, error) {
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	args := []any{f.TenantID}
	where := `de.deleted_at IS NULL AND (
		de.tenant_id = $1
		OR (de.tenant_id IS NULL AND de.source = 'platform' AND de.visibility = 'platform' AND de.status = 'published')
	)`
	if f.CreatorID > 0 {
		args = append(args, f.CreatorID)
		where += " AND de.creator_id=$" + itoa(len(args))
	}
	if f.Status != "" {
		args = append(args, f.Status)
		where += " AND de.status=$" + itoa(len(args))
	}
	if f.Visibility != "" {
		args = append(args, f.Visibility)
		where += " AND de.visibility=$" + itoa(len(args))
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		where += " AND de.name ILIKE $" + itoa(len(args))
	}
	args = append(args, limit, f.Offset)
	rows, err := r.pool.Query(ctx, `
		SELECT `+deBaseCols+creatorCol+deptCol+`,
		       COALESCE(ov.hidden, false) AS tenant_hidden,
		       COALESCE(ov.sort_order, 0) AS tenant_sort_order,
		       COUNT(*) OVER()
		FROM digital_employees de`+creatorJoin+deptJoin+`
		LEFT JOIN digital_employee_visibility_overrides ov
		  ON ov.tenant_id = $1 AND ov.digital_employee_id = de.id
		WHERE `+where+`
		ORDER BY
		  CASE WHEN de.tenant_id = $1 THEN 0 ELSE 1 END,
		  COALESCE(ov.sort_order, 0) ASC,
		  de.id DESC
		LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.DigitalEmployee
	var total int64
	for rows.Next() {
		var e dom.DigitalEmployee
		var rq []byte
		var tags, mf, allow, deny []string
		var caps, meta, badges []byte
		if err := rows.Scan(&e.ID, &e.UUID, &e.TenantID, &e.CreatorID, &e.Name, &e.AvatarURL, &e.Intro,
			&e.Description, &e.WelcomeMsg, &rq, &tags,
			&e.Visibility, &e.WorkspaceID, &e.IsDefaultForCreator, &e.RuntimeEnvironmentID,
			&e.ModelPrimary, &mf, &e.Temperature, &e.ContextWindow,
			&allow, &deny, &caps, &e.Status, &e.CurrentVersion,
			&e.CallableByAgentsJSON, &e.SupportsGroupChat, &e.IsSystem, &meta,
			&e.CreatedAt, &e.CreatedBy, &e.UpdatedAt, &e.UpdatedBy, &e.IsDeleted, &e.DeletedAt,
			&e.PositionLabel, &badges, &e.Source, &e.ContactEnabled, &e.AllowInviteToGroup,
			&e.A2ACardJSON, &e.ModelSource, &e.ModelServiceConfigJSON, &e.ModelServiceAPIKeyPrefix, &e.ExecutionLocus, &e.LocalEngine,
			&e.CreatorName, &e.DepartmentName,
			&e.TenantHidden, &e.TenantSortOrder, &total); err != nil {
			return nil, 0, err
		}
		if len(rq) > 0 {
			_ = json.Unmarshal(rq, &e.RecommendedQuestions)
		}
		e.Tags = tags
		e.ModelFallbacks = mf
		e.ToolAllow = allow
		e.ToolDeny = deny
		if len(caps) > 0 {
			_ = json.Unmarshal(caps, &e.CapabilitiesDeclared)
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &e.Metadata)
		}
		if len(badges) > 0 {
			_ = json.Unmarshal(badges, &e.Badges)
		}
		if e.Badges == nil {
			e.Badges = []string{}
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && f.Offset > 0 {
		if err := r.pool.QueryRow(ctx, `
			SELECT count(*)
			FROM digital_employees de
			LEFT JOIN digital_employee_visibility_overrides ov
			  ON ov.tenant_id = $1 AND ov.digital_employee_id = de.id
			WHERE `+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

// --- bindings ---

const listDraftBindingsSQL = `
	SELECT id, digital_employee_id, agent_version_id, capability_kind, capability_uuid::text, source,
	       granted_tools, granted_scopes, sort_order, pinned, recall_config, created_at
	FROM agent_capability_bindings
	WHERE digital_employee_id=$1 AND agent_version_id IS NULL
	ORDER BY sort_order, id`

func (r *Repo) ListBindings(ctx context.Context, deID int64) ([]dom.CapabilityBinding, error) {
	rows, err := r.pool.Query(ctx, listDraftBindingsSQL, deID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.CapabilityBinding
	for rows.Next() {
		var b dom.CapabilityBinding
		var tools, scopes []string
		var rc []byte
		if err := rows.Scan(&b.ID, &b.DigitalEmpID, &b.AgentVersionID, &b.CapabilityKind, &b.CapabilityUUID, &b.Source,
			&tools, &scopes, &b.SortOrder, &b.Pinned, &rc, &b.CreatedAt); err != nil {
			return nil, err
		}
		b.GrantedTools = tools
		b.GrantedScopes = scopes
		if len(rc) > 0 {
			_ = json.Unmarshal(rc, &b.RecallConfig)
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (r *Repo) AddBinding(ctx context.Context, b *dom.CapabilityBinding) (*dom.CapabilityBinding, error) {
	rc, _ := json.Marshal(emptyMapIfNil(b.RecallConfig))
	row := r.pool.QueryRow(ctx, `
		INSERT INTO agent_capability_bindings (digital_employee_id, agent_version_id, capability_kind, capability_uuid, source, granted_tools, granted_scopes, sort_order, pinned, recall_config)
		VALUES ($1,$2,$3,$4::uuid,$5,$6,$7,$8,$9,$10::jsonb)
		RETURNING id, created_at`,
		b.DigitalEmpID, b.AgentVersionID, b.CapabilityKind, b.CapabilityUUID, b.Source,
		emptyStringSlice(b.GrantedTools), emptyStringSlice(b.GrantedScopes), b.SortOrder, b.Pinned, string(rc))
	if err := row.Scan(&b.ID, &b.CreatedAt); err != nil {
		return nil, translatePgErr(err)
	}
	return b, nil
}

// CopyPlatformKBBindings 把平台模板当前可装配的 canonical KB binding 复制到租户副本。
// overwrite=true 用于新副本创建；overwrite=false 兼容历史副本修复，只插入缺失项，
// 不覆盖副本已有参数，也不删除任何平台/租户 binding。
// CopyPlatformSkillBindings 把平台模板的 composer_skill 能力绑定（平台预置编辑器写的老表
// agent_capability_bindings）翻译成副本的 agent_skill_bindings（租户编辑器与 ZAP 会话下发读的表）。
// 幂等、additive-only：ON CONFLICT (agent_id, skill_id) DO NOTHING，不覆盖租户自己改过的绑定。
// 与租户编辑器 BindAgentSkill 同口径过滤：技能非 active / required_runtimes 不含副本运行时 framework /
// 租户已禁用 → 记入 skipped（skill:<code>:<reason>），不落库。
//
// 2026-09-02 生产实测：模板分发出的副本在租户侧看不到技能、runtime 会话 agent_skills=[]，
// 根因就是两张表口径不一致而复制只抄了老表。
func (r *Repo) CopyPlatformSkillBindings(ctx context.Context, templateID, copyID, createdBy int64) (int, []string, error) {
	rows, err := r.pool.Query(ctx, `
SELECT COALESCE(s.id,0), COALESCE(s.code,b.capability_uuid::text), b.sort_order, b.pinned,
       COALESCE(s.status = 'active' AND s.deleted_at IS NULL AND s.tenant_id IS NULL,false) AS active,
       (s.agent_compat->'required_runtimes' IS NULL
        OR jsonb_typeof(s.agent_compat->'required_runtimes') <> 'array'
        OR jsonb_array_length(s.agent_compat->'required_runtimes') = 0
        OR (s.agent_compat->'required_runtimes') ? tgt.framework) AS compat,
       EXISTS (SELECT 1 FROM tenant_skill_disables d WHERE d.tenant_id = tgt.tenant_id AND d.skill_id = s.id) AS disabled
  FROM agent_capability_bindings b
  LEFT JOIN skills s ON s.uuid = b.capability_uuid
  CROSS JOIN (
    SELECT de.tenant_id, CASE WHEN de.execution_locus='local' THEN COALESCE(NULLIF(de.local_engine,''),'dsh') ELSE COALESCE(re.framework,'') END AS framework
      FROM digital_employees de
      LEFT JOIN runtime_environments re ON re.id = de.runtime_environment_id AND re.is_deleted = false
     WHERE de.id = $2
  ) tgt
 WHERE b.digital_employee_id = $1 AND b.capability_kind = 'composer_skill' AND b.agent_version_id IS NULL
 ORDER BY b.sort_order, b.id`, templateID, copyID)
	if err != nil {
		return 0, nil, err
	}
	type cand struct {
		skillID   int64
		code      string
		sortOrder int
		pinned    bool
		reason    string
	}
	var cands []cand
	for rows.Next() {
		var c cand
		var active, compat, disabled bool
		if err := rows.Scan(&c.skillID, &c.code, &c.sortOrder, &c.pinned, &active, &compat, &disabled); err != nil {
			rows.Close()
			return 0, nil, err
		}
		switch {
		case !active:
			c.reason = "inactive"
		case !compat:
			c.reason = "runtime_mismatch"
		case disabled:
			c.reason = "disabled_in_tenant"
		}
		cands = append(cands, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, nil, err
	}
	var by *int64
	if createdBy > 0 {
		by = &createdBy
	}
	copied := 0
	var skipped []string
	for _, c := range cands {
		if c.reason != "" {
			skipped = append(skipped, "skill:"+c.code+":"+c.reason)
			continue
		}
		tag, err := r.pool.Exec(ctx, `
INSERT INTO agent_skill_bindings (agent_id, skill_id, pinned, sort_order, default_params, source, created_by, updated_by)
VALUES ($1, $2, $3, $4, '{}'::jsonb, 'default_inherit', $5, $5)
ON CONFLICT (agent_id, skill_id) DO NOTHING`, copyID, c.skillID, c.pinned, c.sortOrder, by)
		if err != nil {
			skipped = append(skipped, "skill:"+c.code+":insert_failed")
			continue
		}
		copied += int(tag.RowsAffected())
	}
	return copied, skipped, nil
}

func (r *Repo) CopyPlatformKBBindings(ctx context.Context, templateID, copyID, createdBy int64, overwrite bool) (int, []string, error) {
	rows, err := r.pool.Query(ctx, `
SELECT kb.id, kb.uuid::text, b.binding_kind, b.priority, COALESCE(b.note,''),
       (kb.deleted_at IS NULL AND kb.tenant_id IS NULL
        AND kb.space_kind='platform' AND kb.access_mode='agent_only'
        AND kb.status='active' AND kb.provision_status='active') AS attachable
  FROM agent_kb_bindings b
  JOIN knowledge_bases kb ON kb.id=b.kb_id
 WHERE b.agent_id = $1
   AND b.deleted_at IS NULL`, templateID)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()

	copied := 0
	skipped := make([]string, 0)
	for rows.Next() {
		var (
			kbID        int64
			kbUUID      string
			bindingKind string
			priority    int
			note        string
			attachable  bool
		)
		if err := rows.Scan(&kbID, &kbUUID, &bindingKind, &priority, &note, &attachable); err != nil {
			return copied, skipped, err
		}
		if !attachable {
			skipped = append(skipped, "knowledge_base:"+kbUUID)
			continue
		}

		var tag pgconn.CommandTag
		if overwrite {
			tag, err = r.pool.Exec(ctx, `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, note, created_by)
VALUES ($1,$2,$3,$4,$5,$6)
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind=EXCLUDED.binding_kind, priority=EXCLUDED.priority,
              note=EXCLUDED.note, updated_at=now()`,
				copyID, kbID, bindingKind, priority, note, createdBy)
		} else {
			tag, err = r.pool.Exec(ctx, `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, note, created_by)
VALUES ($1,$2,$3,$4,$5,$6)
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL DO NOTHING`,
				copyID, kbID, bindingKind, priority, note, createdBy)
		}
		if err != nil {
			skipped = append(skipped, "knowledge_base:"+kbUUID)
			continue
		}
		copied += int(tag.RowsAffected())
	}
	if err := rows.Err(); err != nil {
		return copied, skipped, err
	}
	return copied, skipped, nil
}

func (r *Repo) RemoveBinding(ctx context.Context, bindingID int64) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM agent_capability_bindings WHERE id=$1`, bindingID)
	return err
}

// --- helpers ---

func toPgTextArray(items []string) string {
	if len(items) == 0 {
		return "{}"
	}
	quoted := make([]string, 0, len(items))
	for _, s := range items {
		s = strings.ReplaceAll(s, `\`, `\\`)
		s = strings.ReplaceAll(s, `"`, `\"`)
		quoted = append(quoted, `"`+s+`"`)
	}
	return "{" + strings.Join(quoted, ",") + "}"
}

func emptySliceIfNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func emptyMapIfNil(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func float32OrDefault(v, d float32) float32 {
	if v == 0 {
		return d
	}
	return v
}

func intOrDefault(v, d int) int {
	if v == 0 {
		return d
	}
	return v
}

// itoa 不引入 strconv（避免随处可见 fmt.Sprintf）。
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	negative := false
	if n < 0 {
		negative = true
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if negative {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
