// apps.go — F04 §3.3 + §3.4 客户端会话内应用列表 + 应用启动。
//
// 路由前缀 /api/agent-bus/v1/(conversations/{conv_uuid}/apps | apps/{uuid}/launch); 需要 user JWT。
package clientapps

import (
	"context"
	"encoding/json"
	"net/http"

	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	oauthjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
)

type Handlers struct {
	App       domapp.Service
	JWTSigner *oauthjwt.Signer
	Issuer    string
}

func (h *Handlers) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler) {
	mux.Handle("GET /api/agent-bus/v1/workspace/apps", auth(http.HandlerFunc(h.WorkspaceApps)))
	mux.Handle("GET /api/agent-bus/v1/conversations/{conv_uuid}/apps", auth(http.HandlerFunc(h.ListConversationApps)))
	mux.Handle("POST /api/agent-bus/v1/apps/{uuid}/launch", auth(http.HandlerFunc(h.LaunchApp)))
}

// =====================================================
// GET /conversations/{conv_uuid}/apps
// =====================================================

type convAppItem struct {
	UUID         string `json:"uuid"`
	Name         string `json:"name"`
	IconURL      string `json:"icon_url,omitempty"`
	Color        string `json:"color,omitempty"`
	DisplayMode  string `json:"display_mode"`
	CategoryUUID string `json:"category_uuid,omitempty"`
	CategoryName string `json:"category_name,omitempty"`
	BindingKind  string `json:"binding_kind"` // universal | agent_bound
	AgentUUID    string `json:"agent_uuid,omitempty"`
	SortOrder    int    `json:"sort_order"`
}

type listConvAppsResp struct {
	Apps []convAppItem `json:"apps"`
}

func (h *Handlers) ListConversationApps(w http.ResponseWriter, r *http.Request) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	convUUID := r.PathValue("conv_uuid")
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	items, err := h.App.ListConversationApps(r.Context(), domapp.ConversationAppListInput{
		ConversationUUID: convUUID,
		AccountID:        aid,
		TenantID:         tid,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	resp := listConvAppsResp{Apps: make([]convAppItem, 0, len(items))}
	for _, it := range items {
		resp.Apps = append(resp.Apps, convAppItem{
			UUID:         it.UUID,
			Name:         it.Name,
			IconURL:      it.IconURL,
			Color:        it.Color,
			DisplayMode:  it.DisplayMode,
			CategoryUUID: it.CategoryUUID,
			CategoryName: it.CategoryName,
			BindingKind:  it.BindingKind,
			AgentUUID:    it.AgentUUID,
			SortOrder:    it.SortOrder,
		})
	}
	encode.JSON(w, resp)
}

// =====================================================
// POST /apps/{uuid}/launch
// =====================================================

type launchAppReq struct {
	ConversationUUID string `json:"conversation_uuid,omitempty"`
	State            string `json:"state"`
	Nonce            string `json:"nonce,omitempty"`
}

type launchAppResp struct {
	LaunchURL   string `json:"launch_url"`
	DisplayMode string `json:"display_mode"`
	ExpiresIn   int    `json:"expires_in"`
}

func (h *Handlers) LaunchApp(w http.ResponseWriter, r *http.Request) {
	if h.App == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	var req launchAppReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if req.State == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("state required (request correlation value)"))
		return
	}
	result, err := h.App.Launch(r.Context(), domapp.LaunchInput{
		AppUUID:          uuid,
		AccountID:        aid,
		TenantID:         tid,
		ConversationUUID: req.ConversationUUID,
		State:            req.State,
		Nonce:            req.Nonce,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, launchAppResp{
		LaunchURL:   result.LaunchURL,
		DisplayMode: result.DisplayMode,
		ExpiresIn:   result.ExpiresIn,
	})
}

func (h *Handlers) WorkspaceApps(w http.ResponseWriter, r *http.Request) {
	service, ok := h.App.(interface {
		WorkspaceApps(context.Context, int64, int64) ([]map[string]any, error)
	})
	if !ok {
		encode.JSONError(w, apperr.ErrInternal)
		return
	}
	items, err := service.WorkspaceApps(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
