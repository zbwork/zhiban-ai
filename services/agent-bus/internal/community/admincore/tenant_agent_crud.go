// Tenant employee handlers reused from the original admin router. K8s hosting is not exported.
package admincore

import (
	"context"
	"encoding/json"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	svcpos "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
	"net/http"
	"strconv"
	"strings"
)

func (h *Handlers) getAgent(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	bindings, _ := h.Agent.Bindings(r.Context(), e.ID)
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), e), "bindings": bindings})
}

type tenantAgentSaveReq struct {
	domagent.DigitalEmployee
	PositionIDs        *[]int64  `json:"position_ids"`
	PrimaryPositionID  *int64    `json:"primary_position_id"`
	SkillUUIDs         *[]string `json:"skill_uuids"`
	AppUUIDs           *[]string `json:"app_uuids"`
	KBUUIDs            *[]string `json:"kb_uuids"`
	KnowledgeBaseUUIDs *[]string `json:"knowledge_base_uuids"`
	KnowledgeBaseUuids *[]string `json:"knowledgeBaseUuids"`
}

// createAgent admin POST /api/admin/v1/tenant/agents
//
// M3 v1.1 §5.5: 支持 runtime_environment_uuid (与 bus §5.4 同款 service 闸)。
func (h *Handlers) createAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	var raw map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	var runtimeEnvUUID string
	if v, ok := raw["runtime_environment_uuid"]; ok {
		_ = json.Unmarshal(v, &runtimeEnvUUID)
	}
	bodyBytes, _ := json.Marshal(raw)
	var req tenantAgentSaveReq
	if err := json.Unmarshal(bodyBytes, &req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body := req.DigitalEmployee
	body.Source = "enterprise"
	var runtimeID int64
	if runtimeEnvUUID != "" {
		if h.RuntimeEnv == nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
			return
		}
		rt, err := h.RuntimeEnv.ResolveForAgentCreate(r.Context(), tid, accID, runtimeEnvUUID)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		id := rt.ID
		body.RuntimeEnvironmentID = &id
		runtimeID = rt.ID
	}
	var (
		e   *domagent.DigitalEmployee
		err error
	)
	templateUUID, _ := body.Metadata[svcagent.MetadataTemplateSourceKey].(string)
	templateUpdatedAt, _ := body.Metadata["template_source_updated_at"].(string)
	if strings.TrimSpace(templateUUID) != "" {
		e, err = h.Agent.CreateTenantFromTemplate(r.Context(), accID, tid, strings.TrimSpace(templateUUID), strings.TrimSpace(templateUpdatedAt), &body)
	} else {
		e, err = h.Agent.Create(r.Context(), accID, tid, &body)
	}
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if runtimeID > 0 && h.RuntimeEnv != nil {
		_, _, _ = h.RuntimeEnv.EnsurePendingInstance(r.Context(), tid, accID, runtimeID, nil)
	}
	if err := h.replaceTenantAgentEditorBindings(r.Context(), accID, tid, e, req); err != nil {
		if strings.TrimSpace(templateUUID) != "" {
			_ = h.Agent.Delete(r.Context(), accID, tid, e.ID)
		}
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.toAgentAdminDTO(r.Context(), e))
}

func (h *Handlers) updateAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	existing, err := h.Agent.Get(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req tenantAgentSaveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body := req.DigitalEmployee
	body.ID = existing.ID
	if err := h.replaceTenantAgentEditorBindings(r.Context(), accID, tid, existing, req); err != nil {
		encode.JSONError(w, err)
		return
	}
	e, err := h.Agent.Update(r.Context(), accID, tid, &body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.toAgentAdminDTO(r.Context(), e))
}

func (h *Handlers) replaceTenantAgentEditorBindings(ctx context.Context, accountID, tenantID int64, agent *domagent.DigitalEmployee, req tenantAgentSaveReq) error {
	if agent == nil {
		return apperr.ErrInternal.Withf("agent required")
	}
	if req.PositionIDs != nil {
		if h.Position == nil {
			return apperr.ErrInternal.Withf("position service not wired")
		}
		if err := h.Position.AssignAgent(ctx, tenantID, accountID, agent.ID, svcpos.AssignAgentInput{
			PositionIDs:       *req.PositionIDs,
			PrimaryPositionID: req.PrimaryPositionID,
		}); err != nil {
			return err
		}
	}
	if req.AppUUIDs != nil {
		if h.App == nil {
			return apperr.ErrInternal.Withf("app service not wired")
		}
		if err := h.App.BindAgentApps(ctx, tenantID, agent.ID, *req.AppUUIDs); err != nil {
			return err
		}
	}
	if req.SkillUUIDs != nil {
		if h.Skill == nil {
			return apperr.ErrInternal.Withf("skill service not wired")
		}
		if err := h.replaceTenantAgentSkills(ctx, accountID, tenantID, agent.UUID, *req.SkillUUIDs); err != nil {
			return err
		}
	}
	if kbUUIDs := tenantAgentSaveKBUUIDs(req); kbUUIDs != nil {
		if h.Knowledge == nil {
			return apperr.ErrInternal.Withf("knowledge service not wired")
		}
		if err := h.Knowledge.ReplaceAdminAgentKBBindings(ctx, accountID, tenantID, agent.ID, *kbUUIDs); err != nil {
			return err
		}
	}
	return nil
}

func tenantAgentSaveKBUUIDs(req tenantAgentSaveReq) *[]string {
	if req.KBUUIDs != nil {
		out := dedupeNonEmptyStrings(*req.KBUUIDs)
		return &out
	}
	if req.KnowledgeBaseUUIDs != nil {
		out := dedupeNonEmptyStrings(*req.KnowledgeBaseUUIDs)
		return &out
	}
	if req.KnowledgeBaseUuids != nil {
		out := dedupeNonEmptyStrings(*req.KnowledgeBaseUuids)
		return &out
	}
	return nil
}

func (h *Handlers) replaceTenantAgentSkills(ctx context.Context, accountID, tenantID int64, agentUUID string, skillUUIDs []string) error {
	views, err := h.Skill.ListAgentBindings(ctx, tenantID, agentUUID)
	if err != nil {
		return err
	}
	current := make(map[string]int64, len(views))
	for _, v := range views {
		if v.Skill == nil || v.Binding == nil {
			continue
		}
		current[v.Skill.UUID] = v.Binding.ID
	}
	next := make(map[string]struct{}, len(skillUUIDs))
	for _, skillUUID := range skillUUIDs {
		skillUUID = strings.TrimSpace(skillUUID)
		if skillUUID == "" {
			continue
		}
		next[skillUUID] = struct{}{}
		if _, ok := current[skillUUID]; ok {
			continue
		}
		in := domskill.AttachAgentSkillInput{
			TenantID:  tenantID,
			AgentUUID: agentUUID,
			SkillUUID: skillUUID,
		}
		if accountID > 0 {
			in.CreatedBy = &accountID
		}
		if _, err := h.Skill.AttachAgentSkill(ctx, in); err != nil {
			return err
		}
	}
	for skillUUID, bindingID := range current {
		if _, keep := next[skillUUID]; keep {
			continue
		}
		if err := h.Skill.DetachAgentSkill(ctx, tenantID, agentUUID, bindingID); err != nil {
			return err
		}
	}
	return nil
}

func (h *Handlers) deleteAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.Agent.Delete(r.Context(), accID, tid, e.ID); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// publishAgent M3 §3.2.2 + Batch 2C T2C.3: 发布 = OpenClaw 同步 + 快照新版本 + 更新 current_version。
// body 可选 {"notes": "..."}。
//
// OpenClaw 同步失败 (阶段 2) -> 409 + body `{code: "openclaw_sync_failed", error_kind, message}`,
// DB 保持 draft (绝不允许 DB published 而 OpenClaw 端缺失)。
func (h *Handlers) publishAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var body struct {
		Notes string `json:"notes"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	v, agent, err := h.Agent.PublishVersion(r.Context(), accID, tid, e.ID, body.Notes)
	if err != nil {
		if se, ok := svcagent.IsOpenClawSyncError(err); ok {
			respBody := map[string]any{
				"code":       "openclaw_sync_failed",
				"error_kind": se.ErrorKind,
				"stage":      se.Stage,
				"message":    "OpenClaw 同步失败, 请联系平台管理员检查 runtime",
			}
			if se.Cause != nil {
				respBody["detail"] = se.Cause.Error()
			}
			encode.JSONErrorWithCode(w, http.StatusConflict, respBody)
			return
		}
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), agent), "version": v})
}

// unpublishAgent 下架 = status archived; 运行端通过 runtime_resync_outbox 异步生成 agent_unregister。
// agent_unregister 只移除运行端 agent/workspace, 不删除 pod/workload; 入队失败不回滚下架。
func (h *Handlers) unpublishAgent(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	e, err := h.Agent.Get(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	agent, err := h.Agent.Unpublish(r.Context(), accID, tid, e.ID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), agent)})
}

func (h *Handlers) listAgents(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	source := strings.TrimSpace(r.URL.Query().Get("source"))
	if source != "" && source != "platform" && source != "enterprise" && source != "personal" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("source must be platform, enterprise, or personal"))
		return
	}
	status := r.URL.Query().Get("status")
	visibility := r.URL.Query().Get("visibility")
	if source == "platform" {
		status = "published"
		visibility = "platform"
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	creatorID, _ := strconv.ParseInt(r.URL.Query().Get("creator_id"), 10, 64)
	list, total, err := h.Agent.List(r.Context(), domagent.Filter{
		TenantID:               tid,
		CreatorID:              creatorID,
		Source:                 source,
		Visibility:             visibility,
		Status:                 status,
		Keyword:                r.URL.Query().Get("q"),
		Limit:                  limit,
		Offset:                 offset,
		ExcludeTenantInitSeeds: source != "platform",
		// source=platform 时仓储直接读取 tenant_id IS NULL 的已发布平台员工；
		// enterprise/personal 仍严格限定当前租户。
		IncludePlatformPresets: false,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]agentAdminDTO, 0, len(list))
	avatarURLs := make([]string, 0, len(list))
	for i := range list {
		if list[i].AvatarURL != "" {
			avatarURLs = append(avatarURLs, list[i].AvatarURL)
		}
	}
	previewURLs := h.resolveMediaURLMap(r.Context(), avatarURLs)
	for i := range list {
		dto := agentAdminDTO{DigitalEmployee: &list[i]}
		if list[i].AvatarURL != "" {
			dto.AvatarPreviewURL = safeAvatarPreviewURL(list[i].AvatarURL, previewURLs[list[i].AvatarURL])
		}
		items = append(items, dto)
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}

func (h *Handlers) agentCreatorDistribution(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Agent.CreatorDistribution(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

// tenantAgentTemplateDTO doc-15 P1：租户「从模板创建」picker 用的**只读白名单** DTO。
// 严格不含 runtime endpoint / api_key / secret_ref / 内部凭证（安全：模板库对租户只暴露展示+复制所需）。
