// secret_resolver.go — 解 env:// / value:// secret_ref (Phase B sprint).
package storage

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// ErrSecretSchemeNotAllowed secret_ref 协议不在白名单.
var ErrSecretSchemeNotAllowed = errors.New("storage: secret_ref scheme not allowed")

// SecretResolver 把 ref 解成明文值.
//
// 接受协议:
//   - env://VARNAME  → os.Getenv("VARNAME")
//   - value://plaintext → plaintext (由 caller 的 AllowValue 策略决定是否接受)
//
// 设计:
//   - ref 不应日志输出明文; caller 拿到值仅在 oss client 构造时一次性使用.
//   - 解空字符串视为错误 (避免静默退化为空 AK).
type SecretResolver struct {
	AllowValue bool // caller policy；Drive 按 ADR-0034 在所有环境允许
}

// Resolve 解一个 secret_ref.
func (r SecretResolver) Resolve(ref string) (string, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return "", errors.New("storage: empty secret_ref")
	}
	switch {
	case strings.HasPrefix(ref, "env://"):
		name := strings.TrimPrefix(ref, "env://")
		v := os.Getenv(name)
		if v == "" {
			return "", fmt.Errorf("storage: env %s not set", name)
		}
		return v, nil
	case strings.HasPrefix(ref, "value://"):
		if !r.AllowValue {
			return "", ErrSecretSchemeNotAllowed
		}
		return strings.TrimPrefix(ref, "value://"), nil
	default:
		return "", fmt.Errorf("storage: unsupported secret_ref scheme %q", ref)
	}
}

// ValidateRef 仅做协议校验, 不解值 (admin 写入前用).
func ValidateRef(ref string, allowValue bool) error {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return errors.New("secret_ref required")
	}
	switch {
	case strings.HasPrefix(ref, "env://"):
		return nil
	case strings.HasPrefix(ref, "value://"):
		if !allowValue {
			return ErrSecretSchemeNotAllowed
		}
		return nil
	default:
		return fmt.Errorf("unsupported scheme %q (must start with env:// or value://)", ref)
	}
}
