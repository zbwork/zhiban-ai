// Package runtimeenv 是 F02 v0.3 "Agent 平台环境" 的领域模型。
//
// schema 对应 runtime_environments 合表 (ADR-0012) — 旧 runtime_registrations
// + runtime_hosting_configs 已删除; scope + hosting_kind 二维区分 4 类环境
// (platform clawmanager / platform k8s_native / tenant clawmanager+k8s_native
// / tenant external_endpoint)。8 字段审计标准走 ADR-0011。
package runtimeenv

import "time"

// Env 是 runtime_environments 一行的产品视图。51 字段对齐表结构。
type Env struct {
	// A. 8 字段审计 (ADR-0011)
	ID        int64
	UUID      string
	CreatedAt time.Time
	CreatedBy *int64
	UpdatedAt time.Time
	UpdatedBy *int64
	IsDeleted bool
	DeletedAt *time.Time

	// B. 归属维度
	Scope    string // "platform" | "tenant"
	TenantID *int64 // scope='tenant' 必填; scope='platform' 必空 (chk_renv_scope_tenant)

	// C. 基本属性
	Name        string
	Description string
	Framework   string // "openclaw" | "hermes" | "zap" (ADR-0023: 协议本体一直叫 ZAP, framework 列对齐回归)
	HostingKind string // "clawmanager" | "k8s_native" | "external_endpoint"

	// D. 状态控制
	Status        string // "active" | "disabled" | "archived"
	Enabled       bool
	OpenToTenants bool // 仅 scope='platform' 有意义 (chk_renv_open_only_platform)

	// E. 通用 endpoint
	PrimaryEndpoint       string // external_endpoint 用户填; clawmanager/k8s_native 实例 ensure 后回填
	APIKeySecretRef       string // 必须 env:// / value:// / vault:// 前缀
	ExternalEnvironmentID string // 接入方外部环境引用；仅透传，不参与身份/鉴权

	// F. clawmanager 字段 (hosting_kind='clawmanager' 必填)
	WorkloadAPIBaseURL        string
	WorkloadAPITokenSecretRef string

	// G. k8s_native 字段 (hosting_kind='k8s_native' 必填)
	K8sAPIServerURL       string
	K8sTokenSecretRef     string
	K8sNamespace          string
	K8sInsecureSkipVerify bool

	// H. 部署细节 (hosting_kind != 'external_endpoint' 用)
	ImageRepository string
	ImageTag        string
	GatewayPort     int
	MountPath       string
	StorageClass    string

	// I. 资源 quota (hosting_kind != 'external_endpoint' 用)
	DefaultCPUCores int
	DefaultMemoryGB int
	DefaultDiskGB   int
	WorkloadEnv     map[string]any

	// J. 运行时参数 (ADR-0021; hosting_kind != 'external_endpoint' 用)
	//
	// LLM 网关 + backchannel webhook 由 bus.yaml 全局配置, 不再由本表持有;
	// admin 抽屉只让运维改"默认模型 + 出口网络"。详见 docs/adr/0021。
	LLMDefaultModel string // 留空 = 用 bus.yaml.aigc.default_model
	HTTPProxy       string
	HTTPSProxy      string
	NoProxy         string

	// K. probe 留痕
	LastProbedAt       *time.Time
	LastProbeStatus    string // "ok" | "error" | "timeout" | ""
	LastProbeMessage   string
	LastProbeLatencyMs int

	// L. 合规 (F14 保留位)
	DataEgress           string
	EgressAuditStatus    string // "pending" | "approved" | "rejected" | "needs_revision"
	EgressAuditReason    string
	EgressAuditorID      *int64
	EgressReviewedAt     *time.Time
	EgressComplianceDocs map[string]any

	// M. 扩展
	RateLimit       map[string]any
	Metadata        map[string]any // 含 vendor / bring_your_own_llm / extra_endpoints 等低频字段
	FrameworkConfig map[string]any `json:"framework_config,omitempty"` // Hermes / OpenClaw / ZAP adapter 启动参数 (§8.1)

	// 计算字段 (不存表)
	BoundAgents        int64  // 引用此 env 的 digital_employees 数 (is_deleted=false)
	IsDefaultForCaller bool   // tenant scope 视图: 是否当前租户默认环境
	EnablementUUID     string // platform_enabled 视图填; UI disable / set-default 用
}

// Enablement 是 tenant_runtime_enablements 一行。8 字段审计 + 关联 + is_default。
type Enablement struct {
	ID                   int64
	UUID                 string
	CreatedAt            time.Time
	CreatedBy            *int64
	UpdatedAt            time.Time
	UpdatedBy            *int64
	IsDeleted            bool
	DeletedAt            *time.Time
	TenantID             int64
	RuntimeEnvironmentID int64
	IsDefault            bool
}

// CreateCustomInput 是租户新建自定义 runtime_environment 的入参 (scope='tenant')。
//
// 租户自定义最常见走 hosting_kind='external_endpoint' (自托管 runtime, 只填
// primary_endpoint + api_key_secret_ref)。clawmanager / k8s_native 字段保留供
// 平台 admin 或租户自有 K8s 场景用。
type CreateCustomInput struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Framework   string `json:"framework"`    // openclaw / hermes / zap
	HostingKind string `json:"hosting_kind"` // clawmanager / k8s_native / external_endpoint

	// 通用 endpoint
	PrimaryEndpoint       string `json:"primary_endpoint,omitempty"`
	APIKeySecretRef       string `json:"api_key_secret_ref,omitempty"`
	ExternalEnvironmentID string `json:"external_environment_id,omitempty"`

	// clawmanager
	WorkloadAPIBaseURL        string `json:"workload_api_base_url,omitempty"`
	WorkloadAPITokenSecretRef string `json:"workload_api_token_secret_ref,omitempty"`

	// k8s_native
	K8sAPIServerURL       string `json:"k8s_api_server_url,omitempty"`
	K8sTokenSecretRef     string `json:"k8s_token_secret_ref,omitempty"`
	K8sNamespace          string `json:"k8s_namespace,omitempty"`
	K8sInsecureSkipVerify bool   `json:"k8s_insecure_skip_verify,omitempty"`

	// 部署细节 + quota (hosting_kind != 'external_endpoint')
	ImageRepository string         `json:"image_repository,omitempty"`
	ImageTag        string         `json:"image_tag,omitempty"`
	GatewayPort     int            `json:"gateway_port,omitempty"`
	MountPath       string         `json:"mount_path,omitempty"`
	StorageClass    string         `json:"storage_class,omitempty"`
	DefaultCPUCores int            `json:"default_cpu_cores,omitempty"`
	DefaultMemoryGB int            `json:"default_memory_gb,omitempty"`
	DefaultDiskGB   int            `json:"default_disk_gb,omitempty"`
	WorkloadEnv     map[string]any `json:"workload_env,omitempty"`

	// 运行时参数 (ADR-0021; hosting_kind != 'external_endpoint')
	LLMDefaultModel string `json:"llm_default_model,omitempty"`
	HTTPProxy       string `json:"http_proxy,omitempty"`
	HTTPSProxy      string `json:"https_proxy,omitempty"`
	NoProxy         string `json:"no_proxy,omitempty"`

	// 合规
	DataEgress string `json:"data_egress,omitempty"`

	// 扩展
	RateLimit map[string]any `json:"rate_limit,omitempty"`
	Metadata  map[string]any `json:"metadata,omitempty"`

	// 改 endpoint / secret_ref 时, service 层要求附带 probe service 校验后的 token
	ProbeToken string `json:"probe_token,omitempty"`
}

// PatchCustomInput PATCH 自定义环境字段子集; nil = 不改。
type PatchCustomInput struct {
	Name                      *string `json:"name,omitempty"`
	Description               *string `json:"description,omitempty"`
	PrimaryEndpoint           *string `json:"primary_endpoint,omitempty"`
	APIKeySecretRef           *string `json:"api_key_secret_ref,omitempty"`
	ExternalEnvironmentID     *string `json:"external_environment_id,omitempty"`
	WorkloadAPIBaseURL        *string `json:"workload_api_base_url,omitempty"`
	WorkloadAPITokenSecretRef *string `json:"workload_api_token_secret_ref,omitempty"`
	K8sAPIServerURL           *string `json:"k8s_api_server_url,omitempty"`
	K8sTokenSecretRef         *string `json:"k8s_token_secret_ref,omitempty"`
	K8sNamespace              *string `json:"k8s_namespace,omitempty"`
	ImageRepository           *string `json:"image_repository,omitempty"`
	ImageTag                  *string `json:"image_tag,omitempty"`
	DataEgress                *string `json:"data_egress,omitempty"`
	// 运行时参数 (ADR-0021)
	LLMDefaultModel *string        `json:"llm_default_model,omitempty"`
	HTTPProxy       *string        `json:"http_proxy,omitempty"`
	HTTPSProxy      *string        `json:"https_proxy,omitempty"`
	NoProxy         *string        `json:"no_proxy,omitempty"`
	RateLimit       map[string]any `json:"rate_limit,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
	ProbeToken      string         `json:"probe_token,omitempty"` // 改 endpoint / secret_ref 必须重 probe
}

// TenantListResult 三段视图 (F02 §3.4 GET /admin/v1/tenant/runtime-environments)。
type TenantListResult struct {
	PlatformEnabled   []Env `json:"platform_enabled"`
	PlatformAvailable []Env `json:"platform_available"`
	TenantCustom      []Env `json:"tenant_custom"`
	Total             int   `json:"total"`
	Limit             int   `json:"limit"`
	Offset            int   `json:"offset"`
}

// ClientListResult 客户端 GET /api/agent-bus/v1/runtime-environments 视图。
type ClientListResult struct {
	TenantEnabled []Env `json:"tenant_enabled"`
	CustomOption  bool  `json:"custom_option"` // 是否允许租户管理员自定义
}
