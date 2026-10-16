// Package auth M1 身份与登录服务。
//
// 实现 docs/modules/m1-identity-and-login.md §4 端点集:
//   - /auth/login/password         (账密)
//   - /auth/login/sms              (短信验证码)
//   - /auth/login/oidc/callback    (OIDC; M1.x 真接 IdP, 当前 fake)
//   - /auth/token/refresh          (refresh token 续期)
//   - /auth/logout                 (撤销当前 session)
//   - /auth/me                     (当前用户 + 全部 scope)
//   - /auth/scope/switch           (切换有效 scope, 返回新 access token)
//   - /auth/menu                   (按当前 scope 拉菜单)
//   - /auth/captcha + /auth/sms/send 配套 (短信码登录前置)
//
// Token 模型: Ed25519 签的短期 access token (15min) + 不透明 refresh token (30d, hash 存 login_sessions)。
// 撤销: revoke session → Redis 黑名单立即生效 (M1 §8)。
// 失败锁定: 5 次失败锁 15 分钟 (M1 §9)。
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	identityadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/identity"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/sms"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/authaudit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/session"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/smscode"
	identitysvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/identity"
)

// ===== DTO =====

// AccountSummary 给前端的精简账号信息。
//
// A5 (B-5-1) 新增字段:
//   - PhoneMasked / EmailMasked: 客户端显示用脱敏串 (185****1234 / a***@b.com); 调用方按需读.
//   - DepartmentName: 当前主部门名称 (无部门或软删返空); 由 Me handler 用 caller 主 tenant
//     的 membership 解析得到, 不强制 ScopeSwitch 后才能拿.
//
// 老字段 Email / Phone 保留 (内网工具 / admin 可能直接读); 客户端 cutover 后逐步切到 *Masked.
type AccountSummary struct {
	ID                 int64  `json:"id"`
	UUID               string `json:"uuid"`
	DisplayName        string `json:"displayName"`
	Email              string `json:"email,omitempty"`
	EmailMasked        string `json:"email_masked,omitempty"`
	Phone              string `json:"phone,omitempty"`
	PhoneMasked        string `json:"phone_masked,omitempty"`
	Username           string `json:"username,omitempty"`
	AvatarURL          string `json:"avatarUrl,omitempty"`
	AvatarURLSnake     string `json:"avatar_url,omitempty"`
	DepartmentName     string `json:"department_name,omitempty"`
	MustChangePassword bool   `json:"mustChangePassword,omitempty"`
	PasswordSet        bool   `json:"passwordSet"`
}

// ScopeOption /auth/me 里的可切换 scope 选项。
type ScopeOption struct {
	Kind              string   `json:"kind"` // platform / tenant / workspace
	TenantID          int64    `json:"tenantId,omitempty"`
	TenantSlug        string   `json:"tenantSlug,omitempty"`
	TenantName        string   `json:"tenantName,omitempty"`
	MemberDisplayName string   `json:"memberDisplayName,omitempty"`
	WorkspaceID       int64    `json:"workspaceId,omitempty"`
	WorkspaceName     string   `json:"workspaceName,omitempty"`
	Roles             []string `json:"roles"`
	Perms             []string `json:"perms,omitempty"`
	IsAdmin           bool     `json:"isAdmin,omitempty"`
}

// LoginResp 统一登录响应。
type LoginResp struct {
	AccessToken           string         `json:"accessToken"`
	AccessTokenExpiresAt  time.Time      `json:"accessTokenExpiresAt"`
	RefreshToken          string         `json:"refreshToken"`
	RefreshTokenExpiresAt time.Time      `json:"refreshTokenExpiresAt"`
	Account               AccountSummary `json:"account"`
	ActScope              ScopeOption    `json:"actScope"`
}

// PasswordLoginReq 账密登录。
type PasswordLoginReq struct {
	Identifier string     `json:"identifier"` // email/phone/username
	Password   string     `json:"password"`
	Device     DeviceInfo `json:"device,omitempty"`
}

// SmsLoginReq 短信码登录 (兼容客户端字段名 account/code)。
type SmsLoginReq struct {
	Mobile string     `json:"mobile"`
	Code   string     `json:"code"`
	Device DeviceInfo `json:"device,omitempty"`
}

// OIDCCallbackReq /auth/login/oidc/callback。M4 真接入: state 必填用于反查 IdP + 校 nonce。
type OIDCCallbackReq struct {
	Code   string     `json:"code"`
	State  string     `json:"state"`
	Device DeviceInfo `json:"device,omitempty"`
}

// SmsRegisterReq /auth/register/sms 客户端自助注册 (zhiban-app cutover).
//
// 语义: 新手机号经短信验证后, 自动建账号 + 默认租户 + tenant.admin role + membership;
// 复用 service/tenant.Service.Provision 同一条事务路径 (通过注入式 SelfRegisterer 间接调用)。
//
// 安全:
//   - 短信码 scene 必须是 register (与 login 隔离, 防越权登录)。
//   - 手机号必须在 accounts 表不存在 (auth pre-check), 防陌生人把已存在账号"拉进"新租户。
//   - 与 Provision 走同一 tx, 任意子步骤失败整体回滚。
type SmsRegisterReq struct {
	Mobile string     `json:"mobile"`
	Code   string     `json:"code"`
	Device DeviceInfo `json:"device,omitempty"`
}

// SelfRegisterer 自助注册的窄抽象 (cmd/bus 提供 service/tenant.Provision 适配器)。
//
// 实现方负责:
//  1. 构造默认 tenant (name = `用户<后4位>的组织`、slug = `u<后8位>`、status=active);
//  2. 把当前手机号作为 admin.Mobile 调 tenant.Service.Provision;
//  3. 返回新建账号的 (ID, UUID, tenantID), auth.Service 拿来发 session token.
//
// nil 时 RegisterSelf 返 ErrInternal "self-register not wired".
type SelfRegisterer interface {
	ProvisionForMobile(ctx context.Context, mobile string) (accountID int64, accountUUID string, tenantID int64, err error)
}

// StartOIDCReq /auth/login/oidc/start。
type StartOIDCReq struct {
	ProviderUUID  string `json:"providerUuid"`
	AfterRedirect string `json:"afterRedirect,omitempty"`
}

// StartOIDCResp 返回 AuthCodeURL 给前端 window.location.href 跳转。
type StartOIDCResp struct {
	AuthURL string `json:"authUrl"`
	State   string `json:"state"`
}

// MySessionSummary /me/sessions 行 (多设备管理) — 不暴露 refresh_token_hash 等机密字段。
type MySessionSummary struct {
	UUID       string    `json:"uuid"`
	IssuedAt   time.Time `json:"issuedAt"`
	ExpiresAt  time.Time `json:"expiresAt"`
	LastUsedAt time.Time `json:"lastUsedAt"`
	UserAgent  string    `json:"userAgent,omitempty"`
	IP         string    `json:"ip,omitempty"`
	ActingAs   string    `json:"actingAs,omitempty"`
	IsCurrent  bool      `json:"isCurrent"`

	// 登录时客户端上报的结构化设备信息 (§10.6)；旧 session 行没有则全为空，
	// 客户端回退解析 UserAgent。
	DeviceType          string `json:"deviceType,omitempty"`
	DeviceBrand         string `json:"deviceBrand,omitempty"`
	DeviceModel         string `json:"deviceModel,omitempty"`
	DeviceSystemVersion string `json:"deviceSystemVersion,omitempty"`
	DeviceAppVersion    string `json:"deviceAppVersion,omitempty"`
}

// SendSmsReq 申请发短信。
type SendSmsReq struct {
	Mobile      string `json:"mobile"`
	Scene       string `json:"scene"` // login / register / sms-only-login
	CaptchaID   string `json:"captchaId"`
	CaptchaCode string `json:"captchaCode"`
}

// RefreshReq 刷新 token。
type RefreshReq struct {
	RefreshToken string `json:"refreshToken"`
}

// ScopeSwitchReq 切换 scope。
type ScopeSwitchReq struct {
	Kind        string `json:"kind"` // platform / tenant / workspace
	TenantID    int64  `json:"tenantId,omitempty"`
	WorkspaceID int64  `json:"workspaceId,omitempty"`
}

// MeResp /auth/me 响应。
type MeResp struct {
	Account AccountSummary `json:"account"`
	Scopes  []ScopeOption  `json:"scopes"`
}

// ChangePasswordReq 首次登录后强制改密 / 自助改密。
type ChangePasswordReq struct {
	Old string `json:"old,omitempty"`
	New string `json:"new"`
}

// AuthContext 中间件透传给 service 的请求信息 (远端 IP / UA / impersonate 来源)。
type AuthContext struct {
	IP        string
	UserAgent string
	TenantID  int64  // 当前生效租户（用于 audit 关联）
	TraceID   string // OpenTelemetry trace_id
	Device    DeviceInfo
}

// DeviceInfo 登录请求体里客户端可选上报的结构化设备信息
// (agent-bus-client-contract.md §10.6)。全部字段可能为空 (旧客户端未上报)。
type DeviceInfo struct {
	Type          string `json:"type,omitempty"`
	Brand         string `json:"brand,omitempty"`
	Model         string `json:"model,omitempty"`
	SystemVersion string `json:"systemVersion,omitempty"`
	AppVersion    string `json:"appVersion,omitempty"`
	// Fingerprint 客户端生成、本地持久化的稳定设备标识（不随重新登录变化）。
	// 2026-08-24 补齐：issueLogin 用它顶掉同一设备的旧 active session，避免
	// /me/sessions 里同一台设备反复登录后越攒越多（login_sessions.device_fingerprint
	// 列建表时就有，但此前登录链路一直没人写值）。旧客户端不上报时为空，回退到
	// 旧行为（不去重）。
	Fingerprint string `json:"deviceFingerprint,omitempty"`
}

// ImpersonateResp 平台代入租户身份的响应。
type ImpersonateResp struct {
	AccessToken          string    `json:"accessToken"`
	AccessTokenExpiresAt time.Time `json:"accessTokenExpiresAt"`
	TenantID             int64     `json:"tenantId"`
	ActingAs             string    `json:"actingAs"`
}

// ===== Service =====

// Service M1 auth 接口。
type Service interface {
	GenerateCaptcha(ctx context.Context) (*captcha.Result, error)
	SendSms(ctx context.Context, req SendSmsReq) error

	LoginPassword(ctx context.Context, ac AuthContext, req PasswordLoginReq) (*LoginResp, error)
	LoginSms(ctx context.Context, ac AuthContext, req SmsLoginReq) (*LoginResp, error)
	LoginOIDC(ctx context.Context, ac AuthContext, req OIDCCallbackReq) (*LoginResp, error)
	// RegisterSelf 客户端自助注册 (zhiban-app cutover): 短信验证通过 + 手机号未占用时,
	// 通过 d.SelfRegister 适配器原子创建账号 + 默认租户, 同时发 session token 直接登入。
	RegisterSelf(ctx context.Context, ac AuthContext, req SmsRegisterReq) (*LoginResp, error)
	// StartOIDC 生成 state+nonce, 存 Redis, 返跳转 URL 给前端。
	StartOIDC(ctx context.Context, req StartOIDCReq) (*StartOIDCResp, error)
	// ListMySessions /me/sessions 列当前账号所有 active session (多设备管理)。
	ListMySessions(ctx context.Context, accountID int64, currentSessionUUID string) ([]MySessionSummary, error)
	// RevokeMySession /me/sessions/{uuid} 撤销自己其他设备的 session。
	RevokeMySession(ctx context.Context, accountID int64, sessionUUID string) error

	Refresh(ctx context.Context, req RefreshReq) (*LoginResp, error)
	Logout(ctx context.Context, sessionUUID string) error

	// Me round-6 P2-1: 加 currentTenantID 参数 (0 表示 platform / no-scope token);
	// 非 0 时填 AccountSummary.DepartmentName (从 tenant_memberships → departments).
	Me(ctx context.Context, accountID, currentTenantID int64) (*MeResp, error)
	SwitchScope(ctx context.Context, accountID int64, sessionUUID string, req ScopeSwitchReq) (*LoginResp, error)
	ListMenu(ctx context.Context, accountID int64, actScopeKind string, actTenantID int64) ([]rbac.Menu, error)

	ChangePassword(ctx context.Context, accountID int64, req ChangePasswordReq) error
	VerifyToken(ctx context.Context, token string) (*jwt.Claims, error)

	// Impersonate Platform admin 临时代入指定租户 (M1 §5.1).
	// 校验由 admin handler 完成 (require platform.tenant.impersonate 权限点).
	Impersonate(ctx context.Context, ac AuthContext, platformAccountID int64, targetTenantID int64) (*ImpersonateResp, error)

	// Revoker 让 middleware 接黑名单。
	IsSessionRevoked(ctx context.Context, sessionUUID string) (bool, error)
	IsAccountRevoked(ctx context.Context, accountID int64, issuedAt time.Time) (bool, error)
}

// Deps 注入式构造。
type Deps struct {
	Accounts   account.Repository
	Tenants    tenant.Repository
	RBAC       rbac.Repository
	Sessions   session.Repository
	AuditLog   authaudit.Repository
	Issuer     *jwt.Issuer
	Captcha    *captcha.Captcha
	Codes      CodeStore
	SMS        sms.Sender
	Revoke     Revoker
	AccessTTL  time.Duration
	RefreshTTL time.Duration

	LockThreshold int           // 失败锁阈值
	LockDuration  time.Duration // 锁定时长

	// EventBus M0 events_outbox publisher（best-effort；nil 时不发统一 audit_events）。
	// 调用方需自管 pgx 事务；为了不破坏现有非事务 audit 调用，本服务在 helper 层
	// 用独立 tx 包一次（best-effort，失败仅日志）。
	EventBus EventBusPublisher

	// DeptName P2-1 round-6: caller 在 tenant scope 时, /auth/me 用本函数解析 department_name.
	// nil → 返空字符串 (auth.Service.Me 不阻塞响应).
	DeptName DepartmentNameFn

	// AvatarURL round-8 P1-2: 把 accounts.avatar_url 列的稳定值 (storage_key) 动态签名成
	// 短期 presigned GET URL 给客户端. 在所有返 AccountSummary 的路径 (login/me/refresh/
	// scope switch) 透明替换 AvatarURL/AvatarURLSnake 字段.
	//   - 入参 raw = accounts.avatar_url 列原值 (round-8 后是 storage_key, 老行可能是 http URL).
	//   - 出参 = 客户端可直接 GET 的 URL.
	//   - nil 或返 "" → 原样透传 raw (向后兼容; 老 http URL 不再续签).
	// 任何 store 访问失败请实现方 swallow + 返 ""; auth 不阻塞响应.
	AvatarURL AvatarURLResolver

	// M4 OIDC: 真接入 — Registry 按 IdP UUID 查并构造 Provider; StateStore 存 OIDC state/nonce。
	// nil 时 LoginOIDC 仍走 fake。
	IdentityRegistry IdentityRegistry
	OIDCStateStore   OIDCStateStore

	// SelfRegister zhiban-app cutover: 客户端 /auth/register/sms 走的适配器, 适配到
	// service/tenant.Service.Provision 同 tx 创建账号+租户+role+membership。nil 时
	// RegisterSelf 直接返 ErrInternal (Admin 进程不暴露该端点, 无需注入)。
	SelfRegister SelfRegisterer
}

type CodeStore interface {
	Issue(context.Context, smscode.Scene, string) (string, error)
	Verify(context.Context, smscode.Scene, string, string) error
}

// IdentityRegistry 是 service/identity.Registry 的窄抽象 (避免循环 import)。
type IdentityRegistry interface {
	ResolveByUUID(ctx context.Context, uuid string) (*identityadapter.LeasedProvider, error)
	ResolveByIssuer(ctx context.Context, issuer string) (*identityadapter.LeasedProvider, error)
}

// OIDCStateStore 是 service/identity.StateStore 的窄抽象。
type OIDCStateStore interface {
	Save(ctx context.Context, state string, payload identitysvc.StatePayload) error
	Pop(ctx context.Context, state string) (*identitysvc.StatePayload, error)
}

// DepartmentNameFn 反查 (tenantID, departmentID) → name; 失败返 "" 即可.
type DepartmentNameFn func(ctx context.Context, tenantID, departmentID int64) (string, error)

// AvatarURLResolver round-8 P1-2 + F06 Phase 2.7b: storage_key → 短期 presigned GET URL.
// 入参 raw 可能是 storage_key (无 scheme) 或老行 http URL (有 scheme);
// 实现方需自己判定: 有 scheme 一律原样返 (不再续签短期 URL).
//
// F06 Phase 2.7b: 增加 tenantID 入参. avatar 走 drivev3.StorageResolver per-tenant 路由,
// 跨 tenant 不能用同一 default store 签 URL (会指向错 bucket → 客户端 404).
// tenantID<=0 (platform scope) 时 resolver 实现侧应 fallback 到平台 default store.
type AvatarURLResolver func(ctx context.Context, tenantID int64, raw string) string

// EventBusPublisher 是 M0 events_outbox 的薄接口，用于把 auth 关键事件并行进 audit_events 统一表。
//
// 实现见 internal/repository/postgres/event；为了避免 import 循环，这里以函数式接口暴露。
type EventBusPublisher interface {
	PublishAudit(ctx context.Context, evt AuditEvent) error
}

// AuditEvent 简化版 audit payload，由 auth.Service 构造，传给 EventBusPublisher。
type AuditEvent struct {
	Topic          string // 如 "audit.auth.login.success"
	IdempotencyKey string // 可选
	AccountID      int64
	TenantID       int64
	TraceID        string
	IP             string
	UserAgent      string
	Domain         string // 默认 "auth"
	EventKind      string // 默认与 topic 同
	Severity       string // 默认 info
	Data           map[string]any
}

// Revoker 用 Redis 实现的撤销黑名单 + 失败锁定。
type Revoker interface {
	RevokeSession(ctx context.Context, sessionUUID string, ttl time.Duration) error
	RevokeAccount(ctx context.Context, accountID int64, until time.Time) error
	ClearAccountRevoke(ctx context.Context, accountID int64) error
	IsSessionRevoked(ctx context.Context, sessionUUID string) (bool, error)
	IsAccountRevoked(ctx context.Context, accountID int64, issuedAt time.Time) (bool, error)
	BumpFailedLogin(ctx context.Context, accountID int64, threshold int) (int64, bool, error)
	ResetFailedLogin(ctx context.Context, accountID int64) error
	IsLocked(ctx context.Context, accountID int64) (bool, time.Duration, error)
}

type impl struct {
	d         Deps
	deptName  DepartmentNameFn  // 取自 d.DeptName, 单独缓存以缩短 hot path; nil 时跳过.
	avatarURL AvatarURLResolver // round-8 P1-2: storage_key → 短期 signed URL; nil 时透传.
}

// New 构造。
func New(d Deps) Service {
	if d.AccessTTL <= 0 {
		d.AccessTTL = 15 * time.Minute
	}
	if d.RefreshTTL <= 0 {
		d.RefreshTTL = 30 * 24 * time.Hour
	}
	if d.LockThreshold <= 0 {
		d.LockThreshold = 5
	}
	if d.LockDuration <= 0 {
		d.LockDuration = 15 * time.Minute
	}
	return &impl{d: d, deptName: d.DeptName, avatarURL: d.AvatarURL}
}

// SetAvatarURLResolver round-8 P1-2 装配; cmd/bus / cmd/admin 在构造完 driveStore 后注入.
// 解决 auth.New 在 driveStore 之前 wire 的 ordering 问题 (与 EMP / Composer guard 同款 pattern).
func (s *impl) SetAvatarURLResolver(r AvatarURLResolver) { s.avatarURL = r }

// SetAvatarURLResolverOnService round-8 P1-2 helper.
func SetAvatarURLResolverOnService(svc Service, r AvatarURLResolver) {
	if im, ok := svc.(*impl); ok {
		im.SetAvatarURLResolver(r)
	}
}

// ===== captcha + sms 配套 =====

func (s *impl) GenerateCaptcha(ctx context.Context) (*captcha.Result, error) {
	if s.d.Captcha == nil {
		return nil, apperr.ErrInternal.Withf("captcha unavailable")
	}
	return s.d.Captcha.Generate(ctx)
}

func (s *impl) SendSms(ctx context.Context, req SendSmsReq) error {
	mobile := strings.TrimSpace(req.Mobile)
	if mobile == "" {
		return apperr.ErrInvalidParams.Withf("mobile required")
	}
	if s.d.Captcha != nil && req.CaptchaID != "" {
		ok, err := s.d.Captcha.Verify(ctx, req.CaptchaID, req.CaptchaCode)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if !ok {
			return apperr.New(apperr.InvalidParams, "图形验证码错误")
		}
	}
	scene := smscode.Scene(strings.TrimSpace(req.Scene))
	if scene == "" {
		scene = smscode.SceneLogin
	}
	code, err := s.d.Codes.Issue(ctx, scene, mobile)
	if err != nil {
		if errors.Is(err, smscode.ErrCooldown) {
			return apperr.New(apperr.TooManyRequests, "短信发送过于频繁，请稍后再试")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	body := buildSmsBody(scene, code)
	return s.d.SMS.Send(ctx, mobile, body)
}

// ===== login flows =====

func (s *impl) LoginPassword(ctx context.Context, ac AuthContext, req PasswordLoginReq) (*LoginResp, error) {
	id := strings.TrimSpace(req.Identifier)
	if id == "" || req.Password == "" {
		return nil, apperr.ErrInvalidParams.Withf("identifier/password required")
	}
	a, err := s.lookupByIdentifier(ctx, id)
	if err != nil {
		_ = s.audit(ctx, ac, authaudit.Event{Kind: authaudit.EventLoginPassword, Status: authaudit.StatusFailure, LoginMethod: "password", Reason: "account_not_found", Target: id})
		return nil, apperr.ErrUnauthorized.Withf("账号或密码错误")
	}
	if locked, ttl := s.isAccountLockedByRedis(ctx, a.ID); locked {
		_ = s.audit(ctx, ac, authaudit.Event{Kind: authaudit.EventLoginPassword, Status: authaudit.StatusFailure, AccountID: &a.ID, LoginMethod: "password", Reason: "locked_ttl_" + ttl.Round(time.Second).String()})
		return nil, apperr.ErrForbidden.Withf("账号已锁定, 剩余 %s, 请稍后再试", ttl.Round(time.Second))
	}
	if a.PasswordHash == "" || !crypto.VerifyPassword(a.PasswordHash, req.Password) {
		n, locked := s.bumpFailedLogin(ctx, a.ID)
		reason := "wrong_password"
		if locked {
			reason = "locked_now"
			_ = s.audit(ctx, ac, authaudit.Event{Kind: authaudit.EventLock, Status: authaudit.StatusSuccess, AccountID: &a.ID, Reason: "5_failed_attempts"})
		}
		_ = s.audit(ctx, ac, authaudit.Event{Kind: authaudit.EventLoginPassword, Status: authaudit.StatusFailure, AccountID: &a.ID, LoginMethod: "password", Reason: reason, Metadata: map[string]any{"fail_count": n}})
		if locked {
			return nil, apperr.ErrForbidden.Withf("失败次数过多, 账号锁定 15 分钟")
		}
		return nil, apperr.ErrUnauthorized.Withf("账号或密码错误")
	}
	if a.Status != "active" {
		return nil, apperr.ErrForbidden.Withf("账号状态: %s", a.Status)
	}
	s.resetFailedLogin(ctx, a.ID)
	return s.issueLogin(ctx, ac, a, "password", authaudit.EventLoginPassword)
}

// LoginSms 登录或自助注册一体化:
//
//   - 校验短信码 (scene=login) 通过后, 如果手机号未在 accounts 注册,
//     直接调 SelfRegister.ProvisionForMobile 同 tx 建租户+账号+管理员角色, 然后 issueLogin。
//   - 已注册但当前 0 个有效 scope (从未加入过租户, 或原 membership/role_assignment
//     被移出成员/prune-departments 等操作软删): 同样调 SelfRegister.ProvisionForMobile,
//     但复用已有账号只补建默认租户, 然后 issueLogin。见 2026-08-21 决策
//     docs/contracts/agent-bus-client-contract.md §10.2 (故意接受: 被移出成员下次短信登录
//     会自动拿到一个新空租户, 但恢复不了对原租户的访问)。
//   - 已注册且有效 scope → 走常规登录路径; account locked / status != active 仍走原拒绝逻辑。
//
// 这样 zhiban-app 客户端只用一个 /auth/login/sms 入口即可完成"已注册登录"和"未注册首次进入"
// 两种情况, 不需要再让用户感知 register 流程或重新拉短信码。
// /auth/register/sms (RegisterSelf) 仍保留, 第三方/外部 Agent 接入仍可用。
func (s *impl) LoginSms(ctx context.Context, ac AuthContext, req SmsLoginReq) (*LoginResp, error) {
	mobile := strings.TrimSpace(req.Mobile)
	if mobile == "" || req.Code == "" {
		return nil, apperr.ErrInvalidParams.Withf("mobile/code required")
	}
	a, err := s.d.Accounts.GetByPhone(ctx, mobile)
	notFound := errors.Is(err, apperr.ErrNotFound)
	if err != nil && !notFound {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if a != nil {
		if locked, ttl := s.isAccountLockedByRedis(ctx, a.ID); locked {
			return nil, apperr.ErrForbidden.Withf("账号已锁定, 剩余 %s", ttl.Round(time.Second))
		}
	}
	// 校验短信码 (一次性消费)。账号是否存在都需要消费, 防止"探测号码"行为。
	if verr := s.d.Codes.Verify(ctx, smscode.SceneLogin, mobile, req.Code); verr != nil {
		ev := authaudit.Event{Kind: authaudit.EventLoginSms, Status: authaudit.StatusFailure, LoginMethod: "sms", Target: mobile, Reason: smsErrReason(verr)}
		if a != nil {
			ev.AccountID = &a.ID
		}
		_ = s.audit(ctx, ac, ev)
		return nil, smsErrToApi(verr)
	}
	// account not found → 若允许自助注册 (SelfRegister 已注入, 仅 bus 端) 则自动建租户+账号+管理员后 issueLogin;
	// 未注入 (admin 端) 则按"账号不存在"直接拒绝, 防止任何手机号都能进管理后台。
	if notFound {
		if s.d.SelfRegister == nil {
			_ = s.audit(ctx, ac, authaudit.Event{Kind: authaudit.EventLoginSms, Status: authaudit.StatusFailure, LoginMethod: "sms", Target: mobile, Reason: "account_not_found"})
			return nil, apperr.ErrUnauthorized.Withf("账号不存在,请联系管理员开通")
		}
		accID, _, _, perr := s.d.SelfRegister.ProvisionForMobile(ctx, mobile)
		if perr != nil {
			return nil, perr
		}
		newAcc, gerr := s.d.Accounts.GetByID(ctx, accID)
		if gerr != nil {
			return nil, apperr.ErrInternal.Wrap(gerr)
		}
		return s.issueLogin(ctx, ac, newAcc, "sms_register", authaudit.EventLoginSms)
	}
	if a.Status != "active" {
		return nil, apperr.ErrForbidden.Withf("账号状态: %s", a.Status)
	}
	s.resetFailedLogin(ctx, a.ID)
	// 账号存在但当前 0 个有效 scope (从未加入过租户, 或原有 membership/role_assignment
	// 被移出成员/prune-departments 软删): 复用同一条自助建租户路径补建默认租户,
	// 不新建账号。2026-08-21 决策见 docs/contracts/agent-bus-client-contract.md §10.2。
	scopes, serr := s.buildScopeOptions(ctx, a.ID)
	if serr != nil {
		return nil, serr
	}
	if len(scopes) == 0 {
		if s.d.SelfRegister == nil {
			return nil, apperr.ErrForbidden.Withf("账号未加入任何租户")
		}
		if _, _, _, perr := s.d.SelfRegister.ProvisionForMobile(ctx, mobile); perr != nil {
			return nil, perr
		}
		// 复用账号补建租户前, accounts.display_name/avatar_url 可能还是上一个租户
		// (被移出前) 留下的真实姓名/头像。调用前已确认这个账号 0 个有效 scope, 也就是
		// 当前不在任何租户里, 所以直接整体清成"新用户"默认值是安全的——不会影响其它
		// 租户看到的身份 (因为压根没有其它租户)。跟真正全新自助注册账号的默认名同一
		// 套命名约定 (self_register.go ProvisionForMobile 里的 tenant name), 保持一致。
		if len(mobile) >= 4 {
			tail4 := mobile[len(mobile)-4:]
			generic := "用户" + tail4 + "的组织 管理员"
			if rerr := s.d.Accounts.ResetIdentityForSelfHeal(ctx, a.ID, generic); rerr == nil {
				// a 是补建前查的, display_name/avatar_url 已经改了; 重新读一份干净的
				// 传给 issueLogin, 不然响应里的 account 摘要还是旧身份信息。
				if fresh, gerr := s.d.Accounts.GetByID(ctx, a.ID); gerr == nil {
					a = fresh
				}
			}
		}
	}
	return s.issueLogin(ctx, ac, a, "sms", authaudit.EventLoginSms)
}

// LoginOIDC M4 真接入:
//
//   - Pop state 从 Redis → 拿到 expected_nonce + provider_uuid (state 一次性, 防 replay/CSRF)
//   - Registry 按 uuid 拿 Provider 实例 (含 OIDC discovery + JWKS)
//   - Provider.ExchangeCodeWithNonce → 校验 ID Token 签名 + nonce 命中
//   - account_identities 反查本地账号 → 不存在则按 email 兜底; 仍找不到 → 拒绝 (M4 不自动 provisioning)
//   - 走 issueLogin 流程发 session token + refresh
func (s *impl) LoginOIDC(ctx context.Context, ac AuthContext, req OIDCCallbackReq) (*LoginResp, error) {
	if s.d.IdentityRegistry == nil || s.d.OIDCStateStore == nil {
		return nil, apperr.ErrForbidden.Withf("OIDC not enabled (registry / state store not wired)")
	}
	if req.Code == "" || req.State == "" {
		return nil, apperr.ErrInvalidParams.Withf("code/state required")
	}
	payload, err := s.d.OIDCStateStore.Pop(ctx, req.State)
	if err != nil {
		return nil, err
	}
	lp, err := s.d.IdentityRegistry.ResolveByUUID(ctx, payload.ProviderUUID)
	if err != nil {
		return nil, err
	}
	// 现在 Provider 接口的 ExchangeCode 不强制 nonce; 我们专门用 OIDC 的 ExchangeCodeWithNonce。
	type nonceCapable interface {
		ExchangeCodeWithNonce(ctx context.Context, code, state, expectedNonce string) (*identityadapter.Profile, error)
	}
	nc, ok := lp.Provider.(nonceCapable)
	if !ok {
		return nil, apperr.ErrInternal.Withf("provider does not support nonce verification (only OIDC supported in M4)")
	}
	profile, err := nc.ExchangeCodeWithNonce(ctx, req.Code, req.State, payload.Nonce)
	if err != nil {
		return nil, apperr.ErrUnauthorized.Wrap(err)
	}
	if profile.Subject == "" {
		return nil, apperr.ErrUnauthorized.Withf("oidc profile missing subject claim")
	}
	provider := "oidc:" + lp.Cfg.Issuer
	// 1. account_identities 直接命中
	acct, err := s.d.Accounts.FindByProviderUID(ctx, provider, profile.Subject)
	if err != nil {
		if !errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		// 2. email 兜底匹配 (老账号未绑定 IdP, 第一次 SSO 登录时 link)
		if profile.Email == "" {
			return nil, apperr.ErrForbidden.Withf("oidc subject %s 未绑定本地账号; 请联系管理员", profile.Subject)
		}
		acct, err = s.d.Accounts.GetByEmail(ctx, profile.Email)
		if err != nil {
			return nil, apperr.ErrForbidden.Withf("email %s 未找到对应账号 (M4 不自动 provisioning)", profile.Email)
		}
	}
	// 3. upsert identity link (绑定 / 更新 last_used_at)
	meta := map[string]any{
		"email":  profile.Email,
		"name":   profile.Name,
		"groups": profile.Groups,
	}
	if err := s.d.Accounts.LinkIdentity(ctx, acct.ID, provider, profile.Subject, meta); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 4. 走标准 login pipeline 发 session
	return s.issueLogin(ctx, ac, acct, "oidc", authaudit.EventLoginOIDC)
}

// RegisterSelf 客户端自助注册 (zhiban-app cutover, docs/contracts/agent-bus-client-contract.md §10.2)。
//
// 流程:
//  1. trim + 必填校验; 短信码 scene=register (与 login 隔离, 防越权登录);
//  2. 校验 mobile 在 accounts 未被占用 (防陌生人把已存在账号拉进新租户);
//  3. 调 d.SelfRegister 适配器, 复用 service/tenant.Provision 同 tx 建租户+账号+role+membership;
//  4. 重新读 account 行, 走 issueLogin 发 session token (audit_kind=login.sms, login_method="sms_register")。
//
// 失败语义:
//   - SMS 码错误/过期 → 401 验证码错误或已过期
//   - mobile 已存在 → 409 账号已存在, 请直接登录
//   - 适配器未注入 (admin 进程) → 500 self-register not wired
func (s *impl) RegisterSelf(ctx context.Context, ac AuthContext, req SmsRegisterReq) (*LoginResp, error) {
	mobile := strings.TrimSpace(req.Mobile)
	code := strings.TrimSpace(req.Code)
	if mobile == "" || code == "" {
		return nil, apperr.ErrInvalidParams.Withf("mobile/code required")
	}
	if s.d.SelfRegister == nil {
		return nil, apperr.ErrInternal.Withf("self-register not wired")
	}
	if err := s.d.Codes.Verify(ctx, smscode.SceneRegister, mobile, code); err != nil {
		return nil, smsErrToApi(err)
	}
	existing, err := s.d.Accounts.GetByPhone(ctx, mobile)
	if err == nil && existing != nil {
		return nil, apperr.ErrConflict.Withf("账号已存在, 请直接登录")
	}
	if err != nil && !errors.Is(err, apperr.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	accID, _, _, err := s.d.SelfRegister.ProvisionForMobile(ctx, mobile)
	if err != nil {
		return nil, err
	}
	a, err := s.d.Accounts.GetByID(ctx, accID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return s.issueLogin(ctx, ac, a, "sms_register", authaudit.EventLoginSms)
}

// StartOIDC 生成 state + nonce, 存 Redis, 返 AuthCodeURL。
//
// 前端流程: 用户点 "用 X 登录" → POST /auth/login/oidc/start → 服务端返 authUrl →
// 前端 window.location.href = authUrl → IdP 登录 → IdP 跳回 /auth/oidc/callback?code=&state=
// → 前端 POST /auth/login/oidc/callback → 服务端 LoginOIDC 完成登录。
func (s *impl) StartOIDC(ctx context.Context, req StartOIDCReq) (*StartOIDCResp, error) {
	if s.d.IdentityRegistry == nil || s.d.OIDCStateStore == nil {
		return nil, apperr.ErrForbidden.Withf("OIDC not enabled")
	}
	if req.ProviderUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("providerUuid required")
	}
	lp, err := s.d.IdentityRegistry.ResolveByUUID(ctx, req.ProviderUUID)
	if err != nil {
		return nil, err
	}
	state := newRandomToken()
	nonce := newRandomToken()
	if err := s.d.OIDCStateStore.Save(ctx, state, identitysvc.StatePayload{
		ProviderUUID:  req.ProviderUUID,
		Nonce:         nonce,
		AfterRedirect: req.AfterRedirect,
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 仅 OIDC provider 有 AuthCodeURL 方法
	type authURLer interface {
		AuthCodeURL(state, nonce string) string
	}
	au, ok := lp.Provider.(authURLer)
	if !ok {
		return nil, apperr.ErrInternal.Withf("provider does not expose AuthCodeURL")
	}
	return &StartOIDCResp{AuthURL: au.AuthCodeURL(state, nonce), State: state}, nil
}

// ListMySessions /me/sessions: 列当前账号 active session, 用于多设备管理。
//
// currentSessionUUID 是请求侧 (中间件解出来的) 当前 session UUID, 用于标 IsCurrent。
func (s *impl) ListMySessions(ctx context.Context, accountID int64, currentSessionUUID string) ([]MySessionSummary, error) {
	if accountID <= 0 {
		return nil, apperr.ErrInvalidParams
	}
	rows, err := s.d.Sessions.ListActiveByAccount(ctx, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]MySessionSummary, 0, len(rows))
	for _, r := range rows {
		ip := ""
		if r.IP != nil {
			ip = r.IP.String()
		}
		out = append(out, MySessionSummary{
			UUID:                r.UUID,
			IssuedAt:            r.IssuedAt,
			ExpiresAt:           r.ExpiresAt,
			LastUsedAt:          r.LastUsedAt,
			UserAgent:           r.UserAgent,
			IP:                  ip,
			ActingAs:            r.ActingAs,
			IsCurrent:           r.UUID == currentSessionUUID,
			DeviceType:          r.DeviceType,
			DeviceBrand:         r.DeviceBrand,
			DeviceModel:         r.DeviceModel,
			DeviceSystemVersion: r.DeviceSystemVersion,
			DeviceAppVersion:    r.DeviceAppVersion,
		})
	}
	return out, nil
}

// RevokeMySession /me/sessions/{uuid}: 撤销自己其他设备的 session。
//
// 安全: 必须先校验 sessionUUID 属于本账号 (防越权撤别人 session)。
func (s *impl) RevokeMySession(ctx context.Context, accountID int64, sessionUUID string) error {
	if accountID <= 0 || sessionUUID == "" {
		return apperr.ErrInvalidParams
	}
	sess, err := s.d.Sessions.GetByUUID(ctx, sessionUUID)
	if err != nil {
		return apperr.ErrNotFound
	}
	if sess.AccountID != accountID {
		return apperr.ErrForbidden.Withf("session 不属于当前账号")
	}
	if err := s.d.Sessions.Revoke(ctx, sessionUUID, "user-revoke-from-sessions-page"); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	// 立刻把 Redis 黑名单同步上 (跨进程立即失效)
	if s.d.Revoke != nil {
		_ = s.d.Revoke.RevokeSession(ctx, sessionUUID, s.d.AccessTTL*2)
	}
	return nil
}

// newRandomToken 生成 URL-safe 32 字符随机串, 用作 state / nonce。
func newRandomToken() string {
	var b [24]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand 失败极罕见; fail-fast
		panic(fmt.Errorf("rand.Read: %w", err))
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// ===== refresh / logout =====

func (s *impl) Refresh(ctx context.Context, req RefreshReq) (*LoginResp, error) {
	if strings.TrimSpace(req.RefreshToken) == "" {
		return nil, apperr.ErrInvalidParams
	}
	hash := hashRefresh(req.RefreshToken)
	sess, err := s.d.Sessions.GetByRefreshHash(ctx, hash)
	if err != nil {
		return nil, apperr.ErrUnauthorized.Withf("refresh token 无效")
	}
	if sess.RevokedAt != nil {
		return nil, apperr.ErrUnauthorized.Withf("session 已撤销")
	}
	if time.Now().After(sess.ExpiresAt) {
		return nil, apperr.ErrUnauthorized.Withf("refresh token 已过期")
	}
	a, err := s.d.Accounts.GetByID(ctx, sess.AccountID)
	if err != nil {
		return nil, apperr.ErrUnauthorized
	}
	// rotation
	newRefresh, newHash := newRefreshToken()
	newExpire := time.Now().Add(s.d.RefreshTTL)
	if err := s.d.Sessions.TouchUsed(ctx, sess.UUID, newHash, newExpire); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	scopeOpt, err := s.buildScopeOption(ctx, a.ID, sess.ActScopeKind, sess.ActTenantID, sess.ActWorkspaceID)
	if err != nil {
		return nil, err
	}
	tok, err := s.issueAccessToken(a, sess.UUID, scopeOpt)
	if err != nil {
		return nil, err
	}
	return &LoginResp{
		AccessToken:           tok,
		AccessTokenExpiresAt:  time.Now().Add(s.d.AccessTTL),
		RefreshToken:          newRefresh,
		RefreshTokenExpiresAt: newExpire,
		Account:               s.summarizeAccount(ctx, scopeOpt.TenantID, a, false),
		ActScope:              scopeOpt,
	}, nil
}

func (s *impl) Logout(ctx context.Context, sessionUUID string) error {
	if sessionUUID == "" {
		return apperr.ErrInvalidParams
	}
	if err := s.d.Sessions.Revoke(ctx, sessionUUID, "logout"); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if s.d.Revoke != nil {
		_ = s.d.Revoke.RevokeSession(ctx, sessionUUID, s.d.AccessTTL*2)
	}
	_ = s.audit(ctx, AuthContext{}, authaudit.Event{Kind: authaudit.EventLogout, Status: authaudit.StatusSuccess})
	return nil
}

// ===== me / scope.switch / menu =====

func (s *impl) Me(ctx context.Context, accountID, currentTenantID int64) (*MeResp, error) {
	acc, err := s.d.Accounts.GetByIDWithAdminStatus(ctx, accountID)
	if err != nil {
		return nil, err
	}
	scopes, err := s.buildScopeOptions(ctx, accountID)
	if err != nil {
		return nil, err
	}
	summary := s.summarizeAccount(ctx, currentTenantID, acc.Account, acc.MustChangePassword)
	// P2-1: 当 caller 在 tenant scope 时, 填 department_name.
	// platform scope (currentTenantID==0) → 保持空; 无 tenant_membership → 保持空.
	if currentTenantID > 0 {
		summary.DepartmentName = s.lookupDepartmentName(ctx, accountID, currentTenantID)
	}
	return &MeResp{
		Account: summary,
		Scopes:  scopes,
	}, nil
}

// lookupDepartmentName · 返回 caller 在指定 tenant 的部门名; 任何失败 / 缺字段返空字符串.
// 直接走 pgxpool 查 tenant_memberships JOIN departments; 这是 nice-to-have 字段, 不必 fail-closed.
func (s *impl) lookupDepartmentName(ctx context.Context, accountID, tenantID int64) string {
	if s.d.Accounts == nil {
		return ""
	}
	mem, err := s.d.Accounts.GetMembership(ctx, accountID, tenantID)
	if err != nil || mem == nil {
		return ""
	}
	if mem.DepartmentID == nil || *mem.DepartmentID <= 0 {
		return ""
	}
	if s.deptName == nil {
		return ""
	}
	name, err := s.deptName(ctx, tenantID, *mem.DepartmentID)
	if err != nil {
		return ""
	}
	return name
}

func (s *impl) SwitchScope(ctx context.Context, accountID int64, sessionUUID string, req ScopeSwitchReq) (*LoginResp, error) {
	if sessionUUID == "" {
		return nil, apperr.ErrUnauthorized
	}
	kind := strings.TrimSpace(req.Kind)
	switch kind {
	case "platform", "tenant", "workspace":
	default:
		return nil, apperr.ErrInvalidParams.Withf("kind 必须为 platform/tenant/workspace")
	}
	scopeOpt, err := s.buildScopeOption(ctx, accountID, kind, ptr(req.TenantID), ptr(req.WorkspaceID))
	if err != nil {
		return nil, err
	}
	if len(scopeOpt.Perms) == 0 && !(scopeOpt.Kind == "tenant" && scopeOpt.TenantID > 0 && scopeOpt.Roles != nil) {
		return nil, apperr.ErrForbidden.Withf("该 scope 下没有任何权限")
	}
	var tid, wid *int64
	if req.TenantID > 0 {
		v := req.TenantID
		tid = &v
	}
	if req.WorkspaceID > 0 {
		v := req.WorkspaceID
		wid = &v
	}
	// 取切换前的 scope，用于判断是否需要发 audit.auth.scope.impersonate
	// （platform → tenant 视为 impersonate；失败拿不到 fromScope 不影响主路径）。
	var fromScope string
	if prev, perr := s.d.Sessions.GetByUUID(ctx, sessionUUID); perr == nil && prev != nil {
		fromScope = prev.ActScopeKind
	}
	if err := s.d.Sessions.UpdateScope(ctx, session.UpdateScopeInput{
		SessionUUID: sessionUUID, ActScopeKind: kind, ActTenantID: tid, ActWorkspaceID: wid,
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	a, err := s.d.Accounts.GetByID(ctx, accountID)
	if err != nil {
		return nil, err
	}
	tok, err := s.issueAccessToken(a, sessionUUID, scopeOpt)
	if err != nil {
		return nil, err
	}
	_ = s.audit(ctx, AuthContext{}, authaudit.Event{
		Kind: authaudit.EventScopeSwitch, Status: authaudit.StatusSuccess,
		AccountID: &a.ID, TenantID: tid, WorkspaceID: wid,
		Metadata: map[string]any{"from_scope": fromScope, "to_scope": kind},
	})
	// platform admin 进入 tenant scope = cross-scope impersonate-like 行为，单独审计。
	// 复用现有 audit/outbox 路径（不动事务模型）；失败 silently，主路径不受影响。
	if fromScope == "platform" && kind == "tenant" && tid != nil {
		_ = s.audit(ctx, AuthContext{}, authaudit.Event{
			Kind: authaudit.EventScopeImpersonate, Status: authaudit.StatusSuccess,
			AccountID: &a.ID, TenantID: tid,
			ActorKind: "platform_admin",
			Target:    "tenant:" + strconv.FormatInt(*tid, 10),
			Metadata: map[string]any{
				"from_scope":   fromScope,
				"to_scope":     kind,
				"to_tenant_id": *tid,
				"account_id":   a.ID,
				"acting_as":    "platform_admin",
			},
		})
	}
	return &LoginResp{
		AccessToken:          tok,
		AccessTokenExpiresAt: time.Now().Add(s.d.AccessTTL),
		Account:              s.summarizeAccount(ctx, scopeOpt.TenantID, a, false),
		ActScope:             scopeOpt,
	}, nil
}

// ListMenu 返回当前 act_scope 下 caller 可见的菜单 (M1 §3.3.4)。
//
// 过滤规则 (P0-C):
//  1. scope_kind 严格匹配当前 act_scope:
//     - platform → 包含 self/any/platform
//     - tenant / workspace → 包含 self/any/tenant/workspace
//  2. is_visible=true
//  3. menu_permissions 二次过滤: 该菜单挂的任意权限点必须在 caller 的 perms 集合内;
//     若菜单未挂任何 permission (例如 /me 父节点), 视为对所有登录用户可见。
//
// 这样普通成员 (无任何 role) 只会看到 perms 内的菜单 (通常是空)。
func (s *impl) ListMenu(ctx context.Context, accountID int64, actScopeKind string, actTenantID int64) ([]rbac.Menu, error) {
	perms, err := s.d.RBAC.ListPermissionCodesForAccount(ctx, accountID, actTenantID)
	if err != nil {
		return nil, err
	}
	permSet := make(map[string]struct{}, len(perms))
	for _, p := range perms {
		permSet[p] = struct{}{}
	}
	scopeKinds := []string{"self", "any"}
	switch actScopeKind {
	case "platform":
		scopeKinds = append(scopeKinds, "platform")
	case "tenant", "workspace":
		scopeKinds = append(scopeKinds, "tenant", "workspace")
	}
	all, err := s.d.RBAC.ListMenusForScopes(ctx, scopeKinds)
	if err != nil {
		return nil, err
	}
	menuPerms, err := s.d.RBAC.ListMenuPermissionCodes(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]rbac.Menu, 0, len(all))
	for _, m := range all {
		if !m.IsVisible {
			continue
		}
		needs := menuPerms[m.ID]
		if len(needs) == 0 {
			// 未挂权限点的菜单 (父节点 / 预留) 默认对所有已登录可见
			out = append(out, m)
			continue
		}
		hit := false
		for _, code := range needs {
			if _, ok := permSet[code]; ok {
				hit = true
				break
			}
		}
		if hit {
			out = append(out, m)
		}
	}
	return out, nil
}

func (s *impl) ChangePassword(ctx context.Context, accountID int64, req ChangePasswordReq) error {
	if req.New == "" || len(req.New) < 8 {
		return apperr.ErrInvalidParams.Withf("新密码长度至少 8 位")
	}
	a, err := s.d.Accounts.GetByID(ctx, accountID)
	if err != nil {
		return err
	}
	// 自助改密 (mustChange=false): 必须校验老密码。
	// 首次登录强制改密 (mustChange=true): 用户刚用种子密码登录成功, 当前 access token
	// 已是已鉴权状态; 再校验一次旧密码不增加安全性, 反而增加用户摩擦, 与 GitHub /
	// Atlassian / M365 等业界做法对齐 —— 跳过老密码校验, 只验新密码强度。
	mustChange, _ := s.adminMustChangePassword(ctx, accountID)
	if a.PasswordHash != "" && !mustChange {
		if req.Old == "" || !crypto.VerifyPassword(a.PasswordHash, req.Old) {
			return apperr.ErrUnauthorized.Withf("原密码不正确")
		}
	}
	hash, err := crypto.HashPassword(req.New)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if err := s.d.Accounts.UpdatePassword(ctx, accountID, hash); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	_ = s.clearMustChangePassword(ctx, accountID)
	// 改密后强制下线所有 session（DB 行 revoked_at + Redis account-level revoke）
	_ = s.d.Sessions.RevokeAllByAccount(ctx, accountID, "password_change")
	if s.d.Revoke != nil {
		// 决策 #4: 写 Redis account-level revoke，让旧 access token 立即失效，不等 access_ttl
		// cutoff = now（秒精度）：所有 iat<=cutoff_sec 的 token 被拒。
		revokeAt := time.Now()
		_ = s.d.Revoke.RevokeAccount(ctx, accountID, revokeAt)

		// Batch 2B closeout #1：JWT iat 只有秒精度。若改密响应在同一 wall-clock 秒内返回，
		// 客户端立即重新登录拿到的新 token iat == cutoff_sec → 被误判已撤销。
		// 解决：在 ChangePassword 返回前主动 sleep 到下一秒边界，确保后续 re-login 拿到 iat > cutoff。
		// 等待时间 < 1s（平均 ~500ms），可忽略；强一致优先于响应延迟。
		nextSec := revokeAt.Truncate(time.Second).Add(time.Second).Add(50 * time.Millisecond)
		if d := time.Until(nextSec); d > 0 {
			select {
			case <-time.After(d):
			case <-ctx.Done():
			}
		}
	}
	// Batch1 返修 #4: 撤销所有 session 时补 audit.auth.session.revoked
	_ = s.audit(ctx, AuthContext{}, authaudit.Event{
		Kind:      authaudit.EventSessionRevoke,
		Status:    authaudit.StatusSuccess,
		AccountID: &accountID,
		Reason:    "password_change",
	})
	_ = s.audit(ctx, AuthContext{}, authaudit.Event{
		Kind:      authaudit.EventPasswordChange,
		Status:    authaudit.StatusSuccess,
		AccountID: &accountID,
	})
	return nil
}

// ===== verify token (middleware 用) =====

func (s *impl) VerifyToken(ctx context.Context, token string) (*jwt.Claims, error) {
	c, err := s.d.Issuer.Verify(token)
	if err != nil {
		return nil, apperr.ErrUnauthorized.Wrap(err)
	}
	return c, nil
}

func (s *impl) IsSessionRevoked(ctx context.Context, sessionUUID string) (bool, error) {
	if sessionUUID == "" {
		return true, nil
	}
	if s.d.Revoke != nil {
		if revoked, err := s.d.Revoke.IsSessionRevoked(ctx, sessionUUID); err == nil && revoked {
			return true, nil
		}
	}
	// DB is authoritative even if NOTIFY was missed or Redis is unavailable.
	if s.d.Sessions == nil {
		return true, apperr.ErrUnauthorized
	}
	sess, err := s.d.Sessions.GetByUUID(ctx, sessionUUID)
	if err != nil {
		return true, err
	}
	return sess == nil || sess.RevokedAt != nil || !sess.ExpiresAt.After(time.Now()), nil
}

func (s *impl) IsAccountRevoked(ctx context.Context, accountID int64, issuedAt time.Time) (bool, error) {
	if s.d.Revoke == nil {
		return false, nil
	}
	return s.d.Revoke.IsAccountRevoked(ctx, accountID, issuedAt)
}

// ===== impersonate =====

// Impersonate 签发一个 TTL=60min 的临时 access token,
// 让平台管理员以 tenant scope 操作目标租户, acting_as=platform_admin 留痕。
//
// M3 D8 option C: 改成插入真实临时 role_assignment (granted_reason='impersonate',
// expires_at=now+60min)。优点:
//   - 审计完整: role_assignments 表能直接查到 "谁在何时代入了哪个租户";
//   - 权限清晰: 复用 ListPermissionCodesForAccount 标准路径, 不再走 fallback hack;
//   - 自动失效: expires_at 到期后 ListPermissionCodesForAccount 自动过滤;
//     另有 cleanup cron (cmd/bus, cmd/admin 各起一个) 定期删除真正过期的行。
//
// 关键设计 (不变):
//   - login_sessions.acting_as='platform_admin' 留下完整审计记录
//   - exp = 60min 短 TTL, 强制定期回平台 scope
//   - JWT 仍带 ActingAs 让中间件识别 impersonate 状态
func (s *impl) Impersonate(ctx context.Context, ac AuthContext, platformAccountID int64, targetTenantID int64) (*ImpersonateResp, error) {
	if targetTenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenantId required")
	}
	a, err := s.d.Accounts.GetByID(ctx, platformAccountID)
	if err != nil {
		return nil, err
	}

	const impersonateTTL = 60 * time.Minute
	expiresAt := time.Now().Add(impersonateTTL)

	// D8 option C: 先插一条 expires_at=60min 的 role_assignment, 再用标准路径查 perms。
	// codex challenge #5: 保留 assignmentID 用于 defer-rollback。
	// 如果后面 session 创建 / JWT 签发失败, 必须立刻删掉这个临时授权,
	// 否则 platform admin 之后能通过 normal scope switch 切入 (无 ActingAs claim, 审计盲点)。
	// (#H 已在 buildScopeOptions 加 granted_reason='impersonate' 过滤, 这里再加一层防御性 rollback。)
	granter := platformAccountID
	assignmentID, asnErr := s.d.RBAC.IssueImpersonateAssignment(ctx, platformAccountID, targetTenantID, expiresAt, &granter)
	if asnErr != nil {
		return nil, apperr.ErrInternal.Wrap(asnErr)
	}
	// defer 在出错路径上回滚; 成功路径下 commit (设 assignmentID=0 跳过 rollback)。
	defer func() {
		if assignmentID != 0 {
			_ = s.d.RBAC.DeleteImpersonateAssignment(context.Background(), assignmentID)
		}
	}()

	perms, err := s.d.RBAC.ListPermissionCodesForAccount(ctx, platformAccountID, targetTenantID)
	if err != nil {
		return nil, err
	}
	refresh, refreshHash := newRefreshToken()
	tid := targetTenantID
	sess, err := s.d.Sessions.Create(ctx, session.CreateInput{
		AccountID:        platformAccountID,
		RefreshTokenHash: refreshHash,
		ExpiresAt:        time.Now().Add(impersonateTTL),
		ActScopeKind:     "tenant",
		ActTenantID:      &tid,
		ActingAs:         "platform_admin",
		UserAgent:        ac.UserAgent,
		IP:               ac.IP,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	_ = refresh

	tok, err := s.d.Issuer.Issue(jwt.IssueOptions{
		AccountID:   platformAccountID,
		AccountUUID: a.UUID,
		SessionUUID: sess.UUID,
		ActScope:    "tenant",
		ActTenantID: targetTenantID,
		Perms:       perms,
		ActingAs:    "platform_admin",
		Kind:        "impersonation",
		Admin:       true,
		TTL:         impersonateTTL,
	})
	if err != nil {
		return nil, err
	}

	sid64 := sess.ID
	_ = s.audit(ctx, ac, authaudit.Event{
		Kind: authaudit.EventImpersonateEnter, Status: authaudit.StatusSuccess,
		AccountID: &platformAccountID, SessionID: &sid64, TenantID: &targetTenantID,
		ActorKind: "platform_admin", Target: "tenant:" + strconv.FormatInt(targetTenantID, 10),
		Metadata: map[string]any{"ttl_minutes": 60, "role_assignment_id": assignmentID},
	})
	// 成功路径: 清掉 assignmentID 让 defer 不 rollback。
	assignmentID = 0
	return &ImpersonateResp{
		AccessToken:          tok,
		AccessTokenExpiresAt: time.Now().Add(impersonateTTL),
		TenantID:             targetTenantID,
		ActingAs:             "platform_admin",
	}, nil
}

// ===== internals: login pipeline =====

// issueLogin 在密码 / 短信 / OIDC 验证通过后, 写 session + 返回 token 对。
func (s *impl) issueLogin(ctx context.Context, ac AuthContext, a *account.Account, method string, kind authaudit.EventKind) (*LoginResp, error) {
	// pick initial scope: 第一个 platform > 第一个 tenant
	scopes, err := s.buildScopeOptions(ctx, a.ID)
	if err != nil {
		return nil, err
	}
	if len(scopes) == 0 {
		return nil, apperr.ErrForbidden.Withf("账号未加入任何租户")
	}
	initial := scopes[0]
	for _, sc := range scopes {
		if sc.Kind == "platform" {
			initial = sc
			break
		}
	}

	// Session repository atomically replaces the same device class.
	// 新 session
	refresh, refreshHash := newRefreshToken()
	var tidPtr, widPtr *int64
	if initial.TenantID > 0 {
		v := initial.TenantID
		tidPtr = &v
	}
	if initial.WorkspaceID > 0 {
		v := initial.WorkspaceID
		widPtr = &v
	}
	sess, err := s.d.Sessions.Create(ctx, session.CreateInput{
		AccountID:           a.ID,
		RefreshTokenHash:    refreshHash,
		ExpiresAt:           time.Now().Add(s.d.RefreshTTL),
		ActScopeKind:        initial.Kind,
		ActTenantID:         tidPtr,
		ActWorkspaceID:      widPtr,
		UserAgent:           ac.UserAgent,
		IP:                  ac.IP,
		DeviceFingerprint:   ac.Device.Fingerprint,
		DeviceType:          ac.Device.Type,
		DeviceBrand:         ac.Device.Brand,
		DeviceModel:         ac.Device.Model,
		DeviceSystemVersion: ac.Device.SystemVersion,
		DeviceAppVersion:    ac.Device.AppVersion,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	tok, err := s.issueAccessToken(a, sess.UUID, initial)
	if err != nil {
		return nil, err
	}
	_ = s.d.Accounts.UpdateLastLogin(ctx, a.ID, ac.IP)
	sid64 := sess.ID
	_ = s.audit(ctx, ac, authaudit.Event{Kind: kind, Status: authaudit.StatusSuccess, AccountID: &a.ID, SessionID: &sid64, LoginMethod: method})

	mustChange, _ := s.adminMustChangePassword(ctx, a.ID)
	return &LoginResp{
		AccessToken:           tok,
		AccessTokenExpiresAt:  time.Now().Add(s.d.AccessTTL),
		RefreshToken:          refresh,
		RefreshTokenExpiresAt: sess.ExpiresAt,
		Account:               s.summarizeAccount(ctx, initial.TenantID, a, mustChange),
		ActScope:              initial,
	}, nil
}

// issueAccessToken 签一个 JWT。
//
// Batch1 返修 #2: 内部查 admin_accounts.must_change_password 并填入 token claims；
// 中间件 RequirePasswordValid 据此拦截除改密 / logout / me 类之外的业务请求。
func (s *impl) issueAccessToken(a *account.Account, sessionUUID string, sc ScopeOption) (string, error) {
	mustChange, _ := s.adminMustChangePassword(context.Background(), a.ID)
	return s.d.Issuer.Issue(jwt.IssueOptions{
		AccountID:      a.ID,
		AccountUUID:    a.UUID,
		SessionUUID:    sessionUUID,
		ActScope:       sc.Kind,
		ActTenantID:    sc.TenantID,
		ActWorkspaceID: sc.WorkspaceID,
		Perms:          sc.Perms,
		MustChange:     mustChange,
		Admin:          sc.IsAdmin,
	})
}

// lookupByIdentifier email/phone/username 任一种识别符。
func (s *impl) lookupByIdentifier(ctx context.Context, id string) (*account.Account, error) {
	switch {
	case strings.Contains(id, "@"):
		return s.d.Accounts.GetByEmail(ctx, id)
	case looksLikePhone(id):
		return s.d.Accounts.GetByPhone(ctx, id)
	default:
		return s.d.Accounts.GetByUsername(ctx, id)
	}
}

// buildScopeOptions 拉所有可切换的 scope。
// buildScopeOptions 2026-08-24 修复: IsAdmin 必须逐个 scope 用 row.IsAdmin 本身
// (ListScopeSummariesForAccount 已按 scope_kind/tenant_id/workspace_id 分组算好),
// 不能再跨 scope 汇总成一个账号级布尔值——账号在 A 租户是 tenant.admin、在 B 租户
// 只是 tenant.member 时,汇总值会把 A 租户的管理员身份错误地带进 B 租户的 scope
// 选项里,最终签进 B 租户的 JWT Admin claim,造成跨租户权限泄漏。
func (s *impl) buildScopeOptions(ctx context.Context, accountID int64) ([]ScopeOption, error) {
	summaries, err := s.d.RBAC.ListScopeSummariesForAccount(ctx, accountID)
	if err != nil {
		return nil, err
	}
	out := make([]ScopeOption, 0, len(summaries))
	for _, row := range summaries {
		if ok, err := s.scopeTenantExists(ctx, row.Kind, row.TenantID); err != nil {
			return nil, err
		} else if !ok {
			continue
		}
		out = append(out, ScopeOption{
			Kind:        row.Kind,
			TenantID:    row.TenantID,
			WorkspaceID: row.WorkspaceID,
			Roles:       append([]string(nil), row.Roles...),
			Perms:       append([]string(nil), row.Perms...),
			IsAdmin:     row.IsAdmin,
		})
	}
	if len(out) == 0 {
		// 走到这里说明这个账号一条 role_assignment 都没有 (零 scope 兜底走
		// membership 表), 不可能持有任何管理员角色, IsAdmin 恒为 false。
		mems, _ := s.d.Accounts.ListMemberships(ctx, accountID)
		for _, m := range mems {
			if m.Status != "active" {
				continue
			}
			if ok, err := s.scopeTenantExists(ctx, "tenant", m.TenantID); err != nil {
				return nil, err
			} else if !ok {
				continue
			}
			out = append(out, ScopeOption{Kind: "tenant", TenantID: m.TenantID, Roles: []string{}, IsAdmin: false})
		}
	}
	s.hydrateScopeLabels(ctx, accountID, out)
	return out, nil
}

func (s *impl) hydrateScopeLabels(ctx context.Context, accountID int64, scopes []ScopeOption) {
	if len(scopes) == 0 {
		return
	}
	accountDisplayName := ""
	if s.d.Accounts != nil {
		if acc, err := s.d.Accounts.GetByID(ctx, accountID); err == nil && acc != nil {
			accountDisplayName = strings.TrimSpace(acc.DisplayName)
		}
	}
	var memberships map[int64]account.Membership
	if s.d.Accounts != nil {
		if mems, err := s.d.Accounts.ListMemberships(ctx, accountID); err == nil {
			memberships = make(map[int64]account.Membership, len(mems))
			for _, m := range mems {
				memberships[m.TenantID] = m
			}
		}
	}
	for i := range scopes {
		if scopes[i].Kind != "tenant" || scopes[i].TenantID <= 0 {
			continue
		}
		if s.d.Tenants != nil {
			if tn, err := s.d.Tenants.GetByID(ctx, scopes[i].TenantID); err == nil && tn != nil {
				scopes[i].TenantSlug = strings.TrimSpace(tn.Slug)
				scopes[i].TenantName = firstNonEmpty(tn.DisplayName, tn.Name, tn.Slug)
			}
		}
		if m, ok := memberships[scopes[i].TenantID]; ok {
			scopes[i].MemberDisplayName = firstNonEmpty(m.Nickname, accountDisplayName)
		}
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if s := strings.TrimSpace(v); s != "" {
			return s
		}
	}
	return ""
}

func (s *impl) scopeTenantExists(ctx context.Context, kind string, tenantID int64) (bool, error) {
	if kind == "platform" || tenantID <= 0 {
		return true, nil
	}
	if s.d.Accounts == nil {
		return false, apperr.ErrInternal.Withf("account repository not wired")
	}
	return s.d.Accounts.TenantExists(ctx, tenantID)
}

// buildScopeOption 单 scope 重算 (用于 refresh / scope.switch)。
func (s *impl) buildScopeOption(ctx context.Context, accountID int64, kind string, tenantID, workspaceID *int64) (ScopeOption, error) {
	options, err := s.buildScopeOptions(ctx, accountID)
	if err != nil {
		return ScopeOption{}, err
	}
	wantTid := int64(0)
	if tenantID != nil {
		wantTid = *tenantID
	}
	wantWid := int64(0)
	if workspaceID != nil {
		wantWid = *workspaceID
	}
	for _, opt := range options {
		if opt.Kind == kind && opt.TenantID == wantTid && opt.WorkspaceID == wantWid {
			return opt, nil
		}
	}
	return ScopeOption{}, apperr.ErrForbidden.Withf("该 scope 已失效")
}

// ===== helpers (audit / lock / sms / refresh hash) =====

func (s *impl) audit(ctx context.Context, ac AuthContext, e authaudit.Event) error {
	if e.OccurredAt.IsZero() {
		e.OccurredAt = time.Now()
	}
	if e.ActorKind == "" {
		e.ActorKind = "user"
	}
	if e.Status == "" {
		e.Status = authaudit.StatusSuccess
	}
	if e.IP == "" {
		e.IP = ac.IP
	}
	if e.UserAgent == "" {
		e.UserAgent = ac.UserAgent
	}
	// 1) 写 M1 auth_audit_events（detailed schema，沿用）
	var insertErr error
	if s.d.AuditLog != nil {
		insertErr = s.d.AuditLog.Insert(ctx, e)
	}
	// 2) 同步 publish 到 M0 events_outbox → audit-writer → audit_events（best-effort）
	s.publishUnifiedAudit(ctx, ac, e)
	return insertErr
}

// publishUnifiedAudit 把 auth event 异步 publish 到 events_outbox（M0 统一审计）。
// best-effort：失败仅日志，不影响主流程。
//
// idempotency_key 策略（T0.7 + 用户决策 2026-05-15）：
//   - password.changed / session.revoked → 传 key（防同一动作被记两次）
//   - login.success / login.failure / scope.switch / logout → 不传 key（每次都是合法事件）
func (s *impl) publishUnifiedAudit(ctx context.Context, ac AuthContext, e authaudit.Event) {
	if s.d.EventBus == nil {
		return
	}
	topic, idemKey, severity := authTopicFor(e)
	if topic == "" {
		return // 不需要进统一 audit 的事件
	}

	accID := int64(0)
	if e.AccountID != nil {
		accID = *e.AccountID
	}
	data := map[string]any{
		"status":       string(e.Status),
		"login_method": e.LoginMethod,
		"target":       e.Target,
		"reason":       e.Reason,
	}
	for k, v := range e.Metadata {
		data[k] = v
	}

	evt := AuditEvent{
		Topic:          topic,
		IdempotencyKey: idemKey,
		AccountID:      accID,
		TenantID:       ac.TenantID,
		TraceID:        ac.TraceID,
		IP:             e.IP,
		UserAgent:      e.UserAgent,
		Domain:         "auth",
		EventKind:      topic,
		Severity:       severity,
		Data:           data,
	}
	if err := s.d.EventBus.PublishAudit(ctx, evt); err != nil {
		// 不阻塞主流程；仅日志（结构化日志由调用方/装饰器接管，这里用 noop fallback）
		_ = err
	}
}

// authTopicFor 把 authaudit.Event 映射成统一 audit topic + idempotency_key 策略 + severity。
// 返回空 topic 表示不入统一 audit。
func authTopicFor(e authaudit.Event) (topic, idemKey, severity string) {
	status := string(e.Status)
	switch e.Kind {
	case authaudit.EventLoginPassword, authaudit.EventLoginSms, authaudit.EventLoginOIDC:
		// 不传 idemKey：每次登录（含失败）都是合法事件
		if status == string(authaudit.StatusFailure) {
			return "audit.auth.login.failure", "", "warning"
		}
		return "audit.auth.login.success", "", "info"
	case authaudit.EventLogout:
		return "audit.auth.logout", "", "info"
	case authaudit.EventScopeSwitch:
		return "audit.auth.scope.switch", "", "info"
	case authaudit.EventScopeImpersonate:
		// platform admin 切到 tenant scope 视为 impersonate（虽然没换身份）；
		// 单独 topic 便于审计中心按"跨 scope 越权操作"独立查询。
		return "audit.auth.scope.impersonate", "", "warning"
	case authaudit.EventPasswordChange:
		// 传 idemKey：防同一改密被记两次
		key := authIdempKey("password.changed", e)
		return "audit.auth.password.changed", key, "info"
	case authaudit.EventSessionRevoke:
		// 传 idemKey：防同一撤销被记两次
		key := authIdempKey("session.revoked", e)
		return "audit.auth.session.revoked", key, "info"
	case authaudit.EventLock:
		return "audit.auth.account.locked", "", "warning"
	}
	return "", "", ""
}

// authIdempKey 生成 idempotency_key（v1 简化版）：
// 不引入 hash 包，把 (kind, account_id, occurred_at unix nano) 直接拼。
func authIdempKey(kind string, e authaudit.Event) string {
	accID := int64(0)
	if e.AccountID != nil {
		accID = *e.AccountID
	}
	occ := e.OccurredAt.UnixNano()
	return fmt.Sprintf("auth.%s.%d.%d", kind, accID, occ)
}

// isAccountLockedByRedis 通过 Redis 判锁。
func (s *impl) isAccountLockedByRedis(ctx context.Context, accountID int64) (bool, time.Duration) {
	if s.d.Revoke == nil {
		return false, 0
	}
	ok, ttl, _ := s.d.Revoke.IsLocked(ctx, accountID)
	return ok, ttl
}

func (s *impl) bumpFailedLogin(ctx context.Context, accountID int64) (int64, bool) {
	if s.d.Revoke == nil {
		return 0, false
	}
	threshold := s.d.LockThreshold
	if threshold <= 0 {
		threshold = 5
	}
	n, locked, _ := s.d.Revoke.BumpFailedLogin(ctx, accountID, threshold)
	return n, locked
}

func (s *impl) resetFailedLogin(ctx context.Context, accountID int64) {
	if s.d.Revoke != nil {
		_ = s.d.Revoke.ResetFailedLogin(ctx, accountID)
	}
}

// adminMustChangePassword 读 admin_accounts.must_change_password。
// 非 admin_account 行 / 找不到 → false（普通租户用户视为不需强改密）。
func (s *impl) adminMustChangePassword(ctx context.Context, accountID int64) (bool, error) {
	return s.d.Accounts.IsAdminMustChangePassword(ctx, accountID)
}

// clearMustChangePassword 把 admin_accounts.must_change_password 置 false + 刷新 last_password_change。
// 非 admin_account 行 → no-op（不报错）。
func (s *impl) clearMustChangePassword(ctx context.Context, accountID int64) error {
	return s.d.Accounts.SetAdminMustChangePassword(ctx, accountID, false)
}

func buildSmsBody(scene smscode.Scene, code string) string {
	switch scene {
	case smscode.SceneRegister:
		return "【知办AI】您的注册验证码: " + code + ",5 分钟内有效。"
	default:
		return "【知办AI】您的登录验证码: " + code + ",5 分钟内有效。"
	}
}

func smsErrToApi(err error) error {
	switch {
	case errors.Is(err, smscode.ErrMismatch):
		return apperr.ErrUnauthorized.Withf("验证码错误或已过期")
	case errors.Is(err, smscode.ErrTooMany):
		return apperr.ErrForbidden.Withf("失败次数过多,请重新获取验证码")
	default:
		return apperr.ErrInternal.Wrap(err)
	}
}

func smsErrReason(err error) string {
	switch {
	case errors.Is(err, smscode.ErrMismatch):
		return "code_mismatch"
	case errors.Is(err, smscode.ErrTooMany):
		return "too_many"
	default:
		return "other"
	}
}

// summarizeAccount round-8 P1-2 + F06 Phase 2.7b: 成员方法版本; 把 accounts.avatar_url
// (round-8 起存 storage_key) 通过 avatarURL resolver 动态签成短期 GET URL.
// resolver nil / 返空 → 透传原值 (向后兼容).
//
// tenantID 是 caller 当前 act_scope 的 tenant_id (platform scope = 0); resolver 据此走
// drivev3.StorageResolver 选 per-tenant store (Phase 2.7b cutover, 见 docs/features/F06-drive.md §2.4).
//
// 任何 resolver 调用错误吞掉 (resolver 自己 swallow); auth 路径不应被对象存储健康度阻塞.
func (s *impl) summarizeAccount(ctx context.Context, tenantID int64, a *account.Account, mustChange bool) AccountSummary {
	avatar := a.AvatarURL
	if s.avatarURL != nil && avatar != "" {
		if signed := s.avatarURL(ctx, tenantID, avatar); signed != "" {
			avatar = signed
		}
	}
	displayName := a.DisplayName
	if tenantID > 0 && s.d.Accounts != nil {
		if mem, err := s.d.Accounts.GetMembership(ctx, a.ID, tenantID); err == nil && mem != nil {
			if nickname := strings.TrimSpace(mem.Nickname); nickname != "" {
				displayName = nickname
			}
		}
	}
	return AccountSummary{
		ID: a.ID, UUID: a.UUID, DisplayName: displayName,
		Email: a.Email, EmailMasked: maskEmail(a.Email),
		Phone: a.Phone, PhoneMasked: maskPhone(a.Phone),
		Username:  a.Username,
		AvatarURL: avatar, AvatarURLSnake: avatar,
		MustChangePassword: mustChange,
		PasswordSet:        a.PasswordHash != "",
	}
}

// maskPhone · 11 位手机号脱敏: 138****5678; 不识别格式则原样返回前 3 + 末 4.
// 调用方应避免传明文长串过来; 仅用于客户端展示.
func maskPhone(s string) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) < 7 {
		return s
	}
	keepHead := 3
	keepTail := 4
	if len(r) < keepHead+keepTail {
		return s
	}
	mid := len(r) - keepHead - keepTail
	masked := make([]rune, 0, len(r))
	masked = append(masked, r[:keepHead]...)
	for i := 0; i < mid; i++ {
		masked = append(masked, '*')
	}
	masked = append(masked, r[len(r)-keepTail:]...)
	return string(masked)
}

// maskEmail · a@b.com → a***@b.com; 用户名长 ≥3 时保留首末; ≤2 时直接 *@b.com.
func maskEmail(s string) string {
	s = strings.TrimSpace(s)
	at := strings.IndexByte(s, '@')
	if at < 0 {
		return s
	}
	user, host := s[:at], s[at:]
	r := []rune(user)
	switch len(r) {
	case 0:
		return s
	case 1, 2:
		return "***" + host
	default:
		return string(r[:1]) + "***" + string(r[len(r)-1:]) + host
	}
}

func looksLikePhone(s string) bool {
	if len(s) < 5 {
		return false
	}
	for _, c := range s {
		if !(c == '+' || (c >= '0' && c <= '9') || c == '-' || c == ' ') {
			return false
		}
	}
	return true
}

// newRefreshToken 生成 256bit 不透明 refresh token + sha256 hash。
func newRefreshToken() (token, hash string) {
	var raw [32]byte
	_, _ = rand.Read(raw[:])
	token = base64.RawURLEncoding.EncodeToString(raw[:])
	hash = hashRefresh(token)
	return
}

func hashRefresh(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func ptr(v int64) *int64 {
	if v == 0 {
		return nil
	}
	return &v
}
