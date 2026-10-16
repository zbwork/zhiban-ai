// resolver.go — Batch 2C T2C.1.A: 按 runtime_registration_id 解析的 InstanceResolver。
//
// 与 legacy `LegacyInstanceResolver`(adapter.go) 的区别:
//   - 旧: 按 (tenantID, accountID) 解析, 配置只看进程 env, 与 admin 后台注册的 runtime 行无关
//   - 新: 按 runtime_registration_id 解析, 强制优先读 DB 行 (endpoints + metadata.api_key),
//     env 仅作 DB 字段缺失时的最后兜底, 绝不覆盖用户在 admin 后台注册的 runtime
//
// 新接口供:
//   - HealthCheck (T2C.2): runtime.Service.HealthCheck 拿到 *Registration 后调
//   - Agent publish/unpublish hook (T2C.3): agent.Service.Publish 拿 runtime_registration_id 解析
//   - Gateway v3 WS client (T2C.1.B): gatewayws.Endpoint
//
// 参考 docs/tasks/batch-2c-runtime-and-agent-management.md §5 T2C.1.A。

package openclaw

import (
	"context"
	"errors"
	"fmt"

	domrt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtime"
)

// Endpoint 是 OpenClaw Gateway 一次连接所需的最小信息。
type Endpoint struct {
	URL    string // 如 "http://127.0.0.1:18789"，不含 path
	Bearer string // metadata.api_key, 每 runtime 一份, 不共享
}

// IsZero 当 URL 与 Bearer 均空时返回 true。
func (e Endpoint) IsZero() bool { return e.URL == "" && e.Bearer == "" }

// InstanceResolver 按 runtime_registration_id 解析具体 OpenClaw 实例端点。
//
// tenantID / accountID 仅 K8s 模式 (per-user pod) 使用; local 模式忽略。
// 本批 K8s 路径 stub, 返回 ErrInstanceResolverK8sNotImplemented; 接口签名保留
// 三参数让后续 batch 接 K8s 时不改 caller。
//
// agentUUID (ADR-0037 BYOK, 2026-08): 非 nil 时表示这个数字员工独占一个专属
// pod, 解析要落到该 agent 自己的 runtime_instances 行, 而不是账号共享的那
// 一行。LocalRegistryResolver/K8sRegistryResolver 这两个 legacy/stub 实现
// 忽略这个参数; 真正消费它的是 RuntimeInstanceResolver
// (resolver_instance.go)。
type InstanceResolver interface {
	Resolve(ctx context.Context, runtimeRegistrationID, tenantID, accountID int64, agentUUID *string) (Endpoint, error)
}

// ErrEndpointNotConfigured 表示 DB runtime_registrations 行没有任何可用 endpoint
// 字段, 且 env 兜底也未配置。
var ErrEndpointNotConfigured = errors.New("openclaw: runtime endpoint not configured (DB endpoints empty, env fallback empty)")

// ErrRuntimeBearerMissing 表示 DB runtime_registrations 行有 endpoint 但 metadata.api_key 缺失。
//
// 拒绝混用 (DB endpoint + env bearer): 一个 runtime 只能有一份 token; 如果允许用 env bearer 兜底,
// 就会出现 admin 在后台注册了 runtime A (含自己的 token), 但 Bus 实际拿全局 env token 去打 A 的尴尬:
// 跨 runtime 凭证串扰 + 排查链路被切断 + 多租户 K8s 模式下 per-instance token 设计被绕过。
// 安全模型: env 仅在 endpoint 自身也来自 env (即 DB 行不提供 endpoint) 时才使用。
var ErrRuntimeBearerMissing = errors.New("openclaw: runtime row has endpoint but metadata.api_key missing; refuse to mix DB endpoint with env bearer")

// ErrInstanceResolverK8sNotImplemented K8s 路径在 Batch 2C 未实现 (留接口给后续 batch)。
var ErrInstanceResolverK8sNotImplemented = errors.New("openclaw: K8s instance resolver not implemented in Batch 2C")

// runtimeRegistryReader 仅依赖 GetByID, 解耦 service 层完整 Repository。
type runtimeRegistryReader interface {
	GetByID(ctx context.Context, id int64) (*domrt.Registration, error)
}

// LocalRegistryResolver 是本批 2C 主用 resolver:
//
// 解析规则 (强制, 详见 plan §5 T2C.1.A + Batch 2C-closeout #3):
//
//	情形 A: runtimeRegistrationID > 0 且 DB 行有 endpoint
//	   -> URL    必须用 DB endpoint (endpoints.gateway || responses || base, Q9)
//	   -> Bearer 必须用 DB metadata.api_key (Q7); **缺失即 ErrRuntimeBearerMissing**
//	   -> env 完全不参与 (防 DB endpoint + env bearer 串扰)
//
//	情形 B: runtimeRegistrationID > 0 但 DB 行 endpoint 也为空
//	   -> URL + Bearer 全用 env (smoke 启动期; 本机 dev 兜底场景);
//	   -> URL 仍空 -> ErrEndpointNotConfigured
//
//	情形 C: runtimeRegistrationID <= 0 (smoke 启动期 / 极端兜底)
//	   -> 同情形 B, URL + Bearer 一并取 env; URL 空 -> ErrEndpointNotConfigured
//
// **绝对不允许** env 覆盖或部分填充 admin 后台注册的 runtime; 也不允许
// DB endpoint + env bearer 混用。
type LocalRegistryResolver struct {
	reader    runtimeRegistryReader
	envURL    string // AGBUS_RUNTIME_LOCAL_GATEWAY_URL
	envBearer string // AGBUS_RUNTIME_LOCAL_GATEWAY_TOKEN
}

// NewLocalRegistryResolver 构造 local 模式 resolver。
//
// envURL/envBearer 来自 cfg (AGBUS_RUNTIME_LOCAL_GATEWAY_URL/TOKEN), 仅情形 B/C 使用。
// 传 reader=nil 仅在极端 smoke 启动期 (DB 还没起 + runtimeRegistrationID<=0) 合法;
// 业务路径必须传非 nil。
func NewLocalRegistryResolver(reader runtimeRegistryReader, envURL, envBearer string) *LocalRegistryResolver {
	return &LocalRegistryResolver{reader: reader, envURL: envURL, envBearer: envBearer}
}

// Resolve 按上述规则解析端点。agentUUID 未被本 resolver 使用 (legacy local
// 模式没有 per-agent pod 概念)，仅为满足 InstanceResolver 接口签名。
func (r *LocalRegistryResolver) Resolve(ctx context.Context, runtimeRegistrationID, tenantID, accountID int64, agentUUID *string) (Endpoint, error) {
	// 情形 C: 无 runtime id, 直接 env 兜底
	if runtimeRegistrationID <= 0 {
		if r.envURL == "" {
			return Endpoint{}, ErrEndpointNotConfigured
		}
		return Endpoint{URL: r.envURL, Bearer: r.envBearer}, nil
	}
	if r.reader == nil {
		return Endpoint{}, fmt.Errorf("openclaw resolver: runtime registry reader is nil (cannot load runtime id=%d)", runtimeRegistrationID)
	}
	reg, err := r.reader.GetByID(ctx, runtimeRegistrationID)
	if err != nil {
		return Endpoint{}, fmt.Errorf("openclaw resolver: load runtime id=%d: %w", runtimeRegistrationID, err)
	}

	url := PickEndpointURL(reg.Endpoints)
	bearer := PickBearer(reg.Metadata)

	if url != "" {
		// 情形 A: DB endpoint 在; 整体必须来自 DB, 不允许 env 兜底 bearer
		if bearer == "" {
			return Endpoint{}, ErrRuntimeBearerMissing
		}
		return Endpoint{URL: url, Bearer: bearer}, nil
	}

	// 情形 B: DB endpoint 缺 -> 整体 env 兜底
	if r.envURL == "" {
		return Endpoint{}, ErrEndpointNotConfigured
	}
	return Endpoint{URL: r.envURL, Bearer: r.envBearer}, nil
}

// K8sRegistryResolver 是 K8s 模式 resolver 预留 (Batch 2C 不实现, 留给后续)。
//
// 真正实现需:
//   - 按 (runtimeRegistrationID, tenantID, accountID) 在 runtime_instances 查/拉 Pod
//   - 调 clawmanager API CreateWorkload + 轮询 Pod IP 5min + 写回 runtime_instances
//   - 详见 plan §10 T2C-K8s-{1,2,3,4,5}
type K8sRegistryResolver struct{}

// NewK8sRegistryResolver 构造 K8s stub。
func NewK8sRegistryResolver() *K8sRegistryResolver { return &K8sRegistryResolver{} }

// Resolve K8s 路径未实现 (Batch 2C 仅 stub, 返回 ErrInstanceResolverK8sNotImplemented)。
func (r *K8sRegistryResolver) Resolve(ctx context.Context, runtimeRegistrationID, tenantID, accountID int64, agentUUID *string) (Endpoint, error) {
	return Endpoint{}, ErrInstanceResolverK8sNotImplemented
}

// PickEndpointURL 从 runtime_registrations.endpoints JSON 中按 Q9 兼容顺序挑 URL。
// 顺序: gateway -> responses -> base (responses 是 legacy ai-office 字段名兼容)。
// 全部为空返回 ""。
func PickEndpointURL(endpoints map[string]any) string {
	for _, key := range []string{"gateway", "responses", "base"} {
		if v, ok := endpoints[key]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// PickBearer 从 runtime_registrations.metadata JSON 中取 api_key 字段。
func PickBearer(metadata map[string]any) string {
	if v, ok := metadata["api_key"]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
