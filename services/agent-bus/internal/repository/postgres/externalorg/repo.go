// Package externalorg 提供 /api/external/v1/org/* 端点的业务逻辑。
//
// 设计要点:
//   - 对外 ID 使用 id 语义，不暴露数据库 int64 id
//   - 成员用 account.uuid 作为 path id (tenant_memberships 无 uuid 列)
//   - 游标分页按 (updated_at, uuid/account_uuid) 稳定排序
//   - 增量查询: 支持 updated_since 参数, 删除记录以 tombstone 返回
//   - 写操作发 org.* 事件到 events_outbox, 供 webhook dispatcher 消费
package externalorg

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/externalorg"

	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	tenantadminguard "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenantadmin"
)

type ExternalDepartment = dom.ExternalDepartment
type ExternalMember = dom.ExternalMember
type ExternalPosition = dom.ExternalPosition
type CreateDepartmentInput = dom.CreateDepartmentInput
type UpdateDepartmentInput = dom.UpdateDepartmentInput
type CreateMemberInput = dom.CreateMemberInput
type UpdateMemberInput = dom.UpdateMemberInput
type CreatePositionInput = dom.CreatePositionInput
type UpdatePositionInput = dom.UpdatePositionInput
type Service = dom.Service
type CursorPage[T any] = dom.CursorPage[T]

type impl struct {
	pool *pgxpool.Pool
	pub  domevt.Publisher
}

type departmentRowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func resolveMemberDepartmentID(ctx context.Context, q departmentRowQuerier, tenantID int64, departmentUUID string) (int64, error) {
	var departmentID int64
	if departmentUUID != "" {
		err := q.QueryRow(ctx, `
			SELECT id FROM departments
			 WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`, departmentUUID, tenantID).Scan(&departmentID)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.ErrInvalidParams.Withf("department %s not found", departmentUUID)
		}
		return departmentID, err
	}

	err := q.QueryRow(ctx, `
		SELECT id FROM departments
		 WHERE tenant_id=$1 AND parent_id IS NULL AND deleted_at IS NULL
		 ORDER BY id LIMIT 1`, tenantID).Scan(&departmentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, apperr.ErrInternal.Withf("tenant root department not found")
	}
	return departmentID, err
}

func New(pool *pgxpool.Pool, pub domevt.Publisher) Service {
	return &impl{pool: pool, pub: pub}
}

// ── cursor codec ──

type cursorVal struct {
	T string `json:"t"` // updated_at RFC3339Nano
	U string `json:"u"` // uuid or account_uuid
}

func encodeCursor(updatedAt time.Time, uuid string) string {
	b, _ := json.Marshal(cursorVal{T: updatedAt.Format(time.RFC3339Nano), U: uuid})
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeCursor(s string) (time.Time, string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return time.Time{}, "", apperr.ErrInvalidParams.Withf("invalid cursor")
	}
	var v cursorVal
	if err := json.Unmarshal(raw, &v); err != nil {
		return time.Time{}, "", apperr.ErrInvalidParams.Withf("invalid cursor")
	}
	t, err := time.Parse(time.RFC3339Nano, v.T)
	if err != nil {
		return time.Time{}, "", apperr.ErrInvalidParams.Withf("invalid cursor")
	}
	return t, v.U, nil
}

func externalAssignableRoleCode(roleCode string) (string, error) {
	roleCode = strings.TrimSpace(roleCode)
	if roleCode == "" {
		return "", nil
	}
	if roleCode != "tenant.member" {
		return "", apperr.ErrForbidden.Withf("external API can only assign tenant.member")
	}
	return roleCode, nil
}

func trimOptionalIdentifier(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	return &trimmed
}

func syncDepartmentIdentifiers(d *ExternalDepartment) {
	d.ID = d.UUID
	d.ParentID = d.ParentUUID
	d.ThirdDepartmentID = d.ExternalCode
}

func syncMemberIdentifiers(m *ExternalMember) {
	m.AccountID = m.AccountUUID
	m.DepartmentID = m.DepartmentUUID
	m.ThirdUserID = m.EmployeeID
}

func syncPositionIdentifiers(p *ExternalPosition) {
	p.ID = p.UUID
	p.ThirdPositionID = p.ExternalCode
}

// ── org event publishing ──

func (s *impl) publishOrgEvent(ctx context.Context, tx pgx.Tx, topic string, tenantID int64, entityKind, entityUUID string) error {
	if s.pub == nil {
		return nil
	}
	var tenantUUID string
	_ = tx.QueryRow(ctx, `SELECT uuid FROM tenants WHERE id=$1`, tenantID).Scan(&tenantUUID)

	payload, _ := json.Marshal(map[string]any{
		"schema_version": 1,
		"event_type":     topic,
		"tenant_id":      tenantUUID,
		"entity_kind":    entityKind,
		"entity_id":      entityUUID,
		"updated_at":     time.Now().UTC().Format(time.RFC3339Nano),
	})
	return s.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:    topic,
		TenantID: tenantID,
		Payload:  payload,
	})
}

// ── Departments ──

func (s *impl) ListDepartments(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalDepartment], error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	fetch := limit + 1

	args := []any{tenantID}
	// Include soft-deleted rows for incremental sync (tombstone)
	where := `d.tenant_id = $1`
	if updatedSince != nil {
		args = append(args, *updatedSince)
		where += fmt.Sprintf(` AND d.updated_at >= $%d`, len(args))
	} else {
		where += ` AND d.deleted_at IS NULL`
	}
	if cursor != "" {
		ct, cu, err := decodeCursor(cursor)
		if err != nil {
			return nil, err
		}
		args = append(args, ct, cu)
		where += fmt.Sprintf(` AND (d.updated_at, d.uuid::text) > ($%d, $%d)`, len(args)-1, len(args))
	}
	args = append(args, fetch)

	rows, err := s.pool.Query(ctx, `
		SELECT d.uuid, COALESCE(pd.uuid::text, ''), d.name, d.path, d.depth, d.sort_order, d.metadata,
		       (SELECT count(*) FROM tenant_memberships tm WHERE tm.department_id=d.id AND tm.deleted_at IS NULL),
		       d.updated_at, d.deleted_at IS NOT NULL AS is_deleted
		FROM departments d
		LEFT JOIN departments pd ON pd.id = d.parent_id AND pd.tenant_id = d.tenant_id
		WHERE `+where+`
		ORDER BY d.updated_at, d.uuid
		LIMIT $`+fmt.Sprint(len(args)), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := []ExternalDepartment{}
	for rows.Next() {
		var d ExternalDepartment
		var meta []byte
		var isDeleted bool
		var depth int16
		if err := rows.Scan(&d.UUID, &d.ParentUUID, &d.Name, &d.Path, &depth, &d.SortOrder, &meta,
			&d.MemberCount, &d.UpdatedAt, &isDeleted); err != nil {
			return nil, err
		}
		d.Depth = int(depth)
		if len(meta) > 0 {
			var m map[string]any
			_ = json.Unmarshal(meta, &m)
			if ec, ok := m["external_code"].(string); ok {
				d.ExternalCode = ec
			}
			d.Metadata = m
		}
		d.Status = "active"
		if isDeleted {
			d.Status = "deleted"
		}
		syncDepartmentIdentifiers(&d)
		items = append(items, d)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	var nextCursor string
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		nextCursor = encodeCursor(last.UpdatedAt, last.UUID)
	}
	return &CursorPage[ExternalDepartment]{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *impl) GetDepartment(ctx context.Context, tenantID int64, uuid string) (*ExternalDepartment, error) {
	var d ExternalDepartment
	var meta []byte
	var depth int16
	err := s.pool.QueryRow(ctx, `
		SELECT d.uuid, COALESCE(pd.uuid::text, ''), d.name, d.path, d.depth, d.sort_order, d.metadata,
		       (SELECT count(*) FROM tenant_memberships tm WHERE tm.department_id=d.id AND tm.deleted_at IS NULL),
		       d.updated_at
		FROM departments d
		LEFT JOIN departments pd ON pd.id = d.parent_id AND pd.tenant_id = d.tenant_id
		WHERE d.uuid = $1 AND d.tenant_id = $2 AND d.deleted_at IS NULL`,
		uuid, tenantID).Scan(&d.UUID, &d.ParentUUID, &d.Name, &d.Path, &depth, &d.SortOrder, &meta,
		&d.MemberCount, &d.UpdatedAt)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("department %s not found", uuid)
	}
	d.Depth = int(depth)
	d.Status = "active"
	if len(meta) > 0 {
		var m map[string]any
		_ = json.Unmarshal(meta, &m)
		if ec, ok := m["external_code"].(string); ok {
			d.ExternalCode = ec
		}
		d.Metadata = m
	}
	syncDepartmentIdentifiers(&d)
	return &d, nil
}

func (s *impl) CreateDepartment(ctx context.Context, tenantID int64, in CreateDepartmentInput) (*ExternalDepartment, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	in.ParentUUID = strings.TrimSpace(in.ParentID)
	in.ExternalCode = strings.TrimSpace(in.ThirdDepartmentID)

	var parentID *int64
	parentPath := ""
	parentDepth := int16(-1)
	if in.ParentUUID != "" {
		var pid int64
		if err := s.pool.QueryRow(ctx, `SELECT id, path, depth FROM departments WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
			in.ParentUUID, tenantID).Scan(&pid, &parentPath, &parentDepth); err != nil {
			return nil, apperr.ErrInvalidParams.Withf("parent department %s not found", in.ParentUUID)
		}
		parentID = &pid
	}

	meta := in.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	if in.ExternalCode != "" {
		meta["external_code"] = in.ExternalCode
	}
	metaRaw, _ := json.Marshal(meta)
	path := parentPath + "/" + in.Name

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	var uuid string
	if err := tx.QueryRow(ctx, `
		INSERT INTO departments (tenant_id, parent_id, path, depth, name, sort_order, metadata)
		VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
		RETURNING uuid`,
		tenantID, parentID, path, parentDepth+1, in.Name, in.SortOrder, string(metaRaw)).Scan(&uuid); err != nil {
		if strings.Contains(err.Error(), "uq_departments_external_code") {
			return nil, apperr.ErrConflict.Withf("third_department_id %s already exists in this tenant", in.ExternalCode)
		}
		return nil, err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.department.created", tenantID, "department", uuid); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	return s.GetDepartment(ctx, tenantID, uuid)
}

func (s *impl) UpdateDepartment(ctx context.Context, tenantID int64, uuid string, in UpdateDepartmentInput) (*ExternalDepartment, error) {
	in.ParentUUID = trimOptionalIdentifier(in.ParentID)
	in.ExternalCode = trimOptionalIdentifier(in.ThirdDepartmentID)
	var id int64
	var curPath string
	var curDepth int16
	var curParentID *int64
	var curName string
	var curMeta []byte
	var curSortOrder int
	if err := s.pool.QueryRow(ctx, `
		SELECT id, path, depth, parent_id, name, sort_order, metadata
		FROM departments WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID).Scan(&id, &curPath, &curDepth, &curParentID, &curName, &curSortOrder, &curMeta); err != nil {
		return nil, apperr.ErrNotFound.Withf("department %s not found", uuid)
	}

	name := curName
	sortOrder := curSortOrder
	parentID := curParentID
	var metadata map[string]any
	if len(curMeta) > 0 {
		_ = json.Unmarshal(curMeta, &metadata)
	}
	if metadata == nil {
		metadata = map[string]any{}
	}

	if in.Name != nil && *in.Name != "" {
		name = *in.Name
	}
	if in.SortOrder != nil {
		sortOrder = *in.SortOrder
	}
	if in.ExternalCode != nil {
		if *in.ExternalCode == "" {
			delete(metadata, "external_code")
		} else {
			metadata["external_code"] = *in.ExternalCode
		}
	}
	if in.Metadata != nil {
		for k, v := range *in.Metadata {
			metadata[k] = v
		}
	}

	pathChanged := false
	newPath := curPath
	newDepth := curDepth
	if in.ParentUUID != nil {
		pathChanged = true
		if *in.ParentUUID == "" {
			parentID = nil
			newPath = "/" + name
			newDepth = 0
		} else {
			var pid int64
			var pp string
			var pd int16
			if err := s.pool.QueryRow(ctx, `SELECT id, path, depth FROM departments WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
				*in.ParentUUID, tenantID).Scan(&pid, &pp, &pd); err != nil {
				return nil, apperr.ErrInvalidParams.Withf("parent department %s not found", *in.ParentUUID)
			}
			if pid == id {
				return nil, apperr.ErrInvalidParams.Withf("cannot set self as parent")
			}
			if strings.HasPrefix(pp, curPath+"/") || pp == curPath {
				return nil, apperr.ErrInvalidParams.Withf("cannot move into own descendant")
			}
			parentID = &pid
			newPath = pp + "/" + name
			newDepth = pd + 1
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	if pathChanged {
		_, _ = tx.Exec(ctx, `
			UPDATE departments SET path = $1::text || substring(path FROM length($2::text)+1),
			       depth = depth + ($3::int - $4::int), updated_at = now()
			WHERE path LIKE $2::text || '/%' AND tenant_id=$5 AND deleted_at IS NULL`,
			newPath, curPath, int(newDepth), int(curDepth), tenantID)
	}

	metaRaw, _ := json.Marshal(metadata)
	if _, err := tx.Exec(ctx, `
		UPDATE departments SET name=$1, sort_order=$2, parent_id=$3, path=$4, depth=$5, metadata=$6::jsonb, updated_at=now()
		WHERE id=$7 AND tenant_id=$8`,
		name, sortOrder, parentID, newPath, newDepth, string(metaRaw), id, tenantID); err != nil {
		if strings.Contains(err.Error(), "uq_departments_external_code") {
			return nil, apperr.ErrConflict.Withf("third_department_id already exists in this tenant")
		}
		return nil, err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.department.updated", tenantID, "department", uuid); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	return s.GetDepartment(ctx, tenantID, uuid)
}

func (s *impl) DeleteDepartment(ctx context.Context, tenantID int64, uuid string) error {
	var id int64
	var depth int16
	if err := s.pool.QueryRow(ctx, `SELECT id, depth FROM departments WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID).Scan(&id, &depth); err != nil {
		return apperr.ErrNotFound.Withf("department %s not found", uuid)
	}
	if depth == 0 {
		return apperr.ErrConflict.Withf("cannot delete root department")
	}
	var childCount, memberCount int
	_ = s.pool.QueryRow(ctx, `
		SELECT
		  (SELECT count(*) FROM departments WHERE parent_id=$1 AND tenant_id=$2 AND deleted_at IS NULL),
		  (SELECT count(*) FROM tenant_memberships WHERE department_id=$1 AND tenant_id=$2 AND deleted_at IS NULL)`,
		id, tenantID).Scan(&childCount, &memberCount)
	if childCount > 0 {
		return apperr.ErrConflict.Withf("department has %d child departments, move them first", childCount)
	}
	if memberCount > 0 {
		return apperr.ErrConflict.Withf("department has %d members, move them first", memberCount)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE departments SET deleted_at=now(), updated_at=now() WHERE id=$1 AND tenant_id=$2`, id, tenantID); err != nil {
		return err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.department.deleted", tenantID, "department", uuid); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("department:%d", tenantID))
	return nil
}

// ── Members ──

func (s *impl) ListMembers(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalMember], error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	fetch := limit + 1
	args := []any{tenantID}
	where := `tm.tenant_id = $1`
	if updatedSince != nil {
		args = append(args, *updatedSince)
		where += fmt.Sprintf(` AND tm.updated_at >= $%d`, len(args))
	} else {
		where += ` AND tm.deleted_at IS NULL`
	}
	if cursor != "" {
		ct, cu, err := decodeCursor(cursor)
		if err != nil {
			return nil, err
		}
		args = append(args, ct, cu)
		where += fmt.Sprintf(` AND (tm.updated_at, a.uuid::text) > ($%d, $%d)`, len(args)-1, len(args))
	}
	args = append(args, fetch)

	rows, err := s.pool.Query(ctx, `
		SELECT a.uuid, COALESCE(NULLIF(tm.nickname,''), a.display_name), COALESCE(a.email,''), COALESCE(a.phone,''),
		       COALESCE(tm.employee_id,''), COALESCE(tm.title,''),
		       COALESCE(d.uuid::text, ''), tm.status, tm.updated_at,
		       COALESCE(
		         (SELECT array_agg(r.code) FROM role_assignments ra
		          JOIN roles r ON r.id = ra.role_id
		          WHERE ra.account_id = a.id AND ra.scope_kind IN ('tenant','workspace')
		            AND ra.tenant_id = tm.tenant_id AND ra.deleted_at IS NULL), '{}') AS roles
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		LEFT JOIN departments d ON d.id = tm.department_id
		WHERE `+where+`
		ORDER BY tm.updated_at, a.uuid
		LIMIT $`+fmt.Sprint(len(args)), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := []ExternalMember{}
	for rows.Next() {
		var m ExternalMember
		var roles []string
		if err := rows.Scan(&m.AccountUUID, &m.DisplayName, &m.Email, &m.Phone,
			&m.EmployeeID, &m.Title, &m.DepartmentUUID, &m.Status, &m.UpdatedAt, &roles); err != nil {
			return nil, err
		}
		m.Roles = roles
		syncMemberIdentifiers(&m)
		items = append(items, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	var nextCursor string
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		nextCursor = encodeCursor(last.UpdatedAt, last.AccountUUID)
	}
	return &CursorPage[ExternalMember]{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *impl) GetMember(ctx context.Context, tenantID int64, accountUUID string) (*ExternalMember, error) {
	var m ExternalMember
	var roles []string
	err := s.pool.QueryRow(ctx, `
		SELECT a.uuid, COALESCE(NULLIF(tm.nickname,''), a.display_name), COALESCE(a.email,''), COALESCE(a.phone,''),
		       COALESCE(tm.employee_id,''), COALESCE(tm.title,''),
		       COALESCE(d.uuid::text, ''), tm.status, tm.updated_at,
		       COALESCE(
		         (SELECT array_agg(r.code) FROM role_assignments ra
		          JOIN roles r ON r.id = ra.role_id
		          WHERE ra.account_id = a.id AND ra.scope_kind IN ('tenant','workspace')
		            AND ra.tenant_id = tm.tenant_id AND ra.deleted_at IS NULL), '{}')
		FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		LEFT JOIN departments d ON d.id = tm.department_id
		WHERE a.uuid = $1 AND tm.tenant_id = $2 AND tm.deleted_at IS NULL`,
		accountUUID, tenantID).Scan(&m.AccountUUID, &m.DisplayName, &m.Email, &m.Phone,
		&m.EmployeeID, &m.Title, &m.DepartmentUUID, &m.Status, &m.UpdatedAt, &roles)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("member %s not found", accountUUID)
	}
	m.Roles = roles
	syncMemberIdentifiers(&m)
	return &m, nil
}

func (s *impl) CreateMember(ctx context.Context, tenantID int64, in CreateMemberInput) (*ExternalMember, error) {
	in.DepartmentUUID = strings.TrimSpace(in.DepartmentID)
	in.EmployeeID = strings.TrimSpace(in.ThirdUserID)
	phone := strings.TrimSpace(in.Phone)
	email := strings.TrimSpace(in.Email)
	if phone == "" && email == "" {
		return nil, apperr.ErrInvalidParams.Withf("phone or email required")
	}
	displayName := strings.TrimSpace(in.DisplayName)
	if displayName == "" {
		if phone != "" {
			displayName = phone
		} else {
			displayName = email
		}
	}

	departmentID, err := resolveMemberDepartmentID(ctx, s.pool, tenantID, in.DepartmentUUID)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// 与 Admin/F28 的 membership.Invite 共用同一把租户锁，确保成员新增/恢复
	// 在 (account_id, tenant_id) 唯一约束下保持串行。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('member_invite:tenant:' || $1::bigint::text, 0))`, tenantID); err != nil {
		return nil, err
	}

	var accountID int64
	var accountUUID string
	if phone != "" {
		_ = tx.QueryRow(ctx, `SELECT id, uuid FROM accounts WHERE phone=$1 AND deleted_at IS NULL`, phone).Scan(&accountID, &accountUUID)
	}
	if accountID == 0 && email != "" {
		_ = tx.QueryRow(ctx, `SELECT id, uuid FROM accounts WHERE LOWER(email)=LOWER($1) AND deleted_at IS NULL`, email).Scan(&accountID, &accountUUID)
	}
	if accountID == 0 {
		if err := tx.QueryRow(ctx, `
			INSERT INTO accounts (phone, email, display_name, status, locale, timezone)
			VALUES (NULLIF($1,''), NULLIF($2,''), $3, 'active', 'zh-CN', 'Asia/Shanghai')
			RETURNING id, uuid`, phone, email, displayName).Scan(&accountID, &accountUUID); err != nil {
			return nil, err
		}
	}

	var membershipID int64
	var existingSoftDeleted bool
	err = tx.QueryRow(ctx, `
		SELECT id, deleted_at IS NOT NULL
		  FROM tenant_memberships
		 WHERE account_id=$1 AND tenant_id=$2
		 FOR UPDATE`, accountID, tenantID).Scan(&membershipID, &existingSoftDeleted)
	switch {
	case err == nil && !existingSoftDeleted:
		return nil, apperr.ErrConflict.Withf("account is already a member of this tenant")
	case err == nil:
		// 软删 membership 在下方原地恢复。
	case errors.Is(err, pgx.ErrNoRows):
		membershipID = 0
	default:
		return nil, err
	}

	if membershipID > 0 {
		if _, err := tx.Exec(ctx, `
			UPDATE tenant_memberships
			   SET department_id=$3,
			       title=NULLIF($4,''),
			       employee_id=NULLIF($5,''),
			       nickname=NULLIF($6,''),
			       status='active',
			       joined_at=now(),
			       updated_at=now(),
			       deleted_at=NULL
			 WHERE id=$1 AND tenant_id=$2`,
			membershipID, tenantID, departmentID, in.Title, in.EmployeeID, displayName); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_member_positions WHERE membership_id=$1`, membershipID); err != nil {
			return nil, err
		}
	} else {
		if err := tx.QueryRow(ctx, `
			INSERT INTO tenant_memberships (account_id, tenant_id, department_id, title, employee_id, nickname, status, joined_at)
			VALUES ($1, $2, $3, NULLIF($4,''), NULLIF($5,''), NULLIF($6,''), 'active', now())
			RETURNING id`,
			accountID, tenantID, departmentID, in.Title, in.EmployeeID, displayName).Scan(&membershipID); err != nil {
			return nil, err
		}
	}

	if roleCode, err := externalAssignableRoleCode(in.RoleCode); err != nil {
		return nil, err
	} else if roleCode != "" {
		var roleID int64
		if err := tx.QueryRow(ctx, `SELECT id FROM roles WHERE scope_kind='tenant' AND code=$1 AND tenant_id=$2 AND deleted_at IS NULL LIMIT 1`,
			roleCode, tenantID).Scan(&roleID); err == nil {
			_, _ = tx.Exec(ctx, `INSERT INTO role_assignments (account_id, role_id, scope_kind, tenant_id) VALUES ($1,$2,'tenant',$3)`,
				accountID, roleID, tenantID)
		} else {
			return nil, apperr.ErrInvalidParams.Withf("role %s not found in this tenant", roleCode)
		}
	}

	if err := s.publishOrgEvent(ctx, tx, "org.member.created", tenantID, "member", accountUUID); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, accountID))
	return s.GetMember(ctx, tenantID, accountUUID)
}

func (s *impl) UpdateMember(ctx context.Context, tenantID int64, accountUUID string, in UpdateMemberInput) (*ExternalMember, error) {
	in.DepartmentUUID = trimOptionalIdentifier(in.DepartmentID)
	in.EmployeeID = trimOptionalIdentifier(in.ThirdUserID)
	var membershipID, accountID int64
	if err := s.pool.QueryRow(ctx, `
		SELECT tm.id, tm.account_id FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		WHERE a.uuid=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL`,
		accountUUID, tenantID).Scan(&membershipID, &accountID); err != nil {
		return nil, apperr.ErrNotFound.Withf("member %s not found", accountUUID)
	}

	sets := []string{}
	args := []any{}
	idx := 0
	requestedStatus := ""
	addArg := func(v any) string { idx++; args = append(args, v); return fmt.Sprintf("$%d", idx) }

	if in.DisplayName != nil {
		sets = append(sets, "nickname=NULLIF("+addArg(strings.TrimSpace(*in.DisplayName))+"::text, '')")
	}
	if in.Title != nil {
		sets = append(sets, "title=NULLIF("+addArg(*in.Title)+"::text, '')")
	}
	if in.EmployeeID != nil {
		sets = append(sets, "employee_id=NULLIF("+addArg(*in.EmployeeID)+"::text, '')")
	}
	if in.DepartmentUUID != nil {
		if *in.DepartmentUUID == "" {
			return nil, apperr.ErrInvalidParams.Withf("department_id cannot be empty")
		} else {
			departmentID, err := resolveMemberDepartmentID(ctx, s.pool, tenantID, *in.DepartmentUUID)
			if err != nil {
				return nil, err
			}
			sets = append(sets, "department_id="+addArg(departmentID))
		}
	}
	if in.Status != nil && *in.Status != "" {
		st := *in.Status
		if st == "disabled" {
			st = "suspended"
		}
		requestedStatus = st
		sets = append(sets, "status="+addArg(st))
	}
	if len(sets) == 0 {
		return s.GetMember(ctx, tenantID, accountUUID)
	}
	sets = append(sets, "updated_at=now()")
	midP := addArg(membershipID)
	tidP := addArg(tenantID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if requestedStatus != "" && requestedStatus != "active" {
		if err := tenantadminguard.EnsureMemberStatusChangeAllowed(
			ctx, tx, tenantID, 0, accountID, requestedStatus,
		); err != nil {
			return nil, err
		}
	}
	tag, err := tx.Exec(ctx, `UPDATE tenant_memberships SET `+strings.Join(sets, ",")+` WHERE id=`+midP+` AND tenant_id=`+tidP+` AND deleted_at IS NULL`, args...)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != 1 {
		return nil, apperr.ErrNotFound.Withf("member %s not found", accountUUID)
	}
	if err := s.publishOrgEvent(ctx, tx, "org.member.updated", tenantID, "member", accountUUID); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, accountID))
	return s.GetMember(ctx, tenantID, accountUUID)
}

func (s *impl) DeleteMember(ctx context.Context, tenantID int64, accountUUID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var membershipID, accountID int64
	if err := tx.QueryRow(ctx, `
		SELECT tm.id, tm.account_id FROM tenant_memberships tm
		JOIN accounts a ON a.id = tm.account_id
		WHERE a.uuid=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL`,
		accountUUID, tenantID).Scan(&membershipID, &accountID); err != nil {
		return apperr.ErrNotFound.Withf("member %s not found", accountUUID)
	}

	if err := tenantadminguard.EnsureMemberRemovalAllowed(
		ctx, tx, tenantID, 0, accountID,
	); err != nil {
		return err
	}

	tag, err := tx.Exec(ctx, `
		UPDATE tenant_memberships
		   SET deleted_at=now(), status='left', updated_at=now()
		 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		membershipID, tenantID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return apperr.ErrNotFound.Withf("member %s not found", accountUUID)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE role_assignments SET deleted_at=now()
		WHERE account_id=$1 AND tenant_id=$2 AND scope_kind IN ('tenant','workspace') AND deleted_at IS NULL`,
		accountID, tenantID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+strconv.FormatInt(accountID, 10)); err != nil {
		return err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.member.deleted", tenantID, "member", accountUUID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.notifyConfigChange(ctx, fmt.Sprintf("membership:%d:%d", tenantID, accountID))
	return nil
}

// ── Positions ──

func (s *impl) ListPositions(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalPosition], error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	fetch := limit + 1
	args := []any{tenantID}
	where := `p.tenant_id = $1`
	if updatedSince != nil {
		args = append(args, *updatedSince)
		where += fmt.Sprintf(` AND p.updated_at >= $%d`, len(args))
	} else {
		where += ` AND p.deleted_at IS NULL`
	}
	if cursor != "" {
		ct, cu, err := decodeCursor(cursor)
		if err != nil {
			return nil, err
		}
		args = append(args, ct, cu)
		where += fmt.Sprintf(` AND (p.updated_at, p.uuid::text) > ($%d, $%d)`, len(args)-1, len(args))
	}
	args = append(args, fetch)

	rows, err := s.pool.Query(ctx, `
		SELECT p.uuid, p.name, COALESCE(p.description,''), p.sort_order, p.is_system, p.metadata,
		       (SELECT count(*) FROM tenant_member_positions mp WHERE mp.position_id=p.id),
		       (SELECT count(*) FROM tenant_agent_positions ap WHERE ap.position_id=p.id),
		       p.updated_at, p.deleted_at IS NOT NULL AS is_deleted
		FROM tenant_positions p
		WHERE `+where+`
		ORDER BY p.updated_at, p.uuid
		LIMIT $`+fmt.Sprint(len(args)), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := []ExternalPosition{}
	for rows.Next() {
		var p ExternalPosition
		var meta []byte
		var isDeleted bool
		if err := rows.Scan(&p.UUID, &p.Name, &p.Description, &p.SortOrder, &p.IsSystem, &meta,
			&p.MemberCount, &p.AgentCount, &p.UpdatedAt, &isDeleted); err != nil {
			return nil, err
		}
		if len(meta) > 0 {
			var m map[string]any
			_ = json.Unmarshal(meta, &m)
			if ec, ok := m["external_code"].(string); ok {
				p.ExternalCode = ec
			}
			p.Metadata = m
		}
		p.Status = "active"
		if isDeleted {
			p.Status = "deleted"
		}
		syncPositionIdentifiers(&p)
		items = append(items, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	var nextCursor string
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		nextCursor = encodeCursor(last.UpdatedAt, last.UUID)
	}
	return &CursorPage[ExternalPosition]{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *impl) GetPosition(ctx context.Context, tenantID int64, uuid string) (*ExternalPosition, error) {
	var p ExternalPosition
	var meta []byte
	err := s.pool.QueryRow(ctx, `
		SELECT p.uuid, p.name, COALESCE(p.description,''), p.sort_order, p.is_system, p.metadata,
		       (SELECT count(*) FROM tenant_member_positions mp WHERE mp.position_id=p.id),
		       (SELECT count(*) FROM tenant_agent_positions ap WHERE ap.position_id=p.id),
		       p.updated_at
		FROM tenant_positions p
		WHERE p.uuid=$1 AND p.tenant_id=$2 AND p.deleted_at IS NULL`,
		uuid, tenantID).Scan(&p.UUID, &p.Name, &p.Description, &p.SortOrder, &p.IsSystem, &meta,
		&p.MemberCount, &p.AgentCount, &p.UpdatedAt)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("position %s not found", uuid)
	}
	p.Status = "active"
	if len(meta) > 0 {
		var m map[string]any
		_ = json.Unmarshal(meta, &m)
		if ec, ok := m["external_code"].(string); ok {
			p.ExternalCode = ec
		}
		p.Metadata = m
	}
	syncPositionIdentifiers(&p)
	return &p, nil
}

func (s *impl) CreatePosition(ctx context.Context, tenantID int64, in CreatePositionInput) (*ExternalPosition, error) {
	if strings.TrimSpace(in.Name) == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	in.ExternalCode = strings.TrimSpace(in.ThirdPositionID)
	meta := in.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	if in.ExternalCode != "" {
		meta["external_code"] = in.ExternalCode
	}
	metaRaw, _ := json.Marshal(meta)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var uuid string
	if err := tx.QueryRow(ctx, `
		INSERT INTO tenant_positions (tenant_id, name, description, sort_order, metadata)
		VALUES ($1, $2, NULLIF($3,''), $4, $5::jsonb)
		RETURNING uuid`,
		tenantID, in.Name, in.Description, in.SortOrder, string(metaRaw)).Scan(&uuid); err != nil {
		if strings.Contains(err.Error(), "uq_tenant_positions_external_code") {
			return nil, apperr.ErrConflict.Withf("third_position_id %s already exists in this tenant", in.ExternalCode)
		}
		return nil, err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.position.created", tenantID, "position", uuid); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.GetPosition(ctx, tenantID, uuid)
}

func (s *impl) UpdatePosition(ctx context.Context, tenantID int64, uuid string, in UpdatePositionInput) (*ExternalPosition, error) {
	in.ExternalCode = trimOptionalIdentifier(in.ThirdPositionID)
	var id int64
	var curMeta []byte
	var curName, curDesc string
	var curSort int
	if err := s.pool.QueryRow(ctx, `SELECT id, name, COALESCE(description,''), sort_order, metadata FROM tenant_positions WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID).Scan(&id, &curName, &curDesc, &curSort, &curMeta); err != nil {
		return nil, apperr.ErrNotFound.Withf("position %s not found", uuid)
	}

	name := curName
	desc := curDesc
	sortOrder := curSort
	var metadata map[string]any
	if len(curMeta) > 0 {
		_ = json.Unmarshal(curMeta, &metadata)
	}
	if metadata == nil {
		metadata = map[string]any{}
	}

	if in.Name != nil && *in.Name != "" {
		name = *in.Name
	}
	if in.Description != nil {
		desc = *in.Description
	}
	if in.SortOrder != nil {
		sortOrder = *in.SortOrder
	}
	if in.ExternalCode != nil {
		if *in.ExternalCode == "" {
			delete(metadata, "external_code")
		} else {
			metadata["external_code"] = *in.ExternalCode
		}
	}
	if in.Metadata != nil {
		for k, v := range *in.Metadata {
			metadata[k] = v
		}
	}

	metaRaw, _ := json.Marshal(metadata)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		UPDATE tenant_positions SET name=$1, description=NULLIF($2,''), sort_order=$3, metadata=$4::jsonb, updated_at=now()
		WHERE id=$5 AND tenant_id=$6`,
		name, desc, sortOrder, string(metaRaw), id, tenantID); err != nil {
		if strings.Contains(err.Error(), "uq_tenant_positions_external_code") {
			return nil, apperr.ErrConflict.Withf("third_position_id already exists in this tenant")
		}
		return nil, err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.position.updated", tenantID, "position", uuid); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.GetPosition(ctx, tenantID, uuid)
}

func (s *impl) DeletePosition(ctx context.Context, tenantID int64, uuid string) error {
	var id int64
	if err := s.pool.QueryRow(ctx, `SELECT id FROM tenant_positions WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID).Scan(&id); err != nil {
		return apperr.ErrNotFound.Withf("position %s not found", uuid)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE tenant_positions SET deleted_at=now(), updated_at=now() WHERE id=$1 AND tenant_id=$2`, id, tenantID); err != nil {
		return err
	}
	if err := s.publishOrgEvent(ctx, tx, "org.position.deleted", tenantID, "position", uuid); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *impl) notifyConfigChange(ctx context.Context, payload string) {
	_, _ = s.pool.Exec(ctx, `SELECT pg_notify('config_change', $1)`, payload)
}
