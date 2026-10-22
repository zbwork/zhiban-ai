// community-admin serves the community administrator API.
package main

import (
	"context"
	"errors"
	"flag"
	"github.com/redis/go-redis/v9"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/adminrouter"
	communityapps "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/apps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	account "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	audit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/authaudit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/communityresources"
	event "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	rbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/rbac"
	envrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/runtimeenv"
	session "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/session"
	tenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenant"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	authsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	communityagentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communityagent"
	deptsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/department"
	membersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	rbacsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/rbac"
	tenantsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/tenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminapps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminorg"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminsession"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/admintenant"
	agenthttp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/communityagent"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func run(ctx context.Context, path string) error {
	cfg, err := config.Load(path)
	if err != nil {
		return err
	}
	pem, err := os.ReadFile(cfg.JWTPrivateKeyFile)
	if err != nil {
		return errors.New("JWT private key cannot be read")
	}
	issuer, err := jwt.New(string(pem), "", cfg.JWTIssuer, 15*time.Minute)
	if err != nil {
		return errors.New("invalid JWT private key")
	}
	startup, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	pool, err := pgcli.New(startup, cfg.PostgresDSN, 10, 0)
	if err != nil {
		return errors.New("PostgreSQL unavailable")
	}
	defer pool.Close()
	redisClient := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr, Password: cfg.RedisPassword})
	defer redisClient.Close()
	if err = redisClient.Ping(startup).Err(); err != nil {
		return errors.New("Redis unavailable")
	}
	tenantRepo := tenant.New(pool)
	rbacRepo := rbac.New(pool)
	auth := authsvc.New(authsvc.Deps{Accounts: account.New(pool), Tenants: tenantRepo, RBAC: rbacRepo, Sessions: session.New(pool), AuditLog: audit.New(pool), Issuer: issuer, Captcha: captcha.New(redisClient), Revoke: authsvc.NewRedisRevoker(redisClient, 15*time.Minute), EventBus: authsvc.NewPgEventBus(pool)})
	pub := event.New(pool)
	tenantService := tenantsvc.New(tenantRepo, pool, pub, communityresources.Initialize(cfg.StorageQuotaBytes))
	tenantsvc.AllowExistingEmailAdmin(tenantService)
	handlers := adminrouter.Handlers{
		Agents:  &agenthttp.Handlers{Service: &communityagentsvc.Service{Agents: agentsvc.New(agentrepo.New(pool), nil, nil, pool, pub), Environments: envrepo.New(pool)}, Provider: cfg.Model.Provider, Model: cfg.Model.Name},
		Session: &adminsession.Handlers{Auth: auth, RBAC: rbacsvc.New(rbacRepo)},
		Org:     &adminorg.Handlers{Department: deptsvc.New(pool, pub), Membership: membersvc.New(pool, pub)},
		Tenant:  &admintenant.Handlers{Tenant: tenantService, AllowExistingEmailAdmin: true},
	}
	if cfg.AppIssuer != "" {
		handlers.Apps = &adminapps.Handlers{App: communityapps.New(pool, cfg.AppIssuer)}
	}
	mux := http.NewServeMux()
	handlers.Register(mux, middleware.Auth(issuer, auth, false))
	server := &http.Server{Addr: cfg.HTTP, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
}
func main() {
	path := flag.String("config", "configs/community/admin.yaml", "community configuration")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, *path); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
