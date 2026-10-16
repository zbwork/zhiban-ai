//go:build windows

package configuration

import (
	"errors"
	"testing"
)

// Claude Code runs apiKeyHelper through cmd.exe on Windows, so the helper path
// must be double-quoted; POSIX single quotes are taken literally there.
func TestShellQuoteWindowsUsesCmdDoubleQuotes(t *testing.T) {
	t.Parallel()
	helper := `C:\Program Files\知办AI\zhiban-local-bridge.exe`
	got, err := shellQuote(helper)
	if err != nil || got != `"`+helper+`"` {
		t.Fatalf("shellQuote(%q) = %q, %v", helper, got, err)
	}
	for _, unsafe := range []string{"", `C:\a"b\helper.exe`, `C:\%APPDATA%\helper.exe`, `C:\a!b\helper.exe`, "C:\\a\nb\\helper.exe"} {
		if _, err := shellQuote(unsafe); !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("shellQuote(%q) err = %v, want ErrUnsafePath", unsafe, err)
		}
	}
}
