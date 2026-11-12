package clientcatalog

import (
	"context"
	"encoding/json"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
)

// ConversationToAgent 将 conversation_uuid 解到 agent_uuid 的窄抽象。
//
// 实际实现注入自 cmd/bus（PG 直查 conversations + digital_employees）。
type ConversationToAgent interface {
	AgentUUIDForConv(ctx context.Context, accountID, tenantID int64, convUUID string) (string, error)
}

// ----------------------------------------------------------------------------
// chip rail
// ----------------------------------------------------------------------------

func (h *Handlers) SkillRailConfig(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	if h.SkillConvLookup == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv lookup not wired"))
		return
	}
	convUUID := r.PathValue("uuid")
	if convUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("conversation uuid required"))
		return
	}
	aid := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	agentUUID, err := h.SkillConvLookup.AgentUUIDForConv(r.Context(), aid, tid, convUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	in := domskill.GetSkillRailInput{
		AccountID:      aid,
		TenantID:       tid,
		AgentUUID:      agentUUID,
		AcceptLanguage: r.Header.Get("Accept-Language"),
		ClientPlatform: r.Header.Get("X-Client-Platform"),
		ClientVersion:  r.Header.Get("X-Client-Version"),
		DeviceID:       r.Header.Get("X-Device-Id"),
	}
	rail, err := h.Skill.GetSkillRail(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.RailToDTO(r.Context(), convUUID, rail))
}

type RailItemDTO struct {
	SkillUUID        string          `json:"skill_uuid"`
	Code             string          `json:"code"`
	Name             string          `json:"name"`
	IconURL          string          `json:"icon_url,omitempty"`
	Kind             string          `json:"kind"`
	ExecutionMode    string          `json:"execution_mode"`
	Pinned           bool            `json:"pinned"`
	SortOrder        int             `json:"sort_order"`
	Source           string          `json:"source"`
	DefaultParams    json.RawMessage `json:"default_params"`
	Version          string          `json:"version,omitempty"`
	VersionUUID      string          `json:"version_uuid,omitempty"`
	InputChipsSchema json.RawMessage `json:"input_chips_schema"`
	BillingType      string          `json:"billing_type"`
	PricingMode      string          `json:"pricing_mode"`
}

func toItem(it domskill.SkillRailItem, resolvedIcons map[string]string) RailItemDTO {
	dp := json.RawMessage(it.DefaultParams)
	if len(dp) == 0 {
		dp = json.RawMessage("{}")
	}
	chips := json.RawMessage(it.InputChipsSchema)
	if len(chips) == 0 {
		chips = json.RawMessage("[]")
	}
	iconURL := it.IconURL
	if resolved, ok := resolvedIcons[it.IconURL]; ok {
		iconURL = resolved
	}
	return RailItemDTO{
		SkillUUID: it.SkillUUID, Code: it.Code, Name: it.Name, IconURL: iconURL,
		Kind: it.Kind, ExecutionMode: it.ExecutionMode, Pinned: it.Pinned,
		SortOrder: it.SortOrder, Source: it.Source, DefaultParams: dp,
		Version: it.Version, VersionUUID: it.VersionUUID, InputChipsSchema: chips,
		BillingType: it.BillingType, PricingMode: it.PricingMode,
	}
}

func (h *Handlers) RailToDTO(ctx context.Context, convUUID string, r *domskill.SkillRail) map[string]any {
	iconURLs := make([]string, 0, len(r.ChipRail)+len(r.MoreDrawer))
	for _, it := range r.ChipRail {
		if it.IconURL != "" {
			iconURLs = append(iconURLs, it.IconURL)
		}
	}
	for _, it := range r.MoreDrawer {
		if it.IconURL != "" {
			iconURLs = append(iconURLs, it.IconURL)
		}
	}
	resolvedIcons := h.resolveMediaURLMap(ctx, iconURLs)
	chip := make([]RailItemDTO, 0, len(r.ChipRail))
	for _, it := range r.ChipRail {
		chip = append(chip, toItem(it, resolvedIcons))
	}
	more := make([]RailItemDTO, 0, len(r.MoreDrawer))
	for _, it := range r.MoreDrawer {
		more = append(more, toItem(it, resolvedIcons))
	}
	return map[string]any{
		"conversation_uuid": convUUID,
		"agent_uuid":        r.AgentUUID,
		"chip_rail":         chip,
		"more_drawer":       more,
		"tool_rail_system": []map[string]any{
			{"key": "attach_file", "icon": "plus"},
		},
		"config_version":    r.ConfigVersion,
		"cache_ttl_seconds": r.CacheTTLSeconds,
	}
}
