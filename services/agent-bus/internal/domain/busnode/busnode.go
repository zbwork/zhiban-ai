// Package busnode 是 cmd/bus 进程注册表的领域类型 (Batch 3B T3.5).
//
// 每个 bus 进程启动时 INSERT 一行 (node_id 唯一), 心跳 UPDATE last_seen_at, 优雅
// shutdown 时 UPDATE terminated_at. 节点宕机时 row 留下, 通过 last_seen_at 判断"已死"
// (跨节点 Stop 兜底逻辑会用).
//
// node_id 由 cmd/bus/main.go::computeBusNodeID() 生成, 格式
// `<hostname>:<pid>:<bootEpochMs>`, 与 Redis Fanout meta HASH 的 bus_node_id 字段
// 共用. message_streams.bus_node_id 也是同一标识.
package busnode

import (
	"context"
	"time"
)

// Node 一行 bus_nodes.
type Node struct {
	ID           int64
	NodeID       string
	Hostname     string
	PID          int
	BootEpochMs  int64
	StartedAt    time.Time
	LastSeenAt   time.Time
	TerminatedAt *time.Time
	Metadata     map[string]any
}

// Repository bus_nodes 持久化窄接口.
//
// Register 是 UPSERT 语义: 同一 node_id 重复 register (热重启或单元测试反复构造) 时,
// 把 last_seen_at 拍到现在, terminated_at 清空; 不假设 unique 冲突.
type Repository interface {
	// Register 注册节点; idempotent.
	Register(ctx context.Context, n *Node) error

	// Heartbeat 更新 last_seen_at = now(). node_id 不存在时返回 ErrNotRegistered.
	Heartbeat(ctx context.Context, nodeID string) error

	// Terminate 标记节点优雅 shutdown (terminated_at=now()). 多次调用幂等.
	Terminate(ctx context.Context, nodeID string) error

	// GetByNodeID 拉一行; 不存在 → apperr.ErrNotFound.
	GetByNodeID(ctx context.Context, nodeID string) (*Node, error)
}
