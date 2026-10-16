package imconnection

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/imconnection"
)

var ErrInvalidClientMetadata = errors.New("invalid IM client metadata")

type MetadataReporter struct {
	store dom.ClientMetadataStore
	now   func() time.Time
}

// PreparedClientMetadata 是已完成身份绑定、字段校验和平台归一化的旁路观测数据。
// DeviceID 仅用于本次凭证响应；Metadata.DeviceKey 才允许进入持久化层。
type PreparedClientMetadata struct {
	DeviceID string
	Platform string
	Metadata dom.ClientMetadata
}

func NewMetadataReporter(store dom.ClientMetadataStore) *MetadataReporter {
	return &MetadataReporter{store: store, now: time.Now}
}

// Prepare 只信任显式传入的 JWT 身份，客户端 DeviceID 仅用于相关性，不参与鉴权。
// 本方法不访问数据库，凭证签发主链路可在成功后 best-effort 调 Persist。
func (r *MetadataReporter) Prepare(
	tenantID, accountID int64,
	deviceID, clientVersion, platform, osVersion string,
) (PreparedClientMetadata, error) {
	if tenantID <= 0 || accountID <= 0 {
		return PreparedClientMetadata{}, fmt.Errorf("%w: tenant/account required", ErrInvalidClientMetadata)
	}
	normalizedDeviceID, err := normalizeMetadataText("device_id", deviceID, 128, false)
	if err != nil {
		return PreparedClientMetadata{}, err
	}
	// 以下字段只用于可观测性。旧客户端、浏览器或改包客户端可能上报
	// 超长/非法值；丢弃单个坏字段，不能因此阻断 IM 凭证主链路。
	clientVersion = safeOptionalMetadataText("client_version", clientVersion, 64)
	platform = safeOptionalMetadataText("platform", platform, 32)
	platform = canonicalClientPlatform(platform)
	osVersion = safeOptionalMetadataText("os_version", osVersion, 64)
	reportedAt := time.Now().UTC()
	if r != nil && r.now != nil {
		reportedAt = r.now().UTC()
	}
	deviceKey := ""
	if normalizedDeviceID != "" {
		deviceKey = hashDeviceID(normalizedDeviceID)
	}
	return PreparedClientMetadata{
		DeviceID: normalizedDeviceID,
		Platform: platform,
		Metadata: dom.ClientMetadata{
			TenantID: tenantID, AccountID: accountID, DeviceKey: deviceKey,
			ClientVersion: clientVersion, Platform: platform, OSVersion: osVersion, ReportedAt: reportedAt,
		},
	}, nil
}

// Persist 写入客户端元数据旁路；调用方必须在凭证签发成功后 best-effort 调用。
func (r *MetadataReporter) Persist(ctx context.Context, prepared PreparedClientMetadata) error {
	if r == nil || r.store == nil || prepared.Metadata.DeviceKey == "" {
		return nil
	}
	return r.store.UpsertClientMetadata(ctx, prepared.Metadata)
}

func safeOptionalMetadataText(field, value string, maxRunes int) string {
	normalized, err := normalizeMetadataText(field, value, maxRunes, false)
	if err != nil {
		return ""
	}
	return normalized
}

func canonicalClientPlatform(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "web":
		return "Web"
	case "android":
		return "Android"
	case "ios":
		return "iOS"
	case "macos", "macosx":
		return "macOS"
	case "windows":
		return "Windows"
	case "linux":
		return "Linux"
	default:
		return ""
	}
}

func normalizeMetadataText(field, value string, maxRunes int, required bool) (string, error) {
	value = strings.TrimSpace(value)
	if required && value == "" {
		return "", fmt.Errorf("%w: %s required", ErrInvalidClientMetadata, field)
	}
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) > maxRunes {
		return "", fmt.Errorf("%w: %s exceeds %d characters", ErrInvalidClientMetadata, field, maxRunes)
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("%w: %s contains control characters", ErrInvalidClientMetadata, field)
	}
	return value, nil
}

func hashDeviceID(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
