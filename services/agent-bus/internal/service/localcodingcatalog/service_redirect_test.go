package localcodingcatalog

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
)

// presignStore is an object store that only knows how to presign GET URLs on
// a fixed host; every other method is unimplemented and must not be called.
type presignStore struct {
	object.Store
	host         string
	scheme       string // "" = https
	internalHost string // host of the in-cluster endpoint; "" = none
	calls        int
}

func (s *presignStore) PresignGetInternal(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	if s.internalHost == "" {
		return s.PresignGet(context.Background(), in)
	}
	return &object.PresignGetOutput{URL: "http://" + s.internalHost + "/" + in.Key + "?sig=internal", ExpiresAt: time.Now().Add(in.TTL)}, nil
}

func (s *presignStore) Kind() string { return "fake" }

func (s *presignStore) PresignGet(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	s.calls++
	scheme := s.scheme
	if scheme == "" {
		scheme = "https"
	}
	return &object.PresignGetOutput{URL: scheme + "://" + s.host + "/" + in.Key + "?sig=x", ExpiresAt: time.Now().Add(in.TTL)}, nil
}

type presignResolver struct{ store object.Store }

func (r presignResolver) Resolve(context.Context, int64) (object.Store, error) { return r.store, nil }

// The Bridge follows the Bus redirect to the object store's presigned URL,
// so that host must be in the catalog allow-list next to the Bus host.
func TestCatalogAllowsPresignedRedirectHost(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	signer, _ := newTestSigner(t)
	store := &presignStore{host: "zhiban-test.oss-cn-beijing.aliyuncs.com"}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Signer: signer, Packages: packages, ExternalBaseURL: "https://bus.example.com"})

	cur, _ := svc.Create(ctx, codexInput())
	withPackage(repo, cur.UUID)
	if _, err := svc.Publish(ctx, cur.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	signed, err := svc.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[bus.example.com zhiban-test.oss-cn-beijing.aliyuncs.com]" {
		t.Fatalf("allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
	// The package URL itself stays the Bus redirect.
	if src := signed.Catalog.Targets["codex_cli"].Current.Sources[0]; src.URL != "https://bus.example.com"+PackagePathPrefix+cur.UUID+"/download" {
		t.Fatalf("source url: %s", src.URL)
	}
	// Learned once: a second catalog does not presign again.
	if _, err := svc.Catalog(ctx, 2, "macos", "arm64"); err != nil {
		t.Fatal(err)
	}
	if store.calls != 1 {
		t.Fatalf("presign calls = %d, want 1", store.calls)
	}

	// With a CDN front the redirect is not used and the CDN host is listed instead.
	cdn := New(Deps{Repo: repo, Signer: signer, Packages: packages, ExternalBaseURL: "https://bus.example.com", PublicBaseURL: "https://dl.example.cn"})
	signed, err = cdn.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[dl.example.cn]" {
		t.Fatalf("cdn allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
}

// The test environment's object store only speaks http and the Bridge follows
// https alone: such packages are streamed by the Bus (Proxy) and the catalog
// lists just the Bus host. An https store keeps the redirect; external links
// are public already.
func TestPackageLocationProxiesHTTPOnlyStore(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	signer, _ := newTestSigner(t)
	plain := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: &presignStore{host: "s3.test.example", scheme: "http", internalHost: "minio.storage.svc:9000"}}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{Repo: repo, Signer: signer, Packages: plain, ExternalBaseURL: "https://bus.example.com"})

	cur, _ := svc.Create(ctx, codexInput())
	withPackage(repo, cur.UUID)
	if _, err := svc.PackageLocation(ctx, cur.UUID); !errors.Is(err, dom.ErrPackageNotDownloadable) {
		t.Fatalf("draft location: %v", err)
	}
	if _, err := svc.Publish(ctx, cur.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	location, err := svc.PackageLocation(ctx, cur.UUID)
	if err != nil {
		t.Fatal(err)
	}
	// Proxied: the relay reads through the in-cluster endpoint, never the
	// public read host the pod cannot reach.
	if !location.Proxy || !strings.HasPrefix(location.URL, "http://minio.storage.svc:9000/local-coding/"+cur.UUID+"/codex.tar.gz?") || location.FileName != "codex.tar.gz" {
		t.Fatalf("http store location: %+v", location)
	}
	// A store without a separate internal endpoint is read where it is signed.
	single := New(Deps{Repo: repo, Signer: signer, ExternalBaseURL: "https://bus.example.com",
		Packages: svcclientversion.NewPackageStoreWithResolver(presignResolver{store: &presignStore{host: "s3.test.example", scheme: "http"}}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})})
	if loc, err := single.PackageLocation(ctx, cur.UUID); err != nil || !loc.Proxy || !strings.HasPrefix(loc.URL, "http://s3.test.example/local-coding/") {
		t.Fatalf("single-endpoint location: %+v %v", loc, err)
	}
	signed, err := svc.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[bus.example.com]" {
		t.Fatalf("allowed hosts with http store: %v", signed.Catalog.AllowedHosts)
	}

	secure := New(Deps{Repo: repo, Signer: signer, ExternalBaseURL: "https://bus.example.com",
		Packages: svcclientversion.NewPackageStoreWithResolver(presignResolver{store: &presignStore{host: "oss.example.cn"}}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})})
	location, err = secure.PackageLocation(ctx, cur.UUID)
	if err != nil {
		t.Fatal(err)
	}
	if location.Proxy || !strings.HasPrefix(location.URL, "https://oss.example.cn/") {
		t.Fatalf("https store location: %+v", location)
	}

	external := codexInput()
	external.Version = "0.155.0"
	external.ExternalURL = "https://registry.npmmirror.com/@openai/codex/-/codex-0.155.0-darwin-arm64.tgz"
	external.FileSizeBytes = 10
	external.SHA256 = sha
	v, err := svc.Create(ctx, external)
	if err != nil {
		t.Fatal(err)
	}
	repo.rows[v.UUID].Status = dom.StatusCanary
	location, err = svc.PackageLocation(ctx, v.UUID)
	if err != nil {
		t.Fatal(err)
	}
	if location.Proxy || location.URL != external.ExternalURL {
		t.Fatalf("external location: %+v", location)
	}
}
