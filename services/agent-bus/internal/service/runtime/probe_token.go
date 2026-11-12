// probe_token.go: 一次性 probe_token 签发与校验 (M3 §6.3)。
//
// 设计:
//   - HMAC-SHA256 自包含 token, 不入库; 与系统 JWT (Ed25519, M1) 解耦,
//     避免给 probe 临时态串到 user session 体系。
//   - claims: caller_account_id / caller_tenant_id / endpoints_sha256 /
//     scope / protocol_version / runtime_card_summary / exp。
//   - create endpoint 必须带 probe_token 且 endpoints_sha256 与 create body
//     一致, 否则返 tenant_runtime.probe_token_invalid。
//
// 格式 v1: <base64url(json(claims))>.<hex(hmac_sha256(secret, payload))>
// 简单可读, 不需要兼容外部接入方; 单 Bus 进程签发与校验 (同 secret)。
package runtime

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ProbeTokenClaims 是 probe_token 的负载 (M3 §6.3)。
//
// Codex 返修: 增加 AuthConfigSHA256, 绑定 auth.kind + secret (或 secret_ref)
// 的指纹; 后续 create/PATCH 必须重新计算并与 token claims 比对一致, 防止
// "probe 用 token A, create 时换 token B" 的偷换 secret 攻击。
type ProbeTokenClaims struct {
	CallerAccountID    int64  `json:"caller_account_id"`
	CallerTenantID     int64  `json:"caller_tenant_id"`
	EndpointsSHA256    string `json:"endpoints_sha256"`
	AuthConfigSHA256   string `json:"auth_config_sha256"`
	Scope              string `json:"scope"` // platform | tenant | personal
	ProtocolVersion    string `json:"protocol_version"`
	RuntimeCardSummary string `json:"runtime_card_summary"`
	ExpiresAt          int64  `json:"exp"` // unix seconds
}

// ProbeTokenIssuer 签发 + 校验 HMAC-SHA256 一次性 token。
type ProbeTokenIssuer struct {
	secret []byte
	ttl    time.Duration
	now    func() time.Time // 测试可注入; 生产用 time.Now
}

// NewProbeTokenIssuer 构造 issuer。
// secret: HMAC 秘钥; 至少 16 字节, 由 cmd 装配时传入 (cfg 或 env)。
// ttl <=0 走默认 5 分钟。
func NewProbeTokenIssuer(secret []byte, ttl time.Duration) *ProbeTokenIssuer {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &ProbeTokenIssuer{secret: secret, ttl: ttl, now: time.Now}
}

// TTL 给 caller 看的过期; 主要给单测断言用。
func (i *ProbeTokenIssuer) TTL() time.Duration { return i.ttl }

// Issue 给一个不带 exp 的 claims 填上 exp 然后签发。
func (i *ProbeTokenIssuer) Issue(c ProbeTokenClaims) (string, error) {
	if len(i.secret) == 0 {
		return "", errors.New("probe_token: secret not configured")
	}
	c.ExpiresAt = i.now().Add(i.ttl).Unix()
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, i.secret)
	mac.Write([]byte(enc))
	sig := hex.EncodeToString(mac.Sum(nil))
	return enc + "." + sig, nil
}

// Verify 校验签名 + exp; 返回 claims。
func (i *ProbeTokenIssuer) Verify(token string) (*ProbeTokenClaims, error) {
	if len(i.secret) == 0 {
		return nil, apperr.ErrInternal.Withf("probe_token: secret not configured")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_runtime.probe_token_invalid: malformed")
	}
	mac := hmac.New(sha256.New, i.secret)
	mac.Write([]byte(parts[0]))
	want := hex.EncodeToString(mac.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(want), []byte(parts[1])) != 1 {
		return nil, apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: bad signature")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("tenant_runtime.probe_token_invalid: bad payload")
	}
	var c ProbeTokenClaims
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, apperr.ErrInvalidParams.Withf("tenant_runtime.probe_token_invalid: bad json")
	}
	if i.now().Unix() > c.ExpiresAt {
		return nil, apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: expired")
	}
	return &c, nil
}

// EndpointsSHA256 计算 endpoints 的标准 SHA256, 用于绑 probe_token 与 create body
// 一致性 (M3 §6.3)。输入 map 按 key 字典序拼接 "k=v\n"; 同样的逻辑必须在 create
// 端复用 (调 EndpointsSHA256 即可)。
func EndpointsSHA256(endpoints map[string]string) string {
	keys := make([]string, 0, len(endpoints))
	for k := range endpoints {
		keys = append(keys, k)
	}
	sortStrings(keys)
	var sb strings.Builder
	for _, k := range keys {
		sb.WriteString(k)
		sb.WriteByte('=')
		sb.WriteString(endpoints[k])
		sb.WriteByte('\n')
	}
	sum := sha256.Sum256([]byte(sb.String()))
	return hex.EncodeToString(sum[:])
}

// IsProbeSecretFallbackAllowed 判断当前 env 是否允许 probe_token HMAC secret
// 不配置时走"随机 32B 进程内 fallback"。
//
// 策略 (P2 review 闭环):
//   - env=local / dev → 允许 (本地启动 / 单机 smoke 时无人值守也能跑);
//   - 其它 (test / staging / prod 或任何未识别 env) → 必须配置, 否则 fail-fast。
func IsProbeSecretFallbackAllowed(env string) bool {
	switch strings.ToLower(strings.TrimSpace(env)) {
	case "local", "dev", "development":
		return true
	default:
		return false
	}
}

// AuthConfigSHA256 用 auth.kind + (secret 或 secret_ref) 计算指纹; create/PATCH 比对用。
//
// secret 是 probe 阶段 inline 提交的明文 token 或 create 阶段写入的 secret_ref
// 字符串 (e.g. `env://...`); 任一改动都换 hash → token 失配 → 强制重 probe。
func AuthConfigSHA256(kind, secretOrRef string) string {
	sum := sha256.Sum256([]byte("kind=" + kind + "\nsecret=" + secretOrRef))
	return hex.EncodeToString(sum[:])
}

func sortStrings(s []string) {
	// 简单插入排序; 端点数量 <=5。
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}
