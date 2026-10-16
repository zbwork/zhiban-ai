package clientcatalog

import (
	"context"
	"encoding/json"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	"net/http"
	"strconv"
	"strings"
)

type Handlers struct {
	Skill        *svcskill.Service
	ResolveMedia func(context.Context, []string) map[string]string
}

func (h *Handlers) resolveMediaURLMap(ctx context.Context, uris []string) map[string]string {
	if h.ResolveMedia != nil {
		return h.ResolveMedia(ctx, uris)
	}
	return nil
}
func (h *Handlers) Skills(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	q := r.URL.Query()
	in := domskill.ListClientSkillsInput{
		AccountID: middleware.MustAccountID(r.Context()),
		TenantID:  middleware.MustTenantID(r.Context()),
		AgentUUID: q.Get("agent_uuid"),
		Keyword:   q.Get("q"),
		Source:    q.Get("source"),
		SortBy:    q.Get("sort_by"),
		SortOrder: q.Get("sort_order"),
	}
	if c := q.Get("category_id"); c != "" {
		if v, err := strconv.ParseInt(c, 10, 64); err == nil {
			in.CategoryID = &v
		}
	}
	if l := q.Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil {
			in.Limit = v
		}
	}
	if o := q.Get("offset"); o != "" {
		if v, err := strconv.Atoi(o); err == nil {
			in.Offset = v
		}
	}
	views, total, err := h.Skill.ListClientSkills(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	type item struct {
		SkillUUID           string          `json:"skill_uuid"`
		Code                string          `json:"code"`
		Name                string          `json:"name"`
		Description         string          `json:"description,omitempty"`
		UsageExample        string          `json:"usage_example,omitempty"`
		UsageExampleImages  json.RawMessage `json:"usage_example_images"`
		Kind                string          `json:"kind"`
		IconURL             string          `json:"icon_url,omitempty"`
		Source              string          `json:"source"`
		ScopeKind           string          `json:"scope_kind"`
		Status              string          `json:"status"`
		CategoryID          *int64          `json:"category_id,omitempty"`
		IsAttachedToAgent   bool            `json:"is_attached_to_agent"`
		IsTemporaryAttached bool            `json:"is_temporary_attached"`
		InstallCount        int64           `json:"install_count"`
		LatestVersion       string          `json:"latest_version,omitempty"`
		BillingType         string          `json:"billing_type"`
		PricingMode         string          `json:"pricing_mode"`
	}
	items := make([]item, 0, len(views))
	iconURLs := make([]string, 0, len(views))
	for _, v := range views {
		if v.Skill.IconURL != "" {
			iconURLs = append(iconURLs, v.Skill.IconURL)
		}
	}
	resolvedIcons := h.resolveMediaURLMap(r.Context(), iconURLs)
	for _, v := range views {
		iconURL := v.Skill.IconURL
		if resolved, ok := resolvedIcons[v.Skill.IconURL]; ok {
			iconURL = resolved
		}
		items = append(items, item{
			SkillUUID: v.Skill.UUID, Code: v.Skill.Code, Name: v.Skill.Name,
			Description: v.Skill.Description, UsageExample: v.Skill.UsageExample,
			UsageExampleImages: h.resolveSkillUsageExampleImages(r.Context(), json.RawMessage(defaultJSONArr(v.Skill.UsageExampleImages))),
			Kind:               v.Skill.Kind, IconURL: iconURL,
			Source: v.Skill.Source, ScopeKind: v.Skill.ScopeKind, Status: v.Skill.Status,
			CategoryID:        v.Skill.CategoryID,
			IsAttachedToAgent: v.IsAttachedToAgent, IsTemporaryAttached: v.IsTemporaryAttached,
			InstallCount:  v.Skill.InstallCount,
			LatestVersion: v.LatestVersion,
			BillingType:   v.Skill.BillingType, PricingMode: v.Skill.PricingMode,
		})
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}

type skillUsageExampleImageDTO struct {
	StorageURI string `json:"storage_uri,omitempty"`
	URL        string `json:"url"`
	FileName   string `json:"file_name,omitempty"`
}

func (h *Handlers) resolveSkillUsageExampleImages(ctx context.Context, raw json.RawMessage) json.RawMessage {
	items := parseSkillUsageExampleImages(raw)
	if len(items) == 0 {
		return json.RawMessage(`[]`)
	}
	uris := make([]string, 0, len(items))
	for _, item := range items {
		if item.StorageURI != "" {
			uris = append(uris, item.StorageURI)
		}
	}
	resolved := h.resolveMediaURLMap(ctx, uris)
	out := make([]skillUsageExampleImageDTO, 0, len(items))
	for _, item := range items {
		url := item.StorageURI
		if v, ok := resolved[item.StorageURI]; ok {
			url = v
		}
		out = append(out, skillUsageExampleImageDTO{
			URL:      url,
			FileName: item.FileName,
		})
	}
	buf, _ := json.Marshal(out)
	return json.RawMessage(buf)
}

func parseSkillUsageExampleImages(raw json.RawMessage) []skillUsageExampleImageDTO {
	if len(raw) == 0 {
		return nil
	}
	var objects []skillUsageExampleImageDTO
	if err := json.Unmarshal(raw, &objects); err == nil {
		out := objects[:0]
		for _, item := range objects {
			if item.StorageURI == "" {
				item.StorageURI = item.URL
			}
			if item.StorageURI != "" {
				out = append(out, item)
			}
		}
		return out
	}
	var urls []string
	if err := json.Unmarshal(raw, &urls); err != nil {
		return nil
	}
	out := make([]skillUsageExampleImageDTO, 0, len(urls))
	for _, url := range urls {
		if strings.TrimSpace(url) != "" {
			out = append(out, skillUsageExampleImageDTO{StorageURI: strings.TrimSpace(url)})
		}
	}
	return out
}

func defaultJSONArr(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte(`[]`)
	}
	return raw
}

func (h *Handlers) Categories(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill service not wired"))
		return
	}
	categories, total, err := h.Skill.ListCategories(r.Context(), domskill.DictListFilter{
		Status: domskill.StatusActive,
		Limit:  50,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	type item struct {
		ID        int64  `json:"id"`
		Code      string `json:"code"`
		Name      string `json:"name"`
		SortOrder int    `json:"sort_order"`
	}
	items := make([]item, 0, len(categories))
	for _, category := range categories {
		items = append(items, item{
			ID:        category.ID,
			Code:      category.Code,
			Name:      category.Name,
			SortOrder: category.SortOrder,
		})
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}
