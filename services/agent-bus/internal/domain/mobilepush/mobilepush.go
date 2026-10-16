package mobilepush

import (
	"context"
	"errors"
	"time"
)

var ErrInvalidDevice = errors.New("push_device.invalid")

type Device struct {
	TenantID, AccountID                                                   int64
	InstallationID, Platform, Token, Environment, AppVersion, DeviceModel string
	LastSeenAt                                                            time.Time
}

type UpsertDeviceInput struct {
	InstallationID string
	Platform       string
	Token          string
	Environment    string
	AppVersion     string
	DeviceModel    string
}

type Repository interface {
	UpsertDevice(context.Context, Device) error
	RevokeDevice(ctx context.Context, tenantID, accountID int64, installationID string) error
	ListActiveDevices(ctx context.Context, tenantID, accountID int64) ([]Device, error)
}

type Service interface {
	UpsertDevice(context.Context, int64, int64, UpsertDeviceInput) error
	RevokeDevice(context.Context, int64, int64, string) error
	Enqueue(context.Context, EnqueueInput) (bool, error)
}

type Event struct {
	ID, TenantID, AccountID           int64
	UUID, Kind, DedupKey, Title, Body string
	RoutePayload                      map[string]any
}

type Delivery struct {
	ID       int64
	Event    Event
	Attempts int
}

type EnqueueInput struct {
	TenantID, AccountID         int64
	Kind, DedupKey, Title, Body string
	RoutePayload                map[string]any
}

type DeliveryRepository interface {
	Enqueue(ctx context.Context, in EnqueueInput) (*Delivery, error)
	MarkSent(ctx context.Context, id int64, providerMessageID string) error
	MarkFailed(ctx context.Context, id int64, code, message string) error
	MarkDiscarded(ctx context.Context, id int64, code, message string) error
	RevokeToken(ctx context.Context, token string) error
}

type ProviderResultKind string

const (
	ProviderSent         ProviderResultKind = "sent"
	ProviderTemporary    ProviderResultKind = "temporary"
	ProviderInvalidToken ProviderResultKind = "invalid_token"
	ProviderPermanent    ProviderResultKind = "permanent"
)

type ProviderResult struct {
	Kind                     ProviderResultKind
	MessageID, Code, Message string
}
type Provider interface {
	Send(ctx context.Context, device Device, event Event) ProviderResult
}

type EventPublisher interface {
	PublishAccountEvent(ctx context.Context, accountID, tenantID int64, payload map[string]any) error
}

type Recipient struct {
	TenantID, AccountID int64
	// ConversationUUID 是 conversations.uuid（客户端会话列表/当前会话选中态用的 id 空间），
	// 不是 rooms.uuid——两者是不同的 uuid（1 room 对应 1 conversation，但值不同）。
	// 混用会导致客户端"是否正在看这个会话"的判断永远对不上（如桌面通知抑制）。
	ConversationUUID, AccountUUID string
	ConversationTitle             string
}
type RecipientResolver interface {
	ResolveRecipients(ctx context.Context, channelID, fromUID string) ([]Recipient, error)
}
