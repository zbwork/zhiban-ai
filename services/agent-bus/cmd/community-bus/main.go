// community-bus serves the community client API.
package main

import (
	"context"
	"errors"
	"flag"
	"github.com/redis/go-redis/v9"
	communityapps "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/apps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/busrouter"
	communitychat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	communitycron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/cron"
	communitydrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/drive"
	communityim "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/im"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	oauthjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
	oauthkeys "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/keys"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/secretbox"
	account "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	agentkbrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agentkb"
	audit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/authaudit"
	convrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	staterepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/convstate"
	driverepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	eventrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	kbrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
	msgrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/message"
	rbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/rbac"
	envrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/runtimeenv"
	session "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/session"
	tenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenant"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	authsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	personal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/communityagent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contacts"
	cronsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	drivesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider/stub"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientapps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientchat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcontacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcron"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientknowledge"
	httpsession "github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/session"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wellknown"
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
	storage, err := communitydrive.NewStorage(cfg)
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
	contactsSvc := contacts.New(pool)
	chatSvc, err := communitychat.Compose(ctx, pool, redisClient, cfg, contactsSvc)
	if err != nil {
		return err
	}
	defer chatSvc.StopCancelListener()
	handlers := busrouter.Handlers{Session: &httpsession.Handlers{Auth: auth}, Chat: &clientchat.Handlers{Chat: chatSvc}, Contacts: &clientcontacts.Handlers{Contacts: contactsSvc}}
	handlers.Agents = &clientcatalog.AgentHandlers{Agents: agentrepo.New(pool), Personal: &personal.Personal{Agents: agentsvc.New(agentrepo.New(pool), nil, nil, pool, eventrepo.New(pool)), Environments: envrepo.New(pool)}}
	handlers.Catalog = &clientcatalog.Handlers{Skill: communitychat.NewSkills(pool)}
	handlers.Agents.Skills = handlers.Catalog.Skill
	cronService := communitycron.Compose(ctx, pool, chatSvc, contactsSvc, communityim.DirectConversations(pool, cfg, contactsSvc))
	handlers.Cron = &clientcron.Handlers{Cron: cronService}
	cronCtx, stopCron := context.WithCancel(ctx)
	cronDone := make(chan struct{})
	go func() { defer close(cronDone); cronsvc.NewLoop(cronService, 5*time.Second).Run(cronCtx) }()
	defer func() { stopCron(); <-cronDone }()
	var driveLookup svckb.DriveFileLookup
	if storage != nil {
		driveLookup = drivesvc.NewKBSnapshotAdapter(drivesvc.NewSnapshotSvc(pool, driverepo.NewSpaceRepo(pool), driverepo.NewFolderRepo(pool), driverepo.NewFileRepo(pool), drivesvc.NewACLService(pool), storage))
	}
	handlers.KnowledgeAPI = &clientknowledge.Handlers{Knowledge: svckb.New(svckb.Deps{Repo: kbrepo.New(pool), Pool: pool, Audit: eventrepo.New(pool), Provider: stub.New(pool), Config: svckb.Config{PersistOriginals: true, ExtractDocuments: true}, ObjectStores: storage, DriveFiles: driveLookup, AgentKBRepo: agentkbrepo.New(pool)})}
	handlers.Agents.Environments = envrepo.New(pool)
	handlers.Agents.Knowledge = handlers.KnowledgeAPI.Knowledge
	communitychat.WireKnowledge(chatSvc, pool, handlers.KnowledgeAPI.Knowledge)
	if storage != nil {
		handlers.Drive = communitydrive.Compose(pool, storage)
	}
	mux := http.NewServeMux()
	if cfg.AppIssuer != "" {
		box, err := secretbox.New("prod")
		if err != nil {
			return errors.New("application encryption key missing or invalid")
		}
		manager, err := oauthkeys.NewPostgresManager(ctx, pool, box)
		if err != nil {
			return err
		}
		if _, err = manager.Bootstrap(ctx); err != nil {
			return err
		}
		appService := communityapps.New(pool, cfg.AppIssuer)
		handlers.Apps = &clientapps.Handlers{App: appService, JWTSigner: oauthjwt.NewSigner(manager), Issuer: cfg.AppIssuer}
		handlers.Agents.Apps = appService
		mux.HandleFunc("POST /api/external/v1/oauth/token", handlers.Apps.Token)
		discovery := wellknown.DefaultConfig(cfg.AppIssuer, cfg.AppIssuer)
		discovery.GrantTypesSupported = []string{"authorization_code", "refresh_token"}
		(&wellknown.Handlers{Config: discovery, KeysMgr: manager}).Register(mux)
	}
	handlers.Register(mux, middleware.Auth(issuer, auth, false), account.New(pool))
	mux.Handle("GET /api/agent-bus/v1/runtime-environments", middleware.Auth(issuer, auth, false)(middleware.RequireTenant(middleware.RequireActiveTenantMembership(account.New(pool))(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		envs, err := envrepo.New(pool).ListTenantCustom(r.Context(), middleware.MustTenantID(r.Context()))
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		items := []map[string]any{}
		for _, e := range envs {
			if e.Framework == "generic" && e.HostingKind == "embedded" && e.Enabled && e.Status == "active" && !e.IsDeleted {
				items = append(items, map[string]any{"uuid": e.UUID, "name": e.Name, "framework": e.Framework, "status": e.Status, "enabled": true, "is_usable": true, "hosting_kind": e.HostingKind})
			}
		}
		encode.JSON(w, map[string]any{"tenant_enabled": items})
	})))))
	accountStream := clientchat.NewAccountStreamMiddleware(chatSvc, clientchat.AccountStreamConfig{})
	state := &clientchat.StateHandlers{ConvState: staterepo.New(pool), ConvAccess: convrepo.New(pool)}
	mux.Handle("POST /api/agent-bus/v1/chat/conversations/{uuid}/read", middleware.Auth(issuer, auth, false)(middleware.RequireTenant(middleware.RequireActiveTenantMembership(account.New(pool))(http.HandlerFunc(state.MarkConversationRead)))))
	pages := &clientchat.PageHandlers{Messages: msgrepo.New(pool)}
	for suffix, handler := range map[string]http.HandlerFunc{"around": pages.Around, "newer": pages.Newer} {
		mux.Handle("GET /api/agent-bus/v1/chat/conversations/{uuid}/messages/"+suffix, middleware.Auth(issuer, auth, false)(middleware.RequireTenant(middleware.RequireActiveTenantMembership(account.New(pool))(handler))))
	}
	accountStream.Start(ctx)
	defer accountStream.Stop()
	mux.Handle("GET /api/agent-bus/v1/conversations/stream", middleware.Auth(issuer, auth, false)(middleware.RequireTenant(middleware.RequireActiveTenantMembership(account.New(pool))(http.HandlerFunc(accountStream.Handle)))))

	communityim.Register(mux, pool, cfg, chatSvc, contactsSvc, func(handler http.Handler) http.Handler {
		return middleware.Auth(issuer, auth, false)(middleware.RequireTenant(middleware.RequireActiveTenantMembership(account.New(pool))(handler)))
	})
	observed := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, pattern := mux.Handler(r)
		if pattern == "" {
			log.Printf("community route missing: method=%s path=%s", r.Method, r.URL.Path)
		}
		mux.ServeHTTP(w, r)
	})
	server := &http.Server{Addr: cfg.HTTP, Handler: observed, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 0, IdleTimeout: 60 * time.Second}
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
	path := flag.String("config", "configs/community/bus.yaml", "community configuration")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, *path); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
