package agent

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// BuildSnapshot 把 digital_employees + 草稿能力绑定打包成快照 JSON。
func BuildSnapshot(de *dom.DigitalEmployee, bindings []dom.CapabilityBinding) map[string]any {
	caps := make([]map[string]any, 0, len(bindings))
	for _, b := range bindings {
		if b.AgentVersionID != nil {
			continue // 只打草稿
		}
		caps = append(caps, map[string]any{
			"kind":           b.CapabilityKind,
			"uuid":           b.CapabilityUUID,
			"source":         b.Source,
			"granted_tools":  b.GrantedTools,
			"granted_scopes": b.GrantedScopes,
			"sort_order":     b.SortOrder,
			"pinned":         b.Pinned,
			"recall_config":  b.RecallConfig,
		})
	}
	return map[string]any{
		"name":                   de.Name,
		"avatar_url":             de.AvatarURL,
		"intro":                  de.Intro,
		"description":            de.Description,
		"welcome_msg":            de.WelcomeMsg,
		"recommended_questions":  de.RecommendedQuestions,
		"tags":                   de.Tags,
		"visibility":             de.Visibility,
		"workspace_id":           de.WorkspaceID,
		"runtime_environment_id": de.RuntimeEnvironmentID,
		"execution_locus":        de.ExecutionLocus,
		"local_engine":           de.LocalEngine,
		"model_primary":          de.ModelPrimary,
		"model_fallbacks":        de.ModelFallbacks,
		// ADR-0037: BYOK 来源标记 + 协议/base_url/model_id (不含密钥)。真正解密取
		// api_key 的动作留给 Phase 3, 届时直接查 digital_employees 当前行的密文列
		// (按 agent_uuid 定位), 不经过这份快照。
		"model_source":          de.ModelSource,
		"model_service_config":  parseModelServiceConfigForSnapshot(de.ModelServiceConfigJSON),
		"temperature":           de.Temperature,
		"context_window":        de.ContextWindow,
		"tool_allow":            de.ToolAllow,
		"tool_deny":             de.ToolDeny,
		"capabilities_declared": de.CapabilitiesDeclared,
		"callable_by_agents":    de.CallableByAgentsJSON,
		"supports_group_chat":   de.SupportsGroupChat,
		"metadata":              de.Metadata,
		"capability_bindings":   caps,
		"system_prompt":         extractSystemPrompt(de.Metadata),
	}
}

// parseModelServiceConfigForSnapshot 把 model_service_config 的 JSON 字符串解成
// map 存进快照 (跟 capabilities_declared/metadata 同款), 而不是 double-encode 的字符串。
// 空/非法值一律按空 map 处理 (非 byok 数字员工的常态)。
func parseModelServiceConfigForSnapshot(raw string) map[string]any {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return map[string]any{}
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(raw), &out); err != nil || out == nil {
		return map[string]any{}
	}
	return out
}

func extractSystemPrompt(meta map[string]any) string {
	if meta == nil {
		return ""
	}
	if v, ok := meta["system_prompt"].(string); ok {
		return v
	}
	return ""
}

// PublishVersion 把当前草稿快照成新版本 (Batch 2C T2C.3 三阶段 + OpenClaw 同步)。
//
// 阶段 1 校验:
//   - 跨租户拒
//   - runtime 必须非空 + active + approved + probe ok (Q2 hard fail)
//
// 阶段 2 OpenClaw 同步:
//   - syncer.Sync: agents add + tar 流写 7 md + CLAUDE.md 镜像
//   - 失败 -> 调 syncer.Remove (compensation) + audit.agent.publish_failed
//   - 返回 *OpenClawSyncError (transport 翻译 409 openclaw_sync_failed)
//
// 阶段 3 DB 短 tx:
//   - repo.PublishVersion: 写 agent_versions + 复制草稿 bindings + UPDATE current_version + status='published'
//   - audit.agent.published + PG NOTIFY
//   - 失败 -> 调 syncer.Remove 补偿 + audit.publish_compensation_failed
func (s *impl) PublishVersion(ctx context.Context, accountID, tenantID, deID int64, notes string) (*dom.Version, *dom.DigitalEmployee, error) {
	de, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return nil, nil, err
	}
	// 阶段 1: 跨租户校验
	if de.Source == "platform" {
		if tenantID > 0 {
			return nil, nil, apperr.ErrForbidden.Withf("仅平台管理员可发布平台预置 Agent")
		}
	} else if de.TenantID != tenantID {
		return nil, nil, apperr.ErrForbidden
	}
	// 阶段 1: 普通数字员工 runtime 必须非空 + active + approved + probe ok (Q2)。
	// support_builtin 是 Bus 内置执行器, 不需要 runtime_environment_id, 不触发外部运行时同步。
	if de.ExecutionLocus != "local" && !isSupportBuiltinAgent(de) {
		if de.RuntimeEnvironmentID == nil || *de.RuntimeEnvironmentID <= 0 {
			return nil, nil, apperr.ErrInvalidParams.Withf("publish 前必须绑定 runtime")
		}
		if de.Source == "platform" {
			if err := s.checkPlatformPresetRuntime(ctx, de.RuntimeEnvironmentID); err != nil {
				return nil, nil, err
			}
		} else {
			if err := s.checkRuntimeBindableWithSelf(ctx, de.RuntimeEnvironmentID, de.ID); err != nil {
				return nil, nil, err
			}
		}
		if changed, err := s.ensureManagedZAPAgentKey(ctx, de, de.ID); err != nil {
			return nil, nil, err
		} else if changed {
			de, err = s.repo.Update(ctx, de)
			if err != nil {
				return nil, nil, err
			}
		}
	}

	// 阶段 2: OpenClaw 同步 (失败 DB 不动 + 补偿)。
	// 平台预置数字员工是静态模版资产，发布只表示对租户可见并固化版本；
	// 它不归属任何租户运行实例，因此不在平台侧写入 OpenClaw。
	//
	// Plan 17 §6 修正: 非 openclaw framework (例如 ZAP) 也跳过 syncer — syncer 写
	// OpenClaw 容器, 对 ZAP runtime 无意义且会因找不到 openclaw 容器报 cli_exec 失败,
	// 阻止 ZAP 数字员工 publish。doc-12 §11.5 已对租户增量 resync 做 framework 区分,
	// 这里把 publish 路径补齐。
	shouldSyncRuntime := de.ExecutionLocus != "local" && de.Source != "platform" && !isSupportBuiltinAgent(de)
	if shouldSyncRuntime && s.rtRead != nil && de.RuntimeEnvironmentID != nil {
		if reg, rerr := s.rtRead.Get(ctx, *de.RuntimeEnvironmentID); rerr == nil && reg != nil {
			fw := strings.ToLower(strings.TrimSpace(reg.Framework))
			// 空 Framework 视为历史 openclaw (向后兼容; t2c3 单测 fixture 不设 Framework
			// 仍走 syncer 路径)。显式非 openclaw → 跳过, 见 Plan 17 §6。
			if fw != "" && fw != "openclaw" {
				shouldSyncRuntime = false
			}
		}
	}
	if shouldSyncRuntime && s.syncer != nil {
		if err := s.syncer.Sync(ctx, de); err != nil {
			_ = s.syncer.Remove(ctx, de) // compensation, best-effort
			s.auditAfter(ctx, "audit.agent.publish_failed", tenantID, accountID,
				"agent_publish_fail:"+strconv.FormatInt(deID, 10),
				publishFailedAudit(de, err))
			return nil, nil, err // *OpenClawSyncError
		}
	}

	// 阶段 3: DB 短 tx (snapshot + version + UPDATE current_version + status='published')
	bindings, err := s.repo.ListBindings(ctx, deID)
	if err != nil {
		// 此时 OpenClaw 已 Sync 成功, DB 步骤失败 -> 补偿
		if shouldSyncRuntime && s.syncer != nil {
			_ = s.syncer.Remove(ctx, de)
		}
		s.auditAfter(ctx, "audit.agent.publish_compensation_failed", tenantID, accountID,
			"agent_publish_comp_fail:"+strconv.FormatInt(deID, 10),
			map[string]any{"resource_kind": "agent", "resource_uuid": de.UUID, "de_id": deID, "db_error": err.Error()})
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	snap := BuildSnapshot(de, bindings)
	v, err := s.repo.PublishVersion(ctx, deID, snap, accountID, notes)
	if err != nil {
		if shouldSyncRuntime && s.syncer != nil {
			_ = s.syncer.Remove(ctx, de)
		}
		s.auditAfter(ctx, "audit.agent.publish_compensation_failed", tenantID, accountID,
			"agent_publish_comp_fail:"+strconv.FormatInt(deID, 10),
			map[string]any{"resource_kind": "agent", "resource_uuid": de.UUID, "de_id": deID, "db_error": err.Error()})
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	updated, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return nil, nil, err
	}
	s.notify(ctx, agentPayload(deID))
	s.auditAfter(ctx, "audit.agent.published", tenantID, accountID,
		"agent_publish:"+strconv.FormatInt(deID, 10),
		map[string]any{
			"resource_kind":   "agent",
			"resource_uuid":   updated.UUID,
			"de_id":           deID,
			"current_version": updated.CurrentVersion,
			"openclaw_synced": shouldSyncRuntime && s.syncer != nil,
		})
	// doc-12 §11.5 Task C: 发布成功后增量同步到该租户已 ready 实例 (best-effort, 不阻塞、不改历史会话)。
	// 平台模板 (updated.TenantID==0) 不自动传播 → enqueueRuntimeResync 内部 tenant<=0 跳过。
	if updated.ExecutionLocus != "local" {
		s.enqueueRuntimeResync(ctx, updated.TenantID, updated.UUID, "publish")
	}
	return v, updated, nil
}

func (s *impl) ListVersions(ctx context.Context, tenantID, deID int64) ([]dom.Version, error) {
	de, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return nil, err
	}
	if de.TenantID != tenantID && de.Source != "platform" {
		return nil, apperr.ErrForbidden
	}
	return s.repo.ListVersions(ctx, deID)
}

func (s *impl) Gray(ctx context.Context, accountID, tenantID, deID int64, version, pct int, groups []string) (*dom.Version, error) {
	de, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return nil, err
	}
	if de.Source == "platform" {
		if tenantID > 0 {
			return nil, apperr.ErrForbidden
		}
	} else if de.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	target, err := s.repo.GetVersion(ctx, deID, version)
	if err != nil {
		return nil, err
	}
	if target.Status != "published" && target.Status != "grayed" {
		return nil, apperr.ErrInvalidParams.Withf("仅 published/grayed 版本可灰度, 当前=%s", target.Status)
	}
	v, err := s.repo.SetGrayscale(ctx, deID, version, pct, groups)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(deID))
	return v, nil
}

func (s *impl) Rollback(ctx context.Context, accountID, tenantID, deID int64, version int) (*dom.DigitalEmployee, error) {
	de, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return nil, err
	}
	if de.Source == "platform" {
		if tenantID > 0 {
			return nil, apperr.ErrForbidden
		}
	} else if de.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	out, err := s.repo.Rollback(ctx, deID, version)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, agentPayload(deID))
	return out, nil
}

// PickVersion 灰度命中规则: 命中 → 灰度版本号, 否则 → current_version。
// callerDeptPath 形如 `/集团/银行业务部/招行/信用卡中心`; 命中规则为前缀 (deptPath 是 group 的子或等于)。
func (s *impl) PickVersion(ctx context.Context, deID, accountID int64, callerDeptPath string) (int, error) {
	de, err := s.repo.GetByID(ctx, deID)
	if err != nil {
		return 0, err
	}
	versions, err := s.repo.ListVersions(ctx, deID)
	if err != nil {
		return 0, err
	}
	for _, v := range versions {
		if v.Status != "grayed" {
			continue
		}
		if matchGrayDept(v.GrayscaleGroups, callerDeptPath) || hashHit(deID, accountID, v.GrayscalePct) {
			return v.Version, nil
		}
	}
	return de.CurrentVersion, nil
}

func matchGrayDept(groups []string, deptPath string) bool {
	if deptPath == "" {
		return false
	}
	for _, g := range groups {
		if g == "" {
			continue
		}
		if g == deptPath {
			return true
		}
		if strings.HasPrefix(deptPath, strings.TrimRight(g, "/")+"/") {
			return true
		}
	}
	return false
}

func hashHit(deID, accountID int64, pct int) bool {
	if pct <= 0 {
		return false
	}
	if pct >= 100 {
		return true
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(strconv.FormatInt(deID, 10) + ":" + strconv.FormatInt(accountID, 10)))
	return int(h.Sum32()%100) < pct
}

// --- A2A whitelist ---

func (s *impl) ListCallable(ctx context.Context, tenantID, calleeID int64) ([]dom.CalleeWhitelistEntry, error) {
	de, err := s.repo.GetByID(ctx, calleeID)
	if err != nil {
		return nil, err
	}
	if de.TenantID != tenantID && de.Source != "platform" {
		return nil, apperr.ErrForbidden
	}
	return s.repo.ListCallableWhitelist(ctx, calleeID)
}

func (s *impl) AddCallable(ctx context.Context, accountID, tenantID, calleeID, callerID int64, note string) (*dom.CalleeWhitelistEntry, error) {
	de, err := s.repo.GetByID(ctx, calleeID)
	if err != nil {
		return nil, err
	}
	if de.TenantID != tenantID {
		return nil, apperr.ErrForbidden
	}
	caller, err := s.repo.GetByID(ctx, callerID)
	if err != nil {
		return nil, err
	}
	if caller.TenantID != tenantID && caller.Source != "platform" {
		return nil, apperr.ErrInvalidParams.Withf("caller 跨租户")
	}
	by := accountID
	out, err := s.repo.AddCallableWhitelist(ctx, calleeID, callerID, &by, note)
	if err != nil {
		return nil, err
	}
	s.notify(ctx, "callable:"+strconv.FormatInt(calleeID, 10))
	return out, nil
}

func (s *impl) DeleteCallable(ctx context.Context, tenantID, entryID int64) error {
	if err := s.repo.DeleteCallableWhitelist(ctx, entryID); err != nil {
		return err
	}
	return nil
}
