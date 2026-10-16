// Package keys 是 F04 OAuth2 JWT 签名密钥管理。
//
// 概念:
//   - SigningKey   : 一个密钥对 (kid + algorithm + RSA 私钥 + 公钥 JWK), 加生命周期状态
//   - KeyManager   : 暴露 ActiveSigner (签新 JWT 用) + Verifiers (验签用) + JWKS (公开 endpoint)
//   - status 三态  : active (≤1, 签新) | retiring (≥0, 仅验) | retired (从 JWKS 移除, 30 天后删)
//
// 持久化: oauth_signing_keys 表 (migration 000064)。
// 私钥加密: pkg/secretbox AES-256-GCM。
//
// 使用:
//
//	mgr, err := keys.NewPostgresManager(ctx, pool, sealer)
//	if err != nil { return err }
//	if err := mgr.Bootstrap(ctx); err != nil { return err }  // 表空则 generate
//
//	signer, _ := mgr.ActiveSigner(ctx)   // 签新 JWT
//	verSet, _ := mgr.VerifierSet(ctx)    // 验 JWT (kid → key)
//	jwks, _   := mgr.JWKS(ctx)           // serve /.well-known/jwks.json
//
// 进程内缓存: 启动时 Load + 30s 刷新; pg_notify 推过来时立即重载 (v0.2 接);
// v0.1 走 30s 轮询 — 轮转时容忍 30s 验签延迟。
package keys

import (
	"context"
	"crypto/rsa"
	"errors"
	"sync"
	"time"
)

// Status 是 oauth_signing_keys.status 的枚举。
type Status string

const (
	StatusActive   Status = "active"
	StatusRetiring Status = "retiring"
	StatusRetired  Status = "retired"
)

// Algorithm 是签名算法枚举。
type Algorithm string

const (
	AlgRS256 Algorithm = "RS256"
	// AlgES256 / AlgEdDSA 预留 — v0.1 仅 RS256
	AlgES256 Algorithm = "ES256"
	AlgEdDSA Algorithm = "EdDSA"
)

// SigningKey 一个密钥对的完整运行时表达。
//
// PrivateKey 仅当 IsLoaded()=true 时存在 (manager Load 时解密填充);
// Public + JWK + kid + algo 永远有值。
type SigningKey struct {
	ID          int64
	Kid         string
	Algorithm   Algorithm
	Status      Status
	ActivatedAt time.Time

	// PrivateKey 解密后的 RSA 私钥; nil 时表示 verify-only (manager 不加载 retired key 的私钥)。
	PrivateKey *rsa.PrivateKey
	// PublicJWK 是 JWK 序列化形式 (用于直接 serve 给 /.well-known/jwks.json 的 keys 数组元素)。
	// 结构: {"kty":"RSA","use":"sig","alg":"RS256","kid":"...","n":"...","e":"..."}
	PublicJWK map[string]any
}

// PublicKey 返公钥指针 (从 PrivateKey 取); nil 时回退 nil。
func (k *SigningKey) PublicKey() *rsa.PublicKey {
	if k.PrivateKey == nil {
		return nil
	}
	return &k.PrivateKey.PublicKey
}

// Manager 是 JWT 签名密钥的抽象访问接口; 实现见 pg_store.go。
type Manager interface {
	// ActiveSigner 返当前 active 的 signing key (唯一一个); 表里没 active 行返 ErrNoActiveKey。
	// 给 jwt.Signer.Sign() 用。
	ActiveSigner(ctx context.Context) (*SigningKey, error)

	// VerifierByKid 按 kid 查 key (active + retiring 都能查到, retired 不行);
	// 找不到返 ErrKidNotFound。给 jwt.Verifier.Verify() 用。
	VerifierByKid(ctx context.Context, kid string) (*SigningKey, error)

	// JWKSKeys 返当前应该 expose 给 /.well-known/jwks.json 的所有 key (active + retiring);
	// 只含公开字段。
	JWKSKeys(ctx context.Context) ([]map[string]any, error)

	// Refresh 强制从 DB 重读 (运维 hook + pg_notify 触发器); 不报错只 log。
	Refresh(ctx context.Context) error

	// Bootstrap 首次部署用: 表空 → generate 一对 RS256 新 active key 并落库。
	// 表非空 → no-op。返值 first=true 表示这次真触发了 generate。
	Bootstrap(ctx context.Context) (first bool, err error)

	// Rotate 把当前 active → retiring + generate 一个新 active; 原子化 (DB tx)。
	// 给 admin endpoint / 运维 cron 调; v0.1 不暴露 endpoint, 留接口。
	Rotate(ctx context.Context) (newKid string, err error)
}

// 错误。
var (
	ErrNoActiveKey = errors.New("oauth2/keys: no active signing key (run Bootstrap?)")
	ErrKidNotFound = errors.New("oauth2/keys: kid not found or retired")
)

// snapshot 是 manager 内存缓存的不可变快照; 读侧 lock-free。
type snapshot struct {
	active   *SigningKey            // 唯一 active
	byKid    map[string]*SigningKey // active + retiring
	jwksKeys []map[string]any       // active + retiring 公开 JWK
	loadedAt time.Time
}

// baseManager 是 Manager 实现的共用部分 (snapshot + refresh 节流)。
// 具体存储后端 (Postgres) 在 pg_store.go 嵌入。
type baseManager struct {
	mu      sync.RWMutex
	snap    *snapshot
	refresh time.Duration // 后台周期刷新间隔
	load    func(ctx context.Context) (*snapshot, error)
}

func (m *baseManager) current() *snapshot {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.snap
}

func (m *baseManager) setSnap(s *snapshot) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.snap = s
}

// Refresh 走 load + 替换。
func (m *baseManager) Refresh(ctx context.Context) error {
	s, err := m.load(ctx)
	if err != nil {
		return err
	}
	m.setSnap(s)
	return nil
}

// ActiveSigner 从 snapshot 读 active key; 没有则刷新一次再读。
func (m *baseManager) ActiveSigner(ctx context.Context) (*SigningKey, error) {
	if s := m.current(); s != nil && s.active != nil {
		return s.active, nil
	}
	if err := m.Refresh(ctx); err != nil {
		return nil, err
	}
	s := m.current()
	if s == nil || s.active == nil {
		return nil, ErrNoActiveKey
	}
	return s.active, nil
}

// VerifierByKid 同上逻辑。
func (m *baseManager) VerifierByKid(ctx context.Context, kid string) (*SigningKey, error) {
	if s := m.current(); s != nil {
		if k, ok := s.byKid[kid]; ok {
			return k, nil
		}
	}
	// 找不到 → 刷新一次 (可能是刚 rotate 完, 缓存还没追上)
	if err := m.Refresh(ctx); err != nil {
		return nil, err
	}
	s := m.current()
	if s == nil {
		return nil, ErrKidNotFound
	}
	if k, ok := s.byKid[kid]; ok {
		return k, nil
	}
	return nil, ErrKidNotFound
}

// JWKSKeys 直接读 snapshot 的预算好的 jwksKeys 切片。
func (m *baseManager) JWKSKeys(ctx context.Context) ([]map[string]any, error) {
	s := m.current()
	if s == nil {
		if err := m.Refresh(ctx); err != nil {
			return nil, err
		}
		s = m.current()
	}
	if s == nil {
		return []map[string]any{}, nil
	}
	// 拷一份返出去, 防 caller 改
	out := make([]map[string]any, len(s.jwksKeys))
	copy(out, s.jwksKeys)
	return out, nil
}
