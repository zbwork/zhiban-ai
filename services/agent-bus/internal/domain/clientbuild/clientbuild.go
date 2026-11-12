package clientbuild

import (
	"context"
	"errors"
	"time"
)

var (
	ErrInvalidInput  = errors.New("client_build.invalid_input")
	ErrRunnerMissing = errors.New("client_build.runner_not_configured")
	ErrNotRetryable  = errors.New("client_build.not_retryable")
	ErrNotStoppable  = errors.New("client_build.not_stoppable")
)

type Job struct {
	ID                int64      `json:"-"`
	UUID              string     `json:"uuid"`
	Platform          string     `json:"platform"`
	Arch              string     `json:"arch"`
	Environment       string     `json:"environment"`
	Channel           string     `json:"channel"`
	Version           string     `json:"version"`
	BuildNumber       string     `json:"build_number"`
	ReleaseNotes      string     `json:"release_notes"`
	IsForced          bool       `json:"is_forced"`
	GenerateDelta     bool       `json:"generate_delta"`
	Status            string     `json:"status"`
	Attempt           int        `json:"attempt"`
	RetryOf           string     `json:"retry_of,omitempty"`
	RequestID         string     `json:"request_id"`
	RunnerJobID       string     `json:"runner_job_id,omitempty"`
	LastLogSeq        int64      `json:"last_log_seq"`
	ClientVersionUUID string     `json:"client_version_uuid,omitempty"`
	Error             string     `json:"error,omitempty"`
	CreatedBy         int64      `json:"created_by"`
	StartedAt         *time.Time `json:"started_at,omitempty"`
	FinishedAt        *time.Time `json:"finished_at,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
	UpdatedAt         time.Time  `json:"updated_at"`
}

type Input struct {
	Platform      string `json:"platform"`
	Arch          string `json:"arch"`
	Environment   string `json:"-"`
	Channel       string `json:"channel"`
	Version       string `json:"version"`
	BuildNumber   string `json:"build_number"`
	ReleaseNotes  string `json:"release_notes"`
	IsForced      bool   `json:"is_forced"`
	GenerateDelta bool   `json:"generate_delta"`
}

type Log struct {
	Seq       int64     `json:"seq"`
	Stream    string    `json:"stream"`
	Message   string    `json:"message"`
	CreatedAt time.Time `json:"created_at"`
}
type Filter struct {
	Platform, Status string
	Limit, Offset    int
}

type Repository interface {
	Create(context.Context, Input, int64, int, string, string) (*Job, error)
	Get(context.Context, string) (*Job, error)
	List(context.Context, Filter) ([]Job, int64, error)
	UpdateRemote(context.Context, string, string, string) error
	AppendLogs(context.Context, string, []Log, int64) error
	Finish(context.Context, string, string, string, string) error
	RequestStop(context.Context, string) (*Job, error)
	Logs(context.Context, string, int64) ([]Log, error)
}
