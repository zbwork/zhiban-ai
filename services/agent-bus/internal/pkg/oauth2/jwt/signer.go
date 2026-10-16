// signer.go — F04 OAuth2 JWT 签发。
//
// 使用: jwt.NewSigner(keyMgr).SignIDToken(ctx, claims) / SignAccessToken(ctx, claims)
//
// 内部走 keys.Manager.ActiveSigner() 拿当前 active key, 用 go-jose 签 RS256。
// kid 写到 JWT header (verifier 用它找公钥)。
package jwt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/keys"
)

// Signer 签 JWT; goroutine-safe (内部不持状态, 每次调 keys.Manager.ActiveSigner)。
type Signer struct {
	mgr keys.Manager
}

// NewSigner 构造。
func NewSigner(mgr keys.Manager) *Signer {
	return &Signer{mgr: mgr}
}

// SignIDToken 签发 id_token JWT。
func (s *Signer) SignIDToken(ctx context.Context, claims IDTokenClaims) (string, error) {
	return s.signClaims(ctx, claims)
}

// SignAccessToken 签发 access_token JWT。
func (s *Signer) SignAccessToken(ctx context.Context, claims AccessTokenClaims) (string, error) {
	return s.signClaims(ctx, claims)
}

// SignLocalCodingAccessToken 签发 F31 本地编程工具访问模型网关的短期 token。
func (s *Signer) SignLocalCodingAccessToken(ctx context.Context, claims LocalCodingAccessTokenClaims) (string, error) {
	return s.signClaims(ctx, claims)
}

// signClaims 通用签发逻辑; 任何 JSON-marshallable claim struct 都能签。
func (s *Signer) signClaims(ctx context.Context, claims any) (string, error) {
	sk, err := s.mgr.ActiveSigner(ctx)
	if err != nil {
		return "", fmt.Errorf("oauth2/jwt: get active signer: %w", err)
	}
	if sk.PrivateKey == nil {
		return "", errors.New("oauth2/jwt: active key has no private material (corrupt or not loaded)")
	}
	if sk.Algorithm != keys.AlgRS256 {
		return "", fmt.Errorf("oauth2/jwt: unsupported algorithm %q (v0.1 only RS256)", sk.Algorithm)
	}

	signKey := jose.SigningKey{
		Algorithm: jose.RS256,
		Key:       sk.PrivateKey,
	}
	opts := (&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", sk.Kid)

	signer, err := jose.NewSigner(signKey, opts)
	if err != nil {
		return "", fmt.Errorf("oauth2/jwt: new signer: %w", err)
	}

	// 用 go-jose/jwt 高层 API 序列化; 等价于 manual marshal + JWS Sign + Compact。
	// 注意: go-jose jwt.Signed expects a struct with json tags or map; 我们的 claims struct 已有。
	raw, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		return "", fmt.Errorf("oauth2/jwt: serialize: %w", err)
	}
	return raw, nil
}

// SignRaw 给 caller 一份手动控制 — 直接传 marshallable claims map (主要给测试用)。
func (s *Signer) SignRaw(ctx context.Context, claims map[string]any) (string, error) {
	// 校 marshal 通过
	if _, err := json.Marshal(claims); err != nil {
		return "", fmt.Errorf("oauth2/jwt: marshal claims: %w", err)
	}
	return s.signClaims(ctx, claims)
}
