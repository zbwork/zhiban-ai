// community-admin serves the community administrator API.
package main

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/secretbox"
	repoclientbuild "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/memory/clientbuild"
	repoclientanalytics "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/clientanalytics"
	repoclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/clientversion"
	repodownloadchannel "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/downloadchannel"
	repoempblock "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/empblock"
	localrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/localcodingcatalog"
	repomarketinglead "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/marketinglead"
	reposupportfeedback "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/supportfeedback"
	svcclientanalytics "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientanalytics"
	svcclientbuild "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientbuild"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
	svcdownloadchannel "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/downloadchannel"
	svcemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/emp"
	localsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localcodingcatalog"
	svcmarketinglead "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/marketinglead"
	svcruntime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
	svcsupportfeedback "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/supportfeedback"

	wukong "github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	approvalrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/a2aapproval"
	edgerepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/a2acalledge"
	caprepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/a2acapability"
	sdkrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agentsdk"
	imrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/imconnection"
	a2asvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
	sdksvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agentsdk"

	"context"
	"errors"
	"flag"
	"github.com/redis/go-redis/v9"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/admincore"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/adminrouter"
	communityapps "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/apps"
	communitychat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	communitydrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/captcha"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/redact"
	account "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	agentkbrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agentkb"
	alertrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/alert"
	apirepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/apikey"
	repoaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/audit"
	audit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/authaudit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/communityresources"
	repocron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/cron"
	repodrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	event "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
	kbrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
	orgrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/orgwebhook"
	rbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/rbac"
	envrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/runtimeenv"
	session "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/session"
	reposkill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/skill"
	tenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/tenant"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	apisvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/apikey"
	authsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	contactsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contactpolicy"
	cronsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	deptsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/department"
	drivesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	identitysvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/identity"
	kbsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider/stub"
	mediasvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/media"
	membersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	orgsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/orgwebhook"
	platformsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/platform"
	positionsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
	rbacsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/rbac"
	runtimeenvsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimeenv"
	typesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimetype"
	skillsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	storagesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/storage"
	sysusersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/sysuser"
	tenantsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/tenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminapps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminorg"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminsession"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/admintenant"
	authoidchttp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/authoidc"
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
	var identities *identitysvc.Registry
	authDeps := authsvc.Deps{Accounts: account.New(pool), Tenants: tenantRepo, RBAC: rbacRepo, Sessions: session.New(pool), AuditLog: audit.New(pool), Issuer: issuer, Captcha: captcha.New(redisClient), Revoke: authsvc.NewRedisRevoker(redisClient, 15*time.Minute), EventBus: authsvc.NewPgEventBus(pool)}
	if os.Getenv("AGBUS_SECRETBOX_KEY") != "" {
		box, err := secretbox.New("production")
		if err != nil {
			return err
		}
		identities = identitysvc.NewRegistry(pool, box)
		authDeps.IdentityRegistry = identities
		authDeps.OIDCStateStore = identitysvc.NewStateStore(redisClient)
	}
	auth := authsvc.New(authDeps)
	pub := event.New(pool)
	tenantService := tenantsvc.New(tenantRepo, pool, pub, communityresources.Initialize(cfg.StorageQuotaBytes))
	tenantsvc.AllowExistingEmailAdmin(tenantService)
	storage, err := communitydrive.NewStorage(cfg)
	if err != nil {
		return err
	}
	skillService := skillsvc.NewWithAgents(reposkill.NewCommunity(pool), communitychat.SkillAgentLookup{Agents: agentrepo.New(pool)})
	var mediaService *mediasvc.Service
	if storage != nil {
		mediaService = mediasvc.NewWithResolver(storage, mediasvc.Config{})
		skillService.SetPackageStore(skillsvc.NewPackageStoreWithResolver(storage, 0, skillsvc.PackageStoreConfig{}))
	}

	sdkService := sdksvc.New(sdksvc.Deps{CredRepo: sdkrepo.NewCredentialRepo(pool), SessionRepo: sdkrepo.NewSessionTokenRepo(pool), Audit: repoaudit.New(pool)})
	var imClient *wukong.Client
	if cfg.WuKong.URL != "" {
		imClient = wukong.NewAdapter(cfg.WuKong.URL, cfg.WuKong.TCPAddr, cfg.WuKong.WSAddr, nil).Client()
	}

	var clientPackages *svcclientversion.PackageStore
	if storage != nil {
		clientPackages = svcclientversion.NewPackageStoreWithResolver(storage, svcclientversion.PackageStoreConfig{})
	}
	var probeTokenIssuer *svcruntime.ProbeTokenIssuer
	if secret := os.Getenv("AGBUS_RUNTIME_PROBE_TOKEN_SECRET"); secret != "" {
		if len(secret) < 16 {
			return errors.New("runtime probe token secret must contain at least 16 bytes")
		}
		probeTokenIssuer = svcruntime.NewProbeTokenIssuer([]byte(secret), 5*time.Minute)
	}
	appService := communityapps.New(pool, cfg.AppIssuer)
	core := &admincore.Handlers{
		KBProviderRepo:      kbrepo.New(pool),
		AdminAgentA2AInvoke: &admincore.AdminAgentA2AInvokeHandler{Pool: pool, Audit: repoaudit.New(pool)},
		AgentKBBindings:     &admincore.AgentKBBindingsHandler{Pool: pool},
		AdminAgentA2ACard:   &admincore.AdminAgentA2ACardHandler{Pool: pool, Audit: repoaudit.New(pool)},
		App:                 appService,
		ClientBuild: svcclientbuild.New(ctx, repoclientbuild.New(), svcclientbuild.Config{
			Environment: os.Getenv("AGBUS_ENV"),
			Mac:         svcclientbuild.RunnerConfig{URL: os.Getenv("AGBUS_CLIENT_BUILD_MAC_URL"), Token: os.Getenv("AGBUS_CLIENT_BUILD_MAC_TOKEN")},
			Windows:     svcclientbuild.RunnerConfig{URL: os.Getenv("AGBUS_CLIENT_BUILD_WINDOWS_URL"), Token: os.Getenv("AGBUS_CLIENT_BUILD_WINDOWS_TOKEN")},
		}),
		LocalCodingCatalog:      localsvc.New(localsvc.Deps{Repo: localrepo.New(pool), Packages: clientPackages, Audit: repoaudit.New(pool)}),
		AgentModelOptions:       []string{cfg.Model.Name},
		TenantIDP:               &admincore.PgxTenantIDPStore{Pool: pool},
		EMP:                     svcemp.New(nil, repoempblock.New(pool)),
		SupportFeedback:         svcsupportfeedback.New(reposupportfeedback.New(pool)),
		MarketingLead:           svcmarketinglead.New(svcmarketinglead.Deps{Repo: repomarketinglead.New(pool)}),
		ClientVersion:           svcclientversion.NewWithPackageStore(repoclientversion.New(pool), clientPackages),
		DownloadChannel:         svcdownloadchannel.New(repodownloadchannel.New(pool)),
		ClientAnalyticsOverview: svcclientanalytics.NewOverview(repoclientanalytics.New(pool)),
		ClientAnalyticsErrors:   svcclientanalytics.NewErrorAdmin(repoclientanalytics.New(pool)),
		AgentSDK:                sdkService, RuntimeChecker: &agentSDKRuntimeChecker{pool: pool},
		WuKongStatus:           &admincore.WuKongStatusHandler{Pool: pool, Connections: imrepo.New(pool), Client: imClient, Cfg: admincore.WuKongConfig{Enabled: cfg.WuKong.URL != "", APIAddr: cfg.WuKong.URL, TCPAddr: cfg.WuKong.TCPAddr, WSAddr: cfg.WuKong.WSAddr, WebhookSecretRef: cfg.WuKong.Token}},
		AdminA2AApprovals:      &admincore.AdminA2AApprovalHandler{Service: a2asvc.New(a2asvc.Deps{Edges: edgerepo.New(pool), CapabilityRepo: caprepo.New(pool), SessionDeriver: sdkService, Approvals: approvalrepo.New(pool), Agents: agentrepo.New(pool)}), Audit: repoaudit.New(pool)},
		ApiKey:                 apisvc.New(apisvc.Deps{Repo: apirepo.New(pool)}),
		Alerts:                 &admincore.AlertsAdminHandler{Store: alertrepo.New(pool, pub), Audit: repoaudit.New(pool)},
		OrgWebhook:             orgsvc.New(orgsvc.Deps{Repo: orgrepo.New(pool)}),
		SysUser:                sysusersvc.New(pool),
		Knowledge:              kbsvc.New(kbsvc.Deps{Repo: kbrepo.New(pool), Pool: pool, Provider: stub.New(pool), Audit: pub, AgentKBRepo: agentkbrepo.New(pool), ObjectStores: storage, Config: kbsvc.Config{PersistOriginals: true, ExtractDocuments: true}}),
		PlatformType:           typesvc.New(),
		Observability:          &admincore.ObservabilityCallLogsHandler{Pool: pool},
		ObservabilityAgentRuns: &admincore.ObservabilityAgentRunsHandler{Pool: pool, EventPub: pub, Redactor: redact.New()},
		AdminA2A:               &admincore.AdminA2AHandler{Pool: pool},
		AdminOrchestrations:    &admincore.AdminOrchestrationsHandler{Pool: pool},
		AdminSpeakerPolicies:   &admincore.AdminSpeakerPoliciesHandler{Pool: pool},
		Auth:                   auth, ContactPolicy: contactsvc.New(pool),
		Cron:  cronsvc.New(cronsvc.Deps{Repo: repocron.NewCommunity(pool), PromptTemplates: repocron.NewCommunity(pool), Agents: agentrepo.New(pool), Audit: pub, Config: cronsvc.Config{DisableRuntimeProjection: true}}),
		Skill: skillService, Media: mediaService,
		Membership: membersvc.New(pool, pub), Platform: platformsvc.NewCommunity(pool), Position: positionsvc.New(pool), RBAC: rbacsvc.New(rbacRepo), RuntimeEnv: runtimeenvsvc.New(envrepo.New(pool), probeTokenIssuer), Agent: agentsvc.New(agentrepo.New(pool), nil, nil, pool, pub),
		DriveStorage:       &storagesvc.Service{Repo: repodrive.NewStorageRepo(pool), Secret: storagesvc.SecretResolver{AllowValue: true}, AllowValue: true},
		DriveBrowse:        drivesvc.NewAdminBrowseSvc(pool),
		DriveQuotaAdmin:    drivesvc.NewAdminQuotaSvc(pool, repodrive.NewQuotaRepo(pool)),
		DriveUsageAdmin:    drivesvc.NewAdminUsageSvc(repodrive.NewSpaceRepo(pool)),
		DriveWorkersAdmin:  drivesvc.NewAdminWorkersSvc(pool, repodrive.NewTicketRepo(pool), repodrive.NewRecycleRepo(pool), repodrive.NewFileVersionRepo(pool), repodrive.NewWorkerJobRepo(pool)),
		DrivePlatformQuota: drivesvc.NewAdminPlatformQuotaSvc(repodrive.NewQuotaRepo(pool)),
		Audit:              &admincore.AuditAdminHandler{Pool: pool},
		Rooms:              &admincore.AdminRoomsHandler{Pool: pool, Audit: repoaudit.New(pool)},
	}
	core.AgentKBBindings.Knowledge = core.Knowledge
	if os.Getenv("AGBUS_SECRETBOX_KEY") != "" {
		box, err := secretbox.New("production")
		if err != nil {
			return errors.New("invalid secretbox encryption configuration")
		}
		core.SecretSealer = box
	}
	if probeTokenIssuer != nil {
		core.RuntimeProbe = svcruntime.NewProbeService(nil, probeTokenIssuer)
	}
	if storage != nil {
		worker := drivesvc.NewWorkerSvc(pool, repodrive.NewTicketRepo(pool), repodrive.NewRecycleRepo(pool), repodrive.NewFileRepo(pool), repodrive.NewFolderRepo(pool), repodrive.NewFileVersionRepo(pool), repodrive.NewSpaceRepo(pool), repodrive.NewQuotaRepo(pool), storage, repodrive.NewWorkerJobRepo(pool))
		core.DriveRecycleAdmin = drivesvc.NewAdminRecycleSvc(pool, repodrive.NewRecycleRepo(pool), repodrive.NewFileRepo(pool), repodrive.NewFolderRepo(pool), repodrive.NewSpaceRepo(pool), worker)
	}
	handlers := adminrouter.Handlers{
		Apps:        &adminapps.Handlers{App: appService},
		AppReadOnly: cfg.AppIssuer == "",
		Session:     &adminsession.Handlers{Auth: auth, RBAC: rbacsvc.New(rbacRepo)},
		Org:         &adminorg.Handlers{MemberCreator: membersvc.New(pool, pub), Department: deptsvc.New(pool, pub), Membership: membersvc.New(pool, pub)},
		Tenant:      &admintenant.Handlers{Tenant: tenantService, AllowExistingEmailAdmin: true},
		Core:        core,
	}
	mux := http.NewServeMux()
	if identities != nil {
		(&authoidchttp.Handlers{Auth: auth, Catalog: identities, AdminOnly: true}).Register(mux, "/api/admin/v1/auth")
	}
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
