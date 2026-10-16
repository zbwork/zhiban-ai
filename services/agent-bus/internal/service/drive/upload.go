// upload.go — F06 Phase 2.2c + Phase 2.M: drive 上传 staging→final 流程 (UploadSvc).
//
// 5 个 service 入口对应客户端 5 个端点:
//
//	PresignPut          → POST /drive/files:presign-put           (single ≤10MB; multipart auto ≥10MB 或 explicit param)
//	CompleteMultipart   → POST /drive/files:complete-multipart    (Phase 2.M: strategy A 自动 enter confirm back-half)
//	RefreshPartURLs     → POST /drive/files:refresh-part-urls     (Phase 2.M: 重签 part presign, staging_key 不变)
//	Confirm             → POST /drive/files:confirm                (single mode 用)
//
// 核心设计 (F06 §3.2):
//   - presign 永远只签 staging key (`staging/{tenant_id}/{file_uuid}{ext}`); final key 不暴露给客户端
//   - confirm 阶段 Stat verify + 配额二次校验 + server-side Copy 到 final key + 删 staging
//   - 配额扣减用条件 UPDATE (`AddUsedBytesAtomicTx`); 不走 SELECT FOR UPDATE → 再 UPDATE 二段式
//   - 同目录重名当前 slice 直接返 409 drive.duplicate_name; 版本化 (drive_file_versions 写入 + 升版) 在后续 versioning slice 完成
//   - folder_uuid 可空; 空表示上传到真实 space 根. ticket 持久化 space_id,
//     confirm / refresh 阶段按 space editor+ 复检,避免 fabricate space 的 ACL 绕过.
//
// Multipart 策略 A (F06 §3.2 line 761 + Phase 2.M):
//   - CompleteMultipart 一次 HTTP 调用完成 S3 Complete + Stat + Copy + INSERT + quota + ticket=done.
//   - 共享 runConfirmBackHalf 与 Confirm; 唯一差异是先要调 store.CompleteMultipart 合并 parts.
//
// 失败兜底:
//   - Stat 404 / size 不一致 / quota 校验失败 → 412 + best-effort delete staging + ticket='failed'
//   - Copy 失败 → 500 drive.copy_failed + ticket='partial' (staging 留给 reaper 重试用)
//   - 同名 INSERT 23505 → 409 + best-effort delete staging + delete final + ticket='failed'
//   - Phase 4 删 staging 失败 → 仅日志, 不影响响应 (reaper 兜底)
//   - Multipart presign 中途失败 → best-effort store.AbortMultipart + 不入 ticket → 500
package drive

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/drivefilename"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// StorageGetter 是 StorageResolver 的窄接口; 让测试可注入 staticStoreResolver 绕过 secret 解析.
type StorageGetter interface {
	Resolve(ctx context.Context, tenantID int64) (object.Store, error)
}

// F06 §3.2 + Phase 2.M multipart 常量. 单测覆盖边界.
const (
	// MultipartThresholdBytes >= 此 size 强制走 multipart (F06 line 1241 / Phase 2.M 验收).
	MultipartThresholdBytes int64 = 10 * 1024 * 1024 // 10 MiB
	// DefaultPartSizeBytes 客户端不显式指定 part_size_bytes 时的默认值.
	DefaultPartSizeBytes int64 = 10 * 1024 * 1024 // 10 MiB
	// MinPartSizeBytes S3 spec 下界 (last part 例外, 但 service 入口校验只看 declared part_size).
	MinPartSizeBytes int64 = 5 * 1024 * 1024 // 5 MiB
	// MaxParts safety cap. S3 实际允许 10000, drivev3 v1 限 1000 防止 part_urls 数组爆.
	MaxParts = 1000
	// MultipartPartURLTTL F06 §3.2 line 751: 分片 URL 30 分钟.
	MultipartPartURLTTL = 30 * time.Minute
	// MultipartTicketTTL F06 §3.2 line 752: presign TTL + 60min reaper buffer (multipart 用 90min).
	MultipartTicketTTL = 90 * time.Minute
)

// UploadSvc F06 Phase 2.2c 上传服务.
type UploadSvc struct {
	pool         *pgxpool.Pool
	spaces       *drepo.SpaceRepo
	folders      *drepo.FolderRepo
	files        *drepo.FileRepo
	tickets      *drepo.TicketRepo
	quotas       *drepo.QuotaRepo
	versions     *drepo.FileVersionRepo // B1 (file versioning): nil 时同名走 409 (老行为); 非 nil 时同名走"旧 → 历史版本, 当前指针换新内容".
	acl          *ACLService
	storage      StorageGetter
	presignTTL   time.Duration // 单 PUT TTL; 默认 10 分钟 (F06 §3.2)
	ticketTTL    time.Duration // single 模式 ticket TTL; 默认 70 分钟 = presign + 1h reaper buffer
	mpartTTL     time.Duration // multipart 模式 ticket TTL; 默认 90 分钟 = 30min URL + 60min buffer
	mpartPartTTL time.Duration // part URL TTL; 默认 30 分钟
}

// WithVersions B1 (file versioning): 注入 FileVersionRepo, 开启同名上传 → 版本化 路径.
// 不调用此 setter 的旧 caller 行为不变 (同名 → 409 drive.duplicate_name).
func (s *UploadSvc) WithVersions(v *drepo.FileVersionRepo) *UploadSvc {
	s.versions = v
	return s
}

// NewUploadSvc 构造.
func NewUploadSvc(
	pool *pgxpool.Pool,
	sp *drepo.SpaceRepo,
	fd *drepo.FolderRepo,
	fl *drepo.FileRepo,
	tk *drepo.TicketRepo,
	qt *drepo.QuotaRepo,
	acl *ACLService,
	storage StorageGetter,
) *UploadSvc {
	return &UploadSvc{
		pool:         pool,
		spaces:       sp,
		folders:      fd,
		files:        fl,
		tickets:      tk,
		quotas:       qt,
		acl:          acl,
		storage:      storage,
		presignTTL:   10 * time.Minute,
		ticketTTL:    70 * time.Minute,
		mpartTTL:     MultipartTicketTTL,
		mpartPartTTL: MultipartPartURLTTL,
	}
}

// MultipartReq F06 Phase 2.M presign-put multipart 子参数.
// 客户端可显式指定 part_size_bytes (≥ MinPartSizeBytes); 缺省走 DefaultPartSizeBytes.
type MultipartReq struct {
	PartSizeBytes int64 `json:"part_size_bytes,omitempty"`
}

// PresignPutReq F06 Phase 2.2c presign-put 请求体.
// SizeBytes ≥ MultipartThresholdBytes 或 Multipart 非 nil → 强制走 multipart.
type PresignPutReq struct {
	SpaceUUID  string        `json:"space_uuid"`
	FolderUUID string        `json:"folder_uuid,omitempty"`
	FileName   string        `json:"file_name"`
	MimeType   string        `json:"mime_type"`
	SizeBytes  int64         `json:"size_bytes"`
	Multipart  *MultipartReq `json:"multipart,omitempty"`
}

// PresignPutResp F06 Phase 2.2c presign-put 响应.
type PresignPutResp struct {
	Mode   string       `json:"mode"` // "single" | "multipart"
	Ticket TicketDetail `json:"ticket"`
}

// TicketDetail F06 §3.2 ticket 子对象.
//   - single 模式: 仅 PresignURL 有值; UploadID/PartURLs/PartSize 留空.
//   - multipart 模式: UploadID/PartURLs/PartSize 有值; PresignURL 留空.
type TicketDetail struct {
	FileUUID string `json:"file_uuid"`
	// StagingKey/FinalKey/UploadID 仅服务端 ticket/adapter 内部使用, 不暴露给客户端
	// (json:"-"); confirm/complete 按 file_uuid 反查内部 ticket 取回. 详 F06 §3.2 cutover.
	StagingKey string   `json:"-"`
	FinalKey   string   `json:"-"`
	PresignURL string   `json:"presign_url,omitempty"`
	UploadID   string   `json:"-"`
	PartURLs   []string `json:"part_urls,omitempty"`
	PartSize   int64    `json:"part_size,omitempty"`
	ExpiresIn  int      `json:"expires_in"`
}

// ConfirmReq F06 Phase 2.2c confirm 请求体. sha256 可选 (本 slice 不强制校验).
type ConfirmReq struct {
	FileUUID string  `json:"file_uuid"`
	SHA256   *string `json:"sha256,omitempty"`
}

// ProxyUploadReq is the Bus proxy-upload variant of PresignPutReq. It preserves
// the existing staging-key + confirm flow, but Bus writes the staging object on
// behalf of clients that cannot reach the object-store write endpoint.
type ProxyUploadReq struct {
	PresignPutReq
	Body io.Reader
}

// PartIn F06 Phase 2.M complete-multipart 请求子结构.
type PartIn struct {
	PartNumber int    `json:"part_number"`
	ETag       string `json:"etag"`
}

// CompleteMultipartReq F06 Phase 2.M complete-multipart 请求体.
// Parts 必须按 PartNumber asc 排序且 1..N 连续; ETag 不可空.
type CompleteMultipartReq struct {
	FileUUID string   `json:"file_uuid"`
	Parts    []PartIn `json:"parts"`
}

// RefreshPartURLsReq F06 Phase 2.M refresh-part-urls 请求体.
type RefreshPartURLsReq struct {
	FileUUID string `json:"file_uuid"`
}

// RefreshPartURLsResp F06 Phase 2.M refresh-part-urls 响应; 重签当前 ticket.upload_id 下所有 part.
type RefreshPartURLsResp struct {
	PartURLs  []string `json:"part_urls"`
	PartSize  int64    `json:"part_size"`
	ExpiresIn int      `json:"expires_in"`
}

// FileResp F06 Phase 2.2c confirm 响应 / get file 复用 DTO.
type FileResp struct {
	UUID       string `json:"uuid"`
	SpaceUUID  string `json:"space_uuid"`
	FolderUUID string `json:"folder_uuid,omitempty"`
	Name       string `json:"name"`
	MimeType   string `json:"mime_type"`
	SizeBytes  int64  `json:"size_bytes"`
	// StorageKey 仅服务端内部使用, 不暴露给客户端 (json:"-"). 详 F06 §3.2 cutover.
	StorageKey string    `json:"-"`
	CreatedAt  time.Time `json:"created_at"`
}

// PresignPut F06 Phase 2.2c + Phase 2.M §3.2: single 或 multipart 模式自动分流.
//
// folder_uuid 可空:空表示上传到真实 space 根;ticket 记录 space_id 供 confirm-time ACL 复检.
//
// Mode 决策 (F06 line 1241 + Phase 2.M):
//   - SizeBytes >= MultipartThresholdBytes (10MB) → 强制 multipart
//   - req.Multipart != nil → explicit multipart
//   - 其它 → single
//
// 流程:
//  1. 校验 space_uuid 必填
//  2. folder_uuid 非空:解 folder, 校验同 space + 非 system + ACL editor+ on folder
//     folder_uuid 为空:ACL editor+ on space root
//  4. 配额预检 (best-effort; 真正的强制在 confirm 阶段条件 UPDATE)
//  5. Sanitize file_name; 生成 file_uuid; 派生 staging/final key
//     6a. single: PresignPut 单 URL → ticket UploadID=nil, PartSize=nil
//     6b. multipart: InitMultipart → PresignPart × N → ticket UploadID/PartSize 落库
//  7. INSERT drive_upload_tickets status='pending', expires_at = now + ticketTTL
//  8. 返 {mode, ticket:{...}}
func (s *UploadSvc) PresignPut(ctx context.Context, accountID, tenantID int64, req PresignPutReq) (*PresignPutResp, error) {
	if req.SpaceUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("space_uuid required")
	}
	if req.SizeBytes <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("size_bytes must be > 0")
	}

	cleanName := drivefilename.Sanitize(req.FileName)
	if cleanName == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_name invalid")
	}

	// 1. 解 space
	space, err := s.spaces.GetByUUID(ctx, req.SpaceUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("space")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if space.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("space")
	}

	var folderID *int64
	if req.FolderUUID != "" {
		// 2a. 解 folder, 校验同 space + 非 system + folder editor+
		fd, err := s.folders.GetByUUID(ctx, req.FolderUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if fd.SpaceID != space.ID {
			return nil, apperr.ErrForbidden.Withf("drive.cross_space_move_not_allowed")
		}
		if fd.IsSystem {
			return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		fid := fd.ID
		folderID = &fid

		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, *folderID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	} else {
		// 2b. space 根上传:复检真实 space editor+.
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, space.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}

	// 4. 配额预检 (best-effort early return; confirm 阶段还会再原子校一次).
	if err := s.precheckQuota(ctx, tenantID, accountID, req.SizeBytes); err != nil {
		return nil, err
	}

	// 5. 生成 file_uuid + 派生 keys
	fileUUID := uuid.NewString()
	ext := extFromName(cleanName)
	stagingKey := buildStagingKey(tenantID, fileUUID, ext)
	finalKey := buildFinalKey(tenantID, accountID, fileUUID, ext)

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}

	// 6. 分流 single / multipart.
	useMultipart := req.SizeBytes >= MultipartThresholdBytes || req.Multipart != nil
	if !useMultipart {
		return s.presignSingle(ctx, store, accountID, tenantID, &space.ID, folderID, fileUUID, stagingKey, finalKey, cleanName, req)
	}
	return s.presignMultipart(ctx, store, accountID, tenantID, &space.ID, folderID, fileUUID, stagingKey, finalKey, cleanName, req)
}

// UploadProxy handles small-file uploads through Bus. It intentionally delegates
// key/ticket creation to PresignPut and finalization to Confirm so object key,
// ACL, quota, Stat, CopyObject, versioning, and cleanup behavior stay unchanged.
func (s *UploadSvc) UploadProxy(ctx context.Context, accountID, tenantID int64, req ProxyUploadReq) (*FileResp, error) {
	if req.Body == nil {
		return nil, apperr.ErrInvalidParams.Withf("file body required")
	}
	if req.SizeBytes >= MultipartThresholdBytes || req.Multipart != nil {
		return nil, apperr.ErrInvalidParams.Withf("drive.proxy_upload_too_large")
	}
	pres, err := s.PresignPut(ctx, accountID, tenantID, req.PresignPutReq)
	if err != nil {
		return nil, err
	}
	if pres == nil || pres.Mode != "single" || pres.Ticket.StagingKey == "" {
		return nil, apperr.ErrInternal.Withf("drive.proxy_upload_ticket_invalid")
	}
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}
	putter, ok := store.(interface {
		PutObject(context.Context, string, io.Reader, int64, string) error
	})
	if !ok {
		return nil, apperr.ErrInternal.Withf("drive.proxy_upload_not_supported")
	}
	if err := putter.PutObject(ctx, pres.Ticket.StagingKey, req.Body, req.SizeBytes, req.MimeType); err != nil {
		return nil, apperr.ErrUpstreamUnavailable.Withf("drive.proxy_upload_failed").Wrap(err)
	}
	return s.Confirm(ctx, accountID, tenantID, ConfirmReq{FileUUID: pres.Ticket.FileUUID})
}

// presignSingle F06 Phase 2.2c single 模式 (≤10MB 默认走这里).
func (s *UploadSvc) presignSingle(
	ctx context.Context,
	store object.Store,
	accountID, tenantID int64,
	spaceID *int64,
	folderID *int64,
	fileUUID, stagingKey, finalKey, cleanName string,
	req PresignPutReq,
) (*PresignPutResp, error) {
	pres, err := store.PresignPut(ctx, object.PresignPutInput{
		Key:           stagingKey,
		ContentType:   req.MimeType,
		ContentLength: req.SizeBytes,
		TTL:           s.presignTTL,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("presign put: %w", err))
	}
	if err := s.tickets.Create(ctx, dom.CreateUploadTicketInput{
		FileUUID:     fileUUID,
		AccountID:    accountID,
		TenantID:     tenantID,
		SpaceID:      spaceID,
		FolderID:     folderID,
		DeclaredSize: req.SizeBytes,
		DeclaredMime: req.MimeType,
		DeclaredName: cleanName,
		StagingKey:   stagingKey,
		FinalKey:     finalKey,
		UploadID:     nil,
		PartSize:     nil,
		ExpiresAt:    time.Now().Add(s.ticketTTL),
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &PresignPutResp{
		Mode: "single",
		Ticket: TicketDetail{
			FileUUID:   fileUUID,
			StagingKey: stagingKey,
			FinalKey:   finalKey,
			PresignURL: pres.URL,
			ExpiresIn:  int(s.presignTTL.Seconds()),
		},
	}, nil
}

// presignMultipart F06 Phase 2.M multipart 模式.
//
// 流程:
//  1. 计算 partSize (默认 10MB; req.Multipart.PartSizeBytes 覆盖)
//  2. 校验 partSize >= MinPartSizeBytes; numParts <= MaxParts
//  3. store.InitMultipart → uploadID
//  4. for n in [1..numParts]: store.PresignPart → URL; 任一失败 → AbortMultipart + 500
//  5. 入库 ticket (UploadID, PartSize 非 nil), TTL = mpartTTL
//  6. 返 {mode:"multipart", ticket:{ UploadID, PartURLs, PartSize, ... }}
func (s *UploadSvc) presignMultipart(
	ctx context.Context,
	store object.Store,
	accountID, tenantID int64,
	spaceID *int64,
	folderID *int64,
	fileUUID, stagingKey, finalKey, cleanName string,
	req PresignPutReq,
) (*PresignPutResp, error) {
	partSize := DefaultPartSizeBytes
	if req.Multipart != nil && req.Multipart.PartSizeBytes > 0 {
		partSize = req.Multipart.PartSizeBytes
	}
	if partSize < MinPartSizeBytes {
		return nil, apperr.ErrInvalidParams.Withf("drive.part_size_too_small")
	}
	// Cap partSize 到 SizeBytes (单 part 走 multipart 也合法; S3 接受).
	if partSize > req.SizeBytes {
		partSize = req.SizeBytes
	}

	// ceil(size/partSize); numParts ≥ 1
	numParts := int((req.SizeBytes + partSize - 1) / partSize)
	if numParts < 1 {
		numParts = 1
	}
	if numParts > MaxParts {
		return nil, apperr.ErrInvalidParams.Withf("drive.too_many_parts")
	}

	uploadID, err := store.InitMultipart(ctx, stagingKey, req.MimeType)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.multipart_init_failed").Wrap(err)
	}

	partURLs := make([]string, 0, numParts)
	for n := 1; n <= numParts; n++ {
		u, err := store.PresignPart(ctx, stagingKey, uploadID, n, s.mpartPartTTL)
		if err != nil {
			// best-effort abort
			_ = store.AbortMultipart(ctx, stagingKey, uploadID)
			return nil, apperr.ErrInternal.Withf("drive.multipart_presign_failed").Wrap(err)
		}
		partURLs = append(partURLs, u)
	}

	uidVal := uploadID
	psVal := partSize
	if err := s.tickets.Create(ctx, dom.CreateUploadTicketInput{
		FileUUID:     fileUUID,
		AccountID:    accountID,
		TenantID:     tenantID,
		SpaceID:      spaceID,
		FolderID:     folderID,
		DeclaredSize: req.SizeBytes,
		DeclaredMime: req.MimeType,
		DeclaredName: cleanName,
		StagingKey:   stagingKey,
		FinalKey:     finalKey,
		UploadID:     &uidVal,
		PartSize:     &psVal,
		ExpiresAt:    time.Now().Add(s.mpartTTL),
	}); err != nil {
		// ticket 入库失败 → best-effort abort S3 状态 (avoid orphan upload).
		_ = store.AbortMultipart(ctx, stagingKey, uploadID)
		return nil, apperr.ErrInternal.Wrap(err)
	}

	return &PresignPutResp{
		Mode: "multipart",
		Ticket: TicketDetail{
			FileUUID:   fileUUID,
			StagingKey: stagingKey,
			FinalKey:   finalKey,
			UploadID:   uploadID,
			PartURLs:   partURLs,
			PartSize:   partSize,
			ExpiresIn:  int(s.mpartPartTTL.Seconds()),
		},
	}, nil
}

// CompleteMultipart F06 Phase 2.M strategy A: 一次 HTTP 调用做 S3 Complete + Stat + Copy + INSERT + quota + ticket=done.
//
// 流程:
//  1. 校验 req.Parts: 非空 / PartNumber 1..N 连续 / ETag 非空
//  2. ACL + ticket + folder/space 入口校验 (复用 lookupTicketForBackHalf)
//  3. 校验 ticket.UploadID != nil (single 模式不能走这里 → 400 drive.not_multipart)
//  4. store.CompleteMultipart(stagingKey, uploadID, parts) — 让 S3 合并到 stagingKey
//     失败 → best-effort AbortMultipart + ticket='failed' + 500
//  5. runConfirmBackHalf — 复用 Confirm 的 Stat/Copy/TX/cleanup 段
//
// 与 single 模式 Confirm 的唯一差异: 多一步 store.CompleteMultipart; 之后路径完全共享.
func (s *UploadSvc) CompleteMultipart(ctx context.Context, accountID, tenantID int64, req CompleteMultipartReq) (*FileResp, error) {
	if req.FileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}
	if len(req.Parts) == 0 {
		return nil, apperr.ErrInvalidParams.Withf("drive.parts_empty")
	}
	// 校验 parts: PartNumber 必须 1..N 严格递增, ETag 不能空.
	for i, p := range req.Parts {
		if p.PartNumber != i+1 {
			return nil, apperr.ErrInvalidParams.Withf("drive.parts_invalid_sequence")
		}
		if strings.TrimSpace(p.ETag) == "" {
			return nil, apperr.ErrInvalidParams.Withf("drive.parts_etag_empty")
		}
	}

	ticket, fd, space, store, err := s.lookupTicketForBackHalf(ctx, accountID, tenantID, req.FileUUID)
	if err != nil {
		return nil, err
	}
	if ticket.UploadID == nil || *ticket.UploadID == "" {
		return nil, apperr.ErrInvalidParams.Withf("drive.not_multipart")
	}

	// S3 Complete: 合并 parts 到 stagingKey.
	mpParts := make([]object.MultipartPart, 0, len(req.Parts))
	for _, p := range req.Parts {
		mpParts = append(mpParts, object.MultipartPart{PartNumber: p.PartNumber, ETag: p.ETag})
	}
	if err := store.CompleteMultipart(ctx, ticket.StagingKey, *ticket.UploadID, mpParts); err != nil {
		_ = store.AbortMultipart(ctx, ticket.StagingKey, *ticket.UploadID)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Withf("drive.multipart_complete_failed").Wrap(err)
	}

	return s.runConfirmBackHalf(ctx, accountID, tenantID, ticket, fd, space, store, nil /* sha256 */)
}

// Confirm F06 Phase 2.2c §3.2: single 模式上传完成后 staging→final + 落库 + quota 扣减.
//
// 流程 (4 阶段, 见 §3.2):
//
//	Phase 1 (no TX): Stat staging + 早期配额预检
//	Phase 2 (no TX): CopyObject staging→final (失败 → ticket='partial' + 500)
//	Phase 3 (one TX): 重名检测 + 原子 quota UPDATE + INSERT drive_files + UPDATE drive_spaces.used_bytes + ticket='done'
//	Phase 4 (no TX): best-effort delete staging
//
// 版本化 (drive_file_versions 写入 + 同名升版) 在后续 versioning slice 完成;
// 当前 slice 拒同名 409 drive.duplicate_name.
func (s *UploadSvc) Confirm(ctx context.Context, accountID, tenantID int64, req ConfirmReq) (*FileResp, error) {
	if req.FileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}

	ticket, fd, space, store, err := s.lookupTicketForBackHalf(ctx, accountID, tenantID, req.FileUUID)
	if err != nil {
		return nil, err
	}
	return s.runConfirmBackHalf(ctx, accountID, tenantID, ticket, fd, space, store, req.SHA256)
}

// lookupTicketForBackHalf 把 Confirm / CompleteMultipart 共享的入口校验集中:
// ticket fetch + 归属 + status pending + 未过期 + folder + space + ACL editor+ + storage resolve.
// 失败时已设好 apperr code (caller 直接 return).
func (s *UploadSvc) lookupTicketForBackHalf(
	ctx context.Context, accountID, tenantID int64, fileUUID string,
) (*dom.UploadTicket, *dom.Folder, *dom.Space, object.Store, error) {
	ticket, err := s.tickets.GetByFileUUID(ctx, fileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
		}
		return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if ticket.AccountID != accountID || ticket.TenantID != tenantID {
		return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if ticket.Status != dom.TicketStatusPending {
		return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if time.Now().After(ticket.ExpiresAt) {
		return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	folderID := ticket.FolderID
	var fd *dom.Folder
	var space *dom.Space
	if folderID != nil {
		fd, err = s.folders.GetByID(ctx, *folderID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, nil, nil, nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
		}
		// Phase 2.5: 系统目录守卫只对 user-facing upload 生效 (ticket.source = user_upload);
		// 内部 caller (ZAP agent_output / 未来 KB upload) 走系统目录是合法路径,
		// 已在 ZAPSvc/KB svc 入口做了等价授权.
		if fd.IsSystem && (ticket.Source == "" || ticket.Source == dom.FileSourceUserUpload) {
			return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		space, err = s.spaces.GetByID(ctx, fd.SpaceID)
		if err != nil {
			return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
		}
		if space == nil || space.TenantID != tenantID {
			return nil, nil, nil, nil, apperr.ErrNotFound.Withf("space")
		}
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, *folderID)
		if err != nil {
			return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	} else {
		if ticket.SpaceID == nil {
			return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid: missing space")
		}
		space, err = s.spaces.GetByID(ctx, *ticket.SpaceID)
		if err != nil {
			return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
		}
		if space == nil || space.TenantID != tenantID {
			return nil, nil, nil, nil, apperr.ErrNotFound.Withf("space")
		}
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, space.ID)
		if err != nil {
			return nil, nil, nil, nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, nil, nil, nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, nil, nil, nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}
	return ticket, fd, space, store, nil
}

// runConfirmBackHalf F06 Phase 2.2c + Phase 2.M shared "confirm 后半段":
// Stat staging → quota lookup → Copy staging→final → TX (LockForConfirmTx + dup check + quota +
// INSERT drive_files + space.used_bytes + ticket=done) → best-effort delete staging.
//
// 调用前 caller 必须已:
//   - 通过 lookupTicketForBackHalf 拿到 (ticket, fd, space, store)
//   - 对 multipart 路径, 已 store.CompleteMultipart 让 staging key 上是合并后的完整对象
//
// 与原版 Confirm 内联逻辑 1:1, 重命名 fd/space 由 caller 传入避免重复查.
func (s *UploadSvc) runConfirmBackHalf(
	ctx context.Context, accountID, tenantID int64,
	ticket *dom.UploadTicket, fd *dom.Folder, space *dom.Space,
	store object.Store, sha256 *string,
) (*FileResp, error) {
	folderID := ticket.FolderID

	stat, err := store.Stat(ctx, ticket.StagingKey)
	if err != nil {
		if errors.Is(err, object.ErrNotFound) {
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.New(apperr.PreconditionFailed, "drive.staging_missing")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if stat.Size != ticket.DeclaredSize {
		// 申报 size 与实际 PUT 不一致 → 拒, 删 staging (best-effort).
		_ = store.Delete(ctx, ticket.StagingKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.New(apperr.PreconditionFailed, "drive.size_mismatch")
	}

	// 3. 资源 lookup: tenant quota / account quota (best-effort, 不存在 = 无配额)
	tenantQuotaID, accountQuotaID, err := s.lookupQuotaIDs(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 4. Phase 2: CopyObject staging → final
	if err := store.Copy(ctx, ticket.StagingKey, ticket.FinalKey); err != nil {
		// Copy 失败 → ticket 标 partial (staging 留给 reaper / 后续重试), 500 + drive.copy_failed.
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusPartial))
		return nil, apperr.ErrInternal.Withf("drive.copy_failed")
	}

	// 5. Phase 3: 单事务 - 行锁 ticket + 重名检测 + 原子 quota UPDATE + INSERT + space used_bytes + ticket=done.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		// 早期失败 (BeginTx 之前 Copy 已成功 → orphan 风险): 删 final 兜底 + ticket fail.
		// orphan 风险点: Delete 也可能失败 (同 ctx 已坏 / 上游网络抖动), 务必结构化日志便于排查.
		if delErr := store.Delete(ctx, ticket.FinalKey); delErr != nil {
			slog.ErrorContext(ctx, "drive.upload.orphan_object",
				"kind", "final",
				"key", ticket.FinalKey,
				"err", delErr.Error(),
				"tenant_id", tenantID,
				"file_uuid", ticket.FileUUID,
				"reason", "begin_tx_failed",
			)
		}
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("begin tx: %w", err))
	}
	committed := false
	// rolled 标记 TX 是否已显式回滚, 避免 defer 重复 Rollback (PG 会日志 warn).
	// 失败路径必须先显式 Rollback 释放行锁 (LockForConfirmTx 拿了 FOR UPDATE),
	// 否则后续的非-TX UpdateStatus(同一 file_uuid) 会等锁 → 死锁.
	rolled := false
	defer func() {
		if !committed && !rolled {
			_ = tx.Rollback(ctx)
		}
	}()
	rollback := func() {
		if !rolled && !committed {
			_ = tx.Rollback(ctx)
			rolled = true
		}
	}

	// 5.0 锁 ticket 行 + 重 assert pending/expires/归属 (I1 并发防御).
	// 两个并发 Confirm 都过了入口 read 后, 这里只有 1 个能拿到 pending 行;
	// 另一个被 FOR UPDATE 阻塞, 等赢家 commit 后再判 status='pending' 已变 'done' → 拿不到行 → ErrNotFound.
	// 避免双扣 quota / 双行 INSERT (drive_files 无 file_uuid 唯一约束, 不能依赖 PG 兜).
	if _, lockErr := s.tickets.LockForConfirmTx(ctx, tx, ticket.FileUUID, accountID, tenantID); lockErr != nil {
		// 先回滚再做后续 (后续没有写 ticket, 这里只是为了立刻释放行锁).
		rollback()
		if errors.Is(lockErr, drepo.ErrNotFound) {
			// 失败者: 不动 final (赢家会用相同 key, 删了就把赢家的内容也删了);
			// 也不动 ticket 状态 (赢家会标 done).
			return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
		}
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(lockErr)
	}

	// 5a. 重名检测 (folder/root unique index 保护实际并发, 这里 + INSERT 23505 双重防御)
	var existing *dom.File
	if folderID == nil {
		existing, err = s.files.GetBySpaceRootAndName(ctx, space.ID, ticket.DeclaredName)
	} else {
		existing, err = s.files.GetByFolderAndName(ctx, folderID, ticket.DeclaredName)
	}
	if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		rollback()
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if existing != nil {
		// B1 (file versioning): 同名命中且 versions 已注入 → "新内容上位, 旧内容入 drive_file_versions";
		// existing 必须 scope=drive + copy_status=ready (避免触碰 chat scope / 跨 space 进行中的 copy).
		if s.versions != nil && existing.Scope == dom.FileScopeDrive && existing.CopyStatus == dom.CopyStatusReady {
			mime := ticket.DeclaredMime
			if stat.ContentType != "" {
				mime = stat.ContentType
			}
			source := ticket.Source
			if source == "" {
				source = dom.FileSourceUserUpload
			}
			resp, vErr := s.runConfirmVersioning(ctx, tx, accountID, tenantID, ticket, existing, space, fd,
				tenantQuotaID, accountQuotaID, mime, sha256, source)
			if vErr != nil {
				// 失败路径已在 runConfirmVersioning 内 rollback + Delete final + ticket fail; 这里只透传错误.
				return nil, vErr
			}
			// 5e: ticket 标 done (与正常路径一致, 但写在 runConfirmVersioning commit 之前).
			// runConfirmVersioning 内已 commit, 这里不再处理 TX.
			committed = true
			// best-effort delete staging (与正常路径 6 一致).
			if delErr := store.Delete(ctx, ticket.StagingKey); delErr != nil {
				slog.ErrorContext(ctx, "drive.upload.orphan_object",
					"kind", "staging",
					"key", ticket.StagingKey,
					"err", delErr.Error(),
					"tenant_id", tenantID,
					"file_uuid", ticket.FileUUID,
					"reason", "versioning_phase4_cleanup_failed",
				)
			}
			return resp, nil
		}
		rollback()
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = store.Delete(ctx, ticket.StagingKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
	}

	// 5b. 原子 quota UPDATE (tenant 优先 → account, 任一失败 → 412 + 删 final + ticket fail).
	if tenantQuotaID != 0 {
		ok, err := s.quotas.AddUsedBytesAtomicTx(ctx, tx, tenantQuotaID, ticket.DeclaredSize)
		if err != nil {
			rollback()
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !ok {
			rollback()
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
		}
	}
	if accountQuotaID != 0 {
		ok, err := s.quotas.AddUsedBytesAtomicTx(ctx, tx, accountQuotaID, ticket.DeclaredSize)
		if err != nil {
			rollback()
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !ok {
			rollback()
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
		}
	}

	// 5c. INSERT drive_files
	mime := ticket.DeclaredMime
	if stat.ContentType != "" {
		mime = stat.ContentType
	}
	// Phase 2.5: source 从 ticket 读 (ZAP agent_output / 未来 KB upload 等).
	// 老 ticket (column default 'user_upload') 行为不变.
	source := ticket.Source
	if source == "" {
		source = dom.FileSourceUserUpload
	}
	file, err := s.files.CreateTx(ctx, tx, dom.CreateFileInput{
		SpaceID:       space.ID,
		DriveFolderID: folderID,
		Name:          ticket.DeclaredName,
		MimeType:      mime,
		SizeBytes:     ticket.DeclaredSize,
		SHA256:        sha256,
		StorageKey:    ticket.FinalKey,
		Scope:         dom.FileScopeDrive,
		Source:        source,
		CreatedBy:     accountID,
	})
	if err != nil {
		rollback()
		if errors.Is(err, drepo.ErrDuplicateName) {
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = store.Delete(ctx, ticket.StagingKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 5d. space used_bytes += size
	if err := s.spaces.AddUsedBytesTx(ctx, tx, space.ID, ticket.DeclaredSize); err != nil {
		rollback()
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 5e. ticket → done
	if err := s.tickets.UpdateStatusTx(ctx, tx, ticket.FileUUID, string(dom.TicketStatusDone)); err != nil {
		rollback()
		_ = store.Delete(ctx, ticket.FinalKey)
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		// I4: TX rollback → ticket 仍 pending; 不标 failed 会被后续 retry 当成可用 ticket
		// 再走一遍 Stat/Copy/Phase3 → 状态污染. best-effort 标 failed 锁住, 客户端走新 presign.
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		if delErr := store.Delete(ctx, ticket.FinalKey); delErr != nil {
			slog.ErrorContext(ctx, "drive.upload.orphan_object",
				"kind", "final",
				"key", ticket.FinalKey,
				"err", delErr.Error(),
				"tenant_id", tenantID,
				"file_uuid", ticket.FileUUID,
				"reason", "commit_failed",
			)
		}
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("commit: %w", err))
	}
	committed = true

	// 6. Phase 4: best-effort delete staging (失败仅日志, 不阻塞响应; reaper 兜底).
	if delErr := store.Delete(ctx, ticket.StagingKey); delErr != nil {
		slog.ErrorContext(ctx, "drive.upload.orphan_object",
			"kind", "staging",
			"key", ticket.StagingKey,
			"err", delErr.Error(),
			"tenant_id", tenantID,
			"file_uuid", ticket.FileUUID,
			"reason", "phase4_cleanup_failed",
		)
	}

	// M1: 复用入口已 fetch 的 fd, 不再二次查 folder.
	resp := &FileResp{
		UUID:       file.UUID,
		SpaceUUID:  space.UUID,
		FolderUUID: folderUUIDFromPtr(fd),
		Name:       file.Name,
		MimeType:   file.MimeType,
		SizeBytes:  file.SizeBytes,
		StorageKey: file.StorageKey,
		CreatedAt:  file.CreatedAt,
	}
	return resp, nil
}

// RefreshPartURLs F06 Phase 2.M / §3.2 line 938: 续签当前 multipart 上传的所有 part PUT URL.
//
// 流程:
//  1. ticket lookup + 归属 / status='pending' / 未过期 / upload_id 非空 → 不满足任一返 403 或 400
//  2. ACL editor+ 重新校 (与 Confirm 一致)
//  3. 复算 numParts = ceil(declared_size / part_size); part_size 必须从 ticket 拿 (Phase 2.M 落库)
//  4. store.PresignPart × N → 返新一批 URL
//
// staging_key 不变, S3 upload_id 也不变; 多次 refresh 不会泄漏 final key.
func (s *UploadSvc) RefreshPartURLs(ctx context.Context, accountID, tenantID int64, req RefreshPartURLsReq) (*RefreshPartURLsResp, error) {
	if req.FileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}
	ticket, err := s.tickets.GetByFileUUID(ctx, req.FileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if ticket.AccountID != accountID || ticket.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if ticket.Status != dom.TicketStatusPending {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if time.Now().After(ticket.ExpiresAt) {
		return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid")
	}
	if ticket.UploadID == nil || *ticket.UploadID == "" || ticket.PartSize == nil || *ticket.PartSize <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("drive.not_multipart")
	}

	if ticket.FolderID != nil {
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, *ticket.FolderID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	} else {
		if ticket.SpaceID == nil {
			return nil, apperr.ErrForbidden.Withf("drive.upload_ticket_invalid: missing space")
		}
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, *ticket.SpaceID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}

	partSize := *ticket.PartSize
	numParts := int((ticket.DeclaredSize + partSize - 1) / partSize)
	if numParts < 1 {
		numParts = 1
	}
	if numParts > MaxParts {
		return nil, apperr.ErrInvalidParams.Withf("drive.too_many_parts")
	}

	urls := make([]string, 0, numParts)
	for n := 1; n <= numParts; n++ {
		u, err := store.PresignPart(ctx, ticket.StagingKey, *ticket.UploadID, n, s.mpartPartTTL)
		if err != nil {
			return nil, apperr.ErrInternal.Withf("drive.multipart_presign_failed").Wrap(err)
		}
		urls = append(urls, u)
	}

	return &RefreshPartURLsResp{
		PartURLs:  urls,
		PartSize:  partSize,
		ExpiresIn: int(s.mpartPartTTL.Seconds()),
	}, nil
}

// =====================================================
// local helpers
// =====================================================

// precheckQuota presign-put 阶段的 best-effort 配额校验 (avoid 浪费 presign 操作).
// confirm 阶段的强制是条件 UPDATE (AddUsedBytesAtomicTx), 才是真正防御并发抢配额.
// 不存在 quota 行 → 视为无限, 不挡.
func (s *UploadSvc) precheckQuota(ctx context.Context, tenantID, accountID, addBytes int64) error {
	if addBytes <= 0 {
		return nil
	}
	// tenant
	if q, err := s.quotas.GetForTenant(ctx, tenantID); err == nil && q != nil {
		if q.QuotaBytes != -1 && q.UsedBytes+addBytes > q.QuotaBytes {
			return apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
		}
	} else if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return apperr.ErrInternal.Wrap(err)
	}
	// account
	if q, err := s.quotas.GetForAccount(ctx, tenantID, accountID); err == nil && q != nil {
		if q.QuotaBytes != -1 && q.UsedBytes+addBytes > q.QuotaBytes {
			return apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
		}
	} else if err != nil && !errors.Is(err, drepo.ErrNotFound) {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// lookupQuotaIDs confirm 阶段拿 (tenant, account) 两条 quota 行的 id;
// 不存在则返 0 (caller 跳过对应 UPDATE).
func (s *UploadSvc) lookupQuotaIDs(ctx context.Context, tenantID, accountID int64) (tenantQuotaID, accountQuotaID int64, err error) {
	if q, e := s.quotas.GetForTenant(ctx, tenantID); e == nil && q != nil {
		tenantQuotaID = q.ID
	} else if e != nil && !errors.Is(e, drepo.ErrNotFound) {
		return 0, 0, e
	}
	if q, e := s.quotas.GetForAccount(ctx, tenantID, accountID); e == nil && q != nil {
		accountQuotaID = q.ID
	} else if e != nil && !errors.Is(e, drepo.ErrNotFound) {
		return 0, 0, e
	}
	return tenantQuotaID, accountQuotaID, nil
}

// buildStagingKey F06 §3.2: staging/{tenant_id}/{file_uuid}{ext}
// 独立 prefix, 便于 reaper 扫过期 staging.
func buildStagingKey(tenantID int64, fileUUID, ext string) string {
	return fmt.Sprintf("staging/%d/%s%s", tenantID, fileUUID, ext)
}

// buildFinalKey F06 §4.1: tenants/{tenant_id}/accounts/{account_id}/{ym}/{file_uuid}{ext}
// ym = UTC YYYYMM; 与 legacy buildDriveStorageKey 模板一致.
func buildFinalKey(tenantID, accountID int64, fileUUID, ext string) string {
	ym := time.Now().UTC().Format("200601")
	return fmt.Sprintf("tenants/%d/accounts/%d/%s/%s%s", tenantID, accountID, ym, fileUUID, ext)
}

// extFromName 取扩展名 (含点); 无点 / 点是末字符 → 返空.
func extFromName(name string) string {
	if i := strings.LastIndex(name, "."); i >= 0 && i < len(name)-1 {
		return name[i:]
	}
	return ""
}

func folderUUIDFromPtr(fd *dom.Folder) string {
	if fd == nil {
		return ""
	}
	return fd.UUID
}

// runConfirmVersioning B1: 同名上传命中已 ready 行 → "旧内容入 drive_file_versions, 当前 drive_files 行换指针".
//
// 顺序 (复用入口已 BeginTx 的 tx, caller 已做 LockForConfirmTx + GetByFolderAndName + Copy staging→final):
//  1. LockByIDTx(existing.ID) — 防止与并发 rename/move/delete/restore 撞行
//  2. 重检 existing 仍 ready (锁后状态可能变)
//  3. quota delta = new_size - old_size; 正数 atomic +delta (tenant 优先 + account), 负数 signed -|delta|; 0 跳过
//  4. space.AddUsedBytesSignedTx(+delta) — 允许负 (老路径只 +delta)
//  5. InsertSnapshotTx(existing 旧 storage_key + size + mime/sha256) → 历史版本行 (version_no = MAX+1)
//  6. UpdateContentTx(existing.ID, ticket.FinalKey + new size/mime/sha256, updatedBy=accountID) → 当前行换指针
//  7. ticket → done; TX commit
//
// 失败任一步: rollback + Delete final + ticket → failed (与正常路径一致).
// 不删 staging (commit 后由 caller 走 Phase 4 best-effort delete).
// 不删 existing.StorageKey (它现在是历史版本; 由 B5 reaper 在版本超限/超时清理).
func (s *UploadSvc) runConfirmVersioning(
	ctx context.Context, tx pgx.Tx, accountID, tenantID int64,
	ticket *dom.UploadTicket, existing *dom.File, space *dom.Space, fd *dom.Folder,
	tenantQuotaID, accountQuotaID int64,
	mime string, sha256 *string, source dom.FileSource,
) (*FileResp, error) {
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		_ = tx.Rollback(ctx)
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}

	// 1. 锁 existing 行 (FOR UPDATE)
	locked, err := s.files.LockByIDTx(ctx, tx, existing.ID)
	if err != nil {
		_ = tx.Rollback(ctx)
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 锁后重检: 仍 ready + 未软删 (并发 delete/restore 可能改了状态)
	if locked.IsDeleted || locked.CopyStatus != dom.CopyStatusReady {
		_ = tx.Rollback(ctx)
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrConflict.Withf("drive.file_state_changed")
	}

	// 2. quota delta. tenant 优先 → account.
	delta := ticket.DeclaredSize - locked.SizeBytes
	if delta > 0 {
		if tenantQuotaID != 0 {
			ok, qErr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, tenantQuotaID, delta)
			if qErr != nil {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
			if !ok {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
			}
		}
		if accountQuotaID != 0 {
			ok, qErr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, accountQuotaID, delta)
			if qErr != nil {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
			if !ok {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
			}
		}
	} else if delta < 0 {
		if tenantQuotaID != 0 {
			if qErr := s.quotas.AddUsedBytesSignedTx(ctx, tx, tenantQuotaID, delta); qErr != nil {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
		}
		if accountQuotaID != 0 {
			if qErr := s.quotas.AddUsedBytesSignedTx(ctx, tx, accountQuotaID, delta); qErr != nil {
				_ = tx.Rollback(ctx)
				_ = store.Delete(ctx, ticket.FinalKey)
				_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
		}
	}

	// 3. space used_bytes += delta (允许负)
	if delta != 0 {
		if err := s.spaces.AddUsedBytesSignedTx(ctx, tx, space.ID, delta); err != nil {
			_ = tx.Rollback(ctx)
			_ = store.Delete(ctx, ticket.FinalKey)
			_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}

	// 4. snapshot existing → drive_file_versions (version_no auto = MAX+1 per file_id)
	_, err = s.versions.InsertSnapshotTx(ctx, tx, drepo.InsertSnapshotInput{
		FileID:       locked.ID,
		StorageKey:   locked.StorageKey,
		SizeBytes:    locked.SizeBytes,
		SHA256:       locked.SHA256,
		Name:         locked.Name,
		UploadSource: locked.Source,
		CreatedBy:    accountID,
	})
	if err != nil {
		_ = tx.Rollback(ctx)
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 5. rewire 当前行内容 (storage_key + size + mime + sha256)
	updated, err := s.files.UpdateContentTx(ctx, tx, locked.ID, drepo.UpdateContentInput{
		StorageKey: ticket.FinalKey,
		SizeBytes:  ticket.DeclaredSize,
		MimeType:   mime,
		SHA256:     sha256,
		UpdatedBy:  accountID,
	})
	if err != nil {
		_ = tx.Rollback(ctx)
		_ = store.Delete(ctx, ticket.FinalKey)
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// source 字段不强制更新 — 历史 source 留在版本表里, 当前行保留首次创建的 source 语义 (如 agent_output).
	_ = source

	// 6. ticket → done
	if err := s.tickets.UpdateStatusTx(ctx, tx, ticket.FileUUID, string(dom.TicketStatusDone)); err != nil {
		_ = tx.Rollback(ctx)
		_ = store.Delete(ctx, ticket.FinalKey)
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		_ = s.tickets.UpdateStatus(ctx, ticket.FileUUID, string(dom.TicketStatusFailed))
		if delErr := store.Delete(ctx, ticket.FinalKey); delErr != nil {
			slog.ErrorContext(ctx, "drive.upload.orphan_object",
				"kind", "final",
				"key", ticket.FinalKey,
				"err", delErr.Error(),
				"tenant_id", tenantID,
				"file_uuid", ticket.FileUUID,
				"reason", "versioning_commit_failed",
			)
		}
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("commit: %w", err))
	}

	return &FileResp{
		UUID:       updated.UUID,
		SpaceUUID:  space.UUID,
		FolderUUID: folderUUIDFromPtr(fd),
		Name:       updated.Name,
		MimeType:   updated.MimeType,
		SizeBytes:  updated.SizeBytes,
		StorageKey: updated.StorageKey,
		CreatedAt:  updated.CreatedAt,
	}, nil
}
