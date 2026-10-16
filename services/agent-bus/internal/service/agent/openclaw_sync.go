// openclaw_sync.go - Batch 2C T2C.3: publish / unpublish 时把 Agent 状态同步到
// 真实 OpenClaw 容器 (agents add + 7 文件 workspace; agents delete + RemoveDir)。
//
// **不在 PG 事务内做 docker exec / tar**: 三阶段 + 补偿模式, 详见 plan §5 T2C.3。
//
// 错误 -> 返回 OpenClawSyncError, 含 ErrorKind ∈ {cli_exec, fs_write, gateway_probe}。
// transport 层把它翻译成 HTTP 409 + body `{code: "openclaw_sync_failed", error_kind, message}`。
package agent

import (
	"context"
	"errors"
	"fmt"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/agentctl"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/openclaw/fs"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

// OpenClawSyncer 把 Agent 注册/注销到容器并写/清 workspace 文件 (Batch 2C T2C.3)。
//
// 实现类型: LocalOpenClawSyncer 走 docker exec; K8s 模式由后续 batch 实现。
type OpenClawSyncer interface {
	// Sync 在 publish 阶段 2 调: agents add + WriteFiles 7 md。
	// 幂等吞 "already exists" (CLI 端) 与 tar 覆盖写。
	// 失败返回 *OpenClawSyncError, ErrorKind 标记是哪一段错。
	Sync(ctx context.Context, agent *domagent.DigitalEmployee) error
	// Remove 在 unpublish 阶段 2 调: agents delete + RemoveDir workspace + RemoveDir agent-dir。
	// 不存在视为成功 (idempotent)。
	// 失败返回 *OpenClawSyncError。
	Remove(ctx context.Context, agent *domagent.DigitalEmployee) error
}

// OpenClawSyncError publish/unpublish 同步 OpenClaw 失败的归一化错误。
// transport 层据此返回 409 + error_kind。
type OpenClawSyncError struct {
	ErrorKind string // cli_exec | fs_write | gateway_probe (Probe 失败不在 Syncer 范畴, 走 runtime.HealthCheck)
	Stage     string // sync_add | sync_writefiles | remove_delete | remove_rmworkspace | remove_rmagentdir
	Cause     error
	AgentUUID string
}

func (e *OpenClawSyncError) Error() string {
	if e == nil {
		return ""
	}
	return fmt.Sprintf("openclaw_sync_failed kind=%s stage=%s agent=%s: %v", e.ErrorKind, e.Stage, e.AgentUUID, e.Cause)
}

func (e *OpenClawSyncError) Unwrap() error { return e.Cause }

// IsOpenClawSyncError 判定 err 是否为 OpenClawSyncError 实例。
func IsOpenClawSyncError(err error) (*OpenClawSyncError, bool) {
	var se *OpenClawSyncError
	if errors.As(err, &se) {
		return se, true
	}
	return nil, false
}

// AgentWorkspaceKBBindingLister 在 publish/resync 时为 workspace 渲染授权 KB 清单。
type AgentWorkspaceKBBindingLister interface {
	ListAgentWorkspaceKBBindings(ctx context.Context, agentID int64) ([]AgentWorkspaceKBBinding, error)
}

// LocalOpenClawSyncer 本机 docker exec 实现 (Batch 2C 主路径).
type LocalOpenClawSyncer struct {
	Ctl        agentctl.AgentCtl
	FS         fs.FS
	KBBindings AgentWorkspaceKBBindingLister // 可选；nil 时不写 KB 清单
}

// NewLocalOpenClawSyncer 构造 local syncer。containerName 默认 "openclaw"。
func NewLocalOpenClawSyncer(containerName string) *LocalOpenClawSyncer {
	return &LocalOpenClawSyncer{
		Ctl: agentctl.NewLocalCtl(containerName),
		FS:  fs.NewLocalFS(containerName),
	}
}

// WithKBBindingLister 注入 KB 绑定查询器，用于 AGENTS.md 动态 KB 清单。
func (s *LocalOpenClawSyncer) WithKBBindingLister(l AgentWorkspaceKBBindingLister) *LocalOpenClawSyncer {
	if s == nil {
		return nil
	}
	s.KBBindings = l
	return s
}

// Sync 实现 OpenClawSyncer.Sync。
//
// 顺序:
//  1. agentctl.Add (CLI exec, 幂等吞 "already exists")  -> stage=sync_add, kind=cli_exec
//  2. fs.WriteFiles (tar 流写 7 md + CLAUDE.md 镜像)    -> stage=sync_writefiles, kind=fs_write
//
// 步骤 2 失败 -> 不自动补偿删除 step1 的 agent, 因为 agents add 已写 OpenClaw 内部 config,
// 直接 agents delete 才能清。补偿由 caller (agent service Publish 阶段 2 整体) 调 Remove(...)
// 实现。本函数只暴露错误。
func (s *LocalOpenClawSyncer) Sync(ctx context.Context, a *domagent.DigitalEmployee) error {
	if a == nil {
		return fmt.Errorf("openclaw sync: nil agent")
	}
	wsPath := agentctl.WorkspacePath(a.UUID)
	adPath := agentctl.AgentDirPath(a.UUID)

	if err := s.Ctl.Add(ctx, a.UUID, wsPath, adPath); err != nil {
		return &OpenClawSyncError{ErrorKind: "cli_exec", Stage: "sync_add", Cause: err, AgentUUID: a.UUID}
	}
	var kbBindings []AgentWorkspaceKBBinding
	if s.KBBindings != nil && a.ID > 0 {
		if rows, err := s.KBBindings.ListAgentWorkspaceKBBindings(ctx, a.ID); err == nil {
			kbBindings = rows
		}
	}
	metaCtx := LLMMetadataContextFromWorkspace(a, WorkspaceRuntimeContext{TenantID: a.TenantID})
	if err := s.FS.WriteFiles(ctx, BuildAgentWorkspaceFilesWithOptions(a, kbBindings, wsPath, adPath, AgentWorkspaceOptions{LLMMetadata: metaCtx})); err != nil {
		return &OpenClawSyncError{ErrorKind: "fs_write", Stage: "sync_writefiles", Cause: err, AgentUUID: a.UUID}
	}
	return nil
}

// Remove 实现 OpenClawSyncer.Remove。
//
// 顺序:
//  1. agentctl.Delete (CLI exec, idempotent)
//  2. fs.RemoveDir workspace
//  3. fs.RemoveDir agent-dir
//
// 任一步失败立即返回 OpenClawSyncError; **不 best-effort 继续** (避免 DB archived 但
// OpenClaw 残留)。caller 看到错误后保持 DB published, 让 admin 重试。
func (s *LocalOpenClawSyncer) Remove(ctx context.Context, a *domagent.DigitalEmployee) error {
	if a == nil {
		return fmt.Errorf("openclaw remove: nil agent")
	}
	wsPath := agentctl.WorkspacePath(a.UUID)
	adPath := agentctl.AgentDirPath(a.UUID)

	if err := s.Ctl.Delete(ctx, a.UUID); err != nil {
		return &OpenClawSyncError{ErrorKind: "cli_exec", Stage: "remove_delete", Cause: err, AgentUUID: a.UUID}
	}
	if err := s.FS.RemoveDir(ctx, wsPath); err != nil {
		return &OpenClawSyncError{ErrorKind: "fs_write", Stage: "remove_rmworkspace", Cause: err, AgentUUID: a.UUID}
	}
	if err := s.FS.RemoveDir(ctx, adPath); err != nil {
		return &OpenClawSyncError{ErrorKind: "fs_write", Stage: "remove_rmagentdir", Cause: err, AgentUUID: a.UUID}
	}
	return nil
}

// NoopOpenClawSyncer 单测/非 openclaw framework 用。Sync/Remove 都返回 nil。
type NoopOpenClawSyncer struct{}

// NewNoopOpenClawSyncer 构造 no-op。仅供单元测试或当 runtime.framework != openclaw 时使用。
func NewNoopOpenClawSyncer() *NoopOpenClawSyncer { return &NoopOpenClawSyncer{} }

func (NoopOpenClawSyncer) Sync(ctx context.Context, a *domagent.DigitalEmployee) error   { return nil }
func (NoopOpenClawSyncer) Remove(ctx context.Context, a *domagent.DigitalEmployee) error { return nil }
