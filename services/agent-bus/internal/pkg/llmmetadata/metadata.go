package llmmetadata

import (
	"strconv"
	"strings"
)

const Schema = "easyo.llm_context.v1"

type Context struct {
	UsageScene        string
	TenantID          int64
	AccountID         int64
	AgentID           string
	ConversationID    string
	MessageID         string
	StreamID          string
	CronRunID         string
	CallSessionID     string
	RuntimeEnvID      int64
	RuntimeInstanceID string
}

func Map(c Context) map[string]any {
	out := map[string]any{
		"schema": Schema,
	}
	putString(out, "usageScene", c.UsageScene)
	putInt(out, "tenantId", c.TenantID)
	putInt(out, "accountId", c.AccountID)
	putString(out, "agentId", c.AgentID)
	putString(out, "conversationId", c.ConversationID)
	putString(out, "messageId", c.MessageID)
	putString(out, "streamId", c.StreamID)
	putString(out, "cronRunId", c.CronRunID)
	putString(out, "callSessionId", c.CallSessionID)
	putInt(out, "runtimeEnvId", c.RuntimeEnvID)
	putString(out, "runtimeInstanceId", c.RuntimeInstanceID)
	return out
}
func putString(out map[string]any, key, value string) {
	if value = strings.TrimSpace(value); value != "" {
		out[key] = value
	}
}
func putInt(out map[string]any, key string, value int64) {
	if value > 0 {
		out[key] = strconv.FormatInt(value, 10)
	}
}
