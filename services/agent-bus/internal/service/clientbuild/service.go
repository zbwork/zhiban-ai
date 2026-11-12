package clientbuild

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientbuild"
)

type RunnerConfig struct{ URL, Token string }
type Config struct {
	Environment  string
	Mac, Windows RunnerConfig
}
type Service interface {
	List(context.Context, dom.Filter) ([]dom.Job, int64, error)
	Get(context.Context, string) (*dom.Job, error)
	Logs(context.Context, string, int64) ([]dom.Log, error)
	Create(context.Context, dom.Input, int64) (*dom.Job, error)
	Retry(context.Context, string, int64) (*dom.Job, error)
	Stop(context.Context, string, int64) (*dom.Job, error)
}
type impl struct {
	ctx         context.Context
	repo        dom.Repository
	cfg         Config
	client      *http.Client
	environment string
	mu          sync.Mutex
	active      map[string]bool
}

var versionRE = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
var buildRE = regexp.MustCompile(`^\d{1,12}$`)

func New(ctx context.Context, repo dom.Repository, cfg Config) Service {
	return &impl{ctx: ctx, repo: repo, cfg: cfg, client: &http.Client{Timeout: 30 * time.Second}, environment: deploymentEnvironment(cfg.Environment), active: map[string]bool{}}
}
func (s *impl) List(ctx context.Context, f dom.Filter) ([]dom.Job, int64, error) {
	return s.repo.List(ctx, f)
}
func (s *impl) Get(ctx context.Context, id string) (*dom.Job, error) { return s.repo.Get(ctx, id) }
func (s *impl) Logs(ctx context.Context, id string, after int64) ([]dom.Log, error) {
	return s.repo.Logs(ctx, id, after)
}
func (s *impl) Create(ctx context.Context, in dom.Input, actor int64) (*dom.Job, error) {
	in = normalize(in)
	in.Environment = s.environment
	if !valid(in) {
		return nil, dom.ErrInvalidInput
	}
	if _, err := s.runner(in.Platform); err != nil {
		return nil, err
	}
	j, err := s.repo.Create(ctx, in, actor, 1, "", randomID())
	if err == nil {
		s.start(j.UUID)
	}
	return j, err
}
func (s *impl) Retry(ctx context.Context, id string, actor int64) (*dom.Job, error) {
	old, err := s.repo.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if old.Status != "failed" {
		return nil, dom.ErrNotRetryable
	}
	in := dom.Input{Platform: old.Platform, Arch: old.Arch, Environment: old.Environment, Channel: old.Channel, Version: old.Version, BuildNumber: old.BuildNumber, ReleaseNotes: old.ReleaseNotes, IsForced: old.IsForced, GenerateDelta: old.GenerateDelta}
	j, err := s.repo.Create(ctx, in, actor, old.Attempt+1, old.UUID, randomID())
	if err == nil {
		s.start(j.UUID)
	}
	return j, err
}
func (s *impl) Stop(ctx context.Context, id string, _ int64) (*dom.Job, error) {
	j, err := s.repo.RequestStop(ctx, id)
	if err != nil || j.Status == "cancelled" || j.RunnerJobID == "" {
		return j, err
	}
	runner, err := s.runner(j.Platform)
	if err != nil {
		return nil, err
	}
	var remote runnerJob
	status, callErr := s.call(ctx, runner, http.MethodDelete, "/v1/builds/"+url.PathEscape(j.RunnerJobID), nil, &remote)
	if callErr == nil && (status == http.StatusOK || status == http.StatusNotFound) {
		if status == http.StatusNotFound || remote.State == "cancelled" {
			_ = s.repo.Finish(ctx, id, "cancelled", "", "")
		}
	}
	return s.repo.Get(ctx, id)
}
func (s *impl) start(id string) {
	s.mu.Lock()
	if s.active[id] {
		s.mu.Unlock()
		return
	}
	s.active[id] = true
	s.mu.Unlock()
	go func() { defer func() { s.mu.Lock(); delete(s.active, id); s.mu.Unlock() }(); s.run(id) }()
}

type runnerLog struct {
	Seq     int64  `json:"seq"`
	Stream  string `json:"stream"`
	Message string `json:"message"`
}
type runnerJob struct {
	ID                string      `json:"job_id"`
	State             string      `json:"state"`
	Error             string      `json:"error"`
	ClientVersionUUID string      `json:"client_version_uuid"`
	Logs              []runnerLog `json:"logs"`
}

func (s *impl) run(id string) {
	j, err := s.repo.Get(s.ctx, id)
	if err != nil {
		return
	}
	runner, err := s.runner(j.Platform)
	if err != nil {
		_ = s.repo.Finish(s.ctx, id, "failed", "", err.Error())
		return
	}
	remoteID := j.RunnerJobID
	if remoteID == "" {
		payload, _ := json.Marshal(map[string]any{"request_id": j.RequestID, "platform": j.Platform, "version": j.Version, "build_number": j.BuildNumber, "environment": j.Environment, "arch": j.Arch, "channel": j.Channel, "release_notes": j.ReleaseNotes, "is_forced": j.IsForced, "generate_delta": j.GenerateDelta})
		for remoteID == "" {
			j, _ = s.repo.Get(s.ctx, id)
			if j != nil && j.Status == "stopping" {
				_ = s.repo.Finish(s.ctx, id, "cancelled", "", "")
				return
			}
			_ = s.repo.UpdateRemote(s.ctx, id, "dispatching", "")
			var remote runnerJob
			status, callErr := s.call(s.ctx, runner, http.MethodPost, "/v1/builds", payload, &remote)
			if callErr == nil && status == http.StatusAccepted {
				remoteID = remote.ID
				break
			}
			if callErr == nil && status != http.StatusConflict && status < 500 {
				_ = s.repo.Finish(s.ctx, id, "failed", "", fmt.Sprintf("Build Runner 创建任务失败: HTTP %d", status))
				return
			}
			_ = s.repo.UpdateRemote(s.ctx, id, "queued", "")
			select {
			case <-s.ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
		_ = s.repo.UpdateRemote(s.ctx, id, "running", remoteID)
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	missingPolls := 0
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			j, _ = s.repo.Get(s.ctx, id)
			if j.Status == "stopping" {
				var remote runnerJob
				status, e := s.call(s.ctx, runner, http.MethodDelete, "/v1/builds/"+url.PathEscape(remoteID), nil, &remote)
				if e != nil {
					continue
				}
				if status == http.StatusNotFound || (status == http.StatusOK && remote.State == "cancelled") {
					_ = s.repo.Finish(s.ctx, id, "cancelled", "", "")
					return
				}
				continue
			}
			var remote runnerJob
			status, e := s.call(s.ctx, runner, http.MethodGet, "/v1/builds/"+url.PathEscape(remoteID)+"?after_seq="+fmt.Sprint(j.LastLogSeq), nil, &remote)
			if e != nil {
				continue
			}
			if status == http.StatusNotFound {
				missingPolls++
				if missingPolls >= 3 {
					_ = s.repo.Finish(s.ctx, id, "failed", "", "Build Runner 重启或任务状态已丢失，请重试")
					return
				}
				continue
			}
			if status != http.StatusOK {
				continue
			}
			missingPolls = 0
			logs := make([]dom.Log, 0, len(remote.Logs))
			last := j.LastLogSeq
			for _, l := range remote.Logs {
				logs = append(logs, dom.Log{Seq: l.Seq, Stream: l.Stream, Message: l.Message})
				if l.Seq > last {
					last = l.Seq
				}
			}
			if len(logs) > 0 {
				_ = s.repo.AppendLogs(s.ctx, id, logs, last)
			}
			switch remote.State {
			case "succeeded":
				_ = s.repo.Finish(s.ctx, id, "succeeded", remote.ClientVersionUUID, "")
				return
			case "failed":
				_ = s.repo.Finish(s.ctx, id, "failed", "", remote.Error)
				return
			case "cancelled":
				_ = s.repo.Finish(s.ctx, id, "cancelled", "", "")
				return
			}
		}
	}
}
func (s *impl) call(ctx context.Context, a RunnerConfig, method, path string, body []byte, out any) (int, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(a.URL, "/")+path, reader)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+a.Token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("ngrok-skip-browser-warning", "1")
	resp, err := s.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if ngrokCode := strings.TrimSpace(resp.Header.Get("Ngrok-Error-Code")); ngrokCode != "" {
		return resp.StatusCode, fmt.Errorf("Build Runner tunnel unavailable: %s", ngrokCode)
	}
	if out != nil && resp.StatusCode < 300 {
		if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}
func (s *impl) runner(platform string) (RunnerConfig, error) {
	a := s.cfg.Mac
	if platform == "windows" {
		a = s.cfg.Windows
	}
	if strings.TrimSpace(a.URL) == "" || len(a.Token) < 32 {
		return RunnerConfig{}, dom.ErrRunnerMissing
	}
	return a, nil
}
func normalize(in dom.Input) dom.Input {
	in.Platform = strings.ToLower(strings.TrimSpace(in.Platform))
	in.Arch = strings.ToLower(strings.TrimSpace(in.Arch))
	in.Environment = strings.ToLower(strings.TrimSpace(in.Environment))
	in.Channel = strings.ToLower(strings.TrimSpace(in.Channel))
	if in.Channel == "" {
		in.Channel = "stable"
	}
	in.Version = strings.TrimSpace(in.Version)
	in.BuildNumber = strings.TrimSpace(in.BuildNumber)
	in.ReleaseNotes = strings.TrimSpace(in.ReleaseNotes)
	return in
}

func deploymentEnvironment(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "prod", "production":
		return "prod"
	default:
		return "test"
	}
}
func valid(in dom.Input) bool {
	platform := in.Platform == "macos" || in.Platform == "windows" || in.Platform == "ios" || in.Platform == "android"
	arch := in.Arch == "arm64" || in.Arch == "x64" || in.Arch == "universal"
	combo := (in.Platform == "macos" && arch) || (in.Platform == "windows" && in.Arch == "x64") || ((in.Platform == "ios" || in.Platform == "android") && in.Arch == "arm64")
	return platform && combo && (in.Environment == "test" || in.Environment == "prod") && (in.Channel == "stable" || in.Channel == "beta" || in.Channel == "dev") && versionRE.MatchString(in.Version) && buildRE.MatchString(in.BuildNumber) && len(in.ReleaseNotes) <= 10000 && (!in.GenerateDelta || in.Platform == "macos")
}
func randomID() string { b := make([]byte, 24); _, _ = rand.Read(b); return hex.EncodeToString(b) }
