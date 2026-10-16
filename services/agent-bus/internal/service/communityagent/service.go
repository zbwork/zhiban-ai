// Package communityagent limits the shared employee service to community runtimes.
package communityagent

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	runtimeenv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	"strings"
)

type EnvironmentReader interface {
	GetByID(context.Context, int64) (*runtimeenv.Env, error)
}
type Service struct {
	Agents       agentsvc.Service
	Environments EnvironmentReader
}
type Input struct {
	Name      string `json:"name"`
	Intro     string `json:"intro"`
	RuntimeID int64  `json:"runtime_environment_id"`
}

func (s *Service) List(ctx context.Context, tenantID int64, limit, offset int) ([]dom.DigitalEmployee, int64, error) {
	return s.Agents.List(ctx, dom.Filter{TenantID: tenantID, Source: "enterprise", Limit: limit, Offset: offset})
}
func (s *Service) Get(ctx context.Context, tenantID int64, uuid string) (*dom.DigitalEmployee, error) {
	e, err := s.Agents.Get(ctx, tenantID, uuid)
	if err != nil {
		return nil, err
	}
	if e.TenantID != tenantID || e.Source != "enterprise" {
		return nil, apperr.ErrForbidden
	}
	if e.RuntimeEnvironmentID == nil {
		return nil, apperr.ErrForbidden
	}
	if err := s.checkEnvironment(ctx, tenantID, *e.RuntimeEnvironmentID); err != nil {
		return nil, err
	}
	return e, nil
}
func (s *Service) checkEnvironment(ctx context.Context, tenantID, runtimeID int64) error {
	env, err := s.Environments.GetByID(ctx, runtimeID)
	if err != nil {
		return err
	}
	if env == nil || env.TenantID == nil || *env.TenantID != tenantID || env.Framework != "generic" || env.HostingKind != "embedded" || !env.Enabled || env.IsDeleted || env.Status != "active" {
		return apperr.ErrForbidden
	}
	return nil
}
func (s *Service) Create(ctx context.Context, actorID, tenantID int64, in Input) (*dom.DigitalEmployee, error) {
	if strings.TrimSpace(in.Name) == "" || len(in.Name) > 128 || len(in.Intro) > 4096 {
		return nil, apperr.ErrInvalidParams
	}
	if err := s.checkEnvironment(ctx, tenantID, in.RuntimeID); err != nil {
		return nil, err
	}
	return s.Agents.Create(ctx, actorID, tenantID, &dom.DigitalEmployee{Name: strings.TrimSpace(in.Name), Intro: in.Intro, RuntimeEnvironmentID: &in.RuntimeID, Visibility: "tenant", Source: "enterprise", Status: "draft"})
}
func (s *Service) Update(ctx context.Context, actorID, tenantID int64, uuid string, in Input) (*dom.DigitalEmployee, error) {
	e, err := s.Get(ctx, tenantID, uuid)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Name) == "" || len(in.Name) > 128 || len(in.Intro) > 4096 {
		return nil, apperr.ErrInvalidParams
	}
	e.Name = strings.TrimSpace(in.Name)
	e.Intro = in.Intro
	return s.Agents.Update(ctx, actorID, tenantID, e)
}
func (s *Service) Delete(ctx context.Context, actorID, tenantID int64, uuid string) error {
	e, err := s.Get(ctx, tenantID, uuid)
	if err != nil {
		return err
	}
	return s.Agents.Delete(ctx, actorID, tenantID, e.ID)
}
func (s *Service) Publish(ctx context.Context, actorID, tenantID int64, uuid string) (*dom.DigitalEmployee, error) {
	e, err := s.Get(ctx, tenantID, uuid)
	if err != nil {
		return nil, err
	}
	_, published, err := s.Agents.PublishVersion(ctx, actorID, tenantID, e.ID, "Community publication")
	return published, err
}
