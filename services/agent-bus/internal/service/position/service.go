// Package position F01 §1: 租户级职位 CRUD + member/agent 关联。
//
// 表: tenant_positions (字典) + tenant_member_positions (员工 N:N) + tenant_agent_positions (Agent N:N)
// 设计见 docs/features/F01-identity-and-auth.md §1.5。
//
// Service 层不读 ctx 身份, transport 显式传 tenantID + actorAccountID。
package position

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Position 租户级职位字典项。
// ADR-0010: 业务实体表 (positions 这类) 不暴露 code 字段, 内部 stable ID 走 uuid,
// metadata.seed_key 保留系统 seed 追溯, metadata.external_code 用户可选自定义 HR 对账码。
type Position struct {
	ID          int64          `json:"id"`
	UUID        string         `json:"uuid"`
	TenantID    int64          `json:"tenantId"`
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	Icon        string         `json:"icon,omitempty"`
	SortOrder   int            `json:"sortOrder"`
	IsSystem    bool           `json:"isSystem"`
	Metadata    map[string]any `json:"metadata,omitempty"`
	CreatedAt   string         `json:"createdAt"`
	UpdatedAt   string         `json:"updatedAt"`
	MemberCount int            `json:"memberCount"`
	AgentCount  int            `json:"agentCount"`
}

// MemberPositionAssignment 员工 ↔ 职位 N:N 行。
type MemberPositionAssignment struct {
	ID           int64  `json:"id"`
	MembershipID int64  `json:"membershipId"`
	PositionID   int64  `json:"positionId"`
	PositionName string `json:"positionName"`
	IsPrimary    bool   `json:"isPrimary"`
	AssignedAt   string `json:"assignedAt"`
	AssignedBy   *int64 `json:"assignedBy,omitempty"`
}

// AgentPositionAssignment 数字员工 ↔ 职位 N:N 行。
type AgentPositionAssignment struct {
	ID           int64  `json:"id"`
	AgentID      int64  `json:"agentId"`
	PositionID   int64  `json:"positionId"`
	PositionName string `json:"positionName"`
	IsPrimary    bool   `json:"isPrimary"`
	AssignedAt   string `json:"assignedAt"`
}

// CreateInput 新建参数。
type CreateInput struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Icon        string         `json:"icon"`
	SortOrder   int            `json:"sortOrder"`
	Metadata    map[string]any `json:"metadata,omitempty"`
}

// UpdateInput 更新参数 (全 ptr 区分 "不传" vs "清空")。
type UpdateInput struct {
	Name        *string         `json:"name,omitempty"`
	Description *string         `json:"description,omitempty"`
	Icon        *string         `json:"icon,omitempty"`
	SortOrder   *int            `json:"sortOrder,omitempty"`
	Metadata    *map[string]any `json:"metadata,omitempty"`
}

// AssignMemberInput 给员工挂职位。
type AssignMemberInput struct {
	PositionIDs       []int64 `json:"positionIds"`       // 替换式: 提交全集; 不在列表的会被解绑
	PrimaryPositionID *int64  `json:"primaryPositionId"` // 主职位 (必须在 PositionIDs 内, 否则任一为主)
}

// AssignAgentInput 给数字员工挂职位 (语义同 AssignMemberInput)。
type AssignAgentInput struct {
	PositionIDs       []int64 `json:"positionIds"`
	PrimaryPositionID *int64  `json:"primaryPositionId"`
}

// Service 接口。
type Service interface {
	List(ctx context.Context, tenantID int64, keyword string, limit, offset int) ([]Position, int64, error)
	Get(ctx context.Context, tenantID, id int64) (*Position, error)
	Create(ctx context.Context, tenantID, actorAccountID int64, in CreateInput) (*Position, error)
	Update(ctx context.Context, tenantID, actorAccountID, id int64, in UpdateInput) (*Position, error)
	Delete(ctx context.Context, tenantID, actorAccountID, id int64) error

	// AssignMember 替换式给 member 挂职位 N:N (空 PositionIDs 等于清空)。
	AssignMember(ctx context.Context, tenantID, actorAccountID, membershipID int64, in AssignMemberInput) error
	ListMemberPositions(ctx context.Context, tenantID, membershipID int64) ([]MemberPositionAssignment, error)

	// AssignAgent 替换式给数字员工挂职位 N:N (空 PositionIDs 等于清空)。
	AssignAgent(ctx context.Context, tenantID, actorAccountID, agentID int64, in AssignAgentInput) error
	ListAgentPositions(ctx context.Context, tenantID, agentID int64) ([]AgentPositionAssignment, error)
}

type impl struct {
	pool *pgxpool.Pool
}

// New 构造。
func New(pool *pgxpool.Pool) Service { return &impl{pool: pool} }

// List 分页列本租户职位 (按 sort_order, 含 member/agent 计数)。
func (s *impl) List(ctx context.Context, tenantID int64, keyword string, limit, offset int) ([]Position, int64, error) {
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	where := `p.tenant_id = $1 AND p.deleted_at IS NULL`
	args := []any{tenantID}
	if strings.TrimSpace(keyword) != "" {
		args = append(args, "%"+strings.TrimSpace(keyword)+"%")
		where += ` AND (p.name ILIKE $` + itoa(len(args)) + ` OR COALESCE(p.description,'') ILIKE $` + itoa(len(args)) + `)`
	}
	args = append(args, limit, offset)
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, p.uuid::text, p.tenant_id, p.name,
		       COALESCE(p.description,''), COALESCE(p.icon,''), p.sort_order, p.is_system,
		       COALESCE(p.metadata, '{}'::jsonb),
		       p.created_at::text, p.updated_at::text,
		       (SELECT count(*) FROM tenant_member_positions mp WHERE mp.position_id = p.id),
		       (SELECT count(*) FROM tenant_agent_positions ap WHERE ap.position_id = p.id),
		       COUNT(*) OVER()
		  FROM tenant_positions p
		 WHERE `+where+`
		 ORDER BY p.sort_order, p.id
		 LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)), args...)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	out := []Position{}
	var total int64
	for rows.Next() {
		var p Position
		var metaRaw []byte
		if err := rows.Scan(&p.ID, &p.UUID, &p.TenantID, &p.Name,
			&p.Description, &p.Icon, &p.SortOrder, &p.IsSystem, &metaRaw,
			&p.CreatedAt, &p.UpdatedAt, &p.MemberCount, &p.AgentCount, &total); err != nil {
			return nil, 0, apperr.ErrInternal.Wrap(err)
		}
		_ = json.Unmarshal(metaRaw, &p.Metadata)
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	if len(out) == 0 && offset > 0 {
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM tenant_positions p WHERE `+where, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, apperr.ErrInternal.Wrap(err)
		}
	}
	return out, total, nil
}

// Get 单个查询。
func (s *impl) Get(ctx context.Context, tenantID, id int64) (*Position, error) {
	var p Position
	var metaRaw []byte
	err := s.pool.QueryRow(ctx, `
		SELECT id, uuid::text, tenant_id, name,
		       COALESCE(description,''), COALESCE(icon,''), sort_order, is_system,
		       COALESCE(metadata, '{}'::jsonb),
		       created_at::text, updated_at::text,
		       (SELECT count(*) FROM tenant_member_positions mp WHERE mp.position_id = $2),
		       (SELECT count(*) FROM tenant_agent_positions ap WHERE ap.position_id = $2)
		  FROM tenant_positions
		 WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
		tenantID, id).Scan(&p.ID, &p.UUID, &p.TenantID, &p.Name,
		&p.Description, &p.Icon, &p.SortOrder, &p.IsSystem, &metaRaw,
		&p.CreatedAt, &p.UpdatedAt, &p.MemberCount, &p.AgentCount)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("position %d not found", id)
	}
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	_ = json.Unmarshal(metaRaw, &p.Metadata)
	return &p, nil
}

// Create 新建职位 (name 在租户内唯一; 不再有 code 字段)。
func (s *impl) Create(ctx context.Context, tenantID, _ int64, in CreateInput) (*Position, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	metaRaw, _ := json.Marshal(in.Metadata)
	if len(metaRaw) == 0 {
		metaRaw = []byte("{}")
	}
	var id int64
	err := s.pool.QueryRow(ctx, `
		INSERT INTO tenant_positions (tenant_id, name, description, icon, sort_order, is_system, metadata)
		VALUES ($1, $2, NULLIF($3,''), NULLIF($4,''), $5, false, $6::jsonb)
		RETURNING id`,
		tenantID, in.Name, in.Description, in.Icon, in.SortOrder, string(metaRaw)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "duplicate") || strings.Contains(err.Error(), "unique") {
			return nil, apperr.ErrInvalidParams.Withf("职位名 %s 已存在", in.Name)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return s.Get(ctx, tenantID, id)
}

// Update 部分更新 (允许改所有字段, 含系统 seed 的 name/sort)。
func (s *impl) Update(ctx context.Context, tenantID, _, id int64, in UpdateInput) (*Position, error) {
	sets := []string{}
	args := []any{}
	idx := 1
	if in.Name != nil {
		sets = append(sets, "name = $"+itoa(idx))
		args = append(args, *in.Name)
		idx++
	}
	if in.Description != nil {
		sets = append(sets, "description = NULLIF($"+itoa(idx)+",'')")
		args = append(args, *in.Description)
		idx++
	}
	if in.Icon != nil {
		sets = append(sets, "icon = NULLIF($"+itoa(idx)+",'')")
		args = append(args, *in.Icon)
		idx++
	}
	if in.SortOrder != nil {
		sets = append(sets, "sort_order = $"+itoa(idx))
		args = append(args, *in.SortOrder)
		idx++
	}
	if in.Metadata != nil {
		mb, _ := json.Marshal(*in.Metadata)
		if len(mb) == 0 {
			mb = []byte("{}")
		}
		sets = append(sets, "metadata = $"+itoa(idx)+"::jsonb")
		args = append(args, string(mb))
		idx++
	}
	if len(sets) == 0 {
		return s.Get(ctx, tenantID, id)
	}
	sets = append(sets, "updated_at = now()")
	args = append(args, tenantID, id)
	q := "UPDATE tenant_positions SET " + strings.Join(sets, ", ") +
		" WHERE tenant_id = $" + itoa(idx) + " AND id = $" + itoa(idx+1) +
		" AND deleted_at IS NULL"
	res, err := s.pool.Exec(ctx, q, args...)
	if err != nil {
		if strings.Contains(err.Error(), "duplicate") {
			return nil, apperr.ErrInvalidParams.Withf("code 重复")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if res.RowsAffected() == 0 {
		return nil, apperr.ErrNotFound.Withf("position %d not found", id)
	}
	return s.Get(ctx, tenantID, id)
}

// Delete 软删 (CASCADE 关联表)。
func (s *impl) Delete(ctx context.Context, tenantID, _, id int64) error {
	res, err := s.pool.Exec(ctx, `
		UPDATE tenant_positions SET deleted_at = now()
		 WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if res.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("position %d not found", id)
	}
	return nil
}

// AssignMember 替换式挂载: 先删该 membership 全部既有 assign, 再批量插入。
func (s *impl) AssignMember(ctx context.Context, tenantID, actorAccountID, membershipID int64, in AssignMemberInput) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 校验 membership 属本租户
	var mTenant int64
	err = tx.QueryRow(ctx, `SELECT tenant_id FROM tenant_memberships WHERE id = $1 AND deleted_at IS NULL`, membershipID).Scan(&mTenant)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound.Withf("membership %d not found", membershipID)
	}
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if mTenant != tenantID {
		return apperr.ErrForbidden.Withf("membership 不属当前租户")
	}

	// 校验所有 positionIDs 属本租户
	if len(in.PositionIDs) > 0 {
		var cnt int
		err = tx.QueryRow(ctx, `
			SELECT count(*) FROM tenant_positions
			 WHERE tenant_id = $1 AND id = ANY($2::bigint[]) AND deleted_at IS NULL`,
			tenantID, in.PositionIDs).Scan(&cnt)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if cnt != len(in.PositionIDs) {
			return apperr.ErrInvalidParams.Withf("positionIds 含本租户外的职位 id")
		}
	}

	// 清空既有
	if _, err := tx.Exec(ctx, `DELETE FROM tenant_member_positions WHERE membership_id = $1`, membershipID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	// 主职位决定: PrimaryPositionID 优先, 否则用第一个
	var primary int64
	if in.PrimaryPositionID != nil {
		primary = *in.PrimaryPositionID
		found := false
		for _, pid := range in.PositionIDs {
			if pid == primary {
				found = true
				break
			}
		}
		if !found && primary != 0 {
			return apperr.ErrInvalidParams.Withf("primaryPositionId 必须在 positionIds 列表内")
		}
	} else if len(in.PositionIDs) > 0 {
		primary = in.PositionIDs[0]
	}

	// 批量插入
	for _, pid := range in.PositionIDs {
		isPrimary := pid == primary
		if _, err := tx.Exec(ctx, `
			INSERT INTO tenant_member_positions (membership_id, position_id, is_primary, assigned_by)
			VALUES ($1, $2, $3, $4)`, membershipID, pid, isPrimary, actorAccountID); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}

	return tx.Commit(ctx)
}

// ListMemberPositions 列某 member 的全部职位 (含主职位标记)。
func (s *impl) ListMemberPositions(ctx context.Context, tenantID, membershipID int64) ([]MemberPositionAssignment, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT mp.id, mp.membership_id, mp.position_id, p.name,
		       mp.is_primary, mp.assigned_at::text, mp.assigned_by
		  FROM tenant_member_positions mp
		  JOIN tenant_positions p ON p.id = mp.position_id
		  JOIN tenant_memberships m ON m.id = mp.membership_id
		 WHERE m.tenant_id = $1 AND mp.membership_id = $2 AND p.deleted_at IS NULL
		 ORDER BY mp.is_primary DESC, p.sort_order, p.id`,
		tenantID, membershipID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	out := []MemberPositionAssignment{}
	for rows.Next() {
		var a MemberPositionAssignment
		if err := rows.Scan(&a.ID, &a.MembershipID, &a.PositionID, &a.PositionName,
			&a.IsPrimary, &a.AssignedAt, &a.AssignedBy); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		out = append(out, a)
	}
	return out, nil
}

// AssignAgent 替换式挂载: 先删该 agent 全部既有 assign, 再批量插入。
// 表 tenant_agent_positions 无 assigned_by 列, actorAccountID 仅用于审计上下文 (此处不写库)。
func (s *impl) AssignAgent(ctx context.Context, tenantID, _ int64, agentID int64, in AssignAgentInput) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 校验 agent 属本租户
	var aTenant int64
	err = tx.QueryRow(ctx, `SELECT tenant_id FROM digital_employees WHERE id = $1 AND deleted_at IS NULL`, agentID).Scan(&aTenant)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound.Withf("agent %d not found", agentID)
	}
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if aTenant != tenantID {
		return apperr.ErrForbidden.Withf("agent 不属当前租户")
	}

	// 校验所有 positionIDs 属本租户
	if len(in.PositionIDs) > 0 {
		var cnt int
		err = tx.QueryRow(ctx, `
			SELECT count(*) FROM tenant_positions
			 WHERE tenant_id = $1 AND id = ANY($2::bigint[]) AND deleted_at IS NULL`,
			tenantID, in.PositionIDs).Scan(&cnt)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if cnt != len(in.PositionIDs) {
			return apperr.ErrInvalidParams.Withf("positionIds 含本租户外的职位 id")
		}
	}

	if _, err := tx.Exec(ctx, `DELETE FROM tenant_agent_positions WHERE agent_id = $1`, agentID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	var primary int64
	if in.PrimaryPositionID != nil {
		primary = *in.PrimaryPositionID
		found := false
		for _, pid := range in.PositionIDs {
			if pid == primary {
				found = true
				break
			}
		}
		if !found && primary != 0 {
			return apperr.ErrInvalidParams.Withf("primaryPositionId 必须在 positionIds 列表内")
		}
	} else if len(in.PositionIDs) > 0 {
		primary = in.PositionIDs[0]
	}

	for _, pid := range in.PositionIDs {
		isPrimary := pid == primary
		if _, err := tx.Exec(ctx, `
			INSERT INTO tenant_agent_positions (agent_id, position_id, is_primary)
			VALUES ($1, $2, $3)`, agentID, pid, isPrimary); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}

	return tx.Commit(ctx)
}

// ListAgentPositions 列某 agent 的全部职位 (含主职位标记)。
func (s *impl) ListAgentPositions(ctx context.Context, tenantID, agentID int64) ([]AgentPositionAssignment, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT ap.id, ap.agent_id, ap.position_id, p.name,
		       ap.is_primary, ap.assigned_at::text
		  FROM tenant_agent_positions ap
		  JOIN tenant_positions p ON p.id = ap.position_id
		  JOIN digital_employees a ON a.id = ap.agent_id
		 WHERE a.tenant_id = $1 AND ap.agent_id = $2 AND p.deleted_at IS NULL
		 ORDER BY ap.is_primary DESC, p.sort_order, p.id`,
		tenantID, agentID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	out := []AgentPositionAssignment{}
	for rows.Next() {
		var a AgentPositionAssignment
		if err := rows.Scan(&a.ID, &a.AgentID, &a.PositionID, &a.PositionName,
			&a.IsPrimary, &a.AssignedAt); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		out = append(out, a)
	}
	return out, nil
}

func itoa(i int) string {
	// inline strconv.Itoa to avoid import for tiny use case
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var buf [16]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}
