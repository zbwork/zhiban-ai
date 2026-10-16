// Package speakerdecision 定义 SpeakerSelector 决策审计 (F09 Phase B §2.3.8).
//
// speaker_decisions 是月分区表 + 高频写入 (每条群消息触发一行).PR4 只暴露:
//   - 写入 (Insert)
//   - 按 room / agent 反查 (admin 治理页)
//
// 不在本包: 实时聚合 / 跨分区扫描全局 (那是 audit 报表能力).
package speakerdecision

import (
	"context"
	"time"
)

// SelectionKind speaker_decisions.selection_kind 取值.
type SelectionKind string

const (
	SelectionSingle   SelectionKind = "single"
	SelectionParallel SelectionKind = "parallel"
	SelectionNone     SelectionKind = "none"
)

// Decision speaker_decisions 行.
type Decision struct {
	ID              int64
	UUID            string
	TenantID        int64
	RoomID          int64
	TriggerMsgID    *int64
	PolicyID        *int64
	BasePolicy      string
	Candidates      []byte // 原始 JSON; admin 治理页直接渲染,service 层不必反序列化
	SelectedAgentID *int64
	SelectedReason  string
	SelectionKind   SelectionKind
	LatencyMs       *int32
	JudgeTokensIn   *int32
	JudgeTokensOut  *int32
	CreatedAt       time.Time
	CreatedBy       *int64
	UpdatedAt       time.Time
	UpdatedBy       *int64
	IsDeleted       bool
	DeletedAt       *time.Time
}

// InsertInput 写一条决策审计.
type InsertInput struct {
	TenantID        int64
	RoomID          int64
	TriggerMsgID    *int64
	PolicyID        *int64
	BasePolicy      string
	CandidatesJSON  []byte // 调用方负责 JSON marshal;允许 nil → 写空数组
	SelectedAgentID *int64
	SelectedReason  string
	SelectionKind   SelectionKind
	LatencyMs       *int32
	JudgeTokensIn   *int32
	JudgeTokensOut  *int32
	CreatedBy       *int64
}

// ListByRoomFilter admin 治理页 "群详情·触发记录" 用.
type ListByRoomFilter struct {
	TenantID int64
	RoomID   int64
	Limit    int
	Offset   int
}

// Repository 决策审计仓储.
type Repository interface {
	Insert(ctx context.Context, in InsertInput) (*Decision, error)
	GetByUUID(ctx context.Context, tenantID int64, uuid string, createdAt time.Time) (*Decision, error)
	ListByRoom(ctx context.Context, f ListByRoomFilter) ([]*Decision, int, error)
}
