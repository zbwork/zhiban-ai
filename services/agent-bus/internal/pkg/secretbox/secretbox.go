// Package secretbox 是租户 IdP / 第三方凭证字段的 server-side AEAD 加密。
//
// 设计目标 (codex challenge #6: IdP client_secret 不能 base64 裸存):
//   - AES-256-GCM, key 来自 env (AGBUS_SECRETBOX_KEY, 32 字节 base64)
//   - ciphertext = base64(nonce || aead(plaintext))
//   - 单一 key 滚动 v0; v1 加 key_id prefix 时再加版本字段。
//
// 不是任何 KMS / Vault 客户端 — 那是 secret-ref 模式 (config 里写 vault://path/to/key),
// 适合"上游凭证"。本 box 适合"业务字段加密" (DB-at-rest 防 dump)。
//
// fail-fast: prod 环境必须设 AGBUS_SECRETBOX_KEY, 否则 New() 报错;
// dev/local 允许零 key (开发图省事), 但**警告** + 用 hardcoded dev key (不上 prod)。
package secretbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
)

// devKey 是 32 字节 hardcoded 测试 key; 仅当 env 未设 + env 是 local/dev 时用。
// 永远不要在 prod / test 环境出现 — Box.New() 在那些环境会强制要求 env。
var devKey = [32]byte{
	'd', 'e', 'v', '-', 'o', 'n', 'l', 'y',
	'-', 's', 'e', 'c', 'r', 'e', 't', 'b',
	'o', 'x', '-', 'k', 'e', 'y', '-', 'X',
	'X', 'X', 'X', 'X', 'X', 'X', 'X', 'X',
}

// Box 持有 AEAD; 多 goroutine 安全 (crypto/cipher.AEAD 文档承诺)。
type Box struct {
	aead cipher.AEAD
}

// New 构造 Box; env="local"/"dev" 时允许 fallback 到 devKey + 打警告。
//
// 上层一般在 cmd/bus / cmd/admin 启动时 New 一份, 注入需要的 service。
func New(env string) (*Box, error) {
	raw := os.Getenv("AGBUS_SECRETBOX_KEY")
	var key [32]byte
	if raw != "" {
		decoded, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, fmt.Errorf("secretbox: invalid AGBUS_SECRETBOX_KEY base64: %w", err)
		}
		if len(decoded) != 32 {
			return nil, fmt.Errorf("secretbox: AGBUS_SECRETBOX_KEY must decode to 32 bytes, got %d", len(decoded))
		}
		copy(key[:], decoded)
	} else {
		if env != "local" && env != "dev" {
			return nil, fmt.Errorf("secretbox: AGBUS_SECRETBOX_KEY required in env=%q (only local/dev allow dev fallback)", env)
		}
		key = devKey
		fmt.Fprintf(os.Stderr, "[secretbox] WARN: AGBUS_SECRETBOX_KEY unset in env=%q; using hardcoded dev key (NOT FOR PROD)\n", env)
	}
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, fmt.Errorf("secretbox: aes.NewCipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("secretbox: cipher.NewGCM: %w", err)
	}
	return &Box{aead: aead}, nil
}

// Seal 加密明文; 返回 base64(nonce || ciphertext)。空明文 → 空串。
func (b *Box) Seal(plaintext string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	nonce := make([]byte, b.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("secretbox: rand: %w", err)
	}
	ct := b.aead.Seal(nil, nonce, []byte(plaintext), nil)
	out := make([]byte, 0, len(nonce)+len(ct))
	out = append(out, nonce...)
	out = append(out, ct...)
	return base64.StdEncoding.EncodeToString(out), nil
}

// Open 解密 base64(nonce||ct); 失败返错 (含 GCM 校验失败)。
func (b *Box) Open(enc string) (string, error) {
	if enc == "" {
		return "", nil
	}
	raw, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		return "", fmt.Errorf("secretbox: base64: %w", err)
	}
	ns := b.aead.NonceSize()
	if len(raw) < ns+b.aead.Overhead() {
		return "", errors.New("secretbox: ciphertext too short")
	}
	nonce, ct := raw[:ns], raw[ns:]
	pt, err := b.aead.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", fmt.Errorf("secretbox: open: %w", err)
	}
	return string(pt), nil
}
