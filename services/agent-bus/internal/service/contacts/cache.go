package contacts

import (
	"sync"
	"time"
)

// policyCache 是 contacts 服务的 in-process TTL 缓存 (M2.6)。
//
// 只缓存 ContactPolicy: 它在 /contacts 几乎所有路径都被读, 是最划算的一项。
// 失效路径有两条:
//   - TTL 到期 (默认 5min, 与客户端缓存对齐)
//   - 收到 PG NOTIFY config_change payload="contact_policies:<tid>" → Invalidate
//
// 协程安全。
type policyCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[int64]policyEntry
}

type policyEntry struct {
	val ContactPolicy
	exp time.Time
}

func newPolicyCache(ttl time.Duration) *policyCache {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &policyCache{ttl: ttl, entries: map[int64]policyEntry{}}
}

func (c *policyCache) Get(tenantID int64) (ContactPolicy, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c == nil {
		return ContactPolicy{}, false
	}
	e, ok := c.entries[tenantID]
	if !ok {
		return ContactPolicy{}, false
	}
	if time.Now().After(e.exp) {
		return ContactPolicy{}, false
	}
	return e.val, true
}

func (c *policyCache) Put(tenantID int64, p ContactPolicy) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[tenantID] = policyEntry{val: p, exp: time.Now().Add(c.ttl)}
}

// Invalidate 删除单个租户的 policy 缓存。
func (c *policyCache) Invalidate(tenantID int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.entries, tenantID)
}

// InvalidateAll 删除所有缓存条目, 用于 listener 收到不可识别 payload 时的兜底。
func (c *policyCache) InvalidateAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries = map[int64]policyEntry{}
}
