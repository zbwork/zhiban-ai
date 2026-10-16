package messageblocks

import (
	"fmt"
	"strings"
)

// ReadableText returns a best-effort plain text summary for EMP blocks.
//
// It is a server-side fallback for IM substrates, list previews, and old
// clients. The structured blocks remain the source of truth.
func ReadableText(blocks []map[string]any) string {
	if len(blocks) == 0 {
		return ""
	}
	parts := make([]string, 0, len(blocks))
	for _, block := range blocks {
		if text := readableOne(block); strings.TrimSpace(text) != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

func readableOne(block map[string]any) string {
	if len(block) == 0 {
		return ""
	}
	// A2A / 工具执行过程块只用于「已调用工具」时间线展示，不进入 readable text 正文、
	// 会话列表 preview 或 IM substrate。x_source="a2a_timeline" 覆盖被打上该来源的任意块
	// （含 tool_call / tool_result / markdown）。x_source="a2a_approval" 是结构化审批 EMP，
	// 交给客户端 EMP renderer，不在此过滤（其 type 走各自 case，不会命中这里）。
	if strings.EqualFold(asString(block["x_source"]), "a2a_timeline") {
		return ""
	}
	t := strings.ToLower(strings.TrimSpace(asString(block["type"])))
	switch t {
	case "", "markdown", "plain", "text":
		return firstNonEmpty(asString(block["text"]), asString(block["markdown"]), asString(block["content"]))
	case "code":
		text := firstNonEmpty(asString(block["text"]), asString(block["source"]), asString(block["content"]))
		if text == "" {
			return "[代码]"
		}
		lang := firstNonEmpty(asString(block["language"]), asString(block["lang"]))
		return "```" + lang + "\n" + text + "\n```"
	case "table":
		base := "[表格]"
		if title := asString(block["title"]); title != "" {
			base += " " + title
		}
		if rows, ok := block["rows"].([]any); ok {
			return fmt.Sprintf("%s · %d 行", base, len(rows))
		}
		return base
	case "plan":
		base := "[计划]"
		if title := asString(block["title"]); title != "" {
			base += " " + title
		}
		if steps, ok := firstList(block["steps"], block["items"]); ok {
			return fmt.Sprintf("%s · %d 步", base, len(steps))
		}
		return base
	case "tool_result":
		// 工具执行结果不进入 readable text 正文/会话预览（与 tool_call 一致）。
		// 结构化过程由「已调用工具」时间线承载；最终回复只应是 runtime 产出的
		// markdown/plain 块。避免出现 "[工具结果] 法务顾问" 污染正文与会话摘要。
		return ""
	case "error":
		if msg := firstNonEmpty(asString(block["message"]), asString(block["text"])); msg != "" {
			return "[错误] " + msg
		}
		return "[错误]"
	case "progress":
		base := "[进度]"
		if label := firstNonEmpty(asString(block["label"]), asString(block["title"])); label != "" {
			base += " " + label
		}
		return base
	case "approval", "approval_request":
		if title := firstNonEmpty(asString(block["title"]), asString(block["prompt"])); title != "" {
			return "[审批] " + title + " · 需在客户端最新版查看完整组件"
		}
		return "[审批] · 需在客户端最新版查看完整组件"
	case "confirm":
		if title := firstNonEmpty(asString(block["title"]), asString(block["prompt"])); title != "" {
			return "[确认] " + title + " · 需在客户端最新版查看完整组件"
		}
		return "[确认] · 需在客户端最新版查看完整组件"
	case "form":
		if title := asString(block["title"]); title != "" {
			return "[表单] " + title + " · 需在客户端最新版查看完整组件"
		}
		return "[表单] · 需在客户端最新版查看完整组件"
	case "action", "action_bar":
		if title := asString(block["title"]); title != "" {
			return "[操作栏] " + title
		}
		return "[操作栏]"
	case "source", "citation":
		if title := firstNonEmpty(asString(block["title"]), asString(block["name"])); title != "" {
			return "[来源] " + title
		}
		if url := asString(block["url"]); url != "" {
			return "[来源] " + url
		}
		return "[来源]"
	case "artifact":
		name := firstNonEmpty(asString(block["name"]), asString(block["title"]), asString(block["filename"]))
		if name == "" {
			name = "附件"
		}
		if kind := firstNonEmpty(asString(block["artifact_kind"]), asString(block["kind"])); kind != "" {
			return "[附件 · " + kind + "] " + name
		}
		return "[附件] " + name
	case "chart":
		if title := asString(block["title"]); title != "" {
			return "[图表] " + title
		}
		return "[图表]"
	case "app_card":
		if title := firstNonEmpty(asString(block["title"]), asString(block["name"])); title != "" {
			return "[卡片] " + title
		}
		return "[卡片]"
	case "tool_call":
		return ""
	default:
		if title := asString(block["title"]); title != "" {
			return "[" + t + "] " + title
		}
		return "[" + t + "]"
	}
}

func asString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(x)
	case fmt.Stringer:
		return strings.TrimSpace(x.String())
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64, bool:
		return strings.TrimSpace(fmt.Sprint(x))
	default:
		return ""
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func firstList(values ...any) ([]any, bool) {
	for _, v := range values {
		if xs, ok := v.([]any); ok {
			return xs, true
		}
	}
	return nil, false
}
