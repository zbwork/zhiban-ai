package media

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
)

func TestUploadSkillIconUsesContentAddressedKey(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	out, err := svc.Upload(context.Background(), UploadInput{
		Kind:        KindSkillIcon,
		Body:        strings.NewReader("image-bytes"),
		ContentType: "image/png",
	})
	if err != nil {
		t.Fatalf("Upload returned error: %v", err)
	}
	if !strings.HasPrefix(out.StorageKey, "skill-icons/") || !strings.HasSuffix(out.StorageKey, ".png") {
		t.Fatalf("unexpected storage key: %q", out.StorageKey)
	}
	if out.StorageURI != "oss://"+out.StorageKey {
		t.Fatalf("unexpected storage uri: %q", out.StorageURI)
	}
	if store.putKey != out.StorageKey {
		t.Fatalf("PutObject key mismatch: got %q want %q", store.putKey, out.StorageKey)
	}
}

func TestResolveURLMapDeduplicatesRepeatedURIs(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	uri := "oss://skill-icons/reused.png"
	out := svc.ResolveURLMap(context.Background(), []string{uri, uri, "https://cdn.example/icon.png"})
	if out[uri] != "https://media.local/skill-icons/reused.png" {
		t.Fatalf("unexpected resolved URL: %q", out[uri])
	}
	if got := store.presignGetCalls[uri]; got != 1 {
		t.Fatalf("expected one presign for duplicated uri, got %d", got)
	}
	if got := len(out); got != 2 {
		t.Fatalf("expected two unique outputs, got %d", got)
	}
}

func TestSkillExampleImageUsesDedicatedPrefixAndLimit(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	out, err := svc.Upload(context.Background(), UploadInput{
		Kind:        KindSkillExampleImage,
		Body:        strings.NewReader("example-image-bytes"),
		ContentType: "image/webp",
	})
	if err != nil {
		t.Fatalf("Upload returned error: %v", err)
	}
	if !strings.HasPrefix(out.StorageKey, "skill-example-images/") || !strings.HasSuffix(out.StorageKey, ".webp") {
		t.Fatalf("unexpected storage key: %q", out.StorageKey)
	}
}

func TestAgentAvatarAcceptsFiveMiB(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	out, err := svc.Upload(context.Background(), UploadInput{
		Kind:        KindAgentAvatar,
		Body:        strings.NewReader(strings.Repeat("a", 5*1024*1024)),
		ContentType: "image/png",
	})
	if err != nil {
		t.Fatalf("Upload avatar at 5MiB returned error: %v", err)
	}
	if out.Size != 5*1024*1024 {
		t.Fatalf("unexpected size: got %d", out.Size)
	}
	if !strings.HasPrefix(out.StorageKey, "agent-avatars/") {
		t.Fatalf("unexpected avatar key: %q", out.StorageKey)
	}
}

func TestAgentAvatarRejectsAboveFiveMiB(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	_, err := svc.Upload(context.Background(), UploadInput{
		Kind:        KindAgentAvatar,
		Body:        strings.NewReader(strings.Repeat("a", 5*1024*1024+1)),
		ContentType: "image/png",
	})
	if err == nil || !strings.Contains(err.Error(), "media.too_large") {
		t.Fatalf("expected media.too_large, got %v", err)
	}
}

type fakeStore struct {
	putKey          string
	presignGetCalls map[string]int
}

func (f *fakeStore) PutObject(_ context.Context, key string, body io.Reader, _ int64, _ string) error {
	f.putKey = key
	_, _ = io.ReadAll(body)
	return nil
}

func (f *fakeStore) Kind() string { return "fake" }

func (f *fakeStore) PresignPut(context.Context, object.PresignPutInput) (*object.PresignPutOutput, error) {
	return nil, nil
}

func (f *fakeStore) PresignGet(_ context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	if f.presignGetCalls == nil {
		f.presignGetCalls = map[string]int{}
	}
	f.presignGetCalls["oss://"+in.Key]++
	return &object.PresignGetOutput{
		URL:       "https://media.local/" + in.Key,
		ExpiresAt: time.Now().Add(time.Hour),
	}, nil
}

func (f *fakeStore) Delete(context.Context, string) error { return nil }

func (f *fakeStore) Stat(context.Context, string) (*object.Stat, error) { return nil, nil }

func (f *fakeStore) Copy(context.Context, string, string) error { return nil }

func (f *fakeStore) InitMultipart(context.Context, string, string) (string, error) { return "", nil }

func (f *fakeStore) PresignPart(context.Context, string, string, int, time.Duration) (string, error) {
	return "", nil
}

func (f *fakeStore) CompleteMultipart(context.Context, string, string, []object.MultipartPart) error {
	return nil
}

func (f *fakeStore) AbortMultipart(context.Context, string, string) error { return nil }

// --- resolver-backed tests ---

type fakeResolver struct {
	store    object.Store
	err      error
	resolved int
}

func (r *fakeResolver) Resolve(_ context.Context, _ int64) (object.Store, error) {
	r.resolved++
	return r.store, r.err
}

// noPutterStore implements object.Store but NOT Putter (no PutObject method).
type noPutterStore struct{}

func (noPutterStore) Kind() string { return "no-putter" }
func (noPutterStore) PresignPut(context.Context, object.PresignPutInput) (*object.PresignPutOutput, error) {
	return nil, nil
}
func (noPutterStore) PresignGet(context.Context, object.PresignGetInput) (*object.PresignGetOutput, error) {
	return nil, nil
}
func (noPutterStore) Delete(context.Context, string) error                          { return nil }
func (noPutterStore) Stat(context.Context, string) (*object.Stat, error)            { return nil, nil }
func (noPutterStore) Copy(context.Context, string, string) error                    { return nil }
func (noPutterStore) InitMultipart(context.Context, string, string) (string, error) { return "", nil }
func (noPutterStore) PresignPart(context.Context, string, string, int, time.Duration) (string, error) {
	return "", nil
}
func (noPutterStore) CompleteMultipart(context.Context, string, string, []object.MultipartPart) error {
	return nil
}
func (noPutterStore) AbortMultipart(context.Context, string, string) error { return nil }

func TestNewWithResolver_UploadForTenant_UsesResolver(t *testing.T) {
	store := &fakeStore{}
	r := &fakeResolver{store: store}
	svc := NewWithResolver(r, Config{})
	out, err := svc.UploadForTenant(context.Background(), 0, UploadInput{
		Kind:        KindSkillIcon,
		Body:        strings.NewReader("img"),
		ContentType: "image/png",
	})
	if err != nil {
		t.Fatalf("UploadForTenant error: %v", err)
	}
	if !strings.HasPrefix(out.StorageKey, "skill-icons/") {
		t.Fatalf("unexpected key: %q", out.StorageKey)
	}
	if r.resolved < 1 {
		t.Fatalf("resolver was not called")
	}
}

func TestUploadForTenant_NonPutterStore_ReturnsError(t *testing.T) {
	nps := &noPutterStore{}
	r := &fakeResolver{store: nps}
	svc := NewWithResolver(r, Config{})
	_, err := svc.UploadForTenant(context.Background(), 0, UploadInput{
		Kind:        KindAgentAvatar,
		Body:        strings.NewReader("img"),
		ContentType: "image/png",
	})
	if err == nil || !strings.Contains(err.Error(), "does not support PutObject") {
		t.Fatalf("expected PutObject error, got: %v", err)
	}
}

func TestResolveURLForTenant_OSSPrefix_SignsURL(t *testing.T) {
	store := &fakeStore{}
	r := &fakeResolver{store: store}
	svc := NewWithResolver(r, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "oss://skill-icons/abc.png")
	if got != "https://media.local/skill-icons/abc.png" {
		t.Fatalf("unexpected URL: %q", got)
	}
}

func TestResolveURLForTenant_SignFail_ReturnsEmpty(t *testing.T) {
	r := &fakeResolver{err: io.ErrUnexpectedEOF}
	svc := NewWithResolver(r, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "oss://agent-avatars/fail.png")
	if got != "" {
		t.Fatalf("expected empty on resolver failure, got %q", got)
	}
}

func TestResolveURLForTenant_DisallowedPrefix_ReturnsEmpty(t *testing.T) {
	store := &fakeStore{}
	r := &fakeResolver{store: store}
	svc := NewWithResolver(r, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "oss://secret-bucket/key.png")
	if got != "" {
		t.Fatalf("expected empty for disallowed prefix, got %q", got)
	}
}

func TestResolveURLForTenant_HTTPPassthrough(t *testing.T) {
	svc := NewWithResolver(&fakeResolver{}, Config{})
	for _, url := range []string{"https://cdn.example/img.png", "http://old.host/avatar.jpg"} {
		got := svc.ResolveURLForTenant(context.Background(), 0, url)
		if got != url {
			t.Fatalf("expected passthrough %q, got %q", url, got)
		}
	}
}

func TestResolveURLForTenant_EmptyPassthrough(t *testing.T) {
	svc := NewWithResolver(&fakeResolver{}, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "")
	if got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

func TestResolveURLForTenant_BareStorageKey_ReturnsEmpty(t *testing.T) {
	store := &fakeStore{}
	r := &fakeResolver{store: store}
	svc := NewWithResolver(r, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "account-avatars/1/2/x.png")
	if got != "" {
		t.Fatalf("expected empty for bare storage_key, got %q", got)
	}
}

func TestResolveURLForTenant_APIPassthrough(t *testing.T) {
	svc := NewWithResolver(&fakeResolver{}, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "/api/agent-bus/v1/assets/app-icons/icon.png")
	if got != "/api/agent-bus/v1/assets/app-icons/icon.png" {
		t.Fatalf("expected /api/ passthrough, got %q", got)
	}
}

func TestFallbackToFixedStore(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	got := svc.ResolveURLForTenant(context.Background(), 0, "oss://skill-icons/abc.png")
	if got != "https://media.local/skill-icons/abc.png" {
		t.Fatalf("expected fixed store fallback, got %q", got)
	}
}

func TestUpload_DelegatesToUploadForTenant(t *testing.T) {
	store := &fakeStore{}
	svc := New(store, store, Config{})
	out, err := svc.Upload(context.Background(), UploadInput{
		Kind:        KindSkillIcon,
		Body:        strings.NewReader("img"),
		ContentType: "image/png",
	})
	if err != nil {
		t.Fatalf("Upload error: %v", err)
	}
	if !strings.HasPrefix(out.StorageKey, "skill-icons/") {
		t.Fatalf("unexpected key: %q", out.StorageKey)
	}
}
