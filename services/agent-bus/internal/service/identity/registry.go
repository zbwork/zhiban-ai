// Package identity 实现 internal/adapter/identity.Registry: 按 issuer / tenant
// 反查 tenant_identity_providers 行, 解密 client_secret, 构造可用的 Provider 实例。
//
// 设计要点 (M4 真接入):
//   - Provider 实例缓存 5min (lease), 缓存内复用 (OIDC discovery 是网络调用, 重复构造贵)
//   - client_secret 入库时 AES-GCM 密 → 这里 Sealer.Open 解明文给 Provider
//   - kind=oidc 走 adapter/identity/oidc.New; SAML/LDAP/SCIM 暂报 ErrNotSupported
package identity

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	adapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
	oidcadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity/oidc"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Sealer 客户端 secret 解密接口; 实际是 pkg/secretbox.Box。
type Sealer interface {
	Open(enc string) (string, error)
}

// Registry pgx + cache 实现。
type Registry struct {
	pool   *pgxpool.Pool
	sealer Sealer
	ttl    time.Duration

	mu    sync.Mutex
	cache map[int64]*adapter.LeasedProvider // key = tenant_identity_providers.id
}

// NewRegistry 构造; 缓存 TTL 默认 5min。
func NewRegistry(pool *pgxpool.Pool, sealer Sealer) *Registry {
	return &Registry{
		pool:   pool,
		sealer: sealer,
		ttl:    5 * time.Minute,
		cache:  map[int64]*adapter.LeasedProvider{},
	}
}

// ResolveByIssuer 用 OIDC issuer 反查 IdP 行, 构造 Provider。多个 issuer 相同
// 的 IdP 应被禁止 (uq_tenant_idp_issuer_kind 在 tenant 内唯一; 不同租户共享 issuer
// OK, 这里取第一条 active 行)。
func (r *Registry) ResolveByIssuer(ctx context.Context, issuer string) (*adapter.LeasedProvider, error) {
	if issuer == "" {
		return nil, apperr.ErrInvalidParams.Withf("issuer required")
	}
	var id int64
	if err := r.pool.QueryRow(ctx, `
		SELECT id FROM tenant_identity_providers
		 WHERE issuer=$1 AND kind='oidc' AND status='active' AND deleted_at IS NULL
		 ORDER BY id ASC LIMIT 1`, issuer).Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("no active oidc provider for issuer %q", issuer)
		}
		return nil, err
	}
	return r.resolveByID(ctx, id)
}

// ResolveByUUID 给 admin-web Login 页 / OIDC start endpoint 用 — 拿到具体 IdP UUID 后构造 Provider。
//
// 不暴露在 adapter.Registry 接口里, 但本包公开以便 transport 层用。
func (r *Registry) ResolveByUUID(ctx context.Context, uuid string) (*adapter.LeasedProvider, error) {
	if uuid == "" {
		return nil, apperr.ErrInvalidParams.Withf("uuid required")
	}
	var id int64
	if err := r.pool.QueryRow(ctx, `
		SELECT id FROM tenant_identity_providers
		 WHERE uuid=$1 AND status='active' AND deleted_at IS NULL`, uuid).Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("provider %s not found", uuid)
		}
		return nil, err
	}
	return r.resolveByID(ctx, id)
}

// ResolveByTenant 单租户场景拿默认 IdP (M4 简化: 取该租户第一条 active oidc)。
func (r *Registry) ResolveByTenant(ctx context.Context, tenantID int64) (*adapter.LeasedProvider, error) {
	var id int64
	if err := r.pool.QueryRow(ctx, `
		SELECT id FROM tenant_identity_providers
		 WHERE tenant_id=$1 AND kind='oidc' AND status='active' AND deleted_at IS NULL
		 ORDER BY id ASC LIMIT 1`, tenantID).Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("no oidc provider for tenant %d", tenantID)
		}
		return nil, err
	}
	return r.resolveByID(ctx, id)
}

func (r *Registry) resolveByID(ctx context.Context, id int64) (*adapter.LeasedProvider, error) {
	now := time.Now()
	r.mu.Lock()
	if lp, ok := r.cache[id]; ok && lp.LeaseEnd.After(now) {
		r.mu.Unlock()
		return lp, nil
	}
	r.mu.Unlock()

	var (
		uuid, kind, name, issuer, clientID, clientSecretEnc, redirectURI string
		tenantID                                                         int64
		scopes                                                           []string
	)
	row := r.pool.QueryRow(ctx, `
		SELECT uuid::text, tenant_id, kind, name,
		       COALESCE(issuer,''), COALESCE(client_id,''),
		       COALESCE(client_secret_enc,''), COALESCE(redirect_uri,''),
		       COALESCE(scopes,'{}'::varchar[])
		  FROM tenant_identity_providers WHERE id=$1 AND deleted_at IS NULL`, id)
	if err := row.Scan(&uuid, &tenantID, &kind, &name, &issuer, &clientID, &clientSecretEnc, &redirectURI, &scopes); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	cfg := adapter.Config{
		TenantID:    tenantID,
		Kind:        adapter.ProviderKind(kind),
		Name:        name,
		Issuer:      issuer,
		ClientID:    clientID,
		RedirectURI: redirectURI,
		Scopes:      scopes,
	}

	if r.sealer != nil && clientSecretEnc != "" {
		plain, err := r.sealer.Open(clientSecretEnc)
		if err != nil {
			return nil, apperr.ErrInternal.Withf("identity registry: decrypt client_secret for id=%d: %v", id, err)
		}
		cfg.ClientSec = plain
	}

	var prov adapter.Provider
	switch cfg.Kind {
	case adapter.KindOIDC:
		p, err := oidcadapter.New(ctx, oidcadapter.Options{
			Issuer:       cfg.Issuer,
			ClientID:     cfg.ClientID,
			ClientSecret: cfg.ClientSec,
			RedirectURI:  cfg.RedirectURI,
			Scopes:       cfg.Scopes,
		})
		if err != nil {
			// QA 反馈: 假 issuer / 内网 / DNS 不通时报 5000 generic 太难调试。
			// 这里转成 4xx "invalid params" 带具体 issuer URL, 让 admin 知道是配置问题不是服务挂了。
			return nil, apperr.ErrInvalidParams.Withf("oidc discovery failed for issuer %q: %v", cfg.Issuer, err)
		}
		prov = p
	default:
		return nil, apperr.ErrInvalidParams.Withf("identity provider kind %q not supported (M4 only oidc)", cfg.Kind)
	}

	lp := &adapter.LeasedProvider{
		Cfg:      cfg,
		Provider: prov,
		LeaseEnd: now.Add(r.ttl),
	}
	r.mu.Lock()
	r.cache[id] = lp
	r.mu.Unlock()
	return lp, nil
}

// Invalidate 清空缓存 (admin 改了 IdP 配置后 service 层调用)。
func (r *Registry) Invalidate() {
	r.mu.Lock()
	r.cache = map[int64]*adapter.LeasedProvider{}
	r.mu.Unlock()
}

// 编译期保证: Registry 实现 adapter.Registry 接口。
var _ adapter.Registry = (*Registry)(nil)
