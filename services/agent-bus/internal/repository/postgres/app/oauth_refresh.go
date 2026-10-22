package app

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type RefreshTokenRepo struct{ pool *pgxpool.Pool }

func NewRefreshTokenRepo(pool *pgxpool.Pool) *RefreshTokenRepo { return &RefreshTokenRepo{pool: pool} }

const rtCols = `id, uuid::text, token_hash, oauth_client_id, tenant_id, account_id,
    COALESCE(scopes,'{}'::varchar[]),
    issued_at, expires_at, last_used_at, revoked_at, COALESCE(revoke_reason,'')`

func scanRT(row pgx.Row) (*dom.RefreshToken, error) {
	var x dom.RefreshToken
	if err := row.Scan(&x.ID, &x.UUID, &x.TokenHash, &x.OAuthClientID,
		&x.TenantID, &x.AccountID, &x.Scopes,
		&x.IssuedAt, &x.ExpiresAt, &x.LastUsedAt, &x.RevokedAt, &x.RevokeReason); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *RefreshTokenRepo) Insert(ctx context.Context, t *dom.RefreshToken) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO app_oauth_refresh_tokens (token_hash, oauth_client_id, tenant_id, account_id, scopes, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING `+rtCols,
		t.TokenHash, t.OAuthClientID, t.TenantID, t.AccountID, t.Scopes, t.ExpiresAt)
	got, err := scanRT(row)
	if err != nil {
		return err
	}
	*t = *got
	return nil
}

// ConsumeAndRotate UPDATE ... WHERE revoked_at IS NULL AND expires_at > now() ... RETURNING; 原子化。
func (r *RefreshTokenRepo) ConsumeAndRotate(ctx context.Context, tokenHash string) (*dom.RefreshToken, error) {
	row := r.pool.QueryRow(ctx, `
		UPDATE app_oauth_refresh_tokens
		SET revoked_at = now(), revoke_reason = 'rotate', last_used_at = now()
		WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
		RETURNING `+rtCols,
		tokenHash)
	x, err := scanRT(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// CleanupExpired 删 7d 前的 revoked 行 + 已过期未撤销的行。
func (r *RefreshTokenRepo) CleanupExpired(ctx context.Context) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		DELETE FROM app_oauth_refresh_tokens
		WHERE (revoked_at IS NOT NULL AND revoked_at < now() - INTERVAL '7 days')
		   OR (revoked_at IS NULL     AND expires_at < now() - INTERVAL '1 day')`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// ConsumeAndRotateForClient checks the client before revoking the token atomically.
func (r *RefreshTokenRepo) ConsumeAndRotateForClient(ctx context.Context, tokenHash string, clientID int64) (*dom.RefreshToken, error) {
	row := r.pool.QueryRow(ctx, "UPDATE app_oauth_refresh_tokens SET revoked_at=now(), revoke_reason='rotate', last_used_at=now() WHERE token_hash=$1 AND oauth_client_id=$2 AND revoked_at IS NULL AND expires_at>now() RETURNING "+rtCols, tokenHash, clientID)
	x, err := scanRT(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	return x, err
}
