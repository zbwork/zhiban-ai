// Package skill 是 internal/domain/skill.Repository 的 PG 实现。
//
// 涉及表（F03 v0.9.1，detail 见 docs/features/F03-skills.md §2）：
//   - skills / skill_versions
//   - skill_categories / skill_labels / skill_label_bindings
//   - agent_skill_bindings
//   - tenant_skill_preferences / tenant_skill_disables
//   - user_agent_skill_overrides
//   - builtin_skill_keys
//   - client_builtin_handshakes
package skill

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Repo PG 实现。
type Repo struct {
	pool      *pgxpool.Pool
	community bool
}

// New 构造。
func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// NewCommunity excludes commercial pricing tables from all skill read projections.
func NewCommunity(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool, community: true} }
func (r *Repo) columns() string {
	if !r.community {
		return skillCols
	}
	start := strings.Index(skillCols, "COALESCE(s.billing_type")
	end := strings.Index(skillCols, "s.created_by")
	return skillCols[:start] + "'free', 'per_skill', NULL::bigint, 0::bigint, " + skillCols[end:]
}

// 编译期断言。
var _ domskill.Repository = (*Repo)(nil)

// ----------------------------------------------------------------------------
// skills
// ----------------------------------------------------------------------------

const skillCols = `
	s.id, s.uuid::text, s.code, s.name, COALESCE(s.description,''),
	COALESCE(s.usage_example,''), COALESCE(s.usage_example_images, '[]'::jsonb),
	COALESCE(s.icon_url,''), COALESCE(s.placeholder,''), COALESCE(s.submit_label,''),
	s.kind, s.builtin_key, s.execution_mode,
	s.scope_kind, s.tenant_id,
	s.source, s.visibility, s.category_id,
	s.input_chips_schema, s.hosting_modes, s.agent_compat,
	s.default_attached, s.default_pinned, s.sort_order,
	s.latest_version_id, s.status, s.install_count,
	COALESCE(s.billing_type, 'free'), COALESCE(s.pricing_mode, 'per_skill'),
	(
		SELECT dp.credits_per_call
		FROM skill_default_prices dp
		WHERE dp.skill_id = s.id AND dp.status = 'active'
		ORDER BY dp.effective_from DESC
		LIMIT 1
	),
	(
		SELECT count(*)
		FROM skill_operations so
		WHERE so.skill_id = s.id AND so.status = 'active'
	),
	s.created_by, s.updated_by, s.created_at, s.updated_at, s.deleted_at,
	s.marketing_visible`

func scanSkill(row pgx.Row) (*domskill.Skill, error) {
	var s domskill.Skill
	if err := row.Scan(
		&s.ID, &s.UUID, &s.Code, &s.Name, &s.Description,
		&s.UsageExample, &s.UsageExampleImages,
		&s.IconURL, &s.Placeholder, &s.SubmitLabel,
		&s.Kind, &s.BuiltinKey, &s.ExecutionMode,
		&s.ScopeKind, &s.TenantID,
		&s.Source, &s.Visibility, &s.CategoryID,
		&s.InputChipsSchema, &s.HostingModes, &s.AgentCompat,
		&s.DefaultAttached, &s.DefaultPinned, &s.SortOrder,
		&s.LatestVersionID, &s.Status, &s.InstallCount,
		&s.BillingType, &s.PricingMode,
		&s.DefaultCreditsPerCall, &s.OperationCount,
		&s.CreatedBy, &s.UpdatedBy, &s.CreatedAt, &s.UpdatedAt, &s.DeletedAt,
		&s.MarketingVisible,
	); err != nil {
		return nil, err
	}
	return &s, nil
}

// CreateSkill INSERT skills 一行，回填 ID/UUID/CreatedAt/UpdatedAt。
func (r *Repo) CreateSkill(ctx context.Context, s *domskill.Skill) error {
	const q = `
		INSERT INTO skills (
			code, name, description, usage_example, usage_example_images, icon_url, placeholder, submit_label,
			kind, builtin_key, execution_mode,
			scope_kind, tenant_id,
			source, visibility, category_id,
			input_chips_schema, hosting_modes, agent_compat,
			default_attached, default_pinned, sort_order,
			status, billing_type, pricing_mode, created_by
		) VALUES (
			$1,$2,$3,$4,COALESCE($5, '[]'::jsonb),$6,$7,$8,
			$9,$10,$11,
			$12,$13,
			$14,$15,$16,
			COALESCE($17, '[]'::jsonb), $18, COALESCE($19, '{}'::jsonb),
			$20,$21,$22,
			$23, COALESCE(NULLIF($24,''), 'free'), COALESCE(NULLIF($25,''), 'per_skill'), $26
		) RETURNING id, uuid::text, created_at, updated_at`
	row := r.pool.QueryRow(ctx, q,
		s.Code, s.Name, nullStr(s.Description), nullStr(s.UsageExample), nullJSON(s.UsageExampleImages),
		nullStr(s.IconURL), nullStr(s.Placeholder), nullStr(s.SubmitLabel),
		s.Kind, s.BuiltinKey, s.ExecutionMode,
		s.ScopeKind, s.TenantID,
		s.Source, s.Visibility, s.CategoryID,
		nullJSON(s.InputChipsSchema), s.HostingModes, nullJSON(s.AgentCompat),
		s.DefaultAttached, s.DefaultPinned, s.SortOrder,
		s.Status, s.BillingType, s.PricingMode, s.CreatedBy,
	)
	if err := row.Scan(&s.ID, &s.UUID, &s.CreatedAt, &s.UpdatedAt); err != nil {
		return mapPGError(err)
	}
	return nil
}

// GetSkillByUUID 取单条；includeDeleted=false 时 deleted_at IS NOT NULL 的行视为不存在。
func (r *Repo) GetSkillByUUID(ctx context.Context, uuid string, includeDeleted bool) (*domskill.Skill, error) {
	if uuid == "" {
		return nil, apperr.ErrInvalidParams.Withf("skill uuid required")
	}
	q := `SELECT ` + r.columns() + ` FROM skills s WHERE s.uuid=$1::uuid`
	if !includeDeleted {
		q += ` AND s.deleted_at IS NULL`
	}
	row := r.pool.QueryRow(ctx, q, uuid)
	sk, err := scanSkill(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill not found")
		}
		return nil, err
	}
	return sk, nil
}

// ListSkills 多维筛选 + 分页；返回行 + 命中总数。
func (r *Repo) ListSkills(ctx context.Context, f domskill.ListFilter) ([]domskill.Skill, int64, error) {
	where := []string{}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}

	if !f.IncludeDeleted {
		where = append(where, `s.deleted_at IS NULL`)
	}
	if f.ScopeKind != "" {
		add(`s.scope_kind = $%d`, f.ScopeKind)
	}
	if f.TenantID != nil {
		add(`s.tenant_id = $%d`, *f.TenantID)
	}
	if f.Kind != "" {
		add(`s.kind = $%d`, f.Kind)
	}
	if f.Status == "inactive" {
		where = append(where, `s.status <> 'active'`)
	} else if f.Status != "" {
		add(`s.status = $%d`, f.Status)
	}
	if f.CategoryID != nil {
		add(`s.category_id = $%d`, *f.CategoryID)
	}
	if f.Source != "" {
		add(`s.source = $%d`, f.Source)
	}
	if f.Visibility != "" {
		add(`s.visibility = $%d`, f.Visibility)
	}
	if f.BillingType != "" {
		add(`COALESCE(s.billing_type, 'free') = $%d`, f.BillingType)
	}
	if f.PricingMode != "" {
		add(`COALESCE(s.pricing_mode, 'per_skill') = $%d`, f.PricingMode)
	}
	if f.DefaultPrice == "configured" {
		where = append(where, `EXISTS (
			SELECT 1 FROM skill_default_prices dp
			WHERE dp.skill_id = s.id AND dp.status = 'active'
		)`)
	} else if f.DefaultPrice == "missing" {
		where = append(where, `NOT EXISTS (
			SELECT 1 FROM skill_default_prices dp
			WHERE dp.skill_id = s.id AND dp.status = 'active'
		)`)
	}
	if f.Operations == "has_operations" {
		where = append(where, `EXISTS (
			SELECT 1 FROM skill_operations so
			WHERE so.skill_id = s.id AND so.status = 'active'
		)`)
	} else if f.Operations == "no_operations" {
		where = append(where, `NOT EXISTS (
			SELECT 1 FROM skill_operations so
			WHERE so.skill_id = s.id AND so.status = 'active'
		)`)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		idx := len(args)
		where = append(where, fmt.Sprintf(
			`(s.code ILIKE $%d OR s.name ILIKE $%d OR COALESCE(s.description,'') ILIKE $%d)`,
			idx, idx, idx))
	}
	if len(f.LabelIDs) > 0 {
		add(`s.id IN (SELECT skill_id FROM skill_label_bindings WHERE label_id = ANY($%d::bigint[]))`, f.LabelIDs)
	}

	whereSQL := ""
	if len(where) > 0 {
		whereSQL = " WHERE " + strings.Join(where, " AND ")
	}

	// page
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	offset := f.Offset
	if offset < 0 {
		offset = 0
	}
	// 排序：按创建时间倒序；id DESC 用于同毫秒内 created_at 并列时的稳定 tiebreak。
	// sort_order 仍存在表上（手工调权用），但管理后台默认列表不再用它做主排序，
	// 避免“老 sort_order>0 的技能永远顶在最前面，新建的反而看不到”这类困惑。
	q := `SELECT ` + r.columns() + `, COUNT(*) OVER() FROM skills s` + whereSQL +
		` ORDER BY s.created_at DESC, s.id DESC LIMIT $` + fmt.Sprint(len(args)+1) +
		` OFFSET $` + fmt.Sprint(len(args)+2)
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []domskill.Skill{}
	var total int64
	for rows.Next() {
		var sk domskill.Skill
		if err := rows.Scan(
			&sk.ID, &sk.UUID, &sk.Code, &sk.Name, &sk.Description,
			&sk.UsageExample, &sk.UsageExampleImages,
			&sk.IconURL, &sk.Placeholder, &sk.SubmitLabel,
			&sk.Kind, &sk.BuiltinKey, &sk.ExecutionMode,
			&sk.ScopeKind, &sk.TenantID,
			&sk.Source, &sk.Visibility, &sk.CategoryID,
			&sk.InputChipsSchema, &sk.HostingModes, &sk.AgentCompat,
			&sk.DefaultAttached, &sk.DefaultPinned, &sk.SortOrder,
			&sk.LatestVersionID, &sk.Status, &sk.InstallCount,
			&sk.BillingType, &sk.PricingMode,
			&sk.DefaultCreditsPerCall, &sk.OperationCount,
			&sk.CreatedBy, &sk.UpdatedBy, &sk.CreatedAt, &sk.UpdatedAt, &sk.DeletedAt,
			&sk.MarketingVisible,
			&total,
		); err != nil {
			return nil, 0, err
		}
		out = append(out, sk)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx,
			`SELECT count(*) FROM skills s`+whereSQL, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

// ListMarketingShowcase 返回官网技能商店（对外营销）展示投影：仅 scope_kind=platform、status=active、
// marketing_visible=true 且未软删的技能；LEFT JOIN 有效分类取分类名；按运营 sort_order、热度、id 排序。
// limit<=0 或过大时钳到 200，防止误勾过多导致官网静态包膨胀（见 marketing-skill-showcase 契约）。
func (r *Repo) ListMarketingShowcase(ctx context.Context, limit int) ([]domskill.ShowcaseItem, error) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	const q = `
		SELECT s.name, COALESCE(s.description, ''), s.source, s.install_count,
		       COALESCE(s.icon_url, ''), COALESCE(c.name, '')
		FROM skills s
		LEFT JOIN skill_categories c
		       ON c.id = s.category_id AND c.status = 'active' AND c.is_deleted = false
		WHERE s.scope_kind = 'platform'
		  AND s.status = 'active'
		  AND s.marketing_visible = true
		  AND s.deleted_at IS NULL
		ORDER BY s.sort_order ASC, s.install_count DESC, s.id DESC
		LIMIT $1`
	rows, err := r.pool.Query(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []domskill.ShowcaseItem{}
	for rows.Next() {
		var it domskill.ShowcaseItem
		if err := rows.Scan(
			&it.Name, &it.Description, &it.Source, &it.InstallCount, &it.IconURL, &it.CategoryName,
		); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullJSON(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return string(b)
}

// mapPGError 把 PG 唯一约束 / CHECK 违反映射成 apperr 业务错误。
func mapPGError(err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "uq_skills_code_platform"),
		strings.Contains(msg, "uq_skills_code_tenant"):
		return apperr.ErrConflict.Withf("skill.code_taken").Wrap(err)
	case strings.Contains(msg, "skills_kind_consistency"):
		return apperr.ErrInvalidParams.Withf("skill.kind_inconsistency").Wrap(err)
	case strings.Contains(msg, "skills_chips_source_of_truth"):
		return apperr.ErrInvalidParams.Withf("skill.chips_source_of_truth_violation").Wrap(err)
	case strings.Contains(msg, "skills_scope_consistency"):
		return apperr.ErrInvalidParams.Withf("skill.scope_inconsistency").Wrap(err)
	case strings.Contains(msg, "skills_hosting_modes_valid"):
		return apperr.ErrInvalidParams.Withf("skill.hosting_modes_invalid").Wrap(err)
	case strings.Contains(msg, "skills_usage_example_images_array"):
		return apperr.ErrInvalidParams.Withf("skill.usage_example_images_invalid").Wrap(err)
	}
	return err
}
