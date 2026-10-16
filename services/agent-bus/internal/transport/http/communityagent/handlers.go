package communityagent

import (
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communityagent"
	"io"
	"net/http"
	"strconv"
)

type Handlers struct {
	Service         *svc.Service
	Provider, Model string
}

func input(w http.ResponseWriter, r *http.Request) (svc.Input, error) {
	var in svc.Input
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192))
	d.DisallowUnknownFields()
	if err := d.Decode(&in); err != nil {
		return in, apperr.ErrInvalidParams
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return in, apperr.ErrInvalidParams
	}
	return in, nil
}
func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	limit, offset := 20, 0
	var err error
	if value := r.URL.Query().Get("limit"); value != "" {
		limit, err = strconv.Atoi(value)
	}
	if err == nil {
		if value := r.URL.Query().Get("offset"); value != "" {
			offset, err = strconv.Atoi(value)
		}
	}
	if err != nil || limit < 1 || limit > 100 || offset < 0 {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	items, total, err := h.Service.List(r.Context(), middleware.MustTenantID(r.Context()), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	publicItems := make([]employee, 0, len(items))
	for i := range items {
		publicItems = append(publicItems, view(&items[i]))
	}
	encode.JSON(w, map[string]any{"items": publicItems, "total": total, "limit": limit, "offset": offset})
}
func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	e, err := h.Service.Get(r.Context(), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, view(e))
}
func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	in, err := input(w, r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	e, err := h.Service.Create(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, view(e))
}
func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	in, err := input(w, r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	e, err := h.Service.Update(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, view(e))
}
func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	err := h.Service.Delete(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
func (h *Handlers) Publish(w http.ResponseWriter, r *http.Request) {
	e, err := h.Service.Publish(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, view(e))
}
func (h *Handlers) ModelOptions(w http.ResponseWriter, r *http.Request) {
	encode.JSON(w, map[string]any{"items": []map[string]string{{"provider": h.Provider, "name": h.Model}}})
}

// employee exposes only supported community fields.
type employee struct {
	UUID                 string
	Name                 string
	Intro                string
	Status               string
	RuntimeEnvironmentID *int64
}

func view(e *dom.DigitalEmployee) employee {
	return employee{UUID: e.UUID, Name: e.Name, Intro: e.Intro, Status: e.Status, RuntimeEnvironmentID: e.RuntimeEnvironmentID}
}
