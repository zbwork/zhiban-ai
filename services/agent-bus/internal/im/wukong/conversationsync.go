package wukong

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

// ConversationSyncProxy 服务端聚合用:按**当前账号自己的** WuKong uid 拉会话列表,
// 回填 /chat/conversations 的 last_message / unread(P2.1b,ADR-0026)。
//
// 安全:
//   - uid 永远由 accountID 服务端派生(UserUID),客户端无法指定任意 uid;
//   - WuKong /conversation/sync 只返回该 uid 自己的会话(其订阅频道),天然限本账号 + 本租户命名空间;
//   - 这是**服务端内部 adapter**,不暴露为客户端 endpoint;客户端不直连 :5001。
type ConversationSyncProxy struct {
	client *Client
	lookup AccountLookup
}

func NewConversationSyncProxy(client *Client, lookup AccountLookup) *ConversationSyncProxy {
	return &ConversationSyncProxy{client: client, lookup: lookup}
}

// ConversationSyncMsgCount 是 SyncForAccount 传给 /conversation/sync 的 msg_count——
// 每个会话带回多少条最近消息。WuKong 官方文档(conversation/sync)写死上限 50
// (超过会被服务端限到 50),调到上限是为了让 listConvos 的未读重算优先用这批
// 随手带回来的 recents 本地数出结果,省掉大部分按 channel 单独打
// /channel/messagesync 的 N+1 调用(2026-08-21:那个 N+1 是线上 /chat/conversations
// 502/超时高发的根因,见 CountPeerMessagesAfterCached)。
const ConversationSyncMsgCount = 50

// ConvSyncItem 单会话的时间线摘要(WuKong 为真理)。
type ConvSyncItem struct {
	ChannelID   string
	ChannelType int
	Unread      int
	LastText    string // 最近一条文本(type=1);非文本/解析失败为空
	LastFromUID string
	LastTS      int64 // 秒
	// Recents 是这次 /conversation/sync 一并带回来的最近消息(最多
	// ConversationSyncMsgCount 条,任意类型,不只是文本),供本地数未读用;
	// from_uid 为空 / timestamp 非法的条目会被过滤掉,不进这个切片。
	Recents []RecentMsg
	// RawRecentsCount 是过滤前的原始条数(<= ConversationSyncMsgCount)。判断
	// recents 有没有被 WuKong 截断必须用这个,不能用 len(Recents)——见
	// CountPeerMessagesAfterCached 的调用方注释。
	RawRecentsCount int
}

// RecentMsg 是 Recents 里单条消息的最小信息(只留数未读要用的字段,不碰 payload 明文)。
type RecentMsg struct {
	FromUID   string
	Timestamp int64 // 秒
}

// SyncForAccount 拉当前账号自己的会话摘要,返回 map[channelID]ConvSyncItem。
// 失败由调用方降级(返回 err,调用方保留列表只是不回填)。
func (p *ConversationSyncProxy) SyncForAccount(ctx context.Context, tenantID, accountID int64) (map[string]ConvSyncItem, error) {
	if tenantID <= 0 || accountID <= 0 {
		return nil, fmt.Errorf("wukong convsync: invalid tenant/account")
	}
	callerUUID, err := p.lookup.AccountUUID(ctx, accountID)
	if err != nil {
		return nil, fmt.Errorf("wukong convsync: caller lookup: %w", err)
	}
	uid := UserUID(tenantID, callerUUID)
	raw, err := p.client.SyncConversations(ctx, uid, ConversationSyncMsgCount)
	if err != nil {
		return nil, fmt.Errorf("wukong convsync: %w", err)
	}
	return parseConversationSync(raw), nil
}

// wkConvRow / wkRecent 对齐 WuKong /conversation/sync 响应(实测形态)。
type wkConvRow struct {
	ChannelID   string     `json:"channel_id"`
	ChannelType int        `json:"channel_type"`
	Unread      int        `json:"unread"`
	Timestamp   int64      `json:"timestamp"`
	Recents     []wkRecent `json:"recents"`
}

type wkRecent struct {
	FromUID   string `json:"from_uid"`
	Timestamp int64  `json:"timestamp"`
	Payload   string `json:"payload"` // base64({"content":..,"type":1})
}

// parseConversationSync 容错解析:整体解析失败 → 返回空 map(调用方降级,不打挂列表);
// 单条 payload 解析失败 → 该条 LastText 留空,unread 仍保留。
func parseConversationSync(raw []byte) map[string]ConvSyncItem {
	out := map[string]ConvSyncItem{}
	var rows []wkConvRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return out
	}
	for _, r := range rows {
		if r.ChannelID == "" {
			continue
		}
		item := ConvSyncItem{
			ChannelID:   r.ChannelID,
			ChannelType: r.ChannelType,
			Unread:      r.Unread,
			LastTS:      r.Timestamp,
		}
		if len(r.Recents) > 0 {
			item.RawRecentsCount = len(r.Recents)
			item.Recents = make([]RecentMsg, 0, len(r.Recents))
			for _, recent := range r.Recents {
				// 数未读不看消息类型/payload 内容(图片/文件也算一条未读),只要有
				// from_uid + 正时间戳就收进来。
				if recent.FromUID == "" || recent.Timestamp <= 0 {
					continue
				}
				item.Recents = append(item.Recents, RecentMsg{FromUID: recent.FromUID, Timestamp: recent.Timestamp})
			}
			var picked wkRecent
			var pickedText string
			pickedOK := false
			for _, recent := range r.Recents {
				text, ok := decodeDisplayPayload(recent.Payload)
				if !ok || strings.TrimSpace(text) == "" {
					continue
				}
				if !pickedOK ||
					(recent.Timestamp > 0 && (picked.Timestamp <= 0 || recent.Timestamp > picked.Timestamp)) {
					picked = recent
					pickedText = text
					pickedOK = true
				}
			}
			if pickedOK {
				item.LastFromUID = picked.FromUID
				if picked.Timestamp > 0 {
					item.LastTS = picked.Timestamp
				}
				item.LastText = pickedText
			}
		}
		out[r.ChannelID] = item
	}
	return out
}

// WuKong 消息内容类型(与客户端 WkMessageContentType 对齐)。
const (
	wkMsgTypeText       = 1
	wkMsgTypeImage      = 2
	wkMsgTypeFile       = 8
	wkMsgTypeMixed      = 110
	wkMsgTypeAgentFinal = 111
)

// decodeTextPayload 解 base64 → JSON,生成 last_message 展示文案:
//   - type==1 文本 → content;
//   - type==2 图片 → "[图片]";
//   - type==8 文件 → 文件名(无则 "[文件]");
//   - 其余/失败 → 空串(不报错,调用方降级)。
func decodeTextPayload(b64 string) string {
	text, _ := decodeDisplayPayload(b64)
	return text
}

func decodeDisplayPayload(b64 string) (string, bool) {
	if b64 == "" {
		return "", false
	}
	dec, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", false
	}
	var p struct {
		Content string `json:"content"`
		Type    int    `json:"type"`
		Name    string `json:"name"`
		Summary string `json:"summary"`
		Blocks  []struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			Markdown string `json:"markdown"`
			Name     string `json:"name"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal(dec, &p); err != nil {
		return "", false
	}
	switch p.Type {
	case wkMsgTypeText:
		return p.Content, p.Content != ""
	case wkMsgTypeImage:
		return "[图片]", true
	case wkMsgTypeFile:
		if p.Name != "" {
			return p.Name, true
		}
		return "[文件]", true
	case wkMsgTypeMixed:
		if strings.TrimSpace(p.Summary) != "" {
			return p.Summary, true
		}
		text := mixedBlocksText(p.Blocks)
		return text, text != ""
	case wkMsgTypeAgentFinal:
		if strings.TrimSpace(p.Summary) != "" {
			return p.Summary, true
		}
		if strings.TrimSpace(p.Content) != "" {
			return p.Content, true
		}
		text := mixedBlocksText(p.Blocks)
		return text, text != ""
	default:
		return "", false
	}
}

func mixedBlocksText(blocks []struct {
	Type     string `json:"type"`
	Text     string `json:"text"`
	Markdown string `json:"markdown"`
	Name     string `json:"name"`
}) string {
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if strings.TrimSpace(b.Text) != "" {
				parts = append(parts, strings.TrimSpace(b.Text))
			}
		case "markdown":
			text := b.Markdown
			if text == "" {
				text = b.Text
			}
			if strings.TrimSpace(text) != "" {
				parts = append(parts, strings.TrimSpace(text))
			}
		case "image":
			parts = append(parts, "[图片]")
		case "file":
			if strings.TrimSpace(b.Name) != "" {
				parts = append(parts, strings.TrimSpace(b.Name))
			} else {
				parts = append(parts, "[文件]")
			}
		}
	}
	return strings.Join(parts, " ")
}
