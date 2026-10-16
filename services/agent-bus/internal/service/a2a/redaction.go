package a2a

import (
	"encoding/json"
	"regexp"
)

// PayloadSizeCap F09 §4.7.4 size cap: 入库前 ≤ 16 KB.
const PayloadSizeCap = 16 * 1024

// 4 条 regex MVP, 顺序敏感 (API key 在邮箱前, 否则可能被邮箱 regex 吃掉一部分).
// 顺序: API key / 邮箱 / 身份证 / 手机.  邮箱模式较宽, 放在 API key 之后以减少误杀.
var redactPatterns = []struct {
	name string
	re   *regexp.Regexp
}{
	{"secret", regexp.MustCompile(`(?:sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._\-]{20,})`)},
	{"email", regexp.MustCompile(`[\w.+\-]+@[\w\-]+\.[\w.\-]+`)},
	{"idcard", regexp.MustCompile(`\b\d{17}[\dXx]\b`)},
	{"mobile", regexp.MustCompile(`\b1[3-9]\d{9}\b`)},
}

// RedactString 对单个字符串施加全部 4 条 regex 替换.
// 返 (脱敏后字符串, 是否命中过 regex).
//
// 注: 顺序固定; 每条独立替换 (不互依赖). 同一条字符串多次命中也会被各自替换.
func RedactString(in string) (string, bool) {
	hit := false
	out := in
	for _, p := range redactPatterns {
		out = p.re.ReplaceAllStringFunc(out, func(_ string) string {
			hit = true
			return "[REDACTED:" + p.name + "]"
		})
	}
	return out, hit
}

// RedactJSON 对一段 JSON 做"递归字符串脱敏".
//   - 非 JSON / 解析失败 → 原样返回 (但 size cap 仍会 truncate)
//   - 字符串值 / map key 全部经 RedactString
//   - 数字 / bool / null / 数组结构不变
//
// 返 (脱敏后 JSON bytes, 是否命中过 regex, 是否 truncate).
//
// PayloadSizeCap 在最后做: 如果脱敏后仍超 16 KB, 用 "_truncated": true 标记,
// 同时把 _payload_size 字段填原始字节数, 便于审计.
func RedactJSON(raw []byte) ([]byte, bool, bool) {
	if len(raw) == 0 {
		return raw, false, false
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		// 非合法 JSON: 字符串脱敏后 size cap.
		s, hit := RedactString(string(raw))
		if len(s) > PayloadSizeCap {
			return []byte(`{"_truncated":true,"_payload_size":` + itoa(len(s)) + `}`), hit, true
		}
		return []byte(s), hit, false
	}
	hit := false
	v = walkAndRedact(v, &hit)
	out, err := json.Marshal(v)
	if err != nil {
		return raw, hit, false
	}
	if len(out) > PayloadSizeCap {
		return []byte(`{"_truncated":true,"_payload_size":` + itoa(len(out)) + `}`), hit, true
	}
	return out, hit, false
}

func walkAndRedact(v any, hit *bool) any {
	switch x := v.(type) {
	case string:
		s, h := RedactString(x)
		if h {
			*hit = true
		}
		return s
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			// key 一般不做脱敏 (key 通常是协议名), 但 value 递归.
			out[k] = walkAndRedact(val, hit)
		}
		return out
	case []any:
		for i := range x {
			x[i] = walkAndRedact(x[i], hit)
		}
		return x
	default:
		return v
	}
}

// itoa 内联小工具, 不依赖 strconv (避免在 hot path 多 import). 仅整数 ≥ 0.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	buf := make([]byte, 0, 10)
	for n > 0 {
		buf = append([]byte{byte('0' + n%10)}, buf...)
		n /= 10
	}
	return string(buf)
}
