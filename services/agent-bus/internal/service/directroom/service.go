// Package directroom 编排 human-human direct room。
//
// 当前 IM 数据面只走 WuKongIM:
//  1. 解析 peer + 校 self / 同租户 active membership;
//  2. peer 校验通过后再做 WuKong direct channel provisioning，避免非法 peer 产生副作用;
//  3. 调 rooms.CreateDirectWithPair 落业务 metadata + conversation + wukong channel link。
package directroom

import (
	"context"
	"strings"
	"time"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	reporoom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
)

// AccountRepo · directroom 需要的 account 子集.
type AccountRepo interface {
	GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
	GetByUUID(ctx context.Context, uuid string) (*domaccount.Account, error)
	GetMembership(ctx context.Context, accountID, tenantID int64) (*domaccount.Membership, error)
}

// RoomRepo · directroom 需要的 rooms 子集 (CreateDirectWithPair + ConversationUUIDByRoomID).
type RoomRepo interface {
	CreateDirectWithPair(ctx context.Context, in reporoom.CreateDirectWithPairInput) (*reporoom.CreateDirectWithPairOutput, error)
	ConversationUUIDByRoomID(ctx context.Context, roomID int64) (string, error)
}

// ConvStateRepo · direct room 重新打开时返回当前账号的 clear watermark,
// 让客户端能过滤 WuKong 本地缓存中的旧历史。
type ConvStateRepo interface {
	ClearedAt(ctx context.Context, accountID, tenantID int64, conversationUUID string) (*time.Time, error)
}

// WuKongProvisioner · directroom 确保 WuKong direct channel 的窄抽象(ADR-0026)。
// **有副作用(subscriber_add)**:service 在 peer 校验通过后才调,避免对非法 peer 产生副作用。
// 实现见 internal/im/wukong.DirectRoomMapper。返回 (channelID, channelType=2)。
type WuKongProvisioner interface {
	EnsureForDirect(ctx context.Context, tenantID, callerAccountID int64, peerAccountUUID string) (channelID string, channelType int, err error)
}

// 错误码 (M5B).
const (
	ErrCodeDirectSelf            = "directroom.cannot_chat_with_self"
	ErrCodeDirectPeerNotFound    = "directroom.peer_not_found"
	ErrCodeDirectPeerCrossTenant = "directroom.peer_cross_tenant"
)

// IMSubstrate 取值。当前后端只使用 WuKongIM。
const (
	IMSubstrateWuKong = "wukong"
)

// Service · directroom 业务接口.
type Service interface {
	// CreateOrGet 幂等创建 (或返回既有) direct 1v1 room.
	// caller 与 peer 必须同 tenant。**peer 校验通过后**才做 WuKong provisioning(有副作用)。
	// WuKong channel 由注入的 provisioner 确定性派生后存进 rooms。
	CreateOrGet(ctx context.Context, callerAccountID, tenantID int64, peerAccountUUID, title string) (*Result, error)
}

// Result · CreateOrGet 返回。
type Result struct {
	RoomUUID          string
	ConversationUUID  string
	PairUUID          string
	PairCreated       bool // false = 命中既有
	IMSubstrate       string
	WuKongChannelID   string
	WuKongChannelType int
	ClearedAt         *time.Time
}

// Deps · 构造依赖。
type Deps struct {
	Logger    *log.Logger
	Rooms     RoomRepo
	Accounts  AccountRepo
	WuKong    WuKongProvisioner // WuKong 启用时注入; nil = 不写 WuKong link。
	ConvState ConvStateRepo
}

type impl struct {
	logger    *log.Logger
	rooms     RoomRepo
	accounts  AccountRepo
	wukong    WuKongProvisioner
	convState ConvStateRepo
}

func New(d Deps) Service {
	if d.Logger == nil {
		d.Logger = log.Default()
	}
	if d.Rooms == nil {
		panic("directroom.New: rooms repo required")
	}
	if d.Accounts == nil {
		panic("directroom.New: accounts repo required")
	}
	return &impl{
		logger:    d.Logger,
		rooms:     d.Rooms,
		accounts:  d.Accounts,
		wukong:    d.WuKong,
		convState: d.ConvState,
	}
}

func (s *impl) CreateOrGet(ctx context.Context, callerAccountID, tenantID int64, peerAccountUUID, title string) (*Result, error) {
	title = strings.TrimSpace(title)

	// ⚠ 顺序铁律(P2.1 review):所有外部 IM provisioning 必须在 peer 校验之后,
	// 避免对非法 peer 产生副作用。

	// 1) 解析 peer
	peer, err := s.accounts.GetByUUID(ctx, peerAccountUUID)
	if err != nil || peer == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeDirectPeerNotFound).Withf("peer %s not found", peerAccountUUID)
	}
	if peer.ID == callerAccountID {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeDirectSelf).Withf("cannot chat with self")
	}

	// 2) 跨租户校 + active membership
	pm, err := s.accounts.GetMembership(ctx, peer.ID, tenantID)
	if err != nil || pm == nil {
		return nil, apperr.New(apperr.Forbidden, ErrCodeDirectPeerCrossTenant).Withf("peer not member of tenant %d", tenantID)
	}
	if pm.Status != "active" {
		return nil, apperr.New(apperr.Forbidden, ErrCodeDirectPeerCrossTenant).Withf("peer membership not active")
	}

	substrate := IMSubstrateWuKong

	// 3) WuKong provisioning(有副作用 subscriber_add)——必在 peer 校验之后。
	//      确定性派生 channel_id + 双方订阅;返回的 channel 存进 rooms(底座无关地透传)。
	var wukongChannelID string
	var wukongChannelType int
	if s.wukong != nil {
		chID, chType, werr := s.wukong.EnsureForDirect(ctx, tenantID, callerAccountID, peerAccountUUID)
		if werr != nil {
			return nil, apperr.New(apperr.UpstreamUnavailable, "directroom.wukong_ensure_failed").Wrap(werr)
		}
		wukongChannelID = chID
		wukongChannelType = chType
	}

	// 4) 创建 (或命中既有) rooms + room_participants(2 human)+ pair + conversation + WuKong link.
	out, err := s.rooms.CreateDirectWithPair(ctx, reporoom.CreateDirectWithPairInput{
		TenantID: tenantID, CallerID: callerAccountID, PeerID: peer.ID, Title: title,
		WuKongChannelID: wukongChannelID, WuKongChannelType: wukongChannelType,
	})
	if err != nil {
		return nil, err
	}

	convUUID, err := s.rooms.ConversationUUIDByRoomID(ctx, out.Room.ID)
	if err != nil {
		convUUID = ""
	}
	var clearedAt *time.Time
	if s.convState != nil && convUUID != "" {
		ca, cerr := s.convState.ClearedAt(ctx, callerAccountID, tenantID, convUUID)
		if cerr != nil {
			return nil, apperr.ErrInternal.Wrap(cerr)
		}
		clearedAt = ca
	}
	res := &Result{
		RoomUUID:          out.Room.UUID,
		ConversationUUID:  convUUID,
		PairUUID:          out.PairUUID,
		PairCreated:       out.PairCreated,
		IMSubstrate:       substrate,
		WuKongChannelID:   out.WuKongChannelID,
		WuKongChannelType: out.WuKongChannelType,
		ClearedAt:         clearedAt,
	}
	if s.logger != nil {
		s.logger.Info(ctx, "directroom created/got",
			"tenant_id", tenantID, "caller", callerAccountID, "peer", peer.ID,
			"room_uuid", out.Room.UUID, "pair_uuid", out.PairUUID, "created", out.PairCreated,
			"substrate", substrate, "wukong_channel_id", out.WuKongChannelID)
	}
	return res, nil
}
