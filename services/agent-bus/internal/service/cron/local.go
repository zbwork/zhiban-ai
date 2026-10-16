package cron

import (
	"context"
	"errors"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func cronAgentInScope(ag *domagent.DigitalEmployee, accountID, tenantID int64) bool {
	if ag == nil {
		return false
	}
	if ag.ExecutionLocus != "local" {
		return ag.TenantID == tenantID
	}
	switch ag.Source {
	case "platform":
		return ag.TenantID == 0 && ag.Visibility == "platform"
	case "enterprise":
		return ag.TenantID == tenantID
	case "personal":
		return ag.TenantID == tenantID && ag.CreatorID == accountID && ag.Visibility == "private"
	default:
		return false
	}
}
func assertLocalDelivery(ag *domagent.DigitalEmployee, conv *domconv.Conversation, kind string) error {
	if ag.ExecutionLocus == "local" && (kind != DeliveryKindDirect || conv == nil || conv.RoomID != nil || conv.DigitalEmployeeID == nil || *conv.DigitalEmployeeID != ag.ID) {
		return apperr.New(apperr.InvalidParams, "cron.local_direct_only")
	}
	return nil
}
func (s *impl) jobAgent(ctx context.Context, j *domcron.Job) (*domagent.DigitalEmployee, error) {
	id, err := s.fetchAgentUUID(ctx, j.AgentID)
	if err != nil {
		return nil, err
	}
	if s.agents == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound)
	}
	ag, err := s.agents.GetByUUID(ctx, id)
	if err != nil || ag == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound)
	}
	return ag, nil
}
func (s *impl) localDesktopReady(ctx context.Context, j *domcron.Job, ag *domagent.DigitalEmployee) error {
	if ag.ExecutionLocus != "local" {
		return nil
	}
	if s.localDesktop == nil {
		return apperr.New(apperr.PreconditionFailed, "cron.local_unavailable")
	}
	device, err := s.localDesktop.ResolveScheduledDesktop(ctx, j.AccountID, j.TenantID)
	if errors.Is(err, domlocal.ErrConflict) {
		return apperr.New(apperr.PreconditionFailed, "cron.local_conflict")
	}
	if errors.Is(err, domlocal.ErrUpgradeRequired) {
		return apperr.New(apperr.PreconditionFailed, "cron.local_upgrade_required")
	}
	if errors.Is(err, domlocal.ErrOffline) {
		return apperr.New(apperr.PreconditionFailed, "cron.local_offline")
	}
	if err != nil {
		return err
	}
	engine := ag.LocalEngine
	if engine == "" {
		engine = domlocal.EngineDSH
	}
	if !domlocal.SupportsEngine(device, engine) {
		return apperr.New(apperr.PreconditionFailed, "cron.local_upgrade_required")
	}
	return nil
}
func isLocalDesktopWaiting(err error) bool {
	var app *apperr.Error
	return errors.As(err, &app) && (app.Message == "cron.local_offline" || app.Message == "cron.local_conflict")
}
