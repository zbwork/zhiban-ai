package chat

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
)

// WireLocal lets employees that run on the caller's computer use the ordinary chat
// stream. The dispatcher carries no cloud runtime clients; local tasks never fall back
// to a cloud environment.
func WireLocal(chat svc.Service, pool *pgxpool.Pool, local *svclocal.Service) {
	svc.SetLocalRuntimeOnService(chat, local)
	svc.SetIdentityResolverOnService(chat, identity{pool})
	dispatcher := svc.NewZapDispatcher(nil, nil, nil, nil)
	svc.SetZapDispatcherOnService(chat, dispatcher)
	svc.AttachZapDispatcherToService(chat, dispatcher)
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
