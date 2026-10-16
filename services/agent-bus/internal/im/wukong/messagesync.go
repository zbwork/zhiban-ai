package wukong

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// ErrCrossTenant: channel_id 不属于调用方租户(拒绝跨租户拉历史)。
var ErrCrossTenant = errors.New("wukong msgsync: cross-tenant channel denied")

// ErrNotMember: channel 绑定到某 room,但 caller 不是该 room 的 active human participant
// (P2.3a 群历史闸:移出/退出后不能拉历史)。
var ErrNotMember = errors.New("wukong msgsync: caller not a participant of channel room")

// ChannelMembershipChecker · P2.3a 群历史闸。channel 能反查到 room 时,要求 caller 是该 room
// 的 active human participant;反查不到 room 的 channel 沿用租户命名空间校验(向后兼容)。
//
// 实现见 cmd/bus(用 room repo)。nil → 不做成员闸(仅租户命名空间校验,Phase 1 行为)。
type ChannelMembershipChecker interface {
	// CheckChannelMembership 返回 (linked, allowed, err)。
	//   - linked=false: channel 未绑定任何 room → 调用方按租户命名空间校验放行(向后兼容)。
	//   - linked=true, allowed=false: 绑定到 room 但 caller 不是 active human participant → 拒。
	CheckChannelMembership(ctx context.Context, tenantID, callerAccountID int64, channelID string) (linked bool, allowed bool, err error)
}

// MessageSyncProxy 是客户端历史同步的 agent-bus 鉴权代理(ADR-0026)。
//
// 客户端 SDK 需要从服务端同步频道历史,但 WuKong 同步走特权 REST(:5001),
// 按 ADR-0026 客户端绝不能直连。故由 agent-bus 经 authT 鉴权 + 租户校验后代理:
// login_uid 强制用调用方自己的命名空间 uid;channel_id 必须落在调用方租户命名空间。
//
// 本层只做透传(payload 保持 base64,不解析消息内容),保持 agent-bus 不触碰明文。
type MessageSyncProxy struct {
	client     *Client
	lookup     AccountLookup
	membership ChannelMembershipChecker // P2.3a 群历史闸; nil = 仅租户命名空间校验。
}

func NewMessageSyncProxy(client *Client, lookup AccountLookup) *MessageSyncProxy {
	return &MessageSyncProxy{client: client, lookup: lookup}
}

// SetMembershipChecker P2.3a wiring; cmd/bus 注入 room repo 实现的群历史闸。
func (p *MessageSyncProxy) SetMembershipChecker(c ChannelMembershipChecker) { p.membership = c }

// Sync 校验后代理 WuKong /channel/messagesync,返回原始响应体。身份显式传参。
func (p *MessageSyncProxy) Sync(ctx context.Context, tenantID, callerAccountID int64, channelID string, channelType, startMessageSeq, endMessageSeq, limit, pullMode int) ([]byte, error) {
	if tenantID <= 0 || callerAccountID <= 0 || channelID == "" {
		return nil, fmt.Errorf("wukong msgsync: invalid args")
	}
	// 租户隔离:channel_id 必须落在调用方租户命名空间,拒绝跨租户拉历史。
	chTenant, err := TenantIDFromNamespacedID(channelID)
	if err != nil {
		return nil, fmt.Errorf("wukong msgsync: bad channel id: %w", err)
	}
	if chTenant != tenantID {
		return nil, ErrCrossTenant
	}
	// P2.3a 群历史闸:channel 绑定到 room 时,要求 caller 是 active human participant
	// (移出/退出后不能拉历史)。未绑定 room 的 channel 沿用租户命名空间校验(向后兼容)。
	if p.membership != nil {
		linked, allowed, merr := p.membership.CheckChannelMembership(ctx, tenantID, callerAccountID, channelID)
		if merr != nil {
			return nil, fmt.Errorf("wukong msgsync: membership check: %w", merr)
		}
		if linked && !allowed {
			return nil, ErrNotMember
		}
	}
	callerUUID, err := p.lookup.AccountUUID(ctx, callerAccountID)
	if err != nil {
		return nil, fmt.Errorf("wukong msgsync: caller lookup: %w", err)
	}
	loginUID := UserUID(tenantID, callerUUID)
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	return p.client.SyncChannelMessages(ctx, loginUID, channelID, channelType, startMessageSeq, endMessageSeq, limit, pullMode)
}

// CountPeerMessagesAfter 基于 WuKong 历史重算 caller 已读时间之后的"对端新消息数"。
//
// 用途: /conversation/sync 的 unread 可能包含历史累计红点,而 Flutter SDK 的
// updateRedDot 当前只清本地 DB,不回写服务端 unread。Bus 在已有 last_read_at 时,
// 可用本方法对**列表展示**做水位修正:只统计 last_read_at 之后且 from_uid != caller 的消息。
//
// ok=false 表示无法安全重算(例如响应结构不可解析);调用方应降级保留 WuKong unread。
func (p *MessageSyncProxy) CountPeerMessagesAfter(ctx context.Context, tenantID, callerAccountID int64, channelID string, channelType int, after time.Time, limit int) (count int, ok bool, err error) {
	if after.IsZero() {
		return 0, false, nil
	}
	callerUUID, err := p.lookup.AccountUUID(ctx, callerAccountID)
	if err != nil {
		return 0, false, fmt.Errorf("wukong msgsync unread recount caller lookup: %w", err)
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	raw, err := p.Sync(ctx, tenantID, callerAccountID, channelID, channelType, 0, 0, limit, 1)
	if err != nil {
		return 0, false, err
	}
	return CountPeerMessagesAfterRaw(raw, UserUID(tenantID, callerUUID), after)
}

// CountPeerMessagesAfterCached 优先用 SyncForAccount 已经带回来的 recents(见
// ConversationSyncMsgCount)本地数出"对端在 after 之后发的消息数",覆盖不到时
// 才退化成真打一次 /channel/messagesync(CountPeerMessagesAfter)。
//
// recents 只有在"确定没漏"的时候才可信,两种情况:
//  1. rawRecentsCount < recentsCap —— /conversation/sync **过滤前**的原始条数没到
//     上限,说明这就是这个 channel 的全部历史(没有被截断)。注意不能用
//     len(recents)(过滤后)去比 recentsCap:parseConversationSync 会丢掉
//     from_uid 为空/timestamp 非法的条目,过滤后条数天然 <= 过滤前,拿它跟原始
//     上限比会把"确实被截断、只是截断的 50 条里混了几条无效消息"误判成"没截断"。
//  2. recents 里最老一条的时间戳 <= after —— 窗口已经盖过 after 这个时间点,
//     再往前的消息不影响"after 之后"这个统计口径,截不截断都无所谓。
//
// 除此之外(命中了上限、又没盖过 after)不能确定 recents 完整,必须退化成精确查询。
func (p *MessageSyncProxy) CountPeerMessagesAfterCached(
	ctx context.Context,
	tenantID, callerAccountID int64,
	channelID string,
	channelType int,
	recents []RecentMsg,
	rawRecentsCount int,
	recentsCap int,
	after time.Time,
	limit int,
) (count int, ok bool, err error) {
	if after.IsZero() {
		return 0, false, nil
	}
	trustworthy := rawRecentsCount < recentsCap
	if !trustworthy && len(recents) > 0 {
		oldest := recents[0].Timestamp
		for _, m := range recents {
			if oldest <= 0 || (m.Timestamp > 0 && m.Timestamp < oldest) {
				oldest = m.Timestamp
			}
		}
		trustworthy = oldest > 0 && oldest <= after.Unix()
	}
	if trustworthy {
		callerUUID, uerr := p.lookup.AccountUUID(ctx, callerAccountID)
		if uerr == nil {
			ownUID := UserUID(tenantID, callerUUID)
			raw, merr := json.Marshal(cachedRecentsResp(recents))
			if merr == nil {
				if c, localOK, cerr := CountPeerMessagesAfterRaw(raw, ownUID, after); cerr == nil && localOK {
					return c, true, nil
				}
			}
		}
	}
	return p.CountPeerMessagesAfter(ctx, tenantID, callerAccountID, channelID, channelType, after, limit)
}

func cachedRecentsResp(recents []RecentMsg) syncChannelMessagesResp {
	messages := make([]syncChannelMessage, 0, len(recents))
	for _, m := range recents {
		messages = append(messages, syncChannelMessage{FromUID: m.FromUID, Timestamp: m.Timestamp})
	}
	return syncChannelMessagesResp{Messages: messages}
}

type syncChannelMessagesResp struct {
	Messages []syncChannelMessage `json:"messages"`
}

type syncChannelMessage struct {
	FromUID      string          `json:"from_uid"`
	Timestamp    int64           `json:"timestamp"`     // 秒
	MessageID    json.RawMessage `json:"message_id"`    // F09 P1 撤回: 兼容字符串/数字 message_id
	MessageIDStr string          `json:"message_idstr"` // WuKong 常见字符串 ID 字段
	MessageSeq   int64           `json:"message_seq"`
	ClientMsgNo  string          `json:"client_msg_no"` // message_id 尚未稳定同步时的兜底定位键
}

// SeqMessageInfo 是已读回执等服务按 message_seq 反查 WuKong 消息的最小信息。
type SeqMessageInfo struct {
	FromUID    string
	MessageID  string
	MessageSeq int64
}

// ErrMessageNotFound 撤回路径:在指定 seq 范围内未找到匹配 message_id/client_msg_no 的消息.
var ErrMessageNotFound = errors.New("wukong msgsync: message not found")

// LookupMessageSender F09 P1 撤回: 在 channel 上查 messageID/clientMsgNo 对应消息的 from_uid.
//
// 用法: 撤回前需要校验 caller 是不是消息的发送者. 不信任客户端 fromSelf,
// 复用现有 SyncChannelMessages (特权口) 拿 (channel, seq) 范围内的消息列表,
// 优先按 messageID 精确匹配,再按 clientMsgNo 兜底; 同步层已做 (a) tenant 命名空间校验 (b) group 成员闸,
// 故撤回链路天然继承可见性 / 跨租户保护.
//
// messageSeq 不为 0 时取 [seq-1, seq+1] 窄范围 (limit=4) 避免拉一大段;
// =0 (旧消息缺 seq) 时退化为 limit 范围扫描 (limit=100, 最近一段) 兜底.
//
// 返回 (fromUID, foundMessageSeq, error).
//   - ok 匹配 → (from_uid, message_seq, nil)
//   - 未找到 → ("", 0, ErrMessageNotFound)
//   - 跨租户 / 非成员 / 网络错 → 透传 Sync 的 error.
func (p *MessageSyncProxy) LookupMessageSender(
	ctx context.Context,
	tenantID, callerAccountID int64,
	channelID string, channelType int,
	messageID string, messageSeq int64, clientMsgNo string,
) (fromUID string, foundSeq int64, err error) {
	if messageID == "" && clientMsgNo == "" {
		return "", 0, fmt.Errorf("wukong msgsync revoke lookup: empty message_id/client_msg_no")
	}
	start, end, limit, pullMode := 0, 0, 100, 0
	if messageSeq > 0 {
		// 窄范围: seq-1..seq+1 (limit=4 留一点边界余量).
		start = int(messageSeq) - 1
		if start < 0 {
			start = 0
		}
		end = int(messageSeq) + 1
		limit = 4
		// WuKong 当前版本对指定 start/end 的历史窗口必须向前拉取；
		// pull_mode=0 会返回空窗口，把真实消息误判成 not found。
		pullMode = 1
	}
	logger := logpkg.Default().With(
		"event", "chat.message_revoke.wukong_lookup",
		"tenant_id", tenantID,
		"account_id", callerAccountID,
		"channel_id", channelID,
		"channel_type", channelType,
		"requested_message_id", messageID,
		"requested_message_seq", messageSeq,
		"has_client_msg_no", clientMsgNo != "",
		"start_message_seq", start,
		"end_message_seq", end,
		"limit", limit,
		"pull_mode", pullMode,
	)
	raw, err := p.Sync(ctx, tenantID, callerAccountID, channelID, channelType, start, end, limit, pullMode)
	if err != nil {
		logger.Warn(ctx, "chat.message_revoke.wukong_lookup_failed", "err", err)
		return "", 0, err
	}
	var resp syncChannelMessagesResp
	if jerr := json.Unmarshal(raw, &resp); jerr != nil {
		logger.Warn(ctx, "chat.message_revoke.wukong_lookup_decode_failed",
			"response_bytes", len(raw),
			"err", jerr,
		)
		return "", 0, fmt.Errorf("wukong msgsync revoke lookup: unmarshal: %w", jerr)
	}
	if messageID != "" {
		for _, m := range resp.Messages {
			if m.hasMessageID(messageID) {
				logger.Info(ctx, "chat.message_revoke.wukong_message_found",
					"matched_by", "message_id",
					"returned_message_count", len(resp.Messages),
					"found_message_seq", m.MessageSeq,
					"found_from_uid", m.FromUID,
				)
				return m.FromUID, m.MessageSeq, nil
			}
		}
	}
	if clientMsgNo != "" {
		for _, m := range resp.Messages {
			if m.ClientMsgNo == clientMsgNo {
				logger.Info(ctx, "chat.message_revoke.wukong_message_found",
					"matched_by", "client_msg_no",
					"returned_message_count", len(resp.Messages),
					"found_message_seq", m.MessageSeq,
					"found_from_uid", m.FromUID,
				)
				return m.FromUID, m.MessageSeq, nil
			}
		}
	}
	returnedMessageIDs := make([]string, 0, len(resp.Messages))
	returnedMessageSeqs := make([]int64, 0, len(resp.Messages))
	for _, m := range resp.Messages {
		returnedMessageIDs = append(returnedMessageIDs, m.seqMessageInfo().MessageID)
		returnedMessageSeqs = append(returnedMessageSeqs, m.MessageSeq)
	}
	logger.Warn(ctx, "chat.message_revoke.wukong_message_not_found",
		"returned_message_count", len(resp.Messages),
		"returned_message_ids", returnedMessageIDs,
		"returned_message_seqs", returnedMessageSeqs,
	)
	return "", 0, ErrMessageNotFound
}

// LookupSendersBySeqs F09 P1 已读回执: 批量查询若干 message_seq 对应的 from_uid.
//
// 用法: 已读回执 endpoint 必须验证 caller 是否为消息原发送者; 不信客户端.
// 本方法返回 `map[seq]fromUID`, 调用方再比对 `callerWuKongUID`.
//
// 参数:
//   - seqs: 去重后的 seq 列表; 全部 >0; len 在调用方 cap (≤ MaxReceiptsSeqs).
//
// 实现: 取 seqs 的 [min-1, max+1] 窗口一次性 Sync 拉回, 限 limit 上限避免拉超大段.
// 注意: WuKong /channel/messagesync 在当前版本下, 指定 start/end 的历史窗口需用 pull_mode=1
// 才会返回目标 seq; pull_mode=0 会返回空窗口, 导致 sender 校验误判 not_sender。
// 若 (max-min+1) 超过 windowLimit, 退化为单 seq 窄查 (每条 limit=4).
// SyncChannelMessages 层已带 (tenant 命名空间 / 群成员闸) 闸口, 故本方法继承可见性保护.
//
// 返回:
//   - 命中的 seq → from_uid (空 string 也算"消息存在但 from_uid 为空" — 调用方应视作不匹配).
//   - 未命中的 seq 不出现在 map 中 (调用方应据此判定 not found, 403).
//   - 网络/跨租户错 → 透传 Sync 的 error.
func (p *MessageSyncProxy) LookupSendersBySeqs(
	ctx context.Context,
	tenantID, callerAccountID int64,
	channelID string, channelType int,
	seqs []int64,
) (map[int64]string, error) {
	infos, err := p.LookupMessagesBySeqs(ctx, tenantID, callerAccountID, channelID, channelType, seqs)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string, len(infos))
	for seq, info := range infos {
		out[seq] = info.FromUID
	}
	return out, nil
}

// LookupMessagesBySeqs F09 P1 已读回执: 批量查询若干 message_seq 对应的 from_uid/message_id.
//
// 相比 LookupSendersBySeqs,本方法额外暴露 WuKong message_id,用于把 seq 对回
// Bus 本地 messages.metadata.wukong_message_id,从而识别 @Agent 消息的 agent 收到状态。
func (p *MessageSyncProxy) LookupMessagesBySeqs(
	ctx context.Context,
	tenantID, callerAccountID int64,
	channelID string, channelType int,
	seqs []int64,
) (map[int64]SeqMessageInfo, error) {
	if len(seqs) == 0 {
		return map[int64]SeqMessageInfo{}, nil
	}
	// 找 min/max.
	minSeq, maxSeq := seqs[0], seqs[0]
	for _, s := range seqs[1:] {
		if s < minSeq {
			minSeq = s
		}
		if s > maxSeq {
			maxSeq = s
		}
	}
	if minSeq <= 0 {
		return nil, fmt.Errorf("wukong msgsync senders lookup: seqs must be > 0")
	}
	const windowLimit = 200 // 窗口上限; 超出走 per-seq 窄查.
	out := make(map[int64]SeqMessageInfo, len(seqs))
	if maxSeq-minSeq+1 <= windowLimit {
		// 单次窗口拉.
		start := int(minSeq) - 1
		if start < 0 {
			start = 0
		}
		end := int(maxSeq) + 1
		limit := windowLimit
		raw, err := p.Sync(ctx, tenantID, callerAccountID, channelID, channelType, start, end, limit, 1)
		if err != nil {
			return nil, err
		}
		var resp syncChannelMessagesResp
		if jerr := json.Unmarshal(raw, &resp); jerr != nil {
			return nil, fmt.Errorf("wukong msgsync senders lookup unmarshal: %w", jerr)
		}
		needed := make(map[int64]struct{}, len(seqs))
		for _, s := range seqs {
			needed[s] = struct{}{}
		}
		for _, m := range resp.Messages {
			if _, want := needed[m.MessageSeq]; want {
				out[m.MessageSeq] = m.seqMessageInfo()
			}
		}
		return out, nil
	}
	// 退化: 对每个 seq 单独窄查 (避免一次拉过大段).
	for _, s := range seqs {
		start := int(s) - 1
		if start < 0 {
			start = 0
		}
		end := int(s) + 1
		raw, err := p.Sync(ctx, tenantID, callerAccountID, channelID, channelType, start, end, 4, 1)
		if err != nil {
			return nil, err
		}
		var resp syncChannelMessagesResp
		if jerr := json.Unmarshal(raw, &resp); jerr != nil {
			return nil, fmt.Errorf("wukong msgsync senders lookup unmarshal: %w", jerr)
		}
		for _, m := range resp.Messages {
			if m.MessageSeq == s {
				out[s] = m.seqMessageInfo()
				break
			}
		}
	}
	return out, nil
}

func (m syncChannelMessage) hasMessageID(messageID string) bool {
	if messageID == "" {
		return false
	}
	if m.MessageIDStr == messageID {
		return true
	}
	return rawMessageIDString(m.MessageID) == messageID
}

func (m syncChannelMessage) seqMessageInfo() SeqMessageInfo {
	messageID := m.MessageIDStr
	if messageID == "" {
		messageID = rawMessageIDString(m.MessageID)
	}
	return SeqMessageInfo{
		FromUID:    m.FromUID,
		MessageID:  messageID,
		MessageSeq: m.MessageSeq,
	}
}

func rawMessageIDString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return ""
	}
	var s string
	if err := json.Unmarshal(trimmed, &s); err == nil {
		return s
	}
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	dec.UseNumber()
	var n json.Number
	if err := dec.Decode(&n); err == nil {
		return n.String()
	}
	return strings.Trim(string(trimmed), `"`)
}

// CountPeerMessagesAfterRaw 解析 /channel/messagesync 响应并统计 after 之后的对端消息数。
// 导出纯函数方便 transport/service 窄测复用;不解析 payload 明文。
func CountPeerMessagesAfterRaw(raw []byte, ownUID string, after time.Time) (count int, ok bool, err error) {
	if ownUID == "" || after.IsZero() {
		return 0, false, nil
	}
	var resp syncChannelMessagesResp
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0, false, err
	}
	afterUnix := after.Unix()
	for _, m := range resp.Messages {
		if m.Timestamp <= afterUnix {
			continue
		}
		if m.FromUID == "" || m.FromUID == ownUID {
			continue
		}
		count++
	}
	return count, true, nil
}
