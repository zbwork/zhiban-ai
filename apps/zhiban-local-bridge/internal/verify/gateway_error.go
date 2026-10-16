package verify

// The gateway's own answer to a failed L3 probe (contract §2.7 verify.execute
// error_detail, 2026-09-15). Both CLIs print the HTTP status and the body the
// relay sent; keeping only a keyword-derived code turned "503 upstream
// overloaded" into "网关或工具响应不一致 / 无法连接, 一键修复", which nobody could
// act on. The status now drives the code and the relay's message, redacted and
// capped, travels with the failure into 诊断详情.
//
// Observed formats (Codex 0.154.0, Claude Code 2.1.272, against a real and a
// fake relay):
//
//	Codex:  ERROR: unexpected status 503 Service Unavailable: <message>, url: https://…/v1/responses
//	        ERROR: exceeded retry limit, last status: 429 Too Many Requests
//	Claude: {"is_error":true,"api_error_status":503,"result":"API Error: 503 <message>. This is a server-side issue…"}

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const gatewayDetailMaxRunes = 300

var (
	codexUnexpectedStatus = regexp.MustCompile(`unexpected status (\d{3})(?: [A-Za-z' -]+)?(?:: (.*?))?(?:, url: \S+)?\s*$`)
	codexRetryLimit       = regexp.MustCompile(`last status: (\d{3})(?: ([A-Za-z' -]+))?`)

	redactBearer    = regexp.MustCompile(`(?i)bearer\s+\S+`)
	redactSecretKey = regexp.MustCompile(`\bsk-[A-Za-z0-9_\-]{6,}`)
	redactLongToken = regexp.MustCompile(`[A-Za-z0-9_\-+/=]{40,}`)

	// Word-bounded status numbers for output nobody parsed into a status (a
	// bare substring match also hit digits inside session ids).
	fallbackUnauthorized = regexp.MustCompile(`\b401\b`)
	fallbackTooMany      = regexp.MustCompile(`\b429\b`)
)

// gatewayError is the HTTP answer a CLI reported for the probe request.
type gatewayError struct {
	Status  int
	Message string
}

// parseGatewayError finds the last HTTP error a CLI printed; ok is false when
// the output carries none (network failure, crash, unknown format).
func parseGatewayError(targetID string, output []byte) (gatewayError, bool) {
	if targetID == TargetClaudeCLI {
		return parseClaudeGatewayError(output)
	}
	return parseCodexGatewayError(output)
}

func parseCodexGatewayError(output []byte) (gatewayError, bool) {
	lines := strings.Split(string(output), "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSpace(lines[index])
		if match := codexUnexpectedStatus.FindStringSubmatch(line); match != nil {
			status, _ := strconv.Atoi(match[1])
			return gatewayError{Status: status, Message: match[2]}, true
		}
		if match := codexRetryLimit.FindStringSubmatch(line); match != nil && strings.Contains(line, "retry limit") {
			status, _ := strconv.Atoi(match[1])
			return gatewayError{Status: status, Message: strings.TrimSpace(match[2])}, true
		}
	}
	return gatewayError{}, false
}

func parseClaudeGatewayError(output []byte) (gatewayError, bool) {
	lines := strings.Split(string(output), "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSpace(lines[index])
		if !strings.HasPrefix(line, "{") || !strings.Contains(line, `"api_error_status"`) {
			continue
		}
		var result struct {
			Status *int   `json:"api_error_status"`
			Result string `json:"result"`
		}
		if json.Unmarshal([]byte(line), &result) != nil || result.Status == nil || *result.Status < 400 || *result.Status > 599 {
			continue
		}
		message := strings.TrimSpace(result.Result)
		// "API Error: 503 <message>" / "Failed to authenticate. API Error: 401 <message>"
		if at := strings.Index(message, "API Error: "); at >= 0 {
			message = strings.TrimSpace(message[at+len("API Error: "):])
			message = strings.TrimSpace(strings.TrimPrefix(message, strconv.Itoa(*result.Status)))
		}
		// Claude Code appends its own advice after the relay's message.
		if at := strings.Index(message, ". This is a server-side issue"); at >= 0 {
			message = message[:at+1]
		}
		return gatewayError{Status: *result.Status, Message: message}, true
	}
	return gatewayError{}, false
}

// classifyGatewayError maps the relay's HTTP answer to a contract code.
func classifyGatewayError(targetID string, answer gatewayError) string {
	message := strings.ToLower(answer.Message)
	if containsAny(message, "model_not_found", "model not found", "no available channel", "无可用渠道", "does not exist",
		"unsupported model", "model is not supported", "invalid model") {
		return code(targetID, "GATEWAY", "MODEL_DENIED")
	}
	switch {
	case answer.Status == 401 || answer.Status == 403:
		return code(targetID, "AUTH", "TOKEN_EXPIRED")
	case answer.Status == 429:
		return code(targetID, "GATEWAY", "QUOTA_EXHAUSTED")
	case answer.Status >= 500:
		return code(targetID, "GATEWAY", "UPSTREAM_UNAVAILABLE")
	default:
		return code(targetID, "GATEWAY", "PROTOCOL_MISMATCH")
	}
}

// outputDetail renders a CLI probe's own output for error_detail when the
// relay never answered: without it a tool that refuses to start (an option it
// does not know, a missing runtime) only ever shows PROTOCOL_MISMATCH and the
// cause is invisible to the user and to support (2026-09-16: two testers whose
// Claude Code had no --permission-prompts).
func outputDetail(output []byte) string {
	return sanitizeDetail(string(output))
}

// probeOutputDetail prefers the sentence Claude Code put in its JSON result
// ("API Error: Connection refused — a firewall or proxy may be blocking it")
// over the raw JSON around it.
func probeOutputDetail(targetID string, output []byte) string {
	if targetID == TargetClaudeCLI {
		lines := strings.Split(string(output), "\n")
		for index := len(lines) - 1; index >= 0; index-- {
			line := strings.TrimSpace(lines[index])
			if !strings.HasPrefix(line, "{") {
				continue
			}
			var result struct {
				Result string `json:"result"`
			}
			if json.Unmarshal([]byte(line), &result) == nil && strings.TrimSpace(result.Result) != "" {
				return sanitizeDetail(result.Result)
			}
		}
	}
	return outputDetail(output)
}

// timeoutDetail is the error_detail of a probe that was killed by the clock.
func timeoutDetail(timeout time.Duration) string {
	return "探测超时（" + strconv.Itoa(int(timeout.Seconds())) + " 秒内没有任何回答）"
}

// sanitizeDetail redacts secrets, collapses whitespace and caps the length.
func sanitizeDetail(message string) string {
	message = redactBearer.ReplaceAllString(message, "Bearer ***")
	message = redactSecretKey.ReplaceAllString(message, "sk-***")
	message = redactLongToken.ReplaceAllString(message, "***")
	message = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, message)
	message = strings.Join(strings.Fields(message), " ")
	if utf8.RuneCountInString(message) > gatewayDetailMaxRunes {
		runes := []rune(message)
		message = string(runes[:gatewayDetailMaxRunes-1]) + "…"
	}
	return message
}

// gatewayDetail renders the relay's answer for error_detail: "HTTP 503 ·
// <message>", secrets redacted, control characters dropped, capped.
func gatewayDetail(answer gatewayError) string {
	message := redactBearer.ReplaceAllString(answer.Message, "Bearer ***")
	message = redactSecretKey.ReplaceAllString(message, "sk-***")
	message = redactLongToken.ReplaceAllString(message, "***")
	message = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, message)
	message = strings.Join(strings.Fields(message), " ")
	detail := "HTTP " + strconv.Itoa(answer.Status)
	if message != "" {
		detail += " · " + message
	}
	if utf8.RuneCountInString(detail) > gatewayDetailMaxRunes {
		runes := []rune(detail)
		detail = string(runes[:gatewayDetailMaxRunes-1]) + "…"
	}
	return detail
}
