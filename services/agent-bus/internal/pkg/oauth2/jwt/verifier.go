// verifier.go — F04 OAuth2 JWT 验签 + claim 提取。
//
// 流程:
//  1. 解 JWT header, 拿 kid
//  2. keys.Manager.VerifierByKid(kid) 找公钥 (active + retiring 都能 verify)
//  3. go-jose verify 签名
//  4. unmarshal claims 到 caller 提供的 struct
//  5. access token 强校 iss / aud / kind / 必填身份字段 / exp / iat
package jwt

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/go-jose/go-jose/v4"
	gojosejwt "github.com/go-jose/go-jose/v4/jwt"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/keys"
)

// Verifier 验 JWT; goroutine-safe。
type Verifier struct {
	mgr keys.Manager
}

// NewVerifier 构造。
func NewVerifier(mgr keys.Manager) *Verifier {
	return &Verifier{mgr: mgr}
}

// 错误。
var (
	ErrMalformed                     = errors.New("oauth2/jwt: malformed JWT")
	ErrNoKid                         = errors.New("oauth2/jwt: JWT header missing kid")
	ErrSigInvalid                    = errors.New("oauth2/jwt: signature verification failed")
	ErrExpired                       = errors.New("oauth2/jwt: token expired")
	ErrNotYetValid                   = errors.New("oauth2/jwt: token not yet valid (iat in future)")
	ErrIssuerMismatch                = errors.New("oauth2/jwt: iss mismatch")
	ErrAudienceMismatch              = errors.New("oauth2/jwt: aud mismatch")
	ErrInvalidAccessTokenClaims      = errors.New("oauth2/jwt: invalid access token claims")
	ErrInvalidLocalCodingTokenClaims = errors.New("oauth2/jwt: invalid local coding token claims")
)

// VerifyAccessToken 验签 + 解出 AccessTokenClaims; 自动校 exp + iat skew(60s)。
//
// expectedIssuer 不为空时强校; 空则跳过 (给灵活性, 但生产建议必填)。
func (v *Verifier) VerifyAccessToken(ctx context.Context, raw, expectedIssuer string) (*AccessTokenClaims, error) {
	var claims AccessTokenClaims
	if err := v.verify(ctx, raw, &claims); err != nil {
		return nil, err
	}
	if err := checkTime(claims.IssuedAt, claims.ExpiresAt, time.Now()); err != nil {
		return nil, err
	}
	if expectedIssuer != "" && claims.Issuer != expectedIssuer {
		return nil, fmt.Errorf("%w: want %q got %q", ErrIssuerMismatch, expectedIssuer, claims.Issuer)
	}
	if !hasAudience(claims.Audience, AccessTokenAudience) {
		return nil, fmt.Errorf("%w: want %q got %v", ErrAudienceMismatch, AccessTokenAudience, claims.Audience)
	}
	if claims.Kind != AccessTokenKind || claims.ClientID == "" || claims.TenantID <= 0 || claims.Subject == "" {
		return nil, fmt.Errorf("%w: kind/client_id/tenant_id/sub required", ErrInvalidAccessTokenClaims)
	}
	return &claims, nil
}

// VerifyLocalCodingAccessToken 校验 F31 模型网关 token 的签名、时间、用途和最小权限。
// expectedTarget 必填，Responses 与 Messages 网关入口必须分别传入自身 target。
func (v *Verifier) VerifyLocalCodingAccessToken(
	ctx context.Context,
	raw, expectedIssuer, expectedTarget string,
) (*LocalCodingAccessTokenClaims, error) {
	var claims LocalCodingAccessTokenClaims
	if err := v.verify(ctx, raw, &claims); err != nil {
		return nil, err
	}
	if err := checkTime(claims.IssuedAt, claims.ExpiresAt, time.Now()); err != nil {
		return nil, err
	}
	if expectedIssuer == "" || claims.Issuer != expectedIssuer {
		return nil, fmt.Errorf("%w: want %q got %q", ErrIssuerMismatch, expectedIssuer, claims.Issuer)
	}
	if len(claims.Audience) != 1 || claims.Audience[0] != LocalCodingTokenAudience {
		return nil, fmt.Errorf("%w: want %q got %v", ErrAudienceMismatch, LocalCodingTokenAudience, claims.Audience)
	}
	expectedScope, ok := localCodingScopeForTarget(expectedTarget)
	if !ok || claims.Kind != LocalCodingTokenKind || !isSafeLocalCodingIdentifier(claims.Subject) ||
		!isSafeLocalCodingIdentifier(claims.TenantID) || !isSafeLocalCodingIdentifier(claims.DeviceID) ||
		!isSafeLocalCodingIdentifier(claims.ProfileVersion) || !isSafeLocalCodingIdentifier(claims.JWTID) ||
		claims.TargetID != expectedTarget || len(claims.Scopes) != 1 || claims.Scopes[0] != expectedScope ||
		claims.IssuedAt <= 0 || claims.ExpiresAt <= claims.IssuedAt ||
		claims.ExpiresAt-claims.IssuedAt > int64(LocalCodingTokenMaxTTL/time.Second) {
		return nil, ErrInvalidLocalCodingTokenClaims
	}
	return &claims, nil
}

func hasAudience(audiences []string, expected string) bool {
	for _, audience := range audiences {
		if audience == expected {
			return true
		}
	}
	return false
}

// VerifyIDToken 验签 + 解出 IDTokenClaims; 自动校 exp + iat。
//
// 不校 nonce / aud — 调用方自行处理 (业务规则不同)。
func (v *Verifier) VerifyIDToken(ctx context.Context, raw, expectedIssuer string) (*IDTokenClaims, error) {
	var claims IDTokenClaims
	if err := v.verify(ctx, raw, &claims); err != nil {
		return nil, err
	}
	if err := checkTime(claims.IssuedAt, claims.ExpiresAt, time.Now()); err != nil {
		return nil, err
	}
	if expectedIssuer != "" && claims.Issuer != expectedIssuer {
		return nil, fmt.Errorf("%w: want %q got %q", ErrIssuerMismatch, expectedIssuer, claims.Issuer)
	}
	return &claims, nil
}

// VerifyRaw 解 claim 到任意 map; 主要给测试 / debug。验签通过即返, 不校时间。
func (v *Verifier) VerifyRaw(ctx context.Context, raw string) (map[string]any, error) {
	var out map[string]any
	if err := v.verify(ctx, raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// verify 内部: 解 header → 找 kid → verify 签名 → unmarshal 到 dst。
func (v *Verifier) verify(ctx context.Context, raw string, dst any) error {
	tok, err := gojosejwt.ParseSigned(raw, []jose.SignatureAlgorithm{jose.RS256})
	if err != nil {
		return fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(tok.Headers) == 0 || tok.Headers[0].KeyID == "" {
		return ErrNoKid
	}
	kid := tok.Headers[0].KeyID

	sk, err := v.mgr.VerifierByKid(ctx, kid)
	if err != nil {
		return fmt.Errorf("oauth2/jwt: lookup kid %q: %w", kid, err)
	}
	pub := sk.PublicKey()
	if pub == nil {
		return errors.New("oauth2/jwt: key has no public material")
	}

	if err := tok.Claims(pub, dst); err != nil {
		return fmt.Errorf("%w: %v", ErrSigInvalid, err)
	}
	return nil
}

// checkTime 校 iat 跟 exp; ±60s skew 容忍 (服务器时钟不同步)。
func checkTime(iat, exp int64, now time.Time) error {
	const skew = 60 * time.Second
	nowUnix := now.Unix()
	if exp > 0 && nowUnix > exp+int64(skew/time.Second) {
		return ErrExpired
	}
	if iat > 0 && iat-int64(skew/time.Second) > nowUnix {
		return ErrNotYetValid
	}
	return nil
}
