package wukong

import (
	"context"
	"fmt"
)

// groupChannelClient 是 GroupRoomMapper 需要的 WuKong 订阅操作子集(*Client 满足)。
// 抽成接口便于单测注入 fake(无需真实 :5001)。
type groupChannelClient interface {
	AddSubscribers(ctx context.Context, channelID string, channelType int, subscribers []string) error
	RemoveSubscribers(ctx context.Context, channelID string, channelType int, subscribers []string) error
}

// GroupRoomMapper 把群聊 room 映射到 WuKong group channel(type=2)(ADR-0026 / Plan 09 P2.3a)。
//
// 在 /rooms 创建群(校验通过后、写库前)或成员增删时调用,不侵入 room 业务服务的事务。
// 幂等:subscriber_add(reset=0)/ subscriber_remove 可重复调用。
//
// ⚠ 有副作用(WuKong subscriber_add/remove):调用方必须**先完成成员校验**
// (存在 / 同租户 / active)再调,避免对非法成员产生 WuKong 副作用(见 room.Service.Create)。
//
// 本轮(P2.3a)只订阅 human 成员;agent 虚拟用户订阅 / 代发留 @Agent 阶段。
type GroupRoomMapper struct {
	client groupChannelClient
	lookup AccountLookup
}

// NewGroupRoomMapper. client 通常为 wukong.Adapter.Client()。
func NewGroupRoomMapper(client groupChannelClient, lookup AccountLookup) *GroupRoomMapper {
	return &GroupRoomMapper{client: client, lookup: lookup}
}

// EnsureForGroup 确保群 channel 存在并含全部 human 成员订阅。返回 (channel_id, channel_type=2)。
//
// channel_id = GroupChannelID(tenant, room_uuid);订阅者 = 各 human 成员 UserUID。
func (m *GroupRoomMapper) EnsureForGroup(ctx context.Context, tenantID int64, roomUUID string, humanAccountIDs []int64) (string, int, error) {
	if tenantID <= 0 || roomUUID == "" {
		return "", 0, fmt.Errorf("wukong grouproom: invalid args")
	}
	channelID := GroupChannelID(tenantID, roomUUID)
	subs := make([]string, 0, len(humanAccountIDs))
	for _, aid := range humanAccountIDs {
		uuid, err := m.lookup.AccountUUID(ctx, aid)
		if err != nil {
			return "", 0, fmt.Errorf("wukong grouproom: account %d lookup: %w", aid, err)
		}
		subs = append(subs, UserUID(tenantID, uuid))
	}
	if len(subs) > 0 {
		if err := m.client.AddSubscribers(ctx, channelID, ChannelTypeGroup, subs); err != nil {
			return "", 0, fmt.Errorf("wukong grouproom: subscriber_add: %w", err)
		}
	}
	return channelID, ChannelTypeGroup, nil
}

// AddMember 单个 human 成员加入群 channel(subscriber_add,幂等)。
func (m *GroupRoomMapper) AddMember(ctx context.Context, tenantID int64, roomUUID string, humanAccountID int64) error {
	uid, err := m.memberUID(ctx, tenantID, humanAccountID)
	if err != nil {
		return err
	}
	return m.client.AddSubscribers(ctx, GroupChannelID(tenantID, roomUUID), ChannelTypeGroup, []string{uid})
}

// RemoveMember 单个 human 成员移出群 channel(subscriber_remove,幂等)。
// 移除后该 uid 不再实时收发该 channel(配合 room_participants left_at + 历史闸)。
func (m *GroupRoomMapper) RemoveMember(ctx context.Context, tenantID int64, roomUUID string, humanAccountID int64) error {
	uid, err := m.memberUID(ctx, tenantID, humanAccountID)
	if err != nil {
		return err
	}
	return m.client.RemoveSubscribers(ctx, GroupChannelID(tenantID, roomUUID), ChannelTypeGroup, []string{uid})
}

func (m *GroupRoomMapper) memberUID(ctx context.Context, tenantID, accountID int64) (string, error) {
	if tenantID <= 0 || accountID <= 0 {
		return "", fmt.Errorf("wukong grouproom: invalid member args")
	}
	uuid, err := m.lookup.AccountUUID(ctx, accountID)
	if err != nil {
		return "", fmt.Errorf("wukong grouproom: account %d lookup: %w", accountID, err)
	}
	return UserUID(tenantID, uuid), nil
}
