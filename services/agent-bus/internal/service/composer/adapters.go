// adapters.go — wiring 用的轻量适配器, 把现有 svcagent / conversation repo 接到
// composer.AgentLookup / ConversationLookup.
//
// 单独一个文件是因为这些适配器不应该污染 composer 主逻辑.
package composer

import (
	"context"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
)

// AgentRepoAdapter 把 domagent.Repository (GetByID / GetByUUID) 包成 composer.AgentLookup.
type AgentRepoAdapter struct {
	Repo domagent.Repository
}

func (a *AgentRepoAdapter) GetByID(ctx context.Context, id int64) (*AgentInfo, error) {
	e, err := a.Repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	return toAgentInfo(e), nil
}

func (a *AgentRepoAdapter) GetByUUID(ctx context.Context, uuid string) (*AgentInfo, error) {
	e, err := a.Repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	return toAgentInfo(e), nil
}

func toAgentInfo(e *domagent.DigitalEmployee) *AgentInfo {
	if e == nil {
		return nil
	}
	tags := append([]string(nil), e.Tags...)
	return &AgentInfo{
		ID:       e.ID,
		UUID:     e.UUID,
		TenantID: e.TenantID,
		Source:   e.Source,
		Name:     e.Name,
		// F02 v0.3: agent.integration_mode 列已删, scope+hosting_kind 由 env 决定;
		// composer 暂未做 env DI, 默认按 platform_managed 走 (最常见路径)。env-aware
		// 派生待后续接 runtime_environments 表后启用。

		ModelPrimary:         e.ModelPrimary,
		Tags:                 tags,
		RuntimeEnvironmentID: e.RuntimeEnvironmentID,
	}
}

// ConvRepoAdapter 把 domconv.Repository (GetByUUID) 包成 composer.ConversationLookup.
type ConvRepoAdapter struct {
	Repo domconv.Repository
}

func (c *ConvRepoAdapter) GetByUUID(ctx context.Context, uuid string) (*ConvInfo, error) {
	x, err := c.Repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	return &ConvInfo{
		UUID:              x.UUID,
		TenantID:          x.TenantID,
		AccountID:         x.AccountID,
		DigitalEmployeeID: x.DigitalEmployeeID,
		RoomID:            x.RoomID,
	}, nil
}
