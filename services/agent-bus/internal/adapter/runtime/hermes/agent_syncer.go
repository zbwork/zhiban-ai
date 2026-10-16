package hermes

import (
	"context"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/controlplane"
)

// hermesAgentSyncer implements controlplane.AgentSyncer for Hermes.
// Hermes has no CLI-level agent registration (unlike OpenClaw); agent identity
// is conveyed entirely through workspace files.
type hermesAgentSyncer struct {
	workspace controlplane.WorkspaceWriter
}

// SyncAgent writes agent identity workspace files to the target instance.
// No-op when workspace writer is nil or there are no files to write.
func (s *hermesAgentSyncer) SyncAgent(ctx context.Context, target controlplane.InstanceTarget, spec controlplane.AgentSpec) error {
	if s.workspace == nil || len(spec.WorkspaceFiles) == 0 {
		return nil
	}
	if err := s.workspace.WriteWorkspace(ctx, target, spec.WorkspaceFiles); err != nil {
		if controlplane.IsRetryable(err) || isSyncError(err) {
			return err
		}
		return &controlplane.SyncError{Retryable: true, Reason: "hermes.write_identity", Cause: err}
	}
	return nil
}

// RemoveAgent is a no-op for Hermes. Hermes does not maintain a server-side
// agent registry; identity files are overwritten on re-sync and orphaned files
// are harmless.
func (s *hermesAgentSyncer) RemoveAgent(ctx context.Context, target controlplane.InstanceTarget, agentKey string) error {
	return nil
}
