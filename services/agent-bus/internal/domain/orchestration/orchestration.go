// Package orchestration 定义主-子 Agent 编排聚合 (F09 Phase B §2.3.10):
//   - agent_orchestrations 根记录 + 预算 + 状态机
//   - agent_orchestration_steps 子步骤 (planner / worker / reducer / validator)
//
// 设计:
//   - orchestration 与 steps 是 1:N 强一致聚合;同一包暴露
//   - call_edge_id 反指 a2a_call_edges 是 soft FK (分区表受限),仅 service 层校验
//   - PR4 仅暴露 CRUD;真正的编排状态机 (start/step/finish backchannel) 留 PR5
//
// 不在本包: A2A 调用边 (走 a2acalledge 包), Selector 决策 (走 speakerdecision 包).
package orchestration

import (
	"context"
	"time"
)

// Status agent_orchestrations.status 取值.
type Status string

const (
	StatusPending         Status = "pending"
	StatusRunning         Status = "running"
	StatusDone            Status = "done"
	StatusFailed          Status = "failed"
	StatusCancelled       Status = "cancelled"
	StatusTimedOut        Status = "timed_out"
	StatusBudgetExhausted Status = "budget_exhausted"
)

// StepRole agent_orchestration_steps.role 取值.
type StepRole string

const (
	RolePlanner   StepRole = "planner"
	RoleWorker    StepRole = "worker"
	RoleReducer   StepRole = "reducer"
	RoleValidator StepRole = "validator"
)

// StepStatus agent_orchestration_steps.status 取值.
type StepStatus string

const (
	StepPending StepStatus = "pending"
	StepRunning StepStatus = "running"
	StepDone    StepStatus = "done"
	StepFailed  StepStatus = "failed"
	StepSkipped StepStatus = "skipped"
)

// Orchestration agent_orchestrations 行.
type Orchestration struct {
	ID              int64
	UUID            string
	TenantID        int64
	RoomID          *int64
	TriggerMsgID    *int64
	MasterAgentID   int64
	DepthLimit      int16
	TokenBudget     int32
	TimeBudgetMs    int32
	Status          Status
	PlanSummary     string
	FinalSummary    string
	StartedAt       *time.Time
	CompletedAt     *time.Time
	ErrorMessage    string
	TokensInTotal   int32
	TokensOutTotal  int32
	EdgesCount      int32
	MaxDepthReached int16
	CreatedAt       time.Time
	CreatedBy       *int64
	UpdatedAt       time.Time
	UpdatedBy       *int64
	IsDeleted       bool
	DeletedAt       *time.Time
}

// Step agent_orchestration_steps 行.
type Step struct {
	ID              int64
	UUID            string
	OrchestrationID int64
	CallEdgeID      *int64 // soft FK → a2a_call_edges (分区表)
	StepIndex       int16
	Role            StepRole
	WorkerAgentID   *int64
	InputSummary    string
	OutputSummary   string
	Status          StepStatus
	ErrorMessage    string
	TokensIn        int32
	TokensOut       int32
	StartedAt       *time.Time
	CompletedAt     *time.Time
	CreatedAt       time.Time
	CreatedBy       *int64
	UpdatedAt       time.Time
	UpdatedBy       *int64
	IsDeleted       bool
	DeletedAt       *time.Time
}

// CreateInput 新建 Orchestration.大部分预算字段为 0 → 走 DB DEFAULT (depth_limit=3,
// token_budget=16000, time_budget_ms=60000).
type CreateInput struct {
	TenantID      int64
	RoomID        *int64
	TriggerMsgID  *int64
	MasterAgentID int64
	DepthLimit    int16 // 0 = 走 DB default
	TokenBudget   int32
	TimeBudgetMs  int32
	CreatedBy     *int64
}

// CreateStepInput 新建 Step.
type CreateStepInput struct {
	OrchestrationID int64
	CallEdgeID      *int64
	StepIndex       int16
	Role            StepRole
	WorkerAgentID   *int64
	InputSummary    string
	CreatedBy       *int64
}

// UpdateStatusInput 编排状态推进 (start / finish / fail / budget_exhausted).
//   - 字段为 nil = 不动
//   - service 层负责 status 状态机合法性校验
type UpdateStatusInput struct {
	Status          *Status
	PlanSummary     *string
	FinalSummary    *string
	ErrorMessage    *string
	StartedAt       *time.Time
	CompletedAt     *time.Time
	TokensInTotal   *int32
	TokensOutTotal  *int32
	EdgesCount      *int32
	MaxDepthReached *int16
	UpdatedBy       *int64
}

// UpdateStepInput step 状态推进.
type UpdateStepInput struct {
	CallEdgeID    *int64
	OutputSummary *string
	Status        *StepStatus
	ErrorMessage  *string
	TokensIn      *int32
	TokensOut     *int32
	StartedAt     *time.Time
	CompletedAt   *time.Time
	UpdatedBy     *int64
}

// Repository orchestration 聚合仓储 (含 steps).
type Repository interface {
	// Orchestration 根
	Create(ctx context.Context, in CreateInput) (*Orchestration, error)
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*Orchestration, error)
	GetByID(ctx context.Context, id int64) (*Orchestration, error)
	UpdateStatus(ctx context.Context, tenantID int64, uuid string, in UpdateStatusInput) (*Orchestration, error)
	ListByTenant(ctx context.Context, tenantID int64, limit, offset int) ([]*Orchestration, int, error)

	// Steps
	CreateStep(ctx context.Context, in CreateStepInput) (*Step, error)
	UpdateStep(ctx context.Context, stepUUID string, in UpdateStepInput) (*Step, error)
	ListSteps(ctx context.Context, orchestrationID int64) ([]*Step, error)
}
