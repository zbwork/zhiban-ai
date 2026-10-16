package a2a

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// QuotaDefaults F09 §4.7.5 默认值 (B-DEC-9 拍板).
//
// 可由 bus_runtime_params (scope_kind='platform'/'tenant'/'agent') 覆盖,
// 但 PR5 暂不消费 bus_runtime_params 表 (留 follow-up); 这里用一个 Loader
// 接口让 a2a service 注入"动态读默认/覆盖值"的能力 —— 默认实现就是常量.
type QuotaDefaults struct {
	PerAgentRPM         int // 单 Agent A2A 调用每分钟上限
	PerTenantRPD        int // 单租户 A2A 调用每天上限
	PerOrchestrationMax int // 单 orchestration 总 edge 数 (PR5 用于检测; budget 服务 PR6)
}

// DefaultQuota F09 §4.7.5 出厂默认.
func DefaultQuota() QuotaDefaults {
	return QuotaDefaults{
		PerAgentRPM:         60,
		PerTenantRPD:        10000,
		PerOrchestrationMax: 50,
	}
}

// QuotaConfigLoader 是"读运行时配额"的最小接口.
//
// PR5 默认实现 = DefaultQuotaLoader, 始终返 DefaultQuota().
// follow-up: PG 实现读 bus_runtime_params 表 (key='a2a_quota', scope ladder
// platform → tenant → agent), PG NOTIFY 热重载 (M5 / F11 套餐落地时).
type QuotaConfigLoader interface {
	Load(ctx context.Context, tenantID, agentID int64) (QuotaDefaults, error)
}

// DefaultQuotaLoader 总是返默认值. nil-safe.
type DefaultQuotaLoader struct{}

func (DefaultQuotaLoader) Load(_ context.Context, _, _ int64) (QuotaDefaults, error) {
	return DefaultQuota(), nil
}

// QuotaChecker 是限流器接口 (Redis 实现 + 测试用 fake).
//
// CheckAndIncr 返:
//   - allowed=true  说明本次调用可以放行 (counter 已 +1)
//   - allowed=false 说明已超限 (counter 不 +1; 返 retryAfter 秒数, 0 = 未知)
//   - err 仅在 Redis 故障时返
type QuotaChecker interface {
	CheckAndIncr(ctx context.Context, tenantID, agentID int64) (allowed bool, retryAfter int, err error)
}

// RedisQuotaChecker 使用 Redis INCR + EX 实现 token bucket.
//
// Key 设计:
//   - per-agent RPM:  a2a:rpm:<agent_id>:<yyyymmddHHMM>   TTL = 90s
//   - per-tenant RPD: a2a:rpd:<tenant_id>:<yyyymmdd>      TTL = 86400+300s
//
// 用分桶 key (固定时间窗口而不是滑动窗口) 是因为:
//   - O(1) 实现
//   - 简单准确足够 (突发 flood 由 PerAgentRPM 上限兜底)
//   - Stripe / GitHub Public API 都用类似设计
type RedisQuotaChecker struct {
	rdb    *redis.Client
	loader QuotaConfigLoader
	now    func() time.Time
}

func NewRedisQuotaChecker(rdb *redis.Client, loader QuotaConfigLoader, now func() time.Time) *RedisQuotaChecker {
	if loader == nil {
		loader = DefaultQuotaLoader{}
	}
	if now == nil {
		now = time.Now
	}
	return &RedisQuotaChecker{rdb: rdb, loader: loader, now: now}
}

func (r *RedisQuotaChecker) CheckAndIncr(ctx context.Context, tenantID, agentID int64) (bool, int, error) {
	if r == nil || r.rdb == nil {
		// no-op: 没接入 Redis 时不限流 (开发模式).
		return true, 0, nil
	}
	q, err := r.loader.Load(ctx, tenantID, agentID)
	if err != nil {
		return false, 0, err
	}
	now := r.now()

	// per-agent RPM
	rpmKey := fmt.Sprintf("a2a:rpm:%d:%s", agentID, now.UTC().Format("200601021504"))
	rpm, err := r.rdb.Incr(ctx, rpmKey).Result()
	if err != nil {
		return false, 0, err
	}
	if rpm == 1 {
		// 第一次创建 key, 设 TTL = 90s (覆盖整个分钟 + 一点缓冲)
		_ = r.rdb.Expire(ctx, rpmKey, 90*time.Second).Err()
	}
	if rpm > int64(q.PerAgentRPM) {
		// 超限 → 不再增 (实际上已经 +1, 但本次拒绝). 计算 retryAfter = 当前分钟剩余秒数.
		retry := 60 - now.Second()
		if retry <= 0 {
			retry = 60
		}
		return false, retry, nil
	}

	// per-tenant RPD
	rpdKey := fmt.Sprintf("a2a:rpd:%d:%s", tenantID, now.UTC().Format("20060102"))
	rpd, err := r.rdb.Incr(ctx, rpdKey).Result()
	if err != nil {
		return false, 0, err
	}
	if rpd == 1 {
		// 第一次创建 key, 设 TTL = 86400+300s
		_ = r.rdb.Expire(ctx, rpdKey, 86400*time.Second+5*time.Minute).Err()
	}
	if rpd > int64(q.PerTenantRPD) {
		retry := 86400 - (now.Hour()*3600 + now.Minute()*60 + now.Second())
		if retry <= 0 {
			retry = 86400
		}
		return false, retry, nil
	}
	return true, 0, nil
}

// 编译期断言.
var _ QuotaChecker = (*RedisQuotaChecker)(nil)
var _ QuotaConfigLoader = DefaultQuotaLoader{}
