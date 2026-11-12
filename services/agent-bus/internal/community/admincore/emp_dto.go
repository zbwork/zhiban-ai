// emp_dto.go — EMP block registry admin response DTO + mapper.
//
// 领域对象 empblock.Block 不带 json tag（保持领域层干净，不为传输命名污染）。
// admin 端所有 EMP 响应端点（list / get / create / update）统一经此 DTO 序列化，
// 输出 snake_case 字段，与 admin web EMPBlockList 页面读取的字段名一致。
package admincore

import (
	"time"

	domemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
)

// empBlockDTO 是 emp_block_registry 单行的对外形状（snake_case）。
type empBlockDTO struct {
	ID                int64          `json:"id"`
	Code              string         `json:"code"`
	Version           int            `json:"version"`
	Name              string         `json:"name"`
	Category          string         `json:"category"`
	JSONSchema        map[string]any `json:"json_schema"`
	Status            string         `json:"status"`
	MinClientVersion  string         `json:"min_client_version"`
	FallbackBlockType string         `json:"fallback_block_type"`
	BreakingChanges   string         `json:"breaking_changes"`
	DeprecatedAt      *time.Time     `json:"deprecated_at,omitempty"`
	EOLDate           *time.Time     `json:"eol_date,omitempty"`
	Description       string         `json:"description"`
	IsSystem          bool           `json:"is_system"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
}

// newEMPBlockDTO 把领域 Block 映射为对外 DTO；b 为 nil 时返回 nil。
func newEMPBlockDTO(b *domemp.Block) *empBlockDTO {
	if b == nil {
		return nil
	}
	return &empBlockDTO{
		ID:                b.ID,
		Code:              b.Code,
		Version:           b.Version,
		Name:              b.Name,
		Category:          b.Category,
		JSONSchema:        b.JSONSchema,
		Status:            b.Status,
		MinClientVersion:  b.MinClientVersion,
		FallbackBlockType: b.FallbackBlockType,
		BreakingChanges:   b.BreakingChanges,
		DeprecatedAt:      b.DeprecatedAt,
		EOLDate:           b.EOLDate,
		Description:       b.Description,
		IsSystem:          b.IsSystem,
		CreatedAt:         b.CreatedAt,
		UpdatedAt:         b.UpdatedAt,
	}
}

// newEMPBlockDTOs 映射列表；nil / 空切片都返回非 nil 空切片，保证 JSON 输出 [] 而非 null。
func newEMPBlockDTOs(items []domemp.Block) []empBlockDTO {
	out := make([]empBlockDTO, 0, len(items))
	for i := range items {
		out = append(out, *newEMPBlockDTO(&items[i]))
	}
	return out
}
