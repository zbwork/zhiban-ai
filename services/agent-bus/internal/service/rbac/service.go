package rbac

import (
	"context"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Service M1 RBAC + 菜单管理。
type Service interface {
	// read
	PermissionsFor(ctx context.Context, accountID, tenantID int64) ([]string, error)
	// MenusFor 按用户所有 role_assignment 的 menu permissions 过滤，返回一套业务菜单。
	// actScope 仅用于兼容旧调用签名；API/数据隔离仍由中间件按当前 token act_scope 强制校验。
	// 未挂任何权限点的预留菜单 (例如 /me 父节点) 视为对所有登录用户可见。
	MenusFor(ctx context.Context, accountID int64, actScope string, tenantID int64) ([]dom.Menu, error)
	ListPermissions(ctx context.Context, scopeKind string) ([]dom.Permission, error)

	// 后台管理员闸门: 是否拥有 platform.admin 或任意 tenant.admin (M1 §3.3.1)。
	HasAdminRole(ctx context.Context, accountID int64) (bool, error)
	// menu_id → 关联 permission code 列表 (用于 ListMenu 按 caller 权限二次过滤)。
	MenuPermissionCodes(ctx context.Context) (map[int64][]string, error)

	// role CRUD
	ListRoles(ctx context.Context, f dom.RoleFilter) ([]dom.Role, int64, error)
	GetRole(ctx context.Context, id int64) (*RoleWithPerms, error)
	GetRoleByCode(ctx context.Context, scopeKind, code string, tenantID *int64) (*dom.Role, error)
	CreateRole(ctx context.Context, in dom.RoleInput) (*RoleWithPerms, error)
	UpdateRole(ctx context.Context, id int64, in dom.RoleInput) (*RoleWithPerms, error)
	DeleteRole(ctx context.Context, id int64) error

	// role assignments (单成员视角)
	AssignRole(ctx context.Context, a *dom.RoleAssignment) error
	RevokeAssignment(ctx context.Context, id int64) error
	RevokeAssignmentByTuple(ctx context.Context, accountID, roleID int64, scopeKind string, tenantID, workspaceID *int64) error
	ListMemberAssignments(ctx context.Context, accountID, tenantID int64) ([]dom.RoleAssignment, error)

	// menu CRUD
	ListMenus(ctx context.Context, all bool) ([]dom.Menu, error)
	GetMenu(ctx context.Context, id int64) (*MenuWithPerms, error)
	CreateMenu(ctx context.Context, in dom.MenuInput) (*MenuWithPerms, error)
	UpdateMenu(ctx context.Context, id int64, in dom.MenuInput) (*MenuWithPerms, error)
	DeleteMenu(ctx context.Context, id int64) error

	// M3 D8 option C: impersonate 临时 role_assignment 颁发 / 撤销 / cleanup。
	IssueImpersonateAssignment(ctx context.Context, accountID, targetTenantID int64, expiresAt time.Time, grantedBy *int64) (int64, error)
	DeleteImpersonateAssignment(ctx context.Context, id int64) error
	CleanupExpiredImpersonate(ctx context.Context) (int64, error)
}

// RoleWithPerms 列详情时把权限点 ID 列表一起带。
type RoleWithPerms struct {
	Role          *dom.Role `json:"role"`
	PermissionIDs []int64   `json:"permissionIds"`
}

// MenuWithPerms 菜单详情含挂的权限点 ID。
type MenuWithPerms struct {
	Menu          *dom.Menu `json:"menu"`
	PermissionIDs []int64   `json:"permissionIds"`
}

const menuCacheTTL = 30 * time.Second

type menuCacheKey struct {
	AccountID int64
	ActScope  string
	TenantID  int64
}

type menuCacheEntry struct {
	ExpiresAt time.Time
	Items     []dom.Menu
}

type impl struct {
	repo dom.Repository

	menuMu    sync.Mutex
	menuCache map[menuCacheKey]menuCacheEntry
}

// New 构造。
func New(repo dom.Repository) Service {
	return &impl{repo: repo, menuCache: make(map[menuCacheKey]menuCacheEntry)}
}

// ===== read =====

func (s *impl) PermissionsFor(ctx context.Context, accountID, tenantID int64) ([]string, error) {
	return s.repo.ListPermissionCodesForAccount(ctx, accountID, tenantID)
}

func (s *impl) HasAdminRole(ctx context.Context, accountID int64) (bool, error) {
	return s.repo.HasAdminRole(ctx, accountID)
}

func (s *impl) MenuPermissionCodes(ctx context.Context) (map[int64][]string, error) {
	return s.repo.ListMenuPermissionCodes(ctx)
}

func (s *impl) MenusFor(ctx context.Context, accountID int64, actScope string, tenantID int64) ([]dom.Menu, error) {
	key := menuCacheKey{AccountID: accountID, ActScope: actScope, TenantID: tenantID}
	if cached, ok := s.getCachedMenus(key); ok {
		return cached, nil
	}
	out, err := s.repo.ListVisibleMenusForAccountAllScopes(ctx, accountID, []string{"platform", "tenant", "workspace", "self", "any"})
	if err != nil {
		return nil, err
	}
	s.setCachedMenus(key, out)
	return out, nil
}

func (s *impl) getCachedMenus(key menuCacheKey) ([]dom.Menu, bool) {
	s.menuMu.Lock()
	defer s.menuMu.Unlock()
	entry, ok := s.menuCache[key]
	if !ok || time.Now().After(entry.ExpiresAt) {
		if ok {
			delete(s.menuCache, key)
		}
		return nil, false
	}
	return append([]dom.Menu(nil), entry.Items...), true
}

func (s *impl) setCachedMenus(key menuCacheKey, items []dom.Menu) {
	s.menuMu.Lock()
	defer s.menuMu.Unlock()
	s.menuCache[key] = menuCacheEntry{
		ExpiresAt: time.Now().Add(menuCacheTTL),
		Items:     append([]dom.Menu(nil), items...),
	}
}

func (s *impl) clearMenuCache() {
	s.menuMu.Lock()
	defer s.menuMu.Unlock()
	clear(s.menuCache)
}

func (s *impl) ListPermissions(ctx context.Context, scopeKind string) ([]dom.Permission, error) {
	return s.repo.ListPermissions(ctx, scopeKind)
}

// ===== role CRUD =====

func (s *impl) ListRoles(ctx context.Context, f dom.RoleFilter) ([]dom.Role, int64, error) {
	return s.repo.ListRoles(ctx, f)
}

func (s *impl) GetRole(ctx context.Context, id int64) (*RoleWithPerms, error) {
	r, err := s.repo.GetRoleByID(ctx, id)
	if err != nil {
		return nil, err
	}
	pids, _ := s.repo.ListRolePermissionIDs(ctx, id)
	return &RoleWithPerms{Role: r, PermissionIDs: pids}, nil
}

func (s *impl) GetRoleByCode(ctx context.Context, scopeKind, code string, tenantID *int64) (*dom.Role, error) {
	return s.repo.GetRoleByCode(ctx, scopeKind, code, tenantID)
}

func (s *impl) CreateRole(ctx context.Context, in dom.RoleInput) (*RoleWithPerms, error) {
	if in.Code == "" || in.Name == "" {
		return nil, apperr.ErrInvalidParams.Withf("code/name 必填")
	}
	switch in.ScopeKind {
	case "platform":
		if in.TenantID != nil {
			return nil, apperr.ErrInvalidParams.Withf("platform 角色不能挂 tenant_id")
		}
	case "tenant":
		if in.TenantID == nil || *in.TenantID == 0 {
			return nil, apperr.ErrInvalidParams.Withf("tenant 角色必须指定 tenant_id")
		}
	default:
		return nil, apperr.ErrInvalidParams.Withf("scope_kind 必须为 platform 或 tenant")
	}
	r, err := s.repo.CreateRole(ctx, in)
	if err != nil {
		return nil, err
	}
	s.clearMenuCache()
	pids, _ := s.repo.ListRolePermissionIDs(ctx, r.ID)
	return &RoleWithPerms{Role: r, PermissionIDs: pids}, nil
}

func (s *impl) UpdateRole(ctx context.Context, id int64, in dom.RoleInput) (*RoleWithPerms, error) {
	r, err := s.repo.UpdateRole(ctx, id, in)
	if err != nil {
		return nil, err
	}
	s.clearMenuCache()
	pids, _ := s.repo.ListRolePermissionIDs(ctx, id)
	return &RoleWithPerms{Role: r, PermissionIDs: pids}, nil
}

func (s *impl) DeleteRole(ctx context.Context, id int64) error {
	if err := s.repo.DeleteRole(ctx, id); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

// ===== role assignments =====

func (s *impl) AssignRole(ctx context.Context, a *dom.RoleAssignment) error {
	if err := s.repo.AssignRole(ctx, a); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

func (s *impl) RevokeAssignment(ctx context.Context, id int64) error {
	if err := s.repo.RevokeAssignment(ctx, id); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

func (s *impl) RevokeAssignmentByTuple(ctx context.Context, accountID, roleID int64, scopeKind string, tenantID, workspaceID *int64) error {
	if err := s.repo.RevokeAssignmentByTuple(ctx, accountID, roleID, scopeKind, tenantID, workspaceID); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

func (s *impl) ListMemberAssignments(ctx context.Context, accountID, tenantID int64) ([]dom.RoleAssignment, error) {
	return s.repo.ListAssignmentsByMember(ctx, accountID, tenantID)
}

// ===== menu CRUD =====

func (s *impl) ListMenus(ctx context.Context, all bool) ([]dom.Menu, error) {
	if all {
		return s.repo.ListAllMenus(ctx)
	}
	// 默认只返可见
	return s.repo.ListMenusForScopes(ctx, []string{"platform", "tenant", "workspace", "self", "any"})
}

func (s *impl) GetMenu(ctx context.Context, id int64) (*MenuWithPerms, error) {
	m, err := s.repo.GetMenuByID(ctx, id)
	if err != nil {
		return nil, err
	}
	pids, _ := s.repo.ListMenuPermissionIDs(ctx, id)
	return &MenuWithPerms{Menu: m, PermissionIDs: pids}, nil
}

func (s *impl) CreateMenu(ctx context.Context, in dom.MenuInput) (*MenuWithPerms, error) {
	if in.Name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name 必填")
	}
	switch in.ScopeKind {
	case "platform", "tenant", "workspace", "self", "any":
	default:
		return nil, apperr.ErrInvalidParams.Withf("scope_kind 非法")
	}
	m, err := s.repo.CreateMenu(ctx, in)
	if err != nil {
		return nil, err
	}
	s.clearMenuCache()
	pids, _ := s.repo.ListMenuPermissionIDs(ctx, m.ID)
	return &MenuWithPerms{Menu: m, PermissionIDs: pids}, nil
}

func (s *impl) UpdateMenu(ctx context.Context, id int64, in dom.MenuInput) (*MenuWithPerms, error) {
	m, err := s.repo.UpdateMenu(ctx, id, in)
	if err != nil {
		return nil, err
	}
	s.clearMenuCache()
	pids, _ := s.repo.ListMenuPermissionIDs(ctx, id)
	return &MenuWithPerms{Menu: m, PermissionIDs: pids}, nil
}

func (s *impl) DeleteMenu(ctx context.Context, id int64) error {
	if err := s.repo.DeleteMenu(ctx, id); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

// ===== M3 D8 option C impersonate =====

func (s *impl) IssueImpersonateAssignment(ctx context.Context, accountID, targetTenantID int64, expiresAt time.Time, grantedBy *int64) (int64, error) {
	if accountID <= 0 || targetTenantID <= 0 {
		return 0, apperr.ErrInvalidParams
	}
	return s.repo.IssueImpersonateAssignment(ctx, accountID, targetTenantID, expiresAt, grantedBy)
}

func (s *impl) DeleteImpersonateAssignment(ctx context.Context, id int64) error {
	if id <= 0 {
		return apperr.ErrInvalidParams
	}
	if err := s.repo.DeleteImpersonateAssignment(ctx, id); err != nil {
		return err
	}
	s.clearMenuCache()
	return nil
}

func (s *impl) CleanupExpiredImpersonate(ctx context.Context) (int64, error) {
	return s.repo.CleanupExpiredImpersonate(ctx)
}
