// drive_browse.go — /api/admin/v1/tenant/drive/* (M7 Phase B sprint §3.1; F06 Phase 2.4 cutover).
//
// 仅暴露 metadata: 空间列表 / 用量 / 文件元数据表; **不**给下载链接.
//
// 实现层在 F06 Phase 2.4 从 legacy svcdrive.AdminBrowse (引用 owner_id / deleted_at 等旧列, 在
// 新 schema 上跑 500) 切到 drivev3.AdminBrowseSvc; 接口/JSON shape 保持不变, admin 前端无需改动.
package admincore

import (
	"context"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	svcdrivev3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// DriveBrowseService — 租户 admin 浏览本租户云盘内容的窄抽象.
// 类型走 drivev3 (新 schema); JSON shape 与 legacy svcdrive 兼容.
type DriveBrowseService interface {
	ListTenantSpaces(ctx context.Context, tenantID int64) ([]svcdrivev3.AdminTenantSpaceItem, error)
	ListTenantFiles(ctx context.Context, tenantID int64, spaceUUID string, q svcdrivev3.AdminListFilesQuery) ([]svcdrivev3.AdminTenantFileItem, int64, error)
}

func (h *Handlers) listTenantDriveSpaces(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	items, err := h.DriveBrowse.ListTenantSpaces(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) listTenantDriveFiles(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	cursor, _ := strconv.ParseInt(q.Get("cursor"), 10, 64)
	items, next, err := h.DriveBrowse.ListTenantFiles(r.Context(), tid, r.PathValue("uuid"), svcdrivev3.AdminListFilesQuery{
		NameLike:   q.Get("q"),
		MimePrefix: q.Get("mime_prefix"),
		Limit:      limit,
		Cursor:     cursor,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "next_cursor": next})
}
