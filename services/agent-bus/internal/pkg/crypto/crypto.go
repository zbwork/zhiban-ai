// Package crypto 提供密码哈希算法 (argon2id) 与校验。
//
// 算法: argon2id, M1 §9 强制要求, m=64MB, t=3, p=1, salt=16 bytes, output=32 bytes。
// PHC 字符串格式: $argon2id$v=19$m=65536,t=3,p=1$<saltB64>$<hashB64>
package crypto

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

const (
	argonTime    uint32 = 3
	argonMemory  uint32 = 64 * 1024 // 64MB
	argonThreads uint8  = 1
	argonKeyLen  uint32 = 32
	argonSaltLen        = 16
)

var (
	// ErrInvalidHash 表示 hash 字符串不是合法 PHC argon2id 格式。
	ErrInvalidHash = errors.New("crypto: invalid argon2id hash format")
	// ErrUnsupportedVersion 表示 argon2 版本不被支持。
	ErrUnsupportedVersion = errors.New("crypto: unsupported argon2 version")
)

// HashPassword 用 argon2id 哈希密码。
func HashPassword(plain string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(plain), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	b64 := base64.RawStdEncoding.EncodeToString
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		b64(salt), b64(key)), nil
}

// VerifyPassword 校验密码与 hash。
//
// 仅支持 argon2id PHC 格式; 任何其他格式直接返回 false (新项目无遗留 hash)。
func VerifyPassword(hash, plain string) bool {
	params, salt, key, err := decodeArgon2id(hash)
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(plain), salt, params.time, params.memory, params.threads, uint32(len(key)))
	return subtle.ConstantTimeCompare(key, got) == 1
}

type argonParams struct {
	memory  uint32
	time    uint32
	threads uint8
}

func decodeArgon2id(s string) (argonParams, []byte, []byte, error) {
	parts := strings.Split(s, "$")
	// 期望: "" "argon2id" "v=19" "m=...,t=...,p=..." "<salt>" "<key>"
	if len(parts) != 6 || parts[1] != "argon2id" {
		return argonParams{}, nil, nil, ErrInvalidHash
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return argonParams{}, nil, nil, ErrInvalidHash
	}
	if version != argon2.Version {
		return argonParams{}, nil, nil, ErrUnsupportedVersion
	}
	var p argonParams
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.memory, &p.time, &p.threads); err != nil {
		return argonParams{}, nil, nil, ErrInvalidHash
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return argonParams{}, nil, nil, ErrInvalidHash
	}
	key, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return argonParams{}, nil, nil, ErrInvalidHash
	}
	return p, salt, key, nil
}
