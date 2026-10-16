// Package runtime 是 M3 v1.0 留下的 Runtime 注册抽象。
//
// **F02 v0.3 起 Deprecated**: 对应的 runtime_registrations / runtime_hosting_configs
// 表已被 migration 000060 删除, 合并入 runtime_environments (见 internal/domain/runtimeenv)。
// 本包仅留 Instance 给 runtime_instances 表用; Registration 是孤儿类型, S4d 一并删。
package runtime

import (
	"context"
	"time"
)

// Registration 描述一个 Runtime 类型注册 (M3 完整字段)。
//
// Deprecated: F02 v0.3 起底表 runtime_registrations 已删除; 用 runtimeenv.Env。
type Registration struct {
	ID                int64
	UUID              string
	Code              string
	Name              string
	Description       string
	Vendor            string
	Framework         string
	AdapterKind       string // builtin/plugin/external
	Endpoints         map[string]any
	DataEgress        string
	EgressAuditStatus string // pending/approved/rejected/needs_revision
	EgressAuditReason string
	EgressAuditorID   *int64
	EgressReviewedAt  *time.Time
	EgressDocs        map[string]any
	Status            string // active/disabled
	LastProbeStatus   string // ok/error/timeout/空; F02 运行环境连通性闸
	LastHealthyAt     *time.Time
	RateLimit         map[string]any
	Metadata          map[string]any
	CreatedAt         time.Time
	UpdatedAt         time.Time
	// 计算字段
	BoundAgents int64 // 引用此 Runtime 的 Agent 数 (deleted_at IS NULL)
}

// Instance 是 runtime_instances 一行 (K8s Pod / 本地容器)。F02 v0.3 schema:
//   - account_id → created_by (rename, 语义对齐)
//   - runtime_id → runtime_environment_id (rename, 指 runtime_environments)
//   - 补 8 字段审计 (created_by/updated_by/is_deleted/deleted_at)
//
// runtime_instances.agent_id 那一列从未被任何代码路径写入过, ADR-0037 migration
// 000131 已经删掉 (语义被 agent_uuid 取代, 见 runtimehosting 包)。
type Instance struct {
	// 8 字段审计 (ADR-0011)
	ID        int64
	UUID      string
	CreatedAt time.Time
	CreatedBy *int64 // 旧 account_id, 触发 ensure 的人
	UpdatedAt time.Time
	UpdatedBy *int64
	IsDeleted bool
	DeletedAt *time.Time

	// 关联
	TenantID             int64
	RuntimeEnvironmentID int64
	TenantName           string
	AccountName          string
	AccountPhone         string

	// K8s 标识
	K8sNamespace       string
	K8sDeployment      string
	K8sService         string
	WorkloadInstanceID *int64

	// 镜像版本
	ImageVersion       string
	TargetImageVersion string
	LastUpgradedAt     *time.Time
	UpgradeMessage     string

	// 工作目录
	WorkspaceRoot string
	SessionsRoot  string

	// 运行时 endpoint
	EndpointURL     string
	APIKeySecretRef string // 实例签发的 agent_gateway_token (列名), 区分 runtime_environments.api_key_secret_ref

	// 状态机
	Status        string // pending/starting/ready/degraded/stopped/failed
	LastHealthyAt *time.Time
	ErrorMessage  string

	// 扩展
	Metadata map[string]any
}

// Repository M3 完整查询/写入接口。
type Repository interface {
	GetByID(ctx context.Context, id int64) (*Registration, error)
	GetByCode(ctx context.Context, code string) (*Registration, error)
	List(ctx context.Context, includeDisabled bool) ([]Registration, error)
	Create(ctx context.Context, r *Registration) (*Registration, error)
	Update(ctx context.Context, r *Registration) (*Registration, error)
	// Patch 增量更新: 只更新 fields 中实际出现的 key (M3 PATCH 语义)。
	Patch(ctx context.Context, id int64, fields map[string]any) (*Registration, error)
	SoftDelete(ctx context.Context, id int64) error
	BoundAgentsByRuntime(ctx context.Context, id int64) ([]int64, error)

	// 出境审核
	SubmitEgress(ctx context.Context, id int64) (*Registration, error)
	ReviewEgress(ctx context.Context, id, auditorID int64, decision, reason string) (*Registration, error)

	// 健康
	UpdateHealth(ctx context.Context, id int64, status string, lastHealthy time.Time) error
	ListInstances(ctx context.Context, runtimeID int64) ([]Instance, error)
	UpdateInstanceHealth(ctx context.Context, instID int64, status string, lastHealthy time.Time, errMsg string) error

	Notify(ctx context.Context, channel, payload string) error
}
