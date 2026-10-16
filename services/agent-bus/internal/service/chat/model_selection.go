package chat

import (
	"context"
	"errors"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"strings"
)

// Model selection is authorized before persisting a message, and again when queued work starts.
type ConversationModelSelector interface {
	ValidateConversationModel(context.Context, int64, int64, *domagent.DigitalEmployee, string) error
}

func SetConversationModelSelector(svc Service, selector ConversationModelSelector) {
	if s, ok := svc.(*impl); ok {
		s.conversationModels = selector
	}
}
func selectedConversationModel(metadata map[string]any) string {
	value, _ := metadata["conversation_model"].(string)
	return strings.TrimSpace(value)
}
func (s *impl) validateConversationModel(ctx context.Context, account, tenant int64, ag *domagent.DigitalEmployee, framework, model string) error {
	if model == "" {
		return nil
	}
	if framework != FrameworkOpenClaw && framework != FrameworkHermes && framework != FrameworkDSH && framework != FrameworkGeneric {
		return apperr.ErrInvalidParams.Withf("该运行方式不支持会话模型切换")
	}
	if s.conversationModels == nil {
		return apperr.New(apperr.PreconditionFailed, "chat.model_configuration_unavailable")
	}
	if err := s.conversationModels.ValidateConversationModel(ctx, account, tenant, ag, model); err != nil {
		if errors.Is(err, domsource.ErrConfiguration) {
			return apperr.New(apperr.PreconditionFailed, "chat.model_configuration_unavailable")
		}
		return apperr.New(apperr.PreconditionFailed, "chat.model_unavailable")
	}
	return nil
}

// ConversationModelValidator exposes the existing authorization to room sends.
func ConversationModelValidator(svc Service) ConversationModelSelector {
	if s, ok := svc.(*impl); ok {
		return roomModelValidator{s}
	}
	return nil
}

type roomModelValidator struct{ service *impl }

func (v roomModelValidator) ValidateConversationModel(ctx context.Context, account, tenant int64, ag *domagent.DigitalEmployee, model string) error {
	framework, err := v.service.frameworkForAgent(ctx, ag, v.service.runtimeEnvFW)
	if err != nil {
		return err
	}
	return v.service.validateConversationModel(ctx, account, tenant, ag, framework, model)
}

type conversationModelPreparer interface {
	PrepareConversationModel(context.Context, int64, int64, *domagent.DigitalEmployee, string, string) (*domsource.RuntimeBinding, error)
}

func (s *impl) prepareConversationModel(ctx context.Context, account, tenant int64, ag *domagent.DigitalEmployee, message, model string) (*domsource.RuntimeBinding, error) {
	if !domsource.IsReference(model) {
		return nil, nil
	}
	p, ok := s.conversationModels.(conversationModelPreparer)
	if !ok {
		return nil, apperr.ErrForbidden
	}
	return p.PrepareConversationModel(ctx, account, tenant, ag, message, model)
}
