package admincore

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/google/uuid"
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

const managedKBMultipartLimit = 64 << 20

func (h *Handlers) managedKnowledgeService() (svckb.AdminManager, error) {
	manager, ok := h.Knowledge.(svckb.AdminManager)
	if !ok || manager == nil {
		return nil, apperr.ErrInternal.Withf("knowledge management service not wired")
	}
	return manager, nil
}

func managedKnowledgeActor(r *http.Request, scope domkb.ScopeKind) (domkb.Actor, error) {
	claims, ok := middleware.Claims(r.Context())
	if !ok || claims == nil {
		return domkb.Actor{}, apperr.ErrUnauthorized
	}
	actor := domkb.Actor{
		AccountID: middleware.MustAccountID(r.Context()),
		ScopeKind: scope,
		Perms:     append([]string(nil), claims.Perms...),
	}
	if scope == domkb.ScopeTenant {
		tenantID := middleware.MustTenantID(r.Context())
		if tenantID <= 0 {
			return domkb.Actor{}, apperr.ErrForbidden.Withf("tenant scope required")
		}
		actor.TenantID = &tenantID
	}
	return actor, nil
}

func decodeManagedJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return false
	}
	return true
}

func managedUploadErrorMessage(err error) string {
	if appError, ok := apperr.AsError(err); ok && appError.HTTPStatus() < http.StatusInternalServerError {
		return appError.Message
	}
	return "上传失败，请稍后重试"
}

func (h *Handlers) listManagedKnowledgeBases(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		limit, offset, err := parseLimitOffset(r)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		items, total, err := manager.ListManagedKnowledgeBases(r.Context(), actor, svckb.ManagedKBFilter{
			Query: r.URL.Query().Get("q"), Status: r.URL.Query().Get("status"), Limit: limit, Offset: offset,
		})
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
	}
}

func (h *Handlers) getManagedKnowledgeBase(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		item, err := manager.GetManagedKnowledgeBase(r.Context(), actor, r.PathValue("uuid"))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) createManagedKnowledgeBase(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.CreateKBReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		item, err := manager.CreateManagedKnowledgeBase(r.Context(), actor, req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) patchManagedKnowledgeBase(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.PatchKBReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		item, err := manager.PatchManagedKnowledgeBase(r.Context(), actor, r.PathValue("uuid"), req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) deleteManagedKnowledgeBase(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		if err := manager.DeleteManagedKnowledgeBase(r.Context(), actor, r.PathValue("uuid")); err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"deleted": true})
	}
}

func (h *Handlers) managedKnowledgeBaseReferences(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		count, err := manager.ManagedKnowledgeBaseReferences(r.Context(), actor, r.PathValue("uuid"))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"active_agent_count": count})
	}
}

func (h *Handlers) recallManagedKnowledgeBase(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.SearchReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		resp, err := manager.SearchManagedKnowledgeBase(r.Context(), actor, r.PathValue("uuid"), req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, resp)
	}
}

func (h *Handlers) listManagedFolders(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		items, err := manager.ListManagedFolders(r.Context(), actor, r.PathValue("uuid"))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"items": items, "total": len(items)})
	}
}

func (h *Handlers) createManagedFolder(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.CreateFolderReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		item, err := manager.CreateManagedFolder(r.Context(), actor, r.PathValue("uuid"), req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) patchManagedFolder(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.PatchFolderReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		item, err := manager.PatchManagedFolder(r.Context(), actor, r.PathValue("uuid"), r.PathValue("folder_uuid"), req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) deleteManagedFolder(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		if err := manager.DeleteManagedFolder(r.Context(), actor, r.PathValue("uuid"), r.PathValue("folder_uuid")); err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"deleted": true})
	}
}

func (h *Handlers) listManagedDocuments(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		limit, offset, err := parseLimitOffset(r)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		items, total, err := manager.ListManagedDocuments(r.Context(), actor, r.PathValue("uuid"), r.URL.Query().Get("folder_uuid"), limit, offset)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
	}
}

func (h *Handlers) uploadManagedDocuments(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, managedKBMultipartLimit)
		if err := r.ParseMultipartForm(managedKBMultipartLimit); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid or oversized multipart upload"))
			return
		}
		files := r.MultipartForm.File["files"]
		if len(files) == 0 {
			files = r.MultipartForm.File["file"]
		}
		if len(files) == 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("files required"))
			return
		}
		if len(files) > 20 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("at most 20 files per upload"))
			return
		}
		idempotencyKey := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
		if idempotencyKey == "" {
			idempotencyKey = uuid.NewString()
		}
		if _, err := uuid.Parse(idempotencyKey); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("Idempotency-Key must be UUID"))
			return
		}
		folderUUID := strings.TrimSpace(r.FormValue("folder_uuid"))
		items := make([]svckb.DocumentDTO, 0, len(files))
		failures := make([]map[string]string, 0)
		for ordinal, header := range files {
			f, err := header.Open()
			if err != nil {
				failures = append(failures, map[string]string{"filename": header.Filename, "error": "无法读取文件"})
				continue
			}
			content, readErr := io.ReadAll(f)
			_ = f.Close()
			if readErr != nil {
				failures = append(failures, map[string]string{"filename": header.Filename, "error": "读取文件失败"})
				continue
			}
			mime := header.Header.Get("Content-Type")
			if mime == "" {
				mime = http.DetectContentType(content)
			}
			item, err := manager.UploadManagedDocument(r.Context(), actor, r.PathValue("uuid"), svckb.UploadDocReq{
				Title: header.Filename, OriginalName: header.Filename, MimeType: mime, Content: content,
				KBFolderUUID: folderUUID, IdempotencyKey: idempotencyKey, UploadOrdinal: ordinal,
			})
			if err != nil {
				failures = append(failures, map[string]string{"filename": header.Filename, "error": managedUploadErrorMessage(err)})
				continue
			}
			items = append(items, *item)
		}
		encode.JSON(w, map[string]any{"items": items, "total": len(items), "failures": failures, "idempotency_key": idempotencyKey})
	}
}

func (h *Handlers) patchManagedDocument(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		var req svckb.PatchDocumentReq
		if !decodeManagedJSON(w, r, &req) {
			return
		}
		item, err := manager.PatchManagedDocument(r.Context(), actor, r.PathValue("uuid"), r.PathValue("document_uuid"), req)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) deleteManagedDocument(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		if err := manager.DeleteManagedDocument(r.Context(), actor, r.PathValue("uuid"), r.PathValue("document_uuid")); err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"deleted": true})
	}
}

func (h *Handlers) retryManagedDocument(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		item, err := manager.RetryManagedDocument(r.Context(), actor, r.PathValue("uuid"), r.PathValue("document_uuid"))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, item)
	}
}

func (h *Handlers) managedDocumentDownload(scope domkb.ScopeKind) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		manager, err := h.managedKnowledgeService()
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		actor, err := managedKnowledgeActor(r, scope)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		url, err := manager.ManagedDocumentDownloadURL(r.Context(), actor, r.PathValue("uuid"), r.PathValue("document_uuid"))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"url": url})
	}
}

func parseLimitOffset(r *http.Request) (limit, offset int, err error) {
	limit, offset = 20, 0
	if s := strings.TrimSpace(r.URL.Query().Get("limit")); s != "" {
		limit, err = strconv.Atoi(s)
		if err != nil || limit < 1 {
			return 0, 0, fmt.Errorf("limit must be a positive integer")
		}
		if limit > 200 {
			limit = 200
		}
	}
	if s := strings.TrimSpace(r.URL.Query().Get("offset")); s != "" {
		offset, err = strconv.Atoi(s)
		if err != nil || offset < 0 {
			return 0, 0, fmt.Errorf("offset must be a non-negative integer")
		}
	}
	return limit, offset, nil
}

var bindingStatusSet = map[string]bool{
	"pending": true, "active": true, "failed": true, "deactivated": true, "pending_cleanup": true,
}
