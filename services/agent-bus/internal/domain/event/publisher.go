// Package event 定义 M0 最小事件底座的 publisher 契约。
//
// v1 仅一个实现 PgOutboxPublisher（见 internal/repository/postgres/event/）。
// 未来切 Kafka 时换实现即可，业务代码零改动（见 docs/adr/0002-defer-kafka-clickhouse-v1.md）。
//
// Tx 是一个薄接口，避免业务代码 import pgx。具体实现由 repository/postgres 层提供。
package event

import (
	"context"
	"encoding/json"
)

// Tx 是事务句柄抽象（不透明类型）。
//
// 业务代码通过 service 层拿到 Tx 后传给 Publisher.Publish，确保 outbox 写入与业务变更同事务。
// 实际类型由 repository/postgres 实现注入（如 PgTx 包装 pgx.Tx）；具体 SQL 不在本接口语义内。
//
// 用 any 而非 interface{ 方法 } 是为了让 repository 层可以自由实现而无需在 domain 包暴露 pgx 类型；
// repository.Publish 会做类型断言：传错类型直接返错。
type Tx = any

// Event 表示一条待入 outbox 的事件。
//
// IdempotencyKey 可选：传则启用 partial UNIQUE 去重；不传则允许合法重复（如同一秒两次登录失败）。
// 业务侧推荐对"逻辑上不应该重复发"的事件主动算 key（如 password.changed = sha256(account_id||changed_at)）。
type Event struct {
	Topic          string          // 必填；如 "audit.auth.login.success" / "billing.token" / "notify.in_app"
	TenantID       int64           // 0 表示平台级
	TraceID        string          // OpenTelemetry trace_id；可空
	IdempotencyKey string          // 可选；显式提供时启用去重
	Payload        json.RawMessage // 必填；JSON 字节
}

// Publisher 把事件写入事务内的 outbox。
type Publisher interface {
	// Publish 在给定事务内 INSERT 一行到 events_outbox。
	// 当 IdempotencyKey 非空且已存在时，返回 ErrDuplicate（业务层应当当成已发处理）。
	Publish(ctx context.Context, tx Tx, evt Event) error
}
