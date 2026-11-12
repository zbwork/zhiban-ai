package admincore

import (
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
)

// listAgentModelOptions GET /api/admin/v1/{platform|tenant}/agent-model-options
//
// 数字员工"主模型"下拉选项。来源为部署配置 aigc.agent_models, 不动态枚举 AIGC 网关。
func (h *Handlers) listAgentModelOptions(w http.ResponseWriter, r *http.Request) {
	items := make([]map[string]any, 0, len(h.AgentModelOptions))
	for i, id := range h.AgentModelOptions {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		items = append(items, map[string]any{
			"id":      id,
			"label":   id,
			"default": i == 0,
		})
	}
	encode.JSON(w, map[string]any{"items": items})
}
