// Package orgwebhook defines tenant org-sync webhook configuration models.
package orgwebhook

import (
	"context"
	"time"
)

const (
	EventMemberCreated     = "org.member.created"
	EventMemberUpdated     = "org.member.updated"
	EventMemberDeleted     = "org.member.deleted"
	EventDepartmentCreated = "org.department.created"
	EventDepartmentUpdated = "org.department.updated"
	EventDepartmentDeleted = "org.department.deleted"
	EventPositionCreated   = "org.position.created"
	EventPositionUpdated   = "org.position.updated"
	EventPositionDeleted   = "org.position.deleted"
	EventWebhookTest       = "org.webhook.test"
)

// F25: 告警外发复用租户 webhook 通道，事件类型可与 org.* 一样被精确订阅。
const (
	EventAlertFired    = "notify.alert.fired"
	EventAlertResolved = "notify.alert.resolved"
)

var AllowedOrgEvents = []string{
	EventMemberCreated,
	EventMemberUpdated,
	EventMemberDeleted,
	EventDepartmentCreated,
	EventDepartmentUpdated,
	EventDepartmentDeleted,
	EventPositionCreated,
	EventPositionUpdated,
	EventPositionDeleted,
	EventAlertFired,
	EventAlertResolved,
}

type Config struct {
	ID             int64
	UUID           string
	TenantID       int64
	Name           string
	CallbackURL    string
	SigningSecret  string
	Enabled        bool
	EventTypes     []string
	Description    string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	DeletedAt      *time.Time
	LatestDelivery *Delivery
}

type Delivery struct {
	ID              int64
	OutboxID        int64
	WebhookConfigID int64
	EventType       string
	CallbackURL     string
	Status          string
	Attempts        int
	NextRetryAt     *time.Time
	LastError       string
	DoneAt          *time.Time
	CreatedAt       time.Time
}

type CreateInput struct {
	Name        string
	CallbackURL string
	Enabled     bool
	EventTypes  []string
	Description string
}

type PatchInput struct {
	Name        *string
	CallbackURL *string
	Enabled     *bool
	EventTypes  []string
	Description *string
}

type TestResult struct {
	StatusCode int    `json:"statusCode"`
	Message    string `json:"message"`
}

type Repository interface {
	List(ctx context.Context, tenantID int64) ([]Config, error)
	Get(ctx context.Context, tenantID int64, uuid string) (*Config, error)
	Insert(ctx context.Context, c *Config) error
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*Config, error)
	SoftDelete(ctx context.Context, tenantID int64, uuid string) error
	ListDeliveries(ctx context.Context, tenantID int64, configUUID string, limit int) ([]Delivery, error)
}

type Service interface {
	List(ctx context.Context, tenantID int64) ([]Config, error)
	Create(ctx context.Context, tenantID int64, in CreateInput) (*Config, string, error)
	Patch(ctx context.Context, tenantID int64, uuid string, in PatchInput) (*Config, error)
	Delete(ctx context.Context, tenantID int64, uuid string) error
	RotateSecret(ctx context.Context, tenantID int64, uuid string) (*Config, string, error)
	Test(ctx context.Context, tenantID int64, uuid string) (*TestResult, error)
	ListDeliveries(ctx context.Context, tenantID int64, uuid string, limit int) ([]Delivery, error)
}
