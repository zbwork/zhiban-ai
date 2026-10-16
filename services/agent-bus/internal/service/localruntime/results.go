package localruntime

import (
	"context"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"time"
)

type resultRepository interface {
	SaveResults(context.Context, dom.Scope, string, int64, string, int64, []map[string]any) error
}

// Result authority never grants execution/model authority, and expires after seven days.
func (s *Service) ResultTask(ctx context.Context, scope dom.Scope, deviceID string, generation int64, run string, fence int64) (*dom.Task, error) {
	device, err := s.repo.GetDevice(ctx, scope, deviceID)
	if err != nil {
		return nil, err
	}
	if device.Generation != generation || time.Since(device.SeenAt) > 15*time.Second {
		return nil, dom.ErrOffline
	}
	task, err := s.repo.GetTask(ctx, scope, run)
	if err != nil {
		return nil, err
	}
	if task.DeviceUUID != deviceID || task.Fence != fence || task.ExpiresAt.Add(7*24*time.Hour).Before(time.Now()) {
		return nil, dom.ErrDenied
	}
	if task.Status != "completed" && task.Status != "failed" && task.Status != "cancelled" {
		return nil, dom.ErrConflict
	}
	return task, nil
}

func (s *Service) SaveResults(ctx context.Context, scope dom.Scope, deviceID string, generation int64, run string, fence int64, blocks []map[string]any) error {
	task, err := s.ResultTask(ctx, scope, deviceID, generation, run, fence)
	if err != nil {
		return err
	}
	if len(blocks) == 0 || len(blocks) > 32 || validateLocalArtifacts(task, blocks) != nil {
		return dom.ErrDenied
	}
	seen := map[string]bool{}
	for _, b := range blocks {
		ref, ok := b["local_artifact"].(map[string]any)
		if !ok {
			return dom.ErrDenied
		}
		id, _ := ref["artifact_id"].(string)
		if seen[id] {
			return dom.ErrDenied
		}
		seen[id] = true
	}
	repo, ok := s.repo.(resultRepository)
	if !ok {
		return dom.ErrDenied
	}
	return repo.SaveResults(ctx, scope, deviceID, generation, run, fence, blocks)
}

// Only an already recorded immutable result may be uploaded after execution ends.
func ResultMatches(task *dom.Task, artifact, hash, name, mime string, size int64) bool {
	if task.Status == "cancelled" {
		return false
	}
	var payload struct {
		Results []map[string]any `json:"local_results"`
	}
	if json.Unmarshal(task.Payload, &payload) != nil {
		return false
	}
	for _, b := range payload.Results {
		ref, _ := b["local_artifact"].(map[string]any)
		if ref["artifact_id"] == artifact && ref["sha256"] == hash && ref["device_id"] == task.DeviceUUID && b["name"] == name && b["mime"] == mime && b["size"] == float64(size) {
			return true
		}
	}
	return false
}
