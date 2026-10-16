// cache.go — F03 v0.9.1 §4.6 进程内 SkillRail LRU cache + Invalidator 实现。
//
// 当前阶段（v0.9.1）：
//   - LRU keyed by (conversation_uuid)；条目存最近一次 GetSkillRail 的结果与构造时间。
//   - 默认 TTL = AGBUS_SKILL_RAIL_CONFIG_TTL（5min）。
//   - 写命中（NOTIFY listener 派发）→ 调用 Invalidator 接口的相应方法。
//
// 留口 v1：将"按 skill_id / agent_id / tenant_id 反向映射"做精确失效；当前实现采取
// 安全的 conservative-evict：任一信号都触发全量清空（chip rail 体量小、5min TTL，
// 全量清空对热路径影响可接受）。
package skill

import (
	"sync"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
)

// SkillRailEntry 缓存项。
type SkillRailEntry struct {
	Rail      *domskill.SkillRail
	StoredAt  time.Time
	Tenant    int64
	Agent     int64
	AccountID int64
}

// SkillRailCache 进程内 cache + Invalidator 实现。
type SkillRailCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[string]*SkillRailEntry // key = conversation_uuid
}

// NewSkillRailCache 构造；ttl<=0 走默认 5min。
func NewSkillRailCache(ttl time.Duration) *SkillRailCache {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &SkillRailCache{ttl: ttl, entries: map[string]*SkillRailEntry{}}
}

// Get 拿一个未过期的 cache 项；nil 即 miss。
func (c *SkillRailCache) Get(convUUID string) *SkillRailEntry {
	c.mu.RLock()
	e, ok := c.entries[convUUID]
	c.mu.RUnlock()
	if !ok {
		return nil
	}
	if time.Since(e.StoredAt) > c.ttl {
		c.mu.Lock()
		delete(c.entries, convUUID)
		c.mu.Unlock()
		return nil
	}
	return e
}

// Put 写一份 rail 进 cache；调用方需提供 tenant/agent/accountID 用于反向失效路径。
func (c *SkillRailCache) Put(convUUID string, rail *domskill.SkillRail, tenant, agent, account int64) {
	if convUUID == "" || rail == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[convUUID] = &SkillRailEntry{
		Rail: rail, StoredAt: time.Now(),
		Tenant: tenant, Agent: agent, AccountID: account,
	}
}

// ----------------------------------------------------------------------------
// Invalidator 实现
// ----------------------------------------------------------------------------

func (c *SkillRailCache) InvalidateSkill(_ int64) { c.evictAll() }
func (c *SkillRailCache) InvalidateAll()          { c.evictAll() }
func (c *SkillRailCache) InvalidateAgent(agentID int64) {
	c.evictMatching(func(e *SkillRailEntry) bool { return e.Agent == agentID })
}
func (c *SkillRailCache) InvalidateTenant(tenantID int64) {
	c.evictMatching(func(e *SkillRailEntry) bool { return e.Tenant == tenantID })
}
func (c *SkillRailCache) InvalidateUserAgent(aid, agid int64) {
	c.evictMatching(func(e *SkillRailEntry) bool { return e.AccountID == aid && e.Agent == agid })
}

func (c *SkillRailCache) evictAll() {
	c.mu.Lock()
	c.entries = map[string]*SkillRailEntry{}
	c.mu.Unlock()
}

func (c *SkillRailCache) evictMatching(pred func(*SkillRailEntry) bool) {
	c.mu.Lock()
	for k, v := range c.entries {
		if pred(v) {
			delete(c.entries, k)
		}
	}
	c.mu.Unlock()
}
