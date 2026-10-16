package wukong

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im"
)

// defaultCredentialTTL 客户端连接凭证建议刷新 TTL 默认值(配置缺省时用)。
const defaultCredentialTTL = 24 * time.Hour

// AccountLookup 提供 accountID → account_uuid(构造命名空间 uid 用)。
// 真实实现注入 account 仓储;单测用 fake。
type AccountLookup interface {
	AccountUUID(ctx context.Context, accountID int64) (string, error)
}

// CredentialIssuer 签发客户端连接 WuKong 所需凭证(ADR-0026 Phase 1)。
//
// 流程:accountID → account_uuid → UserUID(tenant 命名空间)→ 生成随机 token →
// 经特权 REST 注册(RegisterUserToken)→ 返回 ConnInfo(只含 uid/token/TCP/WS,**无 :5001**)。
//
// 安全:ConnInfo 结构上不含特权 REST 地址;客户端拿到后只用 TCP/WS 长连接。
type CredentialIssuer struct {
	sub         im.Substrate
	lookup      AccountLookup
	deviceLevel int
	// ttl 客户端连接凭证建议刷新时长;now 注入时钟(测试可固定)。
	ttl time.Duration
	now func() time.Time
}

// Option 配置 CredentialIssuer(向后兼容:不传 = 默认 24h TTL + time.Now)。
type Option func(*CredentialIssuer)

// WithTTL 设置连接凭证建议刷新 TTL;<=0 时回落默认值。
func WithTTL(d time.Duration) Option {
	return func(ci *CredentialIssuer) {
		if d > 0 {
			ci.ttl = d
		}
	}
}

// WithClock 注入时钟(测试用);nil 忽略。
func WithClock(now func() time.Time) Option {
	return func(ci *CredentialIssuer) {
		if now != nil {
			ci.now = now
		}
	}
}

// NewCredentialIssuer. deviceLevel 默认 1(主设备),TTL 默认 24h。
func NewCredentialIssuer(sub im.Substrate, lookup AccountLookup, opts ...Option) *CredentialIssuer {
	ci := &CredentialIssuer{
		sub: sub, lookup: lookup, deviceLevel: 1,
		ttl: defaultCredentialTTL, now: time.Now,
	}
	for _, o := range opts {
		o(ci)
	}
	return ci
}

const (
	DeviceFlagApp     = 0
	DeviceFlagWeb     = 1
	DeviceFlagDesktop = 2
)

// DeviceFlagForPlatform 把 EasyO 客户端平台映射为 WuKong 原生设备类别。
// 空/未知值回退 App=0，兼容未规范上报 platform 的旧客户端；不接受客户端直接提交整数 flag。
func DeviceFlagForPlatform(platform string) int {
	switch strings.ToLower(strings.TrimSpace(platform)) {
	case "web":
		return DeviceFlagWeb
	case "macosx", "macos", "windows", "linux":
		return DeviceFlagDesktop
	case "android", "ios":
		return DeviceFlagApp
	default:
		return DeviceFlagApp
	}
}

// Issue 为 (tenantID, accountID) 签发 WuKong 连接凭证。身份显式传参(不读 ctx.Value)。
func (ci *CredentialIssuer) Issue(ctx context.Context, tenantID, accountID int64, platform string) (im.ConnInfo, error) {
	if tenantID <= 0 || accountID <= 0 {
		return im.ConnInfo{}, fmt.Errorf("wukong cred: invalid tenant/account")
	}
	accountUUID, err := ci.lookup.AccountUUID(ctx, accountID)
	if err != nil {
		return im.ConnInfo{}, fmt.Errorf("wukong cred: account lookup: %w", err)
	}
	uid := UserUID(tenantID, accountUUID)
	tok, err := randToken()
	if err != nil {
		return im.ConnInfo{}, fmt.Errorf("wukong cred: token: %w", err)
	}
	deviceFlag := DeviceFlagForPlatform(platform)
	if err := ci.sub.RegisterUserToken(ctx, uid, tok, deviceFlag, ci.deviceLevel); err != nil {
		return im.ConnInfo{}, fmt.Errorf("wukong cred: register token: %w", err)
	}
	tcp, ws := ci.sub.ClientConnAddrs()
	ttl := ci.ttl
	if ttl <= 0 {
		ttl = defaultCredentialTTL
	}
	now := ci.now
	if now == nil {
		now = time.Now
	}
	return im.ConnInfo{
		Substrate:  ci.sub.Name(),
		UID:        uid,
		Token:      tok,
		TCPAddr:    tcp,
		WSAddr:     ws,
		DeviceFlag: deviceFlag,
		// 建议刷新时刻 = 签发时刻 + TTL(UTC RFC3339);客户端据此提前刷新。
		ExpiresAt: now().UTC().Add(ttl).Format(time.RFC3339),
	}, nil
}

func randToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
