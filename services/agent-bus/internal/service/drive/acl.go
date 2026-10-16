// Package drivev3 是 F06 Drive v0.3.x 的 service 层 (side-by-side 切换期临时命名;
// Phase 2.Z 删 legacy 后 rename 为 internal/service/drive).
//
// Phase 2.0c 只含 ACL CheckEffectiveRole; 后续 slice (2.1 storage 已用 drivev3repo
// 不依赖 service drivev3; 2.2 bus drive endpoints 开始才会大量扩 service drivev3)
// 按需扩.
package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ACLService 提供 F06 §4.3 + ADR 0027 的 ACL 计算.
type ACLService struct {
	pool *pgxpool.Pool
}

// NewACLService 构造.
func NewACLService(pool *pgxpool.Pool) *ACLService { return &ACLService{pool: pool} }

// roleRank 用于 max(role) 计算; 数字越大权限越高.
// 空字符串 (无权限) = 0, viewer = 1, editor = 2, manager = 3.
var roleRank = map[dom.ACLRole]int{
	"":                 0,
	dom.ACLRoleViewer:  1,
	dom.ACLRoleEditor:  2,
	dom.ACLRoleManager: 3,
}

// maxRole 取两个 role 中权限较高的.
func maxRole(a, b dom.ACLRole) dom.ACLRole {
	if roleRank[a] >= roleRank[b] {
		return a
	}
	return b
}

// CheckEffectiveRole 计算 accountID 对 target (space|folder|file) 的最终 effective role.
//
// ADR 0027: 默认继承 + 最近账号覆写。account grant 沿 target→root 查最近一条;
// department / link_token grant 仍按命中项取最大。默认 manager 不被降级。
//
// 算法 (F06 §4.3):
//  1. 解析 target 到祖先链 (file → folder → space; folder → folder → ... → space; space 自身)
//  2. 默认权限 = default(space.kind, accountID, space.owner / space.department_id 关系) via tenant_memberships
//  3. 账号 grant = drive_acl_entries WHERE (target_kind, target_id) ∈ 祖先链
//     AND subject_kind='account' AND subject_id=$accountID
//     仅取祖先链中最近一条,允许子级覆盖父级同账号角色
//  4. 部门 grant = 同 3 但 subject_kind='department' AND subject_id ∈ accountID 在该租户的 department_id
//  5. link_token grant = 同 3 但 subject_kind='link_token'
//     AND link_token_id ∈ (drive_share_links 未撤销 + 未到期)
//  6. effective = max(default, 最近账号 grant, 部门/link grant max)
//
// **不**实现: deny / break-inheritance / 私密子目录完全移除继承成员 — 详 ADR 0027.
//
// 调用方约定: accountID 已经过 tenant scope 鉴权 (在 transport 层 middleware 完成);
// 本函数 ONLY 计算 ACL, 不再做 tenant member 校验之外的鉴权.
func (s *ACLService) CheckEffectiveRole(
	ctx context.Context,
	accountID int64,
	targetKind dom.ACLTargetKind,
	targetID int64,
) (dom.ACLRole, error) {
	// 1. 拉 target 的祖先链 + space 信息
	space, ancestors, err := s.resolveTargetAncestors(ctx, targetKind, targetID)
	if err != nil {
		return "", err
	}
	if space == nil {
		// target 不存在或被软删
		return "", nil
	}

	// 2. 查 accountID 在 space.tenant_id 的 membership (含 department_id)
	membership, err := s.getMembership(ctx, accountID, space.TenantID)
	if err != nil {
		return "", err
	}

	// 3. 默认权限
	effective := s.defaultRole(space, accountID, membership)

	// 4. ACL grants (account/department/link_token 三类)
	// **强制 tenant member 门槛**: 按 ADR 0018 + F06 Q3, 链接分享强制本租户登录后 redeem;
	// 跨租户 / 匿名访问在 ACL 函数层就拒绝, 不依赖 transport middleware 防御纵深.
	// 非 tenant member 直接返回 default role (personal/shared owner 仍可命中 default = manager,
	// 但 tenant/department default = "" 且无 grant 加成 → 实际 effective = "")
	if membership == nil {
		return effective, nil
	}

	grants, err := s.collectGrants(ctx, accountID, membership, ancestors)
	if err != nil {
		return "", err
	}
	accountApplied := false
	for _, g := range grants {
		switch g.SubjectKind {
		case "account":
			if !accountApplied {
				effective = maxRole(effective, g.Role)
				accountApplied = true
			}
		default:
			effective = maxRole(effective, g.Role)
		}
	}

	return effective, nil
}

// ancestor 一个祖先节点 (folder 或 space).
type ancestor struct {
	Kind dom.ACLTargetKind // "folder" 或 "space"
	ID   int64
}

// resolveTargetAncestors 把 target 解析到祖先链 + space.
// 返回的 ancestors 包含 target 自身 (除非 target 是 space, 那 space 节点在 ancestors 里独占一条).
// 对 file target: file 不在 ancestors (file 自己也可以有 ACL grant) → ancestors 含 file + 父 folder 链 + space.
func (s *ACLService) resolveTargetAncestors(
	ctx context.Context,
	targetKind dom.ACLTargetKind,
	targetID int64,
) (*dom.Space, []ancestor, error) {
	var (
		spaceID  int64
		folderID *int64 // file 才用; folder/space 时不用
	)

	switch targetKind {
	case dom.ACLTargetSpace:
		// 直接查 space; ancestors = []ancestor{{space, id}}
		sp, err := s.getSpace(ctx, targetID)
		if err != nil {
			return nil, nil, err
		}
		if sp == nil {
			return nil, nil, nil
		}
		return sp, []ancestor{{dom.ACLTargetSpace, targetID}}, nil

	case dom.ACLTargetFolder:
		// 走 folder ancestry CTE
		err := s.pool.QueryRow(ctx,
			`SELECT space_id FROM drive_folders WHERE id = $1 AND is_deleted = false`, targetID).Scan(&spaceID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, nil
		}
		if err != nil {
			return nil, nil, fmt.Errorf("drive.ACL: get folder space: %w", err)
		}
		return s.foldersToAncestors(ctx, spaceID, &targetID)

	case dom.ACLTargetFile:
		// file → 查 drive_folder_id (可能 NULL = KB-only 或 chat scope)
		err := s.pool.QueryRow(ctx,
			`SELECT space_id, drive_folder_id FROM drive_files WHERE id = $1 AND is_deleted = false`, targetID).Scan(&spaceID, &folderID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, nil
		}
		if err != nil {
			return nil, nil, fmt.Errorf("drive.ACL: get file space: %w", err)
		}
		// ancestors 含 file 自身, 然后 folder 链 (若有), 再 space
		sp, anc, err := s.foldersToAncestors(ctx, spaceID, folderID)
		if err != nil {
			return nil, nil, err
		}
		anc = append([]ancestor{{dom.ACLTargetFile, targetID}}, anc...)
		return sp, anc, nil

	default:
		return nil, nil, fmt.Errorf("drive.ACL: unknown targetKind %q", targetKind)
	}
}

// foldersToAncestors 从 startFolderID (可能 nil = 直接到 space root)
// 递归到 space 根, 返回 ancestors (含 start folder, 不含 file).
// spaceID: 必填, 用于 fallback (folder NULL 时仍然要返回 space)
func (s *ACLService) foldersToAncestors(
	ctx context.Context,
	spaceID int64,
	startFolderID *int64,
) (*dom.Space, []ancestor, error) {
	var anc []ancestor
	if startFolderID != nil {
		rows, err := s.pool.Query(ctx, `
            WITH RECURSIVE chain AS (
                SELECT id, parent_id FROM drive_folders WHERE id = $1 AND is_deleted = false
                UNION ALL
                SELECT f.id, f.parent_id FROM drive_folders f
                JOIN chain c ON f.id = c.parent_id
                WHERE f.is_deleted = false
            )
            SELECT id FROM chain
        `, *startFolderID)
		if err != nil {
			return nil, nil, fmt.Errorf("drive.ACL: folder ancestry CTE: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var fid int64
			if err := rows.Scan(&fid); err != nil {
				return nil, nil, err
			}
			anc = append(anc, ancestor{dom.ACLTargetFolder, fid})
		}
		if err := rows.Err(); err != nil {
			return nil, nil, err
		}
	}
	// 加 space 节点
	anc = append(anc, ancestor{dom.ACLTargetSpace, spaceID})

	sp, err := s.getSpace(ctx, spaceID)
	if err != nil {
		return nil, nil, err
	}
	return sp, anc, nil
}

func (s *ACLService) getSpace(ctx context.Context, spaceID int64) (*dom.Space, error) {
	const q = `
        SELECT id, uuid, tenant_id, kind, owner_account_id, department_id,
               name, status, used_bytes
        FROM drive_spaces WHERE id = $1 AND is_deleted = false
    `
	var sp dom.Space
	err := s.pool.QueryRow(ctx, q, spaceID).Scan(
		&sp.ID, &sp.UUID, &sp.TenantID, &sp.Kind, &sp.OwnerAccountID, &sp.DepartmentID,
		&sp.Name, &sp.Status, &sp.UsedBytes,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ACL: get space %d: %w", spaceID, err)
	}
	return &sp, nil
}

// membership 表征 accountID 在 tenant 的从属关系.
type membership struct {
	DepartmentID *int64 // 可能 NULL (账号在 tenant 但没分配部门)
}

// getMembership 查 accountID 在 tenant 的 active membership; 不存在返 nil.
func (s *ACLService) getMembership(ctx context.Context, accountID, tenantID int64) (*membership, error) {
	const q = `
        SELECT department_id FROM tenant_memberships
         WHERE account_id = $1 AND tenant_id = $2
           AND status = 'active' AND deleted_at IS NULL
    `
	var deptID *int64
	err := s.pool.QueryRow(ctx, q, accountID, tenantID).Scan(&deptID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ACL: get membership: %w", err)
	}
	return &membership{DepartmentID: deptID}, nil
}

// defaultRole F06 §1.1 默认权限.
func (s *ACLService) defaultRole(sp *dom.Space, accountID int64, ms *membership) dom.ACLRole {
	switch sp.Kind {
	case dom.SpaceKindPersonal:
		if sp.OwnerAccountID != nil && *sp.OwnerAccountID == accountID {
			return dom.ACLRoleManager
		}
		return ""

	case dom.SpaceKindTenant:
		if ms != nil {
			return dom.ACLRoleViewer
		}
		return ""

	case dom.SpaceKindDepartment:
		if ms == nil {
			return ""
		}
		if ms.DepartmentID != nil && sp.DepartmentID != nil && *ms.DepartmentID == *sp.DepartmentID {
			return dom.ACLRoleEditor
		}
		return dom.ACLRoleViewer

	case dom.SpaceKindShared:
		if sp.OwnerAccountID != nil && *sp.OwnerAccountID == accountID {
			return dom.ACLRoleManager
		}
		// shared space 非 owner 必须靠 ACL grant; default 无访问
		return ""
	}
	return ""
}

// ListAccessibleSpaceIDs F06 Phase 2.2e: 返回 accountID 在 tenant 内有 viewer+ 权限的所有 space.id.
// 用于 Recent / Search / Bootstrap-equivalents 的 "可访问 space 池" 计算.
//
// 算法: 拉 tenant 内全部未删 space, 对每个调 CheckEffectiveRole(space), 命中 viewer+ 收录.
//
// **first-pass 实现取舍**: 走 N+1 (1 ListByTenant + N CheckEffectiveRole), 每个 CheckEffectiveRole
// 内部还会 query 多次 (resolveTargetAncestors + getMembership + collectGrants).
// 优点: 单语义一致, 不重复 ACL 逻辑; 缺点: tenant 内 space 数 > 几十后性能下降.
// 后续 slice 可优化为单 SQL JOIN drive_acl_entries (类似 ListSharedSpacesAccessible 的 union).
// 当前阶段每 tenant space ≈ 个位数 (1 personal + 1 tenant + 0-1 dept + 几 shared), N+1 可接受.
func (s *ACLService) ListAccessibleSpaceIDs(ctx context.Context, tenantID, accountID int64) ([]int64, error) {
	return s.listSpaceIDsForRole(ctx, tenantID, accountID, dom.ACLRoleViewer)
}

// ListManageableSpaceIDs F06 Phase 2.2e: 同 ListAccessibleSpaceIDs, 但门槛 = manager+.
// 用于 Recycle list/restore/purge (只有 manager+ 才能见/操作回收行).
// 实际命中: personal owner + shared owner + shared 上有 manager grant 的成员.
// 注: F06 §1.1 department/tenant default = viewer/editor (非 manager) → 无 manager grant 时不入选.
func (s *ACLService) ListManageableSpaceIDs(ctx context.Context, tenantID, accountID int64) ([]int64, error) {
	return s.listSpaceIDsForRole(ctx, tenantID, accountID, dom.ACLRoleManager)
}

// listSpaceIDsForRole 内部 helper: 拉 tenant 内所有 space, 过滤 effective role >= want.
func (s *ACLService) listSpaceIDsForRole(ctx context.Context, tenantID, accountID int64, want dom.ACLRole) ([]int64, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id FROM drive_spaces WHERE tenant_id = $1 AND is_deleted = false`, tenantID)
	if err != nil {
		return nil, fmt.Errorf("drive.ACL.listSpaceIDsForRole: %w", err)
	}
	defer rows.Close()

	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("drive.ACL.listSpaceIDsForRole scan: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]int64, 0, len(ids))
	wantRank := roleRank[want]
	for _, id := range ids {
		role, err := s.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, id)
		if err != nil {
			return nil, err
		}
		if roleRank[role] >= wantRank {
			out = append(out, id)
		}
	}
	return out, nil
}

type aclGrantMatch struct {
	Role        dom.ACLRole
	SubjectKind string
	Depth       int
}

// collectGrants 拉 ancestors 范围内命中 accountID 的 grants.
// 三类 subject: account / department / link_token (后者 join share_links 过滤未撤销 + 未到期).
// 返回按 depth ASC 排序; account grant 调用方只取最近一条,department/link 取 max.
func (s *ACLService) collectGrants(ctx context.Context, accountID int64, ms *membership, ancestors []ancestor) ([]aclGrantMatch, error) {
	if len(ancestors) == 0 {
		return nil, nil
	}

	// Build VALUES list for (target_kind, target_id) IN clause
	valuesSQL := ""
	args := []interface{}{}
	for i, a := range ancestors {
		if i > 0 {
			valuesSQL += ","
		}
		valuesSQL += fmt.Sprintf("($%d::text, $%d::bigint, $%d::int)", len(args)+1, len(args)+2, len(args)+3)
		args = append(args, string(a.Kind), a.ID, i)
	}

	// accountID for direct account grant
	args = append(args, accountID)
	accountIdx := len(args)

	// department_id for department grant (NULL safe via COALESCE)
	var deptID *int64
	if ms != nil && ms.DepartmentID != nil {
		deptID = ms.DepartmentID
	}
	args = append(args, deptID)
	deptIdx := len(args)

	q := fmt.Sprintf(`
        WITH targets(target_kind, target_id, depth) AS (VALUES %s)
        SELECT ae.role, ae.subject_kind, t.depth
          FROM drive_acl_entries ae
          JOIN targets t ON t.target_kind = ae.target_kind AND t.target_id = ae.target_id
          LEFT JOIN drive_share_links sl ON ae.link_token_id = sl.id
         WHERE ae.is_deleted = false
           AND (
               (ae.subject_kind = 'account' AND ae.subject_id = $%d)
            OR (ae.subject_kind = 'department' AND ae.subject_id = $%d AND $%d IS NOT NULL)
            OR (ae.subject_kind = 'link_token' AND sl.id IS NOT NULL
                AND sl.is_deleted = false
                AND sl.revoked_at IS NULL
                AND (sl.expires_at IS NULL OR sl.expires_at > now()))
           )
         ORDER BY t.depth ASC, ae.id ASC
    `, valuesSQL, accountIdx, deptIdx, deptIdx)

	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("drive.ACL: collect grants: %w", err)
	}
	defer rows.Close()

	var roles []aclGrantMatch
	for rows.Next() {
		var r aclGrantMatch
		if err := rows.Scan(&r.Role, &r.SubjectKind, &r.Depth); err != nil {
			return nil, err
		}
		roles = append(roles, r)
	}
	return roles, rows.Err()
}
