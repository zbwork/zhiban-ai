package knowledge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
)

type managedObjectPutter interface {
	PutObject(ctx context.Context, key string, body io.Reader, contentLength int64, contentType string) error
}

func managedPerm(actor domkb.Actor, action string) string {
	if actor.ScopeKind == domkb.ScopePlatform {
		return "platform.kb." + action
	}
	return "tenant.kb." + action
}

func requireManagedActor(actor domkb.Actor, action string) error {
	if actor.AccountID <= 0 {
		return apperr.ErrUnauthorized
	}
	if actor.ScopeKind != domkb.ScopePlatform && actor.ScopeKind != domkb.ScopeTenant {
		return apperr.ErrForbidden.Withf("unsupported knowledge-base management scope")
	}
	if actor.ScopeKind == domkb.ScopeTenant && (actor.TenantID == nil || *actor.TenantID <= 0) {
		return apperr.ErrForbidden.Withf("tenant scope required")
	}
	if !hasPerm(actor.Perms, managedPerm(actor, action)) {
		return apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).
			Withf("requires %s", managedPerm(actor, action))
	}
	return nil
}

func managedTenantID(actor domkb.Actor) int64 {
	if actor.TenantID == nil {
		return 0
	}
	return *actor.TenantID
}

func mapManagedWriteErr(err error) error {
	var appErr *apperr.Error
	if errors.As(err, &appErr) {
		return appErr
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return apperr.New(apperr.Conflict, "kb.name_conflict").Withf("knowledge-base name already exists")
	}
	if errors.Is(err, apperr.ErrNotFound) || errors.Is(err, pgx.ErrNoRows) {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("knowledge base not found")
	}
	return apperr.ErrInternal.Wrap(err)
}

func (s *impl) failManagedUpload(ctx context.Context, actor domkb.Actor, kb *domkb.KnowledgeBase, doc *domkb.Document, cause error) {
	if doc == nil {
		return
	}
	_ = s.runTx(ctx, func(tx pgx.Tx) error {
		_ = s.repo.MarkDocumentFailed(ctx, tx, doc.ID, truncateErrMsg(cause.Error()))
		return s.releaseManagedQuota(ctx, tx, actor, kb, doc.FileSize)
	})
}

func (s *impl) ListManagedKnowledgeBases(ctx context.Context, actor domkb.Actor, filter ManagedKBFilter) ([]KBDTO, int, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return nil, 0, err
	}
	rows, total, err := s.repo.ListManagedKB(ctx, actor, filter.Query, filter.Status, filter.Limit, filter.Offset)
	if err != nil {
		return nil, 0, mapManagedWriteErr(err)
	}
	out := make([]KBDTO, 0, len(rows))
	for i := range rows {
		dto := s.toKBDTO(&rows[i])
		dto.CanWrite = hasPerm(actor.Perms, managedPerm(actor, "update"))
		out = append(out, dto)
	}
	return out, total, nil
}

func (s *impl) GetManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string) (*KBDTO, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	dto := s.toKBDTO(kb)
	dto.CanWrite = hasPerm(actor.Perms, managedPerm(actor, "update"))
	return &dto, nil
}

func (s *impl) CreateManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, req CreateKBReq) (*KBDTO, error) {
	if err := requireManagedActor(actor, "create"); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(req.Name)
	if len([]rune(name)) < 2 || len([]rune(name)) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("name must be 2-128 characters")
	}
	if len([]rune(req.Description)) > 500 {
		return nil, apperr.ErrInvalidParams.Withf("description too long")
	}
	providerCfg, err := s.repo.GetDefaultProvider(ctx)
	if err != nil {
		return nil, apperr.New(apperr.Conflict, ErrCodeKBProviderDegraded).Withf("default knowledge provider unavailable")
	}
	spaceKind := domkb.SpaceKindTenant
	visibility := domkb.VisibilityTenant
	accessMode := domkb.AccessModeWorkspace
	if actor.ScopeKind == domkb.ScopePlatform {
		spaceKind = domkb.SpaceKindPlatform
		visibility = domkb.VisibilityPlatform
		accessMode = domkb.AccessModeAgentOnly
	}
	provisionStatus := "active"
	if providerCfg.ProviderKind == "ragflow" {
		provisionStatus = "pending"
	}
	var created *domkb.KnowledgeBase
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		kb, err := s.repo.CreateKB(ctx, tx, domkb.CreateKBInput{
			TenantID: actor.TenantID, CreatorID: actor.AccountID,
			SpaceKind: spaceKind, Visibility: visibility, AccessMode: accessMode,
			Name: name, Description: strings.TrimSpace(req.Description),
			ProviderID: &providerCfg.ID, ProviderKind: providerCfg.ProviderKind,
			ProvisionStatus: provisionStatus,
		})
		if err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.created", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind,
			"kb_uuid": kb.UUID, "name": kb.Name,
		})
		created = kb
		return nil
	})
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	s.notify(ctx, "knowledge_bases:"+strconv.FormatInt(created.ID, 10))
	if err := s.maybeEnsureRagflowDataset(ctx, created); err != nil {
		return nil, mapProviderErr(err)
	}
	if refreshed, err := s.repo.GetKBByID(ctx, created.ID); err == nil {
		created = refreshed
	}
	dto := s.toKBDTO(created)
	dto.CanWrite = true
	return &dto, nil
}

func (s *impl) PatchManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string, req PatchKBReq) (*KBDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	in := domkb.UpdateKBInput{}
	if req.Name != nil {
		name := strings.TrimSpace(*req.Name)
		if len([]rune(name)) < 2 || len([]rune(name)) > 128 {
			return nil, apperr.ErrInvalidParams.Withf("name must be 2-128 characters")
		}
		in.Name = &name
	}
	if req.Description != nil {
		description := strings.TrimSpace(*req.Description)
		if len([]rune(description)) > 500 {
			return nil, apperr.ErrInvalidParams.Withf("description too long")
		}
		in.Description = &description
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.PatchKB(ctx, tx, kb.ID, in); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.updated", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind, "kb_uuid": kb.UUID,
		})
		return nil
	}); err != nil {
		return nil, mapManagedWriteErr(err)
	}
	updated, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	dto := s.toKBDTO(updated)
	dto.CanWrite = true
	return &dto, nil
}

func (s *impl) ManagedKnowledgeBaseReferences(ctx context.Context, actor domkb.Actor, kbUUID string) (int64, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return 0, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return 0, mapManagedWriteErr(err)
	}
	n, err := s.repo.CountActiveBindings(ctx, kb.ID)
	if err != nil {
		return 0, apperr.ErrInternal.Wrap(err)
	}
	return n, nil
}

func (s *impl) DeleteManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string) error {
	if err := requireManagedActor(actor, "delete"); err != nil {
		return err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return mapManagedWriteErr(err)
	}
	storageKeys, err := s.repo.ListDocumentStorageKeys(ctx, kb.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT id FROM knowledge_bases WHERE id=$1 AND deleted_at IS NULL FOR UPDATE`, kb.ID).Scan(&kb.ID); err != nil {
			return err
		}
		var refs int64
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM agent_kb_bindings WHERE kb_id=$1 AND deleted_at IS NULL`, kb.ID).Scan(&refs); err != nil {
			return err
		}
		if refs > 0 {
			return apperr.New(apperr.Conflict, "kb.in_use").Withf("knowledge base is referenced by %d agents", refs)
		}
		var releaseBytes int64
		var err error
		releaseBytes, err = s.repo.SumKBQuotaTrackedFileSize(ctx, tx, kb.ID)
		if err != nil {
			return err
		}
		if err := s.enqueueDeleteDatasetTx(ctx, tx, kb); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
UPDATE knowledge_bases SET status='deleting', deleted_at=now(), deleted_by=$2, updated_at=now()
 WHERE id=$1 AND deleted_at IS NULL`, kb.ID, actor.AccountID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE kb_folders SET deleted_at=now(), updated_at=now() WHERE kb_id=$1 AND deleted_at IS NULL`, kb.ID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE kb_documents SET deleted_at=now(), deleted_by=$2, updated_at=now() WHERE kb_id=$1 AND deleted_at IS NULL`, kb.ID, actor.AccountID); err != nil {
			return err
		}
		if err := s.releaseManagedQuota(ctx, tx, actor, kb, releaseBytes); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.deleted", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind, "kb_uuid": kb.UUID,
		})
		return nil
	})
	if err != nil {
		var appErr *apperr.Error
		if errors.As(err, &appErr) {
			return appErr
		}
		return mapManagedWriteErr(err)
	}
	s.notify(ctx, "knowledge_bases:"+kb.UUID)
	if s.objectStores != nil && len(storageKeys) > 0 {
		if store, resolveErr := s.objectStores.Resolve(ctx, s.managedStorageTenantID(actor)); resolveErr == nil {
			for _, key := range storageKeys {
				_ = store.Delete(ctx, key)
			}
		}
	}
	return nil
}

func (s *impl) ListManagedFolders(ctx context.Context, actor domkb.Actor, kbUUID string) ([]FolderDTO, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	rows, err := s.repo.ListFolders(ctx, kb.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]FolderDTO, 0, len(rows))
	for i := range rows {
		out = append(out, toFolderDTO(&rows[i], kb.UUID))
	}
	return out, nil
}

func (s *impl) CreateManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID string, req CreateFolderReq) (*FolderDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	name := sanitizeKBFolderName(req.Name)
	if name == "" || len([]rune(name)) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("folder name invalid")
	}
	var parent *domkb.Folder
	var parentID *int64
	if strings.TrimSpace(req.ParentUUID) != "" {
		parent, err = s.repo.GetFolderByUUID(ctx, req.ParentUUID)
		if err != nil || parent.KBID != kb.ID {
			return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("parent folder not found")
		}
		parentID = &parent.ID
	}
	var created *domkb.Folder
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, kb.ID); err != nil {
			return err
		}
		created, err = s.repo.CreateFolder(ctx, tx, kb.ID, parentID, name, buildKBFolderPath(parent, name))
		if err == nil {
			s.publishAuditTx(ctx, tx, "audit.kb.folder.created", managedTenantID(actor), map[string]any{
				"account_id": actor.AccountID, "kb_uuid": kb.UUID, "folder_uuid": created.UUID,
			})
		}
		return err
	})
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	dto := toFolderDTO(created, kb.UUID)
	return &dto, nil
}

func (s *impl) PatchManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string, req PatchFolderReq) (*FolderDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	folder, err := s.repo.GetFolderByUUID(ctx, folderUUID)
	if err != nil || folder.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("folder not found")
	}
	name := sanitizeKBFolderName(req.Name)
	if name == "" || len([]rune(name)) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("folder name invalid")
	}
	var parent *domkb.Folder
	if folder.ParentID != nil {
		rows, err := s.repo.ListFolders(ctx, kb.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		for i := range rows {
			if rows[i].ID == *folder.ParentID {
				parent = &rows[i]
				break
			}
		}
	}
	var updated *domkb.Folder
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		updated, err = s.repo.RenameFolderTree(ctx, tx, kb.ID, folder.ID, folder.Path, name, buildKBFolderPath(parent, name))
		if err == nil {
			s.publishAuditTx(ctx, tx, "audit.kb.folder.renamed", managedTenantID(actor), map[string]any{
				"account_id": actor.AccountID, "kb_uuid": kb.UUID, "folder_uuid": folder.UUID,
			})
		}
		return err
	})
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	dto := toFolderDTO(updated, kb.UUID)
	return &dto, nil
}

func (s *impl) DeleteManagedFolder(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string) error {
	if err := requireManagedActor(actor, "update"); err != nil {
		return err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return mapManagedWriteErr(err)
	}
	folder, err := s.repo.GetFolderByUUID(ctx, folderUUID)
	if err != nil || folder.KBID != kb.ID {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("folder not found")
	}
	nonEmpty, err := s.repo.FolderHasChildrenOrDocuments(ctx, folder.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if nonEmpty {
		return apperr.New(apperr.Conflict, "kb.folder_not_empty").Withf("folder is not empty")
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, kb.ID); err != nil {
			return err
		}
		if err := s.repo.SoftDeleteFolder(ctx, tx, folder.ID); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.folder.deleted", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "kb_uuid": kb.UUID, "folder_uuid": folder.UUID,
		})
		return nil
	}); err != nil {
		return mapManagedWriteErr(err)
	}
	return nil
}

func (s *impl) ListManagedDocuments(ctx context.Context, actor domkb.Actor, kbUUID, folderUUID string, limit, offset int) ([]DocumentDTO, int, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return nil, 0, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, 0, mapManagedWriteErr(err)
	}
	folderID, err := s.resolveKBFolderID(ctx, kb.ID, folderUUID)
	if err != nil {
		return nil, 0, err
	}
	rows, total, err := s.repo.ListDocumentsPagedInFolder(ctx, kb.ID, folderID, limit, offset)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	out := make([]DocumentDTO, 0, len(rows))
	for i := range rows {
		out = append(out, toDocumentDTO(&rows[i], kb.UUID))
	}
	return out, total, nil
}

func (s *impl) managedStorageTenantID(actor domkb.Actor) int64 {
	if actor.ScopeKind == domkb.ScopeTenant {
		return managedTenantID(actor)
	}
	return 0
}

func (s *impl) reserveManagedQuota(ctx context.Context, tx pgx.Tx, actor domkb.Actor, kb *domkb.KnowledgeBase, bytes int64) error {
	if actor.ScopeKind == domkb.ScopeTenant {
		return s.reserveKnowledgeQuota(ctx, tx, managedTenantID(actor), bytes)
	}
	return s.repo.ReservePlatformQuotaBytes(ctx, tx, bytes, s.cfg.PlatformQuotaBytes)
}

func (s *impl) releaseManagedQuota(ctx context.Context, tx pgx.Tx, actor domkb.Actor, kb *domkb.KnowledgeBase, bytes int64) error {
	if actor.ScopeKind == domkb.ScopeTenant {
		return s.releaseKnowledgeQuota(ctx, tx, managedTenantID(actor), bytes)
	}
	return s.repo.ReleasePlatformQuotaBytes(ctx, tx, bytes)
}

func managedDocumentStorageKey(actor domkb.Actor, kb *domkb.KnowledgeBase, docUUID, originalName string) string {
	ext := strings.ToLower(filepath.Ext(originalName))
	if len(ext) > 12 {
		ext = ""
	}
	if actor.ScopeKind == domkb.ScopePlatform {
		return "platform/knowledge/" + kb.UUID + "/" + docUUID + ext
	}
	return fmt.Sprintf("tenants/%d/knowledge/%s/%s%s", managedTenantID(actor), kb.UUID, docUUID, ext)
}

func (s *impl) UploadManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID string, req UploadDocReq) (*DocumentDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	if kb.Status != "active" || kb.ProvisionStatus != "active" {
		return nil, apperr.New(apperr.Conflict, "kb.not_ready").Withf("knowledge base is not ready")
	}
	mime := strings.ToLower(strings.TrimSpace(req.MimeType))
	if mime == "" {
		mime = "application/octet-stream"
	}
	if !isAllowedDocMIME(mime) {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocFormat).Withf("mime %q not supported", mime)
	}
	if len(req.Content) == 0 {
		return nil, apperr.ErrInvalidParams.Withf("empty document")
	}
	if int64(len(req.Content)) > s.cfg.DocMaxBytes {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeKBDocTooLarge).Withf("document too large")
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = strings.TrimSpace(req.OriginalName)
	}
	if title == "" || len([]rune(title)) > 255 {
		return nil, apperr.ErrInvalidParams.Withf("document title invalid")
	}
	folderID, err := s.resolveKBFolderID(ctx, kb.ID, req.KBFolderUUID)
	if err != nil {
		return nil, err
	}
	if req.IdempotencyKey != "" {
		if existing, err := s.repo.GetDocumentByUploadKey(ctx, kb.ID, req.IdempotencyKey, req.UploadOrdinal); err == nil {
			dto := toDocumentDTO(existing, kb.UUID)
			return &dto, nil
		} else if !errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}
	digest := sha256.Sum256(req.Content)
	shaHex := hex.EncodeToString(digest[:])
	chunks := chunkText(string(req.Content))
	var doc *domkb.Document
	err = s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.reserveManagedQuota(ctx, tx, actor, kb, int64(len(req.Content))); err != nil {
			return err
		}
		var idem *string
		var ordinal *int
		if req.IdempotencyKey != "" {
			idem = &req.IdempotencyKey
			ordinal = &req.UploadOrdinal
		}
		doc, err = s.repo.CreateDocument(ctx, tx, domkb.CreateDocumentInput{
			KBID: kb.ID, FolderID: folderID, Title: title, SourceKind: "upload", MimeType: mime,
			FileSize: int64(len(req.Content)), ChunkCount: len(chunks), Status: domkb.DocStatusIngesting,
			ContentSHA256: shaHex, OriginalName: firstNonEmpty(strings.TrimSpace(req.OriginalName), title),
			UploadIdempotencyKey: idem, UploadOrdinal: ordinal,
		})
		return err
	})
	if err != nil {
		if req.IdempotencyKey != "" {
			if existing, lookupErr := s.repo.GetDocumentByUploadKey(ctx, kb.ID, req.IdempotencyKey, req.UploadOrdinal); lookupErr == nil {
				dto := toDocumentDTO(existing, kb.UUID)
				return &dto, nil
			}
		}
		return nil, mapManagedWriteErr(err)
	}
	if s.objectStores == nil {
		s.failManagedUpload(ctx, actor, kb, doc, errors.New("object storage not wired"))
		return nil, apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object storage not wired")
	}
	store, err := s.objectStores.Resolve(ctx, s.managedStorageTenantID(actor))
	if err != nil {
		s.failManagedUpload(ctx, actor, kb, doc, err)
		return nil, apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object storage unavailable")
	}
	putter, ok := store.(managedObjectPutter)
	if !ok {
		s.failManagedUpload(ctx, actor, kb, doc, errors.New("object storage does not support upload"))
		return nil, apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object storage does not support upload")
	}
	storageKey := managedDocumentStorageKey(actor, kb, doc.UUID, firstNonEmpty(req.OriginalName, title))
	if err := putter.PutObject(ctx, storageKey, bytes.NewReader(req.Content), int64(len(req.Content)), mime); err != nil {
		s.failManagedUpload(ctx, actor, kb, doc, err)
		return nil, apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object upload failed")
	}
	if err := s.repo.UpdateDocumentStorage(ctx, doc.ID, storageKey, shaHex, firstNonEmpty(req.OriginalName, title)); err != nil {
		_ = store.Delete(ctx, storageKey)
		s.failManagedUpload(ctx, actor, kb, doc, err)
		return nil, apperr.ErrInternal.Wrap(err)
	}
	doc.StorageKey = storageKey
	doc.ContentSHA256 = shaHex
	doc.OriginalName = firstNonEmpty(req.OriginalName, title)
	dto, err := s.uploadDocumentToRagflowSync(ctx, actor.AccountID, managedTenantID(actor), kb, doc, title, mime, req.Content, len(chunks))
	if err != nil {
		return nil, err
	}
	return dto, nil
}

func (s *impl) PatchManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string, req PatchDocumentReq) (*DocumentDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil || doc.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("document not found")
	}
	title := strings.TrimSpace(req.Title)
	if title == "" || len([]rune(title)) > 255 {
		return nil, apperr.ErrInvalidParams.Withf("document title invalid")
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.UpdateDocumentTitle(ctx, tx, doc.ID, title); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.document.renamed", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind,
			"kb_uuid": kb.UUID, "document_uuid": doc.UUID,
		})
		return nil
	}); err != nil {
		return nil, mapManagedWriteErr(err)
	}
	doc.Title = title
	doc.UpdatedAt = time.Now()
	dto := toDocumentDTO(doc, kb.UUID)
	return &dto, nil
}

func (s *impl) DeleteManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) error {
	if err := requireManagedActor(actor, "update"); err != nil {
		return err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return mapManagedWriteErr(err)
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil || doc.KBID != kb.ID {
		return apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("document not found")
	}
	releaseBytes := doc.FileSize
	if !quotaTrackedDocStatus(doc.Status) {
		releaseBytes = 0
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.SoftDeleteDocument(ctx, tx, doc.ID); err != nil {
			return err
		}
		if err := s.releaseManagedQuota(ctx, tx, actor, kb, releaseBytes); err != nil {
			return err
		}
		if doc.Status == domkb.DocStatusReady {
			if err := s.repo.IncrTotalDocuments(ctx, tx, kb.ID, -1); err != nil {
				return err
			}
		}
		s.publishAuditTx(ctx, tx, "audit.kb.document.deleted", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind,
			"kb_uuid": kb.UUID, "document_uuid": doc.UUID,
		})
		return nil
	}); err != nil {
		return mapManagedWriteErr(err)
	}
	if strings.TrimSpace(doc.StorageKey) != "" && s.objectStores != nil {
		if store, err := s.objectStores.Resolve(ctx, s.managedStorageTenantID(actor)); err == nil {
			_ = store.Delete(ctx, doc.StorageKey)
		}
	}
	if err := s.provider.DeleteDocument(ctx, provider.DeleteDocumentReq{TenantID: managedTenantID(actor), KBID: kb.ID, DocumentID: doc.ID, ProviderDocID: doc.ProviderDocID}); err != nil {
		s.logger.Warn(ctx, "managed KB provider document cleanup failed", "kb_id", kb.ID, "doc_id", doc.ID, "err", err)
	}
	return nil
}

// RetryManagedDocument re-submits a failed managed document with the original
// object. Scope resolution is performed by GetManagedKBByUUID, so a platform
// operator can never retry a tenant document (and vice versa) by guessing UUIDs.
func (s *impl) RetryManagedDocument(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) (*DocumentDTO, error) {
	if err := requireManagedActor(actor, "update"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil || doc.KBID != kb.ID {
		return nil, apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("document not found")
	}
	if doc.Status != domkb.DocStatusFailed {
		return nil, apperr.ErrInvalidParams.Withf("doc status=%s, only 'failed' supports retry", doc.Status)
	}
	if strings.TrimSpace(doc.StorageKey) == "" || s.objectStores == nil {
		return nil, apperr.New(apperr.Conflict, "kb.original_unavailable").Withf("original file unavailable")
	}
	store, err := s.objectStores.Resolve(ctx, s.managedStorageTenantID(actor))
	if err != nil {
		return nil, apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object storage unavailable")
	}
	presigned, err := store.PresignGet(ctx, object.PresignGetInput{Key: doc.StorageKey, TTL: 5 * time.Minute})
	if err != nil {
		return nil, apperr.New(apperr.Conflict, "kb.original_unavailable").Withf("original file unavailable")
	}
	content, err := fetchDriveBytes(ctx, presigned.URL, s.cfg.DocMaxBytes)
	if err != nil {
		return nil, apperr.New(apperr.Conflict, "kb.original_unavailable").Withf("failed to read original file for retry")
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.reserveManagedQuota(ctx, tx, actor, kb, int64(len(content))); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE kb_documents SET status='ingesting', error_message='', updated_at=now() WHERE id=$1`, doc.ID)
		return err
	}); err != nil {
		return nil, mapManagedWriteErr(err)
	}
	chunks := chunkText(string(content))
	return s.uploadDocumentToRagflowSync(ctx, actor.AccountID, managedTenantID(actor), kb, doc, doc.Title, doc.MimeType, content, len(chunks))
}

func (s *impl) SearchManagedKnowledgeBase(ctx context.Context, actor domkb.Actor, kbUUID string, req SearchReq) (*SearchResp, error) {
	if err := requireManagedActor(actor, "recall"); err != nil {
		return nil, err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return nil, mapManagedWriteErr(err)
	}
	return s.searchResolvedKB(ctx, kb, actor.AccountID, managedTenantID(actor), req, domkb.CallerAdmin)
}

func (s *impl) ManagedDocumentDownloadURL(ctx context.Context, actor domkb.Actor, kbUUID, docUUID string) (string, error) {
	if err := requireManagedActor(actor, "read"); err != nil {
		return "", err
	}
	kb, err := s.repo.GetManagedKBByUUID(ctx, actor, kbUUID)
	if err != nil {
		return "", mapManagedWriteErr(err)
	}
	doc, err := s.repo.GetDocumentByUUID(ctx, docUUID)
	if err != nil || doc.KBID != kb.ID {
		return "", apperr.New(apperr.NotFound, ErrCodeKBNotFound).Withf("document not found")
	}
	if doc.StorageKey == "" || s.objectStores == nil {
		return "", apperr.New(apperr.Conflict, "kb.original_unavailable").Withf("original file unavailable")
	}
	store, err := s.objectStores.Resolve(ctx, s.managedStorageTenantID(actor))
	if err != nil {
		return "", apperr.New(apperr.Conflict, "kb.storage_unavailable").Withf("object storage unavailable")
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{Key: doc.StorageKey, TTL: 5 * time.Minute, Inline: false, FileName: doc.Title})
	if err != nil {
		return "", apperr.ErrInternal.Wrap(err)
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		s.publishAuditTx(ctx, tx, "audit.kb.document.downloaded", managedTenantID(actor), map[string]any{
			"account_id": actor.AccountID, "scope_kind": actor.ScopeKind,
			"kb_uuid": kb.UUID, "document_uuid": doc.UUID,
		})
		return nil
	}); err != nil {
		return "", apperr.ErrInternal.Wrap(err)
	}
	return out.URL, nil
}
