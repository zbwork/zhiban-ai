// chat_import.go — F06 Phase 2.3: chat-attachments list + import-from-chat row-update.
//
// 2 个 service 入口对应 2 个客户端 endpoint:
//
//	ChatAttachments → GET /drive/files:chat-attachments   tenant-scoped 列附件 (cmf JOIN drive_files)
//	ImportFromChat  → POST /drive/files:import-from-chat  纯 row update on drive_files (无 CopyObject)
//
// 关键不变量 (F06 §6.2):
//   - 不复制对象, 不动 storage_key, drive_file_uuid 不变
//   - 仅 UPDATE drive_files SET scope='drive', source='chat_import', drive_folder_id=$,
//     origin_message_file_id=$cmf.id + 审计字段
//   - 同 file 已 import → 409 drive.already_imported
//   - 系统目录禁手动 import → 409 drive.system_folder_protected
//   - 入口反查 cmf 验 tenant; 跨 tenant 立刻 404 drive.chat_attachment_not_found
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// ChatImportSvc Phase 2.3: chat-attachments + import-from-chat.
type ChatImportSvc struct {
	pool    *pgxpool.Pool
	spaces  *drepo.SpaceRepo
	folders *drepo.FolderRepo
	files   *drepo.FileRepo
	cmf     *drepo.CMFRepo
	acl     *ACLService
}

// NewChatImportSvc 构造.
func NewChatImportSvc(
	pool *pgxpool.Pool,
	sp *drepo.SpaceRepo,
	fd *drepo.FolderRepo,
	fl *drepo.FileRepo,
	cmf *drepo.CMFRepo,
	acl *ACLService,
) *ChatImportSvc {
	return &ChatImportSvc{
		pool:    pool,
		spaces:  sp,
		folders: fd,
		files:   fl,
		cmf:     cmf,
		acl:     acl,
	}
}

// =====================================================
// ChatAttachments (GET /drive/files:chat-attachments)
// =====================================================

// ChatAttachmentsReq Phase 2.3 GET /drive/files:chat-attachments 请求参数.
type ChatAttachmentsReq struct {
	ConversationUUID string
	Limit            int // 默认 100, cap 500
}

// ChatAttachmentItem Phase 2.3 列表响应单行.
//
// scope/source 一并返出, 让客户端区分 "仍是 chat 状态" 与 "已 import 到 drive";
// folder_uuid 不返 (cmf 关注的是 chat 时间线锚, 不关心 drive 目录归属;
// 想知道目录请走 GET /drive/files/{uuid}).
type ChatAttachmentItem struct {
	CMFID            int64     `json:"cmf_id"`
	CMFUUID          string    `json:"cmf_uuid"`
	ConversationUUID string    `json:"conversation_uuid"`
	MessageUUID      string    `json:"message_uuid"`
	Role             string    `json:"role"`
	DriveFileUUID    string    `json:"drive_file_uuid"`
	Name             string    `json:"name"`
	MimeType         string    `json:"mime_type"`
	SizeBytes        int64     `json:"size_bytes"`
	Scope            string    `json:"scope"`  // chat / drive
	Source           string    `json:"source"` // user_upload / chat_upload / chat_import / ...
	CreatedAt        time.Time `json:"created_at"`
}

// ChatAttachmentsResp Phase 2.3 列表响应外层.
type ChatAttachmentsResp struct {
	Items []ChatAttachmentItem `json:"items"`
}

// ChatAttachments GET /drive/files:chat-attachments?conversation_uuid=X&limit=N
//
// 列出某 conversation 内所有 attachment 行 (cmf JOIN drive_files), 仅 caller tenant 内可见.
// 跨 tenant cmf 行 silently invisible (不报 403, 直接空列表).
//
// 不做 message-level read ACL 校验: chat 在自己 conversation 内的附件都可见 (与 F09 设计一致).
func (s *ChatImportSvc) ChatAttachments(
	ctx context.Context, accountID, tenantID int64, req ChatAttachmentsReq,
) (*ChatAttachmentsResp, error) {
	convUUID := strings.TrimSpace(req.ConversationUUID)
	if convUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid required")
	}
	limit := req.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	rows, err := s.cmf.ListByConversation(ctx, tenantID, convUUID, limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	items := make([]ChatAttachmentItem, 0, len(rows))
	for _, r := range rows {
		items = append(items, ChatAttachmentItem{
			CMFID:            r.CMF.ID,
			CMFUUID:          r.CMF.UUID,
			ConversationUUID: r.CMF.ConversationUUID,
			MessageUUID:      r.CMF.MessageUUID,
			Role:             string(r.CMF.Role),
			DriveFileUUID:    r.CMF.DriveFileUUID,
			Name:             r.File.Name,
			MimeType:         r.File.MimeType,
			SizeBytes:        r.File.SizeBytes,
			Scope:            r.File.Scope,
			Source:           r.File.Source,
			CreatedAt:        r.CMF.CreatedAt,
		})
	}
	return &ChatAttachmentsResp{Items: items}, nil
}

// =====================================================
// ImportFromChat (POST /drive/files:import-from-chat)
// =====================================================

// ImportFromChatReq Phase 2.3 import-from-chat 请求体.
type ImportFromChatReq struct {
	DriveFileUUID    string `json:"drive_file_uuid"`    // 待 import 的源 (来自 chat 上传的 drive_files)
	TargetFolderUUID string `json:"target_folder_uuid"` // 目标 folder; editor+ ACL, 非 system
}

// ImportFromChatResp Phase 2.3 import-from-chat 响应; 复用 upload.go 的 FileResp 形状.
type ImportFromChatResp struct {
	File FileResp `json:"file"`
}

// ImportFromChat POST /drive/files:import-from-chat
//
// 把一条 chat attachment (drive_files scope='chat') 提升为 drive 文件 (scope='drive', source='chat_import'),
// 挂到指定 folder. 不复制对象, 不动 storage_key. drive_file_uuid 不变.
//
// 流程 (F06 §6.2.2):
//  1. resolve cmf via GetByDriveFileUUID → 验 tenant == caller.tenantID, 否则 404 drive.chat_attachment_not_found
//  2. resolve drive_files via GetByUUID → 验 tenant 一致 + scope='chat' + 未软删;
//     scope already 'drive' → 409 drive.already_imported
//  3. resolve target folder via GetByUUID → 同 tenant + 非 system; ACL editor+ on folder
//  4. duplicate-name check on (folder, name) → 已存在 → 409 drive.duplicate_name
//  5. TX: UPDATE drive_files (scope/source/folder/origin_message_file_id + audit) via ImportFromChatTx
//     空间 used_bytes 不动 (字节早在 chat upload 时已记入 space, scope 切换不算新增)
//  6. 反查更新后行, 返 FileResp
func (s *ChatImportSvc) ImportFromChat(
	ctx context.Context, accountID, tenantID int64, req ImportFromChatReq,
) (*ImportFromChatResp, error) {
	if strings.TrimSpace(req.DriveFileUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("drive_file_uuid required")
	}
	if strings.TrimSpace(req.TargetFolderUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("target_folder_uuid required")
	}

	// 1. 反查 cmf — 没 cmf 行 → 不允许 import (防御 caller 直接拿 drive_file_uuid 试图 import 任意文件).
	cmfRow, err := s.cmf.GetByDriveFileUUID(ctx, req.DriveFileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.chat_attachment_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if cmfRow.TenantID != tenantID {
		// 跨 tenant 一律 404, 不泄露 cmf 是否存在.
		return nil, apperr.ErrNotFound.Withf("drive.chat_attachment_not_found")
	}

	// 2. 反查 drive_files. 已软删 → 同样 404 drive.chat_attachment_not_found (chat 已不可用); 不分别区分.
	file, err := s.files.GetByUUID(ctx, req.DriveFileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.chat_attachment_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// space → 验 tenant 一致 (防御: cmf.tenant 与 drive_files 所在 space.tenant 不一致 = 数据漂移).
	sp, err := s.spaces.GetByID(ctx, file.SpaceID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if sp == nil || sp.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("drive.chat_attachment_not_found")
	}
	// scope guard: 已 import (scope='drive') → 409.
	if file.Scope == dom.FileScopeDrive {
		return nil, apperr.ErrConflict.Withf("drive.already_imported")
	}
	if file.Scope != dom.FileScopeChat {
		// 防御性: 未来增 scope 时这里要先扩白名单.
		return nil, apperr.ErrConflict.Withf("drive.unsupported_source_scope")
	}

	// 3. 反查 target folder.
	folder, err := s.folders.GetByUUID(ctx, req.TargetFolderUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("folder")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	folderSpace, err := s.spaces.GetByID(ctx, folder.SpaceID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if folderSpace == nil || folderSpace.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("folder")
	}
	if folder.IsSystem {
		return nil, apperr.ErrConflict.Withf("drive.system_folder_protected")
	}
	// ACL editor+ on target folder.
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, folder.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastEditor(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	// 4. 同 folder 同名预检 (双重防御; INSERT 阶段也有 23505 兜底).
	folderID := folder.ID
	if existing, err := s.files.GetByFolderAndName(ctx, &folderID, file.Name); err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return nil, apperr.ErrInternal.Wrap(err)
	} else if existing != nil {
		return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
	}

	// 5. TX: 行级 UPDATE (scope/source/folder/origin_message_file_id + audit).
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.ChatImportSvc.ImportFromChat.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	updated, err := s.files.ImportFromChatTx(ctx, tx, file.ID, folder.ID, cmfRow.ID, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.chat_attachment_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.ChatImportSvc.ImportFromChat.commit: %w", err))
	}
	committed = true

	// 6. 构造 FileResp (复用 upload.go 形状).
	return &ImportFromChatResp{
		File: FileResp{
			UUID:       updated.UUID,
			SpaceUUID:  folderSpace.UUID,
			FolderUUID: folder.UUID,
			Name:       updated.Name,
			MimeType:   updated.MimeType,
			SizeBytes:  updated.SizeBytes,
			StorageKey: updated.StorageKey,
			CreatedAt:  updated.CreatedAt,
		},
	}, nil
}
