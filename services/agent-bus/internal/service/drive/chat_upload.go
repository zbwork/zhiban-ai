// chat_upload.go — F06 Slice A1 (Phase 2.Z-pre-1): /api/agent-bus/v1/message-files/* compat
// 走 drivev3 + conversation_message_files. 替换 legacy svcmf.Service.
//
// 流程:
//
//	Presign : 派生 staging key + final key + INSERT ticket (source=chat_upload,
//	          folder_id=NULL, account_id=caller). 客户端 PUT staging.
//	Confirm : Stat staging → Copy staging→final → INSERT drive_files
//	          (scope='chat', source='chat_upload', drive_folder_id=NULL,
//	          created_by=caller) → ticket=done.
//	Bind    : chat.Send 后调; 把 staged 附件 (drive_file_uuid) 绑到 (conversation_uuid,
//	          message_uuid) — INSERT cmf 行, role='user_input'. 满足 chat.AttachmentBinder.
//	Download/Preview : 通过 drive.SnapshotSvc 签 GET URL.
//
// 与 client API drive.UploadSvc 的关键差异:
//   - 无 folder (chat 文件 scope='chat' drive_folder_id NULL, 由 chk_chat_no_folder 约束允许)
//   - 无 ACL on folder (caller 上传自己 chat 附件, 视作 caller 自己的 personal space owner)
//   - source = chat_upload (而非 user_upload)
//   - 同名不冲突 (uq_dfile_folder_name partial index WHERE drive_folder_id IS NOT NULL)
package drive

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/drivefilename"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// ChatUploadSvc Slice A1 (Phase 2.Z-pre-1) 服务: chat 附件 staging+confirm+bind.
type ChatUploadSvc struct {
	pool    *pgxpool.Pool
	spaces  *drepo.SpaceRepo
	files   *drepo.FileRepo
	tickets *drepo.TicketRepo
	cmf     *drepo.CMFRepo
	acl     *ACLService
	storage StorageGetter

	presignTTL  time.Duration
	ticketTTL   time.Duration
	downloadTTL time.Duration
}

// NewChatUploadSvc 构造.
func NewChatUploadSvc(
	pool *pgxpool.Pool,
	spaces *drepo.SpaceRepo, files *drepo.FileRepo,
	tickets *drepo.TicketRepo, cmf *drepo.CMFRepo,
	acl *ACLService,
	storage StorageGetter,
) *ChatUploadSvc {
	return &ChatUploadSvc{
		pool: pool, spaces: spaces, files: files,
		tickets: tickets, cmf: cmf, acl: acl, storage: storage,
		presignTTL:  10 * time.Minute,
		ticketTTL:   70 * time.Minute,
		downloadTTL: 10 * time.Minute,
	}
}

// ----- DTOs (legacy svcmf.* 兼容形状) -----

// ChatPresignReq /message-files/presign 入参. conversation_uuid 可选; 仅 Bind 阶段写 cmf 用.
type ChatPresignReq struct {
	FileName         string `json:"file_name"`
	FileSize         int64  `json:"file_size"`
	MimeType         string `json:"mime_type"`
	ConversationUUID string `json:"conversation_uuid,omitempty"`
}

// ChatPresignResp /message-files/presign 出参 (与 legacy 同 shape).
type ChatPresignResp struct {
	FileUUID      string            `json:"file_uuid"`
	UploadURL     string            `json:"upload_url"`
	UploadHeaders map[string]string `json:"upload_headers,omitempty"`
	StorageKey    string            `json:"storage_key"`
	StorageKind   string            `json:"storage_kind"`
	ExpiresIn     int               `json:"expires_in"`
	ExpiresAt     time.Time         `json:"expires_at"`
	StagedUntil   time.Time         `json:"staged_until"`
}

// ChatConfirmReq /message-files/confirm 入参.
type ChatConfirmReq struct {
	FileUUID   string `json:"file_uuid"`
	StorageKey string `json:"storage_key,omitempty"` // 可选 echo
}

// ChatConfirmResp /message-files/confirm 出参.
type ChatConfirmResp struct {
	FileUUID string `json:"file_uuid"`
	State    string `json:"state"`
}

// ChatUploadReq is the Bus proxy-upload variant of ChatPresignReq. It keeps the
// same ticket/key/confirm path as presign upload, but Bus writes the staging
// object on behalf of clients that cannot reach the object-store write endpoint.
type ChatUploadReq struct {
	FileName         string
	FileSize         int64
	MimeType         string
	ConversationUUID string
	Body             io.Reader
}

// ChatDownloadResp 同 legacy DownloadResp.
type ChatDownloadResp struct {
	FileUUID    string    `json:"file_uuid"`
	URL         string    `json:"url"`
	FileName    string    `json:"file_name"`
	MimeType    string    `json:"mime_type"`
	FileSize    int64     `json:"file_size"`
	ExpiresAt   time.Time `json:"expires_at"`
	Inline      bool      `json:"inline"`
	StorageKind string    `json:"storage_kind"`
}

// ----- Presign -----

func (s *ChatUploadSvc) Presign(ctx context.Context, accountID, tenantID int64, req ChatPresignReq) (*ChatPresignResp, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	if req.FileSize <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("file_size > 0 required")
	}
	cleanName := drivefilename.Sanitize(req.FileName)
	if cleanName == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_name invalid")
	}
	mime := strings.ToLower(strings.TrimSpace(req.MimeType))
	if mime == "" {
		mime = "application/octet-stream"
	}

	// 派生 keys; chat 附件归 caller 的 personal space (内部归属, 客户端不感知)
	fileUUID := uuid.NewString()
	ext := extFromName(cleanName)
	stagingKey := buildStagingKey(tenantID, fileUUID, ext)
	finalKey := buildFinalKey(tenantID, accountID, fileUUID, ext)

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}
	pres, err := store.PresignPut(ctx, object.PresignPutInput{
		Key: stagingKey, ContentType: mime, ContentLength: req.FileSize, TTL: s.presignTTL,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("chat presign put: %w", err))
	}

	// INSERT ticket: source=chat_upload, folder=NULL.
	if err := s.tickets.Create(ctx, dom.CreateUploadTicketInput{
		FileUUID:     fileUUID,
		AccountID:    accountID,
		TenantID:     tenantID,
		FolderID:     nil,
		DeclaredSize: req.FileSize,
		DeclaredMime: mime,
		DeclaredName: cleanName,
		StagingKey:   stagingKey,
		FinalKey:     finalKey,
		UploadID:     nil,
		PartSize:     nil,
		Source:       dom.FileSourceChatUpload,
		ExpiresAt:    time.Now().Add(s.ticketTTL),
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	return &ChatPresignResp{
		FileUUID:      fileUUID,
		UploadURL:     pres.URL,
		UploadHeaders: pres.Headers,
		StorageKey:    stagingKey,
		StorageKind:   store.Kind(),
		ExpiresIn:     int(s.presignTTL.Seconds()),
		ExpiresAt:     pres.ExpiresAt,
		StagedUntil:   time.Now().Add(s.ticketTTL),
	}, nil
}

// Upload proxies a chat attachment upload through Bus while preserving the
// existing staging-key + confirm flow. It intentionally delegates key/ticket
// creation to Presign and finalization to Confirm.
func (s *ChatUploadSvc) Upload(ctx context.Context, accountID, tenantID int64, req ChatUploadReq) (*ChatConfirmResp, error) {
	if req.Body == nil {
		return nil, apperr.ErrInvalidParams.Withf("file body required")
	}
	pres, err := s.Presign(ctx, accountID, tenantID, ChatPresignReq{
		FileName:         req.FileName,
		FileSize:         req.FileSize,
		MimeType:         req.MimeType,
		ConversationUUID: req.ConversationUUID,
	})
	if err != nil {
		return nil, err
	}
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}
	putter, ok := store.(interface {
		PutObject(context.Context, string, io.Reader, int64, string) error
	})
	if !ok {
		return nil, apperr.ErrInternal.Withf("drive.proxy_upload_not_supported")
	}
	if err := putter.PutObject(ctx, pres.StorageKey, req.Body, req.FileSize, req.MimeType); err != nil {
		return nil, apperr.ErrUpstreamUnavailable.Withf("drive.proxy_upload_failed").Wrap(err)
	}
	return s.Confirm(ctx, accountID, tenantID, ChatConfirmReq{FileUUID: pres.FileUUID, StorageKey: pres.StorageKey})
}

// ----- Confirm -----

func (s *ChatUploadSvc) Confirm(ctx context.Context, accountID, tenantID int64, req ChatConfirmReq) (*ChatConfirmResp, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	if req.FileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}

	// 反查 ticket
	ticket, err := s.tickets.GetByFileUUID(ctx, req.FileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrForbidden.Withf("chat.attachment_not_owned")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if ticket.AccountID != accountID || ticket.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("chat.attachment_not_owned")
	}
	if ticket.Status != dom.TicketStatusPending {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if time.Now().After(ticket.ExpiresAt) {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if req.StorageKey != "" && req.StorageKey != ticket.StagingKey {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid: storage_key mismatch")
	}

	// caller 的 personal space (chat 文件归这里; 内部归属, 用户层无感)
	personal, err := s.spaces.EnsurePersonal(ctx, tenantID, accountID, "")
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}

	// Stat staging
	stat, err := store.Stat(ctx, ticket.StagingKey)
	if err != nil {
		if errors.Is(err, object.ErrNotFound) {
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.New(apperr.PreconditionFailed, "drive.staging_missing").Withf("staging object not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if stat.Size != ticket.DeclaredSize {
		_ = store.Delete(ctx, ticket.StagingKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.New(apperr.PreconditionFailed, "drive.size_mismatch").Withf("stat size %d != %d", stat.Size, ticket.DeclaredSize)
	}

	// Copy staging → final
	if err := store.Copy(ctx, ticket.StagingKey, ticket.FinalKey); err != nil {
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusPartial))
		return nil, apperr.ErrInternal.Withf("drive.copy_failed").Wrap(err)
	}

	// TX: INSERT drive_files (scope=chat, source=chat_upload, folder_id=NULL) +
	// space used_bytes 不动 (chat 附件不计 quota 当前简化; 真实 quota 待 Phase 后续)
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = store.Delete(ctx, ticket.StagingKey)
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	// 用预重设 file uuid 与 ticket.FileUUID 一致, 让 drive_files.uuid = ticket.FileUUID; 简化反查.
	// 注: CreateTx 会自动生成 uuid; chat 路径需要让 caller-known file_uuid 保持一致.
	// 用 INSERT ... RETURNING uuid 让 PG 生成新 uuid, 我们记下来供 cmf 引用.
	mime := ticket.DeclaredMime
	if stat.ContentType != "" {
		mime = stat.ContentType
	}
	file, err := s.files.CreateTx(ctx, tx, dom.CreateFileInput{
		SpaceID:       personal.ID,
		DriveFolderID: nil, // chat 文件 chk_chat_no_folder
		Name:          ticket.DeclaredName,
		MimeType:      mime,
		SizeBytes:     ticket.DeclaredSize,
		SHA256:        nil,
		StorageKey:    ticket.FinalKey,
		Scope:         dom.FileScopeChat,
		Source:        dom.FileSourceChatUpload,
		CreatedBy:     accountID,
	})
	if err != nil {
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := s.tickets.UpdateStatusTx(ctx, tx, ticket.FileUUID, string(dom.TicketStatusDone)); err != nil {
		_ = store.Delete(ctx, ticket.FinalKey)
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed = true

	// best-effort delete staging
	_ = store.Delete(ctx, ticket.StagingKey)

	// 注: chat 路径里 ticket.FileUUID 是 caller 见过的标识; drive_files.uuid 是新的 PG-generated.
	// 我们让 ChatConfirmResp.FileUUID 返 drive_files.uuid (后续 client 走 download/preview/bind
	// 都用这个 uuid; 旧 ticket.FileUUID 已 done, 失效).
	return &ChatConfirmResp{
		FileUUID: file.UUID,
		State:    "ready",
	}, nil
}

// ----- ResolveForMessage / BindToMessage (chat.AttachmentBinder 实现) -----

// ResolveForMessage validates file_uuids and returns metadata used to persist
// display blocks on the user message before CMF binding.
func (s *ChatUploadSvc) ResolveForMessage(ctx context.Context, accountID, tenantID int64, fileUUIDs []string) ([]messageblocks.Attachment, error) {
	if len(fileUUIDs) == 0 {
		return nil, nil
	}
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	return s.resolveMessageAttachments(ctx, accountID, tenantID, fileUUIDs)
}

// chat.Send 创建 message 后调; 把 staged 附件 (drive_file_uuid 列表) 绑到这条
// message — INSERT 1 行 cmf per attachment, role='user_input'.
//
// 幂等容忍: 部分 file 已 bind 过 (uq_cmf_msg_file unique) → 跳过该行, 不报错.
func (s *ChatUploadSvc) BindToMessage(ctx context.Context, accountID, tenantID int64, messageUUID string, fileUUIDs []string) error {
	if len(fileUUIDs) == 0 {
		return nil
	}
	if accountID <= 0 || tenantID <= 0 {
		return apperr.ErrUnauthorized.Withf("auth required")
	}
	if messageUUID == "" {
		return apperr.ErrInvalidParams.Withf("message_uuid required")
	}
	// 反查 message → conversation.uuid via conversation_id JOIN
	// (messages 表只持 conversation_id, 不持 conversation_uuid).
	var conversationUUID string
	err := s.pool.QueryRow(ctx,
		`SELECT c.uuid::text
           FROM messages m JOIN conversations c ON c.id = m.conversation_id
          WHERE m.uuid::text = $1 AND m.tenant_id = $2 LIMIT 1`,
		messageUUID, tenantID).Scan(&conversationUUID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound.Withf("chat.message_not_found")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	resolved, err := s.resolveMessageAttachments(ctx, accountID, tenantID, fileUUIDs)
	if err != nil {
		return err
	}
	for _, f := range resolved {
		if err := s.cmf.Create(ctx, dom.CreateCMFInput{
			TenantID:         tenantID,
			ConversationUUID: conversationUUID,
			MessageUUID:      messageUUID,
			AccountID:        accountID,
			Role:             dom.CMFRoleUserInput,
			DriveFileUUID:    f.UUID,
			CreatedBy:        accountID,
		}); err != nil {
			// uq_cmf_msg_file 冲突 (已 bind 过) → 容忍
			if strings.Contains(err.Error(), "uq_cmf_msg_file") {
				continue
			}
			return apperr.ErrInternal.Wrap(err)
		}
	}
	return nil
}

func (s *ChatUploadSvc) resolveMessageAttachments(ctx context.Context, accountID, tenantID int64, fileUUIDs []string) ([]messageblocks.Attachment, error) {
	out := make([]messageblocks.Attachment, 0, len(fileUUIDs))
	seen := make(map[string]struct{}, len(fileUUIDs))
	for _, raw := range fileUUIDs {
		fu := strings.TrimSpace(raw)
		if fu == "" {
			continue
		}
		if _, ok := seen[fu]; ok {
			continue
		}
		seen[fu] = struct{}{}
		// 校 caller 对该 file 有消息附件使用权: chat 上传看创建者, drive 文件看 ACL viewer+.
		f, err := s.files.GetByUUID(ctx, fu)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", fu)
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if err := s.authorizeMessageAttachment(ctx, accountID, tenantID, f, fu); err != nil {
			return nil, err
		}
		out = append(out, messageblocks.Attachment{
			UUID:      f.UUID,
			Name:      f.Name,
			MimeType:  f.MimeType,
			SizeBytes: f.SizeBytes,
		})
	}
	return out, nil
}

func (s *ChatUploadSvc) authorizeMessageAttachment(ctx context.Context, accountID, tenantID int64, f *dom.File, requestedUUID string) error {
	if f == nil {
		return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
	}
	space, err := s.spaces.GetByID(ctx, f.SpaceID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if space == nil || space.TenantID != tenantID {
		return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
	}

	switch f.Scope {
	case dom.FileScopeChat:
		if f.CreatedBy == nil || *f.CreatedBy != accountID {
			// F10 compatibility: old clients stored a chat attachment URL directly as
			// a digital employee avatar. Only an active member of a room that also contains
			// that agent may render it; being in the same tenant is not sufficient.
			allowed, err := s.canAccessGroupAgentAvatar(ctx, accountID, tenantID, requestedUUID)
			if err != nil {
				return apperr.ErrInternal.Wrap(err)
			}
			if allowed {
				return nil
			}
			return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
		}
		return nil
	case dom.FileScopeDrive:
		if f.CopyStatus != dom.CopyStatusReady {
			return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
		}
		if f.Source == dom.FileSourceAgentOutput {
			allowed, err := s.canAccessBoundMessageFile(ctx, accountID, tenantID, requestedUUID)
			if err != nil {
				return apperr.ErrInternal.Wrap(err)
			}
			if allowed {
				return nil
			}
		}
		if s.acl == nil {
			return apperr.ErrInternal.Withf("drive.acl service not wired")
		}
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFile, f.ID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastFile(role, dom.ACLRoleViewer) {
			return apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", requestedUUID)
		}
		return nil
	default:
		return apperr.ErrForbidden.Withf("chat.attachment_scope_invalid: %s", requestedUUID)
	}
}

func (s *ChatUploadSvc) canAccessGroupAgentAvatar(ctx context.Context, accountID, tenantID int64, driveFileUUID string) (bool, error) {
	if s.pool == nil || accountID <= 0 || tenantID <= 0 || strings.TrimSpace(driveFileUUID) == "" {
		return false, nil
	}
	var ok bool
	err := s.pool.QueryRow(ctx, `
SELECT EXISTS (
	SELECT 1
	  FROM digital_employees de
	  JOIN room_participants agent_participant
	    ON agent_participant.agent_id = de.id
	   AND agent_participant.kind = 'agent'
	   AND agent_participant.left_at IS NULL
	  JOIN rooms r
	    ON r.id = agent_participant.room_id
	   AND r.tenant_id = de.tenant_id
	   AND r.status = 'active'
	   AND r.deleted_at IS NULL
	  JOIN room_participants human_participant
	    ON human_participant.room_id = r.id
	   AND human_participant.kind = 'human'
	   AND human_participant.account_id = $2
	   AND human_participant.left_at IS NULL
	 WHERE de.tenant_id = $1
	   AND de.source IN ('personal', 'enterprise')
	   AND de.status = 'published'
	   AND de.deleted_at IS NULL
	   AND de.avatar_url IN (
	       '/message-files/' || $3 || '/preview',
	       '/message-files/' || $3 || '/download',
	       '/api/agent-bus/v1/message-files/' || $3 || '/preview',
	       '/api/agent-bus/v1/message-files/' || $3 || '/download'
	   )
)`, tenantID, accountID, driveFileUUID).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("drive.ChatUploadSvc.canAccessGroupAgentAvatar: %w", err)
	}
	return ok, nil
}

func (s *ChatUploadSvc) canAccessBoundMessageFile(ctx context.Context, accountID, tenantID int64, driveFileUUID string) (bool, error) {
	if s.pool == nil || accountID <= 0 || tenantID <= 0 || strings.TrimSpace(driveFileUUID) == "" {
		return false, nil
	}
	var ok bool
	err := s.pool.QueryRow(ctx, `
SELECT EXISTS (
	SELECT 1
	  FROM conversation_message_files cmf
	  JOIN conversations c
	    ON c.uuid::text = cmf.conversation_uuid::text
	   AND c.tenant_id = cmf.tenant_id
	   AND c.deleted_at IS NULL
	 WHERE cmf.tenant_id = $1
	   AND cmf.drive_file_uuid::text = $2
	   AND cmf.is_deleted = false
	   AND cmf.role IN ('agent_output', 'assistant_attachment')
	   AND (
	        (c.room_id IS NULL AND c.account_id = $3)
	        OR (
	          c.room_id IS NOT NULL
	          AND EXISTS (
	            SELECT 1
	              FROM room_participants rp
	             WHERE rp.room_id = c.room_id
	               AND rp.kind = 'human'
	               AND rp.account_id = $3
	               AND rp.left_at IS NULL
	          )
	        )
	   )
)`, tenantID, driveFileUUID, accountID).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("drive.ChatUploadSvc.canAccessBoundMessageFile: %w", err)
	}
	return ok, nil
}

// ----- Download / Preview -----

func (s *ChatUploadSvc) Download(ctx context.Context, accountID, tenantID int64, fileUUID string) (*ChatDownloadResp, error) {
	return s.downloadOrPreview(ctx, accountID, tenantID, fileUUID, false)
}

func (s *ChatUploadSvc) Preview(ctx context.Context, accountID, tenantID int64, fileUUID string) (*ChatDownloadResp, error) {
	return s.downloadOrPreview(ctx, accountID, tenantID, fileUUID, true)
}

// ResolveRuntimeURL signs a short-lived object URL for external runtimes.
// It uses the same ownership checks as the client /message-files download
// APIs; callers must not pass user bearer tokens to runtimes.
func (s *ChatUploadSvc) ResolveRuntimeURL(ctx context.Context, accountID, tenantID int64, fileUUID string, inline bool) (string, error) {
	resp, err := s.downloadOrPreview(ctx, accountID, tenantID, fileUUID, inline)
	if err != nil {
		return "", err
	}
	return resp.URL, nil
}

func (s *ChatUploadSvc) downloadOrPreview(ctx context.Context, accountID, tenantID int64, fileUUID string, inline bool) (*ChatDownloadResp, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	if fileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}
	f, err := s.files.GetByUUID(ctx, fileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrForbidden.Withf("attachment.access_denied")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.authorizeMessageAttachment(ctx, accountID, tenantID, f, fileUUID); err != nil {
		return nil, err
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}
	// agent 产出的 artifact 有时只登记了一个友好展示名("示例公司落地页"),没带
	// 扩展名——直接拿去签 Content-Disposition,用户下载下来的文件没有 .html
	// 后缀、系统不知道用什么打开(2026-08-17 复现)。这里按 f.MimeType 补一个,
	// 已经带扩展名的文件名原样透传,不覆盖用户/上传方自己选的扩展名。
	downloadName := drivefilename.EnsureExtension(f.Name, f.MimeType)
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key: f.StorageKey, TTL: s.downloadTTL, Inline: inline, FileName: downloadName,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &ChatDownloadResp{
		FileUUID:    f.UUID,
		URL:         out.URL,
		FileName:    downloadName,
		MimeType:    f.MimeType,
		FileSize:    f.SizeBytes,
		ExpiresAt:   out.ExpiresAt,
		Inline:      inline,
		StorageKind: store.Kind(),
	}, nil
}
