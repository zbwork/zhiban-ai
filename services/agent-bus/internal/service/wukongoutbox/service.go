package wukongoutbox

import (
	"context"
	"fmt"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
)

// Service 提供 EnqueueWuKongMessage,供下一轮 agent-direct / revoke / 群代发在业务事务内入 outbox。
// 本轮(方案 A)不接任何现有发送路径。
type Service struct {
	repo dom.Repository
}

func NewService(repo dom.Repository) *Service {
	if repo == nil {
		panic("wukongoutbox.Service: repo required")
	}
	return &Service{repo: repo}
}

// EnqueueParams 一条待发送 WuKong 消息的入参。
type EnqueueParams struct {
	TenantID    string
	ChannelID   string
	ChannelType int
	FromUID     string
	MsgType     int
	Payload     []byte // JSON
	DedupKey    string // 业务幂等键;与 tenant 组成唯一约束
	Source      string // dom.SourceXxx;空 → generic
	MaxRetries  int    // <=0 → 默认 10
}

// EnqueueWuKongMessage 幂等写一条 outbox 行(只写库,不发送;worker 异步发)。
// 同 (TenantID, DedupKey) 重复调用不产生第二行,返回现有行 + inserted=false。
func (s *Service) EnqueueWuKongMessage(ctx context.Context, p EnqueueParams) (dom.Message, bool, error) {
	if p.TenantID == "" || p.ChannelID == "" || p.FromUID == "" || p.DedupKey == "" {
		return dom.Message{}, false, fmt.Errorf("wukongoutbox: tenantID/channelID/fromUID/dedupKey required")
	}
	if len(p.Payload) == 0 {
		return dom.Message{}, false, fmt.Errorf("wukongoutbox: payload required")
	}
	return s.repo.Enqueue(ctx, dom.Message{
		TenantID:    p.TenantID,
		ChannelID:   p.ChannelID,
		ChannelType: p.ChannelType,
		FromUID:     p.FromUID,
		MsgType:     p.MsgType,
		Payload:     p.Payload,
		DedupKey:    p.DedupKey,
		Source:      p.Source,
		MaxRetries:  p.MaxRetries,
	})
}
