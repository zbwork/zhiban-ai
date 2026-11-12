// runtime_platform_types.go: 4 层模型 L1 只读端点
//
//   - GET /api/admin/v1/runtime/platform-types
//
// 详见 docs/design/agent-bus-admin-and-runtime-capabilities-design.md §2.3 L1。
package admincore

import (
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
)

// listPlatformTypes 返 [{code, display_name, description, doc_anchor, hosting_kinds}]
//
// admin 已登录即可读, 不挂细粒度 perm (与协议文档一致, 只读元数据)。
func (h *Handlers) listPlatformTypes(w http.ResponseWriter, r *http.Request) {
	if h.PlatformType == nil {
		// 兜底: 即使没注入 service 也返固定值
		encode.JSON(w, map[string]any{"items": []any{}})
		return
	}
	encode.JSON(w, map[string]any{"items": h.PlatformType.List(r.Context())})
}
