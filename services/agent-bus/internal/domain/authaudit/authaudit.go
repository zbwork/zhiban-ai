// Package authaudit 登录闭环 + 撤销 + scope 切换 + impersonate 的最小审计 (M1)。
//
// 与 internal/domain/audit (业务审计) 分包: 那个是 M8 全平台审计的域型,
// 这个是 M1 §3.1 auth_audit_events 表对应的轻量事件。
package authaudit

import (
	"context"
	"time"
)

// EventKind 事件类型枚举。
type EventKind string

const (
	EventLoginPassword    EventKind = "login.password"
	EventLoginSms         EventKind = "login.sms"
	EventLoginOIDC        EventKind = "login.oidc"
	EventLogout           EventKind = "logout"
	EventTokenRefresh     EventKind = "token.refresh"
	EventLock             EventKind = "lock"
	EventUnlock           EventKind = "unlock"
	EventScopeSwitch      EventKind = "scope.switch"
	EventScopeImpersonate EventKind = "scope.impersonate"
	EventImpersonateEnter EventKind = "impersonate.enter"
	EventImpersonateExit  EventKind = "impersonate.exit"
	EventRoleRevoke       EventKind = "role.revoke"
	EventSessionRevoke    EventKind = "session.revoke"
	EventPasswordChange   EventKind = "password.change"
)

// Status 成功/失败。
type Status string

const (
	StatusSuccess Status = "success"
	StatusFailure Status = "failure"
)

// Event 一行审计。
type Event struct {
	ID          int64
	UUID        string
	AccountID   *int64
	SessionID   *int64
	Kind        EventKind
	Status      Status
	ActorKind   string
	TenantID    *int64
	WorkspaceID *int64
	LoginMethod string
	Target      string
	Reason      string
	IP          string
	UserAgent   string
	Metadata    map[string]any
	OccurredAt  time.Time
}

// Repository 持久化接口。
type Repository interface {
	Insert(ctx context.Context, e Event) error
}
