// drive_storage.go — /api/admin/v1/{platform|tenant}/drive/storage-* handlers.
// (M7 Phase B sprint, docs/tasks/sprint-m7m8-drive-s3-kb-dify.md §3.1)
package admincore

import (
	"context"
	"encoding/json"
	"net/http"

	domdrivev3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcstorage "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/storage"
)

// StorageAdminService — admin handler 的窄抽象.
type StorageAdminService interface {
	ListDefaults(ctx context.Context) ([]svcstorage.PresentDefault, error)
	CreateDefault(ctx context.Context, in svcstorage.CreateDefaultInput) (*svcstorage.PresentDefault, error)
	PatchDefault(ctx context.Context, uuid string, fields map[string]any) error
	DeleteDefault(ctx context.Context, uuid string) error
	SetDefault(ctx context.Context, uuid string) error
	TestConnectionDefault(ctx context.Context, uuid string) (string, error)

	GetTenantOverride(ctx context.Context, tenantID int64) (*domdrivev3.StorageOverride, error)
	UpsertTenantOverride(ctx context.Context, o *domdrivev3.StorageOverride) error
	DeleteTenantOverride(ctx context.Context, tenantID int64) error
	TestConnectionOverride(ctx context.Context, tenantID int64) (string, error)
}

// ===== platform =====

func (h *Handlers) listStorageDefaults(w http.ResponseWriter, r *http.Request) {
	items, err := h.DriveStorage.ListDefaults(r.Context())
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) createStorageDefault(w http.ResponseWriter, r *http.Request) {
	var in svcstorage.CreateDefaultInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.DriveStorage.CreateDefault(r.Context(), in)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) patchStorageDefault(w http.ResponseWriter, r *http.Request) {
	uuid := r.PathValue("uuid")
	var fields map[string]any
	if err := json.NewDecoder(r.Body).Decode(&fields); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	// 防御: 不允许通过 PATCH 直接翻 is_default / deleted_at.
	delete(fields, "is_default")
	delete(fields, "deleted_at")
	delete(fields, "uuid")
	delete(fields, "id")
	if err := h.DriveStorage.PatchDefault(r.Context(), uuid, fields); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (h *Handlers) deleteStorageDefault(w http.ResponseWriter, r *http.Request) {
	if err := h.DriveStorage.DeleteDefault(r.Context(), r.PathValue("uuid")); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (h *Handlers) setStorageDefault(w http.ResponseWriter, r *http.Request) {
	if err := h.DriveStorage.SetDefault(r.Context(), r.PathValue("uuid")); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (h *Handlers) testStorageDefault(w http.ResponseWriter, r *http.Request) {
	status, err := h.DriveStorage.TestConnectionDefault(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSON(w, map[string]any{"status": "degraded", "message": err.Error()})
		return
	}
	encode.JSON(w, map[string]any{"status": status})
}

// ===== tenant =====

func (h *Handlers) getTenantStorageOverride(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	ov, err := h.DriveStorage.GetTenantOverride(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if ov == nil {
		encode.JSON(w, map[string]any{"exists": false})
		return
	}
	encode.JSON(w, presentOverride(ov))
}

func (h *Handlers) putTenantStorageOverride(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	var in struct {
		DefaultID          *int64  `json:"default_id"`
		Region             *string `json:"region"`
		Endpoint           *string `json:"endpoint"`
		ReadEndpoint       *string `json:"read_endpoint"`
		Bucket             *string `json:"bucket"`
		AccessKeySecretRef *string `json:"access_key_secret_ref"`
		SecretKeySecretRef *string `json:"secret_key_secret_ref"`
		Status             string  `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	o := &domdrivev3.StorageOverride{
		TenantID:           tid,
		DefaultID:          in.DefaultID,
		Region:             in.Region,
		Endpoint:           in.Endpoint,
		ReadEndpoint:       in.ReadEndpoint,
		Bucket:             in.Bucket,
		AccessKeySecretRef: in.AccessKeySecretRef,
		SecretKeySecretRef: in.SecretKeySecretRef,
		Status:             domdrivev3.StorageStatus(in.Status),
	}

	if err := h.DriveStorage.UpsertTenantOverride(r.Context(), o); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (h *Handlers) deleteTenantStorageOverride(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	if err := h.DriveStorage.DeleteTenantOverride(r.Context(), tid); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (h *Handlers) testTenantStorageOverride(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	status, err := h.DriveStorage.TestConnectionOverride(r.Context(), tid)
	if err != nil {
		encode.JSON(w, map[string]any{"status": "degraded", "message": err.Error()})
		return
	}
	encode.JSON(w, map[string]any{"status": status})
}

func presentOverride(o *domdrivev3.StorageOverride) map[string]any {
	get := func(s *string) string {
		if s == nil {
			return ""
		}
		return *s
	}
	getInt := func(i *int64) any {
		return i
	}
	return map[string]any{
		"exists":                true,
		"tenant_id":             o.TenantID,
		"default_id":            getInt(o.DefaultID),
		"region":                get(o.Region),
		"endpoint":              get(o.Endpoint),
		"read_endpoint":         get(o.ReadEndpoint),
		"bucket":                get(o.Bucket),
		"access_key_secret_ref": get(o.AccessKeySecretRef),
		"secret_key_secret_ref": get(o.SecretKeySecretRef),
		"status":                string(o.Status),
		"created_at":            o.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		"updated_at":            o.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}
