// agent_ingest.go — F06 Phase 2.8: 内部 agent output ingest 端点.
//
// 场景: 服务端 (F10 / composer / 任何 internal caller) 把一个已经上传到对象存储的
// 文件登记到 drive (drive_files 行) + 可选地登记到 chat (cmf 行).
//
// 与 ZAP /files/{sign,confirm,sign-download} 区别:
//   - ZAP 路径: agent SDK 主动通过 bus-issued presign URL 上传 (staging → confirm → copy → INSERT)
//   - Ingest 路径: 内部 caller 自己已经 PUT 好对象, 拿 storage_key 来登记 (Stat verify → INSERT)
//
// 两者都落 drive_files.source=agent_output 在 caller agent 的 creator personal space 内
// de_outputs 系统目录下 (Phase 2.9 SystemFoldersSvc 提供 ensure).
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/drivefilename"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// AgentIngestSvc Phase 2.8 服务: /internal/drive/ingest-agent-output.
type AgentIngestSvc struct {
	pool       *pgxpool.Pool
	spaces     *drepo.SpaceRepo
	folders    *drepo.FolderRepo
	files      *drepo.FileRepo
	quotas     *drepo.QuotaRepo
	cmf        *drepo.CMFRepo
	storage    StorageGetter
	agents     ZAPAgentLookup
	sysFolders *SystemFoldersSvc
}

// NewAgentIngestSvc 构造.
func NewAgentIngestSvc(
	pool *pgxpool.Pool,
	spaces *drepo.SpaceRepo, folders *drepo.FolderRepo, files *drepo.FileRepo,
	quotas *drepo.QuotaRepo, cmf *drepo.CMFRepo,
	storage StorageGetter, agents ZAPAgentLookup, sysFolders *SystemFoldersSvc,
) *AgentIngestSvc {
	return &AgentIngestSvc{
		pool: pool, spaces: spaces, folders: folders, files: files,
		quotas: quotas, cmf: cmf, storage: storage, agents: agents, sysFolders: sysFolders,
	}
}

// AgentIngestReq Phase 2.8 ingest 请求.
//   - agent_uuid: 谁产出的
//   - storage_key: 已经上传到对象存储的 key (caller 提前 PUT 好); ingest 时 Stat verify
//   - file_name / mime_type / size_bytes / sha256: 客户端声明; Stat 取实际 size 校验
//   - conversation_uuid + message_uuid: 可选; 给了就 INSERT cmf 行 (role='agent_output')
type AgentIngestReq struct {
	AgentUUID        string `json:"agent_uuid"`
	StorageKey       string `json:"storage_key"`
	FileName         string `json:"file_name"`
	MimeType         string `json:"mime_type"`
	SizeBytes        int64  `json:"size_bytes"`
	SHA256           string `json:"sha256,omitempty"`
	ConversationUUID string `json:"conversation_uuid,omitempty"`
	MessageUUID      string `json:"message_uuid,omitempty"`
}

// AgentIngestResp 响应.
type AgentIngestResp struct {
	DriveFileUUID string `json:"drive_file_uuid"`
	FolderUUID    string `json:"folder_uuid"` // = de_outputs.uuid
	CMFUUID       string `json:"cmf_uuid,omitempty"`
}

// Ingest /internal/drive/ingest-agent-output.
//
// 流程:
//  1. 入参校验 + resolve agent → creator
//  2. SystemFoldersSvc.EnsureAgentSystemFolders → de_outputs.id (复用 Phase 2.9)
//  3. Stat storage_key 验证已上传 + size 匹配 (412 missing / 412 size_mismatch)
//  4. TX:
//     a. 同目录重名检测 → 409
//     b. 原子 quota UPDATE (tenant + creator account) → 412 quota_exceeded
//     c. INSERT drive_files (source=agent_output, folder=de_outputs.id, created_by=creator)
//     d. UPDATE drive_spaces.used_bytes += size
//     e. 可选 INSERT cmf 行 (conversation_uuid + message_uuid 给了才写; role='agent_output')
//  5. 返 drive_file_uuid + de_outputs folder_uuid + cmf_uuid (若写了)
func (s *AgentIngestSvc) Ingest(ctx context.Context, tenantID int64, req AgentIngestReq) (*AgentIngestResp, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("tenant required")
	}
	if strings.TrimSpace(req.AgentUUID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("agent_uuid required")
	}
	if strings.TrimSpace(req.StorageKey) == "" {
		return nil, apperr.ErrInvalidParams.Withf("storage_key required")
	}
	if req.SizeBytes <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("size_bytes > 0 required")
	}
	cleanName := drivefilename.Sanitize(req.FileName)
	if cleanName == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_name invalid")
	}
	mime := strings.ToLower(strings.TrimSpace(req.MimeType))
	if mime == "" {
		mime = "application/octet-stream"
	}

	// 1. resolve agent → creator
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	meta, err := s.agents.GetByUUID(ctx, tenantID, req.AgentUUID)
	if err != nil {
		return nil, apperr.ErrForbidden.Withf("drive.access_denied")
	}
	if meta == nil || meta.TenantID != tenantID || meta.CreatorID <= 0 {
		return nil, apperr.ErrForbidden.Withf("drive.access_denied")
	}

	// 2. ensure 系统目录, 拿 de_outputs.id
	if _, err := s.sysFolders.EnsureAgentSystemFolders(ctx, tenantID, meta.CreatorID, req.AgentUUID, agentDisplayName(meta)); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	deOutputs, err := s.resolveDeOutputs(ctx, tenantID, meta.CreatorID, req.AgentUUID)
	if err != nil {
		return nil, err
	}

	// 3. Stat storage_key 验证已上传 + size 一致
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.storage_config_missing").Wrap(err)
	}
	stat, err := store.Stat(ctx, req.StorageKey)
	if err != nil {
		if errors.Is(err, object.ErrNotFound) {
			return nil, apperr.New(apperr.PreconditionFailed, "drive.ingest_object_missing").Withf("storage object not found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if stat.Size != req.SizeBytes {
		return nil, apperr.New(apperr.PreconditionFailed, "drive.size_mismatch").Withf("stat size %d != declared %d", stat.Size, req.SizeBytes)
	}

	// 4. TX: 重名检测 → 原子 quota → INSERT drive_files → 空间 used_bytes + 可选 cmf
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	// 4a. 重名 (same de_outputs folder + same name 活行 → 409)
	if existing, _ := s.files.GetByFolderAndName(ctx, &deOutputs.ID, cleanName); existing != nil {
		return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
	}

	// 4b. 原子 quota: 先查 tenant + creator account 的 quota_id; 然后条件 UPDATE.
	//     与 UploadSvc.runConfirmBackHalf 一致语义.
	if tq, err := s.quotas.GetForTenant(ctx, tenantID); err == nil && tq != nil {
		applied, aerr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, tq.ID, req.SizeBytes)
		if aerr != nil {
			return nil, apperr.ErrInternal.Wrap(aerr)
		}
		if !applied {
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded").Withf("tenant quota")
		}
	}
	if aq, err := s.quotas.GetForAccount(ctx, tenantID, meta.CreatorID); err == nil && aq != nil {
		applied, aerr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, aq.ID, req.SizeBytes)
		if aerr != nil {
			return nil, apperr.ErrInternal.Wrap(aerr)
		}
		if !applied {
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded").Withf("account quota")
		}
	}

	// 4c. INSERT drive_files
	var sha *string
	if req.SHA256 != "" {
		v := req.SHA256
		sha = &v
	}
	folderID := deOutputs.ID
	file, err := s.files.CreateTx(ctx, tx, dom.CreateFileInput{
		SpaceID:       deOutputs.SpaceID,
		DriveFolderID: &folderID,
		Name:          cleanName,
		MimeType:      mime,
		SizeBytes:     req.SizeBytes,
		SHA256:        sha,
		StorageKey:    req.StorageKey,
		Scope:         dom.FileScopeDrive,
		Source:        dom.FileSourceAgentOutput,
		CreatedBy:     meta.CreatorID,
	})
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 4d. drive_spaces.used_bytes += size
	if err := s.spaces.AddUsedBytesTx(ctx, tx, deOutputs.SpaceID, req.SizeBytes); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 4e. 可选 cmf row (chat 内引用)
	cmfUUID := ""
	if req.ConversationUUID != "" && req.MessageUUID != "" {
		if err := s.cmf.Create(ctx, dom.CreateCMFInput{
			TenantID:         tenantID,
			ConversationUUID: req.ConversationUUID,
			MessageUUID:      req.MessageUUID,
			AccountID:        meta.CreatorID,
			Role:             dom.CMFRoleAgentOutput,
			DriveFileUUID:    file.UUID,
			CreatedBy:        meta.CreatorID,
		}); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		// 反查 cmf.uuid (Create 不返); 注意 cmf 是 TX 内插的, 需要在同 TX 查.
		if err := tx.QueryRow(ctx,
			`SELECT uuid::text FROM conversation_message_files
              WHERE conversation_uuid = $1 AND message_uuid = $2 AND drive_file_uuid = $3::uuid
                AND is_deleted = false LIMIT 1`,
			req.ConversationUUID, req.MessageUUID, file.UUID).Scan(&cmfUUID); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed = true

	_ = stat
	_ = time.Now()
	return &AgentIngestResp{
		DriveFileUUID: file.UUID,
		FolderUUID:    deOutputs.UUID,
		CMFUUID:       cmfUUID,
	}, nil
}

// resolveDeOutputs 反查 caller agent 的 de_outputs folder.
// 与 ZAPSvc.resolveDeOutputs 同实现 (复制粘贴 ~20 行避免跨文件耦合; 未来抽到 sysFolders 共用).
func (s *AgentIngestSvc) resolveDeOutputs(ctx context.Context, tenantID, creatorAccountID int64, agentUUID string) (*dom.Folder, error) {
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
		return nil, apperr.ErrInternal.Withf("drive.de_outputs_missing").Wrap(fmt.Errorf("space=%d agent=%s: %w", space.ID, agentUUID, err))
	}
	return &f, nil
}
