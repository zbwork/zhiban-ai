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
// skill_categories
// ----------------------------------------------------------------------------

func (r *Repo) ListCategories(ctx context.Context, f domskill.DictListFilter) ([]domskill.Category, int64, error) {
	where, args := buildDictWhere(f, "", "code", "name", "description")
	limit, offset := normalizePage(f.Limit, f.Offset)
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx,
		`SELECT id, code, name, category_kind, COALESCE(description,''), sort_order, status,
		        created_at, updated_at, is_deleted, deleted_at, deleted_by, COUNT(*) OVER()
		   FROM skill_categories
		  WHERE `+where+`
		  ORDER BY status ASC, sort_order ASC, id ASC
		  LIMIT $`+fmt.Sprint(len(args)-1)+` OFFSET $`+fmt.Sprint(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []domskill.Category{}
	var total int64
	for rows.Next() {
		var c domskill.Category
		if err := rows.Scan(
			&c.ID, &c.Code, &c.Name, &c.CategoryKind, &c.Description, &c.SortOrder, &c.Status,
			&c.CreatedAt, &c.UpdatedAt, &c.IsDeleted, &c.DeletedAt, &c.DeletedBy, &total,
		); err != nil {
			return nil, 0, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		total, err = r.countRows(ctx, "skill_categories", where, args[:len(args)-2])
		if err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *Repo) CreateCategory(ctx context.Context, c *domskill.Category) error {
	row := r.pool.QueryRow(ctx,
		`INSERT INTO skill_categories (code, name, category_kind, description, sort_order)
		    VALUES ($1,$2,$3,$4,$5)
		 RETURNING id, created_at, updated_at, is_deleted`,
		c.Code, c.Name, c.CategoryKind, nullStr(c.Description), c.SortOrder)
	if err := row.Scan(&c.ID, &c.CreatedAt, &c.UpdatedAt, &c.IsDeleted); err != nil {
		if strings.Contains(err.Error(), "skill_categories_code_key") {
			return apperr.ErrConflict.Withf("category.code_taken").Wrap(err)
		}
		return err
	}
	c.Status = domskill.StatusActive
	return nil
}

func (r *Repo) PatchCategory(ctx context.Context, id int64, fields map[string]any) (*domskill.Category, error) {
	allowed := map[string]struct{}{"code": {}, "name": {}, "description": {}, "sort_order": {}, "status": {}}
	if affected, err := r.patchDictRow(ctx, "skill_categories", id, fields, allowed); err != nil {
		if strings.Contains(err.Error(), "skill_categories_code_key") {
			return nil, apperr.ErrConflict.Withf("category.code_taken").Wrap(err)
		}
		return nil, err
	} else if !affected {
		return nil, apperr.ErrNotFound.Withf("category not found")
	}
	row := r.pool.QueryRow(ctx,
		`SELECT id, code, name, category_kind, COALESCE(description,''), sort_order, status,
		        created_at, updated_at, is_deleted, deleted_at, deleted_by
		   FROM skill_categories WHERE id=$1 AND is_deleted=false`, id)
	var c domskill.Category
	if err := row.Scan(
		&c.ID, &c.Code, &c.Name, &c.CategoryKind, &c.Description, &c.SortOrder, &c.Status,
		&c.CreatedAt, &c.UpdatedAt, &c.IsDeleted, &c.DeletedAt, &c.DeletedBy,
	); err != nil {
		return nil, err
	}
	return &c, nil
}

func (r *Repo) DeleteCategory(ctx context.Context, id int64, deletedBy *int64) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE skill_categories
		    SET is_deleted=true, deleted_at=now(), deleted_by=$2, updated_at=now()
		  WHERE id=$1 AND is_deleted=false`, id, deletedBy)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("category not found")
	}
	return nil
}

// ----------------------------------------------------------------------------
// skill_labels
// ----------------------------------------------------------------------------

func (r *Repo) ListLabels(ctx context.Context, f domskill.DictListFilter) ([]domskill.Label, int64, error) {
	where, args := buildDictWhere(f, "", "code", "name", "description")
	limit, offset := normalizePage(f.Limit, f.Offset)
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx,
		`SELECT id, code, name, COALESCE(description,''), sort_order, status,
		        created_at, updated_at, is_deleted, deleted_at, deleted_by, COUNT(*) OVER()
		   FROM skill_labels
		  WHERE `+where+`
		  ORDER BY status ASC, sort_order ASC, id ASC
		  LIMIT $`+fmt.Sprint(len(args)-1)+` OFFSET $`+fmt.Sprint(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []domskill.Label{}
	var total int64
	for rows.Next() {
		var l domskill.Label
		if err := rows.Scan(
			&l.ID, &l.Code, &l.Name, &l.Description, &l.SortOrder, &l.Status,
			&l.CreatedAt, &l.UpdatedAt, &l.IsDeleted, &l.DeletedAt, &l.DeletedBy, &total,
		); err != nil {
			return nil, 0, err
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		total, err = r.countRows(ctx, "skill_labels", where, args[:len(args)-2])
		if err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *Repo) CreateLabel(ctx context.Context, l *domskill.Label) error {
	row := r.pool.QueryRow(ctx,
		`INSERT INTO skill_labels (code, name, description, sort_order) VALUES ($1,$2,$3,$4)
		 RETURNING id, created_at, updated_at, is_deleted`,
		l.Code, l.Name, nullStr(l.Description), l.SortOrder)
	if err := row.Scan(&l.ID, &l.CreatedAt, &l.UpdatedAt, &l.IsDeleted); err != nil {
		if strings.Contains(err.Error(), "skill_labels_code_key") {
			return apperr.ErrConflict.Withf("label.code_taken").Wrap(err)
		}
		return err
	}
	l.Status = domskill.StatusActive
	return nil
}

func (r *Repo) PatchLabel(ctx context.Context, id int64, fields map[string]any) (*domskill.Label, error) {
	allowed := map[string]struct{}{"code": {}, "name": {}, "description": {}, "sort_order": {}, "status": {}}
	if affected, err := r.patchDictRow(ctx, "skill_labels", id, fields, allowed); err != nil {
		if strings.Contains(err.Error(), "skill_labels_code_key") {
			return nil, apperr.ErrConflict.Withf("label.code_taken").Wrap(err)
		}
		return nil, err
	} else if !affected {
		return nil, apperr.ErrNotFound.Withf("label not found")
	}
	row := r.pool.QueryRow(ctx,
		`SELECT id, code, name, COALESCE(description,''), sort_order, status,
		        created_at, updated_at, is_deleted, deleted_at, deleted_by
		   FROM skill_labels WHERE id=$1 AND is_deleted=false`, id)
	var l domskill.Label
	if err := row.Scan(
		&l.ID, &l.Code, &l.Name, &l.Description, &l.SortOrder, &l.Status,
		&l.CreatedAt, &l.UpdatedAt, &l.IsDeleted, &l.DeletedAt, &l.DeletedBy,
	); err != nil {
		return nil, err
	}
	return &l, nil
}

func (r *Repo) DeleteLabel(ctx context.Context, id int64, deletedBy *int64) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE skill_labels
		    SET is_deleted=true, deleted_at=now(), deleted_by=$2, updated_at=now()
		  WHERE id=$1 AND is_deleted=false`, id, deletedBy)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("label not found")
	}
	return nil
}

// ----------------------------------------------------------------------------
// builtin_skill_keys
// ----------------------------------------------------------------------------

func (r *Repo) ListBuiltinKeys(ctx context.Context, f domskill.DictListFilter) ([]domskill.BuiltinKey, int64, error) {
	where, args := buildDictWhere(f, "default_execution_mode", "code", "name", "description")
	limit, offset := normalizePage(f.Limit, f.Offset)
	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx,
		`SELECT id, code, name, COALESCE(description,''), supported_platforms, min_client_versions,
		         default_execution_mode, default_native_capabilities, registered_by, registered_at, updated_at, status,
		         is_deleted, deleted_at, deleted_by, COUNT(*) OVER()
		   FROM builtin_skill_keys
		  WHERE `+where+`
		  ORDER BY status ASC, id ASC
		  LIMIT $`+fmt.Sprint(len(args)-1)+` OFFSET $`+fmt.Sprint(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []domskill.BuiltinKey{}
	var total int64
	for rows.Next() {
		var b domskill.BuiltinKey
		if err := rows.Scan(&b.ID, &b.Code, &b.Name, &b.Description,
			&b.SupportedPlatforms, &b.MinClientVersions, &b.DefaultExecutionMode,
			&b.DefaultNativeCapabilities, &b.RegisteredBy, &b.RegisteredAt, &b.UpdatedAt, &b.Status,
			&b.IsDeleted, &b.DeletedAt, &b.DeletedBy, &total); err != nil {
			return nil, 0, err
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		total, err = r.countRows(ctx, "builtin_skill_keys", where, args[:len(args)-2])
		if err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *Repo) CreateBuiltinKey(ctx context.Context, b *domskill.BuiltinKey) error {
	row := r.pool.QueryRow(ctx,
		`INSERT INTO builtin_skill_keys (
		   code, name, description, supported_platforms, min_client_versions,
		   default_execution_mode, default_native_capabilities, registered_by, status
		 ) VALUES ($1,$2,$3,$4, COALESCE($5::jsonb,'{}'::jsonb), $6, $7, $8, COALESCE($9,'active'))
		 RETURNING id, registered_at, updated_at, is_deleted`,
		b.Code, b.Name, nullStr(b.Description), b.SupportedPlatforms, nullJSON(b.MinClientVersions),
		b.DefaultExecutionMode, b.DefaultNativeCapabilities, b.RegisteredBy, nullStr(b.Status))
	if err := row.Scan(&b.ID, &b.RegisteredAt, &b.UpdatedAt, &b.IsDeleted); err != nil {
		if strings.Contains(err.Error(), "builtin_skill_keys_code_key") {
			return apperr.ErrConflict.Withf("builtin_key.code_taken").Wrap(err)
		}
		return err
	}
	if b.Status == "" {
		b.Status = domskill.BuiltinKeyActive
	}
	return nil
}

func (r *Repo) PatchBuiltinKey(ctx context.Context, id int64, fields map[string]any) (*domskill.BuiltinKey, error) {
	allowed := map[string]struct{}{
		"name": {}, "description": {}, "supported_platforms": {}, "min_client_versions": {},
		"default_execution_mode": {}, "default_native_capabilities": {}, "status": {},
	}
	if affected, err := r.patchDictRow(ctx, "builtin_skill_keys", id, fields, allowed); err != nil {
		return nil, err
	} else if !affected {
		return nil, apperr.ErrNotFound.Withf("builtin_key not found")
	}
	rows, err := r.pool.Query(ctx,
		`SELECT id, code, name, COALESCE(description,''), supported_platforms, min_client_versions,
		         default_execution_mode, default_native_capabilities, registered_by, registered_at, updated_at, status,
		         is_deleted, deleted_at, deleted_by
		   FROM builtin_skill_keys WHERE id=$1 AND is_deleted=false`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, apperr.ErrNotFound
	}
	var b domskill.BuiltinKey
	if err := rows.Scan(&b.ID, &b.Code, &b.Name, &b.Description,
		&b.SupportedPlatforms, &b.MinClientVersions, &b.DefaultExecutionMode,
		&b.DefaultNativeCapabilities, &b.RegisteredBy, &b.RegisteredAt, &b.UpdatedAt, &b.Status,
		&b.IsDeleted, &b.DeletedAt, &b.DeletedBy); err != nil {
		return nil, err
	}
	return &b, nil
}

func (r *Repo) DeleteBuiltinKey(ctx context.Context, id int64, deletedBy *int64) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE builtin_skill_keys
		    SET is_deleted=true, deleted_at=now(), deleted_by=$2, updated_at=now()
		  WHERE id=$1 AND is_deleted=false`, id, deletedBy)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("builtin_key not found")
	}
	return nil
}

func (r *Repo) GetBuiltinKeyByCode(ctx context.Context, code string) (*domskill.BuiltinKey, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, code, name, COALESCE(description,''), supported_platforms, min_client_versions,
		         default_execution_mode, default_native_capabilities, registered_by, registered_at, updated_at, status,
		         is_deleted, deleted_at, deleted_by
		   FROM builtin_skill_keys WHERE code=$1 AND is_deleted=false`, code)
	var b domskill.BuiltinKey
	if err := row.Scan(&b.ID, &b.Code, &b.Name, &b.Description,
		&b.SupportedPlatforms, &b.MinClientVersions, &b.DefaultExecutionMode,
		&b.DefaultNativeCapabilities, &b.RegisteredBy, &b.RegisteredAt, &b.UpdatedAt, &b.Status,
		&b.IsDeleted, &b.DeletedAt, &b.DeletedBy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("builtin_key not found")
		}
		return nil, err
	}
	return &b, nil
}

// ----------------------------------------------------------------------------
// 字典通用 PATCH（白名单字段 + updated_at=now()）
// ----------------------------------------------------------------------------

func (r *Repo) patchDictRow(ctx context.Context, table string, id int64, fields map[string]any, allowed map[string]struct{}) (bool, error) {
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
		// 没有可改字段；按"未找到改"返回 false 让 caller 知道（避免 silent no-op）
		args = append(args, id)
		var exists int
		err := r.pool.QueryRow(ctx, fmt.Sprintf(`SELECT 1 FROM %s WHERE id=$1 AND is_deleted=false`, table), id).Scan(&exists)
		if err != nil {
			return false, err
		}
		return true, nil
	}
	sets = append(sets, "updated_at=now()")
	args = append(args, id)
	q := fmt.Sprintf(`UPDATE %s SET %s WHERE id=$%d AND is_deleted=false`, table, strings.Join(sets, ","), len(args))
	tag, err := r.pool.Exec(ctx, q, args...)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func buildDictWhere(f domskill.DictListFilter, executionModeColumn string, keywordColumns ...string) (string, []any) {
	where := []string{"is_deleted=false"}
	args := []any{}
	if f.Status != "" {
		args = append(args, f.Status)
		where = append(where, fmt.Sprintf("status=$%d", len(args)))
	}
	if f.ExecutionMode != "" && executionModeColumn != "" {
		args = append(args, f.ExecutionMode)
		where = append(where, fmt.Sprintf("%s=$%d", executionModeColumn, len(args)))
	}
	if q := strings.TrimSpace(f.Keyword); q != "" {
		args = append(args, "%"+q+"%")
		parts := make([]string, 0, len(keywordColumns))
		for _, col := range keywordColumns {
			parts = append(parts, fmt.Sprintf("%s ILIKE $%d", col, len(args)))
		}
		where = append(where, "("+strings.Join(parts, " OR ")+")")
	}
	return strings.Join(where, " AND "), args
}

func normalizePage(limit, offset int) (int, int) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 200 {
		limit = 200
	}
	if offset < 0 {
		offset = 0
	}
	return limit, offset
}

func (r *Repo) countRows(ctx context.Context, table, where string, args []any) (int64, error) {
	var total int64
	err := r.pool.QueryRow(ctx, fmt.Sprintf("SELECT count(*) FROM %s WHERE %s", table, where), args...).Scan(&total)
	return total, err
}
