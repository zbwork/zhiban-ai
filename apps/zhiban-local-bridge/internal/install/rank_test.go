package install

import (
	"archive/tar"
	"bytes"
	"context"
	crand "crypto/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// slowHandler trickles bytes so the source looks reachable but slow.
func slowHandler(chunk []byte, every time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		flusher, _ := w.(http.Flusher)
		w.WriteHeader(http.StatusOK)
		for {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
			select {
			case <-r.Context().Done():
				return
			case <-time.After(every):
			}
		}
	}
}

// deadHandler accepts the connection but never answers inside the window.
func deadHandler(w http.ResponseWriter, r *http.Request) {
	<-r.Context().Done()
}

func fastHandler(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(bytes.Repeat([]byte{1}, probeBytes))
}

func rankFixture(t *testing.T, mux *http.ServeMux) (*downloadClient, *httptest.Server) {
	t.Helper()
	server := httptest.NewTLSServer(mux)
	t.Cleanup(server.Close)
	client := newDownloadClient(server.Client().Transport, []string{"127.0.0.1"}, "test")
	client.probeWindow = 1500 * time.Millisecond
	return client, server
}

func TestRankSourcesPrefersClearlyFasterMirrorAndKeepsUnreachableLast(t *testing.T) {
	t.Parallel()
	mux := http.NewServeMux()
	mux.HandleFunc("/slow", slowHandler(bytes.Repeat([]byte{1}, 4<<10), 100*time.Millisecond))
	mux.HandleFunc("/fast", fastHandler)
	mux.HandleFunc("/dead", deadHandler)
	client, server := rankFixture(t, mux)
	sources := []Source{
		{Kind: SourceKindOfficial, URL: server.URL + "/slow"},
		{Kind: SourceKindNPMMirror, URL: server.URL + "/dead"},
		{Kind: SourceKindNPMRegistry, URL: server.URL + "/fast"},
	}
	started := time.Now()
	ranked := client.rankSources(context.Background(), sources)
	if elapsed := time.Since(started); elapsed > 4*time.Second {
		t.Fatalf("ranking took %v, want bounded by the probe window", elapsed)
	}
	got := []string{ranked[0].Kind, ranked[1].Kind, ranked[2].Kind}
	want := []string{SourceKindNPMRegistry, SourceKindOfficial, SourceKindNPMMirror}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("ranked = %v, want %v", got, want)
	}
}

func TestRankSourcesKeepsOfficialFirstWhenComparableAndOrderWhenAllDead(t *testing.T) {
	t.Parallel()
	mux := http.NewServeMux()
	mux.HandleFunc("/fast", fastHandler)
	mux.HandleFunc("/fast2", fastHandler)
	mux.HandleFunc("/dead", deadHandler)
	mux.HandleFunc("/dead2", deadHandler)
	client, server := rankFixture(t, mux)

	comparable := []Source{
		{Kind: SourceKindOfficial, URL: server.URL + "/fast"},
		{Kind: SourceKindNPMMirror, URL: server.URL + "/fast2"},
	}
	ranked := client.rankSources(context.Background(), comparable)
	if ranked[0].Kind != SourceKindOfficial || ranked[1].Kind != SourceKindNPMMirror {
		t.Fatalf("comparable ranked = %v %v, want official first", ranked[0].Kind, ranked[1].Kind)
	}

	dead := []Source{
		{Kind: SourceKindOfficial, URL: server.URL + "/dead"},
		{Kind: SourceKindNPMMirror, URL: server.URL + "/dead2"},
	}
	ranked = client.rankSources(context.Background(), dead)
	if ranked[0].Kind != SourceKindOfficial || ranked[1].Kind != SourceKindNPMMirror {
		t.Fatalf("all-dead ranked = %v %v, want original order", ranked[0].Kind, ranked[1].Kind)
	}

	// A single candidate is never probed.
	only := []Source{{Kind: SourceKindOfficial, URL: server.URL + "/dead"}}
	started := time.Now()
	if ranked = client.rankSources(context.Background(), only); len(ranked) != 1 || time.Since(started) > 500*time.Millisecond {
		t.Fatalf("single source should be returned immediately")
	}

	// Hosts outside the allow-list are unreachable by definition.
	denied := []Source{
		{Kind: SourceKindOfficial, URL: "https://evil.example/x"},
		{Kind: SourceKindNPMMirror, URL: server.URL + "/fast"},
	}
	ranked = client.rankSources(context.Background(), denied)
	if ranked[0].Kind != SourceKindNPMMirror {
		t.Fatalf("denied host ranked first: %v", ranked[0].URL)
	}
}

func TestInstallDownloadsFromFastestSourceWhenOfficialIsSlow(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	// Pad the mirror tarball with incompressible bytes so the speed probe
	// sees a realistic multi-megabyte asset rather than a few-KB fixture.
	filler := make([]byte, 3<<20)
	if _, err := crand.Read(filler); err != nil {
		t.Fatal(err)
	}
	mirror := tarballWith(t, map[string][]byte{
		"package/package.json": []byte(`{"name":"fake"}`),
		"package/filler.bin":   filler,
		"package/claude":       claudeScript(),
	}, func(writer *tar.Writer) {
		_ = writer.WriteHeader(&tar.Header{Name: "package/", Typeflag: tar.TypeDir, Mode: 0o755})
	})
	var officialFullGets, mirrorFullGets atomic.Int32
	mux := http.NewServeMux()
	// The official source is reachable but trickles; a full download from it
	// would take minutes, so it must never be chosen for the real transfer.
	slow := slowHandler(bytes.Repeat([]byte{1}, 4<<10), 100*time.Millisecond)
	mux.HandleFunc("/official/claude", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") == "" {
			officialFullGets.Add(1)
		}
		slow(w, r)
	})
	mux.HandleFunc("/mirror/claude.tgz", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") == "" {
			mirrorFullGets.Add(1)
		}
		w.Header().Set("Content-Length", itoa(len(mirror)))
		_, _ = w.Write(mirror)
	})
	f := newFixture(t, mux, nil)
	claude := f.assets[TargetClaudeCLI]
	claude.Sources = []Source{
		{Kind: SourceKindOfficial, URL: f.server.URL + "/official/claude", Size: int64(len(claudeScript())), SHA256: digestOf(claudeScript()), Layout: LayoutBareBinary},
		{Kind: SourceKindNPMMirror, URL: f.server.URL + "/mirror/claude.tgz", Size: int64(len(mirror)), SHA256: digestOf(mirror), Layout: LayoutTarballMember, Member: "package/claude"},
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI], claude}, AllowedHosts: []string{"127.0.0.1"},
		Transport: f.server.Client().Transport, Detect: f.detector.Detect, Operations: f.registry,
		ProbeWindow: 1500 * time.Millisecond,
		OSVersion:   func() (string, error) { return "15.3", nil },
		FreeBytes:   func(string) (uint64, error) { return 10 << 30, nil },
		Writable:    func(string) bool { return true },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateSucceeded {
		t.Fatalf("final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	installed, err := os.ReadFile(filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion))
	if err != nil || !bytes.Equal(installed, claudeScript()) {
		t.Fatalf("installed = %q, %v", installed, err)
	}
	if officialFullGets.Load() != 0 || mirrorFullGets.Load() != 1 {
		t.Fatalf("full GETs official=%d mirror=%d, want 0/1", officialFullGets.Load(), mirrorFullGets.Load())
	}
	f.assertNoScratch(t)
}
