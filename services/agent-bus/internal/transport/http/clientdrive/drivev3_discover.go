// drivev3_discover.go — F06 Phase 2.2e + 2.2f: recent + search + flat list 端点.
//
// 3 个 URL:
//
//	GET /api/agent-bus/v1/drive/files:recent          ACL viewer+ on space (coarse) — 2.2e
//	GET /api/agent-bus/v1/drive/files:search?q=...    GIN tsvector + ACL coarse 同上 — 2.2e
//	GET /api/agent-bus/v1/drive/files?space_uuid=...  ACL viewer+ on space (单 space 列表) — 2.2f
package clientdrive

import (
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdriv3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// driveV3FilesRecent GET /drive/files:recent?limit=...: 列 caller viewer+ space 最近文件.
func (h *Handlers) DriveV3FilesRecent(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Discover == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 discover service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	limit := parseLimitQuery(r, 50, 200)
	resp, err := h.Drivev3Discover.RecentFiles(r.Context(), accountID, tenantID, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FilesSearch GET /drive/files:search?q=...&limit=...: GIN tsvector 搜文件名.
func (h *Handlers) DriveV3FilesSearch(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Discover == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 discover service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	q := r.URL.Query().Get("q")
	limit := parseLimitQuery(r, 50, 200)
	resp, err := h.Drivev3Discover.SearchFiles(r.Context(), accountID, tenantID, q, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FilesList GET /drive/files?space_uuid=...&folder_uuid=...&q=...&mime_prefix=...&limit=...&cursor=...:
// Phase 2.2f flat list, 替换 legacy h.Drive.ListFiles. ACL viewer+ on space.
func (h *Handlers) DriveV3FilesList(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Discover == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 discover service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	q := r.URL.Query()
	cursor, _ := strconv.ParseInt(q.Get("cursor"), 10, 64)
	if cursor < 0 {
		cursor = 0
	}
	req := svcdriv3.ListReq{
		SpaceUUID:  q.Get("space_uuid"),
		FolderUUID: q.Get("folder_uuid"),
		RootOnly:   q.Get("root") == "1" || q.Get("root") == "true",
		Q:          q.Get("q"),
		MimePrefix: q.Get("mime_prefix"),
		Limit:      parseLimitQuery(r, 50, 200),
		CursorID:   cursor,
	}
	resp, err := h.Drivev3Discover.ListFiles(r.Context(), accountID, tenantID, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// parseLimitQuery 解析 ?limit=N; 缺失 / 非法 → defaultN; > maxN → maxN.
func parseLimitQuery(r *http.Request, defaultN, maxN int) int {
	v := r.URL.Query().Get("limit")
	if v == "" {
		return defaultN
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return defaultN
	}
	if n > maxN {
		return maxN
	}
	return n
}
