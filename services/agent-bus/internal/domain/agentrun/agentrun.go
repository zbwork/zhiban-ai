// Package agentrun defines the F24 agent-run observability domain model:
// one Run per agent reply message (anchor = message_uuid), plus metadata-only
// Steps. Content (prompts, replies, tool payloads) never lives here — it stays
// in messages.blocks / a2a_call_edges (F24 D1).
package agentrun

import (
	"encoding/json"
	"time"
)

// RuntimeKind values (agent_runs.runtime_kind).
const (
	RuntimeOpenClaw       = "openclaw"
	RuntimeHermes         = "hermes"
	RuntimeZapExt         = "zap_external"
	RuntimeCodexAppServer = "codex_app_server"
	RuntimeDSH            = "dsh" // 平台自营 dsh 运行时 (ZAP 线)
	RuntimeBuiltinLLM     = "builtin_llm"
	// RuntimeUnknown is written by the reconcile backfill worker, or by an
	// immediate start-failure run when framework lookup itself was unavailable.
	RuntimeUnknown = "unknown"
)

// TriggerSource values (agent_runs.trigger_source). P0 writes chat/room/a2a;
// debug/cron/rtc are reserved for P1+ (F24 O5).
const (
	TriggerChat  = "chat"
	TriggerRoom  = "room"
	TriggerA2A   = "a2a"
	TriggerDebug = "debug"
	TriggerCron  = "cron"
	TriggerRTC   = "rtc"
)

// Run status values. Terminal semantics mirror messages.status.
const (
	StatusRunning      = "running"
	StatusAwaitingUser = "awaiting_user"
	StatusCompleted    = "completed"
	StatusFailed       = "failed"
	StatusCancelled    = "cancelled"
)

// Step kinds (agent_run_steps.step_kind).
const (
	StepThinking  = "thinking"
	StepToolCall  = "tool_call"
	StepA2AInvoke = "a2a_invoke"
	StepKB        = "kb_retrieval"
	StepHITLWait  = "hitl_wait"
	StepStage     = "stage"
)

// Step status values.
const (
	StepRunning   = "running"
	StepOK        = "ok"
	StepError     = "error"
	StepCancelled = "cancelled"
)

// Usage source values (agent_runs.usage_source).
const (
	UsageSourceRuntime = "runtime"
	UsageSourceNone    = "none"
)

// Ref kinds (agent_run_steps.ref_kind).
const (
	RefMessageBlock   = "message_block"
	RefA2AEdge        = "a2a_edge"
	RefRuntimeCallLog = "runtime_call_log"
	RefKBRecallLog    = "kb_recall_log"
)

// attrsWhitelist is the closed set of keys allowed in agent_run_steps.attrs
// (F24 D9): non-whitelisted keys are dropped at write time so "no content in
// L2" is enforced structurally, not by convention.
var attrsWhitelist = map[string]struct{}{
	"tool_category":   {},
	"kb_hit_count":    {},
	"a2a_invoke_kind": {},
	"a2a_to_agent":    {},
	"stage":           {},
}

// tagsWhitelist is the closed set of keys allowed in agent_runs.tags (F24 D9).
var tagsWhitelist = map[string]struct{}{
	"backfilled":    {},
	"chain_budget":  {},
	"model_family":  {},
	"agent_version": {},
}

// FilterAttrs returns a copy of in containing only whitelisted step attr keys.
func FilterAttrs(in map[string]any) map[string]any {
	return filterKeys(in, attrsWhitelist)
}

// FilterTags returns a copy of in containing only whitelisted run tag keys.
func FilterTags(in map[string]any) map[string]any {
	return filterKeys(in, tagsWhitelist)
}

func filterKeys(in map[string]any, allow map[string]struct{}) map[string]any {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]any, len(in))
	for k, v := range in {
		if _, ok := allow[k]; ok {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// Run is one agent execution. CreatedAt is the partition anchor and is fixed
// on first insert; all later writes upsert via (message_uuid, created_at).
type Run struct {
	UUID                 string
	TenantID             int64
	AccountID            *int64
	DigitalEmployeeID    int64
	ConversationUUID     string
	MessageUUID          string
	StreamID             string
	RoomID               *int64
	RuntimeKind          string
	RuntimeEnvironmentID *int64
	RuntimeInstanceID    string
	TriggerSource        string
	Status               string
	StartedAt            time.Time
	CompletedAt          *time.Time
	DurationMS           *int
	FirstOutputMS        *int
	ThinkingMS           *int
	HITLWaitMS           *int
	ToolCallCount        int
	ToolErrorCount       int
	A2AEdgeCount         int
	InputTokens          *int64
	OutputTokens         *int64
	TotalTokens          *int64
	UsageSource          string
	// Model is the display model (what the UI shows); it defaults to ExecutedModel.
	Model string
	// ExecutionLocus is "local" or "cloud" and is always written explicitly.
	// runtime_kind cannot stand in for it: cloud and desktop DSH share "dsh".
	ExecutionLocus string
	// RequestedModel / ExecutedModel / ResponseModel are three different facts:
	// what the user asked for, what the server ran, and what the upstream gateway
	// echoed back. Divergence between the last two is an upstream alias swap.
	RequestedModel string
	ExecutedModel  string
	ResponseModel  string
	// RetryIndex counts same-model automatic retries in this run (0 = first try).
	RetryIndex  int
	RetryReason string
	// FallbackChain records every model actually used, in order.
	FallbackChain   []FallbackStep
	AgentVersionID  *int64
	RootA2AEdgeUUID string
	ErrorCode       string
	ErrorMessage    string
	TraceID         string
	Tags            map[string]any
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// Step is one metadata-only unit inside a run. CreatedAt always equals the
// owning run's CreatedAt so run+steps share a partition and (run_uuid, seq,
// created_at) works as the idempotency key.
type Step struct {
	UUID         string
	TenantID     int64
	RunUUID      string
	Seq          int
	Kind         string
	Name         string
	Status       string
	StartedAt    time.Time
	EndedAt      *time.Time
	DurationMS   *int
	RefKind      string
	RefUUID      string
	RefCreatedAt *time.Time
	ErrorMessage string
	Attrs        map[string]any
	CreatedAt    time.Time
}

// FallbackStep is one entry of a run's model fallback chain. Reason is a
// controlled enum, never raw upstream text.
type FallbackStep struct {
	Slot   int    `json:"slot"`
	Model  string `json:"model"`
	Reason string `json:"reason,omitempty"`
}

// Execution locus values. Always written explicitly by the dispatch path.
const (
	ExecutionLocusLocal = "local"
	ExecutionLocusCloud = "cloud"
)

// Controlled retry reasons. Upstream error text must never reach these columns.
const (
	RetryReasonUpstreamUnavailable = "upstream_unavailable"
	RetryReasonHeaderTimeout       = "header_timeout"
	RetryReasonTransportError      = "transport_error"
)

// UsageNumbers is the normalized runtime-reported token triple.
type UsageNumbers struct {
	Input  *int64
	Output *int64
	Total  *int64
	Model  string
}

// NormalizeUsage extracts token counts from a runtime usage map, accepting
// the numeric encodings that appear across paths (float64 from JSON, int/int64
// from in-process maps, json.Number from decoders). Single source of truth for
// both the live recorder and the reconcile backfill (F24 口径一致性).
func NormalizeUsage(m map[string]any) UsageNumbers {
	var u UsageNumbers
	if len(m) == 0 {
		return u
	}
	num := func(key string) (int64, bool) {
		switch v := m[key].(type) {
		case float64:
			return int64(v), true
		case int64:
			return v, true
		case int:
			return int64(v), true
		case json.Number:
			if n, err := v.Int64(); err == nil {
				return n, true
			}
		}
		return 0, false
	}
	if v, ok := num("input_tokens"); ok {
		u.Input = &v
	}
	if v, ok := num("output_tokens"); ok {
		u.Output = &v
	}
	if v, ok := num("total_tokens"); ok {
		u.Total = &v
	} else if u.Input != nil && u.Output != nil {
		t := *u.Input + *u.Output
		u.Total = &t
	}
	if model, ok := m["model"].(string); ok {
		u.Model = model
	}
	return u
}
