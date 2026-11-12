package clientversion

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientversion"
)

func TestDeltaDownloadUsesRecordedKeyAcrossPrefixChanges(t *testing.T) {
	for _, tc := range []struct {
		name, uri, requested, wantKey string
		wantErr                       bool
	}{
		{name: "recorded prefix", uri: "oss://old-prefix/version/deltas/update.delta", requested: "update.delta", wantKey: "old-prefix/version/deltas/update.delta"},
		{name: "legacy record", requested: "update.delta", wantKey: "new-prefix/version/deltas/update.delta"},
		{name: "unregistered file", requested: "other.delta", wantErr: true},
		{name: "other release", uri: "oss://old-prefix/other/deltas/update.delta", requested: "update.delta", wantErr: true},
		{name: "noncanonical key", uri: "oss://old-prefix/../version/deltas/update.delta", requested: "update.delta", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &deltaSigningStore{}
			repo := &fakeRepo{version: &dom.Version{UUID: "version", Platform: dom.PlatformMacOS, Status: dom.StatusPublished, Deltas: []dom.DeltaInfo{{FileName: "update.delta", StorageURI: tc.uri}}}}
			svc := NewWithPackageStore(repo, NewPackageStoreWithResolver(deltaStorageResolver{store}, PackageStoreConfig{Prefix: "new-prefix/"}))
			got, err := svc.DownloadDeltaRedirectURL(context.Background(), "version", tc.requested)
			if tc.wantErr {
				if !errors.Is(err, dom.ErrInvalidDownloadAsset) || store.key != "" {
					t.Fatalf("got err=%v signed key=%q, want invalid asset without signing", err, store.key)
				}
				return
			}
			if err != nil || store.key != tc.wantKey || got != "https://storage.example/"+tc.wantKey {
				t.Fatalf("got url=%q key=%q err=%v, want key=%q", got, store.key, err, tc.wantKey)
			}
		})
	}
}

type deltaSigningStore struct {
	object.Store
	key string
}

func (s *deltaSigningStore) PresignGet(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	s.key = in.Key
	return &object.PresignGetOutput{URL: "https://storage.example/" + in.Key}, nil
}

type deltaStorageResolver struct{ store object.Store }

func (r deltaStorageResolver) Resolve(context.Context, int64) (object.Store, error) {
	return r.store, nil
}

func TestUploadDeltaRequiresSourceBuildAndValidEdDSASignature(t *testing.T) {
	svc := New(&fakeRepo{})
	body := bytes.NewBufferString("delta")

	_, err := svc.UploadDelta(context.Background(), "version", "update.delta", "application/octet-stream", body, 5, "", "signature")
	if !errors.Is(err, dom.ErrMissingDeltaFrom) {
		t.Fatalf("UploadDelta() error = %v, want %v", err, dom.ErrMissingDeltaFrom)
	}

	_, err = svc.UploadDelta(context.Background(), "version", "update.delta", "application/octet-stream", body, 5, "12102", "not-base64")
	if !errors.Is(err, dom.ErrInvalidDeltaSignature) {
		t.Fatalf("UploadDelta() error = %v, want %v", err, dom.ErrInvalidDeltaSignature)
	}

	validSignature := base64.StdEncoding.EncodeToString(make([]byte, 64))
	_, err = svc.UploadDelta(context.Background(), "version", "update.delta", "application/octet-stream", body, 5, "12102", validSignature)
	if !errors.Is(err, dom.ErrInstallerStoreMissing) {
		t.Fatalf("UploadDelta() error = %v, want storage validation after valid metadata", err)
	}
}

func TestNormalizeInputPublishedDownloadRequirement(t *testing.T) {
	tests := []struct {
		name     string
		platform string
		wantErr  error
	}{
		{name: "ios may publish without installer", platform: dom.PlatformIOS},
		{name: "macos still requires installer", platform: dom.PlatformMacOS, wantErr: dom.ErrMissingDownload},
		{name: "windows still requires installer", platform: dom.PlatformWindows, wantErr: dom.ErrMissingDownload},
		{name: "android still requires installer", platform: dom.PlatformAndroid, wantErr: dom.ErrMissingDownload},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := normalizeInput(dom.UpsertInput{
				Platform:    tt.platform,
				Version:     "1.0.0",
				BuildNumber: "100",
				Status:      dom.StatusPublished,
			})
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("normalizeInput() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestCompareRelease(t *testing.T) {
	tests := []struct {
		name         string
		leftVersion  string
		leftBuild    string
		rightVersion string
		rightBuild   string
		want         int
	}{
		{name: "build wins", leftVersion: "0.7.55", leftBuild: "756", rightVersion: "0.7.56", rightBuild: "755", want: 1},
		{name: "version fallback", leftVersion: "0.7.56", leftBuild: "", rightVersion: "0.7.55", rightBuild: "", want: 1},
		{name: "same", leftVersion: "0.7.56", leftBuild: "756", rightVersion: "0.7.56", rightBuild: "756", want: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CompareRelease(tt.leftVersion, tt.leftBuild, tt.rightVersion, tt.rightBuild)
			if got != tt.want {
				t.Fatalf("CompareRelease()=%d want %d", got, tt.want)
			}
		})
	}
}

func TestUpdateInfo(t *testing.T) {
	repo := &fakeRepo{
		candidates: []dom.Version{
			{UUID: "older", Platform: "macos", Arch: "universal", Channel: "stable", Version: "0.7.55", BuildNumber: "755", Status: dom.StatusPublished},
			{UUID: "latest", Platform: "macos", Arch: "universal", Channel: "stable", Version: "0.7.56", BuildNumber: "756", Status: dom.StatusPublished},
		},
	}
	svc := New(repo)
	info, err := svc.UpdateInfo(context.Background(), dom.UpdateQuery{
		Platform:           "macos",
		Arch:               "arm64",
		Channel:            "stable",
		CurrentVersion:     "0.7.55",
		CurrentBuildNumber: "755",
	})
	if err != nil {
		t.Fatalf("UpdateInfo() error = %v", err)
	}
	if !info.UpdateAvailable || info.Latest == nil || info.Latest.UUID != "latest" {
		t.Fatalf("UpdateInfo()=%+v want latest update", info)
	}

	info, err = svc.UpdateInfo(context.Background(), dom.UpdateQuery{
		Platform:           "macos",
		Arch:               "arm64",
		Channel:            "stable",
		CurrentVersion:     "0.7.56",
		CurrentBuildNumber: "756",
	})
	if err != nil {
		t.Fatalf("UpdateInfo() error = %v", err)
	}
	if info.UpdateAvailable || info.Latest != nil {
		t.Fatalf("UpdateInfo()=%+v want no update", info)
	}
}

type fakeRepo struct {
	candidates []dom.Version
	version    *dom.Version
}

func (r *fakeRepo) List(context.Context, dom.Filter) ([]dom.Version, int64, error) {
	return nil, 0, nil
}

func (r *fakeRepo) GetByUUID(context.Context, string) (*dom.Version, error) {
	return r.version, nil
}

func (r *fakeRepo) Create(context.Context, dom.UpsertInput) (*dom.Version, error) {
	return nil, nil
}

func (r *fakeRepo) Update(context.Context, string, dom.UpsertInput) (*dom.Version, error) {
	return nil, nil
}

func (r *fakeRepo) Delete(context.Context, string, int64) error {
	return nil
}

func (r *fakeRepo) ListPublishedCandidates(context.Context, string, string, string) ([]dom.Version, error) {
	return r.candidates, nil
}

func (r *fakeRepo) AppendDelta(context.Context, string, dom.DeltaInfo) error {
	return nil
}

var _ dom.Repository = (*fakeRepo)(nil)

// 发版真机（macOS 1.2.1+12100、Windows 1.2.0+12017）：上传安装包后点保存，库里
// 的大小与哈希被写回 0 / 空，appcast 的 length 就是 0，客户端更新校验必失败。
// 保存带的是整条记录，包本身没换时不能让空值覆盖上传记下来的值。
func TestUpdateKeepsUploadedPackageFactsWhenSaveOmitsThem(t *testing.T) {
	const uri = "oss://client-installers/abc/zhiban-setup-1.2.0.12017.exe"
	current := &dom.Version{
		UUID: "v1", Platform: dom.PlatformWindows, Arch: dom.ArchUniversal, Channel: dom.ChannelStable,
		Version: "1.2.0", BuildNumber: "12017", Status: dom.StatusDraft,
		DownloadURL: uri, FileSizeBytes: 334700151, SHA256: "ecda3bdf",
	}
	repo := &savingRepo{current: current}
	svc := New(repo)

	saved, err := svc.Update(context.Background(), "v1", dom.UpsertInput{
		Platform: dom.PlatformWindows, Arch: dom.ArchUniversal, Channel: dom.ChannelStable,
		Version: "1.2.0", BuildNumber: "12017", Status: dom.StatusDraft,
		DownloadURL: uri, SparkleEDSignature: "T23xXHgk",
	})
	if err != nil {
		t.Fatalf("Update() error = %v", err)
	}
	if repo.saved.FileSizeBytes != 334700151 || repo.saved.SHA256 != "ecda3bdf" {
		t.Fatalf("saved package facts = %d / %q", repo.saved.FileSizeBytes, repo.saved.SHA256)
	}
	if saved.SparkleEDSignature != "T23xXHgk" {
		t.Fatalf("signature not saved: %+v", saved)
	}

	// A different package (an address typed by hand) may legitimately have none.
	if _, err := svc.Update(context.Background(), "v1", dom.UpsertInput{
		Platform: dom.PlatformWindows, Arch: dom.ArchUniversal, Channel: dom.ChannelStable,
		Version: "1.2.0", BuildNumber: "12017", Status: dom.StatusDraft,
		DownloadURL: "https://example.cn/win/other.exe",
	}); err != nil {
		t.Fatalf("Update() with another package error = %v", err)
	}
	if repo.saved.FileSizeBytes != 0 || repo.saved.SHA256 != "" {
		t.Fatalf("a replaced package kept stale facts: %d / %q", repo.saved.FileSizeBytes, repo.saved.SHA256)
	}
}

type savingRepo struct {
	fakeRepo
	current *dom.Version
	saved   dom.UpsertInput
}

func (r *savingRepo) GetByUUID(context.Context, string) (*dom.Version, error) { return r.current, nil }

func (r *savingRepo) Update(_ context.Context, _ string, in dom.UpsertInput) (*dom.Version, error) {
	r.saved = in
	item := *r.current
	item.DownloadURL = in.DownloadURL
	item.FileSizeBytes = in.FileSizeBytes
	item.SHA256 = in.SHA256
	item.SparkleEDSignature = in.SparkleEDSignature
	return &item, nil
}
