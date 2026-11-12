package admincore

import (
	"encoding/json"
	"testing"
	"time"

	domemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
)

// TestEMPBlockDTOMarshalsSnakeCase 锁死 EMP 响应形状为 snake_case。
// 回归 QA-2026-07-02 BUG-1: 之前直接序列化领域对象 empblock.Block（无 json tag）
// 输出 PascalCase，导致 admin web EMPBlockList 读 code/name/category 全 undefined，整页渲染坏。
func TestEMPBlockDTOMarshalsSnakeCase(t *testing.T) {
	b := &domemp.Block{
		ID:                16,
		Code:              "artifact",
		Version:           1,
		Name:              "产物",
		Category:          "artifact",
		JSONSchema:        map[string]any{"type": "object"},
		Status:            "stable",
		MinClientVersion:  "0.1.0",
		FallbackBlockType: "markdown",
		Description:       "可下载的产物",
		IsSystem:          true,
	}
	raw, err := json.Marshal(newEMPBlockDTO(b))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	// 必须是 snake_case 键；出现任一 PascalCase 键即视为回归。
	wantKeys := []string{"id", "code", "version", "name", "category", "json_schema", "status", "min_client_version", "fallback_block_type"}
	for _, k := range wantKeys {
		if _, ok := m[k]; !ok {
			t.Errorf("expected snake_case key %q in EMP DTO json, got keys %v", k, keysOf(m))
		}
	}
	for _, bad := range []string{"Code", "Name", "Category", "Version", "JSONSchema", "MinClientVersion"} {
		if _, ok := m[bad]; ok {
			t.Errorf("PascalCase key %q must not appear (BUG-1 regression)", bad)
		}
	}
	if m["code"] != "artifact" || m["name"] != "产物" || m["category"] != "artifact" {
		t.Errorf("field values mismatch: %v", m)
	}
}

// TestEMPBlockDTONilAndList 保证 nil 安全 + 列表返回非 nil 空切片（JSON [] 而非 null）。
func TestEMPBlockDTONilAndList(t *testing.T) {
	if newEMPBlockDTO(nil) != nil {
		t.Errorf("nil block should map to nil DTO")
	}
	dtos := newEMPBlockDTOs(nil)
	if dtos == nil {
		t.Errorf("nil slice should map to non-nil empty slice for JSON []")
	}
	if len(dtos) != 0 {
		t.Errorf("expected empty slice, got len %d", len(dtos))
	}
	one := newEMPBlockDTOs([]domemp.Block{{ID: 1, Code: "text", UpdatedAt: time.Now()}})
	if len(one) != 1 || one[0].Code != "text" {
		t.Errorf("list mapper mismatch: %+v", one)
	}
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
