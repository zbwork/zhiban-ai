package favorite

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/favorite"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	svcknowledge "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

type DriveReader interface {
	GetForTenant(
		ctx context.Context,
		accountID, tenantID int64,
		fileUUID string,
	) (*svcdrive.FileDetailResp, error)
}

type KnowledgeReader interface {
	GetDocument(
		ctx context.Context,
		accountID, tenantID int64,
		kbUUID, docUUID string,
	) (*svcknowledge.DocumentDTO, error)
}

type Service struct {
	repo      dom.Repository
	drive     DriveReader
	knowledge KnowledgeReader
}

func New(repo dom.Repository, drive DriveReader, knowledge KnowledgeReader) *Service {
	return &Service{repo: repo, drive: drive, knowledge: knowledge}
}

type Item struct {
	FavoriteUUID string         `json:"favorite_uuid"`
	TargetKind   dom.TargetKind `json:"target_kind"`
	TargetUUID   string         `json:"target_uuid"`
	KBUUID       string         `json:"kb_uuid,omitempty"`
	SpaceUUID    string         `json:"space_uuid,omitempty"`
	FolderUUID   string         `json:"folder_uuid,omitempty"`
	Name         string         `json:"name"`
	MimeType     string         `json:"mime_type,omitempty"`
	SizeBytes    int64          `json:"size_bytes"`
	Status       string         `json:"status,omitempty"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	FavoritedAt  time.Time      `json:"favorited_at"`
}

type ListResp struct {
	Items []Item `json:"items"`
}

func ParseTargetKind(raw string) (dom.TargetKind, error) {
	switch dom.TargetKind(strings.TrimSpace(raw)) {
	case dom.TargetDriveFile:
		return dom.TargetDriveFile, nil
	case dom.TargetKBDocument:
		return dom.TargetKBDocument, nil
	default:
		return "", apperr.ErrInvalidParams.Withf("favorite.target_kind_invalid")
	}
}

func (s *Service) Add(
	ctx context.Context,
	accountID, tenantID int64,
	kind dom.TargetKind,
	targetUUID, kbUUID string,
) error {
	targetUUID = strings.TrimSpace(targetUUID)
	if targetUUID == "" {
		return apperr.ErrInvalidParams.Withf("favorite.target_uuid_required")
	}

	switch kind {
	case dom.TargetDriveFile:
		if s.drive == nil {
			return apperr.ErrInternal.Withf("favorite.drive_not_wired")
		}
		if _, err := s.drive.GetForTenant(ctx, accountID, tenantID, targetUUID); err != nil {
			return err
		}
	case dom.TargetKBDocument:
		if s.knowledge == nil {
			return apperr.ErrInternal.Withf("favorite.knowledge_not_wired")
		}
		kbUUID = strings.TrimSpace(kbUUID)
		if kbUUID == "" {
			return apperr.ErrInvalidParams.Withf("favorite.kb_uuid_required")
		}
		if _, err := s.knowledge.GetDocument(ctx, accountID, tenantID, kbUUID, targetUUID); err != nil {
			return err
		}
	default:
		return apperr.ErrInvalidParams.Withf("favorite.target_kind_invalid")
	}

	if err := s.repo.Add(ctx, tenantID, accountID, kind, targetUUID); err != nil {
		if errors.Is(err, dom.ErrTargetNotFound) {
			return apperr.ErrNotFound.Withf("favorite.target_not_found")
		}
		return apperr.ErrInternal.Wrap(fmt.Errorf("favorite.Service.Add: %w", err))
	}
	return nil
}

func (s *Service) Remove(
	ctx context.Context,
	accountID, tenantID int64,
	kind dom.TargetKind,
	targetUUID string,
) error {
	targetUUID = strings.TrimSpace(targetUUID)
	if targetUUID == "" {
		return apperr.ErrInvalidParams.Withf("favorite.target_uuid_required")
	}
	if kind != dom.TargetDriveFile && kind != dom.TargetKBDocument {
		return apperr.ErrInvalidParams.Withf("favorite.target_kind_invalid")
	}
	if err := s.repo.Remove(ctx, tenantID, accountID, kind, targetUUID); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("favorite.Service.Remove: %w", err))
	}
	return nil
}

func (s *Service) List(
	ctx context.Context,
	accountID, tenantID int64,
	limit int,
) (*ListResp, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 200 {
		limit = 200
	}

	// 多取一批用于吸收权限已撤销或资源已删除的陈旧关系，最终仍按调用方 limit 截断。
	entries, err := s.repo.List(ctx, tenantID, accountID, 500)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("favorite.Service.List: %w", err))
	}

	items := make([]Item, 0, min(limit, len(entries)))
	for i := range entries {
		if len(items) >= limit {
			break
		}
		entry := &entries[i]
		switch entry.TargetKind {
		case dom.TargetDriveFile:
			if s.drive == nil {
				return nil, apperr.ErrInternal.Withf("favorite.drive_not_wired")
			}
			file, err := s.drive.GetForTenant(ctx, accountID, tenantID, entry.TargetUUID)
			if err != nil {
				if isNoLongerVisible(err) {
					continue
				}
				return nil, err
			}
			items = append(items, Item{
				FavoriteUUID: entry.UUID,
				TargetKind:   entry.TargetKind,
				TargetUUID:   file.UUID,
				SpaceUUID:    file.SpaceUUID,
				FolderUUID:   file.FolderUUID,
				Name:         file.Name,
				MimeType:     file.MimeType,
				SizeBytes:    file.SizeBytes,
				Status:       file.CopyStatus,
				CreatedAt:    file.CreatedAt,
				UpdatedAt:    file.UpdatedAt,
				FavoritedAt:  entry.FavoritedAt,
			})
		case dom.TargetKBDocument:
			if s.knowledge == nil {
				return nil, apperr.ErrInternal.Withf("favorite.knowledge_not_wired")
			}
			doc, err := s.knowledge.GetDocument(
				ctx,
				accountID,
				tenantID,
				entry.ContainerUUID,
				entry.TargetUUID,
			)
			if err != nil {
				if isNoLongerVisible(err) {
					continue
				}
				return nil, err
			}
			items = append(items, Item{
				FavoriteUUID: entry.UUID,
				TargetKind:   entry.TargetKind,
				TargetUUID:   doc.UUID,
				KBUUID:       doc.KBUUID,
				FolderUUID:   doc.KBFolderUUID,
				Name:         doc.Title,
				MimeType:     doc.MimeType,
				SizeBytes:    doc.FileSize,
				Status:       doc.Status,
				CreatedAt:    doc.CreatedAt,
				UpdatedAt:    doc.UpdatedAt,
				FavoritedAt:  entry.FavoritedAt,
			})
		}
	}
	return &ListResp{Items: items}, nil
}

func isNoLongerVisible(err error) bool {
	if appErr, ok := apperr.AsError(err); ok {
		status := appErr.HTTPStatus()
		return status == 403 || status == 404
	}
	return false
}
