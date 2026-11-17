package chat

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	skill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
)

// WireLocal lets employees that run on the caller's computer use the ordinary chat
// stream. The dispatcher carries no cloud runtime clients; local tasks never fall back
// to a cloud environment.
func WireLocal(chat svc.Service, pool *pgxpool.Pool, local *svclocal.Service, skills *skill.Service) {
	svc.SetLocalRuntimeOnService(chat, local)
	svc.SetIdentityResolverOnService(chat, identity{pool})
	dispatcher := svc.NewZapDispatcher(nil, nil, nil, nil)
	svc.SetZapSkillsCarrierOnDispatcher(dispatcher, skillsCarrier{skills})
	svc.SetZapDispatcherOnService(chat, dispatcher)
	svc.AttachZapDispatcherToService(chat, dispatcher)
}

// Preserve the original typed carrier while satisfying chat's narrow interface.
type skillsCarrier struct{ service *skill.Service }

func (a skillsCarrier) BuildZapSessionSkills(ctx context.Context, tenantID, accountID int64, agentUUID string) (any, error) {
	carrier, err := a.service.BuildZapSessionSkills(ctx, tenantID, accountID, agentUUID)
	if err != nil || carrier == nil {
		return nil, err
	}
	return carrier, nil
}

type identity struct{ pool *pgxpool.Pool }

func (i identity) ResolveTenantAccount(ctx context.Context, tenantID, accountID int64) (string, string, error) {
	var tenant, account string
	err := i.pool.QueryRow(ctx, `SELECT t.uuid::text, a.uuid::text FROM tenants t, accounts a WHERE t.id=$1 AND a.id=$2`, tenantID, accountID).Scan(&tenant, &account)
	if err != nil || tenant == "" || account == "" {
		return "", "", errors.New("identity unavailable")
	}
	return tenant, account, nil
}
