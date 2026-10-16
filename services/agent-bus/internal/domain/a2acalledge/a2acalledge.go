// Package a2acalledge 定义 A2A 调用图边 (F09 Phase B §2.3.9).
//
// 月分区表 + 主键 (id, created_at).PR4 仅暴露:
//   - Insert (pending 状态;真正 invoke 由 PR5 service/a2a 调用并 Update 状态)
//   - 按 UUID / idem_key / parent_edge_id 反查 (防环 + 重试幂等)
//   - 按 orchestration_id / room_id 列表查 (admin 治理页 A2A 图)
//
// **不在本包**:
//   - depth 防环算法 (沿 parent_edge_id 回溯) → service/a2a 实现
//   - whitelist / capability / payload redaction / quota 6 重校验 → service/a2a 实现
//   - parent_edge_id self-FK (分区表 ≤ PG17 限制) → 仅 service 层校验,DB 不强制
package a2acalledge

import (
	"context"
	"time"
)

// InvokeKind a2a_call_edges.invoke_kind 取值。
// sync / async 走 edge 轮询; stream 在 v1j 起开放为 Bus 进程内 SSE 实时中继 +
// GetEdge 持久终态兜底。
type InvokeKind string

const (
	InvokeSync   InvokeKind = "sync"
	InvokeAsync  InvokeKind = "async"
	InvokeStream InvokeKind = "stream"
)

// Status a2a_call_edges.status 取值.
type Status string

const (
	StatusPending          Status = "pending"
	StatusAwaitingApproval Status = "awaiting_approval"
	StatusRunning          Status = "running"
	StatusDone             Status = "done"
	StatusFailed           Status = "failed"
	StatusCancelled        Status = "cancelled"
	StatusRejected         Status = "rejected"
	StatusExpired          Status = "expired"
	StatusDroppedLoop      Status = "dropped_loop"
	StatusDroppedBudget    Status = "dropped_budget"
	StatusDroppedWhitelist Status = "dropped_whitelist"
)

// Edge a2a_call_edges 行.
type Edge struct {
	ID              int64
	UUID            string
	TenantID        int64
	RoomID          *int64
	FromAgentID     int64
	ToAgentID       int64
	OrchestrationID *int64
	ParentEdgeID    *int64
	// OriginConversationID is the A2A contextId: the human conversation that
	// started this delegated task tree. nil for SDK/runtime calls without one.
	OriginConversationID *int64
	// RootEdgeID / RootEdgeCreatedAt (Phase5 · migration 000086): root chain 锚点。
	// nil = 本 edge 即根链根 (以自身 (id, created_at) 计数)；子调用写链顶祖先的 (id, created_at)。
	RootEdgeID        *int64
	RootEdgeCreatedAt *time.Time
	Depth             int16
	IdemKey           string
	// RequestFingerprint (Phase5): 规范化调用指纹, 重复调用治理用; 与 idem_key 正交。
	RequestFingerprint string
	InvokeKind         InvokeKind
	RequestPayload     []byte // 原始 JSON (脱敏后, ≤16 KB; 详 §4.7)
	ResponsePayload    []byte
	Status             Status
	StartedAt          *time.Time
	CompletedAt        *time.Time
	ErrorMessage       string
	TokensIn           int32
	TokensOut          int32
	LatencyMs          *int32
	CreatedAt          time.Time
	CreatedBy          *int64
	UpdatedAt          time.Time
	UpdatedBy          *int64
	IsDeleted          bool
	DeletedAt          *time.Time
}

// InsertInput 写一条 edge (status=pending).request_payload 由 service 层
// 完成 redaction + size cap 后传入.
type InsertInput struct {
	TenantID             int64
	RoomID               *int64
	FromAgentID          int64
	ToAgentID            int64
	OrchestrationID      *int64
	ParentEdgeID         *int64
	OriginConversationID *int64
	// RootEdgeID / RootEdgeCreatedAt (Phase5): nil 表示本次即根链根 (DB 落 NULL, 计数按自身 id)。
	RootEdgeID         *int64
	RootEdgeCreatedAt  *time.Time
	Depth              int16
	IdemKey            string
	RequestFingerprint string
	InvokeKind         InvokeKind
	RequestPayload     []byte
	CreatedBy          *int64
}

// ChainStats (Phase5) root chain 聚合结果, 供预算治理。
type ChainStats struct {
	TotalCalls      int // 同一 root chain 内已存在的 edge 数 (含根)
	SameFingerprint int // 同一 root chain 内 request_fingerprint 相同的 edge 数
}

// UpdateStatusInput 状态推进 (awaiting_approval / running / done / failed / cancelled / rejected / expired / dropped_*).
type UpdateStatusInput struct {
	Status          *Status
	ResponsePayload []byte  // 非 nil 整体替换;nil 不动
	ErrorMessage    *string // 非 nil 整体替换;空串转 NULL
	StartedAt       *time.Time
	CompletedAt     *time.Time
	TokensIn        *int32
	TokensOut       *int32
	LatencyMs       *int32
	UpdatedBy       *int64
	ExpectStatuses  []Status // 非空时仅允许当前 status 属于集合的行被推进;并发状态机守卫
}

// ListFilter admin 治理页 / orchestration 详情用.
//
// 至少给一个维度: OrchestrationID / RoomID / FromAgentID / ToAgentID / 时间窗 (CreatedAfter or CreatedBefore);
// 全空返 ErrInvalidParams. CreatedAfter+CreatedBefore 让 admin A2A 治理页可按时间扫 (created_at 是分区 key,
// PG 只命中近期分区, 不会全表扫).
type ListFilter struct {
	TenantID        int64
	OrchestrationID *int64
	RoomID          *int64
	FromAgentID     *int64
	ToAgentID       *int64
	StatusIn        []Status
	CreatedAfter    *time.Time
	CreatedBefore   *time.Time
	Limit           int
	Offset          int
}

// Repository A2A edge 仓储.
type Repository interface {
	Insert(ctx context.Context, in InsertInput) (*Edge, error)

	// FindByIdemKey 防重: tenant + idem_key 已有 row → 返回它 (用于重试幂等).
	// 未找到 → ErrNotFound.
	FindByIdemKey(ctx context.Context, tenantID int64, idemKey string) (*Edge, error)

	GetByUUID(ctx context.Context, tenantID int64, uuid string, createdAt time.Time) (*Edge, error)
	FindLatestByUUID(ctx context.Context, tenantID int64, uuid string) (*Edge, error)
	GetByID(ctx context.Context, id int64, createdAt time.Time) (*Edge, error)

	// UpdateStatus 用 (uuid, createdAt) 定位(分区).PR5 状态机由 service 层校验.
	UpdateStatus(ctx context.Context, tenantID int64, uuid string, createdAt time.Time, in UpdateStatusInput) (*Edge, error)

	// ListAncestors 沿 parent_edge_id 链回溯 (链路分析用).PR4 暂仅声明,PR5 service/a2a 调用.
	// 由 service 层守住 depth ≤ max_depth (默认 5, §12.4.1);DB 已有 depth ≤ 5 CHECK 兜底 (000086).
	ListAncestors(ctx context.Context, tenantID int64, startEdgeID int64, startCreatedAt time.Time, max int) ([]*Edge, error)

	// ChainStats (Phase5) 聚合同一 root chain 的调用总数与同指纹计数 (单条 SQL, 走
	// idx_a2a_edges_root_chain)。rootID/rootCreatedAt 定位根链;fingerprint 为空则 SameFingerprint=0。
	// 统计范围 = 根自身 (id=rootID) + 其所有子孙 (root_edge_id=rootID)。
	ChainStats(ctx context.Context, tenantID int64, rootID int64, rootCreatedAt time.Time, fingerprint string) (ChainStats, error)

	List(ctx context.Context, f ListFilter) ([]*Edge, int, error)

	// FailStale (A2A v1a 悬挂兜底) 把 created_at < cutoff 且仍 pending/running 的 edge 批量标
	// failed: pending → pendingReason, running → runningReason。跨租户 (系统级扫描)。
	// 幂等条件 UPDATE; 扫描窗口下界由实现限定 (近 7 天, 分区裁剪), 返回受影响行数。
	FailStale(ctx context.Context, cutoff time.Time, pendingReason, runningReason string) (int64, error)
}
