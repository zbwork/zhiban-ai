package clientdrive

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcfavorite "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/favorite"
)

type addFavoriteReq struct {
	KBUUID string `json:"kb_uuid"`
}

func (h *Handlers) DriveFavoritesList(w http.ResponseWriter, r *http.Request) {
	if h.DriveFavorites == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("favorite.service_not_wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.DriveFavorites.List(
		r.Context(),
		accountID,
		tenantID,
		parseLimitQuery(r, 100, 200),
	)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) DriveFavoriteAdd(w http.ResponseWriter, r *http.Request) {
	if h.DriveFavorites == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("favorite.service_not_wired"))
		return
	}
	kind, err := svcfavorite.ParseTargetKind(r.PathValue("target_kind"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	var req addFavoriteReq
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	if err := decoder.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}

	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.DriveFavorites.Add(
		r.Context(),
		accountID,
		tenantID,
		kind,
		r.PathValue("target_uuid"),
		req.KBUUID,
	); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) DriveFavoriteRemove(w http.ResponseWriter, r *http.Request) {
	if h.DriveFavorites == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("favorite.service_not_wired"))
		return
	}
	kind, err := svcfavorite.ParseTargetKind(r.PathValue("target_kind"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.DriveFavorites.Remove(
		r.Context(),
		accountID,
		tenantID,
		kind,
		r.PathValue("target_uuid"),
	); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
