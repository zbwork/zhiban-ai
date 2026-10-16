package a2astream

import (
	"context"
	"time"

	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
)

type Event struct {
	Seq             int64
	EdgeUUID        string
	EdgeCreatedAt   time.Time
	Event           string
	Delta           string
	BlockDelta      map[string]any
	Status          doma2a.Status
	ErrorMessage    string
	ResponsePayload []byte
	CreatedAt       time.Time
}

type Repository interface {
	Append(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, ev Event) (Event, error)
	ListAfter(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, afterSeq int64, limit int) ([]Event, error)
	DeleteOlderThan(ctx context.Context, before time.Time, limit int) (int64, error)
}
