// Package media manages small, frequently displayed images such as skill icons
// and agent avatars. Object bytes live in OSS/S3; business tables store only
// oss:// references.
package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
)

type Kind string

const (
	KindSkillIcon         Kind = "skill_icon"
	KindSkillExampleImage Kind = "skill_example_image"
	KindAgentAvatar       Kind = "agent_avatar"
)

type Putter interface {
	PutObject(ctx context.Context, key string, body io.Reader, contentLength int64, contentType string) error
}

type Config struct {
	SkillIconPrefix           string
	SkillExampleImagePrefix   string
	AgentAvatarPrefix         string
	MaxImageBytes             int64
	SkillExampleImageMaxBytes int64
	AgentAvatarMaxBytes       int64
	PreviewTTL                time.Duration
}

// StorageGetter resolves a per-tenant object.Store from DB config.
type StorageGetter interface {
	Resolve(ctx context.Context, tenantID int64) (object.Store, error)
}

type Service struct {
	store    object.Store  // fixed store (legacy / test path)
	putter   Putter        // fixed putter (legacy / test path)
	resolver StorageGetter // DB-backed resolver (preferred when set)
	cfg      Config
}

type UploadInput struct {
	Kind        Kind
	Body        io.Reader
	ContentType string
}

type UploadOutput struct {
	StorageKey string `json:"storage_key"`
	StorageURI string `json:"storage_uri"`
	SignedURL  string `json:"signed_url"`
	Size       int64  `json:"size_bytes"`
	SHA256     string `json:"sha256"`
}

func New(store object.Store, putter Putter, cfg Config) *Service {
	if cfg.SkillIconPrefix == "" {
		cfg.SkillIconPrefix = "skill-icons/"
	}
	if cfg.SkillExampleImagePrefix == "" {
		cfg.SkillExampleImagePrefix = "skill-example-images/"
	}
	if cfg.AgentAvatarPrefix == "" {
		cfg.AgentAvatarPrefix = "agent-avatars/"
	}
	cfg.SkillIconPrefix = ensureSlash(cfg.SkillIconPrefix)
	cfg.SkillExampleImagePrefix = ensureSlash(cfg.SkillExampleImagePrefix)
	cfg.AgentAvatarPrefix = ensureSlash(cfg.AgentAvatarPrefix)
	if cfg.MaxImageBytes <= 0 {
		cfg.MaxImageBytes = 1 * 1024 * 1024
	}
	if cfg.SkillExampleImageMaxBytes <= 0 {
		cfg.SkillExampleImageMaxBytes = 5 * 1024 * 1024
	}
	if cfg.AgentAvatarMaxBytes <= 0 {
		cfg.AgentAvatarMaxBytes = 5 * 1024 * 1024
	}
	if cfg.PreviewTTL <= 0 {
		cfg.PreviewTTL = time.Hour
	}
	return &Service{store: store, putter: putter, cfg: cfg}
}

// NewWithResolver constructs a Service backed by a DB storage resolver.
// Upload uses type-assert to media.Putter on the resolved object.Store.
func NewWithResolver(resolver StorageGetter, cfg Config) *Service {
	svc := New(nil, nil, cfg)
	svc.resolver = resolver
	return svc
}

// Upload uploads via the fixed putter (legacy path). Delegates to UploadForTenant(ctx, 0, in).
func (s *Service) Upload(ctx context.Context, in UploadInput) (*UploadOutput, error) {
	return s.UploadForTenant(ctx, 0, in)
}

// UploadForTenant uploads a small media file using the resolved store for tenantID.
func (s *Service) UploadForTenant(ctx context.Context, tenantID int64, in UploadInput) (*UploadOutput, error) {
	if s == nil {
		return nil, errors.New("media service not configured")
	}
	p, err := s.putterForTenant(ctx, tenantID)
	if err != nil {
		return nil, fmt.Errorf("media upload: %w", err)
	}
	prefix, err := s.prefixForKind(in.Kind)
	if err != nil {
		return nil, err
	}
	contentType, ext, err := imageExtForMIME(in.Kind, in.ContentType)
	if err != nil {
		return nil, err
	}
	buf, err := readLimited(in.Body, s.maxBytesForKind(in.Kind))
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(buf)
	digest := hex.EncodeToString(sum[:])
	key := prefix + digest + ext
	if err := p.PutObject(ctx, key, bytes.NewReader(buf), int64(len(buf)), contentType); err != nil {
		return nil, fmt.Errorf("media put: %w", err)
	}
	signed := s.ResolveURLForTenant(ctx, tenantID, "oss://"+key)
	return &UploadOutput{
		StorageKey: key,
		StorageURI: "oss://" + key,
		SignedURL:  signed,
		Size:       int64(len(buf)),
		SHA256:     digest,
	}, nil
}

func (s *Service) storeForTenant(ctx context.Context, tenantID int64) (object.Store, error) {
	if s.resolver != nil {
		return s.resolver.Resolve(ctx, tenantID)
	}
	if s.store != nil {
		return s.store, nil
	}
	return nil, errors.New("media service not configured")
}

func (s *Service) putterForTenant(ctx context.Context, tenantID int64) (Putter, error) {
	if s.resolver != nil {
		store, err := s.resolver.Resolve(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		p, ok := store.(Putter)
		if !ok {
			return nil, errors.New("media: resolved store does not support PutObject")
		}
		return p, nil
	}
	if s.putter != nil {
		return s.putter, nil
	}
	return nil, errors.New("media service upload not configured")
}

func (s *Service) maxBytesForKind(kind Kind) int64 {
	if kind == KindSkillExampleImage {
		return s.cfg.SkillExampleImageMaxBytes
	}
	if kind == KindAgentAvatar {
		return s.cfg.AgentAvatarMaxBytes
	}
	return s.cfg.MaxImageBytes
}

// ResolveURL delegates to ResolveURLForTenant with tenantID=0 (platform assets).
func (s *Service) ResolveURL(ctx context.Context, raw string) string {
	return s.ResolveURLForTenant(ctx, 0, raw)
}

// ResolveURLForTenant signs an oss:// URI into a presigned GET URL.
// Returns "" if the URI cannot be signed (resolver error, disallowed prefix, presign failure).
// http(s):// and /api/ paths pass through unchanged. Empty string passes through.
// Any other raw value (e.g. bare storage_key) returns "" to prevent leaking internal keys.
func (s *Service) ResolveURLForTenant(ctx context.Context, tenantID int64, raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return raw
	}
	if strings.HasPrefix(raw, "/api/") {
		return raw
	}
	if !strings.HasPrefix(raw, "oss://") {
		return ""
	}
	if s == nil {
		return ""
	}
	key := strings.TrimPrefix(raw, "oss://")
	if !s.allowedMediaKey(key) {
		return ""
	}
	store, err := s.storeForTenant(ctx, tenantID)
	if err != nil || store == nil {
		return ""
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key: key, TTL: s.cfg.PreviewTTL, Inline: true,
	})
	if err != nil || out == nil || out.URL == "" {
		return ""
	}
	return out.URL
}

// ResolveURLMap delegates to ResolveURLMapForTenant with tenantID=0.
func (s *Service) ResolveURLMap(ctx context.Context, raws []string) map[string]string {
	return s.ResolveURLMapForTenant(ctx, 0, raws)
}

// ResolveURLMapForTenant batch-resolves oss:// URIs.
func (s *Service) ResolveURLMapForTenant(ctx context.Context, tenantID int64, raws []string) map[string]string {
	out := make(map[string]string, len(raws))
	for _, raw := range raws {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if _, ok := out[raw]; ok {
			continue
		}
		out[raw] = s.ResolveURLForTenant(ctx, tenantID, raw)
	}
	return out
}

func (s *Service) prefixForKind(kind Kind) (string, error) {
	switch kind {
	case KindSkillIcon:
		return s.cfg.SkillIconPrefix, nil
	case KindSkillExampleImage:
		return s.cfg.SkillExampleImagePrefix, nil
	case KindAgentAvatar:
		return s.cfg.AgentAvatarPrefix, nil
	default:
		return "", fmt.Errorf("media.unsupported_kind: %s", kind)
	}
}

func (s *Service) allowedMediaKey(key string) bool {
	return strings.HasPrefix(key, s.cfg.SkillIconPrefix) ||
		strings.HasPrefix(key, s.cfg.SkillExampleImagePrefix) ||
		strings.HasPrefix(key, s.cfg.AgentAvatarPrefix)
}

func readLimited(body io.Reader, maxBytes int64) ([]byte, error) {
	if body == nil {
		return nil, errors.New("media.empty_body")
	}
	buf, err := io.ReadAll(io.LimitReader(body, maxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read media body: %w", err)
	}
	if int64(len(buf)) > maxBytes {
		return nil, fmt.Errorf("media.too_large: %d > max %d", len(buf), maxBytes)
	}
	if len(buf) == 0 {
		return nil, errors.New("media.empty_body")
	}
	return buf, nil
}

func imageExtForMIME(kind Kind, contentType string) (string, string, error) {
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		mt = strings.ToLower(strings.TrimSpace(contentType))
	}
	switch strings.ToLower(mt) {
	case "image/png":
		return "image/png", ".png", nil
	case "image/jpeg", "image/jpg":
		return "image/jpeg", ".jpg", nil
	case "image/webp":
		return "image/webp", ".webp", nil
	case "image/gif":
		return "image/gif", ".gif", nil
	}
	return "", "", fmt.Errorf("media.unsupported_mime: %s", contentType)
}

func ensureSlash(prefix string) string {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		return ""
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return prefix
}
