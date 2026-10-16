// Package session 登录会话与活跃登录管理域。
package session

import (
	"context"
	"net"
	"time"
)

// LoginSession 一次活跃登录的快照, 一行对应一个 refresh token。
type LoginSession struct {
	ID               int64
	UUID             string
	AccountID        int64
	RefreshTokenHash string

	IssuedAt   time.Time
	ExpiresAt  time.Time
	LastUsedAt time.Time

	ActScopeKind   string // platform | tenant | workspace
	ActTenantID    *int64
	ActWorkspaceID *int64
	ActingAs       string

	UserAgent         string
	IP                *net.IP
	DeviceFingerprint string

	// 登录时客户端可选上报的结构化设备信息 (agent-bus-client-contract.md §10.6)。
	// 全部可能为空 (旧客户端未上报); 空时展示端回退解析 UserAgent。
	DeviceType          string
	DeviceBrand         string
	DeviceModel         string
	DeviceSystemVersion string
	DeviceAppVersion    string

	RevokedAt    *time.Time
	RevokeReason string
}

// CreateInput 新会话的入参。
type CreateInput struct {
	AccountID         int64
	RefreshTokenHash  string
	ExpiresAt         time.Time
	ActScopeKind      string
	ActTenantID       *int64
	ActWorkspaceID    *int64
	ActingAs          string
	UserAgent         string
	IP                string
	DeviceFingerprint string

	DeviceType          string
	DeviceBrand         string
	DeviceModel         string
	DeviceSystemVersion string
	DeviceAppVersion    string
}

// UpdateScopeInput /auth/scope/switch 时更新 session 当前 scope。
type UpdateScopeInput struct {
	SessionUUID    string
	ActScopeKind   string
	ActTenantID    *int64
	ActWorkspaceID *int64
}

// Repository 持久化接口。
type Repository interface {
	Create(ctx context.Context, in CreateInput) (*LoginSession, error)
	GetByUUID(ctx context.Context, uuid string) (*LoginSession, error)
	GetByRefreshHash(ctx context.Context, hash string) (*LoginSession, error)
	TouchUsed(ctx context.Context, sessionUUID string, refreshHash string, newExpire time.Time) error
	UpdateScope(ctx context.Context, in UpdateScopeInput) error
	Revoke(ctx context.Context, sessionUUID, reason string) error
	RevokeAllByAccount(ctx context.Context, accountID int64, reason string) error
	// RevokeActiveByAccountAndFingerprint 撤销该账号在同一设备指纹下的所有活跃 session。
	// 登录时用来"同设备新登录顶掉旧的"，避免同一台设备反复登录在 /me/sessions
	// 列表里越攒越多。fingerprint 为空时是 no-op（调用方负责判断）。
	RevokeActiveByAccountAndFingerprint(ctx context.Context, accountID int64, fingerprint, reason string) error
	ListActiveByAccount(ctx context.Context, accountID int64) ([]LoginSession, error)
}
