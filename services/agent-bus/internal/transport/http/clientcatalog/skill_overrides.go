package clientcatalog

import (
	"encoding/json"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"io"
	"net/http"
	"time"
)

type overrideBody struct {
	SkillUUID string  `json:"skill_uuid"`
	Behavior  string  `json:"behavior"`
	ExpiresAt *string `json:"expires_at,omitempty"`
}

func (h *Handlers) SkillOverrideUpsert(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	body, err := readBusJSON[overrideBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	in := domskill.UpsertUserOverrideInput{
		AccountID: middleware.MustAccountID(r.Context()),
		TenantID:  middleware.MustTenantID(r.Context()),
		AgentUUID: agentUUID,
		SkillUUID: body.SkillUUID,
		Behavior:  body.Behavior,
	}
	if body.ExpiresAt != nil && *body.ExpiresAt != "" {
		t, perr := time.Parse(time.RFC3339, *body.ExpiresAt)
		if perr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("expires_at invalid"))
			return
		}
		in.ExpiresAt = &t
	}
	o, err := h.Skill.UpsertUserOverride(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"override_id": o.ID,
		"account_id":  o.AccountID,
		"agent_uuid":  agentUUID,
		"skill_uuid":  body.SkillUUID,
		"behavior":    o.Behavior,
		"expires_at":  o.ExpiresAt,
	})
}

func (h *Handlers) SkillOverrideDelete(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	skillUUID := r.PathValue("skill_uuid")
	aid := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	if err := h.Skill.DeleteUserOverride(r.Context(), aid, tid, agentUUID, skillUUID); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----------------------------------------------------------------------------
// builtin handshake（§3.3.D）
// ----------------------------------------------------------------------------

type handshakeBody struct {
	ClientPlatform       string   `json:"client_platform"`
	ClientVersion        string   `json:"client_version"`
	DeviceID             string   `json:"device_id"`
	SupportedBuiltinKeys []string `json:"supported_builtin_keys"`
}

func (h *Handlers) SkillHandshake(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	body, err := readBusJSON[handshakeBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	in := domskill.UpsertHandshakeInput{
		AccountID:            middleware.MustAccountID(r.Context()),
		ClientPlatform:       body.ClientPlatform,
		ClientVersion:        body.ClientVersion,
		DeviceID:             body.DeviceID,
		SupportedBuiltinKeys: body.SupportedBuiltinKeys,
	}
	if err := h.Skill.UpsertHandshake(r.Context(), in); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

func readBusJSON[T any](r *http.Request) (T, error) {
	var out T
	if r.Body == nil {
		return out, apperr.ErrInvalidParams.Withf("empty body")
	}
	defer r.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024))
	if err != nil {
		return out, apperr.ErrInvalidParams.Wrap(err)
	}
	if len(raw) == 0 {
		return out, apperr.ErrInvalidParams.Withf("empty body")
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return out, apperr.ErrInvalidParams.Wrap(err)
	}
	return out, nil
}
