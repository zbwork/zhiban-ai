// Package agentkb 是 F07 D5/D9 — agent_kb_bindings 的领域类型 + 仓储接口。
package agentkb

import (
	"context"
	"time"
)

const (
	KindAttached = "attached"
	KindRequired = "required"
	KindOptional = "optional"
)

// Binding 一行 agent_kb_bindings。
type Binding struct {
	ID          int64
	AgentID     int64
	KBID        int64
	BindingKind string
	Priority    int
	Note        string
	CreatedBy   int64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Repository 持久层。
type Repository interface {
	// Attach 绑 KB 到 agent。kind 默认 "attached"。
	Attach(ctx context.Context, agentID, kbID, createdBy int64, kind string, priority int) (*Binding, error)
	// Detach 软删 binding。
	Detach(ctx context.Context, agentID, kbID int64) error
	// ListByAgent 列某 agent 所有有效 binding (按 priority desc)。
	ListByAgent(ctx context.Context, agentID int64) ([]*Binding, error)
	// IsBound 检查给定 (agent, kb) 是否绑定 + 未软删。ZAP capability check 用。
	IsBound(ctx context.Context, agentID, kbID int64) (bool, error)
}
