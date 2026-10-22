// Package ratelimit 是 OAuth2 token endpoint 的 per-client_id token bucket 限流器。
//
// 从 internal/transport/http/external/oauth.go 提取出来; F01 §3.6 (Agent SDK client_credentials grant)
// + F04 §3.5 (App authorization_code grant) 共用一份, 避免多套限流器并存。
//
// 设计 (codex challenge #3 修复一致):
//   - 每个 client_id 一个 bucket; 默认 burst=5, refill=1/s
//   - bucket lazy-init; client_id="" (匿名) 共用一个 "<anon>" 桶, 滥用面同口径
//   - 进程内 map, 单实例; 多副本部署 N 倍但比无限制好得多 (上 Redis 是 v2)
//
// 用法:
//
//	lim := ratelimit.NewClientIDLimiter(5, 1)
//	if !lim.Allow(clientID, time.Now()) {
//	    return apperr.TooManyRequests
//	}
//
// 注意: 即使 clientID 不存在 / 无效, 也消耗桶 — 防 "无 client_id 撞库" 攻击。
package ratelimit

import (
	"sync"
	"time"
)

// ClientIDLimiter 按 client_id 分桶限流; goroutine-safe。
type ClientIDLimiter struct {
	mu      sync.Mutex
	buckets map[string]*clientBucket
	limit   float64 // burst (桶容量)
	rate    float64 // tokens / sec (补给速率)
}

type clientBucket struct {
	tokens     float64
	lastRefill time.Time
}

// NewClientIDLimiter 构造限流器; burst = 桶容量 (允许的瞬时突发), ratePerSec = 每秒补给速率。
//
// 默认推荐: burst=5, ratePerSec=1 (即 平均 1/s, 突发 5 个)。
func NewClientIDLimiter(burst, ratePerSec float64) *ClientIDLimiter {
	return &ClientIDLimiter{
		buckets: map[string]*clientBucket{},
		limit:   burst,
		rate:    ratePerSec,
	}
}

// Allow 返 true 则放行 + 消耗 1 token; false 则拒绝。
//
// clientID 为空时归入共用 "<anon>" 桶 (防绕过 / 探测)。
// now 由 caller 注入便于测试; 生产传 time.Now()。
func (l *ClientIDLimiter) Allow(clientID string, now time.Time) bool {
	if clientID == "" {
		clientID = "<anon>"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[clientID]
	if !ok {
		b = &clientBucket{tokens: l.limit, lastRefill: now}
		l.buckets[clientID] = b
	}
	// refill
	if dt := now.Sub(b.lastRefill).Seconds(); dt > 0 {
		b.tokens += dt * l.rate
		if b.tokens > l.limit {
			b.tokens = l.limit
		}
		b.lastRefill = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// Stats 暴露当前桶数 (给运维 / 测试用; 不影响业务)。
func (l *ClientIDLimiter) Stats() (numBuckets int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
