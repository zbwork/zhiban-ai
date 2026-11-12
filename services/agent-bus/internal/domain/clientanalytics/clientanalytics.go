package clientanalytics

import (
	"context"
	"errors"
	"time"
)

var ErrInvalidEvent = errors.New("client_analytics.invalid_event")
var ErrInvalidRange = errors.New("client_analytics.invalid_range")
var ErrFingerprintNotFound = errors.New("client_analytics.fingerprint_not_found")

type Event struct {
	EventID       string
	Name          string
	SchemaVersion int
	SessionID     string
	Platform      string
	AppVersion    string
	Properties    map[string]any
	OccurredAt    time.Time
}

type Repository interface {
	InsertBatch(ctx context.Context, tenantID, accountID int64, events []Event) error
}

type Service interface {
	Record(ctx context.Context, tenantID, accountID int64, events []Event) error
}

type DailyActivePoint struct {
	Date        string `json:"date"`
	ActiveUsers int64  `json:"active_users"`
}

type ActiveDimension struct {
	Key         string `json:"key"`
	ActiveUsers int64  `json:"active_users"`
}

type TenantActive struct {
	TenantID    int64     `json:"tenant_id"`
	TenantName  string    `json:"tenant_name"`
	ActiveUsers int64     `json:"active_users"`
	LastActive  time.Time `json:"last_active_at"`
}

type DailyErrorPoint struct {
	Date          string `json:"date"`
	ErrorCount    int64  `json:"error_count"`
	AffectedUsers int64  `json:"affected_users"`
}

type ErrorGroup struct {
	Fingerprint    string    `json:"fingerprint"`
	ErrorType      string    `json:"error_type"`
	ErrorMessage   string    `json:"error_message"`
	SourceLocation string    `json:"source_location"`
	Occurrences    int64     `json:"occurrences"`
	AffectedUsers  int64     `json:"affected_users"`
	Platforms      string    `json:"platforms"`
	AppVersions    string    `json:"app_versions"`
	Archived       bool      `json:"archived"`
	LastSeenAt     time.Time `json:"last_seen_at"`
}

type ErrorDetail struct {
	Fingerprint   string         `json:"fingerprint"`
	ErrorType     string         `json:"error_type"`
	ErrorMessage  string         `json:"error_message"`
	Stacktrace    string         `json:"stacktrace"`
	Mechanism     string         `json:"mechanism"`
	Severity      string         `json:"severity"`
	Platform      string         `json:"platform"`
	AppVersion    string         `json:"app_version"`
	Properties    map[string]any `json:"properties"`
	Occurrences   int64          `json:"occurrences"`
	AffectedUsers int64          `json:"affected_users"`
	Archived      bool           `json:"archived"`
	FirstSeenAt   time.Time      `json:"first_seen_at"`
	LastSeenAt    time.Time      `json:"last_seen_at"`
	// 每个受影响账号命中这个指纹的次数（v0.7 起展开，见 F21 文档变更记录；
	// 跟总览同一权限即可查看，未做额外分级）。
	AffectedAccounts []AffectedAccount `json:"affected_accounts"`
}

// AffectedAccount 是某个错误指纹下，单个账号的命中明细。
type AffectedAccount struct {
	AccountID   int64     `json:"account_id"`
	AccountUUID string    `json:"account_uuid"`
	DisplayName string    `json:"display_name"`
	TenantID    int64     `json:"tenant_id"`
	TenantName  string    `json:"tenant_name"`
	Occurrences int64     `json:"occurrences"`
	LastSeenAt  time.Time `json:"last_seen_at"`
}

type ErrorAdminRepository interface {
	ErrorDetail(ctx context.Context, fingerprint string) (*ErrorDetail, error)
	ArchiveError(ctx context.Context, fingerprint string, accountID int64) error
	UnarchiveError(ctx context.Context, fingerprint string) error
}

type Overview struct {
	GeneratedAt       time.Time          `json:"generated_at"`
	Timezone          string             `json:"timezone"`
	RangeDays         int                `json:"range_days"`
	DAU               int64              `json:"dau"`
	WAU               int64              `json:"wau"`
	MAU               int64              `json:"mau"`
	StickinessPct     float64            `json:"stickiness_pct"`
	ActiveTenants24h  int64              `json:"active_tenants_24h"`
	NewAccounts24h    int64              `json:"new_accounts_24h"`
	Trend             []DailyActivePoint `json:"trend"`
	Platforms         []ActiveDimension  `json:"platforms"`
	Versions          []ActiveDimension  `json:"versions"`
	Tenants           []TenantActive     `json:"tenants"`
	ErrorCount        int64              `json:"error_count"`
	ErrorUsers        int64              `json:"error_users"`
	ErrorFingerprints int64              `json:"error_fingerprints"`
	ErrorTrend        []DailyErrorPoint  `json:"error_trend"`
	TopErrors         []ErrorGroup       `json:"top_errors"`
}

type OverviewReader interface {
	Overview(ctx context.Context, days int, now time.Time, includeArchived bool) (*Overview, error)
}
