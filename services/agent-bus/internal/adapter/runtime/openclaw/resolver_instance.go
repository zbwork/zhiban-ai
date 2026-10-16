// resolver_instance.go — F02 v0.3 起 chat send 的正确解析器:
//
// 与已 Deprecated 的 LocalRegistryResolver 的本质差异:
//   - 旧: 只看 runtime_environments.metadata.legacy_endpoints.gateway (静态 admin 注册值)
//         + env URL fallback (`AGBUS_RUNTIME_LOCAL_GATEWAY_URL`) → 本地开发 /
//         单租户共享场景, **拿不到 per-user pod**;
//   - 新: 按 runtime_environments.hosting_kind 分流:
//         * `external_endpoint` (租户自托管 / ZAP)     → 直接用 env.primary_endpoint + env.api_key_secret_ref
//         * `clawmanager` / `k8s_native` (per-user pod) → 查 runtime_instances 中
//           (tenant_id, created_by=accountID, runtime_environment_id) 且 status='ready'
//           的实例, 拿 endpoint_url + agent_gateway_token; 没 ready 实例直接报
//           ErrInstanceNotReady (caller 走 runtime.warming 兜底)。
//
// **绝不**回退 env URL / 127.0.0.1; 也不回退到 metadata.legacy_endpoints。本地 OpenClaw
// 调试模式不再在 chat send 链路支持 — 单租户共享 dev 必须由 admin 后台注册一份
// `external_endpoint` 类型的 runtime_environment 走第一分支。
//
// 与 runtimehosting.CheckReady 共用同一份 (tenant_id, created_by, runtime_environment_id)
// WHERE 条件, 保证"客户端看 503 runtime.warming → 同租户同账号同 env 的 ready instance
// 出现 → 再发就直通"语义不漂移。

package openclaw

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	domenv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ErrInstanceNotReady 表示 hosting_kind=clawmanager/k8s_native 的 runtime 当前没有
// (tenant, account, env) 维度的 ready 实例; caller 应据此返 runtime.warming 给客户端
// (或队列里 retry), **不**回退到任何 env URL / 127.0.0.1。
var ErrInstanceNotReady = errors.New("openclaw: no ready runtime_instance for caller (clawmanager/k8s_native: pod not provisioned / not healthy yet)")

// ErrFrameworkUnsupported chat 链路上 runtime_environment.framework 必须是 "openclaw";
// 非 openclaw (zap / hermes 等) → 拒, caller 报 protocol_unsupported。判定走 runtime_environments
// 字段, 不再用 deprecated 的 runtime/Registration.Framework (那是 legacy mapping)。
var ErrFrameworkUnsupported = errors.New("openclaw: runtime_environment.framework is not 'openclaw'; chat path only supports OpenClaw Gateway v3")

// RuntimeEnvReader 把 runtime_environments 读路径解耦, 方便测试 mock。
//
// 仅 GetByID, 与 LocalRegistryResolver 的 runtimeRegistryReader 同形态 (旧 reader
// 返 Registration, 新 reader 返 Env)。
type RuntimeEnvReader interface {
	GetByID(ctx context.Context, id int64) (*domenv.Env, error)
}

// InstanceLookup 按 (tenant, account, runtime_env) 查 status='ready' 且 endpoint_url 非空的
// runtime_instances 行; 与 runtimehosting.CheckReady 同口径 (改这里两边一起改)。
//
// 单元测试可以注入纯内存实现, 不依赖真实 pgxpool。
// agentUUID 为 nil 时查共享 pod（现状）；非 nil 时查 ADR-0037 BYOK 数字员工
// 的专属 pod。跟 runtimehosting.CheckReady 的 WHERE 条件必须保持同一套
// agent_uuid 消歧口径，改一边要一起改。
type InstanceLookup interface {
	FindReadyInstance(ctx context.Context, tenantID, accountID, runtimeEnvID int64, agentUUID *string) (endpointURL, agentGatewayTokenRef string, found bool, err error)
}

// SecretResolverFunc 把 secret_ref (env:// / value:// / vault://) 解成明文 bearer。
// 由 cmd/bus 注入 (与 admin 同语义, value:// 仅 dev/test)。
type SecretResolverFunc func(ref string) (string, error)

// RuntimeInstanceResolver 是 chat send 主路径解析器 (替代 LocalRegistryResolver)。
//
// 注入:
//   - envRepo:  读 runtime_environments 拿 hosting_kind / primary_endpoint / api_key_secret_ref
//   - lookup:   按 (tenant, account, env) 查 runtime_instances ready 行
//   - secret:   把 api_key_secret_ref / agent_gateway_token 解成明文
type RuntimeInstanceResolver struct {
	envRepo RuntimeEnvReader
	lookup  InstanceLookup
	secret  SecretResolverFunc
}

// NewRuntimeInstanceResolver 构造主路径 resolver。
//
// envRepo / lookup / secret 任一为 nil 都是装配 bug, Resolve 会显式报错(而不是降级)。
func NewRuntimeInstanceResolver(envRepo RuntimeEnvReader, lookup InstanceLookup, secret SecretResolverFunc) *RuntimeInstanceResolver {
	return &RuntimeInstanceResolver{envRepo: envRepo, lookup: lookup, secret: secret}
}

// PoolInstanceLookup 是 InstanceLookup 的 pgxpool 实现; cmd/bus / cmd/admin 用。
type PoolInstanceLookup struct{ pool *pgxpool.Pool }

func NewPoolInstanceLookup(pool *pgxpool.Pool) *PoolInstanceLookup {
	return &PoolInstanceLookup{pool: pool}
}

// FindReadyInstance 直查 runtime_instances; 与 runtimehosting.CheckReady 同 WHERE。
func (l *PoolInstanceLookup) FindReadyInstance(ctx context.Context, tenantID, accountID, runtimeEnvID int64, agentUUID *string) (string, string, bool, error) {
	if l == nil || l.pool == nil {
		return "", "", false, fmt.Errorf("openclaw resolver: PoolInstanceLookup pool nil")
	}
	var id int64
	var endpoint, tokenRef string
	err := l.pool.QueryRow(ctx, `
		SELECT id, COALESCE(endpoint_url,''), COALESCE(agent_gateway_token,'')
		  FROM runtime_instances
		 WHERE tenant_id=$1 AND created_by=$2 AND runtime_environment_id=$3
		   AND agent_uuid IS NOT DISTINCT FROM $4
		   AND is_deleted=false AND status='ready' AND COALESCE(endpoint_url,'') <> ''
		 ORDER BY id DESC LIMIT 1
	`, tenantID, accountID, runtimeEnvID, agentUUID).Scan(&id, &endpoint, &tokenRef)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", "", false, nil
		}
		return "", "", false, err
	}
	if err := probeGatewayHTTP(ctx, endpoint, 1200*time.Millisecond); err != nil {
		_, _ = l.pool.Exec(ctx, `
			UPDATE runtime_instances
			   SET status='starting',
			       endpoint_url=NULL,
			       error_message=$2,
			       updated_at=now()
			 WHERE id=$1
			   AND is_deleted=false
			   AND status='ready'
		`, id, fmt.Sprintf("ready endpoint stale: %v", err))
		return "", "", false, nil
	}
	return endpoint, tokenRef, true, nil
}

func probeGatewayHTTP(ctx context.Context, endpoint string, timeout time.Duration) error {
	base := strings.TrimRight(endpoint, "/")
	client := &http.Client{Timeout: timeout}
	var errs []string
	for _, path := range []string{"/healthz", "/health"} {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
		if err != nil {
			errs = append(errs, path+": "+err.Error())
			continue
		}
		resp, err := client.Do(req)
		if err != nil {
			errs = append(errs, path+": "+err.Error())
			continue
		}
		_ = resp.Body.Close()
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return nil
		}
		errs = append(errs, fmt.Sprintf("%s: status=%d", path, resp.StatusCode))
	}
	return fmt.Errorf("gateway health probe failed: %s", strings.Join(errs, "; "))
}

func probeGatewayTCP(ctx context.Context, endpoint string, timeout time.Duration) error {
	hostport, err := gatewayHostPort(endpoint)
	if err != nil {
		return err
	}
	d := net.Dialer{Timeout: timeout}
	conn, err := d.DialContext(ctx, "tcp", hostport)
	if err != nil {
		return err
	}
	_ = conn.Close()
	return nil
}

func gatewayHostPort(endpoint string) (string, error) {
	raw := strings.TrimSpace(endpoint)
	if raw == "" {
		return "", fmt.Errorf("endpoint empty")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("endpoint URL invalid: %q", endpoint)
	}
	host := u.Hostname()
	port := u.Port()
	if host == "" {
		return "", fmt.Errorf("endpoint host empty: %q", endpoint)
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", fmt.Errorf("endpoint scheme must be http or https: %q", endpoint)
	}
	if port == "" {
		switch scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		}
	}
	return net.JoinHostPort(host, port), nil
}

// Resolve 实现 InstanceResolver.Resolve。
//
//   - runtimeEnvID <= 0 → ErrEndpointNotConfigured (agent 未绑 runtime_environment, 不能聊)
//   - env.Framework != "openclaw" → ErrFrameworkUnsupported (chat 主链路只支持 OpenClaw Gateway v3)
//   - external_endpoint → env.primary_endpoint + env.api_key_secret_ref (空 secret_ref 允许,
//     当用户配的 runtime 不需要 bearer; 但 primary_endpoint 必须非空)
//   - clawmanager / k8s_native → runtime_instances 按 (tenant, created_by, runtime_env_id)
//     ready 实例; 否则 ErrInstanceNotReady
//   - 其它 / 空 hosting_kind → fail-closed (ErrEndpointNotConfigured); **绝不**回退本地 env URL
//     或 external endpoint, 新增 hosting_kind 必须在这里显式接
func (r *RuntimeInstanceResolver) Resolve(ctx context.Context, runtimeEnvID, tenantID, accountID int64, agentUUID *string) (Endpoint, error) {
	if r.envRepo == nil || r.lookup == nil {
		return Endpoint{}, fmt.Errorf("openclaw resolver: envRepo or lookup not wired")
	}
	if runtimeEnvID <= 0 {
		return Endpoint{}, fmt.Errorf("%w: runtime_environment_id is zero (agent 未绑 runtime, 不能进入 chat)", ErrEndpointNotConfigured)
	}
	env, err := r.envRepo.GetByID(ctx, runtimeEnvID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return Endpoint{}, fmt.Errorf("%w: runtime_environment id=%d not found", ErrEndpointNotConfigured, runtimeEnvID)
		}
		return Endpoint{}, fmt.Errorf("load runtime_environment id=%d: %w", runtimeEnvID, err)
	}
	// chat 主链路只支持 OpenClaw Gateway v3; 非 openclaw (zap/hermes/空) 一律拒,
	// 不再让 chat 拿到 zap external endpoint 误打 ZAP 链路 (与 chat/openclaw_v3.go
	// 旧 reg.Framework 守卫语义对齐, 但权威源改成 runtime_environments.framework
	// 而非 deprecated Registration.Framework)。
	if !strings.EqualFold(env.Framework, "openclaw") {
		return Endpoint{}, fmt.Errorf("%w: runtime_environment id=%d framework=%q", ErrFrameworkUnsupported, env.ID, env.Framework)
	}

	switch env.HostingKind {
	case "external_endpoint":
		return r.resolveExternal(env)
	case "clawmanager", "k8s_native":
		return r.resolveHostedInstance(ctx, env, tenantID, accountID, agentUUID)
	default:
		// 2026-06-02 codex 返修 (Fix3): 未知 hosting_kind 不再静默兜底 external,
		// 一律返 ErrEndpointNotConfigured。"开发期不需要兼容";
		// 新增 hosting_kind 必须先在这里显式接, 不允许靠默认分支吃掉。
		return Endpoint{}, fmt.Errorf("%w: runtime_environment id=%d hosting_kind=%q not supported (must be external_endpoint / clawmanager / k8s_native)",
			ErrEndpointNotConfigured, env.ID, env.HostingKind)
	}
}

func (r *RuntimeInstanceResolver) resolveExternal(env *domenv.Env) (Endpoint, error) {
	if env.PrimaryEndpoint == "" {
		return Endpoint{}, fmt.Errorf("%w: runtime_environment id=%d hosting_kind=%q primary_endpoint empty (admin 必须填)",
			ErrEndpointNotConfigured, env.ID, env.HostingKind)
	}
	bearer, err := r.resolveSecret(env.APIKeySecretRef)
	if err != nil {
		return Endpoint{}, fmt.Errorf("resolve api_key_secret_ref for runtime_environment id=%d: %w", env.ID, err)
	}
	return Endpoint{URL: env.PrimaryEndpoint, Bearer: bearer}, nil
}

func (r *RuntimeInstanceResolver) resolveHostedInstance(ctx context.Context, env *domenv.Env, tenantID, accountID int64, agentUUID *string) (Endpoint, error) {
	endpoint, tokenRef, found, err := r.lookup.FindReadyInstance(ctx, tenantID, accountID, env.ID, agentUUID)
	if err != nil {
		return Endpoint{}, fmt.Errorf("query runtime_instances for env=%d tenant=%d account=%d: %w",
			env.ID, tenantID, accountID, err)
	}
	if !found {
		return Endpoint{}, fmt.Errorf("%w: runtime_environment id=%d, tenant=%d, account=%d (hosting_kind=%s)",
			ErrInstanceNotReady, env.ID, tenantID, accountID, env.HostingKind)
	}
	bearer, err := r.resolveSecret(tokenRef)
	if err != nil {
		return Endpoint{}, fmt.Errorf("resolve agent_gateway_token for runtime_environment id=%d: %w", env.ID, err)
	}
	return Endpoint{URL: endpoint, Bearer: bearer}, nil
}

func (r *RuntimeInstanceResolver) resolveSecret(ref string) (string, error) {
	if ref == "" {
		return "", nil
	}
	if r.secret == nil {
		return "", fmt.Errorf("secret resolver not wired")
	}
	return r.secret(ref)
}
