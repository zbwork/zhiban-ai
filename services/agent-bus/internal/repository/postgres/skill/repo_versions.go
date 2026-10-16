package skill

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ----------------------------------------------------------------------------
// skills extended (Get/Patch/Soft-delete/UpdateStatus/UpdateLatestVersion)
// ----------------------------------------------------------------------------

// GetSkillByID 取单条；不区分 deleted_at（用于 Service 内部级联校验）。
func (r *Repo) GetSkillByID(ctx context.Context, id int64) (*domskill.Skill, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+r.columns()+` FROM skills s WHERE s.id=$1`, id)
	sk, err := scanSkill(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill not found")
		}
		return nil, err
	}
	return sk, nil
}

// PatchSkill 字段白名单 UPDATE；fields 已由 service 层过滤。
func (r *Repo) PatchSkill(ctx context.Context, uuid string, fields map[string]any, updatedBy *int64) (*domskill.Skill, error) {
	if len(fields) == 0 && updatedBy == nil {
		return r.GetSkillByUUID(ctx, uuid, false)
	}
	allowed := map[string]struct{}{
		"name": {}, "description": {}, "usage_example": {}, "usage_example_images": {},
		"icon_url": {}, "placeholder": {}, "submit_label": {},
		"execution_mode": {}, "visibility": {}, "category_id": {}, "source": {},
		"hosting_modes": {}, "agent_compat": {}, "input_chips_schema": {},
		"default_attached": {}, "default_pinned": {}, "sort_order": {}, "status": {},
		"marketing_visible": {},
	}
	sets := []string{}
	args := []any{}
	for k, v := range fields {
		if _, ok := allowed[k]; !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, fmt.Sprintf("%s=$%d", k, len(args)))
	}
	if updatedBy != nil {
		args = append(args, *updatedBy)
		sets = append(sets, fmt.Sprintf("updated_by=$%d", len(args)))
	}
	sets = append(sets, "updated_at=now()")
	args = append(args, uuid)
	q := `UPDATE skills SET ` + strings.Join(sets, ",") +
		` WHERE uuid=$` + fmt.Sprint(len(args)) + `::uuid AND deleted_at IS NULL`
	tag, err := r.pool.Exec(ctx, q, args...)
	if err != nil {
		return nil, mapPGError(err)
	}
	if tag.RowsAffected() == 0 {
		return nil, apperr.ErrNotFound.Withf("skill not found")
	}
	return r.GetSkillByUUID(ctx, uuid, false)
}

// SoftDeleteSkill 只写删除字段，不混用 status。
func (r *Repo) SoftDeleteSkill(ctx context.Context, uuid string) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE skills SET deleted_at=now(), updated_at=now()
		   WHERE uuid=$1::uuid AND deleted_at IS NULL`, uuid)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("skill not found")
	}
	return nil
}

// BatchSoftDeletePlatformSkills 在单个事务中锁定、校验并软删除全部目标。
// 先校验数量再 UPDATE，避免过期勾选导致部分成功。
func (r *Repo) BatchSoftDeletePlatformSkills(ctx context.Context, uuids []string) ([]domskill.Skill, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	rows, err := tx.Query(ctx, `
		SELECT id, uuid::text, code
		  FROM skills
		 WHERE uuid::text = ANY($1::text[])
		   AND scope_kind = 'platform'
		   AND deleted_at IS NULL
		 ORDER BY id
		 FOR UPDATE`, uuids)
	if err != nil {
		return nil, err
	}
	items := make([]domskill.Skill, 0, len(uuids))
	ids := make([]int64, 0, len(uuids))
	for rows.Next() {
		var item domskill.Skill
		if err := rows.Scan(&item.ID, &item.UUID, &item.Code); err != nil {
			rows.Close()
			return nil, err
		}
		items = append(items, item)
		ids = append(ids, item.ID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	if len(items) != len(uuids) {
		return nil, apperr.ErrConflict.Withf("skill.batch_delete_target_changed")
	}

	tag, err := tx.Exec(ctx, `
		UPDATE skills
		   SET deleted_at = now(), updated_at = now()
		 WHERE id = ANY($1::bigint[])
		   AND deleted_at IS NULL`, ids)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != int64(len(ids)) {
		return nil, apperr.ErrConflict.Withf("skill.batch_delete_target_changed")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return items, nil
}

// UpdateSkillStatus 显式切 status（draft → active 等）。
func (r *Repo) UpdateSkillStatus(ctx context.Context, id int64, status string) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE skills SET status=$2, updated_at=now() WHERE id=$1`, id, status)
	return err
}

// UpdateSkillLatestVersion 切 latest_version_id；按 spec §3.1.0.D 服务层调
// 用前应该已比较 published_at。
func (r *Repo) UpdateSkillLatestVersion(ctx context.Context, id, versionID int64) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE skills SET latest_version_id=$2, updated_at=now() WHERE id=$1`, id, versionID)
	return err
}

// ----------------------------------------------------------------------------
// skill_versions
// ----------------------------------------------------------------------------

const versionCols = `
	v.id, v.uuid::text, v.skill_id, v.version, v.status, COALESCE(v.changelog,''),
	COALESCE(v.package_url,''), v.package_size_bytes, COALESCE(v.package_sha256,''),
	v.input_chips_schema_snapshot, v.agent_compat_snapshot,
	v.grayscale_pct, v.grayscale_strategy, v.grayscale_allowlist,
	v.published_at, v.published_by, v.created_at, v.updated_at`

func scanVersion(row pgx.Row) (*domskill.SkillVersion, error) {
	var v domskill.SkillVersion
	if err := row.Scan(
		&v.ID, &v.UUID, &v.SkillID, &v.Version, &v.Status, &v.Changelog,
		&v.PackageURL, &v.PackageSizeBytes, &v.PackageSHA256,
		&v.InputChipsSchemaSnapshot, &v.AgentCompatSnapshot,
		&v.GrayscalePct, &v.GrayscaleStrategy, &v.GrayscaleAllowlist,
		&v.PublishedAt, &v.PublishedBy, &v.CreatedAt, &v.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &v, nil
}

// CreateVersion INSERT skill_versions 一行，回填 ID/UUID/CreatedAt/UpdatedAt。
func (r *Repo) CreateVersion(ctx context.Context, v *domskill.SkillVersion) error {
	const q = `
		INSERT INTO skill_versions (
			skill_id, version, status, changelog,
			package_url, package_size_bytes, package_sha256,
			input_chips_schema_snapshot, agent_compat_snapshot,
			grayscale_pct, grayscale_strategy, grayscale_allowlist
		) VALUES (
			$1,$2,$3,$4,
			$5,$6,$7,
			$8,$9,
			$10,$11,$12
		) RETURNING id, uuid::text, created_at, updated_at`
	row := r.pool.QueryRow(ctx, q,
		v.SkillID, v.Version, v.Status, nullStr(v.Changelog),
		nullStr(v.PackageURL), v.PackageSizeBytes, nullStr(v.PackageSHA256),
		nullJSON(v.InputChipsSchemaSnapshot), nullJSON(v.AgentCompatSnapshot),
		v.GrayscalePct, v.GrayscaleStrategy, v.GrayscaleAllowlist,
	)
	if err := row.Scan(&v.ID, &v.UUID, &v.CreatedAt, &v.UpdatedAt); err != nil {
		if strings.Contains(err.Error(), "skill_versions_skill_id_version_uniq") {
			return apperr.ErrConflict.Withf("skill.version_already_exists").Wrap(err)
		}
		if strings.Contains(err.Error(), "skill_versions_package_size_limit") {
			return apperr.ErrInvalidParams.Withf("skill.package_too_large").Wrap(err)
		}
		return err
	}
	return nil
}

// GetVersionByUUID 取单条；不存在返 ErrNotFound。
func (r *Repo) GetVersionByUUID(ctx context.Context, uuid string) (*domskill.SkillVersion, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+versionCols+` FROM skill_versions v WHERE v.uuid=$1::uuid`, uuid)
	v, err := scanVersion(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill version not found")
		}
		return nil, err
	}
	return v, nil
}

// GetVersionByID 内部级联校验用。
func (r *Repo) GetVersionByID(ctx context.Context, id int64) (*domskill.SkillVersion, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+versionCols+` FROM skill_versions v WHERE v.id=$1`, id)
	v, err := scanVersion(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill version not found")
		}
		return nil, err
	}
	return v, nil
}

// ListVersions 按 created_at DESC 列。
func (r *Repo) ListVersions(ctx context.Context, skillID int64) ([]domskill.SkillVersion, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+versionCols+` FROM skill_versions v
		   WHERE v.skill_id=$1 ORDER BY v.created_at DESC, v.id DESC`, skillID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.SkillVersion{}
	for rows.Next() {
		v, err := scanVersion(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *v)
	}
	return out, rows.Err()
}

// ListVersionNamesByIDs 一条 SQL 批量取 version 字符串，key=skill_versions.id。
// 空入参直接返回空 map，不打 DB。
func (r *Repo) ListVersionNamesByIDs(ctx context.Context, ids []int64) (map[int64]string, error) {
	out := map[int64]string{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT id, version FROM skill_versions WHERE id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var version string
		if err := rows.Scan(&id, &version); err != nil {
			return nil, err
		}
		out[id] = version
	}
	return out, rows.Err()
}

// GetLatestPublishedVersion 取 skill 当前 latest_version_id 指向的 version；
// 若 latest_version_id 为空，返回 (nil, nil)。
func (r *Repo) GetLatestPublishedVersion(ctx context.Context, skillID int64) (*domskill.SkillVersion, error) {
	var latestID *int64
	if err := r.pool.QueryRow(ctx,
		`SELECT latest_version_id FROM skills WHERE id=$1`, skillID).Scan(&latestID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill not found")
		}
		return nil, err
	}
	if latestID == nil {
		return nil, nil
	}
	return r.GetVersionByID(ctx, *latestID)
}

// UpdateVersion PATCH 指定字段；fields 由 service 过滤。
//
// 白名单除 changelog / grayscale_* 之外，还包含 §4.7 zip 上传后回写的
// package_url / package_sha256 / package_size_bytes，以及 §4.2 / §1.4 D27
// 真值源 input_chips_schema_snapshot / agent_compat_snapshot。
func (r *Repo) UpdateVersion(ctx context.Context, uuid string, fields map[string]any) (*domskill.SkillVersion, error) {
	allowed := map[string]struct{}{
		"changelog": {}, "grayscale_pct": {}, "grayscale_strategy": {}, "grayscale_allowlist": {},
		"package_url": {}, "package_sha256": {}, "package_size_bytes": {},
		"input_chips_schema_snapshot": {}, "agent_compat_snapshot": {},
	}
	sets := []string{}
	args := []any{}
	for k, v := range fields {
		if _, ok := allowed[k]; !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, fmt.Sprintf("%s=$%d", k, len(args)))
	}
	if len(sets) == 0 {
		return r.GetVersionByUUID(ctx, uuid)
	}
	sets = append(sets, "updated_at=now()")
	args = append(args, uuid)
	q := `UPDATE skill_versions SET ` + strings.Join(sets, ",") +
		` WHERE uuid=$` + fmt.Sprint(len(args)) + `::uuid`
	tag, err := r.pool.Exec(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, apperr.ErrNotFound.Withf("skill version not found")
	}
	return r.GetVersionByUUID(ctx, uuid)
}

// PublishVersionAtomic 把 publish 流程合并为 2 条 SQL（节省 5-6 个 PG 往返）：
//  1. UPDATE skill_versions SET 灰度 + status='published' + published_at WHERE uuid=$ AND status='draft' RETURNING *
//  2. UPDATE skills SET latest_version_id（按 published_at 单调）+ 首版 status draft→active WHERE id=$
//
// 第二条 UPDATE 用 SQL CASE / 子查询完成"published_at 单调比较 + 首版 active 切换"，
// 避免服务层多次 GetLatestPublishedVersion / UpdateSkillLatestVersion / UpdateSkillStatus 串行 RTT。
func (r *Repo) PublishVersionAtomic(
	ctx context.Context,
	uuid string,
	pct int,
	strategy string,
	allowlist []int64,
) (*domskill.SkillVersion, error) {
	// 直接 RETURNING 同名列；不能用 SELECT JOIN CTE，因为 Postgres CTE 内 UPDATE
	// 之后同语句的二次读会看到 pre-modification 值（导致 status 仍是 'draft'）。
	const updateVer = `
		UPDATE skill_versions
		   SET grayscale_pct = $2,
		       grayscale_strategy = $3,
		       grayscale_allowlist = $4,
		       status = 'published',
		       published_at = COALESCE(published_at, now()),
		       updated_at = now()
		 WHERE uuid = $1::uuid AND status = 'draft'
		 RETURNING id, uuid::text, skill_id, version, status, COALESCE(changelog,''),
		           COALESCE(package_url,''), package_size_bytes, COALESCE(package_sha256,''),
		           input_chips_schema_snapshot, agent_compat_snapshot,
		           grayscale_pct, grayscale_strategy, grayscale_allowlist,
		           published_at, published_by, created_at, updated_at`
	row := r.pool.QueryRow(ctx, updateVer, uuid, pct, strategy, allowlist)
	v, err := scanVersion(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrConflict.Withf("skill.version_status_locked")
		}
		return nil, err
	}

	// skills 表更新：
	// - latest_version_id：当前为空，或当前指向的版本 published_at < 新版本 published_at 时切换。
	// - status：当前 draft → active（首版发布触发上架），其他状态保持。
	const updateSkill = `
		UPDATE skills s
		   SET latest_version_id = CASE
		         WHEN s.latest_version_id IS NULL THEN $2
		         WHEN COALESCE((SELECT published_at FROM skill_versions WHERE id = s.latest_version_id),
		                       'epoch'::timestamptz) < $3
		           THEN $2
		         ELSE s.latest_version_id
		       END,
		       status = CASE WHEN s.status='draft' THEN 'active' ELSE s.status END,
		       updated_at = now()
		 WHERE s.id = $1`
	if _, err := r.pool.Exec(ctx, updateSkill, v.SkillID, v.ID, v.PublishedAt); err != nil {
		return nil, err
	}
	return v, nil
}

// UpdateVersionStatus 仅在 spec §3.1.C / §3.1.D / §3.1.E 调。
func (r *Repo) UpdateVersionStatus(ctx context.Context, id int64, status string) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE skill_versions SET status=$2::varchar, updated_at=now(),
		   published_at = CASE WHEN $2::varchar='published' AND published_at IS NULL THEN now() ELSE published_at END
		   WHERE id=$1`, id, status)
	return err
}

// CountPublishedFullBaselineExcluding 计算除 excludeID 外，skill 还有几个
// `status='published' AND grayscale_pct=100` baseline；spec §3.1.D archive 不变量校验用。
func (r *Repo) CountPublishedFullBaselineExcluding(ctx context.Context, skillID, excludeID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx,
		`SELECT count(*) FROM skill_versions
		   WHERE skill_id=$1 AND status='published' AND grayscale_pct=100 AND id <> $2`,
		skillID, excludeID).Scan(&n)
	return n, err
}

// ----------------------------------------------------------------------------
// skill_label_bindings
// ----------------------------------------------------------------------------

// ReplaceSkillLabels 全量替换；事务内 DELETE + INSERT。
func (r *Repo) ReplaceSkillLabels(ctx context.Context, skillID int64, labelIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	if _, err := tx.Exec(ctx, `DELETE FROM skill_label_bindings WHERE skill_id=$1`, skillID); err != nil {
		return err
	}
	for _, lid := range labelIDs {
		if _, err := tx.Exec(ctx,
			`INSERT INTO skill_label_bindings (skill_id, label_id) VALUES ($1,$2)
			   ON CONFLICT DO NOTHING`, skillID, lid); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// ListLabelIDsBySkillIDs 批量查多个 skill 的 label_id 列表，避免列表页 N+1。
//
// 返回 map[skill_id] => []label_id（按 sort_order, id 稳定排序）。空入参返回空 map。
func (r *Repo) ListLabelIDsBySkillIDs(ctx context.Context, skillIDs []int64) (map[int64][]int64, error) {
	out := make(map[int64][]int64)
	if len(skillIDs) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT b.skill_id, b.label_id
		   FROM skill_label_bindings b JOIN skill_labels l ON l.id=b.label_id
		  WHERE b.skill_id = ANY($1::bigint[])
		  ORDER BY l.sort_order ASC, l.id ASC`, skillIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var skillID, labelID int64
		if err := rows.Scan(&skillID, &labelID); err != nil {
			return nil, err
		}
		out[skillID] = append(out[skillID], labelID)
	}
	return out, rows.Err()
}

// ListSkillLabels 列出该 skill 当前挂的全部能力标签。
func (r *Repo) ListSkillLabels(ctx context.Context, skillID int64) ([]domskill.Label, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT l.id, l.code, l.name, COALESCE(l.description,''), l.sort_order, l.status, l.created_at, l.updated_at
		   FROM skill_label_bindings b JOIN skill_labels l ON l.id=b.label_id
		  WHERE b.skill_id=$1 ORDER BY l.sort_order ASC, l.id ASC`, skillID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domskill.Label{}
	for rows.Next() {
		var l domskill.Label
		if err := rows.Scan(&l.ID, &l.Code, &l.Name, &l.Description, &l.SortOrder, &l.Status, &l.CreatedAt, &l.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
