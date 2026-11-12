// api_key.go — 租户 admin 端 API Key CRUD (F01 §3.5 + M1 B2)。
//
// 路由 prefix /api/admin/v1/tenant/api-keys, 权限 tenant.api_key.read/create/update/revoke。
// 服务复用 internal/service/apikey, 与对外 /api/external/v1 的 APIKeyAuth 中间件同源。
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"

	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
)

// apiKeyDTO 列表返回; 不含 hash; 不含 secret 明文。
type apiKeyDTO struct {
	UUID       string     `json:"uuid"`
	Name       string     `json:"name"`
	KeyPrefix  string     `json:"keyPrefix"`
	Scopes     []string   `json:"scopes"`
	Status     string     `json:"status"`
	LastUsedAt *time.Time `json:"lastUsedAt,omitempty"`
	ExpiresAt  *time.Time `json:"expiresAt,omitempty"`
	CreatedAt  time.Time  `json:"createdAt"`
	UpdatedAt  time.Time  `json:"updatedAt"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

func toAPIKeyDTO(k *domapikey.ApiKey, now time.Time) apiKeyDTO {
	status := k.Status
	if status == "active" && k.ExpiresAt != nil && !k.ExpiresAt.After(now) {
		status = "expired"
	}
	return apiKeyDTO{
		UUID: k.UUID, Name: k.Name, KeyPrefix: k.KeyPrefix, Scopes: k.Scopes,
		Status: status, LastUsedAt: k.LastUsedAt, ExpiresAt: k.ExpiresAt,
		CreatedAt: k.CreatedAt, UpdatedAt: k.UpdatedAt, RevokedAt: k.RevokedAt,
	}
}

func (h *Handlers) listApiKeys(w http.ResponseWriter, r *http.Request) {
	if h.ApiKey == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("apikey service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	limit := 20
	if v := strings.TrimSpace(r.URL.Query().Get("limit")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("limit must be integer"))
			return
		}
		limit = n
	}
	offset := 0
	if v := strings.TrimSpace(r.URL.Query().Get("offset")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("offset must be integer"))
			return
		}
		offset = n
	}
	filter := domapikey.ListFilter{
		Status:  strings.TrimSpace(r.URL.Query().Get("status")),
		Keyword: strings.TrimSpace(r.URL.Query().Get("q")),
		Limit:   limit,
		Offset:  offset,
	}
	rows, total, err := h.ApiKey.List(r.Context(), tid, filter)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]apiKeyDTO, 0, len(rows))
	now := time.Now()
	for i := range rows {
		items = append(items, toAPIKeyDTO(&rows[i], now))
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

type createApiKeyReq struct {
	Name      string     `json:"name"`
	Scopes    []string   `json:"scopes"`
	ExpiresAt *time.Time `json:"expiresAt,omitempty"`
}

func (h *Handlers) createApiKey(w http.ResponseWriter, r *http.Request) {
	if h.ApiKey == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("apikey service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	creator := middleware.MustAccountID(r.Context())
	var req createApiKeyReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	row, plaintext, err := h.ApiKey.Issue(r.Context(), tid, creator, req.Name, req.Scopes, req.ExpiresAt)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 一次性返回明文 secret; 调用方必须立即保存。客户端 UI 提示 "关闭后不可见"。
	encode.JSON(w, map[string]any{
		"apiKey": toAPIKeyDTO(row, time.Now()),
		"secret": plaintext,
	})
}

type patchApiKeyReq struct {
	Name           *string    `json:"name,omitempty"`
	Scopes         []string   `json:"scopes,omitempty"`
	ExpiresAt      *time.Time `json:"expiresAt,omitempty"`
	ClearExpiresAt bool       `json:"clearExpiresAt,omitempty"`
}

func (h *Handlers) patchApiKey(w http.ResponseWriter, r *http.Request) {
	if h.ApiKey == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("apikey service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var req patchApiKeyReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	fields := map[string]any{}
	if req.Name != nil {
		fields["name"] = *req.Name
	}
	if len(req.Scopes) > 0 {
		fields["scopes"] = req.Scopes
	}
	if req.ClearExpiresAt {
		fields["expires_at"] = nil
	} else if req.ExpiresAt != nil {
		fields["expires_at"] = req.ExpiresAt
	}
	row, err := h.ApiKey.Patch(r.Context(), tid, uuid, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toAPIKeyDTO(row, time.Now()))
}

func (h *Handlers) revokeApiKey(w http.ResponseWriter, r *http.Request) {
	if h.ApiKey == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("apikey service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if err := h.ApiKey.Revoke(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "status": "revoked"})
}
