// Package oidc 是 OpenID Connect Provider 实现, 基于 coreos/go-oidc v3。
//
// 用法 (M4):
//
//	p, err := oidc.New(ctx, oidc.Options{
//	    Issuer: "https://login.microsoftonline.com/{tenant}/v2.0",
//	    ClientID: "...",
//	    ClientSecret: "...",
//	    RedirectURI: "https://app.example.com/auth/oidc/callback",
//	    Scopes: []string{"openid","email","profile"},
//	})
//	if err != nil { return err }
//	profile, err := p.ExchangeCode(ctx, code, state)
//
// 不缓存 Provider; 每个 OIDC 配置项构造一次 *oidc.Provider (内部含 discovery 缓存),
// Registry 层负责生命周期。
package oidc

import (
	"context"
	"encoding/json"
	"fmt"

	gooidc "github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"

	identityadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
)

// Options 构造参数。
type Options struct {
	Issuer       string // discovery 起点; 例 https://accounts.google.com
	ClientID     string
	ClientSecret string
	RedirectURI  string
	Scopes       []string // 至少含 "openid"; "email"/"profile" 推荐加上
}

// Provider 是 identityadapter.Provider 的 OIDC 实现。
type Provider struct {
	opts     Options
	verifier *gooidc.IDTokenVerifier
	oauth    oauth2.Config
}

// New 构造; 调 Issuer 的 .well-known/openid-configuration 拉 JWKS + endpoints。
//
// 网络失败会直接报错 — 上层 Registry 决定是否缓存/重试。
func New(ctx context.Context, opts Options) (*Provider, error) {
	if opts.Issuer == "" || opts.ClientID == "" || opts.RedirectURI == "" {
		return nil, fmt.Errorf("oidc: issuer/client_id/redirect_uri required")
	}
	prov, err := gooidc.NewProvider(ctx, opts.Issuer)
	if err != nil {
		return nil, fmt.Errorf("oidc: discovery failed: %w", err)
	}
	scopes := opts.Scopes
	if len(scopes) == 0 {
		scopes = []string{gooidc.ScopeOpenID, "email", "profile"}
	}
	return &Provider{
		opts:     opts,
		verifier: prov.Verifier(&gooidc.Config{ClientID: opts.ClientID}),
		oauth: oauth2.Config{
			ClientID:     opts.ClientID,
			ClientSecret: opts.ClientSecret,
			RedirectURL:  opts.RedirectURI,
			Endpoint:     prov.Endpoint(),
			Scopes:       scopes,
		},
	}, nil
}

// Kind 返回 KindOIDC。
func (p *Provider) Kind() identityadapter.ProviderKind { return identityadapter.KindOIDC }

// ExchangeCode 走 authorization_code grant 拿 token, 校 ID Token 后映射成 Profile。
//
// **重要**: state 必须由 caller 在 callback handler 入口处比对完 (provider 不持 state,
// 持 state 的是 session/Redis)。本方法仅做 OIDC 协议层校验。
//
// codex challenge #7 修复: 已删掉本方法仅返 raw token 的早期版本。如果 caller 需要
// nonce 防 replay (强烈推荐), 用 ExchangeCodeWithNonce; 这里只做 code 换 token + 校 sig。
//
// **不**校验 email_verified, 由 callback handler 决定 (有些 IdP 不发这个 claim)。
func (p *Provider) ExchangeCode(ctx context.Context, code, _state string) (*identityadapter.Profile, error) {
	return p.exchangeCodeImpl(ctx, code, "")
}

// ExchangeCodeWithNonce 同 ExchangeCode, 但额外强制校验 ID Token nonce claim
// 与 expectedNonce 相等; 不等返错。caller 必须在 AuthCodeURL 时存好 nonce,
// callback 拿 code 时取出来传入这里。codex challenge #7 必修。
func (p *Provider) ExchangeCodeWithNonce(ctx context.Context, code, _state, expectedNonce string) (*identityadapter.Profile, error) {
	if expectedNonce == "" {
		return nil, fmt.Errorf("oidc: expectedNonce required (use ExchangeCode if you really don't want nonce verification)")
	}
	return p.exchangeCodeImpl(ctx, code, expectedNonce)
}

func (p *Provider) exchangeCodeImpl(ctx context.Context, code, expectedNonce string) (*identityadapter.Profile, error) {
	if code == "" {
		return nil, fmt.Errorf("oidc: code required")
	}
	tok, err := p.oauth.Exchange(ctx, code)
	if err != nil {
		return nil, fmt.Errorf("oidc: exchange code: %w", err)
	}
	rawID, _ := tok.Extra("id_token").(string)
	if rawID == "" {
		return nil, fmt.Errorf("oidc: no id_token in response")
	}
	idTok, err := p.verifier.Verify(ctx, rawID)
	if err != nil {
		return nil, fmt.Errorf("oidc: id_token verify: %w", err)
	}
	var claims struct {
		Sub               string   `json:"sub"`
		Email             string   `json:"email"`
		EmailVerified     bool     `json:"email_verified"`
		Name              string   `json:"name"`
		PreferredUsername string   `json:"preferred_username"`
		PhoneNumber       string   `json:"phone_number"`
		Groups            []string `json:"groups"`
		Nonce             string   `json:"nonce"`
	}
	if err := idTok.Claims(&claims); err != nil {
		return nil, fmt.Errorf("oidc: parse claims: %w", err)
	}
	// codex challenge #7: 校验 nonce; 防 replay / token substitution。
	if expectedNonce != "" && claims.Nonce != expectedNonce {
		return nil, fmt.Errorf("oidc: nonce mismatch (replay or substitution attack)")
	}
	// Raw 兜底; 便于 admin 调试 claims 映射。
	var raw map[string]any
	if b, _ := json.Marshal(idTok); len(b) > 0 {
		_ = json.Unmarshal(b, &raw)
	}
	name := claims.Name
	if name == "" {
		name = claims.PreferredUsername
	}
	return &identityadapter.Profile{
		Subject: claims.Sub,
		Email:   claims.Email,
		Name:    name,
		Phone:   claims.PhoneNumber,
		Groups:  claims.Groups,
		Raw:     raw,
	}, nil
}

// AuthCodeURL helper: 给 callback handler 拼跳转 URL 用 (不在 Provider 接口里)。
//
// state 和 nonce 必须由 caller 生成 + 存到 session/Redis (TTL 5min),
// callback 入口先校 state, 再调 ExchangeCodeWithNonce(code, state, nonce)。
func (p *Provider) AuthCodeURL(state, nonce string) string {
	return p.oauth.AuthCodeURL(state, gooidc.Nonce(nonce))
}
