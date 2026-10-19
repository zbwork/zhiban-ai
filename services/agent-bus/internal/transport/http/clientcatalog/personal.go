package clientcatalog

import (
	"encoding/json"
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
				case "selected_app_uuids", "selected_knowledge_base_uuids":
					var list []string
					if json.Unmarshal(v, &list) != nil || len(list) > 0 {
						return in, bad
					}
				case "selected_app_labels", "selected_knowledge_base_labels":
					var labels map[string]string
					if json.Unmarshal(v, &labels) != nil || len(labels) > 0 {
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
