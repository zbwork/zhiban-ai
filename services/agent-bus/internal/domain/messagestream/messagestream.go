// Package messagestream 是 chat / room agent streaming "流归属" 注册表 (Batch 3B T3.5).
//
// 每条 streaming agent message 写库前先 INSERT 一行, 记 stream_id / message_uuid /
// bus_node_id (流当前在哪个 cmd/bus 进程上跑) / cancel_token. stop / retry HTTP 入口按
// message_uuid 反查 owner_node:
//
//   - owner_node == self → 本进程 cancel + UPDATE state='cancelled'
//   - owner_node != self → Redis PUBLISH bus:cmd:cancel:<owner_node> 让对端 cancel
//
// state 由 chat.Service.finalize 终态时收尾 (done / cancelled / failed).
//
// 与 docs/modules/m4-conversations-and-messages.md §3.2 schema 对齐.
package messagestream

import (
	"context"
	"time"
)

// Stream 一行 message_streams.
type Stream struct {
	ID             int64
	StreamID       string
	TenantID       int64
	AccountID      int64
	ConversationID int64
	MessageUUID    string
	RuntimeSession string
	CancelToken    string
	BusNodeID      string
	State          string // active / done / cancelled / failed
	StartedAt      time.Time
	LastEventAt    time.Time
	FinishedAt     *time.Time
}

// CreateInput chat 服务 Register 时填的字段; ID / 时间戳 / state 由 DB 给默认.
type CreateInput struct {
	StreamID       string
	TenantID       int64
	AccountID      int64
	ConversationID int64
	MessageUUID    string
	CancelToken    string
	BusNodeID      string
}

// Repository message_streams 持久化窄接口.
type Repository interface {
	// Insert 在 chat.Service.runAgentInternal 写 streaming agent message 之前调用.
	// stream_id / message_uuid UNIQUE 冲突时返回原始 pg error (caller 视情况 fail-closed).
	Insert(ctx context.Context, in CreateInput) (*Stream, error)

	// GetByMessageUUID 查归属; 找不到 → apperr.ErrNotFound. stop / retry 路径用.
	GetByMessageUUID(ctx context.Context, messageUUID string) (*Stream, error)

	// GetByStreamID 按 stream_id 查; 找不到 → apperr.ErrNotFound. cancel listener 用.
	GetByStreamID(ctx context.Context, streamID string) (*Stream, error)

	// UpdateStateByStreamID 终态写入 + finished_at. fromActive=true 时 UPDATE WHERE state='active'
	// (幂等防护: 已 cancelled 的不会被 'done' 覆盖). 0-rowcount 视为已收尾, 不视为错误.
	UpdateStateByStreamID(ctx context.Context, streamID, state string, fromActive bool) error

	// CancelActiveByStreamID (3B 返修 #2) 把 'active' 行原子翻成 'cancelled' 并显式返回
	// 是否命中了 active 行. 用于 stop 路径区分:
	//   changed=true   → 我们真正把流从 active 翻成 cancelled; 应当 publish message.cancelled
	//   changed=false  → 流已被 finalize 自然收尾 (done/failed/cancelled); 不应再 publish
	//                    冒充的 message.cancelled (会产生矛盾 SSE).
	//
	// 与 UpdateStateByStreamID(state='cancelled', fromActive=true) 语义一致, 但显式吐
	// affected rows 让 caller 据此分支决策. err 仅在 DB 抖动时返回.
	CancelActiveByStreamID(ctx context.Context, streamID string) (changed bool, err error)

	// UpdateTerminalStateByStreamID (3B 返修 final patch) 是 finalize 终态写入的入口:
	// UPDATE WHERE state='active', 同时回吐 affected rows 和当前 state. 这让 finalize
	// 可以在 currentState='cancelled' 时跳过 publish message.completed / .failed
	// (典型: cross-node optimisticCancel 抢先翻 cancelled, owner 节点的 goroutine
	// 自然完成想 finalize('final') → 必须 gate 掉, 防止客户端先收 cancelled 再收 completed).
	//
	// 语义:
	//   changed=true   → state 真的从 active 翻到 newState; currentState == newState.
	//   changed=false  → 已经是终态 (done/cancelled/failed); currentState 反映当前值,
	//                    caller 根据 currentState 决定是否覆盖 messages.status / publish.
	//   currentState=""→ 行不存在 (不应该发生, caller 视情况 fallback).
	//
	// 比 UpdateStateByStreamID 多吐 currentState, 把 race 决策面交给 service 层.
	UpdateTerminalStateByStreamID(ctx context.Context, streamID, newState string) (changed bool, currentState string, err error)

	// TouchLastEventByStreamID streaming 期间刷 last_event_at (best-effort);
	// 现在仅在终态写入路径调用作为兜底, 后续可在 delta 路径加.
	TouchLastEventByStreamID(ctx context.Context, streamID string) error

	// UpdateOwnerNode (doc-12 Task D 队列) 把仍 active 的 stream 的 bus_node_id 改写为执行节点。
	// chat 队列 worker 消费任务时调用: stream 在 Send 节点创建 (owner=Send 节点), worker (可能是别的节点) 实际执行,
	// 须把归属切到自己, 让 running 态的 stop/cancel 路由到执行节点 (否则 cancel 到 Send 节点找不到 activeStream)。
	// 仅改 state='active' 行 (已终态不动)。
	UpdateOwnerNode(ctx context.Context, streamID, busNodeID string) error
}
