package admincore

import (
	"context"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
	"strings"
)

type agentAdminDTO struct {
	*domagent.DigitalEmployee
	AvatarPreviewURL string `json:"AvatarPreviewURL,omitempty"`
}

func (h *Handlers) toAgentAdminDTO(ctx context.Context, e *domagent.DigitalEmployee) agentAdminDTO {
	dto := agentAdminDTO{DigitalEmployee: e}
	if e != nil && e.AvatarURL != "" {
		dto.AvatarPreviewURL = safeAvatarPreviewURL(e.AvatarURL, h.resolveMediaURL(ctx, e.AvatarURL))
	}
	return dto
}

func safeAvatarPreviewURL(raw, resolved string) string {
	raw = strings.TrimSpace(raw)
	resolved = strings.TrimSpace(resolved)
	if resolved == "" {
		return ""
	}
	if strings.HasPrefix(raw, "oss://") && resolved == raw {
		return ""
	}
	return resolved
}

func (h *Handlers) listPlatformPresetAgents(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	list, total, err := h.Agent.List(r.Context(), domagent.Filter{
		Source:     "platform",
		Visibility: "platform",
		Status:     r.URL.Query().Get("status"),
		Keyword:    r.URL.Query().Get("q"),
		Limit:      limit,
		Offset:     offset,
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

func (h *Handlers) getPlatformPresetAgent(w http.ResponseWriter, r *http.Request) {
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
	bindings, _ := h.Agent.Bindings(r.Context(), e.ID)
	encode.JSON(w, map[string]any{"agent": h.toAgentAdminDTO(r.Context(), e), "bindings": bindings})
}
