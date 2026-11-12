package localcodingcatalog

import (
	"context"
	"net/http"
	"os"
	"testing"
	"time"
)

// TestAutoSyncAgainstTheRealMirror is a manual check (AUTOSYNC_LIVE=1): the
// real npm signature scheme, document shape and package layout, read only.
func TestAutoSyncAgainstTheRealMirror(t *testing.T) {
	if os.Getenv("AUTOSYNC_LIVE") != "1" {
		t.Skip("set AUTOSYNC_LIVE=1 to download real packages from the npm mirror")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	source, err := newNPMSource(&http.Client{}, DefaultAutoSyncRegistry, defaultAutoSyncDownloadHosts, DefaultNPMRegistryKeys())
	if err != nil {
		t.Fatal(err)
	}
	for _, track := range autoSyncTracks {
		version, published, err := source.tagVersion(ctx, track.pkg, track.tag)
		if err != nil {
			t.Fatalf("%s %s: %v", track.pkg, track.tag, err)
		}
		if !releaseVersionPattern.MatchString(version) || published.IsZero() {
			t.Fatalf("%s %s = %q published %v", track.pkg, track.tag, version, published)
		}
		platform := track.platforms[0]
		if only := os.Getenv("AUTOSYNC_LIVE_PLATFORM"); only != "" {
			for _, p := range track.platforms {
				if p.platform+"/"+p.arch == only {
					platform = p
				}
			}
		}
		name, pkgVersion := platform.pkg(version)
		pkg, err := source.packageVersion(ctx, name, pkgVersion)
		if err != nil {
			t.Fatalf("%s@%s document: %v", name, pkgVersion, err)
		}
		tarball, err := source.download(ctx, pkg)
		if err != nil {
			t.Fatalf("%s@%s download: %v", name, pkgVersion, err)
		}
		binary, err := tarball.memberSHA256(platform.program)
		tarball.Close()
		if err != nil {
			t.Fatalf("%s@%s member %s: %v", name, pkgVersion, platform.program, err)
		}
		t.Logf("%s %s/%s %s published %s: %d bytes sha256 %s binary %s", track.targetID, platform.platform, platform.arch,
			version, published.Format(time.RFC3339), tarball.size, tarball.sha256, binary)
	}
}
