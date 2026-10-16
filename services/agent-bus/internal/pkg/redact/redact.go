package redact

import (
	"encoding/json"
	"regexp"
	"strings"
)

const (
	placeholder    = "[REDACTED]"
	defaultMaxBody = 64 * 1024 // 64 KB
)

var defaultSensitiveKeys = []string{
	"authorization", "token", "api_key", "apikey", "api-key",
	"password", "secret", "cookie", "session_token",
	"x-api-key", "x-zap-session-token", "access_token",
	"refresh_token", "client_secret", "private_key",
}

var defaultSensitivePaths = []string{
	"headers.authorization",
	"headers.cookie",
	"headers.x-api-key",
	"llm.api_key",
	"llm.apiKey",
	"llm.token",
	"model_provider.api_key",
	"credentials.value",
	"auth.token",
	"auth.secret",
}

var defaultSensitivePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)bearer\s+[a-z0-9._~+/=-]+`),
	regexp.MustCompile(`(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)=([^&\s]+)`),
	regexp.MustCompile(`sk-[A-Za-z0-9_-]{12,}`),
	regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`),
	regexp.MustCompile(`1[3-9]\d{9}`),
}

var (
	bearerPattern     = regexp.MustCompile(`(?i)\bbearer\s+([a-z0-9._~+/=-]+)`)
	queryTokenPattern = regexp.MustCompile(`(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)=([^&\s]+)`)
	skTokenPattern    = regexp.MustCompile(`sk-[A-Za-z0-9_-]{12,}`)
	emailPattern      = regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)
	phonePattern      = regexp.MustCompile(`1[3-9]\d{9}`)
)

type Redactor struct {
	exactKeys      map[string]bool
	pathKeys       map[string]bool
	suffixPathKeys []string
	patterns       []*regexp.Regexp
	maxBodyLen     int
}

type Option func(*Redactor)

func WithExactKeys(keys ...string) Option {
	return func(r *Redactor) {
		for _, k := range keys {
			r.exactKeys[normalizeKey(k)] = true
		}
	}
}

func WithSensitivePaths(paths ...string) Option {
	return func(r *Redactor) {
		for _, p := range paths {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			if strings.HasPrefix(p, "*.") {
				r.suffixPathKeys = append(r.suffixPathKeys, normalizePath(strings.TrimPrefix(p, "*")))
				continue
			}
			r.pathKeys[normalizePath(p)] = true
		}
	}
}

func WithMaxBodyLen(n int) Option {
	return func(r *Redactor) {
		if n > 0 {
			r.maxBodyLen = n
		}
	}
}

func New(opts ...Option) *Redactor {
	r := &Redactor{
		exactKeys:  make(map[string]bool, len(defaultSensitiveKeys)),
		pathKeys:   make(map[string]bool, len(defaultSensitivePaths)),
		patterns:   defaultSensitivePatterns,
		maxBodyLen: defaultMaxBody,
	}
	for _, k := range defaultSensitiveKeys {
		r.exactKeys[normalizeKey(k)] = true
	}
	for _, p := range defaultSensitivePaths {
		r.pathKeys[normalizePath(p)] = true
	}
	for _, o := range opts {
		o(r)
	}
	return r
}

// RedactJSON takes raw JSON bytes and returns redacted JSON + truncated flag.
// Non-JSON payloads are preserved as {"raw":"..."} so call logs remain useful.
func (r *Redactor) RedactJSON(raw []byte) ([]byte, bool) {
	if r == nil {
		r = New()
	}
	if len(raw) == 0 {
		return []byte("{}"), false
	}

	var data any
	if err := json.Unmarshal(raw, &data); err != nil {
		rawText, truncated := r.truncateString(string(raw))
		rawText = r.redactString(rawText)
		out, _ := json.Marshal(map[string]any{"raw": rawText})
		return out, truncated
	}

	r.walk(data, nil)

	out, err := json.Marshal(data)
	if err != nil {
		return []byte("{}"), false
	}
	if r.maxBodyLen > 0 && len(out) > r.maxBodyLen {
		preview, _ := r.truncateString(string(out))
		preview = r.redactString(preview)
		out, _ = json.Marshal(map[string]any{
			"_preview":   preview,
			"_truncated": true,
		})
		return out, true
	}
	return out, false
}

func (r *Redactor) walk(v any, path []string) {
	switch val := v.(type) {
	case map[string]any:
		for k, child := range val {
			childPath := append(path, k)
			if r.shouldRedact(k, childPath) {
				if s, ok := child.(string); ok {
					val[k] = maskMiddle(s)
				} else {
					val[k] = placeholder
				}
				continue
			}
			if s, ok := child.(string); ok {
				val[k] = r.redactString(s)
				continue
			}
			r.walk(child, childPath)
		}
	case []any:
		for i, item := range val {
			if s, ok := item.(string); ok {
				val[i] = r.redactString(s)
				continue
			}
			r.walk(item, path)
		}
	}
}

func (r *Redactor) shouldRedact(key string, path []string) bool {
	if r.exactKeys[normalizeKey(key)] {
		return true
	}
	normalizedPath := normalizePath(strings.Join(path, "."))
	if r.pathKeys[normalizedPath] {
		return true
	}
	for _, suffix := range r.suffixPathKeys {
		if strings.HasSuffix(normalizedPath, suffix) {
			return true
		}
	}
	return false
}

// RedactText applies pattern redaction (bearer/api-key/email/phone) to a plain
// string. F24 uses it to scrub agent_runs/agent_run_steps error_message before
// DB write so tool errors echoing user input never land in L2 tables.
func (r *Redactor) RedactText(s string) string {
	if r == nil {
		return s
	}
	return r.redactString(s)
}

func (r *Redactor) redactString(s string) string {
	s = bearerPattern.ReplaceAllStringFunc(s, func(match string) string {
		parts := strings.Fields(match)
		if len(parts) < 2 {
			return placeholder
		}
		return parts[0] + " " + maskMiddle(parts[1])
	})
	s = queryTokenPattern.ReplaceAllStringFunc(s, func(match string) string {
		idx := strings.Index(match, "=")
		if idx < 0 {
			return placeholder
		}
		return match[:idx+1] + maskMiddle(match[idx+1:])
	})
	s = skTokenPattern.ReplaceAllStringFunc(s, maskMiddle)
	s = emailPattern.ReplaceAllStringFunc(s, maskEmail)
	s = phonePattern.ReplaceAllStringFunc(s, maskPhone)
	return s
}

func maskPhone(s string) string {
	if len(s) != 11 {
		return maskMiddle(s)
	}
	return s[:3] + "****" + s[7:]
}

func maskEmail(s string) string {
	at := strings.LastIndex(s, "@")
	if at <= 0 {
		return maskMiddle(s)
	}
	local := s[:at]
	domain := s[at:]
	rs := []rune(local)
	if len(rs) == 0 {
		return placeholder
	}
	keep := 1
	if len(rs) >= 4 {
		keep = 2
	}
	return string(rs[:keep]) + "****" + domain
}

func maskMiddle(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return placeholder
	}
	rs := []rune(s)
	n := len(rs)
	switch {
	case n <= 4:
		return placeholder
	case n <= 8:
		return string(rs[:1]) + "****" + string(rs[n-1:])
	case n <= 16:
		return string(rs[:3]) + "****" + string(rs[n-2:])
	default:
		return string(rs[:6]) + "****" + string(rs[n-4:])
	}
}

func (r *Redactor) truncateString(s string) (string, bool) {
	if r.maxBodyLen <= 0 || len(s) <= r.maxBodyLen {
		return s, false
	}
	return s[:r.maxBodyLen], true
}

func normalizeKey(k string) string {
	k = strings.TrimSpace(strings.ToLower(k))
	k = strings.ReplaceAll(k, "-", "_")
	return k
}

func normalizePath(path string) string {
	return strings.ToLower(strings.ReplaceAll(strings.TrimSpace(path), "-", "_"))
}
