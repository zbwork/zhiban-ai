package admincore

import (
	"context"
	"encoding/json"
	"time"

	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
)

func fireAgentCollaborationAudit(ctx context.Context, store domaudit.Store, tenantID, accountID int64, agentUUID, eventKind string, payload map[string]any) {
	if store == nil || tenantID <= 0 || agentUUID == "" || eventKind == "" {
		return
	}
	if payload == nil {
		payload = map[string]any{}
	}
	payload["agent_id"] = agentUUID
	raw, _ := json.Marshal(payload)
	_ = store.Insert(ctx, domaudit.Event{
		OccurredAt:   time.Now().UTC(),
		TenantID:     tenantID,
		AccountID:    accountID,
		ActorKind:    domaudit.ActorAdmin,
		Domain:       "agent",
		EventKind:    eventKind,
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "digital_employee",
		ResourceUUID: agentUUID,
		Payload:      raw,
	})
}

func firePlatformAgentAudit(ctx context.Context, store domaudit.Store, accountID int64, agentUUID, eventKind string, payload map[string]any) {
	if store == nil || agentUUID == "" || eventKind == "" {
		return
	}
	if payload == nil {
		payload = map[string]any{}
	}
	payload["agent_id"] = agentUUID
	raw, _ := json.Marshal(payload)
	_ = store.Insert(ctx, domaudit.Event{
		OccurredAt:   time.Now().UTC(),
		AccountID:    accountID,
		ActorKind:    domaudit.ActorPlatformAdmin,
		Domain:       "agent",
		EventKind:    eventKind,
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "platform_preset_agent",
		ResourceUUID: agentUUID,
		Payload:      raw,
	})
}
