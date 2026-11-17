// Original template picker DTO and handlers, matching the existing community editor.
package admincore

import (
	"context"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	"net/http"
	"strconv"
	"time"
)

type tenantAgentTemplateDTO struct {
	UUID                 string                      `json:"uuid"`
	Name                 string                      `json:"name"`
	PositionLabel        string                      `json:"position_label"`
	Intro                string                      `json:"intro"`
	Description          string                      `json:"description"`
	AvatarURL            string                      `json:"avatar_url"`
	AvatarPreviewURL     string                      `json:"avatar_preview_url"`
	WelcomeMsg           string                      `json:"welcome_msg"`
	SystemPrompt         string                      `json:"system_prompt"`
	RuntimeEnvironmentID *int64                      `json:"runtime_environment_id"`
	ExecutionLocus       string                      `json:"execution_locus"`
	LocalEngine          string                      `json:"local_engine"`
	UpdatedAt            string                      `json:"updated_at"`
	KnowledgeBases       []svckb.AgentKBSummary      `json:"knowledge_bases"`
	Tags                 []string                    `json:"tags"`
	ModelPrimary         string                      `json:"model_primary"`
	AgentKind            string                      `json:"agent_kind"` // single / orchestrator
	Orchestration        *tenantAgentTemplateOrchDTO `json:"orchestration,omitempty"`
	SkillUUIDs           []string                    `json:"skill_uuids"`
	AppUUIDs             []string                    `json:"app_uuids"`
}

type tenantAgentTemplateOrchDTO struct {
	Strategy           string   `json:"strategy"`
	ChildTemplateUUIDs []string `json:"child_template_uuids"`
}

// listTenantAgentTemplates doc-15 P1：列出已发布平台模板，供租户后台「从模板创建」选择 + 预填。
// 数据源 = agent.Service.ListPublishedPlatformTemplates（fail-closed 只返已发布平台模板），不是本地示例。
func (h *Handlers) listTenantAgentTemplates(w http.ResponseWriter, r *http.Request) {
	_ = middleware.MustTenantID(r.Context()) // 仅鉴权（tenant.agent.create）；模板是平台资产，与具体租户无关
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	kind := r.URL.Query().Get("kind") // single / orchestrator / 空=全部
	q := r.URL.Query().Get("q")
	templates, total, err := h.Agent.List(r.Context(), domagent.Filter{Source: "platform", Visibility: "platform", Status: "published", AgentKind: kind, Keyword: q, Limit: limit, Offset: offset})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	avatarURLs := make([]string, 0, len(templates))
	for i := range templates {
		if templates[i].AvatarURL != "" {
			avatarURLs = append(avatarURLs, templates[i].AvatarURL)
		}
	}
	previewURLs := h.resolveMediaURLMap(r.Context(), avatarURLs)

	items := make([]tenantAgentTemplateDTO, 0, len(templates))
	for i := range templates {
		t := &templates[i]
		avatar := t.AvatarURL
		if t.AvatarURL != "" {
			if pv := previewURLs[t.AvatarURL]; pv != "" {
				avatar = pv
			}
		}
		dto, err := h.toTenantAgentTemplateDTO(r.Context(), t, avatar)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		items = append(items, dto)
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

// getTenantAgentTemplate doc-15 P6：单个已发布平台模板详情，供「从模板创建」进入新建页时精确预填。
// fail-closed 由 service.GetPublishedPlatformTemplate 保证（非已发布平台模板 → ErrNotFound）。
func (h *Handlers) getTenantAgentTemplate(w http.ResponseWriter, r *http.Request) {
	_ = middleware.MustTenantID(r.Context()) // 仅鉴权（tenant.agent.create）；模板是平台资产，与具体租户无关
	uuid := r.PathValue("uuid")
	tpl, err := h.Agent.GetPublishedPlatformTemplate(r.Context(), uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	avatar := tpl.AvatarURL
	if tpl.AvatarURL != "" {
		if m := h.resolveMediaURLMap(r.Context(), []string{tpl.AvatarURL}); m[tpl.AvatarURL] != "" {
			avatar = m[tpl.AvatarURL]
		}
	}
	dto, err := h.toTenantAgentTemplateDTO(r.Context(), tpl, avatar)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, dto)
}

// toTenantAgentTemplateDTO 把一个平台模板行映射为只读白名单 DTO（list / detail 共用，确保两条路径暴露面一致）。
// avatar 入参为已解析的可展示头像 URL（list 走批量 map，detail 走单条 resolve）。
// 严格不含 runtime endpoint / api_key / secret_ref / 内部凭证。
func (h *Handlers) toTenantAgentTemplateDTO(ctx context.Context, t *domagent.DigitalEmployee, avatar string) (tenantAgentTemplateDTO, error) {
	var skillUUIDs, appUUIDs []string
	binds, err := h.Agent.Bindings(ctx, t.ID)
	if err != nil {
		return tenantAgentTemplateDTO{}, err
	}
	for _, b := range binds {
		switch b.CapabilityKind {
		case "composer_skill":
			skillUUIDs = append(skillUUIDs, b.CapabilityUUID)
		case "app":
			appUUIDs = append(appUUIDs, b.CapabilityUUID)
		}
	}
	var kbs []svckb.AgentKBSummary
	if h.Knowledge != nil {
		kbs, err = h.Knowledge.ListAgentKBs(ctx, t.ID)
		if err != nil {
			return tenantAgentTemplateDTO{}, err
		}
	}
	prompt, _ := t.Metadata["system_prompt"].(string)
	kind, _ := t.Metadata["agent_kind"].(string)
	if kind == "" {
		kind = "single"
	}
	dto := tenantAgentTemplateDTO{
		UUID:                 t.UUID,
		Name:                 t.Name,
		PositionLabel:        t.PositionLabel,
		Intro:                t.Intro,
		Description:          t.Description,
		AvatarURL:            t.AvatarURL,
		AvatarPreviewURL:     avatar,
		WelcomeMsg:           t.WelcomeMsg,
		SystemPrompt:         prompt,
		RuntimeEnvironmentID: t.RuntimeEnvironmentID,
		ExecutionLocus:       t.ExecutionLocus,
		LocalEngine:          t.LocalEngine,
		UpdatedAt:            t.UpdatedAt.Format(time.RFC3339Nano),
		KnowledgeBases:       kbs,
		Tags:                 t.Tags,
		ModelPrimary:         t.ModelPrimary,
		AgentKind:            kind,
		SkillUUIDs:           skillUUIDs,
		AppUUIDs:             appUUIDs,
	}
	if kind == "orchestrator" {
		orch := &tenantAgentTemplateOrchDTO{}
		if om, ok := t.Metadata["orchestration"].(map[string]any); ok {
			orch.Strategy, _ = om["strategy"].(string)
			if rawKids, ok := om["child_agent_uuids"].([]any); ok {
				for _, c := range rawKids {
					if cu, _ := c.(string); cu != "" {
						orch.ChildTemplateUUIDs = append(orch.ChildTemplateUUIDs, cu)
					}
				}
			}
		}
		dto.Orchestration = orch
	}
	return dto, nil
}
