package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ChatMediaRefRepo P2.2c:chat_media_refs 读写。
type ChatMediaRefRepo struct{ pool *pgxpool.Pool }

// NewChatMediaRefRepo 构造。
func NewChatMediaRefRepo(pool *pgxpool.Pool) *ChatMediaRefRepo {
	return &ChatMediaRefRepo{pool: pool}
}

// Create 插入一条 ref,返回带 id/uuid/created_at 的完整行。
func (r *ChatMediaRefRepo) Create(ctx context.Context, in dom.CreateChatMediaRefInput) (*dom.ChatMediaRef, error) {
	const q = `
		INSERT INTO chat_media_refs
		  (tenant_id, conversation_id, room_id, sender_account_id, media_kind,
		   source_kind, drive_file_uuid, storage_key, file_name, mime_type, size_bytes)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		RETURNING id, uuid::text, created_at`
	out := &dom.ChatMediaRef{
		TenantID:        in.TenantID,
		ConversationID:  in.ConversationID,
		RoomID:          in.RoomID,
		SenderAccountID: in.SenderAccountID,
		MediaKind:       in.MediaKind,
		SourceKind:      in.SourceKind,
		DriveFileUUID:   in.DriveFileUUID,
		StorageKey:      in.StorageKey,
		FileName:        in.FileName,
		MimeType:        in.MimeType,
		SizeBytes:       in.SizeBytes,
	}
	err := r.pool.QueryRow(ctx, q,
		in.TenantID, in.ConversationID, in.RoomID, in.SenderAccountID, in.MediaKind,
		in.SourceKind, in.DriveFileUUID, in.StorageKey, in.FileName, in.MimeType, in.SizeBytes,
	).Scan(&out.ID, &out.UUID, &out.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("drive.ChatMediaRefRepo.Create: %w", err)
	}
	return out, nil
}

// GetByUUID 按 ref uuid 查;未命中返回 ErrNotFound。
func (r *ChatMediaRefRepo) GetByUUID(ctx context.Context, uuid string) (*dom.ChatMediaRef, error) {
	const q = `
		SELECT id, uuid::text, tenant_id, conversation_id, room_id, sender_account_id,
		       media_kind, source_kind, drive_file_uuid::text, storage_key,
		       file_name, mime_type, size_bytes, created_at
		  FROM chat_media_refs WHERE uuid = $1`
	var m dom.ChatMediaRef
	err := r.pool.QueryRow(ctx, q, uuid).Scan(
		&m.ID, &m.UUID, &m.TenantID, &m.ConversationID, &m.RoomID, &m.SenderAccountID,
		&m.MediaKind, &m.SourceKind, &m.DriveFileUUID, &m.StorageKey,
		&m.FileName, &m.MimeType, &m.SizeBytes, &m.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ChatMediaRefRepo.GetByUUID: %w", err)
	}
	return &m, nil
}
