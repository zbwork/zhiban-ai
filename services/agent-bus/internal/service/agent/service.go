package agent

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	domrt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtime"
	domprewarm "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeprewarm"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto/aesgcm"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// ADR-0037 2026-08-28 更新: 按用户要求, BYOK 不接订阅套餐/entitlement 系统,
// 默认对所有租户可用——真正的能力闸是 modelSvcCipher/SSRFGuard 是否配置
// (未配置时 SetModelServiceAPIKey / router 的 SSRF 校验各自 fail-closed),
// 不是按租户显式授权。之前基于 dombilling.EntitlementChecker 的
// ensureBYOKFeatureEnabled 灰度开关已经移除, 不要再加回来。

// notify 发 config_change NOTIFY, 失败吞掉 (写入路径优先)。
func (s *impl) notify(ctx context.Context, payload string) {
	_ = s.repo.Notify(ctx, "config_change", payload)
}

func agentPayload(id int64) string {
	return "digital_employees:" + strconv.FormatInt(id, 10)
}

func overridePayload(tenantID, agentID int64) string {
	return "agent_visibility:" + strconv.FormatInt(tenantID, 10) + ":" + strconv.FormatInt(agentID, 10)
}

type Service interface {
	Get(ctx context.Context, tenantID int64, uuid string) (*dom.DigitalEmployee, error)
	GetByID(ctx context.Context, tenantID, id int64) (*dom.DigitalEmployee, error)
	List(ctx context.Context, f dom.Filter) ([]dom.DigitalEmployee, int64, error)
	CreatorDistribution(ctx context.Context, tenantID int64) ([]dom.CreatorDistributionItem, error)
	Create(ctx context.Context, accountID, tenantID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	CreateTenantFromTemplate(ctx context.Context, accountID, tenantID int64, templateUUID, updatedAt string, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	CreatePersonalFromTemplate(ctx context.Context, accountID, tenantID int64, templateUUID, updatedAt string, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	CreatePlatform(ctx context.Context, accountID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	UpdatePlatform(ctx context.Context, accountID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	Update(ctx context.Context, accountID, tenantID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error)
	Delete(ctx context.Context, accountID, tenantID, id int64) error
	// ADR-0037 BYOK: model_service_api_key 单独走这一对方法, 不并进 Update
	// (通用 Update 不带这个字段, 避免"忘了传密钥"被误判成"要清空密钥")。
	// SetModelServiceAPIKey 加密落库 + 落审计 (created/rotated 视是否已有旧值区分), 返回 key_prefix。
	SetModelServiceAPIKey(ctx context.Context, accountID, tenantID, id int64, plaintext string) (string, error)
	// ClearModelServiceAPIKey 清空 (幂等: 本来就没有 key 时 no-op 不落审计)。
	ClearModelServiceAPIKey(ctx context.Context, accountID, tenantID, id int64) error
	// M2 §5: 发布数字员工 (status draft → published, idempotent)。
	Publish(ctx context.Context, accountID, tenantID, id int64) (*dom.DigitalEmployee, error)
	// 下架. status published/grayed -> archived; runtime 清理由 runtime_resync_outbox 异步生成 agent_unregister。
	// 清理只移除运行端 agent/workspace, 不删除 pod/workload; 入队失败不回滚下架。
	Unpublish(ctx context.Context, accountID, tenantID, id int64) (*dom.DigitalEmployee, error)
	// M2 §5: 平台预置数字员工的本租户隐藏/排序覆盖。
	SetVisibilityOverride(ctx context.Context, tenantID, agentID int64, hidden bool, sortOrder int) error

	// doc-15 平台模板 → 租户副本模型：
	//   ListPublishedPlatformTemplates 列出已发布平台模板（租户「从模板创建」picker 数据源）。
	//   CopyTemplateToTenant 保留底层快照复制能力；产品入口使用 CreateTenantFromTemplate，允许同一模板创建多个独立员工。
	ListPublishedPlatformTemplates(ctx context.Context, kind, keyword string, limit, offset int) ([]dom.DigitalEmployee, int64, error)
	//   GetPublishedPlatformTemplate 取单个已发布平台模板（「从模板创建」精确预填）；fail-closed，非已发布平台模板按不存在处理。
	GetPublishedPlatformTemplate(ctx context.Context, uuid string) (*dom.DigitalEmployee, error)
	CopyTemplateToTenant(ctx context.Context, accountID, tenantID int64, templateUUID string, opts CopyOpts) (*CopyResult, error)
	Bindings(ctx context.Context, deID int64) ([]dom.CapabilityBinding, error)
	AddBinding(ctx context.Context, b *dom.CapabilityBinding) (*dom.CapabilityBinding, error)
	RemoveBinding(ctx context.Context, bindingID int64) error

	// M3 §6: 版本快照/灰度/回滚
	PublishVersion(ctx context.Context, accountID, tenantID, deID int64, notes string) (*dom.Version, *dom.DigitalEmployee, error)
	ListVersions(ctx context.Context, tenantID, deID int64) ([]dom.Version, error)
	Gray(ctx context.Context, accountID, tenantID, deID int64, version, pct int, groups []string) (*dom.Version, error)
	Rollback(ctx context.Context, accountID, tenantID, deID int64, version int) (*dom.DigitalEmployee, error)
	PickVersion(ctx context.Context, deID, accountID int64, callerDeptPath string) (int, error)

	// M3 §6: A2A 白名单
	ListCallable(ctx context.Context, tenantID, calleeID int64) ([]dom.CalleeWhitelistEntry, error)
	AddCallable(ctx context.Context, accountID, tenantID, calleeID, callerID int64, note string) (*dom.CalleeWhitelistEntry, error)
	DeleteCallable(ctx context.Context, tenantID, entryID int64) error

	// 直接对外暴露 Repo (sandbox 服务读取草稿/版本快照)
	Repo() dom.Repository
}

// runtimeReader 仅用于 Create/Update/Publish 时校验 runtime active + probe ok。
// 解耦 service 层完整 runtime.Service。
type runtimeReader interface {
	Get(ctx context.Context, id int64) (*domrt.Registration, error)
}

type impl struct {
	repo   dom.Repository
	rtRead runtimeReader    // T2C.3 runtime active + probe ok 校验; 可为 nil (单测/降级)
	syncer OpenClawSyncer   // T2C.3 publish/unpublish OpenClaw 同步; 可为 nil (单测/非 openclaw framework)
	pool   *pgxpool.Pool    // audit 短 tx; nil -> 不发 audit
	pub    domevt.Publisher // nil -> 不发 audit
	quota  dombilling.EntitlementChecker
	// resync (doc-12 §11.5 Task C): 发布/编辑/绑定成功后入队"运行端增量同步"信号; nil -> 不入队 (单测/未接通)。
	resync RuntimeResyncEnqueuer
	// modelSvcCipher ADR-0037 BYOK: 加密 model_service_api_key; nil -> SetModelServiceAPIKey 拒绝写入 (fail-closed)。
	modelSvcCipher *aesgcm.Cipher
}

// Option 调整 agent service 构造 (向后兼容: 现有 New(...) 5 参调用不受影响)。
type Option func(*impl)

// RuntimeResyncEnqueuer 发布/编辑/绑定变化后入队"运行端增量同步"信号 (doc-12 §11.5 Task C)。
// 由 cmd (admin) 用 runtime_resync_outbox 仓储实现; Bus prewarm worker drain 后做 gated fan-out。
// **不改历史会话**; 写信号不阻塞、失败不回滚已成功的发布/编辑。
type RuntimeResyncEnqueuer interface {
	EnqueueResync(ctx context.Context, tenantID int64, deUUID, reason string) error
}

// WithRuntimeResync 注入增量同步信号入队器 (doc-12 §11.5 Task C)。nil → 不入队。
func WithRuntimeResync(e RuntimeResyncEnqueuer) Option {
	return func(s *impl) {
		if e != nil {
			s.resync = e
		}
	}
}

func WithEntitlementChecker(q dombilling.EntitlementChecker) Option {
	return func(s *impl) {
		s.quota = q
	}
}

func SetEntitlementCheckerOnService(svc Service, q dombilling.EntitlementChecker) {
	if im, ok := svc.(*impl); ok {
		im.quota = q
	}
}

// WithModelServiceCrypto 注入 ADR-0037 BYOK model_service_api_key 加密器。
// 不注入 (nil) -> SetModelServiceAPIKey 恒拒绝写入, BYOK 功能对该进程不可达。
func WithModelServiceCrypto(cipher *aesgcm.Cipher) Option {
	return func(s *impl) {
		s.modelSvcCipher = cipher
	}
}

// New 构造 agent service。
//
// 参数:
//   - repo:    必需, Agent 持久化
//   - rtRead:  nil 跳过 runtime 校验 (单测); 生产请传 svcruntime.Service
//   - syncer:  nil 跳过 OpenClaw 同步 (单测/非 openclaw framework); 生产传 LocalOpenClawSyncer
//   - pool/pub: nil -> 不发 audit
//
// 调用者负责选择 syncer (按 runtime.Framework): openclaw -> Local; 其他 -> Noop。
func New(repo dom.Repository, rtRead runtimeReader, syncer OpenClawSyncer, pool *pgxpool.Pool, pub domevt.Publisher, opts ...Option) Service {
	s := &impl{repo: repo, rtRead: rtRead, syncer: syncer, pool: pool, pub: pub}
	for _, o := range opts {
		o(s)
	}
	return s
}

// enqueueRuntimeResync 发布/编辑/绑定成功后入队增量同步信号 (doc-12 §11.5 Task C, best-effort)。
// **不阻塞、不回滚已成功操作**; 写信号失败记审计 (不静默吞)。tenant<=0 (平台模板) → 不入队 (不自动传播)。
// reason ∈ publish | update | binding_change | agent_unpublish (诊断/分流用)。
func (s *impl) enqueueRuntimeResync(ctx context.Context, tenantID int64, deUUID, reason string) {
	if s.resync == nil || tenantID <= 0 || deUUID == "" {
		return
	}
	if err := s.resync.EnqueueResync(ctx, tenantID, deUUID, reason); err != nil {
		s.auditAfter(ctx, "audit.agent.runtime_resync_enqueue_failed", tenantID, 0,
			"agent_resync_enqueue_fail:"+deUUID,
			map[string]any{"resource_kind": "agent", "resource_uuid": deUUID, "reason": reason, "error": err.Error()})
	}
}

func (s *impl) Repo() dom.Repository { return s.repo }

func (s *impl) Get(ctx context.Context, tenantID int64, uuid string) (*dom.DigitalEmployee, error) {
	e, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if e.TenantID != tenantID && !isPublishedPlatformEmployee(e) {
		return nil, apperr.ErrForbidden
	}
	return e, nil
}

func (s *impl) GetByID(ctx context.Context, tenantID, id int64) (*dom.DigitalEmployee, error) {
	e, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if e.TenantID != tenantID && !isPublishedPlatformEmployee(e) {
		return nil, apperr.ErrForbidden
	}
	return e, nil
}

func isPublishedPlatformEmployee(e *dom.DigitalEmployee) bool {
	return e != nil && e.TenantID == 0 && e.Source == "platform" && e.Visibility == "platform" && e.Status == "published" && !e.IsDeleted
}

func (s *impl) List(ctx context.Context, f dom.Filter) ([]dom.DigitalEmployee, int64, error) {
	return s.repo.List(ctx, f)
}

func (s *impl) CreatorDistribution(ctx context.Context, tenantID int64) ([]dom.CreatorDistributionItem, error) {
	return s.repo.CreatorDistribution(ctx, tenantID)
}

func (s *impl) Create(ctx context.Context, accountID, tenantID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	if e.Source == "" || e.Source == "enterprise" {
		if source, ok := e.Metadata[MetadataTemplateSourceKey]; ok {
			uuid, valid := source.(string)
			if !valid {
				return nil, apperr.ErrInvalidParams.Withf("模板来源无效")
			}
			if uuid = strings.TrimSpace(uuid); uuid != "" {
				updatedAt, _ := e.Metadata["template_source_updated_at"].(string)
				return s.CreateTenantFromTemplate(ctx, accountID, tenantID, uuid, updatedAt, e)
			}
		}
	}
	return s.create(ctx, accountID, tenantID, e, false)
}

// validToolGroups 员工工具组值域, 与 dsh-runtime tool-gate 的逻辑组一致 (bash/fs/skill/platform)。
var validToolGroups = map[string]struct{}{"bash": {}, "fs": {}, "skill": {}, "platform": {}}

// normalizeToolConfig 规整并校验 tool_allow/tool_deny: trim+小写, 未知组 fail-closed 报错。
// nil 保持 nil (repo Update 层 COALESCE 语义 = 请求未携带则不改动)。
func normalizeToolConfig(e *dom.DigitalEmployee) error {
	norm := func(field string, vals []string) ([]string, error) {
		if vals == nil {
			return nil, nil
		}
		out := make([]string, 0, len(vals))
		for _, v := range vals {
			t := strings.ToLower(strings.TrimSpace(v))
			if t == "" {
				continue
			}
			if _, ok := validToolGroups[t]; !ok {
				return nil, apperr.ErrInvalidParams.Withf("%s: 未知工具组 %q (可选: bash/fs/skill/platform)", field, v)
			}
			out = append(out, t)
		}
		return out, nil
	}
	var err error
	if e.ToolAllow, err = norm("tool_allow", e.ToolAllow); err != nil {
		return err
	}
	e.ToolDeny, err = norm("tool_deny", e.ToolDeny)
	return err
}

func (s *impl) create(ctx context.Context, accountID, tenantID int64, e *dom.DigitalEmployee, quotaExempt bool) (*dom.DigitalEmployee, error) {
	if e.Name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name 必填")
	}
	if err := normalizeToolConfig(e); err != nil {
		return nil, err
	}
	e.TenantID = tenantID
	e.CreatorID = accountID
	if err := normalizeExecutionLocus(e, nil); err != nil {
		return nil, err
	}
	if e.Source == "personal" {
		// 客户端个人数字员工默认只对创建者可见；加入群后的调用授权由
		// active room_participants 表达，不能把实体可见性改成 tenant。
		e.Visibility = "private"
	} else if e.Visibility == "" {
		e.Visibility = "private"
	}
	// F02 v0.3: agent.integration_mode 列已删 (ADR-0012); scope/hosting/llm 来源
	// 改由 runtime_environments 表表达 (Batch 2C 旧 platform_managed-only 收口随之失效,
	// 一律按 env 自身策略校验)。
	if e.Status == "" {
		e.Status = "draft"
	}
	// 默认开放通讯录和群聊能力;拉群/群内 @ 的权限仍在 room/trigger 路径校验。
	defaultAgentContactAndGroupSwitches(e)
	if e.Source == "" {
		e.Source = "enterprise"
	}
	if !quotaExempt && e.Metadata != nil {
		delete(e.Metadata, "tenant_init_seed")
	}
	// 平台预置 agent 由 platform admin 单独入口创建; 这里保护:
	// 租户 admin 路径下不允许直接落 source=platform。
	if e.Source == "platform" && tenantID > 0 {
		return nil, apperr.ErrForbidden.Withf("租户管理员不能创建 platform 来源的数字员工")
	}
	if !quotaExempt && tenantID > 0 && (e.Source == "enterprise" || e.Source == "personal") && s.quota != nil {
		n, err := s.repo.CountCustom(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		if err := s.quota.EnsureWithinLimit(ctx, tenantID, "digital_employee_limit", n, 1); err != nil {
			return nil, err
		}
	}
	// CHECK 约束: workspace 必须给 workspace_id; private 必须有 creator
	if e.Visibility == "workspace" && e.WorkspaceID == nil {
		return nil, apperr.ErrInvalidParams.Withf("visibility=workspace 时必须指定 workspace_id")
	}
	// Batch 2C T2C.3: 普通数字员工 runtime 绑定时必须是 active + approved + probe ok。
	if e.ExecutionLocus != "local" && !isSupportBuiltinAgent(e) {
		if err := s.checkRuntimeBindable(ctx, e.RuntimeEnvironmentID); err != nil {
			return nil, err
		}
	}
	if _, err := s.ensureManagedZAPAgentKey(ctx, e, 0); err != nil {
		return nil, err
	}
	out, err := s.repo.Create(ctx, e)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(out.ID))
	s.auditAfter(ctx, "audit.agent.created", out.TenantID, accountID, "agent_create:"+strconv.FormatInt(out.ID, 10),
		map[string]any{
			"resource_kind":          "agent",
			"resource_uuid":          out.UUID,
			"de_id":                  out.ID,
			"name":                   out.Name,
			"visibility":             out.Visibility,
			"runtime_environment_id": intPtrToZero(out.RuntimeEnvironmentID),
			"tenant_id":              out.TenantID,
		})
	return out, nil
}

// CreatePlatform 创建平台侧数字员工模版。
//
// 与租户侧 Create 的核心差异:
//   - 强制 source=platform / tenant_id=NULL / visibility=platform / status=draft
//   - runtime 必须是平台 scope、已启用、active、对租户开放
//   - metadata.agent_key 在同一平台 runtime 下唯一
func (s *impl) CreatePlatform(ctx context.Context, accountID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	if e.Name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name 必填")
	}
	if err := normalizeToolConfig(e); err != nil {
		return nil, err
	}
	e.TenantID = 0
	e.CreatorID = accountID
	e.Source = "platform"
	e.Visibility = "platform"
	e.Status = "draft"
	if e.Metadata == nil {
		e.Metadata = map[string]any{}
	}
	if err := normalizeTemplateExecution(e, nil); err != nil {
		return nil, err
	}
	defaultAgentContactAndGroupSwitches(e)
	if e.ExecutionLocus != "local" && !isSupportBuiltinAgent(e) {
		if err := s.checkPlatformPresetRuntime(ctx, e.RuntimeEnvironmentID); err != nil {
			return nil, err
		}
	}
	if _, err := s.ensureManagedZAPAgentKey(ctx, e, 0); err != nil {
		return nil, err
	}
	if err := s.checkPlatformAgentKeyUnique(ctx, e.RuntimeEnvironmentID, e.Metadata, 0); err != nil {
		return nil, err
	}
	out, err := s.repo.Create(ctx, e)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(out.ID))
	s.auditAfter(ctx, "audit.platform_agent.created", 0, accountID, "platform_agent_create:"+strconv.FormatInt(out.ID, 10),
		map[string]any{
			"resource_kind":          "platform_preset_agent",
			"resource_uuid":          out.UUID,
			"de_id":                  out.ID,
			"name":                   out.Name,
			"runtime_environment_id": intPtrToZero(out.RuntimeEnvironmentID),
		})
	return out, nil
}

func defaultAgentContactAndGroupSwitches(e *dom.DigitalEmployee) {
	e.ContactEnabled = true
	e.AllowInviteToGroup = true
	e.SupportsGroupChat = true
}

func (s *impl) UpdatePlatform(ctx context.Context, accountID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	existing, err := s.repo.GetByID(ctx, e.ID)
	if err != nil {
		return nil, err
	}
	if existing.Source != "platform" || existing.Visibility != "platform" || existing.TenantID != 0 {
		return nil, apperr.ErrForbidden.Withf("仅允许编辑平台预置数字员工模板")
	}
	if err := normalizeToolConfig(e); err != nil {
		return nil, err
	}
	e.TenantID = 0
	e.CreatorID = existing.CreatorID
	e.Source = "platform"
	e.Visibility = "platform"
	if e.Status == "" {
		e.Status = existing.Status
	}
	if e.Metadata == nil {
		e.Metadata = map[string]any{}
	}
	if err := normalizeTemplateExecution(e, existing); err != nil {
		return nil, err
	}
	if e.ExecutionLocus != "local" && !isSupportBuiltinAgent(e) {
		if err := s.checkPlatformPresetRuntime(ctx, e.RuntimeEnvironmentID); err != nil {
			return nil, err
		}
	}
	if _, err := s.ensureManagedZAPAgentKey(ctx, e, e.ID); err != nil {
		return nil, err
	}
	if err := s.checkPlatformAgentKeyUnique(ctx, e.RuntimeEnvironmentID, e.Metadata, e.ID); err != nil {
		return nil, err
	}
	out, err := s.repo.Update(ctx, e)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(out.ID))
	s.auditAfter(ctx, "audit.platform_agent.updated", 0, accountID, "platform_agent_update:"+strconv.FormatInt(out.ID, 10),
		map[string]any{
			"resource_kind":          "platform_preset_agent",
			"resource_uuid":          out.UUID,
			"de_id":                  out.ID,
			"name":                   out.Name,
			"runtime_environment_id": intPtrToZero(out.RuntimeEnvironmentID),
		})
	return out, nil
}

func (s *impl) checkPlatformPresetRuntime(ctx context.Context, runtimeID *int64) error {
	if runtimeID == nil || *runtimeID <= 0 {
		return apperr.ErrInvalidParams.Withf("platform.agent_runtime_required")
	}
	if s.pool == nil {
		return s.checkRuntimeBindable(ctx, runtimeID)
	}
	var scope, status, egressAuditStatus, lastProbeStatus string
	var enabled, openToTenants bool
	if err := s.pool.QueryRow(ctx, `
		SELECT scope, status, enabled, open_to_tenants, egress_audit_status, COALESCE(last_probe_status, '')
		  FROM runtime_environments
		 WHERE id=$1 AND is_deleted=false`, *runtimeID).
		Scan(&scope, &status, &enabled, &openToTenants, &egressAuditStatus, &lastProbeStatus); err != nil {
		return apperr.ErrInvalidParams.Withf("platform.agent_runtime_not_found: %v", err)
	}
	missing := []string{}
	if scope != "platform" {
		missing = append(missing, "scope=platform")
	}
	if !enabled {
		missing = append(missing, "enabled=true")
	}
	if status != "active" {
		missing = append(missing, "status=active")
	}
	if !openToTenants {
		missing = append(missing, "open_to_tenants=true")
	}
	if egressAuditStatus != "approved" {
		missing = append(missing, "egress_audit_status=approved")
	}
	if lastProbeStatus != "ok" {
		missing = append(missing, "last_probe_status=ok")
	}
	if len(missing) > 0 {
		return apperr.ErrConflict.Withf("platform.agent_runtime_not_open_to_tenants: missing %v", missing)
	}
	return nil
}

func (s *impl) checkPlatformAgentKeyUnique(ctx context.Context, runtimeID *int64, metadata map[string]any, excludeAgentID int64) error {
	if runtimeID == nil || *runtimeID <= 0 || s.pool == nil {
		return nil
	}
	raw, ok := metadata["agent_key"]
	if !ok {
		return nil
	}
	agentKey, ok := raw.(string)
	if !ok || agentKey == "" {
		return nil
	}
	var n int
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*)
		  FROM digital_employees
		 WHERE runtime_environment_id=$1
		   AND source='platform'
		   AND deleted_at IS NULL
		   AND ($3::bigint = 0 OR id <> $3::bigint)
		   AND metadata->>'agent_key'=$2`,
		*runtimeID, agentKey, excludeAgentID).Scan(&n); err != nil {
		return apperr.ErrInternal.Withf("platform.agent_key_check_failed: %v", err)
	}
	if n > 0 {
		return apperr.ErrConflict.Withf("platform.agent_key_conflict: runtime_environment_id=%d agent_key=%s", *runtimeID, agentKey)
	}
	return nil
}

// checkRuntimeBindable 校验绑定的 runtime 满足 active + hidden egress approved + last_probe_status=ok。
// runtimeID 为 nil/0 直接返回 nil (允许 draft agent 暂不绑 runtime; publish 时会再校验)。
//
// Codex 第三轮 P1-2 + 容量硬闸:
//   - 必须 active + hidden egress approved + last_probe_status=ok
//   - 容量: single-agent runtime 同时只能绑 1 个 digital_employees;
//     multi-agent runtime 按 max_agents > 0 上限 (max_agents=0 视为不限)
//   - excludeAgentID > 0 时排除自身 (Update 路径下不能把自己计进容量)
func (s *impl) checkRuntimeBindable(ctx context.Context, runtimeID *int64) error {
	return s.checkRuntimeBindableWithSelf(ctx, runtimeID, 0)
}

func (s *impl) checkRuntimeBindableWithSelf(ctx context.Context, runtimeID *int64, excludeAgentID int64) error {
	if runtimeID == nil || *runtimeID <= 0 {
		return nil
	}
	if s.rtRead == nil {
		return nil
	}
	reg, err := s.rtRead.Get(ctx, *runtimeID)
	if err != nil {
		return apperr.ErrInvalidParams.Withf("绑定的 Runtime id=%d 不存在: %v", *runtimeID, err)
	}
	if reg.Status != "active" {
		return apperr.ErrInvalidParams.Withf("绑定的 Runtime 状态=%s, 不满足 active", reg.Status)
	}
	if reg.EgressAuditStatus != "approved" {
		return apperr.ErrInvalidParams.Withf("绑定的 Runtime 隐藏审核状态=%s, 不满足 approved，请重新保存运行环境配置后重试", reg.EgressAuditStatus)
	}
	if reg.LastProbeStatus != "ok" {
		return apperr.ErrInvalidParams.Withf("绑定的 Runtime 最近一次连通性测试未通过 probe=%s，请先在「智能体托管环境」完成连通性测试", reg.LastProbeStatus)
	}
	// 容量硬闸 (P1 后端兜底); pool nil → 单测降级。
	// F02 v0.3: supports_multi_agent / max_agents 列已删 (probe 派生字段废弃); 容量限制
	// 改读 metadata.max_agents (NULL/0 = 不限). bound count 也改新 FK 列。
	if s.pool == nil {
		return nil
	}
	var maxAgents int
	if err := s.pool.QueryRow(ctx,
		`SELECT COALESCE((metadata->>'max_agents')::int, 0)
		   FROM runtime_environments WHERE id=$1 AND is_deleted=false`,
		*runtimeID).Scan(&maxAgents); err != nil {
		return apperr.ErrInvalidParams.Withf("无法读取 runtime 容量信息: %v", err)
	}
	if maxAgents <= 0 {
		// 不限容量 (默认): 直接通过
		return nil
	}
	var bound int64
	if err := s.pool.QueryRow(ctx,
		`SELECT count(*) FROM digital_employees
		   WHERE runtime_environment_id=$1 AND is_deleted=false
		     AND status IN ('draft','published','grayed')
		     AND ($2::bigint = 0 OR id <> $2::bigint)`,
		*runtimeID, excludeAgentID).Scan(&bound); err != nil {
		return apperr.ErrInternal.Withf("读取 runtime 绑定数失败: %v", err)
	}
	if bound >= int64(maxAgents) {
		return apperr.ErrConflict.Withf("agent.runtime_capacity_exceeded: runtime 已达上限 max_agents=%d", maxAgents)
	}
	return nil
}

func intPtrToZero(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// Publish status draft → published, 走三阶段 + OpenClaw 同步 (Batch 2C T2C.3)。
//
// 阶段 1 校验:
//   - 跨租户拒绝
//   - status in (draft, published) -> 继续; published 幂等
//   - runtime 绑定校验: 必须非空 + active + approved + probe ok (Q2 hard fail)
//
// 阶段 2 OpenClaw 同步 (无 PG tx):
//   - syncer.Sync: agents add + tar 流写 7 md + CLAUDE.md 镜像
//   - 失败 -> 调 syncer.Remove (compensation, best-effort) + audit.agent.publish_failed
//   - 返回 *OpenClawSyncError (transport 翻译 409 openclaw_sync_failed)
//
// 阶段 3 DB 短 tx:
//   - repo.Publish: UPDATE status='published'
//   - audit.agent.published + PG NOTIFY
//   - 失败 -> 调 syncer.Remove 补偿 (best-effort) + audit.agent.publish_compensation_failed
//
// 已 published 幂等: 仅再次跑 syncer.Sync 保证容器侧存在 (与 legacy "agents add already exists" 行为一致)。
func (s *impl) Publish(ctx context.Context, accountID, tenantID, id int64) (*dom.DigitalEmployee, error) {
	existing, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	// 平台 agent 由 platform admin 发布; 租户 admin 不能发平台 agent
	if existing.Source == "platform" {
		if tenantID > 0 {
			return nil, apperr.ErrForbidden.Withf("仅平台管理员可发布平台预置数字员工")
		}
	} else if existing.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	if existing.Status != "draft" && existing.Status != "published" {
		return nil, apperr.ErrInvalidParams.Withf("只有 draft 状态可发布, 当前=%s", existing.Status)
	}

	// 阶段 1: 普通数字员工 runtime 必须非空 + active + approved + probe ok (Q2) + 容量 (排除自身)。
	// support_builtin 是 Bus 内置执行器, 不需要 runtime_environment_id。
	if !isSupportBuiltinAgent(existing) {
		if existing.RuntimeEnvironmentID == nil || *existing.RuntimeEnvironmentID <= 0 {
			return nil, apperr.ErrInvalidParams.Withf("publish 前必须绑定 runtime")
		}
		if err := s.checkRuntimeBindableWithSelf(ctx, existing.RuntimeEnvironmentID, existing.ID); err != nil {
			return nil, err
		}
	}
	if changed, err := s.ensureManagedZAPAgentKey(ctx, existing, existing.ID); err != nil {
		return nil, err
	} else if changed {
		existing, err = s.repo.Update(ctx, existing)
		if err != nil {
			return nil, err
		}
	}

	// 阶段 2: OpenClaw 同步 (失败 DB 不动 + 补偿)
	if s.syncer != nil && !isSupportBuiltinAgent(existing) {
		if err := s.syncer.Sync(ctx, existing); err != nil {
			_ = s.syncer.Remove(ctx, existing) // compensation, best-effort
			s.auditAfter(ctx, "audit.agent.publish_failed", tenantID, accountID,
				"agent_publish_fail:"+strconv.FormatInt(id, 10),
				publishFailedAudit(existing, err))
			return nil, err
		}
	}

	// 阶段 3: DB 短 tx + audit
	out, err := s.repo.Publish(ctx, id)
	if err != nil {
		// 补偿: best-effort 把容器侧 agent 删掉
		if s.syncer != nil {
			_ = s.syncer.Remove(ctx, existing)
		}
		s.auditAfter(ctx, "audit.agent.publish_compensation_failed", tenantID, accountID,
			"agent_publish_comp_fail:"+strconv.FormatInt(id, 10),
			map[string]any{"resource_kind": "agent", "resource_uuid": existing.UUID, "de_id": id, "db_error": err.Error()})
		return nil, apperr.ErrInternal.Withf("DB publish 失败, 已尝试补偿; 请人工核对: %v", err)
	}
	s.notify(ctx, agentPayload(id))
	s.auditAfter(ctx, "audit.agent.published", tenantID, accountID,
		"agent_publish:"+strconv.FormatInt(id, 10),
		map[string]any{
			"resource_kind":   "agent",
			"resource_uuid":   existing.UUID,
			"de_id":           id,
			"current_version": out.CurrentVersion,
			"openclaw_synced": s.syncer != nil,
		})
	return out, nil
}

func publishFailedAudit(a *dom.DigitalEmployee, err error) map[string]any {
	out := map[string]any{
		"resource_kind": "agent",
		"resource_uuid": a.UUID,
		"de_id":         a.ID,
		"runtime_id":    intPtrToZero(a.RuntimeEnvironmentID),
	}
	if se, ok := IsOpenClawSyncError(err); ok {
		out["error_kind"] = se.ErrorKind
		out["stage"] = se.Stage
		if se.Cause != nil {
			out["error"] = se.Cause.Error()
		}
	} else {
		out["error"] = err.Error()
	}
	return out
}

// SetVisibilityOverride 仅对 source=platform 的 Agent 生效, 由租户 admin 调用。
func (s *impl) SetVisibilityOverride(ctx context.Context, tenantID, agentID int64, hidden bool, sortOrder int) error {
	if tenantID <= 0 {
		return apperr.ErrForbidden.Withf("missing tenant")
	}
	existing, err := s.repo.GetByID(ctx, agentID)
	if err != nil {
		return err
	}
	if existing.Source != "platform" {
		return apperr.ErrInvalidParams.Withf("visibility-override 仅适用于 source=platform 的数字员工")
	}
	if err := s.repo.UpsertVisibilityOverride(ctx, tenantID, agentID, hidden, sortOrder); err != nil {
		return err
	}
	s.notify(ctx, overridePayload(tenantID, agentID))
	return nil
}

func (s *impl) Update(ctx context.Context, accountID, tenantID int64, e *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	existing, err := s.repo.GetByID(ctx, e.ID)
	if err != nil {
		return nil, err
	}
	if existing.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	// Bus 客户端不能通过 update 把个人数字员工改成组织资产或租户公开。
	// 租户管理员的治理操作走 Admin API。
	e.Source = existing.Source
	e.CreatorID = existing.CreatorID
	if existing.Source == "personal" {
		e.Visibility = "private"
		e.ContactEnabled = true
		e.AllowInviteToGroup = true
		e.SupportsGroupChat = true
	}
	if err := normalizeExecutionLocus(e, existing); err != nil {
		return nil, err
	}
	// runtime 绑定校验 (排除自身)。support_builtin 不需要外部 runtime。
	if e.ExecutionLocus != "local" && !isSupportBuiltinAgent(e) {
		if err := s.checkRuntimeBindableWithSelf(ctx, e.RuntimeEnvironmentID, e.ID); err != nil {
			return nil, err
		}
	}
	e.TenantID = tenantID
	if err := normalizeToolConfig(e); err != nil {
		return nil, err
	}
	if _, err := s.ensureManagedZAPAgentKey(ctx, e, e.ID); err != nil {
		return nil, err
	}
	out, err := s.repo.Update(ctx, e)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(out.ID))
	s.auditAfter(ctx, "audit.agent.updated", out.TenantID, accountID, "agent_update:"+strconv.FormatInt(out.ID, 10),
		map[string]any{
			"resource_kind": "agent",
			"resource_uuid": out.UUID,
			"de_id":         out.ID,
		})
	// doc-12 §11.5 Task C: 保存后增量同步 (best-effort)。草稿/未发布 → ResolveDERuntime fail-closed 跳过 (只 published 才传播)。
	if out.ExecutionLocus != "local" {
		s.enqueueRuntimeResync(ctx, out.TenantID, out.UUID, "update")
	}
	return out, nil
}

// modelServiceAPIKeyPrefix 取前 16 字符 (审计/GET 响应可见, 不解密就能识别哪把 key),
// 照抄 kb_provision computeAPIKeyPrefix 的口径。
func modelServiceAPIKeyPrefix(plaintext string) string {
	const want = 16
	if len(plaintext) <= want {
		return plaintext
	}
	return plaintext[:want]
}

// SetModelServiceAPIKey ADR-0037: 加密落库 BYOK api_key, 立即焚毁明文 (不进日志/不回显),
// 落审计事件 (首次写入 created / 已有旧值 rotated)。modelSvcCipher 未注入 → fail-closed 拒绝。
func (s *impl) SetModelServiceAPIKey(ctx context.Context, accountID, tenantID, id int64, plaintext string) (string, error) {
	if s.modelSvcCipher == nil {
		return "", apperr.ErrInternal.Withf("BYOK model service key storage not configured")
	}
	plaintext = strings.TrimSpace(plaintext)
	if plaintext == "" {
		return "", apperr.ErrInvalidParams.Withf("model_service_api_key required")
	}
	existing, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return "", err
	}
	if existing.TenantID != tenantID {
		return "", apperr.ErrForbidden
	}
	ciphertext, err := s.modelSvcCipher.Encrypt([]byte(plaintext))
	if err != nil {
		return "", apperr.ErrInternal.Wrap(err)
	}
	prefix := modelServiceAPIKeyPrefix(plaintext)
	topic := "audit.agent.model_service_key_created"
	if existing.ModelServiceAPIKeyPrefix != "" {
		topic = "audit.agent.model_service_key_rotated"
	}
	if err := s.repo.SetModelServiceAPIKey(ctx, id, ciphertext, prefix, int(s.modelSvcCipher.Version())); err != nil {
		return "", err
	}
	s.auditAfter(ctx, topic, tenantID, accountID,
		"agent_model_service_key:"+strconv.FormatInt(id, 10)+":"+strconv.FormatInt(time.Now().UnixNano(), 10),
		map[string]any{
			"resource_kind": "agent",
			"resource_uuid": existing.UUID,
			"de_id":         id,
			"key_prefix":    prefix,
			"key_version":   s.modelSvcCipher.Version(),
		})
	return prefix, nil
}

// ClearModelServiceAPIKey ADR-0037: 清空 BYOK api_key (数字员工删除 / model_source 切回
// platform_whitelist 时调用)。幂等: 本来就没配置 key 时直接返回, 不落审计噪音。
func (s *impl) ClearModelServiceAPIKey(ctx context.Context, accountID, tenantID, id int64) error {
	existing, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return err
	}
	if existing.TenantID != tenantID {
		return apperr.ErrForbidden
	}
	if existing.ModelServiceAPIKeyPrefix == "" {
		return nil
	}
	if err := s.repo.ClearModelServiceAPIKey(ctx, id); err != nil {
		return err
	}
	s.auditAfter(ctx, "audit.agent.model_service_key_deleted", tenantID, accountID,
		"agent_model_service_key:"+strconv.FormatInt(id, 10)+":"+strconv.FormatInt(time.Now().UnixNano(), 10),
		map[string]any{
			"resource_kind": "agent",
			"resource_uuid": existing.UUID,
			"de_id":         id,
		})
	return nil
}

func (s *impl) Delete(ctx context.Context, accountID, tenantID, id int64) error {
	existing, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return err
	}
	if existing.TenantID != tenantID {
		return apperr.ErrForbidden
	}
	if existing.IsSystem {
		return apperr.ErrForbidden.Withf("平台预置不可删")
	}
	if err := s.repo.Delete(ctx, id); err != nil {
		return err
	}
	s.notify(ctx, agentPayload(id))
	s.auditAfter(ctx, "audit.agent.deleted", tenantID, accountID, "agent_delete:"+strconv.FormatInt(id, 10),
		map[string]any{
			"resource_kind": "agent",
			"resource_uuid": existing.UUID,
			"de_id":         id,
		})
	return nil
}

// Unpublish 走三阶段 + 补偿: T2C.3 unpublish 闭环。
//
// 阶段 1: 校验
//
//   - published / grayed -> 继续
//   - archived          -> 幂等 no-op 返回当前 agent
//   - draft / 其他       -> 409 "未发布无法下架"
//
// 阶段 2: 外部同步 OpenClaw (强一致, 失败 DB 保持 published)
//
//   - syncer.Remove(): agentctl.Delete + RemoveDir workspace + RemoveDir agent-dir
//   - 失败 -> 返回 OpenClawSyncError + audit.agent.unpublish_failed, DB 状态不动
//
// 阶段 3: DB 短 tx
//
//   - UPDATE status='archived' WHERE id=? AND status IN ('published','grayed')
//   - audit.agent.unpublished + PG NOTIFY
//   - 失败 -> 调 syncer.Sync 还原 (best-effort 补偿); 仍失败 -> audit.unpublish_compensation_failed
func (s *impl) Unpublish(ctx context.Context, accountID, tenantID, id int64) (*dom.DigitalEmployee, error) {
	existing, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if existing.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}

	// 阶段 1 校验
	switch existing.Status {
	case "published", "grayed":
		// continue
	case "archived":
		// 幂等
		return existing, nil
	default:
		return nil, apperr.ErrConflict.Withf("status=%s, 未发布无法下架", existing.Status)
	}

	// 阶段 2: DB 短 tx (Archive 实现已含 idempotency + status whitelist)。
	// 下架是业务可用性动作, 必须优先成功; 运行端清理由下方 outbox 异步收敛。
	out, err := s.repo.Archive(ctx, id)
	if err != nil {
		s.auditAfter(ctx, "audit.agent.unpublish_compensation_failed", tenantID, accountID,
			"agent_unpublish_comp_fail:"+strconv.FormatInt(id, 10),
			map[string]any{"resource_kind": "agent", "resource_uuid": existing.UUID, "de_id": id, "db_error": err.Error()})
		return nil, apperr.ErrInternal.Withf("DB archive 失败; 请人工核对: %v", err)
	}

	s.notify(ctx, agentPayload(id))
	shouldRequestRuntimeUnregister := out.RuntimeEnvironmentID != nil && *out.RuntimeEnvironmentID > 0
	if shouldRequestRuntimeUnregister {
		s.enqueueRuntimeResync(ctx, out.TenantID, out.UUID, domprewarm.ResyncReasonAgentUnpublish)
	}
	s.auditAfter(ctx, "audit.agent.unpublished", tenantID, accountID,
		"agent_unpublish:"+strconv.FormatInt(id, 10),
		map[string]any{
			"resource_kind":                "agent",
			"resource_uuid":                existing.UUID,
			"de_id":                        id,
			"prior_status":                 existing.Status,
			"runtime_unregister_requested": out.TenantID > 0 && out.UUID != "" && shouldRequestRuntimeUnregister,
		})
	return out, nil
}

func (s *impl) Bindings(ctx context.Context, deID int64) ([]dom.CapabilityBinding, error) {
	return s.repo.ListBindings(ctx, deID)
}
func (s *impl) AddBinding(ctx context.Context, b *dom.CapabilityBinding) (*dom.CapabilityBinding, error) {
	out, err := s.repo.AddBinding(ctx, b)
	if err != nil {
		return nil, err
	}
	// doc-12 §11.5 Task C: 绑定新增/版本变化后增量同步 (best-effort)。解析 DE 归属入队信号; published 才真正传播。
	if s.resync != nil {
		if de, derr := s.repo.GetByID(ctx, b.DigitalEmpID); derr == nil {
			s.enqueueRuntimeResync(ctx, de.TenantID, de.UUID, "binding_change")
		}
	}
	return out, nil
}

// RemoveBinding 解绑/删除能力绑定。
//
// doc-12 §11.5 Task C **缺口 (有意, 不假装)**: 当前 SkillSyncer 无 UninstallSkill, 运行端已装的旧 skill 目录可能残留;
// 故解绑**不触发增量同步**(触发也无法清理运行端)。后续补 skill.uninstall 能力 + uninstall task 后再接入。
func (s *impl) RemoveBinding(ctx context.Context, bindingID int64) error {
	return s.repo.RemoveBinding(ctx, bindingID)
}

// auditAfter 在主操作之后用短事务发一条 audit 事件到 events_outbox (best-effort).
// 失败 silently. 与 batch 2B department/membership 同款。
func (s *impl) auditAfter(ctx context.Context, topic string, tenantID, actorAccountID int64, idempKey string, data map[string]any) {
	if s.pub == nil || s.pool == nil {
		return
	}
	parts := splitAuditTopic(topic)
	dataB, _ := json.Marshal(data)
	if len(dataB) == 0 {
		dataB = []byte("{}")
	}
	resourceKind, _ := data["resource_kind"].(string)
	resourceUUID, _ := data["resource_uuid"].(string)
	actorKind := "tenant_admin"
	if actorAccountID <= 0 {
		actorKind = "system"
	} else if tenantID == 0 {
		actorKind = "platform_admin"
	}
	payload, _ := json.Marshal(map[string]any{
		"actor_kind":    actorKind,
		"acting_as":     "",
		"domain":        parts.domain,
		"event_kind":    parts.kind,
		"severity":      "info",
		"resource_kind": resourceKind,
		"resource_uuid": resourceUUID,
		"account_id":    actorAccountID,
		"data":          json.RawMessage(dataB),
	})
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	_ = s.pub.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: idempKey,
		Payload:        payload,
	})
	_ = tx.Commit(ctx)
}

type auditTopicParts struct{ domain, kind string }

func splitAuditTopic(topic string) auditTopicParts {
	out := auditTopicParts{}
	first := strIdxByte(topic, '.')
	if first < 0 {
		return out
	}
	rest := topic[first+1:]
	second := strIdxByte(rest, '.')
	if second < 0 {
		out.domain = rest
		return out
	}
	out.domain = rest[:second]
	out.kind = rest[second+1:]
	return out
}

func strIdxByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
