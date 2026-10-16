package rbac

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	tenantadminguard "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenantadmin"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// ListPermissionCodesForAccount 返回该账号在指定租户下拥有的所有权限 code。
// 包括 platform / tenant / workspace 多个 scope 的合并。
func (r *Repo) ListPermissionCodesForAccount(ctx context.Context, accountID int64, tenantID int64) ([]string, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT p.code
		FROM role_assignments ra
		JOIN roles r ON r.id = ra.role_id
		JOIN role_permissions rp ON rp.role_id = r.id
		JOIN permissions p ON p.id = rp.permission_id
		WHERE ra.account_id = $1
		  AND ra.deleted_at IS NULL
			  AND (
			      (ra.scope_kind = 'platform' AND $2 = 0)
			   OR (ra.scope_kind IN ('tenant','workspace') AND ra.tenant_id = $2)
			  )
		  AND (ra.expires_at IS NULL OR ra.expires_at > now())`, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var codes []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		codes = append(codes, c)
	}
	return codes, rows.Err()
}

// ListPermissionCodesForAccountAllScopes 返回该账号在所有有效 role_assignment 下拥有的权限 code。
// Admin Web 菜单使用它生成"一套菜单"; 真正的数据/API 隔离仍由当前 access token act_scope 控制。
func (r *Repo) ListPermissionCodesForAccountAllScopes(ctx context.Context, accountID int64) ([]string, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT p.code
		FROM role_assignments ra
		JOIN roles r ON r.id = ra.role_id
		JOIN role_permissions rp ON rp.role_id = r.id
		JOIN permissions p ON p.id = rp.permission_id
		WHERE ra.account_id = $1
		  AND ra.deleted_at IS NULL
		  AND (ra.expires_at IS NULL OR ra.expires_at > now())`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var codes []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		codes = append(codes, c)
	}
	return codes, rows.Err()
}

func (r *Repo) GetRoleByCode(ctx context.Context, scopeKind, code string, tenantID *int64) (*dom.Role, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, uuid, scope_kind, tenant_id, code, name, COALESCE(description,''), is_system, created_at
		FROM roles WHERE scope_kind=$1 AND code=$2 AND ((tenant_id IS NULL AND $3::bigint IS NULL) OR tenant_id=$3) AND deleted_at IS NULL`,
		scopeKind, code, tenantID)
	var role dom.Role
	if err := row.Scan(&role.ID, &role.UUID, &role.ScopeKind, &role.TenantID, &role.Code, &role.Name, &role.Description, &role.IsSystem, &role.CreatedAt); err != nil {
		return nil, err
	}
	return &role, nil
}

func (r *Repo) AssignRole(ctx context.Context, a *dom.RoleAssignment) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO role_assignments (account_id, role_id, scope_kind, tenant_id, workspace_id, expires_at)
		VALUES ($1,$2,$3,$4,$5,$6)`,
		a.AccountID, a.RoleID, a.ScopeKind, a.TenantID, a.WorkspaceID, a.ExpiresAt)
	return err
}

func (r *Repo) ListAssignments(ctx context.Context, accountID int64) ([]dom.RoleAssignment, error) {
	// codex challenge #6: 必须过滤 expires_at (过期 impersonate 行不能再被 scope switch 选中)。
	// granted_reason 一起返, 让 service 层决定要不要排除 impersonate (我们在 buildScopeOptions 排除)。
	rows, err := r.pool.Query(ctx, `
		SELECT id, account_id, role_id, scope_kind, tenant_id, workspace_id, expires_at,
		       COALESCE(granted_reason,''), created_at
		FROM role_assignments
		WHERE account_id=$1
		  AND deleted_at IS NULL
		  AND (expires_at IS NULL OR expires_at > now())`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.RoleAssignment
	for rows.Next() {
		var a dom.RoleAssignment
		if err := rows.Scan(&a.ID, &a.AccountID, &a.RoleID, &a.ScopeKind, &a.TenantID, &a.WorkspaceID, &a.ExpiresAt, &a.GrantedReason, &a.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListScopeSummariesForAccount 一次性返回账号可切换 scope、角色 code、权限 code。
// 这是 /admin/me 的热路径，避免 service 层按 assignment / scope 串行回表。
//
// 2026-08-24 修复: is_admin 必须按 (scope_kind, tenant_id, workspace_id) 分组算,
// 不能用一个全账号共享的布尔值。旧版本用独立的 admin_flag CTE 在全部 scope 混一起
// bool_or 出一个全局值, 再无关联地塞进每一行——账号只要在【任意一个】租户/平台持有
// platform.admin/tenant.admin/tenant.operator, 这个 is_admin=true 就会连带写进它在
// 【其它任意租户】的 scope 里(哪怕那边只是 tenant.member), 最终签进那个租户的
// JWT Admin claim, 造成跨租户权限泄漏(同一个人在 A 租户是管理员, 切到只是普通成员
// 的 B 租户后台依然能看见管理入口)。
func (r *Repo) ListScopeSummariesForAccount(ctx context.Context, accountID int64) ([]dom.ScopeSummary, error) {
	rows, err := r.pool.Query(ctx, `
WITH effective AS (
	SELECT
		ra.scope_kind,
		COALESCE(ra.tenant_id, 0)::bigint AS tenant_id,
		COALESCE(ra.workspace_id, 0)::bigint AS workspace_id,
		r.code AS role_code,
		p.code AS perm_code
	FROM role_assignments ra
	JOIN roles r ON r.id = ra.role_id
	LEFT JOIN role_permissions rp ON rp.role_id = r.id
	LEFT JOIN permissions p ON p.id = rp.permission_id
	WHERE ra.account_id = $1
	  AND ra.deleted_at IS NULL
	  AND (ra.expires_at IS NULL OR ra.expires_at > now())
	  AND COALESCE(ra.granted_reason, '') <> 'impersonate'
)
SELECT
	e.scope_kind,
	e.tenant_id,
	e.workspace_id,
	array_agg(DISTINCT e.role_code ORDER BY e.role_code) AS roles,
	COALESCE(array_agg(DISTINCT e.perm_code ORDER BY e.perm_code) FILTER (WHERE e.perm_code IS NOT NULL), ARRAY[]::text[]) AS perms,
	bool_or(e.role_code IN ('platform.admin','tenant.admin','tenant.operator')) AS is_admin
FROM effective e
GROUP BY e.scope_kind, e.tenant_id, e.workspace_id
ORDER BY
	CASE e.scope_kind WHEN 'platform' THEN 0 WHEN 'tenant' THEN 1 WHEN 'workspace' THEN 2 ELSE 3 END,
	e.tenant_id,
	e.workspace_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.ScopeSummary
	for rows.Next() {
		var s dom.ScopeSummary
		if err := rows.Scan(&s.Kind, &s.TenantID, &s.WorkspaceID, &s.Roles, &s.Perms, &s.IsAdmin); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// HasAdminRole 判断账号是否在任何 scope 下持有平台/租户后台管理角色。
//
// 任意一条未过期 + 未软删的 role_assignment 命中即返回 true。
func (r *Repo) HasAdminRole(ctx context.Context, accountID int64) (bool, error) {
	if accountID <= 0 {
		return false, nil
	}
	var ok bool
	err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM role_assignments ra
			JOIN roles r ON r.id = ra.role_id
			WHERE ra.account_id = $1
			  AND ra.deleted_at IS NULL
			  AND (ra.expires_at IS NULL OR ra.expires_at > now())
			  AND r.code IN ('platform.admin','tenant.admin','tenant.operator')
		)`, accountID).Scan(&ok)
	return ok, err
}

// ListMenuPermissionCodes 返回 menu_id → 关联的 permission code 列表。
// 用于 service.ListMenu 按 caller 已授权的 perms 集合过滤菜单。
func (r *Repo) ListMenuPermissionCodes(ctx context.Context) (map[int64][]string, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT mp.menu_id, p.code
		FROM menu_permissions mp
		JOIN permissions p ON p.id = mp.permission_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]string{}
	for rows.Next() {
		var mid int64
		var code string
		if err := rows.Scan(&mid, &code); err != nil {
			return nil, err
		}
		out[mid] = append(out[mid], code)
	}
	return out, rows.Err()
}

func (r *Repo) ListMenusForScopes(ctx context.Context, scopeKinds []string) ([]dom.Menu, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, uuid, parent_id, path, depth, name, COALESCE(icon,''), COALESCE(route,''),
		       sort_order, scope_kind, is_visible, is_system, metadata
		FROM menus
		WHERE scope_kind = ANY($1::text[])
		  AND is_visible = true AND deleted_at IS NULL
		ORDER BY sort_order, id`, scopeKinds)
	return collectMenus(rows, err)
}

// ===== permissions =====

func (r *Repo) ListPermissions(ctx context.Context, scopeKind string) ([]dom.Permission, error) {
	var rows pgx.Rows
	var err error
	const baseCols = `id, code, name, COALESCE(description,''), kind, scope_kind,
	                  COALESCE(resource,''), COALESCE(action,''), COALESCE(category,''), is_system, sort_order`
	if scopeKind == "" {
		rows, err = r.pool.Query(ctx, `SELECT `+baseCols+` FROM permissions ORDER BY scope_kind, sort_order, code`)
	} else {
		rows, err = r.pool.Query(ctx, `SELECT `+baseCols+` FROM permissions WHERE scope_kind=$1 ORDER BY sort_order, code`, scopeKind)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Permission
	for rows.Next() {
		var p dom.Permission
		var desc string
		if err := rows.Scan(&p.ID, &p.Code, &p.Name, &desc, &p.Kind, &p.ScopeKind,
			&p.Resource, &p.Action, &p.Category, &p.IsSystem, &p.SortOrder); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (r *Repo) GetPermissionByCode(ctx context.Context, code string) (*dom.Permission, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, code, name, COALESCE(description,''), kind, scope_kind,
		       COALESCE(resource,''), COALESCE(action,''), COALESCE(category,''), is_system, sort_order
		FROM permissions WHERE code=$1`, code)
	var p dom.Permission
	var desc string
	if err := row.Scan(&p.ID, &p.Code, &p.Name, &desc, &p.Kind, &p.ScopeKind,
		&p.Resource, &p.Action, &p.Category, &p.IsSystem, &p.SortOrder); err != nil {
		return nil, err
	}
	return &p, nil
}

// ===== roles =====

const baseRoleCols = `id, uuid, scope_kind, tenant_id, code, name, COALESCE(description,''), is_system, created_at`

func scanRole(row pgx.Row) (*dom.Role, error) {
	var rl dom.Role
	if err := row.Scan(&rl.ID, &rl.UUID, &rl.ScopeKind, &rl.TenantID, &rl.Code, &rl.Name, &rl.Description, &rl.IsSystem, &rl.CreatedAt); err != nil {
		return nil, err
	}
	return &rl, nil
}

func (r *Repo) GetRoleByID(ctx context.Context, id int64) (*dom.Role, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseRoleCols+` FROM roles WHERE id=$1 AND deleted_at IS NULL`, id)
	return scanRole(row)
}

func (r *Repo) ListRoles(ctx context.Context, f dom.RoleFilter) ([]dom.Role, int64, error) {
	args := []any{}
	where := []string{"deleted_at IS NULL"}
	if f.ScopeKind != "" {
		args = append(args, f.ScopeKind)
		where = append(where, "scope_kind=$"+itoa(len(args)))
	}
	if f.TenantID != nil {
		args = append(args, *f.TenantID)
		where = append(where, "tenant_id=$"+itoa(len(args)))
	} else if f.ScopeKind == "platform" {
		where = append(where, "tenant_id IS NULL")
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		where = append(where, "(code ILIKE $"+itoa(len(args))+" OR name ILIKE $"+itoa(len(args))+")")
	}
	whereSQL := "WHERE " + strings.Join(where, " AND ")
	limit := f.Limit
	if limit <= 0 {
		limit = 100
	}
	args = append(args, limit, f.Offset)
	rows, err := r.pool.Query(ctx,
		"SELECT "+baseRoleCols+", COUNT(*) OVER() FROM roles "+whereSQL+" ORDER BY scope_kind, tenant_id NULLS FIRST, code LIMIT $"+itoa(len(args)-1)+" OFFSET $"+itoa(len(args)),
		args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.Role
	var total int64
	for rows.Next() {
		var rl dom.Role
		if err := rows.Scan(&rl.ID, &rl.UUID, &rl.ScopeKind, &rl.TenantID, &rl.Code, &rl.Name, &rl.Description, &rl.IsSystem, &rl.CreatedAt, &total); err != nil {
			return nil, 0, err
		}
		out = append(out, rl)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && f.Offset > 0 {
		if err := r.pool.QueryRow(ctx, "SELECT count(*) FROM roles "+whereSQL, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (r *Repo) CreateRole(ctx context.Context, in dom.RoleInput) (*dom.Role, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	row := tx.QueryRow(ctx, `
INSERT INTO roles (scope_kind, tenant_id, code, name, description, is_system)
VALUES ($1,$2,$3,$4,$5,false)
RETURNING `+baseRoleCols, in.ScopeKind, in.TenantID, in.Code, in.Name, nullIfEmpty(in.Description))
	rl, err := scanRole(row)
	if err != nil {
		return nil, err
	}
	if len(in.PermissionIDs) > 0 {
		if err := bulkInsertRolePerms(ctx, tx, rl.ID, in.PermissionIDs); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return rl, nil
}

func (r *Repo) UpdateRole(ctx context.Context, id int64, in dom.RoleInput) (*dom.Role, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	row := tx.QueryRow(ctx, `
UPDATE roles SET name=$2, description=$3 WHERE id=$1 AND is_system=false AND deleted_at IS NULL
RETURNING `+baseRoleCols, id, in.Name, nullIfEmpty(in.Description))
	rl, err := scanRole(row)
	if err != nil {
		return nil, err
	}
	if in.PermissionIDs != nil {
		if _, err := tx.Exec(ctx, `DELETE FROM role_permissions WHERE role_id=$1`, id); err != nil {
			return nil, err
		}
		if len(in.PermissionIDs) > 0 {
			if err := bulkInsertRolePerms(ctx, tx, id, in.PermissionIDs); err != nil {
				return nil, err
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return rl, nil
}

func (r *Repo) DeleteRole(ctx context.Context, id int64) error {
	tag, err := r.pool.Exec(ctx, `UPDATE roles SET deleted_at=now() WHERE id=$1 AND is_system=false AND deleted_at IS NULL`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrForbidden.Withf("系统预置角色不可删除或角色不存在")
	}
	return nil
}

func (r *Repo) ListRolePermissionIDs(ctx context.Context, roleID int64) ([]int64, error) {
	rows, err := r.pool.Query(ctx, `SELECT permission_id FROM role_permissions WHERE role_id=$1 ORDER BY permission_id`, roleID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (r *Repo) SetRolePermissions(ctx context.Context, roleID int64, permissionIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// 系统预置角色不允许改权限点
	var isSystem bool
	if err := tx.QueryRow(ctx, `SELECT is_system FROM roles WHERE id=$1`, roleID).Scan(&isSystem); err != nil {
		return err
	}
	if isSystem {
		return apperr.ErrForbidden.Withf("系统预置角色不可改权限点")
	}
	if _, err := tx.Exec(ctx, `DELETE FROM role_permissions WHERE role_id=$1`, roleID); err != nil {
		return err
	}
	if len(permissionIDs) > 0 {
		if err := bulkInsertRolePerms(ctx, tx, roleID, permissionIDs); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func bulkInsertRolePerms(ctx context.Context, tx pgx.Tx, roleID int64, permIDs []int64) error {
	batch := &pgx.Batch{}
	for _, pid := range permIDs {
		batch.Queue(`INSERT INTO role_permissions (role_id, permission_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, roleID, pid)
	}
	br := tx.SendBatch(ctx, batch)
	defer br.Close()
	for range permIDs {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}

// ===== role assignments =====

func (r *Repo) RevokeAssignment(ctx context.Context, id int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := tenantadminguard.EnsureAssignmentRevocationAllowed(ctx, tx, id); err != nil {
		return err
	}
	var aid int64
	if err := tx.QueryRow(ctx, `UPDATE role_assignments SET deleted_at=now() WHERE id=$1 AND deleted_at IS NULL RETURNING account_id`, id).Scan(&aid); err != nil {
		return err
	}
	// M1 §8: 同事务发 NOTIFY, Bus 监听 auth_revoke 立即写 Redis 黑名单 (撤销 ≤ 1s 生效)
	if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+strconv.FormatInt(aid, 10)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (r *Repo) RevokeAssignmentByTuple(ctx context.Context, accountID, roleID int64, scopeKind string, tenantID, workspaceID *int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := tenantadminguard.EnsureAssignmentTupleRevocationAllowed(
		ctx, tx, accountID, roleID, scopeKind, tenantID, workspaceID,
	); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `
UPDATE role_assignments SET deleted_at=now()
 WHERE account_id=$1 AND role_id=$2 AND scope_kind=$3
   AND tenant_id IS NOT DISTINCT FROM $4
   AND workspace_id IS NOT DISTINCT FROM $5
   AND deleted_at IS NULL`, accountID, roleID, scopeKind, tenantID, workspaceID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+strconv.FormatInt(accountID, 10)); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (r *Repo) ListAssignmentsByMember(ctx context.Context, accountID int64, tenantID int64) ([]dom.RoleAssignment, error) {
	// admin 视角: 看某成员在指定租户的授权。这里**不**过滤 expires_at
	// (admin 想看到所有授权, 包括已过期的; UI 可以单独标识)。
	rows, err := r.pool.Query(ctx, `
SELECT id, account_id, role_id, scope_kind, tenant_id, workspace_id, expires_at,
       COALESCE(granted_reason,''), created_at
  FROM role_assignments
 WHERE account_id=$1 AND deleted_at IS NULL
   AND (scope_kind='platform' OR (scope_kind IN ('tenant','workspace') AND tenant_id=$2))`,
		accountID, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.RoleAssignment
	for rows.Next() {
		var a dom.RoleAssignment
		if err := rows.Scan(&a.ID, &a.AccountID, &a.RoleID, &a.ScopeKind, &a.TenantID, &a.WorkspaceID, &a.ExpiresAt, &a.GrantedReason, &a.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ===== menus =====

const baseMenuCols = `id, uuid, parent_id, path, depth, name, COALESCE(icon,''), COALESCE(route,''),
                     sort_order, scope_kind, is_visible, is_system, metadata`

func collectMenus(rows pgx.Rows, err error) ([]dom.Menu, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Menu
	for rows.Next() {
		var m dom.Menu
		var meta []byte
		var depth int16
		if err := rows.Scan(&m.ID, &m.UUID, &m.ParentID, &m.Path, &depth, &m.Name, &m.Icon, &m.Route,
			&m.SortOrder, &m.ScopeKind, &m.IsVisible, &m.IsSystem, &meta); err != nil {
			return nil, err
		}
		m.Depth = int(depth)
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &m.Metadata)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (r *Repo) ListAllMenus(ctx context.Context) ([]dom.Menu, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT `+baseMenuCols+` FROM menus WHERE deleted_at IS NULL ORDER BY parent_id NULLS FIRST, sort_order, id`)
	return collectMenus(rows, err)
}

// ListVisibleMenusForAccountAllScopes 在一条 SQL 内完成账号全 scope 权限和菜单权限过滤。
// Admin Web 菜单展示是便利入口；真正 API 权限仍由中间件按当前 token perms 强制校验。
func (r *Repo) ListVisibleMenusForAccountAllScopes(ctx context.Context, accountID int64, scopeKinds []string) ([]dom.Menu, error) {
	rows, err := r.pool.Query(ctx, `
WITH allowed_codes AS (
	SELECT DISTINCT p.code
	FROM role_assignments ra
	JOIN roles r ON r.id = ra.role_id
	JOIN role_permissions rp ON rp.role_id = r.id
	JOIN permissions p ON p.id = rp.permission_id
	WHERE ra.account_id = $1
	  AND ra.deleted_at IS NULL
	  AND (ra.expires_at IS NULL OR ra.expires_at > now())
),
visible_menus AS (
	SELECT id, uuid, parent_id, path, depth, name, COALESCE(icon,'') AS icon, COALESCE(route,'') AS route,
	       sort_order, scope_kind, is_visible, is_system, metadata
	FROM menus
	WHERE scope_kind = ANY($2::text[])
	  AND is_visible = true
	  AND deleted_at IS NULL
)
SELECT
	m.id, m.uuid, m.parent_id, m.path, m.depth, m.name, m.icon, m.route,
	m.sort_order, m.scope_kind, m.is_visible, m.is_system, m.metadata
FROM visible_menus m
LEFT JOIN menu_permissions mp ON mp.menu_id = m.id
LEFT JOIN permissions p ON p.id = mp.permission_id
GROUP BY m.id, m.uuid, m.parent_id, m.path, m.depth, m.name, m.icon, m.route,
         m.sort_order, m.scope_kind, m.is_visible, m.is_system, m.metadata
HAVING COUNT(mp.permission_id) = 0
    OR BOOL_OR(p.code IN (SELECT code FROM allowed_codes))
ORDER BY m.sort_order, m.id`, accountID, scopeKinds)
	return collectMenus(rows, err)
}

func (r *Repo) GetMenuByID(ctx context.Context, id int64) (*dom.Menu, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+baseMenuCols+` FROM menus WHERE id=$1 AND deleted_at IS NULL`, id)
	var m dom.Menu
	var meta []byte
	var depth int16
	if err := row.Scan(&m.ID, &m.UUID, &m.ParentID, &m.Path, &depth, &m.Name, &m.Icon, &m.Route,
		&m.SortOrder, &m.ScopeKind, &m.IsVisible, &m.IsSystem, &meta); err != nil {
		return nil, err
	}
	m.Depth = int(depth)
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &m.Metadata)
	}
	return &m, nil
}

func (r *Repo) CreateMenu(ctx context.Context, in dom.MenuInput) (*dom.Menu, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// 拼 path / depth
	parentPath := "/"
	depth := 0
	if in.ParentID != nil {
		var pPath string
		var pDepth int16
		if err := tx.QueryRow(ctx, `SELECT path, depth FROM menus WHERE id=$1 AND deleted_at IS NULL`, *in.ParentID).Scan(&pPath, &pDepth); err != nil {
			return nil, err
		}
		parentPath = strings.TrimSuffix(pPath, "/") + "/"
		depth = int(pDepth) + 1
	}
	path := parentPath + in.Route
	if in.Route == "" {
		path = parentPath + in.Name
	}
	meta := []byte("{}")
	if len(in.Metadata) > 0 {
		if b, err := json.Marshal(in.Metadata); err == nil {
			meta = b
		}
	}
	row := tx.QueryRow(ctx, `
INSERT INTO menus (parent_id, path, depth, name, icon, route, sort_order, scope_kind, is_visible, is_system, metadata)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,false,$10::jsonb)
RETURNING `+baseMenuCols,
		in.ParentID, path, depth, in.Name, nullIfEmpty(in.Icon), nullIfEmpty(in.Route),
		in.SortOrder, in.ScopeKind, in.IsVisible, string(meta))
	var m dom.Menu
	var metaOut []byte
	var d int16
	if err := row.Scan(&m.ID, &m.UUID, &m.ParentID, &m.Path, &d, &m.Name, &m.Icon, &m.Route,
		&m.SortOrder, &m.ScopeKind, &m.IsVisible, &m.IsSystem, &metaOut); err != nil {
		return nil, err
	}
	m.Depth = int(d)
	if len(metaOut) > 0 {
		_ = json.Unmarshal(metaOut, &m.Metadata)
	}
	if len(in.PermissionIDs) > 0 {
		if err := bulkInsertMenuPerms(ctx, tx, m.ID, in.PermissionIDs); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &m, nil
}

func (r *Repo) UpdateMenu(ctx context.Context, id int64, in dom.MenuInput) (*dom.Menu, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// 系统预置: 不允许改 route / scope_kind, 仅允许 is_visible / sort_order / icon / name / metadata
	var isSystem bool
	if err := tx.QueryRow(ctx, `SELECT is_system FROM menus WHERE id=$1 AND deleted_at IS NULL`, id).Scan(&isSystem); err != nil {
		return nil, err
	}
	meta := []byte("{}")
	if len(in.Metadata) > 0 {
		if b, err := json.Marshal(in.Metadata); err == nil {
			meta = b
		}
	}
	if isSystem {
		_, err = tx.Exec(ctx, `UPDATE menus SET name=$2, icon=$3, sort_order=$4, is_visible=$5, metadata=$6::jsonb WHERE id=$1`,
			id, in.Name, nullIfEmpty(in.Icon), in.SortOrder, in.IsVisible, string(meta))
	} else {
		_, err = tx.Exec(ctx, `UPDATE menus SET name=$2, icon=$3, route=$4, sort_order=$5, scope_kind=$6, is_visible=$7, metadata=$8::jsonb WHERE id=$1`,
			id, in.Name, nullIfEmpty(in.Icon), nullIfEmpty(in.Route), in.SortOrder, in.ScopeKind, in.IsVisible, string(meta))
	}
	if err != nil {
		return nil, err
	}
	if in.PermissionIDs != nil {
		if _, err := tx.Exec(ctx, `DELETE FROM menu_permissions WHERE menu_id=$1`, id); err != nil {
			return nil, err
		}
		if len(in.PermissionIDs) > 0 {
			if err := bulkInsertMenuPerms(ctx, tx, id, in.PermissionIDs); err != nil {
				return nil, err
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return r.GetMenuByID(ctx, id)
}

func (r *Repo) DeleteMenu(ctx context.Context, id int64) error {
	tag, err := r.pool.Exec(ctx, `UPDATE menus SET deleted_at=now() WHERE id=$1 AND is_system=false AND deleted_at IS NULL`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrForbidden.Withf("系统预置菜单不可删除或菜单不存在")
	}
	return nil
}

func (r *Repo) ListMenuPermissionIDs(ctx context.Context, menuID int64) ([]int64, error) {
	rows, err := r.pool.Query(ctx, `SELECT permission_id FROM menu_permissions WHERE menu_id=$1 ORDER BY permission_id`, menuID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (r *Repo) SetMenuPermissions(ctx context.Context, menuID int64, permissionIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM menu_permissions WHERE menu_id=$1`, menuID); err != nil {
		return err
	}
	if len(permissionIDs) > 0 {
		if err := bulkInsertMenuPerms(ctx, tx, menuID, permissionIDs); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func bulkInsertMenuPerms(ctx context.Context, tx pgx.Tx, menuID int64, permIDs []int64) error {
	batch := &pgx.Batch{}
	for _, pid := range permIDs {
		batch.Queue(`INSERT INTO menu_permissions (menu_id, permission_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, menuID, pid)
	}
	br := tx.SendBatch(ctx, batch)
	defer br.Close()
	for range permIDs {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}

// ===== helpers =====

func itoa(n int) string {
	if n < 10 {
		return string('0' + rune(n))
	}
	return strconv.Itoa(n)
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ===== M3 D8 option C: impersonate 临时 role_assignment =====

// IssueImpersonateAssignment 子查询找 target_tenant 的 tenant.admin 角色 id, 插入
// 一条带 granted_reason='impersonate' + expires_at + granted_by 的 role_assignment。
//
// 注意: 不防重复插入 — 同一 platform admin 短时间内重复 impersonate 同一租户会产生多行;
// 业务侧由 auth.Impersonate 控制 (旧 session 撤销时一并 DeleteImpersonateAssignment)。
func (r *Repo) IssueImpersonateAssignment(ctx context.Context, accountID, targetTenantID int64, expiresAt time.Time, grantedBy *int64) (int64, error) {
	var id int64
	err := r.pool.QueryRow(ctx, `
		INSERT INTO role_assignments (account_id, role_id, scope_kind, tenant_id, expires_at, granted_by, granted_reason)
		SELECT $1, r.id, 'tenant', $2, $3, $4, 'impersonate'
		  FROM roles r
		 WHERE r.code='tenant.admin' AND r.scope_kind='tenant'
		   AND r.tenant_id=$2 AND r.deleted_at IS NULL
		 LIMIT 1
		RETURNING id`,
		accountID, targetTenantID, expiresAt, grantedBy).Scan(&id)
	if err != nil {
		if err.Error() != "" && strings.Contains(err.Error(), "no rows") {
			return 0, apperr.ErrNotFound.Withf("tenant.admin role not found for tenant %d", targetTenantID)
		}
		return 0, err
	}
	return id, nil
}

// DeleteImpersonateAssignment 硬删 (限定 granted_reason='impersonate' 防误删真实授权)。
func (r *Repo) DeleteImpersonateAssignment(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx,
		`DELETE FROM role_assignments WHERE id=$1 AND granted_reason='impersonate'`, id)
	return err
}

// CleanupExpiredImpersonate 删 expires_at<=now 的 impersonate 行 (后台 cron 调)。
func (r *Repo) CleanupExpiredImpersonate(ctx context.Context) (int64, error) {
	tag, err := r.pool.Exec(ctx,
		`DELETE FROM role_assignments WHERE granted_reason='impersonate' AND expires_at <= now()`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
