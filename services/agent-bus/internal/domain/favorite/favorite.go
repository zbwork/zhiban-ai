package favorite

import (
	"context"
	"errors"
	"time"
)

type TargetKind string

const (
	TargetDriveFile  TargetKind = "drive_file"
	TargetKBDocument TargetKind = "kb_document"
)

var ErrTargetNotFound = errors.New("favorite target not found")

type Entry struct {
	UUID          string
	TargetKind    TargetKind
	TargetUUID    string
	ContainerUUID string
	FavoritedAt   time.Time
}

type Repository interface {
	Add(ctx context.Context, tenantID, accountID int64, kind TargetKind, targetUUID string) error
	Remove(ctx context.Context, tenantID, accountID int64, kind TargetKind, targetUUID string) error
	List(ctx context.Context, tenantID, accountID int64, limit int) ([]Entry, error)
}
