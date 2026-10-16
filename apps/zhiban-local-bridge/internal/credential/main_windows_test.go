//go:build windows

package credential

import (
	"os"
	"testing"
)

// DPAPI integration tests exercise the real OS API, but must never delete or
// replace this Windows user's existing Bridge identity/authorization files.
func TestMain(m *testing.M) {
	os.Exit(runIsolatedCredentialTests(m))
}

func runIsolatedCredentialTests(m *testing.M) int {
	directory, err := os.MkdirTemp("", "zhiban-credential-test-")
	if err != nil {
		return 1
	}
	defer os.RemoveAll(directory)
	if err := os.Setenv("LOCALAPPDATA", directory); err != nil {
		return 1
	}
	return m.Run()
}
