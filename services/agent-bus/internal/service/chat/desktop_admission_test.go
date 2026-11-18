package chat

import (
	"context"
	"reflect"
	"testing"
	"time"

	edge "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	orch "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orchestration"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/deorch"
)

func TestDesktopOrchestrationChecksRevokedTargetBeforeNextStep(t *testing.T) {
	employees := orchestrationAgents{employees: map[string]*domagent.DigitalEmployee{
		"master": {ID: 1, UUID: "master", TenantID: 10, Status: "published", ExecutionLocus: "local", Metadata: map[string]any{"agent_kind": deorch.AgentKindOrchestrator}},
		"first":  {ID: 2, UUID: "first", TenantID: 10, Status: "published", ExecutionLocus: "local", CallableByAgentsJSON: `{"mode":"all"}`},
		"second": {ID: 3, UUID: "second", TenantID: 10, Status: "published", ExecutionLocus: "local", CallableByAgentsJSON: `{"mode":"all"}`},
	}}
	svc := &impl{agents: employees, visibility: orchestrationVisibility{}}
	edges := &orchestrationEdges{}
	invoker := &orchestrationChildInvoker{employees: employees.employees}
	executor := deorch.NewExecutor(orchestrationRuns{}, edges, invoker, deorch.A2AAdmission{Capabilities: orchestrationCapability{}}, nil, time.Second, nil)
	out, err := executor.Run(context.Background(), deorch.RunInput{
		TenantID: 10, AccountID: 20,
		Master: deorch.MasterAgent{ID: 1, UUID: "master", TenantID: 10},
		Children: []deorch.ChildAgent{
			{ID: 2, UUID: "first", TenantID: 10, CallableByAgentsJSON: `{"mode":"all"}`},
			{ID: 3, UUID: "second", TenantID: 10, CallableByAgentsJSON: `{"mode":"all"}`},
		},
		Strategy: deorch.StrategySequential,
		Desktop:  deorch.DesktopTarget{Device: "test-desktop"},
		RefreshAdmission: func(ctx context.Context, master deorch.MasterAgent, child deorch.ChildAgent) (deorch.MasterAgent, deorch.ChildAgent, error) {
			return svc.refreshDesktopAdmission(ctx, 20, master, child)
		},
	})
	if err != nil || out.Status != orch.StatusFailed {
		t.Fatalf("want failed run, got %+v, %v", out, err)
	}
	if want := []string{"first"}; !reflect.DeepEqual(invoker.calls, want) {
		t.Fatalf("invoked %v, want %v", invoker.calls, want)
	}
	if len(out.Calls) != 2 || out.Calls[1].Status != edge.StatusDroppedWhitelist {
		t.Fatalf("second step has no rejection trace: %+v", out.Calls)
	}
}

type orchestrationAgents struct {
	domagent.Repository
	employees map[string]*domagent.DigitalEmployee
}

func (a orchestrationAgents) GetByUUID(_ context.Context, id string) (*domagent.DigitalEmployee, error) {
	return a.employees[id], nil
}

type orchestrationVisibility struct{ ContactsVisibility }

func (orchestrationVisibility) AssertAgentVisible(context.Context, int64, int64, string) error {
	return nil
}

type orchestrationCapability struct{}

func (orchestrationCapability) HasA2AInvokeCapability(context.Context, int64) (bool, error) {
	return true, nil
}

type orchestrationRuns struct{}

func (orchestrationRuns) Create(context.Context, orch.CreateInput) (*orch.Orchestration, error) {
	return &orch.Orchestration{UUID: "run"}, nil
}
func (orchestrationRuns) UpdateStatus(context.Context, int64, string, orch.UpdateStatusInput) (*orch.Orchestration, error) {
	return nil, nil
}
func (orchestrationRuns) CreateStep(context.Context, orch.CreateStepInput) (*orch.Step, error) {
	return &orch.Step{UUID: "step"}, nil
}
func (orchestrationRuns) UpdateStep(context.Context, string, orch.UpdateStepInput) (*orch.Step, error) {
	return nil, nil
}

type orchestrationEdges struct{}

func (*orchestrationEdges) Insert(_ context.Context, in edge.InsertInput) (*edge.Edge, error) {
	return &edge.Edge{UUID: in.IdemKey}, nil
}
func (*orchestrationEdges) UpdateStatus(context.Context, int64, string, time.Time, edge.UpdateStatusInput) (*edge.Edge, error) {
	return nil, nil
}

type orchestrationChildInvoker struct {
	employees map[string]*domagent.DigitalEmployee
	calls     []string
}

func (i *orchestrationChildInvoker) Invoke(_ context.Context, in deorch.InvokeInput) (deorch.InvokeResult, error) {
	i.calls = append(i.calls, in.Agent.UUID)
	if in.Agent.UUID == "first" {
		i.employees["second"].CallableByAgentsJSON = `{"mode":"none"}`
	}
	return deorch.InvokeResult{Text: "completed"}, nil
}
