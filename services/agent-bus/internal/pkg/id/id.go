package id

import (
	"crypto/rand"
	"encoding/hex"

	"github.com/google/uuid"
)

// NewUUID 生成业务对外 UUID。
func NewUUID() string { return uuid.NewString() }

// IsValidUUID 判断字符串是否是合法 UUID (任意 variant/版本)。空串视为非法。
// 用于 transport / service 层入参校验, 避免把"看似 uuid 实则脏字符串"塞进 SQL
// (PG `uuid` 列在 cast 失败时返 22P02 invalid_text_representation, 被 service 层
// Wrap 后会变成 500; 用户感受是"我点一下就 500", 不可接受)。
func IsValidUUID(s string) bool {
	if s == "" {
		return false
	}
	_, err := uuid.Parse(s)
	return err == nil
}

// RandomHex 生成 n 字节随机串，hex 编码。
func RandomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
