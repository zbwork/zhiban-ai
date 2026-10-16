package chat

import (
	"context"
	"regexp"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
)

const runtimeFailureDiagnosticMaxBytes = 2000

var runtimeFailureSecretAssignment = regexp.MustCompile(
	`(?i)("?(?:authorization|cookie|x[_-]?api[_-]?key|x[_-]?zap[_-]?session[_-]?token|api[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?token|client[_-]?secret|private[_-]?key|secret|token|password)"?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,;\s}\]]+)`,
)

type runtimeFailureDiagnosticInput struct {
	RuntimeKind          string
	FailureStage         string
	StreamID             string
	MessageUUID          string
	ConversationUUID     string
	RoomUUID             string
	AccountID            int64
	TenantID             int64
	Agent                *domagent.DigitalEmployee
	AgentUUID            string
	RuntimeEnvironmentID int64
	ErrorCode            string
	RawErrorCode         string
	Diagnostic           string
}

// logRuntimeFailureDiagnostic keeps the client-safe error contract separate from
// production diagnostics. External/runtime error text must only enter logs through
// sanitizeRuntimeFailureDiagnostic.
func (s *impl) logRuntimeFailureDiagnostic(ctx context.Context, in runtimeFailureDiagnosticInput) {
	if s == nil || s.logger == nil {
		return
	}
	runtimeKind := strings.TrimSpace(in.RuntimeKind)
	if runtimeKind == "" {
		runtimeKind = "unknown"
	}
	agentUUID := strings.TrimSpace(in.AgentUUID)
	runtimeEnvironmentID := in.RuntimeEnvironmentID
	if in.Agent != nil {
		if agentUUID == "" {
			agentUUID = in.Agent.UUID
		}
		if runtimeEnvironmentID <= 0 && in.Agent.RuntimeEnvironmentID != nil {
			runtimeEnvironmentID = *in.Agent.RuntimeEnvironmentID
		}
	}
	s.logger.Warn(ctx, "chat runtime failure diagnostic",
		"runtime_kind", runtimeKind,
		"failure_stage", strings.TrimSpace(in.FailureStage),
		"stream_id", strings.TrimSpace(in.StreamID),
		"message_uuid", strings.TrimSpace(in.MessageUUID),
		"conversation_uuid", strings.TrimSpace(in.ConversationUUID),
		"room_uuid", strings.TrimSpace(in.RoomUUID),
		"tenant_id", in.TenantID,
		"account_id", in.AccountID,
		"agent_uuid", agentUUID,
		"runtime_environment_id", runtimeEnvironmentID,
		"error_code", strings.TrimSpace(in.ErrorCode),
		"raw_error_code", sanitizeRuntimeFailureDiagnostic(in.RawErrorCode),
		"diagnostic", sanitizeRuntimeFailureDiagnostic(in.Diagnostic),
	)
}

func sanitizeRuntimeFailureDiagnostic(raw string) string {
	s := redact.New().RedactText(strings.TrimSpace(raw))
	s = runtimeFailureSecretAssignment.ReplaceAllString(s, `${1}[REDACTED]`)
	s = strings.Join(strings.Fields(s), " ")
	if s == "" {
		return "(empty)"
	}
	if len(s) > runtimeFailureDiagnosticMaxBytes {
		s = strings.ToValidUTF8(s[:runtimeFailureDiagnosticMaxBytes], "") + "…"
	}
	return s
}
