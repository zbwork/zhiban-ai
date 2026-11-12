package localcodingcatalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
)

// putStore records PutObject calls and presigns on a fixed host.
type putStore struct {
	object.Store
	mu      sync.Mutex
	objects map[string][]byte
	putErr  error
}

func (s *putStore) Kind() string { return "fake" }

func (s *putStore) PutObject(_ context.Context, key string, body io.Reader, contentLength int64, _ string) error {
	data, err := io.ReadAll(body)
	if err != nil {
		return err
	}
	if int64(len(data)) != contentLength {
		return errors.New("content length mismatch")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.putErr != nil {
		return s.putErr
	}
	s.objects[key] = data
	return nil
}

func (s *putStore) PresignGet(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	return &object.PresignGetOutput{URL: "https://oss.example.cn/" + in.Key + "?sig=x", ExpiresAt: time.Now().Add(in.TTL)}, nil
}

func sha256Of(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func TestMirrorPackageCopiesExternalPackageIntoObjectStore(t *testing.T) {
	payload := []byte(strings.Repeat("codex-0.154.0 ", 4096))
	var hits int
	// TLS: the domain only accepts https external package addresses.
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		switch r.URL.Path {
		case "/@openai/codex/-/codex-0.154.0-darwin-arm64.tgz":
			w.Header().Set("Content-Length", itoa(len(payload)))
			_, _ = w.Write(payload)
		case "/changed.tgz":
			w.Header().Set("Content-Length", itoa(len(payload)))
			_, _ = w.Write([]byte(strings.Repeat("x", len(payload))))
		case "/nolength.tgz":
			w.Header().Set("Transfer-Encoding", "chunked")
			flusher, _ := w.(http.Flusher)
			_, _ = w.Write(payload[:10])
			if flusher != nil {
				flusher.Flush()
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()

	ctx := context.Background()
	repo := newFakeRepo()
	audit := &fakeAudit{}
	store := &putStore{objects: map[string][]byte{}}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Audit: audit, Packages: packages, HTTPClient: upstream.Client(), MirrorSync: true, ExternalBaseURL: "https://bus.example.com"})

	// An external https package (the operator entered it or the seed script did).
	external := codexInput()
	external.ExternalURL = upstream.URL + "/@openai/codex/-/codex-0.154.0-darwin-arm64.tgz"
	external.FileSizeBytes = int64(len(payload))
	external.SHA256 = sha256Of(payload)
	v, err := svc.Create(ctx, external)
	if err != nil {
		t.Fatal(err)
	}
	// Seeded rows may already be published; mirroring must not depend on draft.
	repo.rows[v.UUID].Status = dom.StatusCanary
	repo.rows[v.UUID].CanaryTenantIDs = []int64{581}

	done, err := svc.MirrorPackage(ctx, v.UUID, 7)
	if err != nil {
		t.Fatalf("MirrorPackage: %v", err)
	}
	if done.MirrorState != dom.MirrorStateDone || done.MirrorError != "" {
		t.Fatalf("state after mirror: %s / %q", done.MirrorState, done.MirrorError)
	}
	if !strings.HasPrefix(done.StorageURI, "oss://local-coding/"+v.UUID+"/codex-0.154.0-darwin-arm64.tgz") {
		t.Fatalf("storage uri after mirror: %s", done.StorageURI)
	}
	if done.Status != dom.StatusCanary || done.SHA256 != sha256Of(payload) || done.FileSizeBytes != int64(len(payload)) {
		t.Fatalf("row changed beyond storage: %+v", done)
	}
	if got := store.objects["local-coding/"+v.UUID+"/codex-0.154.0-darwin-arm64.tgz"]; string(got) != string(payload) {
		t.Fatalf("object store content mismatch (%d bytes)", len(got))
	}
	last := audit.events[len(audit.events)-1]
	if last.EventKind != "local_coding.package_mirrored" || !strings.Contains(string(last.Payload), `"from_host"`) {
		t.Fatalf("audit: %+v", last)
	}
	// Already mirrored: nothing external left to copy.
	if _, err := svc.MirrorPackage(ctx, v.UUID, 7); !errors.Is(err, dom.ErrPackageNotExternal) {
		t.Fatalf("second mirror: %v", err)
	}
	// The catalog now serves the Bus redirect, not the third-party host.
	signer, _ := newTestSigner(t)
	withSigner := New(Deps{Repo: repo, Packages: packages, Signer: signer, ExternalBaseURL: "https://bus.example.com"})
	signed, err := withSigner.Catalog(ctx, 581, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	src := signed.Catalog.Targets["codex_cli"].Current.Sources[0]
	if !strings.HasPrefix(src.URL, "https://bus.example.com"+PackagePathPrefix) {
		t.Fatalf("catalog source after mirror: %s", src.URL)
	}

	// Upstream bytes changed since the hash was recorded: the copy is refused
	// and the row keeps its external URL.
	changed := codexInput()
	changed.Version = "0.155.0"
	changed.ExternalURL = upstream.URL + "/changed.tgz"
	changed.FileSizeBytes = int64(len(payload))
	changed.SHA256 = sha256Of(payload)
	c, _ := svc.Create(ctx, changed)
	failed, err := svc.MirrorPackage(ctx, c.UUID, 7)
	if err != nil {
		t.Fatal(err)
	}
	if failed.MirrorState != dom.MirrorStateFailed || !strings.Contains(failed.MirrorError, "哈希") || !strings.HasPrefix(failed.StorageURI, "https://") {
		t.Fatalf("mismatch outcome: %+v", failed)
	}
	// The download is checked in the temp dir first: nothing unexpected
	// ever reaches local-coding/<uuid>/.
	if _, ok := store.objects["local-coding/"+c.UUID+"/changed.tgz"]; ok {
		t.Fatal("mismatched download must not be written to the object store")
	}
	// A source without Content-Length cannot be size-checked and is refused.
	chunked := codexInput()
	chunked.Version = "0.156.0"
	chunked.ExternalURL = upstream.URL + "/nolength.tgz"
	chunked.FileSizeBytes = int64(len(payload))
	chunked.SHA256 = sha256Of(payload)
	n, _ := svc.Create(ctx, chunked)
	if out, err := svc.MirrorPackage(ctx, n.UUID, 7); err != nil || out.MirrorState != dom.MirrorStateFailed || !strings.Contains(out.MirrorError, "Content-Length") {
		t.Fatalf("chunked outcome: %+v, %v", out, err)
	}
	// Object-store-hosted rows are not external.
	if _, err := svc.MirrorPackage(ctx, "missing", 7); err == nil {
		t.Fatal("missing row should fail")
	}
	if hits < 3 {
		t.Fatalf("upstream hits = %d", hits)
	}
}

// A published version that still points at an external link accepts the
// same file uploaded through Admin: bytes must match, only the storage moves.
func TestUploadPackageReplacesExternalLinkOnPublishedVersion(t *testing.T) {
	payload := []byte(strings.Repeat("claude-desktop ", 2048))
	ctx := context.Background()
	repo := newFakeRepo()
	store := &putStore{objects: map[string][]byte{}}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Packages: packages, ExternalBaseURL: "https://bus.example.com"})

	in := codexInput()
	in.ExternalURL = "https://gh-proxy.com/https://github.com/x/y/releases/download/v1/Claude-mac-universal.dmg"
	in.FileSizeBytes = int64(len(payload))
	in.SHA256 = sha256Of(payload)
	v, _ := svc.Create(ctx, in)
	repo.rows[v.UUID].Status = dom.StatusCanary
	repo.rows[v.UUID].CanaryTenantIDs = []int64{581}

	// Different bytes: refused, row untouched.
	other := []byte(strings.Repeat("other", 100))
	if _, err := svc.UploadPackage(ctx, v.UUID, "Claude-mac-universal.dmg", "application/octet-stream", strings.NewReader(string(other)), int64(len(other)), 7); !errors.Is(err, dom.ErrMirrorMismatch) {
		t.Fatalf("mismatched upload: %v", err)
	}
	if got := repo.rows[v.UUID]; !strings.HasPrefix(got.StorageURI, "https://") || got.Status != dom.StatusCanary {
		t.Fatalf("row after refused upload: %+v", got)
	}
	// The same bytes: storage moves to the object store, status stays canary.
	done, err := svc.UploadPackage(ctx, v.UUID, "Claude-mac-universal.dmg", "application/octet-stream", strings.NewReader(string(payload)), int64(len(payload)), 7)
	if err != nil {
		t.Fatalf("matching upload: %v", err)
	}
	if !strings.HasPrefix(done.StorageURI, "oss://local-coding/"+v.UUID+"/") || done.Status != dom.StatusCanary || done.MirrorState != dom.MirrorStateDone || done.SHA256 != sha256Of(payload) {
		t.Fatalf("row after upload: %+v", done)
	}
	// Object-store-hosted published rows still cannot be re-uploaded.
	if _, err := svc.UploadPackage(ctx, v.UUID, "x.dmg", "application/octet-stream", strings.NewReader(string(payload)), int64(len(payload)), 7); !errors.Is(err, dom.ErrNotDraft) {
		t.Fatalf("re-upload of hosted published row: %v", err)
	}
}

func itoa(n int) string {
	return strings.TrimSpace(strings.Replace(strings.Repeat(" ", 0)+fmtInt(n), " ", "", -1))
}

func fmtInt(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

// lockedRepo serialises the fake repository for goroutine tests.
type lockedRepo struct {
	mu sync.Mutex
	*fakeRepo
}

func (r *lockedRepo) GetByUUID(ctx context.Context, uuid string) (*dom.Version, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.fakeRepo.GetByUUID(ctx, uuid)
}

func (r *lockedRepo) SetMirrorState(ctx context.Context, uuid, state, message string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.fakeRepo.SetMirrorState(ctx, uuid, state, message)
}

func (r *lockedRepo) ReplaceStorage(ctx context.Context, uuid, storageURI string, sizeBytes int64, sha256 string, actorID int64) (*dom.Version, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.fakeRepo.ReplaceStorage(ctx, uuid, storageURI, sizeBytes, sha256, actorID)
}

// "搬入全部外链" starts one copy per row at once; only mirrorConcurrency
// downloads run together (each spools a whole package to the temp dir), the
// rest wait for a slot and still complete.
func TestMirrorPackageLimitsConcurrentCopies(t *testing.T) {
	payload := []byte(strings.Repeat("pkg", 1024))
	var mu sync.Mutex
	inflight, peak := 0, 0
	release := make(chan struct{})
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		inflight++
		if inflight > peak {
			peak = inflight
		}
		mu.Unlock()
		<-release
		w.Header().Set("Content-Length", itoa(len(payload)))
		_, _ = w.Write(payload)
		mu.Lock()
		inflight--
		mu.Unlock()
	}))
	defer upstream.Close()

	ctx := context.Background()
	repo := &lockedRepo{fakeRepo: newFakeRepo()}
	store := &putStore{objects: map[string][]byte{}}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Packages: packages, HTTPClient: upstream.Client(), ExternalBaseURL: "https://bus.example.com"})

	const rows = 4
	uuids := make([]string, 0, rows)
	for i := 0; i < rows; i++ {
		in := codexInput()
		in.Version = "0.15" + itoa(i) + ".0"
		in.ExternalURL = upstream.URL + "/codex-" + in.Version + ".tgz"
		in.FileSizeBytes = int64(len(payload))
		in.SHA256 = sha256Of(payload)
		v, err := svc.Create(ctx, in)
		if err != nil {
			t.Fatal(err)
		}
		uuids = append(uuids, v.UUID)
	}
	for _, uuid := range uuids {
		if _, err := svc.MirrorPackage(ctx, uuid, 7); err != nil {
			t.Fatal(err)
		}
	}
	waitFor := func(what string, cond func() bool) {
		deadline := time.Now().Add(10 * time.Second)
		for !cond() {
			if time.Now().After(deadline) {
				t.Fatalf("timeout waiting for %s", what)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	waitFor("the first copies to start", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return inflight == mirrorConcurrency
	})
	// Give the queued copies a moment: they must not have started.
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	if peak != mirrorConcurrency {
		mu.Unlock()
		t.Fatalf("peak concurrent downloads = %d, want %d", peak, mirrorConcurrency)
	}
	mu.Unlock()
	close(release)
	waitFor("all copies to finish", func() bool {
		for _, uuid := range uuids {
			v, err := repo.GetByUUID(ctx, uuid)
			if err != nil || v.MirrorState != dom.MirrorStateDone {
				return false
			}
		}
		return true
	})
	mu.Lock()
	defer mu.Unlock()
	if peak != mirrorConcurrency {
		t.Fatalf("peak concurrent downloads after release = %d, want %d", peak, mirrorConcurrency)
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	if len(store.objects) != rows {
		t.Fatalf("objects written = %d, want %d", len(store.objects), rows)
	}
}

// An Admin restart mid-copy used to leave rows at running forever (the copy
// lived in the dead process). Startup recovery fails exactly those rows with
// an operator-facing reason; done / failed / uploaded rows are untouched, and
// the failed row can be mirrored again.
func TestRecoverInterruptedMirrorsFailsOrphanedRunningRows(t *testing.T) {
	payload := []byte(strings.Repeat("claude-2.1.267 ", 2048))
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", itoa(len(payload)))
		_, _ = w.Write(payload)
	}))
	defer upstream.Close()

	ctx := context.Background()
	repo := newFakeRepo()
	store := &putStore{objects: map[string][]byte{}}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Audit: &fakeAudit{}, Packages: packages, HTTPClient: upstream.Client(), MirrorSync: true, ExternalBaseURL: "https://bus.example.com"})

	external := func(version, state, message string) string {
		in := codexInput()
		in.Version = version
		in.ExternalURL = upstream.URL + "/codex-" + version + ".tgz"
		in.FileSizeBytes = int64(len(payload))
		in.SHA256 = sha256Of(payload)
		v, err := svc.Create(ctx, in)
		if err != nil {
			t.Fatal(err)
		}
		repo.rows[v.UUID].MirrorState, repo.rows[v.UUID].MirrorError = state, message
		return v.UUID
	}
	orphaned := external("0.154.0", dom.MirrorStateRunning, "")
	finished := external("0.154.1", dom.MirrorStateDone, "")
	failed := external("0.154.2", dom.MirrorStateFailed, "下载失败")
	uploaded := external("0.154.3", "", "")
	repo.rows[uploaded].StorageURI = "oss://local-coding/" + uploaded + "/codex.tgz"

	// While it is still running the operator cannot retry.
	if _, err := svc.MirrorPackage(ctx, orphaned, 7); !errors.Is(err, dom.ErrMirrorRunning) {
		t.Fatalf("mirror while running: %v", err)
	}

	n, err := svc.RecoverInterruptedMirrors(ctx)
	if err != nil || n != 1 {
		t.Fatalf("recover: n=%d err=%v", n, err)
	}
	got := repo.rows[orphaned]
	if got.MirrorState != dom.MirrorStateFailed || got.MirrorError != mirrorInterruptedMessage {
		t.Fatalf("orphaned row after recover: %s / %q", got.MirrorState, got.MirrorError)
	}
	for uuid, want := range map[string][2]string{finished: {dom.MirrorStateDone, ""}, failed: {dom.MirrorStateFailed, "下载失败"}, uploaded: {"", ""}} {
		if r := repo.rows[uuid]; r.MirrorState != want[0] || r.MirrorError != want[1] {
			t.Fatalf("row %s touched: %s / %q", uuid, r.MirrorState, r.MirrorError)
		}
	}
	// Nothing left to recover on a second run (e.g. the next restart).
	if n, err := svc.RecoverInterruptedMirrors(ctx); err != nil || n != 0 {
		t.Fatalf("second recover: n=%d err=%v", n, err)
	}

	// The operator retries the interrupted copy and it completes normally.
	done, err := svc.MirrorPackage(ctx, orphaned, 7)
	if err != nil {
		t.Fatalf("retry after recover: %v", err)
	}
	if done.MirrorState != dom.MirrorStateDone || done.MirrorError != "" || !strings.HasPrefix(done.StorageURI, "oss://local-coding/"+orphaned+"/") {
		t.Fatalf("retried row: %s / %q / %s", done.MirrorState, done.MirrorError, done.StorageURI)
	}
}
