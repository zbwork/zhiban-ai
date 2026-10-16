package catalog

// Minimum versions that can be switched to the Zhiban gateway (2026-09-15).
// Older installations stay fully usable with the official service — detect,
// open and upgrade work — but are not switched: an old Codex that cannot parse
// the configuration Zhiban writes refuses to start at all. Only versions
// verified on real binaries are listed; a target without an entry is not
// gated. Codex 0.137.0 was the oldest verified (0.137.0–0.144.1 parse the
// managed provider and run its auth command).
var minimumSwitchVersions = map[string]string{
	"codex_cli": "0.137.0",
}

// MinimumSwitchVersion returns the oldest switchable version of a target, and
// whether version is older than it.
func MinimumSwitchVersion(targetID, version string) (minimum string, tooOld bool) {
	minimum, ok := minimumSwitchVersions[targetID]
	if !ok || version == "" {
		return minimum, false
	}
	return minimum, CompareVersions(version, minimum) < 0
}
