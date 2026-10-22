package skill

import (
	"context"
	"errors"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"testing"
)

type unavailableDisablesRepo struct{ *zapRailRepo }

func (unavailableDisablesRepo) ListTenantDisables(context.Context, int64) ([]dom.TenantDisable, error) {
	return nil, errors.New("disable store unavailable")
}
func TestSkillRailFailsClosedOnDisableStoreFailure(t *testing.T) {
	svc, repo := newZapCarrierFixture(t)
	svc.repo = unavailableDisablesRepo{repo}
	rail, err := svc.GetSkillRail(context.Background(), dom.GetSkillRailInput{TenantID: 5, AccountID: 21, AgentUUID: "de-uuid"})
	if err == nil || rail != nil {
		t.Fatalf("rail=%+v err=%v", rail, err)
	}
}
