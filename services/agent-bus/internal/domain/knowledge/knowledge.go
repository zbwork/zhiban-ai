// Package knowledge 是 M8 知识库 (Knowledge Bases) 的领域类型.
//
// Phase A scope (见 docs/tasks/m8-knowledge-bases.md):
//   - KB CRUD (space_kind ∈ personal/tenant, visibility ∈ private/tenant 两组合)
//   - 文档上传 + 同步切片 + 写 kb_chunks (stub provider)
//   - 客户端 search / ZAP backchannel recall
//   - chunk 检索: PG tsvector 主路径 + ILIKE fallback
//
// 领域不变量:
//   - 创建 personal KB 必须 visibility=private; 创建 tenant KB 必须 visibility=tenant.
//   - tenant KB 可由客户端租户成员创建;写操作允许创建者/所有者或 tenant.kb.update.
//   - tenant_id 在所有读写路径强制注入, 不接受外部 body 覆盖.
package knowledge

import (
	"time"
)

// SpaceKind / Visibility 枚举 (Phase A 收窄为 2 组合).
//
// 000005 migration 的 knowledge_bases.space_kind / visibility CHECK 仍允许全 4 值;
// service 层在 CRUD 入口把可用组合收窄到下面两组. workspace / platform 留 Phase B.
const (
	SpaceKindPersonal  = "personal"
	SpaceKindTenant    = "tenant"
	SpaceKindPlatform  = "platform"
	SpaceKindWorkspace = "workspace"

	VisibilityPrivate   = "private"
	VisibilityTenant    = "tenant"
	VisibilityPlatform  = "platform"
	VisibilityWorkspace = "workspace"

	AccessModeWorkspace = "workspace"
	AccessModeAgentOnly = "agent_only"
)

type ScopeKind string

const (
	ScopePlatform ScopeKind = "platform"
	ScopeTenant   ScopeKind = "tenant"
	ScopeSelf     ScopeKind = "self"
)

// Actor is the trusted caller identity used by scope-aware knowledge-base
// operations. TenantID is nil only for platform scope.
type Actor struct {
	AccountID int64
	ScopeKind ScopeKind
	TenantID  *int64
	Perms     []string
}

// DocumentStatus kb_documents.status (000005 既有 CHECK: pending/ingesting/ready/failed/disabled).
const (
	DocStatusPending   = "pending"
	DocStatusIngesting = "ingesting"
	DocStatusReady     = "ready"
	DocStatusFailed    = "failed"
	DocStatusDisabled  = "disabled"
)

// CallerKind kb_recall_logs.caller_kind.
const (
	CallerUser  = "user"
	CallerAgent = "agent"
	CallerAdmin = "admin"
)

// KnowledgeBase 行内最小集.
type KnowledgeBase struct {
	ID               int64
	UUID             string
	TenantID         *int64
	CreatorID        int64
	OwnerAccountID   *int64
	SpaceKind        string
	Name             string
	Description      string
	Visibility       string
	AccessMode       string
	Status           string
	ProviderID       *int64
	ProviderKind     string
	RagflowDatasetID string
	ProvisionStatus  string
	ProvisionError   string
	TotalDocuments   int
	RetrievalConfig  map[string]any
	Metadata         map[string]any
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

// Document 行内最小集.
type Document struct {
	ID            int64
	UUID          string
	KBID          int64
	FolderID      *int64
	FolderUUID    string
	Title         string
	SourceKind    string
	MimeType      string
	FileSize      int64
	ChunkCount    int
	Status        string
	ErrorMessage  string
	ProviderDocID string
	StorageKey    string
	ContentSHA256 string
	OriginalName  string
	Metadata      map[string]any
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// Folder KB 内目录树节点.
type Folder struct {
	ID         int64
	UUID       string
	KBID       int64
	ParentID   *int64
	ParentUUID string
	Path       string
	Name       string
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

// Chunk 行内最小集 (stub provider 用).
type Chunk struct {
	ID         int64
	UUID       string
	KBID       int64
	DocumentID int64
	ChunkIndex int
	Content    string
	Metadata   map[string]any
	CreatedAt  time.Time
}

// ProviderConfig kb_provider_config 行.
type ProviderConfig struct {
	ID           int64
	UUID         string
	ProviderKind string
	Name         string
	EndpointURL  string
	APIKeyRef    string
	Settings     map[string]any
	AdminEmail   string
	IsDefault    bool
	Status       string
}

// RecallLog kb_recall_logs 行 (写时输入).
type RecallLog struct {
	TenantID         *int64
	KBScopeKind      string
	AccountID        int64
	AgentID          int64
	KBID             int64
	CallerKind       string
	ConversationUUID string
	QueryText        string
	TopK             int
	Threshold        float64
	ChunkHits        int
	ScoreTop         float64
	LatencyMs        int
	ErrorCode        string
	Metadata         map[string]any
	APIKeyPrefix     string
	SessionTokenID   *int64
}

// CreateKBInput service → repo.
type CreateKBInput struct {
	TenantID        *int64
	CreatorID       int64
	OwnerAccountID  *int64
	SpaceKind       string
	Visibility      string
	AccessMode      string
	Name            string
	Description     string
	ProviderID      *int64
	ProviderKind    string
	ProvisionStatus string
}

// UpdateKBInput service → repo. nil 字段表示不改.
type UpdateKBInput struct {
	Name        *string
	Description *string
	Visibility  *string
}

// ListKBFilter caller-facing 过滤参数.
type ListKBFilter struct {
	TenantID  int64
	AccountID int64
	Limit     int
}

// CreateDocumentInput service → repo (同事务用).
type CreateDocumentInput struct {
	KBID                 int64
	FolderID             *int64
	Title                string
	SourceKind           string
	MimeType             string
	FileSize             int64
	ChunkCount           int
	Status               string
	StorageKey           string
	ContentSHA256        string
	OriginalName         string
	UploadIdempotencyKey *string
	UploadOrdinal        *int
	Metadata             map[string]any
}
