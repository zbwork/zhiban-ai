package agentdirect

import (
	"context"
	"errors"
	"fmt"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ErrDisabled = agent-direct WuKong 发送链路前置功能未启用
// (flag `Chat.AgentDirectWuKongEnabled=false` 或 WuKong 未接线)。
// transport 层把它翻成 404(feature 未启用,fail-closed、不泄漏 agent 存在性)。
var ErrDisabled = errors.New("agentdirect: prepare disabled")

// ErrAgentNotFound = 可见性通过后仍解析不到 agentID(内部不一致)。
// transport 层按 403 处理(与不可见同口径,**不暴露存在性 oracle**)。
var ErrAgentNotFound = errors.New("agentdirect: agent not found")

// ErrLocalUnsupported protects local single conversations from room-based routing.
var ErrLocalUnsupported = errors.New("agentdirect: local employee does not support room preparation")

type AgentTarget struct {
	ID             int64
	ExecutionLocus string
}

// AgentLookup 把 agent_uuid 解析成内部 agentID(tenant scope 由实现校验)。
// 生产实现 = adapter over `service/agent.Service.Get`(已按 tenant 收口)。
type AgentLookup interface {
	AgentByUUID(ctx context.Context, tenantID int64, agentUUID string) (target AgentTarget, found bool, err error)
}

// VisibilityChecker = agent 可见性闸口(fail-closed)。
// 生产实现 = `service/contacts.Service`(`AssertAgentVisible`,not-found 已翻成 forbidden)。
type VisibilityChecker interface {
	AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error
}

// PrepareService 是 `POST /chat/agent-direct/prepare-wukong` 的窄 service:
// 在客户端发 agent-direct 消息**前**,确保 human↔agent 的 WuKong direct channel +
// canonical room/conversation 就绪,并把 channel/会话信息回给客户端。
//
// **严格不做**:不触发 run、不写任何 message、不向 WuKong `SendMessage`、不改 unread/已读、不调 admin。
// **fail-closed 顺序**:enabled → 可见性(不可见/不存在统一 forbidden,无存在性 oracle)→ 解析 agentID → Provisioner。
type PrepareService struct {
	enabled bool
	agents  AgentLookup
	vis     VisibilityChecker
	prov    *Provisioner
}

// NewPrepareService 装配。enabled = `cfg.Chat.AgentDirectWuKongEnabled`;
// 任一依赖为 nil 视为未接线(Prepare 一律 ErrDisabled)。
func NewPrepareService(enabled bool, agents AgentLookup, vis VisibilityChecker, prov *Provisioner) *PrepareService {
	return &PrepareService{enabled: enabled, agents: agents, vis: vis, prov: prov}
}

// Prepare 准备 agent-direct 发送所需的 WuKong channel + canonical room/conversation。
func (s *PrepareService) Prepare(ctx context.Context, tenantID, accountID int64, agentUUID string) (*Result, error) {
	if !s.enabled || s.prov == nil || s.agents == nil || s.vis == nil {
		return nil, ErrDisabled
	}
	if tenantID <= 0 || accountID <= 0 || agentUUID == "" {
		return nil, fmt.Errorf("agentdirect prepare: invalid args (tenant/account/agentUUID required)")
	}
	// 1) 可见性优先(fail-closed):不可见 / 不存在的 agent 绝不进 Provisioner(无 WuKong/Bus 副作用)。
	//    **统一防存在性泄漏**:把 not-found / forbidden 类一律归一成 forbidden(不让客户端区分"不存在"与"不可见");
	//    仅真正的 DB/系统错误才透传(可成 500)。注意 apperr.Error 无 Is/Unwrap 且 Withf 返回拷贝,
	//    故按 Code 判定(errors.Is 对 .Withf 结果不成立)。
	if err := s.vis.AssertAgentVisible(ctx, accountID, tenantID, agentUUID); err != nil {
		if e, ok := apperr.AsError(err); ok && (e.Code == apperr.NotFound || e.Code == apperr.Forbidden) {
			return nil, apperr.ErrForbidden.Withf("agent not accessible")
		}
		return nil, err
	}
	// 2) 解析 agentID(可见即应存在;防御性:仍解析不到按 forbidden 口径,不泄漏存在性)。
	target, found, err := s.agents.AgentByUUID(ctx, tenantID, agentUUID)
	if err != nil {
		return nil, err
	}
	if !found || target.ID <= 0 {
		return nil, ErrAgentNotFound
	}
	if target.ExecutionLocus == "local" {
		return nil, ErrLocalUnsupported
	}
	// 3) Provisioner:派生 channelID(无副作用)→ ensure Bus room+link → 订阅 WuKong。
	return s.prov.EnsureAgentDirectWuKongRoom(ctx, tenantID, accountID, target.ID, agentUUID)
}
