// Package jwt 提供 Ed25519 (EdDSA) 签名的 JWT 颁发与验证。
//
// 设计决策:
//   - 算法: Ed25519/EdDSA (M1 §9), 不再支持 HS256
//   - 私钥仅 cmd/bus 持有 (签发), 公钥可分发给其它进程做验证
//   - claims 字段: sub=account.uuid, aid=account.id, sid=session.uuid,
//     act_scope=platform|tenant:<uuid>|workspace:<uuid>, perms 摘要 hash,
//     acting_as (impersonate 标记)
package jwt

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"strings"
	"time"

	jwtv5 "github.com/golang-jwt/jwt/v5"
)

// Claims 是 agent-bus 颁发的 JWT 负载。
type Claims struct {
	// AccountID 数字 ID (内部 join 用)。
	AccountID int64 `json:"aid"`
	// AccountUUID 账号 UUID; 也写入 sub。
	AccountUUID string `json:"-"`
	// SessionUUID 关联 login_sessions.uuid, 用于撤销定位。
	SessionUUID string `json:"sid"`
	// ActScope 当前作用范畴: "platform" / "tenant:<uuid>" / "workspace:<uuid>"。
	ActScope string `json:"act_scope"`
	// ActTenantID 当前 tenant 数字 ID (act_scope=tenant/workspace 时填), 0 表示 platform。
	ActTenantID int64 `json:"act_tid,omitempty"`
	// ActWorkspaceID 当前 workspace 数字 ID。
	ActWorkspaceID int64 `json:"act_wid,omitempty"`
	// PermsHash 当前 scope 下 perms 集合的 sha256 摘要前 16 字节 hex,
	// 用于中间件快速判断 perms 是否变化 (变化时需重拉)。
	PermsHash string `json:"ph,omitempty"`
	// Perms 当前 scope 下 perms 全集 (token 自包含, 避免中间件每请求查 PG)。
	// 调权后需 refresh token 重新签发才能拿到新集合。
	Perms []string `json:"perms,omitempty"`
	// MustChange 是否强制改密。true 时除 password.change / logout / me 类接口外都应拒绝业务请求。
	// 由 issue 时 admin_accounts.must_change_password 决定；改密成功后 RevokeAllByAccount 旧 token，新登录拿 false。
	MustChange bool `json:"mc,omitempty"`
	// Admin 表示该账号当前 token 具备进入 admin web 的后台资格。
	// 角色变更通过 auth_revoke 撤销旧 token，避免每个 admin 请求回查 role_assignments。
	Admin bool `json:"admin,omitempty"`
	// ActingAs impersonate 标记, 例 "platform_admin" 表示 platform 管理员代入租户。
	ActingAs string `json:"acting_as,omitempty"`
	// Kind 颁发对象类型: user (普通登录) / impersonation。
	Kind string `json:"kind,omitempty"`
	jwtv5.RegisteredClaims
}

// Issuer 签发 + 验证 JWT。
type Issuer struct {
	priv      ed25519.PrivateKey
	pub       ed25519.PublicKey
	issuer    string
	accessTTL time.Duration
}

// New 用 PEM 编码的 Ed25519 私钥构造。pubPem 可为空, 自动从私钥派生。
//
// privPem: PKCS#8 PEM 编码 Ed25519 私钥
// pubPem:  SPKI  PEM 编码 Ed25519 公钥; 留空时自动派生
func New(privPem, pubPem, issuer string, accessTTL time.Duration) (*Issuer, error) {
	priv, err := parseEd25519Private(privPem)
	if err != nil {
		return nil, fmt.Errorf("jwt: parse private key: %w", err)
	}
	var pub ed25519.PublicKey
	if strings.TrimSpace(pubPem) != "" {
		pub, err = parseEd25519Public(pubPem)
		if err != nil {
			return nil, fmt.Errorf("jwt: parse public key: %w", err)
		}
	} else {
		pub = priv.Public().(ed25519.PublicKey)
	}
	return &Issuer{priv: priv, pub: pub, issuer: issuer, accessTTL: accessTTL}, nil
}

// NewVerifyOnly 仅持有公钥, 不能签发。给 admin / 外部进程用。
func NewVerifyOnly(pubPem, issuer string) (*Issuer, error) {
	pub, err := parseEd25519Public(pubPem)
	if err != nil {
		return nil, fmt.Errorf("jwt: parse public key: %w", err)
	}
	return &Issuer{pub: pub, issuer: issuer}, nil
}

// GenerateDevKeypair 生成一对临时密钥, 仅用于 dev 启动时未配置 KEY 的兜底。
// 返回 (privPem, pubPem)。
func GenerateDevKeypair() (string, string, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return "", "", err
	}
	spki, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", "", err
	}
	privPem := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}))
	pubPem := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: spki}))
	return privPem, pubPem, nil
}

// AccessTTL 公开 TTL 给上层用。
func (i *Issuer) AccessTTL() time.Duration { return i.accessTTL }

// IssueOptions 控制本次签发。
type IssueOptions struct {
	AccountID      int64
	AccountUUID    string
	SessionUUID    string
	ActScope       string
	ActTenantID    int64
	ActWorkspaceID int64
	Perms          []string
	ActingAs       string
	Kind           string
	MustChange     bool          // 强制改密标志
	Admin          bool          // 后台资格标志
	TTL            time.Duration // 0 = 使用默认 accessTTL
}

// Issue 颁发一个 access token。
func (i *Issuer) Issue(opt IssueOptions) (string, error) {
	if i.priv == nil {
		return "", errors.New("jwt: issuer has no private key")
	}
	ttl := opt.TTL
	if ttl <= 0 {
		ttl = i.accessTTL
	}
	now := time.Now()
	c := Claims{
		AccountID:      opt.AccountID,
		AccountUUID:    opt.AccountUUID,
		SessionUUID:    opt.SessionUUID,
		ActScope:       opt.ActScope,
		ActTenantID:    opt.ActTenantID,
		ActWorkspaceID: opt.ActWorkspaceID,
		PermsHash:      hashPerms(opt.Perms),
		Perms:          opt.Perms,
		MustChange:     opt.MustChange,
		Admin:          opt.Admin,
		ActingAs:       opt.ActingAs,
		Kind:           defaultKind(opt.Kind),
		RegisteredClaims: jwtv5.RegisteredClaims{
			Issuer:    i.issuer,
			Subject:   opt.AccountUUID,
			IssuedAt:  jwtv5.NewNumericDate(now),
			NotBefore: jwtv5.NewNumericDate(now),
			ExpiresAt: jwtv5.NewNumericDate(now.Add(ttl)),
			ID:        opt.SessionUUID, // jti = session uuid
		},
	}
	t := jwtv5.NewWithClaims(jwtv5.SigningMethodEdDSA, c)
	return t.SignedString(i.priv)
}

// Verify 校验签名 + 过期, 返回 claims。
func (i *Issuer) Verify(tokenStr string) (*Claims, error) {
	t, err := jwtv5.ParseWithClaims(tokenStr, &Claims{}, func(t *jwtv5.Token) (interface{}, error) {
		if t.Method.Alg() != jwtv5.SigningMethodEdDSA.Alg() {
			return nil, fmt.Errorf("jwt: unexpected alg %s", t.Method.Alg())
		}
		return i.pub, nil
	})
	if err != nil {
		return nil, err
	}
	c, ok := t.Claims.(*Claims)
	if !ok || !t.Valid {
		return nil, errors.New("jwt: invalid token")
	}
	// Subject 是 account_uuid (M1 §4.2)
	c.AccountUUID = c.Subject
	return c, nil
}

// ===== helpers =====

func hashPerms(perms []string) string {
	if len(perms) == 0 {
		return ""
	}
	// 排序在调用方完成; 这里只算 hash。考虑顺序固定: copy 并简易排序。
	// 用 join 后 sha256, 取前 16 字节 hex (32 字符) 控制 token 长度。
	joined := strings.Join(perms, "|")
	sum := sha256.Sum256([]byte(joined))
	return base64.RawURLEncoding.EncodeToString(sum[:12])
}

func defaultKind(k string) string {
	if k == "" {
		return "user"
	}
	return k
}

func parseEd25519Private(p string) (ed25519.PrivateKey, error) {
	block, _ := pem.Decode([]byte(strings.TrimSpace(p)))
	if block == nil {
		return nil, errors.New("not a PEM block")
	}
	if block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("unexpected PEM type %q (want PRIVATE KEY)", block.Type)
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ed, ok := key.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("not an Ed25519 private key (%T)", key)
	}
	return ed, nil
}

func parseEd25519Public(p string) (ed25519.PublicKey, error) {
	block, _ := pem.Decode([]byte(strings.TrimSpace(p)))
	if block == nil {
		return nil, errors.New("not a PEM block")
	}
	if block.Type != "PUBLIC KEY" {
		return nil, fmt.Errorf("unexpected PEM type %q (want PUBLIC KEY)", block.Type)
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ed, ok := key.(ed25519.PublicKey)
	if !ok {
		return nil, fmt.Errorf("not an Ed25519 public key (%T)", key)
	}
	return ed, nil
}

// IssuePerms 用于内部场景: 仅给定一组 perms 算 hash, 不签 token (供 middleware 比对)。
func IssuePerms(perms []string) string { return hashPerms(perms) }
