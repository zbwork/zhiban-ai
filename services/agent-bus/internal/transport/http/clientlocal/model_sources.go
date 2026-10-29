package clientlocal

import (
	"encoding/json"
	"net/http"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

func (h *Handlers) syncModelSources(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.Sources == nil {
		encode.JSONError(w, apperr.ErrUpstreamUnavailable)
		return
	}
	var input struct {
		Providers []dom.Config `json:"providers"`
		Partial   bool         `json:"partial"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Providers == nil {
		logpkg.Default().Warn(r.Context(), "model_sources.sync_rejected", "stage", "decode")
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	scope := dom.Scope{TenantID: middleware.MustTenantID(r.Context()), AccountID: middleware.MustAccountID(r.Context())}
	models, err := h.Sources.Sync(r.Context(), scope, input.Providers, input.Partial)
	if err != nil {
		logpkg.Default().Warn(r.Context(), "model_sources.sync_rejected", "stage", "service", "tenant_id", scope.TenantID, "account_id", scope.AccountID, "provider_count", len(input.Providers))
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("模型平台配置同步失败，请检查地址、协议、模型和密钥"))
		return
	}
	encode.JSON(w, map[string]any{"items": models})
}

// Community has no platform model whitelist: an unconfigured member gets an empty list.
func (h *Handlers) listConversationModels(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.Sources == nil {
		encode.JSON(w, map[string]any{"items": []any{}})
		return
	}
	items, _, err := h.Sources.List(r.Context(), dom.Scope{TenantID: middleware.MustTenantID(r.Context()), AccountID: middleware.MustAccountID(r.Context())})
	if err != nil {
		encode.JSONError(w, apperr.ErrUpstreamUnavailable)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
