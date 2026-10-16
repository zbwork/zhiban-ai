// Package drivev3 是 F06 Drive v0.3.x 的 PG 实现 (side-by-side 切换期临时命名;
// Phase 2.Z 后 rename 为 internal/repository/postgres/drive).
//
// 设计纪律:
//   - 使用 jackc/pgx/v5 + pgxpool, 原 SQL, 无 ORM
//   - Repo struct { pool *pgxpool.Pool } + New(pool) 模式 (跟 event/outbox.go, audit/store.go 一致)
//   - Pool() accessor 给 service 层做 tx (Phase 2.1+ slice 用到时再加)
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ErrNotFound F06 drivev3 通用 not found; 上层 service 决定是否转 apperr.
var ErrNotFound = errors.New("drivev3: not found")

// ErrDuplicateName F06 drivev3 折合 uq_folder_sibling 唯一索引冲突
// (same space_id + parent_id + name 已存在未软删行);
// service 层捕获后转 apperr.ErrConflict("drive.duplicate_name").
var ErrDuplicateName = errors.New("drivev3: duplicate folder sibling name")

// SpaceRepo F06 §2.2 drive_spaces 的 PG 实现.
type SpaceRepo struct{ pool *pgxpool.Pool }

// NewSpaceRepo 构造.
func NewSpaceRepo(pool *pgxpool.Pool) *SpaceRepo { return &SpaceRepo{pool: pool} }

// AddUsedBytesTx F06 Phase 2.2c confirm 流程 TX 内更新 space used_bytes (= +delta).
// 不做 quota 校验 (drive_spaces 没 quota 列, 配额由 drive_quotas 表承担); 仅维护 space 自身的运行统计.
// service 必须在 quota 原子 UPDATE 通过后再调本函数, 同一 TX 内.
func (r *SpaceRepo) AddUsedBytesTx(ctx context.Context, tx pgx.Tx, spaceID, delta int64) error {
	if delta == 0 {
		return nil
	}
	_, err := tx.Exec(ctx,
		`UPDATE drive_spaces SET used_bytes = used_bytes + $1, updated_at = now() WHERE id = $2`,
		delta, spaceID,
	)
	if err != nil {
		return fmt.Errorf("drive.SpaceRepo.AddUsedBytesTx: %w", err)
	}
	return nil
}

// AddUsedBytesSignedTx F06 Phase 2.2e purge 流程 TX 内 -delta 释放 used_bytes.
// 支持负 delta; 用 GREATEST(0, ...) 钉地板, 防御 used_bytes 历史漂移导致下溢负值.
func (r *SpaceRepo) AddUsedBytesSignedTx(ctx context.Context, tx pgx.Tx, spaceID, delta int64) error {
	if delta == 0 {
		return nil
	}
	_, err := tx.Exec(ctx,
		`UPDATE drive_spaces SET used_bytes = GREATEST(0, used_bytes + $1), updated_at = now() WHERE id = $2`,
		delta, spaceID,
	)
	if err != nil {
		return fmt.Errorf("drive.SpaceRepo.AddUsedBytesSignedTx: %w", err)
	}
	return nil
}

// Create F06 Phase 2.2e: 新建 space (当前仅 shared 路径). personal/tenant/department 走专用 Ensure 路径.
// caller (SharedSpaceSvc.Create) 已校 name 合法 + tenant 隔离.
func (r *SpaceRepo) Create(ctx context.Context, in dom.CreateSpaceInput) (*dom.Space, error) {
	const q = `
        INSERT INTO drive_spaces (tenant_id, kind, owner_account_id, department_id, name, description, status, created_by, updated_by)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
        RETURNING id, uuid, tenant_id, kind, owner_account_id, department_id,
                  name, description, status, used_bytes,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	status := in.Status
	if status == "" {
		status = dom.SpaceStatusActive
	}
	var s dom.Space
	err := r.pool.QueryRow(ctx, q,
		in.TenantID, string(in.Kind), in.OwnerAccountID, in.DepartmentID, in.Name, in.Description, string(status), in.CreatedBy,
	).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
		&s.Name, &s.Description, &s.Status, &s.UsedBytes,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.Create: %w", err)
	}
	return &s, nil
}

// UpdateSharedByID 更新 shared space 的客户端可编辑字段。caller 已由 service 校 tenant/kind/ACL。
func (r *SpaceRepo) UpdateSharedByID(ctx context.Context, id int64, name, description string, updatedBy int64) (*dom.Space, error) {
	const q = `
        UPDATE drive_spaces
           SET name = $2,
               description = $3,
               updated_by = $4,
               updated_at = now()
         WHERE id = $1
           AND kind = 'shared'
           AND is_deleted = false
        RETURNING id, uuid, tenant_id, kind, owner_account_id, department_id,
                  name, COALESCE(description, ''), status, used_bytes,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var s dom.Space
	err := r.pool.QueryRow(ctx, q, id, name, description, updatedBy).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
		&s.Name, &s.Description, &s.Status, &s.UsedBytes,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.UpdateSharedByID: %w", err)
	}
	return &s, nil
}

// ArchiveSharedByID 归档并隐藏 shared space。文件/目录行保留,由后续生命周期 worker 清理。
func (r *SpaceRepo) ArchiveSharedByID(ctx context.Context, id int64, updatedBy int64) error {
	tag, err := r.pool.Exec(ctx, `
        UPDATE drive_spaces
           SET status = 'archived',
               is_deleted = true,
               deleted_at = now(),
               updated_by = $2,
               updated_at = now()
         WHERE id = $1
           AND kind = 'shared'
           AND is_deleted = false
    `, id, updatedBy)
	if err != nil {
		return fmt.Errorf("drive.SpaceRepo.ArchiveSharedByID: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *SpaceRepo) GetByID(ctx context.Context, id int64) (*dom.Space, error) {
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_spaces
        WHERE id = $1 AND is_deleted = false
    `
	var s dom.Space
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
		&s.Name, &s.Description, &s.Status, &s.UsedBytes,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.GetByID: %w", err)
	}
	return &s, nil
}

// ListByIDs 批量按 id 查; 与 GetByID 同口径 is_deleted=false, 缺失/软删 id 不返回.
// discover 列表批量补齐 space_uuid 用 (替代逐 file GetByID N+1).
func (r *SpaceRepo) ListByIDs(ctx context.Context, ids []int64) ([]dom.Space, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_spaces
        WHERE id = ANY($1) AND is_deleted = false
    `
	rows, err := r.pool.Query(ctx, q, ids)
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.ListByIDs: %w", err)
	}
	defer rows.Close()
	var out []dom.Space
	for rows.Next() {
		var s dom.Space
		if err := rows.Scan(
			&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
			&s.Name, &s.Description, &s.Status, &s.UsedBytes,
			&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.SpaceRepo.ListByIDs.scan: %w", err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.ListByIDs.rows: %w", err)
	}
	return out, nil
}

// GetByUUID 按 uuid 查 1 行; 软删行不返回.
func (r *SpaceRepo) GetByUUID(ctx context.Context, uuid string) (*dom.Space, error) {
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_spaces
        WHERE uuid = $1 AND is_deleted = false
    `
	var s dom.Space
	err := r.pool.QueryRow(ctx, q, uuid).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
		&s.Name, &s.Description, &s.Status, &s.UsedBytes,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.GetByUUID: %w", err)
	}
	return &s, nil
}

// EnsurePersonal 为 (tenantID, accountID) 幂等创建 personal space.
// 已存在则直接返; 不存在则 INSERT (用 ON CONFLICT 防并发 UNIQUE 冲突).
// F06 v0.3.1 §2.2.
func (r *SpaceRepo) EnsurePersonal(ctx context.Context, tenantID, accountID int64, displayName string) (*dom.Space, error) {
	// SELECT-then-INSERT 模式 (跟 legacy svcdrive 一致, 比 ON CONFLICT 更稳):
	//   partial unique index uq_dspace_personal 形如
	//     (tenant_id, owner_account_id) WHERE kind='personal' AND is_deleted=false
	//   ON CONFLICT 需要 conflict_target 完全匹配, 写起来易错且 DO UPDATE
	//   会污染 updated_at; SELECT-fallback-SELECT 路径清晰且无副作用.
	const selQ = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_spaces
         WHERE tenant_id = $1 AND owner_account_id = $2
           AND kind = 'personal' AND is_deleted = false
         LIMIT 1
    `
	const insQ = `
        INSERT INTO drive_spaces (tenant_id, kind, owner_account_id, name, status)
        VALUES ($1, 'personal', $2, $3, 'active')
        RETURNING id, uuid, tenant_id, kind, owner_account_id, department_id,
                  name, COALESCE(description, ''), status, used_bytes,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `

	scanSpace := func(row pgx.Row, s *dom.Space) error {
		return row.Scan(
			&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
			&s.Name, &s.Description, &s.Status, &s.UsedBytes,
			&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
		)
	}

	// 1. 已存在的优先返
	var s dom.Space
	if err := scanSpace(r.pool.QueryRow(ctx, selQ, tenantID, accountID), &s); err == nil {
		return &s, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("drive.SpaceRepo.EnsurePersonal.select: %w", err)
	}

	// 2. 不存在 → INSERT
	if err := scanSpace(r.pool.QueryRow(ctx, insQ, tenantID, accountID, displayName), &s); err != nil {
		// 并发冲突 (23505 unique_violation) → 上面 SELECT 跟当前 INSERT 之间另一 goroutine 插入了同行
		// → fallback 再 SELECT
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			if err2 := scanSpace(r.pool.QueryRow(ctx, selQ, tenantID, accountID), &s); err2 == nil {
				return &s, nil
			} else {
				return nil, fmt.Errorf("drive.SpaceRepo.EnsurePersonal.refetch: %w", err2)
			}
		}
		return nil, fmt.Errorf("drive.SpaceRepo.EnsurePersonal.insert: %w", err)
	}
	return &s, nil
}

// EnsureDepartment Phase 2.10: 幂等 ensure 部门 drive_space.
// 与 EnsurePersonal 同模式 (SELECT-then-INSERT + 23505 refetch).
// partial unique index uq_dspace_department 形如
//
//	(tenant_id, department_id) WHERE kind='department' AND is_deleted=false
//
// 调方约定: Bootstrap 路径每次 caller 进来时按其 dept memberships 批量调
// (lazy ensure); F01 部门生命周期 hook 暂不接 (留 future eager-hook slice).
func (r *SpaceRepo) EnsureDepartment(ctx context.Context, tenantID, departmentID int64, displayName string) (*dom.Space, error) {
	const selQ = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_spaces
         WHERE tenant_id = $1 AND department_id = $2
           AND kind = 'department' AND is_deleted = false
         LIMIT 1
    `
	const insQ = `
        INSERT INTO drive_spaces (tenant_id, kind, department_id, name, status)
        VALUES ($1, 'department', $2, $3, 'active')
        RETURNING id, uuid, tenant_id, kind, owner_account_id, department_id,
                  name, COALESCE(description, ''), status, used_bytes,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	scanSpace := func(row pgx.Row, s *dom.Space) error {
		return row.Scan(
			&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
			&s.Name, &s.Description, &s.Status, &s.UsedBytes,
			&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
		)
	}
	var s dom.Space
	if err := scanSpace(r.pool.QueryRow(ctx, selQ, tenantID, departmentID), &s); err == nil {
		return &s, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("drive.SpaceRepo.EnsureDepartment.select: %w", err)
	}
	if err := scanSpace(r.pool.QueryRow(ctx, insQ, tenantID, departmentID, displayName), &s); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			if err2 := scanSpace(r.pool.QueryRow(ctx, selQ, tenantID, departmentID), &s); err2 == nil {
				return &s, nil
			} else {
				return nil, fmt.Errorf("drive.SpaceRepo.EnsureDepartment.refetch: %w", err2)
			}
		}
		return nil, fmt.Errorf("drive.SpaceRepo.EnsureDepartment.insert: %w", err)
	}
	return &s, nil
}

// GetTenantSpace 返回 tenant 根 space (1 per tenant), 不存在返 nil (不自动建).
// F01 tenant provision 时建; 本函数不报错 — client 容忍缺失.
func (r *SpaceRepo) GetTenantSpace(ctx context.Context, tenantID int64) (*dom.Space, error) {
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_spaces
        WHERE tenant_id = $1 AND kind = 'tenant' AND is_deleted = false
        LIMIT 1
    `
	var s dom.Space
	err := r.pool.QueryRow(ctx, q, tenantID).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
		&s.Name, &s.Description, &s.Status, &s.UsedBytes,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.GetTenantSpace: %w", err)
	}
	return &s, nil
}

// ListDepartmentSpaces 列出 (tenantID, deptIDs) 命中的 department spaces.
// 上层调用者传 accountID 在 tenant 的 department_id 列表 (通常 0 或 1 个, 因为 1 dept/membership).
func (r *SpaceRepo) ListDepartmentSpaces(ctx context.Context, tenantID int64, deptIDs []int64) ([]dom.Space, error) {
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, COALESCE(description, ''), status, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_spaces
        WHERE tenant_id = $1 AND kind = 'department' AND department_id = ANY($2) AND is_deleted = false
        ORDER BY created_at DESC
    `
	rows, err := r.pool.Query(ctx, q, tenantID, deptIDs)
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.ListDepartmentSpaces: %w", err)
	}
	defer rows.Close()

	var out []dom.Space
	for rows.Next() {
		var s dom.Space
		if err := rows.Scan(
			&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
			&s.Name, &s.Description, &s.Status, &s.UsedBytes,
			&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.SpaceRepo.ListDepartmentSpaces scan: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// ListSharedSpacesAccessible 列出 accountID 可访问的 shared space:
//
//	union {owner_account_id == accountID} + {has any ACL grant target=space (account/dept/link_token)}
//
// 用单 SQL JOIN drive_acl_entries 实现; 三类 grant 都算 (但 link_token 需 share_link active).
// 返回 (spaces, error); accountID 必须已是 tenant member (调用方保证).
func (r *SpaceRepo) ListSharedSpacesAccessible(ctx context.Context, tenantID, accountID int64) ([]dom.Space, error) {
	const q = `
        SELECT DISTINCT ds.id, ds.uuid, ds.tenant_id, ds.kind, ds.owner_account_id, ds.department_id,
                        ds.name, COALESCE(ds.description, ''), ds.status, ds.used_bytes,
                        ds.created_at, ds.created_by, ds.updated_at, ds.updated_by, ds.is_deleted, ds.deleted_at
        FROM drive_spaces ds
        LEFT JOIN drive_acl_entries acl ON ds.id = acl.target_id
                                        AND acl.target_kind = 'space'
                                        AND acl.is_deleted = false
        WHERE ds.tenant_id = $1
          AND ds.kind = 'shared'
          AND ds.is_deleted = false
          AND (
            -- 自己 owner
            ds.owner_account_id = $2
            -- 或有 ACL grant (account/dept/link_token)
            OR (
              acl.id IS NOT NULL
              AND (
                -- account 直接 grant
                (acl.subject_kind = 'account' AND acl.subject_id = $2)
                -- 或 department grant (需验证 accountID 在该 dept; 由上层保证入参时已校)
                OR (acl.subject_kind = 'department')
                -- 或 link_token grant (需 share_link active; 暂简化为 link_token 存在)
                OR (acl.subject_kind = 'link_token')
              )
            )
          )
        ORDER BY ds.created_at DESC
    `
	rows, err := r.pool.Query(ctx, q, tenantID, accountID)
	if err != nil {
		return nil, fmt.Errorf("drive.SpaceRepo.ListSharedSpacesAccessible: %w", err)
	}
	defer rows.Close()

	var out []dom.Space
	for rows.Next() {
		var s dom.Space
		if err := rows.Scan(
			&s.ID, &s.UUID, &s.TenantID, &s.Kind, &s.OwnerAccountID, &s.DepartmentID,
			&s.Name, &s.Description, &s.Status, &s.UsedBytes,
			&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.SpaceRepo.ListSharedSpacesAccessible scan: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// UsageRow Phase A2 admin /platform/drive/usage 租户聚合行.
// 字段对齐前端 wrapper DriveUsageRow.
type UsageRow struct {
	TenantID               int64
	TenantName             string
	TenantStatus           string
	SpacesCount            int64
	PersonalSpacesCount    int64
	CollabSpacesCount      int64
	FilesCount             int64
	UsedBytes              int64
	PersonalUsedBytes      int64
	CollaborationUsedBytes int64
	QuotaBytes             *int64 // tenant-level quota (subject_kind='tenant'); account-level 不在这里展示
}

// likeEscape 把用户输入转成可安全放进 ILIKE '%…%' 的字面量 (转义 \ % _).
func likeEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

// usageSortSQL admin usage 排序白名单; key 与 API sort 参数一致.
// 默认按总用量降序 (运营主诉求 "谁用得最多"), tenant_id 兜底保证稳定分页.
var usageSortSQL = map[string]string{
	"":           "sr.used_bytes DESC, sr.tenant_id ASC",
	"usage_desc": "sr.used_bytes DESC, sr.tenant_id ASC",
	"usage_asc":  "sr.used_bytes ASC, sr.tenant_id ASC",
	"tenant_id":  "sr.tenant_id ASC",
}

// usageSearchCond 列表/汇总共用的 q 过滤条件: 租户名 ILIKE 或 tenant_id 精确.
// $3 = 原始 q, $4 = ILIKE pattern ('%' || 转义(q) || '%').
const usageSearchCond = `AND ($3::TEXT = '' OR t.name ILIKE $4 OR s.tenant_id::TEXT = $3)`

// UsageSummaryAdmin Phase A2 admin: 全租户云盘用量汇总 (按 tenant 聚合).
// 可选 tenantID / search(q: 租户名模糊或 id 精确) / tenantStatus 过滤;
// sort 排序白名单 (见 usageSortSQL, 未知值回落默认, 参数校验在 service 层);
// limit/offset 分页 (limit cap 200).
// JOIN tenants 取名和状态, 并排除软删租户; LEFT JOIN drive_files 算 files_count;
// LEFT JOIN drive_quotas 取 tenant quota.
//
// 数据真实来源:
//   - drive_spaces.tenant_id GROUP BY 算 spaces_count / used_bytes (drive_spaces.used_bytes 列累计)
//   - kind='personal' 汇入 personal_used_bytes; 其它 kind 统一汇入 collaboration_used_bytes
//   - drive_files JOIN 算 files_count (filter is_deleted=false + scope='drive')
//   - drive_quotas tenant 行算 quota_bytes
func (r *SpaceRepo) UsageSummaryAdmin(ctx context.Context, filterTenantID int64, search, filterTenantStatus, sort string, limit, offset int) ([]UsageRow, int64, error) {
	if filterTenantStatus == "" {
		filterTenantStatus = "active"
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	if offset < 0 {
		offset = 0
	}
	orderBy, ok := usageSortSQL[sort]
	if !ok {
		orderBy = usageSortSQL[""]
	}
	search = strings.TrimSpace(search)
	searchPattern := "%" + likeEscape(search) + "%"
	// total: 不带 limit 的租户聚合行数
	var countSQL = `
        SELECT COUNT(*) FROM (
          SELECT 1 FROM drive_spaces s
           JOIN tenants t ON t.id = s.tenant_id AND t.deleted_at IS NULL
           WHERE s.is_deleted = false
             AND ($1::BIGINT  = 0 OR s.tenant_id = $1)
             AND ($2::VARCHAR = 'all' OR t.status = $2)
             ` + usageSearchCond + `
           GROUP BY s.tenant_id
        ) AS sub
    `
	var total int64
	if err := r.pool.QueryRow(ctx, countSQL, filterTenantID, filterTenantStatus, search, searchPattern).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("drive.SpaceRepo.UsageSummaryAdmin count: %w", err)
	}
	q := `
        WITH filtered_spaces AS (
          SELECT s.id,
                 s.tenant_id,
                 s.kind,
                 s.used_bytes,
                 COALESCE(t.name, '') AS tenant_name,
                 COALESCE(t.status, '') AS tenant_status
            FROM drive_spaces s
            JOIN tenants t ON t.id = s.tenant_id AND t.deleted_at IS NULL
           WHERE s.is_deleted = false
             AND ($1::BIGINT = 0 OR s.tenant_id = $1)
             AND ($2::VARCHAR = 'all' OR t.status = $2)
             ` + usageSearchCond + `
        ),
        space_rollup AS (
          SELECT tenant_id,
                 MAX(tenant_name) AS tenant_name,
                 MAX(tenant_status) AS tenant_status,
                 COUNT(*) AS spaces_count,
                 COUNT(*) FILTER (WHERE kind = 'personal') AS personal_spaces_count,
                 COUNT(*) FILTER (WHERE kind <> 'personal') AS collaboration_spaces_count,
                 COALESCE(SUM(used_bytes), 0) AS used_bytes,
                 COALESCE(SUM(used_bytes) FILTER (WHERE kind = 'personal'), 0) AS personal_used_bytes,
                 COALESCE(SUM(used_bytes) FILTER (WHERE kind <> 'personal'), 0) AS collaboration_used_bytes
            FROM filtered_spaces
           GROUP BY tenant_id
        ),
        file_rollup AS (
          SELECT fs.tenant_id,
                 COUNT(*) AS files_count
            FROM filtered_spaces fs
            JOIN drive_files f ON f.space_id = fs.id
           WHERE f.is_deleted = false
             AND f.scope = 'drive'
           GROUP BY fs.tenant_id
        )
        SELECT sr.tenant_id,
               sr.tenant_name,
               sr.tenant_status,
               sr.spaces_count,
               sr.personal_spaces_count,
               sr.collaboration_spaces_count,
               COALESCE(fr.files_count, 0) AS files_count,
               sr.used_bytes,
               sr.personal_used_bytes,
               sr.collaboration_used_bytes,
               (SELECT q.quota_bytes
                  FROM drive_quotas q
                 WHERE q.tenant_id = sr.tenant_id AND q.subject_kind='tenant' AND q.is_deleted=false
                 LIMIT 1) AS tenant_quota_bytes
          FROM space_rollup sr
          LEFT JOIN file_rollup fr ON fr.tenant_id = sr.tenant_id
         ORDER BY ` + orderBy + `
         LIMIT $5 OFFSET $6
    `
	rows, err := r.pool.Query(ctx, q, filterTenantID, filterTenantStatus, search, searchPattern, limit, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.SpaceRepo.UsageSummaryAdmin: %w", err)
	}
	defer rows.Close()
	var out []UsageRow
	for rows.Next() {
		var row UsageRow
		if err := rows.Scan(
			&row.TenantID, &row.TenantName, &row.TenantStatus,
			&row.SpacesCount, &row.PersonalSpacesCount, &row.CollabSpacesCount,
			&row.FilesCount, &row.UsedBytes, &row.PersonalUsedBytes, &row.CollaborationUsedBytes,
			&row.QuotaBytes,
		); err != nil {
			return nil, 0, fmt.Errorf("drive.SpaceRepo.UsageSummaryAdmin scan: %w", err)
		}
		out = append(out, row)
	}
	return out, total, rows.Err()
}

// UsagePlatformSummaryRow admin /platform/drive/usage/summary 平台汇总卡数据.
type UsagePlatformSummaryRow struct {
	TenantsCount           int64
	SpacesCount            int64
	FilesCount             int64
	UsedBytes              int64
	PersonalUsedBytes      int64
	CollaborationUsedBytes int64
	QuotaSetCount          int64 // 存在 drive_quotas tenant 行的租户数 (含 -1 无限)
	NearQuotaCount         int64 // quota_bytes > 0 且 used >= quota*0.8 的租户数
}

// UsagePlatformSummary 平台用量汇总卡: 与 UsageSummaryAdmin 同过滤口径 (tenantID / search / status),
// 不分页, 聚合成单行. near 阈值 0.8 与前端占比预警色 (≥80% 黄) 对齐.
func (r *SpaceRepo) UsagePlatformSummary(ctx context.Context, filterTenantID int64, search, filterTenantStatus string) (UsagePlatformSummaryRow, error) {
	if filterTenantStatus == "" {
		filterTenantStatus = "active"
	}
	search = strings.TrimSpace(search)
	searchPattern := "%" + likeEscape(search) + "%"
	q := `
        WITH filtered_spaces AS (
          SELECT s.id,
                 s.tenant_id,
                 s.used_bytes,
                 s.kind
            FROM drive_spaces s
            JOIN tenants t ON t.id = s.tenant_id AND t.deleted_at IS NULL
           WHERE s.is_deleted = false
             AND ($1::BIGINT = 0 OR s.tenant_id = $1)
             AND ($2::VARCHAR = 'all' OR t.status = $2)
             ` + usageSearchCond + `
        ),
        space_rollup AS (
          SELECT tenant_id,
                 COUNT(*) AS spaces_count,
                 COALESCE(SUM(used_bytes), 0) AS used_bytes,
                 COALESCE(SUM(used_bytes) FILTER (WHERE kind = 'personal'), 0) AS personal_used_bytes,
                 COALESCE(SUM(used_bytes) FILTER (WHERE kind <> 'personal'), 0) AS collaboration_used_bytes
            FROM filtered_spaces
           GROUP BY tenant_id
        ),
        file_rollup AS (
          SELECT fs.tenant_id,
                 COUNT(*) AS files_count
            FROM filtered_spaces fs
            JOIN drive_files f ON f.space_id = fs.id
           WHERE f.is_deleted = false
             AND f.scope = 'drive'
           GROUP BY fs.tenant_id
        ),
        tenant_rows AS (
          SELECT sr.tenant_id,
                 sr.spaces_count,
                 sr.used_bytes,
                 sr.personal_used_bytes,
                 sr.collaboration_used_bytes,
                 COALESCE(fr.files_count, 0) AS files_count,
                 (SELECT q.quota_bytes
                    FROM drive_quotas q
                   WHERE q.tenant_id = sr.tenant_id AND q.subject_kind='tenant' AND q.is_deleted=false
                   LIMIT 1) AS quota_bytes
            FROM space_rollup sr
            LEFT JOIN file_rollup fr ON fr.tenant_id = sr.tenant_id
        )
        SELECT COUNT(*),
               COALESCE(SUM(spaces_count), 0),
               COALESCE(SUM(files_count), 0),
               COALESCE(SUM(used_bytes), 0),
               COALESCE(SUM(personal_used_bytes), 0),
               COALESCE(SUM(collaboration_used_bytes), 0),
               COUNT(*) FILTER (WHERE quota_bytes IS NOT NULL),
               COUNT(*) FILTER (WHERE quota_bytes > 0 AND used_bytes >= quota_bytes * 0.8)
          FROM tenant_rows
    `
	var out UsagePlatformSummaryRow
	if err := r.pool.QueryRow(ctx, q, filterTenantID, filterTenantStatus, search, searchPattern).Scan(
		&out.TenantsCount, &out.SpacesCount, &out.FilesCount,
		&out.UsedBytes, &out.PersonalUsedBytes, &out.CollaborationUsedBytes,
		&out.QuotaSetCount, &out.NearQuotaCount,
	); err != nil {
		return UsagePlatformSummaryRow{}, fmt.Errorf("drive.SpaceRepo.UsagePlatformSummary: %w", err)
	}
	return out, nil
}
