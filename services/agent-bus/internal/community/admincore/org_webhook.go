// org_webhook.go — tenant admin org-sync webhook management.
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	domorgwebhook "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orgwebhook"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type orgWebhookDTO struct {
	UUID           string                 `json:"uuid"`
	Name           string                 `json:"name"`
	CallbackURL    string                 `json:"callbackUrl"`
	Enabled        bool                   `json:"enabled"`
	EventTypes     []string               `json:"eventTypes"`
	Description    string                 `json:"description,omitempty"`
	CreatedAt      time.Time              `json:"createdAt"`
	UpdatedAt      time.Time              `json:"updatedAt"`
	LatestDelivery *orgWebhookDeliveryDTO `json:"latestDelivery,omitempty"`
	HasSecret      bool                   `json:"hasSecret"`
}

type orgWebhookDeliveryDTO struct {
	ID          int64      `json:"id"`
	EventType   string     `json:"eventType"`
	CallbackURL string     `json:"callbackUrl"`
	Status      string     `json:"status"`
	Attempts    int        `json:"attempts"`
	NextRetryAt *time.Time `json:"nextRetryAt,omitempty"`
	LastError   string     `json:"lastError,omitempty"`
	DoneAt      *time.Time `json:"doneAt,omitempty"`
	CreatedAt   time.Time  `json:"createdAt"`
}

func toOrgWebhookDTO(c domorgwebhook.Config) orgWebhookDTO {
	dto := orgWebhookDTO{
		UUID:        c.UUID,
		Name:        c.Name,
		CallbackURL: c.CallbackURL,
		Enabled:     c.Enabled,
		EventTypes:  append([]string(nil), c.EventTypes...),
		Description: c.Description,
		CreatedAt:   c.CreatedAt,
		UpdatedAt:   c.UpdatedAt,
		HasSecret:   c.SigningSecret != "",
	}
	if c.LatestDelivery != nil {
		d := toOrgWebhookDeliveryDTO(*c.LatestDelivery)
		dto.LatestDelivery = &d
	}
	return dto
}

func toOrgWebhookDeliveryDTO(d domorgwebhook.Delivery) orgWebhookDeliveryDTO {
	return orgWebhookDeliveryDTO{
		ID:          d.ID,
		EventType:   d.EventType,
		CallbackURL: d.CallbackURL,
		Status:      d.Status,
		Attempts:    d.Attempts,
		NextRetryAt: d.NextRetryAt,
		LastError:   d.LastError,
		DoneAt:      d.DoneAt,
		CreatedAt:   d.CreatedAt,
	}
}

func (h *Handlers) listOrgWebhooks(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	rows, err := h.OrgWebhook.List(r.Context(), middleware.MustTenantID(r.Context()))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]orgWebhookDTO, 0, len(rows))
	for _, row := range rows {
		items = append(items, toOrgWebhookDTO(row))
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

type createOrgWebhookReq struct {
	Name        string   `json:"name"`
	CallbackURL string   `json:"callbackUrl"`
	Enabled     *bool    `json:"enabled,omitempty"`
	EventTypes  []string `json:"eventTypes"`
	Description string   `json:"description,omitempty"`
}

func (h *Handlers) createOrgWebhook(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	var req createOrgWebhookReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	row, secret, err := h.OrgWebhook.Create(r.Context(), middleware.MustTenantID(r.Context()), domorgwebhook.CreateInput{
		Name:        req.Name,
		CallbackURL: req.CallbackURL,
		Enabled:     enabled,
		EventTypes:  req.EventTypes,
		Description: req.Description,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"webhook": toOrgWebhookDTO(*row), "secret": secret})
}

type patchOrgWebhookReq struct {
	Name        *string  `json:"name,omitempty"`
	CallbackURL *string  `json:"callbackUrl,omitempty"`
	Enabled     *bool    `json:"enabled,omitempty"`
	EventTypes  []string `json:"eventTypes,omitempty"`
	Description *string  `json:"description,omitempty"`
}

func (h *Handlers) patchOrgWebhook(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	var req patchOrgWebhookReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	row, err := h.OrgWebhook.Patch(r.Context(), middleware.MustTenantID(r.Context()), r.PathValue("uuid"), domorgwebhook.PatchInput{
		Name:        req.Name,
		CallbackURL: req.CallbackURL,
		Enabled:     req.Enabled,
		EventTypes:  req.EventTypes,
		Description: req.Description,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toOrgWebhookDTO(*row))
}

func (h *Handlers) deleteOrgWebhook(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if err := h.OrgWebhook.Delete(r.Context(), middleware.MustTenantID(r.Context()), uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

func (h *Handlers) rotateOrgWebhookSecret(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	row, secret, err := h.OrgWebhook.RotateSecret(r.Context(), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"webhook": toOrgWebhookDTO(*row), "secret": secret})
}

func (h *Handlers) testOrgWebhook(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	result, err := h.OrgWebhook.Test(r.Context(), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, result)
}

func (h *Handlers) listOrgWebhookDeliveries(w http.ResponseWriter, r *http.Request) {
	if h.OrgWebhook == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("org webhook service not wired"))
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	rows, err := h.OrgWebhook.ListDeliveries(r.Context(), middleware.MustTenantID(r.Context()), r.PathValue("uuid"), limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]orgWebhookDeliveryDTO, 0, len(rows))
	for _, row := range rows {
		items = append(items, toOrgWebhookDeliveryDTO(row))
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}
