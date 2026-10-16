//go:build !windows

package configuration

import (
	"errors"
	"testing"
)

// Claude Code runs apiKeyHelper through /bin/sh on macOS: POSIX single quotes,
// with embedded single quotes closed, escaped and reopened.
func TestShellQuotePOSIXUsesSingleQuotes(t *testing.T) {
	t.Parallel()
	got, err := shellQuote("/Applications/知办AI.app/Contents/Helpers/zhiban-local-bridge")
	if err != nil || got != "'/Applications/知办AI.app/Contents/Helpers/zhiban-local-bridge'" {
		t.Fatalf("shellQuote() = %q, %v", got, err)
	}
	got, err = shellQuote("/tmp/it's/helper")
	if err != nil || got != `'/tmp/it'"'"'s/helper'` {
		t.Fatalf("shellQuote() with embedded quote = %q, %v", got, err)
	}
	for _, unsafe := range []string{"", "/tmp/a\nb/helper", "/tmp/a\x00b"} {
		if _, err := shellQuote(unsafe); !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("shellQuote(%q) err = %v, want ErrUnsafePath", unsafe, err)
		}
	}
}
