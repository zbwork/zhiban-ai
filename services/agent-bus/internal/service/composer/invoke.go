// invoke.go — ZAP backchannel /zap/v1/internal/skills/invoke 实现 (M6 Phase A §4.2).
//
// 6 步校验链 (每条独立错误码):
//  1. session_token 合法 (解出 tenant_id / agent / conversation)   → zap.session_invalid
//  2. agent.integration_mode ∈ (platform_managed, hybrid)            → zap.borrow_forbidden_self_hosted
//  3. agent 已装配此 skill                                            → zap.skill_not_attached
//  4. skill.exec_kind = platform_backchannel                          → zap.skill_exec_mismatch
//  5. hosting 兼容 (available_to_hybrid for hybrid)                   → zap.skill_not_available_to_hybrid
//  6. composer_params JSON 解析 + 字节上限                            → zap.skill_params_invalid
//
// 执行:
//
//	Phase A 仅实现 1 个 platform_backchannel skill: image_generation.
//	不调真实模型; 直接返 placeholder result_blocks (markdown + image) — 证明
//	Bus 校验链 + 注入路径走通.
//
// audit:
//
//	成功 → audit.skill.invoked
//	失败 → audit.skill.invoke_failed (含 error_code)
package composer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (s *impl) Invoke(ctx context.Context, in InvokeInput) (*InvokeResult, error) {
	// Step 1 — session_token → tenantID / agentUUID / conversationUUID
	agentUUID, tenantID, accountID, _, sessOK := s.resolveSession(ctx, in)
	if !sessOK {
		return nil, s.invokeFail(ctx, "", 0, in.SkillUUID, ErrCodeZAPSessionInvalid, "session token invalid or missing")
	}

	ag, err := s.agents.GetByUUID(ctx, agentUUID)
	if err != nil {
		return nil, s.invokeFail(ctx, agentUUID, tenantID, in.SkillUUID, ErrCodeZAPSessionInvalid, "agent lookup failed: "+err.Error())
	}
	// 防 cross-tenant: session.tenant_id 必须等于 agent.tenant_id.
	if tenantID > 0 && ag.TenantID != tenantID && ag.Source != "platform" {
		return nil, s.invokeFail(ctx, agentUUID, tenantID, in.SkillUUID, ErrCodeZAPSessionInvalid, "session tenant mismatch agent tenant")
	}
	effectiveTenantID := tenantID
	if effectiveTenantID <= 0 {
		effectiveTenantID = ag.TenantID
	}

	// Step 2 — integration_mode 闸口
	if integrationModeOrDefault(ag.IntegrationMode) != "platform_managed" && integrationModeOrDefault(ag.IntegrationMode) != "hybrid" {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPBorrowForbiddenSelf,
			"agent integration_mode="+integrationModeOrDefault(ag.IntegrationMode)+" cannot borrow platform skill")
	}

	// Step 3 — agent 已装配此 skill
	sk, err := s.AssertSkillAttached(ctx, ag.ID, in.SkillUUID)
	if err != nil {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillNotAttached, err.Error())
	}

	// Step 4 — exec_kind = platform_backchannel
	if sk.ExecKind != "platform_backchannel" {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillExecMismatch,
			"skill exec_kind="+sk.ExecKind+" expected platform_backchannel")
	}

	// Step 5 — hosting 兼容
	if integrationModeOrDefault(ag.IntegrationMode) == "hybrid" && !sk.AvailableToHybrid {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillNotAvailHybrid,
			"skill not available to hybrid agents")
	}
	if integrationModeOrDefault(ag.IntegrationMode) == "platform_managed" && !sk.AvailableToPlatformManaged {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillNotAvailHybrid,
			"skill not available to platform_managed agents")
	}

	// Step 6 — params 上限
	body, err := json.Marshal(in.Params)
	if err != nil {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillParamsInvalid,
			"composer_params not json serializable: "+err.Error())
	}
	if len(body) > ComposerParamsMaxBytes {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPSkillParamsInvalid,
			fmt.Sprintf("composer_params %d bytes exceeds max %d", len(body), ComposerParamsMaxBytes))
	}

	charge, err := s.chargeSkillIfConfigured(ctx, ag, sk, in, effectiveTenantID, accountID, body)
	if err != nil {
		return nil, err
	}
	if charge != nil && !charge.Allowed {
		return nil, s.invokeFail(ctx, agentUUID, effectiveTenantID, in.SkillUUID, ErrCodeZAPBillingInsufficient,
			"insufficient credits for skill call: "+charge.Reason)
	}

	// 执行 — Phase A 只有 image_generation 一个 stub.
	result := s.runBackchannelSkill(sk, in.Params)
	attachBillingUsage(result, charge)

	// audit 成功
	if s.audit != nil {
		_ = s.audit.PublishWithTx(ctx, "audit.skill.invoked",
			effectiveTenantID,
			"skill_invoked:"+ag.UUID+":"+sk.UUID+":"+in.SourceMessageUUID,
			map[string]any{
				"resource_kind":        "composer_skill",
				"resource_uuid":        sk.UUID,
				"skill_code":           sk.Code,
				"agent_uuid":           ag.UUID,
				"de_id":                ag.ID,
				"integration_mode":     integrationModeOrDefault(ag.IntegrationMode),
				"source_message_uuid":  in.SourceMessageUUID,
				"operation_code":       strings.TrimSpace(in.OperationCode),
				"params_bytes":         len(body),
				"billing_credits_cost": billingCreditsCost(charge),
			})
	}
	return result, nil
}

func (s *impl) chargeSkillIfConfigured(ctx context.Context, ag *AgentInfo, sk *Skill, in InvokeInput, tenantID, accountID int64, paramsBody []byte) (*dombilling.SkillChargeResult, error) {
	if s.billing == nil {
		return nil, nil
	}
	idempotencyKey := strings.TrimSpace(in.IdempotencyKey)
	if idempotencyKey == "" {
		idempotencyKey = defaultSkillBillingIdempotencyKey(ag.UUID, in.SourceMessageUUID, sk.UUID, in.OperationCode, paramsBody)
	}
	agentID := ag.ID
	metadata, _ := json.Marshal(map[string]any{
		"surface":             "zap_internal_skills_invoke",
		"resource_kind":       "composer_skill",
		"composer_skill_id":   sk.ID,
		"composer_skill_uuid": sk.UUID,
		"composer_skill_code": sk.Code,
		"agent_uuid":          ag.UUID,
		"source_message_uuid": in.SourceMessageUUID,
		"operation_code":      strings.TrimSpace(in.OperationCode),
		"idempotency_key":     idempotencyKey,
	})
	charge, err := s.billing.ChargeSkillCallBySkillUUID(ctx, dombilling.ChargeSkillCallInput{
		TenantID:       tenantID,
		AccountID:      accountID,
		AgentID:        &agentID,
		AgentUUID:      ag.UUID,
		SkillUUID:      sk.UUID,
		OperationCode:  in.OperationCode,
		IdempotencyKey: idempotencyKey,
		Metadata:       metadata,
	})
	if err != nil {
		if isBillingNotFound(err) {
			// 兼容旧 composer_skills：只有同 UUID 已迁入 F03 skills 且配置了计费时才扣费。
			return nil, nil
		}
		return nil, s.invokeFail(ctx, ag.UUID, tenantID, sk.UUID, ErrCodeZAPBillingInvalid, err.Error())
	}
	return charge, nil
}

func defaultSkillBillingIdempotencyKey(agentUUID, sourceMessageUUID, skillUUID, operationCode string, paramsBody []byte) string {
	payload := strings.Join([]string{
		agentUUID,
		sourceMessageUUID,
		skillUUID,
		strings.TrimSpace(operationCode),
		string(paramsBody),
	}, "\x00")
	sum := sha256.Sum256([]byte(payload))
	return "zap_skill_invoke:" + hex.EncodeToString(sum[:])
}

func attachBillingUsage(result *InvokeResult, charge *dombilling.SkillChargeResult) {
	if result == nil || charge == nil {
		return
	}
	if result.Usage == nil {
		result.Usage = map[string]any{}
	}
	result.Usage["billing_type"] = charge.BillingType
	result.Usage["pricing_mode"] = charge.PricingMode
	result.Usage["operation_code"] = charge.OperationCode
	result.Usage["credits_cost"] = charge.CreditsCost
	result.Usage["balance_after"] = charge.BalanceAfter
	if charge.UsageEvent != nil {
		result.Usage["billing_usage_event_id"] = charge.UsageEvent.ID
		result.Usage["billing_idempotency_key"] = charge.UsageEvent.IdempotencyKey
	}
}

func billingCreditsCost(charge *dombilling.SkillChargeResult) int64 {
	if charge == nil {
		return 0
	}
	return charge.CreditsCost
}

func isBillingNotFound(err error) bool {
	if e, ok := apperr.AsError(err); ok && e.Code == apperr.NotFound {
		return true
	}
	return false
}

// resolveSession 把 session_token 转成 agentUUID / tenantID / conversationUUID.
//
// 优先级:
//  1. sessions Resolver 注入 → 用它解
//  2. nil resolver + InvokeInput.AgentUUID 非空 → 直接走单测/smoke 路径
//  3. 都没 → ok=false
func (s *impl) resolveSession(ctx context.Context, in InvokeInput) (agentUUID string, tenantID int64, accountID int64, conversationUUID string, ok bool) {
	if s.sessions != nil && in.SessionToken != "" {
		sess, err := s.sessions.Resolve(ctx, in.SessionToken)
		if err == nil && sess != nil && sess.AgentUUID != "" {
			return sess.AgentUUID, sess.TenantID, sess.AccountID, sess.ConversationUUID, true
		}
	}
	if in.AgentUUID != "" {
		return in.AgentUUID, 0, 0, "", true
	}
	return "", 0, 0, "", false
}

// runBackchannelSkill Phase A stub renderer.
//
// 仅 image_generation 一个 skill 走 backchannel; 其它 platform_backchannel skill 命中
// 这里 (如果后期加) → 默认返一个 markdown placeholder, caller 应在 Phase B 替换.
func (s *impl) runBackchannelSkill(sk *Skill, params map[string]any) *InvokeResult {
	if sk.Code == "image_generation" {
		prompt, _ := params["prompt"].(string)
		model, _ := params["model"].(string)
		if model == "" {
			model = "stub-v0"
		}
		return &InvokeResult{
			ResultBlocks: []map[string]any{
				{"kind": "markdown", "data": map[string]any{"text": "[预留] 已收到生成请求 (Phase A stub)"}},
				{"kind": "image", "data": map[string]any{
					"url":    "https://placeholder.zhiban.invalid/img.png",
					"prompt": prompt,
					"model":  model,
				}},
			},
			Usage: map[string]any{
				"input_tokens":  0,
				"output_tokens": 0,
				"cost_cents":    0,
			},
		}
	}
	return &InvokeResult{
		ResultBlocks: []map[string]any{
			{"kind": "markdown", "data": map[string]any{
				"text": "[预留] platform_backchannel skill " + sk.Code + " 暂未实现 renderer",
			}},
		},
		Usage: map[string]any{"input_tokens": 0, "output_tokens": 0, "cost_cents": 0},
	}
}

// invokeFail 转 err + 顺手发 audit.skill.invoke_failed.
//
// 返回 apperr.ErrForbidden 携带原始 errCode 在 Message 上; transport 层据此返 403 +
// JSON body `{code: <errCode>, message: ...}`.
func (s *impl) invokeFail(ctx context.Context, agentUUID string, tenantID int64, skillUUID, errCode, msg string) error {
	if s.audit != nil {
		_ = s.audit.PublishWithTx(ctx, "audit.skill.invoke_failed",
			tenantID,
			"skill_invoke_failed:"+skillUUID+":"+strconv.FormatInt(tenantID, 10)+":"+errCode,
			map[string]any{
				"resource_kind": "composer_skill",
				"resource_uuid": skillUUID,
				"agent_uuid":    agentUUID,
				"error_code":    errCode,
				"error_message": msg,
			})
	}
	// errCode 已经是稳定字符串, 用作 message; transport 层 encode 时按 message 投出 JSON.
	return apperr.ErrForbidden.Withf("%s: %s", errCode, msg)
}

// ErrorCode 给 transport 层用: 从 err 抽 backchannel 错误码.
//
// 约定: invokeFail 用 apperr.ErrForbidden.Withf("<errCode>: <msg>") 包装.
// transport 层调 ErrorCode(err) 拿到 errCode (zap.*); 没匹配到 → "".
func ErrorCode(err error) string {
	if e, ok := apperr.AsError(err); ok && e != nil {
		msg := e.Message
		// "forbidden: zap.skill_not_attached: ..." → 取 "zap.skill_not_attached"
		for _, prefix := range []string{"forbidden: ", "invalid params: ", "internal error: "} {
			if len(msg) > len(prefix) && msg[:len(prefix)] == prefix {
				msg = msg[len(prefix):]
				break
			}
		}
		if i := indexByte(msg, ':'); i > 0 {
			return msg[:i]
		}
		return msg
	}
	return ""
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
