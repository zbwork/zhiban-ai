package clientcatalog

import (
	"context"
	"errors"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	envdom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communityagent"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	svcskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	"net/http"
	"strconv"
)

type AgentReader interface {
	List(context.Context, domagent.Filter) ([]domagent.DigitalEmployee, int64, error)
	GetByUUID(context.Context, string) (*domagent.DigitalEmployee, error)
}
type AgentHandlers struct {
	Apps         domapp.Service
	Agents       AgentReader
	Personal     *svc.Personal
	Knowledge    svckb.Service
	Skills       *svcskill.Service
	Environments interface {
		GetByID(context.Context, int64) (*envdom.Env, error)
	}
}

func agentView(e domagent.DigitalEmployee) map[string]any {
	metadata := map[string]any{}
	for _, key := range []string{"system_prompt", "agent_key", "allow_internet_access", "selected_app_uuids", "selected_app_labels", "selected_knowledge_base_uuids", "selected_knowledge_base_labels"} {
		if value, ok := e.Metadata[key]; ok {
			metadata[key] = value
		}
	}
	return map[string]any{"Description": e.Description, "WelcomeMsg": e.WelcomeMsg, "metadata": metadata, "Tags": e.Tags, "UUID": e.UUID, "Name": e.Name, "Intro": e.Intro, "AvatarURL": e.AvatarURL, "Status": e.Status, "Source": e.Source, "Visibility": e.Visibility, "CreatorID": e.CreatorID, "CreatorName": e.CreatorName, "IsDefaultForCreator": e.IsDefaultForCreator, "PositionLabel": e.PositionLabel, "DepartmentName": e.DepartmentName, "execution_locus": e.ExecutionLocus, "supports_model_selection": false, "supports_skill_bindings": false, "can_manage_skills": false}
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
		view, err := h.view(r.Context(), e)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		if h.Knowledge != nil {
			kbs, err := h.Knowledge.ListAgentKBs(r.Context(), e.ID)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
			view["knowledge_bases"] = kbs
		}
		items = append(items, view)
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
	view, err := h.view(r.Context(), *e)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if h.Knowledge != nil {
		kbs, err := h.Knowledge.ListAgentKBs(r.Context(), e.ID)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		view["knowledge_bases"] = kbs
	}
	encode.JSON(w, map[string]any{"agent": view, "bindings": []any{}})
}

func (h *AgentHandlers) view(ctx context.Context, e domagent.DigitalEmployee) (map[string]any, error) {
	out := agentView(e)
	if h.Apps != nil {
		apps, err := h.Apps.ListAgentApps(ctx, e.TenantID, e.ID)
		if err != nil {
			return nil, err
		}
		uuids := make([]string, 0, len(apps))
		labels := map[string]string{}
		for _, app := range apps {
			uuids = append(uuids, app.UUID)
			labels[app.UUID] = app.Name
		}
		metadata := out["metadata"].(map[string]any)
		metadata["selected_app_uuids"] = uuids
		metadata["selected_app_labels"] = labels
	}

	if e.RuntimeEnvironmentID != nil && h.Environments != nil {
		env, err := h.Environments.GetByID(ctx, *e.RuntimeEnvironmentID)
		if err != nil {
			if !errors.Is(err, apperr.ErrNotFound) {
				return nil, err
			}
		} else if env != nil && env.TenantID != nil && *env.TenantID == e.TenantID {
			out["runtime_environment_uuid"] = env.UUID
			out["runtime_environment_name"] = env.Name
			out["framework"] = env.Framework
		}
	}
	return out, nil
}
