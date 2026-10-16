// Package agentdirect 是 ADR-0026 agent-direct 双通道「发送链路前置」的窄 service。
//
// 当前客户端发送纯文本 agent-direct 消息前会调用 prepare-wukong,这里确保
// human↔数字员工的 WuKong direct channel + canonical room/conversation 就绪。
// 本 service 只做发送链路前置:不写 message、不触发 run;run 由后续 WuKong webhook/attach 链路承接。
// 契约见 docs/contracts/agent-bus-client-contract.md 的 agent-direct 双通道说明。
package agentdirect

import (
	"context"
	"fmt"
)

// ChannelProvisioner 提供两步:确定性派生 channelID(无副作用)与订阅(有副作用)。
// `*internal/im/wukong.DirectRoomMapper` 同时满足(`DeriveAgentDirectChannelID` + `EnsureForAgentDirect`)。
type ChannelProvisioner interface {
	// DeriveAgentDirectChannelID 确定性计算 channelID(**不订阅、无副作用**)。
	DeriveAgentDirectChannelID(ctx context.Context, tenantID, humanAccountID int64, agentUUID string) (channelID string, channelType int, err error)
	// EnsureForAgentDirect 订阅 human+agent 到 channel(幂等;内部派生同一 channelID)。
	EnsureForAgentDirect(ctx context.Context, tenantID, humanAccountID int64, agentUUID string) (channelID string, channelType int, err error)
}

// RoomEnsurer 确保 canonical human-agent direct room/conversation/participants 并回写 wukong channel link。
// 成员真理 = `room_participants`;实现应复用 `CreateDirectWithAgentPair` 的去重(`room_direct_pairs_with_agent`),
// 幂等返回既有 room。生产适配器下一轮再接(本轮窄测用 fake)。
type RoomEnsurer interface {
	EnsureAgentDirectRoom(ctx context.Context, tenantID, humanAccountID, agentID int64, wukongChannelID string, wukongChannelType int) (roomID int64, roomUUID string, conversationUUID string, err error)
}

// Result 是 EnsureAgentDirectWuKongRoom 的输出。
// RoomUUID/ConversationUUID 对外(客户端 DTO)暴露;RoomID 仅供内部 / 测试断言,不进客户端响应。
type Result struct {
	ChannelID        string
	ChannelType      int
	RoomID           int64
	RoomUUID         string
	ConversationUUID string
}

// Provisioner 编排 channel 派生 + Bus room ensure + WuKong 订阅(纯编排,自身不碰 SQL / WuKong)。
type Provisioner struct {
	channel ChannelProvisioner
	room    RoomEnsurer
}

func New(channel ChannelProvisioner, room RoomEnsurer) *Provisioner {
	if channel == nil || room == nil {
		panic("agentdirect.Provisioner: channel + room required")
	}
	return &Provisioner{channel: channel, room: room}
}

// EnsureAgentDirectWuKongRoom 确保 human↔agent 的 WuKong direct channel + canonical room/conversation 就绪。
//
// **安全顺序(P3 修复,避免孤儿订阅)**:
//  1. **派生** channelID(`DeriveAgentDirectChannelID`,**不订阅、无副作用**);
//  2. **ensure Bus canonical room/conversation/participants** 并用同一 channelID 写 `rooms.wukong_channel_id/type` link;
//  3. **再订阅** WuKong(`EnsureForAgentDirect`,幂等)。
//
// 若 step 2(Bus room)失败 → **尚未订阅 WuKong → 无孤儿订阅**;step 3 失败 → Bus room 已建+link,
// 重试幂等补订阅。幂等:重复调用返回同一 channel/room。不写最终消息到 WuKong、不触发 run。
func (p *Provisioner) EnsureAgentDirectWuKongRoom(ctx context.Context, tenantID, humanAccountID, agentID int64, agentUUID string) (*Result, error) {
	if tenantID <= 0 || humanAccountID <= 0 || agentID <= 0 || agentUUID == "" {
		return nil, fmt.Errorf("agentdirect: invalid args (tenant/account/agentID/agentUUID required)")
	}
	// 1) 派生 channelID(无副作用)。
	channelID, channelType, err := p.channel.DeriveAgentDirectChannelID(ctx, tenantID, humanAccountID, agentUUID)
	if err != nil {
		return nil, fmt.Errorf("agentdirect: derive channel id: %w", err)
	}
	// 2) ensure Bus canonical room + link(失败 → 尚未订阅 WuKong,无孤儿订阅;可重试)。
	roomID, roomUUID, convUUID, err := p.room.EnsureAgentDirectRoom(ctx, tenantID, humanAccountID, agentID, channelID, channelType)
	if err != nil {
		return nil, fmt.Errorf("agentdirect: ensure canonical room: %w", err)
	}
	// 3) 订阅 WuKong(幂等;失败可重试,Bus room 已就绪)。
	if _, _, serr := p.channel.EnsureForAgentDirect(ctx, tenantID, humanAccountID, agentUUID); serr != nil {
		return nil, fmt.Errorf("agentdirect: subscribe wukong channel: %w", serr)
	}
	return &Result{
		ChannelID:        channelID,
		ChannelType:      channelType,
		RoomID:           roomID,
		RoomUUID:         roomUUID,
		ConversationUUID: convUUID,
	}, nil
}
