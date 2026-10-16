// pg_store.go — Manager 的 Postgres 实现; 走 pgxpool 直查 oauth_signing_keys 表。
//
// 私钥落库前 sealer.Seal (AES-256-GCM); 读出后 sealer.Open。
// 错误处理: 解密失败的行被 skip + log, 防一行坏 key 整体不可用。
package keys

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Sealer 解耦 pkg/secretbox.Box, 便于测试 mock。
type Sealer interface {
	Seal(plaintext string) (string, error)
	Open(ciphertext string) (string, error)
}

// PostgresManager 是 Manager 的 pgxpool 实现。
type PostgresManager struct {
	*baseManager
	pool   *pgxpool.Pool
	sealer Sealer
}

// NewPostgresManager 构造; 立即触发首次 Refresh (拉 active+retiring keys 进缓存)。
// 调用方应在 cmd/bus 主循环里定期调 mgr.Refresh(ctx) (走单独 goroutine), 周期 30s。
func NewPostgresManager(ctx context.Context, pool *pgxpool.Pool, sealer Sealer) (*PostgresManager, error) {
	if pool == nil {
		return nil, errors.New("keys: pool required")
	}
	if sealer == nil {
		return nil, errors.New("keys: sealer required")
	}
	m := &PostgresManager{pool: pool, sealer: sealer}
	m.baseManager = &baseManager{
		refresh: 30 * time.Second,
		load:    m.loadAll,
	}
	// 首次加载 — 表空允许 (ActiveSigner 报错让 caller 走 Bootstrap)。
	if err := m.Refresh(ctx); err != nil {
		return nil, fmt.Errorf("keys: initial refresh: %w", err)
	}
	return m, nil
}

const selectColumns = `id, kid, algorithm, public_jwk::text, private_pem_enc, status, activated_at`

// loadAll 拉 active + retiring 的 keys (retired 不要), 解密私钥, 组装 snapshot。
func (m *PostgresManager) loadAll(ctx context.Context) (*snapshot, error) {
	rows, err := m.pool.Query(ctx,
		`SELECT `+selectColumns+`
		   FROM oauth_signing_keys
		  WHERE status IN ('active','retiring')
		  ORDER BY activated_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("keys: query: %w", err)
	}
	defer rows.Close()

	snap := &snapshot{
		byKid:    map[string]*SigningKey{},
		jwksKeys: []map[string]any{},
		loadedAt: time.Now(),
	}

	for rows.Next() {
		var (
			id          int64
			kid, alg    string
			jwkJSON     string
			privPemEnc  string
			statusStr   string
			activatedAt time.Time
		)
		if err := rows.Scan(&id, &kid, &alg, &jwkJSON, &privPemEnc, &statusStr, &activatedAt); err != nil {
			return nil, fmt.Errorf("keys: scan: %w", err)
		}

		sk, err := materializeSigningKey(id, kid, alg, jwkJSON, privPemEnc, statusStr, activatedAt, m.sealer)
		if err != nil {
			return nil, err
		}
		if sk == nil {
			continue
		}
		snap.byKid[kid] = sk
		snap.jwksKeys = append(snap.jwksKeys, sk.PublicJWK)
		if sk.Status == StatusActive {
			snap.active = sk
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("keys: rows.err: %w", err)
	}
	return snap, nil
}

func materializeSigningKey(id int64, kid, alg, jwkJSON, privPemEnc, statusStr string, activatedAt time.Time, sealer Sealer) (*SigningKey, error) {
	status := Status(statusStr)
	active := status == StatusActive

	var pubJWK map[string]any
	if err := json.Unmarshal([]byte(jwkJSON), &pubJWK); err != nil {
		if active {
			return nil, fmt.Errorf("keys: active signing key %s public_jwk invalid: %w", kid, err)
		}
		return nil, nil
	}

	privPem, err := sealer.Open(privPemEnc)
	if err != nil {
		if active {
			return nil, fmt.Errorf("keys: active signing key %s decrypt private_pem_enc: %w", kid, err)
		}
		return nil, nil
	}
	privKey, err := parseRSAPrivatePEM(privPem)
	if err != nil {
		if active {
			return nil, fmt.Errorf("keys: active signing key %s private key invalid: %w", kid, err)
		}
		return nil, nil
	}

	return &SigningKey{
		ID:          id,
		Kid:         kid,
		Algorithm:   Algorithm(alg),
		Status:      status,
		ActivatedAt: activatedAt,
		PrivateKey:  privKey,
		PublicJWK:   pubJWK,
	}, nil
}

// Bootstrap 表空 → generate RSA-2048 + active 落库。
//
// 调用方应在 cmd/bus 启动序列里调一次; 表非空 → 返 first=false 不动数据。
func (m *PostgresManager) Bootstrap(ctx context.Context) (bool, error) {
	var n int64
	if err := m.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM oauth_signing_keys WHERE status='active'`).Scan(&n); err != nil {
		return false, fmt.Errorf("keys: bootstrap count: %w", err)
	}
	if n > 0 {
		return false, nil
	}
	if _, err := m.insertNewKey(ctx, nil, StatusActive); err != nil {
		return false, err
	}
	if err := m.Refresh(ctx); err != nil {
		return true, err
	}
	return true, nil
}

// Rotate active → retiring + 新 active 落库; 单事务原子化。
//
// uq_oauth_signing_keys_active_singleton 强制 active 单例,
// 必须先把老 active 退到 retiring, 再插新 active (同事务)。
func (m *PostgresManager) Rotate(ctx context.Context) (string, error) {
	tx, err := m.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("keys: rotate begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	if _, err := tx.Exec(ctx,
		`UPDATE oauth_signing_keys SET status='retiring', retiring_at=now() WHERE status='active'`); err != nil {
		return "", fmt.Errorf("keys: rotate update old: %w", err)
	}

	newKid, err := m.insertNewKey(ctx, tx, StatusActive)
	if err != nil {
		return "", err
	}

	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("keys: rotate commit: %w", err)
	}

	if err := m.Refresh(ctx); err != nil {
		return newKid, err
	}
	return newKid, nil
}

// insertNewKey generate 一对 + 落库一行; tx 为 nil 时直接走 pool.Exec, 否则用事务。
func (m *PostgresManager) insertNewKey(ctx context.Context, tx pgx.Tx, status Status) (string, error) {
	priv, pubJWK, err := generateRSAPair()
	if err != nil {
		return "", err
	}
	short := strings.ReplaceAll(uuid.NewString(), "-", "")[:12]
	kid := "k-" + short
	pubJWK["kid"] = kid

	pemBytes, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return "", fmt.Errorf("keys: marshal pkcs8: %w", err)
	}
	enc, err := m.sealer.Seal(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pemBytes})))
	if err != nil {
		return "", fmt.Errorf("keys: seal: %w", err)
	}
	jwkJSON, _ := json.Marshal(pubJWK)

	sql := `INSERT INTO oauth_signing_keys (kid, algorithm, public_jwk, private_pem_enc, status, activated_at)
	        VALUES ($1, 'RS256', $2::jsonb, $3, $4, now())`
	args := []any{kid, string(jwkJSON), enc, string(status)}
	if tx != nil {
		if _, err := tx.Exec(ctx, sql, args...); err != nil {
			return "", fmt.Errorf("keys: insert (tx): %w", err)
		}
	} else {
		if _, err := m.pool.Exec(ctx, sql, args...); err != nil {
			return "", fmt.Errorf("keys: insert: %w", err)
		}
	}
	return kid, nil
}

// generateRSAPair 生成 RSA-2048 + 对应公开 JWK (kid 留空, 由 caller 填)。
func generateRSAPair() (*rsa.PrivateKey, map[string]any, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, fmt.Errorf("keys: rsa generate: %w", err)
	}
	pubJWK := map[string]any{
		"kty": "RSA",
		"use": "sig",
		"alg": "RS256",
		"n":   base64.RawURLEncoding.EncodeToString(priv.N.Bytes()),
		"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes()),
	}
	return priv, pubJWK, nil
}

// parseRSAPrivatePEM 把 PEM 形式 PKCS#8 私钥解成 *rsa.PrivateKey;
// 兼容 PKCS#1 (RSA 旧格式) fallback。
func parseRSAPrivatePEM(pemStr string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, errors.New("keys: pem decode failed")
	}
	if rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return rsaKey, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("keys: parse private key: %w", err)
	}
	rsaKey, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("keys: not an RSA key")
	}
	return rsaKey, nil
}
