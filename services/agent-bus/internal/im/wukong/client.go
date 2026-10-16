package wukong

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Client 是 WuKongIM 特权 REST(容器 :5001)的最小客户端。
//
// 安全(ADR-0026 / boundaries §1 不变量 5):此 REST **仅 agent-bus 服务端可访问**,
// 部署上只绑 127.0.0.1 / 内网;**绝不暴露给客户端**(知道 channel_id 即可跨租户读历史)。
// 客户端只走 TCP/WS 长连接 + agent-bus 代理。
//
// WuKong REST 无租户/调用方鉴权(特权口),错误不向业务层泄漏内部细节。
type Client struct {
	baseURL string // e.g. http://127.0.0.1:31021
	hc      *http.Client
}

// ConnectionInfo 是 WuKongIM /connz 返回的单条长连接快照。这里刻意不接收
// AES key/IV、token、IP 等敏感字段，避免它们进入 Bus 日志或持久化链路。
type ConnectionInfo struct {
	CID          int64
	UID          string
	DeviceID     string
	DeviceFlag   int
	DeviceLevel  int
	Version      flexibleString
	Start        string
	LastActivity string
}

// connectionInfoWire 兼容 WuKong /connz 的两种已验证响应：
//   - cid/device_flag/device_level/start
//   - v1.2.6 运行实例的 id/device/uptime（device 示例：PC(从)）
//
// 数值字段使用指针区分“真实值为 0”和“字段不存在”，避免把缺失 device_flag
// 的 Go 零值误判成 App。
type connectionInfoWire struct {
	CID          *int64         `json:"cid"`
	ID           *int64         `json:"id"`
	UID          string         `json:"uid"`
	DeviceID     string         `json:"device_id"`
	DeviceFlag   *int           `json:"device_flag"`
	DeviceLevel  *int           `json:"device_level"`
	Device       string         `json:"device"`
	Version      flexibleString `json:"version"`
	Start        string         `json:"start"`
	Uptime       string         `json:"uptime"`
	LastActivity string         `json:"last_activity"`
}

// flexibleString 兼容 WuKongIM 不同版本的 /connz 响应：version 在部分
// 部署中是 JSON number，在另一些部署中是 JSON string。监控只需要展示，
// 统一规范化为字符串，避免单条连接导致整页快照解析失败。
type flexibleString string

func (s *flexibleString) UnmarshalJSON(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	switch typed := value.(type) {
	case string:
		*s = flexibleString(typed)
	case json.Number:
		*s = flexibleString(typed.String())
	case nil:
		*s = ""
	default:
		return fmt.Errorf("wukong: unsupported connection version type %T", value)
	}
	return nil
}

type ConnectionPage struct {
	NumConnections int              `json:"num_connections"`
	Total          int              `json:"total"`
	Offset         int              `json:"offset"`
	Limit          int              `json:"limit"`
	Connections    []ConnectionInfo `json:"connections"`
}

type connectionPageWire struct {
	NumConnections int                  `json:"num_connections"`
	Total          int                  `json:"total"`
	Offset         int                  `json:"offset"`
	Limit          int                  `json:"limit"`
	Now            string               `json:"now"`
	Connections    []connectionInfoWire `json:"connections"`
}

// NewClient. baseURL 为 WuKong 特权 REST 地址。
func NewClient(baseURL string, hc *http.Client) *Client {
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Second}
	}
	return &Client{baseURL: strings.TrimRight(baseURL, "/"), hc: hc}
}

func (c *Client) post(ctx context.Context, path string, body any) ([]byte, error) {
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("wukong: marshal %s: %w", path, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(buf))
	if err != nil {
		return nil, fmt.Errorf("wukong: build req %s: %w", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("wukong: http %s: %w", path, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("wukong: %s -> HTTP %d", path, resp.StatusCode)
	}
	return respBody, nil
}

func (c *Client) get(ctx context.Context, path string, query url.Values) ([]byte, error) {
	u := c.baseURL + path
	if encoded := query.Encode(); encoded != "" {
		u += "?" + encoded
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("wukong: build req %s: %w", path, err)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("wukong: http %s: %w", path, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("wukong: %s -> HTTP %d", path, resp.StatusCode)
	}
	return respBody, nil
}

// ListConnections 读取 WuKongIM 当前连接快照。subs=0 避免把订阅详情拉入
// 监控采集；分页由调用方遍历，只有整轮成功后才允许更新离线状态。
func (c *Client) ListConnections(ctx context.Context, offset, limit int) (ConnectionPage, error) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	b, err := c.get(ctx, "/connz", url.Values{
		"offset": {strconv.Itoa(offset)},
		"limit":  {strconv.Itoa(limit)},
		"subs":   {"0"},
	})
	if err != nil {
		return ConnectionPage{}, err
	}
	var wire connectionPageWire
	if err := json.Unmarshal(b, &wire); err != nil {
		return ConnectionPage{}, fmt.Errorf("wukong: /connz decode resp: %w", err)
	}
	out := ConnectionPage{
		NumConnections: wire.NumConnections,
		Total:          wire.Total,
		Offset:         wire.Offset,
		Limit:          wire.Limit,
		Connections:    make([]ConnectionInfo, 0, len(wire.Connections)),
	}
	for index, item := range wire.Connections {
		connection, err := normalizeConnectionInfo(item, wire.Now)
		if err != nil {
			return ConnectionPage{}, fmt.Errorf("wukong: /connz connection[%d]: %w", index, err)
		}
		out.Connections = append(out.Connections, connection)
	}
	if out.NumConnections == 0 {
		out.NumConnections = len(out.Connections)
	}
	if out.Total == 0 {
		out.Total = out.NumConnections
	}
	return out, nil
}

func normalizeConnectionInfo(wire connectionInfoWire, pageNow string) (ConnectionInfo, error) {
	var cid int64
	switch {
	case wire.CID != nil:
		cid = *wire.CID
	case wire.ID != nil:
		cid = *wire.ID
	default:
		return ConnectionInfo{}, fmt.Errorf("connection id missing")
	}

	deviceFlag, deviceLevel, err := normalizeDevice(wire)
	if err != nil {
		return ConnectionInfo{}, err
	}
	start := strings.TrimSpace(wire.Start)
	if start == "" && strings.TrimSpace(wire.Uptime) != "" {
		now, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(pageNow))
		if err != nil {
			return ConnectionInfo{}, fmt.Errorf("invalid page now for uptime: %w", err)
		}
		uptime, err := time.ParseDuration(strings.TrimSpace(wire.Uptime))
		if err != nil {
			return ConnectionInfo{}, fmt.Errorf("invalid uptime %q: %w", wire.Uptime, err)
		}
		start = now.Add(-uptime).Format(time.RFC3339Nano)
	}

	return ConnectionInfo{
		CID:          cid,
		UID:          wire.UID,
		DeviceID:     wire.DeviceID,
		DeviceFlag:   deviceFlag,
		DeviceLevel:  deviceLevel,
		Version:      wire.Version,
		Start:        start,
		LastActivity: wire.LastActivity,
	}, nil
}

func normalizeDevice(wire connectionInfoWire) (int, int, error) {
	if wire.DeviceFlag != nil {
		level := 0
		if wire.DeviceLevel != nil {
			level = *wire.DeviceLevel
		}
		return *wire.DeviceFlag, level, nil
	}

	device := strings.TrimSpace(wire.Device)
	kind := device
	if index := strings.IndexRune(kind, '('); index >= 0 {
		kind = kind[:index]
	}
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "app":
		return 0, deviceLevelFromLabel(device), nil
	case "web":
		return 1, deviceLevelFromLabel(device), nil
	case "pc", "desktop":
		return 2, deviceLevelFromLabel(device), nil
	default:
		return 0, 0, fmt.Errorf("unknown device %q without device_flag", device)
	}
}

func deviceLevelFromLabel(device string) int {
	normalized := strings.ToLower(strings.TrimSpace(device))
	if strings.Contains(normalized, "(主)") || strings.Contains(normalized, "master") {
		return 1
	}
	return 0
}

func truncateBody(b []byte, limit int) string {
	if limit <= 0 || len(b) <= limit {
		return string(b)
	}
	return string(b[:limit]) + "..."
}

// RegisterUserToken 注册/更新 uid 的连接 token(POST /user/token,幂等)。
func (c *Client) RegisterUserToken(ctx context.Context, uid, token string, deviceFlag, deviceLevel int) error {
	_, err := c.post(ctx, "/user/token", map[string]any{
		"uid":          uid,
		"token":        token,
		"device_flag":  deviceFlag,
		"device_level": deviceLevel,
	})
	return err
}

// QuitUserDevices 清空 uid 的全部设备 token，并让 WuKong 主动断开现有连接。
// device_flag=-1 是 WuKongIM v1.2.6 的“全部设备”语义。
func (c *Client) QuitUserDevices(ctx context.Context, uid string) error {
	if strings.TrimSpace(uid) == "" {
		return fmt.Errorf("wukong: quit user devices: uid required")
	}
	_, err := c.post(ctx, "/user/device_quit", map[string]any{
		"uid":         uid,
		"device_flag": -1,
	})
	return err
}

// AddSubscribers 把订阅者加入 channel(POST /channel/subscriber_add,幂等)。
// reset=0 增量添加;reset=1 全量重置。Phase 1 用增量。
func (c *Client) AddSubscribers(ctx context.Context, channelID string, channelType int, subscribers []string) error {
	_, err := c.post(ctx, "/channel/subscriber_add", map[string]any{
		"channel_id":   channelID,
		"channel_type": channelType,
		"reset":        0,
		"subscribers":  subscribers,
	})
	return err
}

// RemoveSubscribers 把订阅者移出 channel(POST /channel/subscriber_remove,幂等)。
// 用于群成员退出 / 被移除时同步 WuKong 订阅(P2.3a);移除后该 uid 不再实时收发该 channel。
func (c *Client) RemoveSubscribers(ctx context.Context, channelID string, channelType int, subscribers []string) error {
	_, err := c.post(ctx, "/channel/subscriber_remove", map[string]any{
		"channel_id":   channelID,
		"channel_type": channelType,
		"subscribers":  subscribers,
	})
	return err
}

// SyncChannelMessages 拉取 channel 历史(POST /channel/messagesync,特权口)。
// login_uid 为发起方命名空间 uid;返回 WuKong 原始响应体(payload 为 base64,本层不解析)。
// 供 agent-bus 历史同步代理透传给客户端(客户端绝不直连 :5001)。
func (c *Client) SyncChannelMessages(ctx context.Context, loginUID, channelID string, channelType, startMessageSeq, endMessageSeq, limit, pullMode int) ([]byte, error) {
	return c.post(ctx, "/channel/messagesync", map[string]any{
		"login_uid":         loginUID,
		"channel_id":        channelID,
		"channel_type":      channelType,
		"start_message_seq": startMessageSeq,
		"end_message_seq":   endMessageSeq,
		"limit":             limit,
		"pull_mode":         pullMode,
	})
}

// SyncConversations 拉取某 uid 的会话列表(POST /conversation/sync,特权口)。
// 返回 WuKong 原始响应(数组:channel_id/unread/timestamp/last_msg_seq/recents[payload base64])。
// 供 agent-bus 服务端聚合回填 /chat/conversations 的 last_message/unread(P2.1b;客户端不直连 :5001)。
// msgCount = 每会话取最近几条(回填最后一条用 1)。
func (c *Client) SyncConversations(ctx context.Context, uid string, msgCount int) ([]byte, error) {
	if msgCount <= 0 {
		msgCount = 1
	}
	return c.post(ctx, "/conversation/sync", map[string]any{
		"uid":           uid,
		"version":       0,
		"last_msg_seqs": "",
		"msg_count":     msgCount,
		"device_uuid":   "agent-bus-convsync",
	})
}

func (c *Client) sendMessageWithHeader(ctx context.Context, fromUID, channelID string, channelType int, payload []byte, header map[string]int) (messageID int64, err error) {
	b, err := c.post(ctx, "/message/send", map[string]any{
		"header":       header,
		"from_uid":     fromUID,
		"channel_id":   channelID,
		"channel_type": channelType,
		"payload":      base64.StdEncoding.EncodeToString(payload),
	})
	if err != nil {
		return 0, err
	}
	var out struct {
		Status int    `json:"status"`
		Msg    string `json:"msg"`
		Data   struct {
			MessageID   int64  `json:"message_id"`
			MessageSeq  *int64 `json:"message_seq"`
			ClientMsgNo string `json:"client_msg_no"`
		} `json:"data"`
	}
	if uerr := json.Unmarshal(b, &out); uerr != nil {
		return 0, fmt.Errorf("wukong: /message/send decode resp: %w; body=%s", uerr, truncateBody(b, 256))
	}
	if out.Status != 0 && out.Status != http.StatusOK {
		return 0, fmt.Errorf("wukong: /message/send rejected (status=%d msg=%q message_id=%d message_seq=%d body=%s)",
			out.Status, out.Msg, out.Data.MessageID, messageSeqValue(out.Data.MessageSeq), truncateBody(b, 256))
	}
	// 2026-08-07 用户反馈 + 生产事故复盘:部分 WuKong 部署对已持久化成功的
	// /message/send 响应不带 message_seq 字段(反序列化后是零值,和"真没持久化"
	// 无法区分)。曾经把 message_seq<1 直接当失败返回过(9c5a7263,当天被同作者
	// revert 掉,原因未知),outbox 收到假失败会把这条真正发送成功的消息重发,
	// 造成用户端收到多条重复消息/重复通知——线上确认过一次 17 条重复通知就是这个
	// causal chain。这里改为:message_seq 缺失时不要立即判失败,去 messagesync
	// 按 message_id/client_msg_no 反查确认是否真的已入库,查到了就当成功放行,
	// 查不到(重试耗尽)才是真失败,交给 outbox 重试。
	if header["no_persist"] == 0 && messageSeqValue(out.Data.MessageSeq) < 1 {
		if _, confirmErr := c.confirmPersistedMessage(ctx, fromUID, channelID, channelType, out.Data.MessageID, out.Data.ClientMsgNo); confirmErr != nil {
			return 0, fmt.Errorf("wukong: /message/send not persisted (status=%d msg=%q message_id=%d message_seq=%d body=%s confirm=%v)",
				out.Status, out.Msg, out.Data.MessageID, messageSeqValue(out.Data.MessageSeq), truncateBody(b, 256), confirmErr)
		}
	}
	return out.Data.MessageID, nil
}

func messageSeqValue(seq *int64) int64 {
	if seq == nil {
		return 0
	}
	return *seq
}

// confirmPersistedMessage 兼容部分 WuKong 部署的 /message/send 成功响应不返回
// message_seq。message_id 本身不是持久化证明,因此只在 channel 的最近历史中
// 找到对应 message_id/client_msg_no 且 message_seq>0 后才确认成功。
func (c *Client) confirmPersistedMessage(ctx context.Context, fromUID, channelID string, channelType int, messageID int64, clientMsgNo string) (int64, error) {
	if messageID <= 0 && strings.TrimSpace(clientMsgNo) == "" {
		return 0, fmt.Errorf("response missing message identity")
	}
	messageIDText := ""
	if messageID > 0 {
		messageIDText = strconv.FormatInt(messageID, 10)
	}
	delays := [...]time.Duration{0, 25 * time.Millisecond, 75 * time.Millisecond, 150 * time.Millisecond}
	var lastErr error
	for attempt, delay := range delays {
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return 0, ctx.Err()
			case <-timer.C:
			}
		}
		raw, err := c.SyncChannelMessages(ctx, fromUID, channelID, channelType, 0, 0, 100, 0)
		if err != nil {
			lastErr = fmt.Errorf("attempt %d messagesync: %w", attempt+1, err)
			continue
		}
		var resp syncChannelMessagesResp
		if err := json.Unmarshal(raw, &resp); err != nil {
			lastErr = fmt.Errorf("attempt %d decode messagesync: %w", attempt+1, err)
			continue
		}
		for _, message := range resp.Messages {
			matchesID := messageIDText != "" && message.hasMessageID(messageIDText)
			matchesClientMsgNo := clientMsgNo != "" && message.ClientMsgNo == clientMsgNo
			if (matchesID || matchesClientMsgNo) && message.MessageSeq > 0 {
				return message.MessageSeq, nil
			}
		}
		lastErr = fmt.Errorf("attempt %d message not found in latest history", attempt+1)
	}
	return 0, lastErr
}

// SendMessage 以 fromUID 身份向 channel 发消息(POST /message/send)。
// Phase 2:Agent 虚拟用户代发。payload 为原始字节(WuKong 不解析),内部 base64。
func (c *Client) SendMessage(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (messageID int64, err error) {
	return c.sendMessageWithHeader(ctx, fromUID, channelID, channelType, payload, map[string]int{
		"no_persist": 0,
		"red_dot":    1,
		"sync_once":  0,
	})
}

// SendEphemeralNotification 发送在线临时通知,用于 read-receipt 等轻量刷新信号。
// no_persist=1 + red_dot=0: 不进入普通历史/红点,客户端必须按 content type 旁路消费。
func (c *Client) SendEphemeralNotification(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (messageID int64, err error) {
	return c.sendMessageWithHeader(ctx, fromUID, channelID, channelType, payload, map[string]int{
		"no_persist": 1,
		"red_dot":    0,
		"sync_once":  0,
	})
}
