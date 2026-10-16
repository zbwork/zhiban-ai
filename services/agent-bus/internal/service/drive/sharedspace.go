// sharedspace.go — F06 Phase 2.2e: shared-space create/list/update/archive 端点的服务层 (SharedSpaceSvc).
//
// 2 个 service 入口对应 2 个客户端 endpoint:
//
//	Create  → POST   /drive/shared-spaces         caller = owner (default = manager); 无 ACL grant 写入
//	List    → GET    /drive/shared-spaces         caller 可访问 (owner OR ACL grant); 复用 Bootstrap query
//	Update  → PATCH  /drive/shared-spaces/{uuid}  caller manager+
//	Archive → DELETE /drive/shared-spaces/{uuid}  caller manager+
//
// 推后实现 (future slice):
//   - transfer ownership
//   - share-link 短链 (drive_share_links)
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// roleAtLeastViewer B3 ListMembers 用; viewer / editor / manager 都过.
func roleAtLeastViewer(role dom.ACLRole) bool {
	switch role {
	case dom.ACLRoleViewer, dom.ACLRoleEditor, dom.ACLRoleManager:
		return true
	}
	return false
}

// SpaceResp F06 Phase 2.2e: 单 space 响应 (shared-space create/list 用).
// 字段与 dom.Space 必要子集对齐, 不暴露内部 id / created_by 等审计字段.
type SpaceResp struct {
	UUID        string `json:"uuid"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      string `json:"status"`
	UsedBytes   int64  `json:"used_bytes"`
}

// SharedSpaceCreateResp F06 Phase 2.2e: POST /drive/shared-spaces 响应.
type SharedSpaceCreateResp struct {
	Space SpaceResp `json:"space"`
}

// SharedSpaceListResp F06 Phase 2.2e: GET /drive/shared-spaces 响应.
type SharedSpaceListResp struct {
	Items []SpaceResp `json:"items"`
}

// AccountLookup B3 member API 用: 把 client 传入的 account_uuid 解析为内部 account_id + 校 tenant 一致.
// 实现方在 cmd/bus 用 accRepo (内部 account 包) 包一层; 服务层只持窄接口.
type AccountLookup interface {
	// ResolveByUUID 输入 account_uuid + tenantID; 不存在或跨 tenant → ErrNotFound (apperr).
	ResolveByUUID(ctx context.Context, accountUUID string, tenantID int64) (int64, error)
	// UUIDsByIDs F06 基础设置 slice: 批量反查 account_id → account_uuid。
	// 找不到的 id 在 map 中缺失 (不报错)。caller 负责按需 fallback。
	UUIDsByIDs(ctx context.Context, accountIDs []int64) (map[int64]string, error)
}

// SharedSpaceSvc Phase 2.2e: shared-space 服务.
// B3 起新增 ACLRepo + AccountLookup; member CRUD 在此服务承担.
type SharedSpaceSvc struct {
	spaces   *drepo.SpaceRepo
	acl      *ACLService
	aclRepo  *drepo.ACLRepo // B3: members CRUD
	accounts AccountLookup  // B3: account_uuid → account_id
}

// NewSharedSpaceSvc 构造.
func NewSharedSpaceSvc(sp *drepo.SpaceRepo, acl *ACLService) *SharedSpaceSvc {
	return &SharedSpaceSvc{spaces: sp, acl: acl}
}

// WithMembers B3: 注入 ACLRepo + AccountLookup, 开启 member CRUD 4 端点.
// 未注入 → AddMember/ListMembers/UpdateMember/RemoveMember 返 ErrInternal.drive.members_not_wired.
func (s *SharedSpaceSvc) WithMembers(aclRepo *drepo.ACLRepo, lookup AccountLookup) *SharedSpaceSvc {
	s.aclRepo = aclRepo
	s.accounts = lookup
	return s
}

// Create POST /drive/shared-spaces: 创建 shared space; caller = owner (default = manager).
// 不写 ACL grant 行 (owner default 走 ACL.defaultRole 计算).
func (s *SharedSpaceSvc) Create(ctx context.Context, accountID, tenantID int64, name, description string) (*SharedSpaceCreateResp, error) {
	name = strings.TrimSpace(name)
	if !validSharedSpaceName(name) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_name")
	}
	description = strings.TrimSpace(description)
	if !validSharedSpaceDescription(description) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_description")
	}

	owner := accountID
	createdBy := accountID
	sp, err := s.spaces.Create(ctx, dom.CreateSpaceInput{
		TenantID:       tenantID,
		Kind:           dom.SpaceKindShared,
		OwnerAccountID: &owner,
		Name:           name,
		Description:    description,
		Status:         dom.SpaceStatusActive,
		CreatedBy:      &createdBy,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.SharedSpaceSvc.Create: %w", err))
	}
	return &SharedSpaceCreateResp{Space: toSpaceResp(sp)}, nil
}

// List GET /drive/shared-spaces: 返 caller viewer+ 的 shared space (owner OR ACL grant).
// 复用 SpaceRepo.ListSharedSpacesAccessible — 与 Bootstrap.spaces.shared 同源.
func (s *SharedSpaceSvc) List(ctx context.Context, accountID, tenantID int64) (*SharedSpaceListResp, error) {
	rows, err := s.spaces.ListSharedSpacesAccessible(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]SpaceResp, 0, len(rows))
	for i := range rows {
		out = append(out, toSpaceResp(&rows[i]))
	}
	return &SharedSpaceListResp{Items: out}, nil
}

// Update PATCH /drive/shared-spaces/{uuid}: 修改 shared space 名称/描述。caller 必须 manager+。
func (s *SharedSpaceSvc) Update(ctx context.Context, accountID, tenantID int64, spaceUUID, name string, description *string) (*SharedSpaceCreateResp, error) {
	name = strings.TrimSpace(name)
	if !validSharedSpaceName(name) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_name")
	}
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := s.requireManager(ctx, accountID, sp); err != nil {
		return nil, err
	}
	nextDescription := sp.Description
	if description != nil {
		nextDescription = strings.TrimSpace(*description)
		if !validSharedSpaceDescription(nextDescription) {
			return nil, apperr.ErrInvalidParams.Withf("drive.invalid_description")
		}
	}
	updated, err := s.spaces.UpdateSharedByID(ctx, sp.ID, name, nextDescription, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("space")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &SharedSpaceCreateResp{Space: toSpaceResp(updated)}, nil
}

// Archive DELETE /drive/shared-spaces/{uuid}: 归档 shared space 并从客户端共享空间列表隐藏。
func (s *SharedSpaceSvc) Archive(ctx context.Context, accountID, tenantID int64, spaceUUID string) error {
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return err
	}
	if err := s.requireManager(ctx, accountID, sp); err != nil {
		return err
	}
	if err := s.spaces.ArchiveSharedByID(ctx, sp.ID, accountID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("space")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// toSpaceResp dom.Space → SpaceResp 投影.
func toSpaceResp(sp *dom.Space) SpaceResp {
	return SpaceResp{
		UUID:        sp.UUID,
		Kind:        string(sp.Kind),
		Name:        sp.Name,
		Description: sp.Description,
		Status:      string(sp.Status),
		UsedBytes:   sp.UsedBytes,
	}
}

// validSharedSpaceName F06 Phase 2.2e: shared space 名校验.
// 与 folder 同级 (1-128, 不含路径分隔符 / 控制字符).
func validSharedSpaceName(name string) bool {
	if name == "" || len(name) > 128 {
		return false
	}
	for _, r := range name {
		if r == '/' || r == '\\' || r == 0 || r < 0x20 {
			return false
		}
	}
	return true
}

// validSharedSpaceDescription 与客户端创建弹窗对齐:可空,短文本,不接受控制字符。
func validSharedSpaceDescription(description string) bool {
	if len(description) > 512 {
		return false
	}
	for _, r := range description {
		if r == 0 || (r < 0x20 && r != '\n' && r != '\t') {
			return false
		}
	}
	return true
}

// =====================================================
// B3: shared-space members CRUD
// =====================================================

// MemberResp B3: 单 member 响应 (list/add/update 共用).
type MemberResp struct {
	AccountID   int64  `json:"account_id"`   // 仅 server-side 调试; client 一般以 account_uuid 为准
	AccountUUID string `json:"account_uuid"` // 客户端寻址用; AddMember 输入也接受 account_uuid
	Role        string `json:"role"`         // GET: owner | viewer | editor | manager; mutation: viewer | editor | manager
}

// AddMember POST /drive/spaces/{uuid}/members. ACL manager+ on space; 不能改 owner.
// 已存在 grant 返 409 drive.member_exists (改 role 走 UpdateMember).
// shared space only; 其它 kind 拒.
func (s *SharedSpaceSvc) AddMember(ctx context.Context, callerAccountID, tenantID int64, spaceUUID, memberAccountUUID, role string) (*MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	role = strings.TrimSpace(role)
	if !validMemberRole(role) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_role")
	}
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := s.requireManager(ctx, callerAccountID, sp); err != nil {
		return nil, err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("account")
	}
	if sp.OwnerAccountID != nil && *sp.OwnerAccountID == memberID {
		return nil, apperr.ErrConflict.Withf("drive.owner_cannot_be_member")
	}
	// 已存在 → 409 (强制 caller 走 PATCH 改 role; 不静默升级避免误操作)
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetSpace, sp.ID, memberID)
	if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if existing != nil {
		return nil, apperr.ErrConflict.Withf("drive.member_exists")
	}
	row, err := s.aclRepo.InsertAccountGrant(ctx, drepo.InsertAccountGrantInput{
		TenantID:  sp.TenantID,
		Kind:      dom.ACLTargetSpace,
		TargetID:  sp.ID,
		AccountID: memberID,
		Role:      dom.ACLRole(role),
		GrantedBy: callerAccountID,
	})
	if err != nil {
		// 并发 INSERT 撞 uq_acl_grant → 23505. PG error code 不直接暴露 ErrDuplicate; 用错误字符串匹配.
		if strings.Contains(err.Error(), "23505") {
			return nil, apperr.ErrConflict.Withf("drive.member_exists")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return memberRespFromGrant(row, memberAccountUUID), nil
}

// ListMembers GET /drive/spaces/{uuid}/members. ACL viewer+ on space.
// 首项投影真实 owner (role=owner),其余返回 account_id grants;
// link_token / department 不在此 list (有专门端点).
func (s *SharedSpaceSvc) ListMembers(ctx context.Context, callerAccountID, tenantID int64, spaceUUID string) ([]MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return nil, err
	}
	role, err := s.acl.CheckEffectiveRole(ctx, callerAccountID, dom.ACLTargetSpace, sp.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastViewer(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	rows, err := s.aclRepo.ListAccountSubjectsByTarget(ctx, dom.ACLTargetSpace, sp.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// F06 基础设置 slice: 批量反查 account_id → account_uuid (客户端需用 uuid 走
	// PATCH/DELETE/{account_uuid} + ContactsService 解析显示名)。owner uuid 是成员
	// 读模型与候选禁选的必要字段,缺失时 fail closed;普通 grant 仍可空 uuid 兜底显示。
	ids := make([]int64, 0, len(rows)+1)
	if sp.OwnerAccountID != nil {
		ids = append(ids, *sp.OwnerAccountID)
	}
	for i := range rows {
		if rows[i].SubjectID != nil {
			ids = append(ids, *rows[i].SubjectID)
		}
	}
	uuidByID, err := s.accounts.UUIDsByIDs(ctx, ids)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]MemberResp, 0, len(rows)+1)
	owner, err := ownerMemberResp(sp.OwnerAccountID, uuidByID)
	if err != nil {
		return nil, err
	}
	if owner != nil {
		out = append(out, *owner)
	}
	for i := range rows {
		if rows[i].SubjectID != nil && sp.OwnerAccountID != nil && *rows[i].SubjectID == *sp.OwnerAccountID {
			continue
		}
		uuid := ""
		if rows[i].SubjectID != nil {
			uuid = uuidByID[*rows[i].SubjectID]
		}
		out = append(out, *memberRespFromGrant(&rows[i], uuid))
	}
	return out, nil
}

// UpdateMember PATCH /drive/spaces/{uuid}/members/{account_uuid}. ACL manager+.
// owner 不可 update (无 grant 行); 非现有 member → 404.
func (s *SharedSpaceSvc) UpdateMember(ctx context.Context, callerAccountID, tenantID int64, spaceUUID, memberAccountUUID, role string) (*MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	role = strings.TrimSpace(role)
	if !validMemberRole(role) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_role")
	}
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := s.requireManager(ctx, callerAccountID, sp); err != nil {
		return nil, err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("account")
	}
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetSpace, sp.ID, memberID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("member")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.aclRepo.UpdateRoleByID(ctx, existing.ID, dom.ACLRole(role), callerAccountID); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	existing.Role = dom.ACLRole(role)
	return memberRespFromGrant(existing, memberAccountUUID), nil
}

// RemoveMember DELETE /drive/spaces/{uuid}/members/{account_uuid}. ACL manager+.
// owner 不可 remove (无 grant 行); 非现有 member → 404.
func (s *SharedSpaceSvc) RemoveMember(ctx context.Context, callerAccountID, tenantID int64, spaceUUID, memberAccountUUID string) error {
	if s.aclRepo == nil || s.accounts == nil {
		return apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	sp, err := s.lookupShared(ctx, spaceUUID, tenantID)
	if err != nil {
		return err
	}
	if err := s.requireManager(ctx, callerAccountID, sp); err != nil {
		return err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return apperr.ErrNotFound.Withf("account")
	}
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetSpace, sp.ID, memberID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("member")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if err := s.aclRepo.SoftDeleteByID(ctx, existing.ID, callerAccountID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// ListFolderMembers GET /drive/folders/{uuid}/members.
// 只允许 shared space 下普通 folder;首项投影真实 owner (role=owner),其余返回
// account grants 的 effective list:target→root 路径上同一账号取最近 grant,
// 因此子目录可覆盖父级角色。
func (s *SharedSpaceSvc) ListFolderMembers(ctx context.Context, callerAccountID, tenantID int64, folderUUID string) ([]MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	folderID, sp, ancestors, err := s.lookupSharedFolder(ctx, folderUUID, tenantID)
	if err != nil {
		return nil, err
	}
	role, err := s.acl.CheckEffectiveRole(ctx, callerAccountID, dom.ACLTargetFolder, folderID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastViewer(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	return s.listEffectiveAccountMembers(ctx, sp.TenantID, sp.OwnerAccountID, ancestors)
}

// AddFolderMember POST /drive/folders/{uuid}/members.
// 若上级已授予该账号,这里会创建当前 folder direct grant 作为覆写。
func (s *SharedSpaceSvc) AddFolderMember(ctx context.Context, callerAccountID, tenantID int64, folderUUID, memberAccountUUID, role string) (*MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	role = strings.TrimSpace(role)
	if !validMemberRole(role) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_role")
	}
	folderID, sp, _, err := s.lookupSharedFolder(ctx, folderUUID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := s.requireTargetManager(ctx, callerAccountID, dom.ACLTargetFolder, folderID); err != nil {
		return nil, err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("account")
	}
	if sp.OwnerAccountID != nil && *sp.OwnerAccountID == memberID {
		return nil, apperr.ErrConflict.Withf("drive.owner_cannot_be_member")
	}
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetFolder, folderID, memberID)
	if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if existing != nil {
		return nil, apperr.ErrConflict.Withf("drive.member_exists")
	}
	row, err := s.aclRepo.InsertAccountGrant(ctx, drepo.InsertAccountGrantInput{
		TenantID:  sp.TenantID,
		Kind:      dom.ACLTargetFolder,
		TargetID:  folderID,
		AccountID: memberID,
		Role:      dom.ACLRole(role),
		GrantedBy: callerAccountID,
	})
	if err != nil {
		if strings.Contains(err.Error(), "23505") {
			return nil, apperr.ErrConflict.Withf("drive.member_exists")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return memberRespFromGrant(row, memberAccountUUID), nil
}

// UpdateFolderMember PATCH /drive/folders/{uuid}/members/{account_uuid}.
// 当前 folder 无 direct grant 时插入一条,用于把继承角色改成子级覆写角色。
func (s *SharedSpaceSvc) UpdateFolderMember(ctx context.Context, callerAccountID, tenantID int64, folderUUID, memberAccountUUID, role string) (*MemberResp, error) {
	if s.aclRepo == nil || s.accounts == nil {
		return nil, apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	role = strings.TrimSpace(role)
	if !validMemberRole(role) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_role")
	}
	folderID, sp, _, err := s.lookupSharedFolder(ctx, folderUUID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := s.requireTargetManager(ctx, callerAccountID, dom.ACLTargetFolder, folderID); err != nil {
		return nil, err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return nil, apperr.ErrNotFound.Withf("account")
	}
	if sp.OwnerAccountID != nil && *sp.OwnerAccountID == memberID {
		return nil, apperr.ErrConflict.Withf("drive.owner_cannot_be_member")
	}
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetFolder, folderID, memberID)
	if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if existing == nil {
		row, err := s.aclRepo.InsertAccountGrant(ctx, drepo.InsertAccountGrantInput{
			TenantID:  sp.TenantID,
			Kind:      dom.ACLTargetFolder,
			TargetID:  folderID,
			AccountID: memberID,
			Role:      dom.ACLRole(role),
			GrantedBy: callerAccountID,
		})
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		return memberRespFromGrant(row, memberAccountUUID), nil
	}
	if err := s.aclRepo.UpdateRoleByID(ctx, existing.ID, dom.ACLRole(role), callerAccountID); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	existing.Role = dom.ACLRole(role)
	return memberRespFromGrant(existing, memberAccountUUID), nil
}

// RemoveFolderMember DELETE /drive/folders/{uuid}/members/{account_uuid}.
// 只删除当前 folder direct grant;若上级还有 grant,该账号会恢复继承。
func (s *SharedSpaceSvc) RemoveFolderMember(ctx context.Context, callerAccountID, tenantID int64, folderUUID, memberAccountUUID string) error {
	if s.aclRepo == nil || s.accounts == nil {
		return apperr.ErrInternal.Withf("drive.members_not_wired")
	}
	folderID, _, _, err := s.lookupSharedFolder(ctx, folderUUID, tenantID)
	if err != nil {
		return err
	}
	if err := s.requireTargetManager(ctx, callerAccountID, dom.ACLTargetFolder, folderID); err != nil {
		return err
	}
	memberID, err := s.accounts.ResolveByUUID(ctx, memberAccountUUID, tenantID)
	if err != nil {
		return apperr.ErrNotFound.Withf("account")
	}
	existing, err := s.aclRepo.GetAccountGrant(ctx, dom.ACLTargetFolder, folderID, memberID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if err := s.aclRepo.SoftDeleteByID(ctx, existing.ID, callerAccountID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// lookupShared B3 helper: 取 shared space + 校 tenant 一致 + kind=shared (others reject 404).
func (s *SharedSpaceSvc) lookupShared(ctx context.Context, spaceUUID string, tenantID int64) (*dom.Space, error) {
	sp, err := s.spaces.GetByUUID(ctx, spaceUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("space")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if sp.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("space")
	}
	if sp.Kind != dom.SpaceKindShared {
		return nil, apperr.ErrConflict.Withf("drive.members_only_shared")
	}
	return sp, nil
}

func (s *SharedSpaceSvc) lookupSharedFolder(ctx context.Context, folderUUID string, tenantID int64) (int64, *dom.Space, []ancestor, error) {
	var folderID int64
	err := s.acl.pool.QueryRow(ctx,
		`SELECT id FROM drive_folders WHERE uuid = $1 AND is_deleted = false`, folderUUID).Scan(&folderID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, nil, nil, apperr.ErrNotFound.Withf("folder")
		}
		return 0, nil, nil, apperr.ErrInternal.Wrap(err)
	}
	sp, ancestors, err := s.acl.resolveTargetAncestors(ctx, dom.ACLTargetFolder, folderID)
	if err != nil {
		return 0, nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if sp == nil || sp.TenantID != tenantID {
		return 0, nil, nil, apperr.ErrNotFound.Withf("folder")
	}
	if sp.Kind != dom.SpaceKindShared {
		return 0, nil, nil, apperr.ErrConflict.Withf("drive.members_only_shared")
	}
	return folderID, sp, ancestors, nil
}

func (s *SharedSpaceSvc) requireTargetManager(ctx context.Context, accountID int64, targetKind dom.ACLTargetKind, targetID int64) error {
	r, err := s.acl.CheckEffectiveRole(ctx, accountID, targetKind, targetID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastManager(r) {
		return apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	return nil
}

func (s *SharedSpaceSvc) listEffectiveAccountMembers(ctx context.Context, tenantID int64, ownerAccountID *int64, ancestors []ancestor) ([]MemberResp, error) {
	if len(ancestors) == 0 {
		return nil, nil
	}
	valuesSQL := ""
	args := []interface{}{}
	for i, a := range ancestors {
		if i > 0 {
			valuesSQL += ","
		}
		valuesSQL += fmt.Sprintf("($%d::text, $%d::bigint, $%d::int)", len(args)+1, len(args)+2, len(args)+3)
		args = append(args, string(a.Kind), a.ID, i)
	}
	args = append(args, tenantID)
	tenantIdx := len(args)
	q := fmt.Sprintf(`
        WITH targets(target_kind, target_id, depth) AS (VALUES %s)
        SELECT ae.id, ae.uuid, ae.tenant_id, ae.target_kind, ae.target_id,
               ae.subject_kind, ae.subject_id, ae.link_token_id, ae.role, ae.granted_by,
               ae.created_at, ae.created_by, ae.updated_at, ae.updated_by, ae.is_deleted, ae.deleted_at,
               targets.depth
          FROM drive_acl_entries ae
          JOIN targets ON targets.target_kind = ae.target_kind AND targets.target_id = ae.target_id
         WHERE ae.tenant_id = $%d
           AND ae.subject_kind = 'account'
           AND ae.subject_id IS NOT NULL
           AND ae.is_deleted = false
         ORDER BY targets.depth ASC, ae.id ASC
    `, valuesSQL, tenantIdx)
	rows, err := s.acl.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.listEffectiveAccountMembers: %w", err))
	}
	defer rows.Close()

	byAccount := map[int64]dom.ACLEntry{}
	order := []int64{}
	for rows.Next() {
		var a dom.ACLEntry
		var depth int
		if err := rows.Scan(
			&a.ID, &a.UUID, &a.TenantID, &a.TargetKind, &a.TargetID,
			&a.SubjectKind, &a.SubjectID, &a.LinkTokenID, &a.Role, &a.GrantedBy,
			&a.CreatedAt, &a.CreatedBy, &a.UpdatedAt, &a.UpdatedBy, &a.IsDeleted, &a.DeletedAt,
			&depth,
		); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if a.SubjectID == nil {
			continue
		}
		accountID := *a.SubjectID
		if _, exists := byAccount[accountID]; exists {
			continue
		}
		byAccount[accountID] = a
		order = append(order, accountID)
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	lookupIDs := make([]int64, 0, len(order)+1)
	if ownerAccountID != nil {
		lookupIDs = append(lookupIDs, *ownerAccountID)
	}
	lookupIDs = append(lookupIDs, order...)
	uuidByID, err := s.accounts.UUIDsByIDs(ctx, lookupIDs)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]MemberResp, 0, len(order)+1)
	owner, err := ownerMemberResp(ownerAccountID, uuidByID)
	if err != nil {
		return nil, err
	}
	if owner != nil {
		out = append(out, *owner)
	}
	for _, accountID := range order {
		if ownerAccountID != nil && accountID == *ownerAccountID {
			continue
		}
		row := byAccount[accountID]
		out = append(out, *memberRespFromGrant(&row, uuidByID[accountID]))
	}
	return out, nil
}

// requireManager B3 helper: caller 必须在 space 上 manager+ (owner default 走 ACL.defaultRole, 同样过).
func (s *SharedSpaceSvc) requireManager(ctx context.Context, accountID int64, sp *dom.Space) error {
	r, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, sp.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastManager(r) {
		return apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	return nil
}

// validMemberRole B3: 接受 viewer/editor/manager (不接受 admin / owner / 空字符串).
func validMemberRole(role string) bool {
	switch role {
	case string(dom.ACLRoleViewer), string(dom.ACLRoleEditor), string(dom.ACLRoleManager):
		return true
	}
	return false
}

// memberRespFromGrant 投影 grant → MemberResp; accountUUID 由 caller 传入 (服务层不强查).
func memberRespFromGrant(g *dom.ACLEntry, accountUUID string) *MemberResp {
	out := &MemberResp{
		AccountUUID: accountUUID,
		Role:        string(g.Role),
	}
	if g.SubjectID != nil {
		out.AccountID = *g.SubjectID
	}
	return out
}

// ownerMemberResp 把不落 ACL grant 的 space owner 投影进成员读模型。
// owner uuid 缺失属于数据完整性错误:返回空 uuid 会让客户端无法识别/禁选所有者。
func ownerMemberResp(ownerAccountID *int64, uuidByID map[int64]string) (*MemberResp, error) {
	if ownerAccountID == nil {
		return nil, apperr.ErrInternal.Withf("drive.owner_account_not_found")
	}
	uuid := strings.TrimSpace(uuidByID[*ownerAccountID])
	if uuid == "" {
		return nil, apperr.ErrInternal.Withf("drive.owner_account_not_found")
	}
	return &MemberResp{
		AccountID:   *ownerAccountID,
		AccountUUID: uuid,
		Role:        "owner",
	}, nil
}
