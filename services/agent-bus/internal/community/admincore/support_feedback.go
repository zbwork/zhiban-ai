package admincore

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type supportFeedbackListResp struct {
	Items  []dom.Feedback `json:"items"`
	Total  int64          `json:"total"`
	Limit  int            `json:"limit"`
	Offset int            `json:"offset"`
}

func (h *Handlers) listSupportFeedback(w http.ResponseWriter, r *http.Request) {
	if h.SupportFeedback == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("support feedback service not wired"))
		return
	}
	q := r.URL.Query()
	tenantID, _ := strconv.ParseInt(q.Get("tenant_id"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	filter := dom.Filter{
		TenantID: tenantID,
		Status:   q.Get("status"),
		Category: q.Get("category"),
		Priority: q.Get("priority"),
		Keyword:  q.Get("q"),
		Limit:    limit,
		Offset:   offset,
	}
	items, total, err := h.SupportFeedback.ListPlatform(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapSupportFeedbackError(err))
		return
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, supportFeedbackListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

type patchSupportFeedbackReq struct {
	Status      string `json:"status"`
	Priority    string `json:"priority"`
	HandlerNote string `json:"handler_note"`
}

func (h *Handlers) patchSupportFeedback(w http.ResponseWriter, r *http.Request) {
	if h.SupportFeedback == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("support feedback service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	var req patchSupportFeedbackReq
	if err := json.Unmarshal(body, &req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	assignedTo, assignedToSet, err := decodeSupportFeedbackAssignee(body)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.SupportFeedback.UpdatePlatform(r.Context(), uuid, middleware.MustAccountID(r.Context()), dom.UpdateInput{
		Status:        req.Status,
		Priority:      req.Priority,
		HandlerNote:   req.HandlerNote,
		AssignedTo:    assignedTo,
		AssignedToSet: assignedToSet,
	})
	if err != nil {
		encode.JSONError(w, mapSupportFeedbackError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func decodeSupportFeedbackAssignee(body []byte) (*int64, bool, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, false, err
	}
	v, ok := raw["assigned_to"]
	if !ok {
		return nil, false, nil
	}
	if bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
		return nil, true, nil
	}
	var id int64
	if err := json.Unmarshal(v, &id); err != nil {
		return nil, false, err
	}
	return &id, true, nil
}

func mapSupportFeedbackError(err error) error {
	switch {
	case errors.Is(err, dom.ErrInvalidSource),
		errors.Is(err, dom.ErrInvalidCategory),
		errors.Is(err, dom.ErrInvalidPriority),
		errors.Is(err, dom.ErrInvalidStatus),
		errors.Is(err, dom.ErrMissingTenant),
		errors.Is(err, dom.ErrMissingTitle),
		errors.Is(err, dom.ErrMissingBody),
		errors.Is(err, dom.ErrTooManyFiles),
		errors.Is(err, dom.ErrInvalidAssignee):
		return apperr.ErrInvalidParams.Wrap(err)
	default:
		return err
	}
}
