package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	domapproval "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2aapproval"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svca2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
)

type AdminA2AApprovalService interface {
	ListApprovalViewsForAdmin(ctx context.Context, tenantID int64, status domapproval.Status, limit, offset int) ([]svca2a.ApprovalView, int, error)
	GetApprovalViewForAdmin(ctx context.Context, tenantID int64, approvalUUID string) (*svca2a.ApprovalView, error)
	DecideApproval(ctx context.Context, in svca2a.ApprovalDecisionInput) (*svca2a.ApprovalDecisionResult, error)
}

type AdminA2AApprovalHandler struct {
	Service AdminA2AApprovalService
	Audit   domaudit.Store
}

type adminA2AApprovalDecisionReq struct {
	Decision   string          `json:"decision"`
	FormResult json.RawMessage `json:"form_result"`
	Reason     string          `json:"reason"`
}

func (h *AdminA2AApprovalHandler) List(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.Service == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("a2a approval service not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	items, total, err := h.Service.ListApprovalViewsForAdmin(
		r.Context(),
		middleware.MustTenantID(r.Context()),
		domapproval.Status(q.Get("status")),
		limit,
		offset,
	)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(items))
	for _, it := range items {
		out = append(out, adminA2AApprovalDTO(it))
	}
	encode.JSON(w, map[string]any{"items": out, "total": total, "limit": normalizedApprovalLimit(limit), "offset": maxInt(offset, 0)})
}

func (h *AdminA2AApprovalHandler) Get(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.Service == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("a2a approval service not wired"))
		return
	}
	view, err := h.Service.GetApprovalViewForAdmin(
		r.Context(),
		middleware.MustTenantID(r.Context()),
		r.PathValue("approval_request_id"),
	)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, adminA2AApprovalDTO(*view))
}

func (h *AdminA2AApprovalHandler) Decide(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.Service == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("a2a approval service not wired"))
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var req adminA2AApprovalDecisionReq
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	decision := domapproval.Status(strings.TrimSpace(req.Decision))
	if decision != domapproval.StatusApproved && decision != domapproval.StatusRejected {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("decision must be approved|rejected"))
		return
	}
	res, err := h.Service.DecideApproval(r.Context(), svca2a.ApprovalDecisionInput{
		TenantID:       middleware.MustTenantID(r.Context()),
		ApprovalUUID:   r.PathValue("approval_request_id"),
		ActorAccountID: middleware.MustAccountID(r.Context()),
		Decision:       decision,
		FormResult:     req.FormResult,
		Reason:         req.Reason,
		AdminOverride:  true,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	fireA2AApprovalAdminAudit(
		r.Context(),
		h.Audit,
		middleware.MustTenantID(r.Context()),
		middleware.MustAccountID(r.Context()),
		res,
		decision,
	)
	encode.JSON(w, map[string]any{
		"approval_request_id": res.ApprovalUUID,
		"edge_id":             res.EdgeUUID,
		"edge_created_at":     res.EdgeCreatedAt.UTC().Format(time.RFC3339Nano),
		"approval_status":     string(res.ApprovalStatus),
		"edge_status":         string(res.EdgeStatus),
	})
}

func adminA2AApprovalDTO(view svca2a.ApprovalView) map[string]any {
	it := view.Request
	if it == nil {
		return map[string]any{}
	}
	out := map[string]any{
		"id":              it.UUID,
		"edge_id":         it.EdgeUUID,
		"edge_created_at": it.EdgeCreatedAt.UTC().Format(time.RFC3339Nano),
		"from_agent_id":   view.FromAgentUUID,
		"from_agent_name": view.FromAgentName,
		"to_agent_id":     view.ToAgentUUID,
		"to_agent_name":   view.ToAgentName,
		"status":          string(it.Status),
		"invoke_kind":     string(it.InvokeKind),
		"request_payload": json.RawMessage(jsonOrEmptyObject(it.RequestPayloadRedacted)),
		"form_schema":     json.RawMessage(jsonOrEmptyObject(it.FormSchema)),
		"form_result":     json.RawMessage(jsonOrEmptyObject(it.FormResult)),
		"reason":          it.Reason,
		"created_at":      it.CreatedAt.UTC().Format(time.RFC3339Nano),
	}
	if it.ExpiresAt != nil {
		out["expires_at"] = it.ExpiresAt.UTC().Format(time.RFC3339Nano)
	}
	if it.DecidedAt != nil {
		out["decided_at"] = it.DecidedAt.UTC().Format(time.RFC3339Nano)
	}
	if it.DecidedByAccountID != nil {
		out["decided_by_account_id"] = *it.DecidedByAccountID
	}
	return out
}

func jsonOrEmptyObject(b []byte) []byte {
	if len(b) == 0 {
		return []byte("{}")
	}
	return b
}

func normalizedApprovalLimit(limit int) int {
	if limit <= 0 {
		return 50
	}
	if limit > 200 {
		return 200
	}
	return limit
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func fireA2AApprovalAdminAudit(ctx context.Context, store domaudit.Store, tenantID, accountID int64, res *svca2a.ApprovalDecisionResult, decision domapproval.Status) {
	if store == nil || tenantID <= 0 || accountID <= 0 || res == nil {
		return
	}
	raw, _ := json.Marshal(map[string]any{
		"approval_request_id": res.ApprovalUUID,
		"edge_id":             res.EdgeUUID,
		"decision":            string(decision),
		"approval_status":     string(res.ApprovalStatus),
		"edge_status":         string(res.EdgeStatus),
	})
	_ = store.Insert(ctx, domaudit.Event{
		OccurredAt:   time.Now().UTC(),
		TenantID:     tenantID,
		AccountID:    accountID,
		ActorKind:    domaudit.ActorAdmin,
		Domain:       "agent",
		EventKind:    "tenant.a2a_approval.decide",
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "a2a_approval",
		ResourceUUID: res.ApprovalUUID,
		Payload:      raw,
	})
}
