package chat

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model/openai"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/llm"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/mock"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/chattx"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/message"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/messagestream"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/runtimeenv"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
)

// Compose wires real persistence, Redis fanout and cancellation. Queue is disabled
// until a community chat task consumer is explicitly configured.
func Compose(ctx context.Context, pool *pgxpool.Pool, rdb *redis.Client, c config.Config, visibility svc.ContactsVisibility) (svc.Service, error) {
	logger := log.Default()
	service := svc.NewWithStopRetry(logger, agent.New(pool), conversation.New(pool), message.New(pool), nil, visibility, nil, nil, svc.NewRedisFanout(rdb, logger), "community-"+uuid.NewString(), svc.StopRetryDeps{StreamStore: messagestream.New(pool), EventPub: event.New(pool), TxBegin: chattx.Beginner(pool)})
	svc.SetRuntimeEnvFrameworkLookupOnService(service, frameworkLookup{runtimeenv.New(pool)})
	switch c.Model.Provider {
	case "mock":
		svc.SetGenericRuntime(service, &skillRuntime{Adapter: mock.New(), skills: NewSkills(pool)})
	case "openai-compatible":
		if c.Model.APIKey == "" {
			return nil, errors.New("model API key required")
		}
		svc.SetGenericRuntime(service, &skillRuntime{Adapter: llm.New(openai.New(c.Model.BaseURL, c.Model.APIKey, c.Model.Name, 120)), skills: NewSkills(pool)})
	default:
		return nil, errors.New("unsupported model provider")
	}
	service.StartCancelListener(ctx)
	return service, nil
}

type frameworkLookup struct{ repo *runtimeenv.Repo }

func (f frameworkLookup) GetFrameworkByID(ctx context.Context, id int64) (string, error) {
	env, err := f.repo.GetByID(ctx, id)
	if err != nil {
		return "", err
	}
	if env == nil || env.Framework != svc.FrameworkGeneric || env.HostingKind != "embedded" || !env.Enabled || env.Status != "active" || env.IsDeleted {
		return "", errors.New("community requires generic runtime")
	}
	return env.Framework, nil
}

// NewFrameworkLookup enforces the same embedded runtime boundary for chat and cron.
func NewFrameworkLookup(pool *pgxpool.Pool) frameworkLookup {
	return frameworkLookup{runtimeenv.New(pool)}
}
