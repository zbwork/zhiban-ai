// client_secret.go — OAuth2 client_id / client_secret 生成 + 哈希 + 常时间比对。
//
// 字符串格式 (F04 §2.2 + standards/oauth2-grant-naming-and-token-format.md §2):
//
//	client_id     = "<prefix>_" + 32 base62   (例 "app_K3xJ7p2QvN8mR4tY6bL9wD5cF1aZxxx")
//	client_secret = "sk_" + 48 base62          (例 "sk_8jH4kL7mN9pQ2rS5tU3vW6xY1zA4bC7dE0fG3hJ6")
//
// secret 入库前一律走 HashSecret → sha256(明文) hex; 明文仅在颁发那一刻一次性返回。
// 校验走 VerifySecret(明文, 入库 hash) — subtle.ConstantTimeCompare 防时序攻击。
//
// 跟 agentsdk.genClientCredentials 共用同一套实现; 后续把 agentsdk 那边也切到本包。
package oauth2

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"strings"
)

const (
	// ClientIDRandBytes client_id 随机部分长度 (字节); base62 编码到 32 字符。
	ClientIDRandBytes = 24
	// ClientIDEncodedLen 编码后 client_id 随机部分长度 (base62 字符)。
	ClientIDEncodedLen = 32
	// ClientSecretBytes client_secret 随机部分长度 (字节); base62 编码到 48 字符。
	ClientSecretBytes = 36
	// ClientSecretEncodedLen 编码后 client_secret 长度 (base62 字符, 不含 "sk_" 前缀)。
	ClientSecretEncodedLen = 48

	// SecretPrefix client_secret 统一前缀。
	SecretPrefix = "sk_"
)

// GenClientID 生成 "<prefix>_<32 base62>" 形式的 client_id。
//
// prefix 例: "app" (F04 应用) / "agentsdk" (F01 自定义 Agent)。返值含 prefix + 下划线 + 随机段。
func GenClientID(prefix string) (string, error) {
	if prefix == "" {
		return "", fmt.Errorf("oauth2: GenClientID: prefix required")
	}
	var buf [ClientIDRandBytes]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", fmt.Errorf("oauth2: GenClientID: rand: %w", err)
	}
	return prefix + "_" + base62Encode(buf[:], ClientIDEncodedLen), nil
}

// GenSecret 生成 "sk_<48 base62>" 形式的 client_secret 明文。
//
// 返值仅在颁发那一刻显示给用户; 服务端只存 HashSecret 后的 hash。
func GenSecret() (string, error) {
	var buf [ClientSecretBytes]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", fmt.Errorf("oauth2: GenSecret: rand: %w", err)
	}
	return SecretPrefix + base62Encode(buf[:], ClientSecretEncodedLen), nil
}

// GenRandomCode 生成给定长度的 base62 字符串 (无前缀); 给一次性 code (authorization_code) 用。
//
// 上层例: code = "ac_" + GenRandomCode(32); DB 存 sha256(code)。
func GenRandomCode(length int) (string, error) {
	if length <= 0 {
		return "", fmt.Errorf("oauth2: GenRandomCode: length must be > 0")
	}
	// 24 字节熵足够 32+ base62; 大于 32 字符时增量加字节
	byteLen := length * 3 / 4
	if byteLen < 24 {
		byteLen = 24
	}
	buf := make([]byte, byteLen)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("oauth2: GenRandomCode: rand: %w", err)
	}
	return base62Encode(buf, length), nil
}

// HashSecret 把明文 secret 哈希成 sha256 hex (64 字符), 用于 DB 入库 + 校验。
//
// 跟 agentsdk.hashSecret / api_keys.key_hash 同款算法; 跨 OAuth 用例统一。
func HashSecret(plaintext string) string {
	h := sha256.Sum256([]byte(plaintext))
	return hex.EncodeToString(h[:])
}

// VerifySecret 比对 "用户给的明文 secret" 跟 "DB 里存的 hash" 是否一致。
//
// 使用 subtle.ConstantTimeCompare 防时序攻击 — 即便长度相同, 也不能用 == 比, 因为 == 在 Go
// 里短路比较 (前面字符不等就立刻返回), 攻击者可以测时间逐位枚举。
//
// plaintext 为空 → 返 false (防 nil-equals-nil 通过)。
func VerifySecret(plaintext, storedHash string) bool {
	if plaintext == "" || storedHash == "" {
		return false
	}
	want, err := hex.DecodeString(storedHash)
	if err != nil {
		return false
	}
	got := sha256.Sum256([]byte(plaintext))
	return subtle.ConstantTimeCompare(got[:], want) == 1
}

// HasClientIDPrefix 判断 token 字符串是否是某个 client_id (例 "app_" 开头)。
//
// 给中间件分发用 — 拿到一个 token, 不知是 client_id 还是别的 (eg session_token), 用这个判断。
func HasClientIDPrefix(token, prefix string) bool {
	return strings.HasPrefix(token, prefix+"_")
}

const b62Alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// base62Encode 把字节切片编码成定长 base62 字符串。
//
// 跟 agentsdk.base62Encode 实现一致 — outLen 由 caller 指定,
// 上层 GenClientID/GenSecret 用常量 ClientIDEncodedLen / ClientSecretEncodedLen 调用。
//
// 算法: 把 in 看作大整数, 反复除以 62 取余, 余数映射到字母表。
// 不够 outLen 个字符高位补 '0'; 超过则截断 (调用方应保证字节够长)。
func base62Encode(in []byte, outLen int) string {
	work := append([]byte(nil), in...)
	result := make([]byte, outLen)
	for i := outLen - 1; i >= 0; i-- {
		var rem int
		for j := 0; j < len(work); j++ {
			cur := rem*256 + int(work[j])
			work[j] = byte(cur / 62)
			rem = cur % 62
		}
		result[i] = b62Alphabet[rem]
	}
	return string(result)
}
