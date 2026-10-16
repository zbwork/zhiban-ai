package rbac

import (
	"context"
	"time"
)

// Permission 权限点。
type Permission struct {
	ID        int64
	Code      string
	Name      string
	Kind      string // menu/api/data
	ScopeKind string // platform/tenant/workspace/self
	Resource  string
	Action    string
	Category  string
	IsSystem  bool
	SortOrder int
}

// Role 角色。
type Role struct {
	ID          int64
	UUID        string
	ScopeKind   string // platform / tenant
	TenantID    *int64
	Code        string
	Name        string
	Description string
	IsSystem    bool
	CreatedAt   time.Time
}

// RoleAssignment 账号 × scope × 角色。
type RoleAssignment struct {
	ID            int64
	AccountID     int64
	RoleID        int64
	ScopeKind     string
	TenantID      *int64
	WorkspaceID   *int64
	ExpiresAt     *time.Time
	GrantedReason string // normal | impersonate | ... (M3 加列; impersonate 行不在 scope switch 列出)
	CreatedAt     time.Time
}

// ScopeSummary 是 /admin/me 使用的 scope × roles × perms 聚合结果。
// Repo 层一次性聚合，避免 service 按 role/scope 逐条回表。
type ScopeSummary struct {
	Kind        string
	TenantID    int64
	WorkspaceID int64
	Roles       []string
	Perms       []string
	IsAdmin     bool
}

// Menu 菜单项。
type Menu struct {
	ID        int64          `json:"id"`
	UUID      string         `json:"uuid"`
	ParentID  *int64         `json:"parentId,omitempty"`
	Path      string         `json:"path"`
	Depth     int            `json:"depth"`
	Name      string         `json:"name"`
	Icon      string         `json:"icon"`
	Route     string         `json:"route"`
	SortOrder int            `json:"sortOrder"`
	ScopeKind string         `json:"scopeKind"`
	IsVisible bool           `json:"isVisible"`
	IsSystem  bool           `json:"isSystem"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}

// RoleFilter 列角色用的过滤条件。
type RoleFilter struct {
	ScopeKind string // 空 = 不限; platform/tenant
	TenantID  *int64
	Keyword   string
	Limit     int
	Offset    int
}

// RoleInput 创建/更新角色。
type RoleInput struct {
	ScopeKind     string
	TenantID      *int64
	Code          string
	Name          string
	Description   string
	PermissionIDs []int64
}

// MenuInput 创建/更新菜单节点。
type MenuInput struct {
	ParentID      *int64
	Name          string
	Icon          string
	Route         string
	SortOrder     int
	ScopeKind     string
	IsVisible     bool
	Metadata      map[string]any
	PermissionIDs []int64
}

// Repository 持久化接口。
type Repository interface {
	// permissions
	ListPermissionCodesForAccount(ctx context.Context, accountID int64, tenantID int64) ([]string, error)
	ListPermissionCodesForAccountAllScopes(ctx context.Context, accountID int64) ([]string, error)
	ListPermissions(ctx context.Context, scopeKind string) ([]Permission, error)
	GetPermissionByCode(ctx context.Context, code string) (*Permission, error)

	// roles
	GetRoleByCode(ctx context.Context, scopeKind, code string, tenantID *int64) (*Role, error)
	GetRoleByID(ctx context.Context, id int64) (*Role, error)
	ListRoles(ctx context.Context, f RoleFilter) ([]Role, int64, error)
	CreateRole(ctx context.Context, in RoleInput) (*Role, error)
	UpdateRole(ctx context.Context, id int64, in RoleInput) (*Role, error)
	DeleteRole(ctx context.Context, id int64) error
	ListRolePermissionIDs(ctx context.Context, roleID int64) ([]int64, error)
	SetRolePermissions(ctx context.Context, roleID int64, permissionIDs []int64) error

	// role assignments
	AssignRole(ctx context.Context, a *RoleAssignment) error
	RevokeAssignment(ctx context.Context, id int64) error
	RevokeAssignmentByTuple(ctx context.Context, accountID, roleID int64, scopeKind string, tenantID, workspaceID *int64) error
	ListAssignments(ctx context.Context, accountID int64) ([]RoleAssignment, error)
	ListScopeSummariesForAccount(ctx context.Context, accountID int64) ([]ScopeSummary, error)
	ListAssignmentsByMember(ctx context.Context, accountID int64, tenantID int64) ([]RoleAssignment, error)

	// M3 (F01 §4.3-bis D8 option C): 系统颁发临时 impersonate role_assignment。
	//
	//   - 自动找 target_tenant 的 tenant.admin 角色 id
	//   - 写入 role_assignments(account_id, role_id, scope_kind='tenant', tenant_id=X,
	//     expires_at, granted_by, granted_reason='impersonate')
	//   - 返回新行 id (auth/service 关掉 impersonate 时调 DeleteImpersonateAssignment)
	IssueImpersonateAssignment(ctx context.Context, accountID, targetTenantID int64, expiresAt time.Time, grantedBy *int64) (int64, error)
	// DeleteImpersonateAssignment 硬删 (仅限 granted_reason='impersonate'); 防止误删真实授权。
	DeleteImpersonateAssignment(ctx context.Context, id int64) error
	// CleanupExpiredImpersonate 删 expires_at <= now() 的 impersonate 行 (后台 cron 调)。
	CleanupExpiredImpersonate(ctx context.Context) (int64, error)

	// 后台管理员判定 (M1 §3.3.1): 账号是否拥有 platform.admin 或任意租户的 tenant.admin。
	// 用于 admin 端登录与中间件级 RBAC 闸门。
	HasAdminRole(ctx context.Context, accountID int64) (bool, error)
	// 列出菜单 → 权限 code 的映射 (用于 ListMenu 按 caller 权限过滤)。
	ListMenuPermissionCodes(ctx context.Context) (map[int64][]string, error)

	// menus
	ListVisibleMenusForAccountAllScopes(ctx context.Context, accountID int64, scopeKinds []string) ([]Menu, error)
	ListMenusForScopes(ctx context.Context, scopeKinds []string) ([]Menu, error)
	ListAllMenus(ctx context.Context) ([]Menu, error)
	GetMenuByID(ctx context.Context, id int64) (*Menu, error)
	CreateMenu(ctx context.Context, in MenuInput) (*Menu, error)
	UpdateMenu(ctx context.Context, id int64, in MenuInput) (*Menu, error)
	DeleteMenu(ctx context.Context, id int64) error
	ListMenuPermissionIDs(ctx context.Context, menuID int64) ([]int64, error)
	SetMenuPermissions(ctx context.Context, menuID int64, permissionIDs []int64) error
}
