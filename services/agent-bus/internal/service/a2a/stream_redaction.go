package a2a

import (
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// a2aStreamDeltaRedactor redacts live stream deltas before store/fanout.
// It keeps only a small suspicious tail so secrets split across adjacent chunks
// can be redacted before any complete value is emitted.
type a2aStreamDeltaRedactor struct {
	mu      sync.Mutex
	pending string
}

func newA2AStreamDeltaRedactor() *a2aStreamDeltaRedactor {
	return &a2aStreamDeltaRedactor{}
}

func (r *a2aStreamDeltaRedactor) Redact(ev A2AStreamEvent) (A2AStreamEvent, bool) {
	if r == nil {
		return redactA2AStreamEvent(ev), true
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	if ev.Event == "" {
		ev.Event = "a2a.delta"
	}
	if ev.Event != "a2a.delta" {
		return redactA2AStreamEvent(ev), true
	}

	ev.BlockDelta = redactA2AStreamBlockDelta(ev.BlockDelta)
	if ev.Delta == "" {
		return ev, true
	}

	combined := r.pending + ev.Delta
	redacted, _ := RedactString(combined)
	emit, hold := splitA2AStreamRedactedTail(redacted)
	r.pending = hold
	if emit == "" {
		return A2AStreamEvent{}, false
	}

	ev.Delta = emit
	if ev.BlockDelta != nil {
		if _, ok := ev.BlockDelta["text"]; ok {
			ev.BlockDelta["text"] = emit
		}
	}
	return ev, true
}

func (r *a2aStreamDeltaRedactor) Flush() (A2AStreamEvent, bool) {
	if r == nil {
		return A2AStreamEvent{}, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pending == "" {
		return A2AStreamEvent{}, false
	}
	delta, _ := RedactString(r.pending)
	r.pending = ""
	if delta == "" {
		return A2AStreamEvent{}, false
	}
	return A2AStreamEvent{Event: "a2a.delta", Delta: delta}, true
}

func redactA2AStreamEvent(ev A2AStreamEvent) A2AStreamEvent {
	if ev.Delta != "" {
		ev.Delta, _ = RedactString(ev.Delta)
	}
	ev.BlockDelta = redactA2AStreamBlockDelta(ev.BlockDelta)
	if len(ev.ResponsePayload) > 0 {
		ev.ResponsePayload, _, _ = RedactJSON(ev.ResponsePayload)
	}
	return ev
}

func redactA2AStreamBlockDelta(block map[string]any) map[string]any {
	if block == nil {
		return nil
	}
	hit := false
	redacted := walkAndRedact(block, &hit)
	out, _ := redacted.(map[string]any)
	return out
}

func splitA2AStreamRedactedTail(s string) (emit string, hold string) {
	if s == "" {
		return "", ""
	}
	holdStart := len(s)
	for _, start := range []int{
		partialDigitSecretTailStart(s),
		partialEmailTailStart(s),
		partialTokenSecretTailStart(s),
	} {
		if start >= 0 && start < holdStart {
			holdStart = start
		}
	}
	if holdStart == len(s) {
		return s, ""
	}
	return s[:holdStart], s[holdStart:]
}

func partialDigitSecretTailStart(s string) int {
	i := len(s)
	for i > 0 {
		c := s[i-1]
		if (c >= '0' && c <= '9') || c == 'X' || c == 'x' {
			i--
			continue
		}
		break
	}
	if i == len(s) {
		return -1
	}
	tail := s[i:]
	if len(tail) < 18 {
		return i
	}
	return -1
}

func partialEmailTailStart(s string) int {
	i := len(s)
	for i > 0 {
		r, size := lastRune(s[:i])
		if !isEmailTailRune(r) {
			break
		}
		i -= size
	}
	if i == len(s) {
		return -1
	}
	tail := s[i:]
	if strings.Contains(tail, "@") {
		return i
	}
	return -1
}

func partialTokenSecretTailStart(s string) int {
	start := -1
	if idx := strings.LastIndex(s, "sk-"); idx >= 0 && len(s)-idx < 64 {
		start = idx
	}
	if idx := strings.LastIndex(s, "Bearer "); idx >= 0 && len(s)-idx < 96 {
		if start < 0 || idx < start {
			start = idx
		}
	}
	return start
}

func isEmailTailRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '.' || r == '+' || r == '-' || r == '@'
}

func lastRune(s string) (rune, int) {
	return utf8.DecodeLastRuneInString(s)
}
