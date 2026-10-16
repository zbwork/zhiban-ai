package deorch

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	edgedom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	orchdom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orchestration"
	a2asvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
)

// ───────────────────────── 领域输入/输出 ─────────────────────────

// MasterAgent 编排主控数字员工。
type MasterAgent struct {
	ID          int64
	UUID        string
	TenantID    int64 // A2A 准入 tenant isolation 用 (必填; 0 → fail-closed 拒)
	WorkspaceID *int64
}

// ChildAgent 成员数字员工 (已由调用方解析 + 校验 published/visible/非嵌套)。
type ChildAgent struct {
	ID                   int64
	UUID                 string
	Name                 string
	TenantID             int64 // A2A 准入 tenant isolation 用 (必填; 0 → fail-closed 拒)
	WorkspaceID          *int64
	CallableByAgentsJSON string // 用于 A2A 准入 (callable_by_agents)
}

// InvokeInput 单次 child 调用入参。
type InvokeInput struct {
	TenantID      int64
	AccountID     int64
	FromAgentUUID string
	EdgeUUID      string
	Agent         ChildAgent
	Prompt        string
}

// InvokeResult 单次 child 调用结果 (Text = child assistant 最终文本)。
type InvokeResult struct {
	Text      string
	TokensIn  int32
	TokensOut int32
}

// CallTrace 是一次 child 调用的低敏摘要, 供聊天层投影为 tool_call/tool_result。
// 不包含 request/response payload、endpoint、token 或 runtime key。
type CallTrace struct {
	EdgeUUID     string
	AgentUUID    string
	AgentName    string
	Status       edgedom.Status
	ErrorSummary string
	Attempts     int
}

// AgentInvoker 真实调用一个 child 数字员工并取最终文本 (E5)。
// chat 包提供复用现有 OpenClaw 链路的同步实现; 单测用 fake。**不**写用户可见会话/消息。
type AgentInvoker interface {
	Invoke(ctx context.Context, in InvokeInput) (InvokeResult, error)
}

// AdmissionChecker A2A 准入: 主控 → child 调用是否被 child 的 inbound 白名单允许 (E3, fail-closed)。
type AdmissionChecker interface {
	Admit(ctx context.Context, from MasterAgent, to ChildAgent) (allowed bool, reason string)
}

// Planner manager 策略的成员选择 (E4)。MVP = AllChildrenPlanner (返回全部);
// 预留接口供后续替换为 LLM planner。
type Planner interface {
	Plan(ctx context.Context, master MasterAgent, children []ChildAgent, prompt string) ([]ChildAgent, error)
}

// AllChildrenPlanner MVP planner: 按配置顺序返回全部 child (不做 LLM 路由)。
type AllChildrenPlanner struct{}

func (AllChildrenPlanner) Plan(_ context.Context, _ MasterAgent, children []ChildAgent, _ string) ([]ChildAgent, error) {
	return children, nil
}

// WhitelistAdmission 默认 A2A 准入: 用 child 的 callable_by_agents 4-mode 白名单 (复用 a2a.EvaluateWhitelist)。
type WhitelistAdmission struct{}

func (WhitelistAdmission) Admit(_ context.Context, from MasterAgent, to ChildAgent) (bool, string) {
	pol := a2asvc.ParseCallablePolicy(to.CallableByAgentsJSON)
	ok := a2asvc.EvaluateWhitelist(a2asvc.WhitelistInput{
		FromAgentID:      from.UUID,
		FromAgentWorkspc: from.WorkspaceID,
		ToAgentID:        to.UUID,
		ToAgentWorkspc:   to.WorkspaceID,
		ToCallable:       pol,
	})
	if !ok {
		return false, "callable_whitelist"
	}
	return true, ""
}

// ───────────────────────── 窄仓储接口 (orchestration / a2a edge 的子集) ─────────────────────────

// RunStore = orchestration.Repository 子集 (deorch 只用这几个)。真实 repo 天然满足。
type RunStore interface {
	Create(ctx context.Context, in orchdom.CreateInput) (*orchdom.Orchestration, error)
	UpdateStatus(ctx context.Context, tenantID int64, uuid string, in orchdom.UpdateStatusInput) (*orchdom.Orchestration, error)
	CreateStep(ctx context.Context, in orchdom.CreateStepInput) (*orchdom.Step, error)
	UpdateStep(ctx context.Context, stepUUID string, in orchdom.UpdateStepInput) (*orchdom.Step, error)
}

// EdgeStore = a2acalledge.Repository 子集。
type EdgeStore interface {
	Insert(ctx context.Context, in edgedom.InsertInput) (*edgedom.Edge, error)
	UpdateStatus(ctx context.Context, tenantID int64, uuid string, createdAt time.Time, in edgedom.UpdateStatusInput) (*edgedom.Edge, error)
}

// ───────────────────────── Executor ─────────────────────────

// Logger 最小日志接口 (避免强依赖具体 logger)。
type Logger interface {
	Warn(ctx context.Context, msg string, kv ...any)
}

type noopLogger struct{}

func (noopLogger) Warn(context.Context, string, ...any) {}

// Executor 编排运行期执行器。
type Executor struct {
	runs       RunStore
	edges      EdgeStore
	invoker    AgentInvoker
	admission  AdmissionChecker
	planner    Planner
	timeBudget time.Duration
	logger     Logger
}

// NewExecutor 装配执行器。admission/planner 为 nil 时用默认 (WhitelistAdmission / AllChildrenPlanner)。
func NewExecutor(runs RunStore, edges EdgeStore, invoker AgentInvoker, admission AdmissionChecker, planner Planner, timeBudget time.Duration, logger Logger) *Executor {
	if admission == nil {
		admission = WhitelistAdmission{}
	}
	if planner == nil {
		planner = AllChildrenPlanner{}
	}
	if timeBudget <= 0 {
		timeBudget = 60 * time.Second
	}
	if logger == nil {
		logger = noopLogger{}
	}
	return &Executor{runs: runs, edges: edges, invoker: invoker, admission: admission, planner: planner, timeBudget: timeBudget, logger: logger}
}

// RunInput 一次编排运行 (= 用户对编排型数字员工发一条消息)。
type RunInput struct {
	TenantID  int64
	AccountID int64
	Master    MasterAgent
	Children  []ChildAgent
	Strategy  Strategy
	Prompt    string
}

// RunResult 编排结果。FinalText 是回给用户的最终回复 (用户可见安全, 无内部码);
// Status=failed 且 FinalText 为空时, 调用方应以通用失败收尾消息。
type RunResult struct {
	OrchestrationUUID string
	FinalText         string
	Status            orchdom.Status
	Calls             []CallTrace
}

// childOutcome 单 child 执行结果 (内部)。
type childOutcome struct {
	child    ChildAgent
	ok       bool
	text     string
	status   edgedom.Status // done / failed / dropped_whitelist
	reason   string         // 内部原因 (不下发客户端)
	edgeUUID string
	attempts int
}

const (
	childInvokeMaxAttempts  = 3
	childInvokeRetryBackoff = 80 * time.Millisecond
)

// Run 创建 orchestration run, 按 strategy 调度 children, 写 step/edge trace, reduce 出最终回复。
func (e *Executor) Run(ctx context.Context, in RunInput) (RunResult, error) {
	if len(in.Children) == 0 {
		return RunResult{}, ErrNoChildren
	}
	if !in.Strategy.valid() {
		return RunResult{}, ErrBadStrategy
	}

	createdBy := in.AccountID
	run, err := e.runs.Create(ctx, orchdom.CreateInput{
		TenantID:      in.TenantID,
		MasterAgentID: in.Master.ID,
		CreatedBy:     &createdBy,
	})
	if err != nil {
		return RunResult{}, fmt.Errorf("deorch: create orchestration: %w", err)
	}
	now := time.Now()
	running := orchdom.StatusRunning
	_, _ = e.runs.UpdateStatus(ctx, in.TenantID, run.UUID, orchdom.UpdateStatusInput{
		Status: &running, StartedAt: &now, PlanSummary: strPtr(string(in.Strategy)),
	})

	runCtx, cancel := context.WithTimeout(ctx, e.timeBudget)
	defer cancel()

	var outcomes []childOutcome
	switch in.Strategy {
	case StrategySequential:
		outcomes = e.runSequential(runCtx, in, run)
	case StrategyParallel:
		outcomes = e.runParallel(runCtx, in, run)
	case StrategyManager:
		outcomes = e.runManager(runCtx, in, run)
	}

	finalText, status := reduce(in.Strategy, outcomes)
	completed := time.Now()
	finalStatus := status
	_, _ = e.runs.UpdateStatus(ctx, in.TenantID, run.UUID, orchdom.UpdateStatusInput{
		Status: &finalStatus, CompletedAt: &completed, FinalSummary: strPtr(trunc(finalText, 2000)),
		EdgesCount: int32Ptr(int32(len(outcomes))),
	})
	return RunResult{OrchestrationUUID: run.UUID, FinalText: finalText, Status: status, Calls: callTraces(outcomes)}, nil
}

// runSequential 顺序协作: child[i] 输入 = 原始问题 + 之前输出摘要; 任一失败/拒绝 → 链断, run failed。
func (e *Executor) runSequential(ctx context.Context, in RunInput, run *orchdom.Orchestration) []childOutcome {
	outcomes := make([]childOutcome, 0, len(in.Children))
	accumulated := ""
	for i, child := range in.Children {
		prompt := in.Prompt
		if accumulated != "" {
			prompt = in.Prompt + "\n\n[上一环节产出]\n" + accumulated
		}
		oc := e.invokeChild(ctx, in, run, int16(i), child, prompt)
		outcomes = append(outcomes, oc)
		if !oc.ok {
			break // 顺序协作: 关键环节失败 → 链断 (后续 child 不再调用)
		}
		accumulated = oc.text
	}
	return outcomes
}

// runParallel 并行协作: 并发调用全部 child (原始问题); 单个失败不整体失败。
func (e *Executor) runParallel(ctx context.Context, in RunInput, run *orchdom.Orchestration) []childOutcome {
	outcomes := make([]childOutcome, len(in.Children))
	var wg sync.WaitGroup
	for i, child := range in.Children {
		wg.Add(1)
		go func(idx int, c ChildAgent) {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					outcomes[idx] = childOutcome{child: c, ok: false, status: edgedom.StatusFailed, reason: "panic"}
				}
			}()
			outcomes[idx] = e.invokeChild(ctx, in, run, int16(idx), c, in.Prompt)
		}(i, child)
	}
	wg.Wait()
	return outcomes
}

// runManager 主控调度: Planner 选成员 (MVP=全部), 各自独立调用 (原始问题), reducer 汇总。
func (e *Executor) runManager(ctx context.Context, in RunInput, run *orchdom.Orchestration) []childOutcome {
	planned, err := e.planner.Plan(ctx, in.Master, in.Children, in.Prompt)
	if err != nil {
		e.logger.Warn(ctx, "deorch manager planner failed; falling back to all children", "err", err.Error())
		planned = in.Children
	}
	outcomes := make([]childOutcome, 0, len(planned))
	for i, child := range planned {
		outcomes = append(outcomes, e.invokeChild(ctx, in, run, int16(i), child, in.Prompt))
	}
	return outcomes
}

// admissionDropStatus 把准入拒绝原因映射到 a2a_call_edges 终态:
// 配额类 → dropped_budget; 其余 (自调/跨租户/缺 capability/白名单) → dropped_whitelist。
func admissionDropStatus(reason string) edgedom.Status {
	switch reason {
	case "rate_limited", "quota_error":
		return edgedom.StatusDroppedBudget
	default:
		return edgedom.StatusDroppedWhitelist
	}
}

// invokeChild 单 child 全流程: A2A 准入 → 建 edge/step → 调用 → 写终态。fail-closed。
//
// trace 纪律 (P2 返修): **不允许无 trace 调用 child**。edge 插入失败 / step 创建失败 → child 直接
// failed, **不调用** invoker (否则会出现"真实调用了 child 但 a2a_call_edges/step 没有记录"的审计黑洞)。
func (e *Executor) invokeChild(ctx context.Context, in RunInput, run *orchdom.Orchestration, idx int16, child ChildAgent, prompt string) childOutcome {
	// 1) A2A 准入 (validation-only, fail-closed)。
	allowed, reason := e.admission.Admit(ctx, in.Master, child)

	// 2) 先落 edge trace。插入失败 → fail-closed: 写一条 failed step (best-effort) 后**不调用** child。
	edge, edgeErr := e.insertEdge(ctx, in, run, child)
	if edgeErr != nil || edge == nil {
		e.logger.Warn(ctx, "deorch: a2a edge insert failed; skip child invoke (fail-closed, no untraced call)", "child", child.UUID)
		e.writeStep(ctx, in, run, idx, child, nil, orchdom.StepFailed, "", "trace_edge_insert_failed")
		return childOutcome{child: child, ok: false, status: edgedom.StatusFailed, reason: "trace_edge_insert_failed"}
	}

	if !allowed {
		st := admissionDropStatus(reason)
		e.finishEdge(ctx, in.TenantID, edge, st, "a2a_"+reason, 0, 0)
		e.writeStep(ctx, in, run, idx, child, edge, orchdom.StepSkipped, "", "a2a_"+reason)
		return childOutcome{child: child, ok: false, status: st, reason: "a2a_" + reason, edgeUUID: edge.UUID}
	}

	// 3) 起 step trace。创建失败 → fail-closed: 把 edge 标 failed 后**不调用** child。
	step := e.startStep(ctx, in, run, idx, child, edge, prompt)
	if step == nil {
		e.logger.Warn(ctx, "deorch: orchestration step create failed; skip child invoke (fail-closed, no untraced call)", "child", child.UUID)
		e.finishEdge(ctx, in.TenantID, edge, edgedom.StatusFailed, "trace_step_create_failed", 0, 0)
		return childOutcome{child: child, ok: false, status: edgedom.StatusFailed, reason: "trace_step_create_failed", edgeUUID: edge.UUID}
	}
	e.markEdge(ctx, in.TenantID, edge, edgedom.StatusRunning)

	res, attempts, err := e.invokeWithRetry(ctx, InvokeInput{
		TenantID: in.TenantID, AccountID: in.AccountID, FromAgentUUID: in.Master.UUID,
		EdgeUUID: edge.UUID, Agent: child, Prompt: prompt,
	})
	if err != nil {
		emsg := trunc(err.Error(), 512)
		e.logger.Warn(ctx, "deorch child invoke failed",
			"master", in.Master.UUID,
			"child", child.UUID,
			"edge_id", edge.UUID,
			"attempts", attempts,
			"err", emsg)
		e.finishEdge(ctx, in.TenantID, edge, edgedom.StatusFailed, emsg, 0, 0)
		e.finishStep(ctx, step, orchdom.StepFailed, "", emsg)
		return childOutcome{child: child, ok: false, status: edgedom.StatusFailed, reason: visibleFailureSummary(attempts), edgeUUID: edge.UUID, attempts: attempts}
	}
	e.finishEdge(ctx, in.TenantID, edge, edgedom.StatusDone, "", res.TokensIn, res.TokensOut)
	e.finishStep(ctx, step, orchdom.StepDone, trunc(res.Text, 2000), "")
	return childOutcome{child: child, ok: true, text: res.Text, status: edgedom.StatusDone, edgeUUID: edge.UUID, attempts: attempts}
}

func (e *Executor) invokeWithRetry(ctx context.Context, in InvokeInput) (InvokeResult, int, error) {
	var lastErr error
	for attempt := 1; attempt <= childInvokeMaxAttempts; attempt++ {
		res, err := e.invoker.Invoke(ctx, in)
		if err == nil {
			return res, attempt, nil
		}
		lastErr = err
		if attempt >= childInvokeMaxAttempts || ctx.Err() != nil {
			return InvokeResult{}, attempt, lastErr
		}
		e.logger.Warn(ctx, "deorch child invoke attempt failed; retrying",
			"child", in.Agent.UUID,
			"edge_id", in.EdgeUUID,
			"attempt", attempt,
			"err", trunc(err.Error(), 256))
		timer := time.NewTimer(childInvokeRetryBackoff * time.Duration(attempt))
		select {
		case <-ctx.Done():
			timer.Stop()
			return InvokeResult{}, attempt, ctx.Err()
		case <-timer.C:
		}
	}
	return InvokeResult{}, childInvokeMaxAttempts, lastErr
}

// ───────────────────────── trace 写入 helpers (best-effort; trace 失败不阻断编排) ─────────────────────────

// insertEdge 插一条 master→child 的 a2a_call_edges (status=pending)。
// 返回 error 让 invokeChild 在写失败时 fail-closed (不调用 child)。
func (e *Executor) insertEdge(ctx context.Context, in RunInput, run *orchdom.Orchestration, child ChildAgent) (*edgedom.Edge, error) {
	createdBy := in.AccountID
	runID := run.ID
	edge, err := e.edges.Insert(ctx, edgedom.InsertInput{
		TenantID:        in.TenantID,
		FromAgentID:     in.Master.ID,
		ToAgentID:       child.ID,
		OrchestrationID: &runID,
		Depth:           1,
		IdemKey:         fmt.Sprintf("orch-%s-%d", run.UUID, child.ID),
		InvokeKind:      edgedom.InvokeSync,
		CreatedBy:       &createdBy,
	})
	if err != nil {
		e.logger.Warn(ctx, "deorch insert a2a edge failed", "child", child.UUID, "err", err.Error())
		return nil, err
	}
	return edge, nil
}

func (e *Executor) markEdge(ctx context.Context, tenantID int64, edge *edgedom.Edge, st edgedom.Status) {
	if edge == nil {
		return
	}
	now := time.Now()
	_, _ = e.edges.UpdateStatus(ctx, tenantID, edge.UUID, edge.CreatedAt, edgedom.UpdateStatusInput{Status: &st, StartedAt: &now})
}

func (e *Executor) finishEdge(ctx context.Context, tenantID int64, edge *edgedom.Edge, st edgedom.Status, errMsg string, tin, tout int32) {
	if edge == nil {
		return
	}
	now := time.Now()
	in := edgedom.UpdateStatusInput{Status: &st, CompletedAt: &now}
	if errMsg != "" {
		in.ErrorMessage = &errMsg
	}
	if tin > 0 {
		in.TokensIn = &tin
	}
	if tout > 0 {
		in.TokensOut = &tout
	}
	_, _ = e.edges.UpdateStatus(ctx, tenantID, edge.UUID, edge.CreatedAt, in)
}

func (e *Executor) writeStep(ctx context.Context, in RunInput, run *orchdom.Orchestration, idx int16, child ChildAgent, edge *edgedom.Edge, status orchdom.StepStatus, output, errMsg string) {
	step := e.startStep(ctx, in, run, idx, child, edge, "")
	e.finishStep(ctx, step, status, output, errMsg)
}

func (e *Executor) startStep(ctx context.Context, in RunInput, run *orchdom.Orchestration, idx int16, child ChildAgent, edge *edgedom.Edge, prompt string) *orchdom.Step {
	createdBy := in.AccountID
	worker := child.ID
	csi := orchdom.CreateStepInput{
		OrchestrationID: run.ID,
		StepIndex:       idx,
		Role:            orchdom.RoleWorker,
		WorkerAgentID:   &worker,
		InputSummary:    trunc(prompt, 2000),
		CreatedBy:       &createdBy,
	}
	if edge != nil {
		csi.CallEdgeID = &edge.ID
	}
	step, err := e.runs.CreateStep(ctx, csi)
	if err != nil {
		e.logger.Warn(ctx, "deorch create step failed", "child", child.UUID, "err", err.Error())
		return nil
	}
	return step
}

func (e *Executor) finishStep(ctx context.Context, step *orchdom.Step, status orchdom.StepStatus, output, errMsg string) {
	if step == nil {
		return
	}
	now := time.Now()
	in := orchdom.UpdateStepInput{Status: &status, CompletedAt: &now}
	if output != "" {
		in.OutputSummary = &output
	}
	if errMsg != "" {
		in.ErrorMessage = &errMsg
	}
	_, _ = e.runs.UpdateStep(ctx, step.UUID, in)
}

// ───────────────────────── reducer (E4, MVP 无 LLM) ─────────────────────────

// reduce 把各 child 结果合并为最终回复 + run 终态。
//   - sequential: 链断 (任一失败/拒绝) → failed; 否则取最后一环输出。
//   - parallel/manager: 至少一个成功 → done, 拼接成功成员输出 + 标注不可用成员; 全失败 → failed。
func reduce(strategy Strategy, outcomes []childOutcome) (string, orchdom.Status) {
	if len(outcomes) == 0 {
		return "", orchdom.StatusFailed
	}
	if strategy == StrategySequential {
		last := outcomes[len(outcomes)-1]
		// 链中任一不 ok → 整 run failed (顺序协作每环都关键)。
		for _, oc := range outcomes {
			if !oc.ok {
				return failureFinalText(outcomes), orchdom.StatusFailed
			}
		}
		return last.text, orchdom.StatusDone
	}
	// manager / parallel
	var b strings.Builder
	okCount := 0
	var unavailable []string
	for _, oc := range outcomes {
		if oc.ok {
			okCount++
			name := oc.child.Name
			if name == "" {
				name = "成员"
			}
			if b.Len() > 0 {
				b.WriteString("\n\n")
			}
			b.WriteString("【" + name + "】\n" + oc.text)
		} else {
			name := oc.child.Name
			if name == "" {
				name = "成员"
			}
			unavailable = append(unavailable, name)
		}
	}
	if okCount == 0 {
		return failureFinalText(outcomes), orchdom.StatusFailed
	}
	if len(unavailable) > 0 {
		b.WriteString("\n\n（部分成员本次不可用：" + strings.Join(unavailable, "、") + "）")
	}
	return b.String(), orchdom.StatusDone
}

func failureFinalText(outcomes []childOutcome) string {
	names := make([]string, 0, len(outcomes))
	for _, oc := range outcomes {
		name := strings.TrimSpace(oc.child.Name)
		if name == "" {
			name = "协作数字员工"
		}
		names = append(names, name)
	}
	if len(names) == 0 {
		return "协作调用未能完成，请稍后重试。"
	}
	return "协作调用未能完成：" + strings.Join(names, "、") + " 本次不可用。请稍后重试，或检查对应数字员工的运行环境与协作权限。"
}

func callTraces(outcomes []childOutcome) []CallTrace {
	out := make([]CallTrace, 0, len(outcomes))
	for _, oc := range outcomes {
		if oc.edgeUUID == "" {
			continue
		}
		out = append(out, CallTrace{
			EdgeUUID:     oc.edgeUUID,
			AgentUUID:    oc.child.UUID,
			AgentName:    oc.child.Name,
			Status:       oc.status,
			ErrorSummary: oc.reason,
			Attempts:     oc.attempts,
		})
	}
	return out
}

func visibleFailureSummary(attempts int) string {
	if attempts > 1 {
		return fmt.Sprintf("已重试 %d 次仍未完成", attempts-1)
	}
	return "本次协作未完成"
}

func strPtr(s string) *string { return &s }
func int32Ptr(v int32) *int32 { return &v }

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
