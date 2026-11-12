// Package apikey 是 domain/apikey 的 pgx 仓储实现。
package apikey

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Repo 是 dom.Repository 的 pgxpool 实现。
type Repo struct{ pool *pgxpool.Pool }

// New 构造 Repo。
func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const cols = `id, uuid, tenant_id, creator_id, name, key_prefix, key_hash,
    COALESCE(scopes, '{}'::varchar[]), last_used_at, expires_at, status,
    created_at, updated_at, revoked_at`

func scanKey(row pgx.Row) (*dom.ApiKey, error) {
	var x dom.ApiKey
	if err := row.Scan(&x.ID, &x.UUID, &x.TenantID, &x.CreatorID, &x.Name,
		&x.KeyPrefix, &x.KeyHash, &x.Scopes, &x.LastUsedAt, &x.ExpiresAt,
		&x.Status, &x.CreatedAt, &x.UpdatedAt, &x.RevokedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

// Insert 写入新 key。
func (r *Repo) Insert(ctx context.Context, k *dom.ApiKey) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO api_keys (tenant_id, creator_id, name, key_prefix, key_hash, scopes, expires_at, status)
		VALUES ($1, $2, $3, $4, $5, $6, $7, COALESCE(NULLIF($8,''),'active'))
		RETURNING `+cols,
		k.TenantID, k.CreatorID, k.Name, k.KeyPrefix, k.KeyHash, k.Scopes, k.ExpiresAt, k.Status)
	got, err := scanKey(row)
	if err != nil {
		return err
	}
	*k = *got
	return nil
}

// FindByPrefix 中间件热路径; 不限制 status, 由 Service 层校验 active + expires。
func (r *Repo) FindByPrefix(ctx context.Context, prefix string) (*dom.ApiKey, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+cols+` FROM api_keys WHERE key_prefix=$1`, prefix)
	x, err := scanKey(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// GetByUUID 单条; 限定 tenantID 防跨租户访问。
func (r *Repo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.ApiKey, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+cols+` FROM api_keys WHERE uuid=$1 AND tenant_id=$2`, uuid, tenantID)
	x, err := scanKey(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// ListByTenant 按 created_at desc 列出。
func (r *Repo) ListByTenant(ctx context.Context, tenantID int64, filter dom.ListFilter) ([]dom.ApiKey, int64, error) {
	where := []string{"tenant_id=$1"}
	args := []any{tenantID}
	next := 2
	switch filter.Status {
	case "active":
		where = append(where, "status='active' AND (expires_at IS NULL OR expires_at > now())")
	case "revoked":
		where = append(where, "status='revoked'")
	case "expired":
		where = append(where, "status='active' AND expires_at IS NOT NULL AND expires_at <= now()")
	}
	if filter.Keyword != "" {
		where = append(where, "(name ILIKE $"+strconv.Itoa(next)+" OR key_prefix ILIKE $"+strconv.Itoa(next)+")")
		args = append(args, "%"+filter.Keyword+"%")
		next++
	}
	whereSQL := strings.Join(where, " AND ")
	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM api_keys WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	listArgs := append(append([]any{}, args...), filter.Limit, filter.Offset)
	rows, err := r.pool.Query(ctx, `SELECT `+cols+` FROM api_keys WHERE `+whereSQL+` ORDER BY id DESC LIMIT $`+strconv.Itoa(next)+` OFFSET $`+strconv.Itoa(next+1), listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.ApiKey
	for rows.Next() {
		x, err := scanKey(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *x)
	}
	return out, total, rows.Err()
}

// Patch 增量更新; 支持 name / scopes / expires_at。
func (r *Repo) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.ApiKey, error) {
	if len(fields) == 0 {
		return r.GetByUUID(ctx, tenantID, uuid)
	}
	colMap := map[string]string{
		"name":       "name",
		"scopes":     "scopes",
		"expires_at": "expires_at",
	}
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
	args = append(args, uuid, tenantID)
	q := "UPDATE api_keys SET " + strings.Join(sets, ", ") +
		", updated_at = now() WHERE uuid = $" + strconv.Itoa(idx) +
		" AND tenant_id = $" + strconv.Itoa(idx+1) + " RETURNING " + cols
	row := r.pool.QueryRow(ctx, q, args...)
	x, err := scanKey(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// Revoke 软撤销; 若行已是 revoked 则幂等返回 nil。
func (r *Repo) Revoke(ctx context.Context, tenantID int64, uuid string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE api_keys SET status='revoked', revoked_at=now(), updated_at=now()
		WHERE uuid=$1 AND tenant_id=$2 AND status<>'revoked'`, uuid, tenantID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		// 区分 "不存在" 和 "已撤销": 再查一次。
		if _, gerr := r.GetByUUID(ctx, tenantID, uuid); gerr != nil {
			return gerr
		}
		// 已 revoked, 幂等成功。
	}
	return nil
}

// TouchLastUsed 中间件命中后异步调; 失败不影响主链路。
func (r *Repo) TouchLastUsed(ctx context.Context, id int64, ts time.Time) error {
	_, err := r.pool.Exec(ctx, `UPDATE api_keys SET last_used_at=$2 WHERE id=$1`, id, ts)
	return err
}
