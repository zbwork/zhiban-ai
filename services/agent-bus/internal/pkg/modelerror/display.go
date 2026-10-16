// Package modelerror defines safe public model failure messages shared by HTTP and chat.
package modelerror

import (
	"fmt"
	"regexp"
	"strconv"
)

var messages = map[string]string{
	"model.refused":                   "模型拒绝了本次请求，请调整内容或切换模型",
	"model.empty_response":            "模型未返回有效内容，请重试或切换模型",
	"model.response_incomplete":       "模型响应未完整结束，请重试",
	"model.response_failed":           "模型平台返回失败，请重试或切换模型",
	"model.messages_required":         "模型请求缺少 messages 字段",
	"model.request_invalid":           "模型请求格式错误",
	"model.context_limit":             "对话内容超出模型上下文长度限制",
	"model.token_limit":               "模型输出长度参数不受支持",
	"model.temperature_invalid":       "模型温度参数不受支持",
	"model.tools_invalid":             "模型工具调用参数不兼容",
	"model.upstream_quota":            "模型平台账户额度不足，请检查模型平台余额",
	"model.authentication_failed":     "模型平台鉴权失败，请检查模型凭据或权限",
	"model.unavailable":               "当前模型在模型平台不可用，请切换模型",
	"model.rate_limited":              "模型平台请求过于频繁，请稍后重试",
	"model.timeout":                   "模型平台响应超时，请稍后重试",
	"model.connection_failed":         "模型平台连接失败，请稍后重试",
	"model.upstream_failure":          "模型平台处理请求失败，请稍后重试",
	"billing.model_access_recovering": "积分已到账，正在恢复模型使用权限，请稍后重试",
	"billing.insufficient_credits":    "积分不足，请先购买积分包或升级套餐后再试",
}

// Message never includes vendor text. A zero status means no upstream HTTP response.
func Message(code string, status int) string {
	base, ok := messages[code]
	if !ok {
		return ""
	}
	if status >= 400 && status <= 599 && code != "billing.insufficient_credits" && code != "billing.model_access_recovering" {
		return fmt.Sprintf("%s（HTTP %d）。", base, status)
	}
	return base + "。"
}

var statusSuffix = regexp.MustCompile(`（HTTP ([45][0-9]{2})）。$`)

// Sanitize accepts only the exact fixed message with an optional bounded status.
// Unknown details are discarded, even for an otherwise recognized code.
func Sanitize(code, detail string) string {
	if match := statusSuffix.FindStringSubmatch(detail); match != nil {
		status, _ := strconv.Atoi(match[1])
		if Message(code, status) == detail {
			return detail
		}
	}
	return Message(code, 0)
}
