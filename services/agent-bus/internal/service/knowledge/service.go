// Package knowledge 是 M8 知识库的应用服务 (Phase A).
//
// 范围 (docs/tasks/m8-knowledge-bases.md):
//   - KB CRUD (含 visibility + 权限闸口)
//   - 文档 upload + 同步切片 + 走 stub provider Ingest
//   - 客户端 search / DELETE 文档
//   - ZAP backchannel Recall (走 session_token → tenantID/agentUUID → 校验装配)
//
// 严格按 docs/tasks/m8-knowledge-bases.md §4:
//   - service 方法显式接收 accountID / tenantID / perms; 不读 ctx.Value (本包仅 ctx 传播);
//   - tenant_id 在 Recall / search 强制注入 provider, 不接受 body 覆盖;
//   - pg_notify('config_change','knowledge_bases:<id>') 写后 best-effort.
package knowledge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"

	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
	repoevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	repokb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider/dify"
	kbresolver "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider/resolver"
)

// mapProviderErr 将 provider/resolver 的退化错误映射成 kb.provider_degraded; 其它错误透传.
//
// Codex round-3 P1-4: 业务层 (Search / Recall / Upload / Delete) 任何 provider 调用前/后都
// 走这层映射, 避免被包成 internal/500.
func mapProviderErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, kbresolver.ErrDegraded) || errors.Is(err, dify.ErrProviderDegraded) {
		return apperr.New(apperr.Conflict, ErrCodeKBProviderDegraded).Withf("kb provider unavailable: %v", err)
	}
	return err
}

// Phase A 错误码 (docs/tasks/m8-knowledge-bases.md §4.4 / §4.6).
const (
	ErrCodeKBNotFound = "kb.not_found"
	// Codex round-3 P1-4: provider 退化错误统一映射. 业务层捕获 resolver.ErrDegraded
	// 和 dify.ErrProviderDegraded 后转此码; 不再被包成 internal/500.
	ErrCodeKBProviderDegraded  = "kb.provider_degraded"
	ErrCodeKBVisibilityInvalid = "kb.visibility_invalid"
	ErrCodeKBPermissionDenied  = "kb.permission_denied"
	ErrCodeKBDocFormat         = "kb.document_format_unsupported"
	ErrCodeKBDocTooLarge       = "kb.document_too_large"
	// ErrCodeKBAttachForbidden Codex review #2: admin attach KB 时 KB 类型不允许 (Phase A 仅 tenant+tenant).
	ErrCodeKBAttachForbidden = "kb.attach_forbidden"

	// ZAP backchannel.
	ErrCodeZAPSessionInvalid     = "zap.session_invalid"
	ErrCodeZAPKBNotAttached      = "zap.kb_not_attached"
	ErrCodeZAPKBVisibilityDenied = "zap.kb_visibility_denied"
)

// Phase A 权限 code.
const PermTenantKBUpdate = "tenant.kb.update"

var recallLogRedactor = redact.New()

func recallQueryPreview(query string) string {
	redacted := recallLogRedactor.RedactText(strings.TrimSpace(query))
	runes := []rune(redacted)
	if len(runes) > 500 {
		return string(runes[:500])
	}
	return redacted
}

// 默认值 (env / config 覆盖).
const (
	DefaultTopK            = 5
	DefaultThreshold       = 0.05
	DefaultDocMaxBytes     = 50 * 1024 * 1024 // 50MB
	DefaultRecallTimeoutMs = 1000
)

type storageLimitResolver interface {
	StorageLimitBytes(ctx context.Context, tenantID int64, featureCode string) (*int64, error)
}

// Service 对外接口.
type Service interface {
	// Client (Bus) API ----
	ListKB(ctx context.Context, accountID, tenantID int64, perms []string) ([]KBDTO, error)
	GetKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string) (*KBDTO, error)
	// ReplaceAgentKBBindings 客户端"编辑数字员工"一次性替换该 agent 的知识库绑定
	// (按 kbUUIDs 顺序记 priority)。每个 kb 经 assertKBAccess 校验租户可见性; 空 = 清空。
	// agentID 由调用方解析 uuid + ownership 后传入 (与应用/技能绑定同款 replace 流)。
	ReplaceAgentKBBindings(ctx context.Context, accountID, tenantID, agentID int64, kbUUIDs []string) error
	// ReplaceAdminAgentKBBindings 租户后台编辑数字员工时替换 admin 可管理的 KB 绑定。
	// 仅处理 tenant+tenant KB; 请求中夹带的 personal/private KB 会被忽略, 既不新增也不删除既有私有绑定。
	ReplaceAdminAgentKBBindings(ctx context.Context, accountID, tenantID, agentID int64, kbUUIDs []string) error
	// ListAgentKBs 列出某 agent 已绑的知识库摘要 (uuid+name)，供列表/详情卡片 hydrate。
	ListAgentKBs(ctx context.Context, agentID int64) ([]AgentKBSummary, error)
	CreateKB(ctx context.Context, accountID, tenantID int64, perms []string, req CreateKBReq) (*KBDTO, error)
	PatchKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req PatchKBReq) (*KBDTO, error)
	DeleteKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string) error

	ListFolders(ctx context.Context, accountID, tenantID int64, kbUUID string) ([]FolderDTO, error)
	CreateFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req CreateFolderReq) (*FolderDTO, error)
	PatchFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, folderUUID string, req PatchFolderReq) (*FolderDTO, error)
	DeleteFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, folderUUID string) error

	ListDocuments(ctx context.Context, accountID, tenantID int64, kbUUID, kbFolderUUID string) ([]DocumentDTO, error)
	GetDocument(ctx context.Context, accountID, tenantID int64, kbUUID, docUUID string) (*DocumentDTO, error)
	DownloadDocument(ctx context.Context, accountID, tenantID int64, kbUUID, docUUID string) (*DocumentDownload, error)
	// ListDocumentsPaged 分页版 (admin web 用); limit<=0 → 50, limit>500 → 500, offset<0 → 0。
	ListDocumentsPaged(ctx context.Context, accountID, tenantID int64, kbUUID, kbFolderUUID string, limit, offset int) (items []DocumentDTO, total int, err error)
	// AdminListDocumentsPaged 供 tenant admin 审计/运维视角读取同租户 KB 文档, 不受 private owner 可见性限制。
	AdminListDocumentsPaged(ctx context.Context, tenantID int64, kbUUID string, limit, offset int) (items []DocumentDTO, total int, err error)
	UploadDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req UploadDocReq) (*DocumentDTO, error)
	PatchDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string, req PatchDocumentReq) (*DocumentDTO, error)
	DeleteDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string) error
	Search(ctx context.Context, accountID, tenantID int64, kbUUID string, req SearchReq) (*SearchResp, error)
	RetrieveAuthorizedForChat(ctx context.Context, in ChatRetrieveInput) (*SearchResp, error)
	RetrieveAuthorizedBatchForChat(ctx context.Context, in ChatRetrieveBatchInput) ([]*SearchResp, error)
	// AdminSearch 供 tenant admin 调优/运维视角召回同租户 KB, 不受 private owner 可见性限制。
	AdminSearch(ctx context.Context, accountID, tenantID int64, kbUUID string, req SearchReq) (*SearchResp, error)

	// LinkFromDrive · B-5-1 §A5.7: 把 caller 的 drive_files 内容 ingest 到 KB.
	//
	// driveFileUUID 必填; caller 必须是 drive_file owner; KB 必须可写.
	// MIME / size 校验同 UploadDocument; 读 OSS 内容用 PresignGet URL + http.Get;
	// Dify 不可达 → kb.provider_degraded.
	LinkFromDrive(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, driveFileUUID, kbFolderUUID string) (*DocumentDTO, error)

	// Admin API ----
	ListTenantKB(ctx context.Context, tenantID int64) ([]KBDTO, error)
	// AssertKBAttachable Codex review #2: admin attach KB capability 闸口.
	//
	// Phase A 仅允许装 tenant+tenant KB; personal/private KB 不允许 admin attach (留 owner 流程).
	// 校验: KB 存在 + 软删未行 + 同租户 + space_kind=tenant + visibility=tenant.
	AssertKBAttachable(ctx context.Context, tenantID int64, kbUUID string) error

	// ZAP backchannel ----
	Recall(ctx context.Context, in RecallInput) (*RecallResp, error)

	// F07 集成 API ----
	// ListUserPrivateKB · D13 跨用户列私有 KB (审计敏感); caller 应已通过 scope=tenant.kb.list_user_private 检查.
	ListUserPrivateKB(ctx context.Context, tenantID, targetAccountID int64, apiKeyPrefix string, scopesUsed []string) ([]KBDTO, error)
	// TransferUserKBOnDeactivation · R-10.4 用户离职时把其个人 KB 转给租户 admin (变 space_kind=tenant + owner=NULL).
	TransferUserKBOnDeactivation(ctx context.Context, tenantID, leavingAccountID int64) (int, error)
	// RetryIngest · R-2.3 解析失败的文档人工 retry (status: failed → pending, 让 worker 重新拉 RAGFlow).
	RetryIngest(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string) error
	// EnqueueTenantCleanup · 租户硬删 (30 天宽限期后) 调; 插 outbox 异步清 RAGFlow.
	EnqueueTenantCleanup(ctx context.Context, tenantID int64, ragflowEmail string) error
}

// AdminManager is the scope-aware management surface used only by cmd/admin.
// It is kept separate from the legacy Service interface so existing Bus fakes
// and client contracts do not gain admin-only methods.
type AdminManager interface {
	ListManagedKnowledgeBases(ctx context.Context, actor domkb.Actor, filter ManagedKBFilter) ([]KBDTO, int, error)
	GetManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string) (*KBDTO, error)
	CreateManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, req CreateKBReq) (*KBDTO, error)
	PatchManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string, req PatchKBReq) (*KBDTO, error)
	DeleteManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string) error
	ManagedKnowledgeBaseReferences(ctx context.Context, actor domkb.Actor, kbUUID string) (int64, error)
	ListManagedFolders(ctx context.Context, actor domkb.Actor, kbUUID string) ([]FolderDTO, error)
	CreateManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID string, req CreateFolderReq) (*FolderDTO, error)
	PatchManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string, req PatchFolderReq) (*FolderDTO, error)
	DeleteManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string) error
	ListManagedDocuments(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string, limit, offset int) ([]DocumentDTO, int, error)
	UploadManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID string, req UploadDocReq) (*DocumentDTO, error)
	PatchManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string, req PatchDocumentReq) (*DocumentDTO, error)
	DeleteManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) error
	RetryManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) (*DocumentDTO, error)
	ManagedDocumentDownloadURL(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) (string, error)
	SearchManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string, req SearchReq) (*SearchResp, error)
}

// AgentLookup composer 借用; 反查 agent → de_id / tenant_id.
type AgentLookup interface {
	GetByUUID(ctx context.Context, tenantID int64, agentUUID string) (*AgentMeta, error)
}

// AgentMeta 反查输出 (尽量窄).
type AgentMeta struct {
	ID        int64
	UUID      string
	TenantID  int64
	CreatorID int64
}

// SessionResolver 复用 composer.ZAPSessionResolver 的契约; 这里做窄抽象避免循环依赖.
type SessionResolver interface {
	Resolve(ctx context.Context, sessionToken string) (*Session, error)
}

// EMPValidator Codex review #3: M8 Phase A 把 Recall 返的 source block 也过 3D 校验器.
//
// 与 svcchat.EMPValidator 同款抽象; cmd/bus 用 empValidatorBridge 同源装配 (避免循环依赖).
//
// nil → 跳过校验, source_block 原样返回 (保留 v0 行为).
// fallback → caller 拿到改写后的 block (type=fallback_type), 同时写 audit.emp.block.fallback.
//
// 注意: source block 的 "kind" 字段在 EMP 协议里就是 "type" — service 构造时已对齐.
type EMPValidator interface {
	ValidateBlocks(ctx context.Context, blocks []map[string]any, clientVer string) ([]map[string]any, []EMPFallbackEvent)
}

// EMPFallbackEvent 与 svcchat.EMPFallbackEvent 字段一一对应; 本包不 import chat.
type EMPFallbackEvent struct {
	OriginalType string
	FallbackType string
	Reason       string
	Index        int
}

// Session resolver 输出.
type Session struct {
	TenantID         int64
	AccountID        int64
	AgentUUID        string
	ConversationUUID string
}

// DriveFileLookup · B-5-1 §A5.7 LinkFromDrive 用窄抽象.
//
// 实现职责 (cmd/bus 用 svcdrive.Service + repo 适配):
//  1. 反查 drive_files 一行 (含 storage_kind / storage_key / mime / size / owner check);
//  2. 调 object.Store.PresignGet 拿一个短 TTL signed URL;
//  3. 让 caller HTTP GET 下来 (不在本接口里 fetch, 避免 cross-package HTTP dep).
//
// 与 svcdrive.MessageFileLookup 同款风格 — 单一 method 暴露最小投影.
type DriveFileLookup interface {
	// GetDriveFileForRead 返 file 元信息 + 一个一次性 GET URL (TTL ≤ 10min).
	// caller 用 URL 下载内容. err == nil ⇒ snapshot ≠ nil 且 caller 已校权.
	GetDriveFileForRead(ctx context.Context, accountID, tenantID int64, driveFileUUID string) (*DriveFileSnapshot, error)
}

// DriveFileSnapshot · DriveFileLookup 的最小投影.
type DriveFileSnapshot struct {
	UUID        string
	FileName    string
	MimeType    string
	FileSize    int64
	StorageKind string
	StorageKey  string
	DownloadURL string // 一次性 signed GET URL
}

// Deps 构造依赖.
type Deps struct {
	Logger   *log.Logger
	Repo     *repokb.Repo
	Pool     *pgxpool.Pool
	Provider provider.Provider
	Audit    domevent.Publisher
	Agents   AgentLookup
	Sessions SessionResolver
	// EMPValidator Codex review #3: 可选; nil 时跳过 source block 校验.
	EMPValidator EMPValidator
	// DriveFiles · B-5-1 §A5.7 LinkFromDrive 用; nil → LinkFromDrive 返 kb.link.unavailable.
	DriveFiles DriveFileLookup
	// LinkFromDriveMaxBytes 单次链接的字节上限 (与 DocMaxBytes 一致, 这里独立 cap 防范大文件).
	// 0 → 复用 Config.DocMaxBytes.
	LinkFromDriveMaxBytes int64
	Config                Config
	Quota                 dombilling.EntitlementChecker
	ObjectStores          ObjectStoreResolver

	// F07 集成组件 (全部 optional; nil 时退化到 stub provider 模式):
	//   - RagflowExt: ragflow 真上传/检索/删除 dataset (CreateKB 后 lazy provision)
	//   - OutboxRepo: kb 删除时异步推 RAGFlow DELETE dataset
	//   - AgentKBRepo: ZAP recall capability check (防 D5/D9 交叉访问)
	RagflowExt  RagflowExtension
	OutboxRepo  OutboxRepo
	AgentKBRepo AgentKBRepo
}

// RagflowExtension · ragflow.Provider 实现, 提供超出 provider.Provider 接口的能力。
// 实现典型: *ragflow.Provider (cmd/bus wire 时显式注入)。
type RagflowExtension interface {
	EnsureDataset(ctx context.Context, tenantID int64, kbName string) (datasetID string, err error)
	UploadFile(ctx context.Context, tenantID int64, datasetID, filename string, content []byte) (ragflowDocID string, err error)
	DownloadFile(ctx context.Context, tenantID int64, datasetID, documentID string) ([]byte, error)
	DeleteDataset(ctx context.Context, tenantID int64, datasetID string) error
}

type ScopedRagflowExtension interface {
	EnsureDatasetForKB(ctx context.Context, tenantID, kbID int64, kbName string) (string, error)
	UploadFileForKB(ctx context.Context, tenantID, kbID int64, datasetID, filename string, content []byte) (string, error)
	DownloadFileForKB(ctx context.Context, tenantID, kbID int64, datasetID, documentID string) ([]byte, error)
	DeleteDatasetForKB(ctx context.Context, tenantID, kbID int64, datasetID string) error
}

type ObjectStoreResolver interface {
	Resolve(ctx context.Context, tenantID int64) (object.Store, error)
}

// OutboxRepo · F07 D8 kb_outbox_events 写入接口。
type OutboxRepo interface {
	Insert(ctx context.Context, tenantID int64, op string, payload []byte) error
}

// AgentKBRepo · F07 D5 agent_kb_bindings 查询接口。
type AgentKBRepo interface {
	IsBound(ctx context.Context, agentID, kbID int64) (bool, error)
	// ReplaceForAgent 事务式整体替换某 agent 的知识库绑定 (供编辑数字员工提交)。
	ReplaceForAgent(ctx context.Context, agentID, createdBy int64, kbIDs []int64) error
	// ReplaceAdminTenantForAgent 仅替换后台可管理的 tenant+tenant KB 绑定, 保留 personal/private 绑定。
	ReplaceAdminTenantForAgent(ctx context.Context, agentID, createdBy int64, kbIDs []int64) error
}

// Config service 配置.
type Config struct {
	DocMaxBytes        int64
	PlatformQuotaBytes int64
	DefaultTopK        int
	DefaultThreshold   float64
	RecallTimeoutMs    int
}

// New 构造 service.
func New(deps Deps) Service {
	if deps.Logger == nil {
		deps.Logger = log.Default()
	}
	if deps.Repo == nil {
		panic("knowledge.New: repo required")
	}
	if deps.Pool == nil {
		deps.Pool = deps.Repo.Pool()
	}
	if deps.Pool == nil {
		panic("knowledge.New: pgxpool required")
	}
	if deps.Provider == nil {
		panic("knowledge.New: provider required")
	}
	cfg := deps.Config
	if cfg.DocMaxBytes <= 0 {
		cfg.DocMaxBytes = DefaultDocMaxBytes
	}
	if cfg.PlatformQuotaBytes <= 0 {
		cfg.PlatformQuotaBytes = 100 * 1024 * 1024 * 1024
	}
	if cfg.DefaultTopK <= 0 {
		cfg.DefaultTopK = DefaultTopK
	}
	if cfg.DefaultThreshold <= 0 {
		cfg.DefaultThreshold = DefaultThreshold
	}
	if cfg.RecallTimeoutMs <= 0 {
		cfg.RecallTimeoutMs = DefaultRecallTimeoutMs
	}
	driveCap := deps.LinkFromDriveMaxBytes
	if driveCap <= 0 {
		driveCap = cfg.DocMaxBytes
	}
	return &impl{
		logger:       deps.Logger,
		repo:         deps.Repo,
		pool:         deps.Pool,
		provider:     deps.Provider,
		audit:        deps.Audit,
		agents:       deps.Agents,
		sessions:     deps.Sessions,
		validator:    deps.EMPValidator,
		driveFiles:   deps.DriveFiles,
		driveLinkCap: driveCap,
		cfg:          cfg,
		quota:        deps.Quota,
		objectStores: deps.ObjectStores,
		ragflowExt:   deps.RagflowExt,
		outboxRepo:   deps.OutboxRepo,
		agentKBRepo:  deps.AgentKBRepo,
	}
}

type impl struct {
	logger       *log.Logger
	repo         *repokb.Repo
	pool         *pgxpool.Pool
	provider     provider.Provider
	audit        domevent.Publisher
	agents       AgentLookup
	sessions     SessionResolver
	validator    EMPValidator
	driveFiles   DriveFileLookup
	driveLinkCap int64
	cfg          Config
	quota        dombilling.EntitlementChecker
	objectStores ObjectStoreResolver

	// F07 集成组件 (optional, cmd/bus 装配)
	ragflowExt  RagflowExtension
	outboxRepo  OutboxRepo
	agentKBRepo AgentKBRepo
}

// SetEMPValidator Codex review #3: 装配 helper (cmd/bus / 单测).
func (s *impl) SetEMPValidator(v EMPValidator) { s.validator = v }

// SetEMPValidatorOnService 装配 helper, 与 svcchat.SetEMPValidatorOnService 同款用法.
func SetEMPValidatorOnService(svc Service, v EMPValidator) {
	if im, ok := svc.(*impl); ok {
		im.SetEMPValidator(v)
	}
}

func (s *impl) SetEntitlementChecker(q dombilling.EntitlementChecker) { s.quota = q }

func SetEntitlementCheckerOnService(svc Service, q dombilling.EntitlementChecker) {
	if im, ok := svc.(*impl); ok {
		im.SetEntitlementChecker(q)
	}
}

// =====================================================
// DTOs
// =====================================================

type KBDTO struct {
	UUID             string         `json:"uuid"`
	Name             string         `json:"name"`
	Description      string         `json:"description,omitempty"`
	SpaceKind        string         `json:"space_kind"`
	Visibility       string         `json:"visibility"`
	AccessMode       string         `json:"access_mode"`
	Status           string         `json:"status"`
	ProviderKind     string         `json:"provider_kind,omitempty"`
	RagflowDatasetID string         `json:"ragflow_dataset_id,omitempty"`
	ProvisionStatus  string         `json:"provision_status,omitempty"`
	ProvisionError   string         `json:"provision_error,omitempty"`
	TotalDocuments   int            `json:"total_documents"`
	RetrievalConfig  map[string]any `json:"retrieval_config,omitempty"`
	CreatorID        int64          `json:"creator_id"`
	CreatorName      string         `json:"creator_name,omitempty"`
	OwnerAccountID   *int64         `json:"owner_account_id,omitempty"`
	OwnerName        string         `json:"owner_name,omitempty"`
	CanWrite         bool           `json:"can_write"`
	CreatedAt        time.Time      `json:"created_at"`
	UpdatedAt        time.Time      `json:"updated_at"`
}

type ManagedKBFilter struct {
	Query  string
	Status string
	Limit  int
	Offset int
}

type DocumentDownload struct {
	Title    string
	MimeType string
	Content  []byte
}

type DocumentDTO struct {
	UUID         string    `json:"uuid"`
	KBUUID       string    `json:"kb_uuid"`
	KBFolderUUID string    `json:"kb_folder_uuid,omitempty"`
	Title        string    `json:"title"`
	MimeType     string    `json:"mime_type,omitempty"`
	FileSize     int64     `json:"file_size"`
	ChunkCount   int       `json:"chunk_count"`
	Status       string    `json:"status"`
	ErrorMessage string    `json:"error_message,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type FolderDTO struct {
	UUID       string    `json:"uuid"`
	KBUUID     string    `json:"kb_uuid"`
	ParentUUID string    `json:"parent_uuid,omitempty"`
	Name       string    `json:"name"`
	Path       string    `json:"path"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

type ChunkDTO struct {
	UUID          string  `json:"uuid"`
	DocumentID    int64   `json:"document_id"`
	DocumentTitle string  `json:"document_title,omitempty"`
	ChunkIndex    int     `json:"chunk_index"`
	Content       string  `json:"content"`
	Score         float64 `json:"score"`
	Source        string  `json:"source,omitempty"`
}

type CreateKBReq struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	SpaceKind   string `json:"space_kind"`
	Visibility  string `json:"visibility"`
}

type PatchKBReq struct {
	Name        *string `json:"name,omitempty"`
	Description *string `json:"description,omitempty"`
	Visibility  *string `json:"visibility,omitempty"`
}

type UploadDocReq struct {
	Title          string
	MimeType       string
	Content        []byte
	KBFolderUUID   string
	OriginalName   string
	IdempotencyKey string
	UploadOrdinal  int
}

type PatchDocumentReq struct {
	Title string `json:"title"`
}

type CreateFolderReq struct {
	Name       string `json:"name"`
	ParentUUID string `json:"parent_uuid,omitempty"`
}

type PatchFolderReq struct {
	Name string `json:"name"`
}

type SearchReq struct {
	Query     string  `json:"query"`
	TopK      int     `json:"top_k,omitempty"`
	Threshold float64 `json:"threshold,omitempty"`
}

type SearchResp struct {
	KBUUID string     `json:"kb_uuid"`
	Query  string     `json:"query"`
	Chunks []ChunkDTO `json:"chunks"`
}

// ChatRetrieveInput 是 F07 ChatRAGService 的 Phase 1A 低层检索输入。
// 它只做当前 account + agent binding + KB 可见性校验，然后调用 provider.Retrieve。
// 不写 recall log，不发 audit，不生成 source block；上层 ChatRAGService 负责聚合副作用。
type ChatRetrieveInput struct {
	TenantID  int64
	AccountID int64
	AgentID   int64
	KBUUID    string
	Query     string
	TopK      int
	Threshold float64
}

type ChatRetrieveBatchInput struct {
	TenantID  int64
	AccountID int64
	AgentID   int64
	KBUUIDs   []string
	Query     string
	TopK      int
	Threshold float64
}

// RecallInput ZAP backchannel 入参.
//
// SessionToken 主路径; AgentUUID + TenantID 仅 smoke / 单测路径 (AllowAgentUUIDHeader).
type RecallInput struct {
	SessionToken  string
	AgentUUIDHint string // header fallback (smoke only)
	TenantIDHint  int64
	KBUUID        string
	Query         string
	TopK          int
	Threshold     float64
	// Caller-supplied tenant_id 必须被忽略 (强制 filter 注入).
	UntrustedTenantID int64
	ConversationUUID  string
}

// RecallResp ZAP backchannel 返回.
type RecallResp struct {
	KBUUID string     `json:"kb_uuid"`
	Query  string     `json:"query"`
	Chunks []ChunkDTO `json:"chunks"`
	// SourceBlock Bus 预渲染好的最小 source block DTO (citation 透传).
	// Phase A 仅给 agent 一个参考形态; agent 是否拼到 SSE 输出由其自决.
	SourceBlock map[string]any `json:"source_block,omitempty"`
}

// =====================================================
// helpers
// =====================================================

func (s *impl) toKBDTO(kb *domkb.KnowledgeBase) KBDTO {
	return KBDTO{
		UUID: kb.UUID, Name: kb.Name, Description: kb.Description,
		SpaceKind: kb.SpaceKind, Visibility: kb.Visibility, Status: kb.Status,
		AccessMode:       kb.AccessMode,
		ProviderKind:     kb.ProviderKind,
		RagflowDatasetID: kb.RagflowDatasetID,
		ProvisionStatus:  kb.ProvisionStatus,
		ProvisionError:   kb.ProvisionError,
		TotalDocuments:   kb.TotalDocuments,
		RetrievalConfig:  kb.RetrievalConfig,
		CreatorID:        kb.CreatorID,
		OwnerAccountID:   kb.OwnerAccountID,
		CanWrite:         false,
		CreatedAt:        kb.CreatedAt,
		UpdatedAt:        kb.UpdatedAt,
	}
}

func (s *impl) toKBDTOForAccount(kb *domkb.KnowledgeBase, accountID int64, perms []string) KBDTO {
	dto := s.toKBDTO(kb)
	dto.CanWrite = assertCanModify(kb, accountID, perms) == nil
	return dto
}

func toDocumentDTO(d *domkb.Document, kbUUID string) DocumentDTO {
	return DocumentDTO{
		UUID: d.UUID, KBUUID: kbUUID, KBFolderUUID: d.FolderUUID, Title: d.Title, MimeType: d.MimeType,
		FileSize: d.FileSize, ChunkCount: d.ChunkCount, Status: d.Status,
		ErrorMessage: d.ErrorMessage, CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt,
	}
}

func toFolderDTO(f *domkb.Folder, kbUUID string) FolderDTO {
	return FolderDTO{
		UUID: f.UUID, KBUUID: kbUUID, ParentUUID: f.ParentUUID,
		Name: f.Name, Path: f.Path, CreatedAt: f.CreatedAt, UpdatedAt: f.UpdatedAt,
	}
}

func hasPerm(perms []string, code string) bool {
	for _, p := range perms {
		if p == code {
			return true
		}
	}
	return false
}

func int64Ptr(v int64) *int64 { return &v }

func kbBelongsToTenant(kb *domkb.KnowledgeBase, tenantID int64) bool {
	return kb != nil && kb.TenantID != nil && *kb.TenantID == tenantID
}

func isPlatformAgentKB(kb *domkb.KnowledgeBase) bool {
	return kb != nil && kb.TenantID == nil && kb.SpaceKind == domkb.SpaceKindPlatform &&
		kb.Visibility == domkb.VisibilityPlatform && kb.AccessMode == domkb.AccessModeAgentOnly
}

// validateKBVisibility Phase A 收窄到 2 组合.
func validateKBVisibility(spaceKind, visibility string) error {
	switch {
	case spaceKind == domkb.SpaceKindPersonal && visibility == domkb.VisibilityPrivate:
		return nil
	case spaceKind == domkb.SpaceKindTenant && visibility == domkb.VisibilityTenant:
		return nil
	}
	return apperr.New(apperr.InvalidParams, ErrCodeKBVisibilityInvalid).
		Withf("space_kind=%q visibility=%q not in (personal+private, tenant+tenant)", spaceKind, visibility)
}

func isAdminAttachableKB(kb *domkb.KnowledgeBase) bool {
	return kb != nil && kb.SpaceKind == domkb.SpaceKindTenant && kb.Visibility == domkb.VisibilityTenant
}

// assertKBAccess 访问闸口: tenant 相同 + visibility 命中.
func (s *impl) assertKBAccess(kb *domkb.KnowledgeBase, accountID, tenantID int64) error {
	if !kbBelongsToTenant(kb, tenantID) {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("cross tenant")
	}
	switch kb.Visibility {
	case domkb.VisibilityTenant:
		return nil
	case domkb.VisibilityPrivate:
		if kb.OwnerAccountID != nil && *kb.OwnerAccountID == accountID {
			return nil
		}
		if kb.OwnerAccountID == nil && kb.CreatorID == accountID {
			return nil
		}
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("private kb not visible")
	}
	return apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).Withf("unknown visibility")
}

// assertCanModify 写闸口: personal KB 必须 owner; tenant KB 允许 owner/creator 或 tenant KB 编辑权限.
func assertCanModify(kb *domkb.KnowledgeBase, accountID int64, perms []string) error {
	if kb.SpaceKind == domkb.SpaceKindTenant {
		if kb.OwnerAccountID != nil && *kb.OwnerAccountID == accountID {
			return nil
		}
		if kb.CreatorID == accountID {
			return nil
		}
		if hasPerm(perms, PermTenantKBUpdate) {
			return nil
		}
		return apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).
			Withf("tenant kb requires owner/creator or %s", PermTenantKBUpdate)
	}
	// personal
	if kb.CreatorID != accountID {
		return apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).Withf("not owner")
	}
	return nil
}

// =====================================================
// CRUD
// =====================================================

func (s *impl) ListKB(ctx context.Context, accountID, tenantID int64, perms []string) ([]KBDTO, error) {
	if tenantID <= 0 || accountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant/account required")
	}
	rows, err := s.repo.ListVisibleKB(ctx, domkb.ListKBFilter{
		TenantID: tenantID, AccountID: accountID, Limit: 100,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]KBDTO, 0, len(rows))
	for i := range rows {
		out = append(out, s.toKBDTOForAccount(&rows[i], accountID, perms))
	}
	return out, nil
}

func (s *impl) GetKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string) (*KBDTO, error) {
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
		return nil, err
	}
	dto := s.toKBDTOForAccount(kb, accountID, perms)
	return &dto, nil
}

func (s *impl) ReplaceAgentKBBindings(ctx context.Context, accountID, tenantID, agentID int64, kbUUIDs []string) error {
	if s.agentKBRepo == nil {
		return apperr.ErrInternal.Withf("agent kb repo not wired")
	}
	// 逐个解析 kb uuid → id, 并校验租户可见性 (不信客户端任意 uuid; 跨租户/不存在直接拒)。
	kbIDs := make([]int64, 0, len(kbUUIDs))
	seen := make(map[int64]struct{}, len(kbUUIDs))
	for _, u := range kbUUIDs {
		u = strings.TrimSpace(u)
		if u == "" {
			continue
		}
		kb, err := s.repo.GetKBByUUID(ctx, u)
		if err != nil {
			if errors.Is(err, apperr.ErrNotFound) {
				return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", u)
			}
			return apperr.ErrInternal.Wrap(err)
		}
		if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
			return err
		}
		if _, dup := seen[kb.ID]; dup {
			continue
		}
		seen[kb.ID] = struct{}{}
		kbIDs = append(kbIDs, kb.ID)
	}
	return s.agentKBRepo.ReplaceForAgent(ctx, agentID, accountID, kbIDs)
}

func (s *impl) ReplaceAdminAgentKBBindings(ctx context.Context, accountID, tenantID, agentID int64, kbUUIDs []string) error {
	if s.agentKBRepo == nil {
		return apperr.ErrInternal.Withf("agent kb repo not wired")
	}
	// 平台模板复制会为租户副本写入 platform+agent_only 绑定。编辑器回显并原样
	// 提交这些 UUID 时允许通过，但它们不进入 tenant replace 集合；底层
	// ReplaceAdminTenantForAgent 会保留平台代理绑定。未继承的平台 KB 仍拒绝，避免
	// 租户通过构造请求把任意平台知识库挂到自己的员工上。
	existing, err := s.repo.ListAgentKBBindings(ctx, agentID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	inheritedPlatform := make(map[string]struct{})
	for _, binding := range existing {
		if binding.SpaceKind == domkb.SpaceKindPlatform {
			inheritedPlatform[binding.UUID] = struct{}{}
		}
	}
	kbIDs := make([]int64, 0, len(kbUUIDs))
	seen := make(map[int64]struct{}, len(kbUUIDs))
	for _, u := range kbUUIDs {
		u = strings.TrimSpace(u)
		if u == "" {
			continue
		}
		kb, err := s.repo.GetKBByUUID(ctx, u)
		if err != nil {
			if errors.Is(err, apperr.ErrNotFound) {
				return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", u)
			}
			return apperr.ErrInternal.Wrap(err)
		}
		if isPlatformAgentKB(kb) {
			if _, ok := inheritedPlatform[u]; !ok {
				return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", u)
			}
			continue
		}
		if !kbBelongsToTenant(kb, tenantID) {
			return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", u)
		}
		if !isAdminAttachableKB(kb) {
			continue
		}
		if _, dup := seen[kb.ID]; dup {
			continue
		}
		seen[kb.ID] = struct{}{}
		kbIDs = append(kbIDs, kb.ID)
	}
	return s.agentKBRepo.ReplaceAdminTenantForAgent(ctx, agentID, accountID, kbIDs)
}

// AgentKBSummary · agent 已绑知识库展示摘要 (列表/详情卡片用)。
type AgentKBSummary struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
}

func (s *impl) ListAgentKBs(ctx context.Context, agentID int64) ([]AgentKBSummary, error) {
	views, err := s.repo.ListAgentKBBindings(ctx, agentID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]AgentKBSummary, 0, len(views))
	for _, v := range views {
		out = append(out, AgentKBSummary{UUID: v.UUID, Name: v.Name})
	}
	return out, nil
}

// ListAgentKBsByAgentIDs 批量版 ListAgentKBs（客户端 /agents 列表 hydrate 用）。
// 不在 Service 接口上（避免波及既有 fakes）；transport 层按可选接口断言使用，
// 与 RuntimeEnvBatchNamer 同款模式。map 缺失的 agentID 表示无绑定。
func (s *impl) ListAgentKBsByAgentIDs(ctx context.Context, agentIDs []int64) (map[int64][]AgentKBSummary, error) {
	if len(agentIDs) == 0 {
		return map[int64][]AgentKBSummary{}, nil
	}
	viewsByAgent, err := s.repo.ListAgentKBBindingsByAgents(ctx, agentIDs)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make(map[int64][]AgentKBSummary, len(viewsByAgent))
	for agentID, views := range viewsByAgent {
		items := make([]AgentKBSummary, 0, len(views))
		for _, v := range views {
			items = append(items, AgentKBSummary{UUID: v.UUID, Name: v.Name})
		}
		out[agentID] = items
	}
	return out, nil
}

func (s *impl) CreateKB(ctx context.Context, accountID, tenantID int64, perms []string, req CreateKBReq) (*KBDTO, error) {
	name := strings.TrimSpace(req.Name)
	if name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	if len(name) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("name too long")
	}
	if tenantID <= 0 || accountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant/account required")
	}
	sk := req.SpaceKind
	vis := req.Visibility
	if sk == "" {
		sk = domkb.SpaceKindPersonal
	}
	if vis == "" {
		if sk == domkb.SpaceKindTenant {
			vis = domkb.VisibilityTenant
		} else {
			vis = domkb.VisibilityPrivate
		}
	}
	if err := validateKBVisibility(sk, vis); err != nil {
		return nil, err
	}
	// resolve default provider.
	prov, err := s.repo.GetDefaultProvider(ctx)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("no default kb provider: %v", err)
	}
	pid := prov.ID
	providerKind := prov.ProviderKind
	if providerKind == "" {
		providerKind = "stub"
	}
	provisionStatus := "active"
	if providerKind == "ragflow" {
		provisionStatus = "pending"
	}
	var ownerAccountID *int64
	if sk == domkb.SpaceKindPersonal {
		owner := accountID
		ownerAccountID = &owner
	}

	var created *domkb.KnowledgeBase
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		kb, err := s.repo.CreateKB(ctx, tx, domkb.CreateKBInput{
			TenantID: int64Ptr(tenantID), CreatorID: accountID, OwnerAccountID: ownerAccountID,
			SpaceKind: sk, Visibility: vis,
			AccessMode: domkb.AccessModeWorkspace,
			Name:       name, Description: req.Description,
			ProviderID: &pid, ProviderKind: providerKind, ProvisionStatus: provisionStatus,
		})
		if err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.created", tenantID, map[string]any{
			"account_id": accountID, "kb_uuid": kb.UUID,
			"space_kind": kb.SpaceKind, "visibility": kb.Visibility, "name": kb.Name,
		})
		created = kb
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "knowledge_bases:"+strconv.FormatInt(created.ID, 10))

	// F07 集成 hook: 同步在 RAGFlow 那侧 provision dataset, 写回 ragflow_dataset_id。
	// caller 后续 UploadDocument 立刻能用 dataset_id;失败时不向客户端返回"创建成功"。
	if err := s.maybeEnsureRagflowDataset(ctx, created); err != nil {
		return nil, apperr.ErrUpstreamUnavailable.Withf("%s: ragflow dataset provision failed", ErrCodeKBProviderDegraded)
	}
	if refreshed, err := s.repo.GetKBByID(ctx, created.ID); err == nil {
		created = refreshed
	} else {
		s.logger.Warn(ctx, "kb refresh after provision failed", "kb_id", created.ID, "err", err)
	}

	dto := s.toKBDTOForAccount(created, accountID, perms)
	return &dto, nil
}

func (s *impl) PatchKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req PatchKBReq) (*KBDTO, error) {
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
		return nil, err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}
	in := domkb.UpdateKBInput{}
	if req.Name != nil {
		n := strings.TrimSpace(*req.Name)
		if n == "" || len(n) > 128 {
			return nil, apperr.ErrInvalidParams.Withf("name invalid")
		}
		in.Name = &n
	}
	if req.Description != nil {
		d := *req.Description
		in.Description = &d
	}
	if req.Visibility != nil {
		newVis := *req.Visibility
		// 提权 / 降权 visibility 必须 tenant.kb.update; 且组合必须合法 (与 space_kind 匹配).
		if newVis != kb.Visibility {
			if !hasPerm(perms, PermTenantKBUpdate) {
				return nil, apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).
					Withf("visibility change requires %s", PermTenantKBUpdate)
			}
			// space_kind 不能在 PATCH 改; 但 visibility 提权也得保持组合合法.
			// 实际上 Phase A: personal KB 不允许提到 tenant (会破坏 space_kind=personal+visibility=tenant 不合法).
			if err := validateKBVisibility(kb.SpaceKind, newVis); err != nil {
				return nil, err
			}
		}
		in.Visibility = &newVis
	}

	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.PatchKB(ctx, tx, kb.ID, in); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.updated", tenantID, map[string]any{
			"account_id": accountID, "kb_uuid": kb.UUID,
		})
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "knowledge_bases:"+strconv.FormatInt(kb.ID, 10))
	updated, err := s.repo.GetKBByID(ctx, kb.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	dto := s.toKBDTOForAccount(updated, accountID, perms)
	return &dto, nil
}

func (s *impl) DeleteKB(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string) error {
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
		return err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return err
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		releaseBytes, err := s.repo.SumKBQuotaTrackedFileSize(ctx, tx, kb.ID)
		if err != nil {
			return err
		}
		if err := s.enqueueDeleteDatasetTx(ctx, tx, kb); err != nil {
			return err
		}
		if err := s.repo.SoftDeleteKB(ctx, tx, kb.ID); err != nil {
			return err
		}
		if err := s.releaseKnowledgeQuota(ctx, tx, tenantID, releaseBytes); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.deleted", tenantID, map[string]any{
			"account_id": accountID, "kb_uuid": kb.UUID,
		})
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return e
		}
		return apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "knowledge_bases:"+strconv.FormatInt(kb.ID, 10))

	return nil
}

// =====================================================
// folders
// =====================================================

func (s *impl) ListFolders(ctx context.Context, accountID, tenantID int64, kbUUID string) ([]FolderDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	rows, err := s.repo.ListFolders(ctx, kb.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]FolderDTO, 0, len(rows))
	for i := range rows {
		out = append(out, toFolderDTO(&rows[i], kb.UUID))
	}
	return out, nil
}

func (s *impl) CreateFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req CreateFolderReq) (*FolderDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}
	name := sanitizeKBFolderName(req.Name)
	if name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	var parent *domkb.Folder
	var parentID *int64
	if strings.TrimSpace(req.ParentUUID) != "" {
		parent, err = s.repo.GetFolderByUUID(ctx, strings.TrimSpace(req.ParentUUID))
		if err != nil {
			return nil, mapKBRepoErr(err)
		}
		if parent.KBID != kb.ID {
			return nil, apperr.ErrInvalidParams.Withf("parent folder not in kb")
		}
		parentID = &parent.ID
	}
	path := buildKBFolderPath(parent, name)
	var dto *FolderDTO
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		f, err := s.repo.CreateFolder(ctx, tx, kb.ID, parentID, name, path)
		if err != nil {
			return err
		}
		out := toFolderDTO(f, kb.UUID)
		dto = &out
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return dto, nil
}

func (s *impl) PatchFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, folderUUID string, req PatchFolderReq) (*FolderDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}
	f, err := s.repo.GetFolderByUUID(ctx, folderUUID)
	if err != nil {
		return nil, mapKBRepoErr(err)
	}
	if f.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("folder not in this kb")
	}
	name := sanitizeKBFolderName(req.Name)
	if name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	var parent *domkb.Folder
	if f.ParentID != nil {
		all, err := s.repo.ListFolders(ctx, kb.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		for i := range all {
			if all[i].ID == *f.ParentID {
				parent = &all[i]
				break
			}
		}
	}
	path := buildKBFolderPath(parent, name)
	var dto *FolderDTO
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		updated, err := s.repo.PatchFolder(ctx, tx, f.ID, name, path)
		if err != nil {
			return err
		}
		out := toFolderDTO(updated, kb.UUID)
		dto = &out
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return dto, nil
}

func (s *impl) DeleteFolder(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, folderUUID string) error {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return err
	}
	f, err := s.repo.GetFolderByUUID(ctx, folderUUID)
	if err != nil {
		return mapKBRepoErr(err)
	}
	if f.KBID != kb.ID {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("folder not in this kb")
	}
	hasChildren, err := s.repo.FolderHasChildrenOrDocuments(ctx, f.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if hasChildren {
		return apperr.ErrConflict.Withf("kb.folder_not_empty")
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.SoftDeleteFolder(ctx, tx, f.ID)
	}); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

func (s *impl) resolveKBFolderID(ctx context.Context, kbID int64, folderUUID string) (*int64, error) {
	folderUUID = strings.TrimSpace(folderUUID)
	if folderUUID == "" {
		return nil, nil
	}
	f, err := s.repo.GetFolderByUUID(ctx, folderUUID)
	if err != nil {
		return nil, mapKBRepoErr(err)
	}
	if f.KBID != kbID {
		return nil, apperr.ErrInvalidParams.Withf("kb_folder_uuid not in kb")
	}
	return &f.ID, nil
}

func sanitizeKBFolderName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, "/", " ")
	return strings.TrimSpace(s)
}

func buildKBFolderPath(parent *domkb.Folder, name string) string {
	if parent == nil || strings.TrimSpace(parent.Path) == "" {
		return "/" + name
	}
	return strings.TrimRight(parent.Path, "/") + "/" + name
}

func mapKBRepoErr(err error) error {
	if errors.Is(err, apperr.ErrNotFound) {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb resource not found")
	}
	return apperr.ErrInternal.Wrap(err)
}

func (s *impl) knowledgeStorageLimitBytes(ctx context.Context, tenantID int64) (*int64, error) {
	if s.quota == nil {
		return nil, nil
	}
	if r, ok := s.quota.(storageLimitResolver); ok {
		return r.StorageLimitBytes(ctx, tenantID, "knowledge_file_storage_limit")
	}
	used, err := s.repo.GetTenantQuotaUsedBytes(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.quota.EnsureStorageWithinLimit(ctx, tenantID, "knowledge_file_storage_limit", used, 0); err != nil {
		return nil, err
	}
	return nil, nil
}

func (s *impl) reserveKnowledgeQuota(ctx context.Context, tx pgx.Tx, tenantID, needBytes int64) error {
	if needBytes <= 0 {
		return nil
	}
	limitBytes, err := s.knowledgeStorageLimitBytes(ctx, tenantID)
	if err != nil {
		return err
	}
	_, err = s.repo.ReserveTenantQuotaBytes(ctx, tx, tenantID, needBytes, limitBytes)
	return err
}

func (s *impl) releaseKnowledgeQuota(ctx context.Context, tx pgx.Tx, tenantID, releaseBytes int64) error {
	return s.repo.ReleaseTenantQuotaBytes(ctx, tx, tenantID, releaseBytes)
}

func quotaTrackedDocStatus(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "", domkb.DocStatusPending, domkb.DocStatusIngesting, domkb.DocStatusReady:
		return true
	default:
		return false
	}
}

// =====================================================
// documents
// =====================================================

func (s *impl) ListDocuments(ctx context.Context, accountID, tenantID int64, kbUUID, kbFolderUUID string) ([]DocumentDTO, error) {
	items, _, err := s.ListDocumentsPaged(ctx, accountID, tenantID, kbUUID, kbFolderUUID, 200, 0)
	return items, err
}

// ListDocumentsPaged 分页版; 同时返 total。limit/offset 在 repo 层 clamp。
func (s *impl) ListDocumentsPaged(ctx context.Context, accountID, tenantID int64, kbUUID, kbFolderUUID string, limit, offset int) ([]DocumentDTO, int, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, 0, err
	}
	folderID, err := s.resolveKBFolderID(ctx, kb.ID, kbFolderUUID)
	if err != nil {
		return nil, 0, err
	}
	rows, total, err := s.repo.ListDocumentsPagedInFolder(ctx, kb.ID, folderID, limit, offset)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	out := make([]DocumentDTO, 0, len(rows))
	for i := range rows {
		out = append(out, toDocumentDTO(&rows[i], kb.UUID))
	}
	return out, total, nil
}

func (s *impl) AdminListDocumentsPaged(ctx context.Context, tenantID int64, kbUUID string, limit, offset int) ([]DocumentDTO, int, error) {
	if tenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("tenant required")
	}
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, 0, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	if !kbBelongsToTenant(kb, tenantID) {
		return nil, 0, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("cross tenant")
	}
	rows, total, err := s.repo.ListDocumentsPaged(ctx, kb.ID, limit, offset)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	out := make([]DocumentDTO, 0, len(rows))
	for i := range rows {
		out = append(out, toDocumentDTO(&rows[i], kb.UUID))
	}
	return out, total, nil
}

func (s *impl) GetDocument(ctx context.Context, accountID, tenantID int64, kbUUID, docUUID string) (*DocumentDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if doc.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not in this kb")
	}
	dto := toDocumentDTO(doc, kb.UUID)
	return &dto, nil
}

func (s *impl) DownloadDocument(ctx context.Context, accountID, tenantID int64, kbUUID, docUUID string) (*DocumentDownload, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil {
		return nil, mapKBRepoErr(err)
	}
	if doc.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not in this kb")
	}
	providerDocID := strings.TrimSpace(doc.ProviderDocID)
	if providerDocID == "" {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("document original unavailable")
	}
	datasetID, err := s.ensureRagflowDatasetIDForUpload(ctx, kb)
	if err != nil || strings.TrimSpace(datasetID) == "" {
		return nil, mapProviderErr(fmt.Errorf("ragflow dataset not ready: %w", err))
	}
	if s.ragflowExt == nil {
		return nil, apperr.New(apperr.Conflict, ErrCodeKBProviderDegraded).Withf("ragflow provider not wired")
	}
	content, err := s.ragflowExt.DownloadFile(ctx, tenantID, datasetID, providerDocID)
	if err != nil {
		return nil, mapProviderErr(err)
	}
	mime := strings.TrimSpace(doc.MimeType)
	if mime == "" {
		mime = "application/octet-stream"
	}
	return &DocumentDownload{Title: doc.Title, MimeType: mime, Content: content}, nil
}

func (s *impl) UploadDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID string, req UploadDocReq) (*DocumentDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	// Codex review #1: 文档 upload 等同于改写 KB; 必须过写闸口 (tenant KB 要 tenant.kb.update,
	// personal KB 要 creator). 避免普通员工写 tenant KB 文档.
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}
	mime := strings.ToLower(strings.TrimSpace(req.MimeType))
	if mime == "" {
		mime = "text/plain"
	}
	if !isAllowedDocMIME(mime) {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocFormat).
			Withf("mime %q not supported; allowed: %s", mime, allowedDocMIMEDescription())
	}
	if int64(len(req.Content)) > s.cfg.DocMaxBytes {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocTooLarge).
			Withf("size %d > limit %d", len(req.Content), s.cfg.DocMaxBytes)
	}
	folderID, err := s.resolveKBFolderID(ctx, kb.ID, req.KBFolderUUID)
	if err != nil {
		return nil, err
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = "untitled.txt"
	}
	chunks := chunkText(string(req.Content))

	// Codex round-3 P1-5: Dify ingest 不能在 PG tx 内 (会延长 PG tx 持锁时间 + 把
	// 外部 HTTP 失败和 PG 事务回滚耦合). 改 3 阶段:
	//   Phase 1 (PG tx): INSERT doc status='ingesting'. Commit.
	//   Phase 2 (无 tx): provider.IngestChunks. Multiplex 路由 stub / Dify; 都不持 PG tx.
	//   Phase 3a (PG tx): 成功 → UpdateDocumentReady + IncrTotalDocuments + audit.
	//   Phase 3b (PG tx): 失败 → MarkDocumentFailed + audit.kb.ingest_failed; 不增 total.
	// stub provider 仍可用 pool 路径 (它内部自管 tx); Multiplex/Dify 全程不依赖外部 tx.
	var doc *domkb.Document
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.reserveKnowledgeQuota(ctx, tx, tenantID, int64(len(req.Content))); err != nil {
			return err
		}
		d, err := s.repo.CreateDocument(ctx, tx, domkb.CreateDocumentInput{
			KBID: kb.ID, FolderID: folderID, Title: title, SourceKind: "upload",
			MimeType: mime, FileSize: int64(len(req.Content)),
			ChunkCount: len(chunks), Status: domkb.DocStatusIngesting,
		})
		if err != nil {
			return err
		}
		doc = d
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// RAGFlow path: 真上传成功后再标 ready; 失败落 failed, 让 admin 文档页可见可重试。
	if s.ragflowExt != nil {
		return s.uploadDocumentToRagflowSync(ctx, accountID, tenantID, kb, doc, title, mime, req.Content, len(chunks))
	}

	// Phase 2: 调 provider; **不**持有 PG tx.
	ing, ingErr := s.provider.IngestChunks(ctx, provider.IngestReq{
		TenantID: tenantID, KBID: kb.ID, DocumentID: doc.ID,
		ProviderDocID: doc.UUID, Chunks: chunks,
	})
	if ingErr != nil {
		// Phase 3b: 失败 finalize.
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			_ = s.repo.MarkDocumentFailed(ctx, tx, doc.ID, truncateErrMsg(ingErr.Error()))
			_ = s.releaseKnowledgeQuota(ctx, tx, tenantID, doc.FileSize)
			s.publishAuditTx(ctx, tx, "audit.kb.ingest_failed", tenantID, map[string]any{
				"account_id":    accountID,
				"kb_uuid":       kb.UUID,
				"document_uuid": doc.UUID,
				"reason":        truncateErrMsg(ingErr.Error()),
			})
			return nil
		})
		s.notify(ctx, "kb_documents:"+kb.UUID)
		if mapped := mapProviderErr(ingErr); mapped != ingErr {
			return nil, mapped
		}
		return nil, apperr.ErrInternal.Wrap(ingErr)
	}

	// Phase 3a: 成功 finalize.
	var dto *DocumentDTO
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.UpdateDocumentReady(ctx, tx, doc.ID, ing.ChunkCount, ing.ProviderDocID); err != nil {
			return err
		}
		if err := s.repo.IncrTotalDocuments(ctx, tx, kb.ID, 1); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.ingest", tenantID, map[string]any{
			"account_id":    accountID,
			"kb_uuid":       kb.UUID,
			"document_uuid": doc.UUID,
			"chunk_count":   ing.ChunkCount,
			"file_size":     int64(len(req.Content)),
		})
		d := *doc
		d.ChunkCount = ing.ChunkCount
		d.ProviderDocID = ing.ProviderDocID
		d.Status = domkb.DocStatusReady
		out := toDocumentDTO(&d, kb.UUID)
		dto = &out
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "kb_documents:"+kb.UUID)

	return dto, nil
}

func (s *impl) PatchDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string, req PatchDocumentReq) (*DocumentDTO, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return nil, err
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil {
		return nil, mapKBRepoErr(err)
	}
	if doc.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not in this kb")
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		return nil, apperr.ErrInvalidParams.Withf("title required")
	}
	if len([]rune(title)) > 255 {
		return nil, apperr.ErrInvalidParams.Withf("title too long")
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.UpdateDocumentTitle(ctx, tx, doc.ID, title)
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	doc.Title = title
	doc.UpdatedAt = time.Now()
	out := toDocumentDTO(doc, kb.UUID)
	s.notify(ctx, "kb_documents:"+kb.UUID)
	return &out, nil
}

func truncateErrMsg(s string) string {
	const n = 500
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func (s *impl) DeleteDocument(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string) error {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return err
	}
	// Codex review #1: 删文档等同于改写 KB; 必须过写闸口.
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return err
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not found")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if doc.KBID != kb.ID {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("doc not in this kb")
	}
	releaseBytes := doc.FileSize
	if !quotaTrackedDocStatus(doc.Status) {
		releaseBytes = 0
	}
	// Codex round-3 P1-5: delete 同样分阶段, 与 ingest 对称.
	//   Phase 1 (PG tx): soft delete doc + IncrTotalDocuments(-1) + audit.
	//                    成功后再调 provider; 即使 provider 失败也不会重新出现在 KB 列表里.
	//   Phase 2 (无 tx): provider.DeleteDocument.
	//   Phase 2-fail: 写 audit.kb.provider_delete_failed (留下追溯) + 返 200.
	//                 业务上 PG 已 soft delete; provider 端可能还残留 chunk 但不会影响召回
	//                 (provider 用 tenant_id + business_kb_id + doc_id metadata filter; 该
	//                 doc_id 已 soft delete, 后续 retrieve 不再命中). 残留清理由后续 reaper / 手动.
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.SoftDeleteDocument(ctx, tx, doc.ID); err != nil {
			return err
		}
		if err := s.releaseKnowledgeQuota(ctx, tx, tenantID, releaseBytes); err != nil {
			return err
		}
		if err := s.repo.IncrTotalDocuments(ctx, tx, kb.ID, -1); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.document_deleted", tenantID, map[string]any{
			"account_id": accountID, "kb_uuid": kb.UUID, "document_uuid": doc.UUID,
		})
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return e
		}
		return apperr.ErrInternal.Wrap(err)
	}

	// Phase 2: provider 端删除 (无 tx). 失败不回滚 PG, 仅写 audit + log; 残留处理留 reaper.
	if delErr := s.provider.DeleteDocument(ctx, provider.DeleteDocumentReq{
		TenantID: tenantID, KBID: kb.ID, DocumentID: doc.ID, ProviderDocID: doc.ProviderDocID,
	}); delErr != nil {
		s.logger.Warn(ctx, "kb provider DeleteDocument failed; PG soft-deleted, provider 端可能残留",
			"kb_uuid", kb.UUID, "doc_uuid", doc.UUID, "err", delErr)
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			s.publishAuditTx(ctx, tx, "audit.kb.provider_delete_failed", tenantID, map[string]any{
				"account_id":    accountID,
				"kb_uuid":       kb.UUID,
				"document_uuid": doc.UUID,
				"reason":        truncateErrMsg(delErr.Error()),
			})
			return nil
		})
		// resolver/dify degraded 仍要透传给客户端, 让其知道服务降级.
		if mapped := mapProviderErr(delErr); mapped != delErr {
			s.notify(ctx, "kb_documents:"+kb.UUID)
			return mapped
		}
		// 其它错误吞掉, 客户端视为删除成功 (PG 已 commit).
	}
	s.notify(ctx, "kb_documents:"+kb.UUID)
	return nil
}

// =====================================================
// search (client)
// =====================================================

func (s *impl) Search(ctx context.Context, accountID, tenantID int64, kbUUID string, req SearchReq) (*SearchResp, error) {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	return s.searchResolvedKB(ctx, kb, accountID, tenantID, req, domkb.CallerUser)
}

func (s *impl) RetrieveAuthorizedForChat(ctx context.Context, in ChatRetrieveInput) (*SearchResp, error) {
	if in.TenantID <= 0 || in.AgentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id/agent_id required")
	}
	if strings.TrimSpace(in.KBUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("kb_uuid required")
	}
	q := strings.TrimSpace(in.Query)
	if q == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	kb, err := s.repo.GetKBByUUID(ctx, in.KBUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", in.KBUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !isPlatformAgentKB(kb) {
		if err := s.assertKBAccess(kb, in.AccountID, in.TenantID); err != nil {
			return nil, err
		}
	}
	if err := s.assertAgentKBBound(ctx, in.AgentID, kb.ID, in.TenantID, in.AccountID, kb.UUID); err != nil {
		return nil, err
	}
	return s.retrieveResolvedKBNoSideEffects(ctx, kb, in.TenantID, SearchReq{
		Query:     q,
		TopK:      in.TopK,
		Threshold: in.Threshold,
	})
}

func (s *impl) RetrieveAuthorizedBatchForChat(ctx context.Context, in ChatRetrieveBatchInput) ([]*SearchResp, error) {
	if in.TenantID <= 0 || in.AgentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id/agent_id required")
	}
	if len(in.KBUUIDs) == 0 {
		return nil, apperr.ErrInvalidParams.Withf("kb_uuids required")
	}
	q := strings.TrimSpace(in.Query)
	if q == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	kbs := make([]*domkb.KnowledgeBase, 0, len(in.KBUUIDs))
	seen := map[string]bool{}
	for _, kbUUID := range in.KBUUIDs {
		kbUUID = strings.TrimSpace(kbUUID)
		if kbUUID == "" || seen[kbUUID] {
			continue
		}
		seen[kbUUID] = true
		kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
		if err != nil {
			if errors.Is(err, apperr.ErrNotFound) {
				return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !isPlatformAgentKB(kb) {
			if err := s.assertKBAccess(kb, in.AccountID, in.TenantID); err != nil {
				return nil, err
			}
		}
		if err := s.assertAgentKBBound(ctx, in.AgentID, kb.ID, in.TenantID, in.AccountID, kb.UUID); err != nil {
			return nil, err
		}
		kbs = append(kbs, kb)
	}
	if len(kbs) == 0 {
		return nil, apperr.ErrInvalidParams.Withf("kb_uuids required")
	}
	for _, kb := range kbs {
		if isPlatformAgentKB(kb) {
			out := make([]*SearchResp, 0, len(kbs))
			for _, current := range kbs {
				resp, err := s.retrieveResolvedKBNoSideEffects(ctx, current, in.TenantID, SearchReq{Query: q, TopK: in.TopK, Threshold: in.Threshold})
				if err != nil {
					return nil, err
				}
				out = append(out, resp)
			}
			return out, nil
		}
	}
	topK, threshold := s.normalizeSearchOptions(SearchReq{Query: q, TopK: in.TopK, Threshold: in.Threshold})
	reqs := make([]provider.RetrieveReq, 0, len(kbs))
	for _, kb := range kbs {
		reqs = append(reqs, provider.RetrieveReq{
			TenantID: in.TenantID, KBID: kb.ID, Query: q, TopK: topK, Threshold: threshold,
		})
	}

	batcher, ok := s.provider.(provider.BatchRetriever)
	if !ok {
		out := make([]*SearchResp, 0, len(kbs))
		for _, kb := range kbs {
			resp, err := s.retrieveResolvedKBNoSideEffects(ctx, kb, in.TenantID, SearchReq{Query: q, TopK: topK, Threshold: threshold})
			if err != nil {
				return nil, err
			}
			out = append(out, resp)
		}
		return out, nil
	}

	providerStart := time.Now()
	chunksByKB, err := batcher.RetrieveBatch(ctx, reqs)
	providerLatencyMs := int(time.Since(providerStart).Milliseconds())
	if err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "knowledge batch retrieve provider failed",
				"tenant_id", in.TenantID, "kb_count", len(kbs),
				"top_k", topK, "threshold", threshold,
				"provider_latency_ms", providerLatencyMs, "err", err.Error())
		}
		if mapped := mapProviderErr(err); mapped != err {
			return nil, mapped
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	out := make([]*SearchResp, 0, len(kbs))
	totalChunks := 0
	resolveStart := time.Now()
	for _, kb := range kbs {
		chunks := chunksByKB[kb.ID]
		dto := make([]ChunkDTO, 0, len(chunks))
		for _, c := range chunks {
			dto = append(dto, ChunkDTO{
				UUID: c.UUID, DocumentID: c.DocumentID, ChunkIndex: c.ChunkIndex,
				Content: c.Content, Score: c.Score, Source: c.Source,
			})
		}
		s.resolveChunkDocUUIDs(ctx, kb.ID, dto)
		totalChunks += len(dto)
		out = append(out, &SearchResp{KBUUID: kb.UUID, Query: q, Chunks: dto})
	}
	resolveLatencyMs := int(time.Since(resolveStart).Milliseconds())
	if s.logger != nil {
		s.logger.Info(ctx, "knowledge batch retrieve completed",
			"tenant_id", in.TenantID, "kb_count", len(kbs),
			"top_k", topK, "threshold", threshold, "chunk_count", totalChunks,
			"provider_latency_ms", providerLatencyMs,
			"resolve_doc_latency_ms", resolveLatencyMs,
			"total_latency_ms", providerLatencyMs+resolveLatencyMs)
	}
	return out, nil
}

func (s *impl) AdminSearch(ctx context.Context, accountID, tenantID int64, kbUUID string, req SearchReq) (*SearchResp, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant required")
	}
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !kbBelongsToTenant(kb, tenantID) {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("cross tenant")
	}
	return s.searchResolvedKB(ctx, kb, accountID, tenantID, req, domkb.CallerAdmin)
}

func (s *impl) searchResolvedKB(ctx context.Context, kb *domkb.KnowledgeBase, accountID, tenantID int64, req SearchReq, callerKind string) (*SearchResp, error) {
	q := strings.TrimSpace(req.Query)
	if q == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	start := time.Now()
	resp, err := s.retrieveResolvedKBNoSideEffects(ctx, kb, tenantID, req)
	if err != nil {
		return nil, err
	}
	topK, threshold := s.normalizeSearchOptions(req)
	var topScore float64
	if len(resp.Chunks) > 0 {
		topScore = resp.Chunks[0].Score
	}
	var recallTenantID *int64
	if kb.SpaceKind != domkb.SpaceKindPlatform {
		recallTenantID = int64Ptr(tenantID)
	}
	_ = s.repo.InsertRecallLog(ctx, domkb.RecallLog{
		TenantID: recallTenantID, KBScopeKind: kb.SpaceKind, AccountID: accountID, KBID: kb.ID,
		CallerKind: callerKind, QueryText: recallQueryPreview(q),
		TopK: topK, Threshold: threshold, ChunkHits: len(resp.Chunks),
		ScoreTop:  topScore,
		LatencyMs: int(time.Since(start).Milliseconds()),
	})
	return resp, nil
}

func (s *impl) retrieveResolvedKBNoSideEffects(ctx context.Context, kb *domkb.KnowledgeBase, tenantID int64, req SearchReq) (*SearchResp, error) {
	q := strings.TrimSpace(req.Query)
	if q == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	topK, threshold := s.normalizeSearchOptions(req)
	providerStart := time.Now()
	chunks, err := s.provider.Retrieve(ctx, provider.RetrieveReq{
		TenantID: tenantID, KBID: kb.ID, Query: q, TopK: topK, Threshold: threshold,
	})
	providerLatencyMs := int(time.Since(providerStart).Milliseconds())
	if err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "knowledge retrieve provider failed",
				"tenant_id", tenantID, "kb_id", kb.ID, "kb_uuid", kb.UUID,
				"top_k", topK, "threshold", threshold,
				"provider_latency_ms", providerLatencyMs, "err", err.Error())
		}
		if mapped := mapProviderErr(err); mapped != err {
			return nil, mapped
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	dto := make([]ChunkDTO, 0, len(chunks))
	for _, c := range chunks {
		dto = append(dto, ChunkDTO{
			UUID: c.UUID, DocumentID: c.DocumentID, ChunkIndex: c.ChunkIndex,
			Content: c.Content, Score: c.Score, Source: c.Source,
		})
	}
	// Codex P2 #1: RAGFlow chunk 的 UUID 字段是 ragflow_document_id, 改写成真 kb_documents.uuid
	resolveStart := time.Now()
	s.resolveChunkDocUUIDs(ctx, kb.ID, dto)
	resolveLatencyMs := int(time.Since(resolveStart).Milliseconds())
	if s.logger != nil {
		s.logger.Info(ctx, "knowledge retrieve completed",
			"tenant_id", tenantID, "kb_id", kb.ID, "kb_uuid", kb.UUID,
			"top_k", topK, "threshold", threshold, "chunk_count", len(dto),
			"provider_latency_ms", providerLatencyMs,
			"resolve_doc_latency_ms", resolveLatencyMs,
			"total_latency_ms", providerLatencyMs+resolveLatencyMs)
	}
	return &SearchResp{KBUUID: kb.UUID, Query: q, Chunks: dto}, nil
}

func (s *impl) normalizeSearchOptions(req SearchReq) (int, float64) {
	topK := req.TopK
	if topK <= 0 || topK > 50 {
		topK = s.cfg.DefaultTopK
	}
	threshold := req.Threshold
	if threshold <= 0 {
		threshold = s.cfg.DefaultThreshold
	}
	return topK, threshold
}

// =====================================================
// admin
// =====================================================

func (s *impl) ListTenantKB(ctx context.Context, tenantID int64) ([]KBDTO, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant required")
	}
	// admin 默认视角只列租户级 KB; 跨用户私有 KB 必须走 UserKBInspect 审计入口。
	rows, err := s.pool.Query(ctx,
		`SELECT id, uuid::text, tenant_id, creator_id, owner_account_id,
			        space_kind, name, COALESCE(description,''), visibility, status,
			        provider_id, COALESCE(provider_kind,'stub'), COALESCE(ragflow_dataset_id,''),
			        COALESCE(provision_status,'active'), total_documents, retrieval_config, metadata,
			        created_at, updated_at
			   FROM knowledge_bases
			  WHERE tenant_id = $1 AND deleted_at IS NULL
			    AND space_kind = 'tenant' AND visibility = 'tenant'
			  ORDER BY id DESC
			  LIMIT 200`, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	out := []KBDTO{}
	nameCache := make(map[int64]string)
	for rows.Next() {
		kb, err := scanServiceKB(rows)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		dto := s.toKBDTO(kb)
		dto.CreatorName = s.accountDisplayName(ctx, tenantID, kb.CreatorID, nameCache)
		if kb.OwnerAccountID != nil {
			dto.OwnerName = s.accountDisplayName(ctx, tenantID, *kb.OwnerAccountID, nameCache)
		}
		out = append(out, dto)
	}
	return out, rows.Err()
}

func (s *impl) accountDisplayName(ctx context.Context, tenantID, accountID int64, cache map[int64]string) string {
	if accountID <= 0 {
		return ""
	}
	if cache != nil {
		if name, ok := cache[accountID]; ok {
			return name
		}
	}
	var name string
	err := s.pool.QueryRow(ctx, `
SELECT COALESCE(NULLIF(tm.nickname,''), a.display_name, '')
  FROM accounts a
  LEFT JOIN tenant_memberships tm ON tm.tenant_id = $1
       AND tm.account_id = a.id
       AND tm.deleted_at IS NULL
 WHERE a.id = $2 AND a.deleted_at IS NULL`, tenantID, accountID).Scan(&name)
	if err != nil {
		name = ""
	}
	name = cleanAccountDisplayName(name)
	if cache != nil {
		cache[accountID] = name
	}
	return name
}

func cleanAccountDisplayName(name string) string {
	n := strings.TrimSpace(name)
	if n == "" || strings.Contains(n, "的组织 管理员") || strings.HasPrefix(n, "预热优化") {
		return ""
	}
	return n
}

// AssertKBAttachable Codex review #2 — admin attach KB to agent 闸口.
//
// 失败时返回的错误码:
//   - kb.not_found   : KB 不存在 / 软删 / 跨租户 (统一不暴露存在性)
//   - kb.attach_forbidden : KB 是 personal/private (Phase A admin attach 仅放 tenant+tenant)
func (s *impl) AssertKBAttachable(ctx context.Context, tenantID int64, kbUUID string) error {
	if tenantID <= 0 {
		return apperr.ErrInvalidParams.Withf("tenant required")
	}
	if kbUUID == "" {
		return apperr.ErrInvalidParams.Withf("kb_uuid required")
	}
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if !kbBelongsToTenant(kb, tenantID) {
		// 统一不暴露存在性 (tenant 隔离).
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
	}
	if !isAdminAttachableKB(kb) {
		return apperr.New(apperr.Forbidden, ErrCodeKBAttachForbidden).
			Withf("only tenant+tenant KB attachable by admin; got space_kind=%s visibility=%s",
				kb.SpaceKind, kb.Visibility)
	}
	return nil
}

// =====================================================
// ZAP backchannel recall
// =====================================================

func (s *impl) Recall(ctx context.Context, in RecallInput) (*RecallResp, error) {
	// Step 1 — session 校验.
	tenantID, agentUUID, accountID, convUUID, err := s.resolveSession(ctx, in)
	if err != nil {
		s.auditRecallFail(ctx, 0, 0, 0, in.KBUUID, in.Query, ErrCodeZAPSessionInvalid)
		return nil, err
	}
	if in.KBUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("kb_uuid required")
	}
	if strings.TrimSpace(in.Query) == "" {
		return nil, apperr.ErrInvalidParams.Withf("query required")
	}
	// Step 2 — agent + tenant 反查.
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetByUUID(ctx, tenantID, agentUUID)
	if err != nil || ag == nil {
		s.auditRecallFail(ctx, tenantID, accountID, 0, in.KBUUID, in.Query, ErrCodeZAPSessionInvalid)
		return nil, apperr.New(apperr.Unauthorized, ErrCodeZAPSessionInvalid).Withf("agent lookup: %v", err)
	}
	if ag.TenantID != tenantID {
		s.auditRecallFail(ctx, tenantID, accountID, ag.ID, in.KBUUID, in.Query, ErrCodeZAPSessionInvalid)
		return nil, apperr.New(apperr.Unauthorized, ErrCodeZAPSessionInvalid).Withf("agent tenant mismatch")
	}
	// Step 3 — KB exists and is either caller-tenant scoped or a platform
	// agent-only asset. The runtime path still requires a canonical binding.
	kb, err := s.repo.GetKBByUUID(ctx, in.KBUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			s.auditRecallFail(ctx, tenantID, accountID, ag.ID, in.KBUUID, in.Query, ErrCodeZAPKBNotAttached)
			return nil, apperr.New(apperr.Forbidden, ErrCodeZAPKBNotAttached).Withf("kb not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	isPlatformKB := kb.SpaceKind == domkb.SpaceKindPlatform && kb.TenantID == nil &&
		kb.Visibility == domkb.VisibilityPlatform && kb.AccessMode == domkb.AccessModeAgentOnly
	if !isPlatformKB && !kbBelongsToTenant(kb, tenantID) {
		s.auditRecallFail(ctx, tenantID, accountID, ag.ID, in.KBUUID, in.Query, ErrCodeZAPKBNotAttached)
		return nil, apperr.New(apperr.Forbidden, ErrCodeZAPKBNotAttached).Withf("kb cross tenant")
	}
	if kb.Status != "active" || kb.ProvisionStatus != "active" {
		return nil, apperr.New(apperr.Conflict, "kb.not_ready").Withf("knowledge base is not ready")
	}
	// Step 4 — visibility gate for tenant/personal KBs.
	// F07 收敛: private KB 必须按当前 session account 判断, 不能按 agent creator 放行。
	if !isPlatformKB {
		if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
			s.auditRecallFail(ctx, tenantID, accountID, ag.ID, in.KBUUID, in.Query, ErrCodeZAPKBVisibilityDenied)
			return nil, apperr.New(apperr.Forbidden, ErrCodeZAPKBVisibilityDenied).
				Withf("kb not visible to current account")
		}
	}

	// Step 5 — agent_kb_bindings is the only authorization source.
	if err := s.assertAgentKBBound(ctx, ag.ID, kb.ID, tenantID, accountID, kb.UUID); err != nil {
		s.auditRecallFail(ctx, tenantID, accountID, ag.ID, in.KBUUID, in.Query, ErrCodeZAPKBNotAttached)
		return nil, err
	}
	// Step 6 — Retrieve. UntrustedTenantID 必须被忽略.
	if in.UntrustedTenantID != 0 && in.UntrustedTenantID != tenantID {
		s.logger.Warn(ctx, "knowledge.Recall: body tenant_id ignored (forced filter)",
			"body_tenant", in.UntrustedTenantID, "session_tenant", tenantID)
	}
	topK := in.TopK
	if topK <= 0 || topK > 50 {
		topK = s.cfg.DefaultTopK
	}
	threshold := in.Threshold
	if threshold <= 0 {
		threshold = s.cfg.DefaultThreshold
	}
	rctx, cancel := s.recallCtx(ctx)
	defer cancel()
	start := time.Now()
	chunks, retErr := s.provider.Retrieve(rctx, provider.RetrieveReq{
		TenantID: tenantID, KBID: kb.ID, Query: in.Query, TopK: topK, Threshold: threshold,
	})
	if retErr != nil {
		if mapped := mapProviderErr(retErr); mapped != retErr {
			return nil, mapped
		}
		return nil, apperr.ErrInternal.Wrap(retErr)
	}
	dto := make([]ChunkDTO, 0, len(chunks))
	var topScore float64
	for i, c := range chunks {
		dto = append(dto, ChunkDTO{
			UUID: c.UUID, DocumentID: c.DocumentID, ChunkIndex: c.ChunkIndex,
			Content: c.Content, Score: c.Score, Source: c.Source,
		})
		if i == 0 {
			topScore = c.Score
		}
	}
	// Codex P2 #1: RAGFlow chunk 的 UUID 字段是 ragflow_document_id, 改写成真 kb_documents.uuid
	s.resolveChunkDocUUIDs(ctx, kb.ID, dto)
	// recall log.
	_ = s.repo.InsertRecallLog(ctx, domkb.RecallLog{
		TenantID: int64Ptr(tenantID), KBScopeKind: kb.SpaceKind, AccountID: accountID, AgentID: ag.ID, KBID: kb.ID,
		CallerKind: domkb.CallerAgent, ConversationUUID: firstNonEmpty(in.ConversationUUID, convUUID),
		QueryText: recallQueryPreview(in.Query), TopK: topK, Threshold: threshold,
		ChunkHits: len(chunks), ScoreTop: topScore,
		LatencyMs: int(time.Since(start).Milliseconds()),
	})
	// audit.
	s.bestEffortAudit(ctx, "audit.kb.recall", tenantID, map[string]any{
		"resource_kind": "knowledge_base",
		"resource_uuid": kb.UUID,
		"agent_uuid":    ag.UUID,
		"caller_kind":   "agent",
		"chunk_hits":    len(chunks),
		"score_top":     topScore,
	})
	// source block (citation 透传) — Codex review #3: 过 EMP validator.
	src := buildSourceBlock(kb, chunks)
	src = s.validateSourceBlock(ctx, tenantID, kb.UUID, src)
	return &RecallResp{KBUUID: kb.UUID, Query: in.Query, Chunks: dto, SourceBlock: src}, nil
}

// validateSourceBlock 把 source block 过 EMP validator (Codex review #3).
//
//   - validator nil      → 直接返原 block (兼容 3D 装配前路径).
//   - validator pass     → 返原 block.
//   - validator fallback → 返 rewritten block (type 改为 fallback) + 写 audit.emp.block.fallback.
//   - block 为 nil       → 透传 nil.
func (s *impl) validateSourceBlock(ctx context.Context, tenantID int64, kbUUID string, src map[string]any) map[string]any {
	if src == nil {
		return nil
	}
	if s.validator == nil {
		return src
	}
	rewritten, fbs := s.validator.ValidateBlocks(ctx, []map[string]any{src}, "")
	if len(rewritten) == 0 {
		return src
	}
	if len(fbs) == 0 {
		return rewritten[0]
	}
	// fallback — 记 audit, 复用 3D audit topic 命名.
	for _, e := range fbs {
		s.bestEffortAudit(ctx, "audit.emp.block.fallback", tenantID, map[string]any{
			"resource_kind":  "knowledge_base",
			"resource_uuid":  kbUUID,
			"original_type":  e.OriginalType,
			"fallback_type":  e.FallbackType,
			"failure_reason": e.Reason,
			"emit_path":      "kb.recall",
		})
		s.logger.Warn(ctx, "knowledge.Recall: source block fallback",
			"kb_uuid", kbUUID,
			"original_type", e.OriginalType,
			"fallback_type", e.FallbackType,
			"reason", e.Reason)
	}
	return rewritten[0]
}

func (s *impl) auditRecallFail(ctx context.Context, tenantID, accountID, agentID int64, kbUUID, query, code string) {
	s.bestEffortAudit(ctx, "audit.kb.recall", tenantID, map[string]any{
		"resource_kind": "knowledge_base",
		"resource_uuid": kbUUID,
		"caller_kind":   "agent",
		"error_code":    code,
		"query":         query,
	})
	// Before a KB row is resolved there is no valid kb_id/scope pair to write
	// into kb_recall_logs; the generic audit event above remains the source for
	// these rejected attempts.
}

// resolveSession 接受 Bearer token 主路径; AllowAgentUUIDHeader 在 caller 层已展开 (smoke).
//
// 返回顺序: tenantID, agentUUID, accountID, conversationUUID, error.
func (s *impl) resolveSession(ctx context.Context, in RecallInput) (int64, string, int64, string, error) {
	if s.sessions != nil && in.SessionToken != "" {
		sess, err := s.sessions.Resolve(ctx, in.SessionToken)
		if err != nil {
			return 0, "", 0, "", apperr.New(apperr.Unauthorized, ErrCodeZAPSessionInvalid).
				Withf("session resolve: %v", err)
		}
		if sess == nil || sess.AgentUUID == "" || sess.TenantID <= 0 {
			return 0, "", 0, "", apperr.New(apperr.Unauthorized, ErrCodeZAPSessionInvalid).
				Withf("session payload incomplete")
		}
		return sess.TenantID, sess.AgentUUID, sess.AccountID, sess.ConversationUUID, nil
	}
	// header fallback (smoke / 单测).
	if in.AgentUUIDHint != "" && in.TenantIDHint > 0 {
		return in.TenantIDHint, in.AgentUUIDHint, 0, "", nil
	}
	return 0, "", 0, "", apperr.New(apperr.Unauthorized, ErrCodeZAPSessionInvalid).
		Withf("missing session token")
}

// =====================================================
// internal helpers
// =====================================================

func (s *impl) resolveAccessibleKB(ctx context.Context, kbUUID string, accountID, tenantID int64) (*domkb.KnowledgeBase, error) {
	kb, err := s.repo.GetKBByUUID(ctx, kbUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("kb %s not found", kbUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.assertKBAccess(kb, accountID, tenantID); err != nil {
		return nil, err
	}
	return kb, nil
}

type kbScanner interface {
	Scan(dest ...any) error
}

func scanServiceKB(row kbScanner) (*domkb.KnowledgeBase, error) {
	var kb domkb.KnowledgeBase
	var owner pgtype.Int8
	var rcfg, meta []byte
	if err := row.Scan(&kb.ID, &kb.UUID, &kb.TenantID, &kb.CreatorID, &owner, &kb.SpaceKind, &kb.Name,
		&kb.Description, &kb.Visibility, &kb.Status, &kb.ProviderID, &kb.ProviderKind, &kb.RagflowDatasetID,
		&kb.ProvisionStatus, &kb.TotalDocuments, &rcfg, &meta, &kb.CreatedAt, &kb.UpdatedAt); err != nil {
		return nil, err
	}
	if owner.Valid {
		v := owner.Int64
		kb.OwnerAccountID = &v
	}
	if len(rcfg) > 0 {
		_ = json.Unmarshal(rcfg, &kb.RetrievalConfig)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &kb.Metadata)
	}
	return &kb, nil
}

func (s *impl) ingestWithTx(ctx context.Context, tx pgx.Tx, in provider.IngestReq) (*provider.IngestResult, error) {
	// 如果 provider 实现 WithTx 优先用 tx-bound; 否则走 pool (与 caller tx 不同事务).
	if w, ok := s.provider.(interface {
		WithTx(tx pgx.Tx) provider.Provider
	}); ok {
		return w.WithTx(tx).IngestChunks(ctx, in)
	}
	return s.provider.IngestChunks(ctx, in)
}

func (s *impl) deleteDocumentChunksWithTx(ctx context.Context, tx pgx.Tx, in provider.DeleteDocumentReq) error {
	if w, ok := s.provider.(interface {
		WithTx(tx pgx.Tx) provider.Provider
	}); ok {
		return w.WithTx(tx).DeleteDocument(ctx, in)
	}
	return s.provider.DeleteDocument(ctx, in)
}

func (s *impl) runTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *impl) publishAuditTx(ctx context.Context, tx pgx.Tx, topic string, tenantID int64, payload map[string]any) {
	if s.audit == nil {
		return
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return
	}
	if err := s.audit.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
		Topic: topic, TenantID: tenantID, Payload: body,
	}); err != nil && !errors.Is(err, domevent.ErrDuplicate) {
		s.logger.Warn(ctx, "knowledge: events_outbox publish failed", "topic", topic, "err", err)
	}
}

// bestEffortAudit 独立 tx, 不阻断主流程 (与 drive.bestEffortAudit 同款).
func (s *impl) bestEffortAudit(ctx context.Context, topic string, tenantID int64, payload map[string]any) {
	if s.audit == nil {
		return
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return
	}
	defer func() { _ = tx.Rollback(ctx) }()
	body, _ := json.Marshal(payload)
	if err := s.audit.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
		Topic: topic, TenantID: tenantID, Payload: body,
	}); err != nil && !errors.Is(err, domevent.ErrDuplicate) {
		return
	}
	_ = tx.Commit(ctx)
}

func (s *impl) notify(ctx context.Context, payload string) {
	if _, err := s.pool.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", payload); err != nil {
		s.logger.Warn(ctx, "knowledge: pg_notify failed", "payload", payload, "err", err)
	}
}

func (s *impl) recallCtx(parent context.Context) (context.Context, context.CancelFunc) {
	if s.cfg.RecallTimeoutMs <= 0 {
		return parent, func() {}
	}
	return context.WithTimeout(parent, time.Duration(s.cfg.RecallTimeoutMs)*time.Millisecond)
}

// =====================================================
// utilities (text chunking + helpers)
// =====================================================

func chunkText(text string) []string {
	const hardLimit = 1000
	paragraphs := strings.Split(text, "\n\n")
	out := make([]string, 0, len(paragraphs))
	for _, p := range paragraphs {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if len([]rune(p)) <= hardLimit {
			out = append(out, p)
			continue
		}
		runes := []rune(p)
		for i := 0; i < len(runes); i += hardLimit {
			end := i + hardLimit
			if end > len(runes) {
				end = len(runes)
			}
			out = append(out, string(runes[i:end]))
		}
	}
	if len(out) == 0 && strings.TrimSpace(text) != "" {
		// 没有换行也没空段, 兜底直接放整段
		out = append(out, strings.TrimSpace(text))
	}
	return out
}

func isAllowedDocMIME(mime string) bool {
	switch mime {
	case "text/plain", "text/markdown", "text/md", "text/x-markdown",
		"text/csv", "application/json", "application/pdf",
		"application/msword",
		"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
		"application/vnd.ms-excel",
		"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
		"application/vnd.ms-powerpoint",
		"application/vnd.openxmlformats-officedocument.presentationml.presentation",
		"image/png", "image/jpeg", "image/jpg", "image/gif", "image/tif", "image/tiff":
		return true
	}
	if strings.HasPrefix(mime, "text/") {
		return true
	}
	return false
}

func allowedDocMIMEDescription() string {
	return "text/plain, text/markdown, text/csv, application/json, application/pdf, Word, Excel, PowerPoint, PNG/JPG/JPEG/GIF/TIF"
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// buildSourceBlock 给 agent 一个合法的 emp `source` block 形态作 citation.
//
// 使用 EMP 规范的 envelope (`type` 字段); 与 emp_block_registry (migration 000008 code='source')
// 和 emp/validate.Validator 一致. agent 是否真的把它拼到 SSE 输出由 agent 自决; Bus 只保证形态合法.
func buildSourceBlock(kb *domkb.KnowledgeBase, chunks []provider.Chunk) map[string]any {
	if len(chunks) == 0 {
		return nil
	}
	items := make([]map[string]any, 0, len(chunks))
	for _, c := range chunks {
		items = append(items, map[string]any{
			"kb_uuid":     kb.UUID,
			"kb_name":     kb.Name,
			"document_id": c.DocumentID,
			"chunk_uuid":  c.UUID,
			"snippet":     truncate(c.Content, 240),
			"score":       c.Score,
		})
	}
	// emp_block_registry json_schema 为 `{"items":[...]}` (见 000008 line 144); 与 envelope 平铺.
	return map[string]any{
		"type":  "source",
		"items": items,
	}
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
