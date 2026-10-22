// apps.go — F04 §3.1 + §3.2 admin endpoints (应用 CRUD + 通用开关 + 数字员工绑定 + 分类管理)。
//
// 所有路由前缀 /api/admin/v1/tenant/(apps|agents/{uuid}/apps|app-categories)。
// 平台路由前缀 /api/admin/v1/platform/(apps|app-categories)。
// 权限闸: tenant.app.* / platform.app.*。
package adminapps

import (
	"encoding/json"
	"net/http"
	"strconv"

	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Handlers struct{ App domapp.Service }

func (h *Handlers) Register(mux *http.ServeMux, guard func(string, http.Handler) http.Handler) {
	routes := []struct {
		pattern, permission string
		handler             http.HandlerFunc
	}{
		{"POST /api/admin/v1/tenant/apps", "tenant.app.create", h.createApp},
		{"GET /api/admin/v1/tenant/apps", "tenant.app.read", h.listApps},
		{"GET /api/admin/v1/tenant/apps/{uuid}", "tenant.app.read", h.getApp},
		{"PATCH /api/admin/v1/tenant/apps/{uuid}", "tenant.app.update", h.patchApp},
		{"DELETE /api/admin/v1/tenant/apps/{uuid}", "tenant.app.delete", h.deleteApp},
		{"POST /api/admin/v1/tenant/apps/{uuid}/secret/rotate", "tenant.app.rotate_secret", h.rotateAppSecret},
		{"PATCH /api/admin/v1/tenant/apps/{uuid}/universal", "tenant.app.universal_toggle", h.setAppUniversal},
		{"PATCH /api/admin/v1/tenant/apps/{uuid}/enabled", "tenant.app.enable", h.setAppEnabled},
		{"GET /api/admin/v1/tenant/app-categories", "tenant.app.read", h.listAppCategories},
		{"POST /api/admin/v1/tenant/app-categories", "tenant.app.create", h.createAppCategory},
		{"PATCH /api/admin/v1/tenant/app-categories/{uuid}", "tenant.app.update", h.patchAppCategory},
		{"DELETE /api/admin/v1/tenant/app-categories/{uuid}", "tenant.app.delete", h.deleteAppCategory},
	}
	for _, route := range routes {
		mux.Handle(route.pattern, guard(route.permission, route.handler))
	}
}

// =====================================================
// 创建应用
// =====================================================

// 注: admin API 约定 camelCase JSON tag (跟 F01 §4.3 tenant_idp.go / api.ts 现有 convention 一致)。
// 不要跟 OAuth2 token endpoint 的 snake_case (RFC 6749 / OIDC 标准) 混 — 那是 /api/external/v1/oauth/token, 走 RFC 协议字段名。
type createAppReq struct {
	Code                   string   `json:"code"`
	Name                   string   `json:"name"`
	Description            string   `json:"description"`
	IconURL                string   `json:"iconUrl"`
	Color                  string   `json:"color"`
	DisplayMode            string   `json:"displayMode"`
	UsageScope             string   `json:"usageScope"`
	LaunchURI              string   `json:"launchUri"`
	RedirectURIs           []string `json:"redirectUris"`
	Scopes                 []string `json:"scopes"`
	CategoryUUID           string   `json:"categoryUuid,omitempty"`
	OpenToTenants          bool     `json:"openToTenants,omitempty"`
	AccessTokenTTLSeconds  int      `json:"accessTokenTtlSeconds,omitempty"`
	RefreshTokenTTLSeconds int      `json:"refreshTokenTtlSeconds,omitempty"`
}

type appResp struct {
	UUID          string `json:"uuid"`
	Code          string `json:"code"`
	Name          string `json:"name"`
	Description   string `json:"description,omitempty"`
	IconURL       string `json:"iconUrl,omitempty"`
	Color         string `json:"color,omitempty"`
	DisplayMode   string `json:"displayMode"`
	UsageScope    string `json:"usageScope"`
	LaunchURI     string `json:"launchUri"`
	CategoryUUID  string `json:"categoryUuid,omitempty"`
	SortOrder     int    `json:"sortOrder"`
	Status        string `json:"status"`
	IsSystem      bool   `json:"isSystem"`
	OpenToTenants bool   `json:"openToTenants"`
	IsUniversal   bool   `json:"isUniversal"`
	IsEnabled     bool   `json:"isEnabled"`
	CreatedAt     string `json:"createdAt"`
}

type oauthClientResp struct {
	ClientID               string   `json:"clientId"`
	ClientSecret           string   `json:"clientSecret,omitempty"` // 仅创建 / rotate 时返
	RedirectURIs           []string `json:"redirectUris"`
	Scopes                 []string `json:"scopes"`
	TokenEndpoint          string   `json:"tokenEndpoint,omitempty"`
	Issuer                 string   `json:"issuer,omitempty"`
	JWKSURI                string   `json:"jwksUri,omitempty"`
	DiscoveryURI           string   `json:"discoveryUri,omitempty"`
	AccessTokenTTLSeconds  int      `json:"accessTokenTtlSeconds"`
	RefreshTokenTTLSeconds int      `json:"refreshTokenTtlSeconds"`
	Status                 string   `json:"status"`
}

type createAppResp struct {
	App         appResp         `json:"app"`
	OAuthClient oauthClientResp `json:"oauthClient"`
}

func (h *Handlers) createApp(w http.ResponseWriter, r *http.Request) {
	h.createAppInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) createPlatformApp(w http.ResponseWriter, r *http.Request) {
	h.createAppInScope(w, r, 0)
}

func (h *Handlers) createAppInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	aid := middleware.MustAccountID(r.Context())
	var req createAppReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	categoryUUID := ""
	if req.CategoryUUID != "" {
		categoryUUID = req.CategoryUUID
	}
	result, err := h.App.CreateApp(r.Context(), tid, aid, domapp.CreateAppInput{
		Code:                   req.Code,
		Name:                   req.Name,
		Description:            req.Description,
		IconURL:                req.IconURL,
		Color:                  req.Color,
		DisplayMode:            req.DisplayMode,
		UsageScope:             req.UsageScope,
		LaunchURI:              req.LaunchURI,
		RedirectURIs:           req.RedirectURIs,
		Scopes:                 req.Scopes,
		CategoryUUID:           categoryUUID,
		OpenToTenants:          req.OpenToTenants,
		AccessTokenTTLSeconds:  req.AccessTokenTTLSeconds,
		RefreshTokenTTLSeconds: req.RefreshTokenTTLSeconds,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, createAppResp{
		App:         toAppResp(result.App, ""),
		OAuthClient: toOAuthClientRespWithSecret(result.OAuthClient, result.PlaintextSecret, result.TokenEndpoint, result.Issuer, result.JWKSURI, result.DiscoveryURI),
	})
}

// =====================================================
// 列表 / 详情
// =====================================================

func (h *Handlers) listApps(w http.ResponseWriter, r *http.Request) {
	h.listAppsInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) listPlatformApps(w http.ResponseWriter, r *http.Request) {
	h.listAppsInScope(w, r, 0)
}

func (h *Handlers) listAppsInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	filter := domapp.AppListFilter{
		Status:     r.URL.Query().Get("status"),
		Keyword:    r.URL.Query().Get("keyword"),
		UsageScope: r.URL.Query().Get("usageScope"),
	}
	filter.Limit, _ = strconv.Atoi(r.URL.Query().Get("limit"))
	filter.Offset, _ = strconv.Atoi(r.URL.Query().Get("offset"))
	if cid := r.URL.Query().Get("category_id"); cid != "" {
		if v, err := strconv.ParseInt(cid, 10, 64); err == nil {
			filter.CategoryID = &v
		}
	}
	apps, total, err := h.App.ListApps(r.Context(), tid, filter)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]appResp, 0, len(apps))
	for _, a := range apps {
		items = append(items, toAppResp(&a, ""))
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": filter.Limit, "offset": filter.Offset})
}

type appDetailResp struct {
	App         appResp          `json:"app"`
	OAuthClient *oauthClientResp `json:"oauthClient,omitempty"`
}

func (h *Handlers) getApp(w http.ResponseWriter, r *http.Request) {
	h.getAppInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) getPlatformApp(w http.ResponseWriter, r *http.Request) {
	h.getAppInScope(w, r, 0)
}

func (h *Handlers) getAppInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	a, oc, err := h.App.GetApp(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	resp := appDetailResp{App: toAppResp(a, "")}
	if oc != nil {
		c := toOAuthClientRespWithSecret(oc, "", "", "", "", "")
		resp.OAuthClient = &c
	}
	encode.JSON(w, resp)
}

// =====================================================
// PATCH / DELETE
// =====================================================

type patchAppReq struct {
	Name                   *string  `json:"name,omitempty"`
	Description            *string  `json:"description,omitempty"`
	IconURL                *string  `json:"iconUrl,omitempty"`
	Color                  *string  `json:"color,omitempty"`
	DisplayMode            *string  `json:"displayMode,omitempty"`
	UsageScope             *string  `json:"usageScope,omitempty"`
	LaunchURI              *string  `json:"launchUri,omitempty"`
	CategoryID             *int64   `json:"categoryId,omitempty"`
	CategoryUUID           *string  `json:"categoryUuid,omitempty"`
	SortOrder              *int     `json:"sortOrder,omitempty"`
	Status                 *string  `json:"status,omitempty"`
	OpenToTenants          *bool    `json:"openToTenants,omitempty"`
	RedirectURIs           []string `json:"redirectUris,omitempty"`
	Scopes                 []string `json:"scopes,omitempty"`
	AccessTokenTTLSeconds  *int     `json:"accessTokenTtlSeconds,omitempty"`
	RefreshTokenTTLSeconds *int     `json:"refreshTokenTtlSeconds,omitempty"`
}

func (h *Handlers) patchApp(w http.ResponseWriter, r *http.Request) {
	h.patchAppInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) patchPlatformApp(w http.ResponseWriter, r *http.Request) {
	h.patchAppInScope(w, r, 0)
}

func (h *Handlers) patchAppInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	var req patchAppReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	fields := map[string]any{}
	if req.Name != nil {
		fields["name"] = *req.Name
	}
	if req.Description != nil {
		fields["description"] = *req.Description
	}
	if req.IconURL != nil {
		fields["icon_url"] = *req.IconURL
	}
	if req.Color != nil {
		fields["color"] = *req.Color
	}
	if req.DisplayMode != nil {
		fields["display_mode"] = *req.DisplayMode
	}
	if req.UsageScope != nil {
		fields["usage_scope"] = *req.UsageScope
	}
	if req.LaunchURI != nil {
		fields["launch_uri"] = *req.LaunchURI
	}
	if req.CategoryID != nil {
		fields["category_id"] = *req.CategoryID
	}
	if req.CategoryUUID != nil {
		fields["category_uuid"] = *req.CategoryUUID
	}
	if req.SortOrder != nil {
		fields["sort_order"] = *req.SortOrder
	}
	if req.Status != nil {
		fields["status"] = *req.Status
	}
	if req.OpenToTenants != nil {
		fields["open_to_tenants"] = *req.OpenToTenants
	}
	if req.RedirectURIs != nil {
		fields["oauth_redirect_uris"] = req.RedirectURIs
	}
	if req.Scopes != nil {
		fields["oauth_scopes"] = req.Scopes
	}
	if req.AccessTokenTTLSeconds != nil {
		fields["oauth_access_token_ttl_seconds"] = *req.AccessTokenTTLSeconds
	}
	if req.RefreshTokenTTLSeconds != nil {
		fields["oauth_refresh_token_ttl_seconds"] = *req.RefreshTokenTTLSeconds
	}
	a, err := h.App.PatchApp(r.Context(), tid, uuid, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toAppResp(a, ""))
}

func (h *Handlers) deleteApp(w http.ResponseWriter, r *http.Request) {
	h.deleteAppInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) deletePlatformApp(w http.ResponseWriter, r *http.Request) {
	h.deleteAppInScope(w, r, 0)
}

func (h *Handlers) deleteAppInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if err := h.App.DeleteApp(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

// =====================================================
// Secret rotate
// =====================================================

type rotateSecretResp struct {
	ClientSecret string `json:"clientSecret"`
}

func (h *Handlers) rotateAppSecret(w http.ResponseWriter, r *http.Request) {
	h.rotateAppSecretInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) rotatePlatformAppSecret(w http.ResponseWriter, r *http.Request) {
	h.rotateAppSecretInScope(w, r, 0)
}

func (h *Handlers) rotateAppSecretInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	plaintext, err := h.App.RotateSecret(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, rotateSecretResp{ClientSecret: plaintext})
}

type launchTestResp struct {
	UUID        string `json:"uuid"`
	LaunchURL   string `json:"launchUrl"`
	DisplayMode string `json:"displayMode"`
	Status      string `json:"status"`
}

func (h *Handlers) launchTestApp(w http.ResponseWriter, r *http.Request) {
	h.launchTestAppInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) launchTestPlatformApp(w http.ResponseWriter, r *http.Request) {
	h.launchTestAppInScope(w, r, 0)
}

func (h *Handlers) launchTestAppInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	a, oc, err := h.App.GetApp(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if a.Status != "active" {
		encode.JSONError(w, apperr.ErrConflict.Withf("app status=%s", a.Status))
		return
	}
	if oc == nil || oc.Status != "active" {
		encode.JSONError(w, apperr.ErrConflict.Withf("oauth client not active"))
		return
	}
	encode.JSON(w, launchTestResp{
		UUID:        a.UUID,
		LaunchURL:   a.LaunchURI,
		DisplayMode: a.DisplayMode,
		Status:      "ready",
	})
}

// =====================================================
// Universal toggle / Enabled toggle
// =====================================================

type universalReq struct {
	IsUniversal bool `json:"isUniversal"`
	SortOrder   int  `json:"sortOrder"`
}

func (h *Handlers) setAppUniversal(w http.ResponseWriter, r *http.Request) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var req universalReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.App.SetUniversal(r.Context(), tid, uuid, req.IsUniversal, req.SortOrder); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "isUniversal": req.IsUniversal})
}

type enabledReq struct {
	IsEnabled bool `json:"isEnabled"`
}

func (h *Handlers) setAppEnabled(w http.ResponseWriter, r *http.Request) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var req enabledReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if err := h.App.SetEnabled(r.Context(), tid, uuid, req.IsEnabled); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "isEnabled": req.IsEnabled})
}

// =====================================================
// 数字员工挂应用
// =====================================================

type categoryResp struct {
	UUID      string `json:"uuid"`
	Code      string `json:"code"`
	Name      string `json:"name"`
	SortOrder int    `json:"sortOrder"`
	IsSystem  bool   `json:"isSystem"`
}

func toCategoryResp(c *domapp.Category) categoryResp {
	return categoryResp{
		UUID: c.UUID, Code: c.Code, Name: c.Name,
		SortOrder: c.SortOrder, IsSystem: c.IsSystem,
	}
}

func (h *Handlers) listAppCategories(w http.ResponseWriter, r *http.Request) {
	h.listAppCategoriesInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) listPlatformAppCategories(w http.ResponseWriter, r *http.Request) {
	h.listAppCategoriesInScope(w, r, 0)
}

func (h *Handlers) listAppCategoriesInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	cats, total, err := h.App.ListCategories(r.Context(), tid, limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]categoryResp, 0, len(cats))
	for _, c := range cats {
		items = append(items, toCategoryResp(&c))
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

type createCategoryReq struct {
	Code      string `json:"code"`
	Name      string `json:"name"`
	SortOrder int    `json:"sortOrder"`
}

func (h *Handlers) createAppCategory(w http.ResponseWriter, r *http.Request) {
	h.createAppCategoryInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) createPlatformAppCategory(w http.ResponseWriter, r *http.Request) {
	h.createAppCategoryInScope(w, r, 0)
}

func (h *Handlers) createAppCategoryInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	var req createCategoryReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if req.Code == "" || req.Name == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("code/name required"))
		return
	}
	c, err := h.App.CreateCategory(r.Context(), tid, req.Code, req.Name, req.SortOrder)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toCategoryResp(c))
}

type patchCategoryReq struct {
	Code      *string `json:"code,omitempty"`
	Name      *string `json:"name,omitempty"`
	SortOrder *int    `json:"sortOrder,omitempty"`
}

func (h *Handlers) patchAppCategory(w http.ResponseWriter, r *http.Request) {
	h.patchAppCategoryInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) patchPlatformAppCategory(w http.ResponseWriter, r *http.Request) {
	h.patchAppCategoryInScope(w, r, 0)
}

func (h *Handlers) patchAppCategoryInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	var req patchCategoryReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	fields := map[string]any{}
	if req.Code != nil {
		fields["code"] = *req.Code
	}
	if req.Name != nil {
		fields["name"] = *req.Name
	}
	if req.SortOrder != nil {
		fields["sort_order"] = *req.SortOrder
	}
	c, err := h.App.PatchCategory(r.Context(), tid, uuid, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toCategoryResp(c))
}

func (h *Handlers) deleteAppCategory(w http.ResponseWriter, r *http.Request) {
	h.deleteAppCategoryInScope(w, r, middleware.MustTenantID(r.Context()))
}

func (h *Handlers) deletePlatformAppCategory(w http.ResponseWriter, r *http.Request) {
	h.deleteAppCategoryInScope(w, r, 0)
}

func (h *Handlers) deleteAppCategoryInScope(w http.ResponseWriter, r *http.Request, tid int64) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if err := h.App.DeleteCategory(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

// =====================================================
// 转换 helper
// =====================================================

func toAppResp(a *domapp.App, _ string) appResp {
	return appResp{
		UUID:          a.UUID,
		Code:          a.Code,
		Name:          a.Name,
		Description:   a.Description,
		IconURL:       a.IconURL,
		Color:         a.Color,
		DisplayMode:   a.DisplayMode,
		UsageScope:    a.UsageScope,
		LaunchURI:     a.LaunchURI,
		CategoryUUID:  a.CategoryUUID,
		SortOrder:     a.SortOrder,
		Status:        a.Status,
		IsSystem:      a.IsSystem,
		OpenToTenants: a.OpenToTenants,
		IsUniversal:   a.IsUniversal,
		IsEnabled:     a.IsEnabled,
		CreatedAt:     a.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

func toOAuthClientRespWithSecret(oc *domapp.OAuthClient, plaintext, tokenEndpoint, issuer, jwks, discovery string) oauthClientResp {
	return oauthClientResp{
		ClientID:               oc.ClientID,
		ClientSecret:           plaintext,
		RedirectURIs:           oc.RedirectURIs,
		Scopes:                 oc.Scopes,
		TokenEndpoint:          tokenEndpoint,
		Issuer:                 issuer,
		JWKSURI:                jwks,
		DiscoveryURI:           discovery,
		AccessTokenTTLSeconds:  oc.AccessTokenTTLSeconds,
		RefreshTokenTTLSeconds: oc.RefreshTokenTTLSeconds,
		Status:                 oc.Status,
	}
}
