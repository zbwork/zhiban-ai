package sysuser

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// User 是平台员工账号视图。
type User struct {
	ID                 int64    `json:"id"`
	AccountID          int64    `json:"account_id"`
	UUID               string   `json:"uuid"`
	Email              string   `json:"email,omitempty"`
	Phone              string   `json:"phone,omitempty"`
	Username           string   `json:"username,omitempty"`
	DisplayName        string   `json:"display_name"`
	Status             string   `json:"status"`
	MFAEnabled         bool     `json:"mfa_enabled"`
	IsPlatform         bool     `json:"is_platform"`
	MustChangePassword bool     `json:"must_change_password"`
	Notes              string   `json:"notes,omitempty"`
	LastLoginAt        string   `json:"last_login_at,omitempty"`
	CreatedAt          string   `json:"created_at"`
	RoleIDs            []int64  `json:"role_ids"`
	Roles              []string `json:"roles"`
}

type CreateInput struct {
	Email              string  `json:"email"`
	Phone              string  `json:"phone"`
	Username           string  `json:"username"`
	DisplayName        string  `json:"display_name"`
	Password           string  `json:"password"`
	Status             string  `json:"status"`
	MFAEnabled         bool    `json:"mfa_enabled"`
	IsPlatform         bool    `json:"is_platform"`
	MustChangePassword bool    `json:"must_change_password"`
	Notes              string  `json:"notes"`
	RoleIDs            []int64 `json:"role_ids"`
}

type UpdateInput struct {
	Email              *string `json:"email"`
	Phone              *string `json:"phone"`
	Username           *string `json:"username"`
	DisplayName        *string `json:"display_name"`
	Status             *string `json:"status"`
	MFAEnabled         *bool   `json:"mfa_enabled"`
	IsPlatform         *bool   `json:"is_platform"`
	MustChangePassword *bool   `json:"must_change_password"`
	Notes              *string `json:"notes"`
	RoleIDs            []int64 `json:"role_ids"`
}

type Service interface {
	List(ctx context.Context, keyword string, limit, offset int) ([]User, int64, error)
	Get(ctx context.Context, id int64) (*User, error)
	Create(ctx context.Context, in CreateInput) (*User, error)
	Update(ctx context.Context, id int64, in UpdateInput) (*User, error)
	Suspend(ctx context.Context, id int64) error
}

type impl struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) Service { return &impl{pool: pool} }

const baseUserSelect = `
SELECT aa.id, a.id, a.uuid, COALESCE(a.email,''), COALESCE(a.phone,''), COALESCE(a.username,''),
       a.display_name, a.status, a.mfa_enabled, aa.is_platform, aa.must_change_password,
       COALESCE(aa.notes,''), COALESCE(to_char(a.last_login_at, 'YYYY-MM-DD HH24:MI'), ''),
       to_char(aa.created_at, 'YYYY-MM-DD HH24:MI'),
       COALESCE(
         (SELECT array_agg(r.id ORDER BY r.code)
            FROM role_assignments ra
            JOIN roles r ON r.id = ra.role_id
           WHERE ra.account_id = a.id
             AND ra.scope_kind = 'platform'
             AND ra.deleted_at IS NULL),
         '{}'
       ),
       COALESCE(
         (SELECT array_agg(r.code ORDER BY r.code)
            FROM role_assignments ra
            JOIN roles r ON r.id = ra.role_id
           WHERE ra.account_id = a.id
             AND ra.scope_kind = 'platform'
             AND ra.deleted_at IS NULL),
         '{}'
       )
  FROM admin_accounts aa
  JOIN accounts a ON a.id = aa.account_id
`

const platformSysUserPredicate = `(
    aa.is_platform = true
    OR EXISTS (
      SELECT 1
        FROM role_assignments pra
       WHERE pra.account_id = a.id
         AND pra.scope_kind = 'platform'
         AND pra.deleted_at IS NULL
    )
    OR (
      NOT EXISTS (
        SELECT 1
          FROM tenant_memberships tm
         WHERE tm.account_id = a.id
           AND tm.deleted_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
          FROM role_assignments tra
         WHERE tra.account_id = a.id
           AND tra.scope_kind = 'tenant'
           AND tra.deleted_at IS NULL
      )
    )
  )`

func scanUser(row pgx.Row) (*User, error) {
	var u User
	if err := row.Scan(&u.ID, &u.AccountID, &u.UUID, &u.Email, &u.Phone, &u.Username,
		&u.DisplayName, &u.Status, &u.MFAEnabled, &u.IsPlatform, &u.MustChangePassword,
		&u.Notes, &u.LastLoginAt, &u.CreatedAt, &u.RoleIDs, &u.Roles); err != nil {
		// QA-2026-07-02 BUG-2: 查不到系统用户返回 404，而非把 pgx.ErrNoRows 透到 transport 变 500。
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("系统用户不存在")
		}
		return nil, err
	}
	return &u, nil
}

func listSysUserWhere(keyword string) (string, []any) {
	args := []any{}
	where := []string{"aa.deleted_at IS NULL", "a.deleted_at IS NULL", platformSysUserPredicate}
	if strings.TrimSpace(keyword) != "" {
		args = append(args, "%"+strings.TrimSpace(keyword)+"%")
		where = append(where, "(a.display_name ILIKE $1 OR a.username ILIKE $1 OR a.email ILIKE $1 OR a.phone ILIKE $1)")
	}
	return " WHERE " + strings.Join(where, " AND "), args
}

func (s *impl) List(ctx context.Context, keyword string, limit, offset int) ([]User, int64, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	whereSQL, args := listSysUserWhere(keyword)
	args = append(args, limit, offset)
	listSelect := strings.Replace(baseUserSelect, "\n  FROM admin_accounts", ", COUNT(*) OVER()\n  FROM admin_accounts", 1)
	rows, err := s.pool.Query(ctx, listSelect+whereSQL+` ORDER BY aa.created_at DESC LIMIT $`+itoa(len(args)-1)+` OFFSET $`+itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []User
	var total int64
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.AccountID, &u.UUID, &u.Email, &u.Phone, &u.Username,
			&u.DisplayName, &u.Status, &u.MFAEnabled, &u.IsPlatform, &u.MustChangePassword,
			&u.Notes, &u.LastLoginAt, &u.CreatedAt, &u.RoleIDs, &u.Roles, &total); err != nil {
			return nil, 0, err
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := s.pool.QueryRow(ctx, `SELECT count(*)
  FROM admin_accounts aa JOIN accounts a ON a.id = aa.account_id`+whereSQL, args[:len(args)-2]...).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

func (s *impl) Get(ctx context.Context, id int64) (*User, error) {
	return scanUser(s.pool.QueryRow(ctx, baseUserSelect+` WHERE aa.id=$1 AND aa.deleted_at IS NULL AND a.deleted_at IS NULL AND `+platformSysUserPredicate, id))
}

func (s *impl) Create(ctx context.Context, in CreateInput) (*User, error) {
	in.DisplayName = strings.TrimSpace(in.DisplayName)
	if in.DisplayName == "" {
		return nil, apperr.ErrInvalidParams.Withf("display_name 必填")
	}
	email := strings.TrimSpace(in.Email)
	phone := strings.TrimSpace(in.Phone)
	username := strings.TrimSpace(in.Username)
	notes := strings.TrimSpace(in.Notes)
	if email == "" && phone == "" && username == "" {
		return nil, apperr.ErrInvalidParams.Withf("email/phone/username 至少填写一个")
	}
	status := in.Status
	if status == "" {
		status = "active"
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	accountID, err := resolveSysUserAccountID(ctx, tx, email, phone, username)
	if err != nil {
		return nil, err
	}
	if accountID == 0 {
		password := strings.TrimSpace(in.Password)
		if password == "" {
			return nil, apperr.ErrInvalidParams.Withf("password 必填")
		}
		hash, err := crypto.HashPassword(password)
		if err != nil {
			return nil, err
		}
		if err := tx.QueryRow(ctx, `
INSERT INTO accounts (email, phone, username, display_name, password_hash, password_set_at, status, mfa_enabled, locale, timezone)
VALUES (NULLIF($1,''), NULLIF($2,''), NULLIF($3,''), $4, $5, now(), $6, $7, 'zh-CN', 'Asia/Shanghai')
RETURNING id`, email, phone, username, in.DisplayName, hash, status, in.MFAEnabled).Scan(&accountID); err != nil {
			return nil, translateSysUserPgError(err)
		}
	}

	adminID, err := upsertAdminAccount(ctx, tx, accountID, in.IsPlatform, notes, in.MustChangePassword)
	if err != nil {
		return nil, err
	}
	if err := replacePlatformRoles(ctx, tx, accountID, in.RoleIDs); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.Get(ctx, adminID)
}

func (s *impl) Update(ctx context.Context, id int64, in UpdateInput) (*User, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var accountID int64
	if err := tx.QueryRow(ctx, `SELECT aa.account_id
  FROM admin_accounts aa
  JOIN accounts a ON a.id = aa.account_id
 WHERE aa.id=$1 AND aa.deleted_at IS NULL AND a.deleted_at IS NULL
   AND `+platformSysUserPredicate, id).Scan(&accountID); err != nil {
		// QA-2026-07-02 BUG-2: 更新不存在的系统用户返回 404 而非 500。
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("系统用户不存在")
		}
		return nil, err
	}
	_, err = tx.Exec(ctx, `
UPDATE accounts SET
  email = COALESCE(NULLIF($2,''), email),
  phone = COALESCE(NULLIF($3,''), phone),
  username = COALESCE(NULLIF($4,''), username),
  display_name = COALESCE(NULLIF($5,''), display_name),
  status = COALESCE(NULLIF($6,''), status),
  mfa_enabled = COALESCE($7, mfa_enabled),
  updated_at = now()
WHERE id=$1 AND deleted_at IS NULL`,
		accountID, stringPtrValue(in.Email), stringPtrValue(in.Phone), stringPtrValue(in.Username),
		stringPtrValue(in.DisplayName), stringPtrValue(in.Status), in.MFAEnabled)
	if err != nil {
		return nil, translateSysUserPgError(err)
	}
	_, err = tx.Exec(ctx, `
UPDATE admin_accounts SET
  is_platform = COALESCE($2, is_platform),
  must_change_password = COALESCE($3, must_change_password),
  notes = COALESCE($4, notes),
  updated_at = now()
WHERE id=$1 AND deleted_at IS NULL`, id, in.IsPlatform, in.MustChangePassword, in.Notes)
	if err != nil {
		return nil, err
	}
	if in.RoleIDs != nil {
		if err := replacePlatformRoles(ctx, tx, accountID, in.RoleIDs); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+itoa64(accountID)); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.Get(ctx, id)
}

func resolveSysUserAccountID(ctx context.Context, tx pgx.Tx, email, phone, username string) (int64, error) {
	rows, err := tx.Query(ctx, `
SELECT DISTINCT id
  FROM accounts
 WHERE deleted_at IS NULL
   AND (($1 <> '' AND lower(email) = lower($1))
     OR ($2 <> '' AND phone = $2)
     OR ($3 <> '' AND username = $3))`, email, phone, username)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	switch len(ids) {
	case 0:
		return 0, nil
	case 1:
		return ids[0], nil
	default:
		return 0, apperr.ErrConflict.Withf("email/phone/username 命中了不同账号")
	}
}

func upsertAdminAccount(ctx context.Context, tx pgx.Tx, accountID int64, isPlatform bool, notes string, mustChangePassword bool) (int64, error) {
	var adminID int64
	err := tx.QueryRow(ctx, `
INSERT INTO admin_accounts (account_id, is_platform, notes, must_change_password, last_password_change)
VALUES ($1, $2, NULLIF($3,''), $4, now())
ON CONFLICT (account_id) DO UPDATE SET
  is_platform = EXCLUDED.is_platform,
  notes = COALESCE(EXCLUDED.notes, admin_accounts.notes),
  must_change_password = EXCLUDED.must_change_password,
  deleted_at = NULL,
  updated_at = now()
RETURNING id`, accountID, isPlatform, notes, mustChangePassword).Scan(&adminID)
	if err != nil {
		return 0, translateSysUserPgError(err)
	}
	return adminID, nil
}

func translateSysUserPgError(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return err
	}
	switch pgErr.ConstraintName {
	case "accounts_phone_key":
		return apperr.ErrConflict.Withf("手机号已存在").Wrap(err)
	case "accounts_username_key":
		return apperr.ErrConflict.Withf("用户名已存在").Wrap(err)
	case "accounts_email_key", "uq_accounts_email_active":
		return apperr.ErrConflict.Withf("邮箱已存在").Wrap(err)
	case "admin_accounts_account_id_key":
		return apperr.ErrConflict.Withf("该账号已是系统用户").Wrap(err)
	default:
		return apperr.ErrConflict.Withf("系统用户已存在: %s", pgErr.ConstraintName).Wrap(err)
	}
}

func (s *impl) Suspend(ctx context.Context, id int64) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var accountID int64
	if err := tx.QueryRow(ctx, `SELECT aa.account_id
  FROM admin_accounts aa
  JOIN accounts a ON a.id = aa.account_id
 WHERE aa.id=$1 AND aa.deleted_at IS NULL AND a.deleted_at IS NULL
   AND `+platformSysUserPredicate, id).Scan(&accountID); err != nil {
		// QA-2026-07-02 BUG-2: 停用不存在的系统用户返回 404 而非 500。
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound.Withf("系统用户不存在")
		}
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET status='suspended', updated_at=now() WHERE id=$1 AND deleted_at IS NULL`, accountID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE role_assignments SET deleted_at=now() WHERE account_id=$1 AND scope_kind='platform' AND deleted_at IS NULL`, accountID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify('auth_revoke', $1)`, "account:"+itoa64(accountID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func replacePlatformRoles(ctx context.Context, tx pgx.Tx, accountID int64, roleIDs []int64) error {
	if _, err := tx.Exec(ctx, `UPDATE role_assignments SET deleted_at=now() WHERE account_id=$1 AND scope_kind='platform' AND deleted_at IS NULL`, accountID); err != nil {
		return err
	}
	for _, roleID := range roleIDs {
		var scope string
		if err := tx.QueryRow(ctx, `SELECT scope_kind FROM roles WHERE id=$1 AND deleted_at IS NULL`, roleID).Scan(&scope); err != nil {
			// QA-2026-07-02 BUG-2: 绑定不存在的角色返回明确的 invalid params，而非把 pgx.ErrNoRows 透成 500。
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.ErrInvalidParams.Withf("角色不存在: id=%d", roleID)
			}
			return err
		}
		if scope != "platform" {
			return apperr.ErrInvalidParams.Withf("只能绑定 platform 角色")
		}
		if _, err := tx.Exec(ctx, `
INSERT INTO role_assignments (account_id, role_id, scope_kind)
VALUES ($1, $2, 'platform')`, accountID, roleID); err != nil {
			return err
		}
	}
	return nil
}

func stringPtrValue(v *string) any {
	if v == nil {
		return nil
	}
	return strings.TrimSpace(*v)
}

func itoa(n int) string {
	if n < 10 {
		return string('0' + rune(n))
	}
	return itoa64(int64(n))
}

func itoa64(n int64) string {
	return strconv.FormatInt(n, 10)
}
