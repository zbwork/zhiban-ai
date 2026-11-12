package localcodingcatalog

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

// The signature must assemble exactly as the PaaS "签名算法" page shows:
// accessKey ":" k=v pairs sorted by key joined with "&" (values verbatim,
// booleans spelled out) ":" timestamp ":" nonce ":" secret, then MD5.
func TestShareSignFollowsPlatformAlgorithm(t *testing.T) {
	docs := shareSign("BVH2XY6PR2R2YJSJZ2", "eD5oM6hoM5LD7ntkb1T4uKAzNH5KgPj5zH15g9", map[string]string{
		"bucket": "dawn-public-read", "name": "dawn", "public": "true", "sharer": "congwang",
		"targetPath": "02 _ 给你一张知识地图，计算机组成原理应该这么学.pdf", "validTime": "120",
	}, 1625726140, "0019")
	// md5("BVH2XY6PR2R2YJSJZ2:bucket=dawn-public-read&name=dawn&public=true&sharer=congwang&targetPath=02 _ 给你一张知识地图，计算机组成原理应该这么学.pdf&validTime=120:1625726140:0019:eD5oM6hoM5LD7ntkb1T4uKAzNH5KgPj5zH15g9")
	if docs != "0f2d931fc695a87f1a726c39310a1c5b" {
		t.Fatalf("documentation vector: %s", docs)
	}
	ours := shareSign("AKTEST", "SKTEST", map[string]string{
		"bucket": "agent-bus-public-read", "name": "agent-bus", "public": "true", "sharer": "ops@example.com",
		"targetPath": "local-coding/u1/a.tgz", "validTime": "525600",
	}, 1700000000, "n0nce")
	if ours != "74c539402ca4f0202ab21ad96f991d9d" {
		t.Fatalf("catalog vector: %s", ours)
	}
}

func TestShareURLHelpers(t *testing.T) {
	if got, err := publicShareURL("http://pan.example.test/s/AbC/origin", "s3.example.cn"); err != nil || got != "https://s3.example.cn/s/AbC/origin" {
		t.Fatalf("host swap: %q %v", got, err)
	}
	if got, err := publicShareURL("http://pan.example.test/s/AbC/origin", ""); err != nil || got != "http://pan.example.test/s/AbC/origin" {
		t.Fatalf("verbatim: %q %v", got, err)
	}
	for _, bad := range []string{"", "http://host/", "not a url"} {
		if _, err := publicShareURL(bad, "s3.example.cn"); err == nil {
			t.Fatalf("%q must be rejected", bad)
		}
	}
	if got := shareCodeOf("http://h/s/AbC", "http://h/s/AbC/origin"); got != "AbC" {
		t.Fatalf("code from share url: %s", got)
	}
	if got := shareCodeOf("", "http://h/s/AbC/origin"); got != "AbC" {
		t.Fatalf("code from origin: %s", got)
	}
	if got := shareCodeOf("", ""); got != "" {
		t.Fatalf("no code: %q", got)
	}
	if shareProjectOf("agent-bus-public-read") != "agent" || shareProjectOf("paas") != "paas" {
		t.Fatal("project defaults to the bucket name before the first dash")
	}
}

type fakeShareService struct {
	srv      *httptest.Server
	fail     bool
	calls    int
	query    url.Values
	body     map[string]any
	origin   string
	shareURL string
}

func newFakeShareService(t *testing.T) *fakeShareService {
	t.Helper()
	f := &fakeShareService{origin: "http://pan.example.test/s/AbC123/origin", shareURL: "http://pan.example.test/s/AbC123"}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls++
		if r.URL.Path != "/share/gen" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		f.query = r.URL.Query()
		f.body = map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&f.body)
		w.Header().Set("Content-Type", "application/json")
		if f.fail {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `{"success":false,"code":500,"message":"boom","traceId":"t1"}`)
			return
		}
		fmt.Fprintf(w, `{"success":true,"code":200,"data":{"origin":%q,"url":%q,"intranet":"http://pan.idc/s/AbC123/origin"}}`, f.origin, f.shareURL)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func TestRefreshShareLinksAndCatalogHandOut(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	signer, _ := newTestSigner(t)
	now := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	share := newFakeShareService(t)
	svc := New(Deps{
		Repo: repo, Signer: signer, ExternalBaseURL: "https://bus.example.com",
		Now:   func() time.Time { return now },
		Share: &ShareConfig{APIBaseURL: share.srv.URL + "/", PublicHost: "s3.example.cn", Sharer: "ops@example.com"},
		ShareCredentials: func(context.Context) (string, string, string, error) {
			return "agent-bus-public-read", "AKTEST", "SKTEST", nil
		},
	})

	cur, _ := svc.Create(ctx, codexInput())
	withPackage(repo, cur.UUID)
	if _, err := svc.Publish(ctx, cur.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	draftIn := codexInput()
	draftIn.Version = "0.155.0"
	draft, _ := svc.Create(ctx, draftIn)
	withPackage(repo, draft.UUID)
	ext, err := svc.Create(ctx, dom.UpsertInput{
		TargetID: "claude_desktop", Platform: "macos", Arch: "universal", Version: "1.46388.4", Layout: "app_bundle_dmg",
		ContractCheckRef: "ok", ExternalURL: "https://dl.example.cn/local-coding/claude.dmg", FileSizeBytes: 353897855, SHA256: sha,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Publish(ctx, ext.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}

	// Only the published object-store row is a candidate; the draft and the
	// external package are not.
	report, err := svc.RefreshShareLinks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Candidates != 1 || report.Generated != 1 || len(report.Failures) != 0 || share.calls != 1 {
		t.Fatalf("first pass: %+v calls=%d", report, share.calls)
	}
	// The request is what the platform documents: bucket AK in the query, a
	// nonce, the timestamp, and a signature over the sorted body fields.
	key := "local-coding/" + cur.UUID + "/codex.tar.gz"
	nonce := share.query.Get("nonce")
	if share.query.Get("accessKey") != "AKTEST" || nonce == "" || share.query.Get("timestamp") != fmt.Sprint(now.Unix()) {
		t.Fatalf("query: %v", share.query)
	}
	wantSign := shareSign("AKTEST", "SKTEST", map[string]string{
		"bucket": "agent-bus-public-read", "targetPath": key, "validTime": "525600",
		"sharer": "ops@example.com", "name": "agent", "public": "true",
	}, now.Unix(), nonce)
	if share.query.Get("sign") != wantSign {
		t.Fatalf("signature mismatch: %s", share.query.Get("sign"))
	}
	if share.body["bucket"] != "agent-bus-public-read" || share.body["targetPath"] != key || share.body["validTime"] != float64(525600) ||
		share.body["sharer"] != "ops@example.com" || share.body["name"] != "agent" || share.body["public"] != true {
		t.Fatalf("body: %v", share.body)
	}
	// Stored with the CDN host and https, the code, and the computed expiry.
	row := repo.rows[cur.UUID]
	wantExpiry := now.Add(365 * 24 * time.Hour)
	if row.ShareCode != "AbC123" || row.ShareURL != "https://s3.example.cn/s/AbC123/origin" || row.ShareExpiresAt == nil || !row.ShareExpiresAt.Equal(wantExpiry) {
		t.Fatalf("stored link: %+v", row)
	}
	if repo.rows[draft.UUID].ShareURL != "" || repo.rows[ext.UUID].ShareURL != "" {
		t.Fatal("draft / external rows must not get share links")
	}
	// The catalog hands the share link out and allow-lists its host; the
	// external package keeps its own host.
	signed, err := svc.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if got := signed.Catalog.Targets["codex_cli"].Current.Sources[0].URL; got != "https://s3.example.cn/s/AbC123/origin" {
		t.Fatalf("catalog source: %s", got)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[dl.example.cn s3.example.cn]" {
		t.Fatalf("allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
	// A fresh link is left alone on the next pass.
	if report, _ = svc.RefreshShareLinks(ctx); report.Candidates != 0 || share.calls != 1 {
		t.Fatalf("second pass must be idle: %+v calls=%d", report, share.calls)
	}

	// 8 days before expiry: still more than the catalog TTL left, still handed out.
	now = wantExpiry.Add(-8 * 24 * time.Hour)
	signed, _ = svc.Catalog(ctx, 1, "macos", "arm64")
	if got := signed.Catalog.Targets["codex_cli"].Current.Sources[0].URL; !strings.HasPrefix(got, "https://s3.example.cn/") {
		t.Fatalf("8 days left must still use the share link: %s", got)
	}
	// 6 days before expiry: the catalog falls back to the Bus redirect, and
	// the refresh (inside the 10-day window) fails → row keeps the old link.
	now = wantExpiry.Add(-6 * 24 * time.Hour)
	signed, _ = svc.Catalog(ctx, 1, "macos", "arm64")
	if got := signed.Catalog.Targets["codex_cli"].Current.Sources[0].URL; got != "https://bus.example.com/api/agent-bus/v1/local-coding-tools/packages/"+cur.UUID+"/download" {
		t.Fatalf("6 days left must fall back to the redirect: %s", got)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[bus.example.com dl.example.cn]" {
		t.Fatalf("fallback allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
	share.fail = true
	report, err = svc.RefreshShareLinks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Candidates != 1 || report.Generated != 0 || len(report.Failures) != 1 || !strings.Contains(report.Failures[0], "HTTP 500 code 500: boom") {
		t.Fatalf("failed pass: %+v", report)
	}
	if row := repo.rows[cur.UUID]; row.ShareURL != "https://s3.example.cn/s/AbC123/origin" || !row.ShareExpiresAt.Equal(wantExpiry) {
		t.Fatalf("failure must not touch the row: %+v", row)
	}
	// Service back: regenerated with a new expiry, catalog uses it again.
	share.fail = false
	share.origin, share.shareURL = "http://pan.example.test/s/NeW456/origin", "http://pan.example.test/s/NeW456"
	if report, _ = svc.RefreshShareLinks(ctx); report.Generated != 1 {
		t.Fatalf("regeneration: %+v", report)
	}
	if row := repo.rows[cur.UUID]; row.ShareCode != "NeW456" || !row.ShareExpiresAt.Equal(now.Add(365*24*time.Hour)) {
		t.Fatalf("regenerated link: %+v", row)
	}
	signed, _ = svc.Catalog(ctx, 1, "macos", "arm64")
	if got := signed.Catalog.Targets["codex_cli"].Current.Sources[0].URL; got != "https://s3.example.cn/s/NeW456/origin" {
		t.Fatalf("catalog after regeneration: %s", got)
	}
	// Replacing the package drops the link (it pointed at the old object).
	if _, err := repo.SetPackage(ctx, cur.UUID, dom.PackageInput{StorageURI: "oss://local-coding/" + cur.UUID + "/v2.tar.gz", FileSizeBytes: 1, SHA256: sha}); err != nil {
		t.Fatal(err)
	}
	if row := repo.rows[cur.UUID]; row.ShareURL != "" || row.ShareExpiresAt != nil {
		t.Fatalf("package change must clear the link: %+v", row)
	}
}

func TestShareLinksDisabledOrNotHTTPS(t *testing.T) {
	ctx := context.Background()
	// Not configured: a no-op, no store access, no requests.
	repo := newFakeRepo()
	svc := New(Deps{Repo: repo})
	if report, err := svc.RefreshShareLinks(ctx); err != nil || report.Candidates != 0 || report.Generated != 0 {
		t.Fatalf("disabled: %+v %v", report, err)
	}

	// Test environment shape: no public host configured and the share
	// service answers with http. The link is recorded (visible in Admin) but
	// the catalog never hands out a non-https address.
	signer, _ := newTestSigner(t)
	now := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	share := newFakeShareService(t)
	svc = New(Deps{
		Repo: repo, Signer: signer, ExternalBaseURL: "https://bus.example.com",
		Now:   func() time.Time { return now },
		Share: &ShareConfig{APIBaseURL: share.srv.URL, Sharer: "ops@example.com", ValidFor: 30 * 24 * time.Hour, Project: "zb"},
		ShareCredentials: func(context.Context) (string, string, string, error) {
			return "agent-bus-public-read", "AKTEST", "SKTEST", nil
		},
	})
	cur, _ := svc.Create(ctx, codexInput())
	withPackage(repo, cur.UUID)
	if _, err := svc.Publish(ctx, cur.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	if report, err := svc.RefreshShareLinks(ctx); err != nil || report.Generated != 1 {
		t.Fatalf("http link generation: %+v %v", report, err)
	}
	if share.body["validTime"] != float64(30*24*60) || share.body["name"] != "zb" {
		t.Fatalf("configured validity / project: %v", share.body)
	}
	row := repo.rows[cur.UUID]
	if row.ShareURL != "http://pan.example.test/s/AbC123/origin" || !row.ShareExpiresAt.Equal(now.Add(30*24*time.Hour)) {
		t.Fatalf("http link stored verbatim: %+v", row)
	}
	signed, err := svc.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if got := signed.Catalog.Targets["codex_cli"].Current.Sources[0].URL; !strings.HasPrefix(got, "https://bus.example.com/") {
		t.Fatalf("http share link must not be handed out: %s", got)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[bus.example.com]" {
		t.Fatalf("allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
	// Credential resolution failure is reported, not swallowed.
	svc = New(Deps{
		Repo: repo, Share: &ShareConfig{APIBaseURL: share.srv.URL, Sharer: "ops@example.com"},
		Now: func() time.Time { return now.Add(400 * 24 * time.Hour) },
		ShareCredentials: func(context.Context) (string, string, string, error) {
			return "", "", "", fmt.Errorf("no platform storage")
		},
	})
	if _, err := svc.RefreshShareLinks(ctx); err == nil || !strings.Contains(err.Error(), "no platform storage") {
		t.Fatalf("credential failure: %v", err)
	}
}
