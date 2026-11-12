package admincore

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/downloadchannel"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type downloadChannelListResp struct {
	Items  []dom.ChannelWithStats `json:"items"`
	Total  int64                  `json:"total"`
	Limit  int                    `json:"limit"`
	Offset int                    `json:"offset"`
}

type shareGrowthListResp struct {
	Items  []dom.ShareGrowthItem `json:"items"`
	Total  int64                 `json:"total"`
	Limit  int                   `json:"limit"`
	Offset int                   `json:"offset"`
}

type downloadChannelReq struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      string `json:"status"`
}

func (h *Handlers) listDownloadChannels(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	start, err := parseRangeParam(q.Get("start"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid start: %v", err))
		return
	}
	end, err := parseRangeParam(q.Get("end"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid end: %v", err))
		return
	}
	if start == nil && end == nil {
		s := time.Now().AddDate(0, 0, -30)
		start = &s
	}
	filter := dom.Filter{
		Status:  q.Get("status"),
		Keyword: q.Get("q"),
		// F29: 缺省只查 marketing（个人分享码不进运营列表）；kind=user_share / kind=all 显式可查。
		Kind:       q.Get("kind"),
		RangeStart: start,
		RangeEnd:   end,
		Limit:      limit,
		Offset:     offset,
	}
	items, total, err := h.DownloadChannel.List(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, downloadChannelListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

func (h *Handlers) getDownloadChannelStats(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	q := r.URL.Query()
	start, err := parseRangeParam(q.Get("start"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid start: %v", err))
		return
	}
	end, err := parseRangeParam(q.Get("end"))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid end: %v", err))
		return
	}
	if start == nil && end == nil {
		s := time.Now().AddDate(0, 0, -30)
		start = &s
	}
	stats, err := h.DownloadChannel.Stats(r.Context(), dom.Filter{
		Status:     q.Get("status"),
		Keyword:    q.Get("q"),
		Kind:       q.Get("kind"),
		RangeStart: start,
		RangeEnd:   end,
	})
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, stats)
}

func (h *Handlers) listShareGrowth(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	filter, err := shareGrowthFilter(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items, total, err := h.DownloadChannel.ListShareGrowth(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	if filter.Limit <= 0 || filter.Limit > 100 {
		filter.Limit = 20
	}
	if filter.Offset < 0 {
		filter.Offset = 0
	}
	encode.JSON(w, shareGrowthListResp{Items: items, Total: total, Limit: filter.Limit, Offset: filter.Offset})
}

func (h *Handlers) getShareGrowthStats(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	filter, err := shareGrowthFilter(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	stats, err := h.DownloadChannel.ShareGrowthStats(r.Context(), filter)
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, stats)
}

func shareGrowthFilter(r *http.Request) (dom.Filter, error) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	start, err := parseRangeParam(q.Get("start"))
	if err != nil {
		return dom.Filter{}, apperr.ErrInvalidParams.Withf("invalid start: %v", err)
	}
	end, err := parseRangeParam(q.Get("end"))
	if err != nil {
		return dom.Filter{}, apperr.ErrInvalidParams.Withf("invalid end: %v", err)
	}
	if start == nil && end == nil {
		s := time.Now().AddDate(0, 0, -30)
		start = &s
	}
	return dom.Filter{
		Status:     q.Get("status"),
		Keyword:    q.Get("q"),
		Kind:       dom.KindUserShare,
		RangeStart: start,
		RangeEnd:   end,
		Limit:      limit,
		Offset:     offset,
	}, nil
}

func (h *Handlers) getDownloadChannel(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	item, err := h.DownloadChannel.Get(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) createDownloadChannel(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	var req downloadChannelReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.DownloadChannel.Create(r.Context(), req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) patchDownloadChannel(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	var req downloadChannelReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	item, err := h.DownloadChannel.Update(r.Context(), uuid, req.toInput(middleware.MustAccountID(r.Context())))
	if err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, map[string]any{"item": item})
}

func (h *Handlers) deleteDownloadChannel(w http.ResponseWriter, r *http.Request) {
	if h.DownloadChannel == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("download channel service not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	if err := h.DownloadChannel.Delete(r.Context(), uuid, middleware.MustAccountID(r.Context())); err != nil {
		encode.JSONError(w, mapDownloadChannelError(err))
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

func (r downloadChannelReq) toInput(actorID int64) dom.UpsertInput {
	return dom.UpsertInput{
		Code:        r.Code,
		Name:        r.Name,
		Description: r.Description,
		Status:      r.Status,
		ActorID:     actorID,
	}
}

func mapDownloadChannelError(err error) error {
	switch {
	case errors.Is(err, dom.ErrMissingCode),
		errors.Is(err, dom.ErrMissingName),
		errors.Is(err, dom.ErrInvalidStatus),
		errors.Is(err, dom.ErrInvalidKind):
		return apperr.ErrInvalidParams.Wrap(err)
	case errors.Is(err, dom.ErrDuplicateCode):
		return apperr.ErrConflict.Wrap(err)
	default:
		return err
	}
}

func parseRangeParam(v string) (*time.Time, error) {
	if v == "" {
		return nil, nil
	}
	if t, err := time.Parse(time.RFC3339, v); err == nil {
		return &t, nil
	}
	t, err := time.ParseInLocation("2006-01-02", v, time.Local)
	if err != nil {
		return nil, err
	}
	return &t, nil
}
