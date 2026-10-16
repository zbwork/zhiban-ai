package hermes

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	domenv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
)

var ErrHermesInstanceNotReady = errors.New("hermes: no ready runtime_instance for caller")

var ErrHermesEndpointNotConfigured = errors.New("hermes: endpoint not configured")

// HermesEndpoint is the resolved endpoint + bearer for a Hermes chat request.
type HermesEndpoint struct {
	URL         string
	Bearer      string
	HostingKind string
}

// RuntimeEnvReader reads runtime_environments by ID.
type RuntimeEnvReader interface {
	GetByID(ctx context.Context, id int64) (*domenv.Env, error)
}

// InstanceLookup queries runtime_instances for a ready instance.
// agentUUID: nil 查 (tenant,account,env) 共享 pod; 非 nil 查该数字员工专属 pod。
// ADR-0037 Phase 1 任务组 5 之前, Hermes 确实没有 per-agent 专属 pod, 调用方
// 固定传 nil——那之后 BYOK Hermes 数字员工也会拿到自己专属的 pod
// (worker.processAgentInstanceInit 的 clawmanager/k8s_native 分支跟 OpenClaw
// 走同一套 EnsureWorkload), 调用方必须按 model_source 传对应的 agentUUID,
// 否则聊天请求会被路由到共享 pod 而不是这个数字员工自己配的 BYOK 网关。
type InstanceLookup interface {
	FindReadyInstance(ctx context.Context, tenantID, accountID, runtimeEnvID int64, agentUUID *string) (endpointURL, tokenRef string, found bool, err error)
}

// SecretResolverFunc resolves a secret ref (env:// / value://) to plaintext.
type SecretResolverFunc func(ref string) (string, error)

// EndpointResolver resolves Hermes endpoint + bearer by hosting_kind.
type EndpointResolver struct {
	envRepo RuntimeEnvReader
	lookup  InstanceLookup
	secret  SecretResolverFunc
}

func NewEndpointResolver(envRepo RuntimeEnvReader, lookup InstanceLookup, secret SecretResolverFunc) *EndpointResolver {
	return &EndpointResolver{envRepo: envRepo, lookup: lookup, secret: secret}
}

// Resolve returns the Hermes endpoint for the given runtime environment.
//
// Branching:
//   - external_endpoint → env.PrimaryEndpoint + env.APIKeySecretRef
//   - clawmanager / k8s_native → runtime_instances (tenant, account, env) ready instance
//   - framework != hermes → fail-closed
//   - Hermes requires a bearer token; empty token after resolve → fail-closed
//
// agentUUID: 非 nil 时按该数字员工的专属 pod 解析 (BYOK); nil 走 (tenant,account,env)
// 共享 pod, 跟改动前行为完全一致。external_endpoint 分支不区分 agentUUID (无 per-user pod)。
func (r *EndpointResolver) Resolve(ctx context.Context, runtimeEnvID, tenantID, accountID int64, agentUUID *string) (HermesEndpoint, error) {
	if r.envRepo == nil || r.lookup == nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: envRepo or lookup not wired")
	}
	if runtimeEnvID <= 0 {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment_id is zero", ErrHermesEndpointNotConfigured)
	}

	env, err := r.envRepo.GetByID(ctx, runtimeEnvID)
	if err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: load runtime_environment id=%d: %w", runtimeEnvID, err)
	}

	if !strings.EqualFold(env.Framework, "hermes") {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d framework=%q",
			ErrHermesEndpointNotConfigured, env.ID, env.Framework)
	}

	switch env.HostingKind {
	case "external_endpoint":
		return r.resolveExternal(env)
	case "clawmanager", "k8s_native":
		return r.resolveHostedInstance(ctx, env, tenantID, accountID, agentUUID)
	default:
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d hosting_kind=%q not supported",
			ErrHermesEndpointNotConfigured, env.ID, env.HostingKind)
	}
}

func (r *EndpointResolver) resolveExternal(env *domenv.Env) (HermesEndpoint, error) {
	if env.PrimaryEndpoint == "" {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d hosting_kind=%q primary_endpoint empty",
			ErrHermesEndpointNotConfigured, env.ID, env.HostingKind)
	}
	bearer, err := r.resolveSecret(env.APIKeySecretRef)
	if err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: resolve api_key_secret_ref for env id=%d: %w", env.ID, err)
	}
	if strings.TrimSpace(bearer) == "" {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d api_key_secret_ref empty (Hermes requires bearer)",
			ErrHermesEndpointNotConfigured, env.ID)
	}
	if err := validateEndpointURL(env.PrimaryEndpoint); err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: env id=%d: %w", env.ID, err)
	}
	return HermesEndpoint{URL: env.PrimaryEndpoint, Bearer: bearer, HostingKind: env.HostingKind}, nil
}

func (r *EndpointResolver) resolveHostedInstance(ctx context.Context, env *domenv.Env, tenantID, accountID int64, agentUUID *string) (HermesEndpoint, error) {
	endpoint, tokenRef, found, err := r.lookup.FindReadyInstance(ctx, tenantID, accountID, env.ID, agentUUID)
	if err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: query runtime_instances for env=%d tenant=%d account=%d: %w",
			env.ID, tenantID, accountID, err)
	}
	if !found {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d, tenant=%d, account=%d (hosting_kind=%s)",
			ErrHermesInstanceNotReady, env.ID, tenantID, accountID, env.HostingKind)
	}
	bearer, err := r.resolveSecret(tokenRef)
	if err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: resolve agent_gateway_token for env id=%d: %w", env.ID, err)
	}
	if strings.TrimSpace(bearer) == "" {
		return HermesEndpoint{}, fmt.Errorf("%w: runtime_environment id=%d instance token empty (Hermes requires bearer)",
			ErrHermesEndpointNotConfigured, env.ID)
	}
	if err := validateEndpointURL(endpoint); err != nil {
		return HermesEndpoint{}, fmt.Errorf("hermes resolver: env id=%d instance: %w", env.ID, err)
	}
	return HermesEndpoint{URL: endpoint, Bearer: bearer, HostingKind: env.HostingKind}, nil
}

func (r *EndpointResolver) resolveSecret(ref string) (string, error) {
	if ref == "" {
		return "", nil
	}
	if r.secret == nil {
		return "", fmt.Errorf("secret resolver not wired")
	}
	return r.secret(ref)
}

func validateEndpointURL(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("%w: endpoint URL unparseable", ErrHermesEndpointNotConfigured)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("%w: endpoint URL scheme must be http or https, got %q", ErrHermesEndpointNotConfigured, u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("%w: endpoint URL has empty host", ErrHermesEndpointNotConfigured)
	}
	return nil
}
