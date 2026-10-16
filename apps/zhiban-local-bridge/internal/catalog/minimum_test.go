package catalog

import "testing"

func TestMinimumSwitchVersion(t *testing.T) {
	for _, tc := range []struct {
		target, version string
		tooOld          bool
	}{
		{"codex_cli", "0.136.9", true},
		{"codex_cli", "0.137.0", false},
		{"codex_cli", "0.154.0-alpha.6.2", false},
		{"codex_cli", "", false},
		{"claude_cli", "0.1.0", false}, // not gated until verified
	} {
		if _, tooOld := MinimumSwitchVersion(tc.target, tc.version); tooOld != tc.tooOld {
			t.Fatalf("MinimumSwitchVersion(%s, %s) tooOld = %v, want %v", tc.target, tc.version, tooOld, tc.tooOld)
		}
	}
}
