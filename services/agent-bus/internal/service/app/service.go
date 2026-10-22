// Package app 是 F04 (apps) 业务层。
//
// 公开能力 (Service 接口见 domain/app):
//   - admin CRUD: CreateApp / GetApp / ListApps / PatchApp / DeleteApp / RotateSecret
//   - admin 配置: SetUniversal / SetEnabled / BindAgentApps / ListAgentApps
//   - 分类管理: ListCategories / CreateCategory / PatchCategory / DeleteCategory
//   - client 启动: ListConversationApps / Launch
//   - OAuth2 token endpoint: ConsumeAuthorizationCode / ValidateClientCredentials
//
// 字符串格式 (跟 standards/oauth2-grant-naming-and-token-format.md 对齐):
//   - client_id     = "app_" + 32 base62
//   - client_secret = "sk_" + 48 base62 (明文一次性返回; 入库 sha256 hex)
//   - auth_code     = 32 base62 (明文出现在 launch_url, 入库 sha256 hex; TTL 60s, 一次性消费)
package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domtenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	pkgoauth2 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2"
)

// Deps 服务依赖。
type Deps struct {
	Apps              dom.AppRepo
	Settings          dom.TenantAppSettingRepo
	Bindings          dom.AgentAppBindingRepo
	OAuthClients      dom.OAuthClientRepo
	OAuthCodes        dom.OAuthCodeRepo
	RefreshTokens     dom.RefreshTokenRepo // PR3 加; admin-only 部署可空
	Categories        dom.CategoryRepo
	Conversations     domconv.Repository         // ListConversationApps + Launch 用; 可空 (admin-only 部署)
	ConversationRooms dom.ConversationRoomReader // room-backed agent-direct 成员解析; admin-only 可空
	Agents            domagent.Repository        // BindAgentApps + ListConversationApps 用
	Accounts          domaccount.Repository      // IDTokenUserClaims 用 (token endpoint); admin-only 可空
	Tenants           domtenant.Repository       // IDTokenUserClaims 用; admin-only 可空
	Audit             AuditPublisher             // F04 audit events; nil 时跳过

	Now func() time.Time

	// DiscoveryBaseURL e.g. "https://example.org"; 拼 CreatedAppResult 时用。
	DiscoveryBaseURL string

	// AuthCodeTTL launch endpoint 颁的 code 有效期; 默认 60s。
	AuthCodeTTL time.Duration

	// AccessTokenTTL / RefreshTokenTTL OAuth client 默认 TTL (没显式传时填这俩); 不影响每客户端覆盖。
	DefaultAccessTokenTTL  time.Duration
	DefaultRefreshTokenTTL time.Duration
}

type Service struct {
	deps Deps
	now  func() time.Time
}

type AuditPublisher interface {
	PublishWithTx(ctx context.Context, topic string, tenantID int64, idempKey string, payload map[string]any) error
}

// ensure Service satisfies dom.Service at compile time
var _ dom.Service = (*Service)(nil)

// New 构造。
func New(d Deps) *Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.AuthCodeTTL <= 0 {
		d.AuthCodeTTL = 60 * time.Second
	}
	if d.DefaultAccessTokenTTL <= 0 {
		d.DefaultAccessTokenTTL = 2 * time.Hour
	}
	if d.DefaultRefreshTokenTTL <= 0 {
		d.DefaultRefreshTokenTTL = 30 * 24 * time.Hour
	}
	return &Service{deps: d, now: d.Now}
}

// =====================================================
// admin CRUD
// =====================================================

// CreateApp 创建应用 + 联动创建 OAuth client; 返一次性可见的明文 client_secret。
func (s *Service) CreateApp(ctx context.Context, tenantID, creatorID int64, in dom.CreateAppInput) (*dom.CreatedAppResult, error) {
	if err := validateAppInput(in); err != nil {
		return nil, err
	}

	// 1. 解 category_uuid (可选)
	var categoryID *int64
	if in.CategoryUUID != "" {
		cat, err := s.deps.Categories.GetByUUID(ctx, tenantID, in.CategoryUUID)
		if err != nil {
			return nil, apperr.ErrInvalidParams.Withf("category_uuid %q not found: %v", in.CategoryUUID, err)
		}
		categoryID = &cat.ID
	}

	// 2. INSERT apps
	a := &dom.App{
		TenantID:    tenantID,
		CreatorID:   creatorID,
		Code:        strings.TrimSpace(in.Code),
		Name:        strings.TrimSpace(in.Name),
		Description: in.Description,
		IconURL:     in.IconURL,
		Color:       in.Color,
		DisplayMode: in.DisplayMode,
		UsageScope:  normalizeUsageScope(in.UsageScope),
		LaunchURI:   in.LaunchURI,
		CategoryID:  categoryID,
		Status:      "active",
		IsSystem:    tenantID == 0,
	}
	if tenantID == 0 {
		a.Metadata = map[string]any{"open_to_tenants": in.OpenToTenants}
	}
	if err := s.deps.Apps.Insert(ctx, a); err != nil {
		return nil, fmt.Errorf("create app: %w", err)
	}

	// 3. 生成 client_id + client_secret + hash
	clientID, err := pkgoauth2.GenClientID("app")
	if err != nil {
		return nil, fmt.Errorf("gen client_id: %w", err)
	}
	plaintext, err := pkgoauth2.GenSecret()
	if err != nil {
		return nil, fmt.Errorf("gen secret: %w", err)
	}
	secretHash := pkgoauth2.HashSecret(plaintext)

	accessTTL := in.AccessTokenTTLSeconds
	if accessTTL <= 0 {
		accessTTL = int(s.deps.DefaultAccessTokenTTL.Seconds())
	}
	refreshTTL := in.RefreshTokenTTLSeconds
	if refreshTTL <= 0 {
		refreshTTL = int(s.deps.DefaultRefreshTokenTTL.Seconds())
	}

	// 4. INSERT app_oauth_clients
	oc := &dom.OAuthClient{
		TenantID:                tenantID,
		CreatorID:               creatorID,
		AppID:                   a.ID,
		ClientID:                clientID,
		ClientSecretHash:        secretHash,
		RedirectURIs:            in.RedirectURIs,
		Scopes:                  in.Scopes,
		TokenEndpointAuthMethod: "client_secret_post",
		AccessTokenTTLSeconds:   accessTTL,
		RefreshTokenTTLSeconds:  refreshTTL,
		Status:                  "active",
	}
	if err := s.deps.OAuthClients.Insert(ctx, oc); err != nil {
		// best-effort 回滚 app 行
		_ = s.deps.Apps.SoftDelete(ctx, tenantID, a.UUID)
		return nil, fmt.Errorf("create oauth client: %w", err)
	}

	// 5. 反向 FK apps.oauth_client_id ← oc.id
	if err := s.deps.Apps.SetOAuthClientID(ctx, a.ID, oc.ID); err != nil {
		return nil, fmt.Errorf("set oauth_client_id: %w", err)
	}
	a.OAuthClientID = &oc.ID
	s.audit(ctx, "audit.app.create", tenantID, "app.create:"+a.UUID, map[string]any{
		"resource_kind": "app",
		"resource_uuid": a.UUID,
		"app_uuid":      a.UUID,
		"client_id":     oc.ClientID,
	})

	base := s.deps.DiscoveryBaseURL
	return &dom.CreatedAppResult{
		App:             a,
		OAuthClient:     oc,
		PlaintextSecret: plaintext,
		TokenEndpoint:   base + "/api/external/v1/oauth/token",
		Issuer:          base,
		JWKSURI:         base + "/.well-known/jwks.json",
		DiscoveryURI:    base + "/.well-known/openid-configuration",
	}, nil
}

func (s *Service) GetApp(ctx context.Context, tenantID int64, uuid string) (*dom.App, *dom.OAuthClient, error) {
	a, err := s.deps.Apps.GetByUUID(ctx, tenantID, uuid)
	if err != nil {
		return nil, nil, err
	}
	s.applyTenantSettings(ctx, tenantID, a)
	var oc *dom.OAuthClient
	if a.OAuthClientID != nil {
		oc, err = s.deps.OAuthClients.GetByID(ctx, *a.OAuthClientID)
		if err != nil && !errors.Is(err, apperr.ErrNotFound) {
			return nil, nil, err
		}
	}
	return a, oc, nil
}

func (s *Service) ListApps(ctx context.Context, tenantID int64, filter dom.AppListFilter) ([]dom.App, int64, error) {
	apps, total, err := s.deps.Apps.ListByTenant(ctx, tenantID, filter)
	if err != nil {
		return nil, 0, err
	}
	for i := range apps {
		s.applyTenantSettings(ctx, tenantID, &apps[i])
	}
	return apps, total, nil
}

func (s *Service) PatchApp(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.App, error) {
	if raw, ok := fields["oauth_scopes"]; ok {
		scopes, ok := raw.([]string)
		if !ok {
			return nil, apperr.ErrInvalidParams.Withf("oauth_scopes must be a string array")
		}
		if err := validateOAuthScopes(scopes); err != nil {
			return nil, err
		}
	}
	if raw, ok := fields["usage_scope"]; ok {
		scope, _ := raw.(string)
		if err := validateUsageScope(scope); err != nil {
			return nil, err
		}
		fields["usage_scope"] = normalizeUsageScope(scope)
	}
	if raw, ok := fields["open_to_tenants"]; ok {
		delete(fields, "open_to_tenants")
		if tenantID != 0 {
			return nil, apperr.ErrForbidden.Withf("only platform can change app tenant availability")
		}
		a, err := s.deps.Apps.GetByUUID(ctx, tenantID, uuid)
		if err != nil {
			return nil, err
		}
		meta := a.Metadata
		if meta == nil {
			meta = map[string]any{}
		}
		meta["open_to_tenants"], _ = raw.(bool)
		fields["metadata"] = meta
	}
	if raw, ok := fields["category_uuid"]; ok {
		delete(fields, "category_uuid")
		categoryUUID, _ := raw.(string)
		if strings.TrimSpace(categoryUUID) == "" {
			fields["category_id"] = nil
		} else {
			cat, err := s.deps.Categories.GetByUUID(ctx, tenantID, categoryUUID)
			if err != nil {
				return nil, apperr.ErrInvalidParams.Withf("category_uuid %q not found: %v", categoryUUID, err)
			}
			fields["category_id"] = cat.ID
		}
	}
	oauthFields := map[string]any{}
	for from, to := range map[string]string{
		"oauth_redirect_uris":             "redirect_uris",
		"oauth_scopes":                    "scopes",
		"oauth_access_token_ttl_seconds":  "access_token_ttl_seconds",
		"oauth_refresh_token_ttl_seconds": "refresh_token_ttl_seconds",
	} {
		if v, ok := fields[from]; ok {
			oauthFields[to] = v
			delete(fields, from)
		}
	}
	a, err := s.deps.Apps.Patch(ctx, tenantID, uuid, fields)
	if err != nil {
		return nil, err
	}
	if len(oauthFields) > 0 {
		if a.OAuthClientID == nil {
			return nil, apperr.ErrInternal.Withf("app %q has no oauth_client", uuid)
		}
		if _, err := s.deps.OAuthClients.Patch(ctx, *a.OAuthClientID, oauthFields); err != nil {
			return nil, err
		}
	}
	s.applyTenantSettings(ctx, tenantID, a)
	s.audit(ctx, "audit.app.updated", tenantID, "app.updated:"+uuid+":"+fmt.Sprint(s.now().UnixNano()), map[string]any{
		"resource_kind": "app",
		"resource_uuid": uuid,
		"app_uuid":      uuid,
	})
	return a, nil
}

func (s *Service) DeleteApp(ctx context.Context, tenantID int64, uuid string) error {
	// 软删 app + 撤 OAuth client (级联)
	a, err := s.deps.Apps.GetByUUID(ctx, tenantID, uuid)
	if err != nil {
		return err
	}
	if tenantID != 0 && a.TenantID != tenantID {
		return apperr.ErrForbidden.Withf("platform app can only be deleted by platform admin")
	}
	if err := s.deps.Apps.SoftDelete(ctx, tenantID, uuid); err != nil {
		return err
	}
	if a.OAuthClientID != nil {
		if err := s.deps.OAuthClients.Revoke(ctx, *a.OAuthClientID); err != nil && !errors.Is(err, apperr.ErrNotFound) {
			return err
		}
	}
	s.audit(ctx, "audit.app.deleted", tenantID, "app.deleted:"+uuid, map[string]any{
		"resource_kind": "app",
		"resource_uuid": uuid,
		"app_uuid":      uuid,
	})
	return nil
}

// RotateSecret 重置 client_secret; 返新明文一次。
func (s *Service) RotateSecret(ctx context.Context, tenantID int64, uuid string) (string, error) {
	a, err := s.deps.Apps.GetByUUID(ctx, tenantID, uuid)
	if err != nil {
		return "", err
	}
	if tenantID != 0 && a.TenantID != tenantID {
		return "", apperr.ErrForbidden.Withf("platform app secret can only be rotated by platform admin")
	}
	if a.OAuthClientID == nil {
		return "", apperr.ErrInternal.Withf("app %q has no oauth_client", uuid)
	}
	plaintext, err := pkgoauth2.GenSecret()
	if err != nil {
		return "", fmt.Errorf("gen secret: %w", err)
	}
	if err := s.deps.OAuthClients.RotateSecret(ctx, *a.OAuthClientID, pkgoauth2.HashSecret(plaintext)); err != nil {
		return "", err
	}
	s.audit(ctx, "audit.app.secret_rotated", tenantID, "app.secret_rotated:"+uuid+":"+fmt.Sprint(s.now().UnixNano()), map[string]any{
		"resource_kind": "app",
		"resource_uuid": uuid,
		"app_uuid":      uuid,
	})
	return plaintext, nil
}

// =====================================================
// admin 通用应用开关 + 业务应用绑定
// =====================================================

func (s *Service) SetUniversal(ctx context.Context, tenantID int64, appUUID string, isUniversal bool, sortOrder int) error {
	a, err := s.deps.Apps.GetByUUID(ctx, tenantID, appUUID)
	if err != nil {
		return err
	}
	if isUniversal && !canUseInEndUserEntry(a) {
		return apperr.ErrInvalidParams.Withf("app usage_scope=%s cannot be used in user entry", normalizeUsageScope(a.UsageScope))
	}
	// 读现有 settings 保留 is_enabled 字段
	existing, err := s.deps.Settings.GetByTenantApp(ctx, tenantID, a.ID)
	isEnabled := true
	if err == nil && existing != nil {
		isEnabled = existing.IsEnabled
	}
	return s.deps.Settings.Upsert(ctx, &dom.TenantAppSetting{
		TenantID: tenantID, AppID: a.ID,
		IsUniversal: isUniversal, IsEnabled: isEnabled, SortOrder: sortOrder,
	})
}

func (s *Service) SetEnabled(ctx context.Context, tenantID int64, appUUID string, isEnabled bool) error {
	a, err := s.deps.Apps.GetByUUID(ctx, tenantID, appUUID)
	if err != nil {
		return err
	}
	existing, err := s.deps.Settings.GetByTenantApp(ctx, tenantID, a.ID)
	isUniversal := false
	sortOrder := 0
	if err == nil && existing != nil {
		isUniversal = existing.IsUniversal
		sortOrder = existing.SortOrder
	}
	return s.deps.Settings.Upsert(ctx, &dom.TenantAppSetting{
		TenantID: tenantID, AppID: a.ID,
		IsUniversal: isUniversal, IsEnabled: isEnabled, SortOrder: sortOrder,
	})
}

// BindAgentApps 把数字员工的应用绑定列表替换为 appUUIDs (按顺序记 sort_order)。
func (s *Service) BindAgentApps(ctx context.Context, tenantID, agentID int64, appUUIDs []string) error {
	appIDs := make([]int64, 0, len(appUUIDs))
	for _, u := range appUUIDs {
		a, err := s.deps.Apps.GetByUUID(ctx, tenantID, u)
		if err != nil {
			return apperr.ErrInvalidParams.Withf("app %q not found: %v", u, err)
		}
		if !canUseInAgentBinding(a) {
			return apperr.ErrInvalidParams.Withf("app %q usage_scope=%s cannot be bound to agent", u, normalizeUsageScope(a.UsageScope))
		}
		appIDs = append(appIDs, a.ID)
	}
	return s.deps.Bindings.ReplaceForAgent(ctx, agentID, appIDs)
}

func (s *Service) ListAgentApps(ctx context.Context, tenantID, agentID int64) ([]dom.App, error) {
	appIDs, err := s.deps.Bindings.ListAppIDsByAgent(ctx, agentID)
	if err != nil {
		return nil, err
	}
	out := make([]dom.App, 0, len(appIDs))
	for _, id := range appIDs {
		a, err := s.deps.Apps.GetByID(ctx, id)
		if err != nil {
			if errors.Is(err, apperr.ErrNotFound) {
				continue // 软删的 app 跳过
			}
			return nil, err
		}
		if !agentAppVisible(a, tenantID) {
			continue
		}
		out = append(out, *a)
	}
	return out, nil
}

// ListAgentAppsByAgentIDs 批量版 ListAgentApps（客户端 /agents 列表 hydrate 用，
// 见 pitfalls/client-api-list-hydrate-n-plus-one-remote-db-latency.md）：2 条 SQL 取全量
// 绑定 + app 行后内存分桶。过滤口径与逐条版完全一致（软删跳过 / 跨租户防御性跳过 /
// usage_scope 仅 all|agent）；桶内顺序 = 绑定 sort_order, id。
func (s *Service) ListAgentAppsByAgentIDs(ctx context.Context, tenantID int64, agentIDs []int64) (map[int64][]dom.App, error) {
	out := make(map[int64][]dom.App, len(agentIDs))
	if len(agentIDs) == 0 {
		return out, nil
	}
	bindings, err := s.deps.Bindings.ListByAgents(ctx, agentIDs)
	if err != nil {
		return nil, err
	}
	if len(bindings) == 0 {
		return out, nil
	}
	idSet := make(map[int64]struct{}, len(bindings))
	appIDs := make([]int64, 0, len(bindings))
	for _, b := range bindings {
		if _, ok := idSet[b.AppID]; ok {
			continue
		}
		idSet[b.AppID] = struct{}{}
		appIDs = append(appIDs, b.AppID)
	}
	apps, err := s.deps.Apps.ListByIDs(ctx, appIDs)
	if err != nil {
		return nil, err
	}
	appsByID := make(map[int64]*dom.App, len(apps))
	for i := range apps {
		appsByID[apps[i].ID] = &apps[i]
	}
	for _, b := range bindings {
		a, ok := appsByID[b.AppID]
		if !ok {
			continue // 软删/缺失的 app 跳过（对齐逐条版 ErrNotFound → continue）
		}
		if !agentAppVisible(a, tenantID) {
			continue
		}
		out[b.AgentID] = append(out[b.AgentID], *a)
	}
	return out, nil
}

// agentAppVisible 数字员工绑定视角下 app 是否可见：跨租户防御性跳过 + usage_scope 过滤。
// ListAgentApps 与 ListAgentAppsByAgentIDs 共用，保证两条路径口径永远一致。
func agentAppVisible(a *dom.App, tenantID int64) bool {
	if a.TenantID != 0 && a.TenantID != tenantID {
		return false // 不应发生, 防御性跳过
	}
	return canUseInAgentBinding(a)
}

// =====================================================
// 分类管理
// =====================================================

func (s *Service) ListCategories(ctx context.Context, tenantID int64, limit, offset int) ([]dom.Category, int64, error) {
	return s.deps.Categories.List(ctx, tenantID, limit, offset)
}

func (s *Service) CreateCategory(ctx context.Context, tenantID int64, code, name string, sortOrder int) (*dom.Category, error) {
	c := &dom.Category{
		Code: strings.TrimSpace(code), Name: strings.TrimSpace(name),
		SortOrder: sortOrder, IsSystem: tenantID == 0,
	}
	if err := s.deps.Categories.Insert(ctx, tenantID, c); err != nil {
		return nil, err
	}
	return c, nil
}

func (s *Service) PatchCategory(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.Category, error) {
	return s.deps.Categories.Patch(ctx, tenantID, uuid, fields)
}

func (s *Service) DeleteCategory(ctx context.Context, tenantID int64, uuid string) error {
	return s.deps.Categories.Delete(ctx, tenantID, uuid)
}

func (s *Service) applyTenantSettings(ctx context.Context, tenantID int64, a *dom.App) {
	a.IsEnabled = true
	if tenantID == 0 {
		return
	}
	setting, err := s.deps.Settings.GetByTenantApp(ctx, tenantID, a.ID)
	if err == nil && setting != nil {
		a.IsUniversal = setting.IsUniversal
		a.IsEnabled = setting.IsEnabled
	}
}

func (s *Service) AuditOAuthToken(ctx context.Context, tenantID int64, clientID, grantType, accountUUID string) {
	s.audit(ctx, "audit.app.oauth.token", tenantID, "app.oauth.token:"+clientID+":"+grantType+":"+fmt.Sprint(s.now().UnixNano()), map[string]any{
		"resource_kind": "app_oauth_client",
		"client_id":     clientID,
		"grant_type":    grantType,
		"account_uuid":  accountUUID,
	})
}

// AuditBorrowedCapability 记录应用代表用户调用租户只读能力的行为。
// 不记录 access_token、refresh_token 或 client_secret。
func (s *Service) AuditBorrowedCapability(ctx context.Context, tenantID int64, clientID, accountUUID, capability, method, path string) {
	s.audit(ctx, "audit.app.borrow."+capability, tenantID, "app.borrow:"+clientID+":"+capability+":"+fmt.Sprint(s.now().UnixNano()), map[string]any{
		"resource_kind": "app_oauth_client",
		"client_id":     clientID,
		"account_uuid":  accountUUID,
		"capability":    capability,
		"method":        method,
		"path":          path,
	})
}

func (s *Service) audit(ctx context.Context, topic string, tenantID int64, idempKey string, payload map[string]any) {
	if s.deps.Audit == nil {
		return
	}
	_ = s.deps.Audit.PublishWithTx(ctx, topic, tenantID, idempKey, payload)
}

// =====================================================
// 工具
// =====================================================

func validateAppInput(in dom.CreateAppInput) error {
	if in.Code == "" {
		return apperr.ErrInvalidParams.Withf("code required")
	}
	if in.Name == "" {
		return apperr.ErrInvalidParams.Withf("name required")
	}
	if in.LaunchURI == "" {
		return apperr.ErrInvalidParams.Withf("launch_uri required")
	}
	if len(in.RedirectURIs) == 0 {
		return apperr.ErrInvalidParams.Withf("redirect_uris required (at least 1)")
	}
	if len(in.RedirectURIs) > 5 {
		return apperr.ErrInvalidParams.Withf("redirect_uris exceeds max 5")
	}
	switch in.DisplayMode {
	case "side_panel", "fullscreen", "external_browser":
	default:
		return apperr.ErrInvalidParams.Withf("display_mode must be one of side_panel / fullscreen / external_browser")
	}
	if err := validateUsageScope(in.UsageScope); err != nil {
		return err
	}
	if err := validateOAuthScopes(in.Scopes); err != nil {
		return err
	}
	return nil
}

func validateOAuthScopes(scopes []string) error {
	seen := make(map[string]struct{}, len(scopes))
	for _, scope := range scopes {
		if !dom.IsSupportedOAuthScope(scope) {
			return apperr.ErrInvalidParams.Withf("unsupported app oauth scope %q", scope)
		}
		if _, ok := seen[scope]; ok {
			return apperr.ErrInvalidParams.Withf("duplicate app oauth scope %q", scope)
		}
		seen[scope] = struct{}{}
	}
	return nil
}

func validateUsageScope(scope string) error {
	switch normalizeUsageScope(scope) {
	case "all", "end_user", "agent":
		return nil
	default:
		return apperr.ErrInvalidParams.Withf("usage_scope must be one of all / end_user / agent")
	}
}

func normalizeUsageScope(scope string) string {
	scope = strings.TrimSpace(scope)
	if scope == "" {
		return "all"
	}
	return scope
}

func canUseInEndUserEntry(a *dom.App) bool {
	switch normalizeUsageScope(a.UsageScope) {
	case "all", "end_user":
		return true
	default:
		return false
	}
}

func canUseInAgentBinding(a *dom.App) bool {
	switch normalizeUsageScope(a.UsageScope) {
	case "all", "agent":
		return true
	default:
		return false
	}
}

// genAuthCode 生成一次性 code (32 base62); 调用方加 "ac_" 前缀拼 launch_url, 入库存 sha256 hex。
func genAuthCode() (string, error) {
	return pkgoauth2.GenRandomCode(32)
}
