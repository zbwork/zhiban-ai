// repo_tenant.go — F03 v0.9.1 租户域 / 用户域 / 客户端 repo 实现。
//
// 涉及 5 张表（详 docs/features/F03-skills.md §2.3.C-H）：
//   - agent_skill_bindings
//   - tenant_skill_preferences
//   - tenant_skill_disables
//   - user_agent_skill_overrides
//   - client_builtin_handshakes
package skill

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ----------------------------------------------------------------------------
// agent_skill_bindings
// ----------------------------------------------------------------------------

const agentBindingCols = `
	id, agent_id, skill_id, pinned, sort_order, pinned_version_id,
	default_params, source, created_by, updated_by, created_at, updated_at`

func scanAgentBinding(row pgx.Row) (*domskill.AgentBinding, error) {
	var b domskill.AgentBinding
	if err := row.Scan(
		&b.ID, &b.AgentID, &b.SkillID, &b.Pinned, &b.SortOrder, &b.PinnedVersionID,
		&b.DefaultParams, &b.Source, &b.CreatedBy, &b.UpdatedBy, &b.CreatedAt, &b.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &b, nil
}

// UpsertAgentBinding 插入或冲突时更新（unique (agent_id, skill_id)）；回填 ID/CreatedAt/UpdatedAt。
func (r *Repo) UpsertAgentBinding(ctx context.Context, b *domskill.AgentBinding) error {
	const q = `
		INSERT INTO agent_skill_bindings (
			agent_id, skill_id, pinned, sort_order, pinned_version_id,
			default_params, source, created_by, updated_by
		) VALUES (
			$1, $2, $3, $4, $5,
			COALESCE($6, '{}'::jsonb), $7, $8, $9
		)
		ON CONFLICT (agent_id, skill_id) DO UPDATE SET
			pinned            = EXCLUDED.pinned,
			sort_order        = EXCLUDED.sort_order,
			pinned_version_id = EXCLUDED.pinned_version_id,
			default_params    = EXCLUDED.default_params,
			source            = EXCLUDED.source,
			updated_by        = EXCLUDED.updated_by,
			updated_at        = now()
		RETURNING id, created_at, updated_at`
	row := r.pool.QueryRow(ctx, q,
		b.AgentID, b.SkillID, b.Pinned, b.SortOrder, b.PinnedVersionID,
		nullJSON(b.DefaultParams), b.Source, b.CreatedBy, b.UpdatedBy,
	)
	if err := row.Scan(&b.ID, &b.CreatedAt, &b.UpdatedAt); err != nil {
		return mapPGError(err)
	}
	return nil
}

// GetAgentBinding 按 (agent, skill) 取单条。
func (r *Repo) GetAgentBinding(ctx context.Context, agentID, skillID int64) (*domskill.AgentBinding, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+agentBindingCols+` FROM agent_skill_bindings WHERE agent_id=$1 AND skill_id=$2`,
		agentID, skillID)
	b, err := scanAgentBinding(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("agent_skill_binding not found")
		}
		return nil, err
	}
	return b, nil
}

// GetAgentBindingByID 按 binding_id 取单条。
func (r *Repo) GetAgentBindingByID(ctx context.Context, id int64) (*domskill.AgentBinding, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+agentBindingCols+` FROM agent_skill_bindings WHERE id=$1`, id)
	b, err := scanAgentBinding(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("agent_skill_binding not found")
		}
		return nil, err
	}
	return b, nil
}

// ListAgentBindings 列出某 agent 下所有绑定。
func (r *Repo) ListAgentBindings(ctx context.Context, agentID int64) ([]domskill.AgentBinding, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+agentBindingCols+` FROM agent_skill_bindings
		 WHERE agent_id=$1 ORDER BY sort_order DESC, id DESC`, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.AgentBinding{}
	for rows.Next() {
		b, err := scanAgentBinding(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
	}
	return out, rows.Err()
}

// ListAgentBindingViewsByAgentIDs 批量拉多个 agent 的绑定 + 技能详情（2 条 SQL）。
// digital_employees 联表把 tenant 隔离下沉到 SQL：跨租户 agentID 静默不返回（fail-closed）。
// 技能行物理缺失时该绑定被跳过、软删技能不过滤，两点均对齐逐条路径
// （ListAgentBindings + GetSkillByID）的现有语义。
func (r *Repo) ListAgentBindingViewsByAgentIDs(ctx context.Context, tenantID int64, agentIDs []int64) (map[int64][]domskill.AgentBindingView, error) {
	out := make(map[int64][]domskill.AgentBindingView, len(agentIDs))
	if len(agentIDs) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT b.id, b.agent_id, b.skill_id, b.pinned, b.sort_order, b.pinned_version_id,
		        b.default_params, b.source, b.created_by, b.updated_by, b.created_at, b.updated_at
		 FROM agent_skill_bindings b
		 JOIN digital_employees de ON de.id = b.agent_id AND (
			de.tenant_id = $2 OR (
				de.tenant_id IS NULL AND de.source = 'platform'
				AND de.visibility = 'platform' AND de.status = 'published'
			)
		 )
		 WHERE b.agent_id = ANY($1)
		 ORDER BY b.agent_id, b.sort_order DESC, b.id DESC`, agentIDs, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	bindings := []domskill.AgentBinding{}
	skillIDSet := map[int64]struct{}{}
	for rows.Next() {
		b, err := scanAgentBinding(rows)
		if err != nil {
			return nil, err
		}
		bindings = append(bindings, *b)
		skillIDSet[b.SkillID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(bindings) == 0 {
		return out, nil
	}

	skillIDs := make([]int64, 0, len(skillIDSet))
	for id := range skillIDSet {
		skillIDs = append(skillIDs, id)
	}
	skillRows, err := r.pool.Query(ctx,
		`SELECT `+r.columns()+` FROM skills s WHERE s.id = ANY($1)`, skillIDs)
	if err != nil {
		return nil, err
	}
	defer skillRows.Close()
	skillsByID := make(map[int64]*domskill.Skill, len(skillIDs))
	for skillRows.Next() {
		sk, err := scanSkill(skillRows)
		if err != nil {
			return nil, err
		}
		skillsByID[sk.ID] = sk
	}
	if err := skillRows.Err(); err != nil {
		return nil, err
	}

	for i := range bindings {
		sk, ok := skillsByID[bindings[i].SkillID]
		if !ok {
			continue // 技能行物理缺失 → 跳过该绑定（对齐逐条路径 GetSkillByID not found → continue）
		}
		out[bindings[i].AgentID] = append(out[bindings[i].AgentID], domskill.AgentBindingView{Binding: &bindings[i], Skill: sk})
	}
	return out, nil
}

// PatchAgentBinding partial update；fields 键即列名。
func (r *Repo) PatchAgentBinding(ctx context.Context, id int64, fields map[string]any) (*domskill.AgentBinding, error) {
	if len(fields) == 0 {
		return r.GetAgentBindingByID(ctx, id)
	}
	allowed := map[string]bool{
		"pinned": true, "sort_order": true, "pinned_version_id": true,
		"default_params": true, "updated_by": true,
	}
	sets := []string{}
	args := []any{}
	for k, v := range fields {
		if !allowed[k] {
			continue
		}
		args = append(args, v)
		sets = append(sets, fmt.Sprintf("%s=$%d", k, len(args)))
	}
	if len(sets) == 0 {
		return r.GetAgentBindingByID(ctx, id)
	}
	sets = append(sets, "updated_at=now()")
	args = append(args, id)
	q := `UPDATE agent_skill_bindings SET ` + strings.Join(sets, ", ") +
		` WHERE id=$` + fmt.Sprintf("%d", len(args)) + ` RETURNING ` + agentBindingCols
	row := r.pool.QueryRow(ctx, q, args...)
	b, err := scanAgentBinding(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("agent_skill_binding not found")
		}
		return nil, mapPGError(err)
	}
	return b, nil
}

// DeleteAgentBinding 物理删除；spec §3.2 DELETE /skills/{binding_id}。
func (r *Repo) DeleteAgentBinding(ctx context.Context, id int64) error {
	tag, err := r.pool.Exec(ctx, `DELETE FROM agent_skill_bindings WHERE id=$1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("agent_skill_binding not found")
	}
	return nil
}

// ----------------------------------------------------------------------------
// tenant_skill_preferences
// ----------------------------------------------------------------------------

const prefCols = `
	tenant_id, skill_id, behavior, COALESCE(note,''),
	created_by, updated_by, created_at, updated_at`

func scanPref(row pgx.Row) (*domskill.TenantPreference, error) {
	var p domskill.TenantPreference
	if err := row.Scan(
		&p.TenantID, &p.SkillID, &p.Behavior, &p.Note,
		&p.CreatedBy, &p.UpdatedBy, &p.CreatedAt, &p.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &p, nil
}

// UpsertTenantPreference 写偏好（force_on / force_off）。
func (r *Repo) UpsertTenantPreference(ctx context.Context, p *domskill.TenantPreference) error {
	const q = `
		INSERT INTO tenant_skill_preferences (
			tenant_id, skill_id, behavior, note, created_by, updated_by
		) VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (tenant_id, skill_id) DO UPDATE SET
			behavior   = EXCLUDED.behavior,
			note       = EXCLUDED.note,
			updated_by = EXCLUDED.updated_by,
			updated_at = now()
		RETURNING created_at, updated_at`
	row := r.pool.QueryRow(ctx, q,
		p.TenantID, p.SkillID, p.Behavior, nullStr(p.Note),
		p.CreatedBy, p.UpdatedBy,
	)
	if err := row.Scan(&p.CreatedAt, &p.UpdatedAt); err != nil {
		return mapPGError(err)
	}
	return nil
}

// DeleteTenantPreference 清除一项偏好。
func (r *Repo) DeleteTenantPreference(ctx context.Context, tenantID, skillID int64) error {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM tenant_skill_preferences WHERE tenant_id=$1 AND skill_id=$2`,
		tenantID, skillID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("tenant_skill_preference not found")
	}
	return nil
}

// ListTenantPreferences 列出某租户的所有偏好。
func (r *Repo) ListTenantPreferences(ctx context.Context, tenantID int64) ([]domskill.TenantPreference, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+prefCols+` FROM tenant_skill_preferences WHERE tenant_id=$1 ORDER BY skill_id`,
		tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.TenantPreference{}
	for rows.Next() {
		p, err := scanPref(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// GetTenantPreference 取单条；不存在返 NotFound。
func (r *Repo) GetTenantPreference(ctx context.Context, tenantID, skillID int64) (*domskill.TenantPreference, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+prefCols+` FROM tenant_skill_preferences WHERE tenant_id=$1 AND skill_id=$2`,
		tenantID, skillID)
	p, err := scanPref(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return p, nil
}

// ----------------------------------------------------------------------------
// tenant_skill_disables
// ----------------------------------------------------------------------------

func (r *Repo) UpsertTenantDisable(ctx context.Context, d *domskill.TenantDisable) error {
	const q = `
		INSERT INTO tenant_skill_disables (tenant_id, skill_id, disable_reason, disabled_by)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (tenant_id, skill_id) DO UPDATE SET
			disable_reason = EXCLUDED.disable_reason,
			disabled_by    = EXCLUDED.disabled_by,
			disabled_at    = now()
		RETURNING disabled_at`
	row := r.pool.QueryRow(ctx, q, d.TenantID, d.SkillID, nullStr(d.DisableReason), d.DisabledBy)
	if err := row.Scan(&d.DisabledAt); err != nil {
		return mapPGError(err)
	}
	return nil
}

func (r *Repo) DeleteTenantDisable(ctx context.Context, tenantID, skillID int64) error {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM tenant_skill_disables WHERE tenant_id=$1 AND skill_id=$2`,
		tenantID, skillID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("tenant_skill_disable not found")
	}
	return nil
}

func (r *Repo) ListTenantDisables(ctx context.Context, tenantID int64) ([]domskill.TenantDisable, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT tenant_id, skill_id, COALESCE(disable_reason,''), disabled_at, disabled_by
		   FROM tenant_skill_disables WHERE tenant_id=$1 ORDER BY skill_id`,
		tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.TenantDisable{}
	for rows.Next() {
		var d domskill.TenantDisable
		if err := rows.Scan(&d.TenantID, &d.SkillID, &d.DisableReason, &d.DisabledAt, &d.DisabledBy); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (r *Repo) IsTenantSkillDisabled(ctx context.Context, tenantID, skillID int64) (bool, error) {
	var exists bool
	err := r.pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM tenant_skill_disables WHERE tenant_id=$1 AND skill_id=$2)`,
		tenantID, skillID).Scan(&exists)
	return exists, err
}

// ----------------------------------------------------------------------------
// user_agent_skill_overrides
// ----------------------------------------------------------------------------

const overrideCols = `
	id, account_id, tenant_id, agent_id, skill_id, behavior, expires_at,
	created_at, updated_at`

func scanOverride(row pgx.Row) (*domskill.UserOverride, error) {
	var o domskill.UserOverride
	if err := row.Scan(
		&o.ID, &o.AccountID, &o.TenantID, &o.AgentID, &o.SkillID,
		&o.Behavior, &o.ExpiresAt, &o.CreatedAt, &o.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &o, nil
}

func (r *Repo) UpsertUserOverride(ctx context.Context, o *domskill.UserOverride) error {
	const q = `
		INSERT INTO user_agent_skill_overrides (
			account_id, tenant_id, agent_id, skill_id, behavior, expires_at
		) VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (account_id, agent_id, skill_id) DO UPDATE SET
			behavior   = EXCLUDED.behavior,
			expires_at = EXCLUDED.expires_at,
			updated_at = now()
		RETURNING id, created_at, updated_at`
	row := r.pool.QueryRow(ctx, q,
		o.AccountID, o.TenantID, o.AgentID, o.SkillID, o.Behavior, o.ExpiresAt)
	if err := row.Scan(&o.ID, &o.CreatedAt, &o.UpdatedAt); err != nil {
		return mapPGError(err)
	}
	return nil
}

func (r *Repo) DeleteUserOverride(ctx context.Context, accountID, agentID, skillID int64) error {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM user_agent_skill_overrides
		 WHERE account_id=$1 AND agent_id=$2 AND skill_id=$3`,
		accountID, agentID, skillID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("user_agent_skill_override not found")
	}
	return nil
}

// ListUserOverrides 列出 (account, agent) 维度有效（未过期）的 override。
// 过滤 expires_at IS NULL OR expires_at > now() — 由 chip rail 装载使用。
func (r *Repo) ListUserOverrides(ctx context.Context, accountID, agentID int64) ([]domskill.UserOverride, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+overrideCols+` FROM user_agent_skill_overrides
		 WHERE account_id=$1 AND agent_id=$2
		   AND (expires_at IS NULL OR expires_at > now())
		 ORDER BY id DESC`,
		accountID, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.UserOverride{}
	for rows.Next() {
		o, err := scanOverride(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *o)
	}
	return out, rows.Err()
}

// PurgeExpiredUserOverrides 清理过期 override；返回删除行数。cron worker 每 5min 跑一次。
func (r *Repo) PurgeExpiredUserOverrides(ctx context.Context) (int64, error) {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM user_agent_skill_overrides
		 WHERE expires_at IS NOT NULL AND expires_at <= now()`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// ----------------------------------------------------------------------------
// client_builtin_handshakes
// ----------------------------------------------------------------------------

func (r *Repo) UpsertHandshake(ctx context.Context, h *domskill.ClientHandshake) error {
	const q = `
		INSERT INTO client_builtin_handshakes (
			account_id, client_platform, device_id,
			client_version, supported_builtin_keys, last_reported_at
		) VALUES ($1, $2, $3, $4, $5, now())
		ON CONFLICT (account_id, client_platform, device_id) DO UPDATE SET
			client_version         = EXCLUDED.client_version,
			supported_builtin_keys = EXCLUDED.supported_builtin_keys,
			last_reported_at       = now()
		RETURNING last_reported_at`
	row := r.pool.QueryRow(ctx, q,
		h.AccountID, h.ClientPlatform, h.DeviceID,
		h.ClientVersion, h.SupportedBuiltinKeys)
	return mapPGError(row.Scan(&h.LastReportedAt))
}

func (r *Repo) GetHandshakesForAccount(ctx context.Context, accountID int64) ([]domskill.ClientHandshake, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT account_id, client_platform, device_id, client_version,
		        supported_builtin_keys, last_reported_at
		   FROM client_builtin_handshakes
		  WHERE account_id=$1
		    AND last_reported_at > now() - INTERVAL '24 hours'`,
		accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.ClientHandshake{}
	for rows.Next() {
		var h domskill.ClientHandshake
		if err := rows.Scan(&h.AccountID, &h.ClientPlatform, &h.DeviceID,
			&h.ClientVersion, &h.SupportedBuiltinKeys, &h.LastReportedAt); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// RecomputeInstallCounts 在所有 skills 上跑一次 install_count 刷新。
//
// install_count = 装配该 skill 的不同 agent 数量；soft-deleted skill 也照刷（不可见，但
// 后续恢复时不会出现 stale count）。
func (r *Repo) RecomputeInstallCounts(ctx context.Context) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE skills s SET install_count = COALESCE(b.cnt, 0)
		   FROM (
		     SELECT skill_id, COUNT(DISTINCT agent_id) AS cnt
		       FROM agent_skill_bindings
		      GROUP BY skill_id
		   ) b
		  WHERE s.id = b.skill_id`)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx,
		`UPDATE skills s SET install_count = 0
		  WHERE NOT EXISTS (SELECT 1 FROM agent_skill_bindings b WHERE b.skill_id = s.id)`)
	return err
}

func (r *Repo) PurgeStaleHandshakes(ctx context.Context, before time.Time) (int64, error) {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM client_builtin_handshakes WHERE last_reported_at < $1`, before)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
