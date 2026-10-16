package drive

import (
	"context"
	"time"
)

// TicketStatus 与 drive_upload_tickets.status CHECK 对齐 (F06 §3.2 staging key).
type TicketStatus string

const (
	TicketStatusPending TicketStatus = "pending"
	TicketStatusDone    TicketStatus = "done"
	TicketStatusPartial TicketStatus = "partial"
	TicketStatusFailed  TicketStatus = "failed"
)

// UploadTicket F06 §3.2 drive_upload_tickets (transient cache, 不带 8 字段审计).
type UploadTicket struct {
	ID           int64
	FileUUID     string
	AccountID    int64
	TenantID     int64
	SpaceID      *int64
	FolderID     *int64
	DeclaredSize int64
	DeclaredMime string
	DeclaredName string
	StagingKey   string
	FinalKey     string
	UploadID     *string // multipart upload id; 单 PUT 时 NULL
	// PartSize Phase 2.M (migration 000115): multipart 模式 per-part 字节数.
	// 单 PUT (mode='single') 路径 NULL; :refresh-part-urls 用它重算 numParts.
	PartSize *int64
	// Source Phase 2.5 (migration 000117): caller 上传场景类型, confirm 后半段
	// INSERT drive_files.source 用. 默认 'user_upload'; ZAP agent backchannel 传
	// 'agent_output', chat upload 传 'chat_upload' 等.
	Source    FileSource
	Status    TicketStatus
	CreatedAt time.Time
	ExpiresAt time.Time
}

// TicketRepo Phase 2.0a 仅暴露 GetByFileUUID.
type TicketRepo interface {
	GetByFileUUID(ctx context.Context, fileUUID string) (*UploadTicket, error)
}

// CreateUploadTicketInput F06 Phase 2.2c presign-put 入参.
// status 在 repo 内固定 'pending'; expires_at 由 service 计算 (presign TTL + reaper buffer).
type CreateUploadTicketInput struct {
	FileUUID     string
	AccountID    int64
	TenantID     int64
	SpaceID      *int64
	FolderID     *int64
	DeclaredSize int64
	DeclaredMime string
	DeclaredName string
	StagingKey   string
	FinalKey     string
	UploadID     *string // multipart upload id; 单 PUT 时 nil
	PartSize     *int64  // multipart per-part bytes (Phase 2.M migration 000115); 单 PUT nil
	// Source Phase 2.5 (migration 000117): 透传给 confirm 后半段 INSERT drive_files.source.
	// 空串视为 'user_upload' (默认; 现有 client upload 路径不传); ZAP/agent ingest 等传具体值.
	Source    FileSource
	ExpiresAt time.Time
}
