// system_folders.go — F06 §1.6 + §4.6 + ADR 0019 数字员工系统目录树管理 (Phase 2.9)
//
// 三级系统目录 (caller 个人 space 内):
//
//	de_root    : "/数字员工/"                            agent_id=NULL, is_system=true, parent=NULL
//	de_agent   : "/数字员工/{agentName}/"                agent_id=<aid>, is_system=true, parent=de_root.id
//	de_outputs : "/数字员工/{agentName}/结果文件/"        agent_id=<aid>, is_system=true, parent=de_agent.id
//
// 本 slice 仅提供 service-level helper (无 HTTP 路由), 供未来 F10 数字员工服务在
// agent 创建/改名/删除 时调用; Bootstrap 也回填 de_root (个人 space 入口).
//
// 与 user-facing FolderSvc 关系: FolderSvc.Create/Rename/Delete 已经 reject
// is_system=true 的目录 (Phase 2.2b 实现的 drive.system_folder_protected 守卫);
// 本 svc 走 repo 层直接 INSERT/UPDATE/SoftDelete 绕过 user-facing 守卫, 因为
// 系统调用方 (agent lifecycle) 必须能动这些目录.
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

const (
	// SystemFolderDeRootName F06 §1.6: de_root 固定显示名.
	SystemFolderDeRootName = "数字员工"
	// SystemFolderDeOutputsName F06 §1.6: de_outputs 固定显示名 (de_agent 子).
	SystemFolderDeOutputsName = "结果文件"
)

// SystemFoldersSvc Phase 2.9: 数字员工系统目录 ensure/rename/delete helper.
//
// 调用方约定 (consumer = future F10 agent lifecycle / 当前 Bootstrap 内部):
//   - EnsureAgentSystemFolders : agent 创建后, 在 owner 个人 space 内 ensure 三级目录.
//   - RenameAgentSystemFolder  : agent 改名后, rename de_agent + cascade 子 path.
//   - DeleteAgentSystemFolder  : agent 删除后, soft-delete de_agent + de_outputs.
//   - EnsureDeRootInPersonal   : Bootstrap 调; 个人 space 入口 ensure de_root (无 agent).
type SystemFoldersSvc struct {
	pool    *pgxpool.Pool
	spaces  *drepo.SpaceRepo
	folders *drepo.FolderRepo
}

// NewSystemFoldersSvc 构造.
func NewSystemFoldersSvc(pool *pgxpool.Pool, sp *drepo.SpaceRepo, fd *drepo.FolderRepo) *SystemFoldersSvc {
	return &SystemFoldersSvc{pool: pool, spaces: sp, folders: fd}
}

// EnsureDeRootInPersonal 幂等 ensure caller 个人 space 下的 de_root 目录 (无 agent).
// 用于 Bootstrap 回填: 即便用户从未有过 agent, 个人 space 也应该挂着这个根入口
// (前端展示 "我的云盘 / 数字员工/" 即便后者为空).
//
// 调用方需先调 spaces.EnsurePersonal 拿 personal space id, 再调本方法.
// 返回 de_root folder (新建或已存在).
func (s *SystemFoldersSvc) EnsureDeRootInPersonal(ctx context.Context, personalSpaceID, createdBy int64) (*dom.Folder, error) {
	return s.ensureDeRoot(ctx, personalSpaceID, createdBy)
}

// EnsureAgentSystemFolders 幂等 ensure 三级目录:
//  1. de_root  (个人 space 下, 整 space 内唯一)
//  2. de_agent (de_root 下, 名 = sanitized agentName, agent_id = agentID)
//  3. de_outputs (de_agent 下, 名 = "结果文件", agent_id = agentID)
//
// 调用方 (future F10 / 当前 Bootstrap 仅做 de_root) 必须保证:
//   - personalSpaceID 是 ownerAccountID 真正的 personal space (本方法不校 — 调方先 EnsurePersonal)
//   - agentID 是 agent 的稳定 ID (业务层 UUID); 多次 ensure 同 agentID 返同 folder 三件套
//   - agentName 改名后调 RenameAgentSystemFolder; 不要重复 ensure 新名 (会触发 23505)
//
// 返回 de_agent folder (供 caller 用 id 直接做后续 ingest 等). de_outputs 由本方法内 ensure
// 但不返 — 通过 GetByAgentID(de_outputs kind) 二次反查若需要.
func (s *SystemFoldersSvc) EnsureAgentSystemFolders(
	ctx context.Context,
	tenantID, ownerAccountID int64,
	agentID, agentName string,
) (*dom.Folder, error) {
	if tenantID <= 0 || ownerAccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id + owner_account_id required")
	}
	if strings.TrimSpace(agentID) == "" {
		return nil, apperr.ErrInvalidParams.Withf("agent_id required")
	}
	cleanAgentName := strings.TrimSpace(agentName)
	if cleanAgentName == "" {
		return nil, apperr.ErrInvalidParams.Withf("agent_name required")
	}
	// agent_name 走 user-facing 防御性清洗 (与 user folder rename 一致约束: 无 /\ + 无控制字符).
	if !isValidSystemFolderName(cleanAgentName) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_agent_name")
	}

	// 1. 取 personal space (调方应已 EnsurePersonal; 这里读取后用 id).
	personal, err := s.spaces.EnsurePersonal(ctx, tenantID, ownerAccountID, "")
	if err != nil {
		return nil, fmt.Errorf("drive.SystemFolders.EnsurePersonal: %w", err)
	}

	// 2. ensure de_root
	deRoot, err := s.ensureDeRoot(ctx, personal.ID, ownerAccountID)
	if err != nil {
		return nil, err
	}

	// 3. ensure de_agent under de_root
	deAgent, err := s.ensureChildSystemFolder(
		ctx, personal.ID, &deRoot.ID, cleanAgentName, dom.FolderKindDeAgent, &agentID,
		deRoot.Path+cleanAgentName+"/", ownerAccountID,
	)
	if err != nil {
		return nil, fmt.Errorf("drive.SystemFolders.ensureDeAgent: %w", err)
	}

	// 4. ensure de_outputs under de_agent
	if _, err := s.ensureChildSystemFolder(
		ctx, personal.ID, &deAgent.ID, SystemFolderDeOutputsName, dom.FolderKindDeOutputs, &agentID,
		deAgent.Path+SystemFolderDeOutputsName+"/", ownerAccountID,
	); err != nil {
		return nil, fmt.Errorf("drive.SystemFolders.ensureDeOutputs: %w", err)
	}

	return deAgent, nil
}

// RenameAgentSystemFolder F10 agent 改名钩子: rename de_agent folder + cascade
// 子目录 (de_outputs 及未来扩展) 的 path.
//
// 不改变 agent_id, 不动 de_root. de_outputs 仍叫 "结果文件" 但 path 更新到新的
// 父名下: /数字员工/{newName}/结果文件/.
//
// 调用方保证 newAgentName 已被业务层校验; 本方法做防御性 sanitize.
// 幂等: 若已是 newAgentName (没真改), 返 nil 不报错.
func (s *SystemFoldersSvc) RenameAgentSystemFolder(
	ctx context.Context,
	tenantID, ownerAccountID int64,
	agentID, newAgentName string,
	updatedBy int64,
) error {
	cleanNew := strings.TrimSpace(newAgentName)
	if cleanNew == "" {
		return apperr.ErrInvalidParams.Withf("new_agent_name required")
	}
	if !isValidSystemFolderName(cleanNew) {
		return apperr.ErrInvalidParams.Withf("drive.invalid_agent_name")
	}

	personal, err := s.spaces.EnsurePersonal(ctx, tenantID, ownerAccountID, "")
	if err != nil {
		return fmt.Errorf("drive.SystemFolders.Rename.EnsurePersonal: %w", err)
	}

	deAgent, err := s.findAgentFolderByKind(ctx, personal.ID, agentID, dom.FolderKindDeAgent)
	if err != nil {
		return err
	}
	if deAgent == nil {
		return apperr.ErrNotFound.Withf("drive.system_folder_not_found")
	}
	if deAgent.Name == cleanNew {
		return nil // 幂等: 已经是新名
	}

	// 新 path = parent.path + newName + "/"
	parentPath := strings.TrimSuffix(deAgent.Path, deAgent.Name+"/")
	newPath := parentPath + cleanNew + "/"

	// TX: rename de_agent + cascade descendant paths.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("drive.SystemFolders.Rename.BeginTx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err := s.folders.RenameTx(ctx, tx, deAgent.ID, cleanNew, newPath, updatedBy); err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		return fmt.Errorf("drive.SystemFolders.Rename.exec: %w", err)
	}
	// cascade: 所有以 oldPath 为前缀的 descendant 替换为 newPath
	if err := s.folders.UpdateDescendantPathsTx(ctx, tx, personal.ID, deAgent.ID, deAgent.Path, newPath); err != nil {
		return fmt.Errorf("drive.SystemFolders.Rename.cascade: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("drive.SystemFolders.Rename.Commit: %w", err)
	}
	committed = true
	return nil
}

// DeleteAgentSystemFolder F10 agent 删除钩子: soft-delete de_agent + de_outputs.
//
// 子目录内的 drive_files 不动 — 文件软删 / 物理清理跟随 recycle bin worker (Phase 2.4+
// 递归 subtree soft-delete 落地后再做). 当前 slice: 只 mark 两层 folder is_deleted=true,
// 保留 outputs 文件等用户主动清理.
//
// 幂等: 若 de_agent 已 soft-deleted, 返 nil 不报错.
func (s *SystemFoldersSvc) DeleteAgentSystemFolder(
	ctx context.Context,
	tenantID, ownerAccountID int64,
	agentID string,
	deletedBy int64,
) error {
	personal, err := s.spaces.EnsurePersonal(ctx, tenantID, ownerAccountID, "")
	if err != nil {
		return fmt.Errorf("drive.SystemFolders.Delete.EnsurePersonal: %w", err)
	}

	deAgent, err := s.findAgentFolderByKind(ctx, personal.ID, agentID, dom.FolderKindDeAgent)
	if err != nil {
		return err
	}
	if deAgent == nil {
		return nil // 幂等: 不存在即视为已删
	}
	deOutputs, err := s.findAgentFolderByKind(ctx, personal.ID, agentID, dom.FolderKindDeOutputs)
	if err != nil {
		return err
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return fmt.Errorf("drive.SystemFolders.Delete.BeginTx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	// 先 outputs (子), 再 agent (父) — 与 user-facing folder delete 顺序一致.
	if deOutputs != nil {
		if err := s.folders.SoftDeleteTx(ctx, tx, deOutputs.ID, deletedBy); err != nil {
			return fmt.Errorf("drive.SystemFolders.Delete.de_outputs: %w", err)
		}
	}
	if err := s.folders.SoftDeleteTx(ctx, tx, deAgent.ID, deletedBy); err != nil {
		return fmt.Errorf("drive.SystemFolders.Delete.de_agent: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("drive.SystemFolders.Delete.Commit: %w", err)
	}
	committed = true
	return nil
}

// ----- internal helpers -----

// ensureDeRoot SELECT-then-INSERT 模式 (跟 EnsurePersonal 同款); 23505 → fallback SELECT.
func (s *SystemFoldersSvc) ensureDeRoot(ctx context.Context, spaceID, createdBy int64) (*dom.Folder, error) {
	const selQ = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_folders
         WHERE space_id = $1 AND parent_id IS NULL AND name = $2
           AND kind = 'de_root' AND is_deleted = false
         LIMIT 1
    `
	var f dom.Folder
	err := s.pool.QueryRow(ctx, selQ, spaceID, SystemFolderDeRootName).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if err == nil {
		return &f, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("drive.SystemFolders.ensureDeRoot.select: %w", err)
	}

	out, err := s.folders.Create(ctx, dom.CreateFolderInput{
		SpaceID:   spaceID,
		ParentID:  nil,
		Name:      SystemFolderDeRootName,
		Path:      "/" + SystemFolderDeRootName + "/",
		Kind:      dom.FolderKindDeRoot,
		AgentID:   nil,
		IsSystem:  true,
		CreatedBy: createdBy,
	})
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			// 并发: 另一 goroutine 同时插入 → refetch
			if err2 := s.pool.QueryRow(ctx, selQ, spaceID, SystemFolderDeRootName).Scan(
				&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
				&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
			); err2 == nil {
				return &f, nil
			}
		}
		return nil, fmt.Errorf("drive.SystemFolders.ensureDeRoot.insert: %w", err)
	}
	return out, nil
}

// ensureChildSystemFolder 通用: 在指定 parent 下 ensure 一个 system folder
// (kind = de_agent 或 de_outputs; 带 agent_id; is_system=true). SELECT-then-INSERT 幂等.
func (s *SystemFoldersSvc) ensureChildSystemFolder(
	ctx context.Context,
	spaceID int64,
	parentID *int64,
	name string,
	kind dom.FolderKind,
	agentID *string,
	path string,
	createdBy int64,
) (*dom.Folder, error) {
	return s.folders.EnsureSystemChild(ctx, dom.CreateFolderInput{
		SpaceID: spaceID, ParentID: parentID, Name: name, Kind: kind,
		AgentID: agentID, IsSystem: true, Path: path, CreatedBy: createdBy,
	})
}

// findAgentFolderByKind 反查指定 agent 在指定 space 内的 de_agent / de_outputs folder.
// 返 nil + nil err 表示不存在 (调方按场景决定报错或幂等).
func (s *SystemFoldersSvc) findAgentFolderByKind(
	ctx context.Context,
	spaceID int64,
	agentID string,
	kind dom.FolderKind,
) (*dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_folders
         WHERE space_id = $1 AND agent_id = $2 AND kind = $3 AND is_deleted = false
         LIMIT 1
    `
	var f dom.Folder
	err := s.pool.QueryRow(ctx, q, spaceID, agentID, string(kind)).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("drive.SystemFolders.findAgentFolderByKind: %w", err)
	}
	return &f, nil
}

// isValidSystemFolderName 防御性校验 agent_name 作为 folder 名: 与 user folder
// rename 同约束 (拒 / \ NUL 控制字符 + 长度 ≤ 128).
func isValidSystemFolderName(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for _, r := range s {
		if r == '/' || r == '\\' || r == 0x00 {
			return false
		}
		if r < 0x20 && r != '\t' {
			return false
		}
	}
	return true
}
