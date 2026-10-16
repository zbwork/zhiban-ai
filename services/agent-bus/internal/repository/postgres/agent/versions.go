package agent

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// publishCopyBindingsSQL PublishVersion step 3: 复制草稿能力绑定为 versioned 固化行。
//
// A2A v1b (boundaries §3.4 / database-design §5.3): capability_kind='a2a_invoke' 是
// **非版本化运行时开关** (哨兵行 agent_version_id IS NULL + capability_uuid=uuid_nil),
// 不进入版本快照 —— 复制时**必须排除**, 否则 versioned 副本会污染开关语义
// (HasA2AInvokeCapability 只认哨兵行, versioned 行不算 enabled, 且历史会越积越多)。
// 提为常量供单测断言谓词 (仓库无 live-DB 测试基建)。
const publishCopyBindingsSQL = `
		INSERT INTO agent_capability_bindings (
			digital_employee_id, agent_version_id, capability_kind, capability_uuid,
			source, granted_tools, granted_scopes, sort_order, pinned, recall_config)
		SELECT digital_employee_id, $1, capability_kind, capability_uuid,
		       source, granted_tools, granted_scopes, sort_order, pinned, recall_config
		  FROM agent_capability_bindings
		 WHERE digital_employee_id = $2 AND agent_version_id IS NULL
		   AND capability_kind != 'a2a_invoke'`

// PublishVersion 在单事务里:
//  1. 计算下一个 version 号 = current_version + 1
//  2. 插入 agent_versions(snapshot, status='published')
//  3. 复制草稿能力绑定 (agent_version_id IS NULL) 为 v 固化行 (排除 a2a_invoke, 见 publishCopyBindingsSQL)
//  4. 更新 digital_employees.current_version + status='published'
//  5. 平台模板发布后由各租户实时只读引用，不创建或更新租户副本
func (r *Repo) PublishVersion(ctx context.Context, deID int64, snapshot map[string]any, publishedBy int64, notes string) (*dom.Version, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var current int
	if err := tx.QueryRow(ctx, `
		SELECT current_version
		  FROM digital_employees
		 WHERE id=$1 AND deleted_at IS NULL
		 FOR UPDATE`, deID).Scan(&current); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	next := current + 1
	snap, _ := json.Marshal(snapshot)
	var pubBy any
	if publishedBy > 0 {
		pubBy = publishedBy
	}
	v := &dom.Version{}
	if err := tx.QueryRow(ctx, `
		INSERT INTO agent_versions (digital_employee_id, version, snapshot, status, notes, published_by, published_at)
		VALUES ($1, $2, $3::jsonb, 'published', NULLIF($4,''), $5, now())
		RETURNING id, digital_employee_id, version, status, grayscale_pct, grayscale_groups, COALESCE(notes,''), published_by, published_at, created_at, updated_at`,
		deID, next, string(snap), notes, pubBy).Scan(
		&v.ID, &v.DigitalEmpID, &v.Version, &v.Status, &v.GrayscalePct, &v.GrayscaleGroups, &v.Notes,
		&v.PublishedBy, &v.PublishedAt, &v.CreatedAt, &v.UpdatedAt); err != nil {
		return nil, err
	}
	v.Snapshot = snapshot

	if _, err := tx.Exec(ctx, publishCopyBindingsSQL, v.ID, deID); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(ctx, `UPDATE digital_employees SET current_version=$1, status='published', updated_at=now() WHERE id=$2`, next, deID); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return v, nil
}

func (r *Repo) ListVersions(ctx context.Context, deID int64) ([]dom.Version, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, digital_employee_id, version, snapshot, status, grayscale_pct, grayscale_groups, COALESCE(notes,''),
		       published_by, published_at, created_at, updated_at
		  FROM agent_versions WHERE digital_employee_id=$1 ORDER BY version DESC`, deID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Version
	for rows.Next() {
		var v dom.Version
		var snap []byte
		if err := rows.Scan(&v.ID, &v.DigitalEmpID, &v.Version, &snap, &v.Status, &v.GrayscalePct, &v.GrayscaleGroups, &v.Notes,
			&v.PublishedBy, &v.PublishedAt, &v.CreatedAt, &v.UpdatedAt); err != nil {
			return nil, err
		}
		if len(snap) > 0 {
			_ = json.Unmarshal(snap, &v.Snapshot)
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (r *Repo) GetVersion(ctx context.Context, deID int64, version int) (*dom.Version, error) {
	var v dom.Version
	var snap []byte
	if err := r.pool.QueryRow(ctx, `
		SELECT id, digital_employee_id, version, snapshot, status, grayscale_pct, grayscale_groups, COALESCE(notes,''),
		       published_by, published_at, created_at, updated_at
		  FROM agent_versions WHERE digital_employee_id=$1 AND version=$2`, deID, version).Scan(
		&v.ID, &v.DigitalEmpID, &v.Version, &snap, &v.Status, &v.GrayscalePct, &v.GrayscaleGroups, &v.Notes,
		&v.PublishedBy, &v.PublishedAt, &v.CreatedAt, &v.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if len(snap) > 0 {
		_ = json.Unmarshal(snap, &v.Snapshot)
	}
	return &v, nil
}

// SetGrayscale 把目标版本切到 grayed; 同 Agent 已有 grayed 时由 partial unique 拒绝。
// 调用方负责保证目标版本之前是 published。
func (r *Repo) SetGrayscale(ctx context.Context, deID int64, version int, pct int, groups []string) (*dom.Version, error) {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	if groups == nil {
		groups = []string{}
	}
	v := &dom.Version{}
	if err := r.pool.QueryRow(ctx, `
		UPDATE agent_versions
		   SET status='grayed', grayscale_pct=$3, grayscale_groups=$4, updated_at=now()
		 WHERE digital_employee_id=$1 AND version=$2
		RETURNING id, digital_employee_id, version, status, grayscale_pct, grayscale_groups, COALESCE(notes,''),
		          published_by, published_at, created_at, updated_at`,
		deID, version, pct, groups).Scan(
		&v.ID, &v.DigitalEmpID, &v.Version, &v.Status, &v.GrayscalePct, &v.GrayscaleGroups, &v.Notes,
		&v.PublishedBy, &v.PublishedAt, &v.CreatedAt, &v.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, translatePgErr(err)
	}
	return v, nil
}

// Rollback: current_version=version, 任何 grayed 版本 → rolled_back。
func (r *Repo) Rollback(ctx context.Context, deID int64, version int) (*dom.DigitalEmployee, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var exists int
	if err := tx.QueryRow(ctx, `SELECT 1 FROM agent_versions WHERE digital_employee_id=$1 AND version=$2`, deID, version).Scan(&exists); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("目标版本不存在")
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE agent_versions SET status='rolled_back', updated_at=now() WHERE digital_employee_id=$1 AND status='grayed'`, deID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE digital_employees SET current_version=$1, status='published', updated_at=now() WHERE id=$2`, version, deID); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM digital_employees WHERE id=$1`, deID)
	return scan(row)
}

// --- A2A whitelist ---

func (r *Repo) ListCallableWhitelist(ctx context.Context, calleeID int64) ([]dom.CalleeWhitelistEntry, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT w.id, w.callee_id, w.caller_id, w.granted_by, COALESCE(w.note,''), w.created_at,
		       de.uuid::text, de.name
		  FROM agent_callable_whitelist w
		  JOIN digital_employees de ON de.id = w.caller_id
		 WHERE w.callee_id = $1
		 ORDER BY w.id DESC`, calleeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.CalleeWhitelistEntry
	for rows.Next() {
		var e dom.CalleeWhitelistEntry
		if err := rows.Scan(&e.ID, &e.CalleeID, &e.CallerID, &e.GrantedBy, &e.Note, &e.CreatedAt, &e.CallerUUID, &e.CallerName); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (r *Repo) AddCallableWhitelist(ctx context.Context, calleeID, callerID int64, grantedBy *int64, note string) (*dom.CalleeWhitelistEntry, error) {
	var grantedByArg any
	if grantedBy != nil && *grantedBy > 0 {
		grantedByArg = *grantedBy
	}
	e := &dom.CalleeWhitelistEntry{}
	if err := r.pool.QueryRow(ctx, `
		INSERT INTO agent_callable_whitelist (callee_id, caller_id, granted_by, note)
		VALUES ($1,$2,$3,NULLIF($4,''))
		ON CONFLICT (callee_id, caller_id) DO UPDATE SET note = EXCLUDED.note
		RETURNING id, callee_id, caller_id, granted_by, COALESCE(note,''), created_at`,
		calleeID, callerID, grantedByArg, note).Scan(&e.ID, &e.CalleeID, &e.CallerID, &e.GrantedBy, &e.Note, &e.CreatedAt); err != nil {
		return nil, err
	}
	return e, nil
}

func (r *Repo) DeleteCallableWhitelist(ctx context.Context, entryID int64) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM agent_callable_whitelist WHERE id=$1`, entryID)
	return err
}
