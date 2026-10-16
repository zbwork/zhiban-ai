// Package session login_sessions PostgreSQL 实现。
package session

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/session"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Repo session.Repository 的 Postgres 实现。
type Repo struct{ pool *pgxpool.Pool }

// New 构造。
func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const baseCols = `id, uuid, account_id, refresh_token_hash,
    issued_at, expires_at, last_used_at,
    act_scope_kind, act_tenant_id, act_workspace_id, acting_as,
    user_agent, ip, device_fingerprint,
    device_type, device_brand, device_model, device_system_version, device_app_version,
    revoked_at, revoke_reason`

func scan(row pgx.Row) (*dom.LoginSession, error) {
	var s dom.LoginSession
	var ua, actingAs, fp, reason *string
	var deviceType, deviceBrand, deviceModel, deviceSystemVersion, deviceAppVersion *string
	var ip *netip.Addr
	if err := row.Scan(
		&s.ID, &s.UUID, &s.AccountID, &s.RefreshTokenHash,
		&s.IssuedAt, &s.ExpiresAt, &s.LastUsedAt,
		&s.ActScopeKind, &s.ActTenantID, &s.ActWorkspaceID, &actingAs,
		&ua, &ip, &fp,
		&deviceType, &deviceBrand, &deviceModel, &deviceSystemVersion, &deviceAppVersion,
		&s.RevokedAt, &reason,
	); err != nil {
		return nil, err
	}
	if ua != nil {
		s.UserAgent = *ua
	}
	if actingAs != nil {
		s.ActingAs = *actingAs
	}
	if fp != nil {
		s.DeviceFingerprint = *fp
	}
	if deviceType != nil {
		s.DeviceType = *deviceType
	}
	if deviceBrand != nil {
		s.DeviceBrand = *deviceBrand
	}
	if deviceModel != nil {
		s.DeviceModel = *deviceModel
	}
	if deviceSystemVersion != nil {
		s.DeviceSystemVersion = *deviceSystemVersion
	}
	if deviceAppVersion != nil {
		s.DeviceAppVersion = *deviceAppVersion
	}
	if reason != nil {
		s.RevokeReason = *reason
	}
	if ip != nil {
		ipNet := net.IP(ip.AsSlice())
		s.IP = &ipNet
	}
	return &s, nil
}

// Create atomically replaces the same device class, including concurrent logins.
func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.LoginSession, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// Serialize on the account row, including the first login with no sessions.
	var accountID int64
	if err := tx.QueryRow(ctx, "SELECT id FROM accounts WHERE id=$1 FOR UPDATE", in.AccountID).Scan(&accountID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `WITH revoked AS (
		UPDATE login_sessions SET revoked_at=now(), revoke_reason='device_relogin'
		WHERE account_id=$1 AND revoked_at IS NULL AND (
			lower(btrim(device_type))=ANY($2::text[]) OR ($3<>'' AND device_fingerprint=$3)
		) RETURNING uuid
	) SELECT pg_notify('auth_revoke', 'session:' || uuid::text) FROM revoked`,
		in.AccountID, dom.DeviceClassPlatforms(in.DeviceType), in.DeviceFingerprint); err != nil {
		return nil, err
	}
	row := tx.QueryRow(ctx, `
INSERT INTO login_sessions
  (account_id, refresh_token_hash, expires_at, act_scope_kind,
   act_tenant_id, act_workspace_id, acting_as,
   user_agent, ip, device_fingerprint,
   device_type, device_brand, device_model, device_system_version, device_app_version)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::inet,$10,$11,$12,$13,$14,$15)
RETURNING `+baseCols,
		in.AccountID, in.RefreshTokenHash, in.ExpiresAt, in.ActScopeKind,
		in.ActTenantID, in.ActWorkspaceID, nullIfEmpty(in.ActingAs),
		nullIfEmpty(in.UserAgent), nullIfEmpty(in.IP), nullIfEmpty(in.DeviceFingerprint),
		nullIfEmpty(in.DeviceType), nullIfEmpty(in.DeviceBrand), nullIfEmpty(in.DeviceModel),
		nullIfEmpty(in.DeviceSystemVersion), nullIfEmpty(in.DeviceAppVersion),
	)
	created, err := scan(row)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return created, nil
}

// GetByUUID 按 uuid 取 (含已撤销, 调用方自己判 revoked_at)。
func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.LoginSession, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM login_sessions WHERE uuid=$1`, uuid)
	s, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return s, nil
}

// GetByRefreshHash 用于 /auth/token/refresh。
// 旋转宽限窗 (000134): 旧 hash 在 prev_* 列的宽限期内仍可命中——客户端"续期成功但响应
// 丢失"后拿旧 token 重试, 会再次旋转并收敛到最新对, 不再被判无效踢回登录。
func (r *Repo) GetByRefreshHash(ctx context.Context, hash string) (*dom.LoginSession, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM login_sessions
 WHERE refresh_token_hash=$1
    OR (prev_refresh_token_hash=$1 AND prev_hash_expires_at > now())`, hash)
	s, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return s, nil
}

// TouchUsed refresh 时滚动: 更新 last_used_at + 旋转 refresh hash + expires;
// 旧 hash 挪入 prev_* 留 60s 宽限 (见 GetByRefreshHash)。
func (r *Repo) TouchUsed(ctx context.Context, sessionUUID, newHash string, newExpire time.Time) error {
	_, err := r.pool.Exec(ctx, `
UPDATE login_sessions
   SET last_used_at=now(),
       prev_refresh_token_hash=refresh_token_hash,
       prev_hash_expires_at=now() + interval '60 seconds',
       refresh_token_hash=$2, expires_at=$3
 WHERE uuid=$1 AND revoked_at IS NULL`,
		sessionUUID, newHash, newExpire)
	return err
}

// UpdateScope 切换 session 的 act_scope。
func (r *Repo) UpdateScope(ctx context.Context, in dom.UpdateScopeInput) error {
	_, err := r.pool.Exec(ctx, `
UPDATE login_sessions
   SET act_scope_kind=$2, act_tenant_id=$3, act_workspace_id=$4, last_used_at=now()
 WHERE uuid=$1 AND revoked_at IS NULL`,
		in.SessionUUID, in.ActScopeKind, in.ActTenantID, in.ActWorkspaceID)
	return err
}

// Revoke 主动撤销。
func (r *Repo) Revoke(ctx context.Context, sessionUUID, reason string) error {
	_, err := r.pool.Exec(ctx, `
UPDATE login_sessions
   SET revoked_at=now(), revoke_reason=$2
 WHERE uuid=$1 AND revoked_at IS NULL`,
		sessionUUID, nullIfEmpty(reason))
	return err
}

// RevokeAllByAccount 把账号下所有活跃 session 撤掉 (改密 / 强踢)。
func (r *Repo) RevokeAllByAccount(ctx context.Context, accountID int64, reason string) error {
	_, err := r.pool.Exec(ctx, `
UPDATE login_sessions
   SET revoked_at=now(), revoke_reason=$2
 WHERE account_id=$1 AND revoked_at IS NULL`,
		accountID, nullIfEmpty(reason))
	return err
}

// RevokeActiveByAccountAndFingerprint 同账号 + 同设备指纹的活跃 session 全部撤掉。
// 登录时用来顶掉同一设备的旧 session，避免 /me/sessions 里同一台机器越攒越多。
func (r *Repo) RevokeActiveByAccountAndFingerprint(ctx context.Context, accountID int64, fingerprint, reason string) error {
	if fingerprint == "" {
		return nil
	}
	_, err := r.pool.Exec(ctx, `
UPDATE login_sessions
   SET revoked_at=now(), revoke_reason=$3
 WHERE account_id=$1 AND device_fingerprint=$2 AND revoked_at IS NULL`,
		accountID, fingerprint, nullIfEmpty(reason))
	return err
}

// ListActiveByAccount 活跃 sessions, 给 /auth/me 用。
func (r *Repo) ListActiveByAccount(ctx context.Context, accountID int64) ([]dom.LoginSession, error) {
	rows, err := r.pool.Query(ctx, `
SELECT `+baseCols+` FROM login_sessions
 WHERE account_id=$1 AND revoked_at IS NULL AND expires_at > now()
 ORDER BY last_used_at DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.LoginSession
	for rows.Next() {
		s, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
