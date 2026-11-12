package localcodingcatalog

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	"howett.net/plist"
)

type desktopTransport func(*http.Request) (*http.Response, error)

func (f desktopTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func desktopTestZip(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	for name, data := range entries {
		w, err := z.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = w.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func desktopTestMac(t *testing.T, target, version string, cpus []uint32, format int) []byte {
	identifier := codexDesktopBundleID
	if target == dom.TargetClaudeDesktop {
		identifier = claudeDesktopBundleID
	}
	info, err := plist.Marshal(map[string]string{"CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Desktop"}, format)
	if err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 8+20*len(cpus))
	binary.BigEndian.PutUint32(b, 0xcafebabe)
	binary.BigEndian.PutUint32(b[4:], uint32(len(cpus)))
	for i, cpu := range cpus {
		binary.BigEndian.PutUint32(b[8+20*i:], cpu)
	}
	return desktopTestZip(t, map[string][]byte{"Desktop.app/Contents/Info.plist": info, "Desktop.app/Contents/MacOS/Desktop": b})
}

func desktopTestMSIX(t *testing.T, name, version, arch string) []byte {
	return desktopTestZip(t, map[string][]byte{"AppxManifest.xml": []byte(fmt.Sprintf(`<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="%s" Version="%s" ProcessorArchitecture="%s"/></Package>`, name, version, arch)), "payload": []byte(strings.Repeat("payload", 100))})
}

type desktopFixture struct {
	*autoSyncFixture
	feeds, blobs map[string][]byte
	downloads    map[string]int
	brokenRange  bool
	etag         string
}

func newDesktopFixture(t *testing.T) *desktopFixture {
	t.Helper()
	f := &desktopFixture{autoSyncFixture: newAutoSyncFixture(t), feeds: map[string][]byte{}, blobs: map[string][]byte{}, downloads: map[string]int{}, etag: `"release-1"`}
	f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-72*time.Hour))
	s := f.svc.(*impl)
	s.autoSync.desktopSync = nil
	for _, arch := range []string{dom.ArchArm64, dom.ArchX64} {
		url := codexDesktopBase + "ChatGPT-darwin-" + arch + "-26.924.22138.zip"
		cpu := uint32(0x0100000c)
		if arch == dom.ArchX64 {
			cpu = 0x01000007
		}
		f.blobs[url] = desktopTestMac(t, dom.TargetCodexDesktop, "26.924.22138", []uint32{cpu}, plist.XMLFormat)
		feed := codexDesktopBase + "appcast.xml"
		if arch == dom.ArchX64 {
			feed = codexDesktopBase + "appcast-x64.xml"
		}
		f.feeds[feed] = []byte(fmt.Sprintf(`<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>26.924.22138</sparkle:shortVersionString><enclosure url="%s" length="%d"/></item></channel></rss>`, url, len(f.blobs[url])))
	}
	claudeURL := "https://downloads.claude.ai/releases/darwin/universal/2.9939.2/Claude.zip"
	f.blobs[claudeURL] = desktopTestMac(t, dom.TargetClaudeDesktop, "2.9939.2", []uint32{0x0100000c, 0x01000007}, plist.BinaryFormat)
	f.feeds["https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"] = []byte(`{"currentRelease":"2.9939.2","releases":[{"version":"2.9939.2","updateTo":{"version":"2.9939.2","url":"` + claudeURL + `"}}]}`)
	f.blobs[codexDesktopBase+"ChatGPT-x64.msix"] = desktopTestMSIX(t, "OpenAI.Codex", "26.924.2738.0", "x64")
	f.blobs["https://downloads.claude.ai/releases/win32/x64/2.9939.2/Claude.msix"] = desktopTestMSIX(t, "Claude", "2.9939.2.0", "x64")
	old := s.httpClient.Transport
	s.httpClient = &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		if strings.HasPrefix(r.URL.String(), f.registry.server.URL) {
			return old.RoundTrip(r)
		}
		h := make(http.Header)
		status := 200
		var b []byte
		url := r.URL.String()
		if url == claudeWindowsLatest {
			status = 302
			h.Set("Location", "https://downloads.claude.ai/releases/win32/x64/2.9939.2/Claude.msix")
		} else if feed, ok := f.feeds[url]; ok {
			b = feed
		} else if blob, ok := f.blobs[url]; ok {
			b = blob
			h.Set("ETag", f.etag)
			if r.Header.Get("If-Match") != "" && r.Header.Get("If-Match") != f.etag {
				status = 412
				b = nil
			} else if span := r.Header.Get("Range"); span != "" && !f.brokenRange {
				var start, end int
				_, err := fmt.Sscanf(span, "bytes=%d-%d", &start, &end)
				if err != nil || start < 0 || end < start || end >= len(b) {
					status = 416
					b = nil
				} else {
					status = 206
					h.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(b)))
					b = b[start : end+1]
				}
			} else {
				f.downloads[url]++
			}
		} else {
			return nil, errors.New("fixture has no official resource")
		}
		return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(bytes.NewReader(b)), ContentLength: int64(len(b)), Request: r}, nil
	})}
	return f
}

func TestDesktopAndCLIRoundUploadsTwelveThenSkips(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	first, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Results) != 12 || len(f.repo.rows) != 12 || len(f.store.objects) != 12 {
		t.Fatalf("report=%+v rows=%d objects=%d", first, len(f.repo.rows), len(f.store.objects))
	}
	for _, r := range first.Results {
		if r.Outcome != AutoSyncPublishedCurrent {
			t.Fatal(r)
		}
	}
	for _, row := range f.repo.rows {
		if row.Status != dom.StatusCurrent || len(row.CanaryTenantIDs) != 0 {
			t.Fatal("automatic release is not globally current", row)
		}
		if row.IsDesktop() && (!strings.Contains(row.ContractCheckRef, "客户端安装时校验") || !sha256Pattern.MatchString(row.SHA256)) {
			t.Fatal("misleading or incomplete package record")
		}
	}
	if len(f.downloads) != 5 {
		t.Fatalf("full package URLs=%d", len(f.downloads))
	}
	for _, n := range f.downloads {
		if n != 1 {
			t.Fatal("universal package downloaded twice")
		}
	}
	second, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range second.Results {
		if r.Outcome != AutoSyncSkippedExists {
			t.Fatal(r)
		}
	}
	for _, n := range f.downloads {
		if n != 1 {
			t.Fatal("unchanged package was downloaded again")
		}
	}
	if status := s.AutoSyncStatus(); len(status.DesktopPlatforms) != 2 {
		t.Fatal(status)
	}
}

type autoPublishFailureRepo struct {
	dom.Repository
	fail bool
}

func (r *autoPublishFailureRepo) Publish(ctx context.Context, uuid string, in dom.PublishInput) (*dom.Version, error) {
	if r.fail {
		return nil, errors.New("simulated publish transaction failure")
	}
	return r.Repository.Publish(ctx, uuid, in)
}

func TestDesktopFullReleaseKeepsCurrentOnFailureAndRetriesStoredPackage(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	ctx := context.Background()
	p, err := s.discoverDesktop(ctx, desktopTracks[0])
	if err != nil {
		t.Fatal(err)
	}
	old, err := s.Create(ctx, dom.UpsertInput{TargetID: p.TargetID, Platform: p.Platform, Arch: p.Arch, Version: "25.1.1", Layout: p.Layout, BundleIdentifier: p.BundleIdentifier, TeamIdentifier: p.TeamIdentifier, ContractCheckRef: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	withPackage(f.repo, old.UUID)
	if _, err := s.Publish(ctx, old.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatal(err)
	}
	f.store.putErr = errors.New("storage down")
	if out, _ := s.autoSyncDesktopPackage(ctx, p, nil); out != AutoSyncFailed {
		t.Fatal(out)
	}
	if f.repo.rows[old.UUID].Status != dom.StatusCurrent {
		t.Fatal("upload failure displaced current")
	}
	f.store.putErr = nil
	wrapped := &autoPublishFailureRepo{Repository: f.repo, fail: true}
	s.repo = wrapped
	if out, _ := s.autoSyncDesktopPackage(ctx, p, nil); out != AutoSyncFailed {
		t.Fatal(out)
	}
	row := f.row(p.TargetID, p.Platform, p.Arch, p.Version)
	if row == nil || row.Status != dom.StatusDraft || !row.IsObjectStorePackage() || f.repo.rows[old.UUID].Status != dom.StatusCurrent {
		t.Fatal("publish failure changed current or lost uploaded draft")
	}
	downloads := f.downloads[p.SourceURL]
	wrapped.fail = false
	if out, detail := s.autoSyncDesktopPackage(ctx, p, nil); out != AutoSyncPublishedCurrent {
		t.Fatal(out, detail)
	}
	if f.downloads[p.SourceURL] != downloads {
		t.Fatal("publish retry downloaded an already stored package")
	}
	if f.repo.rows[old.UUID].Status != dom.StatusPrevious {
		t.Fatal("previous version unavailable for rollback")
	}
	rows, _, _ := f.repo.List(ctx, dom.Filter{})
	for _, tenant := range []int64{581, 999} {
		current, previous := resolveForTenant(rows, tenant, p.Arch)
		if current == nil || previous == nil || current.Version != p.Version || previous.UUID != old.UUID {
			t.Fatal("global release not visible with rollback", tenant, current, previous)
		}
	}
}

func TestDesktopExistingAutomaticDraftAndCanaryBecomeCurrent(t *testing.T) {
	for _, status := range []string{dom.StatusDraft, dom.StatusCanary} {
		t.Run(status, func(t *testing.T) {
			f := newDesktopFixture(t)
			s := f.svc.(*impl)
			ctx := context.Background()
			p, err := s.discoverDesktop(ctx, desktopTracks[0])
			if err != nil {
				t.Fatal(err)
			}
			if out, detail := s.autoSyncDesktopPackage(ctx, p, nil); out != AutoSyncPublishedCurrent {
				t.Fatal(out, detail)
			}
			row := f.row(p.TargetID, p.Platform, p.Arch, p.Version)
			row.Status, row.CanaryTenantIDs = status, []int64{581}
			before := f.downloads[p.SourceURL]
			if out, detail := s.autoSyncDesktopPackage(ctx, p, nil); out != AutoSyncPublishedCurrent {
				t.Fatal(out, detail)
			}
			if row.Status != dom.StatusCurrent || len(row.CanaryTenantIDs) != 0 || before != f.downloads[p.SourceURL] {
				t.Fatal("existing automatic version not promoted without re-download")
			}
		})
	}
}

func TestDesktopUploadFailureRetriesAndDetectsDrift(t *testing.T) {
	for _, mode := range []string{"retry", "drift", "manual", "deleted", "withdrawn"} {
		t.Run(mode, func(t *testing.T) {
			f := newDesktopFixture(t)
			s := f.svc.(*impl)
			p, err := s.discoverDesktop(context.Background(), desktopTracks[0])
			if err != nil {
				t.Fatal(err)
			}
			f.store.putErr = errors.New("storage unavailable")
			out, _ := s.autoSyncDesktopPackage(context.Background(), p, nil)
			if out != AutoSyncFailed {
				t.Fatal(out)
			}
			row := f.row(p.TargetID, p.Platform, p.Arch, p.Version)
			if row == nil || row.MirrorState != dom.MirrorStateFailed {
				t.Fatal(row)
			}
			uuid := row.UUID
			f.store.putErr = nil
			want := AutoSyncSkippedExists
			switch mode {
			case "retry":
				want = AutoSyncPublishedCurrent
			case "drift":
				row.SHA256 = strings.Repeat("a", 64)
				want = AutoSyncFailed
			case "manual":
				row.ContractCheckRef = "manual"
			case "deleted":
				if err := s.Delete(context.Background(), uuid, 7); err != nil {
					t.Fatal(err)
				}
			case "withdrawn":
				row.Status = dom.StatusDeprecated
			}
			out, detail := s.autoSyncDesktopPackage(context.Background(), p, nil)
			if out != want {
				t.Fatalf("%s: %s", out, detail)
			}
			if mode == "retry" && (len(f.repo.rows) != 1 || row.UUID != uuid || len(f.store.objects) != 1) {
				t.Fatal("duplicate retry")
			}
			if mode != "retry" && len(f.store.objects) != 0 {
				t.Fatal("protected record uploaded")
			}
		})
	}
}

func TestDesktopMissingStoreOrOlderCurrentDoesNotDownload(t *testing.T) {
	for _, mode := range []string{"store", "current"} {
		t.Run(mode, func(t *testing.T) {
			f := newDesktopFixture(t)
			s := f.svc.(*impl)
			p, err := s.discoverDesktop(context.Background(), desktopTracks[0])
			if err != nil {
				t.Fatal(err)
			}
			want := AutoSyncFailed
			if mode == "store" {
				s.packages = nil
			} else {
				row, err := s.Create(context.Background(), dom.UpsertInput{TargetID: p.TargetID, Platform: p.Platform, Arch: dom.ArchUniversal, Version: "99.1.1", Layout: p.Layout, ContractCheckRef: "manual"})
				if err != nil {
					t.Fatal(err)
				}
				f.repo.rows[row.UUID].Status = dom.StatusCurrent
				want = AutoSyncSkippedNotNewer
			}
			got, _ := s.autoSyncDesktopPackage(context.Background(), p, nil)
			if got != want || len(f.downloads) != 0 {
				t.Fatal(got, f.downloads)
			}
		})
	}
}

func TestDesktopInvalidArchiveDoesNotPublishAndOtherTracksContinue(t *testing.T) {
	f := newDesktopFixture(t)
	url := codexDesktopBase + "ChatGPT-darwin-arm64-26.924.22138.zip"
	// Damage metadata rather than only the ZIP's optional leading bytes.
	f.blobs[url] = bytes.Repeat([]byte("x"), len(f.blobs[url]))
	report := f.svc.(*impl).autoSyncDesktops(context.Background())
	if len(report) != 6 || report[0].Outcome != AutoSyncFailed {
		t.Fatal(report)
	}
	for _, r := range report[1:] {
		if r.Outcome != AutoSyncPublishedCurrent {
			t.Fatal(r)
		}
	}
	if len(f.repo.rows) != 5 {
		t.Fatal("invalid archive entered catalog")
	}
}

func TestDesktopSourceRejectsBadRangeAndRedirect(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	f.brokenRange = true
	if _, err := s.discoverDesktop(context.Background(), desktopTracks[4]); err == nil {
		t.Fatal("accepted ignored Range")
	}
	s.httpClient = &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"http://127.0.0.1/internal"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
	if _, err := s.desktopRequest(context.Background(), dom.TargetCodexDesktop, codexDesktopBase+"appcast.xml", nil); err == nil {
		t.Fatal("followed foreign redirect")
	}
	for _, url := range []string{"http://persistent.oaistatic.com/codex-app-prod/a.zip", "https://secret@persistent.oaistatic.com/codex-app-prod/a.zip", codexDesktopBase + "%2e%2e/a.zip", codexDesktopBase + "a.zip?token=x"} {
		if desktopSourceAllowed(dom.TargetCodexDesktop, url) {
			t.Fatal(url)
		}
	}
}

func TestDesktopDownloadTruncationCleansTemp(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	p, err := s.discoverDesktop(context.Background(), desktopTracks[0])
	if err != nil {
		t.Fatal(err)
	}
	tmp := t.TempDir()
	for _, key := range []string{"TMP", "TEMP", "TMPDIR"} {
		t.Setenv(key, tmp)
	}
	s.httpClient = &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{}, ContentLength: -1, Body: io.NopCloser(strings.NewReader("truncated")), Request: r}, nil
	})}
	if _, err := s.downloadDesktop(context.Background(), p); err == nil {
		t.Fatal("accepted truncated download")
	}
	files, _ := os.ReadDir(tmp)
	if len(files) != 0 {
		t.Fatal("temporary file leaked")
	}
}

func TestDesktopLargeMSIXDirectoryUsesBoundedRequests(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	entries := map[string][]byte{"AppxManifest.xml": []byte(`<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="OpenAI.Codex" Version="26.924.2738.0" ProcessorArchitecture="x64"/></Package>`)}
	for i := 0; i < 12000; i++ {
		entries[fmt.Sprintf("resources/file-%06d.txt", i)] = []byte("payload")
	}
	f.blobs[codexDesktopBase+"ChatGPT-x64.msix"] = desktopTestZip(t, entries)
	requests := 0
	base := s.httpClient.Transport
	s.httpClient.Transport = desktopTransport(func(r *http.Request) (*http.Response, error) {
		requests++
		return base.RoundTrip(r)
	})
	p, err := s.discoverDesktop(context.Background(), desktopTracks[4])
	if err != nil {
		t.Fatal(err)
	}
	if p.Version != "26.924.2738" || requests > 16 || len(f.downloads) != 0 {
		t.Fatal(p, requests, f.downloads)
	}
}

func TestDesktopRejectsSnapshotChangeAndOversizedMetadata(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	p, err := s.discoverDesktop(context.Background(), desktopTracks[4])
	if err != nil {
		t.Fatal(err)
	}
	base := s.httpClient.Transport
	s.httpClient.Transport = desktopTransport(func(r *http.Request) (*http.Response, error) {
		response, err := base.RoundTrip(r)
		if response != nil {
			response.Header.Set("ETag", `"changed"`)
		}
		return response, err
	})
	if _, err := s.downloadDesktop(context.Background(), p); err == nil {
		t.Fatal("accepted changed ETag despite ignored If-Match")
	}
	reader := &desktopRangeReader{ctx: context.Background(), service: s, pkg: p}
	if _, err := reader.ReadAt(make([]byte, 20), 0); err == nil {
		t.Fatal("accepted inconsistent range snapshot")
	}
	f.feeds[codexDesktopBase+"appcast.xml"] = bytes.Repeat([]byte("x"), int(desktopMetadataMax)+1)
	if _, err := s.discoverDesktop(context.Background(), desktopTracks[0]); err == nil {
		t.Fatal("accepted oversized release feed")
	}
	blob := desktopTestZip(t, map[string][]byte{"AppxManifest.xml": bytes.Repeat([]byte("x"), int(desktopMetadataMax)+1)})
	z, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := desktopMSIXVersion(z, dom.TargetCodexDesktop, dom.ArchX64); err == nil {
		t.Fatal("accepted oversized archive metadata")
	}
}

func TestDesktopArchiveIdentityVersionArchitecture(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	for _, track := range desktopTracks {
		p, err := s.discoverDesktop(context.Background(), track)
		if err != nil {
			t.Fatal(err)
		}
		d, err := s.downloadDesktop(context.Background(), p)
		if err != nil {
			t.Fatal(err)
		}
		defer d.Close()
		if err := inspectDesktopArchive(d, p); err != nil {
			t.Fatal(err)
		}
		if p.Platform == dom.PlatformMacOS {
			wrong := *p
			wrong.BundleIdentifier = "other.publisher"
			if inspectDesktopArchive(d, &wrong) == nil {
				t.Fatal("accepted wrong Mac bundle")
			}
			if p.TargetID == dom.TargetCodexDesktop {
				wrong = *p
				wrong.Arch = dom.ArchX64
				if p.Arch == dom.ArchX64 {
					wrong.Arch = dom.ArchArm64
				}
				if inspectDesktopArchive(d, &wrong) == nil {
					t.Fatal("accepted wrong Mac architecture")
				}
			}
		}
		p.Version = "1.0.0"
		if inspectDesktopArchive(d, p) == nil {
			t.Fatal("accepted wrong version")
		}
	}
	for _, blob := range [][]byte{desktopTestMSIX(t, "Other", "1.2.3.0", "x64"), desktopTestMSIX(t, "Claude", "1.2.3.1", "x64"), desktopTestMSIX(t, "Claude", "1.2.3.0", "arm64")} {
		z, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := desktopMSIXVersion(z, dom.TargetClaudeDesktop, dom.ArchX64); err == nil {
			t.Fatal("accepted wrong MSIX metadata")
		}
	}
	_, every, err := ParseAutoSyncSettings("", "", "")
	if err != nil || every != time.Hour {
		t.Fatal(every, err)
	}
}

func TestDesktopDiscoverySkipsBetaAndDelta(t *testing.T) {
	f := newDesktopFixture(t)
	s := f.svc.(*impl)
	url := codexDesktopBase + "appcast.xml"
	feed := string(f.feeds[url])
	bad := `<item><sparkle:shortVersionString>99.1.1</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel><enclosure url="` + codexDesktopBase + `ChatGPT-darwin-arm64-99.1.1.zip" length="100"/></item>`
	delta := strings.Replace(bad, `<sparkle:channel>beta</sparkle:channel>`, "", 1)
	delta = strings.Replace(delta, `length="100"`, `length="100" sparkle:deltaFrom="26.0.0"`, 1)
	f.feeds[url] = []byte(strings.Replace(feed, "</channel>", bad+delta+"</channel>", 1))
	p, err := s.discoverDesktop(context.Background(), desktopTracks[0])
	if err != nil || p.Version != "26.924.22138" {
		t.Fatal(p, err)
	}
}

// Opt-in network check uses production source parsing without touching a DB or OSS.
func TestDesktopLiveDiscovery(t *testing.T) {
	if os.Getenv("F31_LIVE_DISCOVERY") != "1" {
		t.Skip("set F31_LIVE_DISCOVERY=1 for public official sources")
	}
	s := New(Deps{}).(*impl)
	for _, track := range desktopTracks {
		t.Run(track.target+"/"+track.platform+"/"+track.arch, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			p, err := s.discoverDesktop(ctx, track)
			if err != nil {
				t.Fatal(err)
			}
			if err = validateDesktopPackage(p, track.target, track.platform, track.arch); err != nil {
				t.Fatal(err)
			}
			t.Log(p.Version, p.SourceURL, strconv.FormatInt(p.FileSizeBytes, 10))
		})
	}
}

func TestDesktopRealPackageFiles(t *testing.T) {
	if os.Getenv("F31_PACKAGE_TEST_DIR") == "" {
		t.Skip("set F31_PACKAGE_TEST_DIR for locally downloaded official packages")
	}
	for _, target := range []string{dom.TargetCodexDesktop, dom.TargetClaudeDesktop} {
		path := os.Getenv("F31_PACKAGE_TEST_DIR") + "/" + target + "-windows-x64/package.msix"
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		info, _ := file.Stat()
		d := &downloaded{file: file, size: info.Size()}
		z, err := zip.NewReader(file, info.Size())
		if err != nil {
			t.Fatal(err)
		}
		v, err := desktopMSIXVersion(z, target, dom.ArchX64)
		if err != nil {
			t.Fatal(err)
		}
		p := &DesktopPackage{TargetID: target, Platform: dom.PlatformWindows, Arch: dom.ArchX64, Version: v}
		if err := inspectDesktopArchive(d, p); err != nil {
			t.Fatal(err)
		}
		t.Log(target, v, info.Size())
	}
}

// Opt-in full downloads exercise the Linux-compatible parser against real Mac
// archives. No native tools, database, or object storage are used.
func TestDesktopLiveMacPackages(t *testing.T) {
	if os.Getenv("F31_LIVE_MAC_PACKAGES") != "1" {
		t.Skip("set F31_LIVE_MAC_PACKAGES=1 to download official Mac archives")
	}
	for _, track := range desktopTracks[:3] {
		t.Run(track.target+"/"+track.arch, func(t *testing.T) {
			t.Parallel()
			s := New(Deps{}).(*impl)
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Minute)
			defer cancel()
			p, err := s.discoverDesktop(ctx, track)
			if err != nil {
				t.Fatal(err)
			}
			d, err := s.downloadDesktop(ctx, p)
			if err != nil {
				t.Fatal(err)
			}
			defer d.Close()
			if err := inspectDesktopArchive(d, p); err != nil {
				t.Fatal(err)
			}
			if track.target == dom.TargetClaudeDesktop {
				p.Arch = dom.ArchX64
				if err := inspectDesktopArchive(d, p); err != nil {
					t.Fatal(err)
				}
			}
			t.Log(p.Version, d.size, d.sha256)
		})
	}
}

// Inspect real Mac metadata over bounded ranges before downloading hundreds of
// megabytes. The full-download test above also checks the streaming/hash path.
func TestDesktopLiveMacMetadata(t *testing.T) {
	if os.Getenv("F31_LIVE_DISCOVERY") != "1" {
		t.Skip("set F31_LIVE_DISCOVERY=1 for official sources")
	}
	for _, track := range desktopTracks[:3] {
		t.Run(track.target+"/"+track.arch, func(t *testing.T) {
			s := New(Deps{}).(*impl)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			p, err := s.discoverDesktop(ctx, track)
			if err != nil {
				t.Fatal(err)
			}
			r, err := s.desktopRequest(ctx, p.TargetID, p.SourceURL, http.Header{"Range": {"bytes=0-0"}})
			if err != nil {
				t.Fatal(err)
			}
			r.Body.Close()
			var size int64
			if _, err = fmt.Sscanf(r.Header.Get("Content-Range"), "bytes 0-0/%d", &size); err != nil || r.StatusCode != 206 || size <= 0 || size > desktopMaxBytes {
				t.Fatal("invalid archive range", err)
			}
			if p.FileSizeBytes > 0 && p.FileSizeBytes != size {
				t.Fatal("feed size mismatch")
			}
			p.FileSizeBytes, p.ETag, p.LastModified = size, r.Header.Get("ETag"), r.Header.Get("Last-Modified")
			reader := &desktopRangeReader{ctx: ctx, service: s, pkg: p}
			z, err := zip.NewReader(reader, size)
			if err != nil {
				t.Fatal(err)
			}
			if err := inspectDesktopZip(z, p); err != nil {
				t.Fatal(err)
			}
			if track.target == dom.TargetClaudeDesktop {
				p.Arch = dom.ArchX64
				if err := inspectDesktopZip(z, p); err != nil {
					t.Fatal(err)
				}
			}
			t.Log(p.Version, "archive bytes", size, "read bytes", reader.read, "requests", reader.requests)
		})
	}
}
