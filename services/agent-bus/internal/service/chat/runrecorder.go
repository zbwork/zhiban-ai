// runrecorder.go — F24 P0: in-memory run/step collection for agent executions.
//
// One RunRecorder is created per dispatch (OpenClaw / Hermes / ZAP) and
// registered by streamID. Streaming loops call the On* hooks as events pass
// through (pure in-memory bookkeeping — no IO on the chat path). finalize()
// looks the recorder up by streamID and flushes asynchronously (fire-and-
// forget, F19 CallLogWriter pattern): a write failure only logs and the
// reconcile worker backfills a skeleton later (F24 D8).
//
// Clock discipline: all timestamps are Bus observation times (F24 D2).
// Content discipline: only metadata is recorded here — never prompt/reply/
// tool payload text (F24 D1/D9). error strings are redacted before flush.
package chat

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"time"

	domagentrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
	repoagentrun "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agentrun"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// runRecorderSink is the narrow persistence surface RunRecorder needs.
// *repoagentrun.Repo satisfies it; tests inject fakes.
type runRecorderSink interface {
	UpsertRun(ctx context.Context, run *domagentrun.Run) (string, error)
	UpsertSteps(ctx context.Context, steps []*domagentrun.Step) error
	CompleteA2AStep(ctx context.Context, tenantID int64, edgeUUID, status string, endedAt time.Time, errMsg string) (bool, error)
	CloseAwaitingRun(ctx context.Context, tenantID int64, messageUUID string, respondedAt time.Time) (bool, error)
}

var _ runRecorderSink = (*repoagentrun.Repo)(nil)

// runRecorderRegistry indexes live recorders. byStream is authoritative;
// byConvoAgent serves the A2A invoke hook (runtime tool calls only know the
// origin conversation + from-agent); byEdge serves async edge completion.
type runRecorderRegistry struct {
	mu           sync.Mutex
	byStream     map[string]*RunRecorder
	byConvoAgent map[string]*RunRecorder
	byEdge       map[string]*RunRecorder

	sink     runRecorderSink
	redactor *redact.Redactor
	logWarn  func(msg string, kv ...any)
}

func newRunRecorderRegistry(sink runRecorderSink, redactor *redact.Redactor, logWarn func(msg string, kv ...any)) *runRecorderRegistry {
	if logWarn == nil {
		logWarn = func(string, ...any) {}
	}
	return &runRecorderRegistry{
		byStream:     map[string]*RunRecorder{},
		byConvoAgent: map[string]*RunRecorder{},
		byEdge:       map[string]*RunRecorder{},
		sink:         sink,
		redactor:     redactor,
		logWarn:      logWarn,
	}
}

func convoAgentKey(convoUUID string, agentID int64) string {
	return convoUUID + "/" + strconv.FormatInt(agentID, 10)
}

// startRunRecorder opens a recorder for one dispatch. Nil-safe when run
// observability is not wired. Fills trace id from ctx (Bus OTel span).
func (s *impl) startRunRecorder(ctx context.Context, spec RunSpec) *RunRecorder {
	if s.runRecs == nil {
		return nil
	}
	if spec.TraceID == "" {
		if sc := oteltrace.SpanContextFromContext(ctx); sc.IsValid() {
			spec.TraceID = sc.TraceID().String()
		}
	}
	if spec.TriggerSource == "" {
		spec.TriggerSource = domagentrun.TriggerChat
	}
	return s.runRecs.Start(spec, time.Now())
}

func runtimeKindFromFramework(framework string) string {
	switch strings.ToLower(strings.TrimSpace(framework)) {
	case FrameworkOpenClaw:
		return domagentrun.RuntimeOpenClaw
	case FrameworkHermes:
		return domagentrun.RuntimeHermes
	case FrameworkZap:
		return domagentrun.RuntimeZapExt
	case FrameworkDSH:
		return domagentrun.RuntimeDSH
	case FrameworkSupportBuiltin:
		return domagentrun.RuntimeBuiltinLLM
	default:
		return domagentrun.RuntimeUnknown
	}
}

// RunSpec carries the dispatch-time context needed to open a recorder.
type RunSpec struct {
	TenantID          int64
	AccountID         int64 // 0 → NULL (a2a/cron system triggers)
	DigitalEmployeeID int64
	AgentVersionID    *int64
	ConversationUUID  string
	MessageUUID       string
	StreamID          string
	RoomID            *int64
	RuntimeKind       string
	// ExecutionLocus is "local" (the user's own computer) or "cloud". It must be
	// set explicitly by each dispatch path: cloud DSH and desktop DSH share
	// runtime_kind="dsh", so inferring the locus from it is always wrong.
	ExecutionLocus string
	// RequestedModel is what the user picked in the conversation; ExecutedModel is
	// what the server actually injected after authorization. Keeping both is what
	// makes an upstream alias swap observable (see I-03).
	RequestedModel       string
	ExecutedModel        string
	RuntimeEnvironmentID *int64
	RuntimeInstanceID    string
	TriggerSource        string
	RootA2AEdgeUUID      string
	TraceID              string
	// AgentVersion is the digital employee version number executing this run
	// (digital_employees.current_version / verParams.Version). Persisted into
	// tags.agent_version — agent_versions row id is not available on the chat
	// path (P0; see F24 §2.3).
	AgentVersion int
}

// Start opens and registers a recorder. Nil-safe: a nil registry (repo not
// wired) returns nil and every RunRecorder method tolerates a nil receiver,
// so chat paths never branch on observability being enabled.
func (rg *runRecorderRegistry) Start(spec RunSpec, now time.Time) *RunRecorder {
	if rg == nil || rg.sink == nil || spec.StreamID == "" || spec.MessageUUID == "" {
		return nil
	}
	rec := &RunRecorder{
		reg:       rg,
		spec:      spec,
		startedAt: now,
		createdAt: now,
	}
	rg.mu.Lock()
	rg.byStream[spec.StreamID] = rec
	rg.byConvoAgent[convoAgentKey(spec.ConversationUUID, spec.DigitalEmployeeID)] = rec
	rg.mu.Unlock()
	return rec
}

func (rg *runRecorderRegistry) lookupStream(streamID string) *RunRecorder {
	if rg == nil {
		return nil
	}
	rg.mu.Lock()
	defer rg.mu.Unlock()
	return rg.byStream[streamID]
}

// LookupForA2AInvoke resolves the caller-side recorder for a runtime A2A tool
// call, which only knows (origin conversation, from agent).
func (rg *runRecorderRegistry) LookupForA2AInvoke(convoUUID string, fromAgentID int64) *RunRecorder {
	if rg == nil {
		return nil
	}
	rg.mu.Lock()
	defer rg.mu.Unlock()
	return rg.byConvoAgent[convoAgentKey(convoUUID, fromAgentID)]
}

// NotifyA2AEdgeTerminal closes the a2a_invoke step for edgeUUID. In-memory if
// the caller run is still live; otherwise directly in DB (async edges that
// finish after the caller finalized — F24 §3.1-5). Idempotent on both paths.
func (rg *runRecorderRegistry) NotifyA2AEdgeTerminal(tenantID int64, edgeUUID string, ok bool, errMsg string, at time.Time) {
	if rg == nil || edgeUUID == "" {
		return
	}
	rg.mu.Lock()
	rec := rg.byEdge[edgeUUID]
	rg.mu.Unlock()
	if rec != nil {
		rec.closeA2AStep(edgeUUID, ok, errMsg, at)
		return
	}
	rg.NotifyA2AEdgeTerminalDB(tenantID, edgeUUID, ok, errMsg, at)
}

// CloseAwaitingRun settles the run of a HITL awaiting message when the user
// responds (ZAP respond claims the awaiting message → final; the respond turn
// is a NEW stream + message = a new run). hitl_wait_ms = respond - pause.
func (rg *runRecorderRegistry) CloseAwaitingRun(tenantID int64, awaitingMessageUUID string, respondedAt time.Time) {
	if rg == nil || rg.sink == nil || awaitingMessageUUID == "" {
		return
	}
	go func() {
		for _, delay := range []time.Duration{0, 2 * time.Second, 8 * time.Second} {
			if delay > 0 {
				time.Sleep(delay)
			}
			wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			updated, err := rg.sink.CloseAwaitingRun(wctx, tenantID, awaitingMessageUUID, respondedAt)
			cancel()
			if err != nil {
				rg.logWarn("agentrun: close awaiting run failed", "message_uuid", awaitingMessageUUID, "err", err)
				return
			}
			if updated {
				return
			}
		}
		// awaiting 行未落库 (写失败或延迟): reconcile sweeper 按 messages 终态兜底。
	}()
}

func (rg *runRecorderRegistry) redactText(s string) string {
	if rg == nil || rg.redactor == nil {
		return s
	}
	return rg.redactor.RedactText(s)
}

func (rg *runRecorderRegistry) unregister(rec *RunRecorder) {
	rg.mu.Lock()
	defer rg.mu.Unlock()
	if rg.byStream[rec.spec.StreamID] == rec {
		delete(rg.byStream, rec.spec.StreamID)
	}
	key := convoAgentKey(rec.spec.ConversationUUID, rec.spec.DigitalEmployeeID)
	if rg.byConvoAgent[key] == rec {
		delete(rg.byConvoAgent, key)
	}
	for edge, r := range rg.byEdge {
		if r == rec {
			delete(rg.byEdge, edge)
		}
	}
}

// SetAgentRunRecordingOnService wires F24 run observability onto a chat
// Service built by New/NewWithStopRetry (same pattern as
// SetHermesDispatcherOnService). No-op if svc is not *impl or repo is nil.
func SetAgentRunRecordingOnService(svc Service, repo *repoagentrun.Repo, redactor *redact.Redactor) {
	s, ok := svc.(*impl)
	if !ok || repo == nil {
		return
	}
	s.runRecs = newRunRecorderRegistry(repo, redactor, func(msg string, kv ...any) {
		s.logger.Warn(context.Background(), msg, kv...)
	})
}

// AgentRunHooks is the exported, nil-safe facade other packages use to feed
// A2A lifecycle signals into run recording (runtimetools invoke / a2a service
// terminal callbacks). A nil receiver is inert.
type AgentRunHooks struct{ reg *runRecorderRegistry }

// AgentRunHooksOf returns the hooks facade for a chat Service (nil-safe).
func AgentRunHooksOf(svc Service) *AgentRunHooks {
	s, ok := svc.(*impl)
	if !ok || s.runRecs == nil {
		return nil
	}
	return &AgentRunHooks{reg: s.runRecs}
}

// OnA2AInvoke records an outgoing A2A edge on the caller's live run, if any.
func (h *AgentRunHooks) OnA2AInvoke(originConvoUUID string, fromAgentID int64, edgeUUID, toAgentName, invokeKind string) {
	if h == nil || h.reg == nil {
		return
	}
	if rec := h.reg.LookupForA2AInvoke(originConvoUUID, fromAgentID); rec != nil {
		rec.OnA2AInvoke(edgeUUID, toAgentName, invokeKind, time.Now())
	}
}

// OnA2AEdgeTerminal converges the a2a_invoke step when an edge reaches a
// terminal state (sync return, async completion, approval reject, drop).
func (h *AgentRunHooks) OnA2AEdgeTerminal(tenantID int64, edgeUUID string, ok bool, errMsg string) {
	if h == nil || h.reg == nil {
		return
	}
	h.reg.NotifyA2AEdgeTerminal(tenantID, edgeUUID, ok, errMsg, time.Now())
}

type stepRec struct {
	seq       int
	kind      string
	name      string
	status    string
	startedAt time.Time
	endedAt   *time.Time
	refKind   string
	refUUID   string
	errMsg    string
	attrs     map[string]any
}

// RunRecorder accumulates one run's trajectory in memory. All methods are
// nil-safe and cheap (mutex + field writes) — safe on the hot chat path.
type RunRecorder struct {
	reg  *runRecorderRegistry
	spec RunSpec

	mu            sync.Mutex
	startedAt     time.Time
	createdAt     time.Time
	firstOutputAt *time.Time
	thinkingMS    int
	thinkingOpen  *time.Time
	steps         []*stepRec
	openTools     map[string]*stepRec // tool_call_id → step
	toolCalls     int
	toolErrors    int
	a2aEdges      int
	inputTokens   *int64
	outputTokens  *int64
	totalTokens   *int64
	// responseModel is what the upstream echoed back. It is deliberately NOT the
	// display model: keeping them apart is what surfaces an alias swap.
	responseModel string
	retryIndex    int
	retryReason   string
	fallbackChain []domagentrun.FallbackStep
	flushed       bool
}

// OnModelRetry records one same-model retry or one confirmed model switch.
// reason must be a controlled enum from domain/agentrun, never upstream text.
func (r *RunRecorder) OnModelRetry(slot int, model, reason string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.retryIndex++
	r.retryReason = reason
	r.fallbackChain = append(r.fallbackChain, domagentrun.FallbackStep{Slot: slot, Model: model, Reason: reason})
}

// OnExecutedModel records the model the server actually authorized for this run.
// It is set after dispatch-time arbitration, which can resolve a client hint to a
// different concrete model id.
func (r *RunRecorder) OnExecutedModel(model string) {
	if r == nil || model == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.spec.ExecutedModel = model
}

// RetryIndex is the billing idempotency discriminator: each real inference
// attempt must produce its own usage event instead of colliding on one key.
func (r *RunRecorder) RetryIndex() int {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.retryIndex
}

// OnReasoning marks a thinking event. Consecutive reasoning events form one
// thinking segment; any non-reasoning signal closes it.
func (r *RunRecorder) OnReasoning(now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.thinkingOpen == nil {
		t := now
		r.thinkingOpen = &t
	}
}

func (r *RunRecorder) closeThinkingLocked(now time.Time) {
	if r.thinkingOpen == nil {
		return
	}
	start := *r.thinkingOpen
	dur := int(now.Sub(start) / time.Millisecond)
	if dur < 0 {
		dur = 0
	}
	r.thinkingMS += dur
	end := now
	r.steps = append(r.steps, &stepRec{
		seq: len(r.steps) + 1, kind: domagentrun.StepThinking, status: domagentrun.StepOK,
		startedAt: start, endedAt: &end,
	})
	r.thinkingOpen = nil
}

// OnOutput marks a user-visible output event (text/block delta). Closes any
// open thinking segment and records first-output latency once.
func (r *RunRecorder) OnOutput(now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closeThinkingLocked(now)
	if r.firstOutputAt == nil {
		t := now
		r.firstOutputAt = &t
	}
}

// OnToolCall opens a tool step. toolCallID correlates the later result;
// name must be a bare tool identifier (never arguments — F24 D9).
// Idempotent per toolCallID: progress replays (OpenClaw paces tool frames)
// refresh the name but never open a duplicate step.
func (r *RunRecorder) OnToolCall(toolCallID, name string, now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closeThinkingLocked(now)
	if st := r.openTools[toolCallID]; st != nil { // 空 id 也占用 "" 槽位, 防进度重放膨胀
		if name != "" && st.name == "" {
			st.name = name
		}
		return
	}
	st := &stepRec{
		seq: len(r.steps) + 1, kind: domagentrun.StepToolCall, name: name,
		status: domagentrun.StepRunning, startedAt: now,
		refKind: domagentrun.RefMessageBlock, refUUID: toolCallID,
	}
	r.steps = append(r.steps, st)
	if r.openTools == nil {
		r.openTools = map[string]*stepRec{}
	}
	r.openTools[toolCallID] = st
	r.toolCalls++
}

// OnToolResult closes the matching tool step. Unknown ids are tolerated
// (runtime sent a result without a call — counted, not recorded).
func (r *RunRecorder) OnToolResult(toolCallID string, ok bool, errMsg string, now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	st := r.openTools[toolCallID]
	if st == nil || st.endedAt != nil {
		// 无主或重复的结果帧: 不开步骤也不计失败 (重放帧会翻倍 error 计数)。
		return
	}
	end := now
	st.endedAt = &end
	if ok {
		st.status = domagentrun.StepOK
	} else {
		st.status = domagentrun.StepError
		st.errMsg = errMsg
		r.toolErrors++
	}
	delete(r.openTools, toolCallID)
}

// OnA2AInvoke opens an a2a_invoke step and indexes the recorder by edge so
// NotifyA2AEdgeTerminal can close it (in memory or later in DB).
func (r *RunRecorder) OnA2AInvoke(edgeUUID, toAgentName, invokeKind string, now time.Time) {
	if r == nil || edgeUUID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.flushed {
		// Flush 已经快照落库: 迟到的 invoke 打点丢弃, 绝不把已注销的 recorder
		// 重新塞回 byEdge (F24 review C2-adjacent 泄漏窗口)。
		return
	}
	r.closeThinkingLocked(now)
	r.steps = append(r.steps, &stepRec{
		seq: len(r.steps) + 1, kind: domagentrun.StepA2AInvoke, name: toAgentName,
		status: domagentrun.StepRunning, startedAt: now,
		refKind: domagentrun.RefA2AEdge, refUUID: edgeUUID,
		attrs: map[string]any{"a2a_invoke_kind": invokeKind, "a2a_to_agent": toAgentName},
	})
	r.a2aEdges++
	// r.mu 内嵌 reg.mu: 与 Flush(设 flushed 后才 unregister) 串行化。全代码库
	// 无 reg.mu→r.mu 的反向嵌套 (NotifyA2AEdgeTerminal 释放 reg.mu 后才进
	// closeA2AStep), 不构成死锁环。
	r.reg.mu.Lock()
	r.reg.byEdge[edgeUUID] = r
	r.reg.mu.Unlock()
}

func (r *RunRecorder) closeA2AStep(edgeUUID string, ok bool, errMsg string, now time.Time) {
	r.mu.Lock()
	var st *stepRec
	for _, s := range r.steps {
		if s.kind == domagentrun.StepA2AInvoke && s.refUUID == edgeUUID && s.endedAt == nil {
			st = s
			break
		}
	}
	if st != nil {
		end := now
		st.endedAt = &end
		if ok {
			st.status = domagentrun.StepOK
		} else {
			st.status = domagentrun.StepError
			st.errMsg = errMsg
			r.toolErrors++
		}
	}
	flushed := r.flushed
	tenantID := r.spec.TenantID
	r.mu.Unlock()

	r.reg.mu.Lock()
	delete(r.reg.byEdge, edgeUUID)
	r.reg.mu.Unlock()

	if flushed {
		// Run row already persisted with the step still 'running' → converge in DB.
		r.reg.NotifyA2AEdgeTerminalDB(tenantID, edgeUUID, ok, errMsg, now)
	}
}

// NotifyA2AEdgeTerminalDB is the DB-only close path (no registry lookup).
// Bounded retries cover the window where the step row's async insert has not
// landed yet (F24 review C2); anything past that converges via the reconcile
// sweeper (ConvergeA2ASteps).
func (rg *runRecorderRegistry) NotifyA2AEdgeTerminalDB(tenantID int64, edgeUUID string, ok bool, errMsg string, at time.Time) {
	if rg == nil || rg.sink == nil {
		return
	}
	status := domagentrun.StepOK
	if !ok {
		status = domagentrun.StepError
	}
	redacted := rg.redactText(errMsg)
	go func() {
		for _, delay := range []time.Duration{0, 2 * time.Second, 8 * time.Second} {
			if delay > 0 {
				time.Sleep(delay)
			}
			wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			updated, err := rg.sink.CompleteA2AStep(wctx, tenantID, edgeUUID, status, at, redacted)
			cancel()
			if err != nil {
				rg.logWarn("agentrun: complete a2a step failed", "edge_id", edgeUUID, "err", err)
				return
			}
			if updated {
				return
			}
		}
		// step 行仍未出现: 交给 reconcile sweeper 收敛, 不再占用 goroutine。
	}()
}

// OnUsage records runtime-reported token usage (F24 D3: runtime口径, never
// the billing authority).
func (r *RunRecorder) OnUsage(usage map[string]any) {
	if r == nil || len(usage) == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	u := domagentrun.NormalizeUsage(usage)
	if u.Input != nil {
		r.inputTokens = u.Input
	}
	if u.Output != nil {
		r.outputTokens = u.Output
	}
	if u.Total != nil {
		r.totalTokens = u.Total
	}
	if u.Model != "" {
		r.responseModel = u.Model
	}
}

// Flush persists the run + steps asynchronously and unregisters the recorder.
// status is the finalize status ("completed"/""/"failed"/"cancelled"/
// "awaiting_user"). Safe to call more than once; only the first wins in
// memory (DB upsert converges anyway).
func (r *RunRecorder) Flush(status, errCode, errMsg string, now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	if r.flushed {
		r.mu.Unlock()
		return
	}
	r.flushed = true
	r.closeThinkingLocked(now)

	runStatus := domagentrun.StatusCompleted
	switch status {
	case "failed":
		runStatus = domagentrun.StatusFailed
	case "cancelled":
		runStatus = domagentrun.StatusCancelled
	case "awaiting_user":
		runStatus = domagentrun.StatusAwaitingUser
	}

	// Close dangling tool steps with the run's terminal flavor; a2a_invoke
	// steps stay 'running' — the edge-terminal callback converges them.
	for _, st := range r.steps {
		if st.endedAt != nil || st.kind == domagentrun.StepA2AInvoke {
			continue
		}
		end := now
		st.endedAt = &end
		switch runStatus {
		case domagentrun.StatusCancelled:
			st.status = domagentrun.StepCancelled
		case domagentrun.StatusFailed:
			st.status = domagentrun.StepError
		default:
			st.status = domagentrun.StepOK
		}
	}

	spec := r.spec
	duration := int(now.Sub(r.startedAt) / time.Millisecond)
	if duration < 0 {
		duration = 0
	}
	run := &domagentrun.Run{
		TenantID:             spec.TenantID,
		DigitalEmployeeID:    spec.DigitalEmployeeID,
		ConversationUUID:     spec.ConversationUUID,
		MessageUUID:          spec.MessageUUID,
		StreamID:             spec.StreamID,
		RoomID:               spec.RoomID,
		RuntimeKind:          spec.RuntimeKind,
		RuntimeEnvironmentID: spec.RuntimeEnvironmentID,
		RuntimeInstanceID:    spec.RuntimeInstanceID,
		TriggerSource:        spec.TriggerSource,
		Status:               runStatus,
		StartedAt:            r.startedAt,
		CreatedAt:            r.createdAt,
		AgentVersionID:       spec.AgentVersionID,
		RootA2AEdgeUUID:      spec.RootA2AEdgeUUID,
		TraceID:              spec.TraceID,
		ToolCallCount:        r.toolCalls,
		ToolErrorCount:       r.toolErrors,
		A2AEdgeCount:         r.a2aEdges,
		ErrorCode:            errCode,
		ErrorMessage:         r.reg.redactText(errMsg),
		ExecutionLocus:       executionLocus(spec),
		RequestedModel:       spec.RequestedModel,
		ExecutedModel:        spec.ExecutedModel,
		ResponseModel:        r.responseModel,
		RetryIndex:           r.retryIndex,
		RetryReason:          r.retryReason,
		FallbackChain:        r.fallbackChain,
		// Display model prefers what we actually ran; the upstream echo is only a
		// fallback for runtimes that never told us which model was selected.
		Model:       firstNonEmpty(spec.ExecutedModel, r.responseModel, spec.RequestedModel),
		UsageSource: domagentrun.UsageSourceNone,
	}
	if spec.AgentVersion > 0 {
		run.Tags = map[string]any{"agent_version": spec.AgentVersion}
	}
	if spec.AccountID > 0 {
		acc := spec.AccountID
		run.AccountID = &acc
	}
	// awaiting_user runs also record completed_at/duration: execution ended at
	// the pause; completed_at doubles as the HITL-wait anchor for
	// CloseAwaitingRun (hitl_wait = respond - pause, excluded from duration).
	end := now
	run.CompletedAt = &end
	run.DurationMS = &duration
	if r.firstOutputAt != nil {
		f := int(r.firstOutputAt.Sub(r.startedAt) / time.Millisecond)
		run.FirstOutputMS = &f
	}
	if r.thinkingMS > 0 {
		t := r.thinkingMS
		run.ThinkingMS = &t
	}
	if r.totalTokens != nil || r.inputTokens != nil || r.outputTokens != nil {
		run.InputTokens, run.OutputTokens, run.TotalTokens = r.inputTokens, r.outputTokens, r.totalTokens
		run.UsageSource = domagentrun.UsageSourceRuntime
	}

	steps := make([]*domagentrun.Step, 0, len(r.steps))
	for _, st := range r.steps {
		s := &domagentrun.Step{
			TenantID:     spec.TenantID,
			Seq:          st.seq,
			Kind:         st.kind,
			Name:         st.name,
			Status:       st.status,
			StartedAt:    st.startedAt,
			EndedAt:      st.endedAt,
			RefKind:      st.refKind,
			RefUUID:      st.refUUID,
			ErrorMessage: r.reg.redactText(st.errMsg),
			Attrs:        st.attrs,
			CreatedAt:    r.createdAt,
		}
		if st.endedAt != nil {
			d := int(st.endedAt.Sub(st.startedAt) / time.Millisecond)
			if d < 0 {
				d = 0
			}
			s.DurationMS = &d
		}
		steps = append(steps, s)
	}
	r.mu.Unlock()

	r.reg.unregister(r)

	// Detached-context async write (F19 CallLogWriter precedent): the request
	// ctx is about to end; observability writes must never block or fail chat.
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	go func() {
		defer cancel()
		runUUID, err := r.reg.sink.UpsertRun(wctx, run)
		if err != nil {
			r.reg.logWarn("agentrun: upsert run failed", "stream_id", spec.StreamID, "message_uuid", spec.MessageUUID, "err", err)
			return
		}
		for _, s := range steps {
			s.RunUUID = runUUID
		}
		if err := r.reg.sink.UpsertSteps(wctx, steps); err != nil {
			r.reg.logWarn("agentrun: upsert steps failed", "run_uuid", runUUID, "err", err)
		}
	}()
}

// executionLocus fails closed to "cloud" only for paths that genuinely are cloud.
// A dispatch path that forgets to set it would otherwise silently mislabel local
// runs, which is exactly the defect this column exists to remove — so an unknown
// value is normalized here and the caller is expected to set it explicitly.
func executionLocus(spec RunSpec) string {
	if spec.ExecutionLocus == domagentrun.ExecutionLocusLocal {
		return domagentrun.ExecutionLocusLocal
	}
	return domagentrun.ExecutionLocusCloud
}
