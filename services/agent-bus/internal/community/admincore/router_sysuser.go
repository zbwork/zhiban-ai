package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcsysuser "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/sysuser"
)

func (h *Handlers) listSysUsers(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	list, total, err := h.SysUser.List(r.Context(), r.URL.Query().Get("q"), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": list, "total": total})
}

func (h *Handlers) getSysUser(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	res, err := h.SysUser.Get(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) createSysUser(w http.ResponseWriter, r *http.Request) {
	var body svcsysuser.CreateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.SysUser.Create(r.Context(), body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) updateSysUser(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var body svcsysuser.UpdateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	res, err := h.SysUser.Update(r.Context(), id, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

func (h *Handlers) suspendSysUser(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err := h.SysUser.Suspend(r.Context(), id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
