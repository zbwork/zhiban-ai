package chat

import (
	"context"
	"errors"

	"github.com/google/uuid"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type scheduledLocalRuntime interface {
	ResolveScheduledDesktop(context.Context, int64, int64) (*domlocal.Device, error)
	ConversationState(context.Context, domlocal.Scope, string) (map[string]string, error)
	Ready(context.Context, domlocal.Scope, string, int64, string) (string, error)
}

func (s *impl) prepareScheduledLocalChat(ctx context.Context, in RunAgentInput) (map[string]any, error) {
	if s.localRuntime == nil {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.local_unavailable")
	}
	return scheduledLocalMetadata(ctx, s.localRuntime, in)
}
func scheduledLocalMetadata(ctx context.Context, local scheduledLocalRuntime, in RunAgentInput) (map[string]any, error) {
	if _, err := uuid.Parse(in.CronRunUUID); err != nil {
		return nil, apperr.ErrInvalidParams
	}
	if in.Agent == nil || in.Conversation == nil || in.RoomUUID != "" ||
		in.Conversation.AccountID != in.AccountID || in.Conversation.TenantID != in.TenantID || in.Conversation.RoomID != nil ||
		(in.Conversation.DigitalEmployeeID == nil || *in.Conversation.DigitalEmployeeID != in.Agent.ID) || !canRunOnCallersComputer(in.Agent, in.AccountID) {
		return nil, apperr.ErrForbidden
	}
	device, err := local.ResolveScheduledDesktop(ctx, in.AccountID, in.TenantID)
	if errors.Is(err, domlocal.ErrOffline) {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.local_offline")
	}
	if errors.Is(err, domlocal.ErrConflict) {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.local_conflict")
	}
	if errors.Is(err, domlocal.ErrUpgradeRequired) {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.local_upgrade_required")
	}
	if err != nil {
		return nil, err
	}
	state, err := local.ConversationState(ctx, device.Scope, in.Conversation.UUID)
	if err != nil {
		return nil, apperr.New(apperr.PreconditionFailed, "chat.local_context_unavailable")
	}
	model, err := local.Ready(ctx, device.Scope, device.UUID, in.Agent.ID, state["model"])
	if errors.Is(err, domlocal.ErrOffline) {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.local_offline")
	}
	if err != nil {
		return nil, apperr.New(apperr.PreconditionFailed, "chat.model_unavailable")
	}
	triggerUUID := ""
	if in.TriggerMessageUUID != nil {
		triggerUUID = *in.TriggerMessageUUID
	}
	return map[string]any{
		"cron_trigger_message_uuid":  triggerUUID,
		"cron_run_uuid":              in.CronRunUUID,
		"local_task_source":          "desktop",
		"local_requester_session_id": device.Scope.SessionUUID,
		"local_login_session_id":     device.Scope.SessionUUID,
		"local_device_id":            device.UUID,
		"local_context_id":           state["context_id"],
		"local_model_hint":           model,
		"conversation_model":         state["model"],
	}, nil
}
func localTriggerSource(metadata map[string]any) string {
	if id, ok := metadata["cron_run_uuid"].(string); ok && id != "" {
		return "cron"
	}
	return "chat"
}
