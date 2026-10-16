package app

import "testing"

// TestSupportedRuntime pins the platform/arch matrix the Bridge runs on:
// macOS (arm64/x64) and Windows (x64, F31 M2).
func TestSupportedRuntime(t *testing.T) {
	t.Parallel()
	cases := []struct {
		platform, arch string
		want           bool
	}{
		{"macos", "arm64", true},
		{"macos", "x64", true},
		{"windows", "x64", true},
		{"windows", "arm64", false},
		{"linux", "x64", false},
		{"macos", "386", false},
		{"", "", false},
	}
	for _, c := range cases {
		if got := supportedRuntime(c.platform, c.arch); got != c.want {
			t.Errorf("supportedRuntime(%q, %q) = %v, want %v", c.platform, c.arch, got, c.want)
		}
	}
}
