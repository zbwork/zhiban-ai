// Package empblock 是 internal/domain/empblock 的 PG 实现 (Batch 3D T3.10).
package empblock

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// notifyChannel 3D Codex review 返修 #1: NOTIFY 必须与 INSERT/UPDATE 同 tx, 让
// PG 提供原子性 — `pg_notify` 是 transactional, 只在 COMMIT 时才广播; tx 内 ROLLBACK
// 时 NOTIFY 不发. 这样消除了 "row 已落库但 cache 没刷新" 的 stale 窗口.
//
// channel 名复用 `config_change` (与 contacts.PolicyListener 共存), payload 形如
// "emp_block_registry:<id>"; bus 端 emp listener 按前缀过滤.
const notifyChannel = "config_change"

func notifyPayload(id int64) string {
	return "emp_block_registry:" + strconv.FormatInt(id, 10)
}

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const baseCols = `id, code, version, name, category, json_schema,
    status, COALESCE(min_client_version,''), fallback_block_type,
    COALESCE(breaking_changes,''), deprecated_at, eol_date,
    COALESCE(description,''), is_system, created_at, updated_at`

func scan(row pgx.Row) (*dom.Block, error) {
	var (
		b      dom.Block
		schema []byte
	)
	if err := row.Scan(
		&b.ID, &b.Code, &b.Version, &b.Name, &b.Category, &schema,
		&b.Status, &b.MinClientVersion, &b.FallbackBlockType,
		&b.BreakingChanges, &b.DeprecatedAt, &b.EOLDate,
		&b.Description, &b.IsSystem, &b.CreatedAt, &b.UpdatedAt,
	); err != nil {
		return nil, err
	}
	if len(schema) > 0 {
		_ = json.Unmarshal(schema, &b.JSONSchema)
	}
	if b.JSONSchema == nil {
		b.JSONSchema = map[string]any{}
	}
	return &b, nil
}

func (r *Repo) List(ctx context.Context) ([]dom.Block, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+baseCols+` FROM emp_block_registry ORDER BY category, code, version`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Block
	for rows.Next() {
		b, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
	}
	return out, rows.Err()
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Block, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM emp_block_registry WHERE id=$1`, id)
	b, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return b, nil
}

func (r *Repo) GetByCode(ctx context.Context, code string, version int) (*dom.Block, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+baseCols+` FROM emp_block_registry WHERE code=$1 AND version=$2`, code, version)
	b, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return b, nil
}

// Create 3D Codex review 返修 #1: INSERT + pg_notify 同 tx; ROLLBACK 时两者都不生效.
//
// 失败矩阵:
//
//	INSERT 失败 → 直接返错; pg_notify 不执行
//	pg_notify 失败 → tx ROLLBACK, INSERT 不保留
//	Commit 失败 → tx 已自动 ROLLBACK, NOTIFY 也未广播 (PG transactional NOTIFY 保证)
func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.Block, error) {
	if in.JSONSchema == nil {
		in.JSONSchema = map[string]any{}
	}
	schemaBytes, err := json.Marshal(in.JSONSchema)
	if err != nil {
		return nil, err
	}
	status := in.Status
	if status == "" {
		status = dom.StatusDraft
	}
	fb := in.FallbackBlockType
	if fb == "" {
		fb = "markdown"
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	row := tx.QueryRow(ctx, `
INSERT INTO emp_block_registry (
    code, version, name, category, json_schema,
    status, min_client_version, fallback_block_type,
    description, is_system
) VALUES ($1, $2, $3, $4, $5::jsonb,
          $6, NULLIF($7,''), $8,
          NULLIF($9,''), false)
RETURNING `+baseCols,
		in.Code, in.Version, in.Name, in.Category, schemaBytes,
		status, in.MinClientVersion, fb,
		in.Description)
	b, err := scan(row)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, notifyChannel, notifyPayload(b.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return b, nil
}

// Update 3D Codex review 返修 #1: 同 Create, UPDATE + pg_notify 一个 tx, 原子.
func (r *Repo) Update(ctx context.Context, id int64, in dom.UpdateInput) (*dom.Block, error) {
	// 用 COALESCE 模式动态忽略 nil 字段; JSONSchema 单独处理.
	var schemaBytes []byte
	if in.JSONSchema != nil {
		bb, err := json.Marshal(*in.JSONSchema)
		if err != nil {
			return nil, err
		}
		schemaBytes = bb
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	row := tx.QueryRow(ctx, `
UPDATE emp_block_registry
   SET name                = COALESCE($2, name),
       category            = COALESCE($3, category),
       json_schema         = COALESCE($4::jsonb, json_schema),
       status              = COALESCE($5, status),
       min_client_version  = COALESCE($6, min_client_version),
       fallback_block_type = COALESCE($7, fallback_block_type),
       breaking_changes    = COALESCE($8, breaking_changes),
       description         = COALESCE($9, description),
       updated_at          = now()
 WHERE id = $1
RETURNING `+baseCols,
		id, optStr(in.Name), optStr(in.Category), schemaBytes,
		optStr(in.Status), optStr(in.MinClientVersion), optStr(in.FallbackBlockType),
		optStr(in.BreakingChanges), optStr(in.Description))
	b, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, notifyChannel, notifyPayload(b.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return b, nil
}

func optStr(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}
