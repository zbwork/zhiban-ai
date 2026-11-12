// Package a2acalledge postgres 实现 (F09 Phase B §2.3.9).
//
// 月分区表; PK=(id, created_at).
//
// 关键查询路径:
//   - Insert: status='pending', returning created_at 让 service 缓存以便后续 UpdateStatus 精确分区裁剪
//   - FindByIdemKey: idem_key 含 tenant_id, 索引 uq_a2a_idem 命中
//   - UpdateStatus: 用 (uuid, created_at) 双键定位; 必须传 createdAt 才能裁剪分区
//   - ListAncestors: 沿 parent_edge_id 链回溯; 防环 / depth 校验在 service 层做
//
// PR4 不实现真实的 ancestor walker (PR5 service/a2a 用); 这里给出接口实现签名 + 简化的
// LIMIT N 回溯查询. 跨分区查询会比较贵, 但 ancestor 链路最多 4 跳 (depth ≤ 3), 不构成问题.
package a2acalledge

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const cols = `id, uuid, tenant_id, room_id, from_agent_id, to_agent_id,
    orchestration_id, parent_edge_id, origin_conversation_id, depth, idem_key,
    invoke_kind, request_payload, response_payload,
    status, started_at, completed_at, COALESCE(error_message,''),
    tokens_in, tokens_out, latency_ms,
    created_at, created_by, updated_at, updated_by, is_deleted, deleted_at,
    root_edge_id, root_edge_created_at, COALESCE(request_fingerprint,'')`

func scan(row pgx.Row) (*dom.Edge, error) {
	var e dom.Edge
	var invokeKind, status string
	if err := row.Scan(
		&e.ID, &e.UUID, &e.TenantID, &e.RoomID, &e.FromAgentID, &e.ToAgentID,
		&e.OrchestrationID, &e.ParentEdgeID, &e.OriginConversationID, &e.Depth, &e.IdemKey,
		&invokeKind, &e.RequestPayload, &e.ResponsePayload,
		&status, &e.StartedAt, &e.CompletedAt, &e.ErrorMessage,
		&e.TokensIn, &e.TokensOut, &e.LatencyMs,
		&e.CreatedAt, &e.CreatedBy, &e.UpdatedAt, &e.UpdatedBy, &e.IsDeleted, &e.DeletedAt,
		&e.RootEdgeID, &e.RootEdgeCreatedAt, &e.RequestFingerprint,
	); err != nil {
		return nil, err
	}
	e.InvokeKind = dom.InvokeKind(invokeKind)
	e.Status = dom.Status(status)
	return &e, nil
}

func (r *Repo) Insert(ctx context.Context, in dom.InsertInput) (*dom.Edge, error) {
	if in.TenantID == 0 || in.FromAgentID == 0 || in.ToAgentID == 0 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.Insert: tenant_id/from/to required")
	}
	if in.FromAgentID == in.ToAgentID {
		return nil, apperr.ErrInvalidParams.Withf("a2a.Insert: from_agent_id != to_agent_id (DB CHECK chk_a2a_no_self)")
	}
	if in.IdemKey == "" {
		return nil, apperr.ErrInvalidParams.Withf("a2a.Insert: idem_key required")
	}
	if in.Depth < 0 || in.Depth > 5 {
		return nil, apperr.ErrInvalidParams.Withf("a2a.Insert: depth must be 0..5 (DB CHECK chk_a2a_depth_max)")
	}
	if in.InvokeKind == "" {
		in.InvokeKind = dom.InvokeSync
	}
	payload := in.RequestPayload
	if len(payload) == 0 {
		payload = []byte("{}")
	}
	row := r.pool.QueryRow(ctx, `
		INSERT INTO a2a_call_edges (
			tenant_id, room_id, from_agent_id, to_agent_id,
			orchestration_id, parent_edge_id, origin_conversation_id, depth, idem_key,
			invoke_kind, request_payload,
			root_edge_id, root_edge_created_at, request_fingerprint,
			created_by, updated_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, NULLIF($14, ''), $15, $15)
		RETURNING `+cols,
		in.TenantID, in.RoomID, in.FromAgentID, in.ToAgentID,
		in.OrchestrationID, in.ParentEdgeID, in.OriginConversationID, in.Depth, in.IdemKey,
		string(in.InvokeKind), string(payload),
		in.RootEdgeID, in.RootEdgeCreatedAt, in.RequestFingerprint,
		in.CreatedBy,
	)
	return scan(row)
}

func (r *Repo) FindByIdemKey(ctx context.Context, tenantID int64, idemKey string) (*dom.Edge, error) {
	// uq_a2a_idem(tenant_id, idem_key, created_at) WHERE is_deleted=false 命中
	row := r.pool.QueryRow(ctx, `
		SELECT `+cols+` FROM a2a_call_edges
		WHERE tenant_id=$1 AND idem_key=$2 AND is_deleted=false
		ORDER BY created_at DESC
		LIMIT 1`,
		tenantID, idemKey,
	)
	e, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return e, err
}

func (r *Repo) GetByUUID(ctx context.Context, tenantID int64, uuid string, createdAt time.Time) (*dom.Edge, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+cols+` FROM a2a_call_edges
		WHERE tenant_id=$1 AND uuid=$2 AND created_at=$3 AND is_deleted=false`,
		tenantID, uuid, createdAt,
	)
	e, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return e, err
}

func (r *Repo) FindLatestByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Edge, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+cols+` FROM a2a_call_edges
		WHERE tenant_id=$1 AND uuid=$2 AND is_deleted=false
		ORDER BY created_at DESC
		LIMIT 1`,
		tenantID, uuid,
	)
	e, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return e, err
}

func (r *Repo) GetByID(ctx context.Context, id int64, createdAt time.Time) (*dom.Edge, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+cols+` FROM a2a_call_edges
		WHERE id=$1 AND created_at=$2 AND is_deleted=false`,
		id, createdAt,
	)
	e, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return e, err
}

func (r *Repo) UpdateStatus(ctx context.Context, tenantID int64, uuid string, createdAt time.Time, in dom.UpdateStatusInput) (*dom.Edge, error) {
	setClauses := []string{}
	args := []any{tenantID, uuid, createdAt}
	idx := 3
	add := func(clause string, val any) {
		idx++
		setClauses = append(setClauses, fmt.Sprintf(clause, idx))
		args = append(args, val)
	}
	if in.Status != nil {
		add("status=$%d", string(*in.Status))
	}
	if in.ResponsePayload != nil {
		add("response_payload=$%d::jsonb", string(in.ResponsePayload))
	}
	if in.ErrorMessage != nil {
		add("error_message=NULLIF($%d,'')", *in.ErrorMessage)
	}
	if in.StartedAt != nil {
		add("started_at=$%d", *in.StartedAt)
	}
	if in.CompletedAt != nil {
		add("completed_at=$%d", *in.CompletedAt)
	}
	if in.TokensIn != nil {
		add("tokens_in=$%d", *in.TokensIn)
	}
	if in.TokensOut != nil {
		add("tokens_out=$%d", *in.TokensOut)
	}
	if in.LatencyMs != nil {
		add("latency_ms=$%d", *in.LatencyMs)
	}
	if in.UpdatedBy != nil {
		add("updated_by=$%d", *in.UpdatedBy)
	}
	if len(in.ExpectStatuses) > 0 {
		statuses := make([]string, 0, len(in.ExpectStatuses))
		for _, st := range in.ExpectStatuses {
			statuses = append(statuses, string(st))
		}
		args = append(args, statuses)
	}
	setClauses = append(setClauses, "updated_at=now()")
	if len(setClauses) == 1 {
		return r.GetByUUID(ctx, tenantID, uuid, createdAt)
	}

	set := setClauses[0]
	for i := 1; i < len(setClauses); i++ {
		set += ", " + setClauses[i]
	}

	where := "tenant_id=$1 AND uuid=$2 AND created_at=$3 AND is_deleted=false"
	if len(in.ExpectStatuses) > 0 {
		where += fmt.Sprintf(" AND status = ANY($%d)", len(args))
	}

	row := r.pool.QueryRow(ctx, `
		UPDATE a2a_call_edges
		SET `+set+`
		WHERE `+where+`
		RETURNING `+cols,
		args...,
	)
	e, err := scan(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return e, err
}

// FailStale (A2A v1a) 批量把悬挂 pending/running edge 标 failed。
//
//   - 扫描窗口下界固定 now()-7d: created_at 是分区键, 双边界让 PG 只命中近期分区;
//     7 天前仍悬挂的行留给 F14 归档策略, 不在热路径反复扫。
//   - 幂等: 条件 UPDATE, 多实例并发时后到者影响 0 行, 无需 advisory lock。
func (r *Repo) FailStale(ctx context.Context, cutoff time.Time, pendingReason, runningReason string) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		UPDATE a2a_call_edges
		   SET status='failed',
		       error_message = CASE status WHEN 'pending' THEN $2 ELSE $3 END,
		       completed_at = now(),
		       updated_at = now()
		 WHERE status IN ('pending','running')
		   AND created_at >= now() - INTERVAL '7 days'
		   AND created_at < $1
		   AND is_deleted = false`,
		cutoff, pendingReason, runningReason)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

func (r *Repo) ListAncestors(ctx context.Context, tenantID int64, startEdgeID int64, startCreatedAt time.Time, max int) ([]*dom.Edge, error) {
	if max <= 0 || max > 64 {
		max = 8 // Phase5: depth ≤ 5 → 至多 6 跳; 上限给 safe margin (旧值 4 会截断 max_depth=5 的链)
	}
	// 迭代回溯; PR5 可改为单 SQL recursive CTE, PR4 留简单版.
	cur, err := r.GetByID(ctx, startEdgeID, startCreatedAt)
	if err != nil {
		return nil, err
	}
	if cur.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("cross-tenant ancestor walk")
	}
	out := []*dom.Edge{cur}
	for i := 0; i < max-1; i++ {
		if cur.ParentEdgeID == nil {
			break
		}
		// 不知道 parent 的 created_at, 走宽松查询 (id 唯一 → 跨分区 SELECT, depth 链最多 3 跳所以 OK)
		row := r.pool.QueryRow(ctx, `
			SELECT `+cols+` FROM a2a_call_edges
			WHERE id=$1 AND tenant_id=$2 AND is_deleted=false`,
			*cur.ParentEdgeID, tenantID,
		)
		parent, err := scan(row)
		if errors.Is(err, pgx.ErrNoRows) {
			break
		}
		if err != nil {
			return nil, err
		}
		out = append(out, parent)
		cur = parent
	}
	return out, nil
}

// ChainStats (Phase5) 聚合同一 root chain 的调用总数与同指纹计数。单条 SQL:
// 统计范围 = 根自身 (id=rootID) + 其所有子孙 (root_edge_id=rootID)，走 idx_a2a_edges_root_chain。
// fingerprint 为空时 SameFingerprint=0 (FILTER 里显式短路)。
func (r *Repo) ChainStats(ctx context.Context, tenantID int64, rootID int64, rootCreatedAt time.Time, fingerprint string) (dom.ChainStats, error) {
	if tenantID == 0 || rootID == 0 {
		return dom.ChainStats{}, apperr.ErrInvalidParams.Withf("a2a.ChainStats: tenant_id/root_id required")
	}
	var total, sameFp int
	err := r.pool.QueryRow(ctx, `
		SELECT
			count(*) AS total,
			count(*) FILTER (WHERE $4 <> '' AND request_fingerprint = $4) AS same_fp
		FROM a2a_call_edges
		WHERE tenant_id = $1
		  AND is_deleted = false
		  AND (
		    (id = $2 AND created_at = $3)
		    OR (root_edge_id = $2 AND root_edge_created_at = $3)
		  )`,
		tenantID, rootID, rootCreatedAt, fingerprint,
	).Scan(&total, &sameFp)
	if err != nil {
		return dom.ChainStats{}, err
	}
	return dom.ChainStats{TotalCalls: total, SameFingerprint: sameFp}, nil
}

func (r *Repo) List(ctx context.Context, f dom.ListFilter) ([]*dom.Edge, int, error) {
	if f.TenantID == 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("a2a.List: tenant_id required")
	}
	if f.OrchestrationID == nil && f.RoomID == nil && f.FromAgentID == nil && f.ToAgentID == nil && f.CreatedAfter == nil && f.CreatedBefore == nil {
		return nil, 0, apperr.ErrInvalidParams.Withf("a2a.List: 至少给一个过滤维度 (orchestration_id / room_id / from_agent_id / to_agent_id / created_after / created_before)")
	}
	limit, offset := f.Limit, f.Offset
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	args := []any{f.TenantID}
	where := "tenant_id=$1 AND is_deleted=false"

	if f.OrchestrationID != nil {
		args = append(args, *f.OrchestrationID)
		where += fmt.Sprintf(" AND orchestration_id=$%d", len(args))
	}
	if f.RoomID != nil {
		args = append(args, *f.RoomID)
		where += fmt.Sprintf(" AND room_id=$%d", len(args))
	}
	if f.FromAgentID != nil {
		args = append(args, *f.FromAgentID)
		where += fmt.Sprintf(" AND from_agent_id=$%d", len(args))
	}
	if f.ToAgentID != nil {
		args = append(args, *f.ToAgentID)
		where += fmt.Sprintf(" AND to_agent_id=$%d", len(args))
	}
	if len(f.StatusIn) > 0 {
		statuses := make([]string, len(f.StatusIn))
		for i, s := range f.StatusIn {
			statuses[i] = string(s)
		}
		args = append(args, statuses)
		where += fmt.Sprintf(" AND status = ANY($%d)", len(args))
	}
	if f.CreatedAfter != nil {
		args = append(args, *f.CreatedAfter)
		where += fmt.Sprintf(" AND created_at >= $%d", len(args))
	}
	if f.CreatedBefore != nil {
		args = append(args, *f.CreatedBefore)
		where += fmt.Sprintf(" AND created_at <  $%d", len(args))
	}

	var total int
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM a2a_call_edges WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := r.pool.Query(ctx, `
		SELECT `+cols+` FROM a2a_call_edges
		WHERE `+where+`
		ORDER BY created_at DESC
		LIMIT $`+fmt.Sprintf("%d", len(args)-1)+` OFFSET $`+fmt.Sprintf("%d", len(args)),
		args...,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []*dom.Edge
	for rows.Next() {
		e, err := scan(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return out, total, nil
}

// 静态接口断言.
var _ dom.Repository = (*Repo)(nil)
