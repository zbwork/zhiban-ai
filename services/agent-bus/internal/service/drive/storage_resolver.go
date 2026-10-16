// storage_resolver.go — tenant_id → object.Store 解析与缓存
// Phase 2.2a: 从 legacy internal/service/drive/storage_resolver.go 移植到 drivev3, 用 drivev3repo.StorageRepo.
// 缓存:
//   - 60s LRU (key = tenant_id) → object.Store
//   - 通过 Redis pub "drive_storage:invalidate" 主动失效 (cmd/bus 订阅).
//   - 任一 admin 改写 default / override 也调 Invalidate(tenantID).
package drive

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/storage/oss"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	svcstorage "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/storage"
)

// StorageResolver 把 tenant_id 解成 object.Store; 60s 缓存.
type StorageResolver struct {
	repo   *drepo.StorageRepo
	secret svcstorage.SecretResolver

	mu       sync.RWMutex
	cache    map[int64]*storageEntry
	cacheTTL time.Duration
}

type storageEntry struct {
	store object.Store
	exp   time.Time
}

// PublishStorageConfig 是 Bus 调运行端文件发布脚本时需要的最小 OSS 参数。
// 调用方不得记录 AccessKeyID / SecretAccessKey。
type PublishStorageConfig struct {
	Region          string
	Endpoint        string
	ReadEndpoint    string
	Bucket          string
	AccessKeyID     string
	SecretAccessKey string
	ForcePathStyle  bool
}

// NewStorageResolver 构造.
func NewStorageResolver(repo *drepo.StorageRepo, secret svcstorage.SecretResolver) *StorageResolver {
	return &StorageResolver{
		repo:     repo,
		secret:   secret,
		cache:    make(map[int64]*storageEntry),
		cacheTTL: 60 * time.Second,
	}
}

// Resolve 返回该 tenant 当前应使用的 object.Store.
func (r *StorageResolver) Resolve(ctx context.Context, tenantID int64) (object.Store, error) {
	if tenantID < 0 {
		return nil, errors.New("drive.StorageResolver: tenantID must be >= 0")
	}
	now := time.Now()

	r.mu.RLock()
	if e, ok := r.cache[tenantID]; ok && now.Before(e.exp) {
		r.mu.RUnlock()
		return e.store, nil
	}
	r.mu.RUnlock()

	store, err := r.build(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.cache[tenantID] = &storageEntry{store: store, exp: now.Add(r.cacheTTL)}
	r.mu.Unlock()
	return store, nil
}

// Invalidate 清单个 tenant 缓存 (Redis sub 调用 / admin 写后调用).
func (r *StorageResolver) Invalidate(tenantID int64) {
	r.mu.Lock()
	delete(r.cache, tenantID)
	r.mu.Unlock()
}

// InvalidateAll 清空所有缓存 (default 行变更时).
func (r *StorageResolver) InvalidateAll() {
	r.mu.Lock()
	r.cache = make(map[int64]*storageEntry)
	r.mu.Unlock()
}

// ResolvePublishConfig 返回该 tenant 当前应使用的对象存储配置, 供 Bus 侧 server-initiated upload 使用。
func (r *StorageResolver) ResolvePublishConfig(ctx context.Context, tenantID int64) (*PublishStorageConfig, error) {
	if tenantID < 0 {
		return nil, errors.New("drive.StorageResolver: tenantID must be >= 0")
	}
	cfg, err := r.resolveOSSConfig(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	return &PublishStorageConfig{
		Region:          cfg.Region,
		Endpoint:        cfg.Endpoint,
		ReadEndpoint:    cfg.ReadEndpoint,
		Bucket:          cfg.Bucket,
		AccessKeyID:     cfg.AccessKeyID,
		SecretAccessKey: cfg.SecretAccessKey,
		ForcePathStyle:  cfg.ForcePathStyle,
	}, nil
}

// build 不查缓存, 直接装一份 Store.
func (r *StorageResolver) build(ctx context.Context, tenantID int64) (object.Store, error) {
	cfg, err := r.resolveOSSConfig(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	store, err := oss.New(cfg)
	if err != nil {
		return nil, fmt.Errorf("drive.StorageResolver: oss.New: %w", err)
	}
	return store, nil
}

func (r *StorageResolver) resolveOSSConfig(ctx context.Context, tenantID int64) (oss.Config, error) {
	ov, err := r.repo.GetTenantOverride(ctx, tenantID)
	if err != nil {
		return oss.Config{}, fmt.Errorf("drive.StorageResolver: load override: %w", err)
	}

	var base *dom.StorageDefault
	if ov != nil && ov.DefaultID != nil {
		base, err = r.repo.GetDefaultByID(ctx, *ov.DefaultID)
		if err != nil {
			base = nil // fallback 到 active default
		}
	}
	if base == nil {
		base, err = r.repo.GetActiveDefault(ctx)
		if err != nil {
			return oss.Config{}, fmt.Errorf("drive.StorageResolver: no active default: %w", err)
		}
	}

	cfg := oss.Config{
		Kind:         string(base.Kind),
		Region:       base.Region,
		Endpoint:     base.Endpoint,
		ReadEndpoint: base.ReadEndpoint,
		Bucket:       base.Bucket,
		// ForcePathStyle 不再从 DB 读 (migration 000120 已删该列), 由 endpoint 启发式推导。
	}
	akRef := base.AccessKeySecretRef
	skRef := base.SecretKeySecretRef

	if ov != nil {
		if ov.Region != nil {
			cfg.Region = *ov.Region
		}
		if ov.Endpoint != nil {
			cfg.Endpoint = *ov.Endpoint
		}
		if ov.ReadEndpoint != nil {
			cfg.ReadEndpoint = *ov.ReadEndpoint
		}
		if ov.Bucket != nil {
			cfg.Bucket = *ov.Bucket
		}
		if ov.AccessKeySecretRef != nil && *ov.AccessKeySecretRef != "" {
			akRef = *ov.AccessKeySecretRef
		}
		if ov.SecretKeySecretRef != nil && *ov.SecretKeySecretRef != "" {
			skRef = *ov.SecretKeySecretRef
		}
	}
	// merge 完 endpoint 后再启发: 用最终生效的 endpoint 决定 path-style (覆盖了租户 override 的场景)。
	cfg.ForcePathStyle = svcstorage.PickPathStyle(cfg.Endpoint)

	ak, err := r.secret.Resolve(akRef)
	if err != nil {
		return oss.Config{}, fmt.Errorf("drive.StorageResolver: ak: %w", err)
	}
	sk, err := r.secret.Resolve(skRef)
	if err != nil {
		return oss.Config{}, fmt.Errorf("drive.StorageResolver: sk: %w", err)
	}
	cfg.AccessKeyID = ak
	cfg.SecretAccessKey = sk

	return cfg, nil
}
