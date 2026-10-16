package wukong

import (
	"context"
	"fmt"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im"
)

// DirectRoomMapper 把 1v1 direct room 映射到 WuKong direct channel(ADR-0026 Phase 1)。
//
// 在 /direct-rooms 创建/获取 room 之后调用(handler 层),不侵入 directroom 业务服务。
// 幂等:底层 EnsureChannel(subscriber_add reset=0)可重复调用。
type DirectRoomMapper struct {
	sub    im.Substrate
	lookup AccountLookup
}

func NewDirectRoomMapper(sub im.Substrate, lookup AccountLookup) *DirectRoomMapper {
	return &DirectRoomMapper{sub: sub, lookup: lookup}
}

// EnsureForDirect 确保 caller 与 peer 的 WuKong direct channel 存在并含双方订阅。
// 身份显式传参。返回 (channel_id, channel_type=2 group)。
//
// ⚠ 有副作用(WuKong subscriber_add):调用方必须**先完成 peer 校验**(存在/同租户/active)
// 再调本方法,避免对非法 peer 产生 WuKong channel/subscriber 副作用(见 directroom.Service)。
func (m *DirectRoomMapper) EnsureForDirect(ctx context.Context, tenantID, callerAccountID int64, peerAccountUUID string) (string, int, error) {
	if tenantID <= 0 || callerAccountID <= 0 || peerAccountUUID == "" {
		return "", 0, fmt.Errorf("wukong directroom: invalid args")
	}
	callerUUID, err := m.lookup.AccountUUID(ctx, callerAccountID)
	if err != nil {
		return "", 0, fmt.Errorf("wukong directroom: caller lookup: %w", err)
	}
	channelID := DirectChannelID(tenantID, callerUUID, peerAccountUUID)
	subs := []string{
		UserUID(tenantID, callerUUID),
		UserUID(tenantID, peerAccountUUID),
	}
	// 用 group(type=2)共享频道:WuKong 个人频道(type=1)隐式、不支持 subscriber_add。
	// 自定义 _d_ 频道需 group 语义,双方订阅、共享同一 channel_id 与历史。
	if err := m.sub.EnsureChannel(ctx, channelID, ChannelTypeGroup, subs); err != nil {
		return "", 0, fmt.Errorf("wukong directroom: ensure channel: %w", err)
	}
	return channelID, ChannelTypeGroup, nil
}

// DeriveAgentDirectChannelID 确定性计算 human↔agent 的 WuKong direct channelID(**不订阅、无副作用**)。
// 与 EnsureForAgentDirect 派生同一 channelID;用于「先建 Bus canonical room/link 再订阅 WuKong」的安全顺序
// (避免 room ensure 失败时留下孤儿 WuKong 订阅,ADR-0026 P3)。返回 (channel_id, channel_type=2 group)。
func (m *DirectRoomMapper) DeriveAgentDirectChannelID(ctx context.Context, tenantID, humanAccountID int64, agentUUID string) (string, int, error) {
	if tenantID <= 0 || humanAccountID <= 0 || agentUUID == "" {
		return "", 0, fmt.Errorf("wukong agentdirect: invalid args")
	}
	humanUUID, err := m.lookup.AccountUUID(ctx, humanAccountID)
	if err != nil {
		return "", 0, fmt.Errorf("wukong agentdirect: caller lookup: %w", err)
	}
	return AgentDirectChannelID(tenantID, humanUUID, agentUUID), ChannelTypeGroup, nil
}

// EnsureForAgentDirect 确保 human(caller)与数字员工(agent)的 WuKong direct channel 存在并含双方订阅。
// 与 EnsureForDirect(human-human)**分开**、不破坏既有路径;订阅 = UserUID(human) + AgentUID(agent),
// channel_type=2 group(ADR-0026 agent-direct 后端最小前置)。派生 channelID 与 DeriveAgentDirectChannelID 一致。
//
// ⚠ 有副作用(WuKong subscriber_add);调用方须先完成 agent 可见性 / room participant 校验再调。
// 返回 (channel_id, channel_type=2)。
func (m *DirectRoomMapper) EnsureForAgentDirect(ctx context.Context, tenantID, humanAccountID int64, agentUUID string) (string, int, error) {
	if tenantID <= 0 || humanAccountID <= 0 || agentUUID == "" {
		return "", 0, fmt.Errorf("wukong agentdirect: invalid args")
	}
	humanUUID, err := m.lookup.AccountUUID(ctx, humanAccountID)
	if err != nil {
		return "", 0, fmt.Errorf("wukong agentdirect: caller lookup: %w", err)
	}
	channelID := AgentDirectChannelID(tenantID, humanUUID, agentUUID)
	subs := []string{
		UserUID(tenantID, humanUUID),
		AgentUID(tenantID, agentUUID),
	}
	if err := m.sub.EnsureChannel(ctx, channelID, ChannelTypeGroup, subs); err != nil {
		return "", 0, fmt.Errorf("wukong agentdirect: ensure channel: %w", err)
	}
	return channelID, ChannelTypeGroup, nil
}
