// Package aesgcm 提供 AES-256-GCM 对称加密 + 数据密钥版本化能力 (F07 D3 KMS helper)。
//
// 设计:
//   - 主密钥 32 字节 (AES-256), 从 env 读 base64 值
//   - 输出 envelope: [version: 1B][nonce: 12B][ciphertext][tag: 16B], 字节流
//   - version 字节内嵌, 即便 DB 字段丢了也能解码; M2 rotate 时按 envelope[0] 选 key
//   - 失败明确分类: 主密钥配置错 / 密文损坏 / 版本不匹配, 不混用 io.EOF
//
// 用途:
//   - tenant_ragflow_bindings.api_key_ciphertext (RAGFlow api_key 加密)
//   - kb_provider_config.admin_pass_ciphertext (RAGFlow admin 密码加密)
//   - 未来其他长期 secret 长期存 DB 时复用
//
// M1: 仅一个 version=1 主密钥; M2 加 CipherSet 支持 multi-key 并存 + 后台 worker 重加密
package aesgcm

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
)

const (
	// KeyLen 是 AES-256 主密钥长度: 32 字节。
	KeyLen = 32
	// NonceLen 是 GCM 标准 nonce 长度: 12 字节。
	NonceLen = 12
	// TagLen 是 GCM auth tag 长度: 16 字节, 自动附在 ciphertext 尾部。
	TagLen = 16
	// CurrentVersion 是本版本支持的最高 envelope version 号。
	// rotate 时新版本递增, 老版本 envelope 仍可解 (multi-key 模式)。
	CurrentVersion byte = 1
	// MinEnvelopeLen = version(1) + nonce(12) + tag(16); ciphertext 允许 0 字节 (AES-GCM 原生支持空 plaintext)。
	MinEnvelopeLen = 1 + NonceLen + TagLen
)

// 错误集合; 上层据此区分配置错 / 密文损坏 / 版本不匹配。
var (
	// ErrKeyMissing 主密钥未配置或长度错。
	ErrKeyMissing = errors.New("aesgcm: key missing or wrong length (need 32 bytes after base64 decode)")
	// ErrEnvelopeTooShort envelope 字节流过短, 不可能是合法密文。
	ErrEnvelopeTooShort = errors.New("aesgcm: envelope too short")
	// ErrVersionMismatch envelope 头部的版本号与当前 Cipher 不一致 (M2 multi-key 用)。
	ErrVersionMismatch = errors.New("aesgcm: envelope version mismatch")
	// ErrAuthFail GCM tag 验证失败 — 密文被篡改 / 密钥错。
	ErrAuthFail = errors.New("aesgcm: authentication failed (corrupted ciphertext or wrong key)")
)

// Cipher 是单版本的 AES-GCM 加解密器。线程安全。
type Cipher struct {
	gcm     cipher.AEAD
	version byte
}

// New 从原始 32 字节主密钥构造 Cipher。
// 调用方应通过 NewFromEnv / NewFromBase64 来构造, 不要直接传明文 key。
func New(key []byte) (*Cipher, error) {
	if len(key) != KeyLen {
		return nil, ErrKeyMissing
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aesgcm: NewCipher: %w", err)
	}
	g, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("aesgcm: NewGCM: %w", err)
	}
	if g.NonceSize() != NonceLen {
		return nil, fmt.Errorf("aesgcm: unexpected NonceSize=%d", g.NonceSize())
	}
	return &Cipher{gcm: g, version: CurrentVersion}, nil
}

// NewFromBase64 从 base64 编码的主密钥构造 Cipher。
// 期望解码后正好 32 字节 (KeyLen)。
func NewFromBase64(b64 string) (*Cipher, error) {
	if b64 == "" {
		return nil, ErrKeyMissing
	}
	key, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("aesgcm: base64 decode: %w", err)
	}
	return New(key)
}

// NewFromEnv 从环境变量读 base64 主密钥, 构造 Cipher。
func NewFromEnv(envName string) (*Cipher, error) {
	if envName == "" {
		envName = "AGBUS_KB_KMS_DATA_KEY"
	}
	return NewFromBase64(os.Getenv(envName))
}

// NewFromEnvAny 按顺序尝试多个环境变量名, 第一个非空值会被用作 base64 主密钥。
// 用于变量改名时保留旧环境的平滑兼容。
func NewFromEnvAny(envNames ...string) (*Cipher, string, error) {
	for _, envName := range envNames {
		if envName == "" {
			continue
		}
		if value := os.Getenv(envName); value != "" {
			c, err := NewFromBase64(value)
			return c, envName, err
		}
	}
	return nil, "", ErrKeyMissing
}

// Version 返回当前主密钥版本号。
// agent-bus 写 DB 时把 Version() 存到对应表的 api_key_version 字段, 方便审计 + rotate 追踪。
func (c *Cipher) Version() byte { return c.version }

// Encrypt 加密 plaintext, 返回 envelope:
//
//	[version: 1B][nonce: 12B][ciphertext][tag: 16B]
//
// nonce 自动随机生成 (crypto/rand)。
func (c *Cipher) Encrypt(plaintext []byte) ([]byte, error) {
	nonce := make([]byte, NonceLen)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("aesgcm: random nonce: %w", err)
	}
	// AEAD Seal 把 ciphertext + tag 拼一块儿
	sealed := c.gcm.Seal(nil, nonce, plaintext, nil)
	// envelope = version || nonce || sealed
	out := make([]byte, 0, 1+NonceLen+len(sealed))
	out = append(out, c.version)
	out = append(out, nonce...)
	out = append(out, sealed...)
	return out, nil
}

// Decrypt 从 envelope 还原 plaintext。
//
// 错误处理:
//   - ErrEnvelopeTooShort: envelope 字节流过短
//   - ErrVersionMismatch:  envelope 版本号 ≠ 当前 Cipher 版本 (M2 multi-key 时上层捕获后查 CipherSet)
//   - ErrAuthFail:         GCM tag 验证失败 (密文损坏 / 主密钥不对)
func (c *Cipher) Decrypt(envelope []byte) ([]byte, error) {
	if len(envelope) < MinEnvelopeLen {
		return nil, ErrEnvelopeTooShort
	}
	ver := envelope[0]
	if ver != c.version {
		return nil, ErrVersionMismatch
	}
	nonce := envelope[1 : 1+NonceLen]
	sealed := envelope[1+NonceLen:]
	plain, err := c.gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return nil, ErrAuthFail
	}
	return plain, nil
}

// EnvelopeVersion 从 envelope 字节流抽取版本号, 不解密。
// 用途: M2 multi-key 时, 上层先 peek version, 再去 CipherSet 找对应 Cipher。
// envelope 长度不够时返 (0, ErrEnvelopeTooShort)。
func EnvelopeVersion(envelope []byte) (byte, error) {
	if len(envelope) < MinEnvelopeLen {
		return 0, ErrEnvelopeTooShort
	}
	return envelope[0], nil
}
