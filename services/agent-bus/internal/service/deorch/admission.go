// admission.go — doc-14 Objective F / P1 返修: 编排 master→child 的**完整 EasyO 内部 A2A 准入**。
//
// 口径 (务必准确): 这是 **EasyO 内部** A2A admission 的等价校验, **不是**官方开源 A2A Protocol
// (Agent Card / Task / Message / message·send / JSON-RPC) 的 wire-compatible 实现。它复用
// internal/service/a2a 的 whitelist 纯函数 + capability repo + quota port, **不在 deorch 拼裸 SQL**。
//
// 与 a2a.Service.Invoke 的关系: a2a.Service.Invoke 是带副作用的真实异步调用入口 (插 edge + 派生
// session token + 远程 fire)。编排不复用它去 fire (编排由 deorch.Executor 自己同步调 child + 自己写
// edge/step trace), 因此这里只做 **validation-only** 准入 (无副作用), 通过后由 Executor.invokeChild
// 自己插 edge/step 并同步调用 child。
//
// 校验链 (fail-closed, 任一失败拒, 不调用 child):
//  1. 防自调           master.ID != child.ID
//  2. tenant isolation master.TenantID == child.TenantID (任一为 0 → 拒)
//  3. capability       master 必须有 agent_capability_bindings.kind='a2a_invoke'
//  4. callable 白名单   child.callable_by_agents 4-mode (default-deny)
//  5. quota            per-agent RPM + per-tenant RPD (Quota 为 nil → 跳过此闸, 不致命)
//
// depth/loop/budget: 编排 MVP 是**单层** (master→child; sendOrchestrator 拒绝 orchestrator 型 child →
// 无嵌套), depth 恒=1、不可能成环, 故本轮不在准入里做 cycle/depth 校验; 多层嵌套落地时复用
// a2a.Service 的 Cycle/DepthLimit (见 doc-14 §7 剩余项)。
package deorch

import (
	"context"

	a2asvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
)

// CapabilityChecker = a2a CapabilityRepo 子集: master 是否有 a2a_invoke binding。
// 真实实现 = internal/repository/postgres/a2acapability.Repo; 单测用 fake。
type CapabilityChecker interface {
	HasA2AInvokeCapability(ctx context.Context, agentID int64) (bool, error)
}

// QuotaChecker = a2a.QuotaChecker 子集 (per-agent RPM + per-tenant RPD)。可空 → 跳过配额闸。
type QuotaChecker interface {
	CheckAndIncr(ctx context.Context, tenantID, agentID int64) (allowed bool, retryAfter int, err error)
}

// A2AAdmission 完整 EasyO 内部 A2A 准入 (替代纯 WhitelistAdmission 作为运行期默认)。
type A2AAdmission struct {
	Capabilities CapabilityChecker // 必填; nil → 一律拒 (fail-closed)
	Quota        QuotaChecker      // 可空; nil → 跳过配额闸
	Logger       Logger            // 可空
}

var _ AdmissionChecker = A2AAdmission{}

// Admit 跑完整校验链。allowed=false 时 reason 是稳定短码 (Executor 落到 edge.error_message /
// step.error_message, 不下发客户端): self_invoke / cross_tenant / capability_unwired /
// capability_error / missing_capability / callable_whitelist / quota_error / rate_limited。
func (a A2AAdmission) Admit(ctx context.Context, from MasterAgent, to ChildAgent) (bool, string) {
	// 1. 防自调
	if from.ID == to.ID {
		return false, "self_invoke"
	}
	// 2. tenant isolation (fail-closed: 任一为 0 或不相等 → 拒)
	if from.TenantID == 0 || to.TenantID == 0 || from.TenantID != to.TenantID {
		return false, "cross_tenant"
	}
	// 3. capability: master 必须具备 a2a_invoke
	if a.Capabilities == nil {
		return false, "capability_unwired" // 没装 capability repo → fail-closed, 不放行
	}
	ok, err := a.Capabilities.HasA2AInvokeCapability(ctx, from.ID)
	if err != nil {
		if a.Logger != nil {
			a.Logger.Warn(ctx, "deorch a2a admission: capability check failed", "master", from.UUID, "err", err.Error())
		}
		return false, "capability_error" // 查询出错 → fail-closed
	}
	if !ok {
		return false, "missing_capability"
	}
	// 4. callable whitelist (复用 a2a 纯函数, default-deny)
	pol := a2asvc.ParseCallablePolicy(to.CallableByAgentsJSON)
	if !a2asvc.EvaluateWhitelist(a2asvc.WhitelistInput{
		FromAgentID:      from.UUID,
		FromAgentWorkspc: from.WorkspaceID,
		ToAgentID:        to.UUID,
		ToAgentWorkspc:   to.WorkspaceID,
		ToCallable:       pol,
	}) {
		return false, "callable_whitelist"
	}
	// 5. quota (可空)
	if a.Quota != nil {
		allowed, _, qerr := a.Quota.CheckAndIncr(ctx, from.TenantID, from.ID)
		if qerr != nil {
			if a.Logger != nil {
				a.Logger.Warn(ctx, "deorch a2a admission: quota check failed", "master", from.UUID, "err", qerr.Error())
			}
			return false, "quota_error" // 配额查询出错 → fail-closed
		}
		if !allowed {
			return false, "rate_limited"
		}
	}
	return true, ""
}
