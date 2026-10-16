// Package composer 是 M6 Phase A 引入的 Composer Skills & Apps 服务层.
//
// 范围 (Phase A):
//   - GetConversationComposerConfig: 客户端拉 tool_rail + more_drawer + apps + voice flag.
//   - Invoke (在 invoke.go): ZAP backchannel /zap/v1/internal/skills/invoke, 含 6 步校验链.
//   - DeriveDefaultBindings (在 inheritance.go): 新建 agent / admin reset-defaults 时跑.
//
// 不在本批 (Phase B / 后置批次):
//   - Schema 编辑器, chip 联动表达式 (visible_when), 完整 13 项 seed.
//   - composer_config.changed SSE 推送给客户端 (留 M4 完整 SSE).
//   - 真模型接入 (image_generation 仅返 stub block).
//
// 详见 docs/tasks/m6-composer-skills-and-apps.md
package composer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// 错误码 (与 docs/tasks/m6-composer-phase-a.md §4.1 + §4.2 一致).
const (
	ErrCodeSkillNotAttached       = "chat.skill_not_attached"
	ErrCodeComposerParamsTooLarge = "chat.composer_params_too_large"

	ErrCodeZAPSessionInvalid         = "zap.session_invalid"
	ErrCodeZAPBorrowForbiddenSelf    = "zap.borrow_forbidden_self_hosted"
	ErrCodeZAPSkillNotAttached       = "zap.skill_not_attached"
	ErrCodeZAPSkillExecMismatch      = "zap.skill_exec_mismatch"
	ErrCodeZAPSkillNotAvailHybrid    = "zap.skill_not_available_to_hybrid"
	ErrCodeZAPSkillParamsInvalid     = "zap.skill_params_invalid"
	ErrCodeZAPBillingInsufficient    = "zap.billing_insufficient_credits"
	ErrCodeZAPBillingInvalid         = "zap.billing_invalid"
	ErrCodeComposerChipKindUnsupport = "composer.chip_kind_unsupported"
)

// ComposerParamsMaxBytes M6 §10 / Phase A §4.1: composer_params 序列化字节上限.
//
// 由 cmd/bus / cmd/admin 启动时从 env AGBUS_COMPOSER_PARAMS_MAX_BYTES 读, 透传到 chat /
// composer 服务. 0 → 用默认 16KB.
const ComposerParamsMaxBytes = 16 * 1024

// AllowedChipKinds Phase A 允许的 chip kind 白名单 (R2 风险记录).
// 平台 admin PATCH input_chips_schema 时校验 schema 内出现的所有 kind 是否子集.
var AllowedChipKinds = map[string]struct{}{
	"enum-dropdown": {},
	"model-picker":  {},
	"text-inline":   {},
}

// ConfigChangeChannel 与 contacts.PolicyListener / empblock listener 同源.
// payload 形如 "<table>:<id>" — `composer_skills:<id>` / `apps:<id>` /
// `agent_capability_bindings:<de_id>` / `tenant_composer_defaults:<tenant_id>`.
const ConfigChangeChannel = "config_change"

// DefaultCacheTTL bus 本地 in-process 缓存 TTL (M6 Phase A §4.5).
// 启动期 / pg_notify 失效兜底; cmd/bus 可由 env AGBUS_COMPOSER_CONFIG_TTL 覆盖.
const DefaultCacheTTL = 5 * time.Minute

// ToolRailItem composer-config 的 tool_rail / more_drawer 单元 (M6 §5.1).
//
// Kind:
//   - "system":         客户端内置 (attach_file / mode_picker / more_drawer 预留)
//   - "composer_skill": 一个 Skill
//   - "app":            一个 App H5 入口
//   - "more_drawer":    预留, 指示客户端折叠为抽屉
type ToolRailItem struct {
	Kind        string `json:"kind"`
	UUID        string `json:"uuid,omitempty"`
	Key         string `json:"key,omitempty"`
	Icon        string `json:"icon,omitempty"`
	Label       string `json:"label,omitempty"`
	Pinned      bool   `json:"pinned,omitempty"`
	DisplayMode string `json:"display_mode,omitempty"`
}

// ComposerConfig GET /conversations/:uuid/composer-config 响应 (M6 §5.1).
type ComposerConfig struct {
	Version      string         `json:"version"`
	ToolRail     []ToolRailItem `json:"tool_rail"`
	MoreDrawer   []ToolRailItem `json:"more_drawer"`
	VoiceEnabled bool           `json:"voice_enabled"`
}

// SkillDetail GET /composer-skills/:uuid (M6 §3.2 + §3.2.1).
//
// InputChipsSchema 直接以 jsonb 原样返回, client 渲染解析.
type SkillDetail struct {
	UUID                       string         `json:"uuid"`
	Code                       string         `json:"code"`
	Label                      string         `json:"label"`
	Icon                       string         `json:"icon,omitempty"`
	Description                string         `json:"description,omitempty"`
	Placeholder                string         `json:"placeholder,omitempty"`
	SubmitLabel                string         `json:"submit_label,omitempty"`
	ExecKind                   string         `json:"exec_kind"`
	InputChipsSchema           any            `json:"input_chips_schema"`
	AvailableToPlatformManaged bool           `json:"available_to_platform_managed"`
	AvailableToHybrid          bool           `json:"available_to_hybrid"`
	DefaultAttached            bool           `json:"default_attached"`
	DefaultPinned              bool           `json:"default_pinned"`
	Compatibility              map[string]any `json:"compatibility,omitempty"`
	Status                     string         `json:"status"`
	IsSystem                   bool           `json:"is_system"`
}

// AppDetail GET /apps/:uuid (M6 §3.3).
type AppDetail struct {
	UUID              string `json:"uuid"`
	Code              string `json:"code"`
	Name              string `json:"name"`
	Description       string `json:"description,omitempty"`
	IconURL           string `json:"icon_url,omitempty"`
	Color             string `json:"color,omitempty"`
	URL               string `json:"url,omitempty"`
	DisplayMode       string `json:"display_mode"`
	DefaultAttached   bool   `json:"default_attached"`
	DefaultPinned     bool   `json:"default_pinned"`
	AvailableToHybrid bool   `json:"available_to_hybrid"`
	Status            string `json:"status"`
	IsSystem          bool   `json:"is_system"`
}

// Skill 一个完整的 composer_skill 行 (内部 service 用).
type Skill struct {
	ID                         int64
	UUID                       string
	TenantID                   *int64
	Code                       string
	Label                      string
	Icon                       string
	Placeholder                string
	SubmitLabel                string
	Status                     string
	IsSystem                   bool
	ExecKind                   string
	InputChipsSchema           []byte
	AvailableToPlatformManaged bool
	AvailableToHybrid          bool
	DefaultAttached            bool
	DefaultPinned              bool
	Compatibility              map[string]any
}

// App 一个完整的 apps 行 (内部 service 用).
type App struct {
	ID                int64
	UUID              string
	TenantID          *int64
	Code              string
	Name              string
	Description       string
	IconURL           string
	Color             string
	URL               string
	Status            string
	IsSystem          bool
	DisplayMode       string
	DefaultAttached   bool
	DefaultPinned     bool
	AvailableToHybrid bool
}

// Binding agent_capability_bindings 在 composer 视角下的最小集 — capability_kind ∈
// (composer_skill, app), 含 pinned / sort_order.
type Binding struct {
	ID             int64
	DigitalEmpID   int64
	CapabilityKind string
	CapabilityUUID string
	SortOrder      int
	Pinned         bool
}

// Repository 是 composer service 的 PG 读写接口.
//
// 关键点:
//   - GetSkillByUUID / GetAppByUUID 读完整行 (含 input_chips_schema / display_mode 等
//     M6 ALTER 之后字段), 供运行时配置、装配校验与 ZAP 调用链复用.
//   - ListAgentBindings 读 agent_capability_bindings, agent_version_id IS NULL (草稿态)
//     条件由 caller 决定; Phase A 仅用草稿态行.
//   - ListSkills / ListApps 用于 inheritance 算法.
//   - GetTenantComposerDefault / GetTenantAppDefault 读 tenant 强开关.
//   - InsertBinding / DeleteBindingsByDE / Notify 用于 reset-defaults 算法事务.
type Repository interface {
	GetSkillByUUID(ctx context.Context, uuid string) (*Skill, error)
	GetAppByUUID(ctx context.Context, uuid string) (*App, error)
	ListSkills(ctx context.Context, onlySystem bool) ([]Skill, error)
	ListApps(ctx context.Context, onlySystem bool) ([]App, error)
	ListAgentBindings(ctx context.Context, deID int64) ([]Binding, error)
	GetTenantComposerDefault(ctx context.Context, tenantID, skillID int64) (string, bool, error)
	GetTenantAppDefault(ctx context.Context, tenantID, appID int64) (string, bool, error)

	// ResetBindingsForAgent 事务性 — 删 agent 当前 capability_kind ∈
	// (composer_skill, app), agent_version_id IS NULL 的全部 binding, 然后插入 inputs.
	// notifyPayloads 由调用方计算好 (例如 "digital_employees:<id>"), 在同一 tx 内 pg_notify.
	ResetBindingsForAgent(ctx context.Context, deID int64, inputs []Binding, notifyPayloads []string) error

	// Notify 直接 pg_notify(config_change, payload). 服务层在缓存失效场景调用.
	Notify(ctx context.Context, payload string) error
}

// AgentLookup 是 composer service 对 agent 维度的窄接口 (避免 import svcagent 引起循环).
//
// 实现由 wiring 层注入: GetByID 给 chat / room / inheritance 用; GetByUUID 给 invoke /
// admin CRUD 用. 仅读. integration_mode / source / runtime_registration_id 都在
// digital_employees 行上.
type AgentLookup interface {
	GetByID(ctx context.Context, id int64) (*AgentInfo, error)
	GetByUUID(ctx context.Context, uuid string) (*AgentInfo, error)
}

// AgentInfo composer 视角下的 agent 关键字段. 全部从 digital_employees 行读.
type AgentInfo struct {
	ID                   int64
	UUID                 string
	TenantID             int64
	Source               string
	Name                 string
	IntegrationMode      string // self_hosted / hybrid / platform_managed
	ModelPrimary         string
	Tags                 []string
	RuntimeEnvironmentID *int64
}

// ConversationLookup 给 GetConversationComposerConfig 反查 conversation → de_id.
type ConversationLookup interface {
	GetByUUID(ctx context.Context, convUUID string) (*ConvInfo, error)
}

// ConvInfo 仅暴露 service 需要的字段.
type ConvInfo struct {
	UUID              string
	TenantID          int64
	AccountID         int64
	DigitalEmployeeID *int64
	RoomID            *int64
}

// Service 是 composer 服务的公开接口.
type Service interface {
	// GetConversationComposerConfig 客户端拉 composer 配置.
	// caller scope: tenant member; tenant 必须匹配 conversation.tenant_id.
	GetConversationComposerConfig(ctx context.Context, accountID, tenantID int64, convUUID string) (*ComposerConfig, error)

	// GetSkillDetail GET /composer-skills/:uuid 客户端单 Skill 详情.
	GetSkillDetail(ctx context.Context, tenantID int64, skillUUID string) (*SkillDetail, error)

	// GetAppDetail GET /apps/:uuid 客户端单 App 详情.
	GetAppDetail(ctx context.Context, tenantID int64, appUUID string) (*AppDetail, error)

	// AssertSkillAttached chat.Send / room.SendMessage 提交时校验.
	// 命中错误 → ErrSkillNotAttached.
	AssertSkillAttached(ctx context.Context, deID int64, skillUUID string) (*Skill, error)

	// Invoke ZAP backchannel /zap/v1/internal/skills/invoke 入口 (实现在 invoke.go).
	Invoke(ctx context.Context, in InvokeInput) (*InvokeResult, error)

	// DeriveDefaultBindings 给定 agent + tenant, 返回应写入 agent_capability_bindings
	// 的默认装配 (M6 §3.5). 仅算, 不写库.
	// 注意: 只返 default_attached=true (经过 tenant force_on/off 覆盖) 的 skill/app —
	// **新建 agent / reset-defaults 专用**. admin "可装池" 接口 (ListAvailableCapabilities)
	// 不应复用此方法 (会漏掉用户可手动装的非默认项).
	DeriveDefaultBindings(ctx context.Context, agent *AgentInfo) ([]Binding, error)

	// ListAvailableCapabilities admin "可装池" 接口 — 返回所有 hosting + 兼容矩阵 通过
	// 的 system composer_skill / app, 不论 default_attached 是否为真. 即使该 skill 不会被
	// reset-defaults 默认装入, 管理员也可以手动 POST 装它. 用于 admin Step 6 装配 UI 的
	// 候选展示.
	//
	// 与 DeriveDefaultBindings 区别:
	//   DeriveDefaultBindings = ListAvailable ∩ (default_attached + force_on - force_off)
	//
	// self_hosted agent 永远返回空 (boundaries §2.3).
	ListAvailableCapabilities(ctx context.Context, agent *AgentInfo) ([]Binding, error)

	// ResetDefaults admin reset-defaults endpoint: 清空当前装配 (capability_kind ∈
	// composer_skill/app) 后跑 DeriveDefaultBindings 再写回, 同 tx 触发 NOTIFY.
	// 幂等: 重复调用对相同 agent + 相同 platform skill 集合产生相同 binding 集合.
	ResetDefaults(ctx context.Context, actorAccountID int64, agent *AgentInfo) ([]Binding, error)

	// InvalidateAgentCache 由 listener 或写主体调用, 失效某 agent 的 composer-config 缓存.
	InvalidateAgentCache(deID int64)

	// InvalidateAll 缓存全清 (例如 composer_skills 表级写, 影响所有 agent 的配置).
	InvalidateAll()
}

// InvokeInput ZAP backchannel 入参.
type InvokeInput struct {
	// SessionToken 来自 Authorization: Bearer 头. Phase A 简化: 我们用一个
	// 受信的 ZAP session store (cmd/bus 注入) 解出 tenantID / agentID / conversationID.
	SessionToken string
	// 显式 fallback 给单测路径用 (无 ZAP session store 时直接传 agentUUID).
	AgentUUID string

	SkillUUID         string
	Params            map[string]any
	SourceMessageUUID string
	OperationCode     string
	IdempotencyKey    string
}

// InvokeResult ZAP backchannel 返回, Agent 拼到 SSE 输出.
type InvokeResult struct {
	ResultBlocks []map[string]any `json:"result_blocks"`
	Usage        map[string]any   `json:"usage"`
}

// ZAPSessionResolver SessionToken → tenantID/agentID/conversationID 解码.
//
// Phase A 没有完整 ZAP session 表; 实现可选:
//  1. 由 cmd/bus 注入一个简单 in-memory store (smoke 测试用 admin 提前注册);
//  2. wiring 时直接接 ZAP session repo (M5 引入).
//
// 单测路径下 nil → Invoke 退化为 InvokeInput.AgentUUID 直读, 仍走 6 步校验链.
type ZAPSessionResolver interface {
	Resolve(ctx context.Context, sessionToken string) (*ZAPSession, error)
}

// ZAPSession SessionResolver 输出.
type ZAPSession struct {
	TenantID         int64
	AccountID        int64 // optional, audit 用
	AgentUUID        string
	ConversationUUID string
}

// BillingService 是 composer invoke 对 F11 技能扣费服务的窄依赖。
type BillingService interface {
	ChargeSkillCallBySkillUUID(ctx context.Context, in dombilling.ChargeSkillCallInput) (*dombilling.SkillChargeResult, error)
}

// AuditPublisher composer service 写 events_outbox 用的窄接口 (与 chat/agent 同款).
//
// nil → 静默跳过 (单测路径).
type AuditPublisher interface {
	PublishWithTx(ctx context.Context, topic string, tenantID int64, idempKey string, payload map[string]any) error
}

// Deps 构造 service 的依赖.
type Deps struct {
	Logger      *log.Logger
	Repo        Repository
	Agents      AgentLookup
	Convs       ConversationLookup
	Audit       AuditPublisher
	ZAPSessions ZAPSessionResolver // nil ok
	Billing     BillingService     // nil ok; 未配置时沿用旧 composer 行为
	CacheTTL    time.Duration      // 0 → DefaultCacheTTL
}

// impl 是 Service 的 PG 实现.
type impl struct {
	logger   *log.Logger
	repo     Repository
	agents   AgentLookup
	convs    ConversationLookup
	audit    AuditPublisher
	sessions ZAPSessionResolver
	billing  BillingService
	cache    *configCache
}

// New 构造 composer service.
func New(deps Deps) Service {
	logger := deps.Logger
	if logger == nil {
		logger = log.Default()
	}
	if deps.Repo == nil || deps.Agents == nil || deps.Convs == nil {
		// caller bug; service 没法工作. 用 panic 让 cmd 直接 fail-fast.
		panic("composer.New: Repo / Agents / Convs are required")
	}
	ttl := deps.CacheTTL
	if ttl <= 0 {
		ttl = DefaultCacheTTL
	}
	return &impl{
		logger:   logger,
		repo:     deps.Repo,
		agents:   deps.Agents,
		convs:    deps.Convs,
		audit:    deps.Audit,
		sessions: deps.ZAPSessions,
		billing:  deps.Billing,
		cache:    newConfigCache(ttl),
	}
}

// GetConversationComposerConfig 客户端 GET 入口.
//
// 流程:
//  1. convs.GetByUUID → 检查 tenant / account / digital_employee_id
//  2. 命中 cache → 直接返
//  3. agents.GetByID → integration_mode
//  4. repo.ListAgentBindings (草稿态, agent_version_id IS NULL)
//  5. 按 capability_kind 分桶, GetSkill/App by UUID, 按 pinned/sort_order 排序
//  6. 写入 cache (key = deID + integration_mode)
func (s *impl) GetConversationComposerConfig(ctx context.Context, accountID, tenantID int64, convUUID string) (*ComposerConfig, error) {
	conv, err := s.convs.GetByUUID(ctx, convUUID)
	if err != nil {
		return nil, err
	}
	if conv.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("conversation tenant mismatch")
	}
	if conv.AccountID != accountID {
		return nil, apperr.ErrForbidden.Withf("conversation account mismatch")
	}
	if conv.DigitalEmployeeID == nil || *conv.DigitalEmployeeID <= 0 {
		// 群聊 conversation; M6 Phase A 不支持群聊 composer 协同 (M5 完整版).
		return nil, apperr.ErrInvalidParams.Withf("conversation has no agent (group-chat not supported in Phase A)")
	}
	deID := *conv.DigitalEmployeeID

	if cfg, ok := s.cache.get(deID); ok {
		return cfg, nil
	}

	cfg, err := s.buildConfigForAgent(ctx, deID)
	if err != nil {
		return nil, err
	}
	s.cache.put(deID, cfg)
	return cfg, nil
}

func (s *impl) buildConfigForAgent(ctx context.Context, deID int64) (*ComposerConfig, error) {
	ag, err := s.agents.GetByID(ctx, deID)
	if err != nil {
		return nil, err
	}
	bindings, err := s.repo.ListAgentBindings(ctx, deID)
	if err != nil {
		return nil, err
	}
	// 按 pinned desc, sort_order asc 排序 (pinned 优先进 tool_rail).
	sortBindings(bindings)

	cfg := &ComposerConfig{
		ToolRail:     []ToolRailItem{},
		MoreDrawer:   []ToolRailItem{},
		VoiceEnabled: true,
	}
	// 系统预留: attach_file / mode_picker (前端按需渲染; 不在 capability_bindings 里).
	cfg.ToolRail = append(cfg.ToolRail,
		ToolRailItem{Kind: "system", Key: "attach_file", Icon: "plus"},
		ToolRailItem{Kind: "system", Key: "mode_picker", Icon: "eap", Label: "快速"},
	)

	for _, b := range bindings {
		switch b.CapabilityKind {
		case "composer_skill":
			sk, err := s.repo.GetSkillByUUID(ctx, b.CapabilityUUID)
			if err != nil {
				if errors.Is(err, apperr.ErrNotFound) || pgIsNoRows(err) {
					s.logger.Warn(ctx, "composer-config: skill binding points to missing skill",
						"de_id", deID, "skill_uuid", b.CapabilityUUID)
					continue
				}
				return nil, err
			}
			if !s.skillVisibleToAgent(sk, ag) {
				continue
			}
			item := ToolRailItem{
				Kind:   "composer_skill",
				UUID:   sk.UUID,
				Icon:   sk.Icon,
				Label:  sk.Label,
				Pinned: b.Pinned,
			}
			if b.Pinned {
				cfg.ToolRail = append(cfg.ToolRail, item)
			} else {
				cfg.MoreDrawer = append(cfg.MoreDrawer, item)
			}
		case "app":
			a, err := s.repo.GetAppByUUID(ctx, b.CapabilityUUID)
			if err != nil {
				if errors.Is(err, apperr.ErrNotFound) || pgIsNoRows(err) {
					s.logger.Warn(ctx, "composer-config: app binding points to missing app",
						"de_id", deID, "app_uuid", b.CapabilityUUID)
					continue
				}
				return nil, err
			}
			if !s.appVisibleToAgent(a, ag) {
				continue
			}
			item := ToolRailItem{
				Kind:        "app",
				UUID:        a.UUID,
				Label:       a.Name,
				DisplayMode: a.DisplayMode,
				Pinned:      b.Pinned,
			}
			if b.Pinned {
				cfg.ToolRail = append(cfg.ToolRail, item)
			} else {
				cfg.MoreDrawer = append(cfg.MoreDrawer, item)
			}
		default:
			// background_skill / mcp / knowledge_base / external_skill — 不属于
			// composer-config 范畴 (走 agent 内部 / KB recall / MCP invoke), 不渲染.
			continue
		}
	}
	if len(cfg.MoreDrawer) > 0 {
		cfg.ToolRail = append(cfg.ToolRail, ToolRailItem{Kind: "more_drawer"})
	}
	// version 字段供后置 client cutover 用作 ETag 提示. Phase A 没接真 ETag, 取 de_id +
	// in-process cache 时间戳即可 (本地缓存失效后值会变).
	cfg.Version = fmt.Sprintf("de%d-%d", deID, time.Now().Unix())
	return cfg, nil
}

func (s *impl) skillVisibleToAgent(sk *Skill, ag *AgentInfo) bool {
	switch integrationModeOrDefault(ag.IntegrationMode) {
	case "self_hosted":
		// boundaries §2.3: self_hosted 不可借用任何 platform skill.
		// Phase A 不会出现 (inheritance 直接拒装配), 守口兜底.
		return false
	case "platform_managed":
		return sk.AvailableToPlatformManaged
	case "hybrid":
		return sk.AvailableToHybrid
	default:
		// 未知 integration_mode — 默认拒, fail-closed.
		return false
	}
}

func (s *impl) appVisibleToAgent(a *App, ag *AgentInfo) bool {
	switch integrationModeOrDefault(ag.IntegrationMode) {
	case "self_hosted":
		return false
	case "platform_managed":
		return true // Phase A: apps 默认全部对 platform_managed 暴露.
	case "hybrid":
		return a.AvailableToHybrid
	default:
		return false
	}
}

func (s *impl) GetSkillDetail(ctx context.Context, tenantID int64, skillUUID string) (*SkillDetail, error) {
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID)
	if err != nil {
		return nil, err
	}
	// 平台 skill (tenant_id IS NULL) 对所有租户可读; 租户自建 skill 仅本租户可读.
	if sk.TenantID != nil && *sk.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("skill tenant mismatch")
	}
	return toSkillDetail(sk), nil
}

func (s *impl) GetAppDetail(ctx context.Context, tenantID int64, appUUID string) (*AppDetail, error) {
	a, err := s.repo.GetAppByUUID(ctx, appUUID)
	if err != nil {
		return nil, err
	}
	if a.TenantID != nil && *a.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("app tenant mismatch")
	}
	return toAppDetail(a), nil
}

func (s *impl) AssertSkillAttached(ctx context.Context, deID int64, skillUUID string) (*Skill, error) {
	bindings, err := s.repo.ListAgentBindings(ctx, deID)
	if err != nil {
		return nil, err
	}
	for _, b := range bindings {
		if b.CapabilityKind == "composer_skill" && b.CapabilityUUID == skillUUID {
			return s.repo.GetSkillByUUID(ctx, skillUUID)
		}
	}
	return nil, apperr.ErrForbidden.Withf(ErrCodeSkillNotAttached)
}

func (s *impl) InvalidateAgentCache(deID int64) {
	s.cache.invalidate(deID)
}

func (s *impl) InvalidateAll() {
	s.cache.clear()
}

func toSkillDetail(sk *Skill) *SkillDetail {
	out := &SkillDetail{
		UUID:                       sk.UUID,
		Code:                       sk.Code,
		Label:                      sk.Label,
		Icon:                       sk.Icon,
		Placeholder:                sk.Placeholder,
		SubmitLabel:                sk.SubmitLabel,
		ExecKind:                   sk.ExecKind,
		AvailableToPlatformManaged: sk.AvailableToPlatformManaged,
		AvailableToHybrid:          sk.AvailableToHybrid,
		DefaultAttached:            sk.DefaultAttached,
		DefaultPinned:              sk.DefaultPinned,
		Compatibility:              sk.Compatibility,
		Status:                     sk.Status,
		IsSystem:                   sk.IsSystem,
	}
	if len(sk.InputChipsSchema) > 0 {
		out.InputChipsSchema = rawMessage(sk.InputChipsSchema)
	} else {
		out.InputChipsSchema = []any{}
	}
	return out
}

func toAppDetail(a *App) *AppDetail {
	return &AppDetail{
		UUID:              a.UUID,
		Code:              a.Code,
		Name:              a.Name,
		Description:       a.Description,
		IconURL:           a.IconURL,
		Color:             a.Color,
		URL:               a.URL,
		DisplayMode:       a.DisplayMode,
		DefaultAttached:   a.DefaultAttached,
		DefaultPinned:     a.DefaultPinned,
		AvailableToHybrid: a.AvailableToHybrid,
		Status:            a.Status,
		IsSystem:          a.IsSystem,
	}
}

// rawMessage 把 []byte 包成 json.RawMessage 让 encode 时不二次编码.
type rawMessage []byte

func (r rawMessage) MarshalJSON() ([]byte, error) {
	if len(r) == 0 {
		return []byte("null"), nil
	}
	return []byte(r), nil
}

// sortBindings 按 pinned desc, sort_order asc, id asc 排序.
//
// Phase A 暴力 O(n^2) bubble — n 在 Phase A seed 数量 < 20, 不是热路径.
func sortBindings(items []Binding) {
	for i := 0; i < len(items); i++ {
		for j := i + 1; j < len(items); j++ {
			if bindingLess(items[j], items[i]) {
				items[i], items[j] = items[j], items[i]
			}
		}
	}
}

func bindingLess(a, b Binding) bool {
	if a.Pinned != b.Pinned {
		return a.Pinned // pinned 在前
	}
	if a.SortOrder != b.SortOrder {
		return a.SortOrder < b.SortOrder
	}
	return a.ID < b.ID
}

// pgIsNoRows pgx ErrNoRows 兜底判定 (repo 多数已转为 apperr.ErrNotFound, 这里二次保险).
func pgIsNoRows(err error) bool {
	return errors.Is(err, pgx.ErrNoRows)
}

// ----- in-process cache -----

type configCache struct {
	mu  sync.RWMutex
	ttl time.Duration
	m   map[int64]configCacheEntry
}

type configCacheEntry struct {
	cfg     *ComposerConfig
	expires time.Time
}

func newConfigCache(ttl time.Duration) *configCache {
	return &configCache{ttl: ttl, m: make(map[int64]configCacheEntry)}
}

func (c *configCache) get(deID int64) (*ComposerConfig, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	e, ok := c.m[deID]
	if !ok {
		return nil, false
	}
	if time.Now().After(e.expires) {
		return nil, false
	}
	return e.cfg, true
}

func (c *configCache) put(deID int64, cfg *ComposerConfig) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[deID] = configCacheEntry{cfg: cfg, expires: time.Now().Add(c.ttl)}
}

func (c *configCache) invalidate(deID int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.m, deID)
}

func (c *configCache) clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m = make(map[int64]configCacheEntry)
}

// ----- PG audit publisher 适配 (chat/agent 同款短 tx) -----

// NewPGAuditPublisher 拿一个 PG pool 包装出 AuditPublisher (与 chat / agent 同款短 tx).
// cmd/bus / cmd/admin 装配时用; 单测可以传 nil.
func NewPGAuditPublisher(pool *pgxpool.Pool, pub domevt.Publisher) AuditPublisher {
	if pool == nil || pub == nil {
		return nil
	}
	return &pgAuditPub{pool: pool, pub: pub}
}

type pgAuditPub struct {
	pool *pgxpool.Pool
	pub  domevt.Publisher
}

func (p *pgAuditPub) PublishWithTx(ctx context.Context, topic string, tenantID int64, idempKey string, data map[string]any) error {
	if p.pool == nil || p.pub == nil {
		return nil
	}
	domain, kind := splitDomain(topic)
	actorKind := "tenant_admin"
	if tenantID == 0 {
		actorKind = "platform_admin"
	}
	payload := map[string]any{
		"actor_kind":    actorKind,
		"domain":        domain,
		"event_kind":    kind,
		"severity":      "info",
		"resource_kind": data["resource_kind"],
		"resource_uuid": data["resource_uuid"],
		"data":          data,
	}
	body, _ := json.Marshal(payload)
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := p.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: idempKey,
		Payload:        body,
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// splitDomain "audit.skill.invoked" → ("skill", "invoked").
// 与 svcagent.splitAuditTopic 同款; 本地再定义避免跨包依赖.
func splitDomain(topic string) (string, string) {
	rest := strings.TrimPrefix(topic, "audit.")
	if i := strings.IndexByte(rest, '.'); i > 0 {
		return rest[:i], rest[i+1:]
	}
	return rest, ""
}
