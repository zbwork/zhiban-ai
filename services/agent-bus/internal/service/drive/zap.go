// zap.go — F06 Phase 2.5: ZAP backchannel (/zap/v1/internal/files/sign|confirm|sign-download)
// 切到 drivev3 实现.
//
// ZAP 调用方约定:
//   - Agent SDK 用 Authorization: Bearer <session_token> 鉴权;
//     transport 解 session → (tenantID, agentUUID), 传给 svc.
//   - Agent 不能传 folder_id; bus 内部按 agent 归属解析 de_outputs.
//   - 输出文件 source=agent_output, owner_account = agent.creator,
//     存放在 creator 的 personal space → de_root → de_agent → de_outputs.
//
// 与 legacy svcdrive.Agent* 行为对齐 (响应 JSON 形状 / 错误码 / ticket 校验严格度);
// 唯一升级: 走 staging+confirm (Phase 2.2c 模式), 不再直传 final key.
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/drivefilename"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// ZAPAgentMeta drivev3 端对 agent 的窄反查输出 (与 legacy svcdrive.AgentMeta 同 shape).
type ZAPAgentMeta struct {
	ID        int64
	UUID      string
	TenantID  int64
	CreatorID int64
	Name      string
}

// ZAPAgentLookup 注入接口: 由 cmd/bus wiring 用 agent repo 适配.
type ZAPAgentLookup interface {
	GetByUUID(ctx context.Context, tenantID int64, agentUUID string) (*ZAPAgentMeta, error)
}

// ZAPSvc Phase 2.5: ZAP backchannel service.
type ZAPSvc struct {
	pool         *pgxpool.Pool
	spaces       *drepo.SpaceRepo
	folders      *drepo.FolderRepo
	files        *drepo.FileRepo
	tickets      *drepo.TicketRepo
	quotas       *drepo.QuotaRepo
	storage      StorageGetter
	agents       ZAPAgentLookup
	localOutputs local.OutputAgentResolver
	localUpload  *localUploadProxy
	sysFolders   *SystemFoldersSvc
	uploadSvc    *UploadSvc // confirm 复用其 runConfirmBackHalf
	snapshot     *SnapshotSvc

	presignTTL time.Duration
	ticketTTL  time.Duration
}

// NewZAPSvc 构造.
func NewZAPSvc(
	pool *pgxpool.Pool,
	spaces *drepo.SpaceRepo, folders *drepo.FolderRepo, files *drepo.FileRepo,
	tickets *drepo.TicketRepo, quotas *drepo.QuotaRepo,
	storage StorageGetter, agents ZAPAgentLookup,
	sysFolders *SystemFoldersSvc, uploadSvc *UploadSvc, snapshot *SnapshotSvc,
) *ZAPSvc {
	return &ZAPSvc{
		pool: pool, spaces: spaces, folders: folders, files: files,
		tickets: tickets, quotas: quotas, storage: storage, agents: agents,
		sysFolders: sysFolders, uploadSvc: uploadSvc, snapshot: snapshot,
		presignTTL: 10 * time.Minute,
		ticketTTL:  70 * time.Minute, // 同 SingleTicketTTL
	}
}

// ZAPPresignReq Phase 2.5: ZAP sign 入参 (与 legacy AgentPresignReq 同 shape).
type ZAPPresignReq struct {
	FileName    string `json:"file_name"`
	FileSize    int64  `json:"file_size"`
	MimeType    string `json:"mime_type"`
	SourceRef   string `json:"source_ref,omitempty"`
	MessageUUID string `json:"message_id,omitempty"`
}

// ZAPPresignResp Phase 2.5: ZAP sign 响应 (与 legacy PresignResp 同 shape).
type ZAPPresignResp struct {
	Uploaded      bool              `json:"uploaded,omitempty"`
	UploadURL     string            `json:"upload_url"`
	UploadHeaders map[string]string `json:"upload_headers,omitempty"`
	StorageKey    string            `json:"storage_key"`  // staging key (caller 实际 PUT 目标)
	StorageKind   string            `json:"storage_kind"` // store.Kind()
	ExpiresIn     int               `json:"expires_in"`
	ExpiresAt     time.Time         `json:"expires_at"`
	PresignTicket string            `json:"presign_ticket"` // = file_uuid (drivev3 用 file_uuid 当 ticket id)
}

// ZAPConfirmReq Phase 2.5: ZAP confirm 入参 (与 legacy AgentConfirmReq 同 shape).
type ZAPConfirmReq struct {
	PresignTicket string                 `json:"presign_ticket"`
	FileName      string                 `json:"file_name"`
	FileSize      int64                  `json:"file_size"`
	MimeType      string                 `json:"mime_type"`
	Checksum      string                 `json:"checksum,omitempty"`
	StorageKey    string                 `json:"storage_key,omitempty"` // optional echo
	SourceRef     string                 `json:"source_ref,omitempty"`
	MessageUUID   string                 `json:"message_id,omitempty"`
	Metadata      map[string]interface{} `json:"metadata,omitempty"`
}

// ZAPFileDTO Phase 2.5: confirm 响应 (与 legacy FileDTO 关键字段对齐).
type ZAPFileDTO struct {
	UUID        string    `json:"id"`
	SpaceUUID   string    `json:"space_id"`
	FolderUUID  string    `json:"folder_id"`
	Name        string    `json:"name"`
	MimeType    string    `json:"mime_type"`
	FileSize    int64     `json:"file_size"`
	StorageKey  string    `json:"storage_key"`
	StorageKind string    `json:"storage_kind"`
	SourceKind  string    `json:"source_kind"` // = "agent_output"
	CreatedAt   time.Time `json:"created_at"`
}

// ZAPSignDownloadReq Phase 2.5: sign-download 入参.
type ZAPSignDownloadReq struct {
	DriveFileUUID string `json:"file_id"`
}

// ZAPPresignedURL Phase 2.5: sign-download 响应.
type ZAPPresignedURL struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ZAP error codes (与 legacy 对齐, 客户端 SDK 解析).
const (
	ZAPErrSessionInvalid     = "zap.session_invalid"
	ZAPErrAccessDenied       = "drive.access_denied"
	ZAPErrTicketInvalid      = "drive.ticket_invalid"
	ZAPErrAgentDeOutputsOnly = "drive.agent_de_outputs_only"
	ZAPErrFileTooLarge       = "drive.file_too_large"
	ZAPErrQuotaExceeded      = "drive.quota_exceeded"
	ZAPErrStorageMissing     = "drive.storage_config_missing"
)

// Presign ZAP /files/sign: agent 请求一个上传 staging URL.
// 流程:
//  1. resolve agent → creator
//  2. 通过 SystemFoldersSvc 确保 de_outputs 系统目录存在 (sysFolders 已在 Phase 2.9 实现)
//  3. quota precheck
//  4. 生成 file_uuid + staging/final keys + presign staging URL
//  5. INSERT ticket (source=agent_output, folder=de_outputs.id, account=creator)
//  6. 返 legacy ZAP 形状响应; client SDK 拿 presign_ticket=file_uuid 后续 confirm 用
func (s *ZAPSvc) Presign(ctx context.Context, tenantID int64, agentUUID string, req ZAPPresignReq) (*ZAPPresignResp, error) {
	return s.presign(ctx, tenantID, agentUUID, req, uuid.NewString(), false)
}

func (s *ZAPSvc) presign(ctx context.Context, tenantID int64, agentUUID string, req ZAPPresignReq, fileUUID string, reuse bool) (*ZAPPresignResp, error) {
	if err := validateOutputRequest(tenantID, agentUUID, req); err != nil {
		return nil, err
	}
	meta, err := s.agentMeta(ctx, tenantID, agentUUID)
	if err != nil {
		return nil, err
	}
	return s.presignForOwner(ctx, tenantID, meta.CreatorID, agentUUID, agentDisplayName(meta), req, fileUUID, reuse)
}

func validateOutputRequest(tenantID int64, agentUUID string, req ZAPPresignReq) error {
	if tenantID <= 0 || agentUUID == "" {
		return apperr.ErrUnauthorized.Withf(ZAPErrSessionInvalid)
	}
	if strings.TrimSpace(req.FileName) == "" {
		return apperr.ErrInvalidParams.Withf("file_name required")
	}
	if req.FileSize <= 0 {
		return apperr.ErrInvalidParams.Withf("file_size > 0 required")
	}
	if drivefilename.Sanitize(req.FileName) == "" {
		return apperr.ErrInvalidParams.Withf("file_name invalid")
	}
	return nil
}

// presignForOwner only accepts a server-authorized owner, never a request field.
func (s *ZAPSvc) presignForOwner(ctx context.Context, tenantID, ownerAccountID int64, agentUUID, agentName string, req ZAPPresignReq, fileUUID string, reuse bool) (*ZAPPresignResp, error) {
	if err := validateOutputRequest(tenantID, agentUUID, req); err != nil {
		return nil, err
	}
	cleanName := drivefilename.Sanitize(req.FileName)
	mime := strings.ToLower(strings.TrimSpace(req.MimeType))
	if mime == "" {
		mime = "application/octet-stream"
	}

	// 2. ensure 系统目录 (含 de_root + de_agent + de_outputs); 返 de_agent → 反查 de_outputs.
	if _, err := s.sysFolders.EnsureAgentSystemFolders(ctx, tenantID, ownerAccountID, agentUUID, agentName); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	deOutputs, err := s.resolveDeOutputs(ctx, tenantID, ownerAccountID, agentUUID)
	if err != nil {
		return nil, err
	}
	folderID := deOutputs.ID

	if reuse {
		ticket, lookupErr := s.tickets.GetByFileUUID(ctx, fileUUID)
		if lookupErr == nil {
			if ticket.TenantID != tenantID || ticket.AccountID != ownerAccountID || ticket.FolderID == nil || *ticket.FolderID != folderID || ticket.Source != dom.FileSourceAgentOutput || ticket.DeclaredName != cleanName || ticket.DeclaredMime != mime || ticket.DeclaredSize != req.FileSize {
				return nil, apperr.ErrForbidden.Withf(ZAPErrTicketInvalid)
			}
			if ticket.Status == "done" {
				return &ZAPPresignResp{PresignTicket: fileUUID, Uploaded: true}, nil
			}
			if ticket.Status != "pending" || !ticket.ExpiresAt.After(time.Now()) {
				return nil, apperr.ErrForbidden.Withf(ZAPErrTicketInvalid)
			}
			store, err := s.storage.Resolve(ctx, tenantID)
			if err != nil {
				return nil, err
			}
			pres, err := store.PresignPut(ctx, object.PresignPutInput{Key: ticket.StagingKey, ContentType: mime, ContentLength: req.FileSize, TTL: s.presignTTL})
			if err != nil {
				return nil, err
			}
			return &ZAPPresignResp{UploadURL: pres.URL, UploadHeaders: pres.Headers, StorageKey: ticket.StagingKey, StorageKind: store.Kind(), ExpiresAt: pres.ExpiresAt, PresignTicket: fileUUID}, nil
		}
		if !errors.Is(lookupErr, drepo.ErrNotFound) {
			return nil, lookupErr
		}
	}

	// 3. quota precheck (uploadSvc.precheckQuota 是私有, 这里直接复用 quotas repo:
	//    若 tenant/account quota 不存在则跳过 — 与 UploadSvc.precheckQuota 同语义).
	if err := s.precheckQuota(ctx, tenantID, ownerAccountID, req.FileSize); err != nil {
		return nil, err
	}

	// 4. 生成 keys + presign
	ext := extFromName(cleanName)
	stagingKey := buildStagingKey(tenantID, fileUUID, ext)
	finalKey := buildFinalKey(tenantID, ownerAccountID, fileUUID, ext)

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf(ZAPErrStorageMissing).Wrap(err)
	}
	pres, err := store.PresignPut(ctx, object.PresignPutInput{
		Key:           stagingKey,
		ContentType:   mime,
		ContentLength: req.FileSize,
		TTL:           s.presignTTL,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("presign put: %w", err))
	}

	// 5. INSERT ticket (account=authorized owner, folder=de_outputs.id, source=agent_output)
	if err := s.tickets.Create(ctx, dom.CreateUploadTicketInput{
		FileUUID:     fileUUID,
		AccountID:    ownerAccountID,
		TenantID:     tenantID,
		FolderID:     &folderID,
		DeclaredSize: req.FileSize,
		DeclaredMime: mime,
		DeclaredName: cleanName,
		StagingKey:   stagingKey,
		FinalKey:     finalKey,
		UploadID:     nil,
		PartSize:     nil,
		Source:       dom.FileSourceAgentOutput,
		ExpiresAt:    time.Now().Add(s.ticketTTL),
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	return &ZAPPresignResp{
		UploadURL:     pres.URL,
		UploadHeaders: pres.Headers,
		StorageKey:    stagingKey,
		StorageKind:   store.Kind(),
		ExpiresIn:     int(s.presignTTL.Seconds()),
		ExpiresAt:     pres.ExpiresAt,
		PresignTicket: fileUUID,
	}, nil
}

// Confirm ZAP /files/confirm: agent 确认上传完成, bus 校验 + 落 drive_files.
// 流程:
//  1. 校 session + req
//  2. resolve agent → creator
//  3. 反查 ticket; 校全字段 (name/size/mime), 防 caller 在 confirm 阶段塞错入参
//  4. delegate UploadSvc.Confirm(creator_account_id, tenantID, ConfirmReq{file_uuid})
//     UploadSvc 自带: LockForConfirmTx → Stat → Copy → INSERT (source=ticket.Source=agent_output) → quota → ticket=done
//  5. 反查 drive_files 转 legacy FileDTO 形状返回
func (s *ZAPSvc) Confirm(ctx context.Context, tenantID int64, agentUUID string, req ZAPConfirmReq) (*ZAPFileDTO, error) {
	if tenantID <= 0 || agentUUID == "" {
		return nil, apperr.ErrUnauthorized.Withf(ZAPErrSessionInvalid)
	}
	if req.PresignTicket == "" {
		return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("presign_ticket required")
	}
	meta, err := s.agentMeta(ctx, tenantID, agentUUID)
	if err != nil {
		return nil, err
	}

	return s.confirmForOwner(ctx, tenantID, meta.CreatorID, req)
}

func (s *ZAPSvc) confirmForOwner(ctx context.Context, tenantID, ownerAccountID int64, req ZAPConfirmReq) (*ZAPFileDTO, error) {
	// 反查 ticket; 全字段比对防 caller 篡改 (与 legacy Codex 返修 #1 同纪律)
	ticket, err := s.tickets.GetByFileUUID(ctx, req.PresignTicket)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("ticket not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if ticket.TenantID != tenantID || ticket.AccountID != ownerAccountID ||
		ticket.Source != dom.FileSourceAgentOutput {
		return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("ticket scope mismatch")
	}
	if req.FileName != "" && ticket.DeclaredName != drivefilename.Sanitize(req.FileName) {
		return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("file_name mismatch")
	}
	if req.FileSize > 0 && ticket.DeclaredSize != req.FileSize {
		return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("file_size mismatch")
	}
	if req.MimeType != "" {
		if strings.ToLower(strings.TrimSpace(req.MimeType)) != ticket.DeclaredMime {
			return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("mime mismatch")
		}
	}
	if req.StorageKey != "" && req.StorageKey != ticket.StagingKey {
		return nil, apperr.New(apperr.Forbidden, ZAPErrTicketInvalid).Withf("storage_key mismatch")
	}

	// Delegate with the authorized owner (cloud creator or local task account).
	// UploadSvc.Confirm 内部 LockForConfirmTx 校 account+tenant 匹配 ticket.
	var checksum *string
	if req.Checksum != "" {
		value := strings.ToLower(strings.TrimSpace(req.Checksum))
		if len(value) != 64 || strings.Trim(value, "0123456789abcdef") != "" {
			return nil, apperr.ErrInvalidParams.Withf("invalid checksum")
		}
		checksum = &value
	}
	fileResp, err := s.uploadSvc.Confirm(ctx, ownerAccountID, tenantID, ConfirmReq{FileUUID: req.PresignTicket, SHA256: checksum})
	if err != nil {
		return nil, err
	}

	// 反查 drive_files 拿 storage_kind + StorageKey + folder_uuid.
	store, _ := s.storage.Resolve(ctx, tenantID)
	storageKind := ""
	if store != nil {
		storageKind = store.Kind()
	}
	return &ZAPFileDTO{
		UUID:        fileResp.UUID,
		SpaceUUID:   fileResp.SpaceUUID,
		FolderUUID:  fileResp.FolderUUID,
		Name:        fileResp.Name,
		MimeType:    fileResp.MimeType,
		FileSize:    fileResp.SizeBytes,
		StorageKey:  fileResp.StorageKey,
		StorageKind: storageKind,
		SourceKind:  "agent_output",
		CreatedAt:   fileResp.CreatedAt,
	}, nil
}

// SignDownload ZAP /files/sign-download: agent 拿一个短期 GET 签名 URL.
// 严格: file 必须是 agent.creator 在自己 personal space de_outputs 内的 (本 agent 自己的输出);
// 跨 agent / 跨 creator 拒.
func (s *ZAPSvc) SignDownload(ctx context.Context, tenantID int64, agentUUID string, req ZAPSignDownloadReq) (*ZAPPresignedURL, error) {
	if tenantID <= 0 || agentUUID == "" {
		return nil, apperr.ErrUnauthorized.Withf(ZAPErrSessionInvalid)
	}
	if strings.TrimSpace(req.DriveFileUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_id required")
	}
	meta, err := s.agentMeta(ctx, tenantID, agentUUID)
	if err != nil {
		return nil, err
	}
	// 拿 file 校归属
	f, err := s.files.GetByUUID(ctx, req.DriveFileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("file not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	space, err := s.spaces.GetByID(ctx, f.SpaceID)
	if err != nil || space.TenantID != tenantID {
		return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("file cross-tenant")
	}
	// 必须是 agent 自己 creator 的输出 (source=agent_output AND created_by=creator)
	if f.Source != dom.FileSourceAgentOutput {
		return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("not agent output")
	}
	if f.CreatedBy == nil || *f.CreatedBy != meta.CreatorID {
		return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("not owned by agent creator")
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf(ZAPErrStorageMissing).Wrap(err)
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key:      f.StorageKey,
		TTL:      10 * time.Minute,
		Inline:   false,
		FileName: f.Name,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &ZAPPresignedURL{URL: out.URL, ExpiresAt: out.ExpiresAt}, nil
}

// ----- internal helpers -----

func (s *ZAPSvc) agentMeta(ctx context.Context, tenantID int64, agentUUID string) (*ZAPAgentMeta, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("drive: agent lookup not wired")
	}
	meta, err := s.agents.GetByUUID(ctx, tenantID, agentUUID)
	if err != nil {
		return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("agent lookup failed")
	}
	if meta == nil || meta.TenantID != tenantID || meta.CreatorID <= 0 {
		return nil, apperr.New(apperr.Forbidden, ZAPErrAccessDenied).Withf("agent meta invalid")
	}
	return meta, nil
}

// resolveDeOutputs 反查 caller agent 的 de_outputs folder. 假设 sysFolders 已 ensure.
func (s *ZAPSvc) resolveDeOutputs(ctx context.Context, tenantID, creatorAccountID int64, agentUUID string) (*dom.Folder, error) {
	space, err := s.spaces.EnsurePersonal(ctx, tenantID, creatorAccountID, "")
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_folders
         WHERE space_id = $1 AND agent_id = $2 AND kind = 'de_outputs' AND is_deleted = false
         LIMIT 1
    `
	var f dom.Folder
	err = s.pool.QueryRow(ctx, q, space.ID, agentUUID).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.de_outputs_missing").Wrap(err)
	}
	return &f, nil
}

// precheckQuota 与 UploadSvc.precheckQuota 同语义 (但其为私有方法, 本 svc 自实现一份).
func (s *ZAPSvc) precheckQuota(ctx context.Context, tenantID, accountID, size int64) error {
	if tq, err := s.quotas.GetForTenant(ctx, tenantID); err == nil && tq != nil {
		if tq.QuotaBytes >= 0 && tq.UsedBytes+size > tq.QuotaBytes {
			return apperr.New(apperr.PreconditionFailed, ZAPErrQuotaExceeded).Withf("tenant quota exceeded")
		}
	}
	if aq, err := s.quotas.GetForAccount(ctx, tenantID, accountID); err == nil && aq != nil {
		if aq.QuotaBytes >= 0 && aq.UsedBytes+size > aq.QuotaBytes {
			return apperr.New(apperr.PreconditionFailed, ZAPErrQuotaExceeded).Withf("account quota exceeded")
		}
	}
	return nil
}

// agentDisplayName 优先用 meta.Name; 缺时用 UUID 当 fallback (folder name 不能为空).
func agentDisplayName(meta *ZAPAgentMeta) string {
	if name := strings.TrimSpace(meta.Name); name != "" {
		return name
	}
	return meta.UUID
}
