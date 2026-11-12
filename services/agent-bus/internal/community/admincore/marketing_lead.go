package admincore

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/marketinglead"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type marketingLeadListResp struct {
	Items  []dom.Lead `json:"items"`
	Total  int64      `json:"total"`
	Limit  int        `json:"limit"`
	Offset int        `json:"offset"`
}

func (h *Handlers) listMarketingLeads(w http.ResponseWriter, r *http.Request) {
	if h.MarketingLead == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("marketing lead service not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	filter := dom.Filter{
		Status:  q.Get("status"),
		Keyword: q.Get("q"),
		Limit:   limit,
		Offset:  offset,
	}
	if v := q.Get("created_gte"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
		filter.CreatedGTE = &t
	}
	if v := q.Get("created_lte"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
		filter.CreatedLTE = &t
	}
	items, total, err := h.MarketingLead.ListPlatform(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapMarketingLeadAdminError(err))
		return
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, marketingLeadListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

type patchMarketingLeadReq struct {
	Status string `json:"status"`
	Remark string `json:"remark"`
}

func (h *Handlers) patchMarketingLead(w http.ResponseWriter, r *http.Request) {
	if h.MarketingLead == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("marketing lead service not wired"))
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
	var req patchMarketingLeadReq
	if err := json.Unmarshal(body, &req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	assignedTo, assignedToSet, err := decodeMarketingLeadAssignee(body)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.MarketingLead.UpdatePlatform(r.Context(), uuid, middleware.MustAccountID(r.Context()), dom.UpdateInput{
		Status:        req.Status,
		Remark:        req.Remark,
		AssignedTo:    assignedTo,
		AssignedToSet: assignedToSet,
	})
	if err != nil {
		encode.JSONError(w, mapMarketingLeadAdminError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func decodeMarketingLeadAssignee(body []byte) (*int64, bool, error) {
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

func mapMarketingLeadAdminError(err error) error {
	switch {
	case errors.Is(err, dom.ErrInvalidPhone),
		errors.Is(err, dom.ErrInvalidSource),
		errors.Is(err, dom.ErrInvalidStatus),
		errors.Is(err, dom.ErrMissingContactName),
		errors.Is(err, dom.ErrMissingCompany),
		errors.Is(err, dom.ErrMissingCode),
		errors.Is(err, dom.ErrMessageTooLong),
		errors.Is(err, dom.ErrRemarkTooLong),
		errors.Is(err, dom.ErrInvalidAssignee):
		return apperr.ErrInvalidParams.Wrap(err)
	default:
		return err
	}
}
