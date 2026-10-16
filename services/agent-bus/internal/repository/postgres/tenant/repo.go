package tenant

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type PlanProjection struct{ Columns, Join string }
type Repo struct {
	pool *pgxpool.Pool
	plan PlanProjection
}

// PlanProjection must come from trusted compiled wiring, never user input.
func New(pool *pgxpool.Pool, plan ...PlanProjection) *Repo {
	projection := PlanProjection{Columns: "NULL::bigint, ''::text, ''::text"}
	if len(plan) == 1 {
		projection = plan[0]
	}
	return &Repo{pool: pool, plan: projection}
}

func itoa(i int) string { return strconv.Itoa(i) }

const baseCols = `id, uuid, name, slug, COALESCE(display_name,''), COALESCE(description,''), COALESCE(icon_url,''),
    COALESCE(industry,''), owner_id, status, COALESCE(timezone,''), plan_id, brand, metadata, created_at, updated_at`

// listCols 与 baseCols 列序完全一致, 仅带 t. 前缀 (List 查询 JOIN 订阅后列名会歧义); 两处必须同步改。
const listCols = `t.id, t.uuid, t.name, t.slug, COALESCE(t.display_name,''), COALESCE(t.description,''), COALESCE(t.icon_url,''),
    COALESCE(t.industry,''), t.owner_id, t.status, COALESCE(t.timezone,''), t.plan_id, t.brand, t.metadata, t.created_at, t.updated_at`

func scan(row pgx.Row) (*dom.Tenant, error) {
	var t dom.Tenant
	var brand, meta []byte
	if err := row.Scan(&t.ID, &t.UUID, &t.Name, &t.Slug, &t.DisplayName, &t.Description, &t.IconURL,
		&t.Industry, &t.OwnerID, &t.Status, &t.Timezone, &t.PlanID, &brand, &meta, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return nil, err
	}
	if len(brand) > 0 {
		_ = json.Unmarshal(brand, &t.Brand)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &t.Metadata)
	}
	return &t, nil
}

func scanWithEffectivePlan(row pgx.Row) (*dom.Tenant, error) {
	var t dom.Tenant
	var brand, meta []byte
	if err := row.Scan(&t.ID, &t.UUID, &t.Name, &t.Slug, &t.DisplayName, &t.Description, &t.IconURL,
		&t.Industry, &t.OwnerID, &t.Status, &t.Timezone, &t.PlanID, &brand, &meta, &t.CreatedAt, &t.UpdatedAt,
		&t.EffectivePlanID, &t.EffectivePlanCode, &t.EffectivePlanName); err != nil {
		return nil, err
	}
	if len(brand) > 0 {
		_ = json.Unmarshal(brand, &t.Brand)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &t.Metadata)
	}
	return &t, nil
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Tenant, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+listCols+`, `+r.plan.Columns+` FROM tenants t `+r.plan.Join+` WHERE t.id=$1 AND t.deleted_at IS NULL`, id)
	t, err := scanWithEffectivePlan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return t, nil
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Tenant, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM tenants WHERE uuid=$1 AND deleted_at IS NULL`, uuid)
	t, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return t, nil
}

func (r *Repo) GetBySlug(ctx context.Context, slug string) (*dom.Tenant, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM tenants WHERE slug=$1 AND deleted_at IS NULL`, slug)
	t, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return t, nil
}

func (r *Repo) Create(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error) {
	brand, _ := json.Marshal(t.Brand)
	meta, _ := json.Marshal(t.Metadata)
	if len(brand) == 0 {
		brand = []byte("{}")
	}
	if len(meta) == 0 {
		meta = []byte("{}")
	}
	row := r.pool.QueryRow(ctx, `
		INSERT INTO tenants (name, slug, display_name, description, icon_url, industry, owner_id, status, plan_id, brand, metadata)
		VALUES ($1,$2,NULLIF($3,''),NULLIF($4,''),NULLIF($5,''),NULLIF($6,''),$7, COALESCE(NULLIF($8,''),'active'), NULL, $9::jsonb, $10::jsonb)
		RETURNING `+baseCols,
		t.Name, t.Slug, t.DisplayName, t.Description, t.IconURL, t.Industry, t.OwnerID, t.Status, string(brand), string(meta))
	return scan(row)
}

func (r *Repo) Update(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error) {
	brand, _ := json.Marshal(t.Brand)
	meta, _ := json.Marshal(t.Metadata)
	row := r.pool.QueryRow(ctx, `
		UPDATE tenants SET
			name = COALESCE(NULLIF($1,''), name),
			display_name = NULLIF($2,''),
			description = NULLIF($3,''),
			icon_url = NULLIF($4,''),
			industry = NULLIF($5,''),
			status = COALESCE(NULLIF($6,''), status),
			brand = $7::jsonb,
			metadata = $8::jsonb,
			updated_at = now()
		WHERE id = $9 AND deleted_at IS NULL
		RETURNING `+baseCols,
		t.Name, t.DisplayName, t.Description, t.IconURL, t.Industry, t.Status,
		string(brand), string(meta), t.ID)
	return scan(row)
}

func (r *Repo) Delete(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx, `UPDATE tenants SET deleted_at=now(), status='deactivated', updated_at=now() WHERE id=$1 AND deleted_at IS NULL`, id)
	return err
}

func (r *Repo) List(ctx context.Context, status, keyword string, limit, offset int) ([]dom.Tenant, int64, error) {
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	where := `WHERE t.deleted_at IS NULL`
	args := []any{}
	if status != "" {
		args = append(args, status)
		where += ` AND t.status=$` + itoa(len(args))
	}
	if keyword != "" {
		args = append(args, "%"+keyword+"%", keyword)
		where += ` AND (t.name ILIKE $` + itoa(len(args)-1) +
			` OR t.slug ILIKE $` + itoa(len(args)-1) +
			` OR t.uuid::text ILIKE $` + itoa(len(args)-1) +
			` OR t.id::text = $` + itoa(len(args)) + `)`
	}
	args = append(args, limit, offset)
	// es: 当前生效订阅对应的套餐 (计费口径)。tenants.plan_id 只有平台表单显式写入, 大多数租户为 NULL,
	// 列表「套餐」列必须以订阅为准; LATERAL 保持单条 SQL, 避免 N+1。
	rows, err := r.pool.Query(ctx,
		`SELECT `+listCols+`, COUNT(*) OVER(), `+r.plan.Columns+` FROM tenants t `+r.plan.Join+where+
			` ORDER BY t.id DESC LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.Tenant
	var total int64
	for rows.Next() {
		var t dom.Tenant
		var brand, meta []byte
		if err := rows.Scan(&t.ID, &t.UUID, &t.Name, &t.Slug, &t.DisplayName, &t.Description, &t.IconURL,
			&t.Industry, &t.OwnerID, &t.Status, &t.Timezone, &t.PlanID, &brand, &meta, &t.CreatedAt, &t.UpdatedAt,
			&total, &t.EffectivePlanID, &t.EffectivePlanCode, &t.EffectivePlanName); err != nil {
			return nil, 0, err
		}
		if len(brand) > 0 {
			_ = json.Unmarshal(brand, &t.Brand)
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &t.Metadata)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM tenants t `+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}
