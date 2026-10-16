// discover.go — F06 Phase 2.2e: recent + search 端点的服务层 (DiscoverSvc).
//
// 2 个 service 入口对应 2 个客户端 endpoint:
//
//	RecentFiles → GET /drive/files:recent          ACL viewer+ on space (coarse)
//	SearchFiles → GET /drive/files:search?q=...    GIN tsvector + ACL coarse 同上
//
// **first-pass coarse ACL**: 仅按 space-level 过滤 (= ACL.ListAccessibleSpaceIDs); folder-level
// grant (e.g. 用户在 space 上无默认权限, 但被 grant 了某子 folder 的 viewer+) 不在结果中.
// 后续 slice 接入 folder-level 颗粒度过滤; 当前阶段足够覆盖 90%+ 的 "我的文件" / "搜文件" 体验.
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// FileListItem F06 Phase 2.2e: discover / recycle 等列表场景的轻量 file 投影.
// 跟 FileDetailResp (file.go) 区分: 列表不带 storage_key / sha256 / copy_status 等敏感/扩字段.
type FileListItem struct {
	UUID             string    `json:"uuid"`
	SpaceUUID        string    `json:"space_uuid"`
	FolderUUID       string    `json:"folder_uuid,omitempty"`
	Name             string    `json:"name"`
	MimeType         string    `json:"mime_type"`
	SizeBytes        int64     `json:"size_bytes"`
	OwnerAccountUUID string    `json:"owner_account_uuid,omitempty"`
	OwnerDisplayName string    `json:"owner_display_name,omitempty"`
	OwnerAvatarURL   string    `json:"owner_avatar_url,omitempty"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// FileListResp F06 Phase 2.2e: recent / search 响应包. total 反映命中总数 (受 ACL 过滤后),
// items 受 limit cap. 仅 recent / search 使用.
type FileListResp struct {
	Items []FileListItem `json:"items"`
	Total int            `json:"total"`
}

// FilePageResp F06 Phase 2.2f: ListFiles (cursor 分页) 专用响应.
// 不含 Total: 真正的"总数"对分页接口意义不大, 拿 next_cursor 翻页即可.
// next_cursor=0 表示没下一页.
type FilePageResp struct {
	Items      []FileListItem `json:"items"`
	NextCursor int64          `json:"next_cursor"`
}

// ListReq F06 Phase 2.2f: GET /drive/files flat list 请求参数 (与 legacy svcdrive.ListFilesReq
// 语义对齐 — caller 必须指定 space_uuid, 其它字段可选).
type ListReq struct {
	SpaceUUID  string // 必填 — scope 始终是单个 space
	FolderUUID string // 可选; 非空时 filter drive_folder_id=$id
	RootOnly   bool   // folder_uuid 为空时, true 表示只列 drive_folder_id IS NULL 的 space 根文件
	Q          string // 可选; 名称 ILIKE 子串 (大小写不敏感, 已 LIKE-escape)
	MimePrefix string // 可选; mime_type LIKE prefix% (e.g. "image/" / "application/pdf")
	Limit      int    // default 50, cap 200
	CursorID   int64  // 可选 keyset 分页 cursor (last seen id)
}

// DiscoverSvc Phase 2.2e + B4: recent + search 服务.
// B4 起注入 ACLRepo 以解析 folder/file-level grants (granular ACL).
type DiscoverSvc struct {
	pool    *pgxpool.Pool
	spaces  *drepo.SpaceRepo
	folders *drepo.FolderRepo
	files   *drepo.FileRepo
	acl     *ACLService
	aclRepo *drepo.ACLRepo // B4: 列 folder/file 级 grant; nil 时降级到 space-only 老行为
	owners  interface {
		GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
	}
}

// NewDiscoverSvc 构造.
func NewDiscoverSvc(pool *pgxpool.Pool, sp *drepo.SpaceRepo, fd *drepo.FolderRepo, fl *drepo.FileRepo, acl *ACLService) *DiscoverSvc {
	return &DiscoverSvc{pool: pool, spaces: sp, folders: fd, files: fl, acl: acl}
}

// WithACLRepo B4: 注入 ACLRepo, 开启 Recent/Search 的 folder/file-level grant 颗粒.
// 不注入 → 行为不变 (只 space 级).
func (s *DiscoverSvc) WithACLRepo(r *drepo.ACLRepo) *DiscoverSvc {
	s.aclRepo = r
	return s
}

// WithOwnerLookup 注入账号查询,为 recent/search/list 的「所有者」列回填展示字段。
func (s *DiscoverSvc) WithOwnerLookup(lookup interface {
	GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
}) *DiscoverSvc {
	s.owners = lookup
	return s
}

// lookupExtraGranted B4: 取 caller 在 tenant 内被 grant 的 folder/file ids.
// aclRepo 未注入 → 返空 slice (调用方 SQL OR 也会变 "OR ANY(empty)" → 不命中).
func (s *DiscoverSvc) lookupExtraGranted(ctx context.Context, tenantID, accountID int64) (folderIDs, fileIDs []int64, err error) {
	if s.aclRepo == nil {
		return nil, nil, nil
	}
	folderIDs, err = s.aclRepo.ListGrantedFolderIDsByAccount(ctx, tenantID, accountID)
	if err != nil {
		return nil, nil, err
	}
	fileIDs, err = s.aclRepo.ListGrantedFileIDsByAccount(ctx, tenantID, accountID)
	if err != nil {
		return nil, nil, err
	}
	return folderIDs, fileIDs, nil
}

// RecentFiles GET /drive/files:recent: 列 caller viewer+ space 内最近更新的文件.
// B4: + folder/file-level grants (granular ACL).
// limit cap 200; default 50.
func (s *DiscoverSvc) RecentFiles(ctx context.Context, accountID, tenantID int64, limit int) (*FileListResp, error) {
	spaceIDs, err := s.acl.ListAccessibleSpaceIDs(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.RecentFiles.ACL: %w", err))
	}
	extraFolderIDs, extraFileIDs, err := s.lookupExtraGranted(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.RecentFiles.granular: %w", err))
	}
	if len(spaceIDs) == 0 && len(extraFolderIDs) == 0 && len(extraFileIDs) == 0 {
		return &FileListResp{Items: []FileListItem{}, Total: 0}, nil
	}

	files, total, err := s.files.RecentByAccessibleSpaces(ctx, spaceIDs, extraFolderIDs, extraFileIDs, limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	items, err := s.buildItems(ctx, tenantID, files)
	if err != nil {
		return nil, err
	}
	return &FileListResp{Items: items, Total: total}, nil
}

// SearchFiles GET /drive/files:search?q=...: GIN tsvector 搜文件名; ACL = space ∪ folder ∪ file grants.
// q 必填 (trim 后非空); 空 → 400 drive.invalid_params.
func (s *DiscoverSvc) SearchFiles(ctx context.Context, accountID, tenantID int64, query string, limit int) (*FileListResp, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_params: q required")
	}

	spaceIDs, err := s.acl.ListAccessibleSpaceIDs(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.SearchFiles.ACL: %w", err))
	}
	extraFolderIDs, extraFileIDs, err := s.lookupExtraGranted(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.SearchFiles.granular: %w", err))
	}
	if len(spaceIDs) == 0 && len(extraFolderIDs) == 0 && len(extraFileIDs) == 0 {
		return &FileListResp{Items: []FileListItem{}, Total: 0}, nil
	}

	files, total, err := s.files.SearchByName(ctx, spaceIDs, extraFolderIDs, extraFileIDs, query, limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	items, err := s.buildItems(ctx, tenantID, files)
	if err != nil {
		return nil, err
	}
	return &FileListResp{Items: items, Total: total}, nil
}

// ListFiles GET /drive/files flat list (Phase 2.2f 由 drivev3 接管, legacy svcdrive.ListFiles 退场).
//
// 语义 (与 legacy 最小兼容 + ACL 精化):
//   - space_uuid 必填; 空 → 400 drive.space_uuid_required (legacy 错信息为 "space_uuid required",
//     这里用更明确的 code 便于客户端定位).
//   - resolve space.UUID → space.ID; 找不到 → 404 drive.space_not_found.
//   - ACL viewer+ on space; 不满足 → 403 drive.acl.forbidden.
//   - folder_uuid 非空时 resolve → 必须同 space; 跨 space → 403 drive.acl.forbidden.
//   - q / mime_prefix 走 service 层 LIKE escape (% / _ / \\), 防 user input 跑成模式特殊字符.
//   - cursor + limit 走 repo keyset 分页, 返 next_cursor (0 = 没下一页).
//
// **first-pass coarse ACL** (与 recent/search 一致): 只在 space 粒度过滤;
// 后续 'ACL granular discover' slice 接 folder-level grant 颗粒化.
func (s *DiscoverSvc) ListFiles(ctx context.Context, accountID, tenantID int64, req ListReq) (*FilePageResp, error) {
	if strings.TrimSpace(req.SpaceUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("drive.space_uuid_required")
	}

	sp, err := s.spaces.GetByUUID(ctx, req.SpaceUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.space_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.ListFiles.space: %w", err))
	}
	if sp.TenantID != tenantID {
		// 跨 tenant 直接当 404 (与 Preview/Bootstrap 一致, 防 enumerator).
		return nil, apperr.ErrNotFound.Withf("drive.space_not_found")
	}

	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, sp.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.ListFiles.ACL: %w", err))
	}
	if !roleAtLeastDiscover(role, dom.ACLRoleViewer) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	var folderID *int64
	if req.FolderUUID != "" {
		fd, err := s.folders.GetByUUID(ctx, req.FolderUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("drive.folder_not_found")
			}
			return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.DiscoverSvc.ListFiles.folder: %w", err))
		}
		if fd.SpaceID != sp.ID {
			// 同 tenant 但 folder 不属于该 space — 当 forbidden (避免 leak 隔壁 space 的 folder uuid 存在性).
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
		fid := fd.ID
		folderID = &fid
	}

	files, nextCursor, err := s.files.ListInSpace(ctx, sp.ID, folderID,
		req.RootOnly,
		likeEscape(strings.TrimSpace(req.Q)),
		likeEscape(strings.TrimSpace(req.MimePrefix)),
		req.CursorID, req.Limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	items, err := s.buildItems(ctx, tenantID, files)
	if err != nil {
		return nil, err
	}
	return &FilePageResp{Items: items, NextCursor: nextCursor}, nil
}

// likeEscape 转义 SQL LIKE 模式里的特殊字符 (% / _ / \\), 配合 ListInSpace 的 ESCAPE '\\' 子句.
// caller 传 trim 后字符串; 空字符串原样返 (上层走 "不附加过滤" 分支).
func likeEscape(s string) string {
	if s == "" {
		return ""
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch r {
		case '\\', '%', '_':
			b.WriteRune('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// roleAtLeastDiscover discover-scope role 比较 (与 file.go::roleAtLeastFile 等价, 避免反向 import).
func roleAtLeastDiscover(have, want dom.ACLRole) bool {
	rank := map[dom.ACLRole]int{"": 0, dom.ACLRoleViewer: 1, dom.ACLRoleEditor: 2, dom.ACLRoleManager: 3}
	return rank[have] >= rank[want]
}

// ownerBatchLookup 可选批量账号查询 (与 WithOwnerLookup 注入的窄接口配套; account pg repo 已实现).
// 未实现时 buildItems 退回逐 owner GetByID.
type ownerBatchLookup interface {
	ListByIDs(ctx context.Context, ids []int64) ([]domaccount.Account, error)
}

// ownerTenantBatchLookup 优先按租户成员昵称投影展示名，避免资料页改名后
// 云盘「最近使用」等列表继续显示 accounts.display_name 的旧全局默认名。
type ownerTenantBatchLookup interface {
	ListByIDsForTenant(ctx context.Context, tenantID int64, ids []int64) ([]domaccount.Account, error)
}

// buildItems file → FileListItem: 批量预取 space.uuid / folder.uuid / owner 展示字段
// (每类 1 条 IN 查询; 此前为逐 file GetByID N+1, 远程库链路下 100+ 文件 ≈ 秒级放大,
// 见 docs/pitfalls/client-api-list-hydrate-n-plus-one-remote-db-latency.md)。
//
// 容错语义与逐条版一致:
//   - space 查询整体失败 → 请求失败; 单个 space 缺失/软删 → 跳过该 file;
//   - folder 缺失/软删/查询失败 → folder_uuid 留空, 不报错;
//   - owner 缺失/软删/查询失败 → owner 展示字段留空, 不报错。
func (s *DiscoverSvc) buildItems(ctx context.Context, tenantID int64, files []dom.File) ([]FileListItem, error) {
	out := make([]FileListItem, 0, len(files))
	if len(files) == 0 {
		return out, nil
	}

	spaceIDSet := make(map[int64]struct{})
	folderIDSet := make(map[int64]struct{})
	ownerIDSet := make(map[int64]struct{})
	for i := range files {
		spaceIDSet[files[i].SpaceID] = struct{}{}
		if id := files[i].DriveFolderID; id != nil {
			folderIDSet[*id] = struct{}{}
		}
		if s.owners != nil {
			if id := files[i].CreatedBy; id != nil {
				ownerIDSet[*id] = struct{}{}
			}
		}
	}
	keys := func(set map[int64]struct{}) []int64 {
		ids := make([]int64, 0, len(set))
		for id := range set {
			ids = append(ids, id)
		}
		return ids
	}

	spaces, err := s.spaces.ListByIDs(ctx, keys(spaceIDSet))
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	spaceUUIDByID := make(map[int64]string, len(spaces))
	for i := range spaces {
		spaceUUIDByID[spaces[i].ID] = spaces[i].UUID
	}

	folderUUIDByID := make(map[int64]string, len(folderIDSet))
	if len(folderIDSet) > 0 {
		if folders, err := s.folders.ListByIDs(ctx, keys(folderIDSet)); err == nil {
			for i := range folders {
				folderUUIDByID[folders[i].ID] = folders[i].UUID
			}
		}
	}

	ownerByID := make(map[int64]*domaccount.Account, len(ownerIDSet))
	if s.owners != nil && len(ownerIDSet) > 0 {
		if batch, ok := s.owners.(ownerTenantBatchLookup); ok {
			if accounts, err := batch.ListByIDsForTenant(ctx, tenantID, keys(ownerIDSet)); err == nil {
				for i := range accounts {
					ownerByID[accounts[i].ID] = &accounts[i]
				}
			}
		} else if batch, ok := s.owners.(ownerBatchLookup); ok {
			if accounts, err := batch.ListByIDs(ctx, keys(ownerIDSet)); err == nil {
				for i := range accounts {
					ownerByID[accounts[i].ID] = &accounts[i]
				}
			}
		} else {
			for id := range ownerIDSet {
				if acc, err := s.owners.GetByID(ctx, id); err == nil && acc != nil {
					ownerByID[id] = acc
				}
			}
		}
	}

	for i := range files {
		f := &files[i]
		spUUID, ok := spaceUUIDByID[f.SpaceID]
		if !ok {
			continue // space 缺失/并发软删 → 跳过该 file
		}
		var fdUUID string
		if f.DriveFolderID != nil {
			fdUUID = folderUUIDByID[*f.DriveFolderID]
		}
		var ownerUUID, ownerName, ownerAvatar string
		if s.owners != nil && f.CreatedBy != nil {
			if owner := ownerByID[*f.CreatedBy]; owner != nil {
				ownerUUID = owner.UUID
				ownerName = owner.DisplayName
				ownerAvatar = owner.AvatarURL
			}
		}
		out = append(out, FileListItem{
			UUID:             f.UUID,
			SpaceUUID:        spUUID,
			FolderUUID:       fdUUID,
			Name:             f.Name,
			MimeType:         f.MimeType,
			SizeBytes:        f.SizeBytes,
			OwnerAccountUUID: ownerUUID,
			OwnerDisplayName: ownerName,
			OwnerAvatarURL:   ownerAvatar,
			UpdatedAt:        f.UpdatedAt,
		})
	}
	return out, nil
}
