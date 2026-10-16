package chat

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	zapadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime/zap"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
)

// ZAP-1.1 §11 技能接线 (F03 §3.5/§6.5):
//
//  1. POST /sessions body.skills —— EnsureSession 前由 ZapSkillsCarrierBuilder 构造 (见 runZapChatInline)。
//  2. 出站 user message metadata 透传客户端 active_skill_* / skill_params (zapForwardedUserMetadataKeys)。
//  3. 绑定变化后 live session 全量 resync —— ZapSkillsResyncer 由 prewarm worker drain runtime_resync_outbox 时调用。
//     只用 §11.3 resync (整套快照 + seq 归零), 不做 §11.2 PATCH 增量 (Bus 侧不维护 per-session patch_seq)。

// ZapSkillsCarrierBuilder 构造 (tenant, account, agent) 的 skills 节 (cmd 用 service/skill.Service 适配)。
// 返回 nil 节 = 不带 skills (等价空集)。
type ZapSkillsCarrierBuilder interface {
	BuildZapSessionSkills(ctx context.Context, tenantID, accountID int64, agentUUID string) (any, error)
}

// WithZapSkillsCarrier 注入技能集构造器; nil → POST /sessions 不带 skills 节 (行为同旧)。
func WithZapSkillsCarrier(b ZapSkillsCarrierBuilder) ZapDispatcherOption {
	return func(d *zapDispatcherImpl) { d.skills = b }
}

// SetZapSkillsCarrierOnDispatcher 在 dispatcher 构造后注入 (cmd/bus 的 skill service 比 dispatcher 晚装配)。
func SetZapSkillsCarrierOnDispatcher(d ZapDispatcher, b ZapSkillsCarrierBuilder) {
	if impl, ok := d.(*zapDispatcherImpl); ok && impl != nil {
		impl.skills = b
	}
}

// zapForwardedUserMetadataKeys user message metadata 里原样透传给 ZAP runtime 的键 (F03 §4.4 / §11.1)。
// 只放白名单: 其它 metadata (composer_* / 内部标记) 不出站。
var zapForwardedUserMetadataKeys = []string{
	"active_skill_uuid", "active_skill_kind", "active_skill_builtin_key",
	"active_skill_code", "active_skill_version", "skill_params",
}

// mergeZapForwardedUserMetadata 把白名单键并入出站 metadata (不覆盖 llm_context 等已有键)。
func mergeZapForwardedUserMetadata(dst, userMeta map[string]any) map[string]any {
	if len(userMeta) == 0 {
		return dst
	}
	if dst == nil {
		dst = map[string]any{}
	}
	for _, k := range zapForwardedUserMetadataKeys {
		v, ok := userMeta[k]
		if !ok || v == nil {
			continue
		}
		if _, taken := dst[k]; taken {
			continue
		}
		dst[k] = v
	}
	return dst
}

// buildZapSessionSkills best-effort 构造 skills 节; 失败只 Warn 不阻断开会话 (技能是增强, 不是聊天前提)。
func (d *zapDispatcherImpl) buildZapSessionSkills(ctx context.Context, in ZapDispatchInput) any {
	if d == nil || d.skills == nil || in.Agent == nil {
		return nil
	}
	node, err := d.skills.BuildZapSessionSkills(ctx, in.TenantID, in.AccountID, in.Agent.UUID)
	if err != nil {
		if d.parent != nil && d.parent.logger != nil {
			d.parent.logger.Warn(ctx, "chat zap skills carrier build failed; session opens without skills",
				"stream_id", in.StreamID, "agent_uuid", in.Agent.UUID, "err", err.Error())
		}
		return nil
	}
	return node
}

// ---------------------------------------------------------------------------
// live session resync
// ---------------------------------------------------------------------------

// ZapLiveSession 一条仍在有效期内的 ZAP 会话 (conversations.metadata.zap_session_id / zap_session_expires_at)。
type ZapLiveSession = domconv.ZapLiveSession

// ZapLiveSessionLister 列出某数字员工在租户内未过期的 ZAP 会话 (single-chat + agent 直聊房间)。
type ZapLiveSessionLister interface {
	ListLiveZapSessions(ctx context.Context, tenantID, agentID int64, now time.Time) ([]ZapLiveSession, error)
}

// ZapSkillsResyncClient 协议层 §11.3 出站 (cmd 侧用 adapter/zapclient.Client 适配)。
// Routed 返回带会话亲和键的客户端 (多副本 runtime 下 resync 必须打到持有该会话的副本)。
type ZapSkillsResyncClient interface {
	ResyncSkills(ctx context.Context, sessionID string, body any) error
	Routed(routingKey string) ZapSkillsResyncClient
}

// ZapSkillsResyncClientFactory 按 (baseURL, apiKey) 造客户端; 单测注入 fake。
type ZapSkillsResyncClientFactory func(baseURL, apiKey string) ZapSkillsResyncClient

type zapResyncLogger interface {
	Info(ctx context.Context, msg string, kv ...any)
	Warn(ctx context.Context, msg string, kv ...any)
}

// ZapSkillsResyncer 绑定变化后把最新技能集推给该数字员工所有 live ZAP 会话 (§11.3 全量 resync)。
//
// 非 ZAP framework / 无 live 会话 → no-op (返回 0, nil)。单会话失败记录并继续, 最终返回聚合错误
// (调用方 worker 据此 retry; resync 幂等, 重推无副作用)。
type ZapSkillsResyncer struct {
	agents   domagent.Repository
	envs     ZapRuntimeEnvReader
	secret   ZapSecretResolver
	sessions ZapLiveSessionLister
	skills   ZapSkillsCarrierBuilder
	fact     ZapSkillsResyncClientFactory
	logger   zapResyncLogger
	// maxSessions 单次 resync 上限 (防止极端租户拖垮 worker 一轮); 超出部分下次信号再推。
	maxSessions int
}

// NewZapSkillsResyncer 构造; fact=nil 时调用方必须在 cmd 侧注入真实 zapclient 工厂 (本包不 import adapter/zapclient)。
func NewZapSkillsResyncer(agents domagent.Repository, envs ZapRuntimeEnvReader, secret ZapSecretResolver,
	sessions ZapLiveSessionLister, skills ZapSkillsCarrierBuilder, fact ZapSkillsResyncClientFactory, logger zapResyncLogger) *ZapSkillsResyncer {
	return &ZapSkillsResyncer{agents: agents, envs: envs, secret: secret, sessions: sessions, skills: skills, fact: fact, logger: logger, maxSessions: 200}
}

// ResyncLiveSessions 对 (tenant, de) 的 live ZAP 会话逐个推送最新 skills 快照。返回成功推送数。
func (r *ZapSkillsResyncer) ResyncLiveSessions(ctx context.Context, tenantID int64, deUUID string) (int, error) {
	if r == nil || r.agents == nil || r.envs == nil || r.secret == nil || r.sessions == nil || r.skills == nil || r.fact == nil {
		return 0, errors.New("zap skills resync not wired")
	}
	if tenantID <= 0 || strings.TrimSpace(deUUID) == "" {
		return 0, errors.New("zap skills resync: tenant and digital employee required")
	}
	ag, err := r.agents.GetByUUID(ctx, deUUID)
	if err != nil {
		return 0, err
	}
	if ag == nil || ag.TenantID != tenantID || ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID <= 0 {
		return 0, nil
	}
	env, err := r.envs.GetByID(ctx, *ag.RuntimeEnvironmentID)
	if err != nil {
		return 0, err
	}
	if env == nil || !isDSHFramework(env.Framework) {
		return 0, nil // 技能 resync 仅对平台自营 dsh; 外部 ZAP runtime 自管技能, 无 /skills/resync
	}
	if err := validateZapRuntimeEnvReady(env); err != nil {
		return 0, nil // 未就绪的 env 不会有 live 会话; 有也推不动, 不算错
	}
	baseURL := strings.TrimSpace(env.PrimaryEndpoint)
	if baseURL == "" {
		return 0, nil
	}
	if _, err := url.Parse(baseURL); err != nil {
		return 0, nil
	}
	live, err := r.sessions.ListLiveZapSessions(ctx, tenantID, ag.ID, time.Now())
	if err != nil {
		return 0, err
	}
	if len(live) == 0 {
		return 0, nil
	}
	apiKey, err := r.secret.Resolve(env.APIKeySecretRef)
	if err != nil || strings.TrimSpace(apiKey) == "" {
		return 0, errors.New("zap skills resync: api key resolve failed")
	}
	client := r.fact(baseURL, apiKey)
	if len(live) > r.maxSessions && r.maxSessions > 0 {
		r.warn(ctx, "chat zap skills resync truncated", "tenant_id", tenantID, "agent_uuid", deUUID, "live", len(live), "max", r.maxSessions)
		live = live[:r.maxSessions]
	}
	// 同一 account 复用一份快照 (rail 含 per-user override, 不能跨 account 复用)。
	nodeByAccount := map[int64]any{}
	pushed, failed := 0, 0
	var firstErr error
	for _, s := range live {
		if strings.TrimSpace(s.SessionID) == "" {
			continue
		}
		node, ok := nodeByAccount[s.AccountID]
		if !ok {
			n, berr := r.skills.BuildZapSessionSkills(ctx, tenantID, s.AccountID, deUUID)
			if berr != nil {
				failed++
				if firstErr == nil {
					firstErr = berr
				}
				continue
			}
			node = n
			nodeByAccount[s.AccountID] = node
		}
		body := map[string]any{"session_id": s.SessionID, "skills": node}
		if node == nil {
			body["skills"] = map[string]any{"agent_skills": []any{}, "builtin_skills": []any{}}
		}
		if perr := client.Routed(zapadapter.RoutingKeyFor(tenantID, s.AccountID)).ResyncSkills(ctx, s.SessionID, body); perr != nil {
			failed++
			if firstErr == nil {
				firstErr = perr
			}
			r.warn(ctx, "chat zap skills resync push failed", "tenant_id", tenantID, "agent_uuid", deUUID,
				"conversation_id", s.ConversationID, "err", zapSafeErr(perr, "resync failed"))
			continue
		}
		pushed++
	}
	if r.logger != nil {
		r.logger.Info(ctx, "chat zap skills resync done", "tenant_id", tenantID, "agent_uuid", deUUID, "pushed", pushed, "failed", failed)
	}
	if failed > 0 {
		return pushed, fmt.Errorf("zap skills resync: %d/%d session(s) failed: %w", failed, pushed+failed, firstErr)
	}
	return pushed, nil
}

func (r *ZapSkillsResyncer) warn(ctx context.Context, msg string, kv ...any) {
	if r != nil && r.logger != nil {
		r.logger.Warn(ctx, msg, kv...)
	}
}

// dshOnlySkills 仅在平台自营 dsh 运行时返回技能节; 其它 ZAP 运行时返回 nil (它们的严格 schema 会拒未知字段)。
func dshOnlySkills(isDSH bool, build func() any) any {
	if !isDSH {
		return nil
	}
	return build()
}
