package clientversion

import (
	"context"
	"errors"
	"time"
)

const (
	PlatformMacOS   = "macos"
	PlatformWindows = "windows"
	PlatformIOS     = "ios"
	PlatformAndroid = "android"

	ArchUniversal = "universal"
	ArchArm64     = "arm64"
	ArchX64       = "x64"

	ChannelStable = "stable"
	ChannelBeta   = "beta"
	ChannelDev    = "dev"

	StatusDraft     = "draft"
	StatusPublished = "published"
	StatusArchived  = "archived"
)

var (
	ErrInvalidPlatform       = errors.New("client_version.invalid_platform")
	ErrInvalidArch           = errors.New("client_version.invalid_arch")
	ErrInvalidChannel        = errors.New("client_version.invalid_channel")
	ErrInvalidStatus         = errors.New("client_version.invalid_status")
	ErrMissingVersion        = errors.New("client_version.missing_version")
	ErrMissingBuild          = errors.New("client_version.missing_build_number")
	ErrMissingDownload       = errors.New("client_version.missing_download_url")
	ErrMissingCurrentVer     = errors.New("client_version.missing_current_version")
	ErrInstallerStoreMissing = errors.New("client_version.installer_store_missing")
	ErrInvalidDownloadAsset  = errors.New("client_version.invalid_download_asset")
	ErrMissingDeltaFrom      = errors.New("client_version.missing_delta_from")
	ErrInvalidDeltaSignature = errors.New("client_version.invalid_delta_signature")
	// ErrDuplicateBuild: platform+arch+channel+build_number 撞 idx_client_app_versions_unique_build。
	ErrDuplicateBuild = errors.New("client_version.duplicate_build")
)

// DeltaInfo 描述一个 Sparkle 二进制增量包（.delta）的元数据。
// 上传时由发布侧提供 delta_from（旧版本 CFBundleVersion）与 ed_signature
// （Sparkle 对 delta 文件的 EdDSA 签名），Bus 动态 appcast 原样输出给客户端。
type DeltaInfo struct {
	FileName    string `json:"file_name"`
	StorageURI  string `json:"storage_uri,omitempty"`
	DeltaFrom   string `json:"delta_from"`
	SizeBytes   int64  `json:"size_bytes"`
	SHA256      string `json:"sha256"`
	EdSignature string `json:"ed_signature"`
}

type Version struct {
	ID                  int64  `json:"-"`
	UUID                string `json:"uuid"`
	Platform            string `json:"platform"`
	Arch                string `json:"arch"`
	Channel             string `json:"channel"`
	Version             string `json:"version"`
	BuildNumber         string `json:"build_number"`
	Title               string `json:"title"`
	ReleaseNotes        string `json:"release_notes"`
	DownloadURL         string `json:"download_url"`
	DownloadURLRaw      string `json:"download_url_raw,omitempty"`
	AppcastURL          string `json:"appcast_url"`
	AppcastURLRaw       string `json:"appcast_url_raw,omitempty"`
	SparkleEDSignature  string `json:"sparkle_ed_signature"`
	FileSizeBytes       int64  `json:"file_size_bytes"`
	SHA256              string `json:"sha256"`
	MinOSVersion        string `json:"min_os_version"`
	MinSupportedVersion string `json:"min_supported_version"`
	IsForced            bool   `json:"is_forced"`
	Status              string `json:"status"`
	// Deltas 是 macOS Sparkle 增量包元数据列表（无迁移的 JSONB 列）。
	Deltas      []DeltaInfo `json:"deltas,omitempty"`
	PublishedAt *time.Time  `json:"published_at,omitempty"`
	CreatedBy   *int64      `json:"created_by,omitempty"`
	UpdatedBy   *int64      `json:"updated_by,omitempty"`
	CreatedAt   time.Time   `json:"created_at"`
	UpdatedAt   time.Time   `json:"updated_at"`
}

type UpsertInput struct {
	Platform            string
	Arch                string
	Channel             string
	Version             string
	BuildNumber         string
	Title               string
	ReleaseNotes        string
	DownloadURL         string
	AppcastURL          string
	SparkleEDSignature  string
	FileSizeBytes       int64
	SHA256              string
	MinOSVersion        string
	MinSupportedVersion string
	IsForced            bool
	Status              string
	ActorID             int64
}

type Filter struct {
	Platform string
	Arch     string
	Channel  string
	Status   string
	Keyword  string
	Limit    int
	Offset   int
	// SortBy: "build_number" (ASC) 或 "-build_number" (DESC)；空值退回 created_at DESC。
	SortBy string
}

type UpdateQuery struct {
	Platform           string
	Arch               string
	Channel            string
	CurrentVersion     string
	CurrentBuildNumber string
}

type UpdateInfo struct {
	UpdateAvailable    bool     `json:"update_available"`
	CurrentVersion     string   `json:"current_version"`
	CurrentBuildNumber string   `json:"current_build_number"`
	Latest             *Version `json:"latest"`
}

type Repository interface {
	List(ctx context.Context, f Filter) ([]Version, int64, error)
	GetByUUID(ctx context.Context, uuid string) (*Version, error)
	Create(ctx context.Context, in UpsertInput) (*Version, error)
	Update(ctx context.Context, uuid string, in UpsertInput) (*Version, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	ListPublishedCandidates(ctx context.Context, platform, arch, channel string) ([]Version, error)
	// AppendDelta 把上传成功的 .delta 元数据追加到版本记录的 deltas JSONB 列。
	AppendDelta(ctx context.Context, uuid string, d DeltaInfo) error
}

func ValidPlatform(v string) bool {
	switch v {
	case PlatformMacOS, PlatformWindows, PlatformIOS, PlatformAndroid:
		return true
	default:
		return false
	}
}

func ValidArch(v string) bool {
	switch v {
	case ArchUniversal, ArchArm64, ArchX64:
		return true
	default:
		return false
	}
}

func ValidChannel(v string) bool {
	switch v {
	case ChannelStable, ChannelBeta, ChannelDev:
		return true
	default:
		return false
	}
}

func ValidStatus(v string) bool {
	switch v {
	case StatusDraft, StatusPublished, StatusArchived:
		return true
	default:
		return false
	}
}
