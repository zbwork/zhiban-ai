package drive

import (
	"context"
	"time"
)

// FileScope 与 drive_files.scope CHECK 对齐 (F06 §2.4 + ADR 0016).
type FileScope string

const (
	FileScopeDrive FileScope = "drive"
	FileScopeChat  FileScope = "chat"
)

// FileSource 与 drive_files.source CHECK 对齐.
type FileSource string

const (
	FileSourceUserUpload  FileSource = "user_upload"
	FileSourceChatUpload  FileSource = "chat_upload"
	FileSourceChatImport  FileSource = "chat_import"
	FileSourceAgentOutput FileSource = "agent_output"
	FileSourceKbUpload    FileSource = "kb_upload"
)

// CopyStatus F06 v0.3.1 跨 space move lifecycle (F06 §2.4 + §4.9 + ADR 0015).
type CopyStatus string

const (
	CopyStatusReady      CopyStatus = "ready"
	CopyStatusCopying    CopyStatus = "copying"
	CopyStatusCopyFailed CopyStatus = "copy_failed"
)

// ThumbnailStatus 与 drive_files.thumbnail_status CHECK 对齐.
type ThumbnailStatus string

const (
	ThumbnailStatusNone    ThumbnailStatus = "none"
	ThumbnailStatusPending ThumbnailStatus = "pending"
	ThumbnailStatusReady   ThumbnailStatus = "ready"
	ThumbnailStatusFailed  ThumbnailStatus = "failed"
)

// File F06 §2.4 drive_files 共表 (scope=drive|chat 物理元数据中心).
type File struct {
	ID                     int64
	UUID                   string
	SpaceID                int64
	Scope                  FileScope
	Source                 FileSource
	DriveFolderID          *int64 // chat scope / KB-only 时 NULL
	StorageKey             string
	Name                   string
	MimeType               string
	SizeBytes              int64
	SHA256                 *string
	OriginMessageFileID    *int64
	OriginConversationUUID *string
	OriginAgentID          *string
	ThumbnailKey           *string
	ThumbnailStatus        ThumbnailStatus
	CopyStatus             CopyStatus
	CopyFailureReason      *string
	CopySourceFileID       *int64
	CopyStartedAt          *time.Time
	CopyFinishedAt         *time.Time
	CreatedAt              time.Time
	CreatedBy              *int64
	UpdatedAt              time.Time
	UpdatedBy              *int64
	IsDeleted              bool
	DeletedAt              *time.Time
}

// FileRepo Phase 2.0a 仅暴露 GetByID; 后续 slice 按需扩.
type FileRepo interface {
	GetByID(ctx context.Context, id int64) (*File, error)
}

// CreateFileInput F06 Phase 2.2c confirm 写入 drive_files 的入参.
// scope/source CHECK 由 caller 保证 (e.g. user upload → scope=drive, source=user_upload).
type CreateFileInput struct {
	SpaceID       int64
	DriveFolderID *int64 // 可空 (chat scope / KB-only 时 NULL)
	Name          string // 已 Sanitize
	MimeType      string
	SizeBytes     int64
	SHA256        *string
	StorageKey    string // final key
	Scope         FileScope
	Source        FileSource
	CreatedBy     int64
}
