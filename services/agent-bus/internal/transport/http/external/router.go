// Package external 是 F01 §3.5 场景 5 「外部系统调用 知办AI」 的对外路由前缀
// `/api/external/v1/*` 实现。
//
// 与 bus / admin 完全分离:
//   - bus  (/api/agent-bus/v1)   ← JWT, 给 zhiban-app 用
//   - admin (/api/admin/v1)      ← JWT + RBAC perm, 给 agent-bus-admin web 用
//   - external (/api/external/v1) ← API Key (Bearer ek_<prefix>_<secret>), 给外部系统用
//
// 鉴权链: middleware.APIKeyAuth → middleware.RequireApiKeyScope("kb.read") → handler。
package external

import (
	"context"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"

	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	domtenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	userjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	pkgjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
	svcagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agentsdk"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svcextorg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/externalorg"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	svctenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/tenant"
)

// TenantProvisioner 由 cmd/bus 注入 service/tenant.Service (天然满足本接口)。
type TenantProvisioner interface {
	GetBySlug(ctx context.Context, slug string) (*domtenant.Tenant, error)
	Provision(ctx context.Context, t *domtenant.Tenant, admin svctenant.AdminInput) (*svctenant.ProvisionResult, error)
}

// Handlers 装配 external API 的依赖。
//
// M1: 仅 APIKeys + Knowledge (Bearer ek_)。
// M2: 加 AgentSDK (Bearer st_), 走同一组路由 (CompositeExternalAuth 按前缀分发) +
// 独立的 /oauth/token 端点 (client_credentials grant).
type Handlers struct {
	APIKeys   middleware.ApiKeyValidator
	AgentSDK  *svcagentsdk.Service // nil 时不挂 client_credentials grant + 不接受 st_
	Knowledge svckb.Service
	// AgentKnowledge 复用 ChatRAGService；请求 agent_id 先按 st_ tenant/runtime 校验，再聚合检索绑定 KB。
	AgentKnowledge svcchat.ToolSearchService
	// Memory · F17 记忆中台对外入口 (集团自研 agent 经 ek_ 调记忆); nil 时不挂 /memories/* 路由。
	// Pool · F07 §3.2 跨用户 KB 端点用 (resolveAccountIDByUUID 直查 accounts 表); nil → 跨用户端点报 500。
	Pool *pgxpool.Pool

	// F04: 应用接入 OAuth2; nil 时不挂 authorization_code / refresh_token grants + 不接受 eyJ。
	App         domapp.Service
	JWTSigner   *pkgjwt.Signer
	JWTVerifier middleware.JWTVerifier
	Issuer      string // e.g. "https://zhiban.creditease.corp"

	// 外部组织架构同步 (F01 org sync); nil 时不挂 /api/external/v1/org/* 路由。
	ExternalOrg svcextorg.Service

	// 外部通知 (Agent 对话通知); nil 时不挂 /api/external/v1/notifications/* 路由。

	// 外部 Agent 主动聊天消息; nil 时不挂 /api/external/v1/chat/* 路由。

	// 会话附件下载 (F24 拍板 5 履约交接); nil 时不挂 /api/external/v1/files/* 路由。

	// TenantProvision OPC 自注册企业 → 知办一等租户 (tenant_provision.go)。
	// 窄接口:只暴露幂等判断 + 原子 provision,不把整个租户服务开给 external 层。

	// 用户登录 JWT introspection (业务方系统间调用鉴权); nil 时不挂 /auth/introspect。
	LoginIssuer  *userjwt.Issuer
	LoginRevoker middleware.Revoker
}

// Register 把路由挂到给定 mux。
//
// 调用方: cmd/bus/main.go 在共享 mux 上调一次即可; 路径前缀 /api/external/v1 唯一,
// 不会和 bus / admin 冲突。
//
// 鉴权: CompositeExternalAuth 按 Bearer 前缀 ek_ / st_ 自动分发到 APIKeyAuth /
// SessionTokenAuth; 业务 handler 通过 RequireExternalScope 统一闸 scope。
func (h *Handlers) Register(mux *http.ServeMux) {
	if h == nil {
		return
	}
	if h.APIKeys == nil && h.AgentSDK == nil && h.App == nil && h.JWTVerifier == nil {
		return
	}

	var stValidator middleware.SessionTokenValidator
	if h.AgentSDK != nil {
		stValidator = h.AgentSDK
	}
	var jwtV middleware.JWTVerifier
	if h.JWTVerifier != nil {
		jwtV = h.JWTVerifier
	}
	authMW := middleware.CompositeExternalAuth(h.APIKeys, stValidator, jwtV, h.Issuer)

	// OAuth token endpoint: 统一入口 — 内部按 grant_type 分发到 client_credentials (F01) /
	// authorization_code + refresh_token (F04)。任一 grant 提供方 (AgentSDK 或 App+JWTSigner) 在即挂。
	if h.AgentSDK != nil || (h.App != nil && h.JWTSigner != nil) {
		mux.HandleFunc("POST /api/external/v1/oauth/token", h.oauthToken)
	}

	// 用户登录 token introspection — 仅租户 API Key 可调用, 不接受 st_/JWT 转调。
	if h.APIKeys != nil && h.LoginIssuer != nil {
		mux.Handle("POST /api/external/v1/auth/introspect",
			middleware.APIKeyAuth(h.APIKeys)(
				middleware.RequireApiKeyScope(domapikey.ScopeTenantAuthIntrospect)(
					http.HandlerFunc(h.introspectLoginToken))))
	}

	// OPC 自注册企业开通知办租户 (spec 2026-08-17-opc-native-tenant-provision)。
	// 平台级 capability,不绑租户;slug 白名单正则在 handler 内收敛。
	// 鉴权走 platformCredentialAuth(HTTP Basic 直校凭据)而非 authMW —— 租户尚不存在,
	// 签不出 st_(session_tokens.tenant_id NOT NULL + FK),详见该函数注释。

	// 业务端点 (M1: 1 个; M2 起 KB 也对 st_ 开放)
	if h.Knowledge != nil {
		kbRead := func(next http.Handler) http.Handler {
			return authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBRead)(
				h.auditAppBorrowedCapability("kb.read", next)))
		}
		// F01 §3.5 原有 (向后兼容)
		mux.Handle("GET /api/external/v1/knowledge-bases/{knowledge_base_id}/documents",
			kbRead(http.HandlerFunc(h.kbListDocs)))

		// F07 §3.2 新增 endpoint
		mux.Handle("GET /api/external/v1/knowledge-bases",
			kbRead(http.HandlerFunc(h.kbList)))
		mux.Handle("GET /api/external/v1/knowledge-bases/{knowledge_base_id}",
			kbRead(http.HandlerFunc(h.kbGet)))
		mux.Handle("GET /api/external/v1/knowledge-bases/{knowledge_base_id}/documents/{document_id}",
			kbRead(http.HandlerFunc(h.kbGetDoc)))
		mux.Handle("POST /api/external/v1/knowledge-bases/{knowledge_base_id}/retrieve",
			kbRead(http.HandlerFunc(h.kbRetrieve)))
		mux.Handle("POST /api/external/v1/knowledge-bases",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBWrite)(http.HandlerFunc(h.kbCreate))))
		mux.Handle("POST /api/external/v1/knowledge-bases/{knowledge_base_id}/documents",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBWrite)(http.HandlerFunc(h.kbUploadDoc))))

		// F07 D13 跨用户 (独立 scope ScopeTenantKBListUserPrivate, 服务层自动 audit)
		mux.Handle("GET /api/external/v1/users/{user_id}/knowledge-bases",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBListUserPrivate)(http.HandlerFunc(h.kbListUserPrivate))))
		mux.Handle("GET /api/external/v1/users/{user_id}/knowledge-bases/{knowledge_base_id}",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBListUserPrivate)(http.HandlerFunc(h.kbGetUserPrivate))))
		mux.Handle("GET /api/external/v1/users/{user_id}/knowledge-bases/{knowledge_base_id}/documents",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBReadUserPrivate)(http.HandlerFunc(h.kbListUserPrivateDocs))))
	}
	if h.AgentKnowledge != nil && stValidator != nil {
		mux.Handle("POST /api/external/v1/knowledge/retrieve",
			authMW(middleware.RequireExternalScope(domapikey.ScopeTenantKBRead)(http.HandlerFunc(h.agentKnowledgeRetrieve))))
	}

	// F24 拍板 5 履约交接: 平台/外部 runtime 按 chat.file.read 事后取回会话附件
	// (属主校验复用客户端 message-files 下载链, 见 files.go)。

	// F17 记忆中台对外 API (集团自研 agent 经 ek_ 调记忆)。tenant 从 token 取, 底层
	// MemMachine apiKey 只在 Bus, 调用方永不持有 (对齐 F07 KB D9)。

	// 外部组织架构同步 API (F01 org sync):
	//   - GET 读取/增量回查: ek_ API Key、st_ Runtime Access Token (org.read)
	//     或应用 JWT (contacts.read)
	//   - POST/PATCH/DELETE 写入: 仅 ek_ API Key (tenant.org.write)
	if h.ExternalOrg != nil && (h.APIKeys != nil || stValidator != nil || jwtV != nil) {
		orgReadAuth := middleware.CompositeExternalAuth(h.APIKeys, stValidator, jwtV, h.Issuer)
		readScope := middleware.RequireExternalScope(domapikey.ScopeTenantOrgRead)
		writeScope := middleware.RequireExternalScope(domapikey.ScopeTenantOrgWrite)
		var orgWriteAuth func(http.Handler) http.Handler
		if h.APIKeys != nil {
			orgWriteAuth = middleware.APIKeyAuth(h.APIKeys)
		}
		orgRead := func(next http.Handler) http.Handler {
			return orgReadAuth(readScope(h.auditAppBorrowedCapability("contacts.read", next)))
		}

		// Departments
		mux.Handle("GET /api/external/v1/org/departments",
			orgRead(http.HandlerFunc(h.orgListDepartments)))
		mux.Handle("GET /api/external/v1/org/departments/{department_id}",
			orgRead(http.HandlerFunc(h.orgGetDepartment)))
		if h.APIKeys != nil {
			mux.Handle("POST /api/external/v1/org/departments",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgCreateDepartment))))
			mux.Handle("PATCH /api/external/v1/org/departments/{department_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgUpdateDepartment))))
			mux.Handle("DELETE /api/external/v1/org/departments/{department_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgDeleteDepartment))))
		}

		// Members
		mux.Handle("GET /api/external/v1/org/members",
			orgRead(http.HandlerFunc(h.orgListMembers)))
		mux.Handle("GET /api/external/v1/org/members/{account_id}",
			orgRead(http.HandlerFunc(h.orgGetMember)))
		if h.APIKeys != nil {
			mux.Handle("POST /api/external/v1/org/members",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgCreateMember))))
			mux.Handle("PATCH /api/external/v1/org/members/{account_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgUpdateMember))))
			mux.Handle("DELETE /api/external/v1/org/members/{account_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgDeleteMember))))
		}

		// Positions
		mux.Handle("GET /api/external/v1/org/positions",
			orgRead(http.HandlerFunc(h.orgListPositions)))
		mux.Handle("GET /api/external/v1/org/positions/{position_id}",
			orgRead(http.HandlerFunc(h.orgGetPosition)))
		if h.APIKeys != nil {
			mux.Handle("POST /api/external/v1/org/positions",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgCreatePosition))))
			mux.Handle("PATCH /api/external/v1/org/positions/{position_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgUpdatePosition))))
			mux.Handle("DELETE /api/external/v1/org/positions/{position_id}",
				orgWriteAuth(writeScope(http.HandlerFunc(h.orgDeletePosition))))
		}
	}

	// 外部通知 API — ek_ 租户 API Key + st_ Runtime Access Token.

	// 外部 Agent 主动发送聊天消息 — ek_ 租户 API Key + st_ Runtime Access Token.

}

type appBorrowedCapabilityAuditor interface {
	AuditBorrowedCapability(ctx context.Context, tenantID int64, clientID, accountUUID, capability, method, path string)
}

func (h *Handlers) auditAppBorrowedCapability(capability string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clientID := middleware.JWTClientID(r.Context())
		if clientID != "" {
			if auditor, ok := h.App.(appBorrowedCapabilityAuditor); ok {
				auditor.AuditBorrowedCapability(
					r.Context(),
					middleware.JWTTenantID(r.Context()),
					clientID,
					middleware.JWTAccountUUID(r.Context()),
					capability,
					r.Method,
					r.URL.Path,
				)
			}
		}
		next.ServeHTTP(w, r)
	})
}
