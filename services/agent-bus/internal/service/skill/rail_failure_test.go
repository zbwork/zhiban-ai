package skill

import (
	"context"
	"errors"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"testing"
)

type unavailableDisablesRepo struct{ dom.Repository }

func (unavailableDisablesRepo) ListAgentBindings(context.Context, int64) ([]dom.AgentBinding, error) {
	return nil, nil
}
func (unavailableDisablesRepo) ListUserOverrides(context.Context, int64, int64) ([]dom.UserOverride, error) {
	return nil, nil
}

func (unavailableDisablesRepo) ListTenantDisables(context.Context, int64) ([]dom.TenantDisable, error) {
	return nil, errors.New("disable store unavailable")
}

type railFailureAgentLookup struct{}

func (railFailureAgentLookup) GetAgentByUUID(context.Context, string) (*AgentInfo, error) {
	return &AgentInfo{ID: 100, UUID: "de-uuid", TenantID: 5, CreatorID: 21}, nil
}

func TestSkillRailFailsClosedOnDisableStoreFailure(t *testing.T) {
	svc := NewWithAgents(unavailableDisablesRepo{}, railFailureAgentLookup{})
	rail, err := svc.GetSkillRail(context.Background(), dom.GetSkillRailInput{TenantID: 5, AccountID: 21, AgentUUID: "de-uuid"})
	if err == nil || rail != nil {
		t.Fatalf("rail=%+v err=%v", rail, err)
	}
}
