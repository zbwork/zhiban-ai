package downloadchannel

import (
	"context"
	"errors"
	"time"
)

const (
	StatusActive   = "active"
	StatusArchived = "archived"

	EventKindVisit         = "visit"
	EventKindDownloadClick = "download_click"

	// F29: 渠道种类。marketing = 运营投放渠道（F27 原语义）;
	// user_share = 用户个人分享码（每账号一枚, Admin 列表缺省过滤）。
	KindMarketing = "marketing"
	KindUserShare = "user_share"
	// KindAll 仅作 Filter.Kind 的显式"查全部"哨兵, 不入库。
	KindAll = "all"
)

var (
	ErrMissingCode      = errors.New("download_channel.missing_code")
	ErrMissingName      = errors.New("download_channel.missing_name")
	ErrInvalidStatus    = errors.New("download_channel.invalid_status")
	ErrInvalidEventKind = errors.New("download_channel.invalid_event_kind")
	ErrDuplicateCode    = errors.New("download_channel.duplicate_code")
	ErrChannelNotFound  = errors.New("download_channel.not_found")
	// F29: 并发 find-or-create 撞上"每账号一枚"唯一索引; 调用方应重读既有码。
	ErrOwnerShareExists = errors.New("download_channel.owner_share_exists")
	ErrInvalidKind      = errors.New("download_channel.invalid_kind")
)

type Channel struct {
	ID          int64  `json:"-"`
	UUID        string `json:"uuid"`
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      string `json:"status"`
	// Kind F29: marketing / user_share。
	Kind string `json:"kind"`
	// OwnerAccountID F29: kind=user_share 时的归属账号; marketing 为 nil。
	OwnerAccountID *int64    `json:"owner_account_id,omitempty"`
	CreatedBy      *int64    `json:"created_by,omitempty"`
	UpdatedBy      *int64    `json:"updated_by,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type ChannelWithStats struct {
	Channel
	VisitCount    int64 `json:"visit_count"`
	DownloadCount int64 `json:"download_count"`
}

// ShareGrowthItem 是 F29 平台用户分享增长列表的只读行。
// 账号身份只暴露 UUID、显示名与服务端脱敏手机号，不返回内部自增 ID 或手机号明文。
type ShareGrowthItem struct {
	OwnerAccountUUID string     `json:"owner_account_uuid"`
	OwnerDisplayName string     `json:"owner_display_name"`
	OwnerPhoneMasked string     `json:"owner_phone_masked"`
	InviteCode       string     `json:"invite_code"`
	Status           string     `json:"status"`
	VisitCount       int64      `json:"visit_count"`
	DownloadCount    int64      `json:"download_count"`
	FirstEventAt     *time.Time `json:"first_event_at,omitempty"`
	LastEventAt      *time.Time `json:"last_event_at,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
}

type UpsertInput struct {
	Code        string
	Name        string
	Description string
	Status      string
	ActorID     int64
}

type Filter struct {
	Status  string
	Keyword string
	// Kind F29: ""/KindMarketing → 只查 marketing（缺省, 防个人码刷爆运营列表）;
	// KindUserShare → 只查个人分享码; KindAll → 查全部。
	Kind       string
	RangeStart *time.Time
	RangeEnd   *time.Time
	Limit      int
	Offset     int
}

type EventInput struct {
	ChannelCode string
	EventKind   string
	Platform    string
	PageURL     string
	IPHash      string
	UserAgent   string
}

type DailyPoint struct {
	Date          string `json:"date"`
	VisitCount    int64  `json:"visit_count"`
	DownloadCount int64  `json:"download_count"`
}

type Stats struct {
	TotalVisits    int64           `json:"total_visits"`
	TotalDownloads int64           `json:"total_downloads"`
	Trend          []DailyPoint    `json:"trend"`
	Platforms      []PlatformPoint `json:"platforms"`
}

type PlatformPoint struct {
	Platform      string `json:"platform"`
	DownloadCount int64  `json:"download_count"`
}

type ShareGrowthStats struct {
	TotalCodes     int64           `json:"total_codes"`
	ActiveSharers  int64           `json:"active_sharers"`
	TotalVisits    int64           `json:"total_visits"`
	TotalDownloads int64           `json:"total_downloads"`
	Trend          []DailyPoint    `json:"trend"`
	Platforms      []PlatformPoint `json:"platforms"`
}

type Repository interface {
	List(ctx context.Context, f Filter) ([]ChannelWithStats, int64, error)
	GetByUUID(ctx context.Context, uuid string) (*Channel, error)
	Create(ctx context.Context, in UpsertInput) (*Channel, error)
	Update(ctx context.Context, uuid string, in UpsertInput) (*Channel, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	RecordEvent(ctx context.Context, in EventInput) error
	Stats(ctx context.Context, f Filter) (*Stats, error)
	ListShareGrowth(ctx context.Context, f Filter) ([]ShareGrowthItem, int64, error)
	ShareGrowthStats(ctx context.Context, f Filter) (*ShareGrowthStats, error)
	// F29 个人分享码 (kind=user_share)。
	GetUserShareByAccount(ctx context.Context, accountID int64) (*Channel, error)
	// CreateUserShare code 撞唯一索引返回 ErrDuplicateCode;
	// 账号已有码（并发）返回 ErrOwnerShareExists。
	CreateUserShare(ctx context.Context, accountID int64, code, name, description string) (*Channel, error)
}

func ValidStatus(v string) bool {
	switch v {
	case StatusActive, StatusArchived:
		return true
	default:
		return false
	}
}

// ValidFilterKind 校验 Filter.Kind 取值 ("" = 缺省 marketing)。
func ValidFilterKind(v string) bool {
	switch v {
	case "", KindMarketing, KindUserShare, KindAll:
		return true
	default:
		return false
	}
}

func ValidEventKind(v string) bool {
	switch v {
	case EventKindVisit, EventKindDownloadClick:
		return true
	default:
		return false
	}
}
