package admincore

import (
	"context"
	"encoding/json"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strings"
)

type platformPresetAgentCreateReq struct {
	domagent.DigitalEmployee
	SkillUUIDs []string `json:"skill_uuids"`
	AppUUIDs   []string `json:"app_uuids"`
}

func (h *Handlers) createPlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	var req platformPresetAgentCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body := req.DigitalEmployee
	e, err := h.Agent.CreatePlatform(r.Context(), accID, &body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.addPlatformPresetBindings(r.Context(), e.ID, req.SkillUUIDs, req.AppUUIDs); err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.syncPlatformPresetRuntimeBindings(r.Context(), accID, e.ID, req.SkillUUIDs, req.AppUUIDs); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.toAgentAdminDTO(r.Context(), e))
}

func (h *Handlers) updatePlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	existing, err := h.Agent.Get(r.Context(), 0, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if existing.Source != "platform" || existing.Visibility != "platform" {
		encode.JSONError(w, apperr.ErrForbidden.Withf("not a platform preset agent"))
		return
	}
	var req platformPresetAgentCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body := req.DigitalEmployee
	body.ID = existing.ID
	e, err := h.Agent.UpdatePlatform(r.Context(), accID, &body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.replacePlatformPresetBindings(r.Context(), e.ID, req.SkillUUIDs, req.AppUUIDs); err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.syncPlatformPresetRuntimeBindings(r.Context(), accID, e.ID, req.SkillUUIDs, req.AppUUIDs); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.toAgentAdminDTO(r.Context(), e))
}

func (h *Handlers) deletePlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), 0, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if e.Source != "platform" || e.Visibility != "platform" {
		encode.JSONError(w, apperr.ErrForbidden.Withf("not a platform preset agent"))
		return
	}
	if err := h.Agent.Delete(r.Context(), accID, 0, e.ID); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) publishPlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), 0, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if e.Source != "platform" || e.Visibility != "platform" {
		encode.JSONError(w, apperr.ErrForbidden.Withf("not a platform preset agent"))
		return
	}
	var body struct {
		Notes string `json:"notes"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	v, agent, err := h.Agent.PublishVersion(r.Context(), accID, 0, e.ID, body.Notes)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), agent), "version": v})
}

func (h *Handlers) unpublishPlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), 0, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if e.Source != "platform" || e.Visibility != "platform" {
		encode.JSONError(w, apperr.ErrForbidden.Withf("not a platform preset agent"))
		return
	}
	agent, err := h.Agent.Unpublish(r.Context(), accID, 0, e.ID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), agent)})
}

func (h *Handlers) addPlatformPresetBindings(ctx context.Context, agentID int64, skillUUIDs, appUUIDs []string) error {
	sortOrder := 0
	for _, uuid := range uniqueStrings(skillUUIDs) {
		if uuid == "" {
			continue
		}
		sortOrder += 10
		if _, err := h.Agent.AddBinding(ctx, &domagent.CapabilityBinding{
			DigitalEmpID:   agentID,
			CapabilityKind: "composer_skill",
			CapabilityUUID: uuid,
			Source:         "borrow",
			SortOrder:      sortOrder,
		}); err != nil {
			return apperr.ErrInvalidParams.Withf("attach skill %s failed: %v", uuid, err)
		}
	}
	for _, uuid := range uniqueStrings(appUUIDs) {
		if uuid == "" {
			continue
		}
		sortOrder += 10
		if _, err := h.Agent.AddBinding(ctx, &domagent.CapabilityBinding{
			DigitalEmpID:   agentID,
			CapabilityKind: "app",
			CapabilityUUID: uuid,
			Source:         "borrow",
			SortOrder:      sortOrder,
		}); err != nil {
			return apperr.ErrInvalidParams.Withf("attach app %s failed: %v", uuid, err)
		}
	}
	return nil
}

func (h *Handlers) replacePlatformPresetBindings(ctx context.Context, agentID int64, skillUUIDs, appUUIDs []string) error {
	current, err := h.Agent.Bindings(ctx, agentID)
	if err != nil {
		return err
	}
	next := map[string]bool{}
	for _, uuid := range uniqueStrings(skillUUIDs) {
		next["composer_skill:"+uuid] = true
	}
	for _, uuid := range uniqueStrings(appUUIDs) {
		next["app:"+uuid] = true
	}
	for _, b := range current {
		if b.CapabilityKind != "composer_skill" && b.CapabilityKind != "app" {
			continue
		}
		key := b.CapabilityKind + ":" + b.CapabilityUUID
		if !next[key] {
			if err := h.Agent.RemoveBinding(ctx, b.ID); err != nil {
				return err
			}
		} else {
			delete(next, key)
		}
	}
	skillRest := []string{}
	appRest := []string{}
	for key := range next {
		if strings.HasPrefix(key, "composer_skill:") {
			skillRest = append(skillRest, strings.TrimPrefix(key, "composer_skill:"))
		}
		if strings.HasPrefix(key, "app:") {
			appRest = append(appRest, strings.TrimPrefix(key, "app:"))
		}
	}
	return h.addPlatformPresetBindings(ctx, agentID, skillRest, appRest)
}

func (h *Handlers) syncPlatformPresetRuntimeBindings(ctx context.Context, accountID, agentID int64, skillUUIDs, appUUIDs []string) error {
	if h.Skill == nil || h.App == nil {
		return apperr.ErrInternal.Withf("skill/app service not wired")
	}
	if err := h.Skill.ReplacePlatformAgentSkills(ctx, agentID, uniqueStrings(skillUUIDs), accountID); err != nil {
		return err
	}
	return h.App.BindAgentApps(ctx, 0, agentID, uniqueStrings(appUUIDs))
}

func uniqueStrings(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, v := range in {
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}
