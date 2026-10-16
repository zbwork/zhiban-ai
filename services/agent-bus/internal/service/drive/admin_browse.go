// admin_browse.go — F06 Phase 2.4: admin "看本租户云盘内容" 只读浏览 (drivev3 实现).
//
// 替代 legacy svcdrive.AdminBrowse: 旧实现引用 owner_id / deleted_at / folder_id / uploader_id 等
// drivev3 之前的列名, 在新 schema (000108-000110) 上跑出 500. 本文件按新 schema 的
// owner_account_id / is_deleted / drive_folder_id / created_by / source 列重写, 同时保留
// JSON shape (TenantSpaceItem / TenantFileItem 的字段名 / json tag) 不变, admin 前端无需改.
//
// 不暴露下载 URL; 仅返 metadata. tenant_id 强制过滤; spaceUUID 跨租户访问返 404 (不泄信息).
//
// 类型定义放在 service 层 (符合 transport -> service 依赖方向).
// transport/http/admin 通过 DriveBrowseService 窄抽象消费.
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AdminTenantSpaceItem admin 视角的 space 浏览行 (metadata only).
// JSON shape 与 legacy svcdrive.TenantSpaceItem 完全一致, 前端无需调整.
type AdminTenantSpaceItem struct {
	UUID         string `json:"uuid"`
	SpaceKind    string `json:"space_kind"` // personal | tenant | department | shared
	Name         string `json:"name"`
	OwnerID      *int64 `json:"owner_id,omitempty"`   // = owner_account_id; tenant/dept space 时 nil
	OwnerName    string `json:"owner_name,omitempty"` // tenant_memberships.nickname -> accounts.display_name
	QuotaBytes   *int64 `json:"quota_bytes,omitempty"`
	UsedBytes    int64  `json:"used_bytes"`
	FilesCount   int64  `json:"files_count"`   // scope='drive' live count
	FoldersCount int64  `json:"folders_count"` // live count
	Status       string `json:"status"`
	CreatedAt    string `json:"created_at"` // RFC3339 string (与 legacy 输出保持一致)
}

// AdminTenantFileItem 文件 metadata 行 (无下载 url).
// JSON shape 与 legacy svcdrive.TenantFileItem 完全一致.
type AdminTenantFileItem struct {
	UUID         string `json:"uuid"`
	Name         string `json:"name"`
	MimeType     string `json:"mime_type"`
	FileSize     int64  `json:"file_size"`
	StorageKind  string `json:"storage_kind"` // drivev3 不再按行存 backend kind; 留空 (前端容忍)
	StorageKey   string `json:"storage_key"`
	FolderPath   string `json:"folder_path"`
	UploaderID   *int64 `json:"uploader_id,omitempty"`   // = created_by
	UploaderName string `json:"uploader_name,omitempty"` // tenant_memberships.nickname -> accounts.display_name
	SourceKind   string `json:"source_kind,omitempty"`   // = source
	CreatedAt    string `json:"created_at"`
}

// AdminListFilesQuery 文件列表筛选; 字段名沿用 legacy 接口以便 transport 直接传.
type AdminListFilesQuery struct {
	NameLike   string // q (ILIKE 子串, LIKE-escape)
	MimePrefix string // mime_type LIKE prefix
	Limit      int    // default 50, cap 200
	Cursor     int64  // keyset cursor (last seen id; 0 = first page)
}

// AdminBrowseSvc 实现 admin /tenant/drive/spaces + /spaces/{uuid}/files 只读浏览.
type AdminBrowseSvc struct {
	pool *pgxpool.Pool
}

// NewAdminBrowseSvc 构造.
func NewAdminBrowseSvc(pool *pgxpool.Pool) *AdminBrowseSvc {
	return &AdminBrowseSvc{pool: pool}
}

// ListTenantSpaces 列指定 tenant 下所有 drive_spaces (含 4 类), 带 owner JOIN + counts + quota.
// 不分页 — 单 tenant 内 space 数量受限 (personal 1/用户, dept 1/部门, tenant 1, shared 用户自建).
func (s *AdminBrowseSvc) ListTenantSpaces(ctx context.Context, tenantID int64) ([]AdminTenantSpaceItem, error) {
	const sql = `
SELECT s.uuid::text, s.kind, s.name,
       s.owner_account_id, COALESCE(NULLIF(tm.nickname,''), owner.display_name, ''),
       q.quota_bytes,
       s.used_bytes,
       COALESCE(fc.cnt, 0) AS files_count,
       COALESCE(fd.cnt, 0) AS folders_count,
       s.status, s.created_at
  FROM drive_spaces s
  LEFT JOIN accounts owner ON owner.id = s.owner_account_id
  LEFT JOIN tenant_memberships tm ON tm.tenant_id = s.tenant_id
       AND tm.account_id = s.owner_account_id
       AND tm.deleted_at IS NULL
  LEFT JOIN drive_quotas q ON q.tenant_id = s.tenant_id
       AND q.is_deleted = false
       AND (
            (s.kind = 'tenant'     AND q.subject_kind = 'tenant'  AND q.subject_id IS NULL)
         OR (s.kind = 'personal'   AND q.subject_kind = 'account' AND q.subject_id = s.owner_account_id)
         OR (s.kind = 'shared'     AND q.subject_kind = 'account' AND q.subject_id = s.owner_account_id)
         OR (s.kind = 'department' AND q.subject_kind = 'tenant'  AND q.subject_id IS NULL)
       )
  LEFT JOIN LATERAL (
       SELECT COUNT(*)::bigint AS cnt
         FROM drive_files f
        WHERE f.space_id = s.id AND f.scope = 'drive' AND f.is_deleted = false
  ) fc ON true
  LEFT JOIN LATERAL (
       SELECT COUNT(*)::bigint AS cnt
         FROM drive_folders fl
        WHERE fl.space_id = s.id AND fl.is_deleted = false
  ) fd ON true
 WHERE s.tenant_id = $1 AND s.is_deleted = false
 ORDER BY s.kind, s.created_at DESC`

	rows, err := s.pool.Query(ctx, sql, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantSpaces: %w", err))
	}
	defer rows.Close()

	var out []AdminTenantSpaceItem
	for rows.Next() {
		var it AdminTenantSpaceItem
		var owner *int64
		var quota *int64
		var ts any
		if err := rows.Scan(&it.UUID, &it.SpaceKind, &it.Name,
			&owner, &it.OwnerName,
			&quota,
			&it.UsedBytes,
			&it.FilesCount, &it.FoldersCount,
			&it.Status, &ts); err != nil {
			return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantSpaces.scan: %w", err))
		}
		it.OwnerID = owner
		it.QuotaBytes = quota
		it.OwnerName = adminCleanDisplayName(it.OwnerName)
		it.Name = adminSpaceDisplayName(it.SpaceKind, it.Name, it.OwnerName)
		it.CreatedAt = fmt.Sprint(ts)
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantSpaces.rows: %w", err))
	}
	return out, nil
}

func adminSpaceDisplayName(kind, name, ownerName string) string {
	if trimmed := strings.TrimSpace(name); trimmed != "" && !adminLooksGeneratedSpaceName(trimmed) {
		return trimmed
	}
	owner := adminCleanDisplayName(ownerName)
	switch kind {
	case "tenant":
		return "企业云盘"
	case "personal":
		if owner != "" {
			return owner + "的个人云盘"
		}
		return "个人云盘"
	case "department":
		return "部门云盘"
	case "shared":
		if owner != "" {
			return owner + "的共享空间"
		}
		return "共享空间"
	default:
		return "未命名空间"
	}
}

func adminCleanDisplayName(name string) string {
	n := strings.TrimSpace(name)
	if n == "" || adminLooksGeneratedAccountName(n) {
		return ""
	}
	return n
}

func adminLooksGeneratedSpaceName(name string) bool {
	if len(name) < 2 || name[0] != 'u' {
		return false
	}
	for _, ch := range name[1:] {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func adminLooksGeneratedAccountName(name string) bool {
	return strings.Contains(name, "的组织 管理员") || strings.HasPrefix(name, "预热优化")
}

// ListTenantFiles 按 space_uuid 列文件 metadata; tenant_id 强制守口.
//
// 行为:
//   - spaceUUID 不存在 / 跨租户 / soft-deleted → 返 ErrNotFound (不泄跨租户存在性)
//   - 仅列 scope='drive' 文件 (chat-scope 文件不在 admin 视图)
//   - keyset 分页: cursor = 上一页最后一行 id, ORDER BY f.id ASC; 满页时 next = items[last].id
func (s *AdminBrowseSvc) ListTenantFiles(ctx context.Context, tenantID int64, spaceUUID string, q AdminListFilesQuery) ([]AdminTenantFileItem, int64, error) {
	if q.Limit <= 0 || q.Limit > 200 {
		q.Limit = 50
	}

	// 1) 先解 space → tenant 校验 (跨租户走 404, 不泄信息).
	var spaceID int64
	err := s.pool.QueryRow(ctx,
		`SELECT id FROM drive_spaces WHERE uuid = $1 AND tenant_id = $2 AND is_deleted = false`,
		spaceUUID, tenantID).Scan(&spaceID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, 0, apperr.ErrNotFound.Withf("drive.space_not_found")
		}
		return nil, 0, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantFiles.resolve: %w", err))
	}

	// 2) 构造 WHERE.
	args := []any{spaceID, q.Limit, tenantID}
	where := []string{
		"f.space_id = $1",
		"f.scope = 'drive'",
		"f.is_deleted = false",
	}
	idx := 4
	if q.Cursor > 0 {
		where = append(where, fmt.Sprintf("f.id > $%d", idx))
		args = append(args, q.Cursor)
		idx++
	}
	if name := likeEscape(strings.TrimSpace(q.NameLike)); name != "" {
		where = append(where, fmt.Sprintf(`f.name ILIKE $%d ESCAPE '\'`, idx))
		args = append(args, "%"+name+"%")
		idx++
	}
	if mp := likeEscape(strings.TrimSpace(q.MimePrefix)); mp != "" {
		where = append(where, fmt.Sprintf(`f.mime_type LIKE $%d ESCAPE '\'`, idx))
		args = append(args, mp+"%")
		idx++
	}

	sql := `
SELECT f.id, f.uuid::text, f.name, f.mime_type, f.size_bytes, f.storage_key,
       COALESCE(folder.path, '') AS folder_path,
       f.created_by, COALESCE(NULLIF(tm.nickname,''), uploader.display_name, ''),
       f.source, f.created_at
  FROM drive_files f
  LEFT JOIN drive_folders folder ON folder.id = f.drive_folder_id AND folder.is_deleted = false
  LEFT JOIN accounts uploader ON uploader.id = f.created_by
  LEFT JOIN tenant_memberships tm ON tm.tenant_id = $3
       AND tm.account_id = f.created_by
       AND tm.deleted_at IS NULL
 WHERE ` + strings.Join(where, " AND ") + `
 ORDER BY f.id ASC
 LIMIT $2`

	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantFiles: %w", err))
	}
	defer rows.Close()

	var out []AdminTenantFileItem
	var lastID int64
	for rows.Next() {
		var it AdminTenantFileItem
		var id int64
		var uploader *int64
		var ts any
		if err := rows.Scan(&id, &it.UUID, &it.Name, &it.MimeType, &it.FileSize, &it.StorageKey,
			&it.FolderPath,
			&uploader, &it.UploaderName,
			&it.SourceKind, &ts); err != nil {
			return nil, 0, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantFiles.scan: %w", err))
		}
		it.UploaderID = uploader
		it.UploaderName = adminCleanDisplayName(it.UploaderName)
		it.CreatedAt = fmt.Sprint(ts)
		// StorageKind 在 drivev3 新 schema 不按行存 (backend 由 tenant storage override + platform default 决定);
		// 留空, 前端字段可选, 不影响渲染.
		it.StorageKind = ""
		out = append(out, it)
		lastID = id
	}
	if err := rows.Err(); err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(fmt.Errorf("drive.AdminBrowseSvc.ListTenantFiles.rows: %w", err))
	}

	// 未满一页 → 无下一页.
	if len(out) < q.Limit {
		lastID = 0
	}
	return out, lastID, nil
}
