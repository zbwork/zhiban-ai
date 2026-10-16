// Package localruntime defines device transport state independently from cloud runtime environments.
package localruntime

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

var (
	ErrDenied          = errors.New("local_runtime.denied")
	ErrOffline         = errors.New("local_runtime.device_offline")
	ErrUpgradeRequired = errors.New("local_runtime.upgrade_required")
	ErrConflict        = errors.New("local_runtime.conflict")
	ErrSequence        = errors.New("local_runtime.sequence_gap")
)

type Scope struct {
	AccountID   int64
	TenantID    int64
	SessionUUID string
}

type Device struct {
	Engines         map[string]string `json:"engines"`
	ProtocolVersion int               `json:"protocol_version"`
	UUID            string            `json:"device_id"`
	Scope           Scope             `json:"-"`
	TenantUUID      string            `json:"tenant_id"`
	AccountUUID     string            `json:"account_id"`
	InstallationID  string            `json:"-"`
	Platform        string            `json:"platform"`
	Generation      int64             `json:"generation"`
	SeenAt          time.Time         `json:"seen_at"`
}

type Task struct {
	LocalEngine          string          `json:"local_engine"`
	CurrentEngine        string          `json:"-"` // Repository projection, never supplied by the desktop.
	RequesterSessionUUID string          `json:"-"`
	UUID                 string          `json:"run_id"`
	DeviceUUID           string          `json:"device_id"`
	Scope                Scope           `json:"-"`
	TenantUUID           string          `json:"tenant_id"`
	AccountUUID          string          `json:"account_id"`
	LoginSessionUUID     string          `json:"login_session_id"`
	EmployeeID           int64           `json:"-"`
	EmployeeUUID         string          `json:"agent_id"`
	ConversationUUID     string          `json:"conversation_id"`
	MessageUUID          string          `json:"message_id"`
	StreamID             string          `json:"stream_id"`
	Fence                int64           `json:"fencing_token"`
	Model                string          `json:"model"`
	Status               string          `json:"status"`
	Payload              json.RawMessage `json:"payload"`
	TokenHash            string          `json:"-"`
	ExpiresAt            time.Time       `json:"expires_at"`
	LastSeq              int64           `json:"last_seq"`
}

type Event struct {
	RunUUID string          `json:"run_id"`
	Fence   int64           `json:"fencing_token"`
	Seq     int64           `json:"seq"`
	Name    string          `json:"event"`
	Data    json.RawMessage `json:"data"`
}

// OutputAgentResolver revalidates a persisted local task and returns its employee's
// display name. The output owner is task.Scope, never the shared employee's creator.
type OutputAgentResolver interface {
	ResolveOutputAgent(context.Context, *Task) (string, error)
}

// Repository methods recheck the database identity/scope and perform state transitions atomically.
type Repository interface {
	Register(context.Context, Scope, string, string) (*Device, error)
	GetDevice(context.Context, Scope, string) (*Device, error)
	Connect(context.Context, Scope, string, int64) (*Device, error)
	Heartbeat(context.Context, Scope, string, int64) error
	Disconnect(context.Context, Scope, string, int64) error
	Revoke(context.Context, Scope, string) error
	CreateTask(context.Context, *Task) (*Task, error)
	GetTask(context.Context, Scope, string) (*Task, error)
	PendingTasks(context.Context, Scope, string, int64) ([]Task, error)
	AcceptTask(context.Context, Scope, string, int64, string, int64) error
	AppendEvent(context.Context, Scope, string, int64, Event) (int64, error)
	Events(context.Context, Scope, string, int64) ([]Event, error)
	CancelTask(context.Context, Scope, string) error
	ExpireTasks(context.Context) (int64, error)
}
