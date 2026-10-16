// Package department 提供租户部门 CRUD。
package department

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// Department DTO。
// ADR-0010: 业务实体表无 code 字段, stable id 走 uuid, HR 对账码走 metadata.external_code。
type Department struct {
	ID          int64          `json:"id"`
	UUID        string         `json:"uuid"`
	TenantID    int64          `json:"tenant_id"`
	ParentID    *int64         `json:"parent_id"`
	Path        string         `json:"path"`
	Depth       int            `json:"depth"`
	Name        string         `json:"name"`
	LeaderID    *int64         `json:"leader_id,omitempty"`
	SortOrder   int            `json:"sort_order"`
	Metadata    map[string]any `json:"metadata,omitempty"`
	MemberCount int            `json:"member_count"`
}

// CreateInput 新建参数。
type CreateInput struct {
	Name      string         `json:"name"`
	ParentID  *int64         `json:"parent_id"`
	SortOrder int            `json:"sort_order"`
	LeaderID  *int64         `json:"leader_id"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}

// UpdateInput 更新参数。
type UpdateInput struct {
	Name      *string         `json:"name"`
	ParentID  *int64          `json:"parent_id"`
	SortOrder *int            `json:"sort_order"`
	LeaderID  *int64          `json:"leader_id"`
	Metadata  *map[string]any `json:"metadata,omitempty"`
}

// Service 接口。
//
// actorAccountID 是触发本次操作的 admin 账号 id，用于 audit 事件 actor 标记。
// 项目纪律：service 层禁止从 ctx 直读身份；transport 层显式传入。
type Service interface {
	List(ctx context.Context, tenantID int64) ([]Department, error)
	Get(ctx context.Context, tenantID, id int64) (*Department, error)
	Create(ctx context.Context, tenantID, actorAccountID int64, in CreateInput) (*Department, error)
	Update(ctx context.Context, tenantID, actorAccountID, id int64, in UpdateInput) (*Department, error)
	Delete(ctx context.Context, tenantID, actorAccountID, id int64) error
}

type impl struct {
	pool *pgxpool.Pool
	pub  domevt.Publisher // nil = 不发 audit（仅 dev / 测试）
}

// New 构造。pub 用于发 audit.department.* 事件（Batch 2B T2B.2）；可传 nil。
func New(pool *pgxpool.Pool, pub domevt.Publisher) Service { return &impl{pool: pool, pub: pub} }

// notifyConfigChange 发 PG NOTIFY 让 bus contacts listener 即时感知部门变更（M2 §8）。
//
// 多实例契约：多个 bus 进程都 LISTEN 该 channel；admin 写后 1s 内所有 bus 实例收到 payload。
// 现阶段 contacts.Service 不缓存 tree/members 数据（每次 DB 查），但 contact_policies 有 cache，
// 同时该 channel 也是后续 cache / 观察 / change-feed 的统一入口。失败 silently。
func (s *impl) notifyConfigChange(ctx context.Context, payload string) {
	_, _ = s.pool.Exec(ctx, `SELECT pg_notify('config_change', $1)`, payload)
}

// auditAfter 在主操作之后用短事务发一条 audit 事件到 events_outbox（best-effort）。
//
// 设计原因：dept CRUD 不是大事务 provision；audit 失败不应回滚业务。
// 同时为了让 events_outbox 行能立刻被 audit-writer 拾起，仍包一个 tx commit。
// 失败 silently，不污染调用栈。
func (s *impl) auditAfter(ctx context.Context, topic string, tenantID, actorAccountID int64, idempKey string, data map[string]any) {
	if s.pub == nil {
		return
	}
	parts := strings.SplitN(topic, ".", 3)
	domain := ""
	eventKind := ""
	if len(parts) >= 2 {
		domain = parts[1]
	}
	if len(parts) >= 3 {
		eventKind = parts[2]
	}
	dataB, _ := json.Marshal(data)
	if len(dataB) == 0 {
		dataB = []byte("{}")
	}
	resourceKind, _ := data["resource_kind"].(string)
	resourceUUID, _ := data["resource_uuid"].(string)
	payload, _ := json.Marshal(map[string]any{
		"actor_kind":    "tenant_admin",
		"acting_as":     "",
		"domain":        domain,
		"event_kind":    eventKind,
		"severity":      "info",
		"resource_kind": resourceKind,
		"resource_uuid": resourceUUID,
		"account_id":    actorAccountID,
		"data":          json.RawMessage(dataB),
	})
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	_ = s.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: idempKey,
		Payload:        payload,
	})
	_ = tx.Commit(ctx)
}

func (s *impl) List(ctx context.Context, tenantID int64) ([]Department, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT d.id, d.uuid, d.tenant_id, d.parent_id, d.path, d.depth, d.name,
		       d.leader_id, d.sort_order, d.metadata,
		       (SELECT count(*) FROM tenant_memberships tm WHERE tm.department_id = d.id AND tm.deleted_at IS NULL) AS members
		FROM departments d
		WHERE d.tenant_id = $1 AND d.deleted_at IS NULL
		ORDER BY d.path, d.sort_order, d.id`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Department{}
	for rows.Next() {
		var d Department
		var depth int16
		var meta []byte
		if err := rows.Scan(&d.ID, &d.UUID, &d.TenantID, &d.ParentID, &d.Path, &depth, &d.Name,
			&d.LeaderID, &d.SortOrder, &meta, &d.MemberCount); err != nil {
			return nil, err
		}
		d.Depth = int(depth)
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &d.Metadata)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *impl) Get(ctx context.Context, tenantID, id int64) (*Department, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT d.id, d.uuid, d.tenant_id, d.parent_id, d.path, d.depth, d.name,
		       d.leader_id, d.sort_order, d.metadata,
		       (SELECT count(*) FROM tenant_memberships tm WHERE tm.department_id = d.id AND tm.deleted_at IS NULL)
		FROM departments d
		WHERE d.id = $1 AND d.tenant_id = $2 AND d.deleted_at IS NULL`, id, tenantID)
	var d Department
	var depth int16
	var meta []byte
	if err := row.Scan(&d.ID, &d.UUID, &d.TenantID, &d.ParentID, &d.Path, &depth, &d.Name,
		&d.LeaderID, &d.SortOrder, &meta, &d.MemberCount); err != nil {
		return nil, apperr.ErrNotFound
	}
	d.Depth = int(depth)
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &d.Metadata)
	}
	return &d, nil
}

func (s *impl) Create(ctx context.Context, tenantID, actorAccountID int64, in CreateInput) (*Department, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, apperr.ErrInvalidParams.Withf("name 必填")
	}

	// 计算 path / depth
	parentPath := ""
	parentDepth := int16(-1)
	if in.ParentID != nil {
		// 校验父部门属于同租户
		if err := s.pool.QueryRow(ctx, `
			SELECT path, depth FROM departments
			WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`, *in.ParentID, tenantID).
			Scan(&parentPath, &parentDepth); err != nil {
			return nil, apperr.ErrInvalidParams.Withf("parent not found")
		}
	}
	// path 段用 name (移除 code 后无 code 兜底)
	path := parentPath + "/" + in.Name
	metaRaw, _ := json.Marshal(in.Metadata)
	if len(metaRaw) == 0 {
		metaRaw = []byte("{}")
	}

	var id int64
	var uuid string
	if err := s.pool.QueryRow(ctx, `
		INSERT INTO departments (tenant_id, parent_id, path, depth, name, sort_order, leader_id, metadata)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
		RETURNING id, uuid`,
		tenantID, in.ParentID, path, parentDepth+1, in.Name, in.SortOrder, in.LeaderID, string(metaRaw)).
		Scan(&id, &uuid); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	s.auditAfter(ctx, "audit.department.created", tenantID, actorAccountID,
		fmt.Sprintf("department.created:%s", uuid),
		map[string]any{
			"resource_kind": "department",
			"resource_uuid": uuid,
			"department_id": id,
			"name":          in.Name,
			"parent_id":     in.ParentID,
		})
	return s.Get(ctx, tenantID, id)
}

func (s *impl) Update(ctx context.Context, tenantID, actorAccountID, id int64, in UpdateInput) (*Department, error) {
	cur, err := s.Get(ctx, tenantID, id)
	if err != nil {
		return nil, err
	}

	name := cur.Name
	sortOrder := cur.SortOrder
	leaderID := cur.LeaderID
	parentID := cur.ParentID
	metadata := cur.Metadata

	if in.Name != nil && *in.Name != "" {
		name = *in.Name
	}
	if in.SortOrder != nil {
		sortOrder = *in.SortOrder
	}
	if in.LeaderID != nil {
		leaderID = in.LeaderID
	}
	if in.Metadata != nil {
		metadata = *in.Metadata
	}
	// 不允许把自己设为父级
	if in.ParentID != nil && *in.ParentID == id {
		return nil, apperr.ErrInvalidParams.Withf("cannot set self as parent")
	}
	// 如果 parent 变了 → 重新计算 path / depth
	pathChanged := false
	newPath := cur.Path
	newDepth := int16(cur.Depth)
	if in.ParentID != nil && !samePtr(in.ParentID, cur.ParentID) {
		pathChanged = true
		parentID = in.ParentID
		parentPath := ""
		parentDepth := int16(-1)
		if parentID != nil {
			if err := s.pool.QueryRow(ctx, `
				SELECT path, depth FROM departments
				WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`, *parentID, tenantID).
				Scan(&parentPath, &parentDepth); err != nil {
				return nil, apperr.ErrInvalidParams.Withf("new parent not found")
			}
			// 防环：检查 parent 不能是 cur 的后代
			if strings.HasPrefix(parentPath, cur.Path+"/") || parentPath == cur.Path {
				return nil, apperr.ErrInvalidParams.Withf("cannot move into own descendant")
			}
		}
		newPath = parentPath + "/" + name
		newDepth = parentDepth + 1
	}

	if pathChanged {
		// 一并更新所有后代的 path 前缀（如果有）
		// 显式 cast 防止 pgx 把 int16/int 推断成 unknown 导致 "operator is not unique"
		_, err = s.pool.Exec(ctx, `
			UPDATE departments
			SET path = $1::text || substring(path FROM length($2::text)+1),
			    depth = depth + ($3::int - $4::int),
			    updated_at = now()
			WHERE path LIKE $2::text || '/%' AND tenant_id=$5 AND deleted_at IS NULL`,
			newPath, cur.Path, int(newDepth), cur.Depth, tenantID)
		if err != nil {
			return nil, err
		}
	}

	metaRaw, _ := json.Marshal(metadata)
	if len(metaRaw) == 0 {
		metaRaw = []byte("{}")
	}
	if _, err := s.pool.Exec(ctx, `
		UPDATE departments
		SET name=$1, sort_order=$2, leader_id=$3, parent_id=$4,
		    path=$5, depth=$6, metadata=$7::jsonb, updated_at=now()
		WHERE id=$8 AND tenant_id=$9`,
		name, sortOrder, leaderID, parentID, newPath, newDepth, string(metaRaw), id, tenantID); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	topic := "audit.department.updated"
	if pathChanged {
		topic = "audit.department.moved"
	}
	s.auditAfter(ctx, topic, tenantID, actorAccountID,
		fmt.Sprintf("%s:%s:%d", topic, cur.UUID, cur.ID),
		map[string]any{
			"resource_kind": "department",
			"resource_uuid": cur.UUID,
			"department_id": id,
			"new_name":      name,
			"new_path":      newPath,
			"old_path":      cur.Path,
			"old_parent_id": cur.ParentID,
			"new_parent_id": parentID,
		})
	return s.Get(ctx, tenantID, id)
}

func (s *impl) Delete(ctx context.Context, tenantID, actorAccountID, id int64) error {
	// Batch 2B Q2: 拒绝删除含子部门或成员的部门 → 409
	var childCount, memberCount int
	var deptUUID, deptName string
	_ = s.pool.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM departments WHERE parent_id=$1 AND tenant_id=$2 AND deleted_at IS NULL),
		  (SELECT count(*) FROM tenant_memberships WHERE department_id=$1 AND tenant_id=$2 AND deleted_at IS NULL)`,
		id, tenantID).Scan(&childCount, &memberCount)
	if childCount > 0 {
		return apperr.ErrConflict.Withf("部门下还有 %d 个子部门，请先移除", childCount)
	}
	if memberCount > 0 {
		return apperr.ErrConflict.Withf("部门下还有 %d 个成员，请先移到其它部门", memberCount)
	}
	_ = s.pool.QueryRow(ctx, `SELECT uuid, name FROM departments WHERE id=$1 AND tenant_id=$2`, id, tenantID).Scan(&deptUUID, &deptName)
	if _, err := s.pool.Exec(ctx, `UPDATE departments SET deleted_at=now() WHERE id=$1 AND tenant_id=$2`, id, tenantID); err != nil {
		return err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	s.auditAfter(ctx, "audit.department.deleted", tenantID, actorAccountID,
		fmt.Sprintf("department.deleted:%s", deptUUID),
		map[string]any{
			"resource_kind": "department",
			"resource_uuid": deptUUID,
			"department_id": id,
			"name":          deptName,
		})
	return nil
}

func samePtr(a, b *int64) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}
