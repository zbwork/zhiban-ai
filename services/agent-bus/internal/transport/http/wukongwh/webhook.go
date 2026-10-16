package wukongwh

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

// WebhookPath 是 WuKong 出站 webhook 的入站路径(ADR-0026)。
const WebhookPath = "/api/agent-bus/v1/im/wukong/webhook"

// WKTextContentType 是 WuKong 文本消息的 payload type(与客户端 WKTextContent 一致)。
const WKTextContentType = 1

// WKMixedContentType 是客户端 mixed 富内容消息的 payload type。
// 仅解析其中的文本/mentions 参与 @Agent 触发;图片/文件 block 本身不触发。
const WKMixedContentType = 110

// WKAgentFinalContentType 是 EasyO Agent 最终回复的结构化消息 type
// (agent-direct 单聊与群聊 @Agent final 同构)。
// WuKong 作为最终时间线保存 markdown content + 原始 EMP/SSE blocks;SSE 仍只承载执行过程。
// 该 type 不进入 @Agent 触发链路(pre-filter 只放行 type=1/110),天然防 agent final 回环。
const WKAgentFinalContentType = 111

// WKRtcCallSignalContentType 是 F16 RTC 通话控制信令的 payload type(F16 spec v0.6.4 §6.2.6 D14)。
// payload 形如 {"type":1001,"event":"invite|cancel|accept|reject|end|ringing","data":{...}}。
// 信令仅在通话内承载控制语义, **不**触发 @Agent 链路, 见 MuxSink + CallSignalSink。
// SendMessage 的 channelType 仍是 WuKong channel type (1=person/2=group), 1001 写在 payload JSON 内部。
const WKRtcCallSignalContentType = 1001

// WKReadReceiptChangedContentType 是已读回执同步信令的 payload type
// (客户端 `{"type":1002,"kind":"read_receipt.changed",...}`, header.no_persist=1)。
// 纯已读位点同步, 不代表新消息, **不**应触发推送通知, 见 NotificationSink.OnMessage。
const WKReadReceiptChangedContentType = 1002

// Header / query 两种方式携带内网 secret(WuKong webhook 默认无自定义 header,
// 故也支持把 secret 放进 webhook URL 的 ?secret=)。
const (
	secretHeader = "X-WK-Webhook-Secret"
	secretQuery  = "secret"
)

// Mention 是消息 payload.mentions 里的一个结构化提及(飞书式 @entity)。
// 客户端发送时在 content 保留可读 "@名字" 文本的同时, 附 mentions 元数据;
// 后端按 metadata 优先、文本 parser 兜底。
type Mention struct {
	Type string `json:"type"` // all | human | agent
	ID   string `json:"id"`   // all="all"; human=account_uuid; agent=agent_uuid
	Name string `json:"name"`
}

// Event 是从 WuKong webhook 解析出的单条消息事件(供 Agent 触发消费)。
type Event struct {
	MessageID   string
	FromUID     string
	ChannelID   string
	ChannelType int
	EventType   string    // ?event= 值,如 msg.notify
	MessageSeq  int64     // webhook 携带则保留(观测/排序)
	Timestamp   int64     // webhook 携带则保留(unix 秒)
	ContentType int       // 解码后的 WuKong 消息 type(1=text)
	Text        string    // 仅文本消息(ContentType=1)非空;Sink 据此触发 @Agent
	Mentions    []Mention // payload.mentions(结构化 @;无 metadata 的历史消息为空,Sink 用文本兜底)
	Blocks      []map[string]any
}

// Sink 消费已去重的消息事件。Phase 1 可为 nil(仅幂等记录);Phase 2 接 Agent 触发。
type Sink interface {
	OnMessage(ctx context.Context, ev Event) error
}

// Handler 处理 WuKong webhook。Secret 必配(fail-closed);Idem 必配。
type Handler struct {
	PropagateSinkErrors bool // Community persistent run gate handles retries; retain existing default.
	Secret              string
	Idem                Idempotency
	Sink                Sink // 可选
	NotificationSink    Sink // receives every decoded message before Agent/RTC filtering
}

// wukong msg.notify body 既可能是单对象,也可能是数组(实测 G3)。
// payload 是消息正文(WuKong 默认 base64;部分配置下为原始 JSON)。
type wkMsg struct {
	MessageID   json.Number `json:"message_id"`
	MessageSeq  json.Number `json:"message_seq"`
	FromUID     string      `json:"from_uid"`
	ChannelID   string      `json:"channel_id"`
	ChannelType int         `json:"channel_type"`
	Timestamp   json.Number `json:"timestamp"`
	Payload     string      `json:"payload"`
}

func (h *Handler) checkSecret(r *http.Request) bool {
	if h.Secret == "" {
		return false // fail-closed:未配 secret 一律拒
	}
	if r.Header.Get(secretHeader) == h.Secret {
		return true
	}
	return r.URL.Query().Get(secretQuery) == h.Secret
}

// ServeHTTP:secret 校验 → 解析 → message_id 幂等 → (首次)投 Sink。
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// WuKong 对已带 query(?secret=)的 webhook URL 仍直接拼 "?event=",
	// 产生形如 "secret=x?event=msg.notify" 的非法 query,污染 secret 值。
	// 把首个 '?' 之后的 '?' 归一成 '&',让 secret/event 都能正确解析。
	if i := strings.IndexByte(r.URL.RawQuery, '?'); i >= 0 {
		r.URL.RawQuery = r.URL.RawQuery[:i] + "&" + r.URL.RawQuery[i+1:]
	}
	if !h.checkSecret(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if h.Idem == nil {
		http.Error(w, "idempotency not wired", http.StatusInternalServerError)
		return
	}
	body, _ := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	eventType := r.URL.Query().Get("event")

	msgs := parseMessages(body)
	for _, m := range msgs {
		mid := m.MessageID.String()
		if mid == "" || mid == "0" {
			continue
		}
		first, err := h.Idem.SeenOrMark(r.Context(), "wukong:"+mid)
		if err != nil {
			http.Error(w, "idempotency error", http.StatusInternalServerError)
			return
		}
		if !first {
			continue // 重放:不重复处理
		}
		if h.Sink == nil {
			continue
		}
		ct, text, mentions, blocks := decodeWKMessage(m.Payload)
		if ct > 0 && h.NotificationSink != nil {
			_ = h.NotificationSink.OnMessage(r.Context(), Event{MessageID: mid, FromUID: m.FromUID, ChannelID: m.ChannelID, ChannelType: m.ChannelType, EventType: eventType, MessageSeq: asInt64(m.MessageSeq), Timestamp: asInt64(m.Timestamp), ContentType: ct, Text: text, Mentions: mentions, Blocks: blocks})
		}
		// pre-filter: 只放行以下两类:
		//   a) type=1(text) 或 type=110(mixed) 且非空文本/mentions → 进 MuxSink, 由其分发给 wukongAgentTrigger 触发 @Agent
		//      但 F16 通话结束卡片(type=110 + call_event blocks)是系统侧信道, 不进入 Agent 触发链路。
		//   b) type=1001(RTC 通话控制信令) → 进 MuxSink, 由其分发给 CallSignalSink, **绕过** @Agent 触发, 见 F16 spec §6.2.6
		// 图片/文件/其它自定义/空文本且无 mentions/解析失败一律不进 Sink(但已记幂等, webhook 仍 200)。
		isAgentText := (ct == WKTextContentType || ct == WKMixedContentType) &&
			(strings.TrimSpace(text) != "" || len(mentions) > 0) &&
			!isCallEventOnlyMixed(ct, blocks)
		isRtcSignal := ct == WKRtcCallSignalContentType
		if !isAgentText && !isRtcSignal {
			continue
		}
		sinkErr := h.Sink.OnMessage(r.Context(), Event{
			MessageID:   mid,
			FromUID:     m.FromUID,
			ChannelID:   m.ChannelID,
			ChannelType: m.ChannelType,
			EventType:   eventType,
			MessageSeq:  asInt64(m.MessageSeq),
			Timestamp:   asInt64(m.Timestamp),
			ContentType: ct,
			Text:        text,
			Mentions:    mentions,
			Blocks:      blocks,
		})
		if sinkErr != nil && h.PropagateSinkErrors {
			http.Error(w, "message processing unavailable", http.StatusServiceUnavailable)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":200}`))
}

func asInt64(n json.Number) int64 {
	if n == "" {
		return 0
	}
	v, _ := n.Int64()
	return v
}

// wkPayload 是 WuKong 文本消息正文(与客户端 WKTextContent + mentions 扩展一致)。
type wkPayload struct {
	Type     int              `json:"type"`
	Content  string           `json:"content"`
	Text     string           `json:"text"` // 兼容个别客户端
	Summary  string           `json:"summary"`
	Blocks   []map[string]any `json:"blocks"`
	Mentions []Mention        `json:"mentions"`
}

// decodeWKMessage 解码 WuKong 消息 payload, 返回 (contentType, text, mentions, blocks)。
//
// WuKong webhook 的 payload 默认是 base64(消息正文 JSON);部分配置下直接是原始 JSON。
// 文本消息正文形如 {"type":1,"content":"...","mentions":[...]}(与客户端 WKTextContent 编码一致)。
// mixed 消息正文形如 {"type":110,"summary":"...","blocks":[...],"mentions":[...]}。
// 不支持类型/解析失败 → text 为空(caller 据此不触发 Agent);mentions 始终尽力解析。
func decodeWKMessage(payload string) (contentType int, text string, mentions []Mention, blocks []map[string]any) {
	payload = strings.TrimSpace(payload)
	if payload == "" {
		return 0, "", nil, nil
	}
	raw := []byte(payload)
	if dec, err := base64.StdEncoding.DecodeString(payload); err == nil && len(dec) > 0 && json.Valid(dec) {
		raw = dec
	}
	var p wkPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return 0, "", nil, nil
	}
	mentions = sanitizeMentions(p.Mentions)
	contentType = p.Type
	switch contentType {
	case WKTextContentType:
		if p.Content != "" {
			return contentType, p.Content, mentions, nil
		}
		return contentType, p.Text, mentions, nil
	case WKMixedContentType:
		blocks = sanitizeBlocks(p.Blocks)
		if p.Summary != "" {
			return contentType, p.Summary, mentions, blocks
		}
		return contentType, mixedBlocksText(blocks), mentions, blocks
	case WKAgentFinalContentType:
		// Agent 最终回复(type=111,见 wukong_agent_trigger.go buildWuKongAgentReplyPayload)
		// 之前没有 case,落进 default 恒返回空 text/blocks——2026-08-08 排查发现:数字员工消息
		// 的推送通知正文一直是死文案"发来一条消息"，根因就是这里 text/blocks 从没被解出来过，
		// 不是 NotificationSink 那边兜底逻辑的问题。触发 Agent 的 anti-loop 闸口在
		// wukong_agent_trigger.go 里是按 from_uid 的 sender kind 判的，不看 ContentType/Text
		// 是否为空，这里把 text/blocks 解出来不会导致 Agent 自己的回复被误当用户消息重新触发。
		blocks = sanitizeBlocks(p.Blocks)
		if p.Content != "" {
			return contentType, p.Content, mentions, blocks
		}
		if p.Summary != "" {
			return contentType, p.Summary, mentions, blocks
		}
		return contentType, mixedBlocksText(blocks), mentions, blocks
	case WKRtcCallSignalContentType:
		// RTC 信令: 保留原始 payload 给 CallSignalSink, 但**不**产出可见文本(text 留空)。
		// blocks[0]._rtc_signal_raw = base64(原始 JSON), 由 CallSignalSink 反解出 event/data。
		// 这里有意不解析 event/data 字段 —— 这是 sink 的职责, webhook 层只承担 envelope 传递。
		return contentType, "", nil, []map[string]any{
			{"_rtc_signal_raw": base64.StdEncoding.EncodeToString(raw)},
		}
	default:
		return contentType, "", mentions, nil
	}
}

func mixedBlocksText(blocks []map[string]any) string {
	if len(blocks) == 0 {
		return ""
	}
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		kind := strings.TrimSpace(stringField(b, "type"))
		if kind == "" {
			kind = strings.TrimSpace(stringField(b, "kind"))
		}
		if strings.EqualFold(kind, "text") {
			if t := strings.TrimSpace(stringField(b, "text")); t != "" {
				parts = append(parts, t)
			}
		}
	}
	return strings.Join(parts, "\n")
}

func isCallEventOnlyMixed(contentType int, blocks []map[string]any) bool {
	if contentType != WKMixedContentType || len(blocks) == 0 {
		return false
	}
	for _, b := range blocks {
		kind := strings.TrimSpace(stringField(b, "type"))
		if kind == "" {
			kind = strings.TrimSpace(stringField(b, "kind"))
		}
		if !strings.EqualFold(kind, "call_event") {
			return false
		}
	}
	return true
}

func sanitizeBlocks(in []map[string]any) []map[string]any {
	if len(in) == 0 {
		return nil
	}
	out := make([]map[string]any, 0, len(in))
	for _, raw := range in {
		t := strings.ToLower(strings.TrimSpace(stringField(raw, "type")))
		if t == "" {
			t = strings.ToLower(strings.TrimSpace(stringField(raw, "kind")))
		}
		switch t {
		case "text", "markdown", "image", "file", "skill", "call_event":
		default:
			continue
		}
		b := map[string]any{"type": t}
		for _, k := range []string{"text", "url", "file_uuid", "ref_uuid", "slug", "name", "mime", "media_kind", "end_reason"} {
			if v := strings.TrimSpace(stringField(raw, k)); v != "" {
				b[k] = v
			}
		}
		for _, k := range []string{"size", "width", "height", "duration_ms"} {
			if v, ok := numberField(raw, k); ok {
				b[k] = v
			}
		}
		out = append(out, b)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func stringField(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return strings.TrimSpace(strings.Trim(vToString(v), "\""))
}

func vToString(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}

func numberField(m map[string]any, key string) (int64, bool) {
	v, ok := m[key]
	if !ok || v == nil {
		return 0, false
	}
	switch x := v.(type) {
	case float64:
		if x > 0 {
			return int64(x), true
		}
	case int:
		if x > 0 {
			return int64(x), true
		}
	case int64:
		if x > 0 {
			return x, true
		}
	case json.Number:
		if n, err := x.Int64(); err == nil && n > 0 {
			return n, true
		}
	}
	return 0, false
}

// sanitizeMentions 只保留已知类型(all/human/agent)且字段合理的 mention。
func sanitizeMentions(in []Mention) []Mention {
	if len(in) == 0 {
		return nil
	}
	out := make([]Mention, 0, len(in))
	for _, m := range in {
		t := strings.ToLower(strings.TrimSpace(m.Type))
		switch t {
		case "all", "human", "agent":
		default:
			continue
		}
		out = append(out, Mention{Type: t, ID: strings.TrimSpace(m.ID), Name: strings.TrimSpace(m.Name)})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// parseMessages 兼容数组与单对象两种 body 形态。
func parseMessages(body []byte) []wkMsg {
	var arr []wkMsg
	if err := json.Unmarshal(body, &arr); err == nil && len(arr) > 0 {
		return arr
	}
	var one wkMsg
	if err := json.Unmarshal(body, &one); err == nil {
		return []wkMsg{one}
	}
	return nil
}
