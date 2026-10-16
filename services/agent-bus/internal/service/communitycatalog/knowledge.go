package communitycatalog

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"time"
)

type KnowledgeReader interface {
	ListVisibleKB(context.Context, dom.ListKBFilter) ([]dom.KnowledgeBase, error)
}
type Knowledge struct{ Repo KnowledgeReader }
type KB struct {
	UUID           string    `json:"uuid"`
	Name           string    `json:"name"`
	Description    string    `json:"description"`
	SpaceKind      string    `json:"space_kind"`
	Visibility     string    `json:"visibility"`
	AccessMode     string    `json:"access_mode"`
	Status         string    `json:"status"`
	TotalDocuments int       `json:"total_documents"`
	CreatorID      int64     `json:"creator_id"`
	CanWrite       bool      `json:"can_write"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (s *Knowledge) List(ctx context.Context, accountID, tenantID int64) ([]KB, error) {
	rows, err := s.Repo.ListVisibleKB(ctx, dom.ListKBFilter{TenantID: tenantID, AccountID: accountID, Limit: 100})
	if err != nil {
		return nil, err
	}
	out := make([]KB, 0, len(rows))
	for _, k := range rows {
		out = append(out, KB{UUID: k.UUID, Name: k.Name, Description: k.Description, SpaceKind: k.SpaceKind, Visibility: k.Visibility, AccessMode: k.AccessMode, Status: k.Status, TotalDocuments: k.TotalDocuments, CreatorID: k.CreatorID, CanWrite: false, CreatedAt: k.CreatedAt, UpdatedAt: k.UpdatedAt})
	}
	return out, nil
}
