// K8s mode resolver —— 每用户/租户一份 OpenClaw Pod。
//
// 工作流：
//
//  1. 按 (tenantID, accountID) 在 runtime_instances 表里查记录
//  2. 没有 → 创建一条 status=pending，并触发部署系统（workload API）
//     拉起 Pod；同步返回 status=creating，让客户端轮询或下次再调
//  3. 有但 status=ready → 直接返回 endpoint_url
//  4. 有但状态异常 → 触发恢复
//
// v1 留口：真实的 workload API（clawmanager / deployment-workloads）
// 由 WorkloadClient 接口注入。这里给一个 stub 实现，让本地编译不依赖
// 外部系统；真接到 K8s 时换成正经实现即可。
package openclaw

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// WorkloadClient 是"找/拉 OpenClaw Pod"的能力抽象。
// 真接 K8s 时把它实现为 clawmanager / deployment-workloads / K8s API 客户端。
type WorkloadClient interface {
	// EnsureWorkload 确保有一份运行中的 Pod。如果 Pod 还没就绪，可以返回
	// pending=true 且 podURL="" —— 上层会把状态写回 runtime_instances 并
	// 让客户端稍后重试。
	EnsureWorkload(ctx context.Context, tenantID, accountID int64, image string) (podURL string, pending bool, err error)

	// DeleteWorkload 用于按需回收（idle 太久 / 用户退出登录）。
	DeleteWorkload(ctx context.Context, tenantID, accountID int64) error
}

// LegacyK8sResolver 把 (tenantID, accountID) 解析到一个独立 Pod 的入口 URL (DEPRECATED,
// Batch 2C 起仅供旧 HTTP+SSE adapter; 新代码请用 K8sRegistryResolver, 按 runtime_registration_id 解析)。
type LegacyK8sResolver struct {
	logger       *log.Logger
	pool         *pgxpool.Pool
	workloadCli  WorkloadClient
	openclawCode string // runtime_registrations.code = "openclaw"
	image        string // 镜像 tag

	// 缓存：避免每条消息都查 DB
	mu    sync.RWMutex
	cache map[string]legacyCacheEntry
}

type legacyCacheEntry struct {
	URL    string
	Bearer string
	ExpAt  time.Time
}

// NewLegacyK8sResolver 构造 K8s mode resolver (DEPRECATED)。
func NewLegacyK8sResolver(logger *log.Logger, pool *pgxpool.Pool, cli WorkloadClient, image string) *LegacyK8sResolver {
	return &LegacyK8sResolver{
		logger:       logger,
		pool:         pool,
		workloadCli:  cli,
		openclawCode: "openclaw",
		image:        image,
		cache:        map[string]legacyCacheEntry{},
	}
}

func (r *LegacyK8sResolver) cacheKey(tenantID, accountID int64) string {
	return fmt.Sprintf("%d:%d", tenantID, accountID)
}

func (r *LegacyK8sResolver) Resolve(ctx context.Context, tenantID, accountID int64) (string, string, error) {
	if tenantID == 0 || accountID == 0 {
		return "", "", errors.New("k8s resolver: no identity (tenantID/accountID required)")
	}

	key := r.cacheKey(tenantID, accountID)
	r.mu.RLock()
	if c, ok := r.cache[key]; ok && time.Now().Before(c.ExpAt) && c.URL != "" {
		r.mu.RUnlock()
		return c.URL, c.Bearer, nil
	}
	r.mu.RUnlock()

	// 1. 查 runtime_instances
	var (
		instanceID int64
		status     string
		endpoint   *string
		secretRef  *string
	)
	err := r.pool.QueryRow(ctx, `
		SELECT ri.id, ri.status, ri.endpoint_url, ri.agent_gateway_token
		FROM runtime_instances ri
		JOIN runtime_registrations rr ON rr.id = ri.runtime_id
		WHERE rr.code = $1 AND ri.tenant_id = $2 AND ri.account_id = $3 AND ri.deleted_at IS NULL
		LIMIT 1
	`, r.openclawCode, tenantID, accountID).Scan(&instanceID, &status, &endpoint, &secretRef)

	if err != nil && err.Error() != "no rows in result set" {
		// pgx ErrNoRows path 兼容
		if !isNoRows(err) {
			r.logger.Error(ctx, "k8s resolver query failed", "err", err)
			return "", "", err
		}
		// fallthrough as no rows
		err = nil
	}

	if instanceID == 0 {
		// 2. 没记录 → 插一条 pending，并尝试 EnsureWorkload
		_, err = r.pool.Exec(ctx, `
			INSERT INTO runtime_instances (tenant_id, account_id, runtime_id, status, image_version, metadata)
			VALUES ($1, $2, (SELECT id FROM runtime_registrations WHERE code=$3 LIMIT 1), 'pending', $4, '{}'::jsonb)
		`, tenantID, accountID, r.openclawCode, r.image)
		if err != nil {
			return "", "", fmt.Errorf("create runtime_instance: %w", err)
		}
	}

	// 3. 让 workload client 拉/查 Pod
	if r.workloadCli == nil {
		return "", "", errors.New("k8s mode but workload client not configured")
	}
	podURL, pending, err := r.workloadCli.EnsureWorkload(ctx, tenantID, accountID, r.image)
	if err != nil {
		_, _ = r.pool.Exec(ctx, `
			UPDATE runtime_instances SET status='failed', error_message=$1, updated_at=now()
			WHERE tenant_id=$2 AND account_id=$3 AND runtime_id=(SELECT id FROM runtime_registrations WHERE code=$4)
		`, err.Error(), tenantID, accountID, r.openclawCode)
		return "", "", err
	}
	if pending || podURL == "" {
		_, _ = r.pool.Exec(ctx, `
			UPDATE runtime_instances SET status='starting', updated_at=now()
			WHERE tenant_id=$1 AND account_id=$2 AND runtime_id=(SELECT id FROM runtime_registrations WHERE code=$3)
		`, tenantID, accountID, r.openclawCode)
		return "", "", errors.New("openclaw instance is still starting, please retry shortly")
	}

	// 4. 就绪 → 写回 endpoint_url，缓存
	_, _ = r.pool.Exec(ctx, `
		UPDATE runtime_instances SET status='ready', endpoint_url=$1, last_healthy_at=now(), updated_at=now()
		WHERE tenant_id=$2 AND account_id=$3 AND runtime_id=(SELECT id FROM runtime_registrations WHERE code=$4)
	`, podURL, tenantID, accountID, r.openclawCode)

	r.mu.Lock()
	r.cache[key] = legacyCacheEntry{URL: podURL, Bearer: "", ExpAt: time.Now().Add(30 * time.Second)}
	r.mu.Unlock()
	return podURL, "", nil
}

func isNoRows(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return s == "no rows in result set" || s == "scany: no rows in result set"
}
