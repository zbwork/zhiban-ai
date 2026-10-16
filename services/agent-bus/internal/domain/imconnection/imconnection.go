package imconnection

import (
	"context"
	"time"

	"github.com/google/uuid"
)

type Observation struct {
	TenantID          int64
	UID               string
	SubjectKind       string
	SubjectUUID       string
	DeviceKey         string
	DeviceIDMasked    string
	DeviceIDAvailable bool
	DeviceFlag        int
	DeviceLevel       int
	ConnectionID      int64
	ProtocolVersion   string
	ConnectedAt       *time.Time
	LastActivityAt    *time.Time
}

type CollectorStatus struct {
	LastAttemptAt   *time.Time `json:"last_attempt_at,omitempty"`
	LastSuccessAt   *time.Time `json:"last_success_at,omitempty"`
	LastError       string     `json:"last_error,omitempty"`
	ConnectionTotal int        `json:"connection_total"`
}

// ClientMetadata 是客户端通过已鉴权 Bus API 上报的连接设备元数据。
// DeviceKey 必须是 WuKong CONNECT DeviceID 的 SHA-256；仓储层不得接收明文 DeviceID。
type ClientMetadata struct {
	TenantID      int64
	AccountID     int64
	DeviceKey     string
	ClientVersion string
	Platform      string
	OSVersion     string
	ReportedAt    time.Time
}

type ClientMetadataStore interface {
	UpsertClientMetadata(ctx context.Context, metadata ClientMetadata) error
}

type Overview struct {
	OnlineConnections int             `json:"online_connections"`
	OnlineUsers       int             `json:"online_users"`
	OnlineTenants     int             `json:"online_tenants"`
	AnomalousDevices  int             `json:"anomalous_devices"`
	Reconnects5m      int             `json:"reconnects_5m"`
	Reconnects1h      int             `json:"reconnects_1h"`
	Recoveries1h      int             `json:"recoveries_1h"`
	Replacements1h    int             `json:"replacements_1h"`
	Collector         CollectorStatus `json:"collector"`
}

type State struct {
	UUID              uuid.UUID  `json:"uuid"`
	TenantID          int64      `json:"tenant_id"`
	TenantName        string     `json:"tenant_name"`
	AccountID         *int64     `json:"account_id,omitempty"`
	AccountUUID       string     `json:"account_uuid,omitempty"`
	AccountName       string     `json:"account_name,omitempty"`
	UID               string     `json:"uid"`
	SubjectKind       string     `json:"subject_kind"`
	SubjectUUID       string     `json:"subject_uuid"`
	DeviceIDMasked    string     `json:"device_id_masked"`
	DeviceIDAvailable bool       `json:"device_id_available"`
	DeviceFlag        int        `json:"device_flag"`
	DeviceLevel       int        `json:"device_level"`
	ConnectionID      int64      `json:"connection_id"`
	ProtocolVersion   string     `json:"protocol_version"`
	ClientVersion     string     `json:"client_version"`
	ClientPlatform    string     `json:"client_platform"`
	ClientOSVersion   string     `json:"client_os_version"`
	Status            string     `json:"status"`
	ConnectedAt       *time.Time `json:"connected_at,omitempty"`
	LastActivityAt    *time.Time `json:"last_activity_at,omitempty"`
	FirstSeenAt       time.Time  `json:"first_seen_at"`
	LastSeenAt        time.Time  `json:"last_seen_at"`
	LastEventType     string     `json:"last_event_type"`
	Reconnects5m      int        `json:"reconnects_5m"`
	Reconnects1h      int        `json:"reconnects_1h"`
	Anomalous         bool       `json:"anomalous"`
}

type Event struct {
	UUID                 uuid.UUID `json:"uuid"`
	StateUUID            uuid.UUID `json:"state_uuid"`
	TenantID             int64     `json:"tenant_id"`
	TenantName           string    `json:"tenant_name"`
	AccountUUID          string    `json:"account_uuid,omitempty"`
	AccountName          string    `json:"account_name,omitempty"`
	UID                  string    `json:"uid"`
	DeviceIDMasked       string    `json:"device_id_masked"`
	DeviceFlag           int       `json:"device_flag"`
	ConnectionID         int64     `json:"connection_id"`
	PreviousConnectionID *int64    `json:"previous_connection_id,omitempty"`
	EventType            string    `json:"event_type"`
	Reason               string    `json:"reason,omitempty"`
	DataQuality          string    `json:"data_quality"`
	ProtocolVersion      string    `json:"protocol_version,omitempty"`
	OccurredAt           time.Time `json:"occurred_at"`
}

type StateFilter struct {
	Query      string
	TenantID   int64
	Status     string
	Anomalous  bool
	DeviceFlag *int
	Offset     int
	Limit      int
}

type EventFilter struct {
	StateUUID uuid.UUID
	TenantID  int64
	EventType string
	Offset    int
	Limit     int
}

type Store interface {
	ApplySnapshot(ctx context.Context, observations []Observation, observedAt, staleBefore time.Time) error
	MarkCollectorFailure(ctx context.Context, attemptedAt time.Time, message string) error
	CleanupEvents(ctx context.Context, before time.Time) error
	Overview(ctx context.Context) (Overview, error)
	ListStates(ctx context.Context, filter StateFilter) ([]State, int, error)
	GetState(ctx context.Context, id uuid.UUID) (State, error)
	ListEvents(ctx context.Context, filter EventFilter) ([]Event, int, error)
}
