// Package wukongwh 处理 WuKongIM 出站 webhook(ADR-0026)。
//
// 安全:WuKong webhook 默认无签名,本 handler 用**内网 secret(header/query)**校验来源 +
// message_id 幂等。部署上 webhook 只来自内网 WuKong。
package wukongwh

import (
	"context"
	"sync"
)

// Idempotency 按 message_id 去重:首次返回 firstTime=true,重放返回 false。
type Idempotency interface {
	SeenOrMark(ctx context.Context, key string) (firstTime bool, err error)
}

// MemIdempotency 是单实例内存实现(Phase 1)。
//
// 注意:生产多实例需换持久/共享实现(Redis SETNX TTL 或 PG UNIQUE,对标 agent_trigger_log)。
// 接口稳定,替换实现不影响 handler。
type MemIdempotency struct {
	mu   sync.Mutex
	seen map[string]struct{}
}

func NewMemIdempotency() *MemIdempotency {
	return &MemIdempotency{seen: make(map[string]struct{})}
}

func (m *MemIdempotency) SeenOrMark(_ context.Context, key string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.seen[key]; ok {
		return false, nil
	}
	m.seen[key] = struct{}{}
	return true, nil
}
