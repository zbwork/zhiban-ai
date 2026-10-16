// Package oss is the real cloud object store adapter for M7 Phase A.
//
// 实现 internal/adapter/object.Store 接口, 与 inmem 实现完全独立; 用于:
//   - drive_files: 用户 / agent 上传的云盘文件
//   - 未来可被其它批次借用 (KB v1 / 大文件上传)
//
// 关键决策 (docs/tasks/m7-drive.md §4.1, R6 / R9):
//   - 仅暴露 storage_key 一列承担 OSS 对象定位 (R7); bucket 由调用方配置
//   - 默认 AliYun OSS / AWS S3 / MinIO 通用 (S3 兼容 API + SigV4)
//   - smoke 必须真实 PUT 到 OSS; 缺配置 fail fast
package oss

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
)

// KeyPrefixDrive 生成 drive_files 的 storage_key.
//
// 与 docs/tasks/m7-drive.md §4.1 命名约定一致:
//
//	tenants/{tid}/{S}/drive/{ym}/{uuid}{ext}
//
// 其中:
//   - {tid}  = tenantID (decimal)
//   - {S}    = space scope 标识, personal 空间使用 "accounts/{aid}"; workspace / tenant 空间留 Phase B
//   - {ym}   = "YYYY/MM"
//   - {uuid} = 16-byte hex (32 chars)
//   - {ext}  = "." + sanitized lowercase extension or empty
//
// fileName 用于推导扩展名; 不会进 key 路径 (避免 path-injection).
func KeyPrefixDrive(tenantID, ownerAccountID int64, fileName string, now time.Time) (string, error) {
	if tenantID <= 0 {
		return "", errors.New("oss.KeyPrefixDrive: tenantID required")
	}
	if ownerAccountID <= 0 {
		return "", errors.New("oss.KeyPrefixDrive: ownerAccountID required")
	}
	hex, err := id.RandomHex(16)
	if err != nil {
		return "", err
	}
	now = now.UTC()
	ext := normalizeExt(fileName)
	return fmt.Sprintf("tenants/%d/accounts/%d/drive/%04d/%02d/%s%s",
		tenantID, ownerAccountID, now.Year(), int(now.Month()), hex, ext), nil
}

// KeyAgentOutput 生成 agent 写 de_outputs 的 storage_key.
//
//	tenants/{tid}/accounts/{aid}/de_outputs/{agent_uuid}/{ym}/{uuid}{ext}
//
// agentUUID 必填; 失败返错.
func KeyAgentOutput(tenantID, ownerAccountID int64, agentUUID, fileName string, now time.Time) (string, error) {
	if tenantID <= 0 {
		return "", errors.New("oss.KeyAgentOutput: tenantID required")
	}
	if ownerAccountID <= 0 {
		return "", errors.New("oss.KeyAgentOutput: ownerAccountID required")
	}
	if strings.TrimSpace(agentUUID) == "" {
		return "", errors.New("oss.KeyAgentOutput: agentUUID required")
	}
	hex, err := id.RandomHex(16)
	if err != nil {
		return "", err
	}
	now = now.UTC()
	ext := normalizeExt(fileName)
	return fmt.Sprintf("tenants/%d/accounts/%d/de_outputs/%s/%04d/%02d/%s%s",
		tenantID, ownerAccountID, agentUUID, now.Year(), int(now.Month()), hex, ext), nil
}

// normalizeExt 提取小写扩展名 (含前导 .); 无扩展返 "".
//
// 防御性: 限长 16 chars 防对抗性 fileName 撑 key 长度.
func normalizeExt(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	base := filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	ext := strings.ToLower(filepath.Ext(base))
	if ext == "" || ext == "." {
		return ""
	}
	if len(ext) > 16 {
		ext = ext[:16]
	}
	for _, r := range ext[1:] {
		if !isAllowedExtRune(r) {
			return ""
		}
	}
	return ext
}

func isAllowedExtRune(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z':
		return true
	case r >= '0' && r <= '9':
		return true
	case r == '_':
		return true
	}
	return false
}
