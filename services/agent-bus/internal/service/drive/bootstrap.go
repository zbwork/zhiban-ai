// bootstrap.go — F06 §3.2 Bootstrap service (lazy ensure personal + 列出 4 类 space) + folder tree/children 读接口
// Phase 2.2a: 新建 BootstrapSvc + read-only endpoints 底层服务.
package drive

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// BootstrapResp F06 §3.2 POST /drive:bootstrap 响应 shape.
type BootstrapResp struct {
	Spaces struct {
		Personal    *dom.Space  `json:"personal"`
		Tenant      *dom.Space  `json:"tenant"`
		Departments []dom.Space `json:"departments"`
		Shared      []dom.Space `json:"shared"`
	} `json:"spaces"`
}

// FolderTreeResp F06 §3.2 GET /drive/spaces/{uuid}/folders/tree.
type FolderTreeResp struct {
	Items []dom.Folder `json:"items"`
}

// FolderChildrenResp F06 §3.2 GET /drive/folders/{uuid}/children.
type FolderChildrenResp struct {
	Folders []dom.Folder `json:"folders"`
	Files   []dom.File   `json:"files"`
	Total   int          `json:"total"`
}

// BootstrapSvc 提供 Bootstrap (lazy ensure personal + 列出 4 类 space) + list/tree/children 读接口.
type BootstrapSvc struct {
	pool       *pgxpool.Pool
	spaces     *drepo.SpaceRepo
	folders    *drepo.FolderRepo
	files      *drepo.FileRepo
	acl        *ACLService
	sysFolders *SystemFoldersSvc // Phase 2.9: 个人 space 内 de_root 系统目录回填; nil 表示不回填 (向后兼容老 wiring).
}

// NewBootstrapSvc 构造.
func NewBootstrapSvc(pool *pgxpool.Pool, sp *drepo.SpaceRepo, fd *drepo.FolderRepo, fl *drepo.FileRepo, acl *ACLService) *BootstrapSvc {
	return &BootstrapSvc{pool: pool, spaces: sp, folders: fd, files: fl, acl: acl}
}

// WithSystemFolders Phase 2.9: 注入 SystemFoldersSvc, Bootstrap 时回填 de_root.
// 通过 setter 而非新 ctor 是为了不打破现有 NewBootstrapSvc 调用方 (cmd/bus/main.go
// 老 wiring 不传也能跑, 只是 de_root 不会被 Bootstrap 自动建).
func (s *BootstrapSvc) WithSystemFolders(sys *SystemFoldersSvc) *BootstrapSvc {
	s.sysFolders = sys
	return s
}

// Bootstrap 实现 F06 §3.2.
//  1. EnsurePersonal (幂等; 不存在则建)
//  2. GetTenantSpace (不存在 → resp.Spaces.Tenant 为 nil; 不报错 — F01 没建 tenant 时容忍)
//  3. ListDepartmentSpaces (按当前 accountID 在 tenant 的 dept_id 列表; 通常 0 或 1 个)
//  4. ListSharedSpacesAccessible (owner / ACL granted)
//
// 数字员工系统目录树（de_root / de_agent / de_outputs）由 Phase 2.9 BootstrapSvc 扩展 +
// F10 数字员工钩子接入时一并 ensure，本 v0.3.3 阶段 Bootstrap 不做该层 ensure
// (详 plan v0.3.3 Phase 2.9 任务 + F06 §1.6 + ADR 0019).
//
// 上层 (HTTP handler) 必须先验 accountID 已是 tenant member; Bootstrap 不再 check.
func (s *BootstrapSvc) Bootstrap(ctx context.Context, tenantID, accountID int64, displayName string) (*BootstrapResp, error) {
	var resp BootstrapResp

	// 1. personal (lazy)
	personal, err := s.spaces.EnsurePersonal(ctx, tenantID, accountID, displayName)
	if err != nil {
		return nil, fmt.Errorf("drive.Bootstrap.EnsurePersonal: %w", err)
	}
	resp.Spaces.Personal = personal

	// 1b. Phase 2.9: 个人 space 内回填 de_root 系统目录 (idempotent).
	// 失败不阻塞 Bootstrap — caller 仍能看到 4 类 space; 下次再 ensure.
	if s.sysFolders != nil {
		if _, dErr := s.sysFolders.EnsureDeRootInPersonal(ctx, personal.ID, accountID); dErr != nil {
			// 不返错: de_root 缺失只影响 "数字员工/" 入口展示, 不影响其他 space 列表.
			slog.WarnContext(ctx, "drive.bootstrap.de_root_ensure_failed",
				"tenant_id", tenantID, "account_id", accountID, "space_id", personal.ID,
				"err", dErr.Error())
		}
	}

	// 2. tenant (不 lazy — F01 provision 期间已建; 没建直接返 nil 不报错)
	tenant, err := s.spaces.GetTenantSpace(ctx, tenantID)
	if err != nil {
		return nil, fmt.Errorf("drive.Bootstrap.GetTenantSpace: %w", err)
	}
	resp.Spaces.Tenant = tenant

	// 3. department(s) — 通过 tenant_memberships.department_id 反查 caller 当前所在部门
	deptIDs, err := s.fetchAccountDepts(ctx, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	// F06 IA cutover(docs/plans/drive-two-bucket-rethink.md):**停用** Phase 2.10
	// `EnsureDepartment` 懒建钩子。部门不再作为用户可见的默认空间层级,长期方向上
	// 仅作为 shared space 的 ACL subject。`ListDepartmentSpaces` 仍保留,**只返回
	// 已存在(非软删)的 dept space**,兼容已有数据;新租户/新部门不再自动出现。
	depts, err := s.spaces.ListDepartmentSpaces(ctx, tenantID, deptIDs)
	if err != nil {
		return nil, fmt.Errorf("drive.Bootstrap.ListDepartmentSpaces: %w", err)
	}
	resp.Spaces.Departments = depts

	// 4. shared
	shared, err := s.spaces.ListSharedSpacesAccessible(ctx, tenantID, accountID)
	if err != nil {
		return nil, fmt.Errorf("drive.Bootstrap.ListShared: %w", err)
	}
	resp.Spaces.Shared = shared

	// 数字员工系统目录树 ensure 在 Phase 2.9 接入 F10 数字员工钩子时统一做;
	// 本阶段 Bootstrap 仅做 lazy ensure personal (F06 §1.6 + ADR 0019).
	return &resp, nil
}

// FolderTree 拉某 space 全部 folder (前端组装树).
// ACL: 调用方先在 space.id 上 viewer+; 本函数不再 check (上层 handler 已校).
func (s *BootstrapSvc) FolderTree(ctx context.Context, spaceID int64) (*FolderTreeResp, error) {
	items, err := s.folders.ListBySpace(ctx, spaceID)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderTree: %w", err)
	}
	return &FolderTreeResp{Items: items}, nil
}

// FolderChildren 列 folder 直接子 (含文件), 分页.
// pageSize cap 200; page 从 1 起.
func (s *BootstrapSvc) FolderChildren(ctx context.Context, folderID int64, page, pageSize int) (*FolderChildrenResp, error) {
	if page < 1 {
		page = 1
	}
	if pageSize <= 0 {
		pageSize = 50
	}
	if pageSize > 200 {
		pageSize = 200
	}

	folders, err := s.folders.ListChildren(ctx, folderID, page, pageSize)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderChildren.folders: %w", err)
	}
	files, total, err := s.files.ListByFolder(ctx, folderID, page, pageSize)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderChildren.files: %w", err)
	}
	// total 仅表示 file 数; folder 数若需要 total 再扩接口 (v1 暂不暴露)
	return &FolderChildrenResp{Folders: folders, Files: files, Total: total}, nil
}

// lookupDepartmentName Phase 2.10: 反查部门名给 EnsureDepartment 当 space.name 用.
// 失败 fallback "部门" + dept_id 字符串; 不返错 (lazy ensure 失败仅 slog).
func (s *BootstrapSvc) lookupDepartmentName(ctx context.Context, tenantID, departmentID int64) string {
	var name string
	err := s.pool.QueryRow(ctx,
		`SELECT name FROM departments WHERE id = $1 AND tenant_id = $2 AND deleted_at IS NULL LIMIT 1`,
		departmentID, tenantID).Scan(&name)
	if err != nil || name == "" {
		return fmt.Sprintf("部门-%d", departmentID)
	}
	return name
}

// fetchAccountDepts 查 accountID 在 tenant 的 dept_id 列表 (跟 ACL 一致, 1 dept/membership).
func (s *BootstrapSvc) fetchAccountDepts(ctx context.Context, accountID, tenantID int64) ([]int64, error) {
	rows, err := s.pool.Query(ctx, `
        SELECT department_id FROM tenant_memberships
         WHERE account_id = $1 AND tenant_id = $2
           AND status='active' AND department_id IS NOT NULL AND deleted_at IS NULL
    `, accountID, tenantID)
	if err != nil {
		return nil, fmt.Errorf("drive.Bootstrap.fetchDepts: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var d int64
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
