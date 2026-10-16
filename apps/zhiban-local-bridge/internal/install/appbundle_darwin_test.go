//go:build darwin

package install

import "testing"

func TestBundleListedInProcessesIgnoresHelpersOtherProgramsLaunch(t *testing.T) {
	t.Parallel()
	const bundle = "/Applications/Claude.app"
	for _, tc := range []struct {
		name    string
		listing string
		want    bool
	}{
		{
			name:    "Chrome keeps the browser extension host alive with the app closed",
			listing: "/sbin/launchd\n/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n  /Applications/Claude.app/Contents/Helpers/chrome-native-host\n",
			want:    false,
		},
		{
			name:    "main executable",
			listing: "/Applications/Claude.app/Contents/MacOS/Claude\n",
			want:    true,
		},
		{
			// Renderer helpers only live while the app does, and its main
			// executable is caught above; a leftover one must not block.
			name:    "Electron helper without the app itself",
			listing: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)\n",
			want:    false,
		},
		{
			// 2026-09-16: Codex Desktop leaves these behind long after quit.
			name:    "crash reporter helper left behind after quit",
			listing: "/Applications/Claude.app/Contents/Frameworks/Codex Framework.framework/Versions/152.0.7977.64/Helpers/browser_crashpad_handler\n",
			want:    false,
		},
		{
			// The embedded runtime the desktop app spawns for its own use.
			name:    "embedded resource executable",
			listing: "/Applications/Claude.app/Contents/Resources/codex\n",
			want:    false,
		},
		{
			name:    "Squirrel swapping the bundle after quit",
			listing: "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt\n",
			want:    true,
		},
		{
			name:    "another bundle sharing the name prefix",
			listing: "/Applications/Claude.app.old/Contents/MacOS/Claude\n/Applications/Claude Beta.app/Contents/MacOS/Claude\n",
			want:    false,
		},
	} {
		if got := bundleListedInProcesses([]byte(tc.listing), bundle+"/"); got != tc.want {
			t.Errorf("%s: bundleListedInProcesses = %v, want %v", tc.name, got, tc.want)
		}
	}
}
