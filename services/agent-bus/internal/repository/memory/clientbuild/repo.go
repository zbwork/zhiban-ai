package clientbuild

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientbuild"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Repo keeps build jobs only for the lifetime of the Admin process.
type Repo struct {
	mu   sync.RWMutex
	jobs map[string]*dom.Job
	logs map[string][]dom.Log
}

func New() *Repo {
	return &Repo{jobs: make(map[string]*dom.Job), logs: make(map[string][]dom.Log)}
}

func (r *Repo) Create(_ context.Context, in dom.Input, actor int64, attempt int, retryOf, requestID string) (*dom.Job, error) {
	now := time.Now().UTC()
	job := &dom.Job{
		UUID: requestID, Platform: in.Platform, Arch: in.Arch, Environment: in.Environment,
		Channel: in.Channel, Version: in.Version, BuildNumber: in.BuildNumber,
		ReleaseNotes: in.ReleaseNotes, IsForced: in.IsForced, GenerateDelta: in.GenerateDelta,
		Status: "queued", Attempt: attempt, RetryOf: retryOf, RequestID: requestID,
		CreatedBy: actor, CreatedAt: now, UpdatedAt: now,
	}
	r.mu.Lock()
	r.jobs[job.UUID] = clone(job)
	r.mu.Unlock()
	return clone(job), nil
}

func (r *Repo) Get(_ context.Context, uuid string) (*dom.Job, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	job := r.jobs[uuid]
	if job == nil {
		return nil, apperr.ErrNotFound.Withf("client build job not found")
	}
	return clone(job), nil
}

func (r *Repo) List(_ context.Context, f dom.Filter) ([]dom.Job, int64, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	items := make([]dom.Job, 0, len(r.jobs))
	for _, job := range r.jobs {
		if f.Platform != "" && job.Platform != f.Platform || f.Status != "" && job.Status != f.Status {
			continue
		}
		items = append(items, *clone(job))
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.After(items[j].CreatedAt) })
	total := int64(len(items))
	limit, offset := f.Limit, f.Offset
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	if offset >= len(items) {
		return []dom.Job{}, total, nil
	}
	end := offset + limit
	if end > len(items) {
		end = len(items)
	}
	return items[offset:end], total, nil
}

func (r *Repo) UpdateRemote(_ context.Context, uuid, status, runnerID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	job := r.jobs[uuid]
	if job == nil {
		return apperr.ErrNotFound.Withf("client build job not found")
	}
	now := time.Now().UTC()
	if job.Status != "stopping" {
		job.Status = status
	}
	job.UpdatedAt = now
	if runnerID != "" {
		job.RunnerJobID = runnerID
	}
	if job.StartedAt == nil {
		job.StartedAt = &now
	}
	return nil
}

func (r *Repo) RequestStop(_ context.Context, uuid string) (*dom.Job, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	job := r.jobs[uuid]
	if job == nil {
		return nil, apperr.ErrNotFound.Withf("client build job not found")
	}
	switch job.Status {
	case "cancelled", "stopping":
		return clone(job), nil
	case "succeeded", "failed":
		return nil, dom.ErrNotStoppable
	default:
		job.Status, job.UpdatedAt = "stopping", time.Now().UTC()
		return clone(job), nil
	}
}

func (r *Repo) AppendLogs(_ context.Context, uuid string, logs []dom.Log, last int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	job := r.jobs[uuid]
	if job == nil {
		return apperr.ErrNotFound.Withf("client build job not found")
	}
	existing := r.logs[uuid]
	seen := make(map[int64]bool, len(existing))
	for _, item := range existing {
		seen[item.Seq] = true
	}
	now := time.Now().UTC()
	for _, item := range logs {
		if seen[item.Seq] {
			continue
		}
		if item.CreatedAt.IsZero() {
			item.CreatedAt = now
		}
		existing = append(existing, item)
	}
	sort.Slice(existing, func(i, j int) bool { return existing[i].Seq < existing[j].Seq })
	r.logs[uuid], job.LastLogSeq, job.UpdatedAt = existing, last, now
	return nil
}

func (r *Repo) Finish(_ context.Context, uuid, status, clientUUID, message string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	job := r.jobs[uuid]
	if job == nil {
		return apperr.ErrNotFound.Withf("client build job not found")
	}
	now := time.Now().UTC()
	job.Status, job.ClientVersionUUID, job.Error = status, clientUUID, strings.TrimSpace(message)
	job.FinishedAt, job.UpdatedAt = &now, now
	return nil
}

func (r *Repo) Logs(_ context.Context, uuid string, after int64) ([]dom.Log, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.jobs[uuid] == nil {
		return nil, apperr.ErrNotFound.Withf("client build job not found")
	}
	items := make([]dom.Log, 0)
	for _, item := range r.logs[uuid] {
		if item.Seq > after {
			items = append(items, item)
		}
	}
	return items, nil
}

func clone(job *dom.Job) *dom.Job {
	if job == nil {
		return nil
	}
	copy := *job
	return &copy
}

var _ dom.Repository = (*Repo)(nil)
