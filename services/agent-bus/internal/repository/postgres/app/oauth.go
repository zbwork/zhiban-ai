package app

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// =====================================================
// OAuthClientRepo
// =====================================================

type OAuthClientRepo struct{ pool *pgxpool.Pool }

func NewOAuthClientRepo(pool *pgxpool.Pool) *OAuthClientRepo {
	return &OAuthClientRepo{pool: pool}
}

const ocCols = `id, uuid::text, tenant_id, creator_id, app_id, client_id, client_secret_hash,
    COALESCE(redirect_uris, '{}'::varchar[]),
    COALESCE(scopes, '{}'::varchar[]),
    token_endpoint_auth_method, access_token_ttl_seconds, refresh_token_ttl_seconds,
    status, last_used_at, created_at, updated_at, revoked_at`

func scanOC(row pgx.Row) (*dom.OAuthClient, error) {
	var x dom.OAuthClient
	var tenantID *int64
	if err := row.Scan(&x.ID, &x.UUID, &tenantID, &x.CreatorID, &x.AppID,
		&x.ClientID, &x.ClientSecretHash, &x.RedirectURIs, &x.Scopes,
		&x.TokenEndpointAuthMethod, &x.AccessTokenTTLSeconds, &x.RefreshTokenTTLSeconds,
		&x.Status, &x.LastUsedAt, &x.CreatedAt, &x.UpdatedAt, &x.RevokedAt); err != nil {
		return nil, err
	}
	if tenantID != nil {
		x.TenantID = *tenantID
	}
	return &x, nil
}

func (r *OAuthClientRepo) Insert(ctx context.Context, c *dom.OAuthClient) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO app_oauth_clients (tenant_id, creator_id, app_id, client_id, client_secret_hash,
		    redirect_uris, scopes, token_endpoint_auth_method,
		    access_token_ttl_seconds, refresh_token_ttl_seconds, status)
		VALUES (NULLIF($1,0)::bigint, $2, $3, $4, $5, $6, $7, $8, $9, $10, COALESCE(NULLIF($11,''),'active'))
		RETURNING `+ocCols,
		c.TenantID, c.CreatorID, c.AppID, c.ClientID, c.ClientSecretHash,
		c.RedirectURIs, c.Scopes, c.TokenEndpointAuthMethod,
		c.AccessTokenTTLSeconds, c.RefreshTokenTTLSeconds, c.Status)
	got, err := scanOC(row)
	if err != nil {
		return err
	}
	*c = *got
	return nil
}

func (r *OAuthClientRepo) GetByID(ctx context.Context, id int64) (*dom.OAuthClient, error) {
	x, err := scanOC(r.pool.QueryRow(ctx, `SELECT `+ocCols+` FROM app_oauth_clients WHERE id=$1`, id))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *OAuthClientRepo) GetByAppID(ctx context.Context, appID int64) (*dom.OAuthClient, error) {
	x, err := scanOC(r.pool.QueryRow(ctx,
		`SELECT `+ocCols+` FROM app_oauth_clients WHERE app_id=$1`, appID))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *OAuthClientRepo) FindByClientID(ctx context.Context, clientID string) (*dom.OAuthClient, error) {
	x, err := scanOC(r.pool.QueryRow(ctx,
		`SELECT `+ocCols+` FROM app_oauth_clients WHERE client_id=$1`, clientID))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *OAuthClientRepo) RotateSecret(ctx context.Context, id int64, newHash string) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE app_oauth_clients SET client_secret_hash=$1, updated_at=now() WHERE id=$2`,
		newHash, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *OAuthClientRepo) Revoke(ctx context.Context, id int64) error {
	tag, err := r.pool.Exec(ctx,
		`UPDATE app_oauth_clients SET status='revoked', revoked_at=now(), updated_at=now()
		 WHERE id=$1 AND status='active'`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *OAuthClientRepo) TouchLastUsed(ctx context.Context, id int64, ts time.Time) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE app_oauth_clients SET last_used_at=$1 WHERE id=$2`, ts, id)
	return err
}

func (r *OAuthClientRepo) Patch(ctx context.Context, id int64, fields map[string]any) (*dom.OAuthClient, error) {
	if len(fields) == 0 {
		return r.GetByID(ctx, id)
	}
	colMap := map[string]string{
		"redirect_uris":              "redirect_uris",
		"scopes":                     "scopes",
		"token_endpoint_auth_method": "token_endpoint_auth_method",
		"access_token_ttl_seconds":   "access_token_ttl_seconds",
		"refresh_token_ttl_seconds":  "refresh_token_ttl_seconds",
		"status":                     "status",
	}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, col+" = $"+strconv.Itoa(idx))
		idx++
	}
	if len(sets) == 0 {
		return r.GetByID(ctx, id)
	}
	args = append(args, id)
	q := "UPDATE app_oauth_clients SET " + strings.Join(sets, ", ") + ", updated_at=now()" +
		" WHERE id = $" + strconv.Itoa(idx) + " RETURNING " + ocCols
	x, err := scanOC(r.pool.QueryRow(ctx, q, args...))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// =====================================================
// OAuthCodeRepo
// =====================================================

type OAuthCodeRepo struct{ pool *pgxpool.Pool }

func NewOAuthCodeRepo(pool *pgxpool.Pool) *OAuthCodeRepo { return &OAuthCodeRepo{pool: pool} }

const codeCols = `id, uuid::text, code_hash, oauth_client_id, tenant_id, account_id,
    conversation_id, redirect_uri,
    COALESCE(scopes,'{}'::varchar[]),
    COALESCE(state,''), COALESCE(nonce,''),
    issued_at, expires_at, consumed_at`

func scanCode(row pgx.Row) (*dom.OAuthCode, error) {
	var x dom.OAuthCode
	if err := row.Scan(&x.ID, &x.UUID, &x.CodeHash, &x.OAuthClientID,
		&x.TenantID, &x.AccountID, &x.ConversationID, &x.RedirectURI,
		&x.Scopes, &x.State, &x.Nonce,
		&x.IssuedAt, &x.ExpiresAt, &x.ConsumedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *OAuthCodeRepo) Insert(ctx context.Context, c *dom.OAuthCode) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO app_oauth_codes (code_hash, oauth_client_id, tenant_id, account_id,
		    conversation_id, redirect_uri, scopes, state, nonce, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, NULLIF($8,''), NULLIF($9,''), $10)
		RETURNING `+codeCols,
		c.CodeHash, c.OAuthClientID, c.TenantID, c.AccountID,
		c.ConversationID, c.RedirectURI, c.Scopes, c.State, c.Nonce, c.ExpiresAt)
	got, err := scanCode(row)
	if err != nil {
		return err
	}
	*c = *got
	return nil
}

// Consume 原子化消费 (codex challenge: UPDATE ... WHERE consumed_at IS NULL ... RETURNING 保证并发安全)。
//
// 校验:
//  1. code_hash 匹配
//  2. consumed_at IS NULL (没被消费过)
//  3. expires_at > now() (没过期)
//  4. redirect_uri exact match (防 cross-uri)
//  5. oauth_client_id 匹配 (防 cross-client)
func (r *OAuthCodeRepo) Consume(ctx context.Context, codeHash, redirectURI string, oauthClientID int64) (*dom.OAuthCode, error) {
	row := r.pool.QueryRow(ctx, `
		UPDATE app_oauth_codes SET consumed_at = now()
		WHERE code_hash = $1
		  AND consumed_at IS NULL
		  AND expires_at > now()
		  AND redirect_uri = $2
		  AND oauth_client_id = $3
		RETURNING `+codeCols,
		codeHash, redirectURI, oauthClientID)
	x, err := scanCode(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound // service 层包装成 invalid_grant
		}
		return nil, err
	}
	return x, nil
}

// CleanupExpired 删 expires_at < now() - 1h 且 consumed_at IS NOT NULL, 或 issued_at < now() - 1d 且 consumed_at IS NULL。
// 审计期: 已消费的留 1h (refresh / replay 调试), 未消费的留 1d (debug 黑名单)。
func (r *OAuthCodeRepo) CleanupExpired(ctx context.Context) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		DELETE FROM app_oauth_codes
		WHERE (consumed_at IS NOT NULL AND expires_at < now() - INTERVAL '1 hour')
		   OR (consumed_at IS NULL     AND issued_at  < now() - INTERVAL '1 day')`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
