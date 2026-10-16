package drive

import (
	"context"
	"time"
)

// StorageKind 与 drive_storage_defaults.kind CHECK 对齐 (F06 §2.10).
type StorageKind string

const (
	StorageKindOSS   StorageKind = "oss"
	StorageKindS3    StorageKind = "s3"
	StorageKindMinio StorageKind = "minio"
)

// StorageStatus 与 drive_storage_defaults.status / drive_storage_overrides.status CHECK 对齐.
//
// 语义边界:
//   - Active / Disabled = admin 的启用意图, 经 UI 开关写入。
//   - Degraded         = 仅作为测连接 (TestConnection*) 接口的瞬时响应值,
//     不持久化到本表 status 列。当前代码无任何路径将 'degraded'
//     写回 drive_storage_defaults / drive_storage_overrides;
//     PatchDefault / UpsertTenantOverride 在 service 层拒收
//     外部 PATCH status='degraded'。DB CHECK 仍保留 'degraded'
//     是为了和 KB Provider 表的早期 schema 形状一致, 待统一收口。
type StorageStatus string

const (
	StorageStatusActive   StorageStatus = "active"
	StorageStatusDegraded StorageStatus = "degraded"
	StorageStatusDisabled StorageStatus = "disabled"
)

// StorageDefault F06 §2.10.1 平台默认 OSS/S3 配置.
// 2026-05-26 (migration 000120): 砍掉 force_path_style / prefix_tpl / lifecycle_rules 三列.
//   - prefix_tpl     从未生效 (upload.go 硬编码模板)
//   - lifecycle_rules 从未推到 S3 (无 PutBucketLifecycle 调用)
//   - force_path_style 改成 endpoint-based heuristic, 见 service/drive/storage_resolver.go::pickPathStyle()
type StorageDefault struct {
	ID                 int64
	UUID               string
	Name               string
	Kind               StorageKind
	Region             string
	Endpoint           string // 写 endpoint (内网)
	ReadEndpoint       string // 读外网 (空 → fallback Endpoint)
	Bucket             string
	AccessKeySecretRef string // env:// / value:// / vault:// 强制前缀
	SecretKeySecretRef string
	Status             StorageStatus
	IsDefault          bool
	CreatedAt          time.Time
	CreatedBy          *int64
	UpdatedAt          time.Time
	UpdatedBy          *int64
	IsDeleted          bool
	DeletedAt          *time.Time
}

// StorageOverride F06 §2.10.2 租户 override (空字段继承 default_id 指向行).
// 见上方 StorageDefault 关于 000120 schema 收口的注释。
type StorageOverride struct {
	ID                 int64
	UUID               string
	TenantID           int64
	DefaultID          *int64  // 可空: NULL 时 override 必须自带全部必填字段
	Region             *string // NULL 表示继承 default
	Endpoint           *string
	ReadEndpoint       *string
	Bucket             *string
	AccessKeySecretRef *string
	SecretKeySecretRef *string
	Status             StorageStatus
	CreatedAt          time.Time
	CreatedBy          *int64
	UpdatedAt          time.Time
	UpdatedBy          *int64
	IsDeleted          bool
	DeletedAt          *time.Time
}

// StorageRepo F06 §2.10 storage 后端配置 CRUD; Phase 2.1 暴露完整方法集 (替代 legacy repodrive 的 11 个方法).
type StorageRepo interface {
	// defaults
	ListDefaults(ctx context.Context) ([]StorageDefault, error)
	GetDefaultByUUID(ctx context.Context, uuid string) (*StorageDefault, error)
	GetDefaultByID(ctx context.Context, id int64) (*StorageDefault, error)
	GetActiveDefault(ctx context.Context) (*StorageDefault, error)
	CreateDefault(ctx context.Context, d *StorageDefault) error
	PatchDefault(ctx context.Context, uuid string, fields map[string]any) error
	SoftDeleteDefault(ctx context.Context, uuid string) error
	SetDefault(ctx context.Context, uuid string) error
	// overrides
	GetTenantOverride(ctx context.Context, tenantID int64) (*StorageOverride, error)
	UpsertTenantOverride(ctx context.Context, o *StorageOverride) error
	SoftDeleteTenantOverride(ctx context.Context, tenantID int64) error
}
