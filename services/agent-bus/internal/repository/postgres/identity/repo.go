package identity

import (
	"context"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	adapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
	domidentity "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/identity"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"time"
)

type Record struct {
	ID              int64
	UUID            string
	Config          adapter.Config
	SecretEncrypted string
	UpdatedAt       time.Time
}
type PublicProvider = domidentity.PublicProvider
type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool} }
func (r *Repo) lookup(ctx context.Context, where string, value any) (*Record, error) {
	var out Record
	err := r.pool.QueryRow(ctx, `SELECT id,uuid::text,tenant_id,kind,name,COALESCE(issuer,''),COALESCE(client_id,''),COALESCE(client_secret_enc,''),COALESCE(redirect_uri,''),COALESCE(scopes,'{}'::varchar[]),updated_at FROM tenant_identity_providers WHERE kind='oidc' AND status='active' AND deleted_at IS NULL AND `+where+` ORDER BY id LIMIT 1`, value).Scan(&out.ID, &out.UUID, &out.Config.TenantID, &out.Config.Kind, &out.Config.Name, &out.Config.Issuer, &out.Config.ClientID, &out.SecretEncrypted, &out.Config.RedirectURI, &out.Config.Scopes, &out.UpdatedAt)
	if err == pgx.ErrNoRows {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &out, nil
}
func (r *Repo) ByIssuer(ctx context.Context, issuer string) (*Record, error) {
	return r.lookup(ctx, "issuer=$1", issuer)
}
func (r *Repo) ByUUID(ctx context.Context, uuid string) (*Record, error) {
	return r.lookup(ctx, "uuid=$1", uuid)
}
func (r *Repo) ByTenant(ctx context.Context, id int64) (*Record, error) {
	return r.lookup(ctx, "tenant_id=$1", id)
}
func (r *Repo) ListPublic(ctx context.Context) ([]PublicProvider, error) {
	rows, err := r.pool.Query(ctx, `SELECT uuid::text,name,kind FROM tenant_identity_providers WHERE kind='oidc' AND status='active' AND deleted_at IS NULL ORDER BY name,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PublicProvider{}
	for rows.Next() {
		var p PublicProvider
		if err := rows.Scan(&p.UUID, &p.Name, &p.Kind); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
