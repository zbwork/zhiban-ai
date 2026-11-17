package identity

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	adapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
	oidcadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity/oidc"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/identity"
	"sync"
	"time"
)

type Sealer interface{ Open(string) (string, error) }
type cacheEntry struct {
	provider *adapter.LeasedProvider
	version  time.Time
}
type Registry struct {
	repo   *repo.Repo
	sealer Sealer
	ttl    time.Duration
	mu     sync.Mutex
	cache  map[int64]cacheEntry
}

func NewRegistry(pool *pgxpool.Pool, sealer Sealer) *Registry {
	return &Registry{repo: repo.New(pool), sealer: sealer, ttl: 5 * time.Minute, cache: map[int64]cacheEntry{}}
}
func (r *Registry) ResolveByIssuer(ctx context.Context, v string) (*adapter.LeasedProvider, error) {
	rec, err := r.repo.ByIssuer(ctx, v)
	return r.resolve(ctx, rec, err)
}
func (r *Registry) ResolveByUUID(ctx context.Context, v string) (*adapter.LeasedProvider, error) {
	rec, err := r.repo.ByUUID(ctx, v)
	return r.resolve(ctx, rec, err)
}
func (r *Registry) ResolveByTenant(ctx context.Context, v int64) (*adapter.LeasedProvider, error) {
	rec, err := r.repo.ByTenant(ctx, v)
	return r.resolve(ctx, rec, err)
}
func (r *Registry) ListPublic(ctx context.Context) ([]repo.PublicProvider, error) {
	return r.repo.ListPublic(ctx)
}
func (r *Registry) resolve(ctx context.Context, rec *repo.Record, err error) (*adapter.LeasedProvider, error) {
	if err != nil {
		return nil, err
	}
	now := time.Now()
	r.mu.Lock()
	cached, ok := r.cache[rec.ID]
	r.mu.Unlock()
	if ok && cached.version.Equal(rec.UpdatedAt) && cached.provider.LeaseEnd.After(now) {
		return cached.provider, nil
	}
	cfg := rec.Config
	if r.sealer == nil || rec.SecretEncrypted == "" {
		return nil, apperr.ErrForbidden.Withf("企业登录密钥未配置")
	}
	cfg.ClientSec, err = r.sealer.Open(rec.SecretEncrypted)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("企业登录密钥无法解密，请检查服务配置")
	}
	prov, err := oidcadapter.New(ctx, oidcadapter.Options{Issuer: cfg.Issuer, ClientID: cfg.ClientID, ClientSecret: cfg.ClientSec, RedirectURI: cfg.RedirectURI, Scopes: cfg.Scopes})
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("企业登录服务连接失败，请检查认证地址与服务状态")
	}
	lp := &adapter.LeasedProvider{Cfg: cfg, Provider: prov, LeaseEnd: now.Add(r.ttl)}
	r.mu.Lock()
	r.cache[rec.ID] = cacheEntry{lp, rec.UpdatedAt}
	r.mu.Unlock()
	return lp, nil
}
func (r *Registry) Invalidate() { r.mu.Lock(); r.cache = map[int64]cacheEntry{}; r.mu.Unlock() }

var _ adapter.Registry = (*Registry)(nil)
