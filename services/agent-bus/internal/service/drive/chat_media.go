// chat_media.go — P2.2c (Plan 06): 聊天文件消息的会话级媒体引用 + 成员鉴权。
//
// 解决 Codex review 的 P0:
//   - human_direct 消息无 PG message,无法走 cmf(message-bound) 绑定;
//   - message-files preview/download 只认 uploader → 接收方打不开;
//   - 云盘文件直接下发原始 drive URL → 要么打不开,要么放宽 drive ACL 泄露私有云盘。
//
// 模型(详见 docs/plans/06-p2.2c-chat-media-permission.md):
//
//	CreateRef : caller 是会话活跃 human 成员 + 对源文件有权(自己 chat 上传 或 drive viewer+)
//	            → 快照 storage_key 建 ref。
//	Preview/Download : caller 是**同一会话**活跃 human 成员 → 现签短 TTL → 302。
//	                   不再查 drive ACL(由 room 成员授权);源 drive 端点 ACL 不放宽。
package drive

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// ChatMediaSvc P2.2c 服务。
type ChatMediaSvc struct {
	pool    *pgxpool.Pool
	files   *drepo.FileRepo
	spaces  *drepo.SpaceRepo
	refs    *drepo.ChatMediaRefRepo
	acl     *ACLService
	storage StorageGetter

	downloadTTL time.Duration
}

// NewChatMediaSvc 构造。
func NewChatMediaSvc(
	pool *pgxpool.Pool,
	files *drepo.FileRepo, spaces *drepo.SpaceRepo, refs *drepo.ChatMediaRefRepo,
	acl *ACLService, storage StorageGetter,
) *ChatMediaSvc {
	return &ChatMediaSvc{
		pool: pool, files: files, spaces: spaces, refs: refs,
		acl: acl, storage: storage,
		downloadTTL: 10 * time.Minute,
	}
}

// ----- DTOs -----

// ChatMediaCreateReq POST /chat/media 入参。
type ChatMediaCreateReq struct {
	ConversationUUID string `json:"conversation_uuid"`
	DriveFileUUID    string `json:"drive_file_uuid"`
}

// ChatMediaCreateResp POST /chat/media 出参。客户端据此拼 WuKong payload url:
// `${apiBase}/chat/media/{ref_uuid}/preview|download`。
//
// 字段语义:`ref_uuid` 是 chat media ref(授权单元);`drive_file_uuid` 是底层
// drive_files.uuid(溯源/import/去重)。两者**不可混用**:URL 永远用 ref_uuid,
// 审计/去重用 drive_file_uuid。
type ChatMediaCreateResp struct {
	RefUUID       string `json:"ref_uuid"`
	DriveFileUUID string `json:"drive_file_uuid"`
	MediaKind     int    `json:"media_kind"`
	SourceKind    string `json:"source_kind"`
	FileName      string `json:"file_name"`
	MimeType      string `json:"mime_type"`
	SizeBytes     int64  `json:"size_bytes"`
}

// ChatMediaDownloadResp GET /chat/media/{ref}/preview|download(JSON 形态;默认 302)。
type ChatMediaDownloadResp struct {
	RefUUID   string    `json:"ref_uuid"`
	URL       string    `json:"url"`
	FileName  string    `json:"file_name"`
	MimeType  string    `json:"mime_type"`
	SizeBytes int64     `json:"size_bytes"`
	Inline    bool      `json:"inline"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ----- CreateRef -----

func (s *ChatMediaSvc) CreateRef(ctx context.Context, accountID, tenantID int64, req ChatMediaCreateReq) (*ChatMediaCreateResp, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	if strings.TrimSpace(req.ConversationUUID) == "" || strings.TrimSpace(req.DriveFileUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid & drive_file_uuid required")
	}

	// 1. 解析会话 → id/room_id;租户校验。
	convID, roomID, convTenant, err := s.resolveConversation(ctx, req.ConversationUUID)
	if err != nil {
		return nil, err
	}
	if convTenant != tenantID {
		return nil, apperr.ErrForbidden.Withf("chat_media.conversation_cross_tenant")
	}
	// 2. 发送方必须是会话活跃 human 成员。
	member, err := s.isMember(ctx, convID, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !member {
		return nil, apperr.ErrForbidden.Withf("chat_media.sender_not_member")
	}

	// 3. 解析源 drive 文件。
	f, err := s.files.GetByUUID(ctx, req.DriveFileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrForbidden.Withf("chat_media.source_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 4. 源文件租户校验(经 space)。
	space, err := s.spaces.GetByID(ctx, f.SpaceID)
	if err != nil || space == nil || space.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("chat_media.source_cross_tenant")
	}

	// 5. 源文件授权:自己刚传的 chat 附件 OR 对云盘文件有 viewer+。
	sourceKind := dom.ChatMediaSourceDrive
	ownChatUpload := f.Scope == dom.FileScopeChat && f.CreatedBy != nil && *f.CreatedBy == accountID
	if ownChatUpload {
		sourceKind = dom.ChatMediaSourceUpload
	} else {
		role, aerr := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFile, f.ID)
		if aerr != nil {
			return nil, apperr.ErrInternal.Wrap(aerr)
		}
		// 非空 role 即 viewer 或以上(roleRank: ""=0, viewer=1, ...)。
		if role == "" {
			return nil, apperr.ErrForbidden.Withf("chat_media.source_not_authorized")
		}
	}

	// 6. 建 ref(快照 storage_key)。
	ref, err := s.refs.Create(ctx, dom.CreateChatMediaRefInput{
		TenantID:        tenantID,
		ConversationID:  convID,
		RoomID:          roomID,
		SenderAccountID: accountID,
		MediaKind:       mediaKindFromMime(f.MimeType),
		SourceKind:      sourceKind,
		DriveFileUUID:   f.UUID,
		StorageKey:      f.StorageKey,
		FileName:        f.Name,
		MimeType:        f.MimeType,
		SizeBytes:       f.SizeBytes,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	return &ChatMediaCreateResp{
		RefUUID:       ref.UUID,
		DriveFileUUID: ref.DriveFileUUID,
		MediaKind:     ref.MediaKind,
		SourceKind:    ref.SourceKind,
		FileName:      ref.FileName,
		MimeType:      ref.MimeType,
		SizeBytes:     ref.SizeBytes,
	}, nil
}

// ----- Preview / Download -----

func (s *ChatMediaSvc) Preview(ctx context.Context, accountID, tenantID int64, refUUID string) (*ChatMediaDownloadResp, error) {
	return s.downloadOrPreview(ctx, accountID, tenantID, refUUID, true)
}

func (s *ChatMediaSvc) Download(ctx context.Context, accountID, tenantID int64, refUUID string) (*ChatMediaDownloadResp, error) {
	return s.downloadOrPreview(ctx, accountID, tenantID, refUUID, false)
}

func (s *ChatMediaSvc) downloadOrPreview(ctx context.Context, accountID, tenantID int64, refUUID string, inline bool) (*ChatMediaDownloadResp, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("auth required")
	}
	if strings.TrimSpace(refUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("ref_uuid required")
	}
	ref, err := s.refs.GetByUUID(ctx, refUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrForbidden.Withf("chat_media.access_denied")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 租户隔离。
	if ref.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("chat_media.access_denied")
	}
	// 成员鉴权:caller 必须是该会话活跃 human 成员(不查 drive ACL)。
	member, err := s.isMember(ctx, ref.ConversationID, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !member {
		return nil, apperr.ErrForbidden.Withf("chat_media.access_denied")
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key: ref.StorageKey, TTL: s.downloadTTL, Inline: inline, FileName: ref.FileName,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &ChatMediaDownloadResp{
		RefUUID:   ref.UUID,
		URL:       out.URL,
		FileName:  ref.FileName,
		MimeType:  ref.MimeType,
		SizeBytes: ref.SizeBytes,
		Inline:    inline,
		ExpiresAt: out.ExpiresAt,
	}, nil
}

// ----- helpers -----

// resolveConversation 按 uuid 取 conversation 的 id / room_id / tenant_id。
func (s *ChatMediaSvc) resolveConversation(ctx context.Context, convUUID string) (id int64, roomID *int64, tenantID int64, err error) {
	qerr := s.pool.QueryRow(ctx,
		`SELECT id, room_id, tenant_id FROM conversations WHERE uuid::text=$1 AND deleted_at IS NULL`,
		convUUID).Scan(&id, &roomID, &tenantID)
	if errors.Is(qerr, pgx.ErrNoRows) {
		return 0, nil, 0, apperr.ErrForbidden.Withf("chat_media.conversation_not_found")
	}
	if qerr != nil {
		return 0, nil, 0, apperr.ErrInternal.Wrap(qerr)
	}
	return id, roomID, tenantID, nil
}

// isMember 与 conversation.AccessibleByAccount 同口径(按 conversation_id):
// 单聊 → c.account_id==caller;room 会话 → room_participants 活跃 human 成员。
func (s *ChatMediaSvc) isMember(ctx context.Context, conversationID, tenantID, accountID int64) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM conversations c
			 WHERE c.id=$1 AND c.tenant_id=$2 AND c.deleted_at IS NULL
			   AND (
			        (c.room_id IS NULL AND c.account_id=$3)
			        OR (c.room_id IS NOT NULL AND EXISTS (
			              SELECT 1 FROM room_participants rp
			               WHERE rp.room_id=c.room_id AND rp.kind='human'
			                 AND rp.account_id=$3 AND rp.left_at IS NULL))
			   )
		)`, conversationID, tenantID, accountID).Scan(&ok)
	return ok, err
}

func mediaKindFromMime(mime string) int {
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(mime)), "image/") {
		return dom.ChatMediaKindImage
	}
	return dom.ChatMediaKindFile
}
