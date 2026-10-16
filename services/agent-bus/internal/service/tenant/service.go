package tenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// ProvisionHook 给 Provision 在事务最后阶段挂一段额外逻辑 (M3 v1.1 §4.3:
// 新租户开通时同 tx 启用 platform default runtime)。nil = 跳过。
//
// 实现侧 (e.g. runtimeenv repo) 应当只通过传入的 pgx.Tx 操作 DB, 不持有独立连接。
type ProvisionHook func(ctx context.Context, tx pgx.Tx, tenantID, byAccountID int64) error

// ProvisionPostHook 在 Provision **事务提交后**执行外部系统初始化。
//
// 为何 post-commit 而非同 tx: 模板复制 + 逐个发布 (PublishVersion 含版本快照 + runtime 同步) 较重,
// 放主事务会拖长租户创建。故 best-effort: 失败只记日志, 不回滚租户创建。nil = 跳过。
type ProvisionPostHook func(ctx context.Context, tenantID, byAccountID int64)

// AdminInput 创建租户时一并指派的管理员账号信息。
//
// 业务意图: 平台管理员填入的手机号即作为该租户管理员账号。
// 该账号既能登 admin web (因为有 tenant.admin role_assignment),
// 也能登 zhiban-app (因为有 tenant_memberships 行) —— M1 §3.3.2。
//
// Batch 2B 决策 (Q1, 2026-05-15):
// **不接受调用方自带密码**——后端 crypto/rand 生成一次性临时密码，仅在响应里返回一次。
// AdminInput 不再含 Password 字段（哪怕老的反序列化路径带过来也会被忽略）。
type AdminInput struct {
	Mobile      string `json:"mobile"`                // 必填; 手机号即账号 (用于 SMS / 密码登录)
	Email       string `json:"email,omitempty"`       // 可选
	DisplayName string `json:"displayName,omitempty"` // 可选; 缺省 = "{tenant.name} 管理员"
}

// OwnerInfo 平台后台「编辑租户」展示的开通管理员信息。
//
// 解析顺序 (ResolveOwner):
//  1. tenants.owner_id 非空 → 直接读 accounts。
//  2. 否则回查最早的 tenant.admin role_assignment (覆盖历史 owner_id 为 NULL 的存量租户).
//  3. 都查不到 → 返回 nil。
type OwnerInfo struct {
	AccountID   int64  `json:"accountId"`
	AccountUUID string `json:"accountUuid"`
	DisplayName string `json:"displayName"`
	Phone       string `json:"phone,omitempty"`
	Email       string `json:"email,omitempty"`
}

// ProvisionResult /platform/tenants 创建向导的响应。
//
// 新建管理员账号不生成密码（与 F28 targeted invite 一致，见
// docs/features/F01-identity-and-auth.md §"新手机号接受邀请时不生成临时密码"）：
// accounts.password_hash 保持空，admin_accounts.must_change_password=true，
// 该管理员只能先用手机号+短信验证码登录，登录后再自行设置密码。
type ProvisionResult struct {
	Tenant              *dom.Tenant `json:"tenant"`
	AdminAccountID      int64       `json:"adminAccountId"`
	AdminAccountUUID    string      `json:"adminAccountUuid"`
	AdminMobile         string      `json:"adminMobile"`
	AdminAccountReused  bool        `json:"adminAccountReused"` // true = 手机号已存在，复用该账号
	TenantAdminRoleID   int64       `json:"tenantAdminRoleId"`
	DefaultDepartmentID int64       `json:"defaultDepartmentId"`
}

// Service 接口。
type Service interface {
	Get(ctx context.Context, id int64) (*dom.Tenant, error)
	GetByUUID(ctx context.Context, uuid string) (*dom.Tenant, error)
	// GetBySlug 按 slug 查租户 (external OPC provision 端点做幂等判断用)。
	GetBySlug(ctx context.Context, slug string) (*dom.Tenant, error)
	Create(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error)
	Update(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error)
	List(ctx context.Context, status, keyword string, limit, offset int) ([]dom.Tenant, int64, error)
	Delete(ctx context.Context, id int64) error

	// Provision 创建租户 + 同事务创建管理员账号 + 实例化租户默认角色 + 指派超级管理员。
	// M1 §5.3 "创建租户向导" 原子事务实现。
	Provision(ctx context.Context, t *dom.Tenant, admin AdminInput) (*ProvisionResult, error)

	// ResolveOwner 解析租户开通管理员信息，供平台后台「编辑租户」弹窗渲染。
	// 见 OwnerInfo 注释里的解析顺序。
	ResolveOwner(ctx context.Context, tenantID int64) (*OwnerInfo, error)

	// SetProvisionPostHook 注入事务提交后的外部系统初始化回调。nil 不变更。
	SetProvisionPostHook(h ProvisionPostHook)

	// SetLogger 注入结构化日志器；非 nil 时 Provision 打分阶段耗时日志。cmd/admin 装配时调用。
	SetLogger(l *logpkg.Logger)
}

type ProvisionResources func(context.Context, pgx.Tx, int64, int64, int64) error

type impl struct {
	existingEmailAdmin bool
	resources          ProvisionResources
	repo               dom.Repository
	pool               *pgxpool.Pool
	// Publisher 用于在 Provision 同事务里把 audit.tenant.created /
	// audit.member.invited / audit.role.assigned 写入 events_outbox（M0 T0.7 通路）。
	// nil 表示不发 audit（仅 dev / 测试场景）。
	pub domevt.Publisher
	// provisionHook 见 ProvisionHook; 同 tx 内执行, 失败回滚整个 Provision。
	provisionHook ProvisionHook
	// postProvisionHook 见 ProvisionPostHook; 事务提交后 best-effort 执行。
	postProvisionHook ProvisionPostHook
	// logger 可选; 非 nil 时 Provision 打分阶段耗时结构化日志 (QA-2026-07-02: 创建租户约 16s, 先加观测再决定优化)。
	logger *logpkg.Logger
}

// New 构造。pool 用于跨表事务 (Provision 必需)；pub 用于同事务 audit 发布。
func New(repo dom.Repository, pool *pgxpool.Pool, pub domevt.Publisher, resources ...ProvisionResources) Service {
	return &impl{repo: repo, pool: pool, pub: pub, resources: resourceInitializer(resources)}
}

// NewWithHook 多一个 hook 参数; 仅 cmd/admin 装配时用 (避免破坏既有 New 调用)。
func NewWithHook(repo dom.Repository, pool *pgxpool.Pool, pub domevt.Publisher, hook ProvisionHook, resources ...ProvisionResources) Service {
	return &impl{repo: repo, pool: pool, pub: pub, provisionHook: hook, resources: resourceInitializer(resources)}
}

// NewWithHooks 同时注入 in-tx hook + post-commit hook (doc-15 P3 装配)。
func NewWithHooks(repo dom.Repository, pool *pgxpool.Pool, pub domevt.Publisher, hook ProvisionHook, postHook ProvisionPostHook, resources ...ProvisionResources) Service {
	return &impl{repo: repo, pool: pool, pub: pub, provisionHook: hook, postProvisionHook: postHook, resources: resourceInitializer(resources)}
}

// AllowExistingEmailAdmin enables community-only provisioning from existing credentials.
// Configure once at startup; it never creates or changes an email account.
func AllowExistingEmailAdmin(service Service) {
	if s, ok := service.(*impl); ok {
		s.existingEmailAdmin = true
	}
}

func ensureTenantDefaultRole(ctx context.Context, tx pgx.Tx, tenantID int64, code, name, description string, permissionCodes []string) error {
	var roleID int64
	if err := tx.QueryRow(ctx, `
WITH inserted AS (
    INSERT INTO roles (scope_kind, tenant_id, code, name, description, is_system)
    VALUES ('tenant', $1, $2, $3, $4, true)
    ON CONFLICT DO NOTHING
    RETURNING id
)
SELECT id FROM inserted
UNION ALL
SELECT id FROM roles
 WHERE scope_kind='tenant' AND tenant_id=$1 AND code=$2 AND deleted_at IS NULL
LIMIT 1`, tenantID, code, name, description).Scan(&roleID); err != nil {
		return err
	}
	if len(permissionCodes) == 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `
INSERT INTO role_permissions (role_id, permission_id)
SELECT $1, p.id
  FROM permissions p
 WHERE p.code = ANY($2::text[])
ON CONFLICT DO NOTHING`, roleID, permissionCodes)
	return err
}

func tenantOperatorPermissionCodes() []string {
	return []string{
		"tenant.overview.read",
		"tenant.department.read",
		"tenant.department.create",
		"tenant.department.update",
		"tenant.department.delete",
		"tenant.member.read",
		"tenant.member.invite",
		"tenant.member.update",
		"tenant.member.remove",
		"tenant.position.read",
		"tenant.position.create",
		"tenant.position.update",
		"tenant.position.delete",
		"tenant.position.assign",
		"tenant.agent.read",
		"tenant.agent.create",
		"tenant.agent.update",
		"tenant.agent.publish",
		"tenant.agent.delete",
		"tenant.runtime_env.read",
		"tenant.runtime_env.create",
		"tenant.runtime_env.update",
		"tenant.runtime_env.delete",
		"tenant.runtime_env.enable",
		"tenant.runtime_env.set_default",
		"tenant.runtime_env.probe",
		"tenant.kb.read",
		"tenant.kb.update",
		"tenant.kb.recall",
		"tenant.drive.read",
		"tenant.drive.read_metadata",
		"tenant.drive.manage_quota",
		"tenant.drive.manage_recycle",
		"tenant.app.read",
		"tenant.app.create",
		"tenant.app.update",
		"tenant.app.delete",
		"tenant.app.enable",
		"tenant.app.rotate_secret",
		"tenant.app.launch_test",
		"tenant.app.universal_toggle",
		"tenant.app.agent_bind",
		"tenant.app_category.read",
		"tenant.app_category.create",
		"tenant.app_category.update",
		"tenant.app_category.delete",
		"tenant.skill.read",
		"tenant.skill.create",
		"tenant.skill.update",
		"tenant.skill.delete",
		"tenant.skill.publish",
		"tenant.skill.enable",
		"tenant.skill.upload",
		"tenant.skill.agent_bind",
		"tenant.audit.read",
		"workspace.agent.read",
		"workspace.kb.read",
		"self.account.read",
		"self.account.update",
		"self.session.read",
		"self.session.revoke",
	}
}

// ===== read =====

func (s *impl) Get(ctx context.Context, id int64) (*dom.Tenant, error) {
	return s.repo.GetByID(ctx, id)
}
func (s *impl) GetByUUID(ctx context.Context, uuid string) (*dom.Tenant, error) {
	return s.repo.GetByUUID(ctx, uuid)
}
func (s *impl) GetBySlug(ctx context.Context, slug string) (*dom.Tenant, error) {
	return s.repo.GetBySlug(ctx, slug)
}
func (s *impl) Create(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error) {
	return s.repo.Create(ctx, t)
}
func (s *impl) Update(ctx context.Context, t *dom.Tenant) (*dom.Tenant, error) {
	cur, err := s.repo.GetByID(ctx, t.ID)
	if err != nil {
		return nil, err
	}
	merged := *cur
	if t.Name != "" {
		merged.Name = t.Name
	}
	if t.DisplayName != "" {
		merged.DisplayName = t.DisplayName
	}
	if t.Description != "" {
		merged.Description = t.Description
	}
	if t.IconURL != "" {
		merged.IconURL = t.IconURL
	}
	if t.Industry != "" {
		merged.Industry = t.Industry
	}
	if t.Status != "" {
		merged.Status = t.Status
	}
	// 套餐调整必须走 billing.AdminAssignTenantPlan；租户基础信息更新不写旧 tenants.plan_id。
	if t.Brand != nil {
		merged.Brand = t.Brand
	}
	if t.Metadata != nil {
		merged.Metadata = t.Metadata
	}
	return s.repo.Update(ctx, &merged)
}
func (s *impl) List(ctx context.Context, status, keyword string, limit, offset int) ([]dom.Tenant, int64, error) {
	return s.repo.List(ctx, status, keyword, limit, offset)
}
func (s *impl) Delete(ctx context.Context, id int64) error {
	return s.repo.Delete(ctx, id)
}
func (s *impl) SetProvisionPostHook(h ProvisionPostHook) {
	s.postProvisionHook = h
}
func (s *impl) SetLogger(l *logpkg.Logger) {
	s.logger = l
}

// ===== Provision (创建租户向导) =====

func (s *impl) Provision(ctx context.Context, t *dom.Tenant, admin AdminInput) (*ProvisionResult, error) {
	if s.resources == nil {
		return nil, apperr.ErrInternal.Withf("tenant provisioning resources not configured")
	}
	if t == nil || strings.TrimSpace(t.Name) == "" || strings.TrimSpace(t.Slug) == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant.name / tenant.slug 必填")
	}
	admin.Mobile = strings.TrimSpace(admin.Mobile)
	admin.Email = strings.TrimSpace(admin.Email)
	if admin.Mobile == "" && (!s.existingEmailAdmin || admin.Email == "") {
		return nil, apperr.ErrInvalidParams.Withf("管理员手机号必填")
	}
	if admin.DisplayName == "" {
		admin.DisplayName = t.Name + " 管理员"
	}
	if t.Status == "" {
		t.Status = "active"
	}

	// QA-2026-07-02 观测: 记录 Provision 各阶段耗时。仅打点 + 成功后结构化输出一行,
	// 不改异步、不改事务边界。postProvisionHook (模板初始化) 的耗时在 cmd/admin 装配处单独打。
	provisionStart := time.Now()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// 1) INSERT tenants。当前套餐只由 subscriptions 表达；旧 tenants.plan_id 不再写入。
	var tenantID int64
	var tenantUUID string
	if err := tx.QueryRow(ctx, `
INSERT INTO tenants (name, slug, display_name, description, icon_url, industry, status, plan_id)
VALUES ($1, $2, NULLIF($3,''), NULLIF($4,''), NULLIF($5,''), NULLIF($6,''), $7, NULL)
RETURNING id, uuid`,
		t.Name, t.Slug, t.DisplayName, t.Description, t.IconURL, t.Industry, t.Status,
	).Scan(&tenantID, &tenantUUID); err != nil {
		return nil, mapTenantInsertError(err)
	}
	tInsert := time.Now()

	// 2) 默认部门 "默认部门" —— Batch 2B 决策：每个新租户都自带一个根级默认部门
	// path = "/<segment>"，depth=0；与 department.Service.Create 计算一致。
	var defaultDeptID int64
	if err := tx.QueryRow(ctx, `
INSERT INTO departments (tenant_id, parent_id, path, depth, name, sort_order, metadata)
VALUES ($1, NULL, '/默认部门', 0, '默认部门', 0, '{}'::jsonb)
RETURNING id`, tenantID).Scan(&defaultDeptID); err != nil {
		return nil, apperr.ErrInternal.Withf("默认部门创建失败: %v", err)
	}
	tDept := time.Now()

	// 3) 实例化租户默认角色 (F01 §1.6: admin/operator/member 每租户各一条 system 行)
	var roleID int64
	if err := tx.QueryRow(ctx, `
WITH inserted AS (
    INSERT INTO roles (scope_kind, tenant_id, code, name, description, is_system)
    VALUES ('tenant', $1, 'tenant.admin', '超级管理员', '本租户最高权限角色；可维护成员、角色、凭证、SSO、API Key 与所有业务配置', true)
    ON CONFLICT DO NOTHING
    RETURNING id
)
SELECT id FROM inserted
UNION ALL
SELECT id FROM roles
 WHERE scope_kind='tenant' AND tenant_id=$1 AND code='tenant.admin' AND deleted_at IS NULL
LIMIT 1`, tenantID).Scan(&roleID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO role_permissions (role_id, permission_id)
SELECT $1, p.id FROM permissions p WHERE p.scope_kind IN ('tenant','workspace','self')
ON CONFLICT DO NOTHING`, roleID); err != nil {
		return nil, err
	}
	if err := ensureTenantDefaultRole(ctx, tx, tenantID, "tenant.operator", "普通管理员", "本租户日常运营角色；不含角色、SSO、API Key、Agent SDK 等高危安全配置", tenantOperatorPermissionCodes()); err != nil {
		return nil, err
	}
	if err := ensureTenantDefaultRole(ctx, tx, tenantID, "tenant.member", "普通成员", "默认客户端成员角色；无 Admin Web 管理入口", []string{
		"self.account.read",
		"self.account.update",
		"self.session.read",
		"self.session.revoke",
	}); err != nil {
		return nil, err
	}
	tRoles := time.Now()

	// 4) 找/建管理员 account (手机号匹配)
	var adminAccountID int64
	var adminAccountUUID string
	var existingHash string
	var accountReused bool
	query := "SELECT id, uuid, COALESCE(password_hash,'') FROM accounts WHERE phone=$1 AND deleted_at IS NULL"
	identity := admin.Mobile
	emailOnly := s.existingEmailAdmin && admin.Mobile == ""
	if emailOnly {
		query = "SELECT id, uuid, COALESCE(password_hash,'') FROM accounts WHERE email=$1 AND status='active' AND deleted_at IS NULL"
		identity = admin.Email
	}
	lookupErr := tx.QueryRow(ctx, query, identity).Scan(&adminAccountID, &adminAccountUUID, &existingHash)
	if emailOnly && (lookupErr != nil || existingHash == "") {
		return nil, apperr.ErrInvalidParams.Withf("existing password-enabled administrator email required")
	}
	if lookupErr == nil {
		// 已有账号: 复用 (同一手机号已在别的租户存在)；不动密码，不强制改密
		accountReused = true
		// Batch 2B closeout #3：复用账号也要保证能登 admin 后台。
		// admin_accounts(account_id, is_platform=false) upsert；若行已存在则保留原 must_change_password。
		// 复用账号不应再次强制改密——原账号密码是用户已知的（首次邀请时已 must_change 过）。
		if _, err := tx.Exec(ctx, `
INSERT INTO admin_accounts (account_id, is_platform, must_change_password, last_password_change)
VALUES ($1, false, false, now())
ON CONFLICT (account_id) DO NOTHING`, adminAccountID); err != nil {
			return nil, err
		}
	} else {
		// 新建账号：不生成密码，与 F28 targeted invite 保持一致
		// (docs/features/F01-identity-and-auth.md §"新手机号接受邀请时不生成临时密码")——
		// accounts.password_hash 留空，该手机号必须先走短信验证码登录证明本人持有，
		// 首次登录后再自行设置密码；杜绝"平台管理员随口填一个未验证过的手机号，
		// 立刻拿到一个无需验证码即可登录的凭据"这条路径。
		if err := tx.QueryRow(ctx, `
INSERT INTO accounts (phone, email, display_name, status, locale, timezone)
VALUES ($1, NULLIF($2,''), $3, 'active', 'zh-CN', 'Asia/Shanghai')
RETURNING id, uuid`,
			admin.Mobile, admin.Email, admin.DisplayName,
		).Scan(&adminAccountID, &adminAccountUUID); err != nil {
			return nil, apperr.ErrConflict.Withf("管理员账号创建失败: %v", err)
		}
		// admin_accounts 扩展行：must_change_password=true——没有密码，首次登录（短信验证码）后引导设置密码。
		if _, err := tx.Exec(ctx, `
INSERT INTO admin_accounts (account_id, is_platform, must_change_password, last_password_change)
VALUES ($1, false, true, NULL)
ON CONFLICT (account_id) DO NOTHING`, adminAccountID); err != nil {
			return nil, err
		}
	}

	tAdmin := time.Now()

	// 5) tenant_memberships (account × tenant) —— 默认放到刚建的默认部门
	if _, err := tx.Exec(ctx, `
INSERT INTO tenant_memberships (account_id, tenant_id, department_id, title, status, joined_at)
VALUES ($1, $2, $3, $4, 'active', now())
ON CONFLICT (account_id, tenant_id) DO UPDATE SET status='active', deleted_at=NULL`,
		adminAccountID, tenantID, defaultDeptID, "管理员"); err != nil {
		return nil, err
	}

	// 5.5) 把首位管理员写回 tenants.owner_id —— 让平台后台「编辑租户」弹窗能直接显示开通管理员；
	// 历史 owner_id 为 NULL 的存量租户由 ResolveOwner() 做 best-effort 回查兜底。
	if _, err := tx.Exec(ctx, `UPDATE tenants SET owner_id=$1 WHERE id=$2 AND owner_id IS NULL`,
		adminAccountID, tenantID); err != nil {
		return nil, err
	}

	// 6) role_assignments (account × tenant.admin@new_tenant)
	if _, err := tx.Exec(ctx, `
INSERT INTO role_assignments (account_id, role_id, scope_kind, tenant_id, note)
SELECT $1, $2, 'tenant', $3, 'tenant provision'
 WHERE NOT EXISTS (
    SELECT 1 FROM role_assignments
     WHERE account_id=$1 AND role_id=$2 AND scope_kind='tenant'
       AND tenant_id=$3 AND deleted_at IS NULL
 )`, adminAccountID, roleID, tenantID); err != nil {
		return nil, err
	}
	var initialPlanID int64
	if t.InitialPlanID != nil {
		initialPlanID = *t.InitialPlanID
	}
	if err := s.resources(ctx, tx, tenantID, initialPlanID, adminAccountID); err != nil {
		return nil, err
	}
	tMembership := time.Now()

	// 7) 同事务发 3 个 audit 事件到 events_outbox (M0 T0.7 通路)
	//    payload 严禁含 initial_password 明文。
	if s.pub != nil {
		txWrap := evtrepo.WrapTx(tx)
		if err := publishAudit(ctx, s.pub, txWrap, "audit.tenant.created", tenantID,
			fmt.Sprintf("tenant.created:%s", tenantUUID),
			map[string]any{
				"resource_kind":          "tenant",
				"resource_uuid":          tenantUUID,
				"tenant_name":            t.Name,
				"tenant_slug":            t.Slug,
				"default_department_id":  defaultDeptID,
				"first_admin_account_id": adminAccountID,
			}); err != nil {
			return nil, err
		}
		if err := publishAudit(ctx, s.pub, txWrap, "audit.member.invited", tenantID,
			fmt.Sprintf("member.invited:%d:%d:provision", tenantID, adminAccountID),
			map[string]any{
				"resource_kind":     "tenant_membership",
				"resource_uuid":     adminAccountUUID,
				"target_account_id": adminAccountID,
				"phone_present":     admin.Mobile != "",
				"display_name":      admin.DisplayName,
				"by_provision":      true,
				"account_reused":    accountReused,
			}); err != nil {
			return nil, err
		}
		if err := publishAudit(ctx, s.pub, txWrap, "audit.role.assigned", tenantID,
			fmt.Sprintf("role.assigned:%d:%d:%d", tenantID, adminAccountID, roleID),
			map[string]any{
				"resource_kind":     "role_assignment",
				"target_account_id": adminAccountID,
				"role_id":           roleID,
				"role_code":         "tenant.admin",
				"role_scope":        "tenant",
			}); err != nil {
			return nil, err
		}
	}

	tAudit := time.Now()

	// M3 v1.1 §4.3: 新租户开通同 tx 启用 platform default runtime。
	// hook 失败 → 整事务回滚 (避免出现"租户已建但默认环境缺失"半态)。
	if s.provisionHook != nil {
		if err := s.provisionHook(ctx, tx, tenantID, adminAccountID); err != nil {
			return nil, err
		}
	}
	tHook := time.Now()

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	committedAt := time.Now()

	// QA-2026-07-02 观测: 分阶段耗时结构化日志 (best-effort, logger 为 nil 时跳过)。
	// 目的是定位"创建租户约 16s"慢在哪一步; 不改流程, 只记录。
	// 注意: 本条只覆盖事务内 provision 到 commit，不含 post-commit 外部系统初始化。
	if s.logger != nil {
		s.logger.Info(ctx, "tenant.provision.timing",
			"tenant_id", tenantID,
			"account_reused", accountReused,
			"db_provision_total_ms", committedAt.Sub(provisionStart).Milliseconds(),
			"tenant_insert_ms", tInsert.Sub(provisionStart).Milliseconds(),
			"default_department_ms", tDept.Sub(tInsert).Milliseconds(),
			"tenant_roles_ms", tRoles.Sub(tDept).Milliseconds(),
			"admin_account_ms", tAdmin.Sub(tRoles).Milliseconds(),
			"membership_owner_role_ms", tMembership.Sub(tAdmin).Milliseconds(),
			"audit_publish_ms", tAudit.Sub(tMembership).Milliseconds(),
			"provision_hook_ms", tHook.Sub(tAudit).Milliseconds(),
			"commit_ms", committedAt.Sub(tHook).Milliseconds(),
		)
	}

	// 重新读 tenant 完整信息
	created, err := s.repo.GetByID(ctx, tenantID)
	if err != nil {
		return nil, err
	}

	// doc-15 P3: 事务提交后按平台已发布模板初始化租户数字员工副本 (best-effort, 幂等, 失败不影响租户创建)。
	if s.postProvisionHook != nil {
		s.postProvisionHook(ctx, tenantID, adminAccountID)
	}

	return &ProvisionResult{
		Tenant:              created,
		AdminAccountID:      adminAccountID,
		AdminAccountUUID:    adminAccountUUID,
		AdminMobile:         admin.Mobile,
		AdminAccountReused:  accountReused,
		TenantAdminRoleID:   roleID,
		DefaultDepartmentID: defaultDeptID,
	}, nil
}

// publishAudit 在事务内发一条 audit 事件到 events_outbox。
//
// payload 形态对齐 auditwriter/loop.go 的 auditPayloadShape：含 actor_kind / domain / event_kind / data。
// 这里 actor_kind 固定 "platform_admin"——Provision 仅由 platform admin 触发。
func publishAudit(ctx context.Context, pub domevt.Publisher, tx domevt.Tx, topic string, tenantID int64, idempKey string, data map[string]any) error {
	parts := strings.SplitN(topic, ".", 3) // audit.<domain>.<event_kind>
	domain := ""
	eventKind := ""
	if len(parts) >= 2 {
		domain = parts[1]
	}
	if len(parts) >= 3 {
		eventKind = parts[2]
	}
	dataB, _ := json.Marshal(data)
	if len(dataB) == 0 {
		dataB = []byte("{}")
	}
	resourceKind, _ := data["resource_kind"].(string)
	resourceUUID, _ := data["resource_uuid"].(string)
	var targetAccountID int64
	if v, ok := data["target_account_id"]; ok {
		switch t := v.(type) {
		case int64:
			targetAccountID = t
		case int:
			targetAccountID = int64(t)
		}
	}
	payload, _ := json.Marshal(map[string]any{
		"actor_kind":        "platform_admin",
		"acting_as":         "",
		"domain":            domain,
		"event_kind":        eventKind,
		"severity":          "info",
		"resource_kind":     resourceKind,
		"resource_uuid":     resourceUUID,
		"target_account_id": targetAccountID,
		"data":              json.RawMessage(dataB),
	})
	return pub.Publish(ctx, tx, domevt.Event{
		Topic:          topic,
		TenantID:       tenantID,
		IdempotencyKey: idempKey,
		Payload:        payload,
	})
}

// ResolveOwner 解析租户开通管理员信息。详见 OwnerInfo 注释。
//
// 实现使用单条 SQL: 用 LATERAL 选 owner_id (优先) 或 最早 active 的 tenant.admin
// role_assignment.account_id; 然后 join accounts 取展示字段。任何步骤无结果 → 返回 (nil, nil)。
func (s *impl) ResolveOwner(ctx context.Context, tenantID int64) (*OwnerInfo, error) {
	if tenantID <= 0 {
		return nil, nil
	}
	// 用 COALESCE(子查询1, 子查询2) 选 owner_id：
	//   1) tenants.owner_id（新建租户走这里）
	//   2) 最早 tenant.admin role_assignment.account_id（兜底历史 owner_id 为 NULL 的租户）
	// 这样写避免了 UNION 分支里写 ORDER BY/LIMIT 在某些 PG 版本必须加括号的歧义。
	row := s.pool.QueryRow(ctx, `
SELECT a.id, a.uuid::text, COALESCE(a.display_name,''), COALESCE(a.phone,''), COALESCE(a.email,'')
  FROM accounts a
 WHERE a.deleted_at IS NULL
   AND a.id = COALESCE(
       (SELECT owner_id FROM tenants WHERE id = $1 AND deleted_at IS NULL),
       (SELECT ra.account_id
          FROM role_assignments ra
          JOIN roles r ON r.id = ra.role_id
         WHERE ra.tenant_id = $1
           AND ra.scope_kind = 'tenant'
           AND ra.deleted_at IS NULL
           AND r.code = 'tenant.admin'
         ORDER BY ra.created_at ASC
         LIMIT 1)
   )
 LIMIT 1`, tenantID)
	var info OwnerInfo
	if err := row.Scan(&info.AccountID, &info.AccountUUID, &info.DisplayName, &info.Phone, &info.Email); err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	return &info, nil
}

// mapTenantInsertError 把 PG unique 冲突映射成可读的中文错误，方便前端 Toast 直出。
//
// 当前 schema 上只有 tenants.slug / tenants.uuid 是 UNIQUE；name 不是。
// 兜底分支保留对未来可能新增 tenants_name_key 的支持。
func mapTenantInsertError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		switch pgErr.ConstraintName {
		case "tenants_slug_key":
			return apperr.ErrConflict.Withf("租户标识已存在，请修改租户标识")
		case "tenants_name_key":
			return apperr.ErrConflict.Withf("租户名称已存在，请修改租户名称")
		case "tenants_uuid_key":
			return apperr.ErrConflict.Withf("租户 UUID 冲突，请重试")
		}
	}
	return apperr.ErrConflict.Withf("租户创建失败: %v", err)
}

func resourceInitializer(resources []ProvisionResources) ProvisionResources {
	if len(resources) == 1 {
		return resources[0]
	}
	return nil
}
