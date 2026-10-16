package account

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Repo Postgres 实现的 account.Repository。
type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const baseAccountCols = `id, uuid, email, phone, username, display_name, avatar_url,
    locale, timezone, status, mfa_enabled, email_verified_at, password_hash, last_login_at,
    created_at, updated_at`

const baseAccountColsA = `a.id, a.uuid, a.email, a.phone, a.username, a.display_name, a.avatar_url,
    a.locale, a.timezone, a.status, a.mfa_enabled, a.email_verified_at, a.password_hash, a.last_login_at,
    a.created_at, a.updated_at`

func scanAccount(row pgx.Row) (*dom.Account, error) {
	var a dom.Account
	var email, phone, username, avatar, locale, tz, ph *string
	var emailVerifiedAt, last *time.Time
	if err := row.Scan(&a.ID, &a.UUID, &email, &phone, &username, &a.DisplayName, &avatar,
		&locale, &tz, &a.Status, &a.MFAEnabled, &emailVerifiedAt, &ph, &last,
		&a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	if email != nil {
		a.Email = *email
	}
	if phone != nil {
		a.Phone = *phone
	}
	if username != nil {
		a.Username = *username
	}
	if avatar != nil {
		a.AvatarURL = *avatar
	}
	if locale != nil {
		a.Locale = *locale
	}
	if tz != nil {
		a.Timezone = *tz
	}
	if ph != nil {
		a.PasswordHash = *ph
	}
	a.EmailVerifiedAt = emailVerifiedAt
	if last != nil {
		a.LastLoginAt = last
	}
	return &a, nil
}

func scanAccountWithMustChange(row pgx.Row) (*dom.Account, bool, error) {
	var a dom.Account
	var email, phone, username, avatar, locale, tz, ph *string
	var emailVerifiedAt, last *time.Time
	var mustChange bool
	if err := row.Scan(&a.ID, &a.UUID, &email, &phone, &username, &a.DisplayName, &avatar,
		&locale, &tz, &a.Status, &a.MFAEnabled, &emailVerifiedAt, &ph, &last,
		&a.CreatedAt, &a.UpdatedAt, &mustChange); err != nil {
		return nil, false, err
	}
	if email != nil {
		a.Email = *email
	}
	if phone != nil {
		a.Phone = *phone
	}
	if username != nil {
		a.Username = *username
	}
	if avatar != nil {
		a.AvatarURL = *avatar
	}
	if locale != nil {
		a.Locale = *locale
	}
	if tz != nil {
		a.Timezone = *tz
	}
	if ph != nil {
		a.PasswordHash = *ph
	}
	a.EmailVerifiedAt = emailVerifiedAt
	if last != nil {
		a.LastLoginAt = last
	}
	return &a, mustChange, nil
}

// tenantDisplayNameSQL 与 conversation 包的 conversationHumanDisplayNameSQL /
// call 包的 callParticipantDisplayNameSQL 同口径 (优先 tenant_memberships.nickname，
// 回退 accounts.display_name，过滤系统占位名)；三处都是 SQL 片段字面量，不跨包共享
// 常量，改动时需同步。
const tenantDisplayNameSQL = `COALESCE(
	NULLIF(BTRIM(tm.nickname), ''),
	CASE
		WHEN NULLIF(BTRIM(a.display_name), '') IS NULL THEN ''
		WHEN BTRIM(a.display_name) LIKE '%的组织 管理员%' THEN ''
		WHEN BTRIM(a.display_name) LIKE '预热优化%' THEN ''
		ELSE NULLIF(BTRIM(a.display_name), '')
	END,
	''
)`

// tenantOwnerDisplayNameSQL 用于云盘等必须明确展示资产所有者的场景。
// 与聊天/RTC 不同，这里不能把仍是系统占位名的 accounts.display_name 清空，
// 否则文件有合法 created_by，客户端「所有者」列却只能显示空值。
const tenantOwnerDisplayNameSQL = `COALESCE(
	NULLIF(BTRIM(tm.nickname), ''),
	NULLIF(BTRIM(a.display_name), ''),
	''
)`

// GetTenantDisplayName 取账号在某租户下的展示名，与会话列表/通讯录同口径。
// 用于 RTC 1001 invite 信令等"要展示给别人看"的场景——直接用 accounts.display_name
// 会把租户占位名（如"用户 N 的组织 管理员"）也下发给客户端。
func (r *Repo) GetTenantDisplayName(ctx context.Context, tenantID, accountID int64) (string, error) {
	var name string
	err := r.pool.QueryRow(ctx, `
SELECT `+tenantDisplayNameSQL+`
  FROM accounts a
  LEFT JOIN tenant_memberships tm ON tm.tenant_id=$1 AND tm.account_id=a.id
 WHERE a.id=$2 AND a.deleted_at IS NULL`, tenantID, accountID).Scan(&name)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", apperr.ErrNotFound
		}
		return "", err
	}
	return name, nil
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE id=$1 AND deleted_at IS NULL`, id)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

// ListByIDs 批量按 id 查; 与 GetByID 同口径 deleted_at IS NULL, 缺失/软删 id 不返回.
// drive discover 列表批量补齐 owner 展示字段用 (替代逐 file GetByID N+1).
func (r *Repo) ListByIDs(ctx context.Context, ids []int64) ([]dom.Account, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE id = ANY($1) AND deleted_at IS NULL`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Account
	for rows.Next() {
		a, err := scanAccount(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// ListByIDsForTenant 批量查询租户内账号展示资料。
// DisplayName 按 tenant_memberships.nickname → accounts.display_name 投影，
// 使云盘等租户内列表在用户改名后立即展示新名称。账号存在时保留全局默认名
// 作为最终回退，避免资产所有者列因系统占位名过滤而为空。
func (r *Repo) ListByIDsForTenant(ctx context.Context, tenantID int64, ids []int64) ([]dom.Account, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx, `
SELECT a.id, a.uuid, a.email, a.phone, a.username, `+tenantOwnerDisplayNameSQL+` AS display_name, a.avatar_url,
       a.locale, a.timezone, a.status, a.mfa_enabled, a.email_verified_at, a.password_hash, a.last_login_at,
       a.created_at, a.updated_at
  FROM accounts a
  LEFT JOIN tenant_memberships tm
    ON tm.tenant_id=$1 AND tm.account_id=a.id AND tm.deleted_at IS NULL
 WHERE a.id = ANY($2) AND a.deleted_at IS NULL`, tenantID, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Account
	for rows.Next() {
		a, err := scanAccount(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// GetProviderUID 返回账号在指定外部身份源上的唯一主体 ID。
func (r *Repo) GetProviderUID(ctx context.Context, accountID int64, provider string) (string, error) {
	provider = strings.TrimSpace(provider)
	if accountID <= 0 || provider == "" {
		return "", apperr.ErrInvalidParams
	}
	var providerUID string
	err := r.pool.QueryRow(ctx, `
SELECT provider_uid
  FROM account_identities
 WHERE account_id=$1 AND provider=$2
 ORDER BY last_used_at DESC NULLS LAST, linked_at DESC
 LIMIT 1`, accountID, provider).Scan(&providerUID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", apperr.ErrNotFound
		}
		return "", err
	}
	return providerUID, nil
}

func (r *Repo) GetByIDWithAdminStatus(ctx context.Context, id int64) (*dom.AccountWithAdminStatus, error) {
	row := r.pool.QueryRow(ctx, `
SELECT `+baseAccountColsA+`, COALESCE(aa.must_change_password, false)
  FROM accounts a
  LEFT JOIN admin_accounts aa ON aa.account_id = a.id
 WHERE a.id=$1 AND a.deleted_at IS NULL`, id)
	a, mustChange, err := scanAccountWithMustChange(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return &dom.AccountWithAdminStatus{Account: a, MustChangePassword: mustChange}, nil
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE uuid=$1 AND deleted_at IS NULL`, uuid)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

func (r *Repo) GetByEmail(ctx context.Context, email string) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE LOWER(email)=LOWER($1) AND deleted_at IS NULL`, email)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

func (r *Repo) GetByPhone(ctx context.Context, phone string) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE phone=$1 AND deleted_at IS NULL`, phone)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

func (r *Repo) GetByUsername(ctx context.Context, username string) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseAccountCols+` FROM accounts WHERE username=$1 AND deleted_at IS NULL`, username)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

func (r *Repo) Create(ctx context.Context, a *dom.Account) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO accounts (email, phone, username, display_name, password_hash, status, mfa_enabled, locale, timezone)
		VALUES (NULLIF($1,''), NULLIF($2,''), NULLIF($3,''), $4, NULLIF($5,''), COALESCE(NULLIF($6,''),'active'), $7, COALESCE(NULLIF($8,''),'zh-CN'), COALESCE(NULLIF($9,''),'Asia/Shanghai'))
		RETURNING `+baseAccountCols,
		a.Email, a.Phone, a.Username, a.DisplayName, a.PasswordHash, a.Status, a.MFAEnabled, a.Locale, a.Timezone)
	return scanAccount(row)
}

func (r *Repo) UpdatePassword(ctx context.Context, accountID int64, ph string) error {
	_, err := r.pool.Exec(ctx, `UPDATE accounts SET password_hash=$1, password_set_at=now(), updated_at=now() WHERE id=$2`, ph, accountID)
	return err
}

// IsAdminMustChangePassword 读 admin_accounts.must_change_password。
// 非 admin_account 行 / 找不到 → false。
func (r *Repo) IsAdminMustChangePassword(ctx context.Context, accountID int64) (bool, error) {
	var b bool
	err := r.pool.QueryRow(ctx, `SELECT must_change_password FROM admin_accounts WHERE account_id=$1`, accountID).Scan(&b)
	if err != nil {
		if err.Error() == "no rows in result set" || strings.Contains(err.Error(), "no rows") {
			return false, nil
		}
		return false, err
	}
	return b, nil
}

// SetAdminMustChangePassword 更新 admin_accounts.must_change_password；
// 非 admin_account 行 → 0 影响（no-op，不报错）。
// 置为 false 时同时刷新 last_password_change。
func (r *Repo) SetAdminMustChangePassword(ctx context.Context, accountID int64, mustChange bool) error {
	if mustChange {
		_, err := r.pool.Exec(ctx, `UPDATE admin_accounts SET must_change_password=true WHERE account_id=$1`, accountID)
		return err
	}
	_, err := r.pool.Exec(ctx, `UPDATE admin_accounts SET must_change_password=false, last_password_change=now() WHERE account_id=$1`, accountID)
	return err
}

// UpdateDisplayName · round-8 P1-1: 只改 display_name; 不动 avatar_url.
//
// 历史 UpdateProfile(displayName, avatarURL) 用 avatar_url=NULLIF($2,”) 会被空串清空头像,
// PATCH /account/profile 客户端不传头像就会把头像抹掉. round-8 拆成两条独立 UPDATE 后,
// /account/profile 只走 display_name, 头像唯一更新路径 = /account/avatar/confirm.
//
// 空 displayName 不报错 (NULLIF + COALESCE 保护既有值), 但 caller 也应该在 transport 层
// reject 空串 (display_name 字段意图是修改时必传).
func (r *Repo) UpdateDisplayName(ctx context.Context, accountID int64, displayName string) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE accounts SET display_name=COALESCE(NULLIF($1,''),display_name), updated_at=now() WHERE id=$2`,
		displayName, accountID)
	return err
}

// UpdateMembershipNickname 更新当前租户内的成员显示名; 不污染账号全局默认名.
func (r *Repo) UpdateMembershipNickname(ctx context.Context, accountID, tenantID int64, displayName string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE tenant_memberships
		   SET nickname=NULLIF($3,''), updated_at=now()
		 WHERE account_id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		accountID, tenantID, displayName)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// UpdateAvatarStorageKey · round-8 P1-2: 把 storage_key (稳定值) 写进 accounts.avatar_url.
//
// 历史 UpdateProfile 把 PresignGet 短期 URL 写库, OSS/S3 下 10min 后失效. round-8 改为
// 写 storage_key (e.g. "account-avatars/<tenant_id>/<account_id>/<ts>-<rand>.png"),
// auth.Me 时动态用 object store PresignGet 签出短期 URL 给客户端.
//
// 空 storageKey 拒绝 (caller 校验; repo 层只做 SQL).
func (r *Repo) UpdateAvatarStorageKey(ctx context.Context, accountID int64, storageKey string) error {
	if strings.TrimSpace(storageKey) == "" {
		return errors.New("storage_key must not be empty")
	}
	_, err := r.pool.Exec(ctx,
		`UPDATE accounts SET avatar_url=$1, updated_at=now() WHERE id=$2`,
		storageKey, accountID)
	return err
}

// ResetIdentityForSelfHeal 见 domain/account.Repository 上的接口注释:
// 只给 auth.LoginSms 零 scope 自愈分支用, 把 display_name 改成新默认值并清空 avatar_url。
func (r *Repo) ResetIdentityForSelfHeal(ctx context.Context, accountID int64, displayName string) error {
	if strings.TrimSpace(displayName) == "" {
		return errors.New("displayName must not be empty")
	}
	_, err := r.pool.Exec(ctx,
		`UPDATE accounts SET display_name=$1, avatar_url=NULL, updated_at=now() WHERE id=$2`,
		displayName, accountID)
	return err
}

func (r *Repo) UpdateLastLogin(ctx context.Context, accountID int64, ip string) error {
	if ip == "" {
		_, err := r.pool.Exec(ctx, `UPDATE accounts SET last_login_at=now(), updated_at=now() WHERE id=$1`, accountID)
		return err
	}
	_, err := r.pool.Exec(ctx, `UPDATE accounts SET last_login_at=now(), last_login_ip=$1::inet, updated_at=now() WHERE id=$2`, ip, accountID)
	return err
}

func (r *Repo) ListMemberships(ctx context.Context, accountID int64) ([]dom.Membership, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT tm.id, tm.account_id, tm.tenant_id, tm.department_id,
		       COALESCE(tm.employee_id,''), COALESCE(d.path,''),
		       COALESCE(tm.title,''), COALESCE(tm.nickname,''), tm.status, tm.joined_at, tm.created_at
		FROM tenant_memberships tm
		LEFT JOIN departments d ON d.id=tm.department_id AND d.tenant_id=tm.tenant_id AND d.deleted_at IS NULL
		WHERE tm.account_id=$1 AND tm.deleted_at IS NULL`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Membership
	for rows.Next() {
		var m dom.Membership
		var deptID *int64
		var joined *time.Time
		if err := rows.Scan(&m.ID, &m.AccountID, &m.TenantID, &deptID, &m.EmployeeID, &m.DepartmentPath,
			&m.Title, &m.Nickname, &m.Status, &joined, &m.CreatedAt); err != nil {
			return nil, err
		}
		m.DepartmentID = deptID
		m.JoinedAt = joined
		out = append(out, m)
	}
	return out, rows.Err()
}

func (r *Repo) CreateMembership(ctx context.Context, m *dom.Membership) (*dom.Membership, error) {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO tenant_memberships (account_id, tenant_id, department_id, title, nickname, status, joined_at)
		VALUES ($1,$2,COALESCE((
			SELECT id FROM departments
			 WHERE id=$3 AND tenant_id=$2 AND deleted_at IS NULL
		), (
			SELECT id FROM departments
			 WHERE $3::bigint IS NULL AND tenant_id=$2 AND parent_id IS NULL AND deleted_at IS NULL
			 ORDER BY id LIMIT 1
		)),NULLIF($4,''),NULLIF($5,''),COALESCE(NULLIF($6,''),'active'), now())
		RETURNING id, created_at`, m.AccountID, m.TenantID, m.DepartmentID, m.Title, m.Nickname, m.Status)
	if err := row.Scan(&m.ID, &m.CreatedAt); err != nil {
		return nil, err
	}
	return m, nil
}

func (r *Repo) GetMembership(ctx context.Context, accountID, tenantID int64) (*dom.Membership, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT tm.id, tm.account_id, tm.tenant_id, tm.department_id,
		       COALESCE(tm.employee_id,''), COALESCE(d.path,''),
		       COALESCE(tm.title,''), COALESCE(tm.nickname,''), tm.status, tm.joined_at, tm.created_at
		FROM tenant_memberships tm
		LEFT JOIN departments d ON d.id=tm.department_id AND d.tenant_id=tm.tenant_id AND d.deleted_at IS NULL
		WHERE tm.account_id=$1 AND tm.tenant_id=$2 AND tm.deleted_at IS NULL`, accountID, tenantID)
	var m dom.Membership
	var deptID *int64
	var joined *time.Time
	if err := row.Scan(&m.ID, &m.AccountID, &m.TenantID, &deptID, &m.EmployeeID, &m.DepartmentPath,
		&m.Title, &m.Nickname, &m.Status, &joined, &m.CreatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	m.DepartmentID = deptID
	m.JoinedAt = joined
	return &m, nil
}

func (r *Repo) TenantExists(ctx context.Context, tenantID int64) (bool, error) {
	if tenantID <= 0 {
		return false, nil
	}
	var exists bool
	err := r.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM tenants WHERE id=$1 AND deleted_at IS NULL)`,
		tenantID,
	).Scan(&exists)
	return exists, err
}

// FindByProviderUID 按 (provider, provider_uid) 反查 account (M4 OIDC callback)。
func (r *Repo) FindByProviderUID(ctx context.Context, provider, providerUID string) (*dom.Account, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+baseAccountColsA+`
		  FROM accounts a
		  JOIN account_identities ai ON ai.account_id = a.id
		 WHERE ai.provider=$1 AND ai.provider_uid=$2 AND a.deleted_at IS NULL`, provider, providerUID)
	a, err := scanAccount(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return a, nil
}

// LinkIdentity upsert account_identities; last_used_at 更新到 now。
func (r *Repo) LinkIdentity(ctx context.Context, accountID int64, provider, providerUID string, meta map[string]any) error {
	if accountID <= 0 || provider == "" || providerUID == "" {
		return apperr.ErrInvalidParams
	}
	if meta == nil {
		meta = map[string]any{}
	}
	metaJSON, _ := json.Marshal(meta)
	_, err := r.pool.Exec(ctx, `
		INSERT INTO account_identities (account_id, provider, provider_uid, provider_meta, last_used_at)
		VALUES ($1, $2, $3, $4::jsonb, now())
		ON CONFLICT (provider, provider_uid)
		DO UPDATE SET account_id = EXCLUDED.account_id,
		              provider_meta = EXCLUDED.provider_meta,
		              last_used_at = now()`,
		accountID, provider, providerUID, string(metaJSON))
	return err
}
