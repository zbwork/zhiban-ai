package wukong

import (
	"context"
	"errors"
)

// agent-direct 双通道「后端最小前置」(ADR-0026)。本文件**纯前置 + classify-only**:
// 解析 / 分类 WuKong webhook 是否属于 human-agent direct channel,并校验 sender 防回环。
// **绝不触发 agent run、不写 WuKong、不接生产 webhook sink**(下一轮才接,且 flag 保护)。
// 契约见 docs/contracts/agent-bus-client-contract.md §P2.1b agent-direct「后端最小前置阶段」。

// FromKind 是 webhook 发送方分类(防回环)。
const (
	FromKindHuman   = "human"
	FromKindAgent   = "agent"
	FromKindUnknown = "unknown"
)

// ClassifyFromUID 按 fromUID 命名空间分类(纯逻辑,防回环):
//   - `t_{tenant}_u_{account}` → (human, account_uuid)
//   - `t_{tenant}_a_{agent}`   → (agent, agent_uuid)  ← agent 自己发的,调用方**不**触发 run
//   - 其它 / tenant 不匹配 / 解析失败 → (unknown, "")
func ClassifyFromUID(fromUID string, tenantID int64) (kind, uuid string) {
	t, k, rest, ok := ParseNamespacedID(fromUID)
	if !ok || t != tenantID {
		return FromKindUnknown, ""
	}
	switch k {
	case "u":
		return FromKindHuman, rest
	case "a":
		return FromKindAgent, rest
	default:
		return FromKindUnknown, ""
	}
}

// AgentDirectRoom 是 agent_direct room 的解析结果(成员真理来自 room_participants;由 lookup 提供)。
type AgentDirectRoom struct {
	RoomID           int64
	HumanAccountUUID string
	AgentUUID        string
	ConversationUUID string
}

// AgentDirectRoomLookup 按 WuKong direct channel 找 agent_direct room。
// 未找到 / 非 agent_direct(无 agent 参与者)→ found=false。生产实现下一轮再接(本轮窄测用 fake)。
type AgentDirectRoomLookup interface {
	FindAgentDirectByChannel(ctx context.Context, tenantID int64, channelID string) (room AgentDirectRoom, found bool, err error)
}

// AgentDirectTarget 是 webhook 解析结果(classify-only;调用方据 FromKind 决定是否在**下一轮**触发 run)。
type AgentDirectTarget struct {
	TenantID         int64
	AccountUUID      string // human account_uuid
	AgentUUID        string
	ConversationUUID string
	RoomID           int64
	ChannelID        string
	ChannelType      int
	FromKind         string // human / agent
	FromUUID         string // 发送方 uuid(human=account_uuid,agent=agent_uuid)
}

// fail-closed 错误(均不触发 run)。
var (
	ErrNotDirectChannel = errors.New("wukong agent_direct: not a direct channel")
	ErrTenantMismatch   = errors.New("wukong agent_direct: tenant mismatch")
	ErrRoomNotFound     = errors.New("wukong agent_direct: agent_direct room not found for channel")
	ErrSenderNotInRoom  = errors.New("wukong agent_direct: sender not a participant of the room")
)

// ResolveAgentDirectWebhookTarget 是本轮的核心纯前置(**classify-only,绝不触发 run、绝不写 WuKong**):
//  1. channelID 必须是 direct channel 且 tenant 匹配,否则 fail-closed;
//  2. 经 lookup 找 agent_direct room(参与者真理),找不到 → fail-closed;
//  3. 分类 fromUID(防回环):agent → FromKind=agent(调用方不触发);human → FromKind=human;
//  4. sender 必须是该 room 的对应参与者(human==room.HumanAccountUUID / agent==room.AgentUUID),否则 fail-closed;
//  5. 返回 AgentDirectTarget(tenant/account/agent/room/conversation anchor)。
//
// human 命中也**只返回分类结果**;是否触发 run 由调用方在**下一轮**(flag 保护)决定。
func ResolveAgentDirectWebhookTarget(ctx context.Context, lookup AgentDirectRoomLookup, tenantID int64, channelID, fromUID string) (*AgentDirectTarget, error) {
	pt, kind, _, ok := ParseNamespacedID(channelID)
	if !ok || kind != "d" {
		return nil, ErrNotDirectChannel
	}
	if pt != tenantID {
		return nil, ErrTenantMismatch
	}
	if lookup == nil {
		return nil, ErrRoomNotFound
	}
	room, found, err := lookup.FindAgentDirectByChannel(ctx, tenantID, channelID)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, ErrRoomNotFound
	}

	fromKind, fromUUID := ClassifyFromUID(fromUID, tenantID)
	switch fromKind {
	case FromKindHuman:
		if fromUUID != room.HumanAccountUUID {
			return nil, ErrSenderNotInRoom
		}
	case FromKindAgent:
		if fromUUID != room.AgentUUID {
			return nil, ErrSenderNotInRoom
		}
	default:
		// unknown sender(非 human/agent uid / 跨租户)→ fail-closed。
		return nil, ErrSenderNotInRoom
	}

	return &AgentDirectTarget{
		TenantID:         tenantID,
		AccountUUID:      room.HumanAccountUUID,
		AgentUUID:        room.AgentUUID,
		ConversationUUID: room.ConversationUUID,
		RoomID:           room.RoomID,
		ChannelID:        channelID,
		ChannelType:      ChannelTypeGroup,
		FromKind:         fromKind,
		FromUUID:         fromUUID,
	}, nil
}
