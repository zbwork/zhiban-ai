package clientversion

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"mime"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientversion"
)

type Putter interface {
	PutObject(ctx context.Context, key string, body io.Reader, contentLength int64, contentType string) error
}

type StorageResolver interface {
	Resolve(ctx context.Context, tenantID int64) (object.Store, error)
}

type PackageStoreConfig struct {
	Prefix   string
	MaxBytes int64
	SignTTL  time.Duration
}

type PackageStore struct {
	resolver StorageResolver
	cfg      PackageStoreConfig
}

type UploadResult struct {
	StorageURI  string `json:"storage_uri"`
	DownloadURL string `json:"download_url"`
	FileName    string `json:"file_name"`
	SizeBytes   int64  `json:"size_bytes"`
	SHA256      string `json:"sha256"`
}

func NewPackageStoreWithResolver(resolver StorageResolver, cfg PackageStoreConfig) *PackageStore {
	if cfg.Prefix == "" {
		cfg.Prefix = "client-installers/"
	}
	if !strings.HasSuffix(cfg.Prefix, "/") {
		cfg.Prefix += "/"
	}
	if cfg.MaxBytes <= 0 {
		cfg.MaxBytes = 1 * 1024 * 1024 * 1024
	}
	if cfg.SignTTL <= 0 {
		cfg.SignTTL = time.Hour
	}
	return &PackageStore{resolver: resolver, cfg: cfg}
}

func (p *PackageStore) Upload(ctx context.Context, versionUUID, filename string, body io.Reader, size int64, contentType string) (*UploadResult, error) {
	if p == nil || p.resolver == nil {
		return nil, errors.New("client installer store not configured")
	}
	if strings.TrimSpace(versionUUID) == "" {
		return nil, errors.New("client installer upload: version uuid required")
	}
	if body == nil {
		return nil, errors.New("client installer upload: empty body")
	}
	if size <= 0 {
		return nil, errors.New("client installer upload: empty file")
	}
	if size > p.cfg.MaxBytes {
		return nil, fmt.Errorf("client installer too large: %d > %d", size, p.cfg.MaxBytes)
	}
	name := sanitizeFilename(filename)
	ct := normalizeContentType(name, contentType)
	key := path.Join(strings.TrimSuffix(p.cfg.Prefix, "/"), versionUUID, name)
	store, err := p.resolver.Resolve(ctx, 0)
	if err != nil {
		return nil, fmt.Errorf("resolve platform storage: %w", err)
	}
	putter, ok := store.(Putter)
	if !ok {
		return nil, errors.New("platform storage does not support PutObject")
	}
	hasher := sha256.New()
	reader := &hashingReader{r: body, h: hasher}
	if err := putter.PutObject(ctx, key, reader, size, ct); err != nil {
		return nil, fmt.Errorf("put client installer: %w", err)
	}
	if reader.n != size {
		return nil, fmt.Errorf("client installer size mismatch: read %d, expected %d", reader.n, size)
	}
	uri := "oss://" + key
	signed, err := p.SignURL(ctx, uri, name, 0)
	if err != nil {
		return nil, err
	}
	return &UploadResult{
		StorageURI:  uri,
		DownloadURL: signed,
		FileName:    name,
		SizeBytes:   size,
		SHA256:      hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

func (p *PackageStore) UploadAppcast(ctx context.Context, versionUUID, filename string, body io.Reader, size int64, contentType string) (*UploadResult, error) {
	if p == nil || p.resolver == nil {
		return nil, errors.New("client installer store not configured")
	}
	if strings.TrimSpace(versionUUID) == "" {
		return nil, errors.New("client appcast upload: version uuid required")
	}
	if body == nil {
		return nil, errors.New("client appcast upload: empty body")
	}
	if size <= 0 {
		return nil, errors.New("client appcast upload: empty file")
	}
	if size > 10*1024*1024 {
		return nil, fmt.Errorf("client appcast too large: %d > %d", size, 10*1024*1024)
	}
	name := sanitizeFilename(filename)
	if strings.ToLower(filepath.Ext(name)) != ".xml" {
		return nil, errors.New("client appcast upload: only .xml is supported")
	}
	name = "appcast.xml"
	ct := strings.TrimSpace(contentType)
	if ct == "" || ct == "application/octet-stream" {
		ct = "application/xml"
	}
	key := path.Join(strings.TrimSuffix(p.cfg.Prefix, "/"), versionUUID, name)
	store, err := p.resolver.Resolve(ctx, 0)
	if err != nil {
		return nil, fmt.Errorf("resolve platform storage: %w", err)
	}
	putter, ok := store.(Putter)
	if !ok {
		return nil, errors.New("platform storage does not support PutObject")
	}
	hasher := sha256.New()
	reader := &hashingReader{r: body, h: hasher}
	if err := putter.PutObject(ctx, key, reader, size, ct); err != nil {
		return nil, fmt.Errorf("put client appcast: %w", err)
	}
	if reader.n != size {
		return nil, fmt.Errorf("client appcast size mismatch: read %d, expected %d", reader.n, size)
	}
	uri := "oss://" + key
	signed, err := p.SignURL(ctx, uri, name, 0)
	if err != nil {
		return nil, err
	}
	return &UploadResult{
		StorageURI:  uri,
		DownloadURL: signed,
		FileName:    name,
		SizeBytes:   size,
		SHA256:      hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

// UploadDelta stores a Sparkle-generated binary delta below its target release.
// The caller owns appcast generation and signing; this method never interprets it.
func (p *PackageStore) UploadDelta(ctx context.Context, versionUUID, filename string, body io.Reader, size int64, contentType string) (*UploadResult, error) {
	if p == nil || p.resolver == nil {
		return nil, errors.New("client installer store not configured")
	}
	if strings.TrimSpace(versionUUID) == "" {
		return nil, errors.New("client delta upload: version uuid required")
	}
	if body == nil || size <= 0 {
		return nil, errors.New("client delta upload: empty file")
	}
	if size > p.cfg.MaxBytes {
		return nil, fmt.Errorf("client delta too large: %d > %d", size, p.cfg.MaxBytes)
	}
	name := sanitizeFilename(filename)
	if strings.ToLower(filepath.Ext(name)) != ".delta" {
		return nil, errors.New("client delta upload: only .delta is supported")
	}
	store, err := p.resolver.Resolve(ctx, 0)
	if err != nil {
		return nil, fmt.Errorf("resolve platform storage: %w", err)
	}
	putter, ok := store.(Putter)
	if !ok {
		return nil, errors.New("platform storage does not support PutObject")
	}
	h := sha256.New()
	reader := &hashingReader{r: body, h: h}
	key := path.Join(strings.TrimSuffix(p.cfg.Prefix, "/"), versionUUID, "deltas", name)
	if err := putter.PutObject(ctx, key, reader, size, normalizeContentType(name, contentType)); err != nil {
		return nil, fmt.Errorf("put client delta: %w", err)
	}
	if reader.n != size {
		return nil, fmt.Errorf("client delta size mismatch: read %d, expected %d", reader.n, size)
	}
	uri := "oss://" + key
	signed, err := p.SignURL(ctx, uri, name, 0)
	if err != nil {
		return nil, err
	}
	return &UploadResult{StorageURI: uri, DownloadURL: signed, FileName: name, SizeBytes: size, SHA256: hex.EncodeToString(h.Sum(nil))}, nil
}

// internalPresignGetter is implemented by stores with a separate in-cluster
// (write) endpoint; see oss.Store.PresignGetInternal.
type internalPresignGetter interface {
	PresignGetInternal(context.Context, object.PresignGetInput) (*object.PresignGetOutput, error)
}

// SignURL presigns oss:// URIs on the store's public read endpoint (what a
// client is redirected to). http(s) URLs pass through untouched.
func (p *PackageStore) SignURL(ctx context.Context, raw, filename string, ttl time.Duration) (string, error) {
	return p.signURL(ctx, raw, filename, ttl, false)
}

// SignRecordedDeltaURL signs a key already registered on the requested release.
// Recorded keys may use an older upload prefix, but must retain release scope.
func (p *PackageStore) SignRecordedDeltaURL(ctx context.Context, raw, versionUUID, filename string) (string, error) {
	key := strings.TrimPrefix(raw, "oss://")
	if !strings.HasPrefix(raw, "oss://") || path.Clean(key) != key || strings.HasPrefix(key, "/") ||
		!strings.HasSuffix(key, "/"+versionUUID+"/deltas/"+filename) {
		return "", dom.ErrInvalidDownloadAsset
	}
	if p == nil || p.resolver == nil {
		return "", dom.ErrInstallerStoreMissing
	}
	return p.presignKey(ctx, key, filename, p.cfg.SignTTL, false)
}

// SignURLInternal is SignURL on the store's internal (write) endpoint, for
// server-side consumers inside the cluster: pods generally cannot reach the
// public read endpoint directly (test env, 2026-09-11) while the write
// endpoint is the one uploads already use. Falls back to SignURL when the
// store has no separate internal endpoint.
func (p *PackageStore) SignURLInternal(ctx context.Context, raw, filename string, ttl time.Duration) (string, error) {
	return p.signURL(ctx, raw, filename, ttl, true)
}

func (p *PackageStore) signURL(ctx context.Context, raw, filename string, ttl time.Duration, internal bool) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return raw, nil
	}
	if !strings.HasPrefix(raw, "oss://") {
		return raw, nil
	}
	if p == nil || p.resolver == nil {
		return raw, nil
	}
	if ttl <= 0 {
		ttl = p.cfg.SignTTL
	}
	key := strings.TrimPrefix(raw, "oss://")
	if !strings.HasPrefix(key, p.cfg.Prefix) {
		return raw, nil
	}
	return p.presignKey(ctx, key, filename, ttl, internal)
}

func (p *PackageStore) presignKey(ctx context.Context, key, filename string, ttl time.Duration, internal bool) (string, error) {
	store, err := p.resolver.Resolve(ctx, 0)
	if err != nil {
		return "", fmt.Errorf("resolve platform storage: %w", err)
	}
	in := object.PresignGetInput{Key: key, TTL: ttl, Inline: false, FileName: filename}
	var out *object.PresignGetOutput
	if presigner, ok := store.(internalPresignGetter); ok && internal {
		out, err = presigner.PresignGetInternal(ctx, in)
	} else {
		out, err = store.PresignGet(ctx, in)
	}
	if err != nil {
		return "", fmt.Errorf("sign client installer: %w", err)
	}
	return out.URL, nil
}

type hashingReader struct {
	r io.Reader
	h hash.Hash
	n int64
}

func (r *hashingReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	if n > 0 {
		r.n += int64(n)
		_, _ = r.h.Write(p[:n])
	}
	return n, err
}

func sanitizeFilename(name string) string {
	name = strings.TrimSpace(filepath.Base(name))
	if name == "." || name == "/" || name == "" {
		name = "installer.bin"
	}
	name = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r
		case r >= 'A' && r <= 'Z':
			return r
		case r >= '0' && r <= '9':
			return r
		case r == '.', r == '-', r == '_':
			return r
		default:
			return '-'
		}
	}, name)
	if name == "" {
		return "installer.bin"
	}
	return name
}

func normalizeContentType(filename, contentType string) string {
	contentType = strings.TrimSpace(contentType)
	if contentType != "" && contentType != "application/octet-stream" {
		return contentType
	}
	ext := strings.ToLower(filepath.Ext(filename))
	switch ext {
	case ".dmg":
		return "application/x-apple-diskimage"
	case ".pkg":
		return "application/octet-stream"
	case ".zip":
		return "application/zip"
	default:
		if detected := mime.TypeByExtension(ext); detected != "" {
			return detected
		}
		return "application/octet-stream"
	}
}
