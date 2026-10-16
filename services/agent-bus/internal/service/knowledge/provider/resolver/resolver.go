// Package resolver · M8B Resolver: 给定 kb.provider_id (NULL 时回退 default),
// 返回对应 Provider 实例 (stub / dify / ...).
//
// 设计:
//   - 起步只构造 1 个 Provider 实例缓存 per provider id (provider 自身线程安全;
//     启动期解析 secret + dial Dify Workspace 仅一次);
//   - PG NOTIFY config_change=kb_provider_config:<id> 来时清掉对应缓存 (本期不实施 listener,
//     仅暴露 Invalidate 方法供后续接 listener);
//   - 生产 fail-closed: 解析失败 / provider 构造失败 → 返 ErrDegraded (调用方转 kb.provider_degraded);
//   - Stub fallback 仅在 AllowStubFallback=true (dev/CI flag) 下生效.
package resolver

import (
	"context"
	"errors"
	"fmt"
	"sync"

	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	provider "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider/dify"
)

// ErrDegraded · provider 不可用 (配置错 / Dify 不可达 / kind 未知 且 Stub fallback 禁用).
var ErrDegraded = errors.New("kb.provider_degraded")

// ProviderRepo · resolver 依赖的 repo 子集.
type ProviderRepo interface {
	GetDefaultProvider(ctx context.Context) (*domkb.ProviderConfig, error)
	GetProviderByID(ctx context.Context, id int64) (*domkb.ProviderConfig, error)
}

// StubFactory · dev/CI 显式开关下提供 stub provider 的工厂.
type StubFactory func() provider.Provider

// SecretResolver · 把 settings.api_token_secret_ref 解析为真值.
// 复用 cmd/bus 的 resolveSecretRef 即可; 测试用 fake 注入.
type SecretResolver func(ref string) (string, error)

// RagflowFactory · F07 D2 — cmd/bus 注入构造好的 RAGFlow Provider (内含 admin login + bindings + dataset id resolver).
// nil 时 provider_kind=ragflow 走 ErrDegraded。
type RagflowFactory func() provider.Provider

// Config · 启动期配置.
type Config struct {
	Logger            *log.Logger
	Repo              ProviderRepo
	SecretResolve     SecretResolver
	StubFactory       StubFactory    // dev/CI fallback; nil → 禁用 stub
	RagflowFactory    RagflowFactory // F07 生产; nil → ragflow 走 ErrDegraded
	AllowStubFallback bool           // AGBUS_KB_ALLOW_STUB_FALLBACK=1
}

// Resolver · 缓存 (provider_id → Provider) + 解析路由.
type Resolver struct {
	cfg   Config
	mu    sync.RWMutex
	cache map[int64]provider.Provider
}

// New · 构造 resolver. cfg.Repo / SecretResolve 必填.
func New(cfg Config) (*Resolver, error) {
	if cfg.Repo == nil {
		return nil, errors.New("resolver: repo required")
	}
	if cfg.SecretResolve == nil {
		return nil, errors.New("resolver: secret resolver required")
	}
	return &Resolver{cfg: cfg, cache: map[int64]provider.Provider{}}, nil
}

// Resolve · 按 KB 行决定使用哪个 Provider.
//
// 流程:
//  1. providerID == nil → 走 default provider;
//  2. 缓存命中 → 直接返;
//  3. 拉 ProviderConfig + secret resolve + 构造 Provider; 缓存.
//  4. provider_kind=stub:
//     - AllowStubFallback=true → 返 stub;
//     - false (生产) → ErrDegraded (强制配 Dify).
//  5. provider_kind=dify → 构造 DifyKBProvider; 失败 → ErrDegraded.
//  6. 未知 kind → ErrDegraded.
func (r *Resolver) Resolve(ctx context.Context, kb *domkb.KnowledgeBase) (provider.Provider, error) {
	if kb == nil {
		return nil, errors.New("resolver: nil kb")
	}
	var cfg *domkb.ProviderConfig
	var err error
	if kb.ProviderID != nil && *kb.ProviderID > 0 {
		cfg, err = r.cfg.Repo.GetProviderByID(ctx, *kb.ProviderID)
	} else {
		cfg, err = r.cfg.Repo.GetDefaultProvider(ctx)
	}
	if err != nil || cfg == nil {
		if r.cfg.Logger != nil {
			r.cfg.Logger.Warn(ctx, "kb provider config lookup failed", "kb_uuid", kb.UUID, "err", err)
		}
		return nil, ErrDegraded
	}
	// Codex round-3 P1-2: status gating. 业务 Search/Recall/Ingest/Delete 不允许使用
	// degraded/disabled provider; 仅 admin health-check 例外 (走单独路径直接 GetProviderByID).
	if cfg.Status != "" && cfg.Status != "active" {
		if r.cfg.Logger != nil {
			r.cfg.Logger.Warn(ctx, "kb provider not active; refusing to resolve",
				"kb_uuid", kb.UUID, "provider_id", cfg.ID, "status", cfg.Status)
		}
		return nil, ErrDegraded
	}
	r.mu.RLock()
	if p, ok := r.cache[cfg.ID]; ok {
		r.mu.RUnlock()
		return p, nil
	}
	r.mu.RUnlock()

	p, err := r.buildLocked(ctx, cfg)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.cache[cfg.ID] = p
	r.mu.Unlock()
	return p, nil
}

// Invalidate · NOTIFY listener 调; 清掉指定 provider_id 的缓存 (下次 Resolve 重新构造).
func (r *Resolver) Invalidate(providerID int64) {
	r.mu.Lock()
	delete(r.cache, providerID)
	r.mu.Unlock()
}

// InvalidateAll · 全清 (听到全表配置改动时).
func (r *Resolver) InvalidateAll() {
	r.mu.Lock()
	r.cache = map[int64]provider.Provider{}
	r.mu.Unlock()
}

func (r *Resolver) buildLocked(ctx context.Context, cfg *domkb.ProviderConfig) (provider.Provider, error) {
	switch cfg.ProviderKind {
	case "stub":
		if !r.cfg.AllowStubFallback || r.cfg.StubFactory == nil {
			if r.cfg.Logger != nil {
				r.cfg.Logger.Warn(ctx, "kb provider=stub but stub fallback disabled (production fail-closed)", "provider_id", cfg.ID)
			}
			return nil, ErrDegraded
		}
		return r.cfg.StubFactory(), nil

	case "dify":
		// settings 必填字段.
		endpoint, _ := cfg.Settings["endpoint_url"].(string)
		if endpoint == "" {
			endpoint = cfg.EndpointURL
		}
		tokenRef, _ := cfg.Settings["api_token_secret_ref"].(string)
		workspace, _ := cfg.Settings["workspace_id"].(string)
		datasetID, _ := cfg.Settings["dataset_id"].(string)
		tenantDS, _ := cfg.Settings["tenant_dataset_id"].(string)
		userDS, _ := cfg.Settings["user_dataset_id"].(string)
		if tenantDS == "" {
			tenantDS = datasetID
		}
		if userDS == "" {
			userDS = datasetID
		}
		if endpoint == "" || tokenRef == "" || tenantDS == "" || userDS == "" {
			if r.cfg.Logger != nil {
				r.cfg.Logger.Warn(ctx, "dify provider settings incomplete", "provider_id", cfg.ID)
			}
			return nil, ErrDegraded
		}
		token, err := r.cfg.SecretResolve(tokenRef)
		if err != nil || token == "" {
			if r.cfg.Logger != nil {
				r.cfg.Logger.Warn(ctx, "dify api token secret resolve failed", "provider_id", cfg.ID, "err", err)
			}
			return nil, ErrDegraded
		}
		p, err := dify.New(dify.Config{
			EndpointURL:     endpoint,
			APIToken:        token,
			WorkspaceID:     workspace,
			TenantDatasetID: tenantDS,
			UserDatasetID:   userDS,
		})
		if err != nil {
			if r.cfg.Logger != nil {
				r.cfg.Logger.Warn(ctx, "dify provider construct failed", "provider_id", cfg.ID, "err", err)
			}
			return nil, fmt.Errorf("%w: %v", ErrDegraded, err)
		}
		return p, nil
	case "ragflow":
		// F07 D2 — RAGFlow provider; 由 cmd/bus 启动期 wire 进来。
		if r.cfg.RagflowFactory == nil {
			if r.cfg.Logger != nil {
				r.cfg.Logger.Warn(ctx, "kb provider=ragflow but RagflowFactory not wired", "provider_id", cfg.ID)
			}
			return nil, ErrDegraded
		}
		return r.cfg.RagflowFactory(), nil

	default:
		return nil, ErrDegraded
	}
}
