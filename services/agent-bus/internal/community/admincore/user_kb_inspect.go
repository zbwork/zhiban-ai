package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	kbsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

type UserKBInspectHandler struct {
	Accounts interface {
		GetByUUID(context.Context, string) (*domaccount.Account, error)
	}
	Knowledge interface {
		ListTenantMemberPersonalKB(context.Context, int64, int64) ([]kbsvc.KBDTO, error)
	}
	Audit domaudit.Store
}

type personalKBMetadata struct {
	UUID           string    `json:"uuid"`
	Name           string    `json:"name"`
	Description    string    `json:"description,omitempty"`
	SpaceKind      string    `json:"space_kind"`
	Visibility     string    `json:"visibility"`
	Status         string    `json:"status"`
	TotalDocuments int       `json:"total_documents"`
	CreatorID      int64     `json:"creator_id"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (h *UserKBInspectHandler) List(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tenantID, actorID := middleware.MustTenantID(ctx), middleware.MustAccountID(ctx)
	if h.Accounts == nil || h.Knowledge == nil || h.Audit == nil {
		encode.JSONError(w, apperr.ErrInternal)
		return
	}
	targetUUID, err := uuid.Parse(r.PathValue("user_uuid"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("user_uuid must be a valid UUID"))
		return
	}
	target, err := h.Accounts.GetByUUID(ctx, targetUUID.String())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	rows, err := h.Knowledge.ListTenantMemberPersonalKB(ctx, tenantID, target.ID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	data, err := json.Marshal(map[string]int{"result_count": len(rows)})
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if err := h.Audit.Insert(ctx, domaudit.Event{
		OccurredAt: time.Now(), TenantID: tenantID, AccountID: actorID,
		ActorKind: domaudit.ActorAdmin, Domain: "kb", EventKind: "user_kb_inspect",
		ResourceKind: "account", ResourceUUID: targetUUID.String(), TargetAccountID: target.ID, Payload: data,
	}); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	items := make([]personalKBMetadata, 0, len(rows))
	for _, row := range rows {
		items = append(items, personalKBMetadata{
			UUID: row.UUID, Name: row.Name, Description: row.Description,
			SpaceKind: row.SpaceKind, Visibility: row.Visibility, Status: row.Status,
			TotalDocuments: row.TotalDocuments, CreatorID: row.CreatorID, CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt,
		})
	}
	encode.JSON(w, map[string]any{"items": items})
}
