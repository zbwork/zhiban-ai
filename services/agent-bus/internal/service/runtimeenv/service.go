// Package runtimeenv 实现 M3 v1.1 "Agent 平台环境" 的业务服务:
//
//   - Platform admin: 列表 / 详情 / set-as-platform-default / delete-precheck。
//   - Tenant admin:   三段视图 / enable / disable / set-default / 自定义 CRUD。
//   - Client (Bus):   自己可见环境 / personal CRUD。
//
// Probe 子服务 (probe.go) 与本服务通过 probe_token 解耦; create/PATCH 必须用
// 一次性 token, 校 endpoints_sha256 + auth_config_sha256 一致。
package runtimeenv

import (
	"context"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/runtimeenv"
	svcruntime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
)

// Service 业务接口。
type Service interface {
	// === Platform admin ===
	ListPlatform(ctx context.Context, includeDisabled bool) ([]dom.Env, error)
	GetByUUID(ctx context.Context, uuid string) (*dom.Env, error)
	SetPlatformDefault(ctx context.Context, actorAccountID int64, uuid string) error
	DeletePlatform(ctx context.Context, actorAccountID int64, uuid string) error

	// === Tenant admin ===
	ListTenant(ctx context.Context, tenantID int64, limit, offset int) (*dom.TenantListResult, error)
	Enable(ctx context.Context, tenantID, byAccountID int64, runtimeUUID string, makeDefault bool) (*dom.Enablement, error)
	Disable(ctx context.Context, tenantID int64, enablementUUID string) error
	SetEnablementDefault(ctx context.Context, tenantID int64, enablementUUID string) error
	CreateTenantCustom(ctx context.Context, tenantID, byAccountID int64, in dom.CreateCustomInput) (*dom.Env, error)
	PatchTenantCustom(ctx context.Context, tenantID, callerAccountID int64, uuid string, in dom.PatchCustomInput) (*dom.Env, error)
	DeleteTenantCustom(ctx context.Context, tenantID int64, uuid string) error

	// === Client ===
	ListForClient(ctx context.Context, tenantID, accountID int64) (*dom.ClientListResult, error)

	// === Agent 创建闸 (M3 §5.4) ===
	// ResolveForAgentCreate 校验 caller 是否可见某 runtime, 返回 runtime 行。
	// scope=platform 必须在租户启用列表; tenant 必须 tenant_id=caller_tenant。
	// (F02 v0.3: personal scope 已移除 — ADR-0012)
	ResolveForAgentCreate(ctx context.Context, tenantID, accountID int64, runtimeUUID string) (*dom.Env, error)
	// EnsurePendingInstance 创建 agent 后保证 runtime_instances pending 行存在 (Stage 7 最小化)。
	// agentUUID 为 nil 时是共享 pod（现状）；非 nil 时是 ADR-0037 BYOK 专属
	// pod（当前所有调用方仍传 nil，真正按 model_source 判断传值留给后续任
	// 务组接入，见 docs/plans/22 Phase 1 任务组 3）。
	EnsurePendingInstance(ctx context.Context, tenantID, accountID, runtimeID int64, agentUUID *string) (string, string, error)

	Repo() *repo.Repo
}

type impl struct {
	r     *repo.Repo
	token *svcruntime.ProbeTokenIssuer
}

// New 构造。token 用于自定义环境创建/更新时校 probe_token。
func New(r *repo.Repo, token *svcruntime.ProbeTokenIssuer) Service {
	return &impl{r: r, token: token}
}

func (s *impl) Repo() *repo.Repo { return s.r }

// ===== Platform admin =====

func (s *impl) ListPlatform(ctx context.Context, includeDisabled bool) ([]dom.Env, error) {
	out, err := s.r.ListPlatform(ctx, includeDisabled)
	if err != nil {
		return nil, err
	}
	return s.fillBoundAgents(ctx, out)
}

func (s *impl) GetByUUID(ctx context.Context, uuid string) (*dom.Env, error) {
	return s.r.GetByUUID(ctx, uuid)
}

func (s *impl) SetPlatformDefault(ctx context.Context, actorAccountID int64, uuid string) error {
	x, err := s.r.GetByUUID(ctx, uuid)
	if err != nil {
		return err
	}
	if x.Scope != "platform" {
		return apperr.ErrInvalidParams.Withf("not a platform-scope runtime")
	}
	return s.r.SetPlatformDefault(ctx, x.ID)
}

func (s *impl) DeletePlatform(ctx context.Context, actorAccountID int64, uuid string) error {
	x, err := s.r.GetByUUID(ctx, uuid)
	if err != nil {
		return err
	}
	if x.Scope != "platform" {
		return apperr.ErrInvalidParams.Withf("not a platform-scope runtime")
	}
	// 前置校验: 引用方
	if n, err := s.r.CountEnablementsByRuntime(ctx, x.ID); err != nil {
		return err
	} else if n > 0 {
		return apperr.ErrConflict.Withf("runtime referenced by %d tenant enablements; revoke first", n)
	}
	if n, err := s.r.CountAgentsByRuntime(ctx, x.ID); err != nil {
		return err
	} else if n > 0 {
		return apperr.ErrConflict.Withf("runtime referenced by %d digital_employees", n)
	}
	if n, err := s.r.CountInstancesByRuntime(ctx, x.ID); err != nil {
		return err
	} else if n > 0 {
		return apperr.ErrConflict.Withf("runtime has %d active runtime_instances", n)
	}
	return s.r.SoftDelete(ctx, x.ID)
}

// ===== Tenant admin =====

func (s *impl) ListTenant(ctx context.Context, tenantID int64, limit, offset int) (*dom.TenantListResult, error) {
	res, err := s.r.EnablementList(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	enabled, err := s.fillBoundAgents(ctx, res.PlatformEnabled)
	if err != nil {
		return nil, err
	}
	res.PlatformEnabled = enabled
	custom, err := s.fillBoundAgents(ctx, res.TenantCustom)
	if err != nil {
		return nil, err
	}
	res.TenantCustom = custom
	redactTenantRuntimeEnvSecrets(res.PlatformEnabled)
	redactTenantRuntimeEnvSecrets(res.PlatformAvailable)
	// Tenant-custom runtimes are owned by the current tenant admin. Keep their
	// secret refs so the edit drawer can show the saved credential as a masked
	// password and preserve it on save; platform-owned refs stay redacted above.
	applyTenantListPagination(res, limit, offset)
	// custom 默认认为启用; 也加 is_default=false 预留 (UI 一致)
	return res, nil
}

type tenantRuntimeListRow struct {
	section string
	env     dom.Env
}

func applyTenantListPagination(res *dom.TenantListResult, limit, offset int) {
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	all := make([]tenantRuntimeListRow, 0, len(res.PlatformEnabled)+len(res.TenantCustom)+len(res.PlatformAvailable))
	for _, env := range res.PlatformEnabled {
		all = append(all, tenantRuntimeListRow{section: "platform_enabled", env: env})
	}
	for _, env := range res.TenantCustom {
		all = append(all, tenantRuntimeListRow{section: "tenant_custom", env: env})
	}
	for _, env := range res.PlatformAvailable {
		all = append(all, tenantRuntimeListRow{section: "platform_available", env: env})
	}
	total := len(all)
	end := offset + limit
	if offset > total {
		offset = total
	}
	if end > total {
		end = total
	}
	res.PlatformEnabled = []dom.Env{}
	res.TenantCustom = []dom.Env{}
	res.PlatformAvailable = []dom.Env{}
	for _, row := range all[offset:end] {
		switch row.section {
		case "platform_enabled":
			res.PlatformEnabled = append(res.PlatformEnabled, row.env)
		case "tenant_custom":
			res.TenantCustom = append(res.TenantCustom, row.env)
		case "platform_available":
			res.PlatformAvailable = append(res.PlatformAvailable, row.env)
		}
	}
	res.Total = total
	res.Limit = limit
	res.Offset = offset
}

func (s *impl) Enable(ctx context.Context, tenantID, byAccountID int64, runtimeUUID string, makeDefault bool) (*dom.Enablement, error) {
	rt, err := s.r.GetByUUID(ctx, runtimeUUID)
	if err != nil {
		return nil, err
	}
	if rt.Scope == "personal" {
		return nil, apperr.ErrForbidden.Withf("cannot enable a personal-scope runtime")
	}
	return s.r.Enable(ctx, tenantID, rt.ID, byAccountID, makeDefault)
}

func (s *impl) Disable(ctx context.Context, tenantID int64, enablementUUID string) error {
	en, err := s.r.GetEnablementByUUID(ctx, enablementUUID)
	if err != nil {
		return err
	}
	if en.TenantID != tenantID {
		return apperr.ErrForbidden
	}
	// P-C: 检查租户内是否有数字员工绑定该 runtime。
	if cnt, uuids, err := s.r.CountAgentsByRuntimeAndTenant(ctx, en.RuntimeEnvironmentID, tenantID); err != nil {
		return err
	} else if cnt > 0 {
		return apperr.ErrConflict.Withf("tenant_runtime.has_bound_agents: %d agents reference this runtime (uuids=%s)",
			cnt, strings.Join(uuids, ","))
	}
	// 最后一个不能撤销。
	if n, err := s.r.CountActiveEnablements(ctx, tenantID); err != nil {
		return err
	} else if n <= 1 {
		return apperr.ErrConflict.Withf("tenant_runtime.last_one_cannot_remove")
	}
	return s.r.Disable(ctx, tenantID, en.ID)
}

func (s *impl) SetEnablementDefault(ctx context.Context, tenantID int64, enablementUUID string) error {
	en, err := s.r.GetEnablementByUUID(ctx, enablementUUID)
	if err != nil {
		return err
	}
	return s.r.SetDefault(ctx, tenantID, en.ID)
}

// CreateTenantCustom 创建租户自定义 runtime_environment (ADR-0022 v0.4):
//
// 按 hosting_kind 二分:
//   - external_endpoint (= framework=zap, ZAP 协议接入): 走原有 probe_token 校验
//   - 协议 probe 链路, 由 SHA256(endpoint, auth) 绑定保证 caller 不能"probe 用 A,
//     create 改成 B"。
//   - clawmanager / k8s_native (= framework=openclaw|hermes 自带 K8s/PaaS): 不走
//     协议 probe — 这两类的 probe 是 hosting-config probe (runtimehosting.probeDraft),
//     由 admin web 在提交前 gate; service 层只做 schema 落库, 与 platform clawmanager/k8s_native
//     完全对称 (RuntimeHosting.upsertConfig 也无 server-side probe_token 要求)。
//     租户提供的服务地址必须公网可达 (ADR-0022 §2.2)。
func (s *impl) CreateTenantCustom(ctx context.Context, tenantID, byAccountID int64, in dom.CreateCustomInput) (*dom.Env, error) {
	normalizedExternalID, err := dom.NormalizeExternalEnvironmentID(in.ExternalEnvironmentID)
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("%v", err)
	}
	in.ExternalEnvironmentID = normalizedExternalID
	if in.HostingKind != "" && in.HostingKind != "external_endpoint" && normalizedExternalID != "" {
		return nil, apperr.ErrInvalidParams.Withf("external_environment_id is only supported for external_endpoint")
	}
	if in.HostingKind == "external_endpoint" || in.HostingKind == "" {
		// 兼容旧链路 (HostingKind 为空 = 旧版 admin web 不传, 隐式 external_endpoint)
		if err := s.verifyProbeToken(in.ProbeToken, "tenant", byAccountID, tenantID, in.PrimaryEndpoint, in.APIKeySecretRef); err != nil {
			return nil, err
		}
		env := buildCustomEnv(in, "tenant", &tenantID)
		created, err := s.r.CreateCustom(ctx, env)
		if err != nil {
			return nil, err
		}
		return s.r.MarkProbeOK(ctx, created.ID, "runtime probe passed")
	}
	if in.HostingKind != "clawmanager" && in.HostingKind != "k8s_native" {
		return nil, apperr.ErrInvalidParams.Withf("unknown hosting_kind %q", in.HostingKind)
	}
	env := buildCustomEnv(in, "tenant", &tenantID)
	created, err := s.r.CreateCustom(ctx, env)
	if err != nil {
		return nil, err
	}
	return created, nil
}

// PatchTenantCustom 更新租户自定义 runtime_environment (ADR-0022 v0.4):
// hosting_kind=external_endpoint 走 probe_token; clawmanager/k8s_native 不走
// (与 CreateTenantCustom 对称)。
func (s *impl) PatchTenantCustom(ctx context.Context, tenantID, callerAccountID int64, uuid string, in dom.PatchCustomInput) (*dom.Env, error) {
	existing, err := s.r.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if existing.Scope != "tenant" || existing.TenantID == nil || *existing.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	if in.ExternalEnvironmentID != nil {
		normalizedExternalID, normalizeErr := dom.NormalizeExternalEnvironmentID(*in.ExternalEnvironmentID)
		if normalizeErr != nil {
			return nil, apperr.ErrInvalidParams.Withf("%v", normalizeErr)
		}
		if existing.HostingKind != "external_endpoint" && normalizedExternalID != "" {
			return nil, apperr.ErrInvalidParams.Withf("external_environment_id is only supported for external_endpoint")
		}
		in.ExternalEnvironmentID = &normalizedExternalID
	}
	if existing.HostingKind == "external_endpoint" {
		requiresReprobe := isPatchRequiresReprobe(in)
		if requiresReprobe {
			if err := s.verifyProbeTokenForPatch(in.ProbeToken, "tenant", callerAccountID, tenantID, existing, in); err != nil {
				return nil, err
			}
		}
		patched, err := s.r.PatchCustom(ctx, existing.ID, patchFields(in))
		if err != nil {
			return nil, err
		}
		if requiresReprobe {
			return s.r.MarkProbeOK(ctx, patched.ID, "runtime probe passed")
		}
		return patched, nil
	}
	// clawmanager / k8s_native: 直接落库 (probe 由 admin web 调 runtimehosting.probeDraft 把关)
	return s.r.PatchCustom(ctx, existing.ID, patchFields(in))
}

func (s *impl) DeleteTenantCustom(ctx context.Context, tenantID int64, uuid string) error {
	existing, err := s.r.GetByUUID(ctx, uuid)
	if err != nil {
		return err
	}
	if existing.Scope != "tenant" || existing.TenantID == nil || *existing.TenantID != tenantID {
		return apperr.ErrForbidden
	}
	if n, err := s.r.CountAgentsByRuntime(ctx, existing.ID); err != nil {
		return err
	} else if n > 0 {
		return apperr.ErrConflict.Withf("runtime referenced by %d digital_employees", n)
	}
	if n, err := s.r.CountEnablementsByRuntime(ctx, existing.ID); err != nil {
		return err
	} else if n > 0 {
		return apperr.ErrConflict.Withf("runtime still enabled by %d tenants", n)
	}
	return s.r.SoftDelete(ctx, existing.ID)
}

// ===== Client =====

func (s *impl) ListForClient(ctx context.Context, tenantID, accountID int64) (*dom.ClientListResult, error) {
	// F02 v0.3: 取租户已启用 (platform_enabled + tenant_custom)。
	// personal scope 已移除 (ADR-0012); 客户端只看到租户级环境。
	res, err := s.r.EnablementList(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	enabled := append([]dom.Env{}, res.PlatformEnabled...)
	for _, c := range res.TenantCustom {
		enabled = append(enabled, c)
	}
	// Construct a public projection: deployment maps may contain inline credentials.
	// Clearing known SecretRef fields alone does not protect WorkloadEnv/Metadata.
	for i := range enabled {
		enabled[i] = clientEnv(enabled[i])
	}
	return &dom.ClientListResult{
		TenantEnabled: enabled,
		CustomOption:  true,
	}, nil
}

func clientEnv(e dom.Env) dom.Env {
	return dom.Env{
		ID: e.ID, UUID: e.UUID, Scope: e.Scope, TenantID: e.TenantID,
		Name: e.Name, Description: e.Description, Framework: e.Framework,
		HostingKind: e.HostingKind, Status: e.Status, Enabled: e.Enabled,
		IsDefaultForCaller: e.IsDefaultForCaller, EnablementUUID: e.EnablementUUID,
		DataEgress: e.DataEgress, EgressAuditStatus: e.EgressAuditStatus,
	}
}

// ===== Agent create gate =====

func (s *impl) ResolveForAgentCreate(ctx context.Context, tenantID, accountID int64, runtimeUUID string) (*dom.Env, error) {
	rt, err := s.r.GetByUUID(ctx, runtimeUUID)
	if err != nil {
		return nil, err
	}
	// runtime 必须 active + probe ok 才能绑 Agent。
	// 2026-06-25: 还必须最近一次连通性测试通过, 否则创建后会在聊天阶段才失败。
	if rt.Status != "active" || rt.LastProbeStatus != "ok" {
		return nil, apperr.ErrForbidden.Withf("agent.runtime_not_allowed: runtime status=%s probe=%s", rt.Status, rt.LastProbeStatus)
	}
	switch rt.Scope {
	case "platform":
		// 必须在租户 enablements 中。复用三段视图即可。
		res, err := s.r.EnablementList(ctx, tenantID)
		if err != nil {
			return nil, err
		}
		for _, e := range res.PlatformEnabled {
			if e.ID == rt.ID {
				return rt, nil
			}
		}
		return nil, apperr.ErrForbidden.Withf("agent.runtime_not_allowed: platform runtime not enabled for tenant")
	case "tenant":
		if rt.TenantID == nil || *rt.TenantID != tenantID {
			return nil, apperr.ErrForbidden.Withf("agent.runtime_not_allowed: tenant runtime owned by another tenant")
		}
		return rt, nil
	default:
		// F02 v0.3: personal scope 已移除 (ADR-0012); 只剩 platform / tenant。
		return nil, apperr.ErrInvalidParams.Withf("unknown runtime scope %q", rt.Scope)
	}
}

func (s *impl) EnsurePendingInstance(ctx context.Context, tenantID, accountID, runtimeID int64, agentUUID *string) (string, string, error) {
	return s.r.EnsurePendingInstance(ctx, tenantID, accountID, runtimeID, agentUUID)
}

// ===== helpers =====

func redactTenantRuntimeEnvSecrets(items []dom.Env) {
	for i := range items {
		items[i].APIKeySecretRef = ""
		items[i].WorkloadAPITokenSecretRef = ""
		items[i].K8sTokenSecretRef = ""
		items[i].WorkloadEnv = nil
		items[i].ExternalEnvironmentID = ""
	}
}

// verifyProbeToken P1-1 强化版 (Codex 第三轮):
//
// probe 阶段 caller 必须提交 auth.secret_ref (入库引用), probe service 据此算
// AuthConfigSHA256(kind, secret_ref) 写进 token claims。create 阶段 caller 拿
// 同一 token + 必须把同一 api_key_secret_ref 带过来, service 层重算 hash 比对。
// 任何不一致都拒绝, 防止 "probe 用 A, create 改成 B" 偷换。
func (s *impl) verifyProbeToken(tok, scope string, callerAccountID, callerTenantID int64, primaryEndpoint, apiKeyRef string) error {
	if s.token == nil {
		return apperr.ErrInternal.Withf("probe_token issuer not wired")
	}
	if tok == "" {
		return apperr.ErrInvalidParams.Withf("probe_token required")
	}
	if apiKeyRef == "" {
		return apperr.ErrInvalidParams.Withf("api_key_secret_ref required")
	}
	claims, err := s.token.Verify(tok)
	if err != nil {
		return err
	}
	if claims.Scope != scope {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: scope mismatch")
	}
	if claims.CallerAccountID != callerAccountID {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: account mismatch")
	}
	if scope == "tenant" && claims.CallerTenantID != callerTenantID {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: tenant mismatch")
	}
	if claims.EndpointsSHA256 != svcruntime.EndpointsSHA256(map[string]string{"base": primaryEndpoint}) {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: endpoint mismatch")
	}
	// P1-1 真正绑定 auth_config_sha256
	expected := svcruntime.AuthConfigSHA256("bearer", apiKeyRef)
	if claims.AuthConfigSHA256 != expected {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: auth_config mismatch")
	}
	return nil
}

// verifyProbeTokenForPatch P1-3 强化版 (Codex 第四轮):
// 必须校验 caller_account_id / caller_tenant_id / scope / endpoints_sha256 /
// auth_config_sha256 五项, 缺一不可。防 A 用户用自己的 probe_token 改 B 用户/租户
// 的 custom runtime。
func (s *impl) verifyProbeTokenForPatch(tok, scope string, callerAccountID, callerTenantID int64, existing *dom.Env, in dom.PatchCustomInput) error {
	if s.token == nil {
		return apperr.ErrInternal.Withf("probe_token issuer not wired")
	}
	if tok == "" {
		return apperr.ErrInvalidParams.Withf("probe_token required when changing endpoints or secret_ref")
	}
	claims, err := s.token.Verify(tok)
	if err != nil {
		return err
	}
	if claims.Scope != scope {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: scope mismatch")
	}
	if claims.CallerAccountID != callerAccountID {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: account mismatch")
	}
	if scope == "tenant" && claims.CallerTenantID != callerTenantID {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: tenant mismatch")
	}
	primary := existing.PrimaryEndpoint
	if in.PrimaryEndpoint != nil {
		primary = *in.PrimaryEndpoint
	}
	if claims.EndpointsSHA256 != svcruntime.EndpointsSHA256(map[string]string{"base": primary}) {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: endpoint mismatch")
	}
	// secret_ref: 若 patch 显式改了, 用新值; 否则保留 existing。
	ref := existing.APIKeySecretRef
	if in.APIKeySecretRef != nil {
		ref = *in.APIKeySecretRef
	}
	if ref == "" {
		return apperr.ErrInvalidParams.Withf("api_key_secret_ref required")
	}
	expected := svcruntime.AuthConfigSHA256("bearer", ref)
	if claims.AuthConfigSHA256 != expected {
		return apperr.ErrUnauthorized.Withf("tenant_runtime.probe_token_invalid: auth_config mismatch")
	}
	return nil
}

func isPatchRequiresReprobe(in dom.PatchCustomInput) bool {
	if in.PrimaryEndpoint != nil {
		return true
	}
	if in.APIKeySecretRef != nil {
		return true
	}
	return false
}

func patchFields(in dom.PatchCustomInput) map[string]any {
	out := map[string]any{}
	if in.Name != nil {
		out["name"] = *in.Name
	}
	if in.Description != nil {
		out["description"] = *in.Description
	}
	if in.PrimaryEndpoint != nil {
		out["primary_endpoint"] = *in.PrimaryEndpoint
	}
	if in.APIKeySecretRef != nil {
		out["api_key_secret_ref"] = *in.APIKeySecretRef
	}
	if in.ExternalEnvironmentID != nil {
		out["external_environment_id"] = *in.ExternalEnvironmentID
	}
	if in.WorkloadAPIBaseURL != nil {
		out["workload_api_base_url"] = *in.WorkloadAPIBaseURL
	}
	if in.WorkloadAPITokenSecretRef != nil {
		out["workload_api_token_secret_ref"] = *in.WorkloadAPITokenSecretRef
	}
	if in.K8sAPIServerURL != nil {
		out["k8s_api_server_url"] = *in.K8sAPIServerURL
	}
	if in.K8sTokenSecretRef != nil {
		out["k8s_token_secret_ref"] = *in.K8sTokenSecretRef
	}
	if in.K8sNamespace != nil {
		out["k8s_namespace"] = *in.K8sNamespace
	}
	if in.ImageRepository != nil {
		out["image_repository"] = *in.ImageRepository
	}
	if in.ImageTag != nil {
		out["image_tag"] = *in.ImageTag
	}
	if in.DataEgress != nil {
		out["data_egress"] = *in.DataEgress
	}
	if in.RateLimit != nil {
		out["rate_limit"] = in.RateLimit
	}
	if in.Metadata != nil {
		out["metadata"] = in.Metadata
	}
	return out
}

func buildCustomEnv(in dom.CreateCustomInput, scope string, tenantID *int64) *dom.Env {
	return &dom.Env{
		Name:                      strings.TrimSpace(in.Name),
		Description:               in.Description,
		Framework:                 in.Framework,
		HostingKind:               in.HostingKind,
		Scope:                     scope,
		TenantID:                  tenantID,
		PrimaryEndpoint:           in.PrimaryEndpoint,
		APIKeySecretRef:           in.APIKeySecretRef,
		ExternalEnvironmentID:     in.ExternalEnvironmentID,
		WorkloadAPIBaseURL:        in.WorkloadAPIBaseURL,
		WorkloadAPITokenSecretRef: in.WorkloadAPITokenSecretRef,
		K8sAPIServerURL:           in.K8sAPIServerURL,
		K8sTokenSecretRef:         in.K8sTokenSecretRef,
		K8sNamespace:              in.K8sNamespace,
		K8sInsecureSkipVerify:     in.K8sInsecureSkipVerify,
		ImageRepository:           in.ImageRepository,
		ImageTag:                  in.ImageTag,
		GatewayPort:               in.GatewayPort,
		MountPath:                 in.MountPath,
		StorageClass:              in.StorageClass,
		DefaultCPUCores:           in.DefaultCPUCores,
		DefaultMemoryGB:           in.DefaultMemoryGB,
		DefaultDiskGB:             in.DefaultDiskGB,
		WorkloadEnv:               in.WorkloadEnv,
		LLMDefaultModel:           in.LLMDefaultModel,
		HTTPProxy:                 in.HTTPProxy,
		HTTPSProxy:                in.HTTPSProxy,
		NoProxy:                   in.NoProxy,
		DataEgress:                defaultStr(in.DataEgress, "platform-only"),
		RateLimit:                 in.RateLimit,
		Metadata:                  in.Metadata,
	}
}

func defaultStr(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// stringifyEndpoints 把 map[string]any 的 endpoints 落到 svcruntime.EndpointsSHA256
// 期望的 map[string]string。非 string value 丢弃 (probe 阶段就是 string-only)。
func stringifyEndpoints(in map[string]any) map[string]string {
	out := make(map[string]string, len(in))
	for k, v := range in {
		if s, ok := v.(string); ok && s != "" {
			out[k] = s
		}
	}
	return out
}

// fillBoundAgents 给每个 Env 填 BoundAgents 计数。
func (s *impl) fillBoundAgents(ctx context.Context, envs []dom.Env) ([]dom.Env, error) {
	for i := range envs {
		n, err := s.r.CountAgentsByRuntime(ctx, envs[i].ID)
		if err != nil {
			return nil, err
		}
		envs[i].BoundAgents = n
	}
	return envs, nil
}
