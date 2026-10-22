package apps

import (
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/app"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenant"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/app"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/composer"
)

func New(pool *pgxpool.Pool, issuer string) *svc.Service {
	return svc.New(svc.Deps{
		Apps: repo.NewAppRepo(pool), Settings: repo.NewTenantAppSettingRepo(pool), Bindings: repo.NewAgentAppBindingRepo(pool), OAuthClients: repo.NewOAuthClientRepo(pool), OAuthCodes: repo.NewOAuthCodeRepo(pool), RefreshTokens: repo.NewRefreshTokenRepo(pool), Categories: repo.NewCategoryRepo(pool), Conversations: conversation.New(pool), ConversationRooms: room.New(pool), Agents: agent.New(pool), Accounts: account.New(pool), Tenants: tenant.New(pool), DiscoveryBaseURL: issuer, Audit: composer.NewPGAuditPublisher(pool, event.New(pool)),
	})
}
