// Package storage — admin 用的 S3/OSS 配置应用服务
// (M7 Phase B sprint, docs/tasks/sprint-m7m8-drive-s3-kb-dify.md §3).
//
// 设计:
//   - 只暴露 admin 视角的 CRUD + test-connection + set-default.
//   - 写时校验 secret_ref 协议 (env://, value://); 是否允许 value:// 由 caller 决定.
//   - test-connection: 临时构造一份 oss.Store, 发一次 HEAD bucket; 不写库.
//   - 任意写后调 resolver.Invalidate(tenantID) / InvalidateAll().
package storage

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/storage/oss"
	domdrivev3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ResolverInvalidator 允许调用方 (drive.StorageResolver) 失效缓存.
type ResolverInvalidator interface {
	Invalidate(tenantID int64)
	InvalidateAll()
}

// Service admin 视角 S3/OSS 配置.
type Service struct {
	Repo       domdrivev3.StorageRepo
	Secret     SecretResolver
	Resolver   ResolverInvalidator // 可 nil (admin-only 进程)
	AllowValue bool                // 与 SecretResolver.AllowValue 同步 (dev 时 true)
}

// PresentDefault 用于返给 admin 的视图; 不漏 secret 明文.
type PresentDefault struct {
	UUID               string `json:"uuid"`
	Name               string `json:"name"`
	Kind               string `json:"kind"`
	Region             string `json:"region"`
	Endpoint           string `json:"endpoint"`
	ReadEndpoint       string `json:"read_endpoint,omitempty"`
	Bucket             string `json:"bucket"`
	AccessKeySecretRef string `json:"access_key_secret_ref"`
	SecretKeySecretRef string `json:"secret_key_secret_ref"`
	Status             string `json:"status"`
	IsDefault          bool   `json:"is_default"`
	CreatedAt          string `json:"created_at"`
	UpdatedAt          string `json:"updated_at"`
}

// CreateDefaultInput admin POST body.
type CreateDefaultInput struct {
	Name               string `json:"name"`
	Kind               string `json:"kind"`
	Region             string `json:"region"`
	Endpoint           string `json:"endpoint"`
	ReadEndpoint       string `json:"read_endpoint"`
	Bucket             string `json:"bucket"`
	AccessKeySecretRef string `json:"access_key_secret_ref"`
	SecretKeySecretRef string `json:"secret_key_secret_ref"`
}

// ListDefaults 列所有平台默认.
func (s *Service) ListDefaults(ctx context.Context) ([]PresentDefault, error) {
	items, err := s.Repo.ListDefaults(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]PresentDefault, 0, len(items))
	for _, d := range items {
		out = append(out, presentDefault(&d))
	}
	return out, nil
}

// CreateDefault 写一行平台默认.
func (s *Service) CreateDefault(ctx context.Context, in CreateDefaultInput) (*PresentDefault, error) {
	if err := validateDefaultCreate(in, s.AllowValue); err != nil {
		return nil, err
	}
	row := &domdrivev3.StorageDefault{
		Name:               in.Name,
		Kind:               domdrivev3.StorageKind(in.Kind),
		Region:             in.Region,
		Endpoint:           in.Endpoint,
		ReadEndpoint:       in.ReadEndpoint,
		Bucket:             in.Bucket,
		AccessKeySecretRef: in.AccessKeySecretRef,
		SecretKeySecretRef: in.SecretKeySecretRef,
	}
	if err := s.Repo.CreateDefault(ctx, row); err != nil {
		return nil, err
	}
	if s.Resolver != nil {
		s.Resolver.InvalidateAll()
	}
	r := presentDefault(row)
	return &r, nil
}

// PatchDefault 部分字段更新.
//
// status 字段语义见 domain/drive/storage.go StorageStatus 注释:
//   - 只接受 'active' / 'disabled' (admin 启用意图)
//   - 拒收 'degraded' (那是 TestConnection 瞬时响应, 不应入库)
//   - 不允许把当前 is_default=true 的行改成 'disabled' (会留下空默认)
func (s *Service) PatchDefault(ctx context.Context, uuid string, fields map[string]any) error {
	if v, ok := fields["access_key_secret_ref"]; ok {
		if err := ValidateRef(fmt.Sprint(v), s.AllowValue); err != nil {
			return fmt.Errorf("access_key_secret_ref: %w", err)
		}
	}
	if v, ok := fields["secret_key_secret_ref"]; ok {
		if err := ValidateRef(fmt.Sprint(v), s.AllowValue); err != nil {
			return fmt.Errorf("secret_key_secret_ref: %w", err)
		}
	}
	if v, ok := fields["status"]; ok {
		st := strings.TrimSpace(fmt.Sprint(v))
		if st != string(domdrivev3.StorageStatusActive) && st != string(domdrivev3.StorageStatusDisabled) {
			return fmt.Errorf("status: 只接受 'active' / 'disabled' (admin 启用意图); 当前传入 %q", st)
		}
		fields["status"] = st
		if st == string(domdrivev3.StorageStatusDisabled) {
			cur, err := s.Repo.GetDefaultByUUID(ctx, uuid)
			if err != nil {
				return err
			}
			if cur != nil && cur.IsDefault {
				return fmt.Errorf("status: 当前是平台默认行, 不能禁用; 请先把另一行设为默认")
			}
		}
	}
	if err := s.Repo.PatchDefault(ctx, uuid, fields); err != nil {
		return err
	}
	if s.Resolver != nil {
		s.Resolver.InvalidateAll()
	}
	return nil
}

// DeleteDefault 软删.
func (s *Service) DeleteDefault(ctx context.Context, uuid string) error {
	if err := s.Repo.SoftDeleteDefault(ctx, uuid); err != nil {
		return err
	}
	if s.Resolver != nil {
		s.Resolver.InvalidateAll()
	}
	return nil
}

// SetDefault 指定默认行.
func (s *Service) SetDefault(ctx context.Context, uuid string) error {
	if err := s.Repo.SetDefault(ctx, uuid); err != nil {
		return err
	}
	if s.Resolver != nil {
		s.Resolver.InvalidateAll()
	}
	return nil
}

// TestConnectionDefault 用 uuid 行配置发一次 HEAD bucket; 不写库.
func (s *Service) TestConnectionDefault(ctx context.Context, uuid string) (string, error) {
	d, err := s.Repo.GetDefaultByUUID(ctx, uuid)
	if err != nil {
		return "", err
	}
	return s.testWithConfig(ctx, d.Endpoint, d.Bucket, d.Region, d.AccessKeySecretRef, d.SecretKeySecretRef, PickPathStyle(d.Endpoint))
}

// GetTenantOverride 取覆盖 (nil 时返 nil).
func (s *Service) GetTenantOverride(ctx context.Context, tenantID int64) (*domdrivev3.StorageOverride, error) {
	return s.Repo.GetTenantOverride(ctx, tenantID)
}

// UpsertTenantOverride 写租户覆盖.
func (s *Service) UpsertTenantOverride(ctx context.Context, o *domdrivev3.StorageOverride) error {
	if o.AccessKeySecretRef != nil && *o.AccessKeySecretRef != "" {
		if err := ValidateRef(*o.AccessKeySecretRef, s.AllowValue); err != nil {
			return fmt.Errorf("access_key_secret_ref: %w", err)
		}
	}
	if o.SecretKeySecretRef != nil && *o.SecretKeySecretRef != "" {
		if err := ValidateRef(*o.SecretKeySecretRef, s.AllowValue); err != nil {
			return fmt.Errorf("secret_key_secret_ref: %w", err)
		}
	}
	if err := s.Repo.UpsertTenantOverride(ctx, o); err != nil {
		return err
	}
	if s.Resolver != nil {
		s.Resolver.Invalidate(o.TenantID)
	}
	return nil
}

// DeleteTenantOverride 删租户覆盖.
func (s *Service) DeleteTenantOverride(ctx context.Context, tenantID int64) error {
	if err := s.Repo.SoftDeleteTenantOverride(ctx, tenantID); err != nil {
		return err
	}
	if s.Resolver != nil {
		s.Resolver.Invalidate(tenantID)
	}
	return nil
}

// TestConnectionOverride 用租户覆盖 (合并 default fallback) 测一次.
func (s *Service) TestConnectionOverride(ctx context.Context, tenantID int64) (string, error) {
	ov, err := s.Repo.GetTenantOverride(ctx, tenantID)
	if err != nil {
		return "", err
	}
	if ov == nil {
		return "", errors.New("storage: tenant has no override")
	}
	base, err := s.Repo.GetActiveDefault(ctx)
	if err != nil {
		return "", err
	}
	endpoint := base.Endpoint
	bucket := base.Bucket
	region := base.Region
	akRef := base.AccessKeySecretRef
	skRef := base.SecretKeySecretRef
	if ov.Endpoint != nil {
		endpoint = *ov.Endpoint
	}
	if ov.Bucket != nil {
		bucket = *ov.Bucket
	}
	if ov.Region != nil {
		region = *ov.Region
	}
	if ov.AccessKeySecretRef != nil && *ov.AccessKeySecretRef != "" {
		akRef = *ov.AccessKeySecretRef
	}
	if ov.SecretKeySecretRef != nil && *ov.SecretKeySecretRef != "" {
		skRef = *ov.SecretKeySecretRef
	}
	return s.testWithConfig(ctx, endpoint, bucket, region, akRef, skRef, PickPathStyle(endpoint))
}

func (s *Service) testWithConfig(ctx context.Context, endpoint, bucket, region, akRef, skRef string, force bool) (string, error) {
	ak, err := s.Secret.Resolve(akRef)
	if err != nil {
		return "", fmt.Errorf("ak: %w", err)
	}
	sk, err := s.Secret.Resolve(skRef)
	if err != nil {
		return "", fmt.Errorf("sk: %w", err)
	}
	store, err := oss.New(oss.Config{
		Endpoint:        endpoint,
		Bucket:          bucket,
		Region:          region,
		AccessKeyID:     ak,
		SecretAccessKey: sk,
		ForcePathStyle:  force,
	})
	if err != nil {
		return "", err
	}
	// 试 Stat 一个不存在 key; 期望: nil + ErrNotFound 表示通; 否则报错原因.
	_, err = store.Stat(ctx, "__zhiban_admin_probe__")
	if err == nil {
		return "ok", nil
	}
	// inmem 实现可能返 ErrNotFound; oss 实现可能返 status 404 文本.
	msg := err.Error()
	if strings.Contains(msg, "not found") || strings.Contains(msg, "status 404") || strings.Contains(msg, "NoSuchKey") {
		return "ok", nil
	}
	return "", err
}

func presentDefault(d *domdrivev3.StorageDefault) PresentDefault {
	return PresentDefault{
		UUID: d.UUID, Name: d.Name, Kind: string(d.Kind), Region: d.Region,
		Endpoint: d.Endpoint, ReadEndpoint: d.ReadEndpoint, Bucket: d.Bucket,
		AccessKeySecretRef: d.AccessKeySecretRef, SecretKeySecretRef: d.SecretKeySecretRef,
		Status: string(d.Status), IsDefault: d.IsDefault,
		CreatedAt: d.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt: d.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

// PickPathStyle — 由 endpoint hostname 自动判断是否走 path-style URL。
//
// 替代 000120 之前的 drive_storage_*.force_path_style 列。
// 规则:
//   - *.aliyuncs.com  → false (阿里云 OSS 走虚拟主机式, 是其标准)
//   - *.amazonaws.com → false (AWS S3 标准走虚拟主机式; modern endpoint 不支持 path-style)
//   - 其它 (MinIO / Ceph / 自建 S3 / 企业内网 S3) → true (这类几乎都需要 path-style)
//
// 没人能 100% 覆盖所有 corp 部署, 但这个启发覆盖 95% 实际情况; 如有反例, 在 admin 端
// patch DB 行 endpoint 时一并改 kind, 或在此函数加新规则。
func PickPathStyle(endpoint string) bool {
	e := strings.ToLower(strings.TrimSpace(endpoint))
	// 去掉 scheme + 可能的端口号, 取 host 部分。
	if idx := strings.Index(e, "://"); idx >= 0 {
		e = e[idx+3:]
	}
	if idx := strings.IndexAny(e, "/?"); idx >= 0 {
		e = e[:idx]
	}
	if idx := strings.Index(e, ":"); idx >= 0 {
		e = e[:idx]
	}
	if strings.HasSuffix(e, ".aliyuncs.com") || e == "aliyuncs.com" {
		return false
	}
	if strings.HasSuffix(e, ".amazonaws.com") || e == "amazonaws.com" {
		return false
	}
	return true
}

func validateDefaultCreate(in CreateDefaultInput, allowValue bool) error {
	if strings.TrimSpace(in.Name) == "" {
		return errors.New("name required")
	}
	switch in.Kind {
	case "oss", "s3", "minio":
	default:
		return fmt.Errorf("unsupported kind %q (oss|s3|minio)", in.Kind)
	}
	if strings.TrimSpace(in.Region) == "" {
		return errors.New("region required")
	}
	if _, err := url.Parse(in.Endpoint); err != nil || in.Endpoint == "" {
		return fmt.Errorf("invalid endpoint %q", in.Endpoint)
	}
	if in.ReadEndpoint != "" {
		if _, err := url.Parse(in.ReadEndpoint); err != nil {
			return fmt.Errorf("invalid read_endpoint %q", in.ReadEndpoint)
		}
	}
	if strings.TrimSpace(in.Bucket) == "" {
		return errors.New("bucket required")
	}
	if err := ValidateRef(in.AccessKeySecretRef, allowValue); err != nil {
		return fmt.Errorf("access_key_secret_ref: %w", err)
	}
	if err := ValidateRef(in.SecretKeySecretRef, allowValue); err != nil {
		return fmt.Errorf("secret_key_secret_ref: %w", err)
	}
	return nil
}

// HTTPProbe 让 service 携带一个可定制的 http.Client (留扩展; 当前 oss.New 用内置 client).
type HTTPProbe = http.Client
