package drive

// cmf.go — F06 Phase 2.3 / F09 §3 conversation_message_files repository.
//
// 3 个查询入口:
//   GetByDriveFileUUID  — chat-import 入口校验 (反查 cmf, 验 tenant)
//   ListByConversation  — chat-attachments 主 query (JOIN drive_files 列附件元数据)
//   Create              — chat client 上传完 drive 文件后 INSERT cmf 行 (本 phase 未对外暴露, 保留)
//
// Service 层负责所有 ACL / tenant 校验; repo 仅做 SQL.

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// CMFRepo F06 §2.11 / F09 §3 conversation_message_files 的 PG 实现.
type CMFRepo struct{ pool *pgxpool.Pool }

// NewCMFRepo 构造.
func NewCMFRepo(pool *pgxpool.Pool) *CMFRepo { return &CMFRepo{pool: pool} }

// CMFJoinedAttachment Phase 2.3 ListByConversation 的 JOIN drive_files 投影行.
// 把 cmf 元数据 + 关联 drive_files 的展示字段一次返回, 避免 N+1 查文件.
type CMFJoinedAttachment struct {
	CMF  dom.CMFRow
	File CMFAttachmentFile
}

// CMFAttachmentFile Phase 2.3: chat-attachments 列表里 drive_files 的轻量投影.
// 只露列表必需字段; storage_key / sha256 等敏感列由 caller 走 file detail / preview 取.
type CMFAttachmentFile struct {
	UUID      string
	Name      string
	MimeType  string
	SizeBytes int64
	Scope     string // chat | drive (cmf 行可能指向尚未 import 的 chat scope, 也可能已 import 的 drive scope)
	Source    string
}

// GetByDriveFileUUID Phase 2.3: import-from-chat 入口反查 cmf.
// 返第一行 (按 created_at 倒序); 同一 drive_file_uuid 在同一 conversation 可能多次被 message 引用,
// 但本 service 不限制具体 message — 只要存在 cmf 行 (任何 message) 即视为合法 chat 附件.
// 不存在 → ErrNotFound (caller 翻 404 drive.chat_attachment_not_found).
func (r *CMFRepo) GetByDriveFileUUID(ctx context.Context, driveFileUUID string) (*dom.CMFRow, error) {
	const q = `
        SELECT id, uuid::text, tenant_id, conversation_uuid, message_uuid, account_id, role, drive_file_uuid::text,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM conversation_message_files
         WHERE drive_file_uuid = $1 AND is_deleted = false
         ORDER BY created_at DESC
         LIMIT 1
    `
	var c dom.CMFRow
	err := r.pool.QueryRow(ctx, q, driveFileUUID).Scan(
		&c.ID, &c.UUID, &c.TenantID, &c.ConversationUUID, &c.MessageUUID, &c.AccountID, &c.Role, &c.DriveFileUUID,
		&c.CreatedAt, &c.CreatedBy, &c.UpdatedAt, &c.UpdatedBy, &c.IsDeleted, &c.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.CMFRepo.GetByDriveFileUUID: %w", err)
	}
	return &c, nil
}

// ListByConversation Phase 2.3: chat-attachments 主 query.
// JOIN drive_files (软删过滤) 返 cmf + 文件展示元数据, 按 cmf.created_at 倒序; limit cap 500.
//
// **跨 tenant 静默**: 这里只按 conversation_uuid + tenant_id 过滤; service 层不需要再校验
// (调用方传的 tenantID 来自 JWT, 直接当过滤条件用; 跨 tenant cmf 行 silently invisible).
func (r *CMFRepo) ListByConversation(
	ctx context.Context, tenantID int64, conversationUUID string, limit int,
) ([]CMFJoinedAttachment, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	const q = `
        SELECT cmf.id, cmf.uuid::text, cmf.tenant_id, cmf.conversation_uuid, cmf.message_uuid,
               cmf.account_id, cmf.role, cmf.drive_file_uuid::text,
               cmf.created_at, cmf.created_by, cmf.updated_at, cmf.updated_by, cmf.is_deleted, cmf.deleted_at,
               df.uuid::text, df.name, df.mime_type, df.size_bytes, df.scope, df.source
          FROM conversation_message_files cmf
          JOIN drive_files df ON df.uuid = cmf.drive_file_uuid AND df.is_deleted = false
         WHERE cmf.conversation_uuid = $1
           AND cmf.tenant_id = $2
           AND cmf.is_deleted = false
         ORDER BY cmf.created_at DESC
         LIMIT $3
    `
	rows, err := r.pool.Query(ctx, q, conversationUUID, tenantID, limit)
	if err != nil {
		return nil, fmt.Errorf("drive.CMFRepo.ListByConversation: %w", err)
	}
	defer rows.Close()

	var out []CMFJoinedAttachment
	for rows.Next() {
		var (
			c CMFJoinedAttachment
		)
		if err := rows.Scan(
			&c.CMF.ID, &c.CMF.UUID, &c.CMF.TenantID, &c.CMF.ConversationUUID, &c.CMF.MessageUUID,
			&c.CMF.AccountID, &c.CMF.Role, &c.CMF.DriveFileUUID,
			&c.CMF.CreatedAt, &c.CMF.CreatedBy, &c.CMF.UpdatedAt, &c.CMF.UpdatedBy, &c.CMF.IsDeleted, &c.CMF.DeletedAt,
			&c.File.UUID, &c.File.Name, &c.File.MimeType, &c.File.SizeBytes, &c.File.Scope, &c.File.Source,
		); err != nil {
			return nil, fmt.Errorf("drive.CMFRepo.ListByConversation scan: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Create Phase 2.3: chat client 上传完 drive 文件后 INSERT cmf 行.
// 本 phase 不直接对外暴露 endpoint, 保留供后续 chat upload integration 用; 失败返原始 err.
//
// uq_cmf_msg_file 唯一约束 (conversation, message, drive_file) 违反 → 直接返 err
// (caller 决定是否当作 idempotent 重复 INSERT 处理).
func (r *CMFRepo) Create(ctx context.Context, in dom.CreateCMFInput) error {
	role := in.Role
	if role == "" {
		role = dom.CMFRoleUserInput
	}
	const q = `
        INSERT INTO conversation_message_files
            (tenant_id, conversation_uuid, message_uuid, account_id, role, drive_file_uuid,
             created_by, updated_by)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
    `
	_, err := r.pool.Exec(ctx, q,
		in.TenantID, in.ConversationUUID, in.MessageUUID, in.AccountID, string(role), in.DriveFileUUID,
		in.CreatedBy,
	)
	if err != nil {
		return fmt.Errorf("drive.CMFRepo.Create: %w", err)
	}
	return nil
}
