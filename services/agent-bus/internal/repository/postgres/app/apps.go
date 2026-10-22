// Package app 是 domain/app 的 pgx 仓储集合 (5 个表)。
package app

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// =====================================================
// AppRepo
// =====================================================

type AppRepo struct{ pool *pgxpool.Pool }

func NewAppRepo(pool *pgxpool.Pool) *AppRepo { return &AppRepo{pool: pool} }

const appCols = `id, uuid::text, tenant_id, COALESCE(creator_id,0), code, name,
	    COALESCE(description,''), COALESCE(icon_url,''), COALESCE(color,''),
	    display_mode, COALESCE(usage_scope,'all'), launch_uri, oauth_client_id, category_id, sort_order,
	    COALESCE((SELECT c.uuid::text FROM app_category c WHERE c.id = apps.category_id), ''),
	    status, is_system, COALESCE(metadata,'{}'::jsonb), created_at, updated_at, deleted_at`

func scanApp(row pgx.Row) (*dom.App, error) {
	var x dom.App
	var meta []byte
	var tenantID *int64
	if err := row.Scan(&x.ID, &x.UUID, &tenantID, &x.CreatorID, &x.Code, &x.Name,
		&x.Description, &x.IconURL, &x.Color, &x.DisplayMode, &x.UsageScope, &x.LaunchURI,
		&x.OAuthClientID, &x.CategoryID, &x.SortOrder, &x.CategoryUUID, &x.Status, &x.IsSystem, &meta,
		&x.CreatedAt, &x.UpdatedAt, &x.DeletedAt); err != nil {
		return nil, err
	}
	if tenantID != nil {
		x.TenantID = *tenantID
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &x.Metadata)
	}
	if v, ok := x.Metadata["open_to_tenants"].(bool); ok {
		x.OpenToTenants = v
	}
	return &x, nil
}

func (r *AppRepo) Insert(ctx context.Context, a *dom.App) error {
	meta, _ := json.Marshal(emptyJSON(a.Metadata))
	row := r.pool.QueryRow(ctx, `
		INSERT INTO apps (tenant_id, creator_id, code, name, description, icon_url, color,
		                  display_mode, usage_scope, launch_uri, category_id, sort_order, status, is_system, metadata)
		VALUES (NULLIF($1,0)::bigint, NULLIF($2,0)::bigint, $3, $4, NULLIF($5,''), NULLIF($6,''), NULLIF($7,''),
		        $8, COALESCE(NULLIF($9,''),'all'), $10, $11, $12, COALESCE(NULLIF($13,''),'active'), $14, $15::jsonb)
		RETURNING `+appCols,
		a.TenantID, a.CreatorID, a.Code, a.Name, a.Description, a.IconURL, a.Color,
		a.DisplayMode, a.UsageScope, a.LaunchURI, a.CategoryID, a.SortOrder, a.Status, a.IsSystem, string(meta))
	got, err := scanApp(row)
	if err != nil {
		return err
	}
	*a = *got
	return nil
}

func (r *AppRepo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.App, error) {
	where := `uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`
	args := []any{uuid, tenantID}
	if tenantID == 0 {
		where = `uuid=$1 AND tenant_id IS NULL AND deleted_at IS NULL`
		args = []any{uuid}
	} else {
		where = `uuid=$1 AND deleted_at IS NULL AND (
			tenant_id=$2 OR (
				tenant_id IS NULL AND is_system=true
				AND COALESCE((metadata->>'open_to_tenants')::boolean,false)=true
			)
		)`
	}
	row := r.pool.QueryRow(ctx, `SELECT `+appCols+` FROM apps WHERE `+where, args...)
	x, err := scanApp(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *AppRepo) GetByID(ctx context.Context, id int64) (*dom.App, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+appCols+` FROM apps WHERE id=$1 AND deleted_at IS NULL`, id)
	x, err := scanApp(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// ListByIDs 批量取未软删 app（与 GetByID 同口径 deleted_at IS NULL；缺失/软删 id 不返回）。
func (r *AppRepo) ListByIDs(ctx context.Context, ids []int64) ([]dom.App, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+appCols+` FROM apps WHERE id = ANY($1) AND deleted_at IS NULL`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.App
	for rows.Next() {
		x, err := scanApp(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

func (r *AppRepo) ListByTenant(ctx context.Context, tenantID int64, filter dom.AppListFilter) ([]dom.App, int64, error) {
	where := `deleted_at IS NULL`
	args := []any{}
	if tenantID == 0 {
		where += ` AND tenant_id IS NULL`
	} else {
		args = append(args, tenantID)
		where += ` AND (
			tenant_id=$1 OR (
				tenant_id IS NULL AND is_system=true
				AND COALESCE((metadata->>'open_to_tenants')::boolean,false)=true
			)
		)`
	}
	if filter.CategoryID != nil {
		args = append(args, *filter.CategoryID)
		where += " AND category_id = $" + strconv.Itoa(len(args))
	}
	if filter.Status != "" {
		args = append(args, filter.Status)
		where += " AND status = $" + strconv.Itoa(len(args))
	}
	if filter.UsageScope != "" {
		args = append(args, filter.UsageScope)
		where += " AND usage_scope = $" + strconv.Itoa(len(args))
	}
	if filter.Keyword != "" {
		args = append(args, "%"+filter.Keyword+"%")
		where += " AND (name ILIKE $" + strconv.Itoa(len(args)) + " OR code ILIKE $" + strconv.Itoa(len(args)) + ")"
	}
	limit, offset := normalizeListPage(filter.Limit, filter.Offset)
	args = append(args, limit, offset)
	q := `SELECT ` + appCols + `, COUNT(*) OVER() FROM apps WHERE ` + where +
		" ORDER BY sort_order, id DESC LIMIT $" + strconv.Itoa(len(args)-1) + " OFFSET $" + strconv.Itoa(len(args))
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.App
	var total int64
	for rows.Next() {
		var x dom.App
		var meta []byte
		var tenantID *int64
		if err := rows.Scan(&x.ID, &x.UUID, &tenantID, &x.CreatorID, &x.Code, &x.Name,
			&x.Description, &x.IconURL, &x.Color, &x.DisplayMode, &x.UsageScope, &x.LaunchURI,
			&x.OAuthClientID, &x.CategoryID, &x.SortOrder, &x.CategoryUUID, &x.Status, &x.IsSystem, &meta,
			&x.CreatedAt, &x.UpdatedAt, &x.DeletedAt, &total); err != nil {
			return nil, 0, err
		}
		if tenantID != nil {
			x.TenantID = *tenantID
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &x.Metadata)
		}
		if v, ok := x.Metadata["open_to_tenants"].(bool); ok {
			x.OpenToTenants = v
		}
		out = append(out, x)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx, "SELECT count(*) FROM apps WHERE "+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *AppRepo) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.App, error) {
	if len(fields) == 0 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}
	colMap := map[string]string{
		"name":         "name",
		"description":  "description",
		"icon_url":     "icon_url",
		"color":        "color",
		"display_mode": "display_mode",
		"usage_scope":  "usage_scope",
		"launch_uri":   "launch_uri",
		"category_id":  "category_id",
		"sort_order":   "sort_order",
		"status":       "status",
		"metadata":     "metadata",
	}
	jsonbCols := map[string]bool{"metadata": true}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		if jsonbCols[col] {
			b, _ := json.Marshal(v)
			args = append(args, string(b))
			sets = append(sets, col+" = $"+strconv.Itoa(idx)+"::jsonb")
		} else {
			args = append(args, v)
			sets = append(sets, col+" = $"+strconv.Itoa(idx))
		}
		idx++
	}
	if len(sets) == 0 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}
	args = append(args, uuid)
	scopeClause := "tenant_id IS NULL"
	if tenantID != 0 {
		args = append(args, tenantID)
		scopeClause = "tenant_id = $" + strconv.Itoa(idx+1)
	}
	q := "UPDATE apps SET " + strings.Join(sets, ", ") + ", updated_at = now()" +
		" WHERE uuid = $" + strconv.Itoa(idx) +
		" AND " + scopeClause +
		" AND deleted_at IS NULL RETURNING " + appCols
	x, err := scanApp(r.pool.QueryRow(ctx, q, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *AppRepo) SoftDelete(ctx context.Context, tenantID int64, uuid string) error {
	q := `UPDATE apps SET deleted_at = now(), status='revoked', updated_at=now()
		 WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`
	args := []any{uuid, tenantID}
	if tenantID == 0 {
		q = `UPDATE apps SET deleted_at = now(), status='revoked', updated_at=now()
		 WHERE uuid=$1 AND tenant_id IS NULL AND deleted_at IS NULL`
		args = []any{uuid}
	}
	tag, err := r.pool.Exec(ctx, q, args...)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *AppRepo) SetOAuthClientID(ctx context.Context, appID, clientID int64) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE apps SET oauth_client_id=$1, updated_at=now() WHERE id=$2`,
		clientID, appID)
	return err
}

// =====================================================
// CategoryRepo (app_category)
// =====================================================

type CategoryRepo struct{ pool *pgxpool.Pool }

func NewCategoryRepo(pool *pgxpool.Pool) *CategoryRepo { return &CategoryRepo{pool: pool} }

const catCols = `id, uuid::text, tenant_id, code, name, sort_order, is_system, created_at`

func scanCategory(row pgx.Row) (*dom.Category, error) {
	var x dom.Category
	if err := row.Scan(&x.ID, &x.UUID, &x.TenantID, &x.Code, &x.Name, &x.SortOrder, &x.IsSystem, &x.CreatedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *CategoryRepo) List(ctx context.Context, tenantID int64, limit, offset int) ([]dom.Category, int64, error) {
	where := `tenant_id IS NULL OR tenant_id=$1`
	args := []any{tenantID}
	if tenantID == 0 {
		where = `tenant_id IS NULL`
		args = nil
	}
	limit, offset = normalizeListPage(limit, offset)
	args = append(args, limit, offset)
	orderBy := "is_system DESC, sort_order, id"
	if tenantID == 0 {
		orderBy = "sort_order, id"
	}
	q := `SELECT ` + catCols + `, COUNT(*) OVER() FROM app_category WHERE ` + where +
		" ORDER BY " + orderBy + " LIMIT $" + strconv.Itoa(len(args)-1) + " OFFSET $" + strconv.Itoa(len(args))
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.Category
	var total int64
	for rows.Next() {
		var x dom.Category
		if err := rows.Scan(&x.ID, &x.UUID, &x.TenantID, &x.Code, &x.Name, &x.SortOrder, &x.IsSystem, &x.CreatedAt, &total); err != nil {
			return nil, 0, err
		}
		out = append(out, x)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx, "SELECT count(*) FROM app_category WHERE "+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *CategoryRepo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Category, error) {
	q := `SELECT ` + catCols + ` FROM app_category WHERE uuid=$1 AND (tenant_id IS NULL OR tenant_id=$2)`
	args := []any{uuid, tenantID}
	if tenantID == 0 {
		q = `SELECT ` + catCols + ` FROM app_category WHERE uuid=$1 AND tenant_id IS NULL`
		args = []any{uuid}
	}
	x, err := scanCategory(r.pool.QueryRow(ctx, q, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CategoryRepo) Insert(ctx context.Context, tenantID int64, c *dom.Category) error {
	row := r.pool.QueryRow(ctx,
		`INSERT INTO app_category (tenant_id, code, name, sort_order, is_system)
			 VALUES (NULLIF($1,0)::bigint, $2, $3, $4, $1=0)
			 RETURNING `+catCols,
		tenantID, c.Code, c.Name, c.SortOrder)
	got, err := scanCategory(row)
	if err != nil {
		return err
	}
	*c = *got
	return nil
}

func (r *CategoryRepo) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.Category, error) {
	if len(fields) == 0 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}
	colMap := map[string]string{"code": "code", "name": "name", "sort_order": "sort_order"}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, col+" = $"+strconv.Itoa(idx))
		idx++
	}
	if len(sets) == 0 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}
	args = append(args, uuid)
	scopeClause := "tenant_id IS NULL AND is_system = true"
	if tenantID != 0 {
		args = append(args, tenantID)
		scopeClause = "tenant_id = $" + strconv.Itoa(idx+1) + " AND is_system = false"
	}
	q := "UPDATE app_category SET " + strings.Join(sets, ", ") +
		" WHERE uuid = $" + strconv.Itoa(idx) +
		" AND " + scopeClause + " RETURNING " + catCols
	x, err := scanCategory(r.pool.QueryRow(ctx, q, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CategoryRepo) Delete(ctx context.Context, tenantID int64, uuid string) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	q := `SELECT id FROM app_category WHERE uuid=$1 AND tenant_id=$2 AND is_system=false`
	args := []any{uuid, tenantID}
	if tenantID == 0 {
		q = `SELECT id FROM app_category WHERE uuid=$1 AND tenant_id IS NULL AND is_system=true`
		args = []any{uuid}
	}
	var categoryID int64
	if err := tx.QueryRow(ctx, q, args...).Scan(&categoryID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}

	var activeRefs int
	if err := tx.QueryRow(ctx,
		`SELECT count(*) FROM apps WHERE category_id=$1 AND deleted_at IS NULL`,
		categoryID).Scan(&activeRefs); err != nil {
		return err
	}
	if activeRefs > 0 {
		return apperr.ErrConflict.Withf("app_category.has_active_apps: %d", activeRefs)
	}

	if _, err := tx.Exec(ctx,
		`UPDATE apps SET category_id=NULL, updated_at=now() WHERE category_id=$1 AND deleted_at IS NOT NULL`,
		categoryID); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM app_category WHERE id=$1`, categoryID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return tx.Commit(ctx)
}

// emptyJSON 防 nil map 序列化得 "null"。
func emptyJSON(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func normalizeListPage(limit, offset int) (int, int) {
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
