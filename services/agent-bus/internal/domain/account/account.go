package account

import (
	"context"
	"time"
)

// Account 是用户主体。
type Account struct {
	ID              int64      `json:"id"`
	UUID            string     `json:"uuid"`
	Email           string     `json:"email,omitempty"`
	Phone           string     `json:"phone,omitempty"`
	Username        string     `json:"username,omitempty"`
	DisplayName     string     `json:"display_name"`
	AvatarURL       string     `json:"avatar_url,omitempty"`
	Locale          string     `json:"locale,omitempty"`
	Timezone        string     `json:"timezone,omitempty"`
	Status          string     `json:"status"`
	MFAEnabled      bool       `json:"mfa_enabled"`
	EmailVerifiedAt *time.Time `json:"email_verified_at,omitempty"`
	PasswordHash    string     `json:"-"`
	LastLoginAt     *time.Time `json:"last_login_at,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type AccountWithAdminStatus struct {
	Account            *Account
	MustChangePassword bool
}

// Membership 表示一个账号在某租户的成员关系。
type Membership struct {
	ID             int64
	AccountID      int64
	TenantID       int64
	DepartmentID   *int64
	EmployeeID     string
	DepartmentPath string
	Title          string
	Nickname       string
	Status         string
	JoinedAt       *time.Time
	CreatedAt      time.Time
}

// Repository 持久化接口。
type Repository interface {
	GetByID(ctx context.Context, id int64) (*Account, error)
	GetByIDWithAdminStatus(ctx context.Context, id int64) (*AccountWithAdminStatus, error)
	GetByUUID(ctx context.Context, uuid string) (*Account, error)
	GetByEmail(ctx context.Context, email string) (*Account, error)
	GetByPhone(ctx context.Context, phone string) (*Account, error)
	GetByUsername(ctx context.Context, username string) (*Account, error)
	Create(ctx context.Context, a *Account) (*Account, error)
	UpdatePassword(ctx context.Context, accountID int64, passwordHash string) error
	// UpdateDisplayName 只改 accounts.display_name; 作为跨租户默认名使用.
	UpdateDisplayName(ctx context.Context, accountID int64, displayName string) error
	// UpdateMembershipNickname 只改 caller 在当前租户内的成员显示名.
	UpdateMembershipNickname(ctx context.Context, accountID, tenantID int64, displayName string) error
	// UpdateAvatarStorageKey round-8 P1-2: 写稳定 storage_key 到 accounts.avatar_url.
	// /account/avatar/confirm 是唯一允许更新头像字段的路径 (下面 ResetIdentityForSelfHeal
	// 是另一条独立、窄用途的例外, 不复用这个方法).
	UpdateAvatarStorageKey(ctx context.Context, accountID int64, storageKey string) error
	// ResetIdentityForSelfHeal 把 display_name 改成 displayName 并清空 avatar_url。
	// 唯一调用方: auth.LoginSms 的零 scope 自愈分支 (2026-08-21) ——账号当前在任何
	// 租户都没有有效 scope 时, 复用账号自助建一个新租户, 不应该把上一个租户(已被
	// 移出)时期留下的真实姓名/头像带进这个全新租户。调用前必须已确认该账号 0 个
	// 有效 scope, 否则会影响其它租户看到的身份。
	ResetIdentityForSelfHeal(ctx context.Context, accountID int64, displayName string) error
	UpdateLastLogin(ctx context.Context, accountID int64, ip string) error

	ListMemberships(ctx context.Context, accountID int64) ([]Membership, error)
	CreateMembership(ctx context.Context, m *Membership) (*Membership, error)
	GetMembership(ctx context.Context, accountID, tenantID int64) (*Membership, error)
	TenantExists(ctx context.Context, tenantID int64) (bool, error)

	// IsAdminMustChangePassword 读 admin_accounts.must_change_password。
	// 非 admin_account 行 / 找不到 → 返回 (false, nil)。
	IsAdminMustChangePassword(ctx context.Context, accountID int64) (bool, error)
	// SetAdminMustChangePassword 设置 must_change_password 并更新 last_password_change（force=true 时）。
	SetAdminMustChangePassword(ctx context.Context, accountID int64, mustChange bool) error

	// FindByProviderUID 按 (provider, provider_uid) 查 account; 找不到返 ErrNotFound。
	// OIDC callback 用: 拿外部 IdP 的 sub claim 反查本地账号。
	FindByProviderUID(ctx context.Context, provider, providerUID string) (*Account, error)
	// LinkIdentity 把外部 (provider, provider_uid) 绑到本地 accountID; 已存在则更新 last_used_at。
	LinkIdentity(ctx context.Context, accountID int64, provider, providerUID string, meta map[string]any) error
}
