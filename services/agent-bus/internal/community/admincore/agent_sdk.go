// agent_sdk.go — 租户 admin 端 Agent SDK 凭证 CRUD (F01 §3.6 + M2)。
//
// 路由 /api/admin/v1/tenant/agent-sdk-credentials, 权限 tenant.agent_sdk.read/create/update/revoke。
// 创建时返回 client_id + 一次性明文 client_secret; 关闭后不可恢复。
package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AgentSDKRuntimeChecker 校验某 runtime_registration_id 是否对本租户可见 (codex challenge #8)。
//
// 通过条件:
//   - runtime 存在, 且 (Env.OwnerTenantID IS NULL  → 平台 runtime, 全局可见)
//     OR  (Env.OwnerTenantID == tenantID → 本租户自定义 runtime)
type AgentSDKRuntimeChecker interface {
	IsVisibleForTenant(ctx context.Context, runtimeRegistrationID, tenantID int64) (bool, error)
	IsPlatformCredentialTarget(ctx context.Context, runtimeEnvironmentID int64) (bool, error)
}

type agentSDKCredDTO struct {
	UUID                 string     `json:"uuid"`
	Name                 string     `json:"name"`
	ClientID             string     `json:"clientId"`
	CapabilityBindings   []string   `json:"capabilityBindings"`
	RuntimeEnvironmentID *int64     `json:"runtimeRegistrationId,omitempty"`
	Scope                string     `json:"scope"`
	TenantGrantMode      string     `json:"tenantGrantMode,omitempty"`
	AllowedTenantIDs     []int64    `json:"allowedTenantIds,omitempty"`
	Status               string     `json:"status"`
	LastUsedAt           *time.Time `json:"lastUsedAt,omitempty"`
	CreatedAt            time.Time  `json:"createdAt"`
	UpdatedAt            time.Time  `json:"updatedAt"`
	RevokedAt            *time.Time `json:"revokedAt,omitempty"`
}

func toAgentSDKCredDTO(c *domagentsdk.Credential) agentSDKCredDTO {
	return agentSDKCredDTO{
		UUID: c.UUID, Name: c.Name, ClientID: c.ClientID,
		CapabilityBindings:   c.CapabilityBindings,
		RuntimeEnvironmentID: c.RuntimeEnvironmentID,
		Scope:                c.Scope,
		TenantGrantMode:      c.TenantGrantMode,
		AllowedTenantIDs:     c.AllowedTenantIDs,
		Status:               c.Status, LastUsedAt: c.LastUsedAt,
		CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt, RevokedAt: c.RevokedAt,
	}
}

func (h *Handlers) listAgentSDKCredentials(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	rows, err := h.AgentSDK.ListCredentials(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]agentSDKCredDTO, 0, len(rows))
	for i := range rows {
		items = append(items, toAgentSDKCredDTO(&rows[i]))
	}
	encode.JSON(w, map[string]any{"items": items})
}

type createAgentSDKReq struct {
	Name                 string   `json:"name"`
	CapabilityBindings   []string `json:"capabilityBindings"`
	RuntimeEnvironmentID *int64   `json:"runtimeRegistrationId,omitempty"`
}

func (h *Handlers) createAgentSDKCredential(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	creator := middleware.MustAccountID(r.Context())
	var req createAgentSDKReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	// codex challenge #8: runtime_registration_id 必须对本租户可见, 否则 admin 能引用别租户 runtime。
	if req.RuntimeEnvironmentID != nil && h.RuntimeChecker != nil {
		ok, err := h.RuntimeChecker.IsVisibleForTenant(r.Context(), *req.RuntimeEnvironmentID, tid)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		if !ok {
			encode.JSONError(w, apperr.ErrForbidden.Withf("runtime_registration_id %d not visible for tenant", *req.RuntimeEnvironmentID))
			return
		}
	}
	row, plaintext, err := h.AgentSDK.IssueCredential(r.Context(), tid, creator, req.Name, req.CapabilityBindings, req.RuntimeEnvironmentID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"credential":   toAgentSDKCredDTO(row),
		"clientSecret": plaintext,
	})
}

func (h *Handlers) listPlatformAgentSDKCredentials(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	rows, err := h.AgentSDK.ListPlatformCredentials(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]agentSDKCredDTO, 0, len(rows))
	for i := range rows {
		items = append(items, toAgentSDKCredDTO(&rows[i]))
	}
	encode.JSON(w, map[string]any{"items": items})
}

type createPlatformAgentSDKReq struct {
	Name                 string   `json:"name"`
	CapabilityBindings   []string `json:"capabilityBindings"`
	RuntimeEnvironmentID int64    `json:"runtimeEnvironmentId"`
	TenantGrantMode      string   `json:"tenantGrantMode"`
	AllowedTenantIDs     []int64  `json:"allowedTenantIds"`
}

func (h *Handlers) createPlatformAgentSDKCredential(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	creator := middleware.MustAccountID(r.Context())
	var req createPlatformAgentSDKReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if req.RuntimeEnvironmentID <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("runtime_environment_id required"))
		return
	}
	if h.RuntimeChecker != nil {
		ok, err := h.RuntimeChecker.IsPlatformCredentialTarget(r.Context(), req.RuntimeEnvironmentID)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		if !ok {
			encode.JSONError(w, apperr.ErrForbidden.Withf("runtime_environment_id %d is not a platform runtime credential target", req.RuntimeEnvironmentID))
			return
		}
	}
	row, plaintext, err := h.AgentSDK.IssuePlatformCredential(r.Context(), creator, req.Name, req.CapabilityBindings, req.RuntimeEnvironmentID, req.TenantGrantMode, req.AllowedTenantIDs)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"credential":   toAgentSDKCredDTO(row),
		"clientSecret": plaintext,
	})
}

type patchAgentSDKReq struct {
	Name               *string  `json:"name,omitempty"`
	CapabilityBindings []string `json:"capabilityBindings,omitempty"`
}

func (h *Handlers) patchAgentSDKCredential(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var req patchAgentSDKReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	fields := map[string]any{}
	if req.Name != nil {
		fields["name"] = *req.Name
	}
	if len(req.CapabilityBindings) > 0 {
		fields["capability_bindings"] = req.CapabilityBindings
	}
	row, err := h.AgentSDK.PatchCredential(r.Context(), tid, uuid, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toAgentSDKCredDTO(row))
}

func (h *Handlers) revokeAgentSDKCredential(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if err := h.AgentSDK.RevokeCredential(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "status": "revoked"})
}

func (h *Handlers) revokePlatformAgentSDKCredential(w http.ResponseWriter, r *http.Request) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if err := h.AgentSDK.RevokePlatformCredential(r.Context(), uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "status": "revoked"})
}
