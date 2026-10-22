package clientcatalog

import (
	"encoding/json"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communityagent"
	"io"
	"net/http"
	"strings"
)

func personalInput(w http.ResponseWriter, r *http.Request) (svc.PersonalInput, error) {
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	bad := apperr.ErrInvalidParams.Withf("unsupported community employee configuration")
	if err := dec.Decode(&raw); err != nil {
		return svc.PersonalInput{}, bad
	}
	if dec.Decode(new(any)) != io.EOF {
		return svc.PersonalInput{}, bad
	}
	in := svc.PersonalInput{Metadata: map[string]any{}}
	for key, val := range raw {
		var err error
		switch key {
		case "name":
			err = json.Unmarshal(val, &in.Name)
		case "intro":
			err = json.Unmarshal(val, &in.Intro)
		case "description":
			err = json.Unmarshal(val, &in.Description)
		case "welcome_msg":
			err = json.Unmarshal(val, &in.WelcomeMsg)
		case "avatarUrl":
			err = json.Unmarshal(val, &in.AvatarURL)
		case "positionLabel", "position":
			err = json.Unmarshal(val, &in.PositionLabel)
		case "tags", "badges":
			err = json.Unmarshal(val, &in.Tags)
		case "status":
			err = json.Unmarshal(val, &in.Status)
		case "runtime_environment_uuid":
			err = json.Unmarshal(val, &in.RuntimeUUID)
		case "source", "visibility", "execution_locus", "model_source":
			var v string
			err = json.Unmarshal(val, &v)
			allowed := map[string]string{"source": "personal", "visibility": "private", "execution_locus": "cloud", "model_source": "platform_whitelist"}
			if v != allowed[key] {
				return in, bad
			}
		case "contact_enabled", "allow_invite_to_group", "supports_group_chat":
			var v bool
			err = json.Unmarshal(val, &v)
			if !v {
				return in, bad
			}
		case "model_primary":
			var v string
			err = json.Unmarshal(val, &v)
			if strings.TrimSpace(v) != "" {
				return in, bad
			}
		case "metadata":
			var meta map[string]json.RawMessage
			err = json.Unmarshal(val, &meta)
			for k, v := range meta {
				switch k {
				case "system_prompt", "agent_key":
					var text string
					if json.Unmarshal(v, &text) != nil || len(text) > 16384 {
						return in, bad
					}
					in.Metadata[k] = text
				case "allow_internet_access":
					var enabled bool
					if json.Unmarshal(v, &enabled) != nil {
						return in, bad
					}
					in.Metadata[k] = enabled
				case "selected_knowledge_base_uuids":
					var list []string
					if json.Unmarshal(v, &list) != nil || len(list) > 50 {
						return in, bad
					}
				case "selected_knowledge_base_labels":
					var labels map[string]string
					if json.Unmarshal(v, &labels) != nil || len(labels) > 50 {
						return in, bad
					}
				case "selected_app_uuids":
					var list []string
					if json.Unmarshal(v, &list) != nil || len(list) > 50 {
						return in, bad
					}
				case "selected_app_labels":
					var labels map[string]string
					if json.Unmarshal(v, &labels) != nil || len(labels) > 50 {
						return in, bad
					}
				default:
					return in, bad
				}
			}
		default:
			return in, bad
		}
		if err != nil {
			return in, bad
		}
	}
	return in, nil
}
func (h *AgentHandlers) Create(w http.ResponseWriter, r *http.Request) { h.save(w, r, "") }
func (h *AgentHandlers) Update(w http.ResponseWriter, r *http.Request) {
	h.save(w, r, r.PathValue("uuid"))
}
func (h *AgentHandlers) save(w http.ResponseWriter, r *http.Request, uuid string) {
	in, err := personalInput(w, r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	e, err := h.Personal.Save(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), uuid, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, agentView(*e))
}
func (h *AgentHandlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.Personal.Delete(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// EmptyBindings handles the post-save capability replacement contract.
func (h *AgentHandlers) EmptyBindings(w http.ResponseWriter, r *http.Request) {
	employee, err := h.Personal.Get(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var body map[string][]string
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	if err := dec.Decode(&body); err != nil || dec.Decode(new(any)) != io.EOF || len(body) != 1 {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	keys := map[string]string{"skill-bindings": "skill_slugs", "app-bindings": "app_uuids", "kb-bindings": "kb_uuids"}
	field := r.PathValue("field")
	key, ok := keys[field]
	values, exists := body[key]
	if !ok || !exists || len(values) > 50 {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	if field == "skill-bindings" && h.Skills != nil {
		err = h.Skills.ReplaceClientAgentSkillBindings(r.Context(), domskill.ReplaceClientAgentSkillBindingsInput{AccountID: middleware.MustAccountID(r.Context()), TenantID: middleware.MustTenantID(r.Context()), AgentUUID: employee.UUID, SkillCodes: values})
		if err != nil {
			encode.JSONError(w, err)
			return
		}
	} else if field == "app-bindings" && h.Apps != nil {
		err = h.Apps.BindAgentApps(r.Context(), middleware.MustTenantID(r.Context()), employee.ID, values)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
	} else if field == "kb-bindings" && h.Knowledge != nil {
		err = h.Knowledge.ReplaceAgentKBBindings(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), employee.ID, values)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
	} else if len(values) > 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("community runtime does not support this capability"))
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
