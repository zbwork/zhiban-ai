package communityagent

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	envdom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	"strings"
)

type PersonalEnvironments interface {
	EnvironmentReader
	GetByUUID(context.Context, string) (*envdom.Env, error)
	ListTenantCustom(context.Context, int64) ([]envdom.Env, error)
}
type Personal struct {
	Agents       agentsvc.Service
	Environments PersonalEnvironments
}

func (s *Personal) Get(ctx context.Context, accountID, tenantID int64, uuid string) (*dom.DigitalEmployee, error) {
	e, err := s.Agents.Get(ctx, tenantID, uuid)
	if err != nil {
		return nil, err
	}
	if e == nil || e.TenantID != tenantID || e.CreatorID != accountID || e.Source != "personal" {
		return nil, apperr.ErrNotFound
	}
	return e, nil
}
func (s *Personal) Save(ctx context.Context, accountID, tenantID int64, uuid string, in PersonalInput) (*dom.DigitalEmployee, error) {
	var e *dom.DigitalEmployee
	var err error
	if uuid != "" {
		e, err = s.Get(ctx, accountID, tenantID, uuid)
		if err != nil {
			return nil, err
		}
	} else {
		e = &dom.DigitalEmployee{Source: "personal", Visibility: "private", ExecutionLocus: "cloud", Status: "draft", Metadata: map[string]any{}}
	}
	if in.Name != nil {
		e.Name = strings.TrimSpace(*in.Name)
	}
	if e.Name == "" || len(e.Name) > 128 {
		return nil, apperr.ErrInvalidParams.Withf("name required, maximum 128 bytes")
	}
	if in.Intro != nil {
		e.Intro = *in.Intro
	}
	if in.Description != nil {
		e.Description = *in.Description
	}
	if in.WelcomeMsg != nil {
		e.WelcomeMsg = *in.WelcomeMsg
	}
	if in.AvatarURL != nil {
		e.AvatarURL = *in.AvatarURL
	}
	if in.PositionLabel != nil {
		e.PositionLabel = *in.PositionLabel
	}
	if in.Tags != nil {
		e.Tags = in.Tags
	}
	if len(e.Intro) > 4096 || len(e.Description) > 16384 || len(e.WelcomeMsg) > 4096 {
		return nil, apperr.ErrInvalidParams
	}
	if e.Metadata == nil {
		e.Metadata = map[string]any{}
	}
	for key, val := range in.Metadata {
		e.Metadata[key] = val
	}
	if uuid == "" && in.ExecutionLocus == "local" {
		e.ExecutionLocus, e.LocalEngine = "local", in.LocalEngine
	} else if uuid != "" && ((in.ExecutionLocus != "" && in.ExecutionLocus != e.ExecutionLocus) || (in.LocalEngine != "" && in.LocalEngine != e.LocalEngine)) {
		return nil, apperr.ErrInvalidParams.Withf("execution location and engine are immutable")
	}
	if e.ExecutionLocus == "local" {
		e.RuntimeEnvironmentID = nil
		if key, _ := e.Metadata["agent_key"].(string); strings.TrimSpace(key) == "" {
			e.Metadata["agent_key"] = "default"
		}
	} else if in.RuntimeUUID != "" {
		env, err := s.Environments.GetByUUID(ctx, in.RuntimeUUID)
		if err != nil {
			return nil, err
		}
		if env == nil {
			return nil, apperr.ErrForbidden
		}
		e.RuntimeEnvironmentID = &env.ID
	} else if e.RuntimeEnvironmentID == nil {
		envs, err := s.Environments.ListTenantCustom(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		for _, env := range envs {
			if (&Service{Environments: s.Environments}).checkEnvironment(ctx, tenantID, env.ID) == nil {
				id := env.ID
				e.RuntimeEnvironmentID = &id
				break
			}
		}
	}
	if e.ExecutionLocus != "local" {
		if e.RuntimeEnvironmentID == nil {
			return nil, apperr.ErrInvalidParams.Withf("community runtime unavailable")
		}
		if err := (&Service{Environments: s.Environments}).checkEnvironment(ctx, tenantID, *e.RuntimeEnvironmentID); err != nil {
			return nil, err
		}
	}
	wantPublished := e.Status == "published" || uuid == ""
	if in.Status != "" {
		if in.Status != "published" && in.Status != "draft" {
			return nil, apperr.ErrInvalidParams
		}
		wantPublished = in.Status == "published"
	}
	e.Source = "personal"
	e.Visibility = "private"
	e.ContactEnabled = true
	e.AllowInviteToGroup = true
	e.SupportsGroupChat = true
	e.Status = "draft"
	if uuid == "" {
		e, err = s.Agents.Create(ctx, accountID, tenantID, e)
	} else {
		e, err = s.Agents.Update(ctx, accountID, tenantID, e)
	}
	if err != nil {
		return nil, err
	}
	if wantPublished {
		_, e, err = s.Agents.PublishVersion(ctx, accountID, tenantID, e.ID, "Community personal employee")
	}
	return e, err
}
func (s *Personal) Delete(ctx context.Context, accountID, tenantID int64, uuid string) error {
	e, err := s.Get(ctx, accountID, tenantID, uuid)
	if err != nil {
		return err
	}
	return s.Agents.Delete(ctx, accountID, tenantID, e.ID)
}

type PersonalInput struct {
	Name, Intro, Description, WelcomeMsg, AvatarURL, PositionLabel *string
	Tags                                                           []string
	RuntimeUUID, Status                                            string
	ExecutionLocus, LocalEngine                                    string
	Metadata                                                       map[string]any
}
