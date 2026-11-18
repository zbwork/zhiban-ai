package drive

import (
	"context"
	"errors"
	"io"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/storage/oss"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

const bucketKeyPrefix = "community-bucket/"

var bucketName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)

type DriveStorage struct {
	base      *Storage
	overrides interface {
		GetTenantOverride(context.Context, int64) (*dom.StorageOverride, error)
	}
	allowed map[int64]map[string]bool
}

func (s *Storage) ForDrive(pool *pgxpool.Pool) *DriveStorage {
	allowed := make(map[int64]map[string]bool)
	for _, entry := range strings.Split(os.Getenv("COMMUNITY_DRIVE_BUCKET_ALLOWLIST"), ",") {
		id, name, ok := strings.Cut(entry, "=")
		tenant, err := strconv.ParseInt(strings.TrimSpace(id), 10, 64)
		name = strings.TrimSpace(name)
		if !ok || err != nil || tenant <= 0 || !bucketName.MatchString(name) {
			continue
		}
		if allowed[tenant] == nil {
			allowed[tenant] = make(map[string]bool)
		}
		allowed[tenant][name] = true
	}
	return &DriveStorage{base: s, overrides: repo.NewStorageRepo(pool), allowed: allowed}
}

func (s *DriveStorage) EffectiveBucket(o *dom.StorageOverride) string {
	if o != nil && o.Status == dom.StorageStatusActive && o.Bucket != nil && s.allowed[o.TenantID][*o.Bucket] &&
		o.DefaultID == nil && o.Region == nil && o.Endpoint == nil && o.ReadEndpoint == nil &&
		o.AccessKeySecretRef == nil && o.SecretKeySecretRef == nil {
		return *o.Bucket
	}
	return s.base.bucket
}

// ProbeOverride checks the same destination used by new uploads when the override applies.
func (s *DriveStorage) ProbeOverride(ctx context.Context, o *dom.StorageOverride) (bool, error) {
	bucket := s.EffectiveBucket(o)
	if bucket == s.base.bucket {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return true, s.base.store.WithBucket(bucket).HeadBucket(ctx)
}

func (s *DriveStorage) Resolve(ctx context.Context, tenantID int64) (object.Store, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if tenantID <= 0 {
		return nil, errors.New("drive storage requires a tenant")
	}
	return &tenantStore{routing: s, tenantID: tenantID}, nil
}

type tenantStore struct {
	routing  *DriveStorage
	tenantID int64
}

func (s *tenantStore) Kind() string { return s.routing.base.store.Kind() }

func (s *tenantStore) UploadKeys(ctx context.Context, staging, final string) (string, string, error) {
	if len(s.routing.allowed[s.tenantID]) == 0 {
		return staging, final, nil
	}
	override, err := s.routing.overrides.GetTenantOverride(ctx, s.tenantID)
	if err != nil {
		return "", "", err
	}
	bucket := s.routing.EffectiveBucket(override)
	if bucket == s.routing.base.bucket {
		return staging, final, nil
	}
	prefix := bucketKeyPrefix + bucket + "/"
	return prefix + staging, prefix + final, nil
}

func (s *tenantStore) CopyKey(source, destination string) (string, error) {
	bucket, _, err := s.locate(source)
	if err != nil {
		return "", err
	}
	if bucket == s.routing.base.bucket {
		return destination, nil
	}
	return bucketKeyPrefix + bucket + "/" + destination, nil
}

func (s *tenantStore) locate(key string) (bucket string, physicalKey string, err error) {
	rest, routed := strings.CutPrefix(key, bucketKeyPrefix)
	if !routed {
		return s.routing.base.bucket, key, nil
	}
	bucket, physicalKey, ok := strings.Cut(rest, "/")
	tenant := strconv.FormatInt(s.tenantID, 10)
	if !ok || !bucketName.MatchString(bucket) || path.Clean(physicalKey) != physicalKey ||
		(!strings.HasPrefix(physicalKey, "staging/"+tenant+"/") && !strings.HasPrefix(physicalKey, "tenants/"+tenant+"/")) {
		return "", "", errors.New("invalid tenant object location")
	}
	return bucket, physicalKey, nil
}

func (s *tenantStore) target(key string) (*oss.Store, string, error) {
	bucket, physicalKey, err := s.locate(key)
	if err != nil {
		return nil, "", err
	}
	return s.routing.base.store.WithBucket(bucket), physicalKey, nil
}

func (s *tenantStore) PresignPut(ctx context.Context, in object.PresignPutInput) (*object.PresignPutOutput, error) {
	store, key, err := s.target(in.Key)
	if err != nil {
		return nil, err
	}
	in.Key = key
	return store.PresignPut(ctx, in)
}

func (s *tenantStore) PresignGet(ctx context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	store, key, err := s.target(in.Key)
	if err != nil {
		return nil, err
	}
	in.Key = key
	return store.PresignGet(ctx, in)
}

func (s *tenantStore) PresignGetInternal(ctx context.Context, in object.PresignGetInput) (*object.PresignGetOutput, error) {
	store, key, err := s.target(in.Key)
	if err != nil {
		return nil, err
	}
	in.Key = key
	return store.PresignGetInternal(ctx, in)
}

func (s *tenantStore) PutObject(ctx context.Context, key string, body io.Reader, size int64, contentType string) error {
	store, key, err := s.target(key)
	if err != nil {
		return err
	}
	return store.PutObject(ctx, key, body, size, contentType)
}

func (s *tenantStore) Delete(ctx context.Context, key string) error {
	store, key, err := s.target(key)
	if err != nil {
		return err
	}
	return store.Delete(ctx, key)
}

func (s *tenantStore) Stat(ctx context.Context, key string) (*object.Stat, error) {
	store, key, err := s.target(key)
	if err != nil {
		return nil, err
	}
	return store.Stat(ctx, key)
}

func (s *tenantStore) Copy(ctx context.Context, source, destination string) error {
	bucket, sourceKey, err := s.locate(source)
	if err != nil {
		return err
	}
	dstBucket, dstKey, err := s.locate(destination)
	if err != nil {
		return err
	}
	if bucket != dstBucket {
		return errors.New("cloud drive copy requires the same bucket")
	}
	return s.routing.base.store.WithBucket(bucket).Copy(ctx, sourceKey, dstKey)
}

func (s *tenantStore) InitMultipart(ctx context.Context, key, contentType string) (string, error) {
	store, key, err := s.target(key)
	if err != nil {
		return "", err
	}
	return store.InitMultipart(ctx, key, contentType)
}

func (s *tenantStore) PresignPart(ctx context.Context, key, uploadID string, part int, ttl time.Duration) (string, error) {
	store, key, err := s.target(key)
	if err != nil {
		return "", err
	}
	return store.PresignPart(ctx, key, uploadID, part, ttl)
}

func (s *tenantStore) CompleteMultipart(ctx context.Context, key, uploadID string, parts []object.MultipartPart) error {
	store, key, err := s.target(key)
	if err != nil {
		return err
	}
	return store.CompleteMultipart(ctx, key, uploadID, parts)
}

func (s *tenantStore) AbortMultipart(ctx context.Context, key, uploadID string) error {
	store, key, err := s.target(key)
	if err != nil {
		return err
	}
	return store.AbortMultipart(ctx, key, uploadID)
}
