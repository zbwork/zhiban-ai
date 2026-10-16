package clientcatalog

import (
	"context"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
)

type AgentReader interface {
	List(context.Context, domagent.Filter) ([]domagent.DigitalEmployee, int64, error)
	GetByUUID(context.Context, string) (*domagent.DigitalEmployee, error)
}
type AgentHandlers struct{ Agents AgentReader }

func agentView(e domagent.DigitalEmployee) map[string]any {
	return map[string]any{"UUID": e.UUID, "Name": e.Name, "Intro": e.Intro, "Description": e.Description, "AvatarURL": e.AvatarURL, "Status": e.Status, "Source": e.Source, "Visibility": e.Visibility, "CreatorID": e.CreatorID, "CreatorName": e.CreatorName, "IsDefaultForCreator": e.IsDefaultForCreator, "PositionLabel": e.PositionLabel, "DepartmentName": e.DepartmentName, "execution_locus": e.ExecutionLocus, "supports_model_selection": false, "supports_skill_bindings": false, "can_manage_skills": false}
}
func (h *AgentHandlers) List(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	list, total, err := h.Agents.List(r.Context(), domagent.Filter{TenantID: middleware.MustTenantID(r.Context()), CreatorID: middleware.MustAccountID(r.Context()), Source: q.Get("source"), Visibility: q.Get("visibility"), Status: q.Get("status"), Keyword: q.Get("q"), Limit: limit, Offset: offset, ExcludeTenantInitSeeds: true})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]map[string]any, 0, len(list))
	for _, e := range list {
		items = append(items, agentView(e))
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}
func (h *AgentHandlers) Get(w http.ResponseWriter, r *http.Request) {
	e, err := h.Agents.GetByUUID(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if e == nil || e.TenantID != middleware.MustTenantID(r.Context()) || e.CreatorID != middleware.MustAccountID(r.Context()) {
		encode.JSONError(w, apperr.ErrForbidden)
		return
	}
	encode.JSON(w, map[string]any{"agent": agentView(*e), "bindings": []any{}})
}
