// prompt_template.go · F08 §8.2 #4 / R9.
//
// 范围:
//   - validatePromptTemplateVariables: 按模板变量 schema 校验 caller 传的 variables map.
//   - renderPromptTemplate: 把模板 body 里的 {{var_name}} 替换成 variables 提供 (或 default_value) 的值.
//
// 不变量:
//   - validate 失败 → 返 apperr (apperr.InvalidParams) + ErrCodeCronTemplateVar*; render **不**做类型校验.
//   - render 不修改 template / vars 原对象.
//   - render 算法只支持 "{{var_name}}" 直接变量标记 (无表达式 / 过滤器).
package cron

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// validatePromptTemplateVariables · F08 R9 · 按模板的 variable schema 校验 caller 提交的 vars 值.
//
// 行为:
//   - var.Required=true 且 vars 缺 + DefaultValue 也空 → cron.prompt_template_variable_missing.
//   - vars 提供的值类型与 var.VarType 不匹配 → cron.prompt_template_variable_type_mismatch.
//   - vars 多带的 key (模板没声明的) → 静默忽略 (向后兼容; 模板若加变量, 旧 cron 不会立即变非法).
//
// 设计:
//   - 纯函数, 不依赖 DB / 网络, 单测覆盖各 var_type.
func validatePromptTemplateVariables(vars map[string]any, varDefs []domcron.PromptTemplateVariable) error {
	for i := range varDefs {
		v := &varDefs[i]
		raw, present := vars[v.VarName]
		if !present {
			if v.Required && isNilOrEmpty(v.DefaultValue) {
				return apperr.New(apperr.InvalidParams, ErrCodeCronTemplateVarMissing).
					Withf("required variable %q missing", v.VarName)
			}
			continue
		}
		if raw == nil {
			if v.Required {
				return apperr.New(apperr.InvalidParams, ErrCodeCronTemplateVarMissing).
					Withf("required variable %q is null", v.VarName)
			}
			continue
		}
		if !isVarValueValid(v.VarType, v.Options, raw) {
			return apperr.New(apperr.InvalidParams, ErrCodeCronTemplateVarTypeBad).
				Withf("variable %q value does not match type %q", v.VarName, v.VarType)
		}
	}
	return nil
}

// isVarValueValid · 单值是否匹配指定 var_type (与 F08 §4.7 type_matches 表对齐).
func isVarValueValid(varType string, options []any, v any) bool {
	switch varType {
	case domcron.VarTypeString:
		_, ok := v.(string)
		return ok
	case domcron.VarTypeEnum:
		// enum 必须是 string 且 ∈ options.
		s, ok := v.(string)
		if !ok {
			return false
		}
		if len(options) == 0 {
			// 没声明 options → 任意 string 都接受 (向后兼容; 模板可后补).
			return true
		}
		for _, opt := range options {
			if optStr, ok := opt.(string); ok && optStr == s {
				return true
			}
			// 兼容 enum option 是 {"value": "...", "label": "..."} 形态.
			if m, ok := opt.(map[string]any); ok {
				if val, _ := m["value"].(string); val == s {
					return true
				}
			}
		}
		return false
	case domcron.VarTypeInt:
		// JSON 反序列化 number → float64 (jackc/pgx JSONB 也可能是 int64); 都接受.
		switch n := v.(type) {
		case int, int32, int64:
			return true
		case float64:
			return n == float64(int64(n)) // 必须是整数
		case float32:
			return float64(n) == float64(int64(n))
		case string:
			_, err := strconv.ParseInt(n, 10, 64)
			return err == nil
		}
		return false
	case domcron.VarTypeDateTime:
		// 接受 RFC3339 string 或关键字 today / yesterday / last_week.
		s, ok := v.(string)
		if !ok {
			return false
		}
		switch strings.ToLower(s) {
		case "today", "yesterday", "last_week", "this_week", "this_month":
			return true
		}
		if _, err := time.Parse(time.RFC3339, s); err == nil {
			return true
		}
		// 兼容 "YYYY-MM-DD".
		if _, err := time.Parse("2006-01-02", s); err == nil {
			return true
		}
		return false
	case domcron.VarTypeList:
		_, ok := v.([]any)
		return ok
	}
	// 未知类型 → 拒.
	return false
}

func isNilOrEmpty(v any) bool {
	if v == nil {
		return true
	}
	if s, ok := v.(string); ok {
		return strings.TrimSpace(s) == ""
	}
	if arr, ok := v.([]any); ok {
		return len(arr) == 0
	}
	if m, ok := v.(map[string]any); ok {
		return len(m) == 0
	}
	return false
}

// renderPromptTemplate · F08 R9 · 把 body 里的 {{var_name}} 替换为 vars 提供的值 (或 default_value).
//
// 算法:
//  1. 复制 body 到 out.
//  2. 遍历 varDefs (按 OrderIndex 不影响; 直接遍历; 替换互不依赖).
//  3. 每个 var: 取 vars[name] 或 fallback DefaultValue; 转 string; 替换 "{{name}}".
//
// 边界:
//   - body 里没有 "{{name}}" 变量标记 → 该变量没用上, 不报错.
//   - vars 缺 + DefaultValue 也空 → 替换成 "" (validate 早已拦掉 required, 这里不会到; 防御).
//   - List / int / datetime 等非 string 值 → 用 Sprintf("%v"); list 转 "[a, b, c]" 风格.
func renderPromptTemplate(body string, vars map[string]any, varDefs []domcron.PromptTemplateVariable) string {
	out := body
	for i := range varDefs {
		v := &varDefs[i]
		raw, ok := vars[v.VarName]
		if !ok || raw == nil {
			raw = v.DefaultValue
		}
		out = strings.ReplaceAll(out, "{{"+v.VarName+"}}", stringifyVar(raw))
	}
	return out
}

func stringifyVar(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "true"
		}
		return "false"
	case int:
		return strconv.Itoa(x)
	case int32:
		return strconv.FormatInt(int64(x), 10)
	case int64:
		return strconv.FormatInt(x, 10)
	case float32:
		return strconv.FormatFloat(float64(x), 'f', -1, 32)
	case float64:
		// JSON number; 优先去尾 0 (-1 精度).
		return strconv.FormatFloat(x, 'f', -1, 64)
	case []any:
		parts := make([]string, 0, len(x))
		for _, item := range x {
			parts = append(parts, stringifyVar(item))
		}
		return "[" + strings.Join(parts, ", ") + "]"
	default:
		return fmt.Sprintf("%v", v)
	}
}
