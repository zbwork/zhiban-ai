package install

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Keep the public code compatible while retaining the failing native step.
// Only sanitized text may reach operation/diagnostics/support feedback.
type bundleFailure struct {
	kind   error
	detail string
}

func (e *bundleFailure) Error() string { return e.detail }
func (e *bundleFailure) Unwrap() error { return e.kind }

func newBundleFailure(kind error, stage string, cause error) error {
	return &bundleFailure{kind: kind, detail: safeBundleDetail(stage + ": " + cause.Error())}
}

func bundleFailureDetail(err error) string {
	var failure *bundleFailure
	if errors.As(err, &failure) {
		return failure.detail
	}
	return ""
}

var (
	bundleURL    = regexp.MustCompile(`(?i)https?://[^\s<>"']+`)
	bundleBearer = regexp.MustCompile(`(?i)bearer\s+\S+`)
	bundleSecret = regexp.MustCompile(`(?i)(token|password|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+`)
	bundleToken  = regexp.MustCompile(`\bsk-[A-Za-z0-9_-]+|[A-Za-z0-9_+/=-]{40,}`)
	// Known command arguments are removed first; this also removes nested
	// bundle paths reported by codesign, including paths containing spaces.
	bundlePath = regexp.MustCompile(`(?:[A-Za-z]:[\\/]|/)[^\r\n:;<>"']+`)
)

func safeBundleDetail(value string) string {
	value = bundleURL.ReplaceAllString(value, "[URL]")
	value = bundleBearer.ReplaceAllString(value, "Bearer [redacted]")
	value = bundleSecret.ReplaceAllString(value, "$1=[redacted]")
	value = bundleToken.ReplaceAllString(value, "[redacted]")
	value = bundlePath.ReplaceAllString(value, "[path]")
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(value, ""))
	value = strings.Join(strings.Fields(value), " ")
	// Byte-bound on rune boundaries, below the envelope's 1024-byte limit.
	if len(value) > 900 {
		end := 897
		for !utf8.ValidString(value[:end]) {
			end--
		}
		return value[:end] + "…"
	}
	return value
}

func nativeToolFailure(tool string, cause error, stderr string, arguments []string) error {
	for _, argument := range arguments {
		if strings.HasPrefix(argument, "/") {
			stderr = strings.ReplaceAll(stderr, argument, "[path]")
		}
	}
	return fmt.Errorf("%s: %w; %s", tool, cause, safeBundleDetail(stderr))
}
