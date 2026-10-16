// Package audit 定义 audit_events 表的 domain 契约。
//
// v1 实现见 internal/repository/postgres/audit/store.go（普通表 + 5 索引；ADR 0002）。
// 列名对齐 M10 §3.3 设计；未来分区化迁移时业务代码零改动。
package audit

import (
	"context"
	"encoding/json"
	"time"
)

// ActorKind 执行主体类型。
type ActorKind string

const (
	ActorUser          ActorKind = "user"
	ActorAgent         ActorKind = "agent"
	ActorSystem        ActorKind = "system"
	ActorAdmin         ActorKind = "admin"
	ActorPlatformAdmin ActorKind = "platform_admin"
)

// Severity 严重级。
type Severity string

const (
	SeverityInfo     Severity = "info"
	SeverityWarning  Severity = "warning"
	SeverityError    Severity = "error"
	SeverityCritical Severity = "critical"
)

// Event 是 audit_events 表的一行。
type Event struct {
	OccurredAt         time.Time
	TenantID           int64     // 0 表示平台级；存 NULL
	AccountID          int64     // 0 表示系统事件；存 NULL
	ActorKind          ActorKind // 必填
	ActingAs           string    // impersonate 时记录实际身份
	Domain             string    // auth/agent/chat/group/skill/kb/drive/cron/runtime/compliance/...
	EventKind          string    // login.success / message.created / kb.recall / ...
	Severity           Severity  // 默认 info
	ResourceKind       string
	ResourceUUID       string
	TargetAccountID    int64
	TargetResourceUUID string
	TraceID            string
	IP                 string
	UserAgent          string
	Payload            json.RawMessage // JSONB
	DurationMS         int32
}

// Store 是 audit_events 仓储接口。
type Store interface {
	// Insert 写一行；payload 必须是合法 JSON（调用方负责）。
	Insert(ctx context.Context, e Event) error
	// InsertMany 批量写；保证原子（事务内）；失败全部回滚。
	InsertMany(ctx context.Context, events []Event) error
}
